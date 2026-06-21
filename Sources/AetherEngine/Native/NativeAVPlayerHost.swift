import Foundation
import AVFoundation
import AVKit
import Combine

/// `AVPlayer` + `AVPlayerLayer` wrapper owned by AetherEngine. Drives
/// the AVKit side that consumes the loopback HLS-fMP4 URL produced by
/// `HLSVideoEngine`. The reason this path exists at all: tvOS only
/// exposes the HDMI HDR-mode handshake to Dolby Vision through
/// `AVPlayer`-rooted playback, not through `AVSampleBufferDisplayLayer`.
///
/// This is the AVPlayer render path for sources that decode through
/// AVPlayer's HLS-fMP4 pipeline (HEVC, H.264, and AV1 on devices with
/// hardware AV1 decode). The dav1d software fallback for AV1 without
/// HW support and the VP9 path both live in `SoftwarePlaybackHost`.
///
/// Display-criteria handling lives in `DisplayCriteriaController`,
/// invoked from `AetherEngine.load(url:options:)` before the AVPlayer
/// item is loaded so the HDMI HDR-mode handshake is in flight by the
/// time AVPlayer's first segment fetch reaches the system.
@MainActor
final class NativeAVPlayerHost {

    // MARK: - Published state

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    /// AVPlayer's actually-rendered position, published on EVERY periodic
    /// tick including while a seek is in flight. Unlike `currentTime` (which
    /// the seek path holds at the optimistic target and the observer
    /// suppresses across `seekInFlight`, issue #37), this tracks where the
    /// picture really is: during a not-yet-landed seek AVPlayer keeps
    /// reporting the pre-seek clock, i.e. the parked on-screen frame. The
    /// engine folds it onto source PTS and publishes it as `clock.sourceTime`
    /// so frame-accurate consumers (subtitle overlay) follow the picture
    /// instead of the scrub target (issue #49).
    @Published private(set) var renderedTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    @Published private(set) var failureMessage: String?
    /// #50: monotonic token guarding a deferred item-failed confirmation.
    /// Bumped each time a possibly-spurious `.failed` is deferred so a
    /// later transition (a new failure, item swap) cancels an in-flight
    /// confirmation.
    private var failureConfirmToken: Int = 0
    /// #50: latched true on the first `.playing` transition of this session.
    /// Discriminates a genuine startup failure (never played, surface the
    /// `.failed` promptly) from a mid-playback transient (played, then a
    /// self-healing `.failed`). The instantaneous `timeControlStatus` at the
    /// `.failed` KVO instant is unreliable for this: the `.failed` and
    /// `timeControlStatus` KVOs are not synchronized, so a transient error
    /// fired while the clock is still advancing can momentarily read
    /// non-`.playing`. Reset with the item on a reused host.
    private var hasEverPlayed = false
    /// True after the AVPlayer item reaches the end of its stream.
    /// Engine flips state to .idle so host end-of-content flows
    /// (auto-dismiss, next-episode countdown if no marker) fire.
    @Published private(set) var didReachEnd: Bool = false
    /// Mirrors `avPlayer.timeControlStatus`. The engine subscribes so it
    /// can reconcile its own `state` when an external agent toggles the
    /// AVPlayer directly, bypassing `engine.play()` / `pause()`: AVKit's
    /// transport bar (kept active for Control Center skip routing), iPhone
    /// Control Center, or the hardware play/pause button that AVKit handles
    /// internally. Without this the engine's `state` goes stale and the
    /// host's `togglePlayPause()` resolves to a no-op (the "swallowed
    /// play/pause press" symptom).
    @Published private(set) var timeControlStatus: AVPlayer.TimeControlStatus = .paused

    // MARK: - Seek landing state

    /// Monotonic seek counter. A scrub that supersedes an in-flight seek
    /// bumps this so AVPlayer's `finished == false` completion for the
    /// abandoned seek can be told apart from the latest seek's real
    /// landing: only the newest generation clears the in-flight state
    /// and publishes the landed time. See `seek(to:)`.
    private var seekGeneration: UInt64 = 0

    /// True between a `seek(to:)` call and the AVPlayer completion handler
    /// firing for the latest seek. While set, the periodic time observer
    /// suppresses `currentTime` publishing: the loopback HLS-fMP4 source
    /// lands a seek seconds after the call, so the observer would read the
    /// stale pre-seek clock and bounce the engine clock back through the
    /// old position (issue #37). The completion handler publishes the
    /// landed time once and clears this.
    private(set) var seekInFlight: Bool = false

    // MARK: - Output

    /// The AVPlayerLayer the engine attaches to the bound
    /// `AetherPlayerView`. Created at init and reused for the lifetime
    /// of this host, even across `replaceCurrentItem` swaps.
    let playerLayer: AVPlayerLayer

    /// The underlying `AVPlayer`. Exposed engine-internally so the
    /// audio/subtitle track-selection layer can reach `AVMediaSelection`
    /// once that wiring lands.
    let avPlayer: AVPlayer

    // MARK: - Private state

