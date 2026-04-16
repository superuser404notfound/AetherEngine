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

/// AetherEngine — Open-source FFmpeg + VideoToolbox video player engine.
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
/// let player = try AetherEngine()
/// myView.layer.addSublayer(player.videoLayer)
/// try await player.load(url: myVideoURL)
/// player.play()
/// ```
///
/// ## License
///
/// LGPL 3.0 — App Store compatible when dynamically linked.
@MainActor
public final class AetherEngine: ObservableObject {

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

    /// Compressed audio feeder for AC3/EAC3 — feeds raw compressed frames
    /// directly to AVSampleBufferAudioRenderer (no FFmpeg decode, saves CPU).
    /// Note: Atmos (JOC) metadata is NOT preserved — renderer outputs PCM 5.1/7.1.
    private let compressedAudioFeeder = CompressedAudioFeeder()

    /// HLS audio engine for Dolby Atmos — uses AVPlayer + local HLS server
    /// to trigger Dolby MAT 2.0 wrapping for EAC3+JOC passthrough.
    /// Accessed from demux queue — effectively immutable during playback.
    nonisolated(unsafe) private var hlsAudioEngine: HLSAudioEngine?

    /// Separate queue for feeding audio to the HLS engine in Atmos mode.
    private let atmosAudioQueue = DispatchQueue(label: "com.aetherengine.atmos-audio", qos: .userInitiated)
    private let atmosAudioLock = NSLock()
    nonisolated(unsafe) private var atmosAudioBuffer: [Data] = []
    nonisolated(unsafe) private var atmosAudioDrainActive = false
    /// PTS threshold (seconds) for skipping audio packets before seek target.
    /// After seek, demuxer starts at the keyframe BEFORE the target. Video uses
    /// skipThreshold to drop pre-target frames; this does the same for audio.
    nonisolated(unsafe) private var atmosAudioSkipPTS: Double = -1

    /// Separate queue for video decoding in Atmos mode.
    /// Decouples video back-pressure from the demux thread so audio
    /// packets keep flowing even when the display layer is blocked.
    private let atmosVideoQueue = DispatchQueue(label: "com.aetherengine.atmos-video", qos: .userInitiated)
    private let atmosVideoLock = NSLock()
    nonisolated(unsafe) private var atmosVideoBuffer: [UnsafeMutablePointer<AVPacket>] = []
    nonisolated(unsafe) private var atmosVideoDrainActive = false
    /// Cap video buffer at ~50MB to prevent OOM (4K packets ~130KB each)
    private let atmosVideoBufferMax = 384

    /// Audio routing: which engine handles the current audio track.
    enum AudioMode { case pcm, compressed, atmos }
    nonisolated(unsafe) private var audioMode: AudioMode = .pcm

