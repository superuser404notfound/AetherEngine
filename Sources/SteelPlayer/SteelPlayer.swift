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

    /// Compressed audio feeder for AC3 — feeds raw compressed frames
    /// directly to AVSampleBufferAudioRenderer (no FFmpeg decode).
    private let compressedAudioFeeder = CompressedAudioFeeder()

    /// Audio routing: which engine handles the current audio track.
    enum AudioMode { case pcm, compressed, externalAVPlayer }
    nonisolated(unsafe) private var audioMode: AudioMode = .pcm

    /// External audio URL for AVPlayer-based playback (Dolby Atmos passthrough).
    /// Set by the host app BEFORE calling load(). When set and the default audio
    /// track is EAC3, SteelPlayer creates an AVPlayer for audio while handling
    /// video through its own pipeline. AVPlayer wraps EAC3+JOC as Dolby MAT 2.0.
    public var externalAudioURL: URL?

    /// AVPlayer instance for external audio playback.
    private var externalAudioPlayer: AVPlayer?
    private var externalAudioItem: AVPlayerItem?
    private var externalAudioObservation: NSKeyValueObservation?

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
            //
            // EAC3 + externalAudioURL → AVPlayer (Dolby Atmos via MAT 2.0)
            // AC3/EAC3 (no external URL) → CompressedAudioFeeder (no Atmos, saves CPU)
            // Other → FFmpeg PCM decode (AudioDecoder)
            let audioIdx = demuxer.audioStreamIndex
            activeAudioStreamIndex = audioIdx
            audioMode = .pcm

            if audioIdx >= 0, let audioStream = demuxer.stream(at: audioIdx) {
                let codecId = audioStream.pointee.codecpar?.pointee.codec_id
                let channelCount = Int(audioStream.pointee.codecpar?.pointee.ch_layout.nb_channels ?? 2)
                let isEAC3 = (codecId == AV_CODEC_ID_EAC3)
                let isAC3 = (codecId == AV_CODEC_ID_AC3)

                if isEAC3, let audioURL = externalAudioURL {
                    // EAC3 + external URL → AVPlayer for Dolby Atmos passthrough.
                    // AVPlayer is created now, but we wait for readyToPlay
                    // before starting the demux loop (ensures A/V sync).
                    let item = AVPlayerItem(url: audioURL)
                    item.preferredForwardBufferDuration = 4.0
                    let avPlayer = AVPlayer(playerItem: item)
                    avPlayer.automaticallyWaitsToMinimizeStalling = false
                    externalAudioPlayer = avPlayer
                    externalAudioItem = item
                    audioMode = .externalAVPlayer
                    audioAvailable = true

                    // Video uses synchronizer (started when AVPlayer is ready)
                    audioOutput.attachVideoLayer(videoRenderer.displayLayer)

                    #if DEBUG
                    print("[SteelPlayer] Audio: EAC3 → external AVPlayer")
                    print("[SteelPlayer] Audio URL: \(audioURL.absoluteString.prefix(200))")
                    #endif

                    // Wait for AVPlayer to buffer enough data before proceeding.
                    // This ensures video and audio start at the same moment.
                    // If AVPlayer fails, fall back to compressed passthrough.
                    do {
                        try await waitForExternalAudioReady()
                    } catch {
                        #if DEBUG
                        print("[SteelPlayer] AVPlayer failed — falling back to compressed passthrough")
                        #endif
                        stopExternalAudioPlayer()
                        audioMode = .pcm
                        // Try compressed feeder as fallback
                        if let stream = audioStream.pointee.codecpar {
                            try? compressedAudioFeeder.open(stream: audioStream)
                            audioMode = .compressed
                        }
                    }

                } else if isEAC3 || isAC3 {
                    // AC3/EAC3 without external URL → compressed passthrough
                    do {
                        try compressedAudioFeeder.open(stream: audioStream)
                        audioMode = .compressed
                        audioAvailable = true
                        audioOutput.attachVideoLayer(videoRenderer.displayLayer)
                        #if DEBUG
                        print("[SteelPlayer] Audio: \(isEAC3 ? "EAC3" : "AC3") → compressed passthrough")
                        #endif
                    } catch {
                        try? audioDecoder.open(stream: audioStream)
                        audioAvailable = true
                        audioOutput.attachVideoLayer(videoRenderer.displayLayer)
                    }
                } else {
                    // AAC, FLAC, Opus, etc. → FFmpeg PCM decode
                    do {
                        try audioDecoder.open(stream: audioStream)
                        audioAvailable = true
                        audioOutput.attachVideoLayer(videoRenderer.displayLayer)
                    } catch {
                        print("[SteelPlayer] Audio decoder failed: \(error) — playback will be silent")
                    }
                }

                // Match output channels to content
                #if os(iOS) || os(tvOS)
                let maxCh = AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
                let preferred = max(2, min(channelCount, maxCh))
                try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(preferred)
                #endif
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

            // 5. Start external AVPlayer (if active) at the correct position
            if audioMode == .externalAVPlayer, let avPlayer = externalAudioPlayer {
                if CMTimeGetSeconds(initialAudioTime) > 0 {
                    await avPlayer.seek(to: initialAudioTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                avPlayer.play()
                // Start the synchronizer so video frames are presented
                // in sync with AVPlayer (both start from the same time).
                audioOutput.start(at: initialAudioTime)
            }

            // 6. Start the demux→decode loop and time updates
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
        audioOutput.resume()
        externalAudioPlayer?.play()
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        isPlaying = false
        audioOutput.pause()
        externalAudioPlayer?.pause()
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

        switch audioMode {
        case .externalAVPlayer:
            externalAudioPlayer?.pause()
        case .compressed:
            compressedAudioFeeder.flush()
            audioOutput.flush()
        case .pcm:
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

        // Restart audio at the seek position
        if audioMode == .externalAVPlayer, let avPlayer = externalAudioPlayer {
            // Seek AVPlayer, wait for completion, then start both
            await avPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            audioOutput.start(at: seekTime)
            avPlayer.play()
        } else {
            audioOutput.start(at: seekTime)
        }

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

        // Tear down current audio engine
        switch audioMode {
        case .externalAVPlayer:
            stopExternalAudioPlayer()
        case .compressed:
            compressedAudioFeeder.flush()
            compressedAudioFeeder.close()
        case .pcm:
            audioDecoder.flush()
            audioDecoder.close()
        }
        audioOutput.flush()
        activeAudioStreamIndex = streamIndex

        // Open new audio engine for the selected track
        let isEAC3 = (codecId == AV_CODEC_ID_EAC3)
        let isAC3 = (codecId == AV_CODEC_ID_AC3)

        if isEAC3, let audioURL = externalAudioURL {
            // Switch to AVPlayer for Atmos
            let seekTime = CMTimeMakeWithSeconds(currentTime, preferredTimescale: 90000)
            let item = AVPlayerItem(url: audioURL)
            let avPlayer = AVPlayer(playerItem: item)
            avPlayer.automaticallyWaitsToMinimizeStalling = false
            externalAudioPlayer = avPlayer
            externalAudioItem = item
            audioMode = .externalAVPlayer

            // Seek AVPlayer to current position and start
            avPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            avPlayer.play()
            audioOutput.start(at: seekTime)
        } else if isEAC3 || isAC3 {
            do {
                try compressedAudioFeeder.open(stream: stream)
                audioMode = .compressed
            } catch {
                try? audioDecoder.open(stream: stream)
                audioMode = .pcm
            }
            let seekTime = CMTimeMakeWithSeconds(currentTime, preferredTimescale: 90000)
            audioOutput.start(at: seekTime)
        } else {
            try? audioDecoder.open(stream: stream)
            audioMode = .pcm
            let seekTime = CMTimeMakeWithSeconds(currentTime, preferredTimescale: 90000)
            audioOutput.start(at: seekTime)
        }

        #if os(iOS) || os(tvOS)
        let contentCh = Int(stream.pointee.codecpar?.pointee.ch_layout.nb_channels ?? 2)
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
        get { audioOutput.volume }
        set { audioOutput.volume = newValue }  // AVPlayer volume controlled separately if needed
    }

    /// Set playback speed (0.5–2.0). Audio pitch adjusts automatically.
    public func setRate(_ rate: Float) {
        audioOutput.setRate(rate)
        externalAudioPlayer?.rate = rate
    }

    // MARK: - External Audio Player Helpers

    /// Wait for the external AVPlayer to become readyToPlay.
    /// Called during load() to ensure A/V sync — demux loop starts only after audio is ready.
    private func waitForExternalAudioReady() async throws {
        guard let item = externalAudioItem else { return }
        if item.status == .readyToPlay { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            externalAudioObservation = item.observe(\.status) { [weak self] item, _ in
                self?.externalAudioObservation?.invalidate()
                self?.externalAudioObservation = nil
                if item.status == .readyToPlay {
                    #if DEBUG
                    print("[SteelPlayer] External AVPlayer ready to play")
                    #endif
                    continuation.resume()
                } else if item.status == .failed {
                    #if DEBUG
                    print("[SteelPlayer] External AVPlayer failed: \(item.error?.localizedDescription ?? "?")")
                    if let e = item.error as NSError? {
                        print("[SteelPlayer]   domain=\(e.domain) code=\(e.code)")
                        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError {
                            print("[SteelPlayer]   underlying: \(u.domain) code=\(u.code)")
                        }
                    }
                    #endif
                    continuation.resume(throwing: item.error ?? SteelPlayerError.noAudioStream)
                }
            }
        }
    }

    /// Stop and clean up the external AVPlayer.
    private func stopExternalAudioPlayer() {
        externalAudioObservation?.invalidate()
        externalAudioObservation = nil
        externalAudioPlayer?.pause()
        externalAudioPlayer?.replaceCurrentItem(with: nil)
        externalAudioPlayer = nil
        externalAudioItem = nil
    }

    // MARK: - Internal

    private func stopInternal() {
        stopRequested = true
        isPlaying = false
        stopTimeUpdates()

        // Stop audio
        stopExternalAudioPlayer()
        audioOutput.detachVideoLayer(videoRenderer.displayLayer)
        audioOutput.stop()
        compressedAudioFeeder.close()
        audioMode = .pcm

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
                    switch self.audioMode {
                    case .externalAVPlayer: break
                    case .compressed: self.compressedAudioFeeder.flush()
                    case .pcm: self.audioDecoder.flush()
                    }
                    Task { @MainActor [weak self] in
                        self?.state = .idle
                    }
                    break
                }

                let streamIdx = packet.pointee.stream_index

                if streamIdx == videoStreamIndex {
                    // Back-pressure: wait if display layer isn't ready.
                    // During HLS buffering: use a short timeout (50ms) so the
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
                    switch self.audioMode {
                    case .externalAVPlayer:
                        break  // Audio comes from AVPlayer, not from demux loop

                    case .compressed:
                        if let sampleBuffer = self.compressedAudioFeeder.wrapPacket(packet) {
                            audioOutput.enqueue(sampleBuffer: sampleBuffer)
                            if !audioStarted {
                                audioOutput.start(at: initialAudioTime)
                                audioStarted = true
                            }
                        }

                    case .pcm:
                        let sampleBuffers = audioDecoder.decode(packet: packet)
                        for sb in sampleBuffers {
                            audioOutput.enqueue(sampleBuffer: sb)
                        }
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
                if self.audioMode == .externalAVPlayer, let avPlayer = self.externalAudioPlayer {
                    let s = CMTimeGetSeconds(avPlayer.currentTime())
                    t = s.isFinite ? s : 0
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