    private var playerItem: AVPlayerItem?
    /// Latest external-metadata array the host wants on the playing
    /// item. Applied immediately to the current `AVPlayerItem` when set,
    /// and replayed onto a fresh item across internal reloads
    /// (audio-track switch, background reopen) so the system Now Playing
    /// surface keeps its title / artwork after the seam.
    private var pendingExternalMetadata: [AVMetadataItem] = []
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    /// One-shot guard so the settled audio-route capability check (route
    /// dump + downmix warnings) runs once, after the first transition to
    /// `.playing` when AVKit has finished negotiating the HDMI output
    /// format. Sampling at readyToPlay was premature and false-positived
    /// the downmix warning on stereo-idle sinks (issue #24).
    private var didSampleSettledRoute = false
    /// Latched transport intent: true after `play()`, false after
    /// `pause()` / `setRate(0)` / item unload. Exists because a reload
    /// on a REUSED AVPlayer (keepNativeHost) swaps items via
    /// `replaceCurrentItem(nil)` + `replaceCurrentItem(item)`, and a
    /// `play()` issued into that swap window can be swallowed:
    /// AVPlayer reports `waitingToPlay reason=NoItemToPlay`, drops the
    /// rate back to 0, and then sits at `readyToPlay` + `.paused`
    /// forever (live-rejoin repro via `aetherctl live --reload-test`:
    /// the rejoined item became ready but never played, and the
    /// engine's timeControlStatus reconciliation then mislabeled the
    /// session as user-paused). The readyToPlay observer re-asserts
    /// this intent instead of trusting the one-shot `play()` call
    /// (latch over racing the swap, per the binary-lockout pattern).
    private var playIntent = false
    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    /// Observes `playerLayer.isReadyForDisplay`, the only signal for
    /// "the first video frame is actually on screen". Diagnostic for the
    /// audio-leads-black-video startup reports: timeControlStatus can
    /// sit at .playing (audio audible) seconds before the layer flips
    /// ready; the t+ stamps localize where those seconds go.
    private var layerReadyObservation: NSKeyValueObservation?
    /// Stamp of the current load() entry; the t+ reference for the
    /// startup-sequence diagnostics (layer readiness, timeControl
    /// transitions). Written on MainActor in load(), read from KVO
    /// closures off-main; diagnostic-only, a torn read is harmless.
    nonisolated(unsafe) private var loadStartTime = DispatchTime.now()
    private var notificationObservers: [NSObjectProtocol] = []
    private var accessLogCount = 0

    /// Monotonic counter so multi-attempt sessions (DrHurt-style
    /// "play, fail, back out, retry") produce distinguishable log
    /// lines. Every load(url:) increments it; every async asset.load
    /// log line tags itself with the current value so a chain of
    /// "asset.load failed" entries can be matched back to the
    /// originating load() invocation.
    private static var nextSessionID: Int = 0
    private var sessionID: Int = 0

    // MARK: - Init

