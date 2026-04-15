import Foundation
import QuartzCore
import CoreMedia
import CoreVideo
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil

#if canImport(UIKit)
import UIKit
#endif

/// SteelPlayer — Open-source FFmpeg + VideoToolbox video player engine.
///
/// A cross-platform (iOS, tvOS, macOS) media player that handles
/// demuxing, hardware-accelerated decoding via VideoToolbox, and
/// audio/video output via Apple's AVSampleBuffer infrastructure.
/// No UIKit/AppKit dependency — the host app provides its own UI
/// and simply embeds the player's `videoLayer` in a view.
///
/// ## Architecture
///
/// ```
/// URL → AVIO (URLSession) → FFmpeg Demuxer → AVPackets
///   ├─ Video → VideoToolbox HW Decode → CVPixelBuffer → AVSampleBufferDisplayLayer
///   └─ Audio → FFmpeg SW Decode → CMSampleBuffer → AVSampleBufferAudioRenderer
///   └─ Both synced via AVSampleBufferRenderSynchronizer (master clock)
/// ```
///
/// ## Quick Start
///
/// ```swift
/// let player = try SteelPlayer()
/// myView.layer.addSublayer(player.videoLayer)
/// try await player.load(url: myVideoURL)
/// player.play()
/// ```
///
/// ## License
///
/// LGPL 3.0 — App Store compatible when dynamically linked.
@MainActor
public final class SteelPlayer: ObservableObject {

    // MARK: - Public State

    @Published public private(set) var state: PlaybackState = .idle
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var progress: Float = 0
    @Published public private(set) var audioTracks: [TrackInfo] = []
    @Published public private(set) var subtitleTracks: [TrackInfo] = []
    @Published public private(set) var videoFormat: VideoFormat = .sdr

    // MARK: - Output

    /// The video layer to embed in the host view hierarchy.
    /// Uses AVSampleBufferDisplayLayer for optimal frame pacing.
    public var videoLayer: CALayer { videoRenderer.displayLayer }

    // MARK: - Internal Pipeline

    /// Pipeline components — accessed from both main actor and demux queue.
    /// Each has internal locking for thread safety.
    nonisolated(unsafe) private let demuxer = Demuxer()
    private let videoDecoder = VideoDecoder()
    nonisolated(unsafe) private let softwareDecoder = SoftwareVideoDecoder()
    private let audioDecoder = AudioDecoder()

    /// True if the current stream uses software decoding (FFmpeg) instead of VT.
    /// Set during load(), read during demux loop — effectively immutable during playback.
    nonisolated(unsafe) private var usingSoftwareDecode = false
    private let audioOutput = AudioOutput()
    nonisolated(unsafe) private let videoRenderer = SampleBufferRenderer()

    /// AVPlayer-based audio engine for EAC3/AC3 with Dolby Atmos passthrough.
    /// nil when using the standard FFmpeg→PCM pipeline.
    /// Accessed from demux queue — protected by single-writer (main actor sets, demux queue reads).
    nonisolated(unsafe) private var avPlayerAudioEngine: AVPlayerAudioEngine?

    /// True when the current audio track uses AVPlayer for Atmos passthrough.
    nonisolated(unsafe) private var usingAVPlayerAudio = false

    /// True when waiting for the first audio packet to initialize the AVPlayer engine.
    nonisolated(unsafe) private var avPlayerAwaitingFirstPacket = false

    /// True when the AVPlayer engine needs to restart after a seek (vs. initial start).
    nonisolated(unsafe) private var avPlayerNeedsSeekRestart = false

    /// The target seek time for AVPlayer restart.
    nonisolated(unsafe) private var avPlayerSeekTarget: Double = 0

    /// Stored codec info for AVPlayer audio engine initialization from demux loop.
    nonisolated(unsafe) private var avPlayerCodecType: FMP4AudioMuxer.CodecType = .eac3
    nonisolated(unsafe) private var avPlayerSampleRate: UInt32 = 48000
    nonisolated(unsafe) private var avPlayerChannelCount: UInt32 = 6
    nonisolated(unsafe) private var avPlayerBitRate: UInt32 = 640000

    /// Serial queue for the demux→decode loop (runs off main thread).
    private let demuxQueue = DispatchQueue(label: "com.steelplayer.demux", qos: .userInitiated)

