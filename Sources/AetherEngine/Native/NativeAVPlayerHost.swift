import Foundation
import AVFoundation
import AVKit
import Combine
#if os(tvOS) || os(iOS)
import MediaPlayer
#endif

/// NativeAVPlayerHost: AVPlayer + AVPlayerLayer wrapper for the HLS-fMP4 loopback path.
/// tvOS exposes the HDMI DV/HDR handshake only through AVPlayer-rooted playback, not AVSampleBufferDisplayLayer.
/// Covers HEVC, H.264, and HW-AV1; SW fallback (AV1/VP9) lives in SoftwarePlaybackHost.
/// DisplayCriteriaController writes preferredDisplayCriteria before item load so the handshake is in flight first.
/// AE#422: what the seek-deadline loop needs from AVPlayer, as one off-main reading.
/// AE#422 / AE#287: what the premature-end recovery needs from AVPlayer, as one off-main reading.
struct PrematureEndReading: Sendable {
    let playhead: Double
    let seekableEnd: Double?
    let loadedEnd: Double?
}

struct SeekBufferSnapshot: Sendable {
    /// End of the contiguous buffered span covering the playhead.
    let bufferedEnd: Double
    /// Loaded seconds measured AT the pending seek target, not at the playhead.
    let targetIsland: Double
}

@MainActor
final class NativeAVPlayerHost {

    // MARK: - Published state

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    /// AVPlayer's actually-rendered position (pre-seek parked frame during in-flight seeks). Folded to clock.sourceTime so subtitle overlay tracks the picture, not the scrub target (issue #49).
    @Published private(set) var renderedTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    /// #376: the failure a host classifies on, message included. Published instead of a bare string so
    /// the AVFoundation domain and code survive the hop into `state`.
    @Published private(set) var failure: PlaybackErrorInfo?
    /// #50: monotonic token; bumped on each deferred .failed so a superseding failure or item swap cancels the in-flight confirmation.
    private var failureConfirmToken: Int = 0
    /// AE#495: what the AE#495 relay knows about the origin's certificate, when the item this host
    /// plays is served by one. Set by the engine at mount, read only while classifying a failure.
    var upstreamTrustRefusal: (@Sendable () -> Int?)?
    /// AE#561: what the session can still offer when AVPlayer refuses the media, answered by the
    /// engine because the host owns none of it. Set at mount, read only while classifying a failure.
    var softwarePathAvailability: (@Sendable () -> SoftwarePathEscalation.Availability?)?
    /// #50: latched on first .playing; discriminates startup failures (never played) from mid-playback transients. .failed and timeControlStatus KVOs are unsynchronized, so instantaneous status is unreliable. Reset with the item on a reused host.
    private var hasEverPlayed = false
    @Published private(set) var didReachEnd: Bool = false

    /// #315: `AVPlayerLayer.isReadyForDisplay` for the item this host holds, which is the only
    /// signal on this path for "there is a picture". `isReady` is the item's `readyToPlay`, which
    /// AVFoundation reaches before the layer has presented anything and which stays true across a
    /// seek, so a host lifting a black cover on it lifts it onto black.
    ///
    /// A LEVEL, not a latch: it falls whenever the layer loses its picture, which every item swap
    /// does, including the in-place handover (measured: ~40 ms of false around a
    /// `replaceCurrentItem`, even when the swap is meant to be invisible). The engine folds it into
    /// the load-scoped `AetherEngine.hasFirstFrameReadyForDisplay`, which is what a host should
    /// consume; nothing here is worth reacting to on its own.
    @Published private(set) var isVideoReadyForDisplay: Bool = false

    /// What the current session was loaded under, carried across an item swap (#440 round 5). See
    /// `SessionLoadContract` and `swapItem`.
    private(set) var sessionContract = SessionLoadContract()

    /// Where the current item was placed when it was mounted: the explicit start seek `load` makes,
    /// or nil when it joined without one (a live rejoin). Recorded on every mount, the in-place swaps
    /// included, so a recovery that has to replace this item puts the next one where THIS one was,
    /// not where the session first started (#98). A startup-failed item has no reliable
    /// `renderedTime`, which is why the fallback reads the placement rather than the clock.
    private(set) var mountedStartPosition: Double?

    /// Set per load; gates the AE#287 premature-end recovery, which only makes sense for a fixed-length
    /// presentation. A live session has no advertised end to fall short of.
    private var isLiveSession: Bool = false
    /// AE#440: set per load from `LoadOptions.liveJoinStartsImmediately`. Arms the one-shot below.
    private var liveJoinStartsImmediately: Bool = false
    /// AE#440: spent once the join has either been started by hand or rolled on its own, so the override
    /// belongs to the join and every later hold in the session keeps AVPlayer's own stall policy.
    private var liveJoinImmediateStartSpent: Bool = false
    /// AE#440: true while the buffer reading for this decision is in flight off the main actor. The
    /// reading is async, so two hold edges arriving during it would otherwise each decide on their own
    /// copy of a one-shot neither has spent yet.
    private var liveJoinImmediateStartProbeInFlight: Bool = false
    /// AE#440: keeps the "left the wait alone" line to one per load. It reports the depth that failed
    /// the floor, which is the only way to tell a starved join from a rate evaluation after the fact.
    private var liveJoinThinBufferLogged: Bool = false
    /// AE#440 round 5: keeps the "the hold was over before the reading came back" line to one per load.
    private var liveJoinNoDecisionLogged: Bool = false
    /// AE#684: one line per load for a hold the depth would have cut and the item's status refused.
    private var liveJoinNotReadyLogged: Bool = false
    /// AE#684: the one repeat a not-ready refusal gets when the item turned ready under it.
    private var liveJoinNotReadyAskedAgain: Bool = false
    /// AE#440 round 3: one witness per load for a hold that was refused, so the bound is read while the
    /// hold stands and not only at its edges. Observes, never acts (see `startLiveJoinHoldWitness`).
    private var liveJoinHoldWitnessStarted: Bool = false
    /// AE#440 round 4: the one-shot was spent by the override firing rather than by the rate rolling on
    /// its own. Both spend it, and the witness has to name which, because "the wait ended without the
    /// buffer reaching the floor" is the opposite of what happened when the override cut it.
    private var liveJoinImmediateStartCutShort: Bool = false
    /// AE#443: what the items this host has already retired transferred, so `rx` keeps describing the
    /// SESSION across an item swap the session survives.
    ///
    /// Summing an item's access-log entries fixed the fall inside one item; an item's log holds only
    /// its own entries, so the number still restarted from zero the moment the #93 stage-2 recovery
    /// replaced the item under a session that never stopped. Measured by the reporter on 6.53.0:
    /// 1229.1 MB, the field absent for the swap, then 34.3 MB. Same scope error as the two before it,
    /// one layer further out.
    ///
    /// Last observed totals fold at the swap, with an off-main final read reconciling any delta.
    /// Backlogged retirement reads are bounded; if one is discarded these remain observed lower
    /// bounds, explicitly logged rather than invented final counts. The sampler's
    /// `player.currentItem === item` guard keeps the outgoing item from also being counted as current.
    private(set) var retiredItemTransferredBytes: Int64 = 0
    private(set) var retiredItemDroppedFrames: Int = 0

    /// AE#287 bookkeeping, cleared with the item in `unloadCurrentItem`.
    private var prematureEndRecoveryAttempts: Int = 0
    private var lastPrematureEndRecoveryPlayhead: Double?
    /// True across the re-seek of a premature-end recovery. AVPlayer drops to `.paused` for its
    /// duration, and publishing that transient would bounce the engine through `.paused` and back for
    /// what the viewer must not even notice; the real status is republished when the recovery settles.
    private var prematureEndRecoveryInFlight = false
    /// Mirrors avPlayer.timeControlStatus so the engine can reconcile when AVKit's transport bar, Control Center, or hardware buttons toggle the player externally (without this, engine state goes stale and play/pause presses are swallowed).
    @Published private(set) var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    /// Monotonic count of AVPlayerItem playbackStalled notifications (#93 residual): the engine
    /// opens its spurious-pause recovery window on each stall.
    @Published private(set) var stallCount: Int = 0
    /// Monotonic count of loopback-path `failedToPlayToEndTime` deaths after playback was
    /// established (#93 round 3). Accumulated -12889 media timeouts fail the item with tcs parked
    /// at .paused, which every pause-guarded recovery layer misreads as user intent; the engine
    /// subscribes and escalates into the stage-2 item reload with the pause guard bypassed.
    @Published private(set) var endFailureCount: Int = 0
    /// End of the last seekable time range (seconds); tracks the live edge for EVENT playlists.
    /// KVO mirror of `seekableTimeRanges`, NOT a live read: the getter is a sync XPC round-trip
    /// to mediaserverd, and clock-tick sinks plus the 1 Hz paused-live timer read this at a
    /// cadence that turns a busy media server into a main-thread hang (#134).
    @Published private(set) var seekableEnd: Double = 0
    /// AE#446 round 4: the start of the same range. See `seekableStart(from:)`.
    @Published private(set) var seekableStart: Double = 0

    /// Published when a startup `.failed` is a display-rejection of the served master (#98). The
    /// engine's fallback subscriber reads it, decides, and either reloads the media playlist or
    /// surfaces the failure. Reset on each load.
    @Published private(set) var pendingDisplayRejection: DisplayRejection?

    /// AE#561: a failure this host would otherwise have made terminal, offered to the engine's own
    /// decoder instead. The engine's subscriber rebuilds the session on the software path at the
    /// carried position. Reset on each load.
    @Published private(set) var pendingSoftwarePathEscalation: SoftwarePathEscalation.Request?

    /// AetherEngine#168: dynamic range read back from the item's parsed video-track CMFormatDescription,
    /// so the probe-free `nativeRemoteHLS` bypass can report the real format instead of the `.sdr` default.
    /// nil until a video track resolves (or when none does: the audio-only black-screen symptom). The
    /// engine's remote-HLS load subscribes and mirrors it into `sourceVideoFormat` / `videoFormat` and, for
    /// HDR, programs `preferredDisplayCriteria` (the panel switch AVPlayer needs to present HDR at all).
    @Published private(set) var detectedVideoFormat: VideoFormat?

    /// AetherEngine#168: the same-read nominal frame rate, so the engine's remote-HLS criteria also carry
    /// Match Frame Rate (the reporter's 4K item is 50 fps). nil when no video track / rate resolves.
    @Published private(set) var detectedVideoFrameRate: Double?
    /// Codec name read back from the item's video sample type on the probe-free bypass, in the libavcodec
    /// spelling the engine publishes elsewhere. Set beside `detectedVideoFormat`, which the engine's sink
    /// reads it with; nil while no video track resolves.
    @Published private(set) var detectedVideoCodecName: String?
    /// Dimensions and colour description of the delivered video from the same read, for the bypass's
    /// `sourceVideoWidth` / `sourceVideoHeight` / `sourceVideoStreamFormat`. Set before `detectedVideoFormat`.
    @Published private(set) var detectedVideoDescription: RemoteHLSStreamDescription.Video?
    /// The audio tracks AVPlayer built for the item, read at the same two points as the video format.
    /// The engine publishes them as `audioTracks` on the bypass, where no probe lists them.
    @Published private(set) var detectedAudioTracks: [RemoteHLSStreamDescription.AudioReading] = []

    /// AetherEngine#168 follow-up: fires once when the armed carriage watchdog concludes the master
    /// advertises a video rendition but AVPlayer never built a video track past the grace window
    /// (HEVC-in-MPEG-TS carriage, which AVFoundation's HLS demuxer does not support). The engine's
    /// remote-HLS load subscribes and reroutes the session onto the loopback live-ingest path.
    @Published private(set) var remoteHLSVideoCarriageRejected = false
    /// AE#363: fires once when the origin refused the native mount outright (HTTP 401 / 403, measured as
    /// NSURLError -1013 / -1102). The engine subscribes and hands the session to the live ingest, whose
    /// fetcher is a different client: headers on every request, four concurrent fetches at most, no
    /// AVFoundation user agent. Separate from the carriage signal because the evidence is different;
    /// a refusal is the origin's decision, not a verdict about what AVFoundation can demux.
    @Published private(set) var remoteHLSOriginRefused = false
    /// Set per load; arms both live-ingest fallbacks. The carriage watchdog itself starts at
    /// readyToPlay (a dead origin never reaches it), the refusal path fires before readiness.
    private var ingestFallbackArmed = false
    private var carriageWatchdogTask: Task<Void, Never>?
    /// Watchdog poll cadence. The pure `Watchdog`'s grace is expressed in ticks of this length, so the
    /// grace a probe verdict removes is reported in the same unit.
    static let carriageWatchdogTickSeconds = 0.5

    /// #293: what the playlist/PMT probe established about this load's carriage. The probe starts with
    /// the mount rather than at readyToPlay, so the verdict is usually already in when the watchdog arms
    /// and the reroute no longer waits out a grace whose conclusion is known.
    private var carriageProbeEvidence: RemoteHLSIngestFallback.CarriageEvidence = .pending
    private var carriageProbeTask: Task<Void, Never>?
    /// #296: cadence and ceiling of the wait that holds the probe's deferred segment-head read until
    /// readyToPlay. 20 s is well past the point where a mount that has not become ready is going to.
    static let carriageProbeReadinessTickSeconds = 0.05
    static let carriageProbeReadinessTicks = 400

    /// #334: budget for the bypass's readiness deadline, nil on every path that has its own terminal
    /// state (the loopback's live-reload watchdog, VOD). Set per load from `load(readinessDeadline:)`.
    private var readinessDeadlineSeconds: Double?
    private var readinessDeadlineTask: Task<Void, Never>?

    /// #35 (Sodalite) cold-DV-master startup-readiness gate. While the engine drives the bounded
    /// retry loop this is true, so a startup failure (`.failed` with any code, including a
    /// display-rejection) is NOT published: the gate polls `awaitStartupReadiness` and decides to
    /// reload the master, fall back to the media playlist, or give up. `lastSuppressedStartupFailure`
    /// stashes the message so the engine can surface a real terminal error if the gate exhausts
    /// every option (a timed-out silent 0-track park leaves it nil; the gate supplies a fallback).
    var startupReadinessGateActive: Bool = false
    private(set) var lastSuppressedStartupFailure: String?

    // MARK: - Seek landing state

    /// Monotonic seek counter; only the latest generation clears seekInFlight and publishes the landed time (abandoned seeks complete with finished==false).
    private var seekGeneration: UInt64 = 0

    /// Suppresses currentTime publishing while a seek is in flight; the loopback source lands seeks seconds after the call, so the observer would otherwise bounce the clock back through the pre-seek position (issue #37).
    private(set) var seekInFlight: Bool = false
    /// Set immediately before the latest seek completion publishes renderedTime. Deadline recovery
    /// uses this as authoritative presented-frame evidence when that publication wins the MainActor
    /// queue race against the resumed deadline continuation.
    private(set) var latestSeekRenderedTimePublished = false
    /// AE#629: a mount whose item has not landed its mount seek yet. Until the landing AVPlayer reads
    /// first the target, then the start of the segment it decodes up from (12.00 s under a 15.97 s
    /// revive on the harness). Published, that second reading rewinds the playhead, and a
    /// software-path rebuild raised in the window resumed there and replayed the gap. So neither
    /// reading is a landing: only the seek's own completion is, or the item playing, which it cannot
    /// do short of the target. A seek of the host's own takes the clock over from here as well.
    /// Round 5: not only an in-place swap. A VOD mount a host `load()` placed past the head has the
    /// same window, and there the rebuild resumed at 12.00 s once that load had returned. See
    /// `mountHoldsClock`.
    private var mountSeekPending = false

    // MARK: - Output

    /// AVPlayerLayer attached to the bound AetherPlayerView; reused across replaceCurrentItem swaps.
    let playerLayer: AVPlayerLayer

    let avPlayer: AVPlayer

    // MARK: - Private state

    private var playerItem: AVPlayerItem?
    /// AE#616: the item the latest `load` attached, for an output the engine hangs on it.
    var currentPlayerItem: AVPlayerItem? { playerItem }
    /// Applied immediately and replayed onto fresh items across internal reloads so Now Playing title/artwork survives audio-switch/background-reopen seams.
    private var pendingExternalMetadata: [AVMetadataItem] = []
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    /// One-shot guard; route capability check runs after first .playing, not readyToPlay -- early sampling false-positived the downmix warning on stereo-idle sinks (issue #24).
    private var didSampleSettledRoute = false
    /// Latched transport intent; the readyToPlay observer re-asserts it if play() was swallowed during a replaceCurrentItem swap (keepNativeHost reload: AVPlayer drops rate to 0 and parks at readyToPlay+paused forever).
    private var playIntent = false
    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    /// AE#440: the waiting REASON changes without `timeControlStatus` changing. A live join goes
    /// `waitingToPlay(EvaluatingBufferingRate)` -> `waitingToPlay(ToMinimizeStalls)` -> `playing`, and
    /// only the second of those is the hold the join lever may cut short, so keying it off the status
    /// observation alone leaves the decision to whether AVFoundation happens to republish the status.
    private var waitingReasonObservation: NSKeyValueObservation?
    private var seekableObservation: NSKeyValueObservation?
    /// Diagnostic: isReadyForDisplay is the only signal for first-frame-on-screen; t+ stamps localize the audio-leads-black-video gap.
    private var layerReadyObservation: NSKeyValueObservation?
    /// t+ reference for startup diagnostics; written on MainActor, read off-main from KVO -- diagnostic-only, a torn read is harmless.
    nonisolated(unsafe) private var loadStartTime = DispatchTime.now()
    private var notificationObservers: [NSObjectProtocol] = []
    private var itemDiagnostics: AVPlayerItemDiagnostics?
    private var retiringDiagnostics: [ObjectIdentifier: AVPlayerItemDiagnostics] = [:]
    private var counterGeneration = 0
    private var reportedIncompleteRetirement = false
    private let diagnosticPool: ItemDiagnosticReadPool
    private let diagnosticRead: AVPlayerItemDiagnostics.Read

    /// When true, AVPlayer's `failedToPlayToEndTime` (it gave up: rate 0, no more data) routes into the
    /// deferred-failure confirmation instead of being log-only. Set only on the lean remote-HLS live path,
    /// which has no loopback live-reopen / readiness watchdog to recover or surface a dead upstream. Reported
    /// live-IPTV death: segments started 404ing after the initial buffer, AVPlayer fired failedToPlayToEnd and
    /// parked at rate 0, but `item.status` stayed `readyToPlay`, so the `.failed` KVO never fired and the host
    /// never learned playback died. The loopback/VOD path keeps log-only (it owns its own reopen machinery).
    private var surfaceEndFailures = false

    /// Monotonic counter tags every load() invocation so multi-attempt sessions produce distinguishable log lines.
    private static var nextSessionID: Int = 0
    private var sessionID: Int = 0

    /// AE#446 round 4: which item this host currently holds. Bumped by every `load`/`swapItem`, so a
    /// caller that latches something about the item can tell when the item under it changed.
    var itemGeneration: Int { sessionID }

