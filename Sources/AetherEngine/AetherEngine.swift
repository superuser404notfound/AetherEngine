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

    @Published public internal(set) var state: PlaybackState = .idle

    /// True while playback is stalled waiting for data after it had already
    /// begun (AVPlayer `timeControlStatus == .waitingToPlayAtSpecifiedRate`
    /// with play intent), i.e. a mid-playback rebuffer. Distinct from
    /// `state`, which deliberately keeps reporting `.playing` across a
    /// rebuffer so the play/pause icon does not flicker. Consumers that
    /// trust `currentTime` (scrubbers, A/V sync, multi-player coordinators)
    /// can gate on this to tell a stall from real playback (AetherEngine#35).
    /// Always false on the initial load spin-up (that is `state == .loading`).
    @Published public internal(set) var isBuffering: Bool = false

    /// True from the moment a seek begins until it **physically lands**,
    /// uniform across programmatic `seek(to:)` and native AVKit
    /// transport-bar scrubs. Unlike `state == .seeking` (which the engine
    /// optimistically flips back to `.playing` so a host UI does not stick
    /// on the spinner), this spans the real landing on the loopback-HLS
    /// native path, where the seek resolves seconds after the call. A host
    /// coordinating playback across devices can gate on this to tell a
    /// deliberate seek from a rebuffer or an underflow skip without
    /// inferring it from `currentTime` jumps (AetherEngine#38). Paired with
    /// `seekTarget`.
    @Published public internal(set) var isSeeking: Bool = false

    /// The source-PTS destination of the in-flight seek (the same axis as
    /// `currentTime`), or `nil` when no seek is in flight. Set at seek
    /// entry, cleared on the real landing. For native scrubs it is the
    /// time of the segment AVPlayer requested out of range (AetherEngine#38).
    @Published public internal(set) var seekTarget: Double? = nil

    /// Monotonic counter bumped at the entry of every programmatic
    /// `seek(to:)`. A seek finalizes its clock/state and clears the
    /// `isSeeking` signal only if its captured generation still matches,
    /// so a superseded seek's late landing cannot clobber the newer seek's
    /// in-flight state (the engine-side mirror of the host's guard).
    private var seekGeneration: UInt64 = 0

    /// The two independent in-flight sources `isSeeking` unions over. A
    /// programmatic `seek(to:)` and a native AVKit scrub are NOT mutually
    /// exclusive: a programmatic seek to a far target drives AVPlayer,
    /// which requests an out-of-range segment and triggers the same
    /// producer-restart path a transport-bar scrub does. Tracking them
    /// separately and OR-ing keeps `isSeeking` true until BOTH settle, so
    /// the native restart finishing (producer rebuilt) cannot drop the
    /// signal before a programmatic seek's AVPlayer landing, and vice
    /// versa. Routed through `setProgrammaticSeek`/`setNativeScrubSeek`.
    private var programmaticSeekInFlight = false
    private var nativeScrubSeekInFlight = false

    /// Publish `isSeeking`/`seekTarget` from the two in-flight sources.
    /// `target` updates `seekTarget` only while seeking; cleared to nil
    /// once both sources settle. Idempotent on `isSeeking` to avoid
    /// redundant Combine emissions.
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

    /// High-frequency playback clock (`currentTime`, `sourceTime`,
    /// live-edge fields). Deliberately a SEPARATE ObservableObject:
    /// its ~10 Hz ticks must not fire `objectWillChange` on the
    /// engine itself, or every engine-observing SwiftUI view
    /// re-renders per tick (tvOS native `Menu` dropdowns flicker,
    /// AetherEngine#29). Observe `clock` only in the leaf views that
    /// render time; see `PlaybackClock` for the usage guide.
    public let clock = PlaybackClock()

    /// Current playback position in seconds. Read-only convenience
    /// forwarder for polling; for push updates subscribe to
    /// `clock.$currentTime` (the engine's `objectWillChange` does NOT
    /// fire on clock ticks).
    public var currentTime: Double { clock.currentTime }

    @Published public internal(set) var duration: Double = 0

    /// Forwarder; see `clock.progress`.
    public var progress: Float { clock.progress }

    // internal(set): AetherEngine+Loading's post-load reconciliation
    // (syncPublishedAudioStateFromNativeSession) replaces the probe-derived
    // list with the side demuxer's tracks for demuxed-audio live sources.
    @Published public internal(set) var audioTracks: [TrackInfo] = []
    @Published public private(set) var subtitleTracks: [TrackInfo] = []
    /// Container metadata (tags + embedded cover) for the loaded source.
    /// nil while idle or when the source carries no metadata. Populated
    /// during `load(url:)` from the probe demuxer, before backend dispatch,
    /// so it is available for both audio and video sources.
    @Published public private(set) var metadata: MediaMetadata?
    /// Active audio track's container stream index (matches `TrackInfo.id`),
    /// or `nil` while no audio is wired (audio-less source or before the
    /// first `load(url:)` resolves). Updated synchronously when
    /// `selectAudioTrack(index:)` reloads the pipeline; the host's
    /// picker reflects what the engine actually muxed rather than the
    /// last optimistic UI write.
    @Published public internal(set) var activeAudioTrackIndex: Int?
    @Published public internal(set) var videoFormat: VideoFormat = .sdr

    /// Source-detected video range as read from the demuxer probe, before
    /// any panel clamping. Differs from `videoFormat` when the panel can't
    /// present the source (e.g. DV source on an SDR panel, or HDR source
    /// with Match Content off): there `videoFormat` reads `.sdr` because
    /// that's what's on screen, while `sourceVideoFormat` keeps reading
    /// `.dolbyVision` / `.hdr10` because that's what's in the file.
    ///
    /// Hosts that want to label media attributes (Stats for Nerds, file
    /// inspectors) should use this. Hosts that drive UI tied to what the
    /// panel is actually rendering (HDR badges, tone-mapping decisions)
    /// should keep using `videoFormat`.
    ///
    /// Late HDR10+ upgrades from T.35 SEI flip this from `.hdr10` to
    /// `.hdr10Plus` independent of `videoFormat`'s panel guard, because
    /// SEI detection is a source-side fact.
    @Published public internal(set) var sourceVideoFormat: VideoFormat = .sdr

    /// Which internal backend rendered the current session. Resolves
    /// to `.native` for AVPlayer-decodable sources (HEVC, H.264, plus
    /// AV1 on HW-AV1 devices) or `.software` when the source falls
    /// through to `SoftwarePlaybackHost` (SW dav1d for AV1 without HW,
    /// libavcodec for VP9, MPEG-4 Part 2, MPEG-2, VC-1). Kept on the
    /// public surface for diagnostic overlays and TestFlight badges;
    /// hosts should not switch on it.
    @Published public internal(set) var playbackBackend: PlaybackBackend = .none

    /// Timer-sampled diagnostics (`liveTelemetry`, 1 Hz). Deliberately
    /// a SEPARATE ObservableObject for the same reason as `clock`: a
    /// once-per-second sample must not fire `objectWillChange` on the
    /// engine itself, or every engine-observing SwiftUI view re-renders
    /// per sample for the whole session (AetherEngine#29 follow-up).
    /// Observe `diagnostics` only in stats overlays; see
    /// `EngineDiagnostics` for the usage guide.
    public let diagnostics = EngineDiagnostics()

    /// 1 Hz snapshot of live playback telemetry while the engine is
    /// `.playing` or `.paused`. `nil` while idle. Read-only convenience
    /// forwarder for polling; for push updates subscribe to
    /// `diagnostics.$liveTelemetry` (the engine's `objectWillChange`
    /// does NOT fire on telemetry samples).
    public var liveTelemetry: LiveTelemetry? { diagnostics.liveTelemetry }

    /// Human-readable identity of the video decoder currently in use,
    /// suitable for a "stats for nerds" UI. Examples:
    /// - `"VideoToolbox HEVC (HW)"` for the native AVPlayer path on
    ///   anything VideoToolbox can decode (HEVC, H.264, AV1 on HW-AV1
    ///   capable devices).
    /// - `"dav1d AV1 (SW)"` for AV1 falling through to the SW pipeline.
    /// - `"libavcodec VP9 (SW)"` for VP9.
    /// - `"libavcodec MPEG4 (SW)"` etc. for legacy codecs AVPlayer
    ///   cannot decode (MPEG-4 Part 2, MPEG-2, VC-1).
    /// `nil` while no playback session is loaded. Cleared in
    /// `stopInternal` so a new session never inherits the previous
    /// label.
    @Published public internal(set) var activeVideoDecoder: String?

    /// Human-readable identity of the audio pipeline currently in use.
    /// For the native AVPlayer path this reflects what
    /// `HLSVideoEngine`'s stream-copy / FLAC-bridge cascade chose:
    /// - `"Stream-copy (EAC3+JOC Atmos)"` for preserved Atmos passthrough.
    /// - `"Stream-copy (<CODEC>)"` for non-Atmos passthrough.
    /// - `"FLAC bridge ← <CODEC>"` when the source codec isn't legal
    ///   in fMP4 and got re-encoded as FLAC for AVPlayer.
    /// For the SW path: `"libavcodec <codec> → CoreAudio"`.
    /// `nil` when the source has no audio, when the cascade fell
    /// through to video-only, or while no session is loaded.
    @Published public internal(set) var activeAudioDecoder: String?

    /// Decoded subtitle cues for the active subtitle source. Populated
    /// by `selectSidecarSubtitle(url:)` only — embedded subtitle
    /// streams in the source travel through HLSVideoEngine into the
    /// fMP4 wrapper but aren't decoded back to text on this side yet
    /// (AVMediaSelection wiring is a tracked follow-up). Sidecar SRT
    /// works end-to-end.
    @Published public internal(set) var subtitleCues: [SubtitleCue] = []
    /// True while a sidecar file is being downloaded + decoded.
    @Published public internal(set) var isLoadingSubtitles: Bool = false
    /// True when sidecar subtitles are the active subtitle source.
    @Published public internal(set) var isSubtitleActive: Bool = false

    /// Decoded cues for the independent SECONDARY subtitle track
    /// (issue #47). Text-only: bitmap codecs are rejected at selection.
    /// Populated by `selectSecondarySubtitleTrack(index:)` (embedded)
    /// or `selectSecondarySidecarSubtitle(url:)` (sidecar), independent
    /// of the primary track.
    @Published public internal(set) var secondarySubtitleCues: [SubtitleCue] = []
    /// True while a secondary sidecar file is being downloaded + decoded.
    @Published public internal(set) var isLoadingSecondarySubtitles: Bool = false
    /// True when a secondary subtitle source is active.
    @Published public internal(set) var isSecondarySubtitleActive: Bool = false

    /// True while the active session is a live stream (the host set
    /// `LoadOptions.isLive = true` at load time). Hosts use this to
    /// hide duration / scrubber UI, skip seek affordances, and switch
    /// the transport-bar layout to a now-only badge. Cleared in
    /// `stopInternal` so a finished live session doesn't bleed flag
    /// state into the next VOD load.
    @Published public private(set) var isLive: Bool = false

    /// Largest session-relative time reached on a live source (seconds since
    /// first frame). Meaningful only while `isLive`. 0 otherwise.
    /// Forwarder; for push updates subscribe to `clock.$liveEdgeTime`
    /// (live-edge fields tick ~1 Hz and live on the clock so they
    /// don't fire the engine's `objectWillChange`).
    public var liveEdgeTime: Double { clock.liveEdgeTime }
    /// DVR-seekable span on the session timeline, or nil when DVR is disabled
    /// or the source is not live. Forwarder; see `clock.seekableLiveRange`.
    public var seekableLiveRange: ClosedRange<Double>? { clock.seekableLiveRange }
    /// True when playback is at / near the live edge. Forwarder; see
    /// `clock.isAtLiveEdge`.
    public var isAtLiveEdge: Bool { clock.isAtLiveEdge }
    /// Seconds the playhead trails the live edge. 0 at the edge.
    /// Forwarder; see `clock.behindLiveSeconds`.
    public var behindLiveSeconds: Double { clock.behindLiveSeconds }

    /// Fires when the live source server restarted its stream from the
    /// beginning after a connection drop (e.g. a Jellyfin transcode
    /// respawn re-serving from byte 0). The engine has parked the session
    /// (playback drains the remaining buffer) and CANNOT recover on the
    /// same URL: a reopen would replay the same content again. The host
    /// must re-negotiate a fresh playback session (new transcode at the
    /// live edge) and call `load` with the new URL. Event-only (no
    /// replay): subscribe per session.
    public let liveSourceReset = PassthroughSubject<Void, Never>()

    // MARK: - Live scrub thumbnails

    /// Decode contexts for the live scrub preview, keyed by segment
    /// index. Tiny LRU (capacity 2) so scrubbing within one segment
    /// reuses the open demux/decode context; torn down in stopInternal
    /// with the rest of the session state.
    var liveThumbnailExtractors: [(segmentIndex: Int, extractor: FrameExtractor)] = []

    // MARK: - Output

    /// How the AVPlayer surface fills its container layer. Mirrors
    /// the host's preferred fit mode to whichever `AVPlayerLayer` is
    /// currently mounted in the bound `AetherPlayerView`.
    public var videoGravity: AVLayerVideoGravity {
        get { _videoGravity }
        set {
            _videoGravity = newValue
            // Engine's native AVPlayerLayer (nativeHost.playerLayer) is
            // allocated but typically not the surface on screen — most
            // tvOS hosts wrap the AVPlayer in AVPlayerViewController,
            // which mounts its own internal AVPlayerLayer. Writing here
            // is still correct for hosts that use the engine's layer
            // directly (`AetherPlayerView.attach(host.playerLayer)`)
            // and for the SW path's displayLayer.
            nativeHost?.playerLayer.videoGravity = newValue
            softwareHost?.displayLayer.videoGravity = newValue
        }
    }
    var _videoGravity: AVLayerVideoGravity = .resizeAspect

    // MARK: - Capabilities

    /// TEST-ONLY routing override. When true, `load` forces every source
    /// through `SoftwarePlaybackHost` regardless of codec, so the SW live
    /// + DVR path can be exercised against the H.264 fixture (which would
    /// otherwise route native). Set ONLY via
    /// `setForceSoftwarePathForTesting(_:)` from `aetherctl`; nothing in
    /// the shipping app calls that setter, so normal codec dispatch is
    /// unaffected.
    nonisolated(unsafe) static var forceSoftwarePathForTesting = false

    /// TEST-ONLY. Flip the software-path routing override (see
    /// `forceSoftwarePathForTesting`). Exposed for the `aetherctl live
    /// --sw` harness; not intended for app use.
    public nonisolated static func setForceSoftwarePathForTesting(_ on: Bool) {
        forceSoftwarePathForTesting = on
    }

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

    /// Attach the active session's render layer to the bound view.
    /// Picks `nativeHost.playerLayer` (AVPlayerLayer) when the native
    /// AVPlayer path is active, `softwareHost.displayLayer`
    /// (AVSampleBufferDisplayLayer) for the SW dav1d path. No-op when
    /// neither host exists — the layer attaches on the next load.
    func presentCurrentLayer() {
        guard let view = boundView else { return }
        if let host = nativeHost {
            view.attach(host.playerLayer)
        } else if let host = softwareHost {
            view.attach(host.displayLayer)
        }
    }

    // MARK: - Display + native state

    /// Engine-owned HDMI HDR handshake controller. Programs
    /// `AVDisplayManager.preferredDisplayCriteria` from the format +
    /// frame rate the demuxer probes; no-op on iOS / macOS.
    let displayCriteria = DisplayCriteriaController()

    /// HLS video engine that demuxes the source and serves a
    /// loopback HLS-fMP4 playlist for AVPlayer to consume. Non-nil
    /// between `load` and `stop`.
    var nativeVideoSession: HLSVideoEngine?

    /// The native AVPlayer + AVPlayerLayer host. Non-nil between
    /// `load` and `stop`.
    var nativeHost: NativeAVPlayerHost?

    /// Combine subscriptions from `nativeHost`'s @Published into the
    /// engine's own @Published mirrors. Cancelled on stopInternal so
    /// a new session doesn't accumulate them.
    var nativeCancellables: Set<AnyCancellable> = []

    /// Software-decode host for codecs AVPlayer cannot decode on the
    /// active platform (today: AV1 on Apple TV, where Apple ships
    /// dav1d on iOS / macOS but not on tvOS and no Apple TV chip has
    /// HW AV1). Non-nil between `load` and `stop` when the source's
    /// video stream routed through the SW pipeline.
    var softwareHost: SoftwarePlaybackHost?

    /// Combine subscriptions from `softwareHost`'s @Published mirrors.
    /// Cancelled on stopInternal alongside `nativeCancellables`.
    var softwareCancellables: Set<AnyCancellable> = []

    /// The lean audio-only playback host. Non-nil only while an
    /// audio-only session (music) is active. Mutually exclusive with
    /// `nativeHost` / `softwareHost`: a load tears all of them down via
    /// `stopInternal` before bringing one up.
    var audioHost: AudioPlaybackHost?

    /// Combine subscriptions from `audioHost`'s @Published mirrors into
    /// the engine's own surface. Cleared on stopInternal.
    var audioCancellables = Set<AnyCancellable>()

    /// Native AVPlayer audio host. Created lazily on the first AVPlayer
    /// audio load and then KEPT for the engine's lifetime, reused across
    /// tracks via replaceCurrentItem. This is deliberate: its
    /// MPNowPlayingSession must persist so the system sees one stable
    /// Now-Playing app across a playlist. Recreating it per track (a fresh
    /// session each time) prevented the background Siri Remote + system
    /// Now-Playing UI from ever stabilising. `audioAVPlayerActive` gates
    /// whether this host is the CURRENT backend.
    var audioAVPlayerHost: AudioAVPlayerHost?
    var audioAVPlayerActive = false
    var audioNativeCancellables = Set<AnyCancellable>()

    /// Periodic memory diagnostic. Emits the process's resident memory
    /// footprint and engine-internal counters every 30 s so we can
    /// see growth patterns instead of guessing about leaks. Started in
    /// `load(url:)` once `state = .playing` lands; cancelled in
    /// `stopInternal`. The log line shape is grep-friendly:
    ///
    ///   [AetherEngine] memprobe t=210s rss=412MB cache=27 subCues=0
    ///
    /// On macOS / aetherctl the line goes to stdout; on tvOS it goes to
    /// `EngineLog.handler` so the host's diagnostic overlay sees it too.
    var memoryProbeTask: Task<Void, Never>?

    /// Live-RELOAD readiness watchdog (see `armLiveReloadWatchdog`).
    /// Armed only by the reload entry points of a LIVE native session;
    /// nil for initial loads, VOD reloads, and the software path.
    /// Cancelled in `stopInternal` so it can never outlive the session
    /// it was watching (a successor load's stopInternal cancels the
    /// predecessor's watchdog before the new pipeline exists).
    var liveReloadWatchdogTask: Task<Void, Never>?

    /// 1 Hz live-telemetry sampler. Mirrors the lifecycle of
    /// `memoryProbeTask`: started when the engine enters `.playing`
    /// (load completes) and torn down in `stopInternal`. The sampler
    /// holds a weak reference back to the engine so its retained task
    /// can't keep `self` alive past teardown.
    var liveTelemetrySampler: LiveTelemetrySampler?

    /// DVR / live window tracker. Non-nil for ANY live session (both the
    /// native and software-decode paths construct it at load). Its
    /// `windowSeconds` is nil when DVR is disabled (live-only: no rewind
    /// range, scrubbing suppressed), and non-nil when a DVR window was
    /// requested. Updated by `publishLiveWindow`, which both the native
    /// time tick and the SW host's edge callback drive; the published
    /// live surfaces above reflect its state.
    var liveWindow: LiveWindow?

    /// The URL of the current playback session. Used by
    /// `reloadAtCurrentPosition()` to rebuild the pipeline after
    /// background suspension.
    // Internal getter (not public API): read by the same-module
    // AetherEngine+FrameExtractor extension to vend a FrameExtractor.
    var loadedURL: URL?

    /// True when the active source is a custom `IOReader` (loaded via
    /// `load(source: .custom(...))`). Such a source has no URL: `loadedURL`
    /// holds a synthetic placeholder for bookkeeping only, so features that
    /// reopen the source by URL (reload, audio-track switch, embedded
    /// subtitles, FrameExtractor) must no-op instead of trying to reopen the
    /// placeholder. See `load(source:)` docs for the limitation list.
    /// Internal getter (read by the same-module FrameExtractor extension).
    private(set) var isCustomSource = false

    /// The active custom source's reader, retained so internal reloads can
    /// reuse it (seek + rebuild) and so concurrent features can clone it.
    /// Owned by the engine: closed in stopInternal on final teardown, nil for
    /// URL sources.
    private(set) var customReader: IOReader?

    /// The format hint passed with the active custom source, reused when the
    /// engine reopens the source (reload) or opens a clone (subtitles/scrub).
    private(set) var customFormatHint: String?

    /// Whether the active custom source is seekable (set at load from the
    /// probe demuxer's isSourceSeekable). Forward-only custom sources cannot
    /// be reopened/rewound, so reload features stay no-op for them.
    private(set) var customSourceIsSeekable = false

    /// Seconds the producer shifted AVPlayer's HLS clock away from
    /// source PTS on the native path: it subtracts `videoShiftPts` from
    /// every packet's pts/dts so seg-0's fragment tfdt aligns with the
    /// playlist's cumulative-EXTINF origin, leaving AVPlayer's raw clock
    /// at `source_pts - playlistShiftSeconds`. The engine folds this back
    /// in before publishing, so `currentTime` (and `sourceTime`) already
    /// carry source PTS on every path; see `nativeClockSeconds` for the
    /// pre-fold raw value. Retained public for diagnostics.
    ///
    /// Updated by `HLSVideoEngine.onPlaylistShiftChanged` on every
    /// producer init / restart (matroska seek imprecision means the
    /// shift can differ session-to-session for the same source).
    /// 0 on the SW / audio paths, whose clocks track source PTS directly.
    @Published public internal(set) var playlistShiftSeconds: Double = 0

    /// Raw AVPlayer HLS clock (`source_pts - playlistShiftSeconds`) on the
    /// native path, before the shift is folded back into `currentTime`.
    /// Held so `onPlaylistShiftChanged` can re-derive `currentTime` the
    /// instant the shift changes mid-session, instead of waiting for the
    /// next periodic time tick. Unused on the SW / audio paths (shift 0).
    var nativeClockSeconds: Double = 0

    /// Monotonic load/stop generation. Bumped by every `stopInternal`
    /// (which runs at the head of every `load()`, `stop()`, and audio
    /// reload), captured by `load()`/`reloadWithAudioOverride` after
    /// their own teardown, and re-checked after every suspension point.
    /// Without it, a load suspended at the probe / criteria handshake /
    /// session start resumed AFTER a newer load (or a plain `stop()`)
    /// and kept executing: it overwrote the successor's published
    /// state, registered its own session over the successor's (orphaning
    /// the successor's producer + loopback server forever), reloaded the
    /// SHARED native host's item out from under it, and could resurrect
    /// playback after dismissal. A superseded load now unwinds with
    /// `CancellationError` at the first checkpoint.
    var loadGeneration: UInt64 = 0

    /// Throw when the captured generation is stale (a newer load/stop
    /// owns the engine). Callers clean up their LOCAL resources before
    /// calling; shared state belongs to the successor and must not be
    /// touched on the unwind path.
    func checkLoadCurrent(_ gen: UInt64) throws {
        guard loadGeneration == gen else {
            EngineLog.emit(
                "[AetherEngine] load superseded (gen \(gen) -> \(loadGeneration)); unwinding",
                category: .engine
            )
            throw CancellationError()
        }
    }

    /// Session history of live program-boundary shift seams, in
    /// output-timeline order. The producer rebases its timeline the
    /// moment it READS a boundary, but AVPlayer renders that seam
    /// ~buffer + holdback later; each entry holds the new shift and the
    /// raw-clock position from which it is true for on-screen content.
    /// The `$currentTime` sink RESOLVES the active shift by looking up
    /// the newest seam at or before the raw clock (a history, not a
    /// destructive queue: a backward DVR seek across an already-crossed
    /// seam must fold pre-seam content with the pre-seam shift again).
    /// The baseline entry (activateAt -infinity) is seeded by the
    /// gate-open / restart shift. Cleared on every load/stop; capped in
    /// the append handler.
    var liveShiftSeams: [(activateAt: Double, shift: Double)] = []

    /// 1 Hz live-window publisher, independent of playback ticks. The
    /// `$currentTime` sink only fires while AVPlayer's periodic time
    /// observer runs, i.e. NOT while paused, so without this timer
    /// `liveEdgeTime` / `behindLiveSeconds` / `isAtLiveEdge` /
    /// `seekableLiveRange` all freeze for the entire pause: the UI shows
    /// "at live edge" while drifting arbitrarily far behind, and a DVR
    /// scrub issued while paused seeks against a stale edge. The edge is
    /// reachable while paused via `host.seekableEnd` (AVPlayer keeps
    /// reloading the live playlist during a pause).
    var liveWindowTimerTask: Task<Void, Never>?

    /// Source PTS of the currently displayed frame. Equal to `currentTime`
    /// on every path now that the native clock is unified onto source time;
    /// kept as a stable alias for callers that want to express source-
    /// timeline intent explicitly (subtitle overlay, side-demuxer seek).
    /// Forwarder; for push updates subscribe to `clock.$sourceTime`.
    public var sourceTime: Double { clock.sourceTime }

    /// The `LoadOptions` the host passed for the current session.
    /// Replayed on every internal reopen of the source URL
    /// (selectAudioTrack reload, embedded subtitle side demuxer,
    /// background reload) so auth, Match Content state, and the
    /// dvh1 tag override all survive mid-playback pipeline rebuilds
    /// rather than silently reverting to defaults. The audio-switch
    /// reload was hitting `matchContentEnabled = true` on a host that
    /// had loaded with `false`, which then routed HDR HEVC through the
    /// master playlist on a non-DV panel with Match Content off and
    /// surfaced "Öffnen fehlgeschlagen".
    // Internal getter (not public API): read by the same-module
    // AetherEngine+FrameExtractor extension to vend a FrameExtractor.
    private(set) var loadedOptions: LoadOptions = .init()

    /// In-flight sidecar subtitle decode. Cancelled on subtitle
    /// clear / track switch so a stale decode can't overwrite fresh
    /// cues.
    var sidecarTask: Task<Void, Never>?

    /// In-flight embedded-subtitle reader Task. Runs a side Demuxer
    /// against the same source URL, seeked to the current playhead,
    /// reading subtitle packets directly. Bypasses the main HLS pump
    /// (which has already raced past the playhead by ~60-80 s when
    /// subtitle activation happens mid-playback, so its subtitle
    /// packets near the visible time have already been read and
    /// discarded). Cancelled + restarted on track change, on
    /// `clearSubtitle`, on `seek`, and on `stop`.
    var embeddedSubtitleTask: Task<Void, Never>?

    /// Active embedded subtitle stream index, or -1 for none. Used by
    /// `seek` to know whether to re-arm the side demuxer at the new
    /// playback position.
    var activeEmbeddedSubtitleStreamIndex: Int32 = -1

    /// Secondary-channel mirrors of the subtitle reader state (issue #47).
    /// Each is the exact analogue of the primary field above and is
    /// driven only through `SubtitleChannel.secondary`.
    var secondarySidecarTask: Task<Void, Never>?
    var secondaryEmbeddedSubtitleTask: Task<Void, Never>?
    var activeSecondaryEmbeddedSubtitleStreamIndex: Int32 = -1
    var secondarySubtitleSideDemuxer: Demuxer?

    /// Source video dimensions captured at `load()` probe time. The
    /// embedded subtitle decoder uses these as a canvas-size fallback
    /// when a bitmap codec's PCS hasn't been parsed yet. Public
    /// read-only for hosts that size their UI from the source frame
    /// (AetherEngine#28); 0 before the first load or when the source
    /// has no video track. `load(source:)` also returns the full
    /// `SourceProbe`, which carries the same dimensions plus the rest
    /// of the probe metadata in one shot.
    public private(set) var sourceVideoWidth: Int32 = 0
    public private(set) var sourceVideoHeight: Int32 = 0

    /// Font files attached to the loaded container (MKV attachments),
    /// populated once during `load()` from the probe demuxer; empty
    /// when the source carries none. Hosts rendering ASS styling
    /// themselves write these to a directory and point their
    /// renderer's font config at it (AetherEngine#30). Deliberately
    /// not `@Published` and not part of `SourceProbe`: the payloads
    /// can be 10-30 MB and only playback hosts need them.
    public private(set) var fontAttachments: [FontAttachment] = []

    /// Last-detected source video codec id. Latched in `load(url:)` and
    /// reused by the audio-track-switch reload path so it can re-derive
    /// the same `activeVideoDecoder` label without re-running the
    /// demuxer probe. Reset to `AV_CODEC_ID_NONE` in `stopInternal`.
    var lastDetectedVideoCodec: AVCodecID = AV_CODEC_ID_NONE

    /// Probe demuxer of the CURRENTLY RUNNING load(), registered before the
    /// (detached, potentially minutes-blocking) open and cleared when load()
    /// exits. stopInternal marks it closed so player dismissal / channel
    /// zapping aborts a probe stuck in the AVIOReader reconnect loop
    /// instead of letting it reconnect into the next session.
    private var inFlightProbeDemuxer: Demuxer?

    /// The embedded-subtitle side demuxer currently reading, registered
    /// by `runEmbeddedSubtitleReader` so the cancel sites can
    /// `markClosed()` it: Task cancellation alone is only observed
    /// between `readPacket` calls and a read blocked in the AVIO
    /// reconnect loop otherwise survives stop()/track switches.
    var activeSubtitleSideDemuxer: Demuxer?

    /// Cap the per-session subtitle event diagnostic logs so the in-
    /// app overlay stays readable. Reset on `load()` so each new
    /// session gets a fresh budget.
    var subtitleCueDiagnosticCount: Int = 0

    /// How far behind `currentTime` to retain old subtitle cues
    /// before pruning them out of `subtitleCues`. Bounds the
    /// session-time memory footprint of bitmap subtitle tracks
    /// (PGS / DVB / DVD), where each cue carries a CGImage that
    /// retains its decoded RGBA pixel buffer for the cue's lifetime.
    /// A 2-hour Blu-ray remux with PGS English subtitles emits
    /// ~1500-2000 cues; without pruning those CGImages stack and
    /// the heap climbs by several hundred MB over the session.
    /// 300 s covers normal pause durations and the backward-scrub
    /// reach that doesn't trigger a producer restart; cues evicted
    /// before that get re-emitted after a producer restart: the side
    /// reader task restarts alongside it and instantiates a FRESH
    /// `EmbeddedSubtitleDecoder`, so the dedupe set starts empty.
    let subtitleCueRetentionSeconds: Double = 300

    /// How far past the playhead (source-PTS seconds) the embedded-
    /// subtitle side demuxer may read before parking. Without this
    /// gate the side demuxer races to EOF at network speed, which
    /// (a) downloads the entire remaining source a second time in
    /// parallel with playback and (b) accumulates every future cue
    /// in `subtitleCues`, because `pruneOldSubtitleCues` only trims
    /// BEHIND the playhead. On a large file with a PGS track the
    /// bitmap cues (each retaining a decoded RGBA CGImage) pin
    /// hundreds of MB to multiple GB and jetsam kills the app
    /// (AetherEngine#31, 50-80 GB UHD remuxes on Apple TV 4K).
    /// 90 s comfortably covers
    /// the main pump's ~60-80 s production lead plus a network
    /// hiccup on the subtitle connection; while parked, the reader's
    /// stalled `readPacket` stops draining the persistent connection
    /// and TCP backpressure (the 16 MB window high-water) pauses the
    /// transfer server-side, so the second connection throttles to
    /// playback rate instead of line rate.
    nonisolated static let embeddedSubtitleReadAheadSeconds: Double = 90

    // MARK: - Init

    /// Lifecycle notification observers. Block-based observers are NOT
    /// auto-removed on dealloc (unlike selector-based ones), so the bag
    /// removes them in its own deinit (a MainActor deinit can't touch
    /// non-Sendable stored state under Swift 6, hence the helper class).
    /// In practice the engine is a process-wide singleton and never
    /// deallocates; this keeps the cleanup contract honest anyway.
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
        // Route FFmpeg's av_log output into EngineLog before any
        // libav* entry point runs, so probe/load diagnostics land in
        // Console.app + the host handler from the very first call.
        FFmpegLogBridge.install()

        // Declare the audio session's category + multichannel support,
        // but do NOT activate the session or pin a preferred channel
        // count here.
        //
        // Issue #24: activating the shared session once at process launch
        // (the engine is a process-wide singleton) latches it against
        // whatever the HDMI route reports at that instant. With tvOS
        // "Continuous Audio Connection" off the link idles at stereo
        // (output=2) at launch, the route gets pinned, and no later
        // AVAudioSession call (setActive / setPreferred / deactivate +
        // reactivate, all tried on device) can lift it — a 5.1 EAC3 asset
        // then downmixes to stereo. The native video path wraps its
        // AVPlayer in AVPlayerViewController, which owns and activates the
        // session per playback; letting AVKit drive activation lets tvOS
        // auto-negotiate the PCM <-> Dolby route switch against the live
        // sink. The renderer paths (SoftwarePlaybackHost / Audio*Host) do
        // their own activation via `activateRendererAudioSession()` since
        // they render through AVSampleBufferAudioRenderer / a bare
        // AVPlayer with no AVPlayerViewController to manage the session.
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
        audioSourceStreamIndex: Int32? = nil
    ) async throws -> SourceProbe? {
        try await load(
            source: .url(url),
            startPosition: startPosition,
            options: options,
            audioSourceStreamIndex: audioSourceStreamIndex
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
    public func load(
        source: MediaSource,
        startPosition: Double? = nil,
        options: LoadOptions = .init(),
        audioSourceStreamIndex: Int32? = nil
    ) async throws -> SourceProbe? {
        // Preserve the native AVPlayer host across a native->native reload
        // so AVKit's system Now-Playing registration survives the seam
        // (issue #15). Captured before stopInternal resets playbackBackend.
        // If this source instead routes to the software path, the SW branch
        // in the dispatch below releases the preserved host.
        let priorBackendWasNative = (playbackBackend == .native)
        stopInternal(keepNativeHost: priorBackendWasNative)
        // This load owns the engine as long as no newer stop/load bumps
        // the generation; every suspension point below re-checks.
        let gen = loadGeneration
        // A url binding the rest of the body uses. For custom sources this
        // is synthetic: it is never dereferenced for I/O (probe, native, and
        // software opens all run against the preopened probe demuxer below),
        // only used for non-I/O bookkeeping such as loadedURL.
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
        // Native remote-HLS has no engine-managed DVR window; the rewind
        // range is whatever the remote HLS playlist exposes. Give the live
        // window an unbounded rewind bound so the engine's live seek isn't a
        // no-op; the host's `avPlayer.seek` clamps to AVPlayer's real
        // seekable range, so an over-wide bound only affects the published
        // range's width, not where a seek actually lands. VOD/loopback live
        // keeps its disk-backed `dvrWindowSeconds`.
        liveWindow = options.isLive
            ? LiveWindow(windowSeconds: options.nativeRemoteHLS ? .greatestFiniteMagnitude : options.dvrWindowSeconds)
            : nil
        state = .loading
        isBuffering = false
        clock.currentTime = 0
        nativeClockSeconds = 0
        duration = 0
        clock.progress = 0
        audioTracks = []
        subtitleTracks = []
        metadata = nil
        fontAttachments = []
        subtitleCueDiagnosticCount = 0
        // Reset format/dimension state from the previous session. Paths
        // that return before the probe (nativeRemoteHLS) or that find no
        // video track would otherwise keep publishing the predecessor's
        // values: Live TV after an HDR10 film kept reporting .hdr10 for
        // the whole live session, and the doc on sourceVideoWidth/Height
        // promises 0 when the source has no video track.
        videoFormat = .sdr
        sourceVideoFormat = .sdr
        sourceVideoWidth = 0
        sourceVideoHeight = 0

        // Native remote-HLS live path: skip the probe + loopback pipeline
        // entirely and play the URL directly with AVPlayer. The source
        // server (Jellyfin) already exposes HLS; AVPlayer manages the live
        // edge, buffering, and reconnect natively. Routed before the probe
        // because we never demux the m3u8 ourselves (unlike the audioOnly
        // divert below, which needs probe info first).
        if options.nativeRemoteHLS {
            do {
                try await loadRemoteHLS(url: url, options: options)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Without this catch a throwing loadRemoteHLS stranded
                // state at .loading forever (the bypass sits outside the
                // do/catch all other load paths run under). The body
                // can't throw today, but the signature says it can.
                state = .error("Failed to load: \(error.localizedDescription)")
                throw error
            }
            // No probe ran on this bypass; there is nothing to report.
            return nil
        }

        // 1. Brief demuxer probe to grab format + frame rate + track
        //    metadata. The HLSVideoEngine spun up below re-opens
        //    internally; the double-open keeps the failure-mode matrix
        //    small.
        var detectedFormat: VideoFormat = .sdr
        var effectiveFormat: VideoFormat = .sdr
        var detectedRate: Double? = nil
        var detectedDVProfile: Bool = false
        var detectedCodecID: AVCodecID = AV_CODEC_ID_NONE
        var probedAudioTracks: [TrackInfo] = []
        var probedSubtitleTracks: [TrackInfo] = []
        var probedDefaultAudioIndex: Int32 = -1
        let probe = Demuxer()
        // Register the in-flight probe so stopInternal can abort it. The
        // probe's avformat_open_input / find_stream_info can block for the
        // AVIOReader's full reconnect budget against a dead live source
        // (e.g. a tuner answering HTTP 500); without this, dismissing the
        // player or zapping channels left the probe reconnecting in the
        // background THROUGH the next sessions until the budget ran out
        // (device repro: a 500-looping channel kept reconnecting across
        // three subsequent channel sessions). markClosed() is lock-free and
        // makes the blocked open return promptly.
        inFlightProbeDemuxer = probe
        // Identity-guarded: a superseding load() (channel zap mid-probe) has
        // already registered ITS probe by the time this one unwinds; an
        // unconditional nil here would strip the successor's abort handle.
        defer { if inFlightProbeDemuxer === probe { inFlightProbeDemuxer = nil } }
        var probeOpened = false
        do {
            // Detach the HTTP probe + avformat_open_input + avformat_find_stream_info
            // off the @MainActor so the SwiftUI host stays responsive.
            // On a slow CDN this is the dominant blocking call in
            // `load()` (~6 s). Per Delarkz's AetherEngine#10: a @MainActor
            // async function whose body is synchronous Swift blocks the
            // main thread despite the `async` signature — there's no
            // suspension point. `Task.detached.value` introduces a real
            // hop to a background thread so the @MainActor runloop keeps
            // ticking.
            try await Task.detached(priority: .userInitiated) { [probe, source, options] in
                switch source {
                case .url(let u):
                    // Pass isLive so the probe demuxer's AVIOReader is
                    // configured for endless-feed mode. The probe demuxer is
                    // reused as the session demuxer (avformat_open_input +
                    // avformat_find_stream_info run only once), so the
                    // AVIOReader it holds must already have isLive=true when
                    // the producer starts reading from it.
                    try probe.open(url: u, extraHeaders: options.httpHeaders, isLive: options.isLive)
                case .custom(let reader, let formatHint):
                    // Pass isLive so the probe demuxer suppresses the
                    // SEEK_END duration estimate on a forward-only live
                    // reader (same reason as the .url arm above). The probe
                    // demuxer is reused as the session demuxer, so the live
                    // flag must be set at open time.
                    try probe.open(reader: reader, formatHint: formatHint, isLive: options.isLive)
                }
            }.value
            probeOpened = true
            let videoIdx = probe.videoStreamIndex
            if videoIdx >= 0, let stream = probe.stream(at: videoIdx) {
                detectedFormat = Self.detectVideoFormat(stream: stream)
                effectiveFormat = Self.effectiveVideoFormat(detected: detectedFormat, stream: stream)
                detectedRate = Self.detectFrameRate(stream: stream)
                // DrHurt #4 (2026-05-26): use SOURCE-detected DV profile,
                // not effective-format. Drives `codecTag = dvh1` in the
                // display-criteria apply() call below, asking AVDisplayManager
                // for DV mode on every DV source regardless of whether the
                // panel reports DV capability. Apple's HLS pipeline + tone-
                // mapper is industry-leading at downgrading DV → HDR10
                // when the active panel mode can't host DV; we let AVPlayer
                // do that work instead of pre-emptively stripping DV signals
                // engine-side. Pairs with the always-emit-SUPPLEMENTAL +
                // no-strip change in HLSVideoEngine's profile81 / profile84
                // emission.
                detectedDVProfile = (detectedFormat == .dolbyVision)
                detectedCodecID = stream.pointee.codecpar.pointee.codec_id
                sourceVideoWidth = stream.pointee.codecpar.pointee.width
                sourceVideoHeight = stream.pointee.codecpar.pointee.height
                lastDetectedVideoCodec = detectedCodecID
            }
            probedAudioTracks = probe.audioTrackInfos()
            probedSubtitleTracks = probe.subtitleTrackInfos()
            probedDefaultAudioIndex = probe.audioStreamIndex
            // probe.close() deferred: ownership transfers to `loadNative`
            // (native dispatch) or `loadSoftware` (software dispatch). Both
            // adopt the probe demuxer for reuse, or open fresh only if the
            // probe failed. On the error path probe was never opened, so
            // close is a no-op.
        } catch {
            EngineLog.emit("[AetherEngine] probe failed (\(error)); proceeding without criteria", category: .engine)
        }

        // Superseded while the probe was blocked? The probe is this
        // load's local; close it (detached, the close can block) and
        // unwind without touching shared state.
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

        // Live fail-fast: a live source whose probe could not even open is a
        // dead tuner (the AVIOReader already burned its full reconnect
        // budget getting here). Proceeding would dispatch on codec NONE and
        // grind a second, equally doomed open for another ~30 s of spinner
        // before erroring out. Fail now so the host can show the error (or
        // try the next channel) immediately.
        if options.isLive, !probeOpened {
            state = .error("Live source unavailable")
            throw DemuxerError.openFailed(code: -5)
        }

        // Record seekability for reload gating (forward-only custom sources
        // cannot rewind, so audio-switch / background-reload stay no-op).
        customSourceIsSeekable = isCustomSource ? probe.isSourceSeekable : false

        // Source format is what the probe found in the file, before any
        // panel clamping. Stats overlays use this to label "what the file
        // is" vs `videoFormat` labelling "what the panel is showing".
        // (`videoFormat` itself is published lower in this method, after
        // the criteria handshake has settled and we know which dynamic-
        // range mode the panel actually adopted — see comment on the
        // `panelHDRAfterHandshake` snapshot below.)
        sourceVideoFormat = detectedFormat
        audioTracks = probedAudioTracks
        subtitleTracks = probedSubtitleTracks
        metadata = probeOpened ? probe.mediaMetadata() : nil
        fontAttachments = probeOpened ? probe.fontAttachmentInfos() : []
        // Assemble the caller-facing SourceProbe now, while the probe
        // demuxer is open: ownership transfers to loadNative /
        // loadSoftware further down, after which the streams are gone
        // (AetherEngine#28).
        let sourceProbe: SourceProbe? = probeOpened
            ? Self.makeSourceProbe(demuxer: probe, displayURL: url)
            : nil
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
        EngineLog.emit("[AetherEngine] load url=\(url.absoluteString) source-format=\(detectedFormat) effective-format=\(effectiveFormat) rate=\(snappedRate.map { String(format: "%.3f", $0) } ?? "n/a")", category: .engine)

        // 1.5 Audio-only fast path. When the host asked for audio-only
        //     or the probe found no video stream, route to the lean
        //     AudioPlaybackHost and return before the display-criteria
        //     handshake and the video dispatch below ever run. The native
        //     (AVPlayer) audio sub-branch reopens the URL itself, so it
        //     closes the probe; the FFmpeg sub-branch reuses the probe
        //     demuxer (required for custom sources, which have no URL).
        let hasVideoStream = probeOpened && probe.videoStreamIndex >= 0
        if Self.shouldUseAudioOnlyPath(audioOnlyRequested: options.audioOnly, hasVideoStream: hasVideoStream) {
            // Read the chosen audio stream's codec before closing the probe
            // so AVPlayer-decodable audio takes the native path.
            let audioCodecID: AVCodecID = (probeOpened && resolvedInitialAudio >= 0)
                ? (probe.stream(at: resolvedInitialAudio)?.pointee.codecpar.pointee.codec_id ?? AV_CODEC_ID_NONE)
                : AV_CODEC_ID_NONE
            // Custom sources have no URL; AVPlayer (loadAudioNative) cannot consume a
            // custom FFmpeg demuxer, so force the FFmpeg audio path for them.
            let useNativeAudio = !isCustomSource && Self.avPlayerCanDecodeAudio(audioCodecID)
            EngineLog.emit("[AetherEngine] audio dispatch: codec=\(audioCodecID.rawValue) -> \(useNativeAudio ? "AVPlayer" : "FFmpeg")", category: .engine)
            // A native->native reload may have preserved the previous
            // AVPlayer host (issue #15), but this source routes to an
            // audio path: release the video host now (mirrors the SW
            // branch below). Without this the old VIDEO AVPlayer stayed
            // alive and published via currentAVPlayer for the whole
            // audio session, and the volume setter kept writing into it.
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
                // Superseded: the successor owns `state`; just unwind.
                throw CancellationError()
            } catch {
                state = .error("Failed to load: \(error.localizedDescription)")
                throw error
            }
            return sourceProbe
        }

        // 2. Display-criteria handshake. Drive from the effective format so
        //    a non-DV panel doesn't get asked to switch into dvh1 mode.
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
                // Superseded during the panel handshake? The probe is
                // still this load's local; close it and unwind.
                if loadGeneration != gen {
                    probe.markClosed()
                    if probeOpened {
                        Task.detached { [probe] in probe.close() }
                    }
                    try checkLoadCurrent(gen)
                }
            }
        }

        // 2.5. Post-handshake panel-mode snapshot. tvOS exposes only one
        //      combined `isDisplayCriteriaMatchingEnabled` toggle — there's
        //      no API to tell whether Match Dynamic Range is on or only
        //      Match Frame Rate. A user with rate matching on and range
        //      matching off (DrHurt #4 2026-05-27 residual) reports the
        //      combined flag as `true`, the host passes
        //      `matchContentEnabled=true` in LoadOptions, but the panel
        //      stays SDR when we ask for HDR. The old gates
        //      (`supportsHDR && matchContentEnabled`) treated that as "will
        //      switch", routed via master playlist with `VIDEO-RANGE=PQ`,
        //      and AVPlayer rejected with -11848 / -11868 because the
        //      strict variant filter saw HDR variants on an SDR-locked
        //      panel.
        //
        //      Reading `currentEDRHeadroom` after `waitForSwitch` is the
        //      only authoritative way to know which sub-toggle is active:
        //      headroom > 1.0 means the panel accepted the HDR mode
        //      (match-range was on), headroom == 1.0 means it refused
        //      (match-range off). Pass that empirical reading to both the
        //      published `videoFormat` and HLSVideoEngine's master-vs-
        //      media routing so the two stay in step.
        //
        //      Suppressed-criteria hosts (AVKit-sole-writer path) fall
        //      back to the caller's pre-load snapshot — their criteria
        //      fires later from AVKit and we can't probe the outcome
        //      from here.
        let panelHDRAfterHandshake: Bool
        if options.suppressDisplayCriteria {
            panelHDRAfterHandshake = options.panelIsInHDRMode
        } else {
            panelHDRAfterHandshake = displayCriteria.currentPanelIsHDR()
        }
        videoFormat = (effectiveFormat != .sdr && panelHDRAfterHandshake)
            ? effectiveFormat
            : .sdr

        // 3. Dispatch by codec. The native AVPlayer path carries Atmos
        //    passthrough, Dolby Vision HDMI handshake, and the system
        //    HDR / HDR10+ pipeline — so we route there whenever
        //    AVPlayer's HLS-fMP4 pipeline can take the codec. The SW
        //    pipeline (dav1d / libavcodec → AVSampleBufferDisplayLayer)
        //    fills the gaps:
        //
        //    - AV1: native on iOS 17+ / macOS 14+ (Apple ships dav1d in
        //      VideoToolbox), SW on tvOS (Apple doesn't ship dav1d on
        //      tvOS and no Apple TV chip has HW AV1). The probe in
        //      `VTCapabilityProbe.av1Available` decides per-platform.
        //    - VP9: always SW. Empirically AVPlayer's HLS manifest
        //      parser rejects the `vp09` CODECS attribute even though
        //      VideoToolbox can HW-decode the codec — verified via
        //      aetherctl on macOS 26 against a libvpx-vp9 source
        //      (AVPlayer GETs master.m3u8 + media.m3u8 then silently
        //      stops fetching, `item.status` never leaves `.unknown`).
        //    - VP8: always SW. Same HLS-manifest-parser rejection as
        //      VP9; VP8 was never part of the HLS Authoring Spec CODECS
        //      list. Useful for legacy WebM rips.
        //    - MPEG-4 Part 2 (XVID / DIVX / SP / ASP), MPEG-2 video,
        //      VC-1: always SW. AVPlayer's HLS-fMP4 pipeline does not
        //      accept these codecs (`mp4v.20.X`, `mp2v`, `vc-1` are
        //      not in Apple's HLS Authoring Spec CODECS list).
        //      libavcodec ships native decoders for all three in
        //      FFmpegBuild; SoftwareVideoDecoder is codec-generic.
        //
        //    Everything else (HEVC / H.264) goes through the native
        //    path unconditionally.
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
        // Forward-only custom sources cannot serve the native path's seeks
        // (cue prewarm, segment seeks). The software path reads strictly
        // forward and decodes every codec, so route them there regardless.
        // Live custom sources are exempt: the live producer is forward-only
        // by design and never seeks the source backward, scrub previews come
        // from the DVR segment cache (not the source reader), and the
        // audio-switch reload guard below already no-ops for forward-only
        // custom sources. VOD keeps the SW-only rule.
        if isCustomSource && !probe.isSourceSeekable && !options.isLive {
            useSoftwarePath = true
            EngineLog.emit("[AetherEngine] custom source is forward-only, forcing software path", category: .engine)
        }
        // TEST-ONLY routing override. `aetherctl live --sw` flips this so
        // the H.264/HEVC fixture (which would normally take the native
        // path) is forced through SoftwarePlaybackHost, exercising the SW
        // live + DVR path end-to-end without a VP9/MPEG-2 fixture. Default
        // false; nothing in the shipping app sets it, so normal codec
        // routing above is unaffected. See `forceSoftwarePathForTesting`.
        if Self.forceSoftwarePathForTesting {
            useSoftwarePath = true
            EngineLog.emit("[AetherEngine] TEST override: forcing software path", category: .engine)
        }
        EngineLog.emit("[AetherEngine] dispatch: codec=\(detectedCodecID.rawValue) → \(useSoftwarePath ? "software" : "native")", category: .engine)

        // Demuxed-audio live ingest is a native-path-only feature: the
        // side-demuxer merge lives in HLSSegmentProducer, while
        // SoftwarePlaybackHost reads exactly one demuxer. A demuxed-audio
        // source whose video codec routes software (e.g. an MPEG-2 TS
        // rendition) would therefore play SILENT; fail fast instead so the
        // host falls back to the server-muxed route, the same contract the
        // reader's residual demuxedAudioNotSupported cases follow.
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
                // SW path now REUSES the probe demuxer (single open). Do not
                // close it here; loadSoftware adopts it (or opens fresh only
                // if the probe failed). One open AVFormatContext total.
                // A native->native reload may have preserved the previous
                // AVPlayer host (issue #15), but this source routes to the
                // software path. Release it now: the SW pipeline renders
                // into its own layer and the host's currentAVPlayer sink
                // relies on a nil publish to drop AVKit's now-stale player.
                if nativeHost != nil {
                    nativeHost?.tearDown()
                    nativeHost = nil
                    currentAVPlayer = nil
                }
                try await loadSoftware(
                    url: url,
                    sourceHTTPHeaders: options.httpHeaders,
                    startPosition: startPosition,
                    audioSourceStreamIndex: audioSourceStreamIndex,
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
                // Native path: hand the probe Demuxer to loadNative.
                // HLSVideoEngine.start() reuses it instead of running
                // avformat_open_input + find_stream_info a second
                // time, saving ~1-3 s of cold-start latency on slow
                // CDN sources. The cue prewarm seek inside
                // HLSVideoEngine.start invalidates any stale read
                // position from the probe so position state is
                // irrelevant. If probe failed to open, pass nil and
                // HLSVideoEngine falls back to opening fresh.
                try await loadNative(
                    url: url,
                    sourceHTTPHeaders: options.httpHeaders,
                    startPosition: startPosition,
                    audioSourceStreamIndex: audioSourceStreamIndex,
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
                // Native audio identity comes from HLSVideoEngine's
                // cascade: stream-copy is preserved as a passthrough
                // label, FLAC bridge re-labels with the source codec,
                // video-only leaves the field nil.
                activeAudioDecoder = nativeVideoSession?.audioPipelineDescription
                // Reconcile the published audio surface with the
                // session's REAL pick (side-demuxer tracks for
                // demuxed-audio sources, by-type fallback for live TS
                // probes with empty audio codecpar). Without this a
                // host's post-load preferred-language check compares
                // against the probe-derived value and reloads the very
                // track that is already playing.
                syncPublishedAudioStateFromNativeSession()
                presentCurrentLayer()
                // Gate play() on panel handshake completion. With the
                // host's `appliesPreferredDisplayCriteriaAutomatically`
                // = true, AVKit drives the criteria write from the
                // live AVPlayerItem's formatDescription (which reads
                // dvcC correctly from the fMP4 sample entry via
                // private CoreMedia hooks). waitForSwitch's Stage 1
                // grace gives AVKit time to fire that write; Stage 2
                // waits for the panel handshake to settle so the
                // first decoded frame doesn't hit a mid-transition
                // panel. For P5 specifically (no HDR10 base, requires
                // immediate DV mode), this is what makes cold-start
                // playback land.
                await displayCriteria.waitForSwitch()
                try checkLoadCurrent(gen)
                // Auto-play after load. AVPlayer's
                // `automaticallyWaitsToMinimizeStalling = true` (default)
                // handles "play before ready" correctly: it transitions
                // through `waitingToPlayAtSpecifiedRate`, buffers, and
                // starts playing once enough segments are in.
                nativeHost?.play()
                state = .playing
                startMemoryProbe()
                startLiveTelemetrySampler()
            }
        } catch is CancellationError {
            // Superseded: a newer load/stop owns `state`; unwind quietly.
            throw CancellationError()
        } catch {
            state = .error("Failed to load: \(error.localizedDescription)")
            throw error
        }
        return sourceProbe
    }

    // MARK: - Transport

    /// The host that currently owns transport, in the canonical
    /// priority order (audio-AVPlayer -> FFmpeg audio -> software ->
    /// native). Every transport entry point dispatches through this so
    /// the priority can't drift between call sites.
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
    }

    public func togglePlayPause() {
        // Only togglable from the steady transport states (and from
        // .loading, where the press means "start"). Ignore in
        // .seeking / .error / .idle, matching the prior behaviour.
        switch state {
        case .playing, .paused, .loading: break
        default: return
        }
        // Decide from the LIVE transport state, not the published `state`.
        // On the native path AVKit's transport / Control Center / the
        // hardware play/pause button can toggle the AVPlayer directly, and
        // the `$timeControlStatus` reconciliation that mirrors those toggles
        // into `state` is async. Reading the AVPlayer synchronously here
        // closes that gap so a fast press can't act on a stale value and
        // resolve to a no-op (the "swallowed press" symptom). The SW host
        // has no AVPlayer and no competing transport owner, so its `state`
        // is authoritative.
        let isPlaying: Bool
        if audioAVPlayerActive {
            // Audio host has no competing transport owner, so `state` is
            // authoritative (same reasoning as the software host).
            isPlaying = (state == .playing)
        } else if audioHost != nil {
            // Audio host has no competing transport owner, so `state` is
            // authoritative (same reasoning as the software host).
            isPlaying = (state == .playing)
        } else if softwareHost != nil {
            isPlaying = (state == .playing)
        } else if let nativeHost {
            isPlaying = nativeHost.isEffectivelyPlaying
        } else {
            isPlaying = (state == .playing)
        }
        if isPlaying { pause() } else { play() }
    }

    /// Tear down and reload from the current position. Call after
    /// returning from background; AVIO connections and VT sessions
    /// (where applicable) are invalidated by tvOS when the app is
    /// suspended.
    public func reloadAtCurrentPosition() async throws {
        if isCustomSource {
            // No URL to reopen; rebuild on the retained reader (seekable only),
            // keeping the current audio track.
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
        // Live rejoins at the live edge: the pre-suspend playhead is
        // stale by the suspension duration and may already have slid
        // out of the window (reloadWithAudioOverride nils it for live
        // for the same reason). See LiveReloadPolicy.
        let resume: Double? = LiveReloadPolicy.resumePosition(
            isLive: loadedOptions.isLive, currentTime: pos)
        // Mark the reopen as a live REJOIN so loadNative tells the host
        // to skip its initial seek: the same upstream URL re-serves its
        // transcode buffer from the start, so the rebuilt playlist can
        // present a multi-segment backlog where the fresh-join contract
        // (seg0 == cushioned live edge) no longer holds.
        var options = loadedOptions
        options.isLiveRejoin = options.isLive
        try await load(url: url, startPosition: resume, options: options)
        // Same safety net as the audio-switch reload: a live reopen whose
        // AVPlayer never becomes ready while the producer is serving must
        // fail visibly instead of freezing. Initial loads never arm this
        // (the flag is reload-scoped), and the remote-HLS bypass has no
        // loopback producer to watch.
        if options.isLive, !options.nativeRemoteHLS, playbackBackend == .native {
            armLiveReloadWatchdog(generation: loadGeneration)
        }
    }

    public func seek(to seconds: Double) async {
        // No active session: a host scrub racing stop() must not flip an
        // idle/error engine to .seeking -> .playing with no pipeline
        // behind it.
        switch state {
        case .idle, .error:
            EngineLog.emit("[AetherEngine] seek(to:\(seconds)) ignored: no active session (state=\(state))", category: .engine)
            return
        case .loading:
            // Mid-load there are no hosts yet: the body below would be
            // all no-ops but still flip state to .playing, dropping the
            // host's spinner early and breaking the $isReady -> .paused
            // waypoint that load() is still driving.
            EngineLog.emit("[AetherEngine] seek(to:\(seconds)) ignored: load in progress", category: .engine)
            return
        default:
            break
        }
        // Live-only sources (no DVR window) have no rewind range; AVPlayer
        // would either stall indefinitely or land on a segment the playlist
        // hasn't materialised. DVR sources expose a bounded seekable range
        // and fall through. Hosts can hide the scrubber by observing
        // `$seekableLiveRange == nil` so this guard is defence-in-depth.
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
        // Span the real landing (not the optimistic .playing flip below) so a
        // host gets an accurate in-flight seek signal (#38). The generation
        // guard at each finalize point ensures a superseded seek's late
        // landing cannot clear this while a newer seek is still in flight.
        seekGeneration &+= 1
        let seekGen = seekGeneration
        setProgrammaticSeek(inFlight: true, target: target)
        if isLive {
            // Live/DVR native path: translate the session-time target into the
            // AVPlayer live clock. Measure how far behind the live edge the
            // (clamped) target sits, then apply that same delta backward from
            // AVPlayer's current seekable-range end. Because the published edge
            // is seekableEnd + playlistShiftSeconds (the same fold as the
            // playhead), this collapses to clockTarget = target - shift, which
            // is consistent with the engine's source-PTS axis. We compute it via
            // the behind-delta to stay robust if the edge advances between the
            // publish tick and this seek.
            // Software-decode live path: drive the SW host's ring-backed
            // DVR reseed with the session-time target directly (the host
            // maps session time to source PTS internally). The native
            // AVPlayer-clock translation below does not apply; there is no
            // nativeHost, so do NOT touch nativeClockSeconds.
            if softwareHost != nil, nativeHost == nil {
                EngineLog.emit("[AetherEngine] SW live seek target=\(target)", category: .engine)
                await softwareHost?.seek(to: target)
                guard seekGeneration == seekGen else { return }
                clock.currentTime = target
                clock.sourceTime = target
                state = .playing
                setProgrammaticSeek(inFlight: false, target: nil)
                return
            }
            let behind = (liveWindow?.edgeTime ?? target) - target   // >= 0; 0 == "to the edge"
            let clockTarget = max(0, (nativeHost?.seekableEnd ?? 0) - behind)
            EngineLog.emit("[AetherEngine] live seek target=\(target) behind=\(behind) seekableEnd=\(nativeHost?.seekableEnd ?? 0) clockTarget=\(clockTarget)", category: .engine)
            // Publish the target up front so the playhead holds it while the
            // host suppresses the periodic observer's stale pre-seek reads,
            // then await the real landing before flipping back to .playing.
            nativeClockSeconds = clockTarget
            clock.currentTime = target
            clock.sourceTime = target
            await nativeHost?.seek(to: clockTarget)
            guard seekGeneration == seekGen else { return }
            nativeClockSeconds = clockTarget
            clock.currentTime = target
            clock.sourceTime = target
            // publishLiveWindow on the next tick recomputes behindLiveSeconds
            // against the new playhead.
            state = .playing
            setProgrammaticSeek(inFlight: false, target: nil)
            return
        }
        // seek(to:) speaks source PTS (the unified engine clock). On the
        // native path AVPlayer's HLS clock sits at source - playlistShiftSeconds,
        // so convert before driving the host. The SW / audio hosts already
        // run on source time (shift 0), making this a no-op there.
        let clockTarget = target - playlistShiftSeconds
        let gen = loadGeneration
        // Native loopback-HLS lands a seek seconds late. Publish the target
        // up front so the playhead snaps to the drop point; the host
        // suppresses the periodic observer's stale pre-seek reads until the
        // seek lands, so the clock holds the target instead of bouncing back
        // through the old position (#37). Audio/SW hosts run on source time
        // and resolve their seek synchronously to the await, so they write
        // the clock only at finalize below, as before.
        let nativeOnly = !audioAVPlayerActive && audioHost == nil && softwareHost == nil && nativeHost != nil
        if nativeOnly {
            nativeClockSeconds = clockTarget
            clock.currentTime = target
            clock.sourceTime = target
        }
        if audioAVPlayerActive, let host = audioAVPlayerHost {
            await host.seek(to: clockTarget)
        } else if let host = audioHost {
            await host.seek(to: clockTarget)
        } else if let host = softwareHost {
            await host.seek(to: clockTarget)
        } else {
            // Await the real AVPlayer landing before flipping back to
            // .playing so isSeeking spans it (#37/#38).
            await nativeHost?.seek(to: clockTarget)
        }
        // A stop()/load() landing during the await above already tore
        // the session down; writing clock state + .playing into the
        // singleton afterwards would publish a phantom session. A
        // superseding seek bumped seekGeneration and owns the final state.
        guard loadGeneration == gen, seekGeneration == seekGen else { return }
        nativeClockSeconds = clockTarget
        clock.currentTime = target
        clock.sourceTime = target

        // Re-arm the side subtitle demuxer at the new playhead so cues
        // for the post-scrub content surface immediately. Skip when
        // sidecar SRT is active (it pre-decoded the whole file).
        if activeEmbeddedSubtitleStreamIndex >= 0, let url = loadedURL {
            let streamIdx = activeEmbeddedSubtitleStreamIndex
            cancelEmbeddedSubtitleReader()
            subtitleCues = []
            // Side-demuxer seeks in source PTS, which is the seek target.
            // For custom sources, request a fresh clone; skip re-arm if the
            // reader cannot produce one (forward-only source mid-seek).
            if isCustomSource {
                if let clone = customReader?.makeIndependentReader() {
                    startEmbeddedSubtitleTask(url: url, reader: clone, formatHint: customFormatHint, streamIndex: streamIdx, startAt: target)
                }
            } else {
                startEmbeddedSubtitleTask(url: url, reader: nil, formatHint: nil, streamIndex: streamIdx, startAt: target)
            }
        }

        // Mirror the re-arm for the secondary companion track (issue #47).
        if activeSecondaryEmbeddedSubtitleStreamIndex >= 0, let url = loadedURL {
            let streamIdx = activeSecondaryEmbeddedSubtitleStreamIndex
            cancelEmbeddedSubtitleReader(channel: .secondary)
            secondarySubtitleCues = []
            if isCustomSource {
                if let clone = customReader?.makeIndependentReader() {
                    startEmbeddedSubtitleTask(url: url, reader: clone, formatHint: customFormatHint, streamIndex: streamIdx, startAt: target, channel: .secondary)
                }
            } else {
                startEmbeddedSubtitleTask(url: url, reader: nil, formatHint: nil, streamIndex: streamIdx, startAt: target, channel: .secondary)
            }
        }

        // The host seek has physically landed (we awaited it). Flip back to
        // .playing and clear the in-flight seek signal.
        state = .playing
        setProgrammaticSeek(inFlight: false, target: nil)
    }

    /// Deprecated alias for `seek(to:)`, which is now itself source-PTS
    /// based (the engine clock is unified onto source time). Retained so
    /// existing callers keep building; prefer `seek(to:)` in new code.
    @available(*, deprecated, renamed: "seek(to:)")
    public func seek(toSourceTime seconds: Double) async {
        await seek(to: seconds)
    }

    public func stop() {
        stopInternal()
        state = .idle
        clock.currentTime = 0
        clock.progress = 0
        // Published-surface hygiene: without these, the PREVIOUS
        // session's metadata/track lists/duration/format survive until
        // the next load() and hosts reading between stop and load see
        // stale values. pendingExternalMetadata would even replay the
        // old title/artwork onto an unrelated next session.
        duration = 0
        metadata = nil
        audioTracks = []
        subtitleTracks = []
        // Session-scoped like the track lists; must survive stopInternal,
        // which also runs under the audio-track-switch reload (that path
        // skips the probe, so clearing here would strand the session with
        // an empty font list after any audio switch).
        fontAttachments = []
        videoFormat = .sdr
        sourceVideoFormat = .sdr
        sourceVideoWidth = 0
        sourceVideoHeight = 0
        pendingExternalMetadata = []
        // Source identity is load-scoped, but the public stop() ends the
        // session for good: clearing it here keeps reloadAtCurrentPosition
        // from resurrecting the old URL (e.g. a background-return hook
        // firing after the player was dismissed) and keeps
        // selectSubtitleTrack from spawning a side demuxer against a
        // stopped session. load() re-sets all of these immediately, so the
        // internal stopInternal()-then-reload paths are unaffected.
        loadedURL = nil
        isCustomSource = false
        customSourceIsSeekable = false
    }

    /// The active `AVPlayer` instance, when the native AVKit path is in
    /// use. `nil` while the software (AVSampleBufferDisplayLayer) path
    /// is active or no session is loaded. Published so hosts that drive
    /// an `AVPlayerViewController` for system Now Playing can rebind
    /// `.player` whenever the engine swaps the underlying instance
    /// (every `selectAudioTrack` reload tears the previous host down
    /// and brings up a fresh one, so a one-shot assignment goes stale).
    @Published public internal(set) var currentAVPlayer: AVPlayer?

    #if os(tvOS) || os(iOS)
    /// The Now-Playing session bound to the active AVPlayer audio path, or
    /// nil when that path is not active (FFmpeg audio / video / idle). The
    /// host app registers transport commands on its `remoteCommandCenter` and
    /// writes metadata to its `nowPlayingInfoCenter` so the app stays the
    /// active Now-Playing app across a background pause (the shared singletons
    /// drop a paused bare AVPlayer on tvOS, killing the Home badge + the
    /// remote play route). See AudioAVPlayerHost for the full rationale.
    public var audioNowPlayingSession: MPNowPlayingSession? {
        audioAVPlayerActive ? audioAVPlayerHost?.nowPlayingSession : nil
    }
    #endif

    /// Pending externalMetadata for the next native load. Set via
    /// `setExternalMetadata(_:)` before `load(url:)`; consumed when
    /// `loadNative` creates the `NativeAVPlayerHost` and applied to
    /// the AVPlayerItem before AVPlayer.replaceCurrentItem. Survives
    /// across native loads so internal reloads (audio-track switch,
    /// background reopen) replay the metadata.
    var pendingExternalMetadata: [AVMetadataItem] = []

    /// Stage the metadata items for the system Now Playing surface
    /// (title, artwork, description, etc.). Set this rather than writing
    /// to `MPNowPlayingInfoCenter.nowPlayingInfo` when using AVKit or
    /// `MPNowPlayingSession` with automatic publishing: those read
    /// metadata off `AVPlayerItem.externalMetadata`, while manual
    /// `MPNowPlayingInfoCenter` writes race against MediaPlayer's
    /// internal serial queue on tvOS 26 and trip an assertion.
    /// Safe to call BEFORE `load(url:)`: the items are stashed on
    /// the engine and replayed onto the AVPlayerItem the moment the
    /// native host is created.
    public func setExternalMetadata(_ items: [AVMetadataItem]) {
        pendingExternalMetadata = items
        nativeHost?.setExternalMetadata(items)
        audioAVPlayerHost?.setExternalMetadata(items)
    }

    /// Set playback volume (0.0 = mute, 1.0 = full). Routed through the
    /// ACTIVE host only: writing into every host changed the next music
    /// session's volume. The engine additionally remembers the host's
    /// desired volume so a write BEFORE any session exists (e.g. a
    /// restore-persisted-volume call at app init) isn't a silent no-op;
    /// the loaders apply it to each freshly activated host.
    public var volume: Float {
        get { activeTransportHost?.volume ?? desiredVolume ?? 1.0 }
        set {
            desiredVolume = newValue
            activeTransportHost?.volume = newValue
        }
    }

    /// Last volume the host asked for, nil until the first write.
    /// Applied by the loaders when a host is (re)activated.
    var desiredVolume: Float?

    /// Apply the remembered volume to a freshly activated host.
    func applyDesiredVolume(to host: any TransportControllable) {
        if let v = desiredVolume { host.volume = v }
    }

    /// The highest forward playback rate the active path plays reliably.
    /// AVPlayer caps fast-forward at 2x for video; an audio-only session
    /// (no video stream) plays cleanly up to 3x. Above this the AVPlayer
    /// fast-forward becomes unstable (audio and video go abnormal, the
    /// symptom in AetherEngine#39), so hosts should size their speed
    /// picker against this value, and `setRate(_:)` clamps to it as a
    /// backstop. Reflects the currently loaded session; query it after
    /// load (it is 2.0 while idle).
    public var maxSupportedRate: Float {
        (audioAVPlayerActive || audioHost != nil) ? 3.0 : 2.0
    }

    /// Set playback speed. Forward rates are clamped to `maxSupportedRate`
    /// (2x for video, 3x for an audio-only session): AVPlayer's HLS
    /// fast-forward is undefined above that and drives both audio and
    /// video abnormal (AetherEngine#39). 0 pauses; values at or below the
    /// cap pass through unchanged. On the native AVPlayer path audio pitch
    /// adjusts via `audioTimePitchAlgorithm`; on the SW path the rate goes
    /// through the synchronizer and audio plays at the changed rate
    /// without pitch correction.
    public func setRate(_ rate: Float) {
        let cap = maxSupportedRate
        let clamped = min(rate, cap)
        if clamped != rate {
            EngineLog.emit("[AetherEngine] setRate(\(rate)) clamped to \(clamped) (max supported on this path)", category: .engine)
        }
        activeTransportHost?.setRate(clamped)
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
        // Custom sources rebuild on the retained reader; a forward-only reader
        // cannot rewind, so it stays a no-op. This covers the live HLS-ingest
        // readers (incl. demuxed-audio companion sessions, whose published
        // audioTracks come from the side demuxer): rebuilding their pipeline
        // would have to re-consume an already-drained FIFO and would stall
        // silently, so the switch is refused up front. Logged (not silent) so
        // a host picker that appears to do nothing is explainable from the
        // session log.
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

    /// The sidecar subtitle URL the host most recently activated, kept
    /// so `selectAudioTrack` can rehydrate the same selection after the
    /// pipeline reload. Cleared by `clearSubtitle` and `stopInternal`.
    var loadedSidecarURL: URL?
    /// Active secondary sidecar URL, or nil. Mirror of `loadedSidecarURL`.
    var loadedSecondarySidecarURL: URL?

    // MARK: - Internal teardown

    /// - Parameter resetDisplayCriteria: When `true` (default), release
    ///   the `AVDisplayManager.preferredDisplayCriteria` so the panel
    ///   returns to its default mode. Used by `load()` and the public
    ///   `stop()` API where the next session may target a different
    ///   format. The audio-track-switch reload path passes `false`
    ///   because the same source is being re-prepared with only the
    ///   audio stream changing — keeping the criteria in place avoids
    ///   a redundant `apply` + `waitForSwitch` cycle that on some
    ///   panels (notably when paired with a Bluetooth A2DP audio route)
    ///   never settles and times out at 5 s, adding ~12 s of black-
    ///   screen latency per audio switch.
    func stopInternal(resetDisplayCriteria: Bool = true, keepNativeHost: Bool = false, keepCustomReader: Bool = false) {
        // Invalidate any in-flight load(): its post-await checkpoints
        // compare against this counter and unwind when stale.
        loadGeneration &+= 1
        // Stop AVPlayer fetching before tearing down the loopback HLS
        // server, otherwise AVPlayer's segment requests race the
        // server shutdown and produce noisy errors in the log. Display
        // criteria reset is gated by the parameter so audio-only reloads
        // preserve the panel mode (see method doc).
        //
        // `keepNativeHost` preserves the NativeAVPlayerHost and its
        // AVPlayer instance across a native->native reload (episode
        // change, audio-track switch). `tearDown()` still unloads the
        // current item (so AVPlayer stops fetching from the old loopback
        // server before that server is torn down), but the host and the
        // published `currentAVPlayer` survive. AVKit binds its MediaRemote
        // system Now-Playing registration to the AVPlayer instance once,
        // at first presentation, and never re-registers against a swapped
        // player ("Code=14 client callback"), so reusing the instance is
        // what keeps the iPhone Control Center widget populated across the
        // seam (issue #15). Callers that cross into the software path must
        // release the preserved host themselves (the SW pipeline needs the
        // currentAVPlayer sink to see a nil publish).
        memoryProbeTask?.cancel()
        memoryProbeTask = nil
        // The reload watchdog belongs to the session being torn down;
        // its generation check would make it a no-op anyway, but
        // cancelling here keeps no stray 1 Hz poller alive.
        liveReloadWatchdogTask?.cancel()
        liveReloadWatchdogTask = nil
        // Abort a probe blocked in open/find_stream_info (see
        // `inFlightProbeDemuxer`). Lock-free + idempotent; the owning
        // load() unwinds with openFailed and clears the reference.
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

        // Live scrub-thumbnail contexts die with the session.
        let liveThumbs = liveThumbnailExtractors
        liveThumbnailExtractors.removeAll()
        for entry in liveThumbs {
            Task { await entry.extractor.shutdown() }
        }

        // Mirror teardown for the SW path. stop() halts the demux loop,
        // releases the decoders / synchronizer / display layer, and
        // closes the host's own Demuxer. The display layer is owned by
        // the renderer and detaches from the bound view via the view's
        // own attach() on the next presentCurrentLayer call.
        softwareCancellables.removeAll()
        softwareHost?.stop()
        softwareHost = nil

        // Mirror teardown for the audio-only path. stop() halts the
        // demux loop, flushes + releases the renderer / synchronizer,
        // and closes the host's own Demuxer. Clearing audioHost here is
        // what makes a music -> video handoff (and vice versa) start
        // from a clean slate: the engine is a process-wide singleton, so
        // a lingering audioHost would keep the old synchronizer's clock
        // and renderer alive under the next session.
        audioCancellables.removeAll()
        audioHost?.stop()
        audioHost = nil

        // The AVPlayer audio host is KEPT alive across loads (its
        // MPNowPlayingSession must persist for stable system Now-Playing).
        // Mark it inactive and stop playback, but do NOT release it; the
        // next audio load reuses it via replaceCurrentItem.
        audioNativeCancellables.removeAll()
        audioAVPlayerActive = false
        audioAVPlayerHost?.stop()

        // Close the custom source reader on final teardown (a real stop or a
        // new load). Internal reloads pass keepCustomReader: true so the
        // retained reader survives the intermediate teardown for reuse.
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
        isBuffering = false
        // A stop landing mid-seek must not strand the in-flight signal: a
        // late host completion or restart-drain callback is dropped by the
        // generation/session guards, so clear hard here (#38).
        programmaticSeekInFlight = false
        nativeScrubSeekInFlight = false
        isSeeking = false
        seekTarget = nil

        liveWindowTimerTask?.cancel()
        liveWindowTimerTask = nil

        cancelSidecarTask()
        cancelEmbeddedSubtitleReader()
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

        // Pause VIDEO when the app backgrounds so it doesn't keep streaming
        // in the background. The host calls `reloadAtCurrentPosition()` from
        // its own foreground hook to recover from any AVIO invalidation tvOS
        // may do during suspension.
        //
        // AUDIO (music) is the opposite: it is MEANT to keep playing in the
        // background (UIBackgroundModes audio). Pausing it here, or even just
        // flipping `state` to .paused while the audio AVPlayer keeps playing,
        // desyncs the system Now-Playing rate (the system reads
        // MPNowPlayingInfoPropertyPlaybackRate to know play-vs-pause), making
        // tvOS believe we are paused-while-playing and breaking the Now-Playing
        // badge + Siri Remote routing. So skip this entirely for the audio
        // backends and let them stream on.
        let bgObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.audioAVPlayerActive || self.audioHost != nil { return }
                guard self.state == .playing || self.state == .paused else { return }
                self.nativeHost?.pause()
                // The SW path must pause too: without this a SW session
                // kept demuxing/decoding/streaming until tvOS suspended
                // the process, while the published state already said
                // .paused.
                self.softwareHost?.pause()
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
