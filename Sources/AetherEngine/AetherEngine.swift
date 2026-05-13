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
    /// Active audio track's container stream index (matches `TrackInfo.id`),
    /// or `nil` while no audio is wired (audio-less source or before the
    /// first `load(url:)` resolves). Updated synchronously when
    /// `selectAudioTrack(index:)` reloads the pipeline; the host's
    /// picker reflects what the engine actually muxed rather than the
    /// last optimistic UI write.
    @Published public private(set) var activeAudioTrackIndex: Int?
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

    /// In-flight embedded-subtitle reader Task. Runs a side Demuxer
    /// against the same source URL, seeked to the current playhead,
    /// reading subtitle packets directly. Bypasses the main HLS pump
    /// (which has already raced past the playhead by ~60-80 s when
    /// subtitle activation happens mid-playback, so its subtitle
    /// packets near the visible time have already been read and
    /// discarded). Cancelled + restarted on track change, on
    /// `clearSubtitle`, on `seek`, and on `stop`.
    private var embeddedSubtitleTask: Task<Void, Never>?

    /// Active embedded subtitle stream index, or -1 for none. Used by
    /// `seek` to know whether to re-arm the side demuxer at the new
    /// playback position.
    private var activeEmbeddedSubtitleStreamIndex: Int32 = -1

    /// Source video dimensions captured at `load()` probe time. The
    /// embedded subtitle decoder uses these as a canvas-size fallback
    /// when a bitmap codec's PCS hasn't been parsed yet.
    private var sourceVideoWidth: Int32 = 0
    private var sourceVideoHeight: Int32 = 0

    /// Cap the per-session subtitle event diagnostic logs so the in-
    /// app overlay stays readable. Reset on `load()` so each new
    /// session gets a fresh budget.
    private var subtitleCueDiagnosticCount: Int = 0

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
    ///   - audioSourceStreamIndex: Optional container stream index for
    ///     the audio track to mux into the output. When non-nil, this is
    ///     used instead of `av_find_best_stream`'s automatic pick. Lets
    ///     the host honor a saved language preference on the very first
    ///     frame without bouncing through a separate
    ///     `selectAudioTrack` reload (which would cost a second of
    ///     "default-language audio plus black frame" at session start).
    ///     Validated against the container; an invalid index falls back
    ///     to the auto pick.
    public func load(
        url: URL,
        startPosition: Double? = nil,
        options: LoadOptions = .init(),
        audioSourceStreamIndex: Int32? = nil
    ) async throws {
        stopInternal()
        loadedURL = url
        state = .loading
        currentTime = 0
        duration = 0
        progress = 0
        audioTracks = []
        subtitleTracks = []
        subtitleCueDiagnosticCount = 0

        // 1. Brief demuxer probe to grab format + frame rate + track
        //    metadata. The HLSVideoEngine spun up below re-opens
        //    internally; the double-open keeps the failure-mode matrix
        //    small.
        var detectedFormat: VideoFormat = .sdr
        var detectedRate: Double? = nil
        var detectedDVProfile: Bool = false
        var probedAudioTracks: [TrackInfo] = []
        var probedSubtitleTracks: [TrackInfo] = []
        var probedDefaultAudioIndex: Int32 = -1
        let probe = Demuxer()
        do {
            try probe.open(url: url)
            let videoIdx = probe.videoStreamIndex
            if videoIdx >= 0, let stream = probe.stream(at: videoIdx) {
                detectedFormat = Self.detectVideoFormat(stream: stream)
                detectedRate = Self.detectFrameRate(stream: stream)
                detectedDVProfile = (detectedFormat == .dolbyVision)
                sourceVideoWidth = stream.pointee.codecpar.pointee.width
                sourceVideoHeight = stream.pointee.codecpar.pointee.height
            }
            probedAudioTracks = probe.audioTrackInfos()
            probedSubtitleTracks = probe.subtitleTrackInfos()
            probedDefaultAudioIndex = probe.audioStreamIndex
            probe.close()
        } catch {
            EngineLog.emit("[AetherEngine] probe failed (\(error)); proceeding without criteria", category: .engine)
        }

        videoFormat = detectedFormat
        audioTracks = probedAudioTracks
        subtitleTracks = probedSubtitleTracks
        // Mirror the audio stream HLSVideoEngine will actually pick.
        // When the host passed an override, that takes precedence; if
        // the override is invalid we fall back to the auto pick to
        // match the engine's own internal cascade. nil when the source
        // has no audio at all, so the host can hide the picker without
        // having to recompute the default itself.
        let resolvedInitialAudio: Int32
        if let override = audioSourceStreamIndex,
           probedAudioTracks.contains(where: { $0.id == Int(override) }) {
            resolvedInitialAudio = override
        } else {
            resolvedInitialAudio = probedDefaultAudioIndex
        }
        activeAudioTrackIndex = resolvedInitialAudio >= 0 ? Int(resolvedInitialAudio) : nil
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
            try await loadNative(
                url: url,
                startPosition: startPosition,
                audioSourceStreamIndex: audioSourceStreamIndex
            )
            playbackBackend = .native
            presentCurrentLayer()
            // Auto-play after load. AVPlayer's
            // `automaticallyWaitsToMinimizeStalling = true` (default)
            // handles "play before ready" correctly: it transitions
            // through `waitingToPlayAtSpecifiedRate`, buffers, and
            // starts playing once enough segments are in. The legacy
            // aether load() auto-started its own demux loop the same
            // way; preserving that contract means hosts that call
            // `engine.load(...)` get playing pixels without an extra
            // `engine.play()` round-trip.
            nativeHost?.play()
            state = .playing
        } catch {
            state = .error("Failed to load: \(error.localizedDescription)")
            throw error
        }
    }

    /// Open HLSVideoEngine against the source, wire NativeAVPlayerHost
    /// to its loopback URL, forward host @Published into the engine's
    /// own published mirrors. `audioSourceStreamIndex` overrides the
    /// auto-picked audio stream when non-nil; used by the mid-playback
    /// audio-track-switch path so the new pipeline picks up the host's
    /// chosen language without a separate API entry point.
    private func loadNative(
        url: URL,
        startPosition: Double?,
        audioSourceStreamIndex: Int32? = nil
    ) async throws {
        let session = HLSVideoEngine(
            url: url,
            dvModeAvailable: Self.displayCapabilities.supportsDolbyVision,
            audioSourceStreamIndexOverride: audioSourceStreamIndex
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

        // Re-arm the side subtitle demuxer at the new playhead so cues
        // for the post-scrub content surface immediately. Skip when
        // sidecar SRT is active (it pre-decoded the whole file).
        if activeEmbeddedSubtitleStreamIndex >= 0, let url = loadedURL {
            let streamIdx = activeEmbeddedSubtitleStreamIndex
            embeddedSubtitleTask?.cancel()
            subtitleCues = []
            startEmbeddedSubtitleTask(url: url, streamIndex: streamIdx, startAt: target)
        }

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

    /// Switch the active audio track mid-playback. The engine restarts
    /// its HLS pipeline with the new source audio stream as the muxed
    /// audio output, swaps AVPlayer to the freshly served playlist, and
    /// resumes at the current playhead.
    ///
    /// Roughly 0.5-1 s of black frame is expected during the swap
    /// because `AVPlayer.replaceCurrentItem` always tears the render
    /// surface down. The HDMI HDR-mode handshake is suppressed (the
    /// video stream isn't changing), so the panel doesn't re-negotiate.
    ///
    /// `index` is the audio track's container stream index, matching
    /// `TrackInfo.id` from `audioTracks`. Calls with an out-of-range
    /// index, an index pointing at a non-audio stream, or the index
    /// that's already active are no-ops.
    public func selectAudioTrack(index: Int) {
        guard let url = loadedURL else { return }
        guard audioTracks.contains(where: { $0.id == index }) else {
            EngineLog.emit(
                "[AetherEngine] selectAudioTrack: index=\(index) not in audioTracks (\(audioTracks.map { $0.id })), ignored",
                category: .engine
            )
            return
        }
        if activeAudioTrackIndex == index { return }

        let resumeAt = currentTime
        let sidecarToResume: URL? = isSubtitleActive && activeEmbeddedSubtitleStreamIndex < 0
            ? loadedSidecarURL
            : nil
        let embeddedStreamToResume: Int32 = activeEmbeddedSubtitleStreamIndex
        EngineLog.emit(
            "[AetherEngine] selectAudioTrack: switching to stream \(index) at \(String(format: "%.2f", resumeAt))s (embeddedSub=\(embeddedStreamToResume), sidecar=\(sidecarToResume?.lastPathComponent ?? "nil"))",
            category: .engine
        )

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.reloadWithAudioOverride(
                url: url,
                resumeAt: resumeAt,
                audioStreamIndex: Int32(index),
                embeddedSubtitleStreamToResume: embeddedStreamToResume,
                sidecarToResume: sidecarToResume
            )
        }
    }

    /// The sidecar subtitle URL the host most recently activated, kept
    /// so `selectAudioTrack` can rehydrate the same selection after the
    /// pipeline reload. Cleared by `clearSubtitle` and `stopInternal`.
    private var loadedSidecarURL: URL?

    /// Perform the audio-track-switch reload. Tears the current native
    /// session down, brings a fresh `HLSVideoEngine` up with the new
    /// audio source stream override, swaps AVPlayer to the new playlist
    /// URL at `resumeAt`, and re-arms whichever subtitle source was
    /// active before the switch.
    private func reloadWithAudioOverride(
        url: URL,
        resumeAt: Double,
        audioStreamIndex: Int32,
        embeddedSubtitleStreamToResume: Int32,
        sidecarToResume: URL?
    ) async {
        state = .loading
        let previousAudioIndex = activeAudioTrackIndex
        stopInternal()
        loadedURL = url

        do {
            try await loadNative(
                url: url,
                startPosition: resumeAt > 1 ? resumeAt : nil,
                audioSourceStreamIndex: audioStreamIndex
            )
            playbackBackend = .native
            activeAudioTrackIndex = Int(audioStreamIndex)
            presentCurrentLayer()
            nativeHost?.play()
            state = .playing
        } catch {
            EngineLog.emit(
                "[AetherEngine] selectAudioTrack reload failed: \(error), playback stopped",
                category: .engine
            )
            activeAudioTrackIndex = previousAudioIndex
            state = .error("Audio track switch failed: \(error.localizedDescription)")
            return
        }

        // Resume whichever subtitle source the host had active. The
        // sidecar branch wins because `loadedSidecarURL` is set only
        // when the active source is sidecar; the embedded branch
        // restarts the side-demuxer at the new playhead.
        if let sidecar = sidecarToResume {
            selectSidecarSubtitle(url: sidecar)
        } else if embeddedSubtitleStreamToResume >= 0 {
            selectSubtitleTrack(index: Int(embeddedSubtitleStreamToResume))
        }
    }

    /// Activate an embedded subtitle stream from the source. A side
    /// Demuxer opens the source independently of the main HLS pump,
    /// seeks to (just before) the current playback position, and
    /// streams subtitle packets through an `EmbeddedSubtitleDecoder`.
    /// Cues land in `subtitleCues` typically within 1-2 seconds of
    /// activation.
    ///
    /// Supports text codecs (SubRip / ASS / SSA / WebVTT / mov_text)
    /// and bitmap codecs (PGS / DVB / DVD / XSUB) with full canvas-
    /// relative positioning.
    ///
    /// Why a side demuxer instead of routing through the main HLS
    /// pump: when activation happens mid-playback, the main pump has
    /// already raced ~60-80 s ahead of the playhead and discarded
    /// every subtitle packet in that window. Re-reading from the
    /// playhead via a side demuxer is the cheapest way to catch cues
    /// for content the user is about to see. The side demuxer also
    /// re-seeks on `engine.seek` so scrubs surface cues at the new
    /// position immediately.
    public func selectSubtitleTrack(index: Int) {
        cancelSidecarTask()
        embeddedSubtitleTask?.cancel()
        embeddedSubtitleTask = nil

        guard let url = loadedURL else { return }

        isSubtitleActive = true
        subtitleCues = []
        isLoadingSubtitles = true
        activeEmbeddedSubtitleStreamIndex = Int32(index)

        startEmbeddedSubtitleTask(url: url, streamIndex: Int32(index), startAt: currentTime)
    }

    /// Spin up the side-demuxer Task that streams cues into the
    /// engine. Captured-on-init: the URL, the stream index, the
    /// start position, and the source video dimensions. The Task's
    /// run loop is cancellable; `cancel()` triggers a clean exit.
    private func startEmbeddedSubtitleTask(url: URL, streamIndex: Int32, startAt: Double) {
        let w = sourceVideoWidth > 0 ? sourceVideoWidth : 1920
        let h = sourceVideoHeight > 0 ? sourceVideoHeight : 1080
        embeddedSubtitleTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runEmbeddedSubtitleReader(
                url: url, streamIndex: streamIndex, startAt: startAt,
                videoWidth: w, videoHeight: h
            )
        }
    }

    /// Side-demuxer read loop. Opens a fresh `Demuxer` against the
    /// source URL, prewarms the cue table by seeking mid-file (so the
    /// MKV demuxer's cue index is loaded before the real seek), then
    /// seeks slightly before the requested start time and streams
    /// subtitle packets through an `EmbeddedSubtitleDecoder`, emitting
    /// cues back into the engine on the main actor.
    nonisolated private func runEmbeddedSubtitleReader(
        url: URL, streamIndex: Int32, startAt: Double,
        videoWidth: Int32, videoHeight: Int32
    ) async {
        let demuxer = Demuxer()
        do {
            try demuxer.open(url: url)
        } catch {
            EngineLog.emit("[AetherEngine] embedded subtitle open failed: \(error)", category: .engine)
            await MainActor.run { [weak self] in
                self?.isLoadingSubtitles = false
            }
            return
        }
        defer { demuxer.close() }

        // Prewarm the cue table by seeking mid-file before the actual
        // playhead seek. MKV cues live at the end of the file; a fresh
        // demuxer doesn't load them until first seek. Without this
        // prewarm, the seek-to-playhead lands inaccurately and we
        // either miss subtitle packets near the playhead or land far
        // away from where we asked. HLSVideoEngine does the same thing
        // for the same reason; we mirror it on the side demuxer.
        let duration = demuxer.duration
        if duration > 0 {
            demuxer.seek(to: duration * 0.5)
        }

        // Now the real seek. Slightly before the playhead so bitmap
        // subtitle codecs (PGS / DVB / HDMV) catch their state-machine
        // SETUP segments before the first END / EVENT segment.
        let seekTo = max(0, startAt - 2.0)
        demuxer.seek(to: seekTo)

        guard let stream = demuxer.stream(at: streamIndex),
              let decoder = EmbeddedSubtitleDecoder(
                  stream: stream,
                  sourceVideoWidth: videoWidth,
                  sourceVideoHeight: videoHeight
              )
        else {
            EngineLog.emit("[AetherEngine] embedded subtitle decoder open failed for stream=\(streamIndex)", category: .engine)
            await MainActor.run { [weak self] in
                self?.isLoadingSubtitles = false
            }
            return
        }

        let tb = stream.pointee.time_base
        let streamStartTime = stream.pointee.start_time

        // Comprehensive offset diagnostics: log every PTS-reference
        // value we have access to so we can correlate cue startTime
        // (source PTS based) with AVPlayer.currentTime (HLS playlist
        // based). If videoStream.start_time or format.start_time is
        // non-zero, that's the offset between source-time and
        // playlist-time.
        let formatStart = demuxer.formatStartTime
        let videoStream = demuxer.videoStreamIndex >= 0 ? demuxer.stream(at: demuxer.videoStreamIndex) : nil
        let videoStreamStart = videoStream?.pointee.start_time ?? 0
        let videoTb = videoStream?.pointee.time_base ?? AVRational(num: 1, den: 1)
        EngineLog.emit(
            "[AetherEngine] embedded subtitle reader started: stream=\(streamIndex) " +
            "startAt=\(String(format: "%.2f", startAt))s seekTo=\(String(format: "%.2f", seekTo))s " +
            "codec=\(decoder.codecID.rawValue) " +
            "subTb=\(tb.num)/\(tb.den) subStart=\(streamStartTime) " +
            "videoTb=\(videoTb.num)/\(videoTb.den) videoStart=\(videoStreamStart) " +
            "format.start_time=\(formatStart)us",
            category: .engine
        )

        await MainActor.run { [weak self] in
            self?.isLoadingSubtitles = false
        }

        var totalPacketsRead = 0
        var subtitlePacketsRead = 0
        var cuesEmitted = 0
        var firstCueLogged = false

        while !Task.isCancelled {
            guard let pkt = try? demuxer.readPacket() else {
                break
            }
            totalPacketsRead += 1
            let streamIdx = pkt.pointee.stream_index
            if streamIdx != streamIndex {
                var p: UnsafeMutablePointer<AVPacket>? = pkt
                av_packet_free(&p)
                continue
            }
            subtitlePacketsRead += 1
            let pktPTS = pkt.pointee.pts
            let event = decoder.decode(
                packet: pkt,
                streamTimeBase: tb,
                streamStartTime: streamStartTime
            )
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
            if let event {
                cuesEmitted += event.cues.count
                if !firstCueLogged, let firstCue = event.cues.first {
                    EngineLog.emit(
                        "[AetherEngine] subtitle first cue: pktPTS=\(pktPTS) → " +
                        "startTime=\(String(format: "%.3f", firstCue.startTime))s " +
                        "endTime=\(String(format: "%.3f", firstCue.endTime))s",
                        category: .engine
                    )
                    firstCueLogged = true
                }
                await MainActor.run { [weak self] in
                    self?.applySubtitleEvent(event)
                }
            }
        }

        EngineLog.emit(
            "[AetherEngine] embedded subtitle reader exited (cancelled=\(Task.isCancelled)) " +
            "packetsRead=\(totalPacketsRead) subtitlePackets=\(subtitlePacketsRead) " +
            "cuesEmitted=\(cuesEmitted)",
            category: .engine
        )
    }

    /// Apply a decoded subtitle event from HLSVideoEngine's embedded
    /// decoder. Handles PGS clear-event semantics (trim previously
    /// displayed bitmap cues so they actually disappear at the right
    /// moment) and inserts new cues sorted by start time so the
    /// overlay's lookup stays correct after backward scrubs.
    @MainActor
    private func applySubtitleEvent(_ event: EmbeddedSubtitleDecoder.SubtitleEvent) {
        guard isSubtitleActive else { return }

        // Diagnostic: for the first ~20 cues after activation, log
        // each cue's time range alongside engine.currentTime (=
        // AVPlayer.currentTime). Lets us spot whether the source-side
        // PTS and the AVPlayer-side clock differ systematically.
        if subtitleCueDiagnosticCount < 20, let firstCue = event.cues.first {
            subtitleCueDiagnosticCount += 1
            EngineLog.emit(
                "[applySubtitleEvent #\(subtitleCueDiagnosticCount)] " +
                "cueStart=\(String(format: "%.3f", firstCue.startTime))s " +
                "cueEnd=\(String(format: "%.3f", firstCue.endTime))s " +
                "engine.currentTime=\(String(format: "%.3f", currentTime))s",
                category: .engine
            )
        }

        // PGS clear-event trim: each PGS event implicitly terminates
        // whatever was on screen. Truncate any image cue whose
        // interval straddles the new event's start so it disappears
        // at the right moment instead of staying up for the
        // UINT32_MAX (~50-day) default the decoder hands us.
        if let trimAt = event.pgsTrimAt {
            for i in 0..<subtitleCues.count {
                guard case .image = subtitleCues[i].body else { continue }
                let cue = subtitleCues[i]
                if cue.startTime < trimAt && cue.endTime > trimAt {
                    subtitleCues[i] = SubtitleCue(
                        id: cue.id,
                        startTime: cue.startTime,
                        endTime: trimAt,
                        body: cue.body
                    )
                }
            }
        }

        // Cues mostly arrive in DTS order, but a backward scrub can
        // make a fresh packet land before existing cues. Insert each
        // in sorted position so the overlay's lookup (binary search
        // then walk for overlapping cues) stays correct.
        for cue in event.cues {
            var lo = 0, hi = subtitleCues.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if subtitleCues[mid].startTime < cue.startTime {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            subtitleCues.insert(cue, at: lo)
        }
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
        // Sidecar replaces any active embedded stream.
        embeddedSubtitleTask?.cancel()
        embeddedSubtitleTask = nil
        activeEmbeddedSubtitleStreamIndex = -1

        loadedSidecarURL = url
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

    /// Turn subtitles off and clear cached cues. Tears down both the
    /// sidecar SRT decode task and the side-demuxer embedded reader.
    public func clearSubtitle() {
        cancelSidecarTask()
        embeddedSubtitleTask?.cancel()
        embeddedSubtitleTask = nil
        activeEmbeddedSubtitleStreamIndex = -1
        loadedSidecarURL = nil
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
        embeddedSubtitleTask?.cancel()
        embeddedSubtitleTask = nil
        activeEmbeddedSubtitleStreamIndex = -1
        loadedSidecarURL = nil
        isSubtitleActive = false
        subtitleCues = []
        isLoadingSubtitles = false
        // Audio-track state belongs to the host's picker; clear it so a
        // stale index from the previous session can't be re-applied via
        // `selectAudioTrack` before the next `load(url:)` repopulates
        // `audioTracks`.
        activeAudioTrackIndex = nil
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