    // MARK: - Init

    #if os(tvOS) || os(iOS)
    /// Now-Playing session bound to THIS player (same rationale as
    /// AudioAVPlayerHost): the shared MPRemoteCommandCenter /
    /// MPNowPlayingInfoCenter aren't reliably bound to a bare AVPlayer, a
    /// background pause (rate 0) drops the app as active Now-Playing and the
    /// shared center stops receiving commands. Owning the session keeps
    /// ownership across pause; it also persists with the host across
    /// native->native reloads (issue #15), so MediaRemote registration
    /// survives the seam. Hosts register transport commands on
    /// `nowPlayingSession.remoteCommandCenter` and stage per-item metadata
    /// via `setNowPlayingInfo`; auto-publish merges the player-derived
    /// elapsed/rate/duration, so nobody writes the shared info center.
    ///
    /// nil unless the host opted in. The audio host can own its session
    /// unconditionally because it is always a bare AVPlayer; this player is
    /// also consumed by `AVPlayerViewController` hosts, where AVKit owns
    /// Now-Playing through private MediaRemote and WWDC22's guidance is not to
    /// bring a session of our own (the AudioAVPlayerHost comment quotes it).
    /// Claiming one there costs the host AVKit's card, its `externalMetadata`
    /// and its working transport commands.
    private(set) var nowPlayingSession: MPNowPlayingSession?
    #endif

    /// Per-item Now-Playing dictionary (identity keys + a force-decoded,
    /// @Sendable-wrapped MPMediaItemArtwork) replayed onto every new item so
    /// readiness-gate master reloads, media fallbacks, and in-place swaps
    /// keep the system card. Staged even when no session is owned, so a host
    /// that opts in on a later load does not lose what it set.
    private var pendingNowPlayingInfo: [String: Any] = [:]

    /// Whether this host owns a Now-Playing session (see `nowPlayingSession`).
    let ownsNowPlayingSession: Bool

    init(ownsNowPlayingSession: Bool = false,
         diagnosticPool: ItemDiagnosticReadPool = .shared,
         diagnosticRead: @escaping AVPlayerItemDiagnostics.Read = ItemDiagnosticSnapshot.read) {
        self.diagnosticPool = diagnosticPool
        self.diagnosticRead = diagnosticRead
        let player = AVPlayer()
        // Keep automaticallyWaitsToMinimizeStalling at default true: false caused permanent startup stall on 4K HEVC (rate dropped to 0 after asset.load and never resumed).
        self.avPlayer = player
        self.playerLayer = AVPlayerLayer(player: player)
        self.playerLayer.videoGravity = .resizeAspect
        self.ownsNowPlayingSession = ownsNowPlayingSession
        #if os(tvOS) || os(iOS)
        if ownsNowPlayingSession {
            let session = MPNowPlayingSession(players: [player])
            session.automaticallyPublishesNowPlayingInfo = true
            session.becomeActiveIfPossible(completion: { _ in })
            nowPlayingSession = session
        }
        #endif
    }

    /// Re-assert Now-Playing ownership. Mirrors `AudioAVPlayerHost`: a host preserved across a
    /// native->native reload never re-runs init, so without this the session that another app (or
    /// another engine path) took over in the meantime is never claimed back. No-op when no session
    /// is owned.
    func becomeActiveNowPlaying() {
        #if os(tvOS) || os(iOS)
        nowPlayingSession?.becomeActiveIfPossible(completion: { _ in })
        #endif
    }

    /// Stage (and immediately apply) the per-item system Now-Playing
    /// dictionary. Identity keys only, the auto-publishing session owns
    /// elapsed/rate/duration. Empty clears.
    func setNowPlayingInfo(_ info: [String: Any]) {
        pendingNowPlayingInfo = info
        #if os(tvOS) || os(iOS)
        // Only when this host owns the session. Writing item.nowPlayingInfo under an AVKit host
        // would feed AVKit's own Now-Playing publication a second, host-authored identity.
        guard ownsNowPlayingSession else { return }
        playerItem?.nowPlayingInfo = info.isEmpty ? nil : info
        #endif
    }

    // No deinit cleanup: under Swift 6 strict concurrency the deinit
    // of a `@MainActor` type is nonisolated and can't reach
    // main-isolated properties. Callers must call `tearDown()`
    // before dropping this host. `AetherEngine.stopInternal()` is
    // the centralised invocation point.

    // MARK: - Lifecycle

    /// AVURLAsset creation options for extra HTTP headers; nil when there are none, keeping the
    /// loopback path's default asset untouched. AVFoundation applies AVURLAssetHTTPHeaderFieldsKey
    /// to playlist and segment requests, which is what header-enforcing remote-HLS origins
    /// (IPTV / Stremio per-stream Referer / User-Agent / Authorization) need (#119).
    nonisolated static func assetCreationOptions(httpHeaders: [String: String]) -> [String: Any]? {
        httpHeaders.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": httpHeaders]
    }

    /// Everything a load establishes about the SESSION rather than about the item it opens (#440 round 5).
    ///
    /// It exists because an in-place swap replaces the item under a session that stays whole (#443), and
    /// passing these per call site is what failed: six swap sites called `load` with the item arguments
    /// only, so every one of them silently re-declared the session as VOD, header-less, and buffered at
    /// the loopback default. The reporter found it from the outside, as a live rejoin that produced no
    /// AE#440 decision at all; the same silence also handed the AE#287 premature-end recovery an
    /// `isLive: false` on a live session that had just closed a window with ENDLIST.
    ///
    /// `swapItem` is the fix rather than a longer argument list: a swap has no contract argument to get
    /// wrong, and a genuinely new session states its own.
    struct SessionLoadContract: Sendable, Equatable {
        /// Whether the session is live. Gates the AE#440 join override and the AE#287 premature-end
        /// recovery, which only makes sense for a presentation with an advertised end.
        var isLive: Bool = false
        /// AE#440: may the join's stall-avoidance hold be cut short once the cushion is proven. Live-only,
        /// and armed per load.
        var liveJoinStartsImmediately: Bool = false
        /// [MovieClaw patch P2] The same one-shot for a VOD start.
        var vodStartsImmediately: Bool = false
        /// 4 s matches the loopback segment cadence; the remote-HLS bypass passes 0 (system adaptive),
        /// where 4 s forced a 3-4 s black screen on bandwidth-limited Jellyfin live transcodes.
        var forwardBufferDuration: Double = 4.0
        /// The lean remote-HLS path has no live-reopen or readiness watchdog, so AVPlayer's "gave up"
        /// signal has to surface a dead upstream instead of being swallowed as a recoverable stall.
        var surfaceEndFailures: Bool = false
        /// Sent with every asset and segment request. The bypass path carries the origin's auth here, so
        /// a swap that dropped them would re-open the same URL unauthenticated.
        var httpHeaders: [String: String] = [:]
        /// #168 / #293: arm the carriage probe and the ingest reroute for a remote origin.
        var armIngestFallback: Bool = false
        /// #334: the ceiling on silence for a path with no other readiness watchdog.
        var readinessDeadline: Double?
        /// AE#520: this session stream-copies an EAC3 bitstream that carries JOC. HDMI passthrough
        /// then tunnels it through a 2-channel MAT carrier, so the route's channel count is not a
        /// statement about the audio and the surround-downmix warning below must not read it as one.
        var audioIsAtmosStreamCopy: Bool = false
        /// Read the item's audio tracks back into `detectedAudioTracks`. Only the remote-HLS bypass needs
        /// them; the loopback's probe already listed its audio, and the reads are XPC round trips.
        var readsBackAudioTracks: Bool = false
    }

    /// AE#446 round 5: a fresh item is about to attach, invoked before anything can fetch a playlist
    /// for it.
    ///
    /// A live item's zero is the first segment ITS playlist listed, so the axis belongs to the item,
    /// and the engine has to know which item a served playlist describes. Every attach passes through
    /// `load` (`swapItem` delegates to it), so this hook is the one place that knows, and a swap path
    /// added later inherits it without anyone remembering to arm at the call site.
    var onWillAttachItem: (@MainActor () -> Void)?

    /// Replace the item under a session that survives the swap, keeping the contract that session was
    /// loaded under (#440 round 5).
    ///
    /// Every in-place swap is this: the #35 readiness gate reloading a master, the #98 media fallback,
    /// the #65 stalled-consumer reload, the #446 rejoin, an AirPlay hop. None of them starts a new
    /// session, so none of them gets to re-decide whether the session is live or what headers it sends.
    func swapItem(url: URL, startPosition: Double?, skipInitialSeek: Bool = false) {
        load(url: url, startPosition: startPosition, skipInitialSeek: skipInitialSeek,
             inPlaceSwap: true, contract: sessionContract)
    }

    /// Load the loopback HLS-fMP4 URL into AVPlayer. DisplayCriteriaController.apply must run first so the HDR pipeline is configured before the first segment fetch.
    /// `inPlaceSwap`: atomic same-content item swap for the #93 recovery reload. The default
    /// teardown pauses and drops the current item to nil before the new one exists; during PiP
    /// that nil-item gap invalidates AVKit's content source (the PiP window was dismissed ~16 s
    /// after an in-PiP recovery reload) and the pause bounces transport for nothing. The swap
    /// keeps transport intent, clocks and the old item alive until replaceCurrentItem hands
    /// AVPlayer the fresh one.
    func load(url: URL, startPosition: Double?, perFrameHDR: Bool = true, skipInitialSeek: Bool = false,
              inPlaceSwap: Bool = false, contract: SessionLoadContract) {
        let outgoingDiagnostics = inPlaceSwap ? itemDiagnostics : nil
        unloadCurrentItem(inPlaceSwap: inPlaceSwap)

        self.sessionContract = contract
        mountedStartPosition = skipInitialSeek ? nil : (startPosition ?? 0)
        mountSeekPending = Self.mountHoldsClock(inPlaceSwap: inPlaceSwap, skipInitialSeek: skipInitialSeek,
                                                startPosition: startPosition, isLive: contract.isLive)
        // A swap keeps the outgoing item's clock, which already reads the place it holds. A fresh
        // mount has nothing there yet, so it states the place it is mounted at until the landing.
        if mountSeekPending, !inPlaceSwap, let startPosition {
            currentTime = startPosition
            renderedTime = startPosition
        }
        let forwardBufferDuration = contract.forwardBufferDuration
        let httpHeaders = contract.httpHeaders
        let armIngestFallback = contract.armIngestFallback
        self.surfaceEndFailures = contract.surfaceEndFailures
        self.ingestFallbackArmed = armIngestFallback
        self.readinessDeadlineSeconds = contract.readinessDeadline
        self.isLiveSession = contract.isLive
        // AE#440: per load, and only ever armed for a live session. The player is reused across loads,
        // so an override left armed from a live zap would meet the next VOD title's cold start.
        self.liveJoinStartsImmediately = (contract.isLive && contract.liveJoinStartsImmediately)
            || (!contract.isLive && contract.vodStartsImmediately)   // [MovieClaw patch P2]
        self.liveJoinImmediateStartSpent = false
        self.liveJoinImmediateStartProbeInFlight = false
        self.liveJoinThinBufferLogged = false
        self.liveJoinNoDecisionLogged = false
        self.liveJoinNotReadyLogged = false
        self.liveJoinNotReadyAskedAgain = false
        // AE#440 round 4: both of these are per LOAD, and the host is reused across loads on the
        // keepNativeHost path. Left standing, the second live join of a reused host would arm no witness
        // at all and read the previous join's spend reason.
        self.liveJoinHoldWitnessStarted = false
        self.liveJoinImmediateStartCutShort = false
        Self.nextSessionID += 1
        sessionID = Self.nextSessionID
        let sid = sessionID
        // AE#446 round 5: before the item exists, so the first playlist it fetches is recorded against
        // it rather than against the one it replaces.
        onWillAttachItem?()
        let loadStart = DispatchTime.now()
        loadStartTime = loadStart

        EngineLog.emit("[NativeAVPlayerHost] #\(sid) load url=\(url.absoluteString) startPos=\(startPosition.map { String(format: "%.2fs", $0) } ?? "nil") headers=\(httpHeaders.isEmpty ? "none" : "\(httpHeaders.count)")", category: .engine)

        // First frame on screen, published as `isVideoReadyForDisplay` and stamped for the
        // audio-leads-black-video gap (see `layerReadyObservation`).
        //
        // The install-time value is logged separately rather than taken through `.initial`, and it
        // is deliberately not published: on a reused host the layer still reads true here, for the
        // item this load is replacing. AVFoundation clears it ~40 ms later and raises it again for
        // the new item, so only CHANGES observed from here on describe this session's picture
        // (`unloadCurrentItem` has already published false).
        EngineLog.emit(
            "[NativeAVPlayerHost] #\(sid) layer.isReadyForDisplay=\(playerLayer.isReadyForDisplay) t+0.00s (carried in from the previous item when true)",
            category: .engine
        )
        layerReadyObservation = playerLayer.observe(
            \.isReadyForDisplay, options: [.new]
        ) { [weak self] layer, change in
            let ready = change.newValue ?? layer.isReadyForDisplay
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - loadStart.uptimeNanoseconds) / 1_000_000_000
            EngineLog.emit(
                "[NativeAVPlayerHost] #\(sid) layer.isReadyForDisplay=\(ready) t+\(String(format: "%.2f", elapsed))s",
                category: .engine
            )
            // AE#158: the handover leaves the outgoing item on this layer through the load gap, so it
            // keeps producing changes past the false unloadCurrentItem published. Without the session
            // guard the item observers carry, the previous episode's picture reads as the successor's
            // first frame.
            Task { @MainActor in
                guard let self, self.sessionID == sid else { return }
                self.isVideoReadyForDisplay = ready
            }
        }

        let asset = AVURLAsset(url: url, options: Self.assetCreationOptions(httpHeaders: httpHeaders))
        let item = AVPlayerItem(asset: asset)
        AudioRatePolicy.apply(to: item)
        // 4s default matches loopback HLS segment cadence; raising it for live makes AVPlayer race to the edge and stall at the transcode warm-up gap.
        // Remote-HLS passes 0 (system adaptive): 4s forced a 3-4s black screen on bandwidth-limited Jellyfin live transcodes.
        item.preferredForwardBufferDuration = forwardBufferDuration

        // Enables per-frame HDR10+ / DV RPU metadata; without it DV sources show in HDR10 mode (DrHurt: Philips TV stayed in HDR mode for P8 MKVs).
        // Set false on SDR-fallback paths -- the per-frame metadata pipeline is suspected of ~3 MB/sec RSS growth on long DV 8.1 sessions.
        item.appliesPerFrameHDRDisplayMetadata = perFrameHDR
        // Apply before replaceCurrentItem (documented safe order; setting after races AVPlayer's track-load). externalMetadata is unavailable on macOS.
        #if !os(macOS)
        if !pendingExternalMetadata.isEmpty {
            item.externalMetadata = pendingExternalMetadata
        }
        #endif
        #if os(tvOS) || os(iOS)
        // Replay staged Now-Playing identity onto the fresh item (gate
        // reloads / media fallback / in-place swaps keep the system card).
        // Owned sessions only: see setNowPlayingInfo.
        if ownsNowPlayingSession {
            item.nowPlayingInfo = pendingNowPlayingInfo.isEmpty ? nil : pendingNowPlayingInfo
        }
        #endif
        // #293: run the carriage probe alongside the mount. Nothing is serialized in front of first
        // frame; a healthy stream's watchdog disarms and cancels it, an unjudgeable one has its verdict
        // ready by the time the watchdog arms.
        if armIngestFallback {
            startCarriageProbe(asset: asset, url: url, httpHeaders: httpHeaders)
        }
        playerItem = item
        let diagnostics = AVPlayerItemDiagnostics(item: item, pool: diagnosticPool, read: diagnosticRead)
        itemDiagnostics = diagnostics
        diagnostics.onSnapshot = { [weak self, weak diagnostics] snapshot, request in
            guard let self, let diagnostics, self.sessionID == sid,
                  self.itemDiagnostics === diagnostics else { return }
            self.consumeDiagnostics(snapshot, request: request, reader: diagnostics, sid: sid)
        }
        failure = nil
        pendingDisplayRejection = nil
        pendingSoftwarePathEscalation = nil
        lastSuppressedStartupFailure = nil
        isReady = false
        seekableEnd = 0
        // AE#454 round 2: both ends, or the mirror is a mixture. Only the end was reset here, so after
        // an in-place swap `seekableStart` still carried the RETIRED item's window while `seekableEnd`
        // already read the fresh item's. Anything reading the pair across a hand-off then measures one
        // item against the other; the live axis offset is a difference between exactly those two, and
        // it collapses to 0 on the reading that matters (AE#454 round 2, reported from a device).
        seekableStart = 0
        // #334: the bypass's ceiling on silence. Started with the mount rather than at readyToPlay,
        // because the session it exists for is exactly the one that never gets there.
        if let budget = contract.readinessDeadline {
            startReadinessDeadline(item: item, budgetSeconds: budget)
        }

        // #134: mirror seekableTimeRanges instead of reading it per call. The callback runs on
        // the item's queue where the re-read is a harmless off-main XPC; live playlist refreshes
        // keep it current, including while paused.
        seekableObservation = item.observe(\.seekableTimeRanges, options: [.initial, .new]) { [weak self] item, _ in
            let end = Self.seekableEnd(from: item.seekableTimeRanges)
            let start = Self.seekableStart(from: item.seekableTimeRanges)
            Task { @MainActor in
                // AE#454 round 2: a reading belongs to the item it was taken from. The observation is
                // replaced on the next attach, but a notification already in flight is not, and its
                // hop to the main actor can land after the swap; the same `sid == sessionID` guard the
                // end-of-media path has carried since #15.
                guard let self, self.sessionID == sid else { return }
                self.seekableEnd = end
                self.seekableStart = start
            }
        }

        // KVO fires on AVPlayerItem's queue; Task round-trips to MainActor.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let statusStr: String
            switch item.status {
            case .unknown:     statusStr = "unknown"
            case .readyToPlay: statusStr = "readyToPlay"
            case .failed:      statusStr = "failed"
            @unknown default:  statusStr = "@unknown"
            }
            let nsErr = item.error as NSError?
            let errSuffix = nsErr.map { " err=\($0.domain)/\($0.code) '\($0.localizedDescription)'" } ?? ""
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.status=\(statusStr)\(errSuffix)", category: .engine)