    init() {
        let player = AVPlayer()
        // Default (true) is right for VOD HLS, AVPlayer waits for
        // buffer. HLSAudioEngine sets `false` for live-audio latency
        // reasons, don't copy that pattern here: AVPlayer would try
        // to play the moment seg0 has any bytes and stall because
        // the lazy remuxer needs seconds to produce a full fragment.
        //
        // (Tried auto=false as a memory-bound experiment for the
        // long-form 4K HDR HEVC RSS growth. Result: AVPlayer's rate
        // dropped to 0 right after asset.load completed and never
        // resumed — startup permanently stalls. The risk note above
        // is real and the fix is to leave the default in place.)
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

    /// Load the URL produced by `HLSVideoEngine` (loopback HLS-fMP4).
    /// `DisplayCriteriaController.apply(...)` must have been invoked
    /// upstream so AVKit can configure the HDR pipeline against the
    /// right target mode before the first segment is fetched.
    func load(url: URL, startPosition: Double?, perFrameHDR: Bool = true, skipInitialSeek: Bool = false, forwardBufferDuration: Double = 4.0) {
        unloadCurrentItem()

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
        // Forward-buffer floor before AVPlayer leaves
        // `waitingToPlayAtSpecifiedRate` and starts rendering.
        //
        // VOD and loopback-live both use this 4 s default: it matches the
        // loopback HLS segment cadence, enough to ride out a normal
        // segment-generation hiccup from the local producer without
        // ballooning resident memory. Loopback-live deliberately does NOT
        // raise this — a deeper buffer makes AVPlayer pull the whole visible
        // playlist up front and race to the live edge, then stall on the
        // transcode warm-up gap; the 4 s buffer paces consumption instead
        // (see AetherEngine.loadNative call site, verified on device).
        //
        // Live remote-HLS (loadRemoteHLS) passes 0 (system adaptive).
        // Against a remote, bandwidth-limited Jellyfin live transcode the
        // 4 s floor forced AVPlayer to pull ~4 s (~10 MB at 20 Mbps) before
        // unblocking — a 3-4 s black screen at startup while the server
        // transcoded + shipped that buffer. 0 hands buffering back to
        // AVPlayer's own heuristic, which starts as soon as it has a
        // playable lead. preferredForwardBufferDuration == 0.0 is the
        // documented "let the player choose" value.
        item.preferredForwardBufferDuration = forwardBufferDuration

        // Forward per-frame HDR metadata (HDR10+ ST 2094-40 and Dolby
        // Vision RPU) from the source bitstream into AVPlayer's
        // display-mode handshake. Without this, AVPlayer renders DV
        // sources in static HDR10 base only — the TV switches to
        // generic HDR mode instead of Dolby Vision mode, and DV
        // tone-mapping curves never engage. DrHurt's tests confirmed
        // that P8 MKVs and DV-tagged MP4s played end-to-end but the
        // Philips TV stayed in HDR mode for DV sources; he flagged
        // the missing AVPlayerItem flag specifically.
        //
        // Caller can disable when the routing decision routes through
        // the media playlist (panel locked SDR + match off path), where
        // AVPlayer can't engage HDR mode anyway and the per-frame
        // metadata pipeline is suspected of slow memory growth on long
        // DV 8.1 sessions (rss ~3 MB/sec linear, no visible bound).
        // Engine sets this to `false` for SDR-fallback paths so the
        // 4K HDR per-frame metadata path is bypassed and the leak
        // suspect is removed from those sessions.
        item.appliesPerFrameHDRDisplayMetadata = perFrameHDR
        // Apply any externalMetadata the host has pre-staged before this
        // load (e.g. system Now Playing title + artwork). Setting it
        // BEFORE AVPlayer.replaceCurrentItem-equivalent is the documented
        // safe order; doing it after the asset has started loading races
        // with AVPlayer's internal track-load. `AVPlayerItem.externalMetadata`
        // is unavailable on macOS — macOS hosts must write
        // `MPNowPlayingInfoCenter` directly.
        #if !os(macOS)
        if !pendingExternalMetadata.isEmpty {
            item.externalMetadata = pendingExternalMetadata
        }
        #endif
        playerItem = item
        accessLogCount = 0
        failureMessage = nil
        isReady = false

        // Status observer to track readyToPlay / failed transitions.
        // KVO observation runs on the same thread that mutated the
        // observed value, in this case AVPlayerItem hops to its own
        // queue, so we round-trip back to MainActor explicitly.
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

            // On .failed, dump the asset's track format descriptions
            // so we can see what codec FourCC AVPlayer actually saw.
            // Targets DrHurt's hev1 / dvhe rejection caveat: if a
            // session fails because the source's sample-entry tag is
            // hev1 instead of hvc1, that shows up here as "video
            // codec='hev1'". Also surfaces the underlying NSError
            // chain which often has the precise CoreMedia /
            // VideoToolbox cause behind the AVFoundationErrorDomain
            // wrapper.
            //
            // On .readyToPlay we also dump now (besides failures)
            // because the audio-track row carries the parsed
            // CMAudioFormatDescription: sample rate, channel count,
            // channel layout tag. Critical for diagnosing the FLAC
            // bridge surround-to-stereo downmix path — if the layout
            // tag comes back <missing> or kAudioChannelLayoutTag_Stereo
            // for an 8-channel source, the downmix is happening at
            // AVPlayer's moov parse rather than at the route / soundbar.
            if item.status == .failed {
                if let nsErr = nsErr,
                   let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.error.underlying=\(underlying.domain)/\(underlying.code) '\(underlying.localizedDescription)'", category: .engine)
                }
                Self.dumpAssetTracks(item.asset, sid: sid, reason: "item.failed")
                // Dump every error-log event accumulated since item
                // creation. AVPlayer's internal HLS pipeline writes
                // granular diagnostics here (variant filter rejections,
                // CODECS mismatches, init.mp4 parse failures, ATS
                // blocks, manifest errors) that the wrapped
                // AVFoundation/CoreMedia error codes hide. The
                // `newErrorLogEntryNotification` observer only catches
                // entries logged AFTER it registers, which races
                // synchronous entries logged during replaceCurrentItem;
                // polling the full log on .failed catches every entry
                // regardless of timing.
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
                // Item-level state diagnostics. For HLS assets `asset.tracks`
                // is documented empty, but `item.tracks` may contain the
                // AVPlayerItemTrack array AVPlayer constructed from the
                // playlist alone (before init.mp4 parse). presentationSize,
                // seekableTimeRanges, and currentMediaSelection reveal
                // what AVPlayer DID manage to extract from the playlist
                // versus what it couldn't.
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.tracks count=\(item.tracks.count)", category: .engine)
                for (idx, itrack) in item.tracks.enumerated() {
                    let mediaType = itrack.assetTrack?.mediaType.rawValue ?? "?"
                    let fdesc = itrack.assetTrack?.formatDescriptions.first
                    let fourCC: String
                    if let cm = fdesc {
                        // swiftlint:disable:next force_cast
                        let cmDesc = cm as! CMFormatDescription
                        let code = CMFormatDescriptionGetMediaSubType(cmDesc)
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
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.presentationSize=\(item.presentationSize)", category: .engine)
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.seekableTimeRanges.count=\(item.seekableTimeRanges.count)", category: .engine)
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.loadedTimeRanges.count=\(item.loadedTimeRanges.count)", category: .engine)
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.canPlayFastForward=\(item.canPlayFastForward) canPlayFastReverse=\(item.canPlayFastReverse) canStepForward=\(item.canStepForward)", category: .engine)
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.duration=\(item.duration.seconds.isFinite ? String(format: "%.2f", item.duration.seconds) : "indef")", category: .engine)
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.appliesPerFrameHDRDisplayMetadata=\(item.appliesPerFrameHDRDisplayMetadata)", category: .engine)
            } else if item.status == .readyToPlay {
                // For HLS sources `asset.tracks` returns empty
                // synchronously — the tracks live on AVPlayerItem
                // instead. Dump the player-item's audio tracks so we
                // can see what AVPlayer parsed from the moov for
                // diagnostic, plus the active audio route's channel
                // count after the route renegotiates against the
                // loaded asset.
                Self.dumpPlayerItemTracks(item, sid: sid)
                // Dump the route here for reference, but do NOT warn yet:
                // at readyToPlay the player is still paused and AVKit has
                // not finished negotiating the HDMI output format. On a
                // sink that idles at stereo (Continuous Audio off) the
                // route still reads ch=2 at this instant and only lifts to
                // the source channel count once playback actually starts.
                // Warning here produced false "downmix" reports (issue
                // #24). The capability check runs from the settled re-dump
                // on the first .playing transition instead.
                Self.dumpAudioRoute(sid: sid, phase: "readyToPlay, route may still be negotiating")
            }

            Task { @MainActor in
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                    self.isReady = true
                    // Re-assert a play() that the replaceCurrentItem swap
                    // swallowed (see `playIntent`). Only when the caller's
                    // standing intent is "playing" AND AVPlayer actually
                    // parked: a user pause between play() and readiness
                    // cleared the latch, and a healthy startup is already
                    // in waitingToPlay/playing so the guard no-ops.
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

        // timeControlStatus + reasonForWaitingToPlay together explain
        // whether AVPlayer is paused, waiting on buffer, or actively
        // playing. Critical for diagnosing "spinner forever" symptoms
        // because reasonForWaitingToPlay surfaces the exact stall cause
        // (.evaluatingBufferingRate / .toMinimizeStalls / etc.).
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
                // On the first real .playing transition, re-sample the
                // audio route after a short settle delay: AVKit negotiates
                // the HDMI output format (stereo -> source channel count /
                // Dolby) only once playback actually starts, so this is the
                // first point the route reflects the true steady state. The
                // downmix warnings run here, not at readyToPlay (issue #24).
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

        // Error log: AVPlayer surfaces transient HLS-level errors
        // (404 on a segment, parse failure on a manifest, ATS rejection,
        // codec mismatch) without flipping the item to .failed. These
        // are the gold mine for "AVPlayer just sits there" diagnostics.
        let errLogObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let event = self.playerItem?.errorLog()?.events.last else { return }
            let comment = event.errorComment ?? "no comment"
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) errorLog code=\(event.errorStatusCode) domain=\(event.errorDomain) uri=\(event.uri ?? "-") '\(comment)'", category: .engine)
        }
        notificationObservers.append(errLogObs)

        // Access log: log only the first few entries so we know
        // whether AVPlayer ever reached the segment-fetch stage.
        // AVPlayer can pump hundreds of these for a long stream so
        // capping at 5 keeps the overlay readable.
        let accessLogObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newAccessLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  self.accessLogCount < 5,
                  let event = self.playerItem?.accessLog()?.events.last else { return }
            self.accessLogCount += 1
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) accessLog uri=\(event.uri ?? "-") server=\(event.serverAddress ?? "-") bytes=\(event.numberOfBytesTransferred) reqs=\(event.numberOfMediaRequests)", category: .engine)
        }
        notificationObservers.append(accessLogObs)

