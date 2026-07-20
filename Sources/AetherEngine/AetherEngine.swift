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

    /// Dolby Vision profile number (5, 7, 8, 10) of the source, or nil when not DV. Companion to
    /// `sourceVideoFormat` for Stats-for-Nerds labels ("Dolby Vision P5"); read from the dvcC record.
    @Published public internal(set) var sourceDVProfile: Int? = nil

    /// Nominal source frame rate (fps) from the container's `avg_frame_rate` (falling back to `r_frame_rate`),
    /// or nil when the source has no video or libavformat couldn't derive one. Companion to `sourceVideoFormat`
    /// for Stats-for-Nerds. `LiveTelemetry.observedFps` measures the live rate but is nil on the native AVPlayer
    /// path (no usable counter); this nominal value fills that gap for the on-screen readout.
    @Published public internal(set) var sourceVideoFrameRate: Double? = nil

    /// Declared source video bitrate in bits/second (0 when the container declares none). From the video
    /// stream's `codecpar.bit_rate`, or the Matroska `BPS` statistics tag when that is 0 (mkvmerge). Static
    /// container info for Stats-for-Nerds; the live per-second rate lives in `LiveTelemetry`.
    @Published public internal(set) var sourceVideoBitrate: Int64 = 0

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

    /// Master enable for background playback (iOS: PiP + background audio; tvOS: PiP keepalive). Default on.
    public var backgroundPlaybackEnabled = true
    /// Set by the host from its PiP delegate (iOS: AVKit; tvOS: host-built AVPictureInPictureController);
    /// the keepalive policy + pause-safety read it.
    public var pictureInPictureActive = false {
        didSet {
            // SW-PiP Phase C: flip the frame compositor with the PiP state so subtitles appear in the
            // window and never double-draw under the fullscreen host overlay.
            softwareHost?.updateSubtitleCompositor(cues: subtitleCues + secondarySubtitleCues, enabled: pictureInPictureActive)
            #if os(tvOS)
            // PiP window closed while backgrounded: nothing keeps the app running anymore, so run the
            // wedge-safe teardown now, before idle suspension (mirrors the iOS pause-while-backgrounded path).
            if oldValue && !pictureInPictureActive && isBackgrounded,
               !audioAVPlayerActive, audioHost == nil, softwareHost == nil,
               state == .playing || state == .paused {
                Task { @MainActor in await self.teardownVideoForBackground() }
            }
            #endif
        }
    }
    /// #127: seconds a PAUSED session survives backgrounding (iOS) before the wedge-safe teardown runs,
    /// held under a background-task assertion so a quick app switch resumes without a pipeline rebuild.
    /// 0 restores the immediate teardown. Ignored on tvOS. Keep well under the ~30 s system allowance,
    /// the teardown itself needs ~3.5 s of drain before suspension.
    public var backgroundTeardownGraceSeconds: Double = 15

    /// #127: true once the active session's transport is ready to accept seeks and report real time
    /// (native: AVPlayerItem readyToPlay; SW/audio hosts publish readiness at session start). Hosts
    /// gate corrective actions (restore watchdogs, position clamps) on this instead of inferring
    /// readiness from currentTime being pinned at 0.
    @Published public internal(set) var isSessionReady = false

    /// #127: latest host seek issued while the native item was pre-ready; replayed at readiness.
    var pendingPreReadySeekSeconds: Double?
    /// AE#158: set by load() when the running item must survive until the new master attaches (PiP
    /// next-episode handover); consumed and reset by the loopback host.load callsite (inPlaceSwap).
    var pendingInPlaceItemHandover = false
    /// SW-PiP bridge, the software-path analog of `currentAVPlayer`: set when a SW session has its
    /// display layer, nil on teardown. Hosts build their sample-buffer PiP ContentSource from it.
    @Published public internal(set) var softwarePiPSource: SoftwarePiPSource?
    #if os(iOS) || os(tvOS)
    /// True between didEnterBackground and didBecomeActive; gates the pause-while-backgrounded teardown
    /// (iOS) and the PiP-closed-while-backgrounded teardown (tvOS).
    private var isBackgrounded = false
    #endif
    #if os(iOS)
    /// #127: pending grace-window teardown (sleep task + the background-task assertion holding it).
    private var backgroundGraceTask: Task<Void, Never>?
    private var backgroundGraceAssertion: UIBackgroundTaskIdentifier = .invalid
    #endif
    /// Armed by an audio-session interruption that paused an intent-to-play session; fires play()
    /// on interruption end (see the observer in setupLifecycleObservers). Disarmed by user pause()
    /// and stopInternal().
    private var resumeAfterInterruption = false

    /// Wedge-safe keepalive decision: keep the video pipeline alive on background ONLY while the app stays
    /// genuinely running (PiP active, or actively playing for background audio), never across an idle
    /// suspension. Pure so the policy is unit-tested without the lifecycle. See setupLifecycleObservers.
    nonisolated static func shouldKeepVideoAlive(enabled: Bool, pipActive: Bool, state: PlaybackState) -> Bool {
        enabled && (pipActive || state == .playing)
    }

    /// tvOS keepalive: ONLY an active PiP window keeps the app genuinely running in the background (there
    /// is no tvOS background-audio case for video sessions); everything else keeps the wedge-safe
    /// unconditional teardown that protects mediaserverd across multi-hour suspensions.
    nonisolated static func shouldKeepVideoAliveTV(enabled: Bool, pipActive: Bool) -> Bool {
        enabled && pipActive
    }

    /// AE#158: a system PiP window closes the moment its source layer's player drops its item (the #93
    /// in-PiP recovery reload hit the same nil-item gap), so a native->native load while PiP is active
    /// keeps the old item attached through the load gap and swaps in place once the new master is ready.
    nonisolated static func shouldHandOverItemInPlace(pipActive: Bool, priorBackendWasNative: Bool) -> Bool {
        pipActive && priorBackendWasNative
    }

    /// SW-PiP: playable range for the sample-buffer PiP UI on the PTS axis of the enqueued frames
    /// (the source axis; sourceTime = currentTime + container start offset). Live or unknown
    /// duration reports indefinite so the window shows live UI instead of a bogus scrubber.
    nonisolated static func softwarePiPTimeRange(isLive: Bool, sourceTime: Double, currentTime: Double, duration: Double) -> CMTimeRange {
        guard !isLive, duration.isFinite, duration > 0 else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        let sourceStart = sourceTime - currentTime
        return CMTimeRange(
            start: CMTime(seconds: sourceStart, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }

    /// What to do with the active video pipeline when the app enters the background. Pure so the lifecycle
    /// policy is unit-testable. Mirrors the spirit of the native keepalive onto the software path.
    enum BackgroundAction: Equatable {
        case doNothing               // audio backend, or native keepalive: leave the running session alone
        case enterSoftwareAudioOnly  // SW host kept alive: drop video in the demux loop, keep feeding audio
        case teardownVideo           // release the video pipeline before idle suspension
    }

    /// - keepVideoAlive: result of shouldKeepVideoAlive / shouldKeepVideoAliveTV.
    /// - pipActive: a live PiP window renders the SW layer's frames, so the SW host must keep
    ///   decoding video in background instead of dropping to audio-only (SW-PiP Phase A).
    nonisolated static func backgroundAction(
        isAudioBackend: Bool,
        hasSoftwareHost: Bool,
        keepVideoAlive: Bool,
        pipActive: Bool,
        state: PlaybackState
    ) -> BackgroundAction {
        if isAudioBackend { return .doNothing }
        if keepVideoAlive {
            if hasSoftwareHost { return pipActive ? .doNothing : .enterSoftwareAudioOnly }
            return .doNothing
        }
        guard state == .playing || state == .paused else { return .doNothing }
        return .teardownVideo
    }

    /// #127: how to execute a BackgroundAction. A PAUSED teardown on platforms with quick app switches
    /// (iOS) is deferred by a grace window held under a background-task assertion, so a 10-30 s app
    /// switch does not pay a full pipeline rebuild. Wedge-safety holds: the assertion keeps the app
    /// genuinely running for the whole window and the teardown fires at expiry, so the pipeline never
    /// crosses an idle suspension. A PLAYING teardown (background playback disabled) stays immediate,
    /// its audio would keep sounding through the window. tvOS passes supportsGraceWindow=false.
    enum BackgroundStep: Equatable {
        case perform(BackgroundAction)
        case deferTeardown(afterSeconds: Double)
    }

    nonisolated static func backgroundStep(
        action: BackgroundAction,
        state: PlaybackState,
        supportsGraceWindow: Bool,
        graceSeconds: Double
    ) -> BackgroundStep {
        guard action == .teardownVideo, state == .paused, supportsGraceWindow, graceSeconds > 0 else {
            return .perform(action)
        }
        return .deferTeardown(afterSeconds: graceSeconds)
    }

    /// #127: a host seek forwarded into a pre-ready AVPlayer item clamps to 0 against empty seekable
    /// ranges AND replaces load()'s own pending startPosition seek (AVPlayer holds one pending seek).
    /// Defer such seeks and replay the latest at readiness. Live rejoin/DVR paths own their timing
    /// (LiveReloadPolicy), SW/audio hosts resolve seeks synchronously; neither defers.
    nonisolated static func shouldDeferHostSeek(
        nativeSessionActive: Bool,
        isLive: Bool,
        nativeHostReady: Bool
    ) -> Bool {
        nativeSessionActive && !isLive && !nativeHostReady
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
    /// #100: per-channel holdback for PGS cues arriving behind the playhead (catch-up bursts after
    /// side-reader starvation). Reset wherever the cue arrays reset (track switch, seek re-anchor,
    /// clear, load/stop) so a hold can never leak across subtitle sessions.
    var pgsStaleArrivalGates: [SubtitleChannel: PGSStaleArrivalGate] = [:]

    /// #112 rework: per-channel embedded overlay targets served by the playhead-paced
    /// drainer (SubtitleOverlayDrainer) from the session's SubtitlePacketStore. Replaces
    /// the embedded side-demuxer reader for every host, VOD and live, text and bitmap.
    var subtitleDrainTargets: [SubtitleChannel: Int32] = [:]
    var subtitleDrainerTask: Task<Void, Never>?
    /// SW-host sessions have no HLSVideoEngine; their tap fills this store instead.
    var softwareSubtitlePacketStore: SubtitlePacketStore?
    var subtitleDrainDecoders: [SubtitleChannel: EmbeddedSubtitleDecoder] = [:]
    var subtitleDrainCursors: [SubtitleChannel: SubtitleDrainCursor] = [:]
    /// #151: subtitle-only forward side reader filling the session packet store up to
    /// playhead + subtitleDrainLeadSeconds independent of the producer's forward park, so the
    /// drainer's lead window holds cues for host-applied ADVANCE sync offsets (text and bitmap).
    /// nil while idle (subs off, live session, EOF reached).
    var subtitleForwardPrefetchTask: Task<Void, Never>?
    var subtitleForwardPrefetchDemuxer: Demuxer?
    /// #121: session-monotonic id source for cues entering the retained overlay stores
    /// (`subtitleCues` / `secondarySubtitleCues`). The overlay decoder is rebuilt on every seek
    /// (`.resetAndDecode`), restarting its own `nextCueID` at zero, so decoder-local ids cannot stay
    /// unique across the cues that survive the seek. Stamping at the insert funnel keeps the retained
    /// arrays collision-free (the `SubtitleCue: Equatable` / host `ForEach(id:)` contract). Never reset:
    /// monotonic for the engine's lifetime is collision-proof and needs no coordination with the many
    /// array-clear sites.
    var nextRetainedSubtitleCueID: Int = 0
    nonisolated static let subtitleDrainLeadSeconds: Double = 60
    nonisolated static let subtitleDrainBackscanSeconds: Double = 15
    nonisolated static let subtitleDrainJumpThresholdSeconds: Double = 2.5
    nonisolated static let subtitleDrainTickNanoseconds: UInt64 = 500_000_000
    /// Phase D: the OCR worker decodes bitmap compositions to playhead + this lead so AVKit's
    /// ~240 s forward .vtt prefetch burst at selection is served populated, never cached empty.
    nonisolated static let subtitleOCRLeadSeconds: Double = 240
    /// Phase D: forward-prefetch lead while the OCR worker is armed; exceeds
    /// subtitleOCRLeadSeconds so the packet store actually holds the worker's window.
    nonisolated static let subtitleOCRPrefetchLeadSeconds: Double = 270
    /// Phase D: per-tick decode cap; smooths the initial 240 s backfill over a few ticks
    /// instead of one long MainActor pass.
    nonisolated static let subtitleOCRMaxPacketsPerTick: Int = 48
    nonisolated static let subtitleForwardPrefetchParkPollNanoseconds: UInt64 = 500_000_000

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

    /// True when the SERVED playlist is the master (so the master's SUBTITLES renditions reach an
    /// external display), false when the media playlist is served (Sodalite#98 external-subtitle window).
    /// Mirrors the inner session's `servingMasterPlaylist`; the "and renditions exist" refinement is
    /// unnecessary because text subtitles on iOS always get renditions prepared, and bitmap subtitles on
    /// an HDR external display stay a pre-existing limitation (unchanged). Goes false on a media fallback.
    /// The host uses it to decide whether to draw its own subtitle window on a wired external display.
    @Published public internal(set) var nativeSubtitleRenditionsServed: Bool = false

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

    // MARK: - Scrub thumbnails

    /// LRU (cap 2) of FrameExtractor contexts for cache-backed scrub thumbnails (live and
    /// VOD; a session is one or the other). Reuses open demux/decode contexts across scrubs
    /// within the same segment; torn down in stopInternal.
    var scrubThumbnailExtractors: [(segmentIndex: Int, extractor: FrameExtractor)] = []

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
    /// Eligibility is display-configuration aware on all platforms (its change notification fires
    /// on display connection/disconnection), so per-load reads pick up monitor changes; the value
    /// is device-wide, not per-window, so mixed HDR/SDR multi-display Macs read eligible (#98).
    ///
    /// `availableHDRModes` is deprecated in the 26 SDKs ("use eligibleForHDRPlayback instead"),
    /// but that Bool cannot express the per-mode split this engine routes on: a tvOS panel can be
    /// HDR10-capable yet not Dolby Vision, and a single-variant DV P5 master fails there with
    /// -11868. The 26 SDKs ship no public per-mode replacement (full header sweep, 2026-07), and
    /// deprecated is not obsoleted, so the read stays; no warning is emitted while the deployment
    /// targets sit below 26. If the symbol is ever removed: derive iOS modes from eligibility
    /// (built-in HDR panels present every flavor) and pessimistically route DV P5 media-direct on
    /// tvOS, accepting the DV-to-HDR10 downgrade for P8 on DV panels.
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
    /// target is not a wedge, pause false-positive). Starts true: VOD autostarts and the sink corrects it.
    let playIntentMirror = AtomicBool(true)

    /// #35/#93 startup: thread-safe mirror of "AVPlayer has presented a frame this item" (its
    /// `timeControlStatus` reached `.playing` at least once), set on the main actor by the
    /// $timeControlStatus sink and reset per new load(). Read off-main by the producer to keep the VOD
    /// backpressure wedge detector suspended through cold pre-roll: a flat rendered clock before the first
    /// frame is not a wedge, and re-anchoring there livelocks a slow high-bitrate DV-master start.
    let hasRenderedFirstFrameMirror = AtomicBool(false)

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

    /// Source PTS that maps to display-time 0 for the SELECTED source. 0 for normal files and live (their
    /// public seconds axis already coincides with source PTS). For a disc title it equals the (constant) VOD
    /// `playlistShiftSeconds` = clip 0's STC base, because a disc title publishes its `duration` from the
    /// MPLS/IFO playlist on a 0-based axis while the raw source PTS starts at that base (599s / 4199s on the
    /// TRON multi-clip titles, AE#105). Subtracted from the published `currentTime`/`seekTarget` and added back
    /// to the `seek` input so the scrubber position, total, seek and resume all live on the same 0-based axis
    /// the producer already anchors `startPosition` on (`segmentIndexForPlaylistTime`), while `sourceTime`
    /// stays true source PTS for subtitle-cue alignment. Reset to 0 on load/stop; set in onPlaylistShiftChanged.
    var sourcePresentationOrigin: Double = 0

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
    /// On SW it is the raw synchronizer clock in the source axis: equal to currentTime for zero-based sources,
    /// offset by the session zero on live / mid-stream-joined sources (#107). Forwarder; subscribe to `clock.$sourceTime`.
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

    /// Active embedded subtitle stream index, or -1. Used by seek to decide whether to re-arm the side demuxer.
    var activeEmbeddedSubtitleStreamIndex: Int32 = -1


    /// #95 audio tap lifecycle owner; nil when no tap installed. Torn down by stopInternal.
    var audioTapController: AudioTapController?

    /// #77: in-band CEA-608 tap state. The tap owns the cue buffer and publishes snapshots; `ccCueSnapshot`
    /// is the latest, mirrored into `subtitleCues` while the CC track is active.
    var closedCaptionTap: ClosedCaptionTap?
    var ccCueSnapshot: [SubtitleCue] = []
    var ccLastSnapshotSeq: Int = 0

    /// Secondary subtitle reader state mirrors (#47). Driven only through SubtitleChannel.secondary.
    var secondarySidecarTask: Task<Void, Never>?
    var activeSecondaryEmbeddedSubtitleStreamIndex: Int32 = -1

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
        /// Phase D: bitmap (PGS/DVB/DVD) entry whose store is filled by the OCR worker /
        /// sidecar OCR fill, not by the pump tap or the side readers.
        var needsOCR: Bool = false
    }
    var nativeSubtitleTrackTable: [NativeSubtitleTrackEntry] = []

    /// Native WebVTT rendition store for the in-band CEA-608 track (#98). The CC tap feeds it (via
    /// `updateClosedCaptionCues`) so 608 captions ride a native AVKit-selectable rendition and
    /// survive PiP / AirPlay, not just the overlay. Nil when there is no 608 track or native
    /// subtitles are off. Set in the load path, cleared with the tap.
    var ccNativeStore: NativeSubtitleCueStore?

    /// Last ordinal the host requested via setNativeSubtitleSelected (nil after a deselect).
    /// The #93 stage-2 recovery reload swaps AVPlayerItems and legible selection is per-item,
    /// so the reload re-applies this to keep an active rendition (PiP) rendering. Cleared with
    /// the track table on load/stop so a new session never inherits a stale selection.
    var nativeSubtitleReapplyOrdinal: Int?

    /// Whole-file decode tasks filling native stores for load-declared external tracks (#88).
    var externalNativeStoreFillTask: Task<Void, Never>? = nil

    /// Phase D: OCR worker state. Armed while the active subtitle is a needsOCR table entry;
    /// cursors/pending persist across deselect/reselect (no re-recognition of covered regions)
    /// and reset only on load/stop.
    var subtitleOCRArmedOrdinal: Int?
    var subtitleOCRWorkerTask: Task<Void, Never>?
    var subtitleOCRSidecarFillTask: Task<Void, Never>?
    var subtitleOCRDecoder: EmbeddedSubtitleDecoder?
    var subtitleOCRCursors: [Int: SubtitleDrainCursor] = [:]
    var subtitleOCRPendingStates: [Int: SubtitleOCRPendingState] = [:]

    /// AE#154: publishes the remote-HLS bypass item's legible options as `subtitleTracks`.
    /// Session-scoped; cancelled on load()/stop() alongside the other subtitle tasks.
    var remoteHLSSubtitleDiscoveryTask: Task<Void, Never>? = nil

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

    /// #93 round 3: item death (failedToPlayToEndTime after -12889 strikes) escalation.
    /// Deferred-confirm task (a transient that resumes within the window self-clears) plus the
    /// bounded reload budget. Cancelled on load reset; superseded by newer deaths.
    var itemDeathConfirmTask: Task<Void, Never>? = nil
    var itemDeathReviveGate = ItemDeathReviveGate(maxAttempts: 3)
    nonisolated static let itemDeathConfirmSeconds: TimeInterval = 3.0

    /// Single-shot latch for the reactive master->media fallback (#98): fall back at most once per
    /// session so a media reload that also fails cannot loop. Reset on each load.
    var masterFallbackUsed = false

    /// Start position of the current loopback video load, replayed if the master is rejected and we
    /// reload the media playlist (a startup-failed item has no reliable renderedTime).
    var lastNativeVideoStartPosition: Double = 0

    /// #93 PiP skips: AVKit-side seeks (PiP +-15s buttons) bypass the engine seek API, so a far
    /// playhead jump is detected on $renderedTime and, once settled, the native subtitle readers
    /// re-anchor and the remembered rendition selection replays (its deselect/reselect busts
    /// AVKit's cached empty .vtt windows). Cancelled on load reset / stop; newer jumps supersede.
    var nativeSubtitleReanchorTask: Task<Void, Never>? = nil
    /// seekTo anchor of the currently running native subtitle readers; nil = no readers running.
    var nativeSubtitleReaderCoverageStart: Double?
    nonisolated static let subtitleReanchorJumpSeconds: Double = 60
    nonisolated static let subtitleReanchorSettleNanos: UInt64 = 2_500_000_000
    nonisolated static let subtitleReanchorBackwardSlack: Double = 5
    nonisolated static let subtitleReanchorForwardSlack: Double = 90

    /// #93 retest: a user seek that wedges never lands, so the frozen clock still reports the
    /// PRE-seek position (#37) and a recovery anchored there silently loses the seek. The
    /// unlanded seek target (AVPlayer/item clock axis) survives the wedge as recovery intent:
    /// nudge and stage-2 reload aim at it. Cleared on real landing, on rendered output reaching
    /// the target's neighbourhood, on organic playback progress elsewhere (stale: AVPlayer
    /// abandoned the seek), and on load reset / stop.
    var pendingRecoverySeekClockTarget: Double? = nil
    /// The rendered-time sink owns clock/subtitle finalization only after the bounded seek wait
    /// expires. Ordinary in-flight seeks remain owned by their normal continuation.
    var pendingRecoverySeekDeadlineExpired = false
    /// True when a starved deadline already reset subtitle discontinuity state before the pending
    /// seek landed. Healthy late landings perform that reset in the rendered-time sink instead.
    var pendingRecoverySeekSubtitlesReanchored = false
    /// Rendered frame parked on screen when the current native seek began. Distinguishes a genuine
    /// late landing from a short seek whose unchanged old frame is already within the 5 s window.
    var pendingSeekInitialRenderedPosition: Double = 0
    /// Off-main mirror of `pendingRecoverySeekClockTarget` so the session's wedge re-anchor can aim
    /// the producer at the pending target (#93 retest). Kept in sync via `setPendingRecoverySeekTarget`.
    let recoverySeekTargetMirror = AtomicOptionalDouble()
    var pendingSeekProgressAccum: Double = 0
    var lastRenderedForPendingSeek: Double = 0

    /// Single write path for the recovery seek intent: the MainActor field and its off-main mirror
    /// must never diverge (a stale mirror would teleport a wedge re-anchor to a retired target).
    func setPendingRecoverySeekTarget(_ target: Double?) {
        pendingRecoverySeekDeadlineExpired = false
        pendingRecoverySeekSubtitlesReanchored = false
        pendingRecoverySeekClockTarget = target
        if target == nil {
            pendingSeekInitialRenderedPosition = 0
        }
        recoverySeekTargetMirror.set(target)
    }
    nonisolated static let pendingSeekLandedEpsilon: Double = 5.0
    nonisolated static let pendingSeekStaleProgressSeconds: Double = 3.0

    /// Pure decision: where does a stall recovery anchor? The requested-but-unlanded seek target
    /// wins over the frozen clock position. Without one, the anchor can never sit below the
    /// current rendered frame (#115): on VOD the consumer keeps draining buffered segments
    /// through the re-engage grace window, so a pre-grace capture lands the zero-tolerance
    /// nudge behind the on-screen frame, a visible backward replay.
    nonisolated static func recoveryAnchorPosition(
        frozenPosition: Double, pendingSeekTarget: Double?, currentRendered: Double
    ) -> Double {
        pendingSeekTarget ?? max(frozenPosition, currentRendered)
    }

    /// Log suffix explaining why a recovery anchor diverged from the captured position.
    nonisolated static func recoveryAnchorLogSuffix(
        anchor: Double, position: Double, pendingSeekTarget: Double?
    ) -> String {
        guard anchor != position else { return "" }
        let capture = String(format: "%.2f", position)
        return pendingSeekTarget != nil
            ? " (requested seek target; frozen clock \(capture)s)"
            : " (rendered frame; stale capture \(capture)s)"
    }

    /// Pure decision: rendered output near the target means the seek effectively landed.
    nonisolated static func pendingSeekLanded(rendered: Double, target: Double) -> Bool {
        abs(rendered - target) < pendingSeekLandedEpsilon
    }

    nonisolated static func pendingSeekHasRenderedLandingEvidence(
        rendered: Double,
        target: Double,
        initialRendered: Double,
        completionRenderedTimePublished: Bool
    ) -> Bool {
        guard pendingSeekLanded(rendered: rendered, target: target) else { return false }
        if completionRenderedTimePublished { return true }

        let initialDistance = abs(initialRendered - target)
        let currentDistance = abs(rendered - target)
        guard abs(rendered - initialRendered) > 0.1 else { return false }
        if initialDistance < pendingSeekLandedEpsilon {
            return currentDistance <= 0.5
        }
        return true
    }

    nonisolated static func shouldReanchorSubtitlesOnLateSeekLanding(
        alreadyReanchored: Bool
    ) -> Bool {
        !alreadyReanchored
    }

    /// Pure decision: organic playback progress far from the target means AVPlayer abandoned the
    /// seek; keep no stale intent a later unrelated stall could teleport to.
    nonisolated static func isPendingSeekStale(progressWhilePending: Double) -> Bool {
        progressWhilePending >= pendingSeekStaleProgressSeconds
    }

    /// Nudge a consumer that stopped requesting: a zero-tolerance seek to its own position
    /// rebuilds AVFoundation's loading pipeline (the effect a manual back-out had), play()
    /// re-asserts intent. Opens the spurious-pause window, since the nudge can bounce transport.
    func reengageStalledConsumer(position: Double, trigger: String) {
        guard let host = nativeHost, let player = currentAVPlayer,
              let item = player.currentItem else { return }
        guard player.timeControlStatus != .paused else { return }
        let anchor = Self.recoveryAnchorPosition(
            frozenPosition: position, pendingSeekTarget: pendingRecoverySeekClockTarget,
            currentRendered: player.currentTime().seconds)
        stallRecoveryWindowUntil = Date().addingTimeInterval(Self.stallRecoveryWindowSeconds)
        EngineLog.emit(
            "[AetherEngine] #65 re-engaging stalled AVPlayer (\(trigger)): nudge seek to "
            + "\(String(format: "%.2f", anchor))s"
            + Self.recoveryAnchorLogSuffix(
                anchor: anchor, position: position,
                pendingSeekTarget: pendingRecoverySeekClockTarget),
            category: .engine
        )
        item.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: anchor, preferredTimescale: 600),
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
    /// React to AVPlayer rejecting the served master (#98, #130): if eligible, reload the media
    /// playlist in place (single-variant); otherwise surface the failure normally.
    @MainActor
    func fallBackToMediaPlaylist(_ rejection: DisplayRejection) {
        guard let host = nativeHost, let session = nativeVideoSession else {
            state = .error(rejection.message)
            return
        }
        guard MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: rejection.code,
            servingMasterPlaylist: session.servingMasterPlaylist,
            alreadyFellBack: masterFallbackUsed),
              let mediaURL = session.mediaPlaylistURL else {
            state = .error(rejection.message)
            return
        }
        masterFallbackUsed = true
        session.markServingMediaAfterFallback()
        nativeSubtitleRenditionsServed = false
        // #130: a live fallback is a REJOIN of the running ingest (the window may have slid since
        // the failed master attempt); a stale explicit position can wedge AVPlayer against the
        // backlog, so skip the initial seek and let it pick edge-minus-holdback (LiveReloadPolicy).
        // VOD keeps the explicit pre-failure position.
        let position = lastNativeVideoStartPosition
        EngineLog.emit(
            "[AetherEngine] AVPlayer rejected the master (code=\(rejection.code)); falling back to "
            + "media playlist (no CC/subtitle renditions) at "
            + (isLive ? "the live edge" : "\(String(format: "%.2f", position))s"),
            category: .session)
        host.load(url: mediaURL,
                  startPosition: isLive ? nil : position,
                  skipInitialSeek: LiveReloadPolicy.skipInitialSeek(isLive: isLive, isRejoin: true),
                  inPlaceSwap: true)
        host.play()
    }

    /// #35 readiness-gate settle windows. Generous enough that a slow-but-healthy cold start reads as
    /// ready (early-out on presentationSize / first play), tight enough that two failed master attempts
    /// plus a media fallback stay within ~8.5s worst case. Tunable from device logs.
    static let startupGateInitialSeconds: Double = 3.0
    static let startupGateReloadSeconds: Double = 3.0
    static let startupGateMediaSeconds: Double = 2.5

    /// #124: whether a completed load runs its terminal autostart, the single decision every load
    /// path routes through: the native/software/audio `host.play()` + `state = .playing`, and the
    /// native VOD cold-start readiness gate (which plays to poll readiness). `false` is an honest
    /// paused mount: skip all of it, leave `playIntent` false, and let the wired `host.$isReady`
    /// waypoint settle `.loading -> .paused`. Pure so the gate stays greppable and a new autostart
    /// site cannot silently bypass the flag.
    nonisolated static func loadPerformsAutostart(_ options: LoadOptions) -> Bool {
        options.autoplay
    }

    /// #35 cold-DV-master startup-readiness gate. A DV master (P7->P8.1, or any HDR master)
    /// instantiated while the HDMI DV/HDCP decode path is still warming right after an SDR->HDR switch
    /// resolves 0 tracks (silent park) or fails -11819 "Cannot Complete Action"; neither is a
    /// -11868/-11848 rejection, so the reactive #98 path never fires and startup surfaces "Playback
    /// stopped". A second launch just works because the failed attempt warmed the link. This gate
    /// replays that recovery in-session: play, poll readiness, and on a cold failure reload the SAME
    /// master with a fresh asset (bounded) before falling back to the media playlist (HDR10 base, no
    /// DV upgrade). Bounded at every stage, so a cold resume can never hang forever on 0 tracks.
    @MainActor
    private func runStartupReadinessGate(
        session: HLSVideoEngine, position: Double, gen: UInt64
    ) async throws {
        guard let host = nativeHost else { return }
        host.startupReadinessGateActive = true
        defer { host.startupReadinessGateActive = false }

        var attempt = 1
        while true {
            // Attempt 1 plays the item the load path already created; later attempts replay it fresh.
            host.play()
            let timeout = attempt == 1
                ? Self.startupGateInitialSeconds
                : Self.startupGateReloadSeconds
            let outcome = await host.awaitStartupReadiness(timeoutSeconds: timeout)
            try checkLoadCurrent(gen)

            switch StartupReadinessGate.nextAction(
                outcome: outcome,
                attempt: attempt,
                masterAlreadyFellBack: masterFallbackUsed,
                hasMediaFallbackURL: session.mediaPlaylistURL != nil
            ) {
            case .proceed:
                return

            case .reloadMaster:
                guard let masterURL = session.masterPlaylistURL else {
                    // Master URL unavailable (should not happen while serving the master): force the
                    // fallback path on the next loop rather than reloading a URL we don't have.
                    attempt = StartupReadinessGate.masterAttempts
                    continue
                }
                EngineLog.emit(
                    "[AetherEngine] #35 readiness gate: master did not start (\(outcome)) after a "
                    + "panel switch; reloading the master (attempt \(attempt + 1)/"
                    + "\(StartupReadinessGate.masterAttempts), link may still be warming) at "
                    + "\(String(format: "%.2f", position))s",
                    category: .session)
                host.load(url: masterURL, startPosition: position, inPlaceSwap: true)
                attempt += 1

            case .fallBackToMedia:
                // #98: before the bare (subtitle-less) media playlist, try the HDR-preserving reduced
                // master. It keeps HDR10 + subtitle renditions and, being plain hvc1 without DV signaling,
                // may start where the cold DV handshake did not. This case is terminal (returns/throws),
                // so it runs at most once per gate; no guard needed.
                if let reducedURL = session.reducedHDRMasterPlaylistURL {
                    EngineLog.emit(
                        "[AetherEngine] #35 readiness gate: master never produced tracks; trying the "
                        + "HDR-preserving reduced master (subtitles preserved, DV dropped) at "
                        + "\(String(format: "%.2f", position))s",
                        category: .session)
                    host.load(url: reducedURL, startPosition: position, inPlaceSwap: true)
                    host.play()
                    let reducedOutcome = await host.awaitStartupReadiness(
                        timeoutSeconds: Self.startupGateReloadSeconds)
                    try checkLoadCurrent(gen)
                    if reducedOutcome == .ready {
                        EngineLog.emit(
                            "[AetherEngine] #35 readiness gate: reduced master started; HDR10 base and "
                            + "subtitles preserved (DV upgrade dropped this session)",
                            category: .session)
                        return
                    }
                }
                guard let mediaURL = session.mediaPlaylistURL else {
                    throw StartupGateFailure(message: startupGateFailureMessage(host))
                }
                masterFallbackUsed = true
                session.markServingMediaAfterFallback()
                nativeSubtitleRenditionsServed = false
                EngineLog.emit(
                    "[AetherEngine] #35 readiness gate: master never produced tracks after "
                    + "\(StartupReadinessGate.masterAttempts) attempts; falling back to the media "
                    + "playlist at \(String(format: "%.2f", position))s (HDR10 base, DV upgrade "
                    + "dropped this session)",
                    category: .session)
                host.load(url: mediaURL, startPosition: position, inPlaceSwap: true)
                host.play()
                // Best-effort readiness confirm; the media playlist is the universal-compatible route.
                // Clearing the gate (defer) lets a genuine residual media failure surface normally via
                // the host's startup path -- no false-negative terminal error, still bounded.
                _ = await host.awaitStartupReadiness(timeoutSeconds: Self.startupGateMediaSeconds)
                try checkLoadCurrent(gen)
                return

            case .giveUp:
                throw StartupGateFailure(message: startupGateFailureMessage(host))
            }
        }
    }

    /// The message for a terminal gate failure: prefer the real startup error the gate suppressed
    /// while it held the item; fall back to a generic line for a silent 0-track park (no `.failed`).
    @MainActor
    private func startupGateFailureMessage(_ host: NativeAVPlayerHost) -> String {
        host.lastSuppressedStartupFailure
            ?? "The video could not start (no playable tracks after the display handshake)."
    }

    func reloadStalledConsumerItem(position: Double, allowPausedConsumer: Bool = false) {
        guard let host = nativeHost, let player = currentAVPlayer,
              let url = (player.currentItem?.asset as? AVURLAsset)?.url else { return }
        // Item death parks tcs at .paused; only that trigger may bypass the user-pause guard.
        guard Self.stalledConsumerRecoveryAllowed(
            consumerIsPaused: player.timeControlStatus == .paused,
            allowPausedConsumer: allowPausedConsumer) else { return }
        let anchor = Self.recoveryAnchorPosition(
            frozenPosition: position, pendingSeekTarget: pendingRecoverySeekClockTarget,
            currentRendered: player.currentTime().seconds)
        stallRecoveryWindowUntil = Date().addingTimeInterval(Self.stallRecoveryWindowSeconds)
        EngineLog.emit(
            "[AetherEngine] #65 nudge did not revive the consumer; reloading item at "
            + "\(String(format: "%.2f", anchor))s"
            + Self.recoveryAnchorLogSuffix(
                anchor: anchor, position: position,
                pendingSeekTarget: pendingRecoverySeekClockTarget)
            + " (same URL, same host)",
            category: .engine
        )
        host.load(url: url, startPosition: anchor, inPlaceSwap: true)
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

    /// Pure decision (#93 PiP skips): does a rendered-time transition qualify as a seek-like jump?
    nonisolated static func isSubtitleReanchorJump(from: Double, to: Double) -> Bool {
        abs(to - from) >= subtitleReanchorJumpSeconds
    }

    /// Pure decision (#93 PiP skips): do the running readers cover `position`? Slightly ahead of
    /// readMax is covered (the parked reader catches up on its own); far ahead or anywhere behind
    /// the read anchor is not.
    nonisolated static func nativeSubtitleReadersCover(
        position: Double, coverageStart: Double?, readMax: Double
    ) -> Bool {
        guard let start = coverageStart else { return false }
        return position >= start - subtitleReanchorBackwardSlack
            && position <= readMax + subtitleReanchorForwardSlack
    }

    /// Pure decision for the tcs sink (#93 residual): re-assert play() instead of latching a pause?
    nonisolated static func shouldReassertPlayDuringRecovery(
        statusIsPaused: Bool, engineStateIsPlaying: Bool,
        now: Date, windowUntil: Date, reasserts: Int
    ) -> Bool {
        statusIsPaused && engineStateIsPlaying && now < windowUntil
            && reasserts < maxStallRecoveryReasserts
    }

    /// Reconcile native seek completion while the regular time-control sink was gated by `.seeking`.
    /// Live AVPlayer status captures an external play that superseded older engine pause intent; a
    /// live pause wins unless the bounded stall-recovery policy deliberately reasserts playback.
    nonisolated static func seekRecoveredState(
        transportIntentIsPlaying: Bool,
        statusIsPaused: Bool,
        shouldReassertPausedStatus: Bool
    ) -> PlaybackState {
        if statusIsPaused {
            guard transportIntentIsPlaying, shouldReassertPausedStatus else {
                return .paused
            }
        }
        return .playing
    }

    /// Apply the same transport reconciliation after a normal native seek landing and after a
    /// deadline recovery. A starved deadline opens the bounded reassert window; a stable pause on a
    /// healthy path is treated as an external AVKit / MediaRemote command. When recovery overrides a
    /// spurious pause, replay play() because the paused KVO was consumed while state was `.seeking`.
    private func reconcileNativeSeekTransport(
        host: NativeAVPlayerHost,
        isStarved: Bool
    ) {
        let now = Date()
        if isStarved, now >= stallRecoveryWindowUntil {
            stallRecoveryWindowUntil = now.addingTimeInterval(Self.stallRecoveryWindowSeconds)
            stallRecoveryReasserts = 0
        }
        let liveStatus = host.liveTimeControlStatus
        let statusIsPaused = liveStatus == .paused
        let transportIntentIsPlaying = host.transportIntentIsPlaying
        let shouldReassertPausedStatus = Self.shouldReassertPlayDuringRecovery(
            statusIsPaused: statusIsPaused,
            engineStateIsPlaying: transportIntentIsPlaying,
            now: now,
            windowUntil: stallRecoveryWindowUntil,
            reasserts: stallRecoveryReasserts
        )
        let recoveredState = Self.seekRecoveredState(
            transportIntentIsPlaying: transportIntentIsPlaying,
            statusIsPaused: statusIsPaused,
            shouldReassertPausedStatus: shouldReassertPausedStatus
        )
        state = recoveredState
        isBuffering = recoveredState == .playing
            && liveStatus == .waitingToPlayAtSpecifiedRate
        if shouldReassertPausedStatus {
            stallRecoveryReasserts += 1
            playIntentMirror.set(true)
            host.play()
        }
    }

    /// #123: whether a seek landing (host completion + engine finalize) may settle `sourceTime` /
    /// `renderedTime` onto the seek target. `sourceTime` is the on-screen frame (#49), not the scrub
    /// target. When the landed frame is presented (the player is playing or paused at the position)
    /// the target IS the on-screen frame, so settle onto it. While the player is still buffering
    /// toward the target (`waitingToPlayAtSpecifiedRate`, a queued-burst chase on heavy 4K) the
    /// picture is frozen behind the target: settling would park `sourceTime` up to tens of seconds
    /// ahead of the frame for the whole chase, because the 100 ms periodic observer is silent while
    /// buffering and cannot walk it back, so any host pacing cues off `sourceTime` renders them over a
    /// stale frame (rrgomes' report). Hold instead; the observer settles `sourceTime` onto the target
    /// when playback resumes and the frame is delivered. This also keeps `abs(currentTime - sourceTime)`
    /// honest as a "converging" gap hosts can gate cue rendering on, instead of collapsing it at every
    /// landing while the picture is still behind.
    nonisolated static func seekLandingSettlesToTarget(bufferingTowardTarget: Bool) -> Bool {
        !bufferingTowardTarget
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

    /// Detached reader that decodes ALL embedded text subtitle streams in one side-demuxer pass into their
    /// ordinal's NativeSubtitleCueStore (#55, all-tracks). Parallel to the packet-store drainer (which drives
    /// subtitleCues for the active track with full styling). Cancelled on stop/clear/load.
    var nativeSubtitleReadersTask: Task<Void, Never>?

    /// Abort handle for the native multi-decode side demuxer. markClosed unblocks AVIO reconnect loops
    /// (mirrors the old primary side-demuxer teardown).
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

    /// Off-main declaration of the AVAudioSession category (#114). `setCategory` /
    /// `setSupportsMultichannelContent` are XPC round-trips to mediaserverd; running them on the main
    /// thread while the session is already active (a second playback in the same app session, or a live
    /// route like AirPods) trips Xcode's hang-risk diagnostic and can block the watchdog. The category
    /// only has to be declared before the FIRST activation, and nothing reads it synchronously at init,
    /// so we run the pair on a detached task and every load path awaits it before it can activate. This
    /// keeps issue #24's "declare early, never activate at init" contract; only the blocking XPC call
    /// leaves the main thread. The closure captures no engine state, so it holds no reference to `self`.
    private var audioSessionCategoryTask: Task<Void, Never>?

    #if os(iOS) || os(tvOS)
    /// Route-sharing policy the engine declares with the session category. Platform-split (#116):
    /// tvOS keeps `.longFormAudio` for HDMI route negotiation (#24); on iOS that policy marks the
    /// process as a long-form audio client, which pins AVKit's
    /// `AVPictureInPictureController.isPictureInPicturePossible` to false for any host-built PiP
    /// controller around the engine's player layer, so iOS declares `.default`.
    #if os(tvOS)
    nonisolated static let audioSessionRouteSharingPolicy: AVAudioSession.RouteSharingPolicy = .longFormAudio
    #else
    nonisolated static let audioSessionRouteSharingPolicy: AVAudioSession.RouteSharingPolicy = .default
    #endif
    #endif

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
        //
        // Issue #114: the declaration runs off the main thread. See `audioSessionCategoryTask`.
        #if os(iOS) || os(tvOS)
        audioSessionCategoryTask = Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback, policy: AetherEngine.audioSessionRouteSharingPolicy)
                try session.setSupportsMultichannelContent(true)
                EngineLog.emit("[AetherEngine] AVAudioSession: category set off-main, not activated (AVKit drives activation) policy=\(AetherEngine.audioSessionRouteSharingPolicy.rawValue) maxChannels=\(session.maximumOutputNumberOfChannels) output=\(session.outputNumberOfChannels)", category: .engine)
            } catch {
                EngineLog.emit("[AetherEngine] AVAudioSession setup error: \(error)", category: .engine)
            }
        }
        #endif

        setupLifecycleObservers()
    }

    /// Await the off-main category declaration (#114) so it is guaranteed complete before the first
    /// AVAudioSession activation. Idempotent: once the task has finished, `.value` returns immediately;
    /// nil on macOS (no session setup) returns immediately too.
    func awaitAudioSessionCategoryConfigured() async {
        await audioSessionCategoryTask?.value
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
        // AE#158: while a PiP window is live, the running item must survive this load's teardown or the
        // system closes the window; the loopback host.load callsite finishes the handover (inPlaceSwap).
        let handOverInPlace = Self.shouldHandOverItemInPlace(pipActive: pictureInPictureActive,
                                                             priorBackendWasNative: priorBackendWasNative)
        pendingInPlaceItemHandover = handOverInPlace
        // #128 follow-up: preserve the previous session's display criteria across the load seam. Nil-ing it
        // here bounces the panel through SDR before apply() re-negotiates the same mode on video->video
        // reloads. Sessions that never reach apply() clear a stale criteria via loadDisplayCriteriaAction
        // (audio-only fast path, suppressed hosts); a load() that throws before routing leaves it for stop().
        stopInternal(resetDisplayCriteria: false, keepNativeHost: priorBackendWasNative, keepCurrentItem: handOverInPlace)
        // #35/#93: a genuinely new item has not rendered yet; re-arm the cold-startup wedge suspension.
        // Scrub/seek/producer-restart never route through load(), so mid-stream #93 detection stays armed.
        hasRenderedFirstFrameMirror.set(false)
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
        remoteHLSSubtitleDiscoveryTask?.cancel()
        remoteHLSSubtitleDiscoveryTask = nil
        stallRecoveryWindowUntil = .distantPast
        stallRecoveryReasserts = 0
        stallReengageTask?.cancel()
        stallReengageTask = nil
        itemDeathConfirmTask?.cancel()
        itemDeathConfirmTask = nil
        itemDeathReviveGate = ItemDeathReviveGate(maxAttempts: 3)
        masterFallbackUsed = false
        nativeSubtitleReanchorTask?.cancel()
        nativeSubtitleReanchorTask = nil
        setPendingRecoverySeekTarget(nil)
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
        sourceDVProfile = nil
        sourceVideoFrameRate = nil
        sourceVideoBitrate = 0
        sourceVideoWidth = 0
        sourceVideoHeight = 0

        // #114: guarantee the AVAudioSession category is declared (off-main, from init) before any branch
        // below can activate the session: AVKit on the native/remote-HLS paths, activateRendererAudioSession()
        // on the SW and audio paths. The task is short and typically already complete, so this rarely suspends.
        await awaitAudioSessionCategoryConfigured()

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
        var detectedDVProfileNum: Int? = nil
        var detectedRate: Double? = nil
        var detectedVideoBitrate: Int64 = 0
        var detectedDVProfile: Bool = false
        var detectedCodecID: AVCodecID = AV_CODEC_ID_NONE
        var detectedFieldOrder: AVFieldOrder = AV_FIELD_UNKNOWN
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
        var probeFailure: Error?
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
                detectedDVProfileNum = Self.dvProfile(stream: stream)
                detectedCodecID = stream.pointee.codecpar.pointee.codec_id
                detectedFieldOrder = stream.pointee.codecpar.pointee.field_order
                sourceVideoWidth = stream.pointee.codecpar.pointee.width
                sourceVideoHeight = stream.pointee.codecpar.pointee.height
                detectedVideoBitrate = probe.declaredBitrate(stream: stream)
                lastDetectedVideoCodec = detectedCodecID
            }
            probedAudioTracks = probe.audioTrackInfos()
            probedSubtitleTracks = probe.subtitleTrackInfos()
            probedDefaultAudioIndex = probe.audioStreamIndex
            // Ownership transfers to loadNative/loadSoftware, which adopt the probe for reuse
            // or open fresh if the probe failed.
        } catch {
            probeFailure = error
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

        // AE#140: an HLS playlist URL misrouted onto the raw-byte live path. The AVIOReader detected the
        // #EXTM3U body and failed closed instead of looping its endless-feed reconnect forever. Surface a
        // typed, actionable rejection so the host routes m3u8 through LoadOptions.nativeRemoteHLS or
        // HLSLiveIngestReader, not the generic isLive raw path.
        if let readerError = probeFailure as? AVIOReaderError, case .hlsPlaylistOnRawLivePath = readerError {
            state = .error("HLS playlist supplied to the raw live path. Use LoadOptions.nativeRemoteHLS or HLSLiveIngestReader for m3u8 sources.")
            throw AetherEngineError.hlsPlaylistOnRawLivePath
        }

        // AE#154: a non-live HLS playlist on the loopback path. FFmpeg (--disable-network) can never
        // demux it (see AVIOReaderError.hlsPlaylistOnVODPath); remote HLS is AVPlayer's native
        // domain, so reroute this load onto the nativeRemoteHLS bypass instead of surfacing the
        // former bare AVERROR_INVALIDDATA. loadedOptions flips so every downstream consumer
        // (audio-tap reader selection, seek paths) sees a genuine remote-HLS session.
        if RemoteHLSMediaSelection.shouldReroute(probeFailure: probeFailure, isCustomSource: isCustomSource),
           case .url(let hlsURL) = source {
            EngineLog.emit("[AetherEngine] AE#154: HLS playlist on the VOD loopback path; rerouting to the native remote-HLS bypass", category: .engine)
            loadedOptions.nativeRemoteHLS = true
            do {
                try await loadRemoteHLS(url: hlsURL, options: loadedOptions, startPosition: startPosition)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                state = .error("Failed to load: \(error.localizedDescription)")
                throw error
            }
            return nil
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
        sourceDVProfile = detectedDVProfileNum
        sourceVideoFrameRate = detectedRate
        sourceVideoBitrate = detectedVideoBitrate
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
            // The load seam preserves display criteria (#128 follow-up); an audio-only session never calls
            // apply(), so clear a criteria the previous video session left applied. The engine is a
            // process-wide singleton; without this, music playback keeps the panel in DV/HDR.
            if Self.loadDisplayCriteriaAction(suppressDisplayCriteria: options.suppressDisplayCriteria, audioOnlyPath: true) == .clearStale {
                displayCriteria.reset()
            }
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
                    // #124: a paused mount skips autostart; loadAudioNative's host.$isReady settles .paused.
                    if Self.loadPerformsAutostart(options) {
                        audioAVPlayerHost?.play()
                        state = .playing
                    }
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
                    // #124: a paused mount skips autostart; loadAudio's host.$isReady settles .paused.
                    if Self.loadPerformsAutostart(options) {
                        audioHost?.play()
                        state = .playing
                    }
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
        // #35: remember whether an actual SDR->HDR panel switch happened this load. The cold-DV-master
        // startup-readiness gate only arms on a real switch, when the DV/HDCP decode path is still
        // warming and the served master resolves 0 tracks / fails -11819; a warm start (no switch) keeps
        // the unchanged immediate-play path.
        var didSwitchPanel = false
        // #133: when apply() reports the criteria are already active (same-format zap), the panel never
        // starts a switch, so the post-load play-gate waitForSwitch() below has nothing to settle and would
        // otherwise burn its full ~3s cap on unobservable-DV panels. Skip it in exactly that case.
        var criteriaUnchanged = false
        switch Self.loadDisplayCriteriaAction(suppressDisplayCriteria: options.suppressDisplayCriteria, audioOnlyPath: false) {
        case .applyFresh:
            let codecTag: FourCharCode? = detectedDVProfile ? 0x64766831 : nil
            switch displayCriteria.apply(
                format: effectiveFormat,
                frameRate: snappedRate,
                codecTag: codecTag,
                omitColorExtensions: options.omitCriteriaColorExtensions
            ) {
            case .willSwitch:
                didSwitchPanel = true
                await displayCriteria.waitForSwitch()
                // Superseded during panel handshake: close local probe and unwind.
                if loadGeneration != gen {
                    probe.markClosed()
                    if probeOpened {
                        Task.detached { [probe] in probe.close() }
                    }
                    try checkLoadCurrent(gen)
                }
            case .applied:
                break
            case .unchanged:
                criteriaUnchanged = true
            }
        case .clearStale:
            // Suppressed host: the load seam preserved the criteria (#128 follow-up), and AVKit writes its
            // own from the AVPlayerItem formatDescription later. Clear a leftover engine criteria now
            // (didApply-gated no-op for hosts that always suppress) so the two writers can't fight.
            displayCriteria.reset()
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
        // #107: interlaced H.264 joins MPEG-2/VC-1 on the software path so DeinterlaceFilter (bwdif)
        // can deinterlace it; tvOS AVPlayer does not. Decision is pure and unit-tested in
        // VideoRoutingPolicyTests. deint=interlaced passes progressive frames through untouched, so a
        // mis-signalled progressive stream only pays an unnecessary SW decode, never a wrong deinterlace.
        // #150: some live TS channels are interlaced at the SPS level (frame_mbs_only_flag=0) but the
        // demuxer's field_order probe stays UNKNOWN, silently defeating the #107 rule; consult the SPS
        // from codecpar extradata as the tie-breaker.
        var spsIndicatesInterlaced = false
        if detectedCodecID == AV_CODEC_ID_H264, detectedFieldOrder == AV_FIELD_UNKNOWN,
           probeOpened,
           let vStream = probe.stream(at: probe.videoStreamIndex),
           let codecpar = vStream.pointee.codecpar,
           let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 {
            let bytes = Array(UnsafeBufferPointer(start: extradata, count: Int(codecpar.pointee.extradata_size)))
            spsIndicatesInterlaced = VideoRoutingPolicy.spsIndicatesInterlaced(extradata: bytes)
            if spsIndicatesInterlaced {
                EngineLog.emit(
                    "[AetherEngine] fieldOrder=UNKNOWN but SPS frame_mbs_only_flag=0; "
                    + "treating as interlaced for routing (#150)",
                    category: .engine
                )
            }
        }
        var useSoftwarePath = VideoRoutingPolicy.requiresSoftwarePath(
            codecID: detectedCodecID,
            fieldOrder: detectedFieldOrder,
            av1Available: VTCapabilityProbe.av1Available,
            spsIndicatesInterlaced: spsIndicatesInterlaced
        )
        // #2: an H.264 / HEVC format AVPlayer accepts at the HLS CODECS level but VideoToolbox can't
        // hardware-decode (H.264 High 4:2:2/4:4:4/High-10, HEVC Rext on Intel Macs / older Apple TV) reaches
        // readyToPlay then renders nothing on the native path. QuickTime plays it via its own software decoder;
        // there is no analogous fallback on the native route, so route it to the SoftwarePlaybackHost
        // (libavcodec), which decodes these profiles. VOD only: forced-native live keeps its verified path, and
        // broadcast H.264 / HEVC is HW-decodable. Apple Silicon HW-decodes these, so the probe keeps them native.
        if !useSoftwarePath, !options.isLive, probeOpened,
           let vStream = probe.stream(at: probe.videoStreamIndex),
           let codecpar = vStream.pointee.codecpar,
           VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
               codecID: detectedCodecID,
               canHardwareDecode: VTCapabilityProbe.canHardwareDecode(codecpar: codecpar)) {
            useSoftwarePath = true
            EngineLog.emit(
                "[AetherEngine] codec=\(detectedCodecID.rawValue) not hardware-decodable by "
                + "VideoToolbox; routing to the software path so it plays instead of a black screen (#2)",
                category: .engine
            )
        }
        // Forward-only sources can't serve the native path's seeks (cue prewarm, segment seeks).
        // Covers custom readers AND URL sources whose AVIOReader resolved no size and degraded to
        // the forward-only streaming reader (#126: unknown-length HTTP MP4 produced zero segments).
        // Live sources are exempt: the live producer never seeks backward, scrub previews come from
        // the DVR segment cache, and audio-switch is already no-op for forward-only sources.
        if !probe.isSourceSeekable && !options.isLive {
            useSoftwarePath = true
            EngineLog.emit("[AetherEngine] source is forward-only, forcing software path", category: .engine)
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
                // #124: a paused mount skips autostart; loadSoftware's host.$isReady settles .paused.
                if Self.loadPerformsAutostart(options) {
                    softwareHost?.play()
                    state = .playing
                }
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
                // #133: unchanged criteria (same-format zap) mean the panel is already in the target mode and
                // neither the engine nor AVKit will switch it, so there is nothing to settle here. Skipping
                // avoids Stage 1's blind 1s (and, on unobservable-DV panels, the full ~3s cap) on every zap.
                if !criteriaUnchanged {
                    await displayCriteria.waitForSwitch()
                }
                try checkLoadCurrent(gen)
                // automaticallyWaitsToMinimizeStalling=true (default) handles play-before-ready.
                // #35: on a real SDR->HDR switch while serving a VOD master, drive the bounded
                // cold-start readiness gate (play -> poll -> reload master -> media fallback) instead
                // of an unconditional play(); the gate calls play() itself. Warm/live/media paths keep
                // the immediate play().
                // #124: a paused mount skips the terminal play() AND the cold-start readiness gate
                // (an autostart-path recovery: it plays to poll readiness). loadNative wired
                // host.$isReady, which settles .loading -> .paused; the host resumes later with play().
                if Self.loadPerformsAutostart(options) {
                    if didSwitchPanel, let session = nativeVideoSession,
                       session.servingMasterPlaylist, !options.isLive {
                        try await runStartupReadinessGate(
                            session: session, position: startPosition ?? 0, gen: gen)
                    } else {
                        nativeHost?.play()
                    }
                    state = .playing
                }
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
        resumeAfterInterruption = false
        activeTransportHost?.pause()
        isBuffering = false
        if state == .playing {
            state = .paused
        }
        #if os(iOS)
        // Paused while backgrounded with no PiP: the app will idle-suspend, so release the video pipeline
        // (wedge-safe, mirrors the unconditional background teardown). Audio backends are already spared.
        // #127: same grace window as the didEnterBackground path, so pause-after-background quick switches
        // also skip the rebuild.
        if isBackgrounded && !pictureInPictureActive && !audioAVPlayerActive && audioHost == nil && softwareHost == nil {
            switch Self.backgroundStep(
                action: .teardownVideo,
                state: state,
                supportsGraceWindow: true,
                graceSeconds: backgroundTeardownGraceSeconds
            ) {
            case .deferTeardown(let seconds):
                scheduleBackgroundGraceTeardown(afterSeconds: seconds)
            default:
                Task { @MainActor in await self.teardownVideoForBackground() }
            }
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
        // #127: pre-ready native item (background-teardown reload, cold start): forwarding the seek now
        // would clamp to 0 against empty seekable ranges and replace load()'s pending startPosition seek.
        // Stash the latest target (publishing it optimistically so scrub UI follows) and replay at readiness.
        if Self.shouldDeferHostSeek(
            nativeSessionActive: nativeHost != nil && softwareHost == nil && audioHost == nil && !audioAVPlayerActive,
            isLive: isLive,
            nativeHostReady: nativeHost?.isReady ?? true
        ) {
            pendingPreReadySeekSeconds = seconds
            clock.currentTime = max(0, min(seconds, duration))
            EngineLog.emit("[AetherEngine] seek(to:\(String(format: "%.2f", seconds))) deferred until item ready (#127)", category: .engine)
            return
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
            if let nativeHost {
                reconcileNativeSeekTransport(host: nativeHost, isStarved: false)
            } else {
                state = .playing
            }
            setProgrammaticSeek(inFlight: false, target: nil)
            return
        }
        // Convert the (display-axis) target to AVPlayer's HLS clock. The origin re-adds a disc title's clip-0
        // STC base so `target` (0-based, matching duration) lands on the source-PTS shift the producer subtracts,
        // i.e. clockTarget == the 0-based playlist time (AE#105). Origin 0 off disc, so this stays
        // `target - playlistShiftSeconds` for normal VOD; SW/audio hosts run on source time (shift 0), no-op.
        let clockTarget = PresentationAxis.source(displayTime: target, origin: sourcePresentationOrigin) - playlistShiftSeconds
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
            // #93 retest: remember the target as recovery intent BEFORE awaiting; a wedged seek
            // never lands and the recovery chain must aim here, not at the frozen clock.
            setPendingRecoverySeekTarget(clockTarget)
            pendingSeekProgressAccum = 0
            let renderedAtSeekStart = nativeHost?.renderedTime ?? 0
            pendingSeekInitialRenderedPosition = renderedAtSeekStart
            lastRenderedForPendingSeek = renderedAtSeekStart
            // Await real AVPlayer landing so isSeeking spans it (#37/#38), but bound the wait (#65): a seek
            // AVPlayer can never land (producer-wedge starvation) must not leave the optimistic clock latched
            // forever. A normal/slow-but-buffering seek lands or keeps buffering well within the budget.
            let landed = await nativeHost?.seek(to: clockTarget,
                                                deadlineSeconds: Self.nativeSeekReconcileBudgetSeconds) ?? true
            if !landed {
                // Deadline expired. Only the surviving (winning) generation reconciles; a superseded seek
                // returns at the guard below and lets the newer seek own the final state.
                guard loadGeneration == gen, seekGeneration == seekGen else { return }
                guard let host = nativeHost else {
                    EngineLog.emit(
                        "[AetherEngine] seek deadline expired after native host teardown",
                        category: .engine
                    )
                    return
                }
                pendingRecoverySeekDeadlineExpired = true
                // Eight seconds is a hard interactive cap. A second unbounded AVPlayer seek could
                // inherit repeated 20 s source stalls and leave the caller suspended for 40+ s.
                // Keep the original pending seek alive. Re-anchor only a starved producer; a
                // healthy-but-slow producer is already filling toward the target and restarting it
                // would throw away useful progress.
                let avpReal = host.renderedTime
                // The deadline continuation and AVPlayer completion are both MainActor jobs. If the
                // completion published renderedTime first, its sink still saw deadlineExpired=false.
                // Catch that ordering now; otherwise the later publication will settle through the sink.
                if Self.shouldCatchUpDeadlineLanding(
                    renderedTimePublished: host.latestSeekRenderedTimePublished
                ),
                   settleRecoveryClockIfRenderedTargetLanded(
                       rendered: avpReal,
                       shift: playlistShiftSeconds,
                       completionRenderedTimePublished: true
                   ) {
                    nativeClockSeconds = avpReal
                    clock.sourceTime = avpReal + playlistShiftSeconds
                    setProgrammaticSeek(inFlight: false, target: nil)
                    reconcileNativeSeekTransport(host: host, isStarved: false)
                    EngineLog.emit(
                        "[AetherEngine] seek landed while deadline ownership transferred; "
                        + "reconciled from rendered \(String(format: "%.2f", avpReal))s",
                        category: .engine
                    )
                    return
                }
                let wasStarved = seekIsWedged(
                    renderedTime: avpReal, bufferedEnd: host.bufferedEnd)
                // AE#141: a progressing producer is only worth preserving when its march can
                // actually deliver the pending target. A far-forward target beyond coverage
                // (640 s target, march at ~316 s) rides 3x30 s serve timeouts into item death
                // if left to "land late"; the old-position buffer health cannot see that.
                let targetBeyondCoverage: Bool = {
                    guard let target = pendingRecoverySeekClockTarget,
                          let session = nativeVideoSession else { return false }
                    return !session.producerCoversPlaylistTime(target)
                }()
                let needsReanchor = Self.shouldReanchorProducerAfterSeekDeadline(
                    isStarved: wasStarved, targetBeyondProducerCoverage: targetBeyondCoverage)
                nativeClockSeconds = avpReal
                // currentTime on the 0-based display axis (AE#105 origin); sourceTime stays source PTS for subs.
                clock.currentTime = PresentationAxis.display(sourcePTS: avpReal + playlistShiftSeconds,
                                                             origin: sourcePresentationOrigin)
                clock.sourceTime = avpReal + playlistShiftSeconds
                setProgrammaticSeek(inFlight: false, target: nil)
                reconcileNativeSeekTransport(host: host, isStarved: needsReanchor)
                let recoveryAnchor = Self.recoveryAnchorPosition(
                    frozenPosition: avpReal, pendingSeekTarget: pendingRecoverySeekClockTarget,
                    currentRendered: avpReal)
                if needsReanchor {
                    reanchorProducerToPlaylistTime(recoveryAnchor)
                    // The playhead will jump when the restarted producer lets the pending seek land.
                    reanchorSubtitleOverlays()
                    pendingRecoverySeekSubtitlesReanchored = true
                }
                // pendingRecoverySeekClockTarget deliberately survives this reconcile: the UI
                // clock gives up the phantom target, but recovery keeps aiming there until rendered
                // output reaches it or organic playback proves AVPlayer abandoned the seek.
                let reason = wasStarved
                    ? "starved"
                    : (targetBeyondCoverage
                        ? "old position still buffered, target beyond producer coverage"
                        : "old position still buffered")
                EngineLog.emit(
                    "[AetherEngine] seek did not land within \(Self.nativeSeekReconcileBudgetSeconds)s "
                    + "(\(reason), "
                    + "rendered=\(String(format: "%.2f", avpReal))s "
                    + "buffered=\(String(format: "%.2f", host.bufferedEnd))s); reconciled clock"
                    + (needsReanchor
                        ? " and re-anchored producer at \(String(format: "%.2f", recoveryAnchor))s"
                        : " without restarting the progressing producer"),
                    category: .engine
                )
                return
            }
        }
        // Guard: stop/load during the await tore the session down; writing clock state would publish a phantom.
        // A superseding seek owns the final state.
        guard loadGeneration == gen, seekGeneration == seekGen else { return }
        setPendingRecoverySeekTarget(nil)
        nativeClockSeconds = clockTarget
        clock.currentTime = target
        // sourceTime + subtitle re-arm need true source PTS; map the display target back (0 off disc). AE#105.
        let landedSourcePTS = PresentationAxis.source(displayTime: target, origin: sourcePresentationOrigin)
        // #123: only settle sourceTime onto the target when the landed frame is actually presented (see
        // applySeekFinalizeSourceTime); while buffering toward it the picture is frozen behind the target,
        // so hold sourceTime on the rendered frame and let the $renderedTime sink settle it when the frame
        // is delivered.
        applySeekFinalizeSourceTime(target: landedSourcePTS,
                                    bufferingTowardTarget: nativeHost?.isBufferingTowardSeekTarget ?? false)

        // #100 + #96: the playhead jumped; re-anchor the overlay subtitle readers at the landed source-PTS.
        reanchorSubtitleOverlays()

        // Seek has physically landed. #122: preserve the transport intent in effect when the seek
        // was issued: a scrub started while paused lands paused, so the engine never reports playing
        // after a paused scrub and the #93 recovery reassert can't misread the paused landing as a
        // spurious pause and call host.play(). A seek on any non-native host keeps the prior
        // `.playing` default (those paths do not carry the durable intent and are not affected).
        if let nativeHost {
            reconcileNativeSeekTransport(host: nativeHost, isStarved: false)
        } else {
            state = .playing
        }
        setProgrammaticSeek(inFlight: false, target: nil)
    }

    /// #112 rework: the playhead jumped (seek landing or wedge reconcile). Reset the PGS
    /// stale-arrival gates (#100: a held stale arrival belongs to the old position) and reset the
    /// CC tap at the discontinuity. Drained overlay channels keep their retained cues: a backward
    /// in-window seek re-displays instantly (the old retained-coverage semantics), and the drainer's
    /// jump detection rebuilds its decoder and re-decodes the window around the new position on the
    /// next tick.
    func reanchorSubtitleOverlays() {
        pgsStaleArrivalGates = [:]
        if activeEmbeddedSubtitleStreamIndex >= 0,
           activeSubtitleStreamIsClosedCaption(activeEmbeddedSubtitleStreamIndex) {
            subtitleCues = []
            ccCueSnapshot = []
            closedCaptionTap?.requestReset()
        }
    }

    /// Re-base the loopback producer onto the recovery position after a seek deadline, so the
    /// segments AVPlayer is waiting for get produced. requestRestart does blocking teardown
    /// (old.stop + waitForFinish up to 5s) and is designed to run off-main, so dispatch it detached.
    private func reanchorProducerToPlaylistTime(_ seconds: Double) {
        guard let session = nativeVideoSession else { return }
        Task.detached {
            let idx = session.segmentIndexForPlaylistTime(seconds)
            // Authoritative re-anchor: deadline recovery must win the coalescer over any stale
            // in-flight scrub target.
            session.requestRestart(at: idx, authoritative: true)
        }
    }

    /// #129 kept a progressing producer at the seek deadline (restarting discards useful fill);
    /// AE#141 narrows that: preservation only pays when the march can reach the pending target.
    nonisolated static func shouldReanchorProducerAfterSeekDeadline(
        isStarved: Bool, targetBeyondProducerCoverage: Bool
    ) -> Bool {
        isStarved || targetBeyondProducerCoverage
    }

    nonisolated static func shouldCatchUpDeadlineLanding(
        renderedTimePublished: Bool
    ) -> Bool {
        renderedTimePublished
    }

    /// Deprecated alias. The engine clock is now unified onto source PTS; prefer `seek(to:)` in new code.
    @available(*, deprecated, renamed: "seek(to:)")
    public func seek(toSourceTime seconds: Double) async {
        await seek(to: seconds)
    }

    /// Stop playback and tear the session down.
    ///
    /// - Parameter resetDisplayCriteria: `true` (default) returns the panel to its default HDMI mode
    ///   (tvOS). Pass `false` for a stop that hands off to another load(): the current criteria stays on
    ///   AVDisplayManager, so a same-mode follow-up overwrites it in place instead of bouncing the panel
    ///   through SDR (#128). The caller owns the follow-up; if no load() happens after all, the app UI
    ///   stays in the playback mode until a plain stop() clears it. Note that back-to-back load() calls
    ///   preserve the criteria on their own; the flag only matters when stop() is called between items.
    public func stop(resetDisplayCriteria: Bool = true) {
        stopInternal(resetDisplayCriteria: resetDisplayCriteria)
        state = .idle
        clock.currentTime = 0
        clock.bufferedPosition = 0
        clock.progress = 0
        sourcePresentationOrigin = 0  // AE#105: clear disc display-origin so the next source starts on a clean axis.
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
        remoteHLSSubtitleDiscoveryTask?.cancel()
        remoteHLSSubtitleDiscoveryTask = nil
        // Font attachments are session-scoped but must survive stopInternal (audio-track-switch skips the probe;
        // clearing in stopInternal would leave the session with an empty font list after any audio switch).
        fontAttachments = []
        videoFormat = .sdr
        sourceVideoFormat = .sdr
        sourceDVProfile = nil
        sourceVideoFrameRate = nil
        sourceVideoBitrate = 0
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
        // A wired HDMI external display (USB-C/Lightning-to-HDMI adapter, Sodalite#34) keeps the device as the
        // stream origin: 127.0.0.1 loopback stays reachable and the panel carries DV/HDR (DrHurt measured his
        // adapter exposing SDR/HDR/DV in Display & Brightness), so AVPlayer just pushes the already-master
        // playlist item out fullscreen. No LAN-IP/MEDIA swap, which would strip VIDEO-RANGE=PQ down to SDR.
        // Only a wireless AirPlay receiver (#86) needs that reload (loopback unreachable, DV/HDR master rejected).
        let wired = active && Self.isWiredHDMIExternalDisplay()
        if wired {
            EngineLog.emit("[AirPlay] external playback active on wired HDMI -> keep loopback + master (DV/HDR passthrough)", category: .engine)
        }
        let wantAirPlay = active && !wired
        guard wantAirPlay != airPlayActive else { return }
        airPlayActive = wantAirPlay
        // Loopback native path only: remote-HLS is already receiver-reachable. Reload so loadNative rebuilds
        // the playback URL on the LAN IP + media playlist (active) or back on 127.0.0.1 master/media (inactive).
        guard playbackBackend == .native, !loadedOptions.nativeRemoteHLS, loadedURL != nil else { return }
        EngineLog.emit("[AirPlay] external playback \(wantAirPlay ? "active (wireless) -> LAN media reload" : "ended -> loopback reload")", category: .engine)
        Task { try? await reloadAtCurrentPosition() }
    }

    /// True when a wired HDMI external display is the active audio output (USB-C/Lightning-to-HDMI adapter).
    /// `usesExternalPlaybackWhileExternalScreenIsActive` flips `isExternalPlaybackActive` for both a wired screen
    /// and a wireless AirPlay receiver; the audio route tells them apart (`.HDMI` vs `.airPlay`). Wired keeps the
    /// loopback + master playlist (Sodalite#34); wireless takes the LAN-IP + MEDIA path (#86). Mirrors the port
    /// inspection in NativeAVPlayerHost.dumpAudioRoute. iOS-only; external playback never engages on tvOS.
    nonisolated private static func isWiredHDMIExternalDisplay() -> Bool {
        #if os(iOS)
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .HDMI }
        #else
        return false
        #endif
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
    ///   never settles and burns the full settle timeout (~12 s of
    ///   black-screen latency per audio switch on the old fixed 5 s
    ///   poll; capped at ~2 s since #117, but still worth skipping).
    func stopInternal(resetDisplayCriteria: Bool = true, keepNativeHost: Bool = false, keepCustomReader: Bool = false, keepCurrentItem: Bool = false) {
        // Bump generation to invalidate in-flight load() checkpoints.
        loadGeneration &+= 1
        resumeAfterInterruption = false
        // tearDown() unloads the AVPlayer item before the loopback server is torn down to avoid noisy races.
        // keepNativeHost preserves NativeAVPlayerHost + currentAVPlayer across native->native reloads:
        // AVKit binds its MediaRemote registration to the AVPlayer instance once and never re-registers
        // against a swapped player ("Code=14 client callback"); reusing the instance keeps Control Center
        // populated across the seam (issue #15). SW-path callers must release the preserved host themselves.
        memoryProbeTask?.cancel()
        memoryProbeTask = nil
        liveReloadWatchdogTask?.cancel()
        liveReloadWatchdogTask = nil
        // #95: stop the tap reader before the session (and its SegmentCache) goes away.
        audioTapController?.teardown()
        audioTapController = nil
        // markClosed() aborts a probe blocked in avformat_open_input/find_stream_info (lock-free, idempotent).
        inFlightProbeDemuxer?.markClosed()
        liveTelemetrySampler?.stop()
        liveTelemetrySampler = nil
        diagnostics.liveTelemetry = nil
        nativeCancellables.removeAll()
        // AE#158: keepCurrentItem defers the item detach to the next host.load(inPlaceSwap:) so a
        // system PiP window never sees a nil-item gap across a native->native load. Only meaningful
        // together with keepNativeHost; load() computes it via shouldHandOverItemInPlace.
        if !keepCurrentItem {
            nativeHost?.tearDown()
        }
        if !keepNativeHost {
            nativeHost = nil
            currentAVPlayer = nil
        }
        nativeVideoSession?.stop()
        nativeVideoSession = nil
        nativeSubtitleRenditionsServed = false
        extractorYieldState.deactivate()
        setPendingRecoverySeekTarget(nil)
        // #127: readiness + deferred host seeks are session-scoped; the host-side sink can't clear them
        // once nativeCancellables are gone.
        isSessionReady = false
        pendingPreReadySeekSeconds = nil

        // Shut down cache-backed scrub-thumbnail FrameExtractors with the session.
        let scrubThumbs = scrubThumbnailExtractors
        scrubThumbnailExtractors.removeAll()
        for entry in scrubThumbs {
            Task { await entry.extractor.shutdown() }
        }

        softwareCancellables.removeAll()
        softwareHost?.stop()
        softwarePiPSource = nil
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
        stopSubtitleDrainer()                  // #112 rework: both channels
        subtitleDrainTargets.removeAll()
        softwareSubtitlePacketStore = nil
        activeEmbeddedSubtitleStreamIndex = -1
        activeSubtitleTrackIndex = nil
        loadedSidecarURL = nil
        isSubtitleActive = false
        subtitleCues = []
        pgsStaleArrivalGates = [:]   // #100: both channels; a hold never survives the session
        sidecarASSHeader = nil
        isLoadingSubtitles = false
        nativeSubtitleTrackTable = []
        nativeSubtitleReapplyOrdinal = nil
        nativeSubtitleTracks = []
        nativeSubtitleReaderParams = nil
        cancelNativeSubtitleReaders()
        nativeSubtitleRenditionAvailable = false
        cancelSidecarTask(channel: .secondary)
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
                // an idle suspension.
                let keepAlive = Self.shouldKeepVideoAlive(enabled: self.backgroundPlaybackEnabled,
                                                          pipActive: self.pictureInPictureActive,
                                                          state: self.state)
                let supportsGrace = true
                #else
                self.isBackgrounded = true
                // tvOS: only an active PiP window defers the wedge-safe teardown (the system keeps the app
                // running while its PiP window lives); no grace window, no background-audio case. The
                // pictureInPictureActive didSet tears down the moment PiP ends while still backgrounded.
                let keepAlive = Self.shouldKeepVideoAliveTV(enabled: self.backgroundPlaybackEnabled,
                                                            pipActive: self.pictureInPictureActive)
                let supportsGrace = false
                #endif
                let action = Self.backgroundAction(
                    isAudioBackend: self.audioAVPlayerActive || self.audioHost != nil,
                    hasSoftwareHost: self.softwareHost != nil,
                    keepVideoAlive: keepAlive,
                    pipActive: self.pictureInPictureActive,
                    state: self.state
                )
                switch Self.backgroundStep(
                    action: action,
                    state: self.state,
                    supportsGraceWindow: supportsGrace,
                    graceSeconds: self.backgroundTeardownGraceSeconds
                ) {
                case .perform(.doNothing):
                    return
                case .perform(.enterSoftwareAudioOnly):
                    self.softwareHost?.enterBackgroundAudioOnly()
                case .perform(.teardownVideo):
                    await self.teardownVideoForBackground()
                case .deferTeardown(let seconds):
                    #if os(iOS)
                    self.scheduleBackgroundGraceTeardown(afterSeconds: seconds)
                    #endif
                }
            }
        }
        lifecycleObservers.append(bgObserver)
        let fgObserver = nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                #if os(iOS)
                self.cancelBackgroundGraceWindow()
                self.softwareHost?.exitBackgroundAudioOnly()
                #endif
                self.isBackgrounded = false
            }
        }
        lifecycleObservers.append(fgObserver)

        // Foreign-session interruption handling (Sodalite device-verify 2026-07-15): a live-camera
        // PiP re-claims the audio session on every play() and the system pauses AVPlayer ~10ms after
        // .playing (interruption BEGAN reason=default). The system pause never goes through pause(),
        // so the native host's durable playIntent (#122) survives the interruption and anchors the
        // resume decision. Resume fires on ENDED only when the system explicitly grants .shouldResume
        // (calls, Siri); sessions that end without it (the camera PiP closing) stay paused by design,
        // the user resumes manually. An explicit user pause() disarms the resume.
        let interruptionObserver = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            let began = (info[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            #if os(iOS)
            let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt).map(String.init) ?? "n/a"
            #else
            let reason = "n/a"
            #endif
            Task { @MainActor in
                guard let self else { return }
                let session = AVAudioSession.sharedInstance()
                if began {
                    let intent = self.nativeHost?.transportIntentIsPlaying ?? (self.state == .playing)
                    let stateEligible: Bool
                    switch self.state {
                    case .idle, .error: stateEligible = false
                    default: stateEligible = true
                    }
                    self.resumeAfterInterruption = intent && stateEligible
                    EngineLog.emit("[AetherEngine] AVAudioSession interruption BEGAN reason=\(reason) resumeArmed=\(self.resumeAfterInterruption) otherAudio=\(session.isOtherAudioPlaying) silenceHint=\(session.secondaryAudioShouldBeSilencedHint)", category: .engine)
                } else {
                    let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
                    // Background: only audio backends may resume (video is torn down / must not restart unseen).
                    #if os(iOS)
                    let backgroundSafe = !self.isBackgrounded
                        || self.audioAVPlayerActive || self.audioHost != nil || self.softwareHost != nil
                    #else
                    let backgroundSafe = true
                    #endif
                    let firing = self.resumeAfterInterruption && backgroundSafe && shouldResume
                    EngineLog.emit("[AetherEngine] AVAudioSession interruption ENDED shouldResume=\(shouldResume) otherAudio=\(session.isOtherAudioPlaying) resumeArmed=\(self.resumeAfterInterruption) autoResume=\(firing)", category: .engine)
                    if firing {
                        self.resumeAfterInterruption = false
                        self.play()
                    }
                }
            }
        }
        lifecycleObservers.append(interruptionObserver)
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

    #if os(iOS)
    // MARK: #127 paused-background grace window

    /// Hold the paused pipeline alive under a background-task assertion for the grace window, then
    /// re-evaluate and tear down. didBecomeActive cancels the window, making a quick app switch free.
    private func scheduleBackgroundGraceTeardown(afterSeconds seconds: Double) {
        guard backgroundGraceTask == nil else { return }  // window already armed
        let app = UIApplication.shared
        let assertion = app.beginBackgroundTask(withName: "AetherEngine.bgGraceWindow") { [weak self] in
            // System reclaimed the window early. UIKit calls this on the main thread; the synchronous
            // stopInternal releases the decode session, the 3.5 s socket drain is skipped (no time).
            MainActor.assumeIsolated {
                self?.expireBackgroundGraceNow()
            }
        }
        guard assertion != .invalid else {
            // Background execution unavailable: fall back to the immediate teardown.
            Task { @MainActor in await self.teardownVideoForBackground() }
            return
        }
        backgroundGraceAssertion = assertion
        // Clamp: the system allowance is ~30 s; longer values would just move the work into the
        // expiration backstop (and an unbounded host value must not overflow the ns conversion).
        let window = min(max(0, seconds), 60)
        EngineLog.emit("[AetherEngine] background grace window armed (\(String(format: "%.0f", window))s) before paused teardown (#127)", category: .engine)
        backgroundGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.fireBackgroundGraceTeardown()
        }
    }

    /// Grace expiry: re-evaluate the background action (PiP can start and lock-screen play can resume
    /// mid-window) and perform it without further deferral.
    private func fireBackgroundGraceTeardown() async {
        backgroundGraceTask = nil
        if isBackgrounded {
            switch currentBackgroundAction() {
            case .teardownVideo:
                EngineLog.emit("[AetherEngine] background grace window expired, tearing down paused pipeline (#127)", category: .engine)
                await teardownVideoForBackground()
            case .enterSoftwareAudioOnly:
                softwareHost?.enterBackgroundAudioOnly()
            case .doNothing:
                EngineLog.emit("[AetherEngine] background grace window expired, session now kept alive (#127)", category: .engine)
            }
        }
        endBackgroundGraceAssertion()
    }

    /// Expiration-handler backstop: synchronous minimal teardown before the assertion is force-ended.
    private func expireBackgroundGraceNow() {
        backgroundGraceTask?.cancel()
        backgroundGraceTask = nil
        if isBackgrounded, currentBackgroundAction() == .teardownVideo {
            EngineLog.emit("[AetherEngine] background grace assertion expired early, synchronous teardown (#127)", category: .engine)
            stopInternal(resetDisplayCriteria: false, keepNativeHost: true, keepCustomReader: true)
            state = .paused
        }
        endBackgroundGraceAssertion()
    }

    private func cancelBackgroundGraceWindow() {
        guard backgroundGraceTask != nil || backgroundGraceAssertion != .invalid else { return }
        backgroundGraceTask?.cancel()
        backgroundGraceTask = nil
        endBackgroundGraceAssertion()
        EngineLog.emit("[AetherEngine] background grace window cancelled, session survives the app switch (#127)", category: .engine)
    }

    private func endBackgroundGraceAssertion() {
        guard backgroundGraceAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundGraceAssertion)
        backgroundGraceAssertion = .invalid
    }

    /// Live recomputation of the keepalive + background action for grace-window re-evaluation.
    private func currentBackgroundAction() -> BackgroundAction {
        let keepAlive = Self.shouldKeepVideoAlive(
            enabled: backgroundPlaybackEnabled,
            pipActive: pictureInPictureActive,
            state: state
        )
        return Self.backgroundAction(
            isAudioBackend: audioAVPlayerActive || audioHost != nil,
            hasSoftwareHost: softwareHost != nil,
            keepVideoAlive: keepAlive,
            pipActive: pictureInPictureActive,
            state: state
        )
    }
    #endif
    #endif
}

// MARK: - Errors

public enum AetherEngineError: Error, LocalizedError {
    case noVideoStream
    case noAudioStream
    /// AE#140: an HLS playlist URL (m3u8) was handed to `load(isLive:)` on the generic raw-byte path.
    /// Route m3u8 sources through `LoadOptions.nativeRemoteHLS` or `HLSLiveIngestReader` instead.
    case hlsPlaylistOnRawLivePath

    public var errorDescription: String? {
        switch self {
        case .noVideoStream: return "No video stream in source"
        case .noAudioStream: return "No audio stream in source"
        case .hlsPlaylistOnRawLivePath:
            return "HLS playlist supplied to the raw live path. Use LoadOptions.nativeRemoteHLS or HLSLiveIngestReader for m3u8 sources."
        }
    }
}