    /// Serial queue for the demux→decode loop (runs off main thread).
    private let demuxQueue = DispatchQueue(label: "com.aetherengine.demux", qos: .userInitiated)

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
            print("[AetherEngine] AVAudioSession setup error: \(error)")
        }
        // Request multichannel output — separate try so a failure here
        // doesn't prevent the basic audio session from working.
        let maxCh = session.maximumOutputNumberOfChannels
        if maxCh > 2 {
            try? session.setPreferredOutputNumberOfChannels(maxCh)
        }
        #if DEBUG
        print("[AetherEngine] Audio session: maxChannels=\(maxCh), preferred=\(session.preferredOutputNumberOfChannels), output=\(session.outputNumberOfChannels)")
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
        print("[AetherEngine] Loading: \(url.absoluteString)")
        #endif

        do {
            // 1. Open the container with FFmpeg
            try demuxer.open(url: url)
            duration = demuxer.duration

            // 2. Find the video stream and open the hardware decoder
            let videoIdx = demuxer.videoStreamIndex
            guard videoIdx >= 0, let videoStream = demuxer.stream(at: videoIdx) else {
                throw AetherEngineError.noVideoStream
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
                print("[AetherEngine] Using VideoToolbox hardware decode")
                #endif
            } catch {
                #if DEBUG
                print("[AetherEngine] VT failed: \(error) — trying software decode")
                #endif
                do {
                    try softwareDecoder.open(stream: videoStream, onFrame: frameCallback)
                    usingSoftwareDecode = true
                    #if DEBUG
                    print("[AetherEngine] Using FFmpeg software decode")
                    #endif
                } catch {
                    #if DEBUG
                    print("[AetherEngine] Software decode also failed: \(error)")
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
            print("[AetherEngine] Video frame rate: \(String(format: "%.3f", videoFrameRate)) fps")
            #endif

            // Populate track metadata from the demuxer
            audioTracks = demuxer.audioTrackInfos()
            subtitleTracks = demuxer.subtitleTrackInfos()

            // 2b. Compute initial audio time from start position (needed before audio engine setup)
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
                atmosAudioSkipPTS = start
            }

            // 2c. Find the audio stream and configure the appropriate audio engine
            //
            // EAC3 → HLSAudioEngine (AVPlayer + local HLS for Dolby Atmos passthrough)
            //   EAC3+JOC (Atmos) embeds object metadata as extension elements within
            //   the independent substream — identical framing and channel count as
            //   regular EAC3 5.1. Cannot be distinguished at the packet level, so all
            //   EAC3 goes through AVPlayer which handles both Atmos and non-Atmos.
            // AC3 → CompressedAudioFeeder (no Atmos possible, simpler passthrough)
            // Other → FFmpeg PCM decode (AudioDecoder)
            let audioIdx = demuxer.audioStreamIndex
            activeAudioStreamIndex = audioIdx
            audioMode = .pcm

            if audioIdx >= 0, let audioStream = demuxer.stream(at: audioIdx) {
                let codecId = audioStream.pointee.codecpar?.pointee.codec_id
                let channelCount = Int(audioStream.pointee.codecpar?.pointee.ch_layout.nb_channels ?? 2)
                let isEAC3 = (codecId == AV_CODEC_ID_EAC3)
                let isAC3 = (codecId == AV_CODEC_ID_AC3)

                if isEAC3 {
                    // EAC3 → HLS engine for Dolby Atmos (MAT 2.0 passthrough)
                    // Falls back to CompressedAudioFeeder if AVPlayer fails.
                    let streamIdx = audioIdx
                    do {
                        let engine = HLSAudioEngine()
                        engine.onPlaybackFailed = { [weak self] in
                            Task { @MainActor in
                                guard let self,
                                      let s = self.demuxer.stream(at: streamIdx) else { return }
                                self.fallbackToCompressedAudio(stream: s)
                            }
                        }
                        engine.onWillStartTimebase = { [weak self] skipPTS in
                            guard let self else { return }
                            if self.usingSoftwareDecode {
                                self.softwareDecoder.flush()
                                self.softwareDecoder.skipUntilPTS = skipPTS
                            } else {
                                self.videoDecoder.flush()
                            }
                            self.videoRenderer.flush()
                            self.videoRenderer.setSkipThreshold(skipPTS)
                        }
                        try engine.prepare(stream: audioStream, startTime: initialAudioTime)
                        hlsAudioEngine = engine
                        audioMode = .atmos
                        audioAvailable = true
                        // Display layer uses controlTimebase from HLS engine
                        // instead of the synchronizer — AVPlayer is the master clock.
                        videoRenderer.displayLayer.controlTimebase = engine.videoTimebase
                        #if DEBUG
                        print("[AetherEngine] Audio: EAC3 → HLS AVPlayer (Dolby Atmos) (\(channelCount)ch)")
                        #endif
                    } catch {
                        #if DEBUG
                        print("[AetherEngine] HLS engine failed: \(error) — falling back to compressed passthrough")
                        #endif
                        fallbackToCompressedAudio(stream: audioStream)
                    }
                } else if isAC3 {
                    // AC3 → compressed passthrough (no Atmos possible)
                    do {
                        try compressedAudioFeeder.open(stream: audioStream)
                        audioMode = .compressed
                        audioAvailable = true
                        audioOutput.attachVideoLayer(videoRenderer.displayLayer)
                        #if DEBUG
                        print("[AetherEngine] Audio: AC3 → compressed passthrough (\(channelCount)ch)")
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
                        print("[AetherEngine] Audio decoder failed: \(error) — playback will be silent")
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
            // Skip this for Atmos mode — display layer uses its own timebase.
            if !audioAvailable {
                audioOutput.attachVideoLayer(videoRenderer.displayLayer)
                audioOutput.start()
            } else if audioMode == .atmos {
                // Atmos: display layer is NOT on the synchronizer.
                // The HLS engine's controlTimebase drives video timing.
                // We still need the synchronizer for currentTime fallback,
                // but the display layer is detached from it.
            }

            // 4. Start the demux→decode loop and time updates
            isPlaying = true
            state = .playing
            startTimeUpdates()
            startDemuxLoop(videoStreamIndex: videoIdx, audioStreamIndex: audioIdx, initialAudioTime: initialAudioTime)

            #if DEBUG
            print("[AetherEngine] Playback started (duration=\(String(format: "%.1f", duration))s)")
            #endif
        } catch {
            state = .error("Failed to load: \(error.localizedDescription)")
            throw error
        }
    }

    public func play() {
        guard state == .paused else { return }
        isPlaying = true
        if audioMode == .atmos {
            hlsAudioEngine?.resume()
        } else {
            audioOutput.resume()
        }
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        isPlaying = false
        if audioMode == .atmos {
            hlsAudioEngine?.pause()
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

        switch audioMode {
        case .atmos:
            // Clear atmos buffers — drain threads will see empty buffers and stop
            clearAtmosBuffers()
            // Tear down HLS pipeline — must rebuild from new position
            hlsAudioEngine?.prepareForSeek()
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
        if audioMode == .atmos {
            atmosAudioSkipPTS = target
            // Restart HLS engine with new timestamps — feedPacket() will
            // buffer new segments and recreate AVPlayer automatically.
            if let audioStream = demuxer.stream(at: activeAudioStreamIndex) {
                try? hlsAudioEngine?.restartAfterSeek(stream: audioStream, seekTime: seekTime)
            }
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

        // Capture current time BEFORE tearing down the engine
        let seekSeconds = currentTime
        let seekTime = CMTimeMakeWithSeconds(seekSeconds, preferredTimescale: 90000)

        // Tear down current audio engine
        tearDownCurrentAudioEngine()
        activeAudioStreamIndex = streamIndex

        // Flush video pipeline (like a seek) — the demux seek below
        // resets both video and audio position
        if usingSoftwareDecode {
            softwareDecoder.flush()
        } else {
            videoDecoder.flush()
        }
        videoRenderer.flush()

        // Seek the demuxer to the current position so the new track
        // starts from the right place in the stream
        demuxer.seek(to: seekSeconds)
        videoRenderer.setSkipThreshold(seekTime)
        if usingSoftwareDecode {
            softwareDecoder.skipUntilPTS = seekTime
        }
        atmosAudioSkipPTS = seekSeconds

        // Open new audio engine for the selected track
        let isEAC3 = (codecId == AV_CODEC_ID_EAC3)
        let isAC3 = (codecId == AV_CODEC_ID_AC3)

        if isEAC3 {
            do {
                let engine = HLSAudioEngine()
                engine.onPlaybackFailed = { [weak self] in
                    Task { @MainActor in
                        guard let self,
                              let s = self.demuxer.stream(at: streamIndex) else { return }
                        self.fallbackToCompressedAudio(stream: s)
                    }
                }
                engine.onWillStartTimebase = { [weak self] skipPTS in
                    guard let self else { return }
                    if self.usingSoftwareDecode {
                        self.softwareDecoder.flush()
                        self.softwareDecoder.skipUntilPTS = skipPTS
                    } else {
                        self.videoDecoder.flush()
                    }
                    self.videoRenderer.flush()
                    self.videoRenderer.setSkipThreshold(skipPTS)
                }
                try engine.prepare(stream: stream, startTime: seekTime)
                hlsAudioEngine = engine
                audioMode = .atmos
                videoRenderer.displayLayer.controlTimebase = engine.videoTimebase
            } catch {
                fallbackToCompressedAudio(stream: stream)
                audioOutput.start(at: seekTime)
            }
        } else if isAC3 {
            do {
                try compressedAudioFeeder.open(stream: stream)
                audioMode = .compressed
            } catch {
                try? audioDecoder.open(stream: stream)
                audioMode = .pcm
            }
            audioOutput.attachVideoLayer(videoRenderer.displayLayer)
            audioOutput.start(at: seekTime)
        } else {
            try? audioDecoder.open(stream: stream)
            audioMode = .pcm
            audioOutput.attachVideoLayer(videoRenderer.displayLayer)
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

    // MARK: - Audio Engine Helpers

    /// Tear down whichever audio engine is currently active.
    private func tearDownCurrentAudioEngine() {
        switch audioMode {
        case .atmos:
            clearAtmosBuffers()
            hlsAudioEngine?.stop()
            hlsAudioEngine = nil
            videoRenderer.displayLayer.controlTimebase = nil
        case .compressed:
            compressedAudioFeeder.flush()
            compressedAudioFeeder.close()
            audioOutput.flush()
        case .pcm:
            audioDecoder.flush()
            audioDecoder.close()
            audioOutput.flush()
        }
        audioOutput.detachVideoLayer(videoRenderer.displayLayer)
    }

    /// Fall back from HLS Atmos engine to CompressedAudioFeeder.
    /// Called when AVPlayer fails to play the HLS stream.
    private func fallbackToCompressedAudio(stream: UnsafeMutablePointer<AVStream>) {
        #if DEBUG
        print("[AetherEngine] Falling back from Atmos to compressed passthrough")
        #endif

        // Tear down HLS engine
        hlsAudioEngine?.stop()
        hlsAudioEngine = nil
        videoRenderer.displayLayer.controlTimebase = nil

        // Switch to compressed passthrough
        do {
            try compressedAudioFeeder.open(stream: stream)
            audioMode = .compressed
        } catch {
            try? audioDecoder.open(stream: stream)
            audioMode = .pcm
        }

        // Re-attach display layer to synchronizer
        audioOutput.attachVideoLayer(videoRenderer.displayLayer)
        let seekTime = CMTimeMakeWithSeconds(currentTime, preferredTimescale: 90000)
        audioOutput.start(at: seekTime)
    }

    /// Clear all buffered atmos packets. Called from seek (non-async safe).
    nonisolated private func clearAtmosBuffers() {
        atmosAudioLock.lock()
        atmosAudioBuffer.removeAll()
        atmosAudioLock.unlock()
        atmosVideoLock.lock()
        for pkt in atmosVideoBuffer { av_packet_free_safe(pkt) }
        atmosVideoBuffer.removeAll()
        atmosVideoLock.unlock()
    }

    // MARK: - Atmos Audio Drain

    /// Starts the background drain loop if not already running.
    /// Drains buffered audio packets to the HLS engine on a separate queue,
    /// completely independent of video back-pressure.
    private func startAtmosAudioDrain() {
        atmosAudioLock.lock()
        guard !atmosAudioDrainActive else { atmosAudioLock.unlock(); return }
        atmosAudioDrainActive = true
        atmosAudioLock.unlock()

        atmosAudioQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.atmosAudioLock.lock()
                guard !self.atmosAudioBuffer.isEmpty else {
                    self.atmosAudioDrainActive = false
                    self.atmosAudioLock.unlock()
                    return
                }
                let packetData = self.atmosAudioBuffer.removeFirst()
                self.atmosAudioLock.unlock()

                self.hlsAudioEngine?.feedAudioData(packetData)
            }
        }
    }

    // MARK: - Atmos Video Drain

    /// Decodes video packets from the buffer with normal back-pressure.
    /// Runs on its own queue so it doesn't block the demux thread.
    private func startAtmosVideoDrain() {
        atmosVideoLock.lock()
        guard !atmosVideoDrainActive else { atmosVideoLock.unlock(); return }
        atmosVideoDrainActive = true
        atmosVideoLock.unlock()

        atmosVideoQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.atmosVideoLock.lock()
                guard !self.atmosVideoBuffer.isEmpty else {
                    self.atmosVideoDrainActive = false
                    self.atmosVideoLock.unlock()
                    return
                }
                let packet = self.atmosVideoBuffer.removeFirst()
                self.atmosVideoLock.unlock()

                // Back-pressure on THIS thread (doesn't affect demux or audio)
                while !self.videoRenderer.displayLayer.isReadyForMoreMediaData && !self.stopRequested {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                guard !self.stopRequested else {
                    av_packet_free_safe(packet)
                    return
                }

                if self.usingSoftwareDecode {
                    self.softwareDecoder.decode(packet: packet)
                } else {
                    self.videoDecoder.decode(packet: packet)
                }
                av_packet_free_safe(packet)
            }
        }
    }

    /// Set playback volume (0.0 = mute, 1.0 = full).
    public var volume: Float {
        get { audioOutput.volume }
        set { audioOutput.volume = newValue }
    }

    /// Set playback speed (0.5–2.0). Audio pitch adjusts automatically.
    public func setRate(_ rate: Float) {
        if audioMode == .atmos {
            hlsAudioEngine?.setRate(rate)
        } else {
            audioOutput.setRate(rate)
        }
    }

    // MARK: - Internal

    private func stopInternal() {
        stopRequested = true
        isPlaying = false
        stopTimeUpdates()

        // Stop audio — tear down whichever engine is active
        if audioMode == .atmos {
            clearAtmosBuffers()
            hlsAudioEngine?.stop()
            hlsAudioEngine = nil
            videoRenderer.displayLayer.controlTimebase = nil
        } else {
            audioOutput.detachVideoLayer(videoRenderer.displayLayer)
        }
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

        // Cache audio stream time_base to avoid per-packet lookup in the hot path.
        let audioTimeBase: AVRational = {
            if let stream = self.demuxer.stream(at: audioStreamIndex) {
                return stream.pointee.time_base
            }
            return AVRational(num: 1, den: 90000)
        }()

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
                        print("[AetherEngine] Read error (retry \(retries)/\(maxRetries)): \(error)")
                        #endif
                        Thread.sleep(forTimeInterval: Double(1 << retries) * 0.2)
                    }
                }
                if let readError {
                    print("[AetherEngine] Demuxer read failed after \(retries) retries: \(readError)")
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
                    case .atmos:
                        break // HLS engine manages its own lifecycle
                    case .compressed:
                        self.compressedAudioFeeder.flush()
                    case .pcm:
                        self.audioDecoder.flush()
                    }
                    Task { @MainActor [weak self] in
                        self?.state = .idle
                    }
                    break
                }

                let streamIdx = packet.pointee.stream_index

                if streamIdx == videoStreamIndex {
                    if self.audioMode == .atmos {
                        // Atmos mode: push video to separate decode queue.
                        // The demux thread NEVER blocks on video back-pressure,
                        // so audio packets keep flowing to the HLS engine.
                        if let copy = av_packet_clone(packet) {
                            self.atmosVideoLock.lock()
                            // Throttle if buffer is full (prevent OOM)
                            while self.atmosVideoBuffer.count >= self.atmosVideoBufferMax && !self.stopRequested {
                                self.atmosVideoLock.unlock()
                                Thread.sleep(forTimeInterval: 0.01)
                                self.atmosVideoLock.lock()
                            }
                            self.atmosVideoBuffer.append(copy)
                            self.atmosVideoLock.unlock()
                            self.startAtmosVideoDrain()
                        }
                    } else {
                        // Normal mode: inline decode with back-pressure
                        while !self.videoRenderer.displayLayer.isReadyForMoreMediaData && !self.stopRequested {
                            Thread.sleep(forTimeInterval: 0.005)
                        }
                        if self.stopRequested { av_packet_free_safe(packet); break }

                        if self.usingSoftwareDecode {
                            self.softwareDecoder.decode(packet: packet)
                        } else {
                            self.videoDecoder.decode(packet: packet)
                        }
                    }
                } else if streamIdx == self.activeAudioStreamIndex && audioAvailable {
                    switch self.audioMode {
                    case .atmos:
                        // Copy audio data to a separate buffer. A background
                        // queue drains the buffer and feeds the HLS engine.
                        // This decouples audio from video back-pressure so
                        // segments are created even when video decode blocks.
                        if packet.pointee.size > 0, let data = packet.pointee.data {
                            // Skip audio packets before seek target (same as
                            // video skipThreshold). After seek, the demuxer
                            // starts at the keyframe BEFORE the target. Without
                            // this filter, streamOffset overestimates the audio
                            // position → video appears ahead of audio.
                            let skipPTS = self.atmosAudioSkipPTS
                            if skipPTS > 0 {
                                let ptsSeconds = Double(packet.pointee.pts) * Double(audioTimeBase.num) / Double(audioTimeBase.den)
                                if ptsSeconds < skipPTS - 0.01 {
                                    // Drop pre-seek audio packet
                                    break
                                }
                                // First packet at/after target — update streamOffset
                                // to the actual audio PTS for precise sync
                                self.atmosAudioSkipPTS = -1
                                self.hlsAudioEngine?.updateStreamOffset(ptsSeconds)
                            }

                            let packetData = Data(bytes: data, count: Int(packet.pointee.size))
                            self.atmosAudioLock.lock()
                            self.atmosAudioBuffer.append(packetData)
                            self.atmosAudioLock.unlock()
                            self.startAtmosAudioDrain()
                        }

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
                if self.audioMode == .atmos {
                    t = self.hlsAudioEngine?.currentTimeSeconds ?? 0
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
                            print("[AetherEngine] DV stream → Dolby Vision (display supports DV)")
                            #endif
                            return .dolbyVision
                        }
                        #endif
                        #if DEBUG
                        print("[AetherEngine] DV stream → HDR10 fallback")
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
            print("[AetherEngine] Memory warning — flushed texture cache")
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

public enum AetherEngineError: Error {
    case noVideoStream
    case noAudioStream
}
