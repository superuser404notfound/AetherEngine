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
@MainActor
final class NativeAVPlayerHost {

    // MARK: - Published state

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    /// AVPlayer's actually-rendered position (pre-seek parked frame during in-flight seeks). Folded to clock.sourceTime so subtitle overlay tracks the picture, not the scrub target (issue #49).
    @Published private(set) var renderedTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    @Published private(set) var failureMessage: String?
    /// #50: monotonic token; bumped on each deferred .failed so a superseding failure or item swap cancels the in-flight confirmation.
    private var failureConfirmToken: Int = 0
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

    /// Set per load; gates the AE#287 premature-end recovery, which only makes sense for a fixed-length
    /// presentation. A live session has no advertised end to fall short of.
    private var isLiveSession: Bool = false
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

    /// Published when a startup `.failed` is a display-rejection of the served master (#98). The
    /// engine's fallback subscriber reads it, decides, and either reloads the media playlist or
    /// surfaces the failure. Reset on each load.
    @Published private(set) var pendingDisplayRejection: DisplayRejection?

    /// AetherEngine#168: dynamic range read back from the item's parsed video-track CMFormatDescription,
    /// so the probe-free `nativeRemoteHLS` bypass can report the real format instead of the `.sdr` default.
    /// nil until a video track resolves (or when none does: the audio-only black-screen symptom). The
    /// engine's remote-HLS load subscribes and mirrors it into `sourceVideoFormat` / `videoFormat` and, for
    /// HDR, programs `preferredDisplayCriteria` (the panel switch AVPlayer needs to present HDR at all).
    @Published private(set) var detectedVideoFormat: VideoFormat?

    /// AetherEngine#168: the same-read nominal frame rate, so the engine's remote-HLS criteria also carry
    /// Match Frame Rate (the reporter's 4K item is 50 fps). nil when no video track / rate resolves.
    @Published private(set) var detectedVideoFrameRate: Double?

    /// AetherEngine#168 follow-up: fires once when the armed carriage watchdog concludes the master
    /// advertises a video rendition but AVPlayer never built a video track past the grace window
    /// (HEVC-in-MPEG-TS carriage, which AVFoundation's HLS demuxer does not support). The engine's
    /// remote-HLS load subscribes and reroutes the session onto the loopback live-ingest path.
    @Published private(set) var remoteHLSVideoCarriageRejected = false
    /// Set per load; the watchdog itself starts at readyToPlay (a dead origin never reaches it).
    private var carriageWatchdogArmed = false
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

    // MARK: - Output

    /// AVPlayerLayer attached to the bound AetherPlayerView; reused across replaceCurrentItem swaps.
    let playerLayer: AVPlayerLayer

    let avPlayer: AVPlayer

    // MARK: - Private state

    private var playerItem: AVPlayerItem?
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
    private var seekableObservation: NSKeyValueObservation?
    /// Diagnostic: isReadyForDisplay is the only signal for first-frame-on-screen; t+ stamps localize the audio-leads-black-video gap.
    private var layerReadyObservation: NSKeyValueObservation?
    /// t+ reference for startup diagnostics; written on MainActor, read off-main from KVO -- diagnostic-only, a torn read is harmless.
    nonisolated(unsafe) private var loadStartTime = DispatchTime.now()
    private var notificationObservers: [NSObjectProtocol] = []
    private var accessLogCount = 0

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