            // On .failed: dump track FourCCs (hev1 vs hvc1 rejection, dvhe vs dvh1) and full NSError chain.
            // On .readyToPlay: dump audio CMAudioFormatDescription (channel layout tag diagnoses FLAC-bridge downmix vs route downmix).
            if item.status == .failed {
                if let nsErr = nsErr,
                   let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.error.underlying=\(underlying.domain)/\(underlying.code) '\(underlying.localizedDescription)'", category: .engine)
                }
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == sid else { return }
                    // The KVO callback may be running inside AVFoundation notification delivery.
                    // It must unwind before diagnostic getters enter the native stack again.
                    self.itemDiagnostics?.request(.failure)
                }
            } else if item.status == .readyToPlay {
                // HLS: asset.tracks is empty; dump item.tracks for audio codec/layout. Route not warned yet: stereo-idle sinks (Continuous Audio off) read ch=2 until first .playing (issue #24).
                Task { @MainActor in
                    await Self.dumpPlayerItemTracks(item, sid: sid)
                    Self.dumpAudioRoute(sid: sid, phase: "readyToPlay, route may still be negotiating")
                }
            }

            Task { @MainActor in
                guard let self, self.sessionID == sid else { return }
                switch item.status {
                case .readyToPlay:
                    self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                    self.isReady = true
                    // Re-assert play() if the replaceCurrentItem swap swallowed it (playIntent latch).
                    if self.playIntent, self.avPlayer.timeControlStatus == .paused {
                        EngineLog.emit(
                            "[NativeAVPlayerHost] #\(self.sessionID) readyToPlay with play intent "
                            + "but player parked (swallowed play() during item swap); re-issuing play()",
                            category: .engine
                        )
                        self.avPlayer.play()
                    }
                    if self.timeControlStatus == .playing {
                        // Audit NAT-103: a carried `.playing` that never changes status on its way to
                        // motion is this item's roll from here, as for the AE#440 one-shot.
                        self.hasEverPlayed = true
                        self.mountSeekPending = false
                        self.startLiveJoinImmediatelyIfHolding(waitingReason: "-")
                    } else if self.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                        // AE#684: a hold refused for an item that could not play yet is asked again
                        // now that it can, on the playhead the item actually starts from.
                        self.startLiveJoinImmediatelyIfHolding(
                            waitingReason: self.avPlayer.reasonForWaitingToPlay?.rawValue ?? "-")
                    }
                    // #168: publish the item's real dynamic range for the probe-free remote-HLS badge.
                    await self.publishDetectedVideoFormat(from: item)
                    await self.publishDetectedAudioTracks(from: item)
                    guard self.sessionID == sid else { return }
                    // #168 follow-up: watch for an advertised video rendition that never builds a track
                    // (HEVC-in-MPEG-TS carriage); anchored at readyToPlay so dead origins never arm it.
                    if self.ingestFallbackArmed, self.carriageWatchdogTask == nil {
                        self.startVideoCarriageWatchdog(item: item)
                    }
                case .failed:
                    let desc = item.error?.localizedDescription ?? "AVPlayerItem failed (no description)"
                    self.handleItemFailed(desc, item: item)
                default:
                    break
                }
            }
        }

        rateObservation = avPlayer.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate = player.rate
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) rate=\(rate)", category: .engine)
            Task { @MainActor in
                guard let self, self.sessionID == sid else { return }
                self.rate = rate
            }
        }

        // timeControlStatus + reasonForWaitingToPlay diagnose "spinner forever" -- reason surfaces the exact stall cause.
        // AE#440: the reason moves inside a single `waitingToPlayAtSpecifiedRate` stretch, so this is a
        // separate edge from the one below. It carries no diagnostics and no state: the lever logs its
        // own outcome, and everything else here keys on the status.
        waitingReasonObservation = avPlayer.observe(\.reasonForWaitingToPlay, options: [.new]) { [weak self] player, _ in
            guard let reason = player.reasonForWaitingToPlay?.rawValue else { return }
            Task { @MainActor in
                self?.startLiveJoinImmediatelyIfHolding(waitingReason: reason)
            }
        }
        timeControlObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            let statusStr: String
            switch status {
            case .paused:                          statusStr = "paused"
            case .waitingToPlayAtSpecifiedRate:    statusStr = "waitingToPlay"
            case .playing:                         statusStr = "playing"
            @unknown default:                      statusStr = "@unknown"
            }
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "-"
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - (self?.loadStartTime ?? DispatchTime.now()).uptimeNanoseconds) / 1_000_000_000
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) timeControlStatus=\(statusStr) reason=\(reason) t+\(String(format: "%.2f", elapsed))s", category: .engine)
            Task { @MainActor in
                guard let self, self.sessionID == sid else { return }
                // AE#287: swallow the pause AVPlayer takes while a premature-end recovery re-seeks.
                if status == .paused, self.prematureEndRecoveryInFlight { return }
                self.timeControlStatus = status
                self.startLiveJoinImmediatelyIfHolding(waitingReason: reason)
                // First .playing: re-sample route after 2.5s settle -- AVKit only negotiates HDMI format on playback start (issue #24).
                // Audit NAT-103: an in-place swap reuses a player that is still `.playing`, and that status
                // reaches the fresh item before it is ready. Taken as a roll it released the AE#629 hold
                // before the mount seek landed and latched #50's "has played" for an item that had not.
                if status == .playing,
                   Self.playingIsThisItemsRoll(itemIsReadyToPlay: self.playerItem?.status == .readyToPlay) {
                    self.hasEverPlayed = true
                    self.mountSeekPending = false
                }
                if status == .playing, !self.didSampleSettledRoute {
                    self.didSampleSettledRoute = true
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        guard let self = self, let item = self.playerItem else { return }
                        Self.dumpAudioRoute(sid: sid, phase: "settled")
                        await Self.warnIfFLACSurroundExceedsRoute(item, sid: sid)
                        await Self.warnIfEAC3SurroundOnStereoRoute(
                            item, sid: sid, isAtmosStreamCopy: contract.audioIsAtmosStreamCopy)
                        // #168: the video track can be absent from item.tracks at readyToPlay for HLS;
                        // re-read once playing so the remote-HLS badge settles on the real dynamic range.
                        await self.publishDetectedVideoFormat(from: item)
                        await self.publishDetectedAudioTracks(from: item)
                    }
                }
            }
        }

        // errorLog: transient HLS-level errors (404, manifest parse failures, ATS, codec mismatch) without flipping .failed -- gold mine for "AVPlayer just sits there" diagnostics.
        let errLogObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            // Delivered on .main (queue: .main above), so assert MainActor to reach @MainActor state.
            MainActor.assumeIsolated {
                guard let self, self.sessionID == sid else { return }
                self.itemDiagnostics?.request(.error)
            }
        }
        notificationObservers.append(errLogObs)

        // Cap accessLog at 5 entries (AVPlayer pumps hundreds on long streams); confirms AVPlayer reached the segment-fetch stage.
        let accessLogObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newAccessLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            // Delivered on .main (queue: .main above), so assert MainActor to reach @MainActor state.
            MainActor.assumeIsolated {
                guard let self, self.sessionID == sid else { return }
                self.itemDiagnostics?.request(.access)
            }
        }
        notificationObservers.append(accessLogObs)

        let failedToEndObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let err = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            let suffix = err.map { " \($0.domain)/\($0.code) '\($0.localizedDescription)'" } ?? ""
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) failedToPlayToEndTime\(suffix)", category: .engine)
            // Capture only Sendable values (sid: Int, desc: String) across the actor hop; reach the item via
            // self.playerItem on the main actor (the notification/item are non-Sendable). The sid==sessionID
            // guard rejects a stale notification from a since-replaced session.
            let desc = err?.localizedDescription
                ?? "The live stream stopped (the source could not continue)."
            // Delivered on .main (queue: .main above), so assert MainActor to reach @MainActor state.
            MainActor.assumeIsolated {
                guard let self = self, self.sessionID == sid,
                      let current = self.playerItem else { return }
                if self.surfaceEndFailures {
                    // AVPlayer gave up on this item (rate 0, no more segments) and `.failed` may never fire
                    // (item.status can stay readyToPlay). Route into the same deferred confirmation as a .failed
                    // KVO: a transient that resumes within the window self-clears; a dead upstream (live IPTV
                    // token expiry, persistent segment 404) surfaces .error so the host can retune / show it.
                    self.handleItemFailed(desc, item: current)
                } else if Self.shouldCountEndFailureForRevive(
                    surfaceEndFailures: false, hasEverPlayed: self.hasEverPlayed) {
                    // #93 round 3: loopback path. Count the death for the engine's revive
                    // escalation; a startup death (never played) stays with the startup watchdogs.
                    self.endFailureCount += 1
                }
            }
        }
        notificationObservers.append(failedToEndObs)

        let stalledObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) playbackStalled", category: .engine)
            // #93 residual: the engine opens its spurious-pause recovery window on every stall.
            // Delivered on .main (queue: .main above), so assert MainActor to reach @MainActor state.
            MainActor.assumeIsolated {
                self?.stallCount += 1
            }
        }
        notificationObservers.append(stalledObs)

        let didEndObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) didPlayToEndTime", category: .engine)
            Task { @MainActor in
                guard let self, self.sessionID == sid else { return }
                // AE#287: AVPlayer ends a VOD the moment its video renderer runs dry, even with the
                // audio-only tail still ahead. Recover before `.ended` latches; it is terminal.
                if await self.recoverFromPrematureEnd() { return }
                guard self.sessionID == sid else { return }
                self.didReachEnd = true
            }
        }
        notificationObservers.append(didEndObs)

        // 100ms periodic observer drives scrub bar; Task wrapper satisfies Sendable check.
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let value = time.seconds.isFinite ? time.seconds : 0
            Task { @MainActor in
                guard let self, self.sessionID == sid else { return }
                if self.mountSeekPending { return }
                // renderedTime tracks the parked on-screen frame mid-seek (issue #49).
                self.renderedTime = value
                // seekInFlight suppresses currentTime: AVPlayer still reports pre-seek clock until physical landing (issue #37).
                guard !self.seekInFlight else { return }
                self.currentTime = value
            }
        }

        avPlayer.replaceCurrentItem(with: item)
        // Fold cached counters without a native read. The final reconciliation is requested only
        // after detach, and never holds up the handover.
        if let outgoingDiagnostics {
            retireItemCounters(outgoingDiagnostics)
        }

        // Explicitly load each key separately: AVPlayerItem(asset:)+KVO was observed stuck in .unknown (build-123), and separate awaits let DrHurt's "1 success, 3 failures" pattern identify which key -1008 hits.
        let urlStr = url.absoluteString
        Task { @MainActor in
            for key in ["isPlayable", "tracks", "duration"] {
                do {
                    // Use the value returned by the async load instead of re-reading the deprecated
                    // synchronous accessor (asset.isPlayable / .tracks / .duration).
                    let detail: String
                    switch key {
                    case "isPlayable": detail = "value=\(try await asset.load(.isPlayable))"
                    case "tracks":     detail = "count=\(try await asset.load(.tracks).count)"
                    case "duration":   detail = "seconds=\(try await asset.load(.duration).seconds)"
                    default: continue
                    }
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.load(\(key)) ok url=\(urlStr) \(detail)", category: .engine)
                } catch {
                    let nsErr = error as NSError
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.load(\(key)) failed: \(nsErr.domain)/\(nsErr.code) '\(nsErr.localizedDescription)' url=\(urlStr)", category: .engine)
                    if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
                        EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.load(\(key)) underlying=\(underlying.domain)/\(underlying.code) '\(underlying.localizedDescription)'", category: .engine)
                    }
                    // Dump partial track info even on failure: DrHurt's -1008 stall still surfaces the FourCC (hev1 vs hvc1, dvhe vs dvh1).
                    await Self.dumpAssetTracks(asset, sid: sid, reason: "asset.load(\(key)).failed")
                    return
                }
            }
        }

        // Explicit seek prevents AVPlayer from defaulting to the EVENT-playlist live edge. Remote-HLS and loopback live REJOINS set skipInitialSeek (backlog-start seek was the prime suspect for permanent waitingToPlay on rejoin; see LiveReloadPolicy.skipInitialSeek).
        if !skipInitialSeek {
            // AE#509: name the seek and the axis it is spent on. This is the only unconditional
            // reposition of a fresh item, it happens before the item can answer for itself, and
            // nothing logged it: a session parked at an unreachable position looked exactly like a
            // session that placed nothing. `startPosition` is an ITEM-axis anchor, while a live
            // host only ever sees the published clock (item + shift), so a live anchor that is not
            // nil is the one shape where those two axes can be confused.
            EngineLog.emit(
                "[NativeAVPlayerHost] #\(sid) mount seek: item axis "
                + String(format: "%.2f", startPosition ?? 0) + "s "
                + "(startPosition=\(startPosition.map { String(format: "%.2f", $0) } ?? "nil"), "
                + "live=\(contract.isLive))",
                category: .engine)
            // Load-time seek (not a user scrub): no seekInFlight needed; the async seek(to:) carries #37/#38 semantics for user seeks.
            avPlayer.seek(to: CMTime(seconds: startPosition ?? 0, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard finished else { return }
                Task { @MainActor in
                    guard let self, self.sessionID == sid else { return }
                    self.mountSeekPending = false
                }
            }
        }
    }

    func tearDown() {
        unloadCurrentItem()
    }

    /// Retire the outgoing session before the engine subscribes for its successor, without
    /// detaching the item or layer and without bouncing transport. The #93 same-content recovery
    /// keeps its clock through `load(inPlaceSwap:)`; an episode change must not replay the previous
    /// episode's EOF, readiness or position into the next session's subscribers.
    func prepareForItemHandover() {
        unloadCurrentItem(inPlaceSwap: true)
        resetDiagnosticCounters()
        currentTime = 0
        renderedTime = 0
        duration = 0
        rate = 0
        timeControlStatus = .paused
        seekableEnd = 0
    }

    // MARK: - Failure handling

    /// Shared deferred-failure resolution: after the confirm window, surface a terminal failure only if the
    /// player neither resumed playing nor advanced the clock past `threshold`. Pure so the `.failed` KVO and
    /// the live `failedToPlayToEndTime` routing share one recovery contract (a self-healing transient that
    /// resumes within the window must never surface, a frozen player must).
    nonisolated static func shouldSurfaceDeferredFailure(
        isPlaying: Bool, clockAtFailure: Double, clockNow: Double, threshold: Double = 0.5
    ) -> Bool {
        if isPlaying { return false }
        if clockNow > clockAtFailure + threshold { return false }
        return true
    }

    /// #93 round 3, pure decision: does a `failedToPlayToEndTime` count toward the loopback
    /// revive escalation? The lean remote-live path (`surfaceEndFailures`) keeps its own
    /// deferred-failure contract; a startup death before the first frame stays with the
    /// startup watchdogs.
    nonisolated static func shouldCountEndFailureForRevive(
        surfaceEndFailures: Bool, hasEverPlayed: Bool
    ) -> Bool {
        !surfaceEndFailures && hasEverPlayed
    }

    /// #50: AVPlayer fires .failed for self-healing transients (loopback 404, AVIOReader reconnect) while playback advances uninterrupted (rrgomes: tcs=playing at .failed).
    /// Discriminates on hasEverPlayed, not instantaneous timeControlStatus: .failed and timeControlStatus KVOs are unsynchronized (426b45c: still published terminal failure at 27.3s while AVPlayer played smoothly).
    /// Before first .playing: surface promptly (genuine startup failure). After: defer 5s and confirm -- clear if .playing or clock advanced, surface if both stopped.
    @MainActor
    /// AE#561: offer a failure to the engine's own decoder before making it terminal. True when the
    /// offer was made, in which case nothing is surfaced here and the engine rebuilds the session.
    private func offerToSoftwarePath(_ desc: String, item: AVPlayerItem, position: Double) -> Bool {
        let nsError = item.error as NSError?
        // [MovieClaw P24] 「无法解码」外层是 AVFoundation 域、判决在底层 CoreMedia：一样交给引擎自己的解码器
        let domain = SoftwarePathEscalation.effectiveErrorDomain(nsError)
        guard SoftwarePathEscalation.shouldEscalate(
            errorDomain: domain,
            availability: softwarePathAvailability?()
        ) else { return false }
        let at = position.isFinite ? String(format: "%.2f", position) + "s" : "an unreadable position"
        EngineLog.emit(
            "[NativeAVPlayerHost] #\(sessionID) #561 AVPlayer refused the media "
            + "(\(nsError?.domain ?? "?")/\(nsError?.code ?? 0)) at \(at); handing the session to the "
            + "engine's own decoder instead of surfacing: \(desc)",
            category: .engine
        )
        pendingSoftwarePathEscalation = SoftwarePathEscalation.Request(
            domain: domain ?? "",
            code: nsError?.code ?? 0,
            message: desc,
            positionSeconds: position.isFinite ? max(0, position) : 0
        )
        return true
    }

    private func handleItemFailed(_ desc: String, item: AVPlayerItem) {
        // Ignore a late `.failed` KVO from an item we have already replaced.
        guard playerItem === item else { return }

        failureConfirmToken &+= 1
        let token = failureConfirmToken

        // Startup failure: never reached .playing, so nothing to recover here. A display-rejection
        // of the served master (#98) is instead handed to the engine, which reloads the media
        // playlist; only a non-rejection startup failure surfaces immediately.
        if !hasEverPlayed {
            let code = (item.error as NSError?)?.code
            // #35: while the cold-DV-master readiness gate drives the retry loop it owns ALL startup
            // failures (a display rejection AND the -11819 "Cannot Complete Action" cold handshake).
            // Stash the message and stay silent; the gate polls item state and reloads the master /
            // falls back to media / surfaces a terminal error itself. Publishing here would race it.
            if startupReadinessGateActive {
                lastSuppressedStartupFailure = desc
                EngineLog.emit(
                    "[NativeAVPlayerHost] #\(sessionID) startup .failed (code=\(code.map(String.init) ?? "?")) "
                    + "held by the readiness gate: \(desc)",
                    category: .engine)
                return
            }
            // AE#363: the origin refused this client. Publishing a terminal failure here ends a live
            // session the engine's own fetcher may well be allowed to serve, so signal the reroute
            // instead of surfacing, the same way a master rejection is handed to the engine below.
            if let nsError = item.error as NSError?,
               RemoteHLSIngestFallback.shouldRerouteOnOriginRefusal(
                   domain: nsError.domain, code: nsError.code,
                   armed: ingestFallbackArmed, alreadyRerouted: remoteHLSOriginRefused) {
                EngineLog.emit(
                    "[NativeAVPlayerHost] #\(sessionID) origin refused the native mount "
                    + "(\(nsError.domain)/\(nsError.code)); handing the session to the live ingest (AE#363)",
                    category: .engine)
                remoteHLSOriginRefused = true
                return
            }
            if let code, MasterFallbackDecision.isMasterRejectionCode(code) {
                EngineLog.emit(
                    "[NativeAVPlayerHost] #\(sessionID) startup .failed is a master rejection "
                    + "(code=\(code)); signalling engine for media fallback instead of surfacing",
                    category: .engine)
                pendingDisplayRejection = DisplayRejection(code: code,
                                                           message: desc,
                                                           domain: (item.error as NSError?)?.domain)
                return
            }
            // AE#561: a startup failure on the media itself (a segment Apple's parser refuses) is
            // not the end of the source, only of this consumer's opinion of it.
            if offerToSoftwarePath(desc, item: item, position: renderedTime) { return }
            failure = Self.itemFailureInfo(desc: desc, itemError: item.error,
                                           relayRefusalCode: upstreamTrustRefusal?())
            return
        }

        let clockAtFailure = renderedTime
        EngineLog.emit(
            "[NativeAVPlayerHost] #\(sessionID) item.status=.failed after playback established "
            + "(tcs=\(avPlayer.timeControlStatus.rawValue) clock=\(String(format: "%.2f", clockAtFailure))); "
            + "deferring possibly-spurious failure: \(desc)",
            category: .engine
        )
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self = self,
                  self.failureConfirmToken == token,
                  self.playerItem === item else { return }
            let advanced = self.renderedTime > clockAtFailure + 0.5
            if Self.shouldSurfaceDeferredFailure(
                isPlaying: self.avPlayer.timeControlStatus == .playing,
                clockAtFailure: clockAtFailure,
                clockNow: self.renderedTime
            ) {
                EngineLog.emit(
                    "[NativeAVPlayerHost] #\(self.sessionID) deferred failure confirmed: player stopped "
                    + "(tcs=\(self.avPlayer.timeControlStatus.rawValue) "
                    + "clock=\(String(format: "%.2f", self.renderedTime)))",
                    category: .engine
                )
                if self.offerToSoftwarePath(desc, item: item, position: self.renderedTime) { return }
                self.failure = Self.itemFailureInfo(desc: desc, itemError: item.error,
                                                    relayRefusalCode: self.upstreamTrustRefusal?())
            } else {
                EngineLog.emit(
                    "[NativeAVPlayerHost] #\(self.sessionID) deferred failure cleared: player recovered "
                    + "(tcs=\(self.avPlayer.timeControlStatus.rawValue) "
                    + "clock=\(String(format: "%.2f", self.renderedTime)) advanced=\(advanced))",
                    category: .engine
                )
            }
        }
    }

    /// #35: poll the current item after `play()` until it becomes playable, dies, or the settle
    /// window elapses. `.ready` as soon as the item reports a non-zero presentation size or actually
    /// starts playing (`hasEverPlayed`); `.dead` on `item.status == .failed`; `.timedOut` if neither
    /// happens within `timeoutSeconds` (the silent 0-track park, `AVPlayerWaitingWithNoItemToPlay`).
    /// Bounded by construction, so the engine's gate loop can never spin forever. `item.status` only
    /// advances once AVPlayer is told to play, so the caller must `play()` before awaiting.
    func awaitStartupReadiness(timeoutSeconds: Double) async -> StartupReadiness {
        let tickMs: UInt64 = 100
        let ticks = max(1, Int((timeoutSeconds * 1000).rounded()) / Int(tickMs))
        for _ in 0..<ticks {
            guard let item = playerItem else { return .dead }
            if hasEverPlayed || item.presentationSize != .zero { return .ready }
            if item.status == .failed { return .dead }
            try? await Task.sleep(nanoseconds: tickMs * 1_000_000)
        }
        if let item = playerItem, hasEverPlayed || item.presentationSize != .zero { return .ready }
        // #169: distinguish an unserved first segment (no media loaded -> still producing over a slow
        // link, keep waiting) from a served-but-0-tracks master (the cold DV/HDCP decode park).
        let loaded = playerItem.map { Self.hasLoadedMedia($0.loadedTimeRanges) } ?? false
        return StartupReadinessGate.timeoutOutcome(hasLoadedMedia: loaded)
    }

    /// True when the item has any positive-duration loaded range: real media has been served (vs a fresh
    /// item whose first segment is still being produced). Drives the #169 awaitingData split.
    nonisolated static func hasLoadedMedia(_ loadedTimeRanges: [NSValue]) -> Bool {
        for value in loadedTimeRanges {
            let d = value.timeRangeValue.duration.seconds
            if d.isFinite && d > 0 { return true }
        }
        return false
    }

    // MARK: - Playback control

    var isEffectivelyPlaying: Bool { avPlayer.timeControlStatus != .paused }
    var liveTimeControlStatus: AVPlayer.TimeControlStatus { avPlayer.timeControlStatus }

    /// #122: durable engine-routed transport intent (the last play/pause/setRate command), untouched
    /// by a seek. External AVKit / MediaRemote commands are reflected by `timeControlStatus` instead.
    /// Unlike `isEffectivelyPlaying` (instantaneous, momentarily `.paused`/`.waitingToPlay` right
    /// after a landing) this survives a scrub, so the engine's seek finalize can land a paused
    /// scrub paused instead of forcing `.playing`.
    var transportIntentIsPlaying: Bool { playIntent }

    /// #123: true while AVPlayer is still buffering toward a seek target (`waitingToPlayAtSpecifiedRate`)
    /// rather than presenting a frame. A paused or playing status is presenting the on-screen frame at
    /// the current position (a paused scrub shows the seeked frame); only `waitingToPlay` has the
    /// picture frozen BEHIND the target while it fills. The seek finalize / landing use this to avoid
    /// stamping `sourceTime`/`renderedTime` to a target the picture has not reached yet (#123).
    var isBufferingTowardSeekTarget: Bool { avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate }

    /// AE#446 round 4: the START of the first seekable range, the other end of `seekableEnd`.
    ///
    /// A live item's seekable range is a WINDOW, and only its end was ever mirrored, which is enough
    /// to follow the live edge and not enough to answer whether a given position is inside the item
    /// at all. A rejoin after an in-place swap asks exactly that question.
    nonisolated static func seekableStart(from ranges: [NSValue]) -> Double {
        guard let r = ranges.first?.timeRangeValue else { return 0 }
        let start = CMTimeGetSeconds(r.start)
        return start.isFinite ? start : 0
    }

    /// Maps `seekableTimeRanges` to the end of the last range (seconds); 0 when empty or non-finite.
    nonisolated static func seekableEnd(from ranges: [NSValue]) -> Double {
        guard let r = ranges.last?.timeRangeValue else { return 0 }
        let end = CMTimeGetSeconds(r.start + r.duration)
        return end.isFinite ? end : 0
    }

    /// End of the contiguous buffered span covering the playhead (AetherEngine#54); disjoint ranges
    /// ahead of a gap are ignored. Pure, so the reading can be taken off the main actor (AE#422).
    nonisolated static func contiguousBufferedEnd(ranges: [(Double, Double)], now: Double) -> Double {
        guard now.isFinite else { return 0 }
        var end = now
        for (start, endpoint) in ranges {
            guard start.isFinite, endpoint.isFinite else { continue }
            // Contiguous with the playhead (small tolerance for the gap
            // between the rendered frame and the range's reported start).
            if start <= now + 1.0 && endpoint >= now { end = max(end, endpoint) }
        }
        return end
    }

    /// AE#422: the queue every figplayer-backed read hops onto. A stalled reply parks a GCD thread
    /// rather than the main thread, which past the watchdog threshold is a process kill.
    nonisolated static let offMainReadQueue = DispatchQueue(
        label: "engine.avplayerhost.avfread", qos: .userInitiated)

    /// AE#422: everything the seek-deadline loop measures, read ONCE and off the main actor.
    ///
    /// That loop runs precisely while a seek is not landing, which is the state in which the media
    /// server is least likely to answer, and it was taking four synchronous XPC round trips per pass
    /// on the main actor (one island, three `bufferedEnd`). The reporter measured 13.3 s of fully
    /// blocked app on one such read, returning 30 ms after the re-engage watchdog fired. Batching
    /// also makes the two figures one consistent reading rather than four moments.
    func seekBufferSnapshot(target: Double, excludeAtOrAbove: Double?) async -> SeekBufferSnapshot {
        guard let item = avPlayer.currentItem else { return SeekBufferSnapshot(bufferedEnd: 0, targetIsland: 0) }
        return await AVFoundationOffMain.read(item, on: Self.offMainReadQueue) { item in
            let now = item.currentTime().seconds
            let ranges = item.loadedTimeRanges.map { value -> (Double, Double) in
                let r = value.timeRangeValue
                return (r.start.seconds, (r.start + r.duration).seconds)
            }
            return SeekBufferSnapshot(
                bufferedEnd: NativeAVPlayerHost.contiguousBufferedEnd(ranges: ranges, now: now),
                targetIsland: NativeAVPlayerHost.bufferedSecondsInWindow(
                    ranges: ranges, target: target, tolerance: 1.0, window: 30.0,
                    excludeAtOrAbove: excludeAtOrAbove))
        }
    }

    /// Seconds of media buffered *at the pending seek target*, i.e. how much the producer has actually
    /// served where the seek is trying to land.
    ///
    /// Deliberately measures against no playhead. `bufferedEnd` and `avPlayerBufferAheadSeconds()` are both
    /// measured from `item.currentTime()`, while the deadline loop's frozen position is `renderedTime`;
    /// during a buffering landing those two legitimately diverge (#123: `currentTime()` is already at the
    /// target while the rendered frame is still the old one), so any figure derived by subtracting one
    /// from the other is meaningless in exactly the case the seek-extension logic has to judge. The target
    /// is an absolute playlist time, so measuring against it needs neither.
    ///
    /// Only loaded media inside `[target - tolerance, target + window]` counts, so a *far* backward seek
    /// cannot count the old position's forward buffer. That window alone is not enough for a *near* one:
    /// a backward seek of less than `window` leaves the abandoned playhead's buffer sitting inside it, and
    /// a still-full old buffer would then read as "the producer is serving the target" and buy the seek an
    /// extension it has not earned. `excludeAtOrAbove` (the frozen playhead, passed by the deadline loop
    /// for a backward seek only) cuts the window off below it. Note this is an *exclusion* bound, not a
    /// measurement origin: the reason this function ignores the playhead is that a figure measured *from*
    /// one is meaningless while `currentTime()` and `renderedTime` diverge, and clamping a range does not
    /// reintroduce that.
    // AE#422: the main-actor reader that used to sit here is gone; `seekBufferSnapshot` is the only
    // way in, so a stall-adjacent caller cannot accidentally take the blocking route again.

    /// Pure part of `bufferedSecondsAtTarget(_:tolerance:window:excludeAtOrAbove:)`: total loaded seconds
    /// intersecting the target window, with the optional exclusion bound applied.
    ///
    /// AE#408: the target itself must be covered before any of the window counts. The window reaches
    /// `window` seconds PAST the target, so without that gate a band loaded 20 s downstream reads as
    /// "the producer is serving the target" at full weight: the reporter's `island=7.30s at target`
    /// sat next to `rendered == bufferedEnd` and a seek that never landed, which is only possible if
    /// nothing was loaded at the target at all (media there would have landed the seek). The window
    /// stays as wide as it was, because its job is measuring how DEEP the served region runs; it is
    /// only the licence to read it that now requires the target to be inside it.
    nonisolated static func bufferedSecondsInWindow(
        ranges: [(start: Double, end: Double)],
        target: Double,
        tolerance: Double = 1.0,
        window: Double = 30.0,
        excludeAtOrAbove: Double? = nil
    ) -> Double {
        guard target.isFinite else { return 0 }
        let lowerBound = target - tolerance
        var upperBound = target + window
        if let excludeAtOrAbove, excludeAtOrAbove.isFinite {
            upperBound = Swift.min(upperBound, excludeAtOrAbove - tolerance)
        }
        guard upperBound > lowerBound else { return 0 }
        // Coverage is judged inside the same clamped window, so the exclusion bound cannot be walked
        // around by a range that merely reaches down across the target from above it.
        let coverageHigh = Swift.min(target + tolerance, upperBound)
        var covered = false
        var total = 0.0
        for range in ranges {
            guard range.start.isFinite, range.end.isFinite, range.end > range.start else { continue }
            if range.start < coverageHigh, range.end > lowerBound { covered = true }
            let lo = Swift.max(range.start, lowerBound)
            let hi = Swift.min(range.end, upperBound)
            if hi > lo { total += hi - lo }
        }
        return covered ? total : 0
    }

    /// AE#440: whether to cut AVPlayer's stall-avoidance wait short right now.
    ///
    /// The wait this answers is the join tail a host cannot otherwise reach. AVPlayer presents the first
    /// frame, publishes `.waitingToPlayAtSpecifiedRate` with `AVPlayerWaitingToMinimizeStallsReason`, and
    /// holds that frame still while it decides whether the cushion it has will sustain playback. Against
    /// a live source delivered at 1x, that cushion is bought in wall-clock time and nothing on the item
    /// shortens it.
    ///
    /// Four guards, each of which is a way this would otherwise be the wrong call:
    /// - `armed`: opt-in per load, and never on a VOD session, whose start has no such deadline.
    /// - `hostWantsToPlay`: a host that paused during the join asked for a still picture. Overriding into
    ///   motion there would resurrect a session the host put down.
    /// - `isWaitingToMinimizeStalls`: NOT the `EvaluatingBufferingRate` reason, which `AVPlayer.h`
    ///   describes as a brief monitoring period and explicitly tells clients not to show waiting UI for.
    ///   Firing there would preempt an evaluation that was about to start playback on its own.
    /// - `playbackBufferEmpty`: the documented precondition. Over a non-empty buffer `playImmediately`
    ///   starts on the media already there; over an empty one `AVPlayer.h` says it "will act as if the
    ///   buffer became empty during playback", and a stall while the player is not waiting to minimize
    ///   stalls is exactly the shape that resets rate to 0 and never resumes. That is the failure the
    ///   2026-05 `automaticallyWaitsToMinimizeStalling = false` experiment hit process-wide (35fa16d0),
    ///   and the reason this is a one-shot on a proven buffer rather than a policy on the player.
    /// - `bufferedAheadSeconds`: how deep that proven buffer actually is. The flag above is the
    ///   documented MINIMUM, not a measure of safety: one served fragment reads `false` exactly as a
    ///   four-second cushion does. The device A/B that turned this default on sampled the real hold and
    ///   found 3.7 to 4.9 s ahead of the playhead throughout, which is why starting on it cost nothing;
    ///   behind the same `false` a genuinely starved join holds a fraction of a second, and starting
    ///   there trades a still picture for an immediate stall. The depth is the axis that separates the
    ///   two mechanisms, so it is the one the guard reads.
    /// - `itemIsReadyToPlay` (AE#684): the depth is measured from `currentTime()`, and until the item
    ///   is ready that is where the loader started fetching, not where playback will begin. Under an
    ///   `EXT-X-START` placement AVPlayer fetches from about 6 s below the target first, so the reading
    ///   is the lookback itself: captured on a rejoin placed at 53.908 s as `buffer ahead 4.00s` from a
    ///   playhead of 48.00 s, every second of it behind the start point, on an item whose status had
    ///   not left `unknown`, 36 ms before it did. That is the starved start the depth guard exists to
    ///   refuse, read as a four-second cushion, and it was the one item of five in that capture to
    ///   be forced, and the one its viewer reported out of sync. The hold is asked again at readiness.
    nonisolated static func shouldStartLiveJoinImmediately(
        armed: Bool,
        alreadySpent: Bool,
        hostWantsToPlay: Bool,
        isWaitingToMinimizeStalls: Bool,
        playbackBufferEmpty: Bool,
        bufferedAheadSeconds: Double,
        itemIsReadyToPlay: Bool
    ) -> Bool {
        guard armed, !alreadySpent, hostWantsToPlay else { return false }
        guard isWaitingToMinimizeStalls else { return false }
        guard itemIsReadyToPlay else { return false }
        guard !playbackBufferEmpty else { return false }
        // NaN fails every comparison silently, and an unresolved item's currentTime() is NaN, so an
        // absent reading has to be rejected rather than fall through the bound below.
        guard bufferedAheadSeconds.isFinite else { return false }
        return bufferedAheadSeconds >= minimumLiveJoinBufferAhead
    }

    /// Seconds of contiguous buffer a live join must hold ahead of its playhead before the
    /// stall-avoidance wait may be cut short.
    ///
    /// Chosen to separate the two mechanisms rather than to model a link: below one segment the cushion
    /// is a fragment and the start is a coin flip, while the hold this exists for was measured at 3.7 s
    /// and up on hardware, so the floor sits well under the case it must always admit and well over the
    /// case it must never admit. A source delivered at 1x does not grow this figure after the start,
    /// which is why AVPlayer's own estimate waits so long on a live join in the first place.
    nonisolated static let minimumLiveJoinBufferAhead: Double = 1.5

    /// Spend the AE#440 one-shot if this transport status is the join holding on buffered media. Also
    /// spends it silently once the rate rolls on its own, so the override can never reach a mid-stream
    /// rebuffer: past the join, AVPlayer's stall policy is the right one and a live channel that runs
    /// dry should wait rather than spin at rate 1 over nothing.
    private func startLiveJoinImmediatelyIfHolding(waitingReason: String) {
        guard liveJoinStartsImmediately, !liveJoinImmediateStartSpent else { return }
        if timeControlStatus == .playing {
            if Self.playingIsThisItemsRoll(itemIsReadyToPlay: playerItem?.status == .readyToPlay) {
                liveJoinImmediateStartSpent = true
            }
            return
        }
        // The free guards first, so the reading below is only ever taken on a hold that could actually
        // be cut short. `timeControlStatus` is the observer's mirror rather than a fresh player read:
        // the edge that called this set it one line earlier.
        guard playIntent,
              timeControlStatus == .waitingToPlayAtSpecifiedRate,
              waitingReason == AVPlayer.WaitingReason.toMinimizeStalls.rawValue,
              !liveJoinImmediateStartProbeInFlight,
              let item = playerItem
        else { return }
        liveJoinImmediateStartProbeInFlight = true
        let probeStart = DispatchTime.now()
        let sid = sessionID
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reading = await Self.liveJoinBufferReading(item)
            // Audit NAT-4: a load during the read reset the one-shot and the in-flight flag for its own
            // item, and a swap replaced the item this reading describes. Neither is this probe's to
            // spend or clear.
            guard self.sessionID == sid else { return }
            self.liveJoinImmediateStartProbeInFlight = false
            guard self.playerItem === item else { return }
            // AE#422: the reading is async, so the hold it described may be over. Decide on the state
            // that exists now, not on the edge that asked.
            guard !self.liveJoinImmediateStartSpent,
                  self.playIntent,
                  self.timeControlStatus == .waitingToPlayAtSpecifiedRate
            else {
                // Round 5: and say so. This is the last silent exit of the three the report walked into,
                // and it is the one a short hold takes: a rejoin swap that rolled 70 ms after entering the
                // wait produced no line at all, which from outside is indistinguishable from a lever that
                // was never armed on that path. One per load, because a hold has one such ending.
                if !self.liveJoinNoDecisionLogged {
                    self.liveJoinNoDecisionLogged = true
                    EngineLog.emit(
                        "[NativeAVPlayerHost] #\(self.sessionID) "
                        + Self.liveJoinDecisionAbandoned(
                            afterSeconds: Self.secondsSince(probeStart),
                            rolled: self.timeControlStatus == .playing),
                        category: .engine
                    )
                }
                return
            }
            guard Self.shouldStartLiveJoinImmediately(
                armed: self.liveJoinStartsImmediately,
                alreadySpent: self.liveJoinImmediateStartSpent,
                hostWantsToPlay: self.playIntent,
                isWaitingToMinimizeStalls: true,
                playbackBufferEmpty: reading.bufferEmpty,
                bufferedAheadSeconds: reading.aheadSeconds,
                itemIsReadyToPlay: reading.itemStatus == .readyToPlay
            ) else {
                // AE#684: a refusal the depth alone would have granted is the item's, not the
                // cushion's. It has its own line, and the thin-buffer line would contradict it (it
                // prints the same depth as the reason for leaving the wait alone).
                if let line = Self.liveJoinNotReadyRefusal(reading: reading) {
                    if !self.liveJoinNotReadyLogged {
                        self.liveJoinNotReadyLogged = true
                        EngineLog.emit("[NativeAVPlayerHost] #\(self.sessionID) " + line, category: .engine)
                    }
                } else if !self.liveJoinThinBufferLogged {
                    // The cushion, not the decision, is what a later report needs: it separates a join
                    // waiting on AVPlayer's rate estimate from one genuinely starved at the edge.
                    self.liveJoinThinBufferLogged = true
                    EngineLog.emit(
                        "[NativeAVPlayerHost] #\(self.sessionID) AE#440 live join: leaving the "
                        + "stall-avoidance wait alone (buffer ahead "
                        + String(format: "%.2f", reading.aheadSeconds)
                        + "s, empty=\(reading.bufferEmpty), floor "
                        + String(format: "%.2f", Self.minimumLiveJoinBufferAhead) + "s)"
                        + (Self.liveJoinPlacementClause(reading: reading).map { "; " + $0 } ?? ""),
                        category: .engine
                    )
                }
                self.startLiveJoinHoldWitness(item: item)
                // The item can turn ready while this reading is in flight. The readiness sink asked
                // at that moment and was turned away by the in-flight flag, so a reading taken on an
                // item that could not play yet, thin or deep, is the last word unless the question
                // is put again here.
                if Self.liveJoinAsksAgainAfterNotReadyRefusal(
                    readingWasNotReady: reading.itemStatus != .readyToPlay,
                    itemIsReadyNow: item.status == .readyToPlay,
                    alreadyAskedAgain: self.liveJoinNotReadyAskedAgain) {
                    self.liveJoinNotReadyAskedAgain = true
                    self.startLiveJoinImmediatelyIfHolding(
                        waitingReason: self.avPlayer.reasonForWaitingToPlay?.rawValue ?? "-")
                }
                return
            }
            self.liveJoinImmediateStartSpent = true
            self.liveJoinImmediateStartCutShort = true
            // #436: `defaultRate` is where the session's speed lives; a resume window must not silently
            // return a live join to 1.0 when the host is running at another rate.
            let rate = self.avPlayer.defaultRate != 0 ? self.avPlayer.defaultRate : 1.0
            EngineLog.emit(
                "[NativeAVPlayerHost] #\(self.sessionID) AE#440 live join: cutting the stall-avoidance "
                + "wait short at rate \(rate) (buffer ahead "
                + String(format: "%.2f", reading.aheadSeconds) + "s)",
                category: .engine
            )
            self.avPlayer.playImmediately(atRate: rate)
        }
    }

    /// Whether a `.playing` transport status is this item's rate rolling: the event that spends the
    /// AE#440 one-shot, latches #50's `hasEverPlayed` and releases the AE#629 swap hold (audit NAT-103).
    ///
    /// An in-place swap reuses a player that is still `.playing`, and that status reaches the fresh
    /// item as its first edge, before the item can play anything. Spent there, the one-shot was gone
    /// before the join's own `ToMinimizeStalls` hold began, so a #446 rejoin produced no decision and no
    /// line. An item cannot roll before it is ready, so readiness is what separates the carry from the
    /// roll. The readyToPlay sink asks again, for a carry that never changes status on its way to motion.
    nonisolated static func playingIsThisItemsRoll(itemIsReadyToPlay: Bool) -> Bool {
        itemIsReadyToPlay
    }

    /// AE#629 round 5: whether a mount holds the clock until its mount seek lands. Every in-place swap
    /// that seeks does (#646). A fresh mount does when it is VOD placed past the head: at the head
    /// there is no earlier segment start to read, and a live mount's anchor sits on the item axis
    /// while its clock is folded through the session shift.
    nonisolated static func mountHoldsClock(
        inPlaceSwap: Bool, skipInitialSeek: Bool, startPosition: Double?, isLive: Bool
    ) -> Bool {
        if skipInitialSeek { return false }
        if inPlaceSwap { return true }
        return !isLive && (startPosition ?? 0) > 0
    }

    /// AE#440 round 3: what a refused hold did next, reported and never acted on.
    ///
    /// The guard above answers one instant, and the bound it read is read only at the hold's edges: a
    /// `timeControlStatus` change or a `reasonForWaitingToPlay` change. A join that begins the hold
    /// starved and fills while the reason stands still therefore gets no second look, and no log line
    /// says whether that happened. The reporter's stack is about to make that shape common rather than
    /// hypothetical: with #447 the first manifest is served 1.2 s into a join and with #449 the
    /// display-criteria gate no longer spends a 2 s cap in front of `play()`, so the decision now falls
    /// EARLIER relative to the media arriving, which is the variable that decides what the guard reads.
    ///
    /// So this samples the same reading while the hold stands, and says which of three things happened:
    /// the cushion crossed the floor with the hold still standing (the case that would justify deciding
    /// during a hold), the hold ended first (the guard was right and the wait was AVPlayer's own rate
    /// estimate), or the sampling budget ran out with the hold still up. Exactly one line either way,
    /// because a witness that is silent about its own negative cannot be told from a witness that never
    /// ran. Round 4 makes that true: the first version still had two silent exits, and one of them was
    /// the ordinary ending (see `liveJoinHoldWitnessEnding`).
    ///
    /// It does not start playback. Firing on a cushion that has just crossed and is still climbing is
    /// the bet `minimumLiveJoinBufferAhead` exists to refuse, and the evidence for taking it is what
    /// this produces rather than what it assumes.
    private func startLiveJoinHoldWitness(item: AVPlayerItem) {
        guard !liveJoinHoldWitnessStarted else { return }
        liveJoinHoldWitnessStarted = true
        let startedAt = DispatchTime.now()
        // Held rather than read off `self`, so the two endings that have no host to read it from still
        // carry the session they belong to.
        let sid = sessionID
        Task { @MainActor [weak self] in
            // Optional, and it stays nil until this witness has actually read something (#440 round 5).
            // A placeholder here printed `ahead 0.00s, empty=true` for a hold that ended inside the first
            // sampling interval, which reads as a measurement of a starved buffer and contradicted the
            // refusal's own `empty=false` one line above it. A reading that was never taken has to say so.
            var last: LiveJoinBufferReading?
            func account(_ outcome: LiveJoinHoldOutcome) {
                EngineLog.emit(
                    "[NativeAVPlayerHost] #\(sid) "
                    + Self.liveJoinHoldAccount(outcome: outcome,
                                               standingSeconds: Self.secondsSince(startedAt),
                                               reading: last),
                    category: .engine
                )
            }
            // [MovieClaw P28] VOD 采样更密：过线后每多等一个采样间隔，就是多冻一截画面
            let vod = self?.isLiveSession == false
            let interval = vod ? AetherEngine.vodStartWitnessIntervalSeconds : Self.liveJoinHoldWitnessInterval
            // [MovieClaw P57] 分片边产出边送时，慢线路上缓冲是一个片段一个片段慢慢涨的：从长 GOP 中间续播，
            // 6 Mbit/s 下出首帧要 6 秒、攒够 1.5 秒还要再几秒，5 秒的见证早过期了，AVPlayer 自己的码率估计又一直
            // 觉得跟不上，要等整段下完（模拟器实测首帧 6.4 秒、25 秒才开播）。所以边送时多看一会儿：头 5 秒照旧
            // 每 `interval` 一次，之后每 0.1 秒一次，最多 `vodProgressiveWitnessBudgetSeconds`
            let budget = vod && AetherEngine.servesSegmentsProgressively
                ? Self.vodProgressiveWitnessBudgetSeconds : Self.vodHoldWitnessBudgetSeconds
            let denseSamples = vod ? Int((min(budget, Self.vodHoldWitnessBudgetSeconds) / interval).rounded(.up))
                                   : Self.liveJoinHoldWitnessSamples
            let sparseSamples = vod ? Int((max(0, budget - Self.vodHoldWitnessBudgetSeconds) / 0.1).rounded(.up)) : 0
            for sample in 0..<(denseSamples + sparseSamples) {
                let wait = sample < denseSamples ? interval : 0.1
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self else { account(.hostGone); return }
                if let ending = Self.liveJoinHoldWitnessEnding(
                    itemIsCurrent: self.playerItem === item,
                    waitWasCutShort: self.liveJoinImmediateStartCutShort,
                    oneShotSpent: self.liveJoinImmediateStartSpent,
                    hostWantsToPlay: self.playIntent,
                    isWaitingToPlay: self.timeControlStatus == .waitingToPlayAtSpecifiedRate
                ) {
                    account(ending)
                    return
                }
                let reading = await Self.liveJoinBufferReading(item)
                last = reading
                guard Self.shouldStartLiveJoinImmediately(
                    armed: true, alreadySpent: false, hostWantsToPlay: true,
                    isWaitingToMinimizeStalls: true,
                    playbackBufferEmpty: reading.bufferEmpty, bufferedAheadSeconds: reading.aheadSeconds,
                    itemIsReadyToPlay: reading.itemStatus == .readyToPlay
                ) else { continue }
                account(.crossed)
                // [MovieClaw P28] VOD 的分片由本机远快于 1 倍速地产出，过线后的缓冲只会继续涨，上游「只记录不动手」
                // 顾虑的直播 1 倍速供给不存在：真机 UHD 原盘起播时缓冲已 3.65 秒、AVPlayer 还多按了 0.6 秒。
                // 所以 VOD 过线即开播；直播保持上游行为
                if !self.isLiveSession, self.playerItem === item, self.playIntent,
                   !self.liveJoinImmediateStartSpent,
                   self.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                   self.avPlayer.reasonForWaitingToPlay == .toMinimizeStalls {
                    self.liveJoinImmediateStartSpent = true
                    self.liveJoinImmediateStartCutShort = true
                    let rate = self.avPlayer.defaultRate != 0 ? self.avPlayer.defaultRate : 1.0
                    EngineLog.emit(
                        "[NativeAVPlayerHost] #\(sid) [MovieClaw P28] VOD 缓冲已过线（"
                        + String(format: "%.2f", reading.aheadSeconds) + " 秒），不再等 AVPlayer 的码率估计，直接开播",
                        category: .engine)
                    self.avPlayer.playImmediately(atRate: rate)
                }
                return
            }
            account(.budgetSpent)
        }
    }

    /// Which ending this sample landed on, or nil to keep sampling. Pure, because the endings that
    /// matter most are the ones a device run does not reliably produce.
    ///
    /// The order is the whole point of round 4. A spent one-shot used to be read first and as a reason
    /// to stop WITHOUT a line, on the theory that it meant the witness no longer applied. But the rate
    /// rolling is exactly what spends it (`startLiveJoinImmediatelyIfHolding` spends it on the
    /// `.playing` edge so the override can never reach a mid-stream rebuffer), so the single most
    /// common way a refused hold ends was routed into the silent exit and `.holdEnded` was left
    /// reachable only by a pause. The 6.56.1 field capture is that defect: three refusals, one line,
    /// and no way from outside to tell a sampler that ended in a state with no line from one that never
    /// armed. Every ending below emits.
    nonisolated static func liveJoinHoldWitnessEnding(itemIsCurrent: Bool,
                                                      waitWasCutShort: Bool,
                                                      oneShotSpent: Bool,
                                                      hostWantsToPlay: Bool,
                                                      isWaitingToPlay: Bool) -> LiveJoinHoldOutcome? {
        guard itemIsCurrent else { return .itemReplaced }
        // Before the plain spend, which it also sets: the override firing is the opposite fact from the
        // wait ending on its own.
        if waitWasCutShort { return .cutShort }
        if oneShotSpent || !hostWantsToPlay || !isWaitingToPlay { return .holdEnded }
        return nil
    }

    /// How a refused live-join hold ended, from the witness's side.
    enum LiveJoinHoldOutcome: Sendable, Equatable {
        /// The cushion reached the floor while the hold was still standing.
        case crossed
        /// The hold ended on its own (the rate rolled, or the host paused) before it did.
        case holdEnded
        /// A later edge found the cushion over the floor and the override cut the wait short.
        case cutShort
        /// The item was replaced under the witness: this join was abandoned rather than resolved.
        case itemReplaced
        /// The host went away while the hold stood.
        case hostGone
        /// The sampling budget ran out with the hold still standing.
        case budgetSpent
    }

    /// One line per refused hold, in the terms the decision would be taken in. Pure so the negative
    /// cases are pinned by tests rather than by a device run that happens not to produce them.
    nonisolated static func liveJoinHoldAccount(outcome: LiveJoinHoldOutcome,
                                                standingSeconds: Double,
                                                reading: LiveJoinBufferReading?) -> String {
        let stood = String(format: "%.2f", standingSeconds)
        let floor = String(format: "%.2f", minimumLiveJoinBufferAhead)
        let head = "AE#440 live join: "
        // What this witness itself measured, or the fact that it never got to (#440 round 5). The floor
        // travels with it either way, since it is the number the sentence is about.
        let seen: String = reading.map {
            "last reading ahead \(String(format: "%.2f", $0.aheadSeconds))s, "
            + "empty=\($0.bufferEmpty), floor \(floor)s"
            + (liveJoinPlacementClause(reading: $0).map { "; " + $0 } ?? "")
        } ?? "no reading of its own was taken before it ended, so the cushion named at the refusal is "
            + "the last one measured (floor \(floor)s)"
        let ahead = reading.map { String(format: "%.2f", $0.aheadSeconds) } ?? "n/a"
        switch outcome {
        case .crossed:
            return head + "the wait was still standing \(stood)s after the refusal when the buffer "
                + "reached the floor (ahead \(ahead)s, floor \(floor)s); observed only, the decision "
                + "is still taken at the edges"
        case .holdEnded:
            return head + "the wait ended \(stood)s after the refusal without the buffer reaching the "
                + "floor (\(seen))"
        case .cutShort:
            let sample = reading.map { "last sample ahead \(String(format: "%.2f", $0.aheadSeconds))s" }
                ?? "this witness took no sample of its own"
            return head + "the wait was cut short at an edge \(stood)s after the refusal, so the cushion "
                + "had crossed the floor by then (\(sample), floor \(floor)s)"
        case .itemReplaced:
            return head + "the wait was still standing \(stood)s after the refusal when the item was "
                + "replaced, so this join was abandoned rather than resolved (\(seen))"
        case .hostGone:
            return head + "the wait was still standing \(stood)s after the refusal when the host went "
                + "away (\(seen))"
        case .budgetSpent:
            return head + "the wait was still standing after \(stood)s of sampling and the buffer had "
                + "not reached the floor (\(seen))"
        }
    }

    /// The decision's own ending when there was nothing left to decide (#440 round 5). Pure, because the
    /// hold that produces it is 70 ms long and no harness reproduces it on demand.
    ///
    /// It is not a defect that no decision was taken: the buffer reading is asynchronous, so a hold that
    /// ends while it is in flight has to be left alone rather than acted on from a state that no longer
    /// exists (AE#422). What was a defect is that this said nothing, which reads exactly like a lever
    /// that was never armed for the path at all.
    nonisolated static func liveJoinDecisionAbandoned(afterSeconds: Double, rolled: Bool) -> String {
        "AE#440 live join: the hold was over "
        + (rolled ? "and the rate had rolled " : "")
        + "by the time the buffer reading came back \(String(format: "%.2f", afterSeconds))s later, "
        + "so no decision was taken on it"
    }

    /// Sampling cadence and budget for the witness above. A quarter second is well under the shortest
    /// hold either report measured (1.55 s), and five seconds outlives the longest (2.81 s) without
    /// leaving a sampler running behind a session that has moved on.
    nonisolated static let liveJoinHoldWitnessInterval: Double = 0.25
    nonisolated static let liveJoinHoldWitnessSamples: Int = 20
    /// [MovieClaw P28] VOD 的见证采样至多看 5 秒（间隔见 `AetherEngine.vodStartWitnessIntervalSeconds`）
    nonisolated static let vodHoldWitnessBudgetSeconds: Double = 5
    /// [MovieClaw P57] 分片边产出边送时 VOD 见证至多看这么久（见上面采样循环里的说明）
    nonisolated static let vodProgressiveWitnessBudgetSeconds: Double = 45

    nonisolated static func secondsSince(_ start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// AE#440 + AE#422: both figures the live-join guard weighs, read once and off the main actor.
    ///
    /// This runs while AVPlayer is holding a presented frame, which on the starved half of the two
    /// mechanisms is precisely the state where the media server is least likely to answer. A
    /// synchronous `isPlaybackBufferEmpty` there is the shape AE#422 measured at 13.3 s of fully
    /// blocked app, and the depth needs two more reads on top of it.
    nonisolated static func liveJoinBufferReading(_ item: AVPlayerItem) async -> LiveJoinBufferReading {
        await AVFoundationOffMain.read(item, on: Self.offMainReadQueue) { item in
            let now = item.currentTime().seconds
            let ranges = item.loadedTimeRanges.map { value -> (Double, Double) in
                let r = value.timeRangeValue
                return (r.start.seconds, (r.start + r.duration).seconds)
            }
            // Contiguous from the playhead, not the sum of every loaded range: an island past a gap
            // cannot sustain a rate that has to cross the gap to reach it.
            let ahead = NativeAVPlayerHost.contiguousBufferedEnd(ranges: ranges, now: now) - now
            let placement = NativeAVPlayerHost.liveJoinPlacement(ranges: ranges, now: now)
            return LiveJoinBufferReading(bufferEmpty: item.isPlaybackBufferEmpty, aheadSeconds: ahead,
                                         playheadSeconds: now,
                                         loadedRangeCount: placement.count,
                                         nearestRangeOffsetSeconds: placement.nearestOffset,
                                         itemStatus: item.status)
        }
    }

    struct LiveJoinBufferReading: Sendable {
        let bufferEmpty: Bool
        let aheadSeconds: Double
        /// Where the item says it is, which is the axis every other number here is measured against.
        var playheadSeconds: Double = .nan
        /// How many loaded ranges the item holds at all.
        var loadedRangeCount: Int = 0
        /// Signed distance from the playhead to the nearest loaded range that does not contain it:
        /// positive when the nearest one STARTS that far ahead, negative when the nearest one ENDED
        /// that far behind. nil when a range contains the playhead, or when there are none.
        var nearestRangeOffsetSeconds: Double? = nil
        /// AVPlayer's own verdict on the item, read in the same batch as everything above it.
        /// nil only where a caller builds a reading without one.
        var itemStatus: AVPlayerItem.Status? = nil
    }

    /// AE#447 follow-up: `ahead 0.00s` is two different facts and the line printed one word for both.
    ///
    /// `contiguousBufferedEnd` returns the playhead itself whenever no range touches it, so an item
    /// that has placed NOTHING AT ALL and an item that holds media somewhere else entirely read
    /// identically, while `empty=false` (AVPlayer's own answer about the item) is true in both. Those
    /// two need opposite investigations: nothing placed points at the fetch, placed elsewhere points at
    /// the item and the playlist disagreeing about where the media sits. A field report that has to be
    /// cross-referenced against a 1 Hz verbose `[LagDiag] fwd=-` to tell them apart is one nobody reads
    /// that way, which is how a 20 s wedge arrived with the discriminating fact already in the capture
    /// and unread.
    nonisolated static func liveJoinPlacement(ranges: [(Double, Double)],
                                              now: Double) -> (count: Int, nearestOffset: Double?) {
        let usable = ranges.filter { $0.0.isFinite && $0.1.isFinite }
        guard now.isFinite, !usable.isEmpty else { return (usable.count, nil) }
        // The same tolerance the contiguity test uses, so "contains the playhead" means the same thing
        // in both places and a range can never be reported as both.
        if usable.contains(where: { $0.0 <= now + 1.0 && $0.1 >= now }) { return (usable.count, nil) }
        let offsets = usable.map { $0.0 > now ? $0.0 - now : $0.1 - now }
        let nearest = offsets.min(by: { abs($0) < abs($1) })
        return (usable.count, nearest)
    }

    /// AE#509: the item's own verdict, said out loud by the account that describes the wedge.
    ///
    /// `item.status` is otherwise carried by a KVO observer that fires on a CHANGE, so an item that
    /// never leaves `.unknown` produces no status line at all: the engine is silent about the item in
    /// exactly the state where the item is the question. A 20 s field wedge arrived with "nothing
    /// placed" from here and `.unknown` from the host's own private dump, and only the pair of them
    /// said anything. The two readings point opposite ways: `.unknown` is AVPlayer never accepting the
    /// media (look at the segment bytes), `.readyToPlay` is an accepted item that places nothing (look
    /// at the fetch).
    nonisolated static func liveJoinStatusClause(_ status: AVPlayerItem.Status?) -> String {
        switch status {
        case .unknown:
            return ", and the item's own status has not left unknown, so AVPlayer has not accepted "
                + "the media at all"
        case .readyToPlay:
            return ", on an item AVPlayer has accepted (status readyToPlay)"
        case .failed:
            return ", on an item AVPlayer has failed (status failed)"
        case .none:
            return ""
        @unknown default:
            return ""
        }
    }

    /// AE#684: whether a refusal taken on a not-ready item puts the question again, whatever the
    /// depth it read (a thin reading on such an item is as stale as a deep one). Once per load, and
    /// only when the item has become ready since the reading was taken: the reading is asynchronous, the readiness
    /// sink's own question is dropped while one is in flight, and without this a hold that outlives
    /// readiness on that race is never judged on the playhead it starts from.
    nonisolated static func liveJoinAsksAgainAfterNotReadyRefusal(readingWasNotReady: Bool,
                                                                  itemIsReadyNow: Bool,
                                                                  alreadyAskedAgain: Bool) -> Bool {
        readingWasNotReady && itemIsReadyNow && !alreadyAskedAgain
    }

    /// AE#684: the refusal line for a hold that had the depth and not the item. nil for every other
    /// refusal, which the thin-buffer line already accounts for.
    nonisolated static func liveJoinNotReadyRefusal(reading: LiveJoinBufferReading) -> String? {
        guard reading.itemStatus != .readyToPlay, !reading.bufferEmpty,
              reading.aheadSeconds.isFinite, reading.aheadSeconds >= minimumLiveJoinBufferAhead
        else { return nil }
        let head = reading.playheadSeconds.isFinite
            ? String(format: "%.2f", reading.playheadSeconds) + "s"
            : "an unreadable position"
        return "AE#440 live join: leaving the stall-avoidance wait alone on an item that cannot play "
            + "yet (buffer ahead " + String(format: "%.2f", reading.aheadSeconds) + "s of playhead "
            + head + ", which until readiness is where the fetch began and not where playback will); "
            + "asked again at readiness"
    }

    /// The placement clause the two accounts below carry when the cushion reads zero. nil when a range
    /// contains the playhead: there the depth is the whole story and this would only add noise.
    nonisolated static func liveJoinPlacementClause(reading: LiveJoinBufferReading) -> String? {
        guard reading.aheadSeconds <= 0 else { return nil }
        let head = reading.playheadSeconds.isFinite
            ? String(format: "%.2f", reading.playheadSeconds) + "s"
            : "an unreadable position"
        let status = liveJoinStatusClause(reading.itemStatus)
        if reading.loadedRangeCount == 0 {
            return "the item holds no loaded range at all, so nothing has been placed on its axis "
                + "since it was mounted (playhead \(head))" + status
        }
        guard let offset = reading.nearestRangeOffsetSeconds else {
            // A range does contain the playhead and the depth is simply zero: starved at the edge.
            return "the item holds \(reading.loadedRangeCount) loaded range(s) and the playhead sits "
                + "inside one of them with nothing ahead of it (playhead \(head))" + status
        }
        let where_ = offset > 0
            ? "starts \(String(format: "%.2f", offset))s AHEAD of it"
            : "ended \(String(format: "%.2f", -offset))s BEHIND it"
        return "the item holds \(reading.loadedRangeCount) loaded range(s) but none at the playhead: "
            + "the nearest \(where_) (playhead \(head))" + status
    }

    func play() {
        // Set intent before play() so readyToPlay observer can re-assert if the replaceCurrentItem swap swallowed it.
        playIntent = true
        // Call play() immediately (no defer-until-ready): item.status never advances past .unknown until AVPlayer is told to play.
        avPlayer.play()
    }

    func pause() {
        playIntent = false
        avPlayer.pause()
    }

    /// Synthesize organic end-of-media when the engine determines a tail park is video-exhaustion
    /// (AetherEngine#169), not a recoverable stall. Sets the same `didReachEnd` the real
    /// didPlayToEndTime observer sets, so the engine transitions to `.ended` and the host's
    /// end-of-playback handling (mark-watched / autoplay-next / dismiss) fires exactly as an organic
    /// finish. Idempotent, and cleared per load in `unloadCurrentItem`.
    func markEndOfMediaReached() {
        guard !didReachEnd else { return }
        EngineLog.emit("[NativeAVPlayerHost] #\(sessionID) synthesized end-of-media (tail park, #169)", category: .engine)
        didReachEnd = true
    }

    /// The mirror of `markEndOfMediaReached` (AetherEngine#287): suppress an end-of-item event that
    /// AVPlayer's own seekable range contradicts, and resume instead of completing.
    ///
    /// A VOD whose selected audio track outruns its video track makes AVPlayer fire didPlayToEndTime
    /// the moment the video renderer runs dry, tens of seconds short of the advertised duration and
    /// well inside the range it still reports as seekable. Forwarding that as `didReachEnd` latches the terminal
    /// `.ended` (#63/#164), after which the tail is unreachable for the rest of the session. Re-seeking
    /// to the SAME position re-arms the renderers and the tail plays out to an organic end at the real
    /// duration, dropping nothing (measured; `play()` alone leaves the clock frozen at the boundary).
    ///
    /// Returns true when the end was suppressed and playback resumed, false when the caller should
    /// complete the item as usual. Both the attempt cap and the forward-progress rule live in
    /// `AetherEngine.prematureEndRecoveryQualifies`, so a recovery that cannot work costs one re-seek
    /// and then completes exactly as it does today.
    private func recoverFromPrematureEnd() async -> Bool {
        // Only resume what the viewer was playing: an item that ends while the transport is parked
        // must stay parked.
        guard playIntent, !didReachEnd else { return false }
        // AE#422: one batched off-main reading. A premature end IS a state where the media server is
        // misreporting, so "one read at a rare event" (the note that used to stand on
        // `seekableRangeEndSeconds`) is not the cheap thing it looks like: the reporter measured a
        // single such read holding the main thread for 13.3 s.
        let reading = await prematureEndReading()
        let playhead = reading.playhead
        let seekEnd = reading.seekableEnd
        guard AetherEngine.prematureEndRecoveryQualifies(
            isLive: isLiveSession,
            duration: duration,
            playhead: playhead,
            seekableEnd: seekEnd,
            attemptsUsed: prematureEndRecoveryAttempts,
            lastAttemptPlayhead: lastPrematureEndRecoveryPlayhead
        ) else { return false }

        prematureEndRecoveryAttempts += 1
        lastPrematureEndRecoveryPlayhead = playhead
        prematureEndRecoveryInFlight = true
        EngineLog.emit(
            "[NativeAVPlayerHost] #\(sessionID) AE#287 premature end: playhead="
            + "\(String(format: "%.3f", playhead))s duration=\(String(format: "%.3f", duration))s "
            + "seekableEnd=\(String(format: "%.3f", seekEnd ?? -1))s "
            + "loadedEnd=\(String(format: "%.3f", reading.loadedEnd ?? -1))s; "
            + "\(String(format: "%.1f", duration - playhead))s of the presentation lies past the end "
            + "AVPlayer reported, re-seeking in place (attempt \(prematureEndRecoveryAttempts))",
            category: .engine)
        let sid = sessionID
        await seek(to: playhead)
        // The session may have been handed over while the seek was in flight; a retired session
        // must not restart the player under its successor.
        guard sessionID == sid else { return true }
        avPlayer.play()
        prematureEndRecoveryInFlight = false
        timeControlStatus = avPlayer.timeControlStatus
        let resumedAt = await prematureEndReading().playhead
        EngineLog.emit(
            "[NativeAVPlayerHost] #\(sessionID) AE#287 resumed: rate=\(avPlayer.rate) "
            + "t=\(String(format: "%.3f", resumedAt))s",
            category: .engine)
        return true
    }

    /// AE#422: the three figures the #287 recovery needs, read once and off the main actor.
    private func prematureEndReading() async -> PrematureEndReading {
        guard let item = playerItem else {
            return PrematureEndReading(playhead: 0, seekableEnd: nil, loadedEnd: nil)
        }
        return await AVFoundationOffMain.read(item, on: Self.offMainReadQueue) { item in
            func endOf(_ ranges: [NSValue]) -> Double? {
                guard let last = ranges.last?.timeRangeValue else { return nil }
                let end = CMTimeGetSeconds(CMTimeAdd(last.start, last.duration))
                return end.isFinite ? end : nil
            }
            return PrematureEndReading(
                playhead: item.currentTime().seconds,
                seekableEnd: endOf(item.seekableTimeRanges),
                loadedEnd: endOf(item.loadedTimeRanges))
        }
    }

    /// AE#287 witnesses, now read through `prematureEndReading()`. `seekableEnd` is the extent of the
    /// presentation AVPlayer parsed from the playlist, read from the item rather than the KVO mirror
    /// (which exists to keep the LIVE edge off a tick-cadence read, #134). `loadedEnd` is diagnostics
    /// only and is NOT the witness: measured at a premature end, AVPlayer has already trimmed that
    /// range back to the exhaustion point, so it corroborates the mistake instead of refuting it.

    /// Resolve only when the seek physically lands (loopback source lands seeks seconds after the call; issue #37).
    /// seekInFlight suppresses the periodic observer across the wait; only the latest seekGeneration clears it.
    func seek(to seconds: Double) async {
        _ = await seek(to: seconds, deadlineSeconds: nil)
    }

    /// Deadline-bounded seek (#65). Returns `true` if AVPlayer physically landed (or no deadline was set),
    /// `false` if `deadlineSeconds` elapsed with the seek still pending. On a deadline expiry the in-flight
    /// `avPlayer.seek` is NOT cancelled (it lands later if it ever can), but `seekInFlight` is cleared for the
    /// latest generation so the periodic observer resumes publishing AVPlayer's real position, letting the
    /// engine reconcile a clock that would otherwise stay latched at an unreachable optimistic target.
    @discardableResult
    func seek(to seconds: Double, deadlineSeconds: Double?) async -> Bool {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        seekGeneration &+= 1
        let gen = seekGeneration
        seekInFlight = true
        // [MovieClaw P28] VOD 每次跳转重新给一次 P2 的「提前开播」：跳转落点后 AVPlayer 同样会以 ToMinimizeStalls
        // 按住已缓冲好的画面等码率估计（真机 4K60 往回 5 秒、往前 20 秒都落在本机已产出的分片里，仍各等了 1.4–1.5 秒）。
        // 守卫与起播时相同：缓冲非空且至少 1.5 秒才切，缓冲薄时照旧交给 AVPlayer 自己的策略
        if !isLiveSession && liveJoinStartsImmediately {
            liveJoinImmediateStartSpent = false
            liveJoinThinBufferLogged = false
            liveJoinNoDecisionLogged = false
            liveJoinHoldWitnessStarted = false
            liveJoinImmediateStartCutShort = false
        }
        // AE#629: this seek's own landing publishes the clock from here on.
        mountSeekPending = false
        latestSeekRenderedTimePublished = false
        let resumeGuard = SeekResumeGuard()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            if let deadlineSeconds, deadlineSeconds > 0 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(deadlineSeconds * 1_000_000_000))
                    guard resumeGuard.claim() else { return } // landing already won the race
                    // Clear seekInFlight for the latest generation so the periodic observer un-gates and the
                    // engine can fold AVPlayer's real position back in. Do not cancel the underlying seek.
                    if let self, gen == self.seekGeneration { self.seekInFlight = false }
                    cont.resume(returning: false)
                }
            }
            // Zero tolerances: unbounded tolerances caused AVPlayer to land on arbitrary sync samples for loopback HLS-fMP4 (openradar 44904505).
            avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self else {
                        if resumeGuard.claim() { cont.resume(returning: true) }
                        return
                    }
                    // Settle the clock on a real landing even if the deadline already returned (late landing).
                    // Superseded seek: leave the newer generation's flags intact.
                    if gen == self.seekGeneration {
                        self.seekInFlight = false
                        let landed = self.avPlayer.currentTime().seconds
                        if landed.isFinite {
                            self.currentTime = landed
                            // #49: settle renderedTime so sourceTime settles immediately, BUT only when the
                            // landed frame is actually presented (playing or paused shows the target frame).
                            // #123: while still buffering toward the target (`waitingToPlayAtSpecifiedRate`)
                            // the picture is frozen behind it and `landed` is the target the player accepted,
                            // not the on-screen frame; stamping it parks renderedTime (and thus sourceTime)
                            // ahead of the picture for the whole chase, because the 100ms periodic observer is
                            // silent while waiting and cannot walk it back. Hold renderedTime on the frozen
                            // frame; the observer settles it to the target when playback resumes.
                            if AetherEngine.seekLandingSettlesToTarget(
                                bufferingTowardTarget: self.isBufferingTowardSeekTarget) {
                                self.latestSeekRenderedTimePublished = true
                                self.renderedTime = landed
                            }
                        }
                    }
                    if resumeGuard.claim() { cont.resume(returning: true) }
                }
            }
        }
    }

    /// DV/SMB forward-seek revert fix: wait longer for the seek already in flight WITHOUT issuing a
    /// new `avPlayer.seek`. A deadline expiry does not cancel the underlying seek (see `seek(to:deadlineSeconds:)`),
    /// so it is still progressing toward `target` and its completion (which settles `currentTime` for the
    /// unchanged generation) can still fire; the engine gave up too early on a slow source. Re-issuing the
    /// seek would bump the generation and could make AVPlayer re-fetch the target segment it has already
    /// partly loaded, the opposite of what a starved SMB source needs. This just re-arms the wait and
    /// re-gates the periodic observer (which the deadline un-gated) so the optimistic clock is not walked
    /// back to the pre-seek position while the target buffers.
    ///
    /// - Returns: `true` once the pending seek has landed (AVPlayer's `currentTime` reached `target`),
    ///   `false` if it is still pending after `deadlineSeconds` or a newer seek superseded it.
    func awaitPendingSeekLanding(target seconds: Double, deadlineSeconds: Double, forward: Bool) async -> Bool {
        // Re-gate: the prior deadline cleared seekInFlight, so the periodic observer would otherwise
        // publish AVPlayer's still-pre-seek position and un-latch the optimistic clock. The original
        // seek's completion clears this again when it lands.
        let gen = seekGeneration
        // We latch the gate ourselves below so the periodic observer keeps `currentTime` pinned while we
        // wait. Note the gate is deliberately NOT used as a landing signal: see below.
        if !seekInFlight { seekInFlight = true }
        // Poll for landing rather than sleeping the whole window: on a slow extend-path seek AVPlayer can
        // resume playing partway through the wait, and finalize (which clears the consumer's loading
        // spinner) must not lag that edge by a full ~4s tick -- that left the spinner up over already-
        // playing video (device: timeControlStatus=playing at 25360.989 but seek END at 25363.415).
        // Edge-detect the landing at ~AVPlayer's own 100ms observer cadence so finalize tracks it.
        //
        // Poll the published `renderedTime` rather than `avPlayer.currentTime()`: the periodic observer
        // writes it every 100ms BEFORE the seekInFlight gate, so it is both current and free, whereas
        // currentTime() is a synchronous XPC read (#134) that this loop would perform ~360 times in a
        // worst-case seek, on the main actor.
        let pollInterval = 0.1
        // Monotonic: a wall-clock step (NTP, user change) must not stretch or truncate the budget.
        let deadline = DispatchTime.now() + .milliseconds(Int(deadlineSeconds * 1000))
        while DispatchTime.now() < deadline {
            do {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            } catch {
                // Cancelled. Swallowing this (try?) would turn the loop into an unthrottled MainActor spin
                // -- Task.sleep then throws instantly every pass -- for the rest of the window.
                releaseSeekGate()
                return false
            }
            // A newer seek arrived while we waited: let it own the final state.
            guard gen == seekGeneration else { return false }
            // Require POSITION evidence. "The completion ran" is deliberately not accepted as a landing:
            // `reengageStalledConsumer` calls `item.cancelPendingSeeks()` without bumping seekGeneration,
            // which completes the in-flight seek with finished == false and clears seekInFlight for this
            // same generation. Treating that as a landing would report the target as reached, retire
            // `pendingRecoverySeekClockTarget`, and silently lose the seek (#93) while AVPlayer sits
            // wherever the nudge left it. A genuine landing moves the rendered frame to the target, so
            // nothing is lost by insisting on it.
            //
            // A zero-tolerance seek lands AT the target and a playing item then advances in the seek
            // direction, so a forward seek can render PAST it. Accept an overshoot in the seek direction;
            // the pinned pre-seek playhead sits far on the opposite side and is never mistaken for a
            // landing. This stops a forward overshoot from reading as "still pending" and triggering a
            // backward-yank re-seek on an already-playing item.
            let rendered = renderedTime
            if AetherEngine.seekLandedAtTarget(rendered: rendered, target: seconds, forward: forward) {
                // The completion may not have run its MainActor job yet; settle so the observer stays gated
                // until the engine finalizes and mirror what the completion would publish.
                seekInFlight = false
                if rendered.isFinite { currentTime = rendered }
                return true
            }
        }
        // Timed out. Restore the gate to the state the deadline left it in: leaving it latched would keep
        // the periodic observer from publishing `currentTime`, freezing `host.$currentTime` -- the sole
        // driver of the engine's clock tick -- for the rest of this generation. On the give-up path this
        // caller returns immediately afterwards, so nothing else would ever clear it.
        releaseSeekGate()
        return false
    }

    /// Un-gate the periodic observer without asserting a landing (cancellation / give-up paths).
    private func releaseSeekGate() {
        seekInFlight = false
    }

    func setRate(_ value: Float) {
        // Non-zero rate counts as play intent (must survive replaceCurrentItem swap like play() does).
        playIntent = (value != 0)
        // #436: `play()` is rate 1.0 by definition, and it is re-issued from paths no client can see:
        // the readyToPlay re-assert after an item swap, interruption and background resume, the #287
        // premature-end recovery, plus AVKit's own transport and the remote command centre calling
        // play() straight on this player. `defaultRate` is what AVPlayer starts at when told to play,
        // so recording the speed there is what makes it survive all of them, with no rate write in
        // anyone's resume window. Setting `rate` does not update it (AVPlayer.h), hence both.
        if value != 0 { avPlayer.defaultRate = value }
        avPlayer.rate = value
    }

    func setResumeRate(_ rate: Float) {
        guard rate != 0 else { return }
        avPlayer.defaultRate = rate
    }

    var volume: Float {
        get { avPlayer.volume }
        set { avPlayer.volume = newValue }
    }

    /// Stage Now Playing metadata; applied immediately and replayed onto future items created by load().
    func setExternalMetadata(_ items: [AVMetadataItem]) {
        pendingExternalMetadata = items
        #if !os(macOS)
        playerItem?.externalMetadata = items
        #endif
    }

    // MARK: - Internal

    func recordItemCounters(_ counters: ItemLogCounters, item: AVPlayerItem) {
        guard playerItem === item else { return }
        itemDiagnostics?.recordCounters(counters)
    }

    private func retireItemCounters(_ reader: AVPlayerItemDiagnostics) {
        let id = ObjectIdentifier(reader)
        let baseline = reader.counters
        retiredItemTransferredBytes &+= baseline.transferredBytes ?? 0
        retiredItemDroppedFrames &+= baseline.droppedFrames ?? 0
        let generation = counterGeneration
        retiringDiagnostics[id] = reader
        reader.retire { [weak self] final, complete in
            guard let self, self.counterGeneration == generation else { return }
            self.retiredItemTransferredBytes &+= (final.transferredBytes ?? 0) - (baseline.transferredBytes ?? 0)
            self.retiredItemDroppedFrames &+= (final.droppedFrames ?? 0) - (baseline.droppedFrames ?? 0)
            self.retiringDiagnostics.removeValue(forKey: id)
            if !complete, !self.reportedIncompleteRetirement {
                self.reportedIncompleteRetirement = true
                EngineLog.emit(
                    "[NativeAVPlayerHost] retirement diagnostics backlogged; retaining last observed counters (final totals incomplete)",
                    category: .engine)
            }
        }
    }

    private func consumeDiagnostics(_ snapshot: ItemDiagnosticSnapshot, request: ItemDiagnosticRequest,
                                    reader: AVPlayerItemDiagnostics, sid: Int) {
        func isCurrent() -> Bool {
            sessionID == sid && itemDiagnostics === reader
        }
        // Both EngineLog's host handler and Combine subscribers can synchronously replace the item.
        // Cancellation fences future completions, but cannot interrupt this delivery already on-stack.
        func emit(_ line: String) -> Bool {
            guard isCurrent() else { return false }
            EngineLog.emit(line, category: .engine)
            return isCurrent()
        }
        for event in reader.newErrors(in: snapshot) {
            guard emit("[NativeAVPlayerHost] #\(sid) errorLog code=\(event.code) domain=\(event.domain) uri=\(event.uri ?? "-") '\(event.comment ?? "no comment")'") else { return }
            // #93: meaningful even when a later entry in the coalesced batch is not loader poison.
            if event.code == -15628 {
                guard emit("[NativeAVPlayerHost] #\(sid) -15628 loader poison: surfacing as stall signal") else { return }
                stallCount += 1
                guard isCurrent() else { return }
            }
        }
        if request.contains(.access) {
            for event in reader.newAccessEntries(in: snapshot) {
                guard emit("[NativeAVPlayerHost] #\(sid) accessLog uri=\(event.uri ?? "-") server=\(event.server ?? "-") bytes=\(event.bytes) reqs=\(event.requests)") else { return }
            }
        }
        if request.contains(.failure) {
            guard emit("[NativeAVPlayerHost] #\(sid) errorLog dump: \(snapshot.errors.map { "\($0.count) events" } ?? "<nil>")") else { return }
            for (idx, event) in (snapshot.errors ?? []).enumerated() {
                guard emit("[NativeAVPlayerHost] #\(sid)   errorLog[\(idx)] code=\(event.code) domain=\(event.domain) uri=\(event.uri ?? "-") server=\(event.server ?? "-") '\(event.comment ?? "no comment")'") else { return }
            }
            guard emit("[NativeAVPlayerHost] #\(sid) accessLog dump: \(snapshot.access.map { "\($0.count) events" } ?? "<nil>")") else { return }
            for (idx, event) in (snapshot.access ?? []).enumerated() {
                guard emit("[NativeAVPlayerHost] #\(sid)   accessLog[\(idx)] uri=\(event.uri ?? "-") bytes=\(event.bytes) reqs=\(event.requests) downloadOverdue=\(event.stalls) dlSegments=\(event.droppedFrames)") else { return }
            }
            for detail in snapshot.failureDetails {
                guard emit("[NativeAVPlayerHost] #\(sid) \(detail)") else { return }
            }
            if let tracks = snapshot.failedTracks, let item = playerItem {
                Task { @MainActor [weak self] in
                    guard self?.sessionID == sid else { return }
                    await Self.dumpAssetTracks(item.asset, sid: sid, reason: "item.failed")
                    guard self?.sessionID == sid else { return }
                    await Self.dumpFailedItemTracks(tracks, sid: sid)
                }
            }
        }
    }

    private func resetDiagnosticCounters() {
        counterGeneration &+= 1
        itemDiagnostics?.cancel()
        itemDiagnostics = nil
        for reader in retiringDiagnostics.values { reader.cancel() }
        retiringDiagnostics.removeAll()
        reportedIncompleteRetirement = false
        retiredItemTransferredBytes = 0
        retiredItemDroppedFrames = 0
    }

    private func unloadCurrentItem(inPlaceSwap: Bool = false) {
        // Invalidating KVO does not cancel callbacks already queued onto the main actor. Retire
        // their session now so they drop on their `sessionID == sid` guard, including during the
        // handover gap where the old item is still attached and still producing them.
        sessionID = 0
        if !inPlaceSwap {
            resetDiagnosticCounters()
        }
        if let to = timeObserver {
            avPlayer.removeTimeObserver(to)
            timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        waitingReasonObservation?.invalidate()
        waitingReasonObservation = nil
        seekableObservation?.invalidate()
        seekableObservation = nil
        layerReadyObservation?.invalidate()
        layerReadyObservation = nil
        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        notificationObservers.removeAll()
        // Clear terminal flags: keepNativeHost reload reuses the host and @Published replays on subscribe; stale failure/didReachEnd corrupt the new session (issue #15).
        failure = nil
        // Audit Vcore-102: the same replay would hand the successor's sinks this item's refusal.
        pendingDisplayRejection = nil
        pendingSoftwarePathEscalation = nil
        didReachEnd = false
        // #315: same reason. The layer itself still reads true for a few tens of ms past this point
        // (AVFoundation clears it after the swap), so the published value leads the layer here on
        // purpose: the outgoing item's picture is not this session's.
        isVideoReadyForDisplay = false
        // AE#287: the recovery budget is per item, not per host.
        prematureEndRecoveryAttempts = 0
        lastPrematureEndRecoveryPlayhead = nil
        prematureEndRecoveryInFlight = false
        didSampleSettledRoute = false
        // #168: a reused host must not report the prior session's dynamic range before the new item resolves.
        detectedVideoFormat = nil
        detectedVideoFrameRate = nil
        detectedVideoCodecName = nil
        detectedVideoDescription = nil
        detectedAudioTracks = []
        // #168 follow-up: the carriage verdict belongs to the outgoing item.
        carriageWatchdogTask?.cancel()
        carriageWatchdogTask = nil
        ingestFallbackArmed = false
        remoteHLSVideoCarriageRejected = false
        remoteHLSOriginRefused = false
        carriageProbeTask?.cancel()
        carriageProbeTask = nil
        carriageProbeEvidence = .pending
        // #334: the deadline belongs to the outgoing item too.
        readinessDeadlineTask?.cancel()
        readinessDeadlineTask = nil
        readinessDeadlineSeconds = nil
        // Re-arm #50 hasEverPlayed: reused host must not inherit prior session's established state.
        hasEverPlayed = false
        // #93 recovery reload: same content, same position, playback must continue. Skip the
        // pause + nil-item gap below (PiP content-source invalidation + transport bounce); the
        // old item keeps playing until replaceCurrentItem swaps in the fresh one, and playIntent
        // stays latched so the new item's readyToPlay re-asserts play().
        if inPlaceSwap {
            isReady = false
            return
        }
        // Pause before item swap: keepNativeHost reload carries rate=1.0 across replaceCurrentItem; without this the new item auto-resumes and beats the waitForSwitch gate (audio leads video on episode autoplay, issue #15).
        // Clear playIntent so the previous session can't restart the next item at ITS readyToPlay.
        playIntent = false
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        playerItem = nil
        isReady = false
        currentTime = 0
        renderedTime = 0
        duration = 0
        rate = 0
        // The observation was invalidated above, so the pause just issued is never published. Left at the
        // outgoing item's `.playing`, the next session's sink reads a roll on subscribe and then publishes
        // its own pre-roll `.paused` as a real pause (a host raises its transport on it).
        timeControlStatus = .paused
        // The AVAudioSession is NOT released here. Teardown ordering is the engine's call, not the host's:
        // AetherEngine.stopInternal deactivates once every render path is quiesced (#215).
    }

    /// Dump asset URL + track FourCCs on .failed and asset.load failure; d9b8aa5 added the asset.load path because item.status never went .failed in DrHurt's P5 MKV session.
    // async: AVAsset.tracks and AVAssetTrack.formatDescriptions/isEnabled/isPlayable are load-based in
    // current SDKs (the synchronous accessors are deprecated). @MainActor (implicit on this @MainActor
    // type) so the AVAsset/AVAssetTrack reads stay on the main actor.
    private static func dumpAssetTracks(_ asset: AVAsset, sid: Int, reason: String) async {
        if let urlAsset = asset as? AVURLAsset {
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.url=\(urlAsset.url.absoluteString) (\(reason))", category: .engine)
        }
        let tracks = (try? await asset.load(.tracks)) ?? []
        if tracks.isEmpty {
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.tracks empty (\(reason))", category: .engine)
            return
        }
        for track in tracks {
            let fourcc: String
            var extra = ""
            if let cm = (try? await track.load(.formatDescriptions))?.first {
                fourcc = fourccString(CMFormatDescriptionGetMediaSubType(cm))
                if track.mediaType == .audio {
                    extra = " " + audioFormatDescription(cm)
                }
            } else {
                fourcc = "?"
            }
            let enabled = (try? await track.load(.isEnabled)) ?? false
            let playable = (try? await track.load(.isPlayable)) ?? false
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.track type=\(track.mediaType.rawValue) codec='\(fourcc)' enabled=\(enabled) playable=\(playable)\(extra) (\(reason))", category: .engine)
        }
    }

    /// Dump item.tracks at readyToPlay (HLS: asset.tracks is empty; item.tracks has the resolved list after playlist+init.mp4 parse). Channel layout tag diagnoses multichannel-routing path.
    private static func dumpPlayerItemTracks(_ item: AVPlayerItem, sid: Int) async {
        let tracks = item.tracks
        if tracks.isEmpty {
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.tracks empty (readyToPlay)", category: .engine)
            return
        }
        for itemTrack in tracks {
            guard let assetTrack = itemTrack.assetTrack else { continue }
            let fourcc: String
            var extra = ""
            if let cm = (try? await assetTrack.load(.formatDescriptions))?.first {
                fourcc = fourccString(CMFormatDescriptionGetMediaSubType(cm))
                if assetTrack.mediaType == .audio {
                    extra = " " + audioFormatDescription(cm)
                } else if assetTrack.mediaType == .video {
                    extra = " " + videoFormatDescription(cm)
                }
            } else {
                fourcc = "?"
            }
            let trackLabel: String
            if assetTrack.mediaType == .audio {
                trackLabel = "audioTrack"
            } else if assetTrack.mediaType == .video {
                trackLabel = "videoTrack"
            } else {
                continue
            }
            EngineLog.emit(
                "[NativeAVPlayerHost] #\(sid) item.\(trackLabel) codec='\(fourcc)' "
                + "enabled=\(itemTrack.isEnabled)\(extra) (readyToPlay)",
                category: .engine
            )
        }
    }

    /// AE#293: read the carriage off the source itself (playlist plus, where the playlists cannot settle
    /// it, the first segment's PMT) while the native mount runs, so the #168 verdict does not cost a mount
    /// plus the watchdog grace on every first open. Gated on AVFoundation's own master parse, which is
    /// already fetched and therefore free: only a codec the HLS Authoring Spec sanctions in fMP4 alone, or
    /// a source with no master evidence at all, reaches the network here. The verdict feeds the same
    /// watchdog; it never fires on its own.
    ///
    /// AE#296: the two stages run at different times, because they cost different things. Playlists are
    /// not what a per-token connection cap counts, so the playlist stage runs against the mount; a segment
    /// fetch is, so it waits for readyToPlay (see `awaitReadyForDeferredProbe`).
    @MainActor
    private func startCarriageProbe(asset: AVURLAsset, url: URL, httpHeaders: [String: String]) {
        let sid = sessionID
        carriageProbeTask = Task { @MainActor [weak self] in
            let variants = (try? await asset.load(.variants)) ?? []
            guard self?.sessionID == sid, !Task.isCancelled else { return }
            let advertises = RemoteHLSIngestFallback.advertisesVideo(
                variantHasVideoAttributes: variants.map { $0.videoAttributes != nil })
            let codecs = variants.compactMap { $0.videoAttributes }.flatMap { $0.codecTypes }
            guard RemoteHLSIngestFallback.shouldProbeCarriage(
                advertisesVideo: advertises, advertisedVideoCodecs: codecs) else { return }
            let evidence = await HLSCarriageProbe.classifyFromPlaylists(
                playlistURL: url,
                httpHeaders: httpHeaders,
                advertisesFragmentedMP4OnlyVideo:
                    RemoteHLSIngestFallback.advertisesFragmentedMP4OnlyVideo(codecs)
            )
            guard let self, !Task.isCancelled, self.sessionID == sid else { return }
            switch evidence {
            case .settled(let verdict):
                self.publishCarriageProbeVerdict(verdict, sid: sid, from: "playlist")
            case .needsSegmentHead(let segmentURL):
                EngineLog.emit(
                    "[NativeAVPlayerHost] #\(sid) carriage probe: the playlists cannot settle this one, "
                    + "so the segment head waits for readyToPlay rather than compete with the mount (#296)",
                    category: .engine
                )
                switch await self.awaitReadyForDeferredProbe(sid: sid) {
                case .abandoned:
                    return
                case .ceilingExpired:
                    // #334: readiness is not coming. Deferring existed so the read would not compete
                    // with the mount, and a mount that has not settled in 20 s is not competing for
                    // anything; giving up here is what left the source unjudged and the session silent.
                    EngineLog.emit(
                        "[NativeAVPlayerHost] #\(sid) carriage probe: readyToPlay never arrived, "
                        + "reading the segment head anyway rather than leaving the source unjudged (#334)",
                        category: .engine
                    )
                case .ready:
                    break
                }
                let verdict = await HLSCarriageProbe.classifyDeferredSegmentHead(
                    url: segmentURL, httpHeaders: httpHeaders, credentialOrigin: url)
                guard !Task.isCancelled, self.sessionID == sid else { return }
                self.publishCarriageProbeVerdict(verdict, sid: sid, from: "segment PMT")
            }
        }
    }

    @MainActor
    private func publishCarriageProbeVerdict(
        _ verdict: MPEGTransportStreamCodecProbe.Verdict, sid: Int, from source: String
    ) {
        carriageProbeEvidence = verdict == .hevcInMPEGTS ? .transportStreamHEVC : .nativeCapable
        // #334: a settled verdict is conclusive without the grace, so it must not wait for the timing
        // loop that arms at readyToPlay. A source with no audio track either never reaches readiness at
        // all, and that is precisely the session this verdict is the only fix for.
        if RemoteHLSIngestFallback.shouldRerouteOnSettledEvidence(
            carriageEvidence: carriageProbeEvidence,
            videoTrackCount: currentVideoTrackCount(),
            armed: ingestFallbackArmed,
            alreadyRejected: remoteHLSVideoCarriageRejected
        ) {
            EngineLog.emit(
                "[NativeAVPlayerHost] #\(sid) carriage probe: \(verdict) from \(source) evidence; "
                + "rerouting without waiting for readyToPlay (#334)",
                category: .engine
            )
            carriageWatchdogTask?.cancel()
            carriageWatchdogTask = nil
            remoteHLSVideoCarriageRejected = true
            return
        }
        EngineLog.emit(
            "[NativeAVPlayerHost] #\(sid) carriage probe: \(verdict) from \(source) evidence (#293)",
            category: .engine
        )
    }

    /// #334: the wait has three outcomes, because "readiness never came" and "this session is gone" no
    /// longer lead to the same place. Only the second abandons the probe.
    private enum DeferredProbeWait { case ready, ceilingExpired, abandoned }

    /// AE#296: hold the deferred segment-head read until the item is ready. It removes the one window
    /// where the read is expensive: a connection lost while the mount is establishing its own can cost
    /// the mount, one lost afterwards can only cost the verdict, on a session that is already black. A
    /// session whose watchdog disarms first spends no media byte at all.
    ///
    /// #334 corrected the other half of that rationale. Waiting was said to cost nothing because the
    /// verdict could not be acted on before readyToPlay anyway; it can now, and a source AVFoundation
    /// builds no track at all for never reaches readiness, so the ceiling reports itself rather than
    /// silently ending the probe.
    @MainActor
    private func awaitReadyForDeferredProbe(sid: Int) async -> DeferredProbeWait {
        var ticksWaited = 0
        while !isReady {
            guard !Task.isCancelled, sessionID == sid else { return .abandoned }
            guard ticksWaited < Self.carriageProbeReadinessTicks else { return .ceilingExpired }
            ticksWaited += 1
            try? await Task.sleep(
                nanoseconds: UInt64(Self.carriageProbeReadinessTickSeconds * 1_000_000_000))
        }
        return (!Task.isCancelled && sessionID == sid) ? .ready : .abandoned
    }

    /// Video tracks AVPlayer has actually built for the current item. Shared by the watchdog tick and
    /// the #334 pre-readiness reroute so both judge the same thing.
    @MainActor
    private func currentVideoTrackCount() -> Int {
        playerItem?.tracks.filter { $0.assetTrack?.mediaType == .video }.count ?? 0
    }

    /// #334: fail a bypass session that neither becomes ready nor fails. Runs from the mount rather than
    /// from readyToPlay for the obvious reason. Everything that resolves the session disarms it, so the
    /// budget is only ever spent by a session that was going to sit in `.loading` indefinitely.
    @MainActor
    private func startReadinessDeadline(item: AVPlayerItem, budgetSeconds: Double) {
        let sid = sessionID
        readinessDeadlineTask = Task { @MainActor [weak self] in
            var deadline = RemoteHLSReadinessDeadline(
                budgetSeconds: budgetSeconds, tickSeconds: Self.carriageWatchdogTickSeconds)
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.carriageWatchdogTickSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled, self.sessionID == sid,
                      self.playerItem === item else { return }
                switch deadline.tick(isReady: self.isReady,
                                     carriageRerouted: self.remoteHLSVideoCarriageRejected,
                                     hasFailed: self.failure != nil) {
                case .keepWaiting:
                    continue
                case .disarm:
                    return
                case .fail:
                    let message = RemoteHLSReadinessDeadline.failureMessage(budgetSeconds: budgetSeconds)
                    EngineLog.emit(
                        "[NativeAVPlayerHost] #\(sid) readiness deadline: no track, no readiness and no "
                        + "failure in \(Int(budgetSeconds.rounded()))s; surfacing a terminal state (#334)",
                        category: .engine
                    )
                    self.failure = PlaybackErrorInfo(kind: .noPlayableTrackWithinBudget, message: message)
                    return
                }
            }
        }
    }

    /// AetherEngine#168 follow-up: after readyToPlay, poll `item.tracks` at the tick cadence against the
    /// pure `RemoteHLSIngestFallback.Watchdog`. Advertisement evidence comes from `AVURLAsset.variants`,
    /// AVFoundation's own already-fetched master-playlist parse, so this adds no origin connect (IPTV
    /// tokens / WAFs). Publishes `remoteHLSVideoCarriageRejected` once when an advertised video rendition
    /// never builds an item track (HEVC-in-MPEG-TS carriage), or as soon as the #293 probe has read that
    /// carriage off the source; every healthy or judgeless outcome disarms.
    @MainActor
    private func startVideoCarriageWatchdog(item: AVPlayerItem) {
        let sid = sessionID
        carriageWatchdogTask = Task { @MainActor [weak self] in
            var watchdog = RemoteHLSIngestFallback.Watchdog()
            let variants: [AVAssetVariant]
            if let urlAsset = item.asset as? AVURLAsset {
                variants = (try? await urlAsset.load(.variants)) ?? []
            } else {
                variants = []
            }
            let advertises = RemoteHLSIngestFallback.advertisesVideo(
                variantHasVideoAttributes: variants.map { $0.videoAttributes != nil })
            while !Task.isCancelled {
                guard let self, self.playerItem === item else { return }
                let videoTrackCount = self.currentVideoTrackCount()
                let evidence = self.carriageProbeEvidence
                switch watchdog.tick(
                    videoTrackCount: videoTrackCount,
                    variantsAdvertiseVideo: advertises,
                    carriageEvidence: evidence
                ) {
                case .keepWaiting:
                    break
                case .disarm:
                    self.carriageProbeTask?.cancel()
                    EngineLog.emit(
                        "[NativeAVPlayerHost] #\(sid) carriage watchdog disarmed "
                        + "(videoTracks=\(videoTrackCount) advertised=\(advertises.map { "\($0)" } ?? "unknown"))",
                        category: .engine
                    )
                    return
                case .fire:
                    if evidence == .transportStreamHEVC {
                        let saved = watchdog.remainingGraceSeconds(tickInterval: Self.carriageWatchdogTickSeconds)
                        EngineLog.emit(
                            "[NativeAVPlayerHost] #\(sid) the source's own PMT declares HEVC in MPEG-TS, "
                            + "so AVPlayer will build no video track; rerouting "
                            + "\(String(format: "%.1f", saved))s before the watchdog grace would have "
                            + "concluded the same (#293)",
                            category: .engine
                        )
                    } else {
                        EngineLog.emit(
                            "[NativeAVPlayerHost] #\(sid) master advertises video "
                            + "(\(variants.count) variant(s)) but AVPlayer built no video track after grace; "
                            + "HEVC-in-MPEG-TS carriage suspected (#168)",
                            category: .engine
                        )
                    }
                    self.remoteHLSVideoCarriageRejected = true
                    return
                }
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.carriageWatchdogTickSeconds * 1_000_000_000))
            }
        }
    }

    /// AetherEngine#168: read the item's video-track dynamic range back from AVPlayer's parsed
    /// CMFormatDescription and publish it, so the probe-free `nativeRemoteHLS` bypass can report the real
    /// format instead of the `.sdr` default. Called at readyToPlay and again at first `.playing` (an HLS
    /// video track can be absent from `item.tracks` at the readyToPlay instant). No-op for the item once it
    /// has been replaced; leaves `detectedVideoFormat` nil while no video track resolves (audio-only black).
    ///
    /// AE#515: this runs on every native session, the loopback route included, where the engine reads it
    /// as a Dolby Vision label upgrade rather than as the format itself. The line used to name itself
    /// `remote-HLS` on both, which cost a reporter time on a log where the route was the question.
    @MainActor
    private func publishDetectedVideoFormat(from item: AVPlayerItem) async {
        let sid = sessionID
        guard sid != 0, playerItem === item else { return }
        for itemTrack in item.tracks {
            guard let assetTrack = itemTrack.assetTrack, assetTrack.mediaType == .video else { continue }
            guard let cm = try? await assetTrack.load(.formatDescriptions).first else { continue }
            let rate = (try? await assetTrack.load(.nominalFrameRate)).map(Double.init)
            guard sessionID == sid, playerItem === item else { return }
            let subType = CMFormatDescriptionGetMediaSubType(cm)
            let ext = CMFormatDescriptionGetExtensions(cm) as? [String: Any] ?? [:]
            let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            let fmt = RemoteHLSFormatDetection.videoFormat(transferFunction: transfer, videoSubType: subType)
            // Rate, codec and description before format: the engine's format sink reads them when it fires.
            if let rate, rate > 0 { detectedVideoFrameRate = rate }
            detectedVideoCodecName = RemoteHLSFormatDetection.codecName(videoSubType: subType)
            let description = RemoteHLSStreamDescription.video(from: cm)
            if detectedVideoDescription != description { detectedVideoDescription = description }
            if detectedVideoFormat != fmt {
                detectedVideoFormat = fmt
                EngineLog.emit(
                    "[NativeAVPlayerHost] #\(sessionID) item videoFormat=\(fmt) "
                    + "subType='\(fourccString(subType))' transfer=\(transfer ?? "nil") "
                    + "rate=\(rate.map { String(format: "%.3f", $0) } ?? "nil")",
                    category: .engine
                )
            }
            return
        }
    }

    /// The audio half of the read above, at the same two points. Language comes from the track, and where
    /// the track has none (muxed HLS audio rarely does) from the audible option AVPlayer selected.
    @MainActor
    private func publishDetectedAudioTracks(from item: AVPlayerItem) async {
        let sid = sessionID
        guard sid != 0, playerItem === item, sessionContract.readsBackAudioTracks else { return }
        var selectedOptionLanguage: String?
        if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
           let option = item.currentMediaSelection.selectedMediaOption(in: group) {
            selectedOptionLanguage = option.extendedLanguageTag
        }
        var readings: [RemoteHLSStreamDescription.AudioReading] = []
        for itemTrack in item.tracks {
            guard let assetTrack = itemTrack.assetTrack, assetTrack.mediaType == .audio else { continue }
            guard let cm = try? await assetTrack.load(.formatDescriptions).first else { continue }
            let extendedTag = try? await assetTrack.load(.extendedLanguageTag)
            let languageCode = try? await assetTrack.load(.languageCode)
            let language = [extendedTag ?? nil, languageCode ?? nil, selectedOptionLanguage]
                .compactMap { $0 }.first { !$0.isEmpty && $0 != "und" }
            if let reading = RemoteHLSStreamDescription.audioReading(
                from: cm, isEnabled: itemTrack.isEnabled, language: language) {
                readings.append(reading)
            }
        }
        guard sessionID == sid, playerItem === item else { return }
        if detectedAudioTracks != readings { detectedAudioTracks = readings }
    }

    /// Compact video track summary: dimensions + color attachments (primaries/transfer/matrix). Mismatch vs source-side codecpar signals DV/HDR signaling didn't survive the muxer.
    /// Dump item.tracks on .failed (FourCC per track). Async: AVAssetTrack.formatDescriptions is
    /// load-based; assetTrack access is main-actor.
    private static func dumpFailedItemTracks(_ tracks: [AVPlayerItemTrack], sid: Int) async {
        EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.tracks count=\(tracks.count)", category: .engine)
        for (idx, itrack) in tracks.enumerated() {
            let assetTrack = itrack.assetTrack
            let mediaType = assetTrack?.mediaType.rawValue ?? "?"
            var fdesc: CMFormatDescription?
            if let assetTrack {
                fdesc = (try? await assetTrack.load(.formatDescriptions))?.first
            }
            let fourCC: String
            if let cm = fdesc {
                let code = CMFormatDescriptionGetMediaSubType(cm)
                let b: [UInt8] = [
                    UInt8((code >> 24) & 0xff),
                    UInt8((code >> 16) & 0xff),
                    UInt8((code >> 8) & 0xff),
                    UInt8(code & 0xff),
                ]
                fourCC = String(bytes: b.map { ($0 >= 0x20 && $0 < 0x7f) ? $0 : 0x2e }, encoding: .ascii) ?? "????"
            } else {
                fourCC = "<no fdesc>"
            }
            EngineLog.emit("[NativeAVPlayerHost] #\(sid)   item.tracks[\(idx)] mediaType=\(mediaType) fourCC=\(fourCC) enabled=\(itrack.isEnabled)", category: .engine)
        }
    }

    nonisolated private static func videoFormatDescription(_ fmt: CMFormatDescription) -> String {
        var parts: [String] = []
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        parts.append("dim=\(dims.width)x\(dims.height)")
        let extensions = CMFormatDescriptionGetExtensions(fmt) as? [String: Any] ?? [:]
        if let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String {
            parts.append("primaries=\(primaries)")
        }
        if let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String {
            parts.append("transfer=\(transfer)")
        }
        if let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String {
            parts.append("matrix=\(matrix)")
        }
        if let fullRange = extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool {
            parts.append("fullRange=\(fullRange)")
        }
        return parts.joined(separator: " ")
    }

    /// Warn when the FLAC bridge produced N-channel LPCM but the route carries fewer channels. FLAC bridge decodes to LPCM (unlike stream-copy EAC3/AC3 which tunnels encoded); Sonos Arc reports ch=2 LPCM even with eARC. Not a bridge bug -- a route capability mismatch.
    private static func warnIfFLACSurroundExceedsRoute(_ item: AVPlayerItem, sid: Int) async {
        #if os(iOS) || os(tvOS)
        var trackChannels: Int = 0
        var isFLAC = false
        for itemTrack in item.tracks {
            guard let assetTrack = itemTrack.assetTrack else { continue }
            guard assetTrack.mediaType == .audio else { continue }
            guard let cm = try? await assetTrack.load(.formatDescriptions).first else { continue }
            let codec = fourccString(CMFormatDescriptionGetMediaSubType(cm))
            if codec.lowercased() == "flac" {
                isFLAC = true
                if let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(cm) {
                    trackChannels = Int(asbdPtr.pointee.mChannelsPerFrame)
                }
                break
            }
        }
        guard isFLAC, trackChannels > 2 else { return }
        let session = AVAudioSession.sharedInstance()
        let routeChannels = max(
            session.currentRoute.outputs.first?.channels?.count ?? 0,
            session.outputNumberOfChannels
        )
        guard routeChannels > 0, routeChannels < trackChannels else { return }
        EngineLog.emit(
            "[NativeAVPlayerHost] #\(sid) WARNING: FLAC bridge produced \(trackChannels)-channel "
            + "LPCM but active audio route carries only \(routeChannels) LPCM channels, tvOS "
            + "will downmix. Common cause: soundbars (Sonos Arc, etc.) accept multichannel only "
            + "via bitstream codecs (EAC3, Atmos, DD+), not LPCM. Stream-copy paths bypass this; "
            + "TrueHD / DTS-HD MA sources route through the FLAC bridge and hit the LPCM limit. "
            + "AVRs with 7.1 LPCM-over-HDMI support play these sources at full source channel "
            + "count without downmix.",
            category: .session
        )
        #endif
    }

    /// Warn when EAC3/AC3 multichannel plays into a stereo-only HDMI route. Cause: Sonos Arc reports
    /// ch=2 LPCM after boot or HDMI handshake glitch; fix is power-cycling the sink. Not a pipeline
    /// bug (dec3 bitstream is identical across runs).
    ///
    /// AE#520: Atmos is excluded, and until this the exclusion existed only in the docstring and in
    /// the warning's own closing sentence. Every EAC3+JOC session matches the condition by
    /// construction, because a 6-channel `ec-3` track tunnelling through a 2-channel MAT carrier is
    /// what correct Atmos passthrough looks like, so the line fired on exactly the sessions it then
    /// told the reader to ignore it for. The reporter had to reason it away himself while chasing a
    /// real defect. The route cannot answer this (a MAT carrier and a stereo LPCM route both report
    /// two channels); the session can, and now says so through the contract.
    private static func warnIfEAC3SurroundOnStereoRoute(_ item: AVPlayerItem, sid: Int,
                                                        isAtmosStreamCopy: Bool) async {
        #if os(iOS) || os(tvOS)
        guard !isAtmosStreamCopy else { return }
        var trackChannels: Int = 0
        var codecID: String = ""
        for itemTrack in item.tracks {
            guard let assetTrack = itemTrack.assetTrack else { continue }
            guard assetTrack.mediaType == .audio else { continue }
            guard let cm = try? await assetTrack.load(.formatDescriptions).first else { continue }
            let codec = fourccString(CMFormatDescriptionGetMediaSubType(cm))
            let lower = codec.lowercased()
            if lower == "ec-3" || lower == "ac-3" {
                codecID = codec
                if let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(cm) {
                    trackChannels = Int(asbdPtr.pointee.mChannelsPerFrame)
                }
                break
            }
        }
        guard !codecID.isEmpty, trackChannels > 2 else { return }
        let session = AVAudioSession.sharedInstance()
        let routeChannels = max(
            session.currentRoute.outputs.first?.channels?.count ?? 0,
            session.outputNumberOfChannels
        )
        guard routeChannels > 0, routeChannels < trackChannels else { return }
        EngineLog.emit(
            "[NativeAVPlayerHost] #\(sid) WARNING: \(codecID) \(trackChannels)-channel "
            + "track playing into a \(routeChannels)-channel route. tvOS will downmix to "
            + "\(routeChannels) channels. The encoded bitstream is correct (dec3/dac3 reports "
            + "5.1 with acmod=7+lfeon=1, packets carry the full multichannel content). The "
            + "route limit comes from the HDMI sink's current capability advertisement, not "
            + "from this engine. Common cause on soundbars: HDMI handshake landed in stereo "
            + "PCM mode after a reboot or audio-format change. Atmos (EAC3+JOC) is unaffected "
            + "because it tunnels through a 2-channel MAT carrier. Power cycle the sink or "
            + "flip Apple TV's audio format setting once to re-negotiate ch=6 LPCM / EAC3 "
            + "passthrough.",
            category: .session
        )
        #endif
    }

    /// Dump audio route channel capability post-load (route renegotiates on asset load; pre-load poll is stale). outputNumberOfChannels is the actual LPCM limit; EAC3/Atmos bypasses it via bitstream tunnel.
    nonisolated private static func dumpAudioRoute(sid: Int, phase: String) {
        // AE#684: the route's own latency rides on the line, per item, beside the item's start.
        guard let route = AudioRouteDescription.current() else { return }
        EngineLog.emit("[NativeAVPlayerHost] #\(sid) audioRoute \(route) (\(phase))", category: .engine)
    }

    /// Read sr/ch/bits/layoutTag from CMAudioFormatDescription. Layout tag diagnoses where downmix occurs: unknown/stereo tag = AVPlayer parse layer; correct 7.1 tag = route/soundbar layer.
    nonisolated private static func audioFormatDescription(_ fmt: CMFormatDescription) -> String {
        var parts: [String] = []
        if let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
            let asbd = asbdPtr.pointee
            parts.append("sr=\(RemoteHLSStreamDescription.wholeSampleRate(asbd.mSampleRate))")
            parts.append("ch=\(asbd.mChannelsPerFrame)")
            parts.append(String(format: "bits=%d", asbd.mBitsPerChannel))
            parts.append("fmt=\(fourccString(asbd.mFormatID))")
        }
        var layoutSize = 0
        if let layoutPtr = CMAudioFormatDescriptionGetChannelLayout(fmt, sizeOut: &layoutSize),
           layoutSize >= MemoryLayout<AudioChannelLayout>.size {
            let layout = layoutPtr.pointee
            parts.append("layoutTag=0x\(String(layout.mChannelLayoutTag, radix: 16))")
            if layout.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
                parts.append("descs=\(layout.mNumberChannelDescriptions)")
            }
        } else {
            parts.append("layoutTag=<missing>")
        }
        return parts.joined(separator: " ")
    }

}

