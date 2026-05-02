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

    /// Decoded subtitle cues for the active subtitle source — either
    /// an embedded stream (text codec) routed through the main demux
    /// loop, or a sidecar file URL fully decoded up-front. Empty when
    /// no subtitle is active or the source is a graphic format the
    /// engine doesn't render yet.
    @Published public private(set) var subtitleCues: [SubtitleCue] = []
    /// True while a sidecar file is being downloaded + decoded.
    /// Embedded tracks populate cues lazily as the demuxer reads
    /// packets, so this stays false for those.
    @Published public private(set) var isLoadingSubtitles: Bool = false
    /// True when the engine is the active subtitle source — a
    /// `selectSubtitleTrack` or `selectSidecarSubtitle` call is in
    /// effect. Goes false on `clearSubtitle`. The host should mirror
    /// `subtitleCues` only while this is true so a parallel HTTP
    /// fallback path doesn't get clobbered.
    @Published public private(set) var isSubtitleActive: Bool = false

    // MARK: - Output

    /// The video layer to embed in the host view hierarchy.
    /// Uses AVSampleBufferDisplayLayer for optimal frame pacing.
    public var videoLayer: CALayer { videoRenderer.displayLayer }

    /// Fires when the video layer is replaced with a fresh instance —
    /// which happens on every `load()` call to avoid stale
    /// Synchronizer/controlTimebase state from a previous playback.
    /// The host view must remove the old sublayer and add the new one.
    /// See `SampleBufferRenderer.onLayerReplaced` for the why.
    public var onVideoLayerReplaced: ((CALayer) -> Void)? {
        didSet {
            videoRenderer.onLayerReplaced = { [weak self] newLayer in
                self?.onVideoLayerReplaced?(newLayer)
            }
        }
    }

    /// The URL and position of the current playback session.
    /// Used by `reloadAtCurrentPosition()` to rebuild the pipeline
    /// after background suspension invalidates VT sessions and AVIO.
    var loadedURL: URL?

    /// In-flight sidecar subtitle decode (separate AVFormatContext
    /// on a small text file). Cancelled on subtitle clear / track
    /// switch so a stale decode can't overwrite fresh cues.
    private var sidecarTask: Task<Void, Never>?

    // MARK: - Internal Pipeline

    /// Pipeline components — accessed from both main actor and demux queue.
    /// Each has internal locking for thread safety.
    /// `internal` (no modifier) so the Audio + AtmosDrains extensions
    /// in their own files can reach them; the AetherEngine module is
    /// the only consumer either way.
    nonisolated(unsafe) let demuxer = Demuxer()
    let videoDecoder = VideoDecoder()
    nonisolated(unsafe) let softwareDecoder = SoftwareVideoDecoder()
    let audioDecoder = AudioDecoder()

    /// True if the current stream uses software decoding (FFmpeg) instead of VT.
    /// Set during load(), read during demux loop — effectively immutable during playback.
    nonisolated(unsafe) var usingSoftwareDecode = false
    let audioOutput = AudioOutput()
    nonisolated(unsafe) let videoRenderer = SampleBufferRenderer()

    /// HLS audio engine for Dolby Atmos — uses AVPlayer + local HLS server
    /// to trigger Dolby MAT 2.0 wrapping for EAC3+JOC passthrough.
    /// Accessed from demux queue — effectively immutable during playback.
    nonisolated(unsafe) var hlsAudioEngine: HLSAudioEngine?

    /// Separate queue for feeding audio to the HLS engine in Atmos mode.
    let atmosAudioQueue = DispatchQueue(label: "com.aetherengine.atmos-audio", qos: .userInitiated)
    let atmosAudioLock = NSLock()
    nonisolated(unsafe) var atmosAudioBuffer: PacketDeque<Data> = PacketDeque()
    nonisolated(unsafe) var atmosAudioDrainActive = false
    /// PTS threshold (seconds) for skipping audio packets before seek target.
    /// After seek, demuxer starts at the keyframe BEFORE the target. Video uses
    /// skipThreshold to drop pre-target frames; this does the same for audio.
    nonisolated(unsafe) var atmosAudioSkipPTS: Double = -1

    /// Separate queue for video decoding in Atmos mode.
    /// Decouples video back-pressure from the demux thread so audio
    /// packets keep flowing even when the display layer is blocked.
    let atmosVideoQueue = DispatchQueue(label: "com.aetherengine.atmos-video", qos: .userInitiated)
    let atmosVideoLock = NSLock()
    nonisolated(unsafe) var atmosVideoBuffer: PacketDeque<UnsafeMutablePointer<AVPacket>> = PacketDeque()
    nonisolated(unsafe) var atmosVideoDrainActive = false
    /// Cap video buffer at ~50MB to prevent OOM (4K packets ~130KB each)
    let atmosVideoBufferMax = 384
    /// Cap audio buffer to bound memory if AVPlayer stalls. EAC3 packets
    /// run ~32 KB each at typical Atmos bitrates, so 1024 ≈ 32 MB
    /// worth of headroom — large enough that a 30s network blip doesn't
    /// throttle real playback, small enough that a stuck AVPlayer can't
    /// quietly grow the heap into hundreds of MB.
    let atmosAudioBufferMax = 1024

    /// Audio routing: which engine handles the current audio track.
    enum AudioMode { case pcm, atmos }
    nonisolated(unsafe) var audioMode: AudioMode = .pcm

    /// Serial queue for the demux→decode loop (runs off main thread).
    private let demuxQueue = DispatchQueue(label: "com.aetherengine.demux", qos: .userInitiated)

    /// Thread-safe playback control flags.
    /// Accessed from both main actor and demux queue — protected by flagsLock.
    private let flagsLock = NSLock()
    nonisolated(unsafe) private var _isPlaying = false
    nonisolated(unsafe) private var _stopRequested = false

    /// Whether the audio stream was successfully opened.
    var audioAvailable = false

    /// Detected video frame rate.
    private var videoFrameRate: Double = 0

    /// The currently active audio stream index — accessed from the
    /// demux queue (single-writer from the main actor) and from the
    /// Audio extension when switching tracks.
    nonisolated(unsafe) var activeAudioStreamIndex: Int32 = -1

    /// Stream index of the subtitle stream currently being routed
    /// through the demux loop, or -1 when subtitles are off.
    /// Read by the demux thread to decide whether to decode each
    /// packet; written from the main actor in `selectSubtitleTrack`/
    /// `clearSubtitle` under `subtitleLock`.
    nonisolated(unsafe) var activeSubtitleStreamIndex: Int32 = -1
    /// Codec context for the active subtitle stream. Allocated on
    /// track select, freed on clear / track switch / stop.
    nonisolated(unsafe) var subtitleCodecContext: UnsafeMutablePointer<AVCodecContext>?
    /// Serializes codec context lifecycle (alloc / free) against the
    /// demux thread's decode call.
    let subtitleLock = NSLock()
    /// Monotonic ID source for cues so SwiftUI animations stay stable
    /// across appends. Reset on every track switch.
    nonisolated(unsafe) var subtitleCueIDCounter: Int = 0
    /// Dedupe set keyed by `"start|end"` so packets re-read after
    /// a seek don't produce duplicate cues.
    nonisolated(unsafe) var seenSubtitleKeys: Set<String> = []
    /// Source video frame width / height in pixels — captured at
    /// load() so the demux thread can normalise bitmap-subtitle rect
    /// coordinates without re-touching the AVStream.
    nonisolated(unsafe) var videoFrameWidth: Int32 = 0
    nonisolated(unsafe) var videoFrameHeight: Int32 = 0

    /// Diagnostic counters for the subtitle pipeline. Reset on every
    /// track switch; printed periodically from the decode hot path so
    /// silent failures (codec produced no cues, demuxer never feeds
    /// the chosen stream, etc.) leave a trail in `log stream`.
    nonisolated(unsafe) var subtitlePacketsSeen: Int = 0
    nonisolated(unsafe) var subtitleDecodeAttempts: Int = 0
    nonisolated(unsafe) var subtitleDecodeSuccess: Int = 0
    /// One-shot latch so the "PGS packets carry PES header" notice
    /// only logs once per session.
    nonisolated(unsafe) var pgsHeaderStripLogged: Bool = false

    /// Condition for waking the demux loop from pause.
    private let demuxCondition = NSCondition()

    /// Set to true by the demux loop the first time an audio packet
    /// flows through to the renderer (audioOutput.start fires for
    /// PCM, first segment fed to AVPlayer for Atmos). `load()` polls
    /// this before returning so the engine guarantees that, by the
    /// time `await load(...)` resumes the caller, the synchronizer
    /// is fully wired up — without it, an immediate `pause()` from
    /// the caller races the demux loop's `audioOutput.start(at:)`
    /// call and leaves the synchronizer's clock running at rate 1
    /// while the engine state is `.paused`. Resume after that race
    /// would render one stale frame and stall.
    private let audioFlowLock = NSLock()
    nonisolated(unsafe) private var _isAudioFlowing: Bool = false
    nonisolated var isAudioFlowing: Bool {
        get { audioFlowLock.lock(); defer { audioFlowLock.unlock() }; return _isAudioFlowing }
        set {
            audioFlowLock.lock()
            _isAudioFlowing = newValue
            audioFlowLock.unlock()
        }
    }

    nonisolated var isPlaying: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _isPlaying }
        set {
            flagsLock.lock()
            _isPlaying = newValue
            flagsLock.unlock()
            if newValue { demuxCondition.broadcast() }
        }
    }
    nonisolated var stopRequested: Bool {
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
            #if DEBUG
            print("[AetherEngine] AVAudioSession setup error: \(error)")
            #endif
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
    ///
    /// - Parameters:
    ///   - url: Media source (http/https/file).
    ///   - startPosition: Seconds into the stream to start at (resume).
    ///   - tonemapHDRToSDR: Force HDR10/DV content to be tone-mapped down
    ///     to BT.709 SDR inside VideoToolbox. Use this when the display
    ///     cannot switch to HDR mode (e.g. user disabled Match Content
    ///     on tvOS, or panel is SDR-only) — otherwise HDR content appears
    ///     black because AVSampleBufferDisplayLayer does not tone-map.
    public func load(
        url: URL,
        startPosition: Double? = nil,
        tonemapHDRToSDR: Bool = false
    ) async throws {
        // Tear down any previous playback
        stopInternal()
        loadedURL = url
        // Replace the display layer with a clean instance. Reusing
        // the old one after a Synchronizer↔controlTimebase history
        // leaves it in a rendering-but-frozen state on some videos
        // (no recovery via flush). The fresh layer starts without
        // that history and renders cleanly.
        videoRenderer.recreateDisplayLayer()

        state = .loading
        currentTime = 0
        duration = 0
        progress = 0
        audioTracks = []
        subtitleTracks = []
        videoFormat = .sdr
        audioAvailable = false
        stopRequested = false
        isAudioFlowing = false

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

            // Capture source video dimensions — used to normalise
            // bitmap-subtitle rect coordinates so the host can scale
            // to any on-screen video rect.
            videoFrameWidth = videoStream.pointee.codecpar.pointee.width
            videoFrameHeight = videoStream.pointee.codecpar.pointee.height

            let videoRenderer = self.videoRenderer
            let frameCallback: DecodedFrameHandler = { pixelBuffer, pts in
                videoRenderer.enqueue(pixelBuffer: pixelBuffer, pts: pts)
            }

            // Try VideoToolbox hardware decode first, fall back to FFmpeg
            // software decode for codecs without HW support (AV1 on A15, etc.)
            do {
                try videoDecoder.open(
                    stream: videoStream,
                    tonemapToSDR: tonemapHDRToSDR,
                    onFrame: frameCallback
                )
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

            // Opt the display layer into HDR output only when the pipeline
            // actually delivers HDR pixel buffers. When tonemapHDRToSDR is
            // on (or the content is SDR to begin with), the decoder emits
            // BT.709 SDR — declaring the layer as HDR then breaks the
            // Atmos controlTimebase path (compositor refuses the frames,
            // picture stays black / frozen on frame 1).
            let pipelineIsHDR: Bool = {
                guard !tonemapHDRToSDR else { return false }
                switch videoFormat {
                case .hdr10, .dolbyVision, .hlg: return true
                case .sdr: return false
                }
            }()
            videoRenderer.setHDROutput(pipelineIsHDR)

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
            // AC3/EAC3/AAC/etc. → FFmpeg PCM decode (full dynamics, no dialnorm)
            // Other → FFmpeg PCM decode (AudioDecoder)
            let audioIdx = demuxer.audioStreamIndex
            activeAudioStreamIndex = audioIdx
            audioMode = .pcm

            if audioIdx >= 0, let audioStream = demuxer.stream(at: audioIdx) {
                let codecpar = audioStream.pointee.codecpar!
                let codecId = codecpar.pointee.codec_id
                let channelCount = Int(codecpar.pointee.ch_layout.nb_channels)
                let profile = codecpar.pointee.profile
                let isEAC3 = (codecId == AV_CODEC_ID_EAC3)
                let isAC3 = (codecId == AV_CODEC_ID_AC3)
                // FF_PROFILE_EAC3_DDP_ATMOS = 30 — set by FFmpeg's EAC3 parser
                // when JOC (Joint Object Coding) is detected in the bitstream.
                // This is the only reliable way to distinguish Atmos from regular
                // EAC3 5.1 without depending on server metadata.
                // The capability check keeps us off the HLS/AVPlayer path on
                // outputs that can't accept multichannel passthrough (e.g.
                // Bluetooth speakers) — there we just decode to PCM and let
                // the system mix to whatever the route supports.
                let streamIsAtmos = isEAC3 && profile == 30
                let canPassthrough = canPassthroughAtmos()
                let isAtmos = streamIsAtmos && canPassthrough

                #if DEBUG
                if isEAC3 {
                    let atmosState: String
                    if streamIsAtmos && !canPassthrough {
                        atmosState = "Atmos (JOC) — route can't passthrough, using PCM"
                    } else if streamIsAtmos {
                        atmosState = "Atmos (JOC)"
                    } else {
                        atmosState = "standard 5.1"
                    }
                    print("[AetherEngine] EAC3 profile=\(profile) → \(atmosState)")
                }
                #endif

                if isAtmos {
                    // EAC3+JOC → HLS engine for Dolby Atmos (MAT 2.0 passthrough)
                    // Falls back to FFmpeg PCM decode if AVPlayer fails.
                    let streamIdx = audioIdx
                    do {
                        let engine = HLSAudioEngine()
                        engine.onPlaybackFailed = { [weak self] in
                            Task { @MainActor in
                                guard let self,
                                      let s = self.demuxer.stream(at: streamIdx) else { return }
                                self.fallbackToPCMAudio(stream: s)
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
                        // Full handoff sequence before giving the layer
                        // the Atmos timebase:
                        //   1. detach from any synchronizer (sync wait)
                        //   2. drop old controlTimebase
                        //   3. flush the layer — clears internal
                        //      pipeline state and resets .failed status
                        //      back to .unknown if a previous handoff
                        //      corrupted it
                        //   4. assign the new timebase
                        audioOutput.detachVideoLayer(videoRenderer.displayLayer)
                        videoRenderer.displayLayer.controlTimebase = nil
                        videoRenderer.flushDisplayLayer()
                        videoRenderer.displayLayer.controlTimebase = engine.videoTimebase
                        #if DEBUG
                        let status: String
                        switch videoRenderer.displayLayer.status {
                        case .unknown: status = "unknown"
                        case .rendering: status = "rendering"
                        case .failed: status = "failed"
                        @unknown default: status = "?"
                        }
                        print("[AetherEngine] Atmos handoff: layer status=\(status) error=\(videoRenderer.displayLayer.error?.localizedDescription ?? "nil")")
                        #endif
                        #if DEBUG
                        print("[AetherEngine] Audio: EAC3 → HLS AVPlayer (Dolby Atmos) (\(channelCount)ch)")
                        #endif
                    } catch {
                        #if DEBUG
                        print("[AetherEngine] HLS engine failed: \(error) — falling back to FFmpeg PCM")
                        #endif
                        fallbackToPCMAudio(stream: audioStream)
                    }
                } else {
                    // All other codecs (AC3, EAC3 non-Atmos, AAC, FLAC, etc.)
                    // → FFmpeg PCM decode. Consistent output across all codecs,
                    // no dialnorm/DRC attenuation from Apple's decoder.
                    do {
                        try audioDecoder.open(stream: audioStream)
                        audioAvailable = true
                        audioOutput.attachVideoLayer(videoRenderer.displayLayer)
                        #if DEBUG
                        let codecName = isEAC3 ? "EAC3" : isAC3 ? "AC3" : "PCM"
                        print("[AetherEngine] Audio: \(codecName) → FFmpeg PCM decode (\(channelCount)ch)")
                        #endif
                    } catch {
                        #if DEBUG
                        print("[AetherEngine] Audio decoder failed: \(error)")
                        #endif
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

            // Wait for the demux loop to confirm audio is actually
            // flowing through before returning. Without this, a
            // caller that awaits `load(...)` and immediately calls
            // `pause()` races the demux loop's first audioOutput.
            // start() / HLS feed — the synchronizer's clock then
            // advances past the renderer queue and resume after
            // pause renders one stale frame and stalls. Capped at
            // 2s so audio-less files (or unusual containers without
            // an audio stream) still let load() return.
            if audioAvailable {
                let deadline = Date().addingTimeInterval(2.0)
                while !isAudioFlowing && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms poll
                }
                #if DEBUG
                if !isAudioFlowing {
                    print("[AetherEngine] Audio flow timeout — load() returning anyway")
                }
                #endif
            }
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

    /// Tear down and reload from the current position.
    /// Call after returning from background — VTDecompressionSession and
    /// AVIO connections are invalidated by tvOS when the app is suspended.
    /// A fresh load() rebuilds everything safely.
    public func reloadAtCurrentPosition() async throws {
        guard let url = loadedURL else { return }
        let pos = currentTime
        try await load(url: url, startPosition: pos > 1 ? pos : nil)
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

    // selectAudioTrack, selectSubtitleTrack, audio engine helpers and
    // Atmos drain logic live in AetherEngine+Audio.swift and
    // AetherEngine+AtmosDrains.swift respectively.

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

    // MARK: - Subtitles

    /// Switch the active embedded subtitle stream and decode it
    /// Switch the active subtitle stream. Subtitle packets read by
    /// the main demux loop get routed through a per-track decoder,
    /// converted to `SubtitleCue`s, and appended to `subtitleCues`
    /// in playback order. Auto-resolved tracks selected before
    /// playback starts capture cues from the very first packet —
    /// mid-playback enables only see cues from the demuxer cursor
    /// onwards, since prior packets are already past.
    ///
    /// Text codecs (SubRip / ASS / SSA / WebVTT / mov_text) decode
    /// directly. Bitmap codecs (PGS / DVB) decode but produce no
    /// text — `subtitleCues` stays empty and the host should fall
    /// back to its server-extraction path for those.
    public func selectSubtitleTrack(index: Int) {
        print("[Engine.subs] selectSubtitleTrack index=\(index)")
        closeSubtitleDecoder()
        cancelSidecarTask()

        guard let stream = demuxer.stream(at: Int32(index)),
              let codecpar = stream.pointee.codecpar,
              codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
        else {
            print("[Engine.subs] ✗ stream \(index) is not a subtitle stream (or out of range)")
            isSubtitleActive = false
            subtitleCues = []
            isLoadingSubtitles = false
            return
        }

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id),
              let ctx = avcodec_alloc_context3(codec)
        else {
            print("[Engine.subs] ✗ no decoder for codec_id=\(codecpar.pointee.codec_id.rawValue) on stream \(index)")
            isSubtitleActive = false
            subtitleCues = []
            isLoadingSubtitles = false
            return
        }

        if avcodec_parameters_to_context(ctx, codecpar) < 0 {
            var local: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&local)
            print("[Engine.subs] ✗ avcodec_parameters_to_context failed for stream \(index)")
            isSubtitleActive = false
            subtitleCues = []
            isLoadingSubtitles = false
            return
        }

        // Bitmap subtitle codecs author their bitmaps against a known
        // canvas (the source video frame). The probe step often can't
        // determine those dimensions when the file is big and the
        // sub stream sparse — codec context comes back with width=0
        // and the decoder rejects later segments. Seed from the
        // captured video frame size as a fallback; the PCS will
        // overwrite once it arrives.
        if isBitmapSubtitleCodec(codecpar.pointee.codec_id) {
            if ctx.pointee.width == 0 { ctx.pointee.width = videoFrameWidth }
            if ctx.pointee.height == 0 { ctx.pointee.height = videoFrameHeight }
        }

        if avcodec_open2(ctx, codec, nil) < 0 {
            var local: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&local)
            print("[Engine.subs] ✗ avcodec_open2 failed for stream \(index)")
            isSubtitleActive = false
            subtitleCues = []
            isLoadingSubtitles = false
            return
        }

        subtitleLock.lock()
        subtitleCodecContext = ctx
        activeSubtitleStreamIndex = Int32(index)
        subtitleCueIDCounter = 0
        seenSubtitleKeys = []
        subtitlePacketsSeen = 0
        subtitleDecodeAttempts = 0
        subtitleDecodeSuccess = 0
        pgsHeaderStripLogged = false
        subtitleLock.unlock()

        // Some demuxers default subtitle streams to AVDISCARD_DEFAULT
        // which can swallow packets that the parser thinks are
        // useless. Force NONE on the active stream so every byte
        // makes it to av_read_frame.
        stream.pointee.discard = AVDISCARD_NONE

        let codecName = String(cString: codec.pointee.name)
        let videoW = videoFrameWidth, videoH = videoFrameHeight
        print("[Engine.subs] ✓ codec=\(codecName) stream=\(index) videoFrame=\(videoW)x\(videoH)")

        isSubtitleActive = true
        subtitleCues = []
        isLoadingSubtitles = false
    }

    /// Decode a sidecar subtitle file (`.srt` / `.ass` / `.vtt` / `.ssa`
    /// served alongside the media). The whole file is fetched and
    /// decoded up-front via `SubtitleDecoder.decodeFile`, then the
    /// resulting cues replace `subtitleCues` atomically. `isLoadingSubtitles`
    /// flips on for the duration so the host can show a spinner.
    /// Subsequent calls cancel any in-flight sidecar decode.
    public func selectSidecarSubtitle(url: URL) {
        closeSubtitleDecoder()
        cancelSidecarTask()

        isSubtitleActive = true
        subtitleCues = []
        isLoadingSubtitles = true

        sidecarTask = Task { [weak self] in
            let cues: [SubtitleCue]
            do {
                cues = try await SubtitleDecoder.decodeFile(url: url)
            } catch {
                #if DEBUG
                print("[AetherEngine] sidecar decode failed: \(error)")
                #endif
                await MainActor.run {
                    guard let self = self else { return }
                    if self.isSubtitleActive {
                        self.isLoadingSubtitles = false
                    }
                }
                return
            }

            await MainActor.run {
                guard let self = self else { return }
                // Drop late results if the host switched away.
                guard self.isSubtitleActive else { return }
                self.subtitleCues = cues
                self.isLoadingSubtitles = false
            }
        }
    }

    /// Turn subtitles off and clear cached cues. Closes the active
    /// embedded subtitle codec context and cancels any sidecar task.
    public func clearSubtitle() {
        closeSubtitleDecoder()
        cancelSidecarTask()
        isSubtitleActive = false
        subtitleCues = []
        isLoadingSubtitles = false
    }

    private func cancelSidecarTask() {
        sidecarTask?.cancel()
        sidecarTask = nil
    }

    nonisolated private func closeSubtitleDecoder() {
        subtitleLock.lock()
        if subtitleCodecContext != nil {
            avcodec_free_context(&subtitleCodecContext)
        }
        activeSubtitleStreamIndex = -1
        seenSubtitleKeys = []
        subtitleLock.unlock()
    }

    /// Decode a subtitle packet pulled by the main demux loop and
    /// publish the resulting cue to `subtitleCues` on the main actor.
    /// Runs on the demux queue; codec-context access serialised by
    /// `subtitleLock` so a track switch on the main actor can't free
    /// the context mid-decode.
    nonisolated func decodeSubtitlePacket(_ pkt: UnsafeMutablePointer<AVPacket>, stream: UnsafeMutablePointer<AVStream>) {
        subtitleLock.lock()
        guard let ctx = subtitleCodecContext else {
            subtitleLock.unlock()
            return
        }

        var sub = AVSubtitle()
        var gotSub: Int32 = 0
        let ret = decodeSubtitleWithFixups(ctx: ctx, pkt: pkt, sub: &sub, gotSub: &gotSub)
        subtitleDecodeAttempts += 1
        if subtitleDecodeAttempts <= 3 {
            print("[Engine.subs] decode attempt#\(subtitleDecodeAttempts) ret=\(ret) gotSub=\(gotSub) pktSize=\(pkt.pointee.size) pts=\(pkt.pointee.pts) duration=\(pkt.pointee.duration)")
            dumpSubtitlePacket(pkt, attempt: subtitleDecodeAttempts)
        }

        // Some MKV converters drop the trailing END segment (0x80) on
        // PGS, so the decoder accumulates state but never gets the
        // signal to emit. If gotSub is still 0 after the real packet
        // and the codec is PGS, feed a synthetic END to flush —
        // duplicate END would give AVERROR_INVALIDDATA which we just
        // ignore, but for the missing-END case it produces the cue.
        if gotSub == 0,
           ctx.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE,
           pkt.pointee.size > 30 {
            var endBytes: [UInt8] = [0x80, 0x00, 0x00,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 0, 0]
            endBytes.withUnsafeMutableBufferPointer { buf in
                var endPkt = AVPacket()
                endPkt.data = buf.baseAddress
                endPkt.size = 3
                endPkt.pts = pkt.pointee.pts
                endPkt.dts = pkt.pointee.dts
                endPkt.duration = pkt.pointee.duration
                endPkt.stream_index = pkt.pointee.stream_index
                _ = avcodec_decode_subtitle2(ctx, &sub, &gotSub, &endPkt)
            }
            if subtitleDecodeAttempts <= 5 {
                print("[Engine.subs] synthetic-END flush: gotSub=\(gotSub) (codec needed an END segment that wasn't in the packet)")
            }
        }

        guard ret >= 0, gotSub != 0 else {
            subtitleLock.unlock()
            return
        }
        subtitleDecodeSuccess += 1

        let timeBase = stream.pointee.time_base
        let tbSec = Double(timeBase.num) / Double(timeBase.den)
        let pktPTS = pkt.pointee.pts == Int64.min
            ? 0.0
            : Double(pkt.pointee.pts) * tbSec
        let startOffset = Double(sub.start_display_time) / 1000.0
        let endOffset: Double
        if sub.end_display_time > 0 {
            endOffset = Double(sub.end_display_time) / 1000.0
        } else if pkt.pointee.duration > 0 {
            endOffset = Double(pkt.pointee.duration) * tbSec
        } else {
            // Last-resort default for streams that don't carry duration.
            endOffset = 5.0
        }
        let startTime = pktPTS + startOffset
        let endTime = pktPTS + endOffset

        // Build a list of cue bodies from this packet's rects. Most
        // text packets have one rect; PGS / DVB packets can have
        // several (signs/songs at top + dialogue at bottom) — each
        // becomes its own cue at the same time range.
        var bodies: [SubtitleCue.Body] = []
        var textLines: [String] = []
        if sub.num_rects > 0, let rects = sub.rects {
            for i in 0..<Int(sub.num_rects) {
                guard let rect = rects[i] else { continue }
                if let text = Self.textForSubtitleRect(rect) {
                    textLines.append(text)
                } else if let image = Self.imageForSubtitleRect(
                    rect,
                    videoWidth: Int(videoFrameWidth),
                    videoHeight: Int(videoFrameHeight)
                ) {
                    bodies.append(.image(image))
                }
            }
        }
        avsubtitle_free(&sub)

        // Merge plain text rects into a single text body — that
        // matches the existing single-Text overlay rendering.
        let merged = textLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !merged.isEmpty {
            bodies.append(.text(merged))
        }

        guard !bodies.isEmpty, endTime > startTime else {
            if subtitleDecodeSuccess <= 3 {
                print("[Engine.subs] decode#\(subtitleDecodeSuccess) bodies=\(bodies.count) start=\(startTime) end=\(endTime) — DROPPED (empty bodies or bad timing)")
            }
            subtitleLock.unlock()
            return
        }

        if subtitleDecodeSuccess <= 3 {
            let bodyDesc = bodies.map { body -> String in
                switch body {
                case .text(let s): return "text(\(s.prefix(40)))"
                case .image(let img): return "image(\(img.cgImage.width)x\(img.cgImage.height) at \(img.position))"
                }
            }.joined(separator: ", ")
            print("[Engine.subs] decode#\(subtitleDecodeSuccess) start=\(startTime) end=\(endTime) bodies=[\(bodyDesc)]")
        }

        let key = "\(startTime)|\(endTime)"
        if seenSubtitleKeys.contains(key) {
            subtitleLock.unlock()
            return
        }
        seenSubtitleKeys.insert(key)
        let cueIDStart = subtitleCueIDCounter
        subtitleCueIDCounter += bodies.count
        let streamIdx = activeSubtitleStreamIndex
        subtitleLock.unlock()

        let cues: [SubtitleCue] = bodies.enumerated().map { (offset, body) in
            SubtitleCue(
                id: cueIDStart + offset,
                startTime: startTime,
                endTime: endTime,
                body: body
            )
        }

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Drop cues whose stream the user has since switched away from.
            guard self.activeSubtitleStreamIndex == streamIdx else { return }
            // Cues mostly arrive in DTS order, but a backward seek can
            // make a fresh packet land before existing cues. Insert
            // each in sorted position so the overlay's lookup
            // (binary-search-then-walk for overlapping cues) stays
            // correct.
            for cue in cues {
                var lo = 0, hi = self.subtitleCues.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if self.subtitleCues[mid].startTime < cue.startTime {
                        lo = mid + 1
                    } else {
                        hi = mid
                    }
                }
                self.subtitleCues.insert(cue, at: lo)
            }
        }
    }

    /// Pull displayable text out of an `AVSubtitleRect`. Prefers
    /// `rect.text` (raw plain text), otherwise parses `rect.ass`
    /// as an ASS dialogue line and strips override blocks.
    nonisolated private static func textForSubtitleRect(_ rect: UnsafeMutablePointer<AVSubtitleRect>) -> String? {
        if let textPtr = rect.pointee.text {
            let s = String(cString: textPtr)
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let assPtr = rect.pointee.ass {
            var line = String(cString: assPtr)
            if line.hasPrefix("Dialogue: ") {
                line.removeFirst("Dialogue: ".count)
            }
            // ASS dialogue layout: 9 comma-separated fields; the body
            // is the 9th and may itself contain commas.
            let parts = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            let raw = parts.count == 9 ? String(parts[8]) : line
            return cleanASSBody(raw)
        }
        return nil
    }

    /// Diagnostic — dumps the first 16 bytes of a subtitle packet
    /// plus a heuristic scan of segment headers (`type` + 16-bit
    /// `length`). Used during the first three packets after a
    /// track switch so a `log stream` capture pinpoints whether a
    /// failure to produce cues is from a bogus prefix (PG magic),
    /// missing END (0x80) segment, or genuinely unparseable data.
    nonisolated private func dumpSubtitlePacket(_ pkt: UnsafeMutablePointer<AVPacket>, attempt: Int) {
        guard let data = pkt.pointee.data, pkt.pointee.size > 0 else { return }
        let pktSize = Int(pkt.pointee.size)

        var hex = ""
        for i in 0..<min(16, pktSize) {
            hex += String(format: "%02x ", data[i])
        }

        var segments: [String] = []
        var off = 0
        while off + 3 <= pktSize, segments.count < 8 {
            let segType = data[off]
            let segLen = (Int(data[off + 1]) << 8) | Int(data[off + 2])
            segments.append(String(format: "0x%02x(%d)", segType, segLen))
            off += 3 + segLen
            if segLen < 0 || off > pktSize { break }
        }
        let segText = segments.joined(separator: ",")
        print("[Engine.subs] pkt#\(attempt) hex16=\(hex)| segments=[\(segText)]")
    }

    /// Codecs that emit bitmap (graphic) subtitle rects rather than
    /// text. Bitmap decoders need the canvas dimensions from the
    /// container to correctly position rects; these are also the
    /// codecs we seed `videoFrameWidth/Height` into when the probe
    /// missed them.
    nonisolated private func isBitmapSubtitleCodec(_ codecID: AVCodecID) -> Bool {
        return codecID == AV_CODEC_ID_HDMV_PGS_SUBTITLE
            || codecID == AV_CODEC_ID_DVB_SUBTITLE
            || codecID == AV_CODEC_ID_DVD_SUBTITLE
            || codecID == AV_CODEC_ID_XSUB
    }

    /// Decode wrapper that fixes up packets some Blu-ray-to-MKV tools
    /// store in non-standard form before handing them to FFmpeg.
    ///
    /// **PGS with leading PES "PG" header** — the spec for MKV PGS
    /// stores raw segments (`segment_type` + `segment_size` +
    /// `payload`). Some converters leave the original PES PG header
    /// (`'P','G'` magic + 4-byte pts + 4-byte dts = 10 bytes) at the
    /// start of every block. With the header still attached, FFmpeg's
    /// pgssubdec reads byte 0 = 0x50 as a segment type, fails to
    /// recognise it, jumps the bogus length, and never sees the
    /// trailing END (0x80) segment — so `got_sub_ptr` stays 0
    /// forever. Strip the 10 bytes into a working copy before decode.
    /// The check is cheap (two-byte sniff per packet) and a no-op for
    /// any properly-stored PGS / DVB / DVD stream.
    nonisolated private func decodeSubtitleWithFixups(
        ctx: UnsafeMutablePointer<AVCodecContext>,
        pkt: UnsafeMutablePointer<AVPacket>,
        sub: UnsafeMutablePointer<AVSubtitle>,
        gotSub: UnsafeMutablePointer<Int32>
    ) -> Int32 {
        let isPGS = ctx.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE
        if isPGS,
           let data = pkt.pointee.data,
           pkt.pointee.size > 10,
           data[0] == 0x50, data[1] == 0x47 {
            if !pgsHeaderStripLogged {
                print("[Engine.subs] PGS packets carry leading 'PG' PES header — stripping 10 bytes per block before decode")
                pgsHeaderStripLogged = true
            }
            return decodeWithStrippedPrefix(ctx: ctx, pkt: pkt, prefix: 10, sub: sub, gotSub: gotSub)
        }
        return avcodec_decode_subtitle2(ctx, sub, gotSub, pkt)
    }

    /// Build a transient AVPacket whose data points at a Swift-owned
    /// padded copy of the input minus the first `prefix` bytes, hand
    /// it to the decoder, and let the buffer drop when the closure
    /// returns. The padded tail (AV_INPUT_BUFFER_PADDING_SIZE = 64
    /// bytes of zeros) keeps libavcodec's bitstream readers from
    /// straying past the end.
    nonisolated private func decodeWithStrippedPrefix(
        ctx: UnsafeMutablePointer<AVCodecContext>,
        pkt: UnsafeMutablePointer<AVPacket>,
        prefix: Int,
        sub: UnsafeMutablePointer<AVSubtitle>,
        gotSub: UnsafeMutablePointer<Int32>
    ) -> Int32 {
        let originalSize = Int(pkt.pointee.size)
        guard originalSize > prefix, let srcData = pkt.pointee.data else {
            return avcodec_decode_subtitle2(ctx, sub, gotSub, pkt)
        }
        let payloadSize = originalSize - prefix
        let paddingSize = 64
        var buffer = [UInt8](repeating: 0, count: payloadSize + paddingSize)
        memcpy(&buffer, srcData.advanced(by: prefix), payloadSize)

        return buffer.withUnsafeMutableBufferPointer { bufPtr -> Int32 in
            var temp = AVPacket()
            temp.data = bufPtr.baseAddress
            temp.size = Int32(payloadSize)
            temp.pts = pkt.pointee.pts
            temp.dts = pkt.pointee.dts
            temp.duration = pkt.pointee.duration
            temp.stream_index = pkt.pointee.stream_index
            temp.flags = pkt.pointee.flags
            return avcodec_decode_subtitle2(ctx, sub, gotSub, &temp)
        }
    }

    nonisolated private static func cleanASSBody(_ raw: String) -> String? {
        var s = raw
        s = s.replacingOccurrences(of: "\\N", with: "\n")
        s = s.replacingOccurrences(of: "\\n", with: "\n")
        s = s.replacingOccurrences(of: "\\h", with: " ")
        s = s.replacingOccurrences(
            of: "\\{[^}]*\\}",
            with: "",
            options: .regularExpression
        )
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Render a bitmap subtitle rect (PGS / DVB / HDMV) into a
    /// CGImage with normalised position. Walks the indexed-pixel
    /// plane (`data[0]`) through the palette (`data[1]`) into a
    /// packed RGBA buffer and wraps that as a CGImage.
    ///
    /// The palette is delivered by libavcodec as 32-bit values laid
    /// out with alpha in the high byte and BGR below — i.e. on a
    /// little-endian platform the bytes in memory read `[B, G, R, A]`.
    /// We rewrite to RGBA byte order for CGImage's
    /// `premultipliedLast` consumer.
    nonisolated private static func imageForSubtitleRect(
        _ rect: UnsafeMutablePointer<AVSubtitleRect>,
        videoWidth: Int,
        videoHeight: Int
    ) -> SubtitleImage? {
        // libavcodec's 5.x layout: SUBTITLE_BITMAP rects carry the
        // indexed plane in `data.0` and the palette in `data.1`.
        let r = rect.pointee
        guard r.type == SUBTITLE_BITMAP,
              r.w > 0, r.h > 0,
              let pixelsPtr = r.data.0,
              let palettePtr = r.data.1
        else { return nil }

        let width = Int(r.w)
        let height = Int(r.h)
        let stride = Int(r.linesize.0)

        // Convert indexed → packed RGBA premultiplied.
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let palIdx = Int(pixelsPtr[y * stride + x])
                let palOff = palIdx * 4
                // Memory order from libavcodec on little-endian Apple
                // platforms is [B, G, R, A] for a uint32 stored as
                // (a << 24) | (r << 16) | (g << 8) | b.
                let b = palettePtr[palOff + 0]
                let g = palettePtr[palOff + 1]
                let red = palettePtr[palOff + 2]
                let a = palettePtr[palOff + 3]

                // Premultiply against alpha so CGImage's
                // premultipliedLast renders correctly without the
                // black-fringe edges that straight alpha produces
                // on smooth blends.
                let outOff = (y * width + x) * 4
                rgba[outOff + 0] = UInt8((Int(red) * Int(a) + 127) / 255)
                rgba[outOff + 1] = UInt8((Int(g) * Int(a) + 127) / 255)
                rgba[outOff + 2] = UInt8((Int(b) * Int(a) + 127) / 255)
                rgba[outOff + 3] = a
            }
        }

        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        // Normalise the rect's position against the source video
        // frame. `videoWidth` / `videoHeight` come from the engine's
        // captured codecpar dims; if for some reason they're zero
        // (very early in load before videoStream picked) we fall
        // back to a centered overlay sized for the bitmap's own
        // aspect — better than rendering at (0, 0) full-size.
        let position: CGRect
        if videoWidth > 0, videoHeight > 0 {
            position = CGRect(
                x: Double(r.x) / Double(videoWidth),
                y: Double(r.y) / Double(videoHeight),
                width: Double(width) / Double(videoWidth),
                height: Double(height) / Double(videoHeight)
            )
        } else {
            position = CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.15)
        }

        return SubtitleImage(cgImage: cgImage, position: position)
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
        // Subtitle codec context is tied to the demuxer's stream
        // pointers — drop it before closing the demuxer so we don't
        // dangle into the next load.
        closeSubtitleDecoder()
        demuxer.close()
        audioAvailable = false
        atmosAudioSkipPTS = -1
        // usingSoftwareDecode must be reset — otherwise a subsequent
        // load() that fails before opening any decoder would see a stale
        // `true` from a prior SW-decoded session and try to flush/close
        // the wrong decoder in its catch path.
        usingSoftwareDecode = false
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
        #if DEBUG
        nonisolated(unsafe) var loggedCloneFailed = false
        #endif

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
                    #if DEBUG
                    print("[AetherEngine] Demuxer read failed after \(retries) retries: \(readError)")
                    #endif
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
                        } else {
                            #if DEBUG
                            if !loggedCloneFailed {
                                loggedCloneFailed = true
                                print("[Demux] av_packet_clone FAILED (size=\(packet.pointee.size))")
                            }
                            #endif
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

                            // Zero-copy hand-off: clone the packet (refcount
                            // bump on the underlying buffer, no memcpy) and
                            // wrap its data into a Data view that releases
                            // the cloned packet when freed. Saves the
                            // malloc + memcpy that `Data(bytes:count:)`
                            // would do per packet — at 768 kbps Atmos that
                            // was ~96 KB/s of allocation churn on the demux
                            // thread. Falls back to the copy path if the
                            // refcount bump fails (allocation pressure).
                            let packetData: Data
                            if let cloned = av_packet_clone(packet),
                               let clonedBytes = cloned.pointee.data {
                                let size = Int(cloned.pointee.size)
                                packetData = Data(
                                    bytesNoCopy: UnsafeMutableRawPointer(mutating: clonedBytes),
                                    count: size,
                                    deallocator: .custom { _, _ in
                                        var p: UnsafeMutablePointer<AVPacket>? = cloned
                                        av_packet_free(&p)
                                    }
                                )
                            } else {
                                packetData = Data(bytes: data, count: Int(packet.pointee.size))
                            }
                            self.atmosAudioLock.lock()
                            // Throttle if buffer is full — same approach as
                            // the video drain. Without it a multi-second
                            // AVPlayer stall lets the audio buffer grow
                            // without bound (one Data per packet, no
                            // back-pressure from the consumer side).
                            while self.atmosAudioBuffer.count >= self.atmosAudioBufferMax && !self.stopRequested {
                                self.atmosAudioLock.unlock()
                                Thread.sleep(forTimeInterval: 0.01)
                                self.atmosAudioLock.lock()
                            }
                            self.atmosAudioBuffer.append(packetData)
                            self.atmosAudioLock.unlock()
                            self.startAtmosAudioDrain()
                            // Atmos parallel of the PCM signal: as
                            // soon as a packet has been routed into
                            // the HLS pipeline, downstream consumers
                            // can rely on `await load(...)` having
                            // returned with a settled engine.
                            self.isAudioFlowing = true
                        }

                    case .pcm:
                        let sampleBuffers = audioDecoder.decode(packet: packet)
                        for sb in sampleBuffers {
                            audioOutput.enqueue(sampleBuffer: sb)
                        }
                        if !audioStarted && !sampleBuffers.isEmpty {
                            audioOutput.start(at: initialAudioTime)
                            audioStarted = true
                            // Signal load() that the synchronizer is
                            // now driving samples — safe to release
                            // the caller from `await load(...)`.
                            self.isAudioFlowing = true
                        }
                    }
                } else if streamIdx == self.activeSubtitleStreamIndex {
                    // Subtitle stream — decode the packet inline. Text
                    // codecs are cheap (a few microseconds each) so we
                    // don't bother offloading; cues land on the main
                    // actor through `decodeSubtitlePacket`.
                    self.subtitlePacketsSeen += 1
                    if self.subtitlePacketsSeen == 1 {
                        print("[Engine.subs] first subtitle packet on stream \(streamIdx) pts=\(packet.pointee.pts) size=\(packet.pointee.size)")
                    }
                    if let stream = self.demuxer.stream(at: streamIdx) {
                        self.decodeSubtitlePacket(packet, stream: stream)
                    }
                    if self.subtitlePacketsSeen % 50 == 0 {
                        print("[Engine.subs] tally packetsSeen=\(self.subtitlePacketsSeen) decodeAttempts=\(self.subtitleDecodeAttempts) decodeSuccess=\(self.subtitleDecodeSuccess)")
                    }
                }

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

        // Stop the demux loop when entering background — VTDecompressionSession
        // and AVIO connections are invalidated by tvOS during suspension.
        // Just pausing isn't enough: when the user resumes, the demux loop
        // calls av_read_frame which crashes on the dead AVIO context.
        // The host app should call reloadAtCurrentPosition() on foreground return.
        let bgObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            guard self.state == .playing || self.state == .paused else { return }
            self.stopRequested = true
            self.isPlaying = false
            if self.audioMode == .atmos {
                self.hlsAudioEngine?.pause()
            } else {
                self.audioOutput.pause()
            }
            if let tb = self.hlsAudioEngine?.videoTimebase {
                CMTimebaseSetRate(tb, rate: 0)
            }
            self.state = .paused
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
/// Top-level helper used by the demux loop and by the Atmos drains
/// in their respective extension files. `internal` so cross-file
/// access is allowed within the AetherEngine module.
func av_packet_free_safe(_ packet: UnsafeMutablePointer<AVPacket>) {
    var p: UnsafeMutablePointer<AVPacket>? = packet
    av_packet_free(&p)
}

// MARK: - Errors

public enum AetherEngineError: Error {
    case noVideoStream
    case noAudioStream
}
