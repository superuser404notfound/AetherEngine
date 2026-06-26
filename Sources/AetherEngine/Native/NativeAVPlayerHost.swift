import Foundation
import AVFoundation
import AVKit
import Combine

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
    /// Mirrors avPlayer.timeControlStatus so the engine can reconcile when AVKit's transport bar, Control Center, or hardware buttons toggle the player externally (without this, engine state goes stale and play/pause presses are swallowed).
    @Published private(set) var timeControlStatus: AVPlayer.TimeControlStatus = .paused

    // MARK: - Seek landing state

    /// Monotonic seek counter; only the latest generation clears seekInFlight and publishes the landed time (abandoned seeks complete with finished==false).
    private var seekGeneration: UInt64 = 0

    /// Suppresses currentTime publishing while a seek is in flight; the loopback source lands seeks seconds after the call, so the observer would otherwise bounce the clock back through the pre-seek position (issue #37).
    private(set) var seekInFlight: Bool = false

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

    init() {
        let player = AVPlayer()
        // Keep automaticallyWaitsToMinimizeStalling at default true: false caused permanent startup stall on 4K HEVC (rate dropped to 0 after asset.load and never resumed).
        self.avPlayer = player
        self.playerLayer = AVPlayerLayer(player: player)
        self.playerLayer.videoGravity = .resizeAspect
    }

    // No deinit cleanup: under Swift 6 strict concurrency the deinit
    // of a `@MainActor` type is nonisolated and can't reach
    // main-isolated properties. Callers must call `tearDown()`
    // before dropping this host. `AetherEngine.stopInternal()` is
    // the centralised invocation point.

    // MARK: - Lifecycle

    /// Load the loopback HLS-fMP4 URL into AVPlayer. DisplayCriteriaController.apply must run first so the HDR pipeline is configured before the first segment fetch.
    func load(url: URL, startPosition: Double?, perFrameHDR: Bool = true, skipInitialSeek: Bool = false, forwardBufferDuration: Double = 4.0, surfaceEndFailures: Bool = false) {
        unloadCurrentItem()

        self.surfaceEndFailures = surfaceEndFailures
        Self.nextSessionID += 1
        sessionID = Self.nextSessionID
        let sid = sessionID
        let loadStart = DispatchTime.now()
        loadStartTime = loadStart

        EngineLog.emit("[NativeAVPlayerHost] #\(sid) load url=\(url.absoluteString) startPos=\(startPosition.map { String(format: "%.2fs", $0) } ?? "nil")", category: .engine)

        // First-frame-visible diagnostic (see `layerReadyObservation`).
        layerReadyObservation = playerLayer.observe(
            \.isReadyForDisplay, options: [.new, .initial]
        ) { layer, change in
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - loadStart.uptimeNanoseconds) / 1_000_000_000
            EngineLog.emit(
                "[NativeAVPlayerHost] #\(sid) layer.isReadyForDisplay=\(change.newValue ?? layer.isReadyForDisplay) t+\(String(format: "%.2f", elapsed))s",
                category: .engine
            )
        }

        let asset = AVURLAsset(url: url)
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
        playerItem = item
        accessLogCount = 0
        failureMessage = nil
        isReady = false

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
                self.timeControlStatus = status
                // First .playing: re-sample route after 2.5s settle -- AVKit only negotiates HDMI format on playback start (issue #24).
                if status == .playing { self.hasEverPlayed = true }
                if status == .playing, !self.didSampleSettledRoute {
                    self.didSampleSettledRoute = true
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        guard let self = self, let item = self.playerItem else { return }
                        Self.dumpAudioRoute(sid: sid, phase: "settled")
                        Self.warnIfFLACSurroundExceedsRoute(item, sid: sid)
                        Self.warnIfEAC3SurroundOnStereoRoute(item, sid: sid)
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
                guard let self = self, self.surfaceEndFailures, self.sessionID == sid,
                      let current = self.playerItem else { return }
                // AVPlayer gave up on this item (rate 0, no more segments) and `.failed` may never fire
                // (item.status can stay readyToPlay). Route into the same deferred confirmation as a .failed
                // KVO: a transient that resumes within the window self-clears; a dead upstream (live IPTV
                // token expiry, persistent segment 404) surfaces .error so the host can retune / show it.
                self.handleItemFailed(desc, item: current)
            }
        }
        notificationObservers.append(failedToEndObs)

        let stalledObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { _ in
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) playbackStalled", category: .engine)
        }
        notificationObservers.append(stalledObs)

        let didEndObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) didPlayToEndTime", category: .engine)
            Task { @MainActor in
                self?.didReachEnd = true
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

    /// #50: AVPlayer fires .failed for self-healing transients (loopback 404, AVIOReader reconnect) while playback advances uninterrupted (rrgomes: tcs=playing at .failed).
    /// Discriminates on hasEverPlayed, not instantaneous timeControlStatus: .failed and timeControlStatus KVOs are unsynchronized (426b45c: still published terminal failure at 27.3s while AVPlayer played smoothly).
    /// Before first .playing: surface promptly (genuine startup failure). After: defer 5s and confirm -- clear if .playing or clock advanced, surface if both stopped.
    @MainActor
    private func handleItemFailed(_ desc: String, item: AVPlayerItem) {
        // Ignore a late `.failed` KVO from an item we have already replaced.
        guard playerItem === item else { return }

        failureConfirmToken &+= 1
        let token = failureConfirmToken

        // Startup failure: never reached .playing, so nothing to recover.
        if !hasEverPlayed {
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

    // MARK: - Playback control

    var isEffectivelyPlaying: Bool { avPlayer.timeControlStatus != .paused }

    /// End of the last seekable time range (seconds); tracks the live edge for EVENT playlists.
    var seekableEnd: Double {
        guard let r = avPlayer.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return 0 }
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
                            // Also settle renderedTime so sourceTime settles immediately (#49).
                            self.renderedTime = landed
                        }
                    }
                    if resumeGuard.claim() { cont.resume(returning: true) }
                }
            }
        }
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

    private func unloadCurrentItem() {
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
        didSampleSettledRoute = false
        // Re-arm #50 hasEverPlayed: reused host must not inherit prior session's established state.
        hasEverPlayed = false
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
    private static func warnIfFLACSurroundExceedsRoute(_ item: AVPlayerItem, sid: Int) {
        #if os(iOS) || os(tvOS)
        var trackChannels: Int = 0
        var isFLAC = false
        for itemTrack in item.tracks {
            guard let assetTrack = itemTrack.assetTrack else { continue }
            guard assetTrack.mediaType == .audio else { continue }
            guard let fmt = assetTrack.formatDescriptions.first else { continue }
            let cm = fmt as! CMFormatDescription
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
            + "LPCM but active audio route carries only \(routeChannels) LPCM channels — tvOS "
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
    private static func warnIfEAC3SurroundOnStereoRoute(_ item: AVPlayerItem, sid: Int) {
        #if os(iOS) || os(tvOS)
        var trackChannels: Int = 0
        var codecID: String = ""
        for itemTrack in item.tracks {
            guard let assetTrack = itemTrack.assetTrack else { continue }
            guard assetTrack.mediaType == .audio else { continue }
            guard let fmt = assetTrack.formatDescriptions.first else { continue }
            let cm = fmt as! CMFormatDescription
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