extension NativeAVPlayerHost {
    /// AE#495: classify a failed item before publishing it. AVFoundation's own error is what
    /// `item.error` reports (`-11800` and friends), and a refused certificate rides one or two levels
    /// below it in `NSUnderlyingErrorKey`, so a host reading domain and code alone sees AVFoundation
    /// giving up and nothing about why. Everything that is not a trust refusal keeps
    /// `nativeItemFailed` exactly as before.
    ///
    /// `relayRefusalCode` is the same verdict reached one hop away. With the AE#495 relay mounted the
    /// player's request went to loopback and came back a plain 502, so the chain it would have been
    /// read off no longer exists on this side; the relay lost the handshake and remembers it.
    nonisolated static func itemFailureInfo(desc: String, itemError: Error?,
                                            relayRefusalCode: Int? = nil) -> PlaybackErrorInfo {
        if let code = TransportSecurityFailure.code(in: itemError) ?? relayRefusalCode {
            return PlaybackErrorInfo(kind: .sourceCertificateRejected,
                                     message: TransportSecurityFailure.sentence(for: code),
                                     underlyingDomain: NSURLErrorDomain,
                                     underlyingCode: code)
        }
        return PlaybackErrorInfo(kind: .nativeItemFailed, message: desc, underlying: itemError)
    }
}
