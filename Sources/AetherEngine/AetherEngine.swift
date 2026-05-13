import Foundation
import QuartzCore
import CoreMedia
import CoreVideo
import AVFoundation
import Combine
import Libavformat
import Libavcodec
import Libavutil

#if canImport(UIKit)
import UIKit
#endif

/// AetherEngine, format-agnostic video muxer that feeds AVPlayer.
///
/// Open-source LGPL 3.0 engine that takes any source (HTTP, file://,
/// MKV / MP4 / TS containers; AVC / HEVC / VP9 / AV1 codecs) and
/// streams it as HLS-fMP4 over a loopback HTTP server to an internal
/// AVPlayer. The host embeds a single `AetherPlayerView` and calls
/// `engine.load(url:options:)`; the engine handles demux, fMP4 mux,
/// HDMI HDR-mode handshake, frame-rate matching, AVPlayer wiring, and
/// per-frame HDR metadata forwarding.
///
/// ## Architecture
///
/// ```
/// URL → FFmpeg Demuxer → HLS-fMP4 Mux (libavformat) → loopback HTTP
///   → AVPlayer → AVPlayerLayer (hosted by AetherPlayerView)
/// ```
///
/// Audio is stream-copied into the fMP4 when the codec is legal there
/// (AAC, AC3, EAC3 incl. JOC Atmos, FLAC, ALAC, MP3, Opus). Codecs
/// that aren't legal in fMP4 (TrueHD, DTS, etc.) bridge through the
/// engine's FLAC re-encoder so AVPlayer plays them as lossless FLAC.
///
/// ## Quick Start
///
/// ```swift
/// let engine = try AetherEngine()
/// let view = AetherPlayerView()
/// engine.bind(view: view)
/// try await engine.load(url: myVideoURL, options: .init())
/// engine.play()
/// ```
///
/// ## License
///
/// LGPL 3.0, App Store compatible when dynamically linked.
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

    /// Which internal backend rendered the current session.
    /// Always `.native` after 1.0.0 (the legacy aether sample-buffer
    /// path was removed). Kept on the public surface for diagnostic
    /// overlays / TestFlight badges.
    @Published public private(set) var playbackBackend: PlaybackBackend = .none

    /// Decoded subtitle cues for the active subtitle source. Populated
    /// by `selectSidecarSubtitle(url:)` only — embedded subtitle
    /// streams in the source travel through HLSVideoEngine into the
    /// fMP4 wrapper but aren't decoded back to text on this side yet
    /// (AVMediaSelection wiring is a tracked follow-up). Sidecar SRT
    /// works end-to-end.
    @Published public private(set) var subtitleCues: [SubtitleCue] = []
    /// True while a sidecar file is being downloaded + decoded.
    @Published public private(set) var isLoadingSubtitles: Bool = false
    /// True when sidecar subtitles are the active subtitle source.
    @Published public private(set) var isSubtitleActive: Bool = false

    // MARK: - Output

    /// How the AVPlayer surface fills its container layer. Mirrors
    /// the host's preferred fit mode to whichever `AVPlayerLayer` is
    /// currently mounted in the bound `AetherPlayerView`.
    public var videoGravity: AVLayerVideoGravity {
        get { _videoGravity }
        set {
            _videoGravity = newValue
            nativeHost?.playerLayer.videoGravity = newValue
        }
    }
    private var _videoGravity: AVLayerVideoGravity = .resizeAspect

    // MARK: - Capabilities

    /// Snapshot of what the active display can present right now.
    ///
    /// Reads `AVPlayer.eligibleForHDRPlayback` and
    /// `AVPlayer.availableHDRModes` at call time. tvOS and iOS report
    /// panel capabilities; macOS reports the built-in display only and
    /// may under-report external displays.
    public static var displayCapabilities: DisplayCapabilities {
        #if os(tvOS) || os(iOS)
        let hdrEligible = AVPlayer.eligibleForHDRPlayback
        let modes = AVPlayer.availableHDRModes
        return DisplayCapabilities(
            supportsHDR: hdrEligible,
            supportsDolbyVision: modes.contains(.dolbyVision),
            supportsHDR10: modes.contains(.hdr10),
            supportsHLG: modes.contains(.hlg)
        )
        #else
        return DisplayCapabilities(
            supportsHDR: AVPlayer.eligibleForHDRPlayback,
            supportsDolbyVision: false,
            supportsHDR10: false,
            supportsHLG: false
        )
        #endif
    }

    // MARK: - View binding

    /// The view currently bound to this engine, if any. Weak so a host
    /// that drops its view reference doesn't leak the surface through
    /// the engine singleton.
    private weak var boundView: AetherPlayerView?

    /// Bind a render surface to this engine. The engine attaches the
    /// active `AVPlayerLayer` immediately and re-attaches on every
    /// session swap. Calling `bind` again with a different view
    /// detaches the old one.
    public func bind(view: AetherPlayerView) {
        if let existing = boundView, existing !== view {
            existing.detach()
        }
        boundView = view
        presentCurrentLayer()
    }

    /// Unbind a previously bound view. Idempotent; safe to call when
    /// nothing is bound or when a different view is bound.
    public func unbind(view: AetherPlayerView) {
        guard boundView === view else { return }
        view.detach()
        boundView = nil
    }

    /// Attach the AVPlayerLayer for the active native session to the
    /// bound view. No-op when there's no session (boundView retains
    /// nothing to show; layer attaches on the next load).
    func presentCurrentLayer() {
        guard let view = boundView, let host = nativeHost else { return }
        view.attach(host.playerLayer)
    }

    // MARK: - Display + native state

    /// Engine-owned HDMI HDR handshake controller. Programs
    /// `AVDisplayManager.preferredDisplayCriteria` from the format +
    /// frame rate the demuxer probes; no-op on iOS / macOS.
    private let displayCriteria = DisplayCriteriaController()

    /// HLS video engine that demuxes the source and serves a
    /// loopback HLS-fMP4 playlist for AVPlayer to consume. Non-nil
    /// between `load` and `stop`.
    private var nativeVideoSession: HLSVideoEngine?

    /// The native AVPlayer + AVPlayerLayer host. Non-nil between
    /// `load` and `stop`.
    private var nativeHost: NativeAVPlayerHost?

    /// Combine subscriptions from `nativeHost`'s @Published into the
    /// engine's own @Published mirrors. Cancelled on stopInternal so
    /// a new session doesn't accumulate them.
    private var nativeCancellables: Set<AnyCancellable> = []

    /// The URL of the current playback session. Used by
    /// `reloadAtCurrentPosition()` to rebuild the pipeline after
    /// background suspension.
    private var loadedURL: URL?

    /// In-flight sidecar subtitle decode. Cancelled on subtitle
    /// clear / track switch so a stale decode can't overwrite fresh
    /// cues.
    private var sidecarTask: Task<Void, Never>?

    // MARK: - Init

    /// Lifecycle notification observers, stored for cleanup.
    private var lifecycleObservers: [Any] = []

    public init() throws {
        // Configure audio session for multichannel playback. AVPlayer
        // needs `.playback` + `.moviePlayback` + multichannel-content
        // enabled before its first asset opens, otherwise output is
        // forced to stereo. The `.longFormAudio` policy keeps audio
        // alive across rapid app-switch flips.
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
            try session.setSupportsMultichannelContent(true)
            try session.setActive(true)
        } catch {
            EngineLog.emit("[AetherEngine] AVAudioSession setup error: \(error)", category: .engine)
        }
        let maxCh = session.maximumOutputNumberOfChannels
        if maxCh > 2 {
            try? session.setPreferredOutputNumberOfChannels(maxCh)
        }
        EngineLog.emit("[AetherEngine] AVAudioSession: maxChannels=\(maxCh), preferred=\(session.preferredOutputNumberOfChannels), output=\(session.outputNumberOfChannels)", category: .engine)
        #endif

        setupLifecycleObservers()
    }

    // MARK: - Public load

    /// Load a media file or stream URL. Replaces any current playback.
    ///
    /// Behavior:
    /// 1. Tears down the previous session.
    /// 2. Briefly opens the demuxer to detect format + frame rate.
    /// 3. Programs `AVDisplayCriteria` from the detected metadata
    ///    (DV → `dvh1`, others → `hvc1`; refresh rate snapped to a
    ///    standard rate; honors Match Content + Match Frame Rate).
    /// 4. Waits for the panel mode-switch to settle.
    /// 5. Spins up `HLSVideoEngine` + `NativeAVPlayerHost`.
    ///
    /// VP9 / AV1 sources gate on a runtime VideoToolbox capability
    /// probe; on hardware that can't decode them, the engine throws
    /// `HLSVideoEngine.HLSVideoEngineError.unsupportedCodec` and the
    /// host should surface that to the user. Dolby Vision Profile 7
    /// (dual-layer) and Profile 8.2 (SDR base) similarly throw.
    ///
    /// - Parameters:
    ///   - url: Media source (http/https/file).
    ///   - startPosition: Seconds into the stream to start at (resume).
    ///   - options: Engine-internal toggles. See `LoadOptions`.
    public func load(
        url: URL,
        startPosition: Double? = nil,
        options: LoadOptions = .init()
    ) async throws {
        stopInternal()
        loadedURL = url
        state = .loading
        currentTime = 0
        duration = 0
        progress = 0

        // 1. Brief demuxer probe to grab format + frame rate. The
        //    HLSVideoEngine spun up below re-opens internally; the
        //    double-open keeps the failure-mode matrix small.
        var detectedFormat: VideoFormat = .sdr
        var detectedRate: Double? = nil
        var detectedDVProfile: Bool = false
        let probe = Demuxer()
        do {
            try probe.open(url: url)
            let videoIdx = probe.videoStreamIndex
            if videoIdx >= 0, let stream = probe.stream(at: videoIdx) {
                detectedFormat = Self.detectVideoFormat(stream: stream)
                detectedRate = Self.detectFrameRate(stream: stream)
                detectedDVProfile = (detectedFormat == .dolbyVision)
            }
            probe.close()
        } catch {
            EngineLog.emit("[AetherEngine] probe failed (\(error)); proceeding without criteria", category: .engine)
        }

        videoFormat = detectedFormat
        let snappedRate = FrameRateSnap.snap(detectedRate ?? 0)
        EngineLog.emit("[AetherEngine] load url=\(url.absoluteString) format=\(detectedFormat) rate=\(snappedRate.map { String(format: "%.3f", $0) } ?? "n/a")", category: .engine)

        // 2. Display-criteria handshake.
        if !options.suppressDisplayCriteria {
            let codecTag: FourCharCode? = detectedDVProfile ? 0x64766831 : nil
            let willSwitch = displayCriteria.apply(
                format: detectedFormat,
                frameRate: snappedRate,
                codecTag: codecTag,
                omitColorExtensions: options.omitCriteriaColorExtensions
            )
            if willSwitch {
                await displayCriteria.waitForSwitch()
            }
        }

        // 3. Native-only: open HLSVideoEngine + NativeAVPlayerHost.
        //    Errors propagate to the caller; there's no aether fallback
        //    after 1.0.0.
        do {
            try await loadNative(url: url, startPosition: startPosition)
            playbackBackend = .native
            presentCurrentLayer()
        } catch {
            state = .error("Failed to load: \(error.localizedDescription)")
            throw error
        }
    }

    /// Open HLSVideoEngine against the source, wire NativeAVPlayerHost
    /// to its loopback URL, forward host @Published into the engine's
    /// own published mirrors.
    private func loadNative(url: URL, startPosition: Double?) async throws {
        let session = HLSVideoEngine(
            url: url,
            dvModeAvailable: Self.displayCapabilities.supportsDolbyVision
        )
        let playbackURL = try session.start()
        self.nativeVideoSession = session

        let host = NativeAVPlayerHost()
        host.playerLayer.videoGravity = _videoGravity
        self.nativeHost = host

        nativeCancellables.removeAll()
        host.$currentTime
            .sink { [weak self] value in self?.currentTime = value }
            .store(in: &nativeCancellables)
        host.$duration
            .sink { [weak self] value in
                if value > 0 { self?.duration = value }
            }
            .store(in: &nativeCancellables)
        host.$isReady
            .sink { [weak self] ready in
                guard let self = self else { return }
                if ready, self.state == .loading {
                    self.state = .paused
                }
            }
            .store(in: &nativeCancellables)
        host.$failureMessage
            .compactMap { $0 }
            .sink { [weak self] msg in self?.state = .error(msg) }
            .store(in: &nativeCancellables)
        host.$didReachEnd
            .filter { $0 }
            .sink { [weak self] _ in
                // AVPlayer reached end-of-stream. Flip to .idle so the
                // host's end-of-content flow fires.
                self?.state = .idle
            }
            .store(in: &nativeCancellables)

        host.load(url: playbackURL, startPosition: startPosition)
    }

    // MARK: - Transport

    public func play() {
        nativeHost?.play()
        if state == .paused || state == .loading {
            state = .playing
        }
    }

    public func pause() {
        nativeHost?.pause()
        if state == .playing {
            state = .paused
        }
    }

    public func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused, .loading: play()
        default: break
        }
    }

    /// Tear down and reload from the current position. Call after
    /// returning from background; AVIO connections and VT sessions
    /// (where applicable) are invalidated by tvOS when the app is
    /// suspended.
    public func reloadAtCurrentPosition() async throws {
        guard let url = loadedURL else { return }
        let pos = currentTime
        try await load(url: url, startPosition: pos > 1 ? pos : nil)
    }

    public func seek(to seconds: Double) async {
        let target = max(0, min(seconds, duration))
        state = .seeking
        nativeHost?.seek(to: target)
        currentTime = target
        // AVPlayer surfaces post-seek readiness via its own KVO; the
        // engine optimistically flips back to .playing so the host UI
        // doesn't stick on .seeking when the seek lands fast.
        state = .playing
    }

    public func stop() {
        stopInternal()
        state = .idle
        currentTime = 0
        progress = 0
    }

    /// Set playback volume (0.0 = mute, 1.0 = full).
    public var volume: Float {
        get { nativeHost?.avPlayer.volume ?? 1.0 }
        set { nativeHost?.avPlayer.volume = newValue }
    }

    /// Set playback speed (0.5–2.0). Audio pitch adjusts automatically
    /// via AVPlayer's `audioTimePitchAlgorithm`.
    public func setRate(_ rate: Float) {
        nativeHost?.setRate(rate)
    }

    // MARK: - Audio / subtitle track selection

    /// Audio track selection during playback. Native-only architecture
    /// would route this through `AVMediaSelection`; that wiring is a
    /// tracked follow-up. Today it's a no-op; the source's default
    /// audio stream plays.
    public func selectAudioTrack(index: Int) {
        // Tracked: AVMediaSelection routing. For now `audioTracks`
        // stays empty and the host hides the picker.
        _ = index
    }

    /// Embedded subtitle stream selection. Same AVMediaSelection
    /// follow-up as `selectAudioTrack`; today a no-op. Use
    /// `selectSidecarSubtitle(url:)` for SRT files; that path works
    /// end-to-end.
    public func selectSubtitleTrack(index: Int) {
        _ = index
        isSubtitleActive = false
        subtitleCues = []
        isLoadingSubtitles = false
    }

    /// Decode a sidecar subtitle file (`.srt` / `.ass` / `.vtt` /
    /// `.ssa` served alongside the media). The whole file is fetched
    /// and decoded up-front via `SubtitleDecoder.decodeFile`, then the
    /// resulting cues replace `subtitleCues` atomically.
    /// `isLoadingSubtitles` flips on for the duration so the host can
    /// show a spinner. Subsequent calls cancel any in-flight sidecar
    /// decode.
    public func selectSidecarSubtitle(url: URL) {
        cancelSidecarTask()

        isSubtitleActive = true
        subtitleCues = []
        isLoadingSubtitles = true

        sidecarTask = Task { [weak self] in
            let cues: [SubtitleCue]
            do {
                cues = try await SubtitleDecoder.decodeFile(url: url)
            } catch {
                EngineLog.emit("[AetherEngine] sidecar decode failed: \(error)", category: .engine)
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
                guard self.isSubtitleActive else { return }
                self.subtitleCues = cues
                self.isLoadingSubtitles = false
            }
        }
    }

    /// Turn subtitles off and clear cached cues.
    public func clearSubtitle() {
        cancelSidecarTask()
        isSubtitleActive = false
        subtitleCues = []
        isLoadingSubtitles = false
    }

    private func cancelSidecarTask() {
        sidecarTask?.cancel()
        sidecarTask = nil
    }

    // MARK: - Internal teardown

    private func stopInternal() {
        // Stop AVPlayer fetching before tearing down the loopback HLS
        // server, otherwise AVPlayer's segment requests race the
        // server shutdown and produce noisy errors in the log. Always
        // reset display criteria so a previous DV/HDR session doesn't
        // leak the panel mode into the next playback.
        nativeCancellables.removeAll()
        nativeHost?.tearDown()
        nativeHost = nil
        nativeVideoSession?.stop()
        nativeVideoSession = nil
        displayCriteria.reset()
        playbackBackend = .none

        cancelSidecarTask()
        isSubtitleActive = false
        subtitleCues = []
        isLoadingSubtitles = false
    }

    // MARK: - Format / frame-rate probing

    private static func detectVideoFormat(stream: UnsafeMutablePointer<AVStream>) -> VideoFormat {
        let codecpar = stream.pointee.codecpar.pointee
        let transfer = codecpar.color_trc
        // PQ + DV side data → dolbyVision; PQ alone → hdr10. HLG → hlg.
        // Everything else → sdr. Per-stream HDR10+ T.35 SEI detection
        // happens inside HLSVideoEngine; this probe is the coarse
        // gate for the display-criteria handshake.
        if transfer == AVCOL_TRC_SMPTE2084 {
            return Self.streamHasDV(stream: stream) ? .dolbyVision : .hdr10
        }
        if transfer == AVCOL_TRC_ARIB_STD_B67 {
            return .hlg
        }
        return .sdr
    }

    private static func streamHasDV(stream: UnsafeMutablePointer<AVStream>) -> Bool {
        let nb = Int(stream.pointee.codecpar.pointee.nb_coded_side_data)
        guard nb > 0, let sideData = stream.pointee.codecpar.pointee.coded_side_data else {
            return false
        }
        for i in 0..<nb {
            if sideData[i].type == AV_PKT_DATA_DOVI_CONF {
                return true
            }
        }
        return false
    }

    private static func detectFrameRate(stream: UnsafeMutablePointer<AVStream>) -> Double? {
        let avg = stream.pointee.avg_frame_rate
        if avg.den > 0 && avg.num > 0 {
            return Double(avg.num) / Double(avg.den)
        }
        let r = stream.pointee.r_frame_rate
        if r.den > 0 && r.num > 0 {
            return Double(r.num) / Double(r.den)
        }
        return nil
    }

    // MARK: - App Lifecycle

    private func setupLifecycleObservers() {
        #if os(iOS) || os(tvOS)
        let nc = NotificationCenter.default

        // Pause AVPlayer when the app backgrounds so audio doesn't
        // keep streaming in the background. The host calls
        // `reloadAtCurrentPosition()` from its own foreground hook to
        // recover from any AVIO invalidation tvOS may do during
        // suspension.
        let bgObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                guard self.state == .playing || self.state == .paused else { return }
                self.nativeHost?.pause()
                self.state = .paused
            }
        }
        lifecycleObservers.append(bgObserver)
        #endif
    }
}

// MARK: - Errors

public enum AetherEngineError: Error {
    case noVideoStream
    case noAudioStream
}