    /// Thread-safe playback control flags.
    /// Accessed from both main actor and demux queue — protected by flagsLock.
    private let flagsLock = NSLock()
    nonisolated(unsafe) private var _isPlaying = false
    nonisolated(unsafe) private var _stopRequested = false

    /// Whether the audio stream was successfully opened.
    private var audioAvailable = false

    /// Detected video frame rate.
    private var videoFrameRate: Double = 0

    /// Condition for waking the demux loop from pause.
    private let demuxCondition = NSCondition()

    nonisolated private var isPlaying: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _isPlaying }
        set {
            flagsLock.lock()
            _isPlaying = newValue
            flagsLock.unlock()
            if newValue { demuxCondition.broadcast() }
        }
    }
    nonisolated private var stopRequested: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _stopRequested }
        set {
            flagsLock.lock()
            _stopRequested = newValue
            flagsLock.unlock()
            if newValue { demuxCondition.broadcast() }
        }
    }

    // MARK: - Init

    /// Lifecycle notification observers — stored for cleanup.
    private var lifecycleObservers: [Any] = []

    public init() throws {
        // Configure audio session BEFORE creating renderers — the renderer
        // may lock its output configuration at creation time. Without this,
        // multichannel content is downmixed to stereo.
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
            try session.setSupportsMultichannelContent(true)
            try session.setActive(true)
        } catch {
            print("[SteelPlayer] AVAudioSession setup error: \(error)")
        }
        // Request multichannel output — separate try so a failure here
        // doesn't prevent the basic audio session from working.
        let maxCh = session.maximumOutputNumberOfChannels
        if maxCh > 2 {
            try? session.setPreferredOutputNumberOfChannels(maxCh)
        }
        #if DEBUG
        print("[SteelPlayer] Audio session: maxChannels=\(maxCh), preferred=\(session.preferredOutputNumberOfChannels), output=\(session.outputNumberOfChannels)")
        #endif
        #endif

        // Display layer timing is configured in load() based on which
        // audio engine is active (synchronizer for PCM, controlTimebase for AVPlayer).
        setupLifecycleObservers()
    }

    // MARK: - Public API

    /// Load a media file or stream URL. Replaces any current playback.
    public func load(url: URL, startPosition: Double? = nil) async throws {
        // Tear down any previous playback
        stopInternal()

        state = .loading
        currentTime = 0
        duration = 0
        progress = 0
        audioTracks = []
        subtitleTracks = []
        videoFormat = .sdr
        audioAvailable = false
        stopRequested = false

        #if DEBUG
        print("[SteelPlayer] Loading: \(url.absoluteString)")
        #endif

        do {
            // 1. Open the container with FFmpeg
            try demuxer.open(url: url)
            duration = demuxer.duration

            // 2. Find the video stream and open the hardware decoder
            let videoIdx = demuxer.videoStreamIndex
            guard videoIdx >= 0, let videoStream = demuxer.stream(at: videoIdx) else {
                throw SteelPlayerError.noVideoStream
            }

            let videoRenderer = self.videoRenderer
            let frameCallback: DecodedFrameHandler = { pixelBuffer, pts in
                videoRenderer.enqueue(pixelBuffer: pixelBuffer, pts: pts)
            }

            // Try VideoToolbox hardware decode first, fall back to FFmpeg
            // software decode for codecs without HW support (AV1 on A15, etc.)
            do {
                try videoDecoder.open(stream: videoStream, onFrame: frameCallback)
                usingSoftwareDecode = false
                #if DEBUG
                print("[SteelPlayer] Using VideoToolbox hardware decode")
                #endif
            } catch {
                #if DEBUG
                print("[SteelPlayer] VT failed: \(error) — trying software decode")
                #endif
                do {
                    try softwareDecoder.open(stream: videoStream, onFrame: frameCallback)
                    usingSoftwareDecode = true
                    #if DEBUG
                    print("[SteelPlayer] Using FFmpeg software decode")
                    #endif
                } catch {
                    #if DEBUG
                    print("[SteelPlayer] Software decode also failed: \(error)")
                    #endif
                    throw error
                }
            }

            // Detect video format (SDR/HDR10/DV/HLG) from codec parameters
            videoFormat = detectVideoFormat(stream: videoStream)

            // Detect video frame rate for display link matching.
            // Also used for AVDisplayCriteria to set correct refresh rate.
            let avgFR = videoStream.pointee.avg_frame_rate
            if avgFR.den > 0 && avgFR.num > 0 {
                videoFrameRate = Double(avgFR.num) / Double(avgFR.den)
            } else {
                let rFR = videoStream.pointee.r_frame_rate
                if rFR.den > 0 && rFR.num > 0 {
                    videoFrameRate = Double(rFR.num) / Double(rFR.den)
                }
            }
            #if DEBUG
            print("[SteelPlayer] Video frame rate: \(String(format: "%.3f", videoFrameRate)) fps")
            #endif

            // Populate track metadata from the demuxer
            audioTracks = demuxer.audioTrackInfos()
            subtitleTracks = demuxer.subtitleTrackInfos()

            // 2b. Find the audio stream and configure the appropriate audio engine
            let audioIdx = demuxer.audioStreamIndex
            activeAudioStreamIndex = audioIdx
            usingAVPlayerAudio = false
            avPlayerAwaitingFirstPacket = false

            if audioIdx >= 0, let audioStream = demuxer.stream(at: audioIdx) {
                let codecId = audioStream.pointee.codecpar?.pointee.codec_id
                // Only EAC3 can carry Atmos (via JOC dependent substreams).
                // AC3 never has Atmos — always use PCM for AC3.
                let canUseAVPlayer = (codecId == AV_CODEC_ID_EAC3)

                if canUseAVPlayer {
                    // EAC3 → AVPlayer audio engine for potential Dolby Atmos passthrough
                    let codecpar = audioStream.pointee.codecpar!
                    avPlayerCodecType = .eac3
                    avPlayerSampleRate = UInt32(codecpar.pointee.sample_rate)
                    avPlayerChannelCount = UInt32(codecpar.pointee.ch_layout.nb_channels)
                    avPlayerBitRate = UInt32(codecpar.pointee.bit_rate)
                    if avPlayerSampleRate == 0 { avPlayerSampleRate = 48000 }
                    if avPlayerChannelCount == 0 { avPlayerChannelCount = 6 }

                    // Also open AudioDecoder as PCM fallback — if AVPlayer fails,
                    // we switch to PCM seamlessly.
                    do {
                        try audioDecoder.open(stream: audioStream)
                    } catch {
                        #if DEBUG
                        print("[SteelPlayer] PCM fallback decoder failed: \(error)")
                        #endif
                    }

                    let engine = AVPlayerAudioEngine()
                    engine.onPlaybackFailed = { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.fallbackToPCMAudio()
                        }
                    }
                    avPlayerAudioEngine = engine
                    usingAVPlayerAudio = true
                    avPlayerAwaitingFirstPacket = true
                    audioAvailable = true

                    // Video timing driven by AVPlayer's timebase
                    videoRenderer.displayLayer.controlTimebase = engine.videoTimebase

                    #if DEBUG
                    print("[SteelPlayer] Audio: EAC3 → AVPlayer engine (Atmos passthrough)")
                    #endif

                    // Match output channels to content (e.g. stereo→2, 5.1→6)
                    #if os(iOS) || os(tvOS)
                    let contentCh = Int(avPlayerChannelCount)
                    let maxCh = AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
                    let preferred = max(2, min(contentCh, maxCh))
                    try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(preferred)
                    #endif
                } else {
                    // AC3, AAC, and all other codecs → FFmpeg PCM pipeline
                    do {
                        try audioDecoder.open(stream: audioStream)
                        audioAvailable = true

                        // Video timing driven by synchronizer
                        audioOutput.attachVideoLayer(videoRenderer.displayLayer)

                        // Match output channels to content (e.g. stereo→2, 5.1→6)
                        #if os(iOS) || os(tvOS)
                        let contentCh = Int(audioDecoder.channels)
                        let maxCh = AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
                        let preferred = max(2, min(contentCh, maxCh))
                        try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(preferred)
                        #endif
                    } catch {
                        print("[SteelPlayer] Audio decoder failed: \(error) — playback will be silent")
                    }
                }
            }

            // For video-only files (or failed audio), use the synchronizer
            // as a free-running clock so video frame sync still works.
            if !audioAvailable {
                audioOutput.attachVideoLayer(videoRenderer.displayLayer)
                audioOutput.start()
            }

            // 4. Seek to start position if requested.
            // Pre-start the audio clock at the seek time so the synchronizer
            // doesn't reject video frames whose PTS is far ahead of time 0.
            // The demux loop's audioOutput.start() becomes a no-op since
            // _isStarted is already true.
            var initialAudioTime: CMTime = .zero
            if let start = startPosition, start > 0 {
                demuxer.seek(to: start)
                currentTime = start
                let seekTime = CMTimeMakeWithSeconds(start, preferredTimescale: 90000)
                videoRenderer.setSkipThreshold(seekTime)
                if usingSoftwareDecode {
                    softwareDecoder.skipUntilPTS = seekTime
                }
                initialAudioTime = seekTime
                // DON'T start audioOutput here — the clock would advance
                // while the demux loop hasn't produced any frames yet.
                // Instead, pass the time to the demux loop.
            }

            // 5. Start the demux→decode loop and time updates
            isPlaying = true
            state = .playing
            startTimeUpdates()
            startDemuxLoop(videoStreamIndex: videoIdx, audioStreamIndex: audioIdx, initialAudioTime: initialAudioTime)

            #if DEBUG
            print("[SteelPlayer] Playback started (duration=\(String(format: "%.1f", duration))s)")
            #endif
        } catch {
            state = .error("Failed to load: \(error.localizedDescription)")
            throw error
        }
    }

    public func play() {
        guard state == .paused else { return }
        isPlaying = true
        if usingAVPlayerAudio {
            avPlayerAudioEngine?.resume()
        } else {
            audioOutput.resume()
        }
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        isPlaying = false
        if usingAVPlayerAudio {
            avPlayerAudioEngine?.pause()
        } else {
            audioOutput.pause()
        }
        state = .paused
    }

    public func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused: play()
        default: break
        }
    }

    public func seek(to seconds: Double) async {
        let target = max(0, min(seconds, duration))
        state = .seeking

        // Pause the demux loop so it stops calling readPacket().
        isPlaying = false

        // Flush decoders FIRST — VTDecompressionSession's flush waits for
        // async frames which get delivered to the renderer. Then flush the
        // renderer to clear those stale frames.
        if usingSoftwareDecode {
            softwareDecoder.flush()
        } else {
            videoDecoder.flush()
        }
        videoRenderer.flush()

        if usingAVPlayerAudio {
            // Prepare AVPlayer engine for seek — stops current playback,
            // cancels pending resource loader requests.
            avPlayerAudioEngine?.prepareForSeek()
            avPlayerAwaitingFirstPacket = true
            avPlayerNeedsSeekRestart = true
            avPlayerSeekTarget = target
        } else {
            audioDecoder.flush()
            audioOutput.flush()
        }

        // Seek the demuxer
        demuxer.seek(to: target)
        currentTime = target

        // Drop decoded frames between the keyframe and the seek target
        let seekTime = CMTimeMakeWithSeconds(target, preferredTimescale: 90000)
        videoRenderer.setSkipThreshold(seekTime)
        if usingSoftwareDecode {
            softwareDecoder.skipUntilPTS = seekTime
        }

        if !usingAVPlayerAudio {
            // PCM mode: restart the audio clock at the seek position
            audioOutput.start(at: seekTime)
        }
        // AVPlayer mode: engine restarts when first post-seek packet arrives

        // Resume playing from new position
        isPlaying = true
        state = .playing
    }

    public func stop() {
        stopInternal()
        state = .idle
        currentTime = 0
        progress = 0
    }

    /// The currently active audio stream index.
    /// Accessed from demux queue — protected by single-writer (main actor).
    nonisolated(unsafe) private var activeAudioStreamIndex: Int32 = -1

    public func selectAudioTrack(index: Int) {
        let streamIndex = Int32(index)
        guard streamIndex != activeAudioStreamIndex,
              let stream = demuxer.stream(at: streamIndex) else { return }

        let codecId = stream.pointee.codecpar?.pointee.codec_id
        let newIsAtmos = (codecId == AV_CODEC_ID_EAC3)

        // Tear down current audio engine
        if usingAVPlayerAudio {
            avPlayerAudioEngine?.stop()
            avPlayerAudioEngine = nil
            videoRenderer.displayLayer.controlTimebase = nil
        } else {
            audioDecoder.flush()
            audioDecoder.close()
            audioOutput.flush()
            audioOutput.detachVideoLayer(videoRenderer.displayLayer)
        }

        activeAudioStreamIndex = streamIndex

        if newIsAtmos {
            // Switch to AVPlayer audio engine
            let codecpar = stream.pointee.codecpar!
            avPlayerCodecType = (codecId == AV_CODEC_ID_EAC3) ? .eac3 : .ac3
            avPlayerSampleRate = UInt32(codecpar.pointee.sample_rate)
            avPlayerChannelCount = UInt32(codecpar.pointee.ch_layout.nb_channels)
            avPlayerBitRate = UInt32(codecpar.pointee.bit_rate)
            if avPlayerSampleRate == 0 { avPlayerSampleRate = 48000 }
            if avPlayerChannelCount == 0 { avPlayerChannelCount = 6 }

            let engine = AVPlayerAudioEngine()
            avPlayerAudioEngine = engine
            usingAVPlayerAudio = true
            avPlayerAwaitingFirstPacket = true

            videoRenderer.displayLayer.controlTimebase = engine.videoTimebase

            #if DEBUG
            print("[SteelPlayer] Switched to AVPlayer audio (\(codecId == AV_CODEC_ID_EAC3 ? "EAC3" : "AC3"))")
            #endif
        } else {
            // Switch to FFmpeg PCM pipeline
            usingAVPlayerAudio = false
            avPlayerAwaitingFirstPacket = false
            audioOutput.attachVideoLayer(videoRenderer.displayLayer)

            do {
                try audioDecoder.open(stream: stream)
                let seekTime = CMTimeMakeWithSeconds(currentTime, preferredTimescale: 90000)
                audioOutput.start(at: seekTime)
            } catch {
                #if DEBUG
                print("[SteelPlayer] Audio track switch failed: \(error)")
                #endif
            }
        }

        // Update preferred output channels
        #if os(iOS) || os(tvOS)
        let contentCh = newIsAtmos ? Int(avPlayerChannelCount) : Int(audioDecoder.channels)
        let maxCh = AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
        let preferred = max(2, min(contentCh, maxCh))
        try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(preferred)
        #endif
    }

    public func selectSubtitleTrack(index: Int) {
        // TODO: Phase 6 — subtitle support
    }

    /// Set playback volume (0.0 = mute, 1.0 = full).
    public var volume: Float {
        get {
            if usingAVPlayerAudio {
                return avPlayerAudioEngine?.volume ?? 1.0
            }
            return audioOutput.volume
        }
        set {
            if usingAVPlayerAudio {
                avPlayerAudioEngine?.volume = newValue
            }
            audioOutput.volume = newValue
        }
    }

    /// Set playback speed (0.5–2.0). Audio pitch adjusts automatically.
    public func setRate(_ rate: Float) {
        if usingAVPlayerAudio {
            avPlayerAudioEngine?.setRate(rate)
        } else {
            audioOutput.setRate(rate)
        }
    }

    // MARK: - AVPlayer Fallback

    /// Fall back from AVPlayer audio to FFmpeg PCM pipeline.
    /// Called when AVPlayer fails to open the fMP4 audio stream.
    private func fallbackToPCMAudio() {
        guard usingAVPlayerAudio else { return }

        #if DEBUG
        print("[SteelPlayer] AVPlayer audio failed — falling back to PCM")
        #endif

        // Stop AVPlayer engine
        avPlayerAudioEngine?.stop()
        avPlayerAudioEngine = nil
        videoRenderer.displayLayer.controlTimebase = nil

        // Switch to synchronizer-driven video timing
        usingAVPlayerAudio = false
        avPlayerAwaitingFirstPacket = false
        audioOutput.attachVideoLayer(videoRenderer.displayLayer)

        // AudioDecoder was already opened as fallback in load().
        // Restart synchronizer at current position.
        let seekTime = CMTimeMakeWithSeconds(currentTime, preferredTimescale: 90000)
        audioOutput.start(at: seekTime)
    }

    // MARK: - Internal

    private func stopInternal() {
        stopRequested = true
        isPlaying = false
        stopTimeUpdates()

        // Stop audio engines
        if usingAVPlayerAudio {
            avPlayerAudioEngine?.stop()
            avPlayerAudioEngine = nil
            videoRenderer.displayLayer.controlTimebase = nil
        } else {
            audioOutput.detachVideoLayer(videoRenderer.displayLayer)
        }
        audioOutput.stop()
        usingAVPlayerAudio = false
        avPlayerAwaitingFirstPacket = false

        // Flush decoders before renderer — decoder flush waits for async
        // VT frames which would otherwise land on the already-flushed renderer.
        if usingSoftwareDecode {
            softwareDecoder.flush()
            softwareDecoder.close()
        } else {
            videoDecoder.flush()
            videoDecoder.close()
        }
        videoRenderer.flush()
        audioDecoder.close()
        demuxer.close()
        audioAvailable = false

        // Remove lifecycle observers
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    // MARK: - Demux Loop

    /// Runs on `demuxQueue`. Reads packets from the demuxer and feeds
    /// them to the appropriate decoders. Uses semaphore-based back-pressure
    /// instead of busy-waiting.
    private func startDemuxLoop(videoStreamIndex: Int32, audioStreamIndex: Int32, initialAudioTime: CMTime = .zero) {
        let audioOutput = self.audioOutput
        let audioDecoder = self.audioDecoder
        let audioAvailable = self.audioAvailable
        nonisolated(unsafe) var audioStarted = false

        demuxQueue.async { [weak self] in
            guard let self = self else { return }

            while !self.stopRequested {
                // Wait if paused
                if !self.isPlaying {
                    self.demuxCondition.lock()
                    while !self.isPlaying && !self.stopRequested {
                        self.demuxCondition.wait(until: Date(timeIntervalSinceNow: 0.5))
                    }
                    self.demuxCondition.unlock()
                    continue
                }

                // Read the next packet from the container.
                // Retry transient errors (network hiccups) up to 3 times
                // with exponential backoff before giving up.
                let packet: UnsafeMutablePointer<AVPacket>?
                var readError: Error?
                var retries = 0
                let maxRetries = 3
                while true {
                    do {
                        packet = try self.demuxer.readPacket()
                        readError = nil
                        break
                    } catch {
                        retries += 1
                        if retries >= maxRetries || self.stopRequested {
                            readError = error
                            packet = nil
                            break
                        }
                        #if DEBUG
                        print("[SteelPlayer] Read error (retry \(retries)/\(maxRetries)): \(error)")
                        #endif
                        Thread.sleep(forTimeInterval: Double(1 << retries) * 0.2)
                    }
                }
                if let readError {
                    print("[SteelPlayer] Demuxer read failed after \(retries) retries: \(readError)")
                    Task { @MainActor [weak self] in
                        self?.state = .error("Playback error: \(readError)")
                    }
                    break
                }

                guard let packet = packet else {
                    // EOF — flush decoder and drain reorder buffer
                    if self.usingSoftwareDecode {
                        self.softwareDecoder.flush()
                    } else {
                        self.videoDecoder.flush()
                    }
                    self.videoRenderer.drainReorderBuffer()
                    if !self.usingAVPlayerAudio {
                        self.audioDecoder.flush()
                    }
                    Task { @MainActor [weak self] in
                        self?.state = .idle
                    }
                    break
                }

                let streamIdx = packet.pointee.stream_index

                if streamIdx == videoStreamIndex {
                    // Back-pressure: wait if display layer isn't ready
                    while !self.videoRenderer.displayLayer.isReadyForMoreMediaData && !self.stopRequested {
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    if self.stopRequested { av_packet_free_safe(packet); break }

                    if self.usingSoftwareDecode {
                        self.softwareDecoder.decode(packet: packet)
                    } else {
                        self.videoDecoder.decode(packet: packet)
                    }
                } else if streamIdx == self.activeAudioStreamIndex && audioAvailable {
                    if self.usingAVPlayerAudio {
                        // AVPlayer audio engine — feed raw packets (no decode)
                        let packetData = Data(
                            bytes: packet.pointee.data,
                            count: Int(packet.pointee.size)
                        )

                        if self.avPlayerAwaitingFirstPacket {
                            // First packet after load or seek — initialize/restart engine
                            self.avPlayerAwaitingFirstPacket = false
                            let engine = self.avPlayerAudioEngine

                            if self.avPlayerNeedsSeekRestart {
                                // Restart after seek
                                self.avPlayerNeedsSeekRestart = false
                                let seekTime = CMTimeMakeWithSeconds(
                                    self.avPlayerSeekTarget,
                                    preferredTimescale: 90000
                                )
                                engine?.restartAfterSeek(
                                    firstPacketData: packetData,
                                    atTime: seekTime
                                )
                            } else {
                                // Initial start
                                engine?.start(
                                    firstPacketData: packetData,
                                    codecType: self.avPlayerCodecType,
                                    sampleRate: self.avPlayerSampleRate,
                                    channelCount: self.avPlayerChannelCount,
                                    bitRate: self.avPlayerBitRate,
                                    startTime: initialAudioTime
                                )
                            }
                        } else {
                            self.avPlayerAudioEngine?.feedPacket(packetData)
                        }
                    } else {
                        // FFmpeg PCM pipeline
                        let sampleBuffers = audioDecoder.decode(packet: packet)
                        for sb in sampleBuffers {
                            audioOutput.enqueue(sampleBuffer: sb)
                        }
                        // Start the synchronizer when first audio data arrives.
                        if !audioStarted && !sampleBuffers.isEmpty {
                            audioOutput.start(at: initialAudioTime)
                            audioStarted = true
                        }
                    }
                }
                // TODO: Phase 6 — route subtitle packets

                av_packet_free_safe(packet)
            }
        }
    }

    // MARK: - Playback Time Updates

    /// Periodically update currentTime/progress from the audio clock.
    private var timeUpdateTimer: Task<Void, Never>?

    private func startTimeUpdates() {
        timeUpdateTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self = self, !Task.isCancelled else { return }
                let t: Double
                if self.usingAVPlayerAudio {
                    t = self.avPlayerAudioEngine?.currentTimeSeconds ?? 0
                } else {
                    t = self.audioOutput.currentTimeSeconds
                }
                if t > 0 {
                    self.currentTime = t
                    if self.duration > 0 {
                        self.progress = Float(t / self.duration)
                    }
                }
            }
        }
    }

    private func stopTimeUpdates() {
        timeUpdateTimer?.cancel()
        timeUpdateTimer = nil
    }

    // MARK: - Video Format Detection

    /// Detect HDR format from stream metadata.
    private func detectVideoFormat(stream: UnsafeMutablePointer<AVStream>) -> VideoFormat {
        guard let codecpar = stream.pointee.codecpar else { return .sdr }

        let codecId = codecpar.pointee.codec_id
        let colorTRC = codecpar.pointee.color_trc
        let colorPrimaries = codecpar.pointee.color_primaries

        // Check for Dolby Vision via codec parameters side data.
        // Only report .dolbyVision if the display actually supports it —
        // otherwise report .hdr10 (DV Profile 8 is HDR10-compatible).
        if codecId == AV_CODEC_ID_HEVC {
            let nbSideData = Int(codecpar.pointee.nb_coded_side_data)
            if let sideData = codecpar.pointee.coded_side_data {
                for i in 0..<nbSideData {
                    if sideData[i].type == AV_PKT_DATA_DOVI_CONF {
                        #if os(tvOS) || os(iOS)
                        if AVPlayer.availableHDRModes.contains(.dolbyVision) {
                            #if DEBUG
                            print("[SteelPlayer] DV stream → Dolby Vision (display supports DV)")
                            #endif
                            return .dolbyVision
                        }
                        #endif
                        #if DEBUG
                        print("[SteelPlayer] DV stream → HDR10 fallback")
                        #endif
                        return .hdr10
                    }
                }
            }
        }

        // HDR10: BT.2020 primaries + PQ transfer function
        if colorTRC == AVCOL_TRC_SMPTE2084 && colorPrimaries == AVCOL_PRI_BT2020 {
            return .hdr10
        }

        // HLG: BT.2020 primaries + HLG transfer function
        if colorTRC == AVCOL_TRC_ARIB_STD_B67 && colorPrimaries == AVCOL_PRI_BT2020 {
            return .hlg
        }

        return .sdr
    }

    // MARK: - App Lifecycle

    private func setupLifecycleObservers() {
        #if os(iOS) || os(tvOS)
        let nc = NotificationCenter.default

        // Pause when entering background — Metal rendering is not allowed,
        // and VTDecompressionSession becomes invalid in background.
        let bgObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.state == .playing else { return }
            self.pause()
        }
        lifecycleObservers.append(bgObserver)

        // Handle memory pressure — flush texture cache and drop queued frames
        let memObserver = nc.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.videoRenderer.flush()
            #if DEBUG
            print("[SteelPlayer] Memory warning — flushed texture cache")
            #endif
        }
        lifecycleObservers.append(memObserver)
        #endif
    }

}

// MARK: - Helpers

/// Safe wrapper around av_packet_free that handles the double-pointer.
private func av_packet_free_safe(_ packet: UnsafeMutablePointer<AVPacket>) {
    var p: UnsafeMutablePointer<AVPacket>? = packet
    av_packet_free(&p)
}

// MARK: - Errors

public enum SteelPlayerError: Error {
    case noVideoStream
    case noAudioStream
}