    init(ownsNowPlayingSession: Bool = false) {
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

    /// Load the loopback HLS-fMP4 URL into AVPlayer. DisplayCriteriaController.apply must run first so the HDR pipeline is configured before the first segment fetch.
    /// `inPlaceSwap`: atomic same-content item swap for the #93 recovery reload. The default
    /// teardown pauses and drops the current item to nil before the new one exists; during PiP
    /// that nil-item gap invalidates AVKit's content source (the PiP window was dismissed ~16 s
    /// after an in-PiP recovery reload) and the pause bounces transport for nothing. The swap
    /// keeps transport intent, clocks and the old item alive until replaceCurrentItem hands
    /// AVPlayer the fresh one.
    func load(url: URL, startPosition: Double?, perFrameHDR: Bool = true, skipInitialSeek: Bool = false, forwardBufferDuration: Double = 4.0, surfaceEndFailures: Bool = false, inPlaceSwap: Bool = false, httpHeaders: [String: String] = [:], armVideoCarriageWatchdog: Bool = false, readinessDeadline: Double? = nil, isLive: Bool = false) {
        unloadCurrentItem(inPlaceSwap: inPlaceSwap)

        self.surfaceEndFailures = surfaceEndFailures
        self.carriageWatchdogArmed = armVideoCarriageWatchdog
        self.readinessDeadlineSeconds = readinessDeadline
        self.isLiveSession = isLive
        Self.nextSessionID += 1
        sessionID = Self.nextSessionID
        let sid = sessionID
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
            Task { @MainActor in self?.isVideoReadyForDisplay = ready }
        }

        let asset = AVURLAsset(url: url, options: Self.assetCreationOptions(httpHeaders: httpHeaders))
        let item = AVPlayerItem(asset: asset)
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
        if armVideoCarriageWatchdog {
            startCarriageProbe(asset: asset, url: url, httpHeaders: httpHeaders)
        }
        playerItem = item
        accessLogCount = 0
        failureMessage = nil
        pendingDisplayRejection = nil
        lastSuppressedStartupFailure = nil
        isReady = false
        seekableEnd = 0
        // #334: the bypass's ceiling on silence. Started with the mount rather than at readyToPlay,
        // because the session it exists for is exactly the one that never gets there.
        if let budget = readinessDeadline {
            startReadinessDeadline(item: item, budgetSeconds: budget)
        }

        // #134: mirror seekableTimeRanges instead of reading it per call. The callback runs on
        // the item's queue where the re-read is a harmless off-main XPC; live playlist refreshes
        // keep it current, including while paused.
        seekableObservation = item.observe(\.seekableTimeRanges, options: [.initial, .new]) { [weak self] item, _ in
            let end = Self.seekableEnd(from: item.seekableTimeRanges)
            Task { @MainActor in self?.seekableEnd = end }
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
                // Poll full errorLog on .failed (notification observer misses synchronous entries during replaceCurrentItem).
                if let log = item.errorLog() {
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) errorLog dump: \(log.events.count) events", category: .engine)
                    for (idx, event) in log.events.enumerated() {
                        let comment = event.errorComment ?? "no comment"
                        let uri = event.uri ?? "-"
                        let server = event.serverAddress ?? "-"
                        EngineLog.emit("[NativeAVPlayerHost] #\(sid)   errorLog[\(idx)] code=\(event.errorStatusCode) domain=\(event.errorDomain) uri=\(uri) server=\(server) '\(comment)'", category: .engine)
                    }
                } else {
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) errorLog dump: <nil>", category: .engine)
                }
                if let log = item.accessLog() {
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) accessLog dump: \(log.events.count) events", category: .engine)
                    for (idx, event) in log.events.enumerated() {
                        let uri = event.uri ?? "-"
                        EngineLog.emit("[NativeAVPlayerHost] #\(sid)   accessLog[\(idx)] uri=\(uri) bytes=\(event.numberOfBytesTransferred) reqs=\(event.numberOfMediaRequests) downloadOverdue=\(event.numberOfStalls) dlSegments=\(event.numberOfDroppedVideoFrames)", category: .engine)
                    }
                } else {
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) accessLog dump: <nil>", category: .engine)
                }
                // AVAsset/AVAssetTrack track info is load-based + main-actor in current SDKs; dump it off
                // the KVO callback on the main actor (HLS asset.tracks is empty; item.tracks shows what
                // AVPlayer built from the playlist before init.mp4 parse).
                Task { @MainActor in
                    await Self.dumpAssetTracks(item.asset, sid: sid, reason: "item.failed")
                    await Self.dumpFailedItemTracks(item, sid: sid)
                }
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.presentationSize=\(item.presentationSize)", category: .engine)
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.seekableTimeRanges.count=\(item.seekableTimeRanges.count)", category: .engine)
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.loadedTimeRanges.count=\(item.loadedTimeRanges.count)", category: .engine)
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.canPlayFastForward=\(item.canPlayFastForward) canPlayFastReverse=\(item.canPlayFastReverse) canStepForward=\(item.canStepForward)", category: .engine)
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.duration=\(item.duration.seconds.isFinite ? String(format: "%.2f", item.duration.seconds) : "indef")", category: .engine)
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.appliesPerFrameHDRDisplayMetadata=\(item.appliesPerFrameHDRDisplayMetadata)", category: .engine)
            } else if item.status == .readyToPlay {
                // HLS: asset.tracks is empty; dump item.tracks for audio codec/layout. Route not warned yet: stereo-idle sinks (Continuous Audio off) read ch=2 until first .playing (issue #24).
                Task { @MainActor in
                    await Self.dumpPlayerItemTracks(item, sid: sid)
                    Self.dumpAudioRoute(sid: sid, phase: "readyToPlay, route may still be negotiating")
                }
            }

            Task { @MainActor in
                guard let self = self else { return }
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
                    // #168: publish the item's real dynamic range for the probe-free remote-HLS badge.
                    await self.publishDetectedVideoFormat(from: item)
                    // #168 follow-up: watch for an advertised video rendition that never builds a track
                    // (HEVC-in-MPEG-TS carriage); anchored at readyToPlay so dead origins never arm it.
                    if self.carriageWatchdogArmed, self.carriageWatchdogTask == nil {
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
                self?.rate = rate
            }
        }

        // timeControlStatus + reasonForWaitingToPlay diagnose "spinner forever" -- reason surfaces the exact stall cause.
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
                guard let self = self else { return }
                // AE#287: swallow the pause AVPlayer takes while a premature-end recovery re-seeks.
                if status == .paused, self.prematureEndRecoveryInFlight { return }
                self.timeControlStatus = status
                // First .playing: re-sample route after 2.5s settle -- AVKit only negotiates HDMI format on playback start (issue #24).
                if status == .playing { self.hasEverPlayed = true }
                if status == .playing, !self.didSampleSettledRoute {
                    self.didSampleSettledRoute = true
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        guard let self = self, let item = self.playerItem else { return }
                        Self.dumpAudioRoute(sid: sid, phase: "settled")
                        await Self.warnIfFLACSurroundExceedsRoute(item, sid: sid)
                        await Self.warnIfEAC3SurroundOnStereoRoute(item, sid: sid)
                        // #168: the video track can be absent from item.tracks at readyToPlay for HLS;
                        // re-read once playing so the remote-HLS badge settles on the real dynamic range.
                        await self.publishDetectedVideoFormat(from: item)
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
                guard let self = self, let event = self.playerItem?.errorLog()?.events.last else { return }
                let comment = event.errorComment ?? "no comment"
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) errorLog code=\(event.errorStatusCode) domain=\(event.errorDomain) uri=\(event.uri ?? "-") '\(comment)'", category: .engine)
                // #93 startup: -15628 is the loader-poison signature. Before the first frame no
                // playbackStalled will ever fire (playback never started), so the stall-driven
                // dead-consumer watchdog would never arm; surface the poison as a stall signal.
                // The watchdog's own guards (fetches frozen, waitingToPlay, item healthy) drop
                // transients where the loader in fact survived.
                if event.errorStatusCode == -15628 {
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) -15628 loader poison: surfacing as stall signal", category: .engine)
                    self.stallCount += 1
                }
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
                guard let self = self,
                      self.accessLogCount < 5,
                      let event = self.playerItem?.accessLog()?.events.last else { return }
                self.accessLogCount += 1
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) accessLog uri=\(event.uri ?? "-") server=\(event.serverAddress ?? "-") bytes=\(event.numberOfBytesTransferred) reqs=\(event.numberOfMediaRequests)", category: .engine)
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
                guard let self else { return }
                // AE#287: AVPlayer ends a VOD the moment its video renderer runs dry, even with the
                // audio-only tail still ahead. Recover before `.ended` latches; it is terminal.
                if await self.recoverFromPrematureEnd() { return }
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
                guard let self else { return }
                // renderedTime tracks the parked on-screen frame mid-seek (issue #49).
                self.renderedTime = value
                // seekInFlight suppresses currentTime: AVPlayer still reports pre-seek clock until physical landing (issue #37).
                guard !self.seekInFlight else { return }
                self.currentTime = value
            }
        }

        avPlayer.replaceCurrentItem(with: item)

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
            // Load-time seek (not a user scrub): no seekInFlight needed; the async seek(to:) carries #37/#38 semantics for user seeks.
            avPlayer.seek(to: CMTime(seconds: startPosition ?? 0, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func tearDown() {
        unloadCurrentItem()
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
            if let code, MasterFallbackDecision.isMasterRejectionCode(code) {
                EngineLog.emit(
                    "[NativeAVPlayerHost] #\(sessionID) startup .failed is a master rejection "
                    + "(code=\(code)); signalling engine for media fallback instead of surfacing",
                    category: .engine)
                pendingDisplayRejection = DisplayRejection(code: code, message: desc)
                return
            }
            failureMessage = desc
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
                self.failureMessage = desc
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

    /// Maps `seekableTimeRanges` to the end of the last range (seconds); 0 when empty or non-finite.
    nonisolated static func seekableEnd(from ranges: [NSValue]) -> Double {
        guard let r = ranges.last?.timeRangeValue else { return 0 }
        let end = CMTimeGetSeconds(r.start + r.duration)
        return end.isFinite ? end : 0
    }

    /// End of the contiguous buffered span covering the playhead (AetherEngine#54); disjoint ranges ahead of a gap are ignored.
    var bufferedEnd: Double {
        guard let item = avPlayer.currentItem else { return 0 }
        let now = item.currentTime().seconds
        guard now.isFinite else { return 0 }
        var end = now
        for value in item.loadedTimeRanges {
            let r = value.timeRangeValue
            let s = r.start.seconds
            let e = (r.start + r.duration).seconds
            guard s.isFinite, e.isFinite else { continue }
            // Contiguous with the playhead (small tolerance for the gap
            // between the rendered frame and the range's reported start).
            if s <= now + 1.0 && e >= now { end = max(end, e) }
        }
        return end
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
    func bufferedSecondsAtTarget(
        _ target: Double,
        tolerance: Double = 1.0,
        window: Double = 30.0,
        excludeAtOrAbove: Double? = nil
    ) -> Double {
        guard let item = avPlayer.currentItem else { return 0 }
        return Self.bufferedSecondsInWindow(
            ranges: item.loadedTimeRanges.map {
                let r = $0.timeRangeValue
                return (r.start.seconds, (r.start + r.duration).seconds)
            },
            target: target,
            tolerance: tolerance,
            window: window,
            excludeAtOrAbove: excludeAtOrAbove)
    }

    /// Pure part of `bufferedSecondsAtTarget(_:tolerance:window:excludeAtOrAbove:)`: total loaded seconds
    /// intersecting the target window, with the optional exclusion bound applied.
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
        var total = 0.0
        for range in ranges {
            guard range.start.isFinite, range.end.isFinite, range.end > range.start else { continue }
            let lo = Swift.max(range.start, lowerBound)
            let hi = Swift.min(range.end, upperBound)
            if hi > lo { total += hi - lo }
        }
        return total
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
        let playhead = avPlayer.currentTime().seconds
        let seekEnd = seekableRangeEndSeconds
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
            + "loadedEnd=\(String(format: "%.3f", loadedRangeEndSeconds ?? -1))s; "
            + "\(String(format: "%.1f", duration - playhead))s of the presentation lies past the end "
            + "AVPlayer reported, re-seeking in place (attempt \(prematureEndRecoveryAttempts))",
            category: .engine)
        await seek(to: playhead)
        avPlayer.play()
        prematureEndRecoveryInFlight = false
        timeControlStatus = avPlayer.timeControlStatus
        EngineLog.emit(
            "[NativeAVPlayerHost] #\(sessionID) AE#287 resumed: rate=\(avPlayer.rate) "
            + "t=\(String(format: "%.3f", avPlayer.currentTime().seconds))s",
            category: .engine)
        return true
    }

    /// End of AVPlayer's last seekable time range, in item seconds: the extent of the presentation it
    /// parsed from the playlist. Read from the item rather than the `seekableEnd` KVO mirror, which
    /// exists to keep the LIVE edge off a tick-cadence read (#134); this is one read at a rare event.
    private var seekableRangeEndSeconds: Double? {
        guard let last = playerItem?.seekableTimeRanges.last?.timeRangeValue else { return nil }
        let end = CMTimeGetSeconds(CMTimeAdd(last.start, last.duration))
        return end.isFinite ? end : nil
    }

    /// Raw end of AVPlayer's last loaded time range, in item seconds; diagnostics only. It is NOT the
    /// #287 witness: measured at a premature end, AVPlayer has already trimmed this range back to the
    /// exhaustion point, so it corroborates the mistake instead of refuting it.
    private var loadedRangeEndSeconds: Double? {
        guard let last = playerItem?.loadedTimeRanges.last?.timeRangeValue else { return nil }
        let end = CMTimeGetSeconds(CMTimeAdd(last.start, last.duration))
        return end.isFinite ? end : nil
    }

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
        avPlayer.rate = value
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

    private func unloadCurrentItem(inPlaceSwap: Bool = false) {
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
        seekableObservation?.invalidate()
        seekableObservation = nil
        layerReadyObservation?.invalidate()
        layerReadyObservation = nil
        for obs in notificationObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        notificationObservers.removeAll()
        accessLogCount = 0
        // Clear terminal flags: keepNativeHost reload reuses the host and @Published replays on subscribe; stale failureMessage/didReachEnd corrupt the new session (issue #15).
        failureMessage = nil
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
        // #168 follow-up: the carriage verdict belongs to the outgoing item.
        carriageWatchdogTask?.cancel()
        carriageWatchdogTask = nil
        carriageWatchdogArmed = false
        remoteHLSVideoCarriageRejected = false
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
                    url: segmentURL, httpHeaders: httpHeaders)
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
            armed: carriageWatchdogArmed,
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
                                     hasFailed: self.failureMessage != nil) {
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
                    self.failureMessage = message
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
    @MainActor
    private func publishDetectedVideoFormat(from item: AVPlayerItem) async {
        guard playerItem === item else { return }
        for itemTrack in item.tracks {
            guard let assetTrack = itemTrack.assetTrack, assetTrack.mediaType == .video else { continue }
            guard let cm = try? await assetTrack.load(.formatDescriptions).first else { continue }
            let rate = (try? await assetTrack.load(.nominalFrameRate)).map(Double.init)
            guard playerItem === item else { return }
            let subType = CMFormatDescriptionGetMediaSubType(cm)
            let ext = CMFormatDescriptionGetExtensions(cm) as? [String: Any] ?? [:]
            let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            let fmt = RemoteHLSFormatDetection.videoFormat(transferFunction: transfer, videoSubType: subType)
            // Rate before format: the engine's format sink reads detectedVideoFrameRate when it fires.
            if let rate, rate > 0 { detectedVideoFrameRate = rate }
            if detectedVideoFormat != fmt {
                detectedVideoFormat = fmt
                EngineLog.emit(
                    "[NativeAVPlayerHost] #\(sessionID) remote-HLS videoFormat=\(fmt) "
                    + "subType='\(fourccString(subType))' transfer=\(transfer ?? "nil") "
                    + "rate=\(rate.map { String(format: "%.3f", $0) } ?? "nil")",
                    category: .engine
                )
            }
            return
        }
    }

    /// Compact video track summary: dimensions + color attachments (primaries/transfer/matrix). Mismatch vs source-side codecpar signals DV/HDR signaling didn't survive the muxer.
    /// Dump item.tracks on .failed (FourCC per track). Async: AVAssetTrack.formatDescriptions is
    /// load-based; assetTrack access is main-actor.
    private static func dumpFailedItemTracks(_ item: AVPlayerItem, sid: Int) async {
        EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.tracks count=\(item.tracks.count)", category: .engine)
        for (idx, itrack) in item.tracks.enumerated() {
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

    /// Warn when EAC3/AC3 multichannel plays into a stereo-only HDMI route. Atmos excluded (ch=2 MAT carrier is correct for Atmos passthrough). Cause: Sonos Arc reports ch=2 LPCM after boot or HDMI handshake glitch; fix is power-cycling the sink. Not a pipeline bug (dec3 bitstream is identical across runs).
    private static func warnIfEAC3SurroundOnStereoRoute(_ item: AVPlayerItem, sid: Int) async {
        #if os(iOS) || os(tvOS)
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
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        let out = session.outputNumberOfChannels
        let pref = session.preferredOutputNumberOfChannels
        let maxCh = session.maximumOutputNumberOfChannels
        let route = session.currentRoute
        let outputDescs = route.outputs.map { port in
            let portName = port.portName
            let portType = port.portType.rawValue
            let nChannels = port.channels?.count ?? -1
            return "\(portName)[\(portType), ch=\(nChannels)]"
        }.joined(separator: ", ")
        EngineLog.emit(
            "[NativeAVPlayerHost] #\(sid) audioRoute output=\(out) preferred=\(pref) max=\(maxCh) "
            + "ports=[\(outputDescs)] (\(phase))",
            category: .engine
        )
        #endif
    }

    /// Read sr/ch/bits/layoutTag from CMAudioFormatDescription. Layout tag diagnoses where downmix occurs: unknown/stereo tag = AVPlayer parse layer; correct 7.1 tag = route/soundbar layer.
    nonisolated private static func audioFormatDescription(_ fmt: CMFormatDescription) -> String {
        var parts: [String] = []
        if let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
            let asbd = asbdPtr.pointee
            parts.append("sr=\(Int(asbd.mSampleRate))")
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