        let failedToEndObs = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { notification in
            let err = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            let suffix = err.map { " \($0.domain)/\($0.code) '\($0.localizedDescription)'" } ?? ""
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) failedToPlayToEndTime\(suffix)", category: .engine)
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

        // End-of-stream: AVPlayer fires didPlayToEndTime when the
        // last sample is rendered. Flip the published flag so the
        // engine knows the session reached its natural end (engine
        // forwards that to state = .idle).
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

        // Periodic time observer at 100 ms drives the scrub bar
        // and the resume-position progress reporter. The closure is
        // already invoked on `.main`, so the `MainActor` mutation
        // is safe; cast through a Task to satisfy the Sendable check.
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let value = time.seconds.isFinite ? time.seconds : 0
            Task { @MainActor in
                guard let self else { return }
                // `renderedTime` always tracks AVPlayer's reported position,
                // even mid-seek: during a not-yet-landed seek that value is
                // the parked on-screen frame, which is exactly what the
                // source-PTS `sourceTime` should follow (issue #49).
                self.renderedTime = value
                // While a seek is in flight AVPlayer still reports the
                // pre-seek clock until the seek physically lands on the
                // loopback HLS-fMP4 source; publishing it to `currentTime`
                // bounces the engine clock back through the old position
                // (issue #37). The seek completion handler publishes the
                // landed time.
                guard !self.seekInFlight else { return }
                self.currentTime = value
            }
        }

        avPlayer.replaceCurrentItem(with: item)

        // Explicitly kick off the async load of the asset's playable /
        // tracks / duration values. AVPlayerItem(asset:) plus KVO on
        // status SHOULD trigger this implicitly per Apple's docs, but
        // the build-123 overlay showed AVPlayer stuck in waitingToPlay
        // with the item never advancing past .unknown — consistent
        // with the asset never beginning its async load. Forcing the
        // load explicitly removes that ambiguity.
        //
        // We load each key in a separate await so DrHurt's
        // "1 success, 3 failures" log signature can be decoded down
        // to "which key is the -1008 hitting on": isPlayable, tracks,
        // or duration. With the batch load they all share one error
        // and we can't tell which probe AVFoundation gave up on.
        let urlStr = url.absoluteString
        Task { [weak self] in
            for key in ["isPlayable", "tracks", "duration"] {
                do {
                    switch key {
                    case "isPlayable": _ = try await asset.load(.isPlayable)
                    case "tracks":     _ = try await asset.load(.tracks)
                    case "duration":   _ = try await asset.load(.duration)
                    default: continue
                    }
                    let detail: String
                    switch key {
                    case "isPlayable": detail = "value=\(asset.isPlayable)"
                    case "tracks":     detail = "count=\(asset.tracks.count)"
                    case "duration":   detail = "seconds=\(asset.duration.seconds)"
                    default: detail = "-"
                    }
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.load(\(key)) ok url=\(urlStr) \(detail)", category: .engine)
                } catch {
                    let nsErr = error as NSError
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.load(\(key)) failed: \(nsErr.domain)/\(nsErr.code) '\(nsErr.localizedDescription)' url=\(urlStr)", category: .engine)
                    if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
                        EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.load(\(key)) underlying=\(underlying.domain)/\(underlying.code) '\(underlying.localizedDescription)'", category: .engine)
                    }
                    // Dump whatever track info AVFoundation managed
                    // to populate before the load gave up. Targets
                    // DrHurt's -1008 stall: even on failure the
                    // asset's first probe often surfaces the
                    // sample-entry FourCC (hev1 vs hvc1, dvhe vs
                    // dvh1) that explains the rejection.
                    Self.dumpAssetTracks(asset, sid: sid, reason: "asset.load(\(key)).failed")
                    _ = self
                    return
                }
            }
        }

        // Always issue an explicit seek so AVPlayer doesn't fall back
        // to its EVENT-playlist live-edge default. For VOD this is a
        // no-op (default start is already time 0); for the sliding-
        // window EVENT path it's what makes replay-from-beginning land
        // at 0:00 instead of at the end of the initial visible window
        // (~2 min in for a 30-segment initialFillSegments window).
        // EXT-X-START:TIME-OFFSET=0 in the playlist is the spec-level
        // hint but isn't enough on its own — AVPlayer treats EVENT
        // playlists as "start near the live edge" unless the caller
        // explicitly seeks first.
        //
        // Live remote-HLS (nativeRemoteHLS) WANTS AVPlayer's natural live-
        // edge start, so it sets skipInitialSeek and we leave the position
        // to AVPlayer. Loopback live REJOINS (audio-switch reload,
        // background-return reopen) set it too: their rebuilt playlist can
        // present a multi-segment backlog (the upstream re-serves its
        // buffer at I/O speed), and this pre-readiness zero-tolerance
        // seek pointing at the backlog start, ~a window behind AVPlayer's
        // own live-join target, is the prime suspect for a reloaded item
        // that fetched every segment yet never reached readyToPlay
        // (permanent waitingToPlay, frozen frame; tvOS 26 + Jellyfin live
        // device repro). See LiveReloadPolicy.skipInitialSeek. VOD /
        // initial loopback joins (default) seek to startPosition.
        if !skipInitialSeek {
            // Load-time positioning, not a user seek: no in-flight signal or
            // landing await needed (the item is not yet serving a clock the
            // host observes). Drive AVPlayer directly; the async public
            // seek(to:) carries the #37/#38 landing semantics for scrubs.
            avPlayer.seek(to: CMTime(seconds: startPosition ?? 0, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Release the AVPlayerItem so a follow-up `load(...)` starts
    /// from a clean state. Caller is responsible for resetting the
    /// display-criteria (the engine does this from
    /// `stopInternal()` after invoking `tearDown()` here).
    func tearDown() {
        unloadCurrentItem()
    }

    // MARK: - Failure handling

    /// #50: AVPlayer flips `item.status` to `.failed` on transient errors it
    /// then self-heals - an in-range loopback 404 the host retries, or an
    /// AVIOReader range-read reconnect ("The network connection was lost.") -
    /// while the player keeps playing straight through from buffer: the clock
    /// and subtitle cues keep advancing and the title plays to the end. The
    /// `item.error` is non-nil, but the failure is not actually terminal.
    /// Publishing it as a terminal `.error` aborts a session that is
    /// demonstrably still playing (rrgomes' device capture: `tcs=playing`,
    /// `rate=1.0` at the `.failed` transition).
    ///
    /// A genuine fatal failure leaves the player stopped. 426b45c gated the
    /// publish on the *instantaneous* `timeControlStatus` at the `.failed`
    /// instant: surface immediately when not `.playing`, defer-and-confirm
    /// when still `.playing`. rrgomes' `426b45c` retest showed that single
    /// sample is unreliable - the engine still published a terminal failure at
    /// avpClock=27.3s while the AVPlayer kept playing smoothly, and the
    /// "deferring" log never fired, meaning the immediate-surface branch ran
    /// (`timeControlStatus != .playing` at that instant) even though playback
    /// was demonstrably advancing. The `.failed` KVO and the `timeControlStatus`
    /// KVO are not synchronized: a self-healing transient (in-range loopback
    /// 404, AVIOReader range-read reconnect) can fire `.failed` during a brief
    /// `.waitingToPlayAtSpecifiedRate` blip while the clock never stops.
    ///
    /// So discriminate on *whether playback was ever established*, not on an
    /// instantaneous transport sample. Before the first `.playing` transition a
    /// `.failed` is a genuine startup failure (no recovery expected) and
    /// surfaces promptly. Once playback has established, every `.failed` is
    /// treated as possibly-spurious and deferred; at confirmation a recovered
    /// player is one that is `.playing` *or* whose clock advanced past the
    /// failure point (clock progress is immune to the same instantaneous-sample
    /// race on the confirmation side). Only a player that is both stopped and
    /// has not advanced after the settle surfaces the failure.
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
            if self.avPlayer.timeControlStatus == .playing || advanced {
                EngineLog.emit(
                    "[NativeAVPlayerHost] #\(self.sessionID) deferred failure cleared: player recovered "
                    + "(tcs=\(self.avPlayer.timeControlStatus.rawValue) "
                    + "clock=\(String(format: "%.2f", self.renderedTime)) advanced=\(advanced))",
                    category: .engine
                )
            } else {
                EngineLog.emit(
                    "[NativeAVPlayerHost] #\(self.sessionID) deferred failure confirmed: player stopped "
                    + "(tcs=\(self.avPlayer.timeControlStatus.rawValue) "
                    + "clock=\(String(format: "%.2f", self.renderedTime)))",
                    category: .engine
                )
                self.failureMessage = desc
            }
        }
    }

    // MARK: - Playback control

    /// Live, synchronous read of whether the player intends to be playing
    /// (`.playing`, or the transient `.waitingToPlayAtSpecifiedRate` buffer
    /// stall). Read at the moment of a toggle so a rapid press can't act on
    /// the async `timeControlStatus` mirror before it has caught up.
    var isEffectivelyPlaying: Bool { avPlayer.timeControlStatus != .paused }

    /// End (seconds) of the AVPlayer item's last seekable time range, or 0 when
    /// no seekable range is available. For a live HLS playlist this tracks the
    /// live edge in the AVPlayer clock.
    var seekableEnd: Double {
        guard let r = avPlayer.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return 0 }
        let end = CMTimeGetSeconds(r.start + r.duration)
        return end.isFinite ? end : 0
    }

    /// End (seconds, AVPlayer clock) of the contiguous `loadedTimeRanges`
    /// span covering the current playhead, i.e. how far ahead AVPlayer has
    /// actually buffered (AetherEngine#54). Returns the playhead itself when
    /// no loaded range covers it, so the engine's folded `bufferedPosition`
    /// never trails `sourceTime`. Disjoint ranges ahead of a gap are ignored
    /// on purpose: a buffer bar should show the continuously playable span.
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
        // Record the standing intent FIRST so the readyToPlay observer
        // can re-assert a play() that the replaceCurrentItem swap
        // swallowed (see `playIntent`).
        playIntent = true
        // AVPlayer with `automaticallyWaitsToMinimizeStalling=true`
        // (the default) handles "play before ready" correctly: it
        // sets rate=1, transitions to waitingToPlayAtSpecifiedRate,
        // begins loading the asset, buffers, and once it has enough
        // it transitions to playing. The earlier defer-until-ready
        // pattern was a guard against a different bug (master playlist
        // parse-rejection) and reintroduced a chicken-and-egg here:
        // item.status doesn't advance until the player is actually
        // told to play, so deferring play() on item.status kept the
        // status stuck at .unknown forever.
        avPlayer.play()
    }

    func pause() {
        playIntent = false
        avPlayer.pause()
    }

    /// Seek the underlying AVPlayer and resolve only when the seek
    /// **physically lands** (AVPlayer's completion handler), not when the
    /// call returns. The loopback HLS-fMP4 source lands a seek seconds
    /// after the call; resolving early let the engine flip back to
    /// `.playing` and let the 100 ms periodic observer overwrite the
    /// target with the stale pre-seek clock (issue #37). `seekInFlight`
    /// spans the real landing so the observer is suppressed across it.
    ///
    /// A superseding seek (the user scrubs again before this lands) bumps
    /// `seekGeneration`; AVPlayer reports the abandoned seek's completion
    /// with `finished == false`. Only the latest generation clears the
    /// in-flight state and publishes the landed time, so a stale
    /// completion can't drop the in-flight flag while a newer seek is
    /// still in flight.
    func seek(to seconds: Double) async {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        seekGeneration &+= 1
        let gen = seekGeneration
        seekInFlight = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Frame-accurate seek. Earlier experiment with
            // `.positiveInfinity` tolerances to skip the IDR-to-target
            // decode pre-roll caused AVPlayer to land on apparently-
            // arbitrary sync samples far from the requested time — the
            // user's TestFlight session showed the image "hanging" on
            // wrong-position content during forward scrubs. AVPlayer's
            // "most efficient seek" interpretation of unbounded tolerance
            // appears to be undefined for HLS-fMP4 served over loopback,
            // matching the long-standing openradar 44904505 bug report.
            // Keep tolerances at zero until we have a different lever
            // (predictive engine prefetch on scrub commit) that doesn't
            // depend on tolerance semantics.
            avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { cont.resume(); return }
                    // A newer seek already owns the in-flight state; just
                    // unblock this awaiter and leave its flags intact.
                    if gen == self.seekGeneration {
                        self.seekInFlight = false
                        // Publish the exact landed position so the clock
                        // settles on the target immediately instead of
                        // waiting a tick for the periodic observer.
                        let landed = self.avPlayer.currentTime().seconds
                        if landed.isFinite {
                            self.currentTime = landed
                            // The picture now sits at the landed position too,
                            // so settle the rendered clock with it rather than
                            // waiting a tick for the periodic observer (#49).
                            self.renderedTime = landed
                        }
                    }
                    cont.resume()
                }
            }
        }
    }

    func setRate(_ value: Float) {
        // Rate 0 is a pause; any other rate is a standing play intent
        // (speed changes must survive the same swap window play() does).
        playIntent = (value != 0)
        avPlayer.rate = value
    }

    /// Forwarded AVPlayer volume so the host satisfies
    /// `TransportControllable` like the other three hosts.
    var volume: Float {
        get { avPlayer.volume }
        set { avPlayer.volume = newValue }
    }

    /// Stage the metadata items the host wants on the current and any
    /// future `AVPlayerItem` of this session. The system Now Playing
    /// surface reads from `AVPlayerItem.externalMetadata` when an
    /// `MPNowPlayingSession` is active with automatic publishing on.
    /// Applied immediately if an item exists; otherwise replays onto the
    /// next item created by `load(url:startPosition:)`.
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
        // Clear the published terminal flags so a REUSED host (issue-15
        // keepNativeHost reload) doesn't replay the previous session's
        // values into the next session: @Published replays the current
        // value on subscribe, and the engine subscribes BEFORE calling
        // load(), so a stale failureMessage flipped the new session to
        // .error before it started (terminal on state machines that
        // refuse to leave .error), and a stale didReachEnd fired a
        // spurious end-of-item edge.
        failureMessage = nil
        didReachEnd = false
        // Re-arm the settled-route diagnostic for the next session on
        // this reused host (episode 2+ of a binge otherwise silently
        // lost the issue-24 downmix warnings).
        didSampleSettledRoute = false
        // Re-arm the #50 startup-vs-established discriminator: a reused host
        // must treat the next session's pre-playback failures as startup
        // failures (surface promptly), not inherit the prior session's
        // established state.
        hasEverPlayed = false
        // Force the player rate to 0 before swapping the item. On a
        // native->native reload the host (and its AVPlayer) is reused to
        // keep AVKit's system Now-Playing registration alive (issue #15),
        // so the instance carries its previous `rate=1.0` across the swap.
        // Without this pause, `replaceCurrentItem` lets the new item
        // auto-resume the moment it buffers — which beats the engine's
        // `waitForSwitch` + explicit `play()` gate (AetherEngine.load step
        // 3) and starts audio while the panel is still mid Match-Frame-Rate
        // refresh switch (HDMI output blanked). The result is "audio leads,
        // video appears a beat later" on episode autoplay. Pausing here
        // restores the intended gate: the new item stays parked until the
        // explicit post-handshake `play()`. No-op on a cold load (rate is
        // already 0).
        //
        // The play-intent latch is session-scoped: clear it with the item
        // so the PREVIOUS session's intent cannot re-start the next item
        // at ITS readyToPlay, ahead of the engine's gated play() (that
        // would re-open the issue-15 audio-leads-video window).
        playIntent = false
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        playerItem = nil
        isReady = false
        // (didReachEnd already cleared above, with the terminal flags.)
        currentTime = 0
        renderedTime = 0
        duration = 0
        rate = 0
    }

    /// Log the asset's URL plus every track's media type, codec
    /// FourCC, enabled flag, and playable flag. Called from both the
    /// `item.status == .failed` path and the per-key `asset.load`
    /// failure path so DrHurt's "AVPlayer stalls in waitingToPlay
    /// instead of failing" sessions still surface the codec FourCCs
    /// (item.status never going `.failed` was the reason d9b8aa5's
    /// dump didn't fire in DrHurt's P5 MKV log).
    private static func dumpAssetTracks(_ asset: AVAsset, sid: Int, reason: String) {
        if let urlAsset = asset as? AVURLAsset {
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.url=\(urlAsset.url.absoluteString) (\(reason))", category: .engine)
        }
        let tracks = asset.tracks
        if tracks.isEmpty {
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.tracks empty (\(reason))", category: .engine)
            return
        }
        for track in tracks {
            let fourcc: String
            var extra = ""
            if let fmt = track.formatDescriptions.first {
                let cm = fmt as! CMFormatDescription
                fourcc = fourccString(CMFormatDescriptionGetMediaSubType(cm))
                if track.mediaType == .audio {
                    extra = " " + audioFormatDescription(cm)
                }
            } else {
                fourcc = "?"
            }
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) asset.track type=\(track.mediaType.rawValue) codec='\(fourcc)' enabled=\(track.isEnabled) playable=\(track.isPlayable)\(extra) (\(reason))", category: .engine)
        }
    }

    /// AVPlayerItem.tracks-based audio track dump. For HLS sources
    /// `asset.tracks` is empty synchronously, only AVPlayerItem.tracks
    /// returns the resolved track list once the playlist + init.mp4
    /// have been parsed. Logs one line per audio track with sample
    /// rate, channel count, bit depth, format ID, and channel layout
    /// tag (the multichannel-routing diagnostic).
    private static func dumpPlayerItemTracks(_ item: AVPlayerItem, sid: Int) {
        let tracks = item.tracks
        if tracks.isEmpty {
            EngineLog.emit("[NativeAVPlayerHost] #\(sid) item.tracks empty (readyToPlay)", category: .engine)
            return
        }
        for itemTrack in tracks {
            guard let assetTrack = itemTrack.assetTrack else { continue }
            let fourcc: String
            var extra = ""
            if let fmt = assetTrack.formatDescriptions.first {
                let cm = fmt as! CMFormatDescription
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

    /// Compact one-line summary of a CMFormatDescription for video
    /// tracks. Reads the picture dimensions plus the color attachments
    /// AVPlayer applied (primaries / transfer / matrix / range), which
    /// is what we need to compare against the source-side codecpar
    /// values that we log from the engine in `[HLSVideoEngine] DV
    /// source` / `prepared`. A mismatch here is a strong signal the
    /// DV / HDR signaling didn't survive the muxer round-trip.
    private static func videoFormatDescription(_ fmt: CMFormatDescription) -> String {
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

    /// One-line warning when the FLAC bridge has produced an N-channel
    /// track but the active audio route can only carry M < N channels
    /// of LPCM. Fires only for FLAC tracks because:
    ///
    ///   - Stream-copy paths (EAC3 / AC3 / AAC) tunnel through HDMI as
    ///     encoded bitstream, bypassing the LPCM channel-count limit.
    ///     A Sonos Arc with route.ch=2 still receives 7.1 surround via
    ///     EAC3 bitstream over eARC.
    ///   - FLAC bridge output is decoded to LPCM by AVPlayer, then
    ///     routed via the active port's LPCM channel count. If the
    ///     port can carry only stereo (e.g. Sonos Arc reports 2ch
    ///     LPCM via HDMI even with eARC, because the soundbar handles
    ///     multichannel exclusively via bitstream), the 8-channel
    ///     LPCM gets downmixed before reaching the sink. End result:
    ///     stereo from a TrueHD / DTS-HD MA source.
    ///
    /// This is a route capability mismatch, not a bug in the bridge.
    /// AVR setups with proper 7.1 LPCM-over-HDMI support (Denon /
    /// Marantz / NAD) carry the full 7.1 LPCM cleanly and don't
    /// trigger this warning.
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

    /// Warn when an EAC3 / AC3 multichannel track plays into a route
    /// the HDMI sink is reporting as stereo-only. Atmos (EAC3 with the
    /// `flag_ec3_extension_type_a` JOC marker set in dec3) is excluded
    /// from this warning because Atmos uses a 2-channel MAT 2.0 / IEC
    /// 61937 carrier — `ch=2` on the route is the correct, working
    /// state for an Atmos passthrough and does NOT mean stereo output.
    ///
    /// Why: plain DD+ 5.1 and DD 5.1 need either ch=6 LPCM or a
    /// bitstream passthrough negotiation that the sink advertises in
    /// its EDID. Sonos Arc (and similar soundbars) report ch=2 on the
    /// HDMI port when the sink is in stereo PCM mode — usually after a
    /// boot, an HDMI handshake glitch, or after the AVR/soundbar lost
    /// the Apple TV's audio format hint. AVPlayer can still try the
    /// bitstream-passthrough path, but Sonos can apparently reject it
    /// when ch=2 is advertised, falling back to PCM stereo. Common fix
    /// is a power cycle of the soundbar so EDID re-negotiates and ch=6
    /// becomes available, OR the user can flip Apple TV's audio format
    /// setting once to force a re-handshake.
    ///
    /// This is a route capability mismatch, not a bug in our pipeline.
    /// The EAC3 bitstream we deliver is identical across runs (we
    /// proved this with byte-level diff of the dec3 box and the first
    /// audio packet), so when one run plays surround and the next
    /// stereo on the same source, the difference is at the sink layer.
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

    /// Dump the active audio route's channel capability after the
    /// AVPlayerItem reaches readyToPlay. The route renegotiates when
    /// AVPlayer loads an asset, so the channel count we polled at
    /// AVAudioSession setup (engine init, before any asset existed)
    /// can differ from the post-load capability.
    ///
    /// `outputNumberOfChannels` is the actual channel count the route
    /// will carry — if the asset is 8-channel FLAC but the soundbar /
    /// AVR doesn't accept 7.1 LPCM via HDMI, the route stays at 2 and
    /// AVPlayer's PCM decoder downmixes upstream. EAC3 / Atmos avoids
    /// this because the bitstream tunnels through as encoded data
    /// without an LPCM intermediate.
    private static func dumpAudioRoute(sid: Int, phase: String) {
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

    /// Read sample rate, channel count, and channel layout tag from
    /// a CMAudioFormatDescription. Used by `dumpAssetTracks` to expose
    /// what AVPlayer actually parsed for the audio track. Critical for
    /// multichannel sources: if libavformat's mov muxer wrote the
    /// codec / dfLa / chnl / chan boxes correctly, the channel layout
    /// tag here matches the source's spatial layout (kAudio...7_1_A for
    /// MPEG-style 7.1). If the tag comes back unknown or stereo, the
    /// downmix is happening at the AVPlayer parse layer rather than at
    /// the soundbar / route layer.
    private static func audioFormatDescription(_ fmt: CMFormatDescription) -> String {
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
