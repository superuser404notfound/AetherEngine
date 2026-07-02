import Foundation
import Darwin.Mach
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
import MediaPlayer

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

    @Published public internal(set) var state: PlaybackState = .idle {
        didSet { recomputePlaybackPhase() }
    }

    /// Mid-playback rebuffer flag. `state` stays `.playing` across a rebuffer to avoid icon flicker;
    /// gate on this when you need to distinguish a stall from real playback (AetherEngine#35).
    /// Always false during initial load spin-up (`state == .loading`).
    @Published public internal(set) var isBuffering: Bool = false {
        didSet { recomputePlaybackPhase() }
    }

    /// True from seek entry until physical landing, covering both programmatic and native AVKit scrubs.
    /// Unlike `state == .seeking` (optimistically flipped to `.playing`), this spans the real
    /// loopback-HLS landing, which resolves seconds after the call (AetherEngine#38). Paired with `seekTarget`.
    @Published public internal(set) var isSeeking: Bool = false {
        didSet { recomputePlaybackPhase() }
    }

    /// Source-PTS seek destination, or nil when idle. Cleared on landing. For native scrubs, set to the
    /// out-of-range segment time AVPlayer requested (AetherEngine#38).
    @Published public internal(set) var seekTarget: Double? = nil

    /// Single source of truth for what playback is doing right now (#85), derived from
    /// `state` / `isBuffering` / `isSeeking` / the reader network phase. Recomputed on every input change;
    /// never a parallel state machine. Hosts should observe this instead of stitching the raw signals or
    /// regex-matching `EngineLog`.
    @Published public internal(set) var playbackPhase: PlaybackPhase = .idle

    /// Reader source-fetch axis feeding `playbackPhase`. Updated off the demux thread via
    /// `setReaderNetworkPhase`. `didSet` keeps `playbackPhase` in sync (#85).
    private var readerStall: ReaderNetworkPhase = .flowing {
        didSet { recomputePlaybackPhase() }
    }

    /// Idempotent: assigns `playbackPhase` only when the derived value actually changes, so a flapping
    /// origin or redundant input write never fires a spurious `objectWillChange`.
    private func recomputePlaybackPhase() {
        let next = PlaybackPhase.derive(state: state,
                                        isBuffering: isBuffering,
                                        isSeeking: isSeeking,
                                        stall: readerStall)
        if playbackPhase != next { playbackPhase = next }
    }

    /// Main-actor entry point for the demuxer's `@Sendable onNetworkPhaseChanged` callback (#85).
    func setReaderNetworkPhase(_ phase: ReaderNetworkPhase) {
        if readerStall != phase { readerStall = phase }
    }

    /// Bumped at every `seek(to:)` entry; a seek finalizes isSeeking only when its generation still matches,
    /// preventing a superseded seek from clobbering a newer one.
    private var seekGeneration: UInt64 = 0

    /// Two independent seek-in-flight flags that isSeeking OR-s over. Programmatic and native scrub seeks
    /// are NOT mutually exclusive: a far programmatic seek triggers the same producer-restart as a scrub.
    /// Tracked separately so neither can drop isSeeking before the other settles. Routed through
    /// `setProgrammaticSeek`/`setNativeScrubSeek`.
    private var programmaticSeekInFlight = false
    private var nativeScrubSeekInFlight = false

    /// Recomputes isSeeking/seekTarget from both in-flight flags. Idempotent to avoid redundant Combine emissions.
    private func recomputeSeekSignal(target: Double?) {
        let seeking = programmaticSeekInFlight || nativeScrubSeekInFlight
        if isSeeking != seeking { isSeeking = seeking }
        if seeking {
            if let target { seekTarget = target }
        } else {
            seekTarget = nil
        }
    }

    private func setProgrammaticSeek(inFlight: Bool, target: Double?) {
        programmaticSeekInFlight = inFlight
        recomputeSeekSignal(target: target)
    }

    /// Wired to `HLSVideoEngine.onSeekStateChanged`; see `requestRestart`.
    func setNativeScrubSeek(inFlight: Bool, target: Double?) {
        nativeScrubSeekInFlight = inFlight
        recomputeSeekSignal(target: target)
    }

    /// High-frequency playback clock (currentTime, sourceTime, live-edge). Separate ObservableObject:
    /// its ~10 Hz ticks must not fire objectWillChange on the engine or every SwiftUI view re-renders per
    /// tick, causing tvOS Menu flicker (AetherEngine#29). Observe only in leaf views that render time.
    public let clock = PlaybackClock()

    /// Forwarder; for push updates subscribe to `clock.$currentTime` (objectWillChange does NOT fire on ticks).
    public var currentTime: Double { clock.currentTime }

    @Published public internal(set) var duration: Double = 0

    /// Forwarder; see `clock.progress`.
    public var progress: Float { clock.progress }

    // internal(set): syncPublishedAudioStateFromNativeSession replaces the probe-derived list with side-demuxer
    // tracks for demuxed-audio live sources after load completes.
    @Published public internal(set) var audioTracks: [TrackInfo] = []
    // internal(set): the disc title-switch reload republishes the new title's tracks from AetherEngine+Loading.
    @Published public internal(set) var subtitleTracks: [TrackInfo] = []
    /// Container metadata (tags + cover). Populated from the probe demuxer before backend dispatch; nil while idle.
    @Published public private(set) var metadata: MediaMetadata?
    /// Active audio stream index (matches TrackInfo.id), or nil when no audio is wired. Updated synchronously
    /// on `selectAudioTrack` reload so the picker reflects the actual muxed track.
    @Published public internal(set) var activeAudioTrackIndex: Int?
    @Published public internal(set) var videoFormat: VideoFormat = .sdr

    /// Source video format before panel clamping. Differs from `videoFormat` when the panel can't present the
    /// source (e.g. DV on SDR panel): `videoFormat` reads `.sdr` (what's on screen), this stays `.dolbyVision`.
    /// Use for media-attribute labels (Stats for Nerds); use `videoFormat` for panel-rendering UI.
    /// Late HDR10+ T.35 SEI upgrades flip this independently of `videoFormat`'s panel guard.
    @Published public internal(set) var sourceVideoFormat: VideoFormat = .sdr

    // MARK: - Disc titles / chapters (#67)

    /// Selectable titles on the loaded disc image (Blu-ray playlists / DVD titles), longest first so
    /// id 0 is the main feature. Empty for non-disc sources. Populated from the probe demuxer at load.
    @Published public internal(set) var discTitles: [TitleInfo] = []
    /// The disc title currently playing, or nil for a non-disc source. Updated on `selectTitle` reload.
    @Published public internal(set) var selectedDiscTitle: TitleInfo?
    /// Chapters of the selected title. Empty until Blu-ray chapter parsing ships (Phase 2); declared
    /// now so hosts can bind the picker against a stable API.
    @Published public internal(set) var discChapters: [ChapterInfo] = []
    /// The id of the title the disc demuxer should (re)open with. Mirrors `selectedDiscTitle?.id` but
    /// kept as plain state so it survives the stopInternal inside a reload and threads into audio-switch /
    /// background-resume reopens (a URL-disc reopen with no id would silently revert to the main title).
    var activeDiscTitleID: Int?

    /// Source container start PTS (seconds) from the probe (AVFormatContext.start_time). The software-path
    /// playback clock begins here (the native path's content base is `playlistShiftSeconds`), so a DVD
    /// chapter seek adds it to the chapter's title-relative (0-based) target. 0 when unknown (#67).
    var sourceStartSeconds: Double = 0

    /// Active playback backend: `.native` (AVPlayer) or `.software` (SoftwarePlaybackHost/dav1d/libavcodec).
    /// Exposed for diagnostic overlays; hosts should not branch on it.
    @Published public internal(set) var playbackBackend: PlaybackBackend = .none

    /// iOS: master enable for background playback (PiP + background audio). Default on; no user setting yet.
    public var backgroundPlaybackEnabled = true
    /// iOS: set by the host from the AVKit PiP delegate; the keepalive policy + pause-safety read it.
    public var pictureInPictureActive = false
    #if os(iOS)
    /// True between didEnterBackground and didBecomeActive; gates the pause-while-backgrounded teardown.
    private var isBackgrounded = false
    #endif

    /// Wedge-safe keepalive decision: keep the video pipeline alive on background ONLY while the app stays
    /// genuinely running (PiP active, or actively playing for background audio), never across an idle
    /// suspension. Pure so the policy is unit-tested without the lifecycle. See setupLifecycleObservers.
    nonisolated static func shouldKeepVideoAlive(enabled: Bool, pipActive: Bool, state: PlaybackState) -> Bool {
        enabled && (pipActive || state == .playing)
    }

    /// What to do with the active video pipeline when the app enters the background. Pure so the lifecycle
    /// policy is unit-testable. Mirrors the spirit of the native keepalive onto the software path.
    enum BackgroundAction: Equatable {
        case doNothing               // audio backend, or native keepalive: leave the running session alone
        case enterSoftwareAudioOnly  // SW host kept alive: drop video in the demux loop, keep feeding audio
        case teardownVideo           // release the video pipeline before idle suspension
    }

    /// - keepVideoAlive: result of shouldKeepVideoAlive. Pass false on tvOS (the wedge-safe unconditional teardown).
    nonisolated static func backgroundAction(
        isAudioBackend: Bool,
        hasSoftwareHost: Bool,
        keepVideoAlive: Bool,
        state: PlaybackState
    ) -> BackgroundAction {
        if isAudioBackend { return .doNothing }
        if keepVideoAlive { return hasSoftwareHost ? .enterSoftwareAudioOnly : .doNothing }
        guard state == .playing || state == .paused else { return .doNothing }
        return .teardownVideo
    }

    /// 1 Hz diagnostics sampler. Separate ObservableObject for the same reason as `clock`: per-sample
    /// objectWillChange would re-render every engine-observing view (AetherEngine#29 follow-up).
    /// Observe only in stats overlays.
    public let diagnostics = EngineDiagnostics()

    /// Forwarder; for push updates subscribe to `diagnostics.$liveTelemetry` (objectWillChange does NOT fire).
    public var liveTelemetry: LiveTelemetry? { diagnostics.liveTelemetry }

    /// Human-readable decoder label for stats UI (e.g. "VideoToolbox HEVC (HW)", "dav1d AV1 (SW)",
    /// "libavcodec VP9 (SW)"). nil while idle; cleared in stopInternal so sessions never inherit the previous label.
    @Published public internal(set) var activeVideoDecoder: String?

    /// Human-readable audio pipeline label (e.g. "Stream-copy (EAC3+JOC Atmos)", "TrueHD → FLAC bridge",
    /// "libavcodec <codec> -> CoreAudio"). nil when no audio or no session.
    @Published public internal(set) var activeAudioDecoder: String?

    /// Decoded cues for the active subtitle source (sidecar or embedded side-demuxer). When
    /// `LoadOptions.prepareNativeSubtitles` is set, cues also flow into NativeSubtitleCueStore for mov_text injection (#55).
    @Published public internal(set) var subtitleCues: [SubtitleCue] = []
    @Published public internal(set) var isLoadingSubtitles: Bool = false
    @Published public internal(set) var isSubtitleActive: Bool = false
    /// Active primary embedded subtitle stream index (matches TrackInfo.id), or nil when subtitles are off or
    /// a sidecar (not an embedded track) is active. Mirrors `activeAudioTrackIndex` so a host picker reflects
    /// the track auto-selected by `LoadOptions.preferredSubtitleLanguages` (#73) as well as host `selectSubtitleTrack` calls.
    @Published public internal(set) var activeSubtitleTrackIndex: Int?

    /// ASS script header ([Script Info] + [V4+ Styles] + [Events] Format line) for the primary sidecar, or nil.
    /// Populated when `LoadOptions.preserveASSMarkup` is set and the file is ASS/SSA; `subtitleCues` then carry
    /// raw event lines. Hosts pair both to drive a whole-script renderer via ASSScriptBuilder (AetherEngine#48).
    /// Nil for SRT/VTT and when markup preservation is off.
    @Published public internal(set) var sidecarASSHeader: String? = nil

    /// Cues for the secondary subtitle track (#47). Text-only (bitmap rejected); independent of primary.
    @Published public internal(set) var secondarySubtitleCues: [SubtitleCue] = []
    @Published public internal(set) var isLoadingSecondarySubtitles: Bool = false
    @Published public internal(set) var isSecondarySubtitleActive: Bool = false

    /// True once the NativeSubtitleCueStore has at least one cue for the native mov_text track (#55).
    /// Use to gate the AVMediaSelection picker (PiP/AirPlay). Cleared by clearSubtitle and stopInternal.
    @Published public internal(set) var nativeSubtitleRenditionAvailable: Bool = false

    /// Ordered native mov_text subtitle tracks for the session (#55). Populated from nativeSubtitleTrackTable
    /// when `LoadOptions.prepareNativeSubtitles` is set; empty otherwise. Cleared on stop/load.
    /// Hosts use this to populate a picker and call `setNativeSubtitleSelected(track:)`.
    @Published public internal(set) var nativeSubtitleTracks: [NativeSubtitleTrack] = []

    /// Ordinal of the native subtitle rendition marked DEFAULT=YES in the master, resolved from
    /// `LoadOptions.preferredSubtitleLanguages` (fallback 0). A programmatically-selected legible track only
    /// renders if it is the master's default (AVKit's AVSmartSubtitlesController hides a non-default selection
    /// as mute-only), so a host selecting a native track for PiP should select THIS ordinal (Sodalite#32).
    @Published public internal(set) var nativeSubtitleDefaultOrdinal: Int = 0

    /// True for a live session (`LoadOptions.isLive`). Cleared in stopInternal so it can't bleed into the next VOD load.
    @Published public private(set) var isLive: Bool = false

    /// Forwarder; subscribe to `clock.$liveEdgeTime` for push (live-edge fields live on clock, not engine).
    public var liveEdgeTime: Double { clock.liveEdgeTime }
    /// Forwarder; see `clock.seekableLiveRange`.
    public var seekableLiveRange: ClosedRange<Double>? { clock.seekableLiveRange }
    /// Forwarder; see `clock.isAtLiveEdge`.
    public var isAtLiveEdge: Bool { clock.isAtLiveEdge }
    /// Forwarder; see `clock.behindLiveSeconds`.
    public var behindLiveSeconds: Double { clock.behindLiveSeconds }

    /// Fires when the live source restarted from byte 0 (e.g. a Jellyfin transcode respawn). The engine has
    /// parked the session; the host must negotiate a fresh transcode URL and call `load`. No replay; subscribe per session.
    public let liveSourceReset = PassthroughSubject<Void, Never>()

    // MARK: - Live scrub thumbnails

    /// LRU (cap 2) of FrameExtractor contexts for live scrub thumbnails. Reuses open demux/decode contexts
    /// across scrubs within the same segment; torn down in stopInternal.
    var liveThumbnailExtractors: [(segmentIndex: Int, extractor: FrameExtractor)] = []

    // MARK: - Output

    /// Fill mode of the active AVPlayerLayer or SW displayLayer in the bound AetherPlayerView.
    public var videoGravity: AVLayerVideoGravity {
        get { _videoGravity }
        set {
            _videoGravity = newValue
            // Most tvOS hosts use AVPlayerViewController, which mounts its own AVPlayerLayer.
            // Still correct for hosts that use the engine's layer directly and for the SW displayLayer.
            nativeHost?.playerLayer.videoGravity = newValue
            softwareHost?.displayLayer.videoGravity = newValue
        }
    }
    var _videoGravity: AVLayerVideoGravity = .resizeAspect

    // MARK: - Capabilities

    /// TEST-ONLY: forces every source through SoftwarePlaybackHost so the SW live+DVR path can be exercised
    /// against H.264 fixtures. Set only via `setForceSoftwarePathForTesting(_:)` from `aetherctl`.
    nonisolated(unsafe) static var forceSoftwarePathForTesting = false

    /// TEST-ONLY. Flip the SW-path override for the `aetherctl live --sw` harness; not for app use.
    public nonisolated static func setForceSoftwarePathForTesting(_ on: Bool) {
        forceSoftwarePathForTesting = on
    }

    /// TEST-ONLY: throttle source IO to simulate a slow CDN/origin (kbit/s; 0 = unlimited). Read once by
    /// each `AVIOReader` at init, so set it before `load`/`start`. Used by `aetherctl --throttle-kbps` to
    /// starve the producer below real-time and provoke AVPlayer rebuffers (e.g. the #92 open-GOP repro).
    nonisolated(unsafe) static var sourceThrottleKbpsForTesting = 0

    /// TEST-ONLY. Set the source-IO throttle for the `aetherctl --throttle-kbps` harness; not for app use.
    public nonisolated static func setSourceThrottleKbpsForTesting(_ kbps: Int) {
        sourceThrottleKbpsForTesting = max(0, kbps)
    }

    /// Reads `AVPlayer.eligibleForHDRPlayback` and `AVPlayer.availableHDRModes` at call time.
    /// macOS reports the built-in display only and may under-report external displays.
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

    /// Weak: dropping the view reference must not leak the surface through the engine singleton.
    private weak var boundView: AetherPlayerView?

    /// Bind a render surface. Attaches the active layer immediately; re-attaches on session swaps.
    /// Binding a different view detaches the old one.
    public func bind(view: AetherPlayerView) {
        if let existing = boundView, existing !== view {
            existing.detach()
        }
        boundView = view
        presentCurrentLayer()
    }

    /// Unbind a view. Idempotent.
    public func unbind(view: AetherPlayerView) {
        guard boundView === view else { return }
        view.detach()
        boundView = nil
    }

    /// Attaches nativeHost.playerLayer or softwareHost.displayLayer to the bound view. No-op when no host.
    func presentCurrentLayer() {
        guard let view = boundView else { return }
        if let host = nativeHost {
            view.attach(host.playerLayer)
        } else if let host = softwareHost {
            view.attach(host.displayLayer)
        }
    }

    // MARK: - Display + native state

    /// Programs AVDisplayManager.preferredDisplayCriteria from probed format + frame rate. No-op on iOS/macOS.
    let displayCriteria = DisplayCriteriaController()

    /// Loopback HLS-fMP4 engine. Non-nil between load and stop.
    var nativeVideoSession: HLSVideoEngine?
    /// Thread-safe starvation inputs for session-coupled FrameExtractor yield closures
    /// (#93 startup); written on load/stop and by the 1 Hz telemetry tick.
    let extractorYieldState = ExtractorYieldState()

    /// #65: thread-safe mirror of AVPlayer's rendered (playlist-axis) position, updated on the main actor by
    /// the $renderedTime sink. Read off-main by the producer when it re-anchors on a backpressure wedge.
    let renderedPositionMirror = AtomicDouble(0)

    /// #65: thread-safe mirror of AVPlayer's play intent (`timeControlStatus != .paused`), updated on the main
    /// actor by the $timeControlStatus sink. Read off-main by the producer to suspend its backpressure wedge
    /// detector while the consumer is paused (a paused player issues no forward fetch, so its frozen fetch
    /// target is not a wedge — pause false-positive). Starts true: VOD autostarts and the sink corrects it.
    let playIntentMirror = AtomicBool(true)

    /// #65: how long a native VOD seek may stay pending before the engine checks for a wedge. A normal
    /// loopback seek lands in ~1-2s and slow-but-buffering seeks refill within it; only a starved seek
    /// (no forward buffer after the budget) is reconciled.
    static let nativeSeekReconcileBudgetSeconds: Double = 8.0

    /// Native AVPlayer + AVPlayerLayer host. Non-nil between load and stop.
    var nativeHost: NativeAVPlayerHost?

    /// Combine subscriptions mirroring nativeHost's @Published into the engine. Cancelled in stopInternal.
    var nativeCancellables: Set<AnyCancellable> = []

    /// SW decode host (dav1d/libavcodec) for codecs AVPlayer can't handle (AV1 on tvOS, VP9, MPEG-2, VC-1).
    /// Non-nil between load and stop when the source routed SW.
    var softwareHost: SoftwarePlaybackHost?

    /// Combine subscriptions mirroring softwareHost's @Published. Cancelled in stopInternal.
    var softwareCancellables: Set<AnyCancellable> = []

    /// FFmpeg audio-only host (music). Mutually exclusive with nativeHost/softwareHost; stopInternal tears all down.
    var audioHost: AudioPlaybackHost?

    /// Combine subscriptions mirroring audioHost's @Published. Cleared in stopInternal.
    var audioCancellables = Set<AnyCancellable>()

    /// AVPlayer audio host. Kept alive for the engine's lifetime and reused across tracks via replaceCurrentItem:
    /// its MPNowPlayingSession must persist for stable system Now-Playing across a playlist. `audioAVPlayerActive`
    /// gates whether this is the active backend.
    var audioAVPlayerHost: AudioAVPlayerHost?
    var audioAVPlayerActive = false
    var audioNativeCancellables = Set<AnyCancellable>()

    /// Periodic memory diagnostic (30 s). Emits grep-friendly lines:
    ///   [AetherEngine] memprobe t=210s rss=412MB cache=27 subCues=0
    /// Started when state reaches .playing; cancelled in stopInternal.
    var memoryProbeTask: Task<Void, Never>?

    /// Live native reload watchdog. Armed only on live native reloads; nil for initial loads, VOD, and SW path.
    /// Cancelled in stopInternal so it can never outlive its session.
    var liveReloadWatchdogTask: Task<Void, Never>?

    /// 1 Hz live-telemetry sampler. Lifecycle mirrors memoryProbeTask. Holds a weak engine reference
    /// so the retained task can't keep self alive past teardown.
    var liveTelemetrySampler: LiveTelemetrySampler?

    /// DVR/live window tracker. Non-nil for any live session. `windowSeconds` nil means DVR disabled.
    /// Updated by `publishLiveWindow` from both the native time tick and SW host edge callback.
    var liveWindow: LiveWindow?

    /// Current session URL. Used by reloadAtCurrentPosition and AetherEngine+FrameExtractor.
    var loadedURL: URL?

    /// True for a custom IOReader source. loadedURL is a synthetic placeholder; URL-based reopens must no-op.
    /// Read by AetherEngine+FrameExtractor.
    private(set) var isCustomSource = false

    /// Retained custom IOReader. Reused on internal reloads; closed in stopInternal; nil for URL sources.
    private(set) var customReader: IOReader?

    /// Format hint for the active custom source; reused on reload and when opening clones.
    private(set) var customFormatHint: String?

    /// False for forward-only custom sources; reload features (audio switch, background reload) no-op for them.
    private(set) var customSourceIsSeekable = false

    /// Seconds the producer subtracted from source PTS so AVPlayer's raw clock sits at
    /// `source_pts - playlistShiftSeconds`. The engine folds this back before publishing, so
    /// currentTime/sourceTime always carry source PTS. Updated by HLSVideoEngine.onPlaylistShiftChanged
    /// on every producer init/restart (Matroska seek imprecision means the shift can differ per restart).
    /// 0 on SW/audio paths (no shift). See `nativeClockSeconds` for the pre-fold raw value.
    @Published public internal(set) var playlistShiftSeconds: Double = 0

    /// Raw AVPlayer clock (source_pts - playlistShiftSeconds) before shift fold. Held so
    /// onPlaylistShiftChanged can re-derive currentTime immediately on shift change. Unused on SW/audio (shift 0).
    var nativeClockSeconds: Double = 0

    /// Diagnostics only. Reads HLSVideoEngine's videoShiftPts synchronously, bypassing the async
    /// onPlaylistShiftChanged relay. A persistent gap vs `playlistShiftSeconds` means the clock is folding
    /// with a stale shift (AetherEngine#49 divergence). Poll alongside `frameAhead` when tracing divergence.
    /// 0 on SW/audio. Not for production playback logic.
    public var activeProducerShiftSeconds: Double {
        nativeVideoSession?.playlistShiftSeconds ?? 0
    }

    /// `activeProducerShiftSeconds - playlistShiftSeconds`. Positive = decoded frame ahead of currentTime.
    /// Growing value with seek count indicates AetherEngine#49 accumulation. Diagnostics only.
    public var frameAhead: Double {
        activeProducerShiftSeconds - playlistShiftSeconds
    }

    /// `currentTime - sourceTime`. Positive while a native seek is in flight: currentTime holds the seek target
    /// while sourceTime tracks AVPlayer's rendered position. This is the AetherEngine#49 divergence measured
    /// by rrgomes on-device. Distinct from `frameAhead` (producer-shift fold). Diagnostics only.
    public var clockLeadSeconds: Double {
        clock.currentTime - clock.sourceTime
    }

    /// Monotonic load/stop generation. Bumped by every stopInternal; captured after teardown; re-checked at
    /// every suspension point. Without it, a load suspended at the probe/criteria/session-start could resume
    /// after a newer load, orphan the successor's producer+loopback server, and resurrect playback after
    /// dismissal. A superseded load throws CancellationError at the first checkpoint.
    var loadGeneration: UInt64 = 0

    /// Throws CancellationError when the captured generation is stale. Callers must clean up local resources
    /// before calling; shared state belongs to the successor.
    func checkLoadCurrent(_ gen: UInt64) throws {
        guard loadGeneration == gen else {
            EngineLog.emit(
                "[AetherEngine] load superseded (gen \(gen) -> \(loadGeneration)); unwinding",
                category: .engine
            )
            throw CancellationError()
        }
    }

    /// Live program-boundary shift seam history in output-timeline order. The producer rebases immediately on
    /// reading a boundary; AVPlayer renders it ~buffer+holdback later. Each entry holds the new shift and the
    /// raw-clock position from which it applies. currentTime sink resolves the active shift by looking up the
    /// newest seam at or before the raw clock (a history, not a queue: backward DVR seeks must fold pre-seam
    /// content with pre-seam shift). Seeded with a baseline entry at -infinity. Cleared on load/stop.
    var liveShiftSeams: [(activateAt: Double, shift: Double)] = []

    /// 1 Hz live-window updater, independent of the periodic time observer (which only fires while playing).
    /// Without this, liveEdgeTime/behindLiveSeconds/isAtLiveEdge/seekableLiveRange all freeze on pause:
    /// the UI shows "at live edge" while drifting, and DVR scrubs seek against a stale edge.
    var liveWindowTimerTask: Task<Void, Never>?

    /// Source PTS of the rendered frame. Equals currentTime in steady state; holds the on-screen frame while a
    /// seek is in flight or the loopback rebuffers (issue #49). Use for subtitle overlay and side-demuxer re-arm.
    /// Equals currentTime on SW/audio (shift 0, seeks resolve synchronously). Forwarder; subscribe to `clock.$sourceTime`.
    public var sourceTime: Double { clock.sourceTime }

    /// Source-axis buffer frontier ahead of the playhead (AetherEngine#54). Forwarder; subscribe to `clock.$bufferedPosition`.
    public var bufferedPosition: Double { clock.bufferedPosition }

    /// LoadOptions from the current session. Replayed on every internal source reopen (audio-track switch,
    /// subtitle side-demuxer, background reload) so auth, matchContentEnabled, and dvh1 tag survive pipeline
    /// rebuilds. Without replay, audio-switch was silently reverting matchContentEnabled=true to false, causing
    /// HDR HEVC to route via the master playlist on a non-DV panel and surface "Öffnen fehlgeschlagen".
    /// Read by AetherEngine+FrameExtractor.
    private(set) var loadedOptions: LoadOptions = .init()

    #if DEBUG
    /// Test-only: install LoadOptions without a load (#88 unit tests exercise selection gating).
    func setLoadedOptionsForTesting(_ options: LoadOptions) { loadedOptions = options }
    #endif

    /// In-flight sidecar decode task. Cancelled on clear/track-switch to prevent stale cue overwrites.
    var sidecarTask: Task<Void, Never>?

    /// In-flight embedded subtitle reader. Runs a side Demuxer seeked to the playhead; bypasses the main HLS
    /// pump, which has already raced ~60-80s ahead and discarded subtitle packets near the visible time.
    /// Cancelled+restarted on track change, clearSubtitle, seek, and stop.
    var embeddedSubtitleTask: Task<Void, Never>?

    /// Active embedded subtitle stream index, or -1. Used by seek to decide whether to re-arm the side demuxer.
    var activeEmbeddedSubtitleStreamIndex: Int32 = -1

    /// #77: in-band CEA-608 tap state. The tap owns the cue buffer and publishes snapshots; `ccCueSnapshot`
    /// is the latest, mirrored into `subtitleCues` while the CC track is active.
    var closedCaptionTap: ClosedCaptionTap?
    var ccCueSnapshot: [SubtitleCue] = []
    var ccLastSnapshotSeq: Int = 0

    /// Secondary subtitle reader state mirrors (#47). Driven only through SubtitleChannel.secondary.
    var secondarySidecarTask: Task<Void, Never>?
    var secondaryEmbeddedSubtitleTask: Task<Void, Never>?
    var activeSecondaryEmbeddedSubtitleStreamIndex: Int32 = -1
    var secondarySubtitleSideDemuxer: Demuxer?
    /// Identity ("url#titleID") of the retained secondary side demuxer, so a same-source track switch
    /// reuses it instead of re-opening (#76 part 2). nil when none is retained.
    var secondarySubtitleSideDemuxerKey: String?

    /// Source video dimensions from the probe. Used as a bitmap-subtitle canvas fallback before the first PCS
    /// is parsed. 0 before load or when source has no video (AetherEngine#28). Also available in SourceProbe.
    public private(set) var sourceVideoWidth: Int32 = 0
    public private(set) var sourceVideoHeight: Int32 = 0

    /// MKV font attachments from the probe. Hosts write these to disk for ASS renderer font config (AetherEngine#30).
    /// Not @Published and not in SourceProbe: payloads are 10-30 MB and only playback hosts need them.
    public private(set) var fontAttachments: [FontAttachment] = []

    /// Latched at load; reused by audio-track-switch reload to re-derive activeVideoDecoder without re-probing.
    /// Reset to AV_CODEC_ID_NONE in stopInternal.
    var lastDetectedVideoCodec: AVCodecID = AV_CODEC_ID_NONE

    /// In-flight probe demuxer. Registered before the detached open so stopInternal can markClosed() it:
    /// without this, player dismissal/channel zapping left the probe reconnecting through subsequent sessions.
    private var inFlightProbeDemuxer: Demuxer?

    /// Active embedded subtitle side demuxer. Registered so cancel sites can markClosed(): Task cancellation
    /// alone is only observed between readPacket calls, so a blocked AVIO reconnect would otherwise survive stop().
    var activeSubtitleSideDemuxer: Demuxer?
    /// Identity ("url#titleID") of the retained primary side demuxer. A subtitle track switch or a seek on
    /// the same source reuses the open demuxer (skipping the network open + find_stream_info) when this
    /// matches the request; a new load / title switch / clear tears it down and clears the key (#76 part 2).
    var activeSubtitleSideDemuxerKey: String?

    /// One entry per native mov_text track in muxer-declaration order (#55). Built at load from the merged
    /// subtitleTracks (probed non-bitmap streams + load-declared external tracks, #88). sourceStreamIndex is
    /// nil for external entries, whose synthetic id lives in externalID; language is ISO 639-2. Ordinal =
    /// position in array. Empty means native subs disabled. Cleared on stop/load.
    struct NativeSubtitleTrackEntry: Sendable {
        let sourceStreamIndex: Int?
        var externalID: Int? = nil
        let language: String?
        /// Container FORCED disposition; declared as FORCED=YES on the WebVTT rendition so
        /// AVFoundation distinguishes same-language forced/full pairs.
        var isForced: Bool = false
    }
    var nativeSubtitleTrackTable: [NativeSubtitleTrackEntry] = []

    /// Last ordinal the host requested via setNativeSubtitleSelected (nil after a deselect).
    /// The #93 stage-2 recovery reload swaps AVPlayerItems and legible selection is per-item,
    /// so the reload re-applies this to keep an active rendition (PiP) rendering. Cleared with
    /// the track table on load/stop so a new session never inherits a stale selection.
    var nativeSubtitleReapplyOrdinal: Int?

    /// Whole-file decode tasks filling native stores for load-declared external tracks (#88).
    var externalNativeStoreFillTask: Task<Void, Never>? = nil

    /// Deferred lazy-reader start while a producer restart is in flight (#93 residual): the
    /// readers' side demuxer competed with the restart for the starved link. Cancelled by
    /// cancelNativeSubtitleReaders (deselect / clear / stop / load).
    var nativeSubtitleReaderDeferralTask: Task<Void, Never>? = nil

    /// #93 residual spurious-pause window: after a playbackStalled notification (or a consumer
    /// re-engage nudge), AVPlayer can drop to `.paused` with rate 0 and no wait reason WITHOUT any
    /// user action (device: stall, -15628 errorLog, fetches stop, then the pause). Latching that as
    /// a user pause kills both recovery paths (producer wedge breaker suspends, re-engage nudge
    /// aborts on play intent). Within this bounded window a `.paused` transition is re-asserted
    /// with play() instead of latched; a user pause outside recovery keeps the normal latch, and
    /// the re-assert cap lets a determined in-window user pause win after two presses.
    var stallRecoveryWindowUntil: Date = .distantPast
    var stallRecoveryReasserts = 0
    nonisolated static let stallRecoveryWindowSeconds: TimeInterval = 30
    nonisolated static let maxStallRecoveryReasserts = 3

    /// Stall-triggered re-engage watchdog (#93 residual): the producer-wedge chain needs ~60 s
    /// (park build-up + 24 s break threshold + grace) before its nudge fires; a dead consumer
    /// pipeline (-15628 signature: stall, then ZERO media fetches) is detectable within seconds
    /// of the playbackStalled notification. Cancelled on load reset; superseded by newer stalls.
    var stallReengageTask: Task<Void, Never>? = nil
    nonisolated static let stallReengageGraceSeconds: TimeInterval = 6.0

    /// Nudge a consumer that stopped requesting: a zero-tolerance seek to its own position
    /// rebuilds AVFoundation's loading pipeline (the effect a manual back-out had), play()
    /// re-asserts intent. Opens the spurious-pause window, since the nudge can bounce transport.
    func reengageStalledConsumer(position: Double, trigger: String) {
        guard let host = nativeHost, let player = currentAVPlayer,
              let item = player.currentItem else { return }
        guard player.timeControlStatus != .paused else { return }
        stallRecoveryWindowUntil = Date().addingTimeInterval(Self.stallRecoveryWindowSeconds)
        EngineLog.emit(
            "[AetherEngine] #65 re-engaging stalled AVPlayer (\(trigger)): nudge seek to "
            + "\(String(format: "%.2f", position))s",
            category: .engine
        )
        item.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        host.play()
    }

    /// Last-resort consumer revival (#93 residual): device-proven that after a -15628 errorLog
    /// the nudge seek reaches AVPlayer (rate re-asserts) yet its media loader stays dead, zero
    /// GETs follow. Only a fresh AVPlayerItem resets the loader, the same effect as the user's
    /// manual back-out. Same URL + same host (the #15 reuse path keeps AVKit/Control Center and
    /// the AVPlayer instance alive); segments are in retention so the reload serves instantly.
    /// Native subtitle rendition selection is per-item, so the host's last request is replayed
    /// onto the fresh item below (an active PiP rendition otherwise silently disappeared).
    func reloadStalledConsumerItem(position: Double) {
        guard let host = nativeHost, let player = currentAVPlayer,
              let url = (player.currentItem?.asset as? AVURLAsset)?.url else { return }
        guard player.timeControlStatus != .paused else { return }
        stallRecoveryWindowUntil = Date().addingTimeInterval(Self.stallRecoveryWindowSeconds)
        EngineLog.emit(
            "[AetherEngine] #65 nudge did not revive the consumer; reloading item at "
            + "\(String(format: "%.2f", position))s (same URL, same host)",
            category: .engine
        )
        host.load(url: url, startPosition: position)
        host.play()
        if let ordinal = nativeSubtitleReapplyOrdinal {
            EngineLog.emit(
                "[AetherEngine] #65 re-applying native subtitle ordinal=\(ordinal) after item reload",
                category: .engine
            )
            // The select path's own stall-recovery retries (#32) cover the fresh item's
            // not-ready window; the stores are already filled, so the pre-fill returns fast.
            setNativeSubtitleSelected(track: ordinal)
        }
    }

    /// Pure decision for the tcs sink (#93 residual): re-assert play() instead of latching a pause?
    nonisolated static func shouldReassertPlayDuringRecovery(
        statusIsPaused: Bool, engineStateIsPlaying: Bool,
        now: Date, windowUntil: Date, reasserts: Int
    ) -> Bool {
        statusIsPaused && engineStateIsPlaying && now < windowUntil
            && reasserts < maxStallRecoveryReasserts
    }

    #if DEBUG
    /// Test-only override for the session's restart-in-flight signal (#93 residual deferral tests).
    var testHookRestartInFlightOverride: Bool? = nil
    #endif

    #if DEBUG
    /// Test-only store override for the external instant-backfill path (#88); production reads the
    /// live session's stores.
    var testHookNativeStores: [NativeSubtitleCueStore]? = nil
    func testHookInstallNativeStores(_ stores: [NativeSubtitleCueStore]) { testHookNativeStores = stores }
    #endif

    /// External subtitle registrations by synthetic TrackInfo id (AetherEngine#88). Cleared on
    /// load()/stop() alongside subtitleTracks.
    var externalSubtitleRegistry: [Int: ExternalSubtitleTrack] = [:]
    var nextExternalSubtitleOrdinal = 0
    /// True once the host made an explicit subtitle choice this session (select / sidecar / clear).
    /// Gates the preferred-language re-run after a late external add, so a user who turned
    /// subtitles off does not get them re-enabled (#88).
    var hostExplicitSubtitleAction = false
    /// Synthetic id of the external track active on the secondary channel, nil when the secondary
    /// is off or embedded (#88).
    var activeSecondaryExternalSubtitleTrackID: Int? = nil
    /// Base for synthetic external-subtitle TrackInfo ids; far above any real AVStream index.
    public static let externalSubtitleTrackIDBase = 100_000

    /// Sodalite#32 Phase 2: source stream index of the embedded text track whose OVERLAY cues are fed
    /// by the producer's pump tap (no side demuxer). nil = tap-overlay mode off (bitmap/CC/sidecar/live
    /// selections keep the reader paths).
    var subtitleTapOverlayStreamIndex: Int32?

    /// Detached reader that decodes ALL embedded text subtitle streams in one side-demuxer pass into their
    /// ordinal's NativeSubtitleCueStore (#55, all-tracks). Parallel to embeddedSubtitleTask (which drives
    /// subtitleCues for the active track with full styling). Cancelled on stop/clear/load.
    var nativeSubtitleReadersTask: Task<Void, Never>?

    /// Abort handle for the native multi-decode side demuxer. markClosed unblocks AVIO reconnect loops
    /// (mirrors activeSubtitleSideDemuxer).
    var nativeSubtitleReadersDemuxer: Demuxer?

    /// Lazy-start params for the native subtitle readers (#15): captured at load when prepareNativeSubtitles
    /// declared the mov_text track, but the readers only start on the first setNativeSubtitleSelected (PiP),
    /// so a session that never selects a native track pays no standing side-demuxer cost. Cleared on stop/clear.
    var nativeSubtitleReaderParams: (url: URL, stores: [NativeSubtitleCueStore])?

    /// True while the running native readers were started in read-to-EOF (eager) mode (Sodalite#32).
    /// Deselect must NOT cancel such a reader (it is building whole-session coverage for the next PiP
    /// entry), and select must not replace it with a playhead-anchored parking reader.
    var nativeSubtitleReadersRunToEOF = false

    /// Per-session subtitle event log counter. Caps diagnostic output; reset on each load.
    var subtitleCueDiagnosticCount: Int = 0

    /// Trailing retention window for subtitleCues (seconds). Bounds bitmap-cue (PGS/DVB/DVD) memory:
    /// each cue retains a decoded RGBA CGImage; a 2-hr Blu-ray PGS track emits ~1500-2000 cues.
    /// 300 s covers normal pause durations and backward-scrub reach that doesn't trigger a restart;
    /// evicted cues are re-emitted after a producer restart (fresh EmbeddedSubtitleDecoder, empty dedupe set).
    let subtitleCueRetentionSeconds: Double = 300

    /// Source-PTS read-ahead limit for the embedded subtitle side demuxer. Without this gate, the demuxer races
    /// to EOF, downloading the entire source a second time and accumulating all future bitmap cues (each a RGBA
    /// CGImage); on 50-80 GB UHD remuxes this causes jetsam on Apple TV 4K (AetherEngine#31). 90 s covers the
    /// main pump's ~60-80 s lead plus network jitter; while parked, TCP backpressure throttles the subtitle
    /// connection to playback rate.
    ///
    /// CRITICAL INVARIANT (#55): must exceed bufferAheadSegments * targetSegmentDurationSeconds (currently
    /// 10 * 4 = 40 s). The producer drains NativeSubtitleCueStore when cutting each segment; if the store's
    /// park horizon is inside the buffer window, segments beyond it get no cues and the native tx3g track gaps.
    /// Verify this constraint when raising bufferAheadSegments or targetSegmentDurationSeconds.
    nonisolated static let embeddedSubtitleReadAheadSeconds: Double = 90
    /// #15: native WebVTT readers must stay ahead of AVPlayer's subtitle prefetch (~240s burst at PiP start),
    /// otherwise far segments are fetched empty and cached empty for the VOD rendition. Larger than the inline
    /// reader's 90s lead; only runs while a native rendition is selected (PiP), so the extra read is bounded.
    nonisolated static let nativeSubtitleReadAheadSeconds: Double = 300

    /// Source-time flush window for ASS cue batching (#56). Previously each event triggered a MainActor.run hop;
    /// on packet-dense tracks (hundreds of events in a few seconds) those hops serialised the demux loop against
    /// the on-MainActor renderer, causing published cues to fall far behind the playhead. Coalescing within this
    /// window decouples demux speed from MainActor pressure. Small enough that sparse tracks still flush per event,
    /// and well under the 2 s seek pre-roll so the first cue lands before the playhead.
    nonisolated static let embeddedSubtitleFlushWindowSeconds: Double = 0.5

    /// Per-flush event count cap. Handles same-timestamp bursts (span stays 0, so the window rule never trips)
    /// and NOPTS packets with no demux clock. The #56 sample had 1534 ASS events on a single pts (5.207s);
    /// at this cap that cluster publishes in ~12 hops. Sized large because same-pts bursts are far ahead of the
    /// playhead, so a bigger batch costs no display latency.
    nonisolated static let embeddedSubtitleFlushCountCap = 128

    /// Flush predicate for the embedded ASS cue batch. Pure so SubtitleBatchFlushTests can unit-test it.
    ///
    /// - `batchSpanSeconds`: demux position minus the first event's source time, or nil (NOPTS).
    ///
    /// Flushes when the batch spans >= windowSeconds (common case) or reaches countCap (same-timestamp/NOPTS).
    /// An empty batch never flushes.
    nonisolated static func shouldFlushSubtitleBatch(
        pendingCount: Int,
        batchSpanSeconds: Double?,
        windowSeconds: Double = AetherEngine.embeddedSubtitleFlushWindowSeconds,
        countCap: Int = AetherEngine.embeddedSubtitleFlushCountCap
    ) -> Bool {
        guard pendingCount > 0 else { return false }
        if pendingCount >= countCap { return true }
        if let span = batchSpanSeconds, span >= windowSeconds { return true }
        return false
    }

    // MARK: - Init

    /// Block-based observers are NOT auto-removed on dealloc; the bag removes them in its own deinit.
    /// A MainActor deinit can't touch non-Sendable stored state under Swift 6, hence the helper class.
    private let lifecycleObservers = LifecycleObserverBag()

    private final class LifecycleObserverBag: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [Any] = []
        func append(_ token: Any) {
            lock.lock(); tokens.append(token); lock.unlock()
        }
        deinit {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    public init() throws {
        // Route av_log into EngineLog before any libav* entry point so probe/load diagnostics are captured.
        FFmpegLogBridge.install()

        // Declare category + multichannel support but do NOT activate the session here.
        //
        // Issue #24: activating at launch latches the route against whatever HDMI reports at that instant.
        // With "Continuous Audio Connection" off, the link idles at stereo (output=2); no later
        // AVAudioSession call can lift that latch, causing 5.1 EAC3 to downmix. AVPlayerViewController
        // owns and activates the session for the native path, letting tvOS auto-negotiate the route.
        // SW/audio renderer paths activate via `activateRendererAudioSession()` since they bypass AVKit.
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
            try session.setSupportsMultichannelContent(true)
        } catch {
            EngineLog.emit("[AetherEngine] AVAudioSession setup error: \(error)", category: .engine)
        }
        EngineLog.emit("[AetherEngine] AVAudioSession: category set, not activated (AVKit drives activation) maxChannels=\(session.maximumOutputNumberOfChannels) output=\(session.outputNumberOfChannels)", category: .engine)
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
    /// Load media from a URL. Convenience wrapper over `load(source:)`.
    @discardableResult
    public func load(
        url: URL,
        startPosition: Double? = nil,
        options: LoadOptions = .init(),
        audioSourceStreamIndex: Int32? = nil,
        discTitleID: Int? = nil
    ) async throws -> SourceProbe? {
        try await load(
            source: .url(url),
            startPosition: startPosition,
            options: options,
            audioSourceStreamIndex: audioSourceStreamIndex,
            discTitleID: discTitleID
        )
    }

    /// Load media from a URL or a custom `IOReader`. See `MediaSource`.
    ///
    /// Custom sources: seekable readers play on both the native and
    /// software paths; forward-only readers (`seek` returns negative for
    /// SEEK_SET/CUR/END) play on the software path only. A custom source
    /// whose initial probe fails throws, since it cannot be reopened by URL.
    ///
    /// Capability for custom sources. Seekable readers support audio-track
    /// switching and background-return reload (the pipeline rebuilds on the
    /// retained reader). Embedded-subtitle selection and FrameExtractor scrub
    /// previews work when the reader implements `makeIndependentReader()` (they
    /// run a second demuxer concurrently and need an independent cursor); they
    /// no-op when it returns nil. Forward-only readers (seek returns negative)
    /// cannot rewind or, typically, clone, so those features no-op for them.
    /// Plain playback and sidecar subtitles always work.
    ///
    /// Returns the `SourceProbe` assembled from the internal probe
    /// stage (video size, codec, tracks, metadata) so hosts get the
    /// source facts without a second probe round-trip
    /// (AetherEngine#28). nil on the `nativeRemoteHLS` bypass (no
    /// probe runs there) and when the probe failed but playback
    /// proceeds anyway (URL sources can be reopened internally).
    @discardableResult
    /// - Parameter discTitleID: For a disc image (Blu-ray / DVD ISO), the title to open (id from
    ///   `discTitles`). nil opens the main title. Threaded into the probe so the chosen title is honored
    ///   on the first frame; an out-of-range id clamps to the main title. `selectTitle(id:)` and
    ///   background-resume route through here to (re)open at the right title (#67).
    public func load(
        source: MediaSource,
        startPosition: Double? = nil,
        options: LoadOptions = .init(),
        audioSourceStreamIndex: Int32? = nil,
        discTitleID: Int? = nil
    ) async throws -> SourceProbe? {
        // Preserve the NativeAVPlayerHost across native->native reloads so AVKit's system Now-Playing
        // registration survives the seam (issue #15). Captured before stopInternal resets playbackBackend;
        // the SW dispatch branch releases it if this source routes software.
        let priorBackendWasNative = (playbackBackend == .native)
        stopInternal(keepNativeHost: priorBackendWasNative)
        // Drop disc recognition memoized for the previous media. Track-switch reopens (audio / subtitle
        // side demuxer) deliberately keep it so a remote ISO is parsed once per session (#76); only a
        // genuinely new load clears it, which also keeps custom sources (shared placeholder URL) from
        // bleeding one disc's structure into the next.
        DiscReader.clearCache()
        // Capture generation; every suspension point re-checks for supersession.
        let gen = loadGeneration
        // For custom sources this is a synthetic placeholder; all I/O runs against the preopened probe demuxer.
        let url: URL
        switch source {
        case .url(let u):
            url = u
            isCustomSource = false
            customReader = nil
            customFormatHint = nil
        case .custom(let reader, let hint):
            url = URL(string: "aether-custom://source")!
            isCustomSource = true
            customReader = reader
            customFormatHint = hint
        }
        loadedURL = url
        loadedOptions = options
        isLive = options.isLive
        // nativeRemoteHLS: DVR window is unbounded (AVPlayer clamps seeks to its real seekable range);
        // an over-wide published bound only affects range width, not seek landing.
        liveWindow = options.isLive
            ? LiveWindow(windowSeconds: options.nativeRemoteHLS ? .greatestFiniteMagnitude : options.dvrWindowSeconds)
            : nil
        state = .loading
        isBuffering = false
        readerStall = .flowing
        clock.currentTime = 0
        clock.bufferedPosition = 0
        nativeClockSeconds = 0
        duration = 0
        clock.progress = 0
        audioTracks = []
        subtitleTracks = []
        externalSubtitleRegistry = [:]
        nextExternalSubtitleOrdinal = 0
        hostExplicitSubtitleAction = false
        activeSecondaryExternalSubtitleTrackID = nil
        externalNativeStoreFillTask?.cancel()
        externalNativeStoreFillTask = nil
        stallRecoveryWindowUntil = .distantPast
        stallRecoveryReasserts = 0
        stallReengageTask?.cancel()
        stallReengageTask = nil
        nativeSubtitleTrackTable = []
        nativeSubtitleReapplyOrdinal = nil
        nativeSubtitleTracks = []
        nativeSubtitleReaderParams = nil
        metadata = nil
        fontAttachments = []
        discTitles = []
        selectedDiscTitle = nil
        discChapters = []
        subtitleCueDiagnosticCount = 0
        // Reset format/dimension state so paths that skip the probe (nativeRemoteHLS) or find no video
        // don't keep publishing the predecessor's values (e.g. Live TV after an HDR10 film kept reporting .hdr10).
        videoFormat = .sdr
        sourceVideoFormat = .sdr
        sourceVideoWidth = 0
        sourceVideoHeight = 0

        // nativeRemoteHLS: skip probe + loopback; play HLS URL directly with AVPlayer (Jellyfin already serves HLS).
        // Routed before the probe because we never demux the m3u8.
        if options.nativeRemoteHLS {
            do {
                try await loadRemoteHLS(url: url, options: options)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Without this catch, a throwing loadRemoteHLS would strand state at .loading forever.
                state = .error("Failed to load: \(error.localizedDescription)")
                throw error
            }
            // No probe ran on this bypass; there is nothing to report.
            return nil
        }

        // 1. Probe: detect format, frame rate, and track metadata.
        //    HLSVideoEngine re-opens internally; the double-open keeps the failure-mode matrix small.
        var detectedFormat: VideoFormat = .sdr
        var effectiveFormat: VideoFormat = .sdr
        var detectedRate: Double? = nil
        var detectedDVProfile: Bool = false
        var detectedCodecID: AVCodecID = AV_CODEC_ID_NONE
        var probedAudioTracks: [TrackInfo] = []
        var probedSubtitleTracks: [TrackInfo] = []
        var probedDefaultAudioIndex: Int32 = -1
        let probe = Demuxer()
        // Register so stopInternal can markClosed(): avformat_open_input/find_stream_info can block for the
        // full AVIOReader reconnect budget (device repro: a 500-looping channel kept reconnecting across three
        // subsequent sessions until the budget ran out).
        inFlightProbeDemuxer = probe
        // Identity-guarded: a superseding load() has already registered its own probe; unconditioned nil here
        // would strip the successor's abort handle.
        defer { if inFlightProbeDemuxer === probe { inFlightProbeDemuxer = nil } }
        var probeOpened = false
        do {
            // Detach avformat_open_input + find_stream_info off @MainActor (~6 s on a slow CDN).
            // AetherEngine#10: a @MainActor async body without a suspension point blocks the main thread
            // despite the async signature; Task.detached.value introduces a real background hop.
            try await Task.detached(priority: .userInitiated) { [probe, source, options] in
                // Caller-bounded find_stream_info budget (#68); nil keeps the .playback default. This probe
                // demuxer is reused as the session demuxer, so the cap lands on the open that actually pays it.
                let probeProfile = DemuxerOpenProfile.playback.withProbeBudget(
                    probesize: options.probesize, maxAnalyzeDuration: options.maxAnalyzeDuration)
                switch source {
                case .url(let u):
                    // isLive configures the AVIOReader for endless-feed mode; must be set at open time because
                    // the probe demuxer is reused as the session demuxer (avformat_open_input runs only once).
                    try probe.open(url: u, extraHeaders: options.httpHeaders, profile: probeProfile, isLive: options.isLive, selectTitleID: discTitleID)
                case .custom(let reader, let formatHint):
                    // isLive suppresses SEEK_END duration estimate on forward-only live readers; same open-time requirement.
                    try probe.open(reader: reader, formatHint: formatHint, profile: probeProfile, isLive: options.isLive, selectTitleID: discTitleID)
                }
            }.value
            probeOpened = true
            let videoIdx = probe.videoStreamIndex
            if videoIdx >= 0, let stream = probe.stream(at: videoIdx) {
                detectedFormat = Self.detectVideoFormat(stream: stream)
                effectiveFormat = Self.effectiveVideoFormat(detected: detectedFormat, stream: stream)
                detectedRate = Self.detectFrameRate(stream: stream)
                // DrHurt #4 (2026-05-26): use source-detected DV, not effective-format, so codecTag=dvh1
                // asks AVDisplayManager for DV mode on every DV source. AVPlayer's HLS tone-mapper downgrades
                // DV->HDR10 when the panel can't host it; we don't pre-strip engine-side. Pairs with
                // always-emit-SUPPLEMENTAL + no-strip in HLSVideoEngine's profile81/profile84 emission.
                detectedDVProfile = (detectedFormat == .dolbyVision)
                detectedCodecID = stream.pointee.codecpar.pointee.codec_id
                sourceVideoWidth = stream.pointee.codecpar.pointee.width
                sourceVideoHeight = stream.pointee.codecpar.pointee.height
                lastDetectedVideoCodec = detectedCodecID
            }
            probedAudioTracks = probe.audioTrackInfos()
            probedSubtitleTracks = probe.subtitleTrackInfos()
            probedDefaultAudioIndex = probe.audioStreamIndex
            // Ownership transfers to loadNative/loadSoftware, which adopt the probe for reuse
            // or open fresh if the probe failed.
        } catch {
            EngineLog.emit("[AetherEngine] probe failed (\(error)); proceeding without criteria", category: .engine)
        }

        // Superseded during probe: close the local probe (detached, can block) and unwind.
        if loadGeneration != gen {
            probe.markClosed()
            if probeOpened {
                Task.detached { [probe] in probe.close() }
            }
            try checkLoadCurrent(gen)
        }

        // Custom sources have no URL to reopen from: a failed probe is fatal.
        if case .custom = source, !probeOpened {
            state = .error("Failed to load: custom source probe failed")
            throw DemuxerError.openFailed(code: -1)
        }

        // Live fail-fast: a failed probe means the AVIOReader burned its full reconnect budget.
        // Proceeding would dispatch on codec NONE and grind another ~30 s before erroring.
        if options.isLive, !probeOpened {
            state = .error("Live source unavailable")
            throw DemuxerError.openFailed(code: -5)
        }

        // Forward-only custom sources cannot rewind; audio-switch and background-reload stay no-op for them.
        customSourceIsSeekable = isCustomSource ? probe.isSourceSeekable : false

        // sourceVideoFormat = what's in the file; videoFormat = what the panel shows (published after
        // the criteria handshake; see panelHDRAfterHandshake below).
        sourceVideoFormat = detectedFormat
        audioTracks = probedAudioTracks
        subtitleTracks = probedSubtitleTracks
        // #88: load-declared external tracks join the list now, BEFORE preferred-language selection
        // and the native rendition table are built from it.
        for track in options.externalSubtitles { registerExternalSubtitleTrack(track) }
        metadata = probeOpened ? probe.mediaMetadata() : nil
        fontAttachments = probeOpened ? probe.fontAttachmentInfos() : []
        // Disc titles/chapters off the probe demuxer (post-detach, on MainActor) so the host can populate
        // a title picker. selectedDiscTitleID reflects what DiscReader.wrap actually selected (discTitleID
        // clamped to an in-range id); non-disc sources report empty/nil (#67).
        discTitles = probeOpened ? probe.discTitleInfos() : []
        discChapters = probeOpened ? probe.discChapterInfos() : []
        activeDiscTitleID = probeOpened ? probe.selectedDiscTitleID : nil
        selectedDiscTitle = activeDiscTitleID.flatMap { id in discTitles.first { $0.id == id } }
        // Content start PTS for the software-path chapter-seek base (see sourceStartSeconds). start_time is
        // AV_NOPTS_VALUE (Int64.min) when unknown; only a positive value is a real offset.
        let probedStartTime = probeOpened ? probe.formatStartTime : 0
        sourceStartSeconds = probedStartTime > 0 ? Double(probedStartTime) / Double(AV_TIME_BASE) : 0
        // Assemble SourceProbe now while the demuxer is open; ownership transfers to loadNative/loadSoftware
        // after which streams are gone (AetherEngine#28).
        let sourceProbe: SourceProbe? = probeOpened
            ? Self.makeSourceProbe(demuxer: probe, displayURL: url)
            : nil
        // Resolve the initial audio track: an explicit host override wins, else the ordered language
        // preference (#72) resolved from this single probe. selectedAudio is nil when neither applies,
        // so the session keeps its own default pick (empty preferences + no override is a behavioural
        // no-op). Passing selectedAudio into session start lets the host honor a saved language on the
        // first frame without a separate pre-probe or a selectAudioTrack reload.
        // On probe failure (probedAudioTracks empty) the override can't be validated, so honor it
        // verbatim and let the reopened session re-validate it: an explicit audioSourceStreamIndex
        // still wins (the contract), matching pre-#72 behavior where the raw override was passed through.
        let selectedAudio = Self.selectAudioIndex(
            tracks: probedAudioTracks,
            override: audioSourceStreamIndex,
            preferredLanguages: options.preferredAudioLanguages
        ) ?? (probeOpened ? nil : audioSourceStreamIndex)
        let resolvedInitialAudio = selectedAudio ?? probedDefaultAudioIndex
        activeAudioTrackIndex = resolvedInitialAudio >= 0 ? Int(resolvedInitialAudio) : nil
        let snappedRate = FrameRateSnap.snap(detectedRate ?? 0)
        EngineLog.emit("[AetherEngine] load url=\(url.absoluteString) source-format=\(detectedFormat) effective-format=\(effectiveFormat) rate=\(snappedRate.map { String(format: "%.3f", $0) } ?? "n/a")", category: .engine)

        // 1.5 Audio-only fast path: no display-criteria handshake, no video dispatch.
        //     Native sub-branch closes the probe and reopens via AVPlayer; FFmpeg sub-branch reuses the probe
        //     (required for custom sources).
        let hasVideoStream = probeOpened && probe.videoStreamIndex >= 0
        if Self.shouldUseAudioOnlyPath(audioOnlyRequested: options.audioOnly, probeOpened: probeOpened, hasVideoStream: hasVideoStream) {
            // Read codec before closing the probe; custom sources always use FFmpeg (AVPlayer can't consume a custom demuxer).
            let audioCodecID: AVCodecID = (probeOpened && resolvedInitialAudio >= 0)
                ? (probe.stream(at: resolvedInitialAudio)?.pointee.codecpar.pointee.codec_id ?? AV_CODEC_ID_NONE)
                : AV_CODEC_ID_NONE
            let useNativeAudio = !isCustomSource && Self.avPlayerCanDecodeAudio(audioCodecID)
            EngineLog.emit("[AetherEngine] audio dispatch: codec=\(audioCodecID.rawValue) -> \(useNativeAudio ? "AVPlayer" : "FFmpeg")", category: .engine)
            // A preserved video NativeAVPlayerHost from a native->native reload must be released before an audio
            // session; otherwise the old AVPlayer stays alive in currentAVPlayer and the volume setter writes into it.
            if nativeHost != nil {
                nativeHost?.tearDown()
                nativeHost = nil
                currentAVPlayer = nil
            }
            do {
                if useNativeAudio {
                    if probeOpened { probe.close() }
                    try await loadAudioNative(url: url, startPosition: startPosition, httpHeaders: options.httpHeaders, generation: gen)
                    try checkLoadCurrent(gen)
                    playbackBackend = .audio
                    activeVideoDecoder = nil
                    activeAudioDecoder = "AVPlayer"
                    videoFormat = .sdr
                    audioAVPlayerHost?.play()
                    state = .playing
                    startMemoryProbe()
                } else {
                    try await loadAudio(
                        url: url,
                        sourceHTTPHeaders: options.httpHeaders,
                        startPosition: startPosition,
                        audioSourceStreamIndex: resolvedInitialAudio >= 0 ? resolvedInitialAudio : nil,
                        preopenedDemuxer: probeOpened ? probe : nil,
                        generation: gen
                    )
                    try checkLoadCurrent(gen)
                    playbackBackend = .audio
                    activeVideoDecoder = nil
                    activeAudioDecoder = Self.softwareAudioDecoderLabel(
                        audioTracks: probedAudioTracks,
                        activeIndex: resolvedInitialAudio
                    )
                    videoFormat = .sdr
                    audioHost?.play()
                    state = .playing
                    startMemoryProbe()
                }
            } catch is CancellationError {
                // Superseded: successor owns state.
                throw CancellationError()
            } catch {
                state = .error("Failed to load: \(error.localizedDescription)")
                throw error
            }
            return sourceProbe
        }

        // Reaching here with a failed probe means a non-audioOnly URL source whose open-time probe lost to a
        // transient origin error (custom + live already fail-fast above). Don't degrade to audio-only (#78):
        // dispatch native on codec NONE (the default switch arm) with a nil preopenedDemuxer so HLSVideoEngine
        // reopens and discovers the real stream. Format/codec stay at their .sdr/NONE defaults; AVKit fires the
        // criteria from the AVPlayerItem formatDescription once the reopened stream lands.
        if !probeOpened {
            EngineLog.emit("[AetherEngine] probe failed; falling through to the native video path (HLSVideoEngine will reopen and discover the stream) rather than degrading to audio-only", category: .engine)
        }

        // 2. Display-criteria handshake. Use effective format so a non-DV panel isn't asked to switch to dvh1.
        if !options.suppressDisplayCriteria {
            let codecTag: FourCharCode? = detectedDVProfile ? 0x64766831 : nil
            let willSwitch = displayCriteria.apply(
                format: effectiveFormat,
                frameRate: snappedRate,
                codecTag: codecTag,
                omitColorExtensions: options.omitCriteriaColorExtensions
            )
            if willSwitch {
                await displayCriteria.waitForSwitch()
                // Superseded during panel handshake: close local probe and unwind.
                if loadGeneration != gen {
                    probe.markClosed()
                    if probeOpened {
                        Task.detached { [probe] in probe.close() }
                    }
                    try checkLoadCurrent(gen)
                }
            }
        }

        // 2.5. Post-handshake panel-mode snapshot.
        //      tvOS exposes only one combined isDisplayCriteriaMatchingEnabled toggle; no API distinguishes
        //      Match Dynamic Range from Match Frame Rate. A user with rate-only matching reports the flag true,
        //      host passes matchContentEnabled=true, but the panel stays SDR. The old supportsHDR gate routed
        //      via the master playlist with VIDEO-RANGE=PQ and AVPlayer rejected -11848/-11868.
        //
        //      Reading currentEDRHeadroom after waitForSwitch is the only authoritative check: headroom > 1.0
        //      means the panel accepted HDR (range matching on); == 1.0 means refused. Pass to both videoFormat
        //      and HLSVideoEngine master-vs-media routing so they stay in step.
        //
        //      Suppressed-criteria hosts fall back to the caller's pre-load panelIsInHDRMode snapshot
        //      (AVKit fires criteria later from the AVPlayerItem formatDescription).
        let panelHDRAfterHandshake: Bool
        if options.suppressDisplayCriteria {
            panelHDRAfterHandshake = options.panelIsInHDRMode
        } else {
            panelHDRAfterHandshake = displayCriteria.currentPanelIsHDR()
        }
        #if os(iOS)
        // The iPhone built-in display has no HDMI Match-Content handshake; it renders HDR/DV natively
        // whenever the system reports it eligible. effectiveFormat is already clamped to displayCapabilities
        // (the same signal that drives the served DV/HDR stream), so publish it directly. Gating on
        // panelHDRAfterHandshake (false on iOS, kept for media-playlist routing) wrongly relabelled every
        // HDR/DV title as SDR in Stats for Nerds.
        videoFormat = effectiveFormat
        #else
        videoFormat = (effectiveFormat != .sdr && panelHDRAfterHandshake)
            ? effectiveFormat
            : .sdr
        #endif

        // 3. Dispatch by codec.
        //    Native: HEVC/H.264 (unconditional) and AV1 on platforms with HW decode (iOS 17+/macOS 14+).
        //    SW (SoftwarePlaybackHost / dav1d / libavcodec):
        //    - AV1 on tvOS: no Apple-shipped dav1d, no HW AV1 on any Apple TV chip.
        //    - VP9/VP8: AVPlayer's HLS manifest parser rejects vp09/vp8 CODECS attributes even when VT can
        //      HW-decode VP9 (verified via aetherctl: item.status never leaves .unknown).
        //    - MPEG-4 Part 2, MPEG-2, VC-1: not in the HLS Authoring Spec CODECS list; libavcodec handles all.
        var useSoftwarePath: Bool
        switch detectedCodecID {
        case AV_CODEC_ID_AV1:
            useSoftwarePath = !VTCapabilityProbe.av1Available
        case AV_CODEC_ID_VP9,
             AV_CODEC_ID_VP8,
             AV_CODEC_ID_MPEG4,
             AV_CODEC_ID_MPEG2VIDEO,
             AV_CODEC_ID_VC1:
            useSoftwarePath = true
        default:
            useSoftwarePath = false
        }
        // Forward-only custom sources can't serve the native path's seeks (cue prewarm, segment seeks).
        // Live custom sources are exempt: the live producer never seeks backward, scrub previews come from the
        // DVR segment cache, and audio-switch is already no-op for forward-only sources.
        if isCustomSource && !probe.isSourceSeekable && !options.isLive {
            useSoftwarePath = true
            EngineLog.emit("[AetherEngine] custom source is forward-only, forcing software path", category: .engine)
        }
        // TEST-ONLY: forces SW path for aetherctl live --sw; unset in shipping builds.
        if Self.forceSoftwarePathForTesting {
            useSoftwarePath = true
            EngineLog.emit("[AetherEngine] TEST override: forcing software path", category: .engine)
        }
        EngineLog.emit("[AetherEngine] dispatch: codec=\(detectedCodecID.rawValue) → \(useSoftwarePath ? "software" : "native")", category: .engine)

        // Demuxed-audio live ingest is native-path-only (side-demuxer merge lives in HLSSegmentProducer).
        // A demuxed-audio source routed SW would play silent; fail fast so the host falls back to server-muxed.
        if useSoftwarePath, options.isLive,
           (customReader as? LiveIngestSourceInfo)?.companionAudioReader != nil,
           probe.audioStreamIndex < 0 {
            probe.markClosed()
            Task.detached { [probe] in probe.close() }
            EngineLog.emit(
                "[AetherEngine] demuxed-audio live source routed to the software path "
                + "(codec=\(detectedCodecID.rawValue)); side-audio merge is native-only, failing fast",
                category: .engine
            )
            state = .error("Demuxed-audio live source not supported on this codec path")
            throw HLSIngestError.demuxedAudioNotSupported
        }

        do {
            if useSoftwarePath {
                // SW path reuses the probe demuxer (single AVFormatContext open); do not close here.
                // Release a preserved NativeAVPlayerHost from a native->native reload: the SW pipeline
                // renders into its own layer and currentAVPlayer must publish nil to drop AVKit's stale player.
                if nativeHost != nil {
                    nativeHost?.tearDown()
                    nativeHost = nil
                    currentAVPlayer = nil
                }
                try await loadSoftware(
                    url: url,
                    sourceHTTPHeaders: options.httpHeaders,
                    startPosition: startPosition,
                    audioSourceStreamIndex: selectedAudio,
                    isLive: options.isLive,
                    dvrWindowSeconds: options.dvrWindowSeconds,
                    preopenedDemuxer: probeOpened ? probe : nil,
                    generation: gen
                )
                playbackBackend = .software
                activeVideoDecoder = Self.videoDecoderLabel(
                    codecID: detectedCodecID, isSoftware: true
                )
                activeAudioDecoder = Self.softwareAudioDecoderLabel(
                    audioTracks: probedAudioTracks,
                    activeIndex: resolvedInitialAudio
                )
                presentCurrentLayer()
                softwareHost?.play()
                state = .playing
                startMemoryProbe()
                startLiveTelemetrySampler()
            } else {
                // Native path: pass the probe Demuxer to loadNative so HLSVideoEngine.start() skips
                // avformat_open_input + find_stream_info (~1-3 s saved on slow CDN). The cue prewarm
                // seek inside start() invalidates any stale read position. Pass nil if probe failed.
                try await loadNative(
                    url: url,
                    sourceHTTPHeaders: options.httpHeaders,
                    startPosition: startPosition,
                    audioSourceStreamIndex: selectedAudio,
                    keepDvh1TagWithoutDV: options.keepDvh1TagWithoutDV,
                    matchContentEnabled: options.matchContentEnabled,
                    panelIsInHDRMode: panelHDRAfterHandshake,
                    audioBridgeMode: options.audioBridgeMode,
                    isLive: options.isLive,
                    dvrWindowSeconds: options.dvrWindowSeconds,
                    // Set only by reloadAtCurrentPosition's live reopen:
                    // the host must skip its initial seek so AVPlayer
                    // joins the rebuilt (possibly backlog-bearing)
                    // playlist at its own live edge. Hosts cannot set
                    // this; fresh joins keep the verified seek-to-0.
                    liveRejoin: options.isLiveRejoin,
                    preopenedDemuxer: probeOpened ? probe : nil,
                    generation: gen
                )
                playbackBackend = .native
                activeVideoDecoder = Self.videoDecoderLabel(
                    codecID: detectedCodecID, isSoftware: false
                )
                // Audio label comes from HLSVideoEngine's stream-copy/FLAC-bridge cascade.
                activeAudioDecoder = nativeVideoSession?.audioPipelineDescription
                // Reconcile published audioTracks with the session's real pick (side-demuxer tracks for
                // demuxed-audio sources). Without this a post-load language check would reload the track already playing.
                syncPublishedAudioStateFromNativeSession()
                presentCurrentLayer()
                // Gate play() on panel handshake. With appliesPreferredDisplayCriteriaAutomatically=true,
                // AVKit drives the criteria write from the live AVPlayerItem's formatDescription (reads dvcC
                // via private CoreMedia hooks). waitForSwitch Stage 1 gives AVKit time to fire that write;
                // Stage 2 waits for the panel to settle so the first frame doesn't hit a mid-transition panel.
                // Critical for DV P5 (no HDR10 base, requires immediate DV mode).
                await displayCriteria.waitForSwitch()
                try checkLoadCurrent(gen)
                // automaticallyWaitsToMinimizeStalling=true (default) handles play-before-ready.
                nativeHost?.play()
                state = .playing
                startMemoryProbe()
                startLiveTelemetrySampler()
            }
        } catch is CancellationError {
            // Superseded.
            throw CancellationError()
        } catch {
            state = .error("Failed to load: \(error.localizedDescription)")
            throw error
        }
        // Honor a saved subtitle-language preference on the first frame (#73). Runs only on the successful
        // video path (the audio-only branch returns earlier and renders no subtitles); a no-op when the
        // preference list is empty, no track matches, or the host already activated one.
        applyPreferredSubtitleSelection(startAnchor: startPosition, sourceDuration: sourceProbe?.durationSeconds)
        return sourceProbe
    }

    // MARK: - Transport

    /// Current transport owner. Priority: audio-AVPlayer -> FFmpeg audio -> software -> native.
    /// Centralised so priority can't drift across call sites.
    private var activeTransportHost: (any TransportControllable)? {
        if audioAVPlayerActive, let host = audioAVPlayerHost { return host }
        if let host = audioHost { return host }
        if let host = softwareHost { return host }
        return nativeHost
    }

    public func play() {
        activeTransportHost?.play()
        if state == .paused || state == .loading {
            state = .playing
        }
        clampLiveResumeIfBehindWindow()
    }

    public func pause() {
        activeTransportHost?.pause()
        isBuffering = false
        if state == .playing {
            state = .paused
        }
        #if os(iOS)
        // Paused while backgrounded with no PiP: the app will idle-suspend, so release the video pipeline
        // now (wedge-safe, mirrors the unconditional background teardown). Audio backends are already spared.
        if isBackgrounded && !pictureInPictureActive && !audioAVPlayerActive && audioHost == nil && softwareHost == nil {
            Task { @MainActor in await self.teardownVideoForBackground() }
        }
        #endif
    }

    public func togglePlayPause() {
        // Only togglable from steady states + .loading ("start"). Ignore in .seeking/.error/.idle.
        switch state {
        case .playing, .paused, .loading: break
        default: return
        }
        // Read the LIVE AVPlayer state, not the published `state`. AVKit/Control Center/hardware button can
        // toggle AVPlayer directly; the $timeControlStatus reconciliation is async, so a fast press on a stale
        // value would no-op. SW/audio hosts have no competing transport owner so `state` is authoritative there.
        let isPlaying: Bool
        if let nativeHost, !audioAVPlayerActive && audioHost == nil && softwareHost == nil {
            isPlaying = nativeHost.isEffectivelyPlaying
        } else {
            isPlaying = (state == .playing)
        }
        if isPlaying { pause() } else { play() }
    }

    /// Tear down and reload from the current position. Call after background return; tvOS invalidates
    /// AVIO connections and VT sessions on suspension.
    public func reloadAtCurrentPosition() async throws {
        if isCustomSource {
            // Rebuild on retained reader (seekable only); no URL to reopen.
            guard customSourceIsSeekable, let placeholderURL = loadedURL else { return }
            await reloadWithAudioOverride(
                url: placeholderURL,
                audioStreamIndex: activeAudioTrackIndex.map { Int32($0) },
                expectedGeneration: loadGeneration
            )
            return
        }
        guard let url = loadedURL else { return }
        let pos = currentTime
        // Snapshot the disc title before load()'s stopInternal wipes it, so a background-resumed disc image
        // keeps the title the user selected instead of reverting to the main title (#67).
        let titleID = activeDiscTitleID
        // Live: rejoin at the live edge; pre-suspend playhead is stale and may have slid out of the window.
        let resume: Double? = LiveReloadPolicy.resumePosition(
            isLive: loadedOptions.isLive, currentTime: pos)
        // isLiveRejoin tells loadNative to skip the initial seek: the rebuilt playlist can have a multi-segment
        // backlog where the fresh-join contract (seg0 == live edge) no longer holds.
        var options = loadedOptions
        options.isLiveRejoin = options.isLive
        try await load(url: url, startPosition: resume, options: options, discTitleID: titleID)
        // Arm the watchdog so a live reopen whose AVPlayer never becomes ready fails visibly instead of freezing.
        if options.isLive, !options.nativeRemoteHLS, playbackBackend == .native {
            armLiveReloadWatchdog(generation: loadGeneration)
        }
    }

    public func seek(to seconds: Double) async {
        // Guard: a host scrub racing stop() must not flip an idle/error engine to .seeking -> .playing.
        // .ended is terminal too: after end-of-media the host reloads to replay, it does not scrub a parked session.
        switch state {
        case .idle, .ended, .error:
            EngineLog.emit("[AetherEngine] seek(to:\(seconds)) ignored: no active session (state=\(state))", category: .engine)
            return
        case .loading:
            // No hosts yet; body would no-op but still flip state to .playing, dropping the host's spinner early.
            EngineLog.emit("[AetherEngine] seek(to:\(seconds)) ignored: load in progress", category: .engine)
            return
        default:
            break
        }
        // Live-only (no DVR): no rewind range; AVPlayer would stall or land on an unmaterialised segment.
        // Hosts should hide the scrubber when seekableLiveRange == nil; this guard is defence-in-depth.
        if isLive {
            guard let w = liveWindow, w.windowSeconds != nil else {
                EngineLog.emit("[AetherEngine] seek(to:\(seconds)) ignored: live, DVR disabled", category: .engine)
                return
            }
        }
        // VOD: clamp to [0, duration] in source PTS. Live/DVR: clamp to the
        // window's session-relative seekable range.
        let target: Double = isLive ? (liveWindow?.clamp(seconds) ?? seconds) : max(0, min(seconds, duration))
        state = .seeking
        // Span isSeeking across the real landing, not just the optimistic .playing flip (#38).
        // Generation guard at each finalize point prevents a superseded seek from clearing it.
        seekGeneration &+= 1
        let seekGen = seekGeneration
        setProgrammaticSeek(inFlight: true, target: target)
        // Capture loadGeneration so the live finalize can detect a concurrent stop()/load()/zap
        // (which bumps loadGeneration in stopInternal but leaves seekGeneration untouched), matching
        // the VOD guard below. Without it a superseded live seek writes clock/state onto a torn-down session.
        let loadGen = loadGeneration
        if isLive {
            // Live/DVR native: translate session-time target into AVPlayer live clock via behind-delta
            // (robust if the edge advances between publish tick and seek; collapses to clockTarget = target - shift).
            // Live SW: drive the host's ring-backed DVR reseed directly; no AVPlayer-clock translation applies.
            if softwareHost != nil, nativeHost == nil {
                EngineLog.emit("[AetherEngine] SW live seek target=\(target)", category: .engine)
                await softwareHost?.seek(to: target)
                guard loadGeneration == loadGen, seekGeneration == seekGen else { return }
                clock.currentTime = target
                clock.sourceTime = target
                state = .playing
                setProgrammaticSeek(inFlight: false, target: nil)
                return
            }
            let behind = (liveWindow?.edgeTime ?? target) - target   // >= 0; 0 == "to the edge"
            let clockTarget = max(0, (nativeHost?.seekableEnd ?? 0) - behind)
            EngineLog.emit("[AetherEngine] live seek target=\(target) behind=\(behind) seekableEnd=\(nativeHost?.seekableEnd ?? 0) clockTarget=\(clockTarget)", category: .engine)
            // Publish target up front to hold the scrub clock while the host suppresses stale pre-seek reads.
            // Only currentTime takes the optimistic target; sourceTime stays on the rendered frame (#49).
            nativeClockSeconds = clockTarget
            clock.currentTime = target
            await nativeHost?.seek(to: clockTarget)
            guard loadGeneration == loadGen, seekGeneration == seekGen else { return }
            nativeClockSeconds = clockTarget
            clock.currentTime = target
            clock.sourceTime = target
            // publishLiveWindow on the next tick recomputes behindLiveSeconds.
            state = .playing
            setProgrammaticSeek(inFlight: false, target: nil)
            return
        }
        // Convert source-PTS target to AVPlayer's HLS clock (source - playlistShiftSeconds).
        // SW/audio hosts run on source time (shift 0), so the conversion is a no-op there.
        let clockTarget = target - playlistShiftSeconds
        let gen = loadGeneration
        // Publish the native-path seek target up front so the scrub clock snaps immediately (#37); the host
        // suppresses periodic-observer reads until landing. SW/audio hosts resolve synchronously and write
        // the clock only at finalize.
        let nativeOnly = !audioAVPlayerActive && audioHost == nil && softwareHost == nil && nativeHost != nil
        if nativeOnly {
            // Optimistic scrub clock; sourceTime holds the rendered frame via $renderedTime sink until landing (#49).
            nativeClockSeconds = clockTarget
            clock.currentTime = target
        }
        if audioAVPlayerActive, let host = audioAVPlayerHost {
            await host.seek(to: clockTarget)
        } else if let host = audioHost {
            await host.seek(to: clockTarget)
        } else if let host = softwareHost {
            await host.seek(to: clockTarget)
        } else {
            // Await real AVPlayer landing so isSeeking spans it (#37/#38), but bound the wait (#65): a seek
            // AVPlayer can never land (producer-wedge starvation) must not leave the optimistic clock latched
            // forever. A normal/slow-but-buffering seek lands or keeps buffering well within the budget.
            let landed = await nativeHost?.seek(to: clockTarget,
                                                deadlineSeconds: Self.nativeSeekReconcileBudgetSeconds) ?? true
            if !landed {
                // Deadline expired. Only the surviving (winning) generation reconciles; a superseded seek
                // returns at the guard below and lets the newer seek own the final state.
                guard loadGeneration == gen, seekGeneration == seekGen else { return }
                if let host = nativeHost,
                   host.isEffectivelyPlaying, // #65: a paused seek lands while paused and is not a wedge; only reconcile a starved seek the player actually wants to play
                   seekIsWedged(renderedTime: host.renderedTime, bufferedEnd: host.bufferedEnd) {
                    // Genuine wedge: snap the clock back to AVPlayer's REAL rendered position (not the
                    // unreachable optimistic target) and re-anchor the producer there.
                    let avpReal = host.renderedTime
                    nativeClockSeconds = avpReal
                    clock.currentTime = avpReal + playlistShiftSeconds
                    clock.sourceTime = avpReal + playlistShiftSeconds
                    setProgrammaticSeek(inFlight: false, target: nil)
                    // Hand state to AVPlayer's ACTUAL transport status, not the phantom .playing the normal
                    // finalize forces nor the stuck .seeking we entered with: the $timeControlStatus sink is
                    // gated on state already being .playing/.paused, so leaving .seeking would latch it there
                    // forever even after the producer re-anchor recovers playback.
                    state = (host.timeControlStatus == .paused) ? .paused : .playing
                    isBuffering = host.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    reanchorProducerToPlaylistTime(avpReal)
                    EngineLog.emit(
                        "[AetherEngine] #65 seek did not land within \(Self.nativeSeekReconcileBudgetSeconds)s "
                        + "and AVPlayer is starved (rendered=\(String(format: "%.2f", avpReal))s "
                        + "buffered=\(String(format: "%.2f", host.bufferedEnd))s); reconciled clock to rendered "
                        + "position and re-anchored producer",
                        category: .engine
                    )
                    return
                }
                // Slow-but-buffering: preserve the #37/#38 await-real-landing contract.
                await nativeHost?.seek(to: clockTarget)
            }
        }
        // Guard: stop/load during the await tore the session down; writing clock state would publish a phantom.
        // A superseding seek owns the final state.
        guard loadGeneration == gen, seekGeneration == seekGen else { return }
        nativeClockSeconds = clockTarget
        clock.currentTime = target
        clock.sourceTime = target

        // Re-arm the embedded subtitle side demuxer at the new playhead.
        if activeEmbeddedSubtitleStreamIndex >= 0, let url = loadedURL {
            let streamIdx = activeEmbeddedSubtitleStreamIndex
            // #77: in-band CC is fed by the producer CC tap, which rides the producer across the seek.
            // Clear the on-screen caption now so a pre-seek cue can't linger (symmetric with the side-demuxer
            // branch below), then tell the tap to drop stale decoder/cue state at this discontinuity; it
            // republishes as the re-anchored producer re-pumps. No side demuxer to re-arm.
            if activeSubtitleStreamIsClosedCaption(streamIdx) {
                subtitleCues = []
                ccCueSnapshot = []
                closedCaptionTap?.requestReset()
            } else if subtitleTapOverlayStreamIndex == streamIdx {
                // Sodalite#32 Phase 2: tap-fed overlay; nothing to re-arm, the tap rides the producer
                // across the seek. Re-backfill from the store so earlier-pruned cues reappear.
                subtitleCues = tapOverlayBackfill(streamIndex: streamIdx)
            } else {
                subtitleCues = []
                // startEmbeddedSubtitleTask cancels + drains the prior reader, then reuses the open side demuxer
                // and just re-seeks it to the new playhead (URL sources); no re-open on a seek (#76 part 2).
                // Custom sources: clone the reader; skip re-arm if the reader can't produce a clone (forward-only).
                if isCustomSource {
                    if let clone = customReader?.makeIndependentReader() {
                        startEmbeddedSubtitleTask(url: url, reader: clone, formatHint: customFormatHint, streamIndex: streamIdx, startAt: target)
                    }
                } else {
                    startEmbeddedSubtitleTask(url: url, reader: nil, formatHint: nil, streamIndex: streamIdx, startAt: target)
                }
            }
        }

        // Re-arm the secondary embedded subtitle track (#47).
        if activeSecondaryEmbeddedSubtitleStreamIndex >= 0, let url = loadedURL {
            let streamIdx = activeSecondaryEmbeddedSubtitleStreamIndex
            secondarySubtitleCues = []
            if isCustomSource {
                if let clone = customReader?.makeIndependentReader() {
                    startEmbeddedSubtitleTask(url: url, reader: clone, formatHint: customFormatHint, streamIndex: streamIdx, startAt: target, channel: .secondary)
                }
            } else {
                startEmbeddedSubtitleTask(url: url, reader: nil, formatHint: nil, streamIndex: streamIdx, startAt: target, channel: .secondary)
            }
        }

        // Seek has physically landed.
        state = .playing
        setProgrammaticSeek(inFlight: false, target: nil)
    }

    /// #65: re-base the loopback producer onto AVPlayer's real (playlist-axis) position after a seek-deadline
    /// wedge reconcile, so the segments AVPlayer is starved for get produced. requestRestart does blocking
    /// teardown (old.stop + waitForFinish up to 5s) and is designed to run off-main, so dispatch it detached.
    private func reanchorProducerToPlaylistTime(_ seconds: Double) {
        guard let session = nativeVideoSession else { return }
        Task.detached {
            let idx = session.segmentIndexForPlaylistTime(seconds)
            // #79: authoritative re-anchor. `seconds` is AVPlayer's REAL rendered position (the clock was
            // just reconciled to it), so it must win the coalescer over any stale in-flight scrub target.
            // Without this a burst-tail scrub overrode it and the producer stayed ~1600s off the playhead.
            session.requestRestart(at: idx, authoritative: true)
        }
    }

    /// Deprecated alias. The engine clock is now unified onto source PTS; prefer `seek(to:)` in new code.
    @available(*, deprecated, renamed: "seek(to:)")
    public func seek(toSourceTime seconds: Double) async {
        await seek(to: seconds)
    }

    public func stop() {
        stopInternal()
        state = .idle
        clock.currentTime = 0
        clock.bufferedPosition = 0
        clock.progress = 0
        // Clear session state; without this, metadata/track lists/format/pendingExternalMetadata from the
        // previous session survive until the next load and bleed into unrelated sessions.
        duration = 0
        metadata = nil
        audioTracks = []
        subtitleTracks = []
        externalSubtitleRegistry = [:]
        nextExternalSubtitleOrdinal = 0
        hostExplicitSubtitleAction = false
        activeSecondaryExternalSubtitleTrackID = nil
        externalNativeStoreFillTask?.cancel()
        externalNativeStoreFillTask = nil
        // Font attachments are session-scoped but must survive stopInternal (audio-track-switch skips the probe;
        // clearing in stopInternal would leave the session with an empty font list after any audio switch).
        fontAttachments = []
        videoFormat = .sdr
        sourceVideoFormat = .sdr
        sourceVideoWidth = 0
        sourceVideoHeight = 0
        pendingExternalMetadata = []
        // Clear loadedURL on public stop() so reloadAtCurrentPosition can't resurrect the URL after dismissal
        // and selectSubtitleTrack can't spawn a side demuxer against a stopped session.
        loadedURL = nil
        isCustomSource = false
        customSourceIsSeekable = false
    }

    /// Active AVPlayer on the native path, nil on SW path or when idle. Published so hosts driving an
    /// AVPlayerViewController can rebind `.player` on every audio-track reload (one-shot assignment goes stale).
    @Published public internal(set) var currentAVPlayer: AVPlayer? {
        didSet { observeExternalPlayback() }
    }

    /// AirPlay (#86, DrHurt): true while the native AVPlayer reports external playback. loadNative reads it to
    /// serve the loopback over the device's LAN IP (the receiver can't reach 127.0.0.1) AND to force the MEDIA
    /// playlist (AVPlayer rejects a DV/HDR MASTER playlist on an SDR receiver and won't auto-switch, DrHurt).
    /// Loopback native path only; a remote-HLS source is already receiver-reachable, so it's left untouched.
    private(set) var airPlayActive = false
    private var externalPlaybackObservation: NSKeyValueObservation?

    private func observeExternalPlayback() {
        externalPlaybackObservation?.invalidate()
        externalPlaybackObservation = nil
        guard let player = currentAVPlayer else { return }
        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, change in
            let active = change.newValue ?? false
            Task { @MainActor in self?.handleExternalPlaybackChange(active: active) }
        }
    }

    private func handleExternalPlaybackChange(active: Bool) {
        guard active != airPlayActive else { return }
        airPlayActive = active
        // Loopback native path only: remote-HLS is already receiver-reachable. Reload so loadNative rebuilds
        // the playback URL on the LAN IP + media playlist (active) or back on 127.0.0.1 master/media (inactive).
        guard playbackBackend == .native, !loadedOptions.nativeRemoteHLS, loadedURL != nil else { return }
        EngineLog.emit("[AirPlay] external playback \(active ? "active -> LAN media reload" : "ended -> loopback reload")", category: .engine)
        Task { try? await reloadAtCurrentPosition() }
    }

    /// AirPlay loopback URL (#86): rewrite the loopback playback URL to the device's LAN IP and force the MEDIA
    /// playlist, so the receiver reaches the engine-processed stream and isn't handed a DV/HDR master it rejects
    /// on an SDR panel (DrHurt). nil if no LAN IP (caller keeps the original 127.0.0.1 URL).
    func airPlayPlaybackURL(base: URL) -> URL? {
        guard let lanIP = HLSLocalServer.localActiveIPAddress() else { return nil }
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)
        c?.host = lanIP
        c?.path = "/media.m3u8"
        return c?.url
    }

    #if os(tvOS) || os(iOS)
    /// MPNowPlayingSession for the active AVPlayer audio path, or nil. The host registers transport commands
    /// and writes metadata here to stay the active Now-Playing app across a background pause (tvOS drops a
    /// paused bare AVPlayer, killing the Home badge and remote play route). See AudioAVPlayerHost.
    public var audioNowPlayingSession: MPNowPlayingSession? {
        audioAVPlayerActive ? audioAVPlayerHost?.nowPlayingSession : nil
    }
    #endif

    /// Staged externalMetadata applied to the AVPlayerItem before replaceCurrentItem. Survives across native
    /// loads so audio-track-switch and background reopen replays the metadata.
    var pendingExternalMetadata: [AVMetadataItem] = []

    /// Stage AVKit externalMetadata for the on-screen info pane (video path / AVPlayerViewController). On the video
    /// path AVKit also republishes it as Now-Playing Info. The bare-AVPlayer audio path has no AVPlayerViewController,
    /// so for system Now-Playing on that path use `setAudioNowPlayingInfo` instead. Safe to call before load();
    /// items are replayed at host creation.
    public func setExternalMetadata(_ items: [AVMetadataItem]) {
        pendingExternalMetadata = items
        nativeHost?.setExternalMetadata(items)
        audioAVPlayerHost?.setExternalMetadata(items)
    }

    #if os(iOS) || os(tvOS)
    /// Staged per-item Now-Playing dictionary for the audio AVPlayer path. Replayed at host creation.
    var pendingAudioNowPlayingInfo: [String: Any] = [:]

    /// Stage the system Now-Playing dictionary for the audio AVPlayer path (MPMediaItemProperty /
    /// MPNowPlayingInfoProperty keys, including the host's already-force-decoded, @Sendable-wrapped MPMediaItemArtwork).
    /// The host owns the AVPlayer session with auto-publish ON; this is written to the per-item
    /// AVPlayerItem.nowPlayingInfo (the documented, queue-safe channel) and the session merges in the player-derived
    /// elapsed/rate/duration. Supplying a valid artwork keeps the system from falling back to the asset's embedded
    /// cover. Pass an empty dict to clear. Safe before load(); replayed at host creation.
    public func setAudioNowPlayingInfo(_ info: [String: Any]) {
        pendingAudioNowPlayingInfo = info
        audioAVPlayerHost?.setNowPlayingInfo(info)
    }
    #endif

    /// Playback volume (0.0-1.0). Routes to the active host only; writing all hosts changed subsequent music
    /// sessions. Remembered by `desiredVolume` so a pre-session write (e.g. app-init restore) isn't a no-op.
    public var volume: Float {
        get { activeTransportHost?.volume ?? desiredVolume ?? 1.0 }
        set {
            desiredVolume = newValue
            activeTransportHost?.volume = newValue
        }
    }

    var desiredVolume: Float?

    func applyDesiredVolume(to host: any TransportControllable) {
        if let v = desiredVolume { host.volume = v }
    }

    /// Maximum reliable forward rate: 3x for audio-only sessions, 2x for video.
    /// Above the cap AVPlayer fast-forward becomes unstable (AetherEngine#39).
    /// Hosts should size their speed picker against this. Query after load; returns 2.0 while idle.
    public var maxSupportedRate: Float {
        (audioAVPlayerActive || audioHost != nil) ? 3.0 : 2.0
    }

    /// Set playback speed. Clamped to `maxSupportedRate` (AetherEngine#39). 0 pauses.
    /// Native path: pitch-corrected via audioTimePitchAlgorithm. SW path: no pitch correction.
    public func setRate(_ rate: Float) {
        let cap = maxSupportedRate
        let clamped = min(rate, cap)
        if clamped != rate {
            EngineLog.emit("[AetherEngine] setRate(\(rate)) clamped to \(clamped) (max supported on this path)", category: .engine)
        }
        activeTransportHost?.setRate(clamped)
    }

    // MARK: - Audio / subtitle track selection

    /// Switch the active audio track mid-playback. Restarts the HLS pipeline with the new audio stream;
    /// expects ~0.5-1 s black frame (AVPlayer.replaceCurrentItem tears the surface). Display-criteria handshake
    /// is suppressed (video unchanged). `index` is the container stream index (TrackInfo.id). No-op if
    /// out-of-range, pointing at a non-audio stream, or already active.
    public func selectAudioTrack(index: Int) {
        // Forward-only custom sources (incl. live HLS-ingest) can't rewind; rebuilding would re-consume a
        // drained FIFO and stall silently. Logged so a picker that does nothing is explainable.
        if isCustomSource && !customSourceIsSeekable {
            EngineLog.emit(
                "[AetherEngine] selectAudioTrack(\(index)) ignored: forward-only custom "
                + "source cannot rebuild its pipeline (live ingest / demuxed-audio "
                + "sessions switch tracks only via a fresh load)",
                category: .engine
            )
            return
        }
        guard let url = loadedURL else { return }
        guard audioTracks.contains(where: { $0.id == index }) else {
            EngineLog.emit(
                "[AetherEngine] selectAudioTrack: index=\(index) not in audioTracks (\(audioTracks.map { $0.id })), ignored",
                category: .engine
            )
            return
        }
        if activeAudioTrackIndex == index { return }

        EngineLog.emit(
            "[AetherEngine] selectAudioTrack: scheduling switch to stream \(index)",
            category: .engine
        )

        let gen = loadGeneration
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.reloadWithAudioOverride(
                url: url,
                audioStreamIndex: Int32(index),
                expectedGeneration: gen
            )
        }
    }

    /// Switch the active disc title (a Blu-ray playlist or DVD-Video title) mid-playback. Rebuilds the
    /// pipeline from the new title's start; expect a brief black frame like a fresh load. No-op when `id`
    /// is out of range, already selected, there is no disc, or the source is a forward-only custom reader.
    /// `id` is a `TitleInfo.id` from `discTitles`. (#67)
    public func selectTitle(id: Int) {
        if isCustomSource && !customSourceIsSeekable {
            EngineLog.emit(
                "[AetherEngine] selectTitle(\(id)) ignored: forward-only custom source cannot rebuild its pipeline",
                category: .engine
            )
            return
        }
        guard let url = loadedURL else { return }
        guard discTitles.contains(where: { $0.id == id }) else {
            EngineLog.emit(
                "[AetherEngine] selectTitle: id=\(id) not in discTitles (\(discTitles.map { $0.id })), ignored",
                category: .engine
            )
            return
        }
        if activeDiscTitleID == id { return }

        EngineLog.emit("[AetherEngine] selectTitle: scheduling switch to title \(id)", category: .engine)
        let gen = loadGeneration
        let options = loadedOptions
        let custom = isCustomSource
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if custom {
                // Custom readers (e.g. SMB ISO) have no URL to reopen; rebuild on the retained reader with the
                // title override, restarting at the new title's head.
                await self.reloadWithAudioOverride(
                    url: url,
                    audioStreamIndex: nil,
                    expectedGeneration: gen,
                    discTitleIDOverride: id,
                    resumeOverride: 0
                )
            } else {
                // Liveness guard: a stop()/load() enqueued between selectTitle and this body would otherwise be
                // resurrected by the load() below (selectAudioTrack gets this for free via reloadWithAudioOverride).
                guard self.loadGeneration == gen else {
                    EngineLog.emit("[AetherEngine] selectTitle reload superseded before start; ignored", category: .engine)
                    return
                }
                // URL/local disc: a full reload re-probes the new title and republishes audio/subtitle/title/
                // duration plus re-runs the display-criteria handshake. Correct because a title switch changes
                // content entirely (unlike the audio-switch fast path, which keeps the panel mode).
                do {
                    try await self.load(url: url, startPosition: 0, options: options, discTitleID: id)
                } catch is CancellationError {
                    // Superseded by a newer load/stop; it owns engine state.
                } catch {
                    EngineLog.emit("[AetherEngine] selectTitle reload failed: \(error)", category: .engine)
                }
            }
        }
    }

    /// Seek to a chapter within the active disc title. `id` is a `ChapterInfo.id` from `discChapters`. A thin
    /// wrapper over `seek(to:)` (no pipeline rebuild, since the chapter lives in the playing title's stream).
    /// No-op when `id` is unknown. (#67)
    public func selectChapter(id: Int) {
        guard let chapter = discChapters.first(where: { $0.id == id }) else {
            EngineLog.emit(
                "[AetherEngine] selectChapter: id=\(id) not in discChapters (\(discChapters.map { $0.id })), ignored",
                category: .engine
            )
            return
        }
        // discChapters are title-relative (0-based: chapter 1 = 0), matching the disc timeline and the
        // 0-based title duration. The engine clock and seek(to:) run on the source-PTS axis, which begins at
        // the title's content start; that base differs by backend (native re-times onto a 0-based playlist
        // shifted by playlistShiftSeconds; the software path's raw clock begins at the container start,
        // sourceStartSeconds). Add it so the seek lands on the chapter, not the base seconds early.
        let base = (playbackBackend == .software) ? sourceStartSeconds : playlistShiftSeconds
        let target = chapter.startSeconds + base
        EngineLog.emit(
            "[AetherEngine] selectChapter: seeking to chapter \(id) @ title-relative "
            + "\(String(format: "%.2f", chapter.startSeconds))s -> source \(String(format: "%.2f", target))s "
            + "(base \(String(format: "%.2f", base))s, backend \(playbackBackend))",
            category: .engine
        )
        Task { @MainActor [weak self] in await self?.seek(to: target) }
    }

    /// Most recent sidecar subtitle URL; rehydrated by selectAudioTrack after pipeline reload. Cleared on clearSubtitle/stop.
    var loadedSidecarURL: URL?
    /// Active secondary sidecar URL, or nil. Mirror of loadedSidecarURL.
    var loadedSecondarySidecarURL: URL?

    // MARK: - Internal teardown

    /// - Parameter resetDisplayCriteria: When `true` (default), release
    ///   the `AVDisplayManager.preferredDisplayCriteria` so the panel
    ///   returns to its default mode. Used by `load()` and the public
    ///   `stop()` API where the next session may target a different
    ///   format. The audio-track-switch reload path passes `false`
    ///   because the same source is being re-prepared with only the
    ///   audio stream changing; keeping the criteria in place avoids
    ///   a redundant `apply` + `waitForSwitch` cycle that on some
    ///   panels (notably when paired with a Bluetooth A2DP audio route)
    ///   never settles and times out at 5 s, adding ~12 s of black-
    ///   screen latency per audio switch.
    func stopInternal(resetDisplayCriteria: Bool = true, keepNativeHost: Bool = false, keepCustomReader: Bool = false) {
        // Bump generation to invalidate in-flight load() checkpoints.
        loadGeneration &+= 1
        // tearDown() unloads the AVPlayer item before the loopback server is torn down to avoid noisy races.
        // keepNativeHost preserves NativeAVPlayerHost + currentAVPlayer across native->native reloads:
        // AVKit binds its MediaRemote registration to the AVPlayer instance once and never re-registers
        // against a swapped player ("Code=14 client callback"); reusing the instance keeps Control Center
        // populated across the seam (issue #15). SW-path callers must release the preserved host themselves.
        memoryProbeTask?.cancel()
        memoryProbeTask = nil
        liveReloadWatchdogTask?.cancel()
        liveReloadWatchdogTask = nil
        // markClosed() aborts a probe blocked in avformat_open_input/find_stream_info (lock-free, idempotent).
        inFlightProbeDemuxer?.markClosed()
        liveTelemetrySampler?.stop()
        liveTelemetrySampler = nil
        diagnostics.liveTelemetry = nil
        nativeCancellables.removeAll()
        nativeHost?.tearDown()
        if !keepNativeHost {
            nativeHost = nil
            currentAVPlayer = nil
        }
        nativeVideoSession?.stop()
        nativeVideoSession = nil
        extractorYieldState.deactivate()

        // Shut down live scrub-thumbnail FrameExtractors with the session.
        let liveThumbs = liveThumbnailExtractors
        liveThumbnailExtractors.removeAll()
        for entry in liveThumbs {
            Task { await entry.extractor.shutdown() }
        }

        softwareCancellables.removeAll()
        softwareHost?.stop()
        softwareHost = nil

        // Clear audioHost so music<->video handoffs start from a clean slate; the engine is a process-wide
        // singleton and a lingering host would keep the old synchronizer alive under the next session.
        audioCancellables.removeAll()
        audioHost?.stop()
        audioHost = nil

        // AVPlayer audio host is KEPT alive (MPNowPlayingSession must persist). Mark inactive; next audio load
        // reuses via replaceCurrentItem.
        audioNativeCancellables.removeAll()
        audioAVPlayerActive = false
        audioAVPlayerHost?.stop()

        // Close custom reader on final teardown. Internal reloads pass keepCustomReader=true to survive for reuse.
        if !keepCustomReader {
            customReader?.close()
            customReader = nil
            customFormatHint = nil
            customSourceIsSeekable = false
        }

        if resetDisplayCriteria {
            displayCriteria.reset()
        }
        playbackBackend = .none
        activeVideoDecoder = nil
        activeAudioDecoder = nil
        lastDetectedVideoCodec = AV_CODEC_ID_NONE
        playlistShiftSeconds = 0
        liveShiftSeams.removeAll()
        nativeClockSeconds = 0
        clock.sourceTime = 0
        clock.bufferedPosition = 0
        isBuffering = false
        readerStall = .flowing
        // Hard-clear in-flight seek state: late callbacks are dropped by generation guards, but isSeeking
        // must not strand (#38).
        programmaticSeekInFlight = false
        nativeScrubSeekInFlight = false
        isSeeking = false
        seekTarget = nil

        liveWindowTimerTask?.cancel()
        liveWindowTimerTask = nil

        cancelSidecarTask()
        cancelEmbeddedSubtitleReader()
        activeEmbeddedSubtitleStreamIndex = -1
        activeSubtitleTrackIndex = nil
        loadedSidecarURL = nil
        isSubtitleActive = false
        subtitleCues = []
        sidecarASSHeader = nil
        isLoadingSubtitles = false
        nativeSubtitleTrackTable = []
        nativeSubtitleReapplyOrdinal = nil
        nativeSubtitleTracks = []
        nativeSubtitleReaderParams = nil
        cancelNativeSubtitleReaders()
        nativeSubtitleRenditionAvailable = false
        cancelSidecarTask(channel: .secondary)
        cancelEmbeddedSubtitleReader(channel: .secondary)
        activeSecondaryEmbeddedSubtitleStreamIndex = -1
        loadedSecondarySidecarURL = nil
        isSecondarySubtitleActive = false
        secondarySubtitleCues = []
        isLoadingSecondarySubtitles = false
        // Clear so a stale index from the previous session can't be re-applied before the next load() repopulates audioTracks.
        activeAudioTrackIndex = nil
        // Disc title state. activeDiscTitleID is plain state the reload paths snapshot BEFORE this runs, so
        // clearing it here can't strip a title carried across an audio switch / background-resume reopen (#67).
        discTitles = []
        selectedDiscTitle = nil
        discChapters = []
        activeDiscTitleID = nil
        sourceStartSeconds = 0
        isLive = false
        liveWindow = nil
        clock.liveEdgeTime = 0
        clock.seekableLiveRange = nil
        clock.isAtLiveEdge = false
        clock.behindLiveSeconds = 0
    }

    // MARK: - App Lifecycle

    private func setupLifecycleObservers() {
        #if os(iOS) || os(tvOS)
        let nc = NotificationCenter.default

        // Tear the VIDEO pipeline down on background. Pausing left live sessions frozen across multi-hour
        // tvOS suspension: AVPlayer decode session in mediaserverd + loopback sockets + AVIO connection all
        // stayed allocated; on resume that wedged mediaserverd system-wide until reboot. teardownVideoForBackground()
        // releases the decode session synchronously so nothing crosses into suspension.
        //
        // AUDIO (music) keeps playing in the background (UIBackgroundModes audio). Flipping state to .paused
        // while AVPlayer keeps playing desyncs MPNowPlayingInfoPropertyPlaybackRate, breaking the Now-Playing
        // badge + Siri Remote routing. Skip teardown for audio backends.
        let bgObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                #if os(iOS)
                self.isBackgrounded = true
                // Keep the video pipeline alive for PiP / background audio while the app stays running.
                // Wedge-safe: a pause while backgrounded tears down via pause() below, so nothing crosses
                // an idle suspension. tvOS keeps the unconditional teardown.
                let keepAlive = Self.shouldKeepVideoAlive(enabled: self.backgroundPlaybackEnabled,
                                                          pipActive: self.pictureInPictureActive,
                                                          state: self.state)
                #else
                let keepAlive = false  // tvOS: wedge-safe unconditional teardown
                #endif
                switch Self.backgroundAction(
                    isAudioBackend: self.audioAVPlayerActive || self.audioHost != nil,
                    hasSoftwareHost: self.softwareHost != nil,
                    keepVideoAlive: keepAlive,
                    state: self.state
                ) {
                case .doNothing:
                    return
                case .enterSoftwareAudioOnly:
                    self.softwareHost?.enterBackgroundAudioOnly()
                case .teardownVideo:
                    await self.teardownVideoForBackground()
                }
            }
        }
        lifecycleObservers.append(bgObserver)
        #if os(iOS)
        let fgObserver = nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.softwareHost?.exitBackgroundAudioOnly()
                self.isBackgrounded = false
            }
        }
        lifecycleObservers.append(fgObserver)
        #endif
        #endif
    }

    #if os(iOS) || os(tvOS)
    /// Release the video pipeline before tvOS suspension.
    ///
    /// stopInternal's replaceCurrentItem(nil) + VTDecompressionSession invalidation frees the shared
    /// mediaserverd decode session synchronously. keepNativeHost=true preserves the NativeAVPlayerHost shell
    /// for AVKit's Now-Playing registration (issue #15); keepCustomReader=true retains the byte-source reader.
    /// clock.currentTime/loadedURL/loadedOptions are preserved so reloadAtCurrentPosition() resumes correctly.
    ///
    /// A UIApplication background-task assertion is held across teardown so the loopback server's detached
    /// socket close (HLSVideoEngine.stop drains the producer up to 3 s) completes before suspension.
    @MainActor
    private func teardownVideoForBackground() async {
        let app = UIApplication.shared
        let bgTask = app.beginBackgroundTask(withName: "AetherEngine.bgVideoTeardown")
        stopInternal(resetDisplayCriteria: false, keepNativeHost: true, keepCustomReader: true)
        // Session torn down; host will reload + repause on foreground return.
        state = .paused
        // Wait for the loopback server's detached cleanup (<=3 s producer drain + socket shutdown) before releasing.
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        if bgTask != .invalid { app.endBackgroundTask(bgTask) }
    }
    #endif
}

// MARK: - Errors

public enum AetherEngineError: Error {
    case noVideoStream
    case noAudioStream
}
