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
        didSet {
            recomputePlaybackPhase()
            resolveLoadingStashedSeek(from: oldValue)
        }
    }

    /// Mid-playback rebuffer flag. `state` stays `.playing` across a rebuffer to avoid icon flicker;
    /// gate on this when you need to distinguish a stall from real playback (AetherEngine#35).
    /// Always false during initial load spin-up (`state == .loading`).
    @Published public internal(set) var isBuffering: Bool = false {
        didSet { recomputePlaybackPhase() }
    }

    /// True from seek entry until physical landing, covering programmatic seeks, native AVKit scrubs and
    /// seeks the session could not take yet (#127/#178 stash). Unlike `state == .seeking` (optimistically
    /// flipped to `.playing`), this spans the real loopback-HLS landing, which resolves seconds after the
    /// call (AetherEngine#38). Paired with `seekTarget`.
    ///
    /// A LEVEL signal: it says a seek is in flight, never why it stopped being one. Observe `seekEvents`
    /// where the falling edge itself carries weight (landed vs gave up vs superseded, and which target).
    @Published public internal(set) var isSeeking: Bool = false {
        didSet { recomputePlaybackPhase() }
    }

    /// Source-PTS seek destination, or nil when idle. Cleared on landing. For native scrubs, set to the
    /// out-of-range segment time AVPlayer requested (AetherEngine#38). Follows the most authoritative
    /// in-flight source (programmatic > scrub > deferred), so it never publishes a settled seek's target
    /// while a different one is in flight.
    @Published public internal(set) var seekTarget: Double? = nil

    /// Seek-lifecycle events: one value per transition, carrying the outcome and the target it belongs to
    /// (AetherEngine#38 follow-up). See `SeekEvent` for the contract, including the late `.landed` that
    /// can follow a `.stalled` and that `isSeeking` structurally cannot express.
    public var seekEvents: AnyPublisher<SeekEvent, Never> { seekEventSubject.eraseToAnyPublisher() }

    private let seekEventSubject = PassthroughSubject<SeekEvent, Never>()

    /// Monotonic id source for `SeekEvent`. Deliberately NOT `seekGeneration`: that counter is the
    /// supersede fence every in-flight finalize checks itself against, so a rejected or stashed seek must
    /// not be able to move it (it would make a live seek believe it lost and return without finalizing).
    private var seekEventCounter: UInt64 = 0

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

    /// #250: read-only view of the seek fence for the subtitle-resolution statement. Read-only on
    /// purpose: only `seek(to:)` may move the counter, and a diagnostic must not be able to.
    var currentSeekGeneration: UInt64 { seekGeneration }

    /// Three independent seek-in-flight flags that isSeeking OR-s over. Programmatic and native scrub
    /// seeks are NOT mutually exclusive: a far programmatic seek triggers the same producer-restart as a
    /// scrub. `deferred` is a seek stashed before the session could take it (#127/#178). Tracked
    /// separately so none can drop isSeeking before the others settle. Routed through
    /// `setProgrammaticSeek`/`setNativeScrubSeek`/`setDeferredSeek`.
    private var programmaticSeekInFlight = false
    private var nativeScrubSeekInFlight = false
    private var deferredSeekInFlight = false

    /// Per-source targets behind the published `seekTarget`. Kept apart because one fold over "the last
    /// non-nil target written" published a finished programmatic seek's destination while a scrub was in
    /// flight toward a different one, and a consumer broadcasting `seekTarget` broadcast the wrong place.
    private var programmaticSeekTarget: Double?
    private var nativeScrubSeekTarget: Double?
    private var deferredSeekTarget: Double?

    /// Event-side bookkeeping for one seek: the id its `.began` carried and the target it aims at. An
    /// open ticket IS the "not yet reported" state, so closing it is what prevents a double report.
    /// Deliberately outlives `programmaticSeekInFlight` on the give-up path: a seek reported `.stalled`
    /// stays alive inside AVPlayer as recovery intent, and the late landing that finally settles it has to
    /// arrive under the SAME id (AE#38 follow-up).
    struct SeekTicket {
        let id: UInt64
        let target: Double
        let origin: SeekEvent.Origin
    }

    var programmaticSeekTicket: SeekTicket?
    var nativeScrubSeekTicket: SeekTicket?
    private var deferredSeekTicket: SeekTicket?

    /// Armed scrub landing watch and its give-up timer; see `setNativeScrubSeek`.
    var pendingScrubLanding: PendingScrubLanding?
    var scrubLandingWatchdog: Task<Void, Never>?

    /// Was the in-flight restart run caused by a programmatic seek rather than a user scrub? Captured at
    /// the rising edge, because by the drain the programmatic seek may already have finalized.
    var scrubRestartOwnedByProgrammaticSeek = false

    private func nextSeekEventID() -> UInt64 {
        seekEventCounter &+= 1
        return seekEventCounter
    }

    /// Publishes one `SeekEvent` and logs it. The log line is the device-side record: a host that has not
    /// wired the stream still gets the same statement in `EngineLog`.
    func emitSeekEvent(id: UInt64, origin: SeekEvent.Origin, outcome: SeekEvent.Outcome, target: Double) {
        let event = SeekEvent(id: id, origin: origin, outcome: outcome, target: target)
        EngineLog.emit("[AetherEngine] \(event)", category: .engine)
        seekEventSubject.send(event)
    }

    /// Opens a ticket and publishes its `.began`.
    private func beginSeekTicket(origin: SeekEvent.Origin, target: Double) -> SeekTicket {
        let ticket = SeekTicket(id: nextSeekEventID(), target: target, origin: origin)
        emitSeekEvent(id: ticket.id, origin: origin, outcome: .began, target: target)
        return ticket
    }

    /// Terminates a ticket: emits the outcome under the id its `.began` carried, then closes it. A closed
    /// ticket is what keeps the late-landing hook from double-reporting a seek the finalize already
    /// settled, so every terminal path must run through here.
    func closeSeekTicket(_ ticket: inout SeekTicket?, with outcome: SeekEvent.Outcome) {
        guard let open = ticket else { return }
        emitSeekEvent(id: open.id, origin: open.origin, outcome: outcome, target: open.target)
        ticket = nil
    }

    /// The give-up contract: the seek drops out of `isSeeking`, but it is still alive inside AVPlayer as
    /// recovery intent, so its ticket stays OPEN and the late `.landed` arrives under the same id when the
    /// source finally serves the target (AE#38 follow-up, the case a level signal cannot express).
    func reportSeekStalled() {
        guard let open = programmaticSeekTicket else { return }
        emitSeekEvent(id: open.id, origin: open.origin, outcome: .stalled, target: open.target)
    }

    /// Recomputes isSeeking/seekTarget from the in-flight flags. Idempotent to avoid redundant Combine emissions.
    private func recomputeSeekSignal() {
        let seeking = programmaticSeekInFlight || nativeScrubSeekInFlight || deferredSeekInFlight
        // #240: a seek owns the link until it lands. Set unconditionally (not inside the
        // change guard) so the gate cannot drift from the flags it mirrors.
        sideReaderLinkGate.setSeeking(seeking)
        if isSeeking != seeking { isSeeking = seeking }
        let target = programmaticSeekTarget ?? nativeScrubSeekTarget ?? deferredSeekTarget
        if seekTarget != target { seekTarget = target }
    }

    private func setProgrammaticSeek(inFlight: Bool, target: Double?) {
        programmaticSeekInFlight = inFlight
        programmaticSeekTarget = inFlight ? target : nil
        recomputeSeekSignal()
    }

    /// #127/#178: a seek stashed before the session can take it. The engine publishes the target on
    /// `clock.currentTime` up front so scrub UI follows, which is exactly the position a consumer must NOT
    /// treat as reached, so the stash window carries the seek signal like any other in-flight seek.
    private func setDeferredSeek(inFlight: Bool, target: Double?) {
        deferredSeekInFlight = inFlight
        deferredSeekTarget = inFlight ? target : nil
        recomputeSeekSignal()
    }

    /// Opens (or replaces) the deferred stash entry. A second stashed seek supersedes the first, matching
    /// `pendingPreReadySeekSeconds`' own latest-wins rule.
    func beginDeferredSeek(target: Double) {
        closeSeekTicket(&deferredSeekTicket, with: .superseded)
        deferredSeekTicket = beginSeekTicket(origin: .deferred, target: target)
        setDeferredSeek(inFlight: true, target: target)
    }

    /// Ends the deferred stash window. `.superseded` when the replay hands it to a real seek, `.rejected`
    /// when the load died under it. No-op without an open stash.
    func endDeferredSeek(_ outcome: SeekEvent.Outcome) {
        guard deferredSeekInFlight || deferredSeekTicket != nil else { return }
        closeSeekTicket(&deferredSeekTicket, with: outcome)
        setDeferredSeek(inFlight: false, target: nil)
    }

    /// Rejection path: the seek never reached a host, so it gets a standalone event and no `.began`.
    func emitSeekRejected(_ reason: SeekEvent.Rejection, target: Double) {
        emitSeekEvent(id: nextSeekEventID(), origin: .programmatic, outcome: .rejected(reason), target: target)
    }

    /// Complete the seek state after a late async recovery landing settled the clock through the
    /// `$renderedTime` sink. The deadline loop holds the clock at the target and returns without
    /// finalizing when a pathologically slow source has not served the target GOP within the whole
    /// extension budget (spinner-at-target rather than the old revert + flap). When the re-anchored
    /// producer finally serves the target, the sink settles the clock onto it; clear the
    /// programmatic-seek gate and reconcile the transport here so `state`/`isSeeking` leave `.seeking`
    /// instead of parking a spinner over a now-live frame.
    ///
    /// The event half runs even when the gate is already closed, which is the whole point: a seek that
    /// exhausted its budget was reported `.stalled` and dropped out of `isSeeking`, but it stayed alive
    /// as recovery intent, and this is where its real landing finally becomes observable. A level signal
    /// has no edge left to spend there, so the ticket carries it (AE#38 follow-up).
    func finalizeLateRecoverySeekLanding(rendered: Double) {
        closeSeekTicket(&programmaticSeekTicket, with: .landed(renderedTime: rendered))
        guard programmaticSeekInFlight else { return }
        setProgrammaticSeek(inFlight: false, target: nil)
        if let nativeHost {
            reconcileNativeSeekTransport(host: nativeHost, isStarved: false)
        }
    }

    /// Wired to `HLSVideoEngine.onSeekStateChanged`; see `requestRestart`. `target` is on the display
    /// axis; nil on the falling edge.
    ///
    /// The falling edge from the coalescer means "the producer is now producing at the new index", NOT
    /// "AVPlayer rendered it": the picture arrives a fetch and a decode later, measured at 1.4 s on a WAN
    /// source by the host this signal exists for. Clearing there published a landing that had not
    /// happened. Instead the scrub stays in flight and a landing watch on `$renderedTime` closes it when
    /// the picture actually reaches the target, bounded by `nativeScrubLandingBudgetSeconds` so a source
    /// that never serves it degrades to `.stalled` rather than latching the signal (AE#38 follow-up).
    func setNativeScrubSeek(inFlight: Bool, target: Double?) {
        if inFlight {
            // A restart that a programmatic seek caused is that seek's business: it owns the landing, its
            // own target is where the picture will end up, and the restart segment can sit a segment below
            // it (probe: restart 84.0, landing 90.0). Watching for a landing at the RESTART target there
            // would report a miss on a seek that landed fine, so this restart keeps the old drain-edge
            // semantics and the programmatic ticket carries the outcome.
            scrubRestartOwnedByProgrammaticSeek = programmaticSeekInFlight
            guard let target else {
                // No resolvable segment time (index outside the plan): keep the flag honest but publish no
                // target, and leave the landing watch unarmed.
                nativeScrubSeekInFlight = true
                nativeScrubSeekTarget = nil
                recomputeSeekSignal()
                return
            }
            if let open = nativeScrubSeekTicket, open.target != target {
                closeSeekTicket(&nativeScrubSeekTicket, with: .superseded)
            }
            // No ticket for a programmatic seek's own restart: that seek's events are the authority, and a
            // second pair reporting a landing at the RESTART target (a segment below where the picture
            // ends up) would contradict them. The level flag is still set, exactly as before.
            if nativeScrubSeekTicket == nil, !scrubRestartOwnedByProgrammaticSeek {
                nativeScrubSeekTicket = beginSeekTicket(origin: .nativeScrub, target: target)
            }
            nativeScrubSeekInFlight = true
            nativeScrubSeekTarget = target
            // A fresh restart run supersedes any armed watch; its watchdog must not outlive it and trip
            // the next one's window.
            pendingScrubLanding = nil
            scrubLandingWatchdog?.cancel()
            scrubLandingWatchdog = nil
            recomputeSeekSignal()
            return
        }
        // Coalesced restart run drained. Hand the falling edge to the landing watch when this restart was
        // a user scrub with a target and a native host to watch; otherwise settle now, exactly as before.
        guard !scrubRestartOwnedByProgrammaticSeek,
              let watchTarget = nativeScrubSeekTarget,
              let host = nativeHost else {
            // AE#270: the event's `target` is on the display axis, so its landing has to be too.
            finishNativeScrubSeek(.landed(renderedTime: PresentationAxis.display(
                sourcePTS: clock.sourceTime, origin: sourcePresentationOrigin)))
            return
        }
        pendingScrubLanding = PendingScrubLanding(
            displayTarget: watchTarget,
            playlistTarget: PresentationAxis.source(displayTime: watchTarget,
                                                    origin: sourcePresentationOrigin) - playlistShiftSeconds,
            frozenRendered: host.renderedTime
        )
        // The watch runs on `$renderedTime`, which goes silent while AVPlayer waits to play, so the
        // give-up cannot be tick-driven.
        scrubLandingWatchdog?.cancel()
        let budget = Self.nativeScrubLandingBudgetSeconds
        scrubLandingWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            guard !Task.isCancelled, let self, self.pendingScrubLanding != nil else { return }
            EngineLog.emit(
                "[AetherEngine] scrub landing watch expired after \(String(format: "%.0f", budget))s; "
                + "reporting stalled",
                category: .engine
            )
            self.finishNativeScrubSeek(.stalled)
        }
        checkPendingScrubLanding(rendered: host.renderedTime)
    }

    /// Closes the scrub's in-flight window and its ticket, and disarms the landing watch.
    func finishNativeScrubSeek(_ outcome: SeekEvent.Outcome) {
        pendingScrubLanding = nil
        scrubLandingWatchdog?.cancel()
        scrubLandingWatchdog = nil
        closeSeekTicket(&nativeScrubSeekTicket, with: outcome)
        nativeScrubSeekInFlight = false
        nativeScrubSeekTarget = nil
        recomputeSeekSignal()
    }

    /// `$renderedTime` hook for the scrub landing watch. No-op unless a watch is armed.
    func checkPendingScrubLanding(rendered: Double) {
        guard let watch = pendingScrubLanding else { return }
        guard Self.nativeScrubLanded(rendered: rendered,
                                     target: watch.playlistTarget,
                                     frozen: watch.frozenRendered) else { return }
        finishNativeScrubSeek(
            .landed(renderedTime: PresentationAxis.display(sourcePTS: rendered + playlistShiftSeconds,
                                                           origin: sourcePresentationOrigin))
        )
    }

    /// Armed when a coalesced scrub restart drains; retired when the picture reaches the target or the
    /// watchdog expires. `playlistTarget` is the AVPlayer-axis twin of `displayTarget`, because
    /// `renderedTime` is on the playlist axis.
    struct PendingScrubLanding {
        let displayTarget: Double
        let playlistTarget: Double
        let frozenRendered: Double
    }

    /// Budget for the scrub landing watch. Same order as the programmatic seek's reconcile budget: past
    /// it, "not landed" is the honest report.
    static let nativeScrubLandingBudgetSeconds: Double = 8.0

    /// High-frequency playback clock (currentTime, sourceTime, live-edge). Separate ObservableObject:
    /// its ~10 Hz ticks must not fire objectWillChange on the engine or every SwiftUI view re-renders per
    /// tick, causing tvOS Menu flicker (AetherEngine#29). Observe only in leaf views that render time.
    public let clock = PlaybackClock()

    /// Forwarder; for push updates subscribe to `clock.$currentTime` (objectWillChange does NOT fire on ticks).
    public var currentTime: Double { clock.currentTime }

    /// Deactivate the shared `AVAudioSession` when playback is torn down for good. Default `false`.
    ///
    /// Opt in only if your app owns the audio session. On an E-AC-3/Atmos BITSTREAM PASSTHROUGH route the
    /// HDMI sink keeps its own decode ring, and with the session still active it can loop the last MAT
    /// frame after the player is released (audio keeps stuttering after leaving the video, even off-screen).
    /// Deactivating on final teardown closes that ring.
    ///
    /// It is off by default because the native path deliberately never *activates* the session -- AVKit
    /// does that per playback (#24) -- so switching this on makes the engine mutate process-global state it
    /// did not create, using `.notifyOthersOnDeactivation`. An app that plays its own audio (UI sounds, TTS,
    /// an `AVAudioEngine`, a background music player) would have its session torn out from under it. Only
    /// a genuine final teardown honours this: `stop()` (with `resetDisplayCriteria: true`), never a
    /// handoff, reload, or retune.
    ///
    /// Applies to every backend, not just the native one. The software and audio renderer paths bypass
    /// AVKit and activate the session themselves (`activateRendererAudioSession`), so for those the
    /// deactivation is the engine releasing what the engine took.
    ///
    /// The release runs just after the teardown rather than inside it. `setActive(false)` is an XPC round
    /// trip that takes roughly half a second on an Atmos MAT passthrough route, which inline would be half
    /// a second of frozen UI before the host's dismiss can start. A `load()` that follows cancels a release
    /// that has not run yet, so a stop/load pair never loses its session.
    public var deactivatesAudioSessionOnStop: Bool = false

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
    /// Container (Matroska/MP4) chapters of the loaded source, from the probe demuxer at load. Empty
    /// when the container declares none and for disc sources (whose chapters publish on `discChapters`
    /// with title-relative seek semantics). `startSeconds` values are content timestamps a host passes
    /// straight to `seek(to:)`.
    @Published public internal(set) var mediaChapters: [ChapterInfo] = []
    /// The id of the title the disc demuxer should (re)open with. Mirrors `selectedDiscTitle?.id` but
    /// kept as plain state so it survives the stopInternal inside a reload and threads into audio-switch /
    /// background-resume reopens (a URL-disc reopen with no id would silently revert to the main title).
    var activeDiscTitleID: Int?

    /// Source container start PTS (seconds) from the probe (AVFormatContext.start_time). The software-path
    /// playback clock begins here (the native path's content base is `playlistShiftSeconds`), so a DVD
    /// chapter seek adds it to the chapter's title-relative (0-based) target. 0 when unknown (#67).
    var sourceStartSeconds: Double = 0

    /// Active playback backend: `.native` (AVPlayer) or `.software` (SoftwarePlaybackHost/dav1d/libavcodec).
    /// Exposed for diagnostic overlays; hosts should not branch on it. Branch on `videoRoute` instead,
    /// which also separates the two native pipelines (#321).
    @Published public internal(set) var playbackBackend: PlaybackBackend = .none {
        didSet { recomputeVideoRoute() }
    }

    /// Pipeline actually serving this session (#321), including the reroutes the host never asked for.
    /// Derived from `playbackBackend` + `loadedOptions.nativeRemoteHLS`, the two properties every reroute
    /// site already writes, so it cannot desync from them. See `VideoRoute` for the transitions.
    @Published public internal(set) var videoRoute: VideoRoute = .none

    /// Idempotent: assigns only on a real change, so options writes that leave the route alone (the
    /// per-reopen replay) do not flap the publisher. Logs every route the session takes; the drop to
    /// `.none` is teardown, which carries no route information and is already loud in the log.
    private func recomputeVideoRoute() {
        let next = VideoRoute.derive(backend: playbackBackend,
                                     nativeRemoteHLS: loadedOptions.nativeRemoteHLS)
        guard videoRoute != next else { return }
        videoRoute = next
        if next != .none {
            EngineLog.emit("[AetherEngine] #321: effective video route = \(next.rawValue)", category: .engine)
        }
    }

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

    /// #315: the running path has a first frame ready for display, for the media this `load()`
    /// opened. This is the edge a black cover comes off on; `isSessionReady` is not that edge and
    /// cannot be made into one.
    ///
    /// `isSessionReady` is `AVPlayerItem.readyToPlay`, which AVFoundation reaches before the layer
    /// holds a picture and which stays true across a seek. Measured on a loopback origin, the
    /// player's layer reports its first frame ~0.05 s into a load and `timeControlStatus` follows
    /// at ~0.10 s; on a slow origin those separate by as much as the source is slow, and a load
    /// opened paused never produces the second one at all. Hosts approximating presentation from
    /// `phase == .playing/.paused && isSessionReady` therefore lift the cover onto black.
    ///
    /// What backs it: `AVPlayerLayer.isReadyForDisplay` on the native path,
    /// `AVSampleBufferDisplayLayer.isReadyForDisplay` on the software one (below tvOS/iOS 17.4 and
    /// macOS 14.4, where that property does not exist, the software path falls back to the first
    /// frame handed to the renderer, one hop earlier than presentation). Audio-only sessions have
    /// nothing to display and leave it false.
    ///
    /// Two things it does NOT claim:
    ///
    /// - **Not "the viewer sees it".** It is the pipeline's own statement that a first frame is
    ///   ready. The engine's layer reaches it even when it is in no view hierarchy (measured), so
    ///   a host that never bound a surface still gets true here while showing nothing (#298), and
    ///   an `AVPlayerViewController` host presents through AVKit's own layer a frame or so later.
    /// - **Not a level.** It is latched for the load: false at every `load()` and at `stop()`, true
    ///   once and then held. The seams that reuse the running host (media fallback, the wired-HDMI
    ///   AirPlay master swap, the #93 recovery reload, the AE#158 in-place handover) each drop the
    ///   layer's picture for a few tens of milliseconds, measured, and this holds true through
    ///   them: reporting them would make a host re-cover a seam it is deliberately not meant to
    ///   see, and a falling edge would be ambiguous in exactly the way `SeekEvent` was introduced
    ///   to fix, since nothing in a level says why it fell. A rebuild that goes back through
    ///   `load()`, `reloadAtCurrentPosition()` included, does reset it: there the item is genuinely
    ///   gone and its first frame has to be reached again.
    ///
    /// For "has this seek reached the screen", the per-seek answer is `SeekEvent.landed`, not this
    /// flag: a seek keeps the previous frame up, so the layer never stops being ready for display.
    @Published public internal(set) var hasFirstFrameReadyForDisplay = false

    /// #127: latest host seek issued while the native item was pre-ready; replayed at readiness.
    var pendingPreReadySeekSeconds: Double?
    /// AE#158: set by load() when the running item must survive until the new master attaches (PiP
    /// next-episode handover); consumed and reset by the loopback host.load callsite (inPlaceSwap).
    var pendingInPlaceItemHandover = false
    /// SW-PiP bridge, the software-path analog of `currentAVPlayer`: set when a SW session has its
    /// display layer, nil on teardown. Hosts build their sample-buffer PiP ContentSource from it.
    @Published public internal(set) var softwarePiPSource: SoftwarePiPSource?

    /// #288: the native-path counterpart of `softwarePiPSource.layer`. `AVPictureInPictureController`
    /// wants the layer, not the player, so a host presenting its own PiP on the native path (tvOS has
    /// no reachable AVKit affordance behind suppressed chrome) cannot get there from `currentAVPlayer`.
    /// nil while no native session exists, which is also the honest signal for hiding a PiP button:
    /// a software session has no AVPlayerLayer, it has `softwarePiPSource`.
    ///
    /// Read it per session rather than caching it. The layer survives item swaps and the PiP
    /// next-episode handover (AE#158), but `stop()` tears the host down and the next `load()` builds
    /// a fresh layer. A host driving PiP must still set `pictureInPictureActive`, which arms both the
    /// keepalive policy and that in-place handover.
    public var nativePlayerLayer: AVPlayerLayer? { nativeHost?.playerLayer }
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

    /// #178: what to do with a seek stashed while `state == .loading` when `state` changes.
    /// Only transitions OUT of `.loading` resolve the stash; every other transition holds it
    /// (non-loading stashes belong to the #127 readiness sink). `.seeking` cannot follow
    /// `.loading` (the `.loading` guard stashes instead of seeking) but holds defensively.
    enum LoadingStashResolution { case replay, discard, hold }

    nonisolated static func loadingStashResolution(
        oldState: PlaybackState, newState: PlaybackState
    ) -> LoadingStashResolution {
        guard oldState == .loading else { return .hold }
        switch newState {
        case .playing, .paused: return .replay
        case .idle, .ended, .error: return .discard
        case .loading, .seeking: return .hold
        }
    }

    /// #178: `state` didSet hook. Replays the loading-window seek once the session settles into a
    /// playable state (covers autostart paths where readiness fires while `state` is still
    /// `.loading` and the #127 sink must not replay yet), discards it when the load dies.
    private func resolveLoadingStashedSeek(from oldState: PlaybackState) {
        guard let pending = pendingPreReadySeekSeconds else { return }
        switch Self.loadingStashResolution(oldState: oldState, newState: state) {
        case .hold:
            return
        case .discard:
            pendingPreReadySeekSeconds = nil
            // The load died under the stash; the seek never reaches a host (#38 follow-up).
            endDeferredSeek(.rejected(.noActiveSession))
        case .replay:
            pendingPreReadySeekSeconds = nil
            EngineLog.emit("[AetherEngine] replaying seek stashed during load to \(String(format: "%.2f", pending))s (#178)", category: .engine)
            Task { @MainActor in await self.seek(to: pending) }
        }
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
    /// #271: monotonic timestamp of the previous drain tick, so a tick that ran long is not read as
    /// a seek by the next one (`SubtitleOverlayDrainer.drainPlan`). Per tick, not per channel: both
    /// channels are planned in the same pass off the same playhead. nil before the first tick.
    var subtitleDrainLastTickUptime: Double?
    /// #271: the OCR worker's own tick timestamp; same rule, separate cadence.
    var subtitleOCRLastTickUptime: Double?
    /// #250: the frontier source of the last statement emitted per channel, so a change of source
    /// (the prefetcher dying, EOF landing) gets its own line instead of waiting for the 30 s
    /// cadence. nil before the first statement of a session.
    var subtitleResolutionLastFrontier: [SubtitleChannel: SubtitleResolutionStatement.Frontier] = [:]
    /// #318: channels whose current decoded run has already stated determination at the playhead,
    /// so the crossing is announced once and not on every tick after it. Cleared per channel by
    /// every reset, because a fresh run's coverage is a fresh question.
    var subtitleResolutionCoverageStated: Set<SubtitleChannel> = []
    /// #151: subtitle-only forward side reader filling the session packet store up to
    /// playhead + subtitleDrainLeadSeconds independent of the producer's forward park, so the
    /// drainer's lead window holds cues for host-applied ADVANCE sync offsets (text and bitmap).
    /// nil while idle (subs off, live session, EOF reached).
    var subtitleForwardPrefetchTask: Task<Void, Never>?
    var subtitleForwardPrefetchDemuxer: Demuxer?
    /// #240: the running session's in-place anchor box, so a playhead jump moves its cursor instead
    /// of rebuilding the session. nil while no session is live.
    var subtitleForwardPrefetchReanchor: SubtitleForwardPrefetcher.SideReaderReanchor?
    /// #240: the lead the running session was started with. A changed lead (the OCR worker arming)
    /// is the one anchor change that still needs a rebuild, since the loop captures it at start.
    var subtitleForwardPrefetchActiveLead: Double?
    /// #240: link arbitration between the video path and the subtitle side readers. On Matroska a
    /// side reader is a second full copy of the stream, so on a link with little headroom the two
    /// starve each other; the video path has priority. See `SideReaderLinkPolicy`.
    nonisolated let sideReaderLinkGate = SideReaderLinkGate()
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
    /// #271: per-tick decode cap for the overlay drainer, extended to the next PTS boundary
    /// (`SubtitleOverlayDrainer.batchEnd`). The drain window is bounded in seconds of content, so on
    /// a dense typeset track one window is thousands of packets and the loop holds the main actor
    /// for all of them. Generous on purpose: the backscan sits at the head of the window, so the
    /// cues around the playhead still land in the first batch and the rest of the 60 s lead fills
    /// over the following ticks.
    nonisolated static let subtitleDrainMaxPacketsPerTick: Int = 256
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
    /// #231: a prefetch session that dies on a read error is restarted, bounded. Consecutive
    /// failures are what a dead link looks like; the total ceiling covers a source that fails in a
    /// loop after harvesting a packet each time.
    nonisolated static let subtitleForwardPrefetchMaxConsecutiveFailures: Int = 3
    nonisolated static let subtitleForwardPrefetchMaxRestarts: Int = 8
    /// Doubles per consecutive failure (1s, 2s, 4s), capped by the consecutive-failure ceiling.
    nonisolated static let subtitleForwardPrefetchRestartBackoffNanoseconds: UInt64 = 1_000_000_000

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

    /// TEST-ONLY: scales the reader's reconnect backoff (1.0 = real timing). Read once by each
    /// `AVIOReader` at init, so set it before `load`/`start`. Lets a bounded give-up that spans
    /// ~13 exponential backoffs finish in test time instead of a minute of real sleeping.
    nonisolated(unsafe) static var reconnectBackoffScaleForTesting = 1.0

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

    /// DV/SMB forward-seek revert fix: when the first budget expires but the producer is demonstrably
    /// serving the target region (buffer at the seek target is above the floor and still growing), the
    /// seek is slow, not wedged, and the recovery (clock revert + producer re-anchor) would destroy
    /// in-flight download progress and park the session. Grant a bounded number of shorter extension
    /// windows so a slow SMB / Dolby-Vision source can land, before falling back to recovery.
    static let nativeSeekMaxDeadlineExtensions: Int = 4
    /// Per-extension budget, shorter than the initial budget so a landing is detected promptly.
    ///
    /// This also bounds how long `await seek(to:)` can stay suspended. Worst case is
    /// `8s initial + 4×4s extensions + 4s re-issued seek + 4×4s post-re-anchor waits ≈ 44s`, reached only
    /// on a source that keeps making measurable progress and then never lands. The loop cannot exceed it:
    /// both counters are monotone and never reset, so it runs at most 10 iterations before the terminal
    /// give-up, which reports `.rebuffering`/`.stalled` rather than staying `.seeking`.
    static let nativeSeekExtensionBudgetSeconds: Double = 4.0
    /// This much media buffered AT the seek target proves the producer is serving it: extend rather than
    /// recover. `bufferedEnd`/`seekIsWedged` are blind to it (they only span the pinned pre-seek
    /// playhead); `NativeAVPlayerHost.bufferedSecondsAtTarget(_:)` measures it directly against the
    /// target, needing no playhead reference. Presence alone is not enough, see
    /// `shouldExtendSeekDeadlineForProgress`, which also requires the figure to be growing.
    static let nativeSeekProgressIslandFloorSeconds: Double = 1.0

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

    /// AE#270: the origin this session settled on, nil before the first publish. A non-disc VOD source
    /// keeps its first one: later publishes fold producer drift into the shift, and re-reading them would
    /// move the display axis under a picture that has not moved.
    var latchedPresentationOrigin: Double?

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

    /// Shift seam history on the item axis. The producer rebases immediately (live program boundary) or starts a
    /// fresh epoch (VOD restart); AVPlayer renders that content ~buffer+holdback later. The currentTime sink
    /// resolves the active shift by looking up the newest seam at or before the raw clock (a history, not a
    /// queue: backward DVR seeks must fold pre-seam content with pre-seam shift). Cleared on load/stop.
    ///
    /// Write only through `setPresentationAxis`, which keeps the off-main mirror in step.
    private(set) var presentationAxis = PresentationAxisMap()

    /// Off-main mirror of `presentationAxis`. Read by hosts converting between axes on their own thread
    /// (subtitle rasterisation, #260); the map itself is main-actor state.
    let presentationAxisMirror = AtomicPresentationAxisMap()

    /// Conversion between the source-PTS axis (subtitle cues, chapters, `sourceTime`) and the item axis
    /// (`AVPlayerItem.currentTime()`, its timebase, `NativeVideoFrameTime.item`) for the native path.
    /// Readable off the main actor. Empty on the SW and audio paths, which have no producer shift (#260).
    public nonisolated var presentationAxisMap: PresentationAxisMap {
        presentationAxisMirror.get()
    }

    /// Host observer for per-frame presentation times (#260). Held here so it survives across loads and is
    /// re-installed on each new native session; see `setNativeVideoFrameTimeObserver`.
    var nativeVideoFrameTimeObserver: NativeVideoFrameTimeObserver?

    /// The software path's equivalent (#311), held for the same reason: a `load()` builds a fresh
    /// host, and the observer has to survive it. See `setSoftwareVideoFrameTimeObserver`.
    var softwareVideoFrameTimeObserver: SoftwareVideoFrameTimeObserver?

    func setPresentationAxis(_ map: PresentationAxisMap) {
        presentationAxis = map
        presentationAxisMirror.set(map)
    }

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
    /// Read by AetherEngine+FrameExtractor. Every internal reroute (#154, #168, #199, #246, #268) reaches
    /// the published route through this property, so its writes feed `recomputeVideoRoute` (#321).
    private(set) var loadedOptions: LoadOptions = .init() {
        didSet { recomputeVideoRoute() }
    }

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

    /// #266: one pass over one container, filling every native store whose external track points at
    /// it. Tracks that share a URL and headers collapse into a single job, so a container holding
    /// several subtitle streams is fetched once rather than once per registered track.
    struct ExternalSubtitleFillJob: Sendable {
        struct Target: Sendable {
            /// Absolute AVStream index in this container, nil for its first subtitle stream.
            let streamIndex: Int32?
            let store: NativeSubtitleCueStore
        }
        let url: URL
        let headers: [String: String]
        let targets: [Target]
    }

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

    /// #214 follow-up: `LoadOptions.confirmAtmos` state. The ledger is the session's authority on which
    /// stream indices carry JOC, because a mid-session audio switch republishes `audioTracks` and would
    /// otherwise drop a confirmed flag. It is keyed to the source it was gathered from, so it invalidates
    /// itself on a new item and survives a session-preserving reload of the same one.
    var atmosConfirmationTask: Task<Void, Never>?
    var atmosConfirmationDemuxer: Demuxer?
    var confirmedAtmosStreamIndices: Set<Int32> = []
    var confirmedAtmosSource: URL?

    /// AE#154: publishes the remote-HLS bypass item's legible options as `subtitleTracks`.
    /// Session-scoped; cancelled on load()/stop() alongside the other subtitle tasks.
    var remoteHLSSubtitleDiscoveryTask: Task<Void, Never>? = nil

    /// #316: the loopback origin standing in front of a remote HLS master to carry the host's declared
    /// sidecars as legible renditions. Nil whenever the bypass plays the origin URL directly, which is
    /// every live source, every source without declared sidecars, and every refused rewrite.
    var remoteHLSSubtitleProxy: RemoteHLSSubtitleProxy.Prepared?

    /// #316: external track id -> the NAME its injected rendition carries in the served master. Selecting
    /// one of these must drive AVMediaSelection, not the sidecar overlay, or the two draw on top of
    /// each other. Empty when no proxy is standing.
    var injectedSubtitleRenditionNames: [Int: String] = [:]

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

    /// #199: masters whose #168 carriage verdict fired; consulted at the top of `load(source:)` to
    /// route known cases straight onto the live-ingest loopback. Engine-lifetime by design: it must
    /// survive stop()/load() seams (zap away and back) or the discovery tax returns per retune.
    var rerouteVerdictMemory = RerouteVerdictMemory()
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
        // #227: while AirPlaying, the item under the rejection is the LAN-IP URL; `mediaPlaylistURL` is the
        // 127.0.0.1 loopback the receiver cannot reach, so the fallback has to be rewritten too or the
        // recovery loads nothing. Media playlist already, so there is no master to keep.
        let fallbackURL = airPlayActive ? (airPlayPlaybackURL(base: mediaURL) ?? mediaURL) : mediaURL
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
        host.load(url: fallbackURL,
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

    /// First settle window on a wireless AirPlay hop (#227 follow-up). The receiver fetches across the LAN
    /// and runs its own decode handshake before anything is playable, which the local 3 s window can miss.
    static let airPlayGateInitialSeconds: Double = 6.0

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
    ///
    /// #227: the same escalation is what a wireless AirPlay hop needs. The master kept for an SDR source
    /// carries the subtitle renditions but assumes the receiver can take that variant, which the sender
    /// cannot check (a receiver without 4K HEVC would reject it). The gate covers the rejection and the
    /// silent park, and its reloads are rewritten onto the LAN IP so the receiver can reach them at all.
    @MainActor
    private func runStartupReadinessGate(
        session: HLSVideoEngine, position: Double, gen: UInt64
    ) async throws {
        guard let host = nativeHost else { return }
        host.startupReadinessGateActive = true
        defer { host.startupReadinessGateActive = false }

        // A receiver's first fetch crosses the LAN and its own decode handshake, so the local 3 s settle
        // window would judge a healthy AirPlay start too early and reload a master that was on its way.
        let initialSettle = airPlayActive
            ? Self.airPlayGateInitialSeconds
            : Self.startupGateInitialSeconds
        var attempt = 1
        var dataWaitRounds = 0
        while true {
            // Attempt 1 plays the item the load path already created; later attempts replay it fresh.
            host.play()
            let timeout = attempt == 1
                ? initialSettle
                : Self.startupGateReloadSeconds
            let outcome = await host.awaitStartupReadiness(timeoutSeconds: timeout)
            try checkLoadCurrent(gen)

            // AE#169 round 3: the data-wait exists for a first segment still being produced. A pump
            // that already exited with nothing served (tail resume onto an unproducible final
            // segment) can never satisfy it; consult liveness so the gate fails over immediately
            // instead of riding 24 s of false hope. A restart in flight reads as still-producing.
            let productionFinished = session.currentProducerFinished && !session.restartInFlight
            if outcome == .awaitingData, productionFinished {
                EngineLog.emit(
                    "[AetherEngine] #169 readiness gate: production already finished with no data "
                    + "served; skipping the data-wait (not a slow link)",
                    category: .session)
            }

            switch StartupReadinessGate.nextAction(
                outcome: outcome,
                attempt: attempt,
                masterAlreadyFellBack: masterFallbackUsed,
                hasMediaFallbackURL: session.mediaPlaylistURL != nil,
                dataWaitRounds: dataWaitRounds,
                productionFinished: productionFinished
            ) {
            case .proceed:
                return

            case .keepAwaitingData:
                // #169: the master's first segment (a tail resume anchors it on the final segment) has
                // not been served yet because it is still being produced over a slow link. That is not a
                // cold DV/HDCP decode failure; keep the DV master and re-await the SAME item rather than
                // reloading and falling back to the media playlist (which would needlessly drop DV).
                dataWaitRounds += 1
                EngineLog.emit(
                    "[AetherEngine] #35/#169 readiness gate: master's first segment not served yet "
                    + "(still producing over a slow link); keeping the DV master and waiting "
                    + "(data-wait \(dataWaitRounds)/\(StartupReadinessGate.maxDataWaitRounds)) at "
                    + "\(String(format: "%.2f", position))s",
                    category: .session)
                continue

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
                host.load(url: airPlayHostSwapped(masterURL), startPosition: position, inPlaceSwap: true)
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
                    host.load(url: airPlayHostSwapped(reducedURL), startPosition: position, inPlaceSwap: true)
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
                host.load(url: airPlayHostSwapped(mediaURL), startPosition: position, inPlaceSwap: true)
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
            + (isLive ? "the live edge (rejoin)" : "\(String(format: "%.2f", anchor))s")
            + Self.recoveryAnchorLogSuffix(
                anchor: anchor, position: position,
                pendingSeekTarget: pendingRecoverySeekClockTarget)
            + " (same URL, same host)",
            category: .engine
        )
        // Live reload = live REJOIN: no stale-clock resume, no explicit start seek — the
        // zero-tolerance seek into a possibly-slid window wedges the fresh item in waitingToPlay.
        // Same contract as the #98 media fallback above; see LiveReloadPolicy.
        host.load(url: url,
                  startPosition: isLive ? nil : anchor,
                  skipInitialSeek: LiveReloadPolicy.skipInitialSeek(isLive: isLive, isRejoin: true),
                  inPlaceSwap: true)
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

    /// Tolerance for "the playhead has reached the end of a VOD" (AetherEngine#164). Absorbs the
    /// frame-granular gap between a scrub-to-end target and the exact declared duration, plus the
    /// loopback playlist-shift float error, without tripping on a deliberate pause a second or two
    /// before the credits.
    nonisolated static let endOfMediaEpsilonSeconds: Double = 0.5

    /// True when a non-live source's playhead sits at (or past) its final frame (AetherEngine#164).
    /// Live sources have no fixed end, and an unknown (zero) duration cannot be "reached".
    nonisolated static func isAtEndOfMedia(currentTime: Double, duration: Double, isLive: Bool) -> Bool {
        guard !isLive, duration > 0 else { return false }
        return currentTime >= duration - endOfMediaEpsilonSeconds
    }

    /// True when a native VOD tick shows the tail-park signature of AetherEngine#169: the final segment
    /// is loaded to (approximately) the advertised end, yet the playhead sits a hair short of `duration`
    /// waiting to minimize stalls. The final segment's advertised EXTINF is derived from the container
    /// duration (`sourceDurationSeconds`), which overshoots the last real video sample whenever the audio
    /// track runs a few frames longer or the container duration is rounded up; the video renderer then
    /// has no frame for the last fraction of a second, AVPlayer parks in WaitingToMinimizeStalls, never
    /// fires didPlayToEndTime, and after ~43 s dies with CoreMediaErrorDomain -12889.
    ///
    /// The `loadedEnd` guard is the discriminator against a still-downloading final segment: a playhead
    /// within the end epsilon but with the media loaded well short of `duration` is a recoverable network
    /// stall, NOT exhausted video, and must be left to the stall/reload recovery. A live source, an
    /// actually-playing item, a deliberate pause (not waiting-to-play), and a mid-stream position all fail
    /// the guards above.
    nonisolated static func endOfMediaParkTickQualifies(
        isLive: Bool,
        duration: Double,
        playhead: Double,
        loadedEnd: Double,
        waitingToPlay: Bool,
        minimizingStalls: Bool
    ) -> Bool {
        guard !isLive, duration > 0 else { return false }
        guard waitingToPlay, minimizingStalls else { return false }
        guard isAtEndOfMedia(currentTime: playhead, duration: duration, isLive: isLive) else { return false }
        return loadedEnd >= duration - endOfMediaEpsilonSeconds
    }

    /// Rolling count of consecutive 1 Hz native ticks whose tail-park conditions held with a frozen
    /// playhead. Resets to zero the instant a tick stops qualifying or the playhead advances, so a
    /// momentary near-end buffering blip that then resumes never accumulates toward completion.
    nonisolated static func endOfMediaParkFrozenTicks(
        previous: Int,
        tickQualifies: Bool,
        playheadFrozen: Bool
    ) -> Int {
        (tickQualifies && playheadFrozen) ? previous + 1 : 0
    }

    /// Grace before synthesizing end-of-media from a tail park (AetherEngine#169): the park must persist
    /// this many consecutive 1 Hz ticks so a transient near-end stall that self-recovers is never cut
    /// short. Three ticks (~3 s) still finishes far faster than the ~43 s AVPlayer takes to surface -12889.
    nonisolated static let endOfMediaParkGraceTicks: Int = 3

    /// Synthesize organic end-of-media once the tail park has persisted past the grace window.
    nonisolated static func shouldSynthesizeEndOfMediaFromPark(frozenTicks: Int) -> Bool {
        frozenTicks >= endOfMediaParkGraceTicks
    }

    /// How far short of `duration` an end-of-item event must land before it counts as premature
    /// (AetherEngine#287). Deliberately above `endOfMediaEpsilonSeconds` so the #169 tail park owns the
    /// last half second and the two can never contend for the same event.
    nonisolated static let prematureEndShortfallSeconds: Double = 1.0

    /// How far past the playhead AVPlayer's own seekable range must reach before its end-of-item event
    /// counts as self-contradicted (AetherEngine#287).
    nonisolated static let prematureEndSeekableLeadSeconds: Double = 1.0

    /// Cap on premature-end recoveries per item (AetherEngine#287). A source whose video track has
    /// several holes gets a recovery at each of them; a pathological one cannot spin.
    nonisolated static let prematureEndRecoveryMaxAttempts: Int = 3

    /// A recovery must have moved the playhead by at least this much before another one is allowed
    /// (AetherEngine#287). Re-seeking a position that already failed to resume would loop forever.
    nonisolated static let prematureEndRecoveryMinProgressSeconds: Double = 0.5

    /// True when AVPlayer's `didPlayToEndTime` is contradicted by AVPlayer's own seekable range, i.e. it
    /// ended the item tens of seconds inside a presentation it still reports as seekable
    /// (AetherEngine#287).
    ///
    /// A VOD whose selected audio track outruns its video track (the reporter's dual-audio BDRip: video
    /// ends 1431.971 s, the selected English AAC 1484.935 s, container 1484.936 s) makes AVPlayer end the
    /// item the moment the video renderer runs dry, ~53 s short of the advertised duration. Reproduced
    /// on a synthesized 60 s-video / 113 s-audio MKV: the end fires at 60.03 s of a 113.02 s
    /// presentation whose final segment had already been fetched whole, and identically for a 2 s, an
    /// 8 s and a 53 s tail, so the trigger is the video exhaustion rather than the length of the tail.
    /// The playlist is not the culprit either: its EXTINF sum equals the container duration to the
    /// millisecond (measured 14 x 4.004 + 56.967 = 113.023).
    ///
    /// The engine cannot talk AVPlayer out of that call, but it must not forward it as an organic
    /// finish. `.ended` is terminal (#63/#164), so seek and play become no-ops and the tail is
    /// unreachable for the rest of the session; the host sees a hard stop tens of seconds early. Seeking
    /// back to the SAME position and resuming re-arms the renderers and plays the tail out to an organic
    /// end at the real duration with no audio dropped (measured; `play()` without the seek leaves the
    /// clock frozen at the boundary indefinitely).
    ///
    /// The witness is the SEEKABLE range, not the loaded one that carries #169. Measured at the instant
    /// the premature end fires: `loadedTimeRanges` has already been trimmed back to the exhaustion point
    /// ([22.34, 60.01] with the playhead at 60.03), so the loaded range agrees with AVPlayer's mistake
    /// and cannot refute it, while `seekableTimeRanges` still reports the whole presentation
    /// ([0, 113.02]). A live session fails this guard on its own, its seekable end being the live edge.
    ///
    /// A real serve failure does not reach here: a segment that never arrives fails the item with
    /// `failedToPlayToEndTime` / -12889, a different notification with its own recovery. And a recovery
    /// that cannot work costs one re-seek before the same end is accepted, so the worst case is today's
    /// behaviour one seek later.
    nonisolated static func prematureEndRecoveryQualifies(
        isLive: Bool,
        duration: Double,
        playhead: Double,
        seekableEnd: Double?,
        attemptsUsed: Int,
        lastAttemptPlayhead: Double?
    ) -> Bool {
        guard !isLive, duration > 0, playhead.isFinite else { return false }
        guard attemptsUsed < prematureEndRecoveryMaxAttempts else { return false }
        guard duration - playhead > prematureEndShortfallSeconds else { return false }
        guard let seekableEnd, seekableEnd.isFinite,
              seekableEnd - playhead >= prematureEndSeekableLeadSeconds else { return false }
        if let lastAttemptPlayhead,
           playhead - lastAttemptPlayhead < prematureEndRecoveryMinProgressSeconds { return false }
        return true
    }

    /// Complete a native VOD that parked a hair short of its advertised duration because the final
    /// segment's video is exhausted (AetherEngine#169): the final segment's EXTINF, derived from the
    /// container duration, overshoots the last real video sample, so AVPlayer sits in
    /// WaitingToMinimizeStalls a few frames from the end, never fires didPlayToEndTime, and after ~43 s
    /// dies with -12889. Fires organic end-of-media through the host's `didReachEnd` so the session
    /// finishes cleanly (`.ended` -> mark-watched / autoplay-next / dismiss) instead of hanging then
    /// erroring. The tail numbers are logged so a field trace confirms the mechanism (video ends short
    /// of the container duration the final EXTINF was built from). Driven from the 1 Hz native tick.
    @MainActor
    func synthesizeEndOfMediaFromTailPark(playhead: Double, loadedEnd: Double) {
        EngineLog.emit(
            "[AetherEngine] #169 tail park: playhead=\(String(format: "%.3f", playhead))s "
            + "duration=\(String(format: "%.3f", duration))s loadedEnd=\(String(format: "%.3f", loadedEnd))s; "
            + "final-segment video exhausted within \(String(format: "%.2f", Self.endOfMediaEpsilonSeconds))s "
            + "of duration, synthesizing end-of-media",
            category: .engine)
        nativeHost?.markEndOfMediaReached()
    }

    /// A VOD seek whose target lands at end-of-media parks at the final frame (AetherEngine#164): it is
    /// not playing, but it is NOT the terminal `.ended` state either. `.ended` (organic completion, #63)
    /// fires the host's end-of-playback handling (mark-watched / autoplay-next / dismiss) and is reserved
    /// for playback finishing on its own; forcing it on a manual scrub would misfire those side effects
    /// and, being terminal, would strand the playhead with no way to scrub back. Settle to `.paused`
    /// instead so the scrubber stays live and the park replays via `play()`. Returns nil to keep the
    /// normal seek-landing reconcile for a mid-stream target.
    nonisolated static func seekEndParkState(target: Double, duration: Double, isLive: Bool) -> PlaybackState? {
        isAtEndOfMedia(currentTime: target, duration: duration, isLive: isLive) ? .paused : nil
    }

    /// Whether `play()` / `togglePlayPause()` must rewind to the start before resuming (AetherEngine#164).
    /// A VOD parked at its final frame (scrubbed to the end, or paused there) cannot advance;
    /// `AVPlayer.play()` at end-of-media is a no-op, freezing the button. `.ended` is deliberately
    /// excluded: it is terminal (#63), the host revives it by reloading, and a play press racing the end
    /// card must not silently restart the finished session.
    nonisolated static func shouldRewindBeforePlay(
        state: PlaybackState, currentTime: Double, duration: Double, isLive: Bool
    ) -> Bool {
        guard state != .ended else { return false }
        return isAtEndOfMedia(currentTime: currentTime, duration: duration, isLive: isLive)
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
    /// #170: true while `reloadAtCurrentPosition` runs a session-preserving reload. Host
    /// `setNativeSubtitleRendering` calls landing in this window are latched into
    /// `pendingNativeRenderingRequest` (the mid-reload active track is transiently nil and would
    /// misread as deselect) and applied by `restoreSubtitleSelection`.
    var sessionPreservingReloadInFlight = false
    var pendingNativeRenderingRequest: Bool? = nil

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
    /// Pending off-main deactivation (#215). See `scheduleAudioSessionDeactivation()`.
    private var audioSessionDeactivationTask: Task<Void, Never>?
    #endif

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
        _ = DeinterlaceHardwareWarmup.shared

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
    enum HLSVODIngestReroute {
        /// No content evidence for unsupported carriage; the caller keeps its existing route.
        case notTaken
        /// The load was restarted on the ingest; the caller must return this result.
        case taken(SourceProbe?)
    }

    /// AE#268: content-gated reroute of a finite HLS VOD onto the seekable TS -> fMP4 ingest.
    ///
    /// AVFoundation builds no video track for HEVC in MPEG-TS (the HLS Authoring Spec sanctions HEVC
    /// only in fMP4), so the AE#154 bypass would hand this source to AVPlayer for an audio-only,
    /// black session. The #168 watchdog cannot catch it either: it is live-only and needs master
    /// variant evidence, which a direct media playlist has none of. The decision therefore comes from
    /// the playlist and the first segment's PMT, never from the `.m3u8` suffix or an AVPlayer error,
    /// and only positive evidence reroutes: unknown, fMP4, live, encrypted, demuxed-audio and
    /// H.264 shapes stay on the native path.
    private func rerouteOntoHEVCMPEGTSIngest(
        playlistURL: URL,
        options: LoadOptions,
        startPosition: Double?,
        audioSourceStreamIndex: Int32?,
        discTitleID: Int?,
        generation: UInt64,
        evidence: String
    ) async throws -> HLSVODIngestReroute {
        guard let reader = try await HLSVODIngestReader.makeIfHEVCMPEGTS(
            playlistURL: playlistURL,
            httpHeaders: options.httpHeaders
        ) else { return .notTaken }
        try checkLoadCurrent(generation)
        EngineLog.emit(
            "[AetherEngine] AE#268: \(evidence); routing through the seekable TS -> fMP4 ingest",
            category: .engine
        )
        var remuxOptions = options
        remuxOptions.nativeRemoteHLS = false
        return .taken(try await load(
            source: .custom(reader, formatHint: "mpegts"),
            startPosition: startPosition,
            options: remuxOptions,
            audioSourceStreamIndex: audioSourceStreamIndex,
            discTitleID: discTitleID
        ))
    }

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
        var source = source
        var options = options
        // #199: a live master whose #168 carriage verdict already fired routes straight onto the
        // live-ingest loopback. Remounting the native bypass would burn readyToPlay plus the watchdog
        // grace on a deterministic no-video-track outcome; after an ingest death that discovery tax
        // used to run once per host retune (the reporter's ~13s reroute cycle).
        if case .url(let candidate) = source,
           options.nativeRemoteHLS,
           RemoteHLSIngestFallback.shouldRouteDirectlyToIngest(
               isLive: options.isLive,
               fallbackEnabled: options.nativeRemoteHLSIngestFallback,
               verdictRemembered: rerouteVerdictMemory.remembers(candidate, now: Date())) {
            EngineLog.emit(
                "[AetherEngine] #199: master is a remembered no-video-track carriage case; "
                + "routing directly onto the live-ingest loopback path",
                category: .engine
            )
            options.nativeRemoteHLS = false
            source = .custom(
                HLSLiveIngestReader(playlistURL: candidate, httpHeaders: options.httpHeaders),
                formatHint: "mpegts"
            )
        }
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
        // The public #315 counterpart is un-latched by the stopInternal() above, which every load()
        // runs. The seams that reuse the running host call host.load() directly, reach neither, and
        // keep the latch through their few tens of ms without a picture.
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
        // #170: the carryover is consumed by THIS load only (registration site below, or never on
        // the branches that return before it); it must not persist into loadedOptions where a later
        // host-initiated reload would resurrect a stale session snapshot.
        loadedOptions.subtitleSessionCarryover = nil
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
        // #170: a stale latched rendering request from a superseded session-preserving reload
        // must not leak into this session; requests for the in-flight reload can only land at
        // suspension points after this prologue, so they survive.
        pendingNativeRenderingRequest = nil
        externalNativeStoreFillTask?.cancel()
        externalNativeStoreFillTask = nil
        resetSubtitleOCRState()   // Phase D: new session, new axis
        remoteHLSSubtitleDiscoveryTask?.cancel()
        remoteHLSSubtitleDiscoveryTask = nil
        remoteHLSSubtitleProxy?.tearDown()   // #316
        remoteHLSSubtitleProxy = nil
        injectedSubtitleRenditionNames = [:]
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
        mediaChapters = []
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
            // #316: this bypass returns before the probe path's registration, so a host that declared
            // sidecars at load time used to get nothing at all, silently. Seat them here instead.
            registerDeclaredExternalSubtitles(options)
            do {
                // AE#246: a VOD playlist honors the resume anchor here the same way the AE#154 reroute
                // does; without it a rerouted (or directly requested) VOD bypass always restarted at 0.
                // Live keeps the no-initial-seek contract every live caller relies on, so its anchor
                // stays nil even when the host passes one.
                try await loadRemoteHLS(url: url, options: options,
                                        startPosition: options.isLive ? nil : startPosition)
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
        if RemoteHLSMediaSelection.shouldReroute(failure: probeFailure, isCustomSource: isCustomSource),
           case .url(let hlsURL) = source {
            if case .taken(let probe) = try await rerouteOntoHEVCMPEGTSIngest(
                playlistURL: hlsURL,
                options: loadedOptions,
                startPosition: startPosition,
                audioSourceStreamIndex: audioSourceStreamIndex,
                discTitleID: discTitleID,
                generation: gen,
                evidence: "finite HEVC-in-MPEG-TS HLS"
            ) {
                return probe
            }
            EngineLog.emit("[AetherEngine] AE#154: HLS playlist on the VOD loopback path; rerouting to the native remote-HLS bypass", category: .engine)
            loadedOptions.nativeRemoteHLS = true
            // #316: the reroute returns before the registration below, same as the direct bypass.
            registerDeclaredExternalSubtitles(loadedOptions)
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
        applyConfirmedAtmos()
        subtitleTracks = probedSubtitleTracks
        // #88: load-declared external tracks join the list now, BEFORE preferred-language selection
        // and the native rendition table are built from it.
        // #170: a session-preserving reload seeds the previous session's registry verbatim
        // instead: mid-session adds survive with their ids (and, registered pre-table, become
        // rendition-eligible on the reloaded item); mid-session removals stay removed; the host's
        // subtitle authority carries over so the load-end auto-selection cannot override it.
        registerDeclaredExternalSubtitles(options)
        metadata = probeOpened ? probe.mediaMetadata() : nil
        fontAttachments = probeOpened ? probe.fontAttachmentInfos() : []
        // Disc titles/chapters off the probe demuxer (post-detach, on MainActor) so the host can populate
        // a title picker. selectedDiscTitleID reflects what DiscReader.wrap actually selected (discTitleID
        // clamped to an in-range id); non-disc sources report empty/nil (#67).
        discTitles = probeOpened ? probe.discTitleInfos() : []
        discChapters = probeOpened ? probe.discChapterInfos() : []
        mediaChapters = (probeOpened && discTitles.isEmpty) ? probe.mediaChapterInfos() : []
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
            startAtmosConfirmation()
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
        // #232: a declared interlaced field order is not evidence that any frame IS interlaced.
        // European 25 fps Blu-ray masters ship as 1080i25 (there is no 1080p25): interlaced carriage,
        // progressive pictures, and FFmpeg's parser reports TT for them off SEI pic_struct alone while
        // its decoder leaves AV_FRAME_FLAG_INTERLACED clear on the very same picture. Those streams took
        // the software detour and then never deinterlaced, because SoftwareVideoDecoder engages the
        // filter on that flag and on nothing else. So decode a sample and ask the runtime's own
        // question: would the deinterlacer ever engage. Only a clean answer overrules the declaration;
        // inconclusive keeps today's routing. VOD + seekable only: the sample moves the read position of
        // the demuxer the session reuses, and live 1080i broadcast (the case the rule exists for) is
        // neither seekable nor mis-declared.
        if useSoftwarePath, probeOpened, !options.isLive, probe.isSourceSeekable,
           probe.videoStreamIndex >= 0,
           VideoRoutingPolicy.routesSoftwareForDeclaredInterlace(
               codecID: detectedCodecID,
               fieldOrder: detectedFieldOrder,
               spsIndicatesInterlaced: spsIndicatesInterlaced) {
            let videoIdx = probe.videoStreamIndex
            let verdict = await Task.detached(priority: .userInitiated) { [probe] in
                let verdict = InterlaceProbe.run(demuxer: probe, streamIndex: videoIdx)
                probe.seek(to: 0)  // sample consumed packets; the session reuses this demuxer
                return verdict
            }.value
            if loadGeneration != gen {
                probe.markClosed()
                Task.detached { [probe] in probe.close() }
                try checkLoadCurrent(gen)
            }
            if InterlaceProbe.refutesDeclaredInterlace(verdict) {
                useSoftwarePath = false
                EngineLog.emit(
                    "[AetherEngine] declared interlaced (fieldOrder=\(detectedFieldOrder.rawValue)) but "
                    + "\(verdict); the deinterlacer would never engage, routing native for HW decode (#232)",
                    category: .engine
                )
            } else {
                EngineLog.emit(
                    "[AetherEngine] declared interlaced and the frame sample agrees (\(verdict)); "
                    + "keeping the software deinterlace path (#232)",
                    category: .engine
                )
            }
        }
        // #2: an H.264 / HEVC format AVPlayer accepts at the HLS CODECS level but VideoToolbox can't
        // hardware-decode (H.264 High 4:2:2/4:4:4/High-10, HEVC Rext on Intel Macs / older Apple TV) reaches
        // readyToPlay then renders nothing on the native path. QuickTime plays it via its own software decoder;
        // there is no analogous fallback on the native route, so route it to the SoftwarePlaybackHost
        // (libavcodec), which decodes these profiles. VOD only: forced-native live keeps its verified path, and
        // broadcast H.264 / HEVC is HW-decodable. Apple Silicon HW-decodes these, so the probe keeps them native.
        // #176: DV Profile 5 is exempt inside the policy; the raw-hvcC probe misjudges the dvh1 route and the
        // software path decodes IPT-PQ-c2 with a green/purple cast, so P5 must stay native unconditionally.
        if !useSoftwarePath, !options.isLive, probeOpened,
           let vStream = probe.stream(at: probe.videoStreamIndex),
           let codecpar = vStream.pointee.codecpar {
            let dvProfile = Self.dvProfile(stream: vStream)
            if VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
                   codecID: detectedCodecID,
                   dvProfile: dvProfile,
                   canHardwareDecode: { VTCapabilityProbe.canHardwareDecode(codecpar: codecpar) }) {
                useSoftwarePath = true
                EngineLog.emit(
                    "[AetherEngine] codec=\(detectedCodecID.rawValue) not hardware-decodable by "
                    + "VideoToolbox; routing to the software path so it plays instead of a black screen (#2)",
                    category: .engine
                )
            } else if detectedCodecID == AV_CODEC_ID_HEVC, dvProfile == 5 {
                EngineLog.emit(
                    "[AetherEngine] DV Profile 5: VT probe skipped, native dvh1 path is the only "
                    + "correct decode (#176)",
                    category: .engine
                )
            }
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

        // #176 follow-up: IPT-only DV (HEVC P5, AV1 P10.0) must never start on the software path; the
        // decoded IPT-PQ-c2 signal renders as YCbCr (green/purple cast). AV1 P10.0 without HW AV1 decode
        // has no native fallback (AVPlayer HLS requires HW AV1), and HEVC P5 reaches here only off
        // forward-only sources the native path cannot serve. Fail fast instead of playing wrong color.
        if useSoftwarePath, probeOpened,
           let vStream = probe.stream(at: probe.videoStreamIndex),
           let dvConfig = Self.dvConfig(stream: vStream),
           VideoRoutingPolicy.softwarePathCannotRepresent(
               codecID: detectedCodecID,
               dvProfile: dvConfig.profile,
               dvBlCompatID: dvConfig.blCompatID) {
            probe.markClosed()
            Task.detached { [probe] in probe.close() }
            let profileLabel = detectedCodecID == AV_CODEC_ID_AV1 ? "10.0" : "5"
            EngineLog.emit(
                "[AetherEngine] DV Profile \(profileLabel) routed to the software path; IPT-PQ-c2 has "
                + "no compatible base layer and would render green/purple, failing fast (#176)",
                category: .engine
            )
            state = .error("Dolby Vision Profile \(profileLabel) requires a hardware playback path on this device")
            throw AetherEngineError.dolbyVisionUnplayableOnSoftwarePath(profile: profileLabel)
        }

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
                armDisplayModeDiagnostic(gen: gen, backend: "software",
                                         contentRate: detectedRate, requestedRate: snappedRate)
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
                // #274: the 1000ms Stage 1 budget is the DV-cold-start bet on a sole-writer host's inbound
                // write. Sessions no dynamic-range switch can reach (engine-writer, or SDR content) take the
                // 200ms budget instead of paying it on every load.
                await displayCriteria.waitForSwitch(startGrace: Self.playGateGrace(
                    criteriaUnchanged: criteriaUnchanged,
                    engineIsCriteriaWriter: !options.suppressDisplayCriteria,
                    formatKnown: probeOpened,
                    effectiveFormat: effectiveFormat
                ))
                try checkLoadCurrent(gen)
                // automaticallyWaitsToMinimizeStalling=true (default) handles play-before-ready.
                // #35: on a real SDR->HDR switch while serving a VOD master, drive the bounded
                // cold-start readiness gate (play -> poll -> reload master -> media fallback) instead
                // of an unconditional play(); the gate calls play() itself. Warm/live/media paths keep
                // the immediate play().
                // #124: a paused mount skips the terminal play() AND the cold-start readiness gate
                // (an autostart-path recovery: it plays to poll readiness). loadNative wired
                // host.$isReady, which settles .loading -> .paused; the host resumes later with play().
                // #227 follow-up: a master handed to a wireless AirPlay receiver arms the same gate. The
                // receiver's HDR mode is unreadable from the sender, so an offered HDR/DV master can be
                // rejected or park silently, and the escalation (reload master -> reduced HDR master ->
                // media, all on the LAN IP) is exactly the recovery that hop needs.
                if Self.loadPerformsAutostart(options) {
                    if didSwitchPanel || airPlayServedMasterToReceiver, let session = nativeVideoSession,
                       session.servingMasterPlaylist, !options.isLive {
                        try await runStartupReadinessGate(
                            session: session, position: startPosition ?? 0, gen: gen)
                    } else {
                        nativeHost?.play()
                    }
                    state = .playing
                    // #227: a receiver that refuses the playlist it was handed neither fails the item nor
                    // reports a rejection, so the gate above cannot see it. Watch the clock instead.
                    armAirPlayProgressWatchdog(gen: gen, position: startPosition ?? 0)
                }
                startMemoryProbe()
                startLiveTelemetrySampler()
                armDisplayModeDiagnostic(gen: gen, backend: "native",
                                         contentRate: detectedRate, requestedRate: snappedRate)
            }
        } catch is CancellationError {
            // Superseded.
            throw CancellationError()
        } catch {
            // AE#246: the load-time probe failed for a reason that was not the HLS classification, so the
            // AE#154 check above saw an inconclusive failure and this load fell through to the loopback
            // path with no preopened demuxer. The session's own open is then the first one to read the
            // body, and it has now classified the source as remote HLS after all. Take the same reroute
            // rather than surfacing a terminal failure for a source AVPlayer can play. A full load()
            // restart (the #168 reroute's shape) is what clears the half-built loopback session; the
            // bypass runs no probe, so this cannot bounce back here a second time.
            if RemoteHLSMediaSelection.shouldReroute(failure: error, isCustomSource: isCustomSource),
               case .url(let hlsURL) = source,
               loadGeneration == gen {
                if case .taken(let probe) = try await rerouteOntoHEVCMPEGTSIngest(
                    playlistURL: hlsURL,
                    options: loadedOptions,
                    startPosition: startPosition,
                    audioSourceStreamIndex: audioSourceStreamIndex,
                    discTitleID: discTitleID,
                    generation: gen,
                    evidence: "second open confirmed finite HEVC-in-MPEG-TS HLS"
                ) {
                    return probe
                }
                EngineLog.emit(
                    "[AetherEngine] AE#246: the loopback session's own open classified the source as HLS; "
                    + "taking the AE#154 reroute onto the native remote-HLS bypass",
                    category: .engine
                )
                var rerouted = loadedOptions
                rerouted.nativeRemoteHLS = true
                _ = try await load(source: .url(hlsURL), startPosition: startPosition, options: rerouted)
                return nil
            }
            state = .error("Failed to load: \(error.localizedDescription)")
            throw error
        }
        // Honor a saved subtitle-language preference on the first frame (#73). Runs only on the successful
        // video path (the audio-only branch returns earlier and renders no subtitles); a no-op when the
        // preference list is empty, no track matches, or the host already activated one.
        applyPreferredSubtitleSelection(startAnchor: startPosition, sourceDuration: sourceProbe?.durationSeconds)
        // #214 follow-up: opt-in JOC confirmation runs behind the session, never in front of the first frame.
        startAtmosConfirmation()
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
        // AetherEngine#164: a VOD parked at its final frame (scrubbed to the end, or paused there)
        // cannot advance; AVPlayer.play() would no-op and leave the button frozen. Rewind to the start
        // first, then resume. `.ended` is excluded (see shouldRewindBeforePlay): it stays terminal so a
        // play press racing the host end card does not silently revive a finished session (#63).
        if Self.shouldRewindBeforePlay(
            state: state, currentTime: currentTime, duration: duration, isLive: isLive
        ) {
            Task { @MainActor in
                await self.seek(to: 0)
                self.play()
            }
            return
        }
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
        // #170: session state the from-scratch load() would wipe and re-derive by auto-selection
        // (AirPlay LAN-swap reload, background-return reopen). The explicit audio pick rides the
        // load's own override contract (matching the custom-source branch above); the subtitle
        // session state is seeded into the load and the selection restored after it.
        let audioToRestore = activeAudioTrackIndex
        let carryover = captureSubtitleSessionCarryover()
        sessionPreservingReloadInFlight = true
        // #227: the reconcile has to run on every exit, including a thrown/superseded load, or an edge held
        // during the reload is lost and the session stays on the wrong URL for the current route.
        defer {
            sessionPreservingReloadInFlight = false
            reconcileExternalPlaybackAfterReload()
        }
        // Live: rejoin at the live edge; pre-suspend playhead is stale and may have slid out of the window.
        let resume: Double? = LiveReloadPolicy.resumePosition(
            isLive: loadedOptions.isLive, currentTime: pos)
        // isLiveRejoin tells loadNative to skip the initial seek: the rebuilt playlist can have a multi-segment
        // backlog where the fresh-join contract (seg0 == live edge) no longer holds.
        var options = loadedOptions
        options.isLiveRejoin = options.isLive
        options.subtitleSessionCarryover = carryover
        try await load(url: url, startPosition: resume, options: options,
                       audioSourceStreamIndex: audioToRestore.map { Int32($0) }, discTitleID: titleID)
        restoreSubtitleSelection(from: carryover, resumeAnchor: resume)
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
            emitSeekRejected(.noActiveSession, target: seconds)
            return
        case .loading:
            // #178: don't drop a seek raced against load(). No hosts exist yet (forwarding would
            // no-op and flip state early, dropping the host's spinner), so stash the latest target
            // in the #127 slot and resolve it on the transition out of .loading (state didSet):
            // replay into a playable state, discard into a terminal one. Clamp/live guards re-run
            // at replay when the session is actually known; duration may still be unprobed here.
            pendingPreReadySeekSeconds = seconds
            clock.currentTime = duration > 0 ? max(0, min(seconds, duration)) : max(0, seconds)
            EngineLog.emit("[AetherEngine] seek(to:\(String(format: "%.2f", seconds))) stashed during load; will replay when the session settles (#178)", category: .engine)
            beginDeferredSeek(target: clock.currentTime)
            return
        default:
            break
        }
        // Live-only (no DVR): no rewind range; AVPlayer would stall or land on an unmaterialised segment.
        // Hosts should hide the scrubber when seekableLiveRange == nil; this guard is defence-in-depth.
        if isLive {
            guard let w = liveWindow, w.windowSeconds != nil else {
                EngineLog.emit("[AetherEngine] seek(to:\(seconds)) ignored: live, DVR disabled", category: .engine)
                emitSeekRejected(.liveWithoutDVR, target: seconds)
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
            beginDeferredSeek(target: clock.currentTime)
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
        // A stash resolving into this seek hands its window over without a gap in `isSeeking`: the
        // deferred flag clears in the same recompute that sets the programmatic one.
        closeSeekTicket(&deferredSeekTicket, with: .superseded)
        deferredSeekInFlight = false
        deferredSeekTarget = nil
        // Whatever was in flight lost; its ticket closes here rather than at the generation guards, which
        // are spread over every exit of the deadline loop.
        closeSeekTicket(&programmaticSeekTicket, with: .superseded)
        programmaticSeekTicket = beginSeekTicket(origin: .programmatic, target: target)
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
                closeSeekTicket(&programmaticSeekTicket, with: .landed(renderedTime: target))
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
            closeSeekTicket(&programmaticSeekTicket, with: .landed(renderedTime: target))
            return
        }
        // #178: this seek supersedes any recovery re-anchor still holding the restart coalescer's
        // authoritative slot (it was computed for the seek being superseded). Released before the
        // host seek below so the new target's segment-driven restart cannot be dropped against a
        // locked slot. Live never reaches here (returned above); LiveReopen's anchors are safe.
        nativeVideoSession?.releaseSupersededAuthoritativeRestart()
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
        // #254: the SW/audio hosts reposition their demuxer under a read deadline, off the main actor.
        // A reposition that spends its budget leaves the read position undefined and nothing re-issues
        // it, unlike the native recovery path whose ticket stays open for a late landing, so that case
        // closes this ticket terminally as `.stalled` instead of claiming a landing it cannot back up.
        var hostReposition: Demuxer.RepositionOutcome = .landed
        if audioAVPlayerActive, let host = audioAVPlayerHost {
            await host.seek(to: clockTarget)
        } else if let host = audioHost {
            hostReposition = await host.seek(to: clockTarget)
        } else if let host = softwareHost {
            hostReposition = await host.seek(to: clockTarget)
        } else {
            // #93 retest: remember the target as recovery intent BEFORE awaiting; a wedged seek
            // never lands and the recovery chain must aim here, not at the frozen clock.
            setPendingRecoverySeekTarget(clockTarget)
            pendingSeekProgressAccum = 0
            let renderedAtSeekStart = nativeHost?.renderedTime ?? 0
            pendingSeekInitialRenderedPosition = renderedAtSeekStart
            lastRenderedForPendingSeek = renderedAtSeekStart
            // Direction of travel for landing detection: a forward seek's playhead climbs from the old
            // position toward (and, once playing, PAST) the target; a backward seek's descends to it.
            let seekIsForward = clockTarget >= renderedAtSeekStart
            // Await real AVPlayer landing so isSeeking spans it (#37/#38), but bound the wait (#65): a seek
            // AVPlayer can never land (producer-wedge starvation) must not leave the optimistic clock latched
            // forever. A normal/slow-but-buffering seek lands or keeps buffering well within the budget.
            var deadlineExtensionsUsed = 0
            // Last observed buffer AT the target, so an extension can require the island to be GROWING
            // rather than merely present: a producer that served 4 s and then died reads identically to
            // one still filling, and presence alone would buy it the whole extension budget.
            var lastTargetIslandSeconds: Double?
            // Recovery fallthrough state (backward-into-unbuffered / true wedge / budget exhausted):
            // once the producer is re-anchored at the target we hold the clock there and wait on the
            // re-issued seek for a bounded number of windows rather than reverting to the old position.
            var reanchored = false
            var postReanchorWaits = 0
            var landed = await nativeHost?.seek(to: clockTarget,
                                                deadlineSeconds: Self.nativeSeekReconcileBudgetSeconds) ?? true
            deadlineLoop: while !landed {
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
                // The `$renderedTime` sink can finalize this very seek underneath the loop, and its
                // landing predicate is deliberately looser than the loop's: `pendingSeekLanded` accepts
                // any rendered position within ±5 s of the target (symmetric), while `seekLandedAtTarget`
                // wants ±0.75 s on the near side. A landing 3 s short of the target therefore settles the
                // clock and runs `finalizeLateRecoverySeekLanding` (clearing the seek gate, reconciling the
                // transport) while this loop still reads "not landed" and would go on to re-anchor the
                // producer and re-issue a backward seek on an item that is already playing, the exact
                // yank the overshoot rule above exists to prevent. `programmaticSeekInFlight` is the
                // authoritative "this seek is still ours" latch: it is set before the first host seek and
                // cleared only by a finalize (here, in the sink, or at the give-up) or `stopInternal`.
                guard programmaticSeekInFlight else {
                    EngineLog.emit(
                        "[AetherEngine] seek finalized elsewhere while the deadline loop waited "
                        + "(late landing settled through the rendered-time sink); leaving recovery to it",
                        category: .engine
                    )
                    return
                }
                // Cancellation of the calling task must not be spent running the recovery at full speed.
                // `awaitPendingSeekLanding` sleeps on the caller's task, so a cancelled `Task.sleep` throws
                // instantly and every remaining window returns `false` in microseconds: the loop would burn
                // its whole budget in one runloop turn and still restart the producer on the way through.
                // (`host.seek(to:deadlineSeconds:)` runs its deadline on a detached task and is unaffected,
                // which is why this could not happen before the wait windows existed.) Terminate on the
                // give-up contract instead: clock held at the target, gate cleared, honest phase reported.
                guard !Task.isCancelled else {
                    setProgrammaticSeek(inFlight: false, target: nil)
                    reportSeekStalled()
                    reconcileNativeSeekTransport(host: host, isStarved: true)
                    EngineLog.emit(
                        "[AetherEngine] seek deadline recovery cancelled; holding clock at target "
                        + "\(String(format: "%.2f", target))s without re-anchoring",
                        category: .engine
                    )
                    return
                }
                pendingRecoverySeekDeadlineExpired = true
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
                    closeSeekTicket(&programmaticSeekTicket,
                                    with: .landed(renderedTime: PresentationAxis.display(
                                        sourcePTS: avpReal + playlistShiftSeconds,
                                        origin: sourcePresentationOrigin)))
                    reconcileNativeSeekTransport(host: host, isStarved: false)
                    EngineLog.emit(
                        "[AetherEngine] seek landed while deadline ownership transferred; "
                        + "reconciled from rendered \(String(format: "%.2f", avpReal))s",
                        category: .engine
                    )
                    return
                }
                // Overshoot landing: a zero-tolerance seek lands AT the target, then a *playing* item keeps
                // moving in the seek direction while the deadline continuation settles, so a forward seek can
                // render a GOP PAST the target (device: rendered=1289.70 vs target=1288.14, contiguous buffer,
                // timeControlStatus=playing). The old tolerance treated that overshoot as "not landed" and the
                // fallthrough re-seeked backward to the exact target, dragging a playing playhead back ~1.5s and
                // re-stalling it (Brandon: "loading even though it had already started playing, then reverted
                // back a second or 2"). Accept a landing at/past the target in the seek direction and finalize;
                // NEVER issue a backward correction for a forward overshoot (overshoot is strictly better for
                // the user than a re-stall + yank). The opposite bound stays tight so the pinned pre-seek
                // playhead (forward: far below target; backward: far above) is never mistaken for a landing.
                if Self.seekLandedAtTarget(
                    rendered: avpReal, target: clockTarget, forward: seekIsForward) {
                    EngineLog.emit(
                        "[AetherEngine] seek landed at deadline "
                        + "(rendered=\(String(format: "%.2f", avpReal))s "
                        + "target=\(String(format: "%.2f", clockTarget))s "
                        + "\(seekIsForward ? "fwd" : "back")); finalizing without re-seek",
                        category: .engine
                    )
                    landed = true
                    break deadlineLoop
                }
                // AE#141: a progressing producer is only worth preserving when its march can actually
                // deliver the pending target. A far-forward target beyond coverage (640 s target, march at
                // ~316 s) rides 3x30 s serve timeouts into item death if left to "land late", and the
                // old-position buffer health cannot see that. Computed BEFORE the extend branch so it can
                // veto an extension too -- granting 16 s of "land late" to an unreachable target is exactly
                // what AE#141 forbids.
                //
                // Uses the immutable local `clockTarget`, not the published `pendingRecoverySeekClockTarget`:
                // the $renderedTime sink can retire that field mid-flight (organic progress far from the
                // target reads as "seek abandoned"), and a nil there would both weaken this gate and make
                // `recoveryAnchorPosition` fall back to the frozen OLD position -- re-anchoring the producer
                // at the very spot the user is leaving while the clock is held at, and the seek re-issued
                // to, the target.
                let targetBeyondCoverage: Bool = {
                    guard let session = nativeVideoSession else { return false }
                    return !session.producerCoversPlaylistTime(clockTarget)
                }()
                // DV/SMB forward-seek revert fix: `seekIsWedged`/`bufferedEnd` only measure the buffer
                // contiguous with AVPlayer's pre-seek playhead, which stays pinned during a pending
                // zero-tolerance forward seek, so a slow-but-working forward seek (the producer IS
                // serving the target) reads identically to a true wedge. Reconciling here (clock revert +
                // producer re-anchor) would discard the in-flight download and park the session flapping on
                // a slow SMB source. Measure what the producer has actually served AT the target instead,
                // and extend only while that is above the floor AND still growing.
                // A backward seek excludes the abandoned playhead's own buffer explicitly: the measurement
                // window is only wide enough to keep a FAR backward target clear of it, and a near one
                // (less than the window back) would otherwise read the old, full buffer as progress at the
                // target and earn an extension the producer never served.
                let targetIsland = host.bufferedSecondsAtTarget(
                    clockTarget, excludeAtOrAbove: seekIsForward ? nil : avpReal)
                if Self.shouldExtendSeekDeadlineForProgress(
                    targetIslandSeconds: targetIsland,
                    previousIslandSeconds: lastTargetIslandSeconds,
                    extensionsUsed: deadlineExtensionsUsed,
                    maxExtensions: Self.nativeSeekMaxDeadlineExtensions,
                    islandFloor: Self.nativeSeekProgressIslandFloorSeconds,
                    targetBeyondProducerCoverage: targetBeyondCoverage
                ) {
                    deadlineExtensionsUsed += 1
                    lastTargetIslandSeconds = targetIsland
                    // Re-assert the optimistic scrub clock at the target: the host cleared seekInFlight at
                    // the deadline, un-gating the periodic observer, which could otherwise stick the clock
                    // at the old playhead while the island fills. `awaitPendingSeekLanding` re-gates it and
                    // waits on the SAME in-flight seek (no new avPlayer.seek, so the loaded target island is
                    // not flushed); the producer is deliberately NOT restarted, and together that preserves the
                    // in-flight target download that the old re-anchor discarded (the ~40s device stall).
                    nativeClockSeconds = clockTarget
                    clock.currentTime = target
                    EngineLog.emit(
                        "[AetherEngine] seek slow but producer serving target "
                        + "(island=\(String(format: "%.2f", targetIsland))s at target, "
                        + "rendered=\(String(format: "%.2f", avpReal))s "
                        + "buffered=\(String(format: "%.2f", host.bufferedEnd))s); extending budget "
                        + "\(deadlineExtensionsUsed)/\(Self.nativeSeekMaxDeadlineExtensions)",
                        category: .engine
                    )
                    landed = await host.awaitPendingSeekLanding(
                        target: clockTarget,
                        deadlineSeconds: Self.nativeSeekExtensionBudgetSeconds,
                        forward: seekIsForward)
                    continue deadlineLoop
                }
                lastTargetIslandSeconds = targetIsland
                // No forward island (or extend budget exhausted). This is a true wedge, a
                // backward-into-unbuffered seek (the target sits BEHIND the frozen playhead, so
                // `avPlayerBufferAheadSeconds` never counts it -> island is structurally 0), or a
                // forward seek that spent its whole extension budget. The old recovery reverted the
                // clock to the frozen rendered position and reconciled the transport, which on a slow
                // DV/SMB source is exactly the device-reported failure: the scrubber visibly jumps back
                // to the pre-seek spot and the session flaps paused<->playing for ~40s while the old
                // segment drains. Instead HOLD the clock at the target (same UX contract as the extend
                // branch: scrubber parked at target + buffering spinner), re-anchor the producer to the
                // target once, re-issue the seek so AVPlayer abandons the old-position buffer and targets
                // the re-anchored region, and wait for it to land -- reconciling FORWARD to the target,
                // never back to the rendered position.
                let wasStarved = seekIsWedged(
                    renderedTime: avpReal, bufferedEnd: host.bufferedEnd)
                // `targetBeyondCoverage` (AE#141) was computed above, before the extend branch, so it
                // gates both the extension and this re-anchor decision.
                let reason = wasStarved
                    ? "starved"
                    : (targetBeyondCoverage
                        ? "old position still buffered, target beyond producer coverage"
                        : "old position still buffered")
                // Hold the optimistic clock at the target; pendingRecoverySeekClockTarget stays set so
                // applyNativeHostClockTick keeps it there between ticks (no revert to the old playhead).
                nativeClockSeconds = clockTarget
                clock.currentTime = target
                if !reanchored {
                    reanchored = true
                    postReanchorWaits = 0
                    let recoveryAnchor = Self.recoveryAnchorPosition(
                        frozenPosition: avpReal, pendingSeekTarget: clockTarget,
                        currentRendered: avpReal)
                    let didReanchor = Self.shouldReanchorProducerAfterSeekDeadline(
                        isStarved: wasStarved, targetBeyondProducerCoverage: targetBeyondCoverage)
                    if didReanchor {
                        reanchorProducerToPlaylistTime(recoveryAnchor)
                        // The playhead will jump when the restarted producer lets the pending seek land.
                        reanchorSubtitleOverlays()
                        pendingRecoverySeekSubtitlesReanchored = true
                    }
                    EngineLog.emit(
                        "[AetherEngine] seek did not land within budget "
                        + "(\(deadlineExtensionsUsed) extension\(deadlineExtensionsUsed == 1 ? "" : "s"); "
                        + "\(reason), "
                        + "island=\(String(format: "%.2f", targetIsland))s at target, "
                        + "rendered=\(String(format: "%.2f", avpReal))s "
                        + "buffered=\(String(format: "%.2f", host.bufferedEnd))s); holding clock at target "
                        + "\(String(format: "%.2f", target))s"
                        + (didReanchor
                            ? " and re-anchored producer at \(String(format: "%.2f", recoveryAnchor))s, re-seeking"
                            : ", re-seeking without restarting the progressing producer"),
                        category: .engine
                    )
                    // Re-issue the seek toward the (re-anchored) target. A deadline does not cancel the
                    // prior seek, but this fresh zero-tolerance seek supersedes it and points AVPlayer at
                    // the re-anchored region so it stops waiting on the abandoned old-position segments.
                    landed = await host.seek(to: clockTarget,
                                             deadlineSeconds: Self.nativeSeekExtensionBudgetSeconds)
                    continue deadlineLoop
                }
                // Already re-anchored + re-seeked. Keep holding the clock at the target and wait on the
                // re-issued seek for a bounded number of windows; the re-anchored producer is serving the
                // target so it should land within a couple of GOP fetches on any workable source.
                if postReanchorWaits < Self.nativeSeekMaxDeadlineExtensions {
                    postReanchorWaits += 1
                    EngineLog.emit(
                        "[AetherEngine] holding clock at target \(String(format: "%.2f", target))s while "
                        + "re-anchored producer serves it (wait \(postReanchorWaits)/"
                        + "\(Self.nativeSeekMaxDeadlineExtensions))",
                        category: .engine
                    )
                    landed = await host.awaitPendingSeekLanding(
                        target: clockTarget,
                        deadlineSeconds: Self.nativeSeekExtensionBudgetSeconds,
                        forward: seekIsForward)
                    continue deadlineLoop
                }
                // Budget fully spent and still buffering after the re-anchor. Keep the clock held at the
                // target (no revert, no scrubber jump-back -- the whole point of this path), but do NOT
                // stay `.seeking`: `programmaticSeekInFlight`/`isSeeking` are cleared only by
                // setProgrammaticSeek, finalizeLateRecoverySeekLanding, or stopInternal, and none of those
                // is on a timer. Both $renderedTime exits require host.renderedTime to be PUBLISHED again,
                // which the periodic observer does not do while waitingToPlayAtSpecifiedRate and the seek
                // completion withholds while buffering (#123). On a source that never serves the target --
                // an SMB share dropped mid-seek, a dead producer, the #65 wedge signature of "stall with no
                // surfaced failure" -- nothing would ever fire and the engine would park in `.seeking`
                // forever. That is the permanent-spinner class this whole change exists to remove, so
                // relocating it to the give-up is not acceptable.
                //
                // Report the honest phase instead: clear the programmatic-seek gate and reconcile the
                // transport as starved, which surfaces `.rebuffering`/`.stalled` rather than an
                // indistinguishable infinite spinner. `pendingRecoverySeekClockTarget` deliberately stays
                // set so the clock keeps holding at the target and the producer keeps aiming there; a late
                // landing still settles through the sink, where finalizeLateRecoverySeekLanding is then a
                // harmless no-op.
                setProgrammaticSeek(inFlight: false, target: nil)
                reportSeekStalled()
                reconcileNativeSeekTransport(host: host, isStarved: true)
                EngineLog.emit(
                    "[AetherEngine] seek still buffering after re-anchor + full budget "
                    + "(\(Self.nativeSeekMaxDeadlineExtensions) waits); holding clock at target "
                    + "\(String(format: "%.2f", target))s (no revert), reported as stalled",
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
        // spurious pause and call host.play().
        // #292: the SW/audio hosts carry that intent through their seek window now, so read it off
        // them instead of defaulting to `.playing`. Reporting playing over a host that landed paused
        // is half of what the #292 report describes. AVPlayer-backed audio keeps the default.
        if let nativeHost {
            reconcileNativeSeekTransport(host: nativeHost, isStarved: false)
        } else if !audioAVPlayerActive, let hostIsPlaying = softwareHost?.isPlaying ?? audioHost?.isPlaying {
            state = hostIsPlaying ? .playing : .paused
        } else {
            state = .playing
        }
        // AetherEngine#164: a VOD scrubbed to its final frame is parked, not playing. Override the
        // reconcile's `.playing` with an honest `.paused` (non-terminal, so the scrubber stays live and
        // `play()` can rewind + replay). `.ended` stays reserved for organic completion (#63).
        if let parked = Self.seekEndParkState(target: target, duration: duration, isLive: isLive) {
            state = parked
        }
        setProgrammaticSeek(inFlight: false, target: nil)
        // `sourceTime` is the on-screen frame (#49/#123): the honest landing position, which keyframe
        // granularity or a still-draining chase can put a little off the target. Folded onto the display
        // axis because that is the axis the ticket's `target` is on (AE#270; identity off disc and off a
        // PTS-origin source).
        closeSeekTicket(&programmaticSeekTicket,
                        with: Self.seekTicketOutcome(
                            hostReposition: hostReposition,
                            renderedTime: PresentationAxis.display(sourcePTS: clock.sourceTime,
                                                                   origin: sourcePresentationOrigin)))
    }

    /// #254: how a SW/audio-host reposition maps onto this seek's ticket. A reposition that spent its
    /// read-deadline budget left the read position undefined, and nothing on that path re-issues it:
    /// the native recovery loop can leave its ticket open because AVPlayer keeps aiming at the target
    /// and a late `.landed` still arrives, while here no one does. So it closes terminally as
    /// `.stalled` rather than claiming a landing it cannot back up.
    nonisolated static func seekTicketOutcome(
        hostReposition: Demuxer.RepositionOutcome, renderedTime: Double
    ) -> SeekEvent.Outcome {
        hostReposition == .stalled ? .stalled : .landed(renderedTime: renderedTime)
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

    /// Pure decision: on a seek-deadline expiry, should the engine grant another (shorter) extension
    /// window instead of reverting the clock + re-anchoring the producer?
    ///
    /// Yes only while the producer is *demonstrably* serving the target. Three conditions:
    ///
    /// - `targetIslandSeconds >= islandFloor`: enough media is buffered AT the target to call it served.
    /// - The island is still **growing** (`targetIslandSeconds > previousIslandSeconds + growthEpsilon`),
    ///   except for the first extension, which has no earlier sample to compare against. Presence alone is
    ///   a single observation and cannot distinguish a producer that is still filling from one that
    ///   buffered a few seconds and then died, and the latter would otherwise buy the full 16 s of extensions
    ///   while nothing happens.
    /// - `targetBeyondProducerCoverage == false`: AE#141: a target the producer's march cannot reach
    ///   rides serve timeouts into item death if left to "land late", so it must never be granted an
    ///   extension no matter how healthy the buffer looks.
    ///
    /// Plus the budget check. This keeps a slow-but-working forward seek (DV/SMB) from being converted
    /// into a permanent wedge by a recovery that would discard the in-flight download, without letting a
    /// dead or unreachable one sit for the whole budget.
    nonisolated static func shouldExtendSeekDeadlineForProgress(
        targetIslandSeconds: Double,
        previousIslandSeconds: Double?,
        extensionsUsed: Int,
        maxExtensions: Int,
        islandFloor: Double,
        targetBeyondProducerCoverage: Bool,
        growthEpsilon: Double = 0.25
    ) -> Bool {
        guard extensionsUsed < maxExtensions else { return false }
        guard !targetBeyondProducerCoverage else { return false }
        guard targetIslandSeconds >= islandFloor else { return false }
        guard let previous = previousIslandSeconds else { return true }
        return targetIslandSeconds > previous + growthEpsilon
    }

    nonisolated static func shouldCatchUpDeadlineLanding(
        renderedTimePublished: Bool
    ) -> Bool {
        renderedTimePublished
    }

    /// Pure decision: has a zero-tolerance seek physically landed at the target by the deadline, allowing
    /// for a directional overshoot? A zero-tolerance `avPlayer.seek` lands AT the target, but a *playing*
    /// item keeps advancing in the seek direction while the deadline continuation settles, so by the time
    /// the engine samples `rendered` a forward seek can sit a GOP PAST the target and a backward seek a
    /// hair past it (downward). Accept a landing at/past the target in the seek direction; keep the
    /// opposite bound tight (`tolerance`) so the pinned pre-seek playhead (which sits far BELOW the target
    /// for a forward seek and far ABOVE it for a backward seek until the seek completes) is never mistaken
    /// for a landing. Prevents the fallthrough from issuing a backward exact re-seek to "correct" a forward
    /// overshoot (which drags a playing playhead back and re-stalls it).
    nonisolated static func seekLandedAtTarget(
        rendered: Double,
        target: Double,
        forward: Bool,
        tolerance: Double = 0.75
    ) -> Bool {
        guard rendered.isFinite else { return false }
        return forward ? rendered >= target - tolerance : rendered <= target + tolerance
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
    ///
    /// - Parameter finalTeardown: whether this stop means "leaving playback entirely" rather than handing
    ///   off to another `load()`. Defaults to `resetDisplayCriteria`, which is the right answer for almost
    ///   every caller, but the two are separable: a host that keeps display criteria across a stop/load
    ///   pair (`resetDisplayCriteria: false`) and *is* genuinely leaving playback can pass
    ///   `finalTeardown: true`. Only a final teardown honours `deactivatesAudioSessionOnStop`.
    public func stop(resetDisplayCriteria: Bool = true, finalTeardown: Bool? = nil) {
        stopInternal(resetDisplayCriteria: resetDisplayCriteria,
                     finalTeardown: finalTeardown ?? resetDisplayCriteria)
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
        pendingNativeRenderingRequest = nil   // #170: the session the latched request targeted is gone
        externalNativeStoreFillTask?.cancel()
        externalNativeStoreFillTask = nil
        resetSubtitleOCRState()   // Phase D: new session, new axis
        remoteHLSSubtitleDiscoveryTask?.cancel()
        remoteHLSSubtitleDiscoveryTask = nil
        // #316: the proxy serves exactly one session's master; a standing socket outliving it would keep a
        // port and a decode task alive for a source nobody plays any more.
        remoteHLSSubtitleProxy?.tearDown()
        remoteHLSSubtitleProxy = nil
        injectedSubtitleRenditionNames = [:]
        // Font attachments are session-scoped but must survive stopInternal (audio-track-switch skips the probe;
        // clearing in stopInternal would leave the session with an empty font list after any audio switch).
        fontAttachments = []
        // Container chapters belong to the source URL, not to the pipeline, so they follow the same rule:
        // every reopen of the same source (audio switch, iOS background return, #127 expiry) runs through
        // stopInternal without re-probing, and a wipe there would strip them for the rest of the session.
        // Disc chapters are NOT in this block: a title switch really does change them, and the reload path
        // recaptures them from the reopened demuxer.
        mediaChapters = []
        videoFormat = .sdr
        sourceVideoFormat = .sdr
        sourceDVProfile = nil
        sourceVideoFrameRate = nil
        sourceVideoBitrate = 0
        sourceVideoWidth = 0
        sourceVideoHeight = 0
        pendingExternalMetadata = []
        #if os(tvOS) || os(iOS)
        // Same lifetime as pendingExternalMetadata: session identity the host staged, cleared when the
        // host leaves playback so the next session cannot inherit the previous title's system card.
        // Surviving stopInternal is deliberate (a reload keeps the card through the seam).
        pendingVideoNowPlayingInfo = [:]
        #endif
        // Clear loadedURL on public stop() so reloadAtCurrentPosition can't resurrect the URL after dismissal
        // and selectSubtitleTrack can't spawn a side demuxer against a stopped session.
        loadedURL = nil
        isCustomSource = false
        customSourceIsSeekable = false
    }

    /// Active AVPlayer on the native path, nil on SW path or when idle. Published so hosts driving an
    /// AVPlayerViewController can rebind `.player` on every audio-track reload (one-shot assignment goes stale).
    @Published public internal(set) var currentAVPlayer: AVPlayer? {
        didSet {
            observeExternalPlayback()
            observeCurrentItem()
        }
    }

    /// Item currently loaded into `currentAVPlayer` (#260). Published separately because items are swapped in
    /// place (`replaceCurrentItem`, on every audio-track reload and episode autoplay) without the player itself
    /// changing, so a host holding the item or its timebase gets no signal from `currentAVPlayer` alone.
    @Published public internal(set) var currentAVPlayerItem: AVPlayerItem?
    private var currentItemObservation: NSKeyValueObservation?

    private func observeCurrentItem() {
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        guard let player = currentAVPlayer else {
            currentAVPlayerItem = nil
            return
        }
        currentAVPlayerItem = player.currentItem
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, change in
            guard let item = change.newValue else { return }
            Task { @MainActor in self?.currentAVPlayerItem = item }
        }
    }

    /// AirPlay (#86, DrHurt): true while the native AVPlayer reports external playback. loadNative reads it to
    /// serve the loopback over the device's LAN IP (the receiver can't reach 127.0.0.1), and for an HDR/DV
    /// source also to force the MEDIA playlist (AVPlayer rejects a DV/HDR MASTER playlist on an SDR receiver
    /// and won't auto-switch, DrHurt). An SDR master is kept so its subtitle renditions travel (#227).
    /// Loopback native path only; a remote-HLS source is already receiver-reachable, so it's left untouched.
    private(set) var airPlayActive = false
    private var externalPlaybackObservation: NSKeyValueObservation?

    /// Current external-playback state, or false where the platform has no such route.
    /// `AVPlayer.isExternalPlaybackActive` is unavailable on visionOS: video goes to the wearer's
    /// displays, there is no receiver to hand the stream to, so the whole #86 / #227 serve-the-loopback-
    /// over-the-LAN path is inert there.
    private var isExternalPlaybackActiveNow: Bool {
        #if os(visionOS)
        return false
        #else
        return currentAVPlayer?.isExternalPlaybackActive ?? false
        #endif
    }

    private func observeExternalPlayback() {
        externalPlaybackObservation?.invalidate()
        externalPlaybackObservation = nil
        #if !os(visionOS)
        guard let player = currentAVPlayer else { return }
        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, change in
            let active = change.newValue ?? false
            Task { @MainActor in self?.handleExternalPlaybackChange(active: active) }
        }
        #endif
    }

    /// #227: an external-playback edge arrived while the reload this observer started was still running, so
    /// the real route state has to be re-read once the rebuilt item exists.
    private var externalPlaybackEdgeHeld = false

    /// #227: how long a master handed to a wireless AirPlay receiver gets to actually move the clock before
    /// it counts as refused. A receiver that will not play the offered variant does NOT fail the item and
    /// does not report `-11868`: it simply never starts, while the rate flickers to `playing` for a tick
    /// (device log 2026-07-27, DV master). That is invisible to the readiness gate, so progress is the only
    /// signal left. A receiver that does take the master fetches its init segment within about a second of
    /// the playlist, so this is generous without making a parked receiver wait for nothing.
    static let airPlayProgressWatchdogSeconds: Double = 5.0

    /// Master attempts on a wireless AirPlay hop before the media fallback (#227). Two, matching the #35
    /// gate: the first attempt is what makes a Match-Dynamic-Range receiver switch its output to HDR, and
    /// the second is the one that can be accepted once it has.
    static let airPlayMasterAttempts = 2
    private var airPlayProgressWatchdog: Task<Void, Never>?

    private var displayModeDiagnostic: Task<Void, Never>?

    /// Sodalite #49: read back what the Match-Frame-Rate switch actually landed on. `preferredDisplayCriteria`
    /// is a hint with no read-back, so a display-link sample once playback is running is the only way to tell
    /// three cases apart for a judder report: the panel ignored the criteria and kept the system rate (50.000
    /// under a 29.970 source), it took a rate that does not divide the content rate (60.000 vs 59.940, one
    /// repeated frame every ~16 s), or it is correct and the cadence problem is downstream of the panel.
    /// Logs both backends so the software path serves as the control for a native-path report.
    @MainActor
    func armDisplayModeDiagnostic(gen: UInt64, backend: String, contentRate: Double?, requestedRate: Double?) {
        #if os(tvOS)
        displayModeDiagnostic?.cancel()
        displayModeDiagnostic = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled, self.loadGeneration == gen else { return }
            let sample = await self.displayCriteria.measureRefreshRate()
            guard !Task.isCancelled, self.loadGeneration == gen else { return }
            // currentVideoFrameRate is 0 on audio tracks and while paused, so the first non-zero entry is
            // the video track's own measure of how many frames the player is actually putting on screen.
            let playerRate = self.currentAVPlayer?.currentItem?.tracks
                .lazy.map(\.currentVideoFrameRate).first { $0 > 0 }
            func fmt(_ value: Double?) -> String {
                value.map { String(format: "%.3f", $0) } ?? "n/a"
            }
            EngineLog.emit(
                "[DisplayCriteria] mode check (\(backend)): content=\(fmt(contentRate)) "
                + "requested=\(fmt(requestedRate)) panel=\(fmt(sample?.measured))Hz "
                + "(nominal \(fmt(sample?.nominal))) player=\(fmt(playerRate.map(Double.init)))fps",
                category: .engine
            )
        }
        #endif
    }

    /// Receivers that failed to start on an HDR master this process, by route UID (#227). An Apple TV
    /// parked in SDR refuses one, and nothing in the public API reports the receiver's dynamic range, so
    /// the offer has to be made once and remembered. Per process on purpose: a user who switches the
    /// receiver's output format to HDR gets the offer again on the next launch.
    private var airPlayReceiversRefusingHDRMaster: Set<String> = []

    /// Route UID of the wireless AirPlay receiver currently holding the audio route, or nil.
    nonisolated static func currentAirPlayReceiverUID() -> String? {
        #if os(iOS)
        return AVAudioSession.sharedInstance().currentRoute.outputs
            .first { $0.portType == .airPlay }?.uid
        #else
        return nil
        #endif
    }

    /// Arm the progress watchdog for a load that handed the receiver a playlist with subtitle renditions.
    /// No-op otherwise: the media playlist is the fallback itself, and a local session cannot be refused.
    @MainActor
    func armAirPlayProgressWatchdog(gen: UInt64, position: Double) {
        airPlayProgressWatchdog?.cancel()
        airPlayProgressWatchdog = nil
        guard airPlayActive, airPlayServedMasterToReceiver else { return }
        let baseline = currentTime
        airPlayProgressWatchdog = Task { @MainActor [weak self] in
            let seconds = AetherEngine.airPlayProgressWatchdogSeconds
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.loadGeneration == gen else { return }
            self.handleRefusedAirPlayMaster(baseline: baseline, position: position)
        }
    }

    /// The receiver never started on the playlist it was handed (#227): reload the LAN media playlist, which
    /// every receiver takes, and remember an HDR refusal so the same receiver is not made to wait again.
    ///
    /// A second master attempt was tried and dropped. The idea was that the first, refused attempt is what
    /// makes a Match-Dynamic-Range receiver switch its output to HDR, the way the #35 cold-DV gate's failed
    /// attempt warms the link; the receiver does switch during that window. On device it changed nothing and
    /// only doubled the wait before the picture appeared, so the honest answer for such a receiver is the
    /// media playlist plus a host telling the user to set the format to HDR or Dolby Vision.
    @MainActor
    private func handleRefusedAirPlayMaster(baseline: Double, position: Double) {
        guard airPlayActive, airPlayServedMasterToReceiver else { return }
        guard let host = nativeHost, let session = nativeVideoSession,
              let mediaURL = session.mediaPlaylistURL else { return }
        // Deliberately NOT gated on `state`: a refused session parks at paused, which is exactly the case
        // this exists for, and an earlier version guarded on `state == .playing` and therefore never fired
        // (device log 2026-07-27, where the #65 wedge recovery then nudged six times and gave up). The
        // honest discriminator is the server's: a receiver that refuses the manifest fetches playlists and
        // never a single segment, while a merely paused session has long since fetched its init segment.
        let advanced = currentTime - baseline
        guard advanced < 0.5, !session.hasServedMediaSegment else { return }

        let receiverUID = Self.currentAirPlayReceiverUID()
        if let receiverUID, session.servedSourceIsHDR {
            airPlayReceiversRefusingHDRMaster.insert(receiverUID)
        }
        EngineLog.emit(
            "[AirPlay] receiver did not start in "
            + "\(String(format: "%.0f", Self.airPlayProgressWatchdogSeconds))s (clock advanced "
            + "\(String(format: "%.2f", advanced))s, no segment fetched); the playlist it was handed is "
            + "refused, falling back to the LAN media playlist (subtitle renditions dropped"
            + (receiverUID != nil && session.servedSourceIsHDR
               ? ", and this receiver is remembered as refusing HDR masters" : "") + ")",
            category: .session)
        session.markServingMediaAfterFallback()
        nativeSubtitleRenditionsServed = false
        airPlayServedMasterToReceiver = false
        host.load(url: airPlayHostSwapped(mediaURL), startPosition: position, inPlaceSwap: true)
        host.play()
    }

    private func handleExternalPlaybackChange(active: Bool) {
        // #227 (device log 2026-07-27): the reload started below tears down the very item the KVO watches, so
        // AVPlayer reports a transient `false` in the middle of it. Acting on that edge cleared `airPlayActive`
        // before `loadNative` read it, the rebuilt session served 127.0.0.1 again, the receiver re-engaged
        // external playback, and that true edge started the next reload: one full session rebuild per turn,
        // forever (ports 51291, 51296, 51299, ... in the log), with the LAN swap never once applied. Hold any
        // edge for the duration of the reload and reconcile against the live route afterwards.
        if sessionPreservingReloadInFlight {
            externalPlaybackEdgeHeld = true
            EngineLog.emit("[AirPlay] external playback \(active) during a session-preserving reload; "
                           + "holding the edge until the rebuilt item settles", category: .engine)
            return
        }
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

    /// Re-read external playback after a session-preserving reload and act on it if it really changed (#227).
    /// The player flag alone is not trustworthy at this instant: the rebuilt item may not have re-engaged the
    /// receiver yet, which would read as "AirPlay ended" and start the next reload of the same loop. The audio
    /// route survives the item teardown, so a receiver still holding the route keeps the session on its LAN URL.
    func reconcileExternalPlaybackAfterReload() {
        guard externalPlaybackEdgeHeld else { return }
        externalPlaybackEdgeHeld = false
        let active = isExternalPlaybackActiveNow || Self.isWirelessAirPlayRoute()
        EngineLog.emit("[AirPlay] reconciling the held edge after the reload: active=\(active) "
                       + "(player=\(isExternalPlaybackActiveNow) "
                       + "route=\(Self.isWirelessAirPlayRoute()))", category: .engine)
        handleExternalPlaybackChange(active: active)
    }

    /// True when a wireless AirPlay receiver holds the current audio route. Unlike
    /// `AVPlayer.isExternalPlaybackActive` this survives an item teardown, which is what makes it the right
    /// signal for the post-reload reconcile (#227). Wired HDMI reports `.HDMI` and is excluded by construction.
    nonisolated static func isWirelessAirPlayRoute() -> Bool {
        #if os(iOS)
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        #else
        return false
        #endif
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

    /// Playback URL and subtitle-rendition reality for a freshly started loopback session, after the AirPlay
    /// rewrite (#86, #227). Identity outside iOS and whenever external playback is off; when the LAN IP scan
    /// comes up empty the loopback URL stays as resolved (the receiver then simply cannot reach it, unchanged
    /// from #86). `subtitleRenditionsServed` is what the served playlist actually carries, which is what
    /// `nativeSubtitleRenditionsServed` promises hosts.
    func airPlayAdjustedPlayback(url: URL, session: HLSVideoEngine) -> (url: URL, subtitleRenditionsServed: Bool) {
        airPlayServedMasterToReceiver = false
        #if os(iOS)
        guard airPlayActive else { return (url, session.servingMasterPlaylist) }
        let receiverUID = Self.currentAirPlayReceiverUID()
        let refusedBefore = receiverUID.map { airPlayReceiversRefusingHDRMaster.contains($0) } ?? false
        let playlist = AirPlayPlaylistDecision.playlistForReceiver(
            servingMasterPlaylist: session.servingMasterPlaylist,
            sourceIsHDR: session.servedSourceIsHDR,
            receiverRefusedHDRMaster: refusedBefore)
        let carriesRenditions = AirPlayPlaylistDecision.carriesSubtitleRenditions(playlist)
        guard let lanURL = airPlayPlaybackURL(base: url, playlist: playlist) else {
            EngineLog.emit("[AirPlay] no LAN IP; keeping \(url.absoluteString)", category: .engine)
            return (url, session.servingMasterPlaylist)
        }
        airPlayServedMasterToReceiver = carriesRenditions
        EngineLog.emit("[AirPlay] loadNative serving via \(lanURL.absoluteString) (playlist=\(playlist) "
                       + "sourceIsHDR=\(session.servedSourceIsHDR) refusedBefore=\(refusedBefore) "
                       + "subtitle renditions \(carriesRenditions ? "carried" : "dropped"))", category: .engine)
        return (lanURL, carriesRenditions)
        #else
        return (url, session.servingMasterPlaylist)
        #endif
    }

    /// True while the current native load handed the receiver a MASTER playlist (#227 follow-up). Arms the
    /// startup-readiness gate on that hop: the sender cannot read the receiver's HDR mode, so a rejected or
    /// silently parked master has to be caught and downgraded to the LAN media playlist.
    private(set) var airPlayServedMasterToReceiver = false

    /// The same loopback URL on the device's LAN IP, path untouched (master, reduced master, media). For the
    /// readiness gate's reloads while AirPlaying, which otherwise hand the receiver a 127.0.0.1 URL it cannot
    /// reach. Identity when no LAN IP resolves.
    func airPlayHostSwapped(_ url: URL) -> URL {
        airPlayPlaybackURL(base: url, playlist: .master) ?? url
    }

    /// AirPlay loopback URL (#86): rewrite the loopback playback URL to the device's LAN IP so the receiver
    /// reaches the engine-processed stream. nil if no LAN IP (caller keeps the original 127.0.0.1 URL).
    ///
    /// `playlist` also picks the path: the resolved master for SDR (the renditions live only there, #227),
    /// the reduced HDR master or plain media for HDR. See `AirPlayPlaylistDecision`.
    func airPlayPlaybackURL(base: URL,
                            playlist: AirPlayPlaylistDecision.ReceiverPlaylist = .media) -> URL? {
        guard let lanIP = HLSLocalServer.localActiveIPAddress() else { return nil }
        return AirPlayPlaylistDecision.receiverURL(base: base, lanIP: lanIP, playlist: playlist)
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

    #if os(tvOS) || os(iOS)
    /// Opt in to owning the system Now-Playing session on the native VIDEO path.
    ///
    /// Off by default, and that default is load-bearing. The native path is consumed both by hosts
    /// that build their own transport around a bare `AVPlayer` and by `AVPlayerViewController` hosts,
    /// and AVKit owns Now-Playing itself there through private MediaRemote: WWDC22's guidance is not
    /// to bring an `MPNowPlayingSession` when using AVKit, and doing so costs the host AVKit's card,
    /// its `externalMetadata`, and its working transport commands. Only a host with custom UI should
    /// set this. The audio path has no such fork (always a bare AVPlayer) and owns its session
    /// unconditionally.
    ///
    /// Read when a native host is created, so set it before `load()`. A host preserved across a
    /// native->native reload (issue #15) keeps whatever it was created with; the change takes effect
    /// on the next fresh host.
    public var ownsVideoNowPlayingSession: Bool = false

    /// MPNowPlayingSession for the native VIDEO path; nil unless `ownsVideoNowPlayingSession` was set
    /// before the session loaded (also nil on the software path and with no host). Same contract as
    /// `audioNowPlayingSession`: the host app registers transport commands on `remoteCommandCenter`
    /// and stages identity metadata via `setVideoNowPlayingInfo`; the session auto-publishes
    /// elapsed/rate/duration from the AVPlayer and survives native->native reloads with the host
    /// (issue #15), so system Now-Playing ownership holds across a background pause.
    public var videoNowPlayingSession: MPNowPlayingSession? {
        nativeHost?.nowPlayingSession
    }

    /// Staged per-item Now-Playing dictionary for the native video path. Replayed at host creation
    /// and onto every fresh AVPlayerItem (gate reloads, media fallback, in-place swaps). Caller-managed
    /// like the audio variant: pass an empty dict to clear.
    var pendingVideoNowPlayingInfo: [String: Any] = [:]

    /// Stage the system Now-Playing identity dictionary for the native video path (MPMediaItemProperty
    /// keys + a force-decoded, @Sendable-wrapped MPMediaItemArtwork). Elapsed/rate/duration keys are
    /// unnecessary, the session merges the player truth. Safe before `load()`; replayed at host
    /// creation. Ignored by a host that does not own the session (`ownsVideoNowPlayingSession`), but
    /// still staged, so a host that opts in on a later load keeps what it set.
    public func setVideoNowPlayingInfo(_ info: [String: Any]) {
        pendingVideoNowPlayingInfo = info
        nativeHost?.setNowPlayingInfo(info)
    }
    #endif

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

    /// Whether a teardown may release the shared `AVAudioSession` (#215).
    ///
    /// Three independent conditions, all required:
    /// - `finalTeardown`: the caller declared "leaving playback", which only `stop()` does. `!keepNativeHost`
    ///   is NOT a usable proxy for it: it defaults to `false`, so every bare `stopInternal()` (the live-reload
    ///   watchdog, for one, which expects the host to retune immediately) would tear a process-wide session
    ///   down mid-cycle.
    /// - `!keepNativeHost`: belt and braces. A preserved host means audio keeps flowing into the next load.
    /// - `hostOptedIn`: `deactivatesAudioSessionOnStop`. The session is process-global state the engine
    ///   mostly does not own, so releasing it is the host app's call.
    nonisolated static func shouldDeactivateAudioSessionOnTeardown(finalTeardown: Bool,
                                                                   keepNativeHost: Bool,
                                                                   hostOptedIn: Bool) -> Bool {
        finalTeardown && !keepNativeHost && hostOptedIn
    }

    #if os(iOS) || os(tvOS)
    /// Counterpart to the activations the engine takes part in (#215). The native path never activates the
    /// session itself (AVKit does it per playback, #24); the software and audio renderer paths do, in
    /// `activateRendererAudioSession()`. Either way, holding an active `.playback` session after playback is
    /// over is what strands an E-AC-3/JOC Atmos BITSTREAM PASSTHROUGH render ring on the HDMI sink: the
    /// receiver keeps looping the last MAT frame once the player is released (reported by Brandon Moore:
    /// audio stutters on after leaving the video and persists off-screen). `.notifyOthersOnDeactivation` so
    /// whatever was interrupted resumes. Best effort: a failure here costs the ring, not the teardown.
    nonisolated static func deactivateSharedAudioSession() {
        let started = DispatchTime.now()
        func elapsedMs() -> Int {
            Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
        }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            EngineLog.emit(
                "[AetherEngine] AVAudioSession deactivated on final teardown in \(elapsedMs())ms "
                + "(release passthrough render ring)",
                category: .engine)
        } catch {
            // `.isBusy` is NOT a failure and must not be retried. Per AVAudioSession.h: since iOS 8,
            // deactivating with running I/O still DEACTIVATES the session and returns this code purely
            // "to indicate the misuse of the API" -- and since iOS/tvOS 26 it is not returned at all.
            // The ring is released either way; the only actionable part is that we were asked to
            // deactivate before the render path finished releasing its I/O. Retrying would be worse than
            // useless: a retry landing after a subsequent load() would deactivate the NEW session.
            let nsError = error as NSError
            if nsError.code == AVAudioSession.ErrorCode.isBusy.rawValue {
                EngineLog.emit(
                    "[AetherEngine] AVAudioSession deactivated on final teardown in \(elapsedMs())ms "
                    + "(session released; I/O was still running)",
                    category: .engine)
            } else {
                EngineLog.emit(
                    "[AetherEngine] AVAudioSession deactivate on teardown failed after \(elapsedMs())ms: "
                    + "\(error) (passthrough ring may keep looping)",
                    category: .engine)
            }
        }
    }

    /// Run the #215 deactivation off the main actor.
    ///
    /// `setActive(false)` is an XPC round trip to mediaserverd, and on an E-AC-3 / Atmos MAT passthrough
    /// route the sink renegotiates the HDMI link inside that call: measured at roughly half a second on an
    /// Apple TV 4K feeding an AVR, against a few milliseconds for the same call on a 5.1 route. Inline in
    /// the teardown that is half a second of frozen UI, because the host's dismiss cannot start until
    /// `stop()` returns. Same reasoning that moved `setCategory` off-main in #114; the difference is that
    /// this one has to stay ordered against a following `load()`, hence the generation guard.
    ///
    /// `loadGeneration` was bumped by the `stopInternal` that scheduled this, so any `load()` starting in
    /// the meantime bumps it again and the pending deactivation drops rather than releasing the session
    /// out from under the new item. `stopInternal` also cancels a pending task before scheduling a new one.
    private func scheduleAudioSessionDeactivation() {
        let generation = loadGeneration
        audioSessionDeactivationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, await self.loadGeneration == generation else { return }
            AetherEngine.deactivateSharedAudioSession()
        }
    }
    #endif

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
    func stopInternal(resetDisplayCriteria: Bool = true, keepNativeHost: Bool = false, keepCustomReader: Bool = false, keepCurrentItem: Bool = false, finalTeardown: Bool = false) {
        // Bump generation to invalidate in-flight load() checkpoints.
        loadGeneration &+= 1
        resumeAfterInterruption = false
        #if os(iOS) || os(tvOS)
        // A deactivation still queued from a previous teardown must not land on this session (#215).
        audioSessionDeactivationTask?.cancel()
        audioSessionDeactivationTask = nil
        #endif
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
        // #214 follow-up: the confirmation ledger is NOT cleared here. It is keyed to loadedURL and a
        // session-preserving reload runs through stopInternal too; clearing would re-pay the pass on
        // every audio switch. A new item invalidates it in startAtmosConfirmation().
        cancelAtmosConfirmation()
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
        // #314: detach before stop() so a pump still unwinding does not report frames into a table the
        // host has already retired for the next item. Only the session's slot is cleared; the engine
        // keeps the host's observer and re-arms the next session with it in load().
        nativeVideoSession?.setNativeVideoFrameTimeObserver(nil)
        nativeVideoSession?.stop()
        nativeVideoSession = nil
        nativeSubtitleRenditionsServed = false
        airPlayProgressWatchdog?.cancel()
        airPlayProgressWatchdog = nil
        displayModeDiagnostic?.cancel()
        displayModeDiagnostic = nil
        airPlayServedMasterToReceiver = false
        extractorYieldState.deactivate()
        setPendingRecoverySeekTarget(nil)
        // #127: readiness + deferred host seeks are session-scoped; the host-side sink can't clear them
        // once nativeCancellables are gone.
        isSessionReady = false
        // #315: session-scoped for the same reason, and the host mirrors are being cut here.
        hasFirstFrameReadyForDisplay = false
        pendingPreReadySeekSeconds = nil

        // Shut down cache-backed scrub-thumbnail FrameExtractors with the session.
        let scrubThumbs = scrubThumbnailExtractors
        scrubThumbnailExtractors.removeAll()
        for entry in scrubThumbs {
            Task { await entry.extractor.shutdown() }
        }

        softwareCancellables.removeAll()
        // #314: same detach on the software path, where the outgoing renderer's decode thread is what
        // can still hand a frame over while the next host comes up.
        softwareHost?.setVideoFrameTimeObserver(nil)
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

        // #215: release the shared AVAudioSession once every render path above is quiesced. Scheduled
        // last so the item is unloaded, the AVPlayer released and the software/audio outputs stopped
        // before the session goes away, and scheduled rather than called because the release itself can
        // block for ~0.5 s on a MAT passthrough route. Opt-in twice over: the caller must declare an
        // actual final teardown, AND the host must have set deactivatesAudioSessionOnStop.
        #if os(iOS) || os(tvOS)
        if Self.shouldDeactivateAudioSessionOnTeardown(finalTeardown: finalTeardown,
                                                       keepNativeHost: keepNativeHost,
                                                       hostOptedIn: deactivatesAudioSessionOnStop) {
            scheduleAudioSessionDeactivation()
        }
        #endif

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
        // AE#105 / AE#270: the display origin belongs to the session that published it. Clearing it here
        // rather than only in stop() keeps a load that reuses the engine (the common path: load() runs
        // stopInternal itself) from folding the previous source's PTS origin into the new one's clock.
        sourcePresentationOrigin = 0
        latchedPresentationOrigin = nil
        setPresentationAxis(PresentationAxisMap())
        nativeClockSeconds = 0
        clock.sourceTime = 0
        clock.bufferedPosition = 0
        isBuffering = false
        readerStall = .flowing
        // Hard-clear in-flight seek state: late callbacks are dropped by generation guards, but isSeeking
        // must not strand (#38). Open tickets are rejected rather than left dangling, so a host tracking
        // "did my target land" never waits on a seek whose session is gone. A ticket kept open by the
        // give-up path (recovery intent) dies here too: the session it aimed at no longer exists.
        closeSeekTicket(&programmaticSeekTicket, with: .rejected(.noActiveSession))
        closeSeekTicket(&nativeScrubSeekTicket, with: .rejected(.noActiveSession))
        closeSeekTicket(&deferredSeekTicket, with: .rejected(.noActiveSession))
        pendingScrubLanding = nil
        scrubLandingWatchdog?.cancel()
        scrubLandingWatchdog = nil
        programmaticSeekInFlight = false
        nativeScrubSeekInFlight = false
        deferredSeekInFlight = false
        programmaticSeekTarget = nil
        nativeScrubSeekTarget = nil
        deferredSeekTarget = nil
        // Through the recompute rather than assigning the two properties: it also releases the #240 side
        // reader link gate, which a stop landing mid-seek otherwise leaves owned by the video path for the
        // whole next session (the gate is per engine, not per session).
        recomputeSeekSignal()

        liveWindowTimerTask?.cancel()
        liveWindowTimerTask = nil

        cancelSidecarTask()
        stopSubtitleDrainer()                  // #112 rework: both channels
        resetSubtitleOCRState()                // Phase D
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
    /// #176 follow-up: HEVC P5 / AV1 P10.0 carry only an IPT-PQ-c2 signal (no compatible base layer);
    /// the software path would decode it as YCbCr (green/purple cast), so the load fails instead.
    /// AV1 P10.0 requires hardware AV1 decode; HEVC P5 requires a seekable source for the native path.
    case dolbyVisionUnplayableOnSoftwarePath(profile: String)

    public var errorDescription: String? {
        switch self {
        case .noVideoStream: return "No video stream in source"
        case .noAudioStream: return "No audio stream in source"
        case .hlsPlaylistOnRawLivePath:
            return "HLS playlist supplied to the raw live path. Use LoadOptions.nativeRemoteHLS or HLSLiveIngestReader for m3u8 sources."
        case .dolbyVisionUnplayableOnSoftwarePath(let profile):
            return "Dolby Vision Profile \(profile) has no compatible base layer and cannot be color-correctly decoded on the software playback path"
        }
    }
}
