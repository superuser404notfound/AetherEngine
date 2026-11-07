import Foundation
import AVFoundation
import Combine
import MediaPlayer

/// Native audio-only host: source URL straight to an AVPlayer (no HLS/loopback/display layer) for codecs AVPlayer
/// decodes natively (AAC, MP3, ALAC, FLAC, AC-3). Others use AudioPlaybackHost (FFmpeg). Mirrors AudioPlaybackHost's
/// published surface so the engine wires both paths the same way.
@MainActor
final class AudioAVPlayerHost {

    // MARK: - Published state (mirrors AudioPlaybackHost surface)

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    /// Mirrors avPlayer.timeControlStatus so the engine reconciles transport when the system (Control Center,
    /// Siri Remote, AirPods) plays/pauses the AVPlayer directly. Without it `state` goes stale and the play/pause
    /// toggle is swallowed (looks like "only pause works").
    @Published private(set) var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    /// The item has played and is now starved: AVPlayer is `waitingToPlayAtSpecifiedRate`, or it posted
    /// `AVPlayerItemPlaybackStalled` and has not resumed since. The engine folds this into `isBuffering`,
    /// so `playbackPhase` reads `.rebuffering` on this path too (architecture.md promised that; the flag
    /// never existed). Startup spin-up before the first `.playing` is not a rebuffer, and a paused player
    /// is never one. See `rebufferingFlag(hasStartedPlaying:status:waitingReason:stalledSinceLastPlaying:)`.
    @Published private(set) var isRebuffering: Bool = false
    /// #376: carries the classification with the message, so the engine can publish both.
    @Published private(set) var failure: PlaybackErrorInfo?
    @Published private(set) var didReachEnd: Bool = false

    // MARK: - Output

    /// Created once, reused across replaceCurrentItem swaps for the host's lifetime.
    let avPlayer = AVPlayer()

    #if os(tvOS) || os(iOS)
    /// Now-Playing session bound to THIS player. The SHARED MPRemoteCommandCenter / MPNowPlayingInfoCenter aren't
    /// reliably bound to a bare AVPlayer: on background pause (rate 0) the app is dropped as active Now-Playing app
    /// and the shared center stops receiving ANY command (play button never returns). Binding a session keeps
    /// ownership across pause. WWDC22 guidance is "don't use MPNowPlayingSession on tvOS WHEN USING AVKit" (AVKit
    /// owns its own); for a bare AVPlayer with custom UI, owning the session explicitly is sanctioned. Mixing in the
    /// shared singletons is what produces the half-working state.
    let nowPlayingSession: MPNowPlayingSession
    #endif
    /// Sodalite#175: false for a `.secondary` engine, which never claims Now Playing. Set per load, the
    /// host outlives a role change.
    var ownsNowPlaying: Bool

    // MARK: - Private state

    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var waitingReasonObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var errorLogObserver: NSObjectProtocol?
    private var itemDiagnostics: AVPlayerItemDiagnostics?
    private let diagnosticPool: ItemDiagnosticReadPool
    private let diagnosticRead: AVPlayerItemDiagnostics.Read

    /// Rebuffer inputs for the current item; reset per `load()` / `stop()`. `hasStartedPlaying` latches
    /// on the first `.playing` so the pre-roll wait of a fresh item never reads as a stall;
    /// `stalledSinceLastPlaying` latches on `AVPlayerItemPlaybackStalled` and clears on the next `.playing`,
    /// covering the notification arriving ahead of the status change (or a player configured not to wait).
    private var hasStartedPlaying = false
    private var stalledSinceLastPlaying = false
    /// Mirrors avPlayer.reasonForWaitingToPlay for the rebuffer fold (Sodalite#168).
    private var waitingReason: AVPlayer.WaitingReason?

    private var lastRate: Float = 1.0

    /// Start-position seconds stashed at load(); performed once readyToPlay, then cleared.
    private var pendingSeek: Double?

    /// Now-playing externalMetadata. externalMetadata feeds AVKit's on-screen info pane; on a bare AVPlayer (no
    /// AVPlayerViewController) it does NOT surface in system Now-Playing. The Now-Playing channel is `nowPlayingInfo`.
    private var pendingExternalMetadata: [AVMetadataItem] = []

    /// Per-item Now-Playing dictionary (MPMediaItemProperty keys + the host's force-decoded, @Sendable-wrapped
    /// MPMediaItemArtwork) that the auto-publishing MPNowPlayingSession reads from AVPlayerItem.nowPlayingInfo.
    /// Stashed so a back-to-back item swap (replaceCurrentItem) replays it onto the new item.
    #if os(iOS) || os(tvOS)
    private var pendingNowPlayingInfo: [String: Any] = [:]
    #endif

    // MARK: - Init

    init(ownsNowPlaying: Bool = true,
         diagnosticPool: ItemDiagnosticReadPool = .shared,
         diagnosticRead: @escaping AVPlayerItemDiagnostics.Read = ItemDiagnosticSnapshot.read) {
        self.ownsNowPlaying = ownsNowPlaying
        self.diagnosticPool = diagnosticPool
        self.diagnosticRead = diagnosticRead
        #if os(tvOS) || os(iOS)
        nowPlayingSession = MPNowPlayingSession(players: [avPlayer])
        // Apple's documented path for a bare AVPlayer (WWDC22 110338, MPNowPlayingSession.h): the session
        // auto-publishes Now-Playing from the player (elapsed/rate/state/duration) merged with the per-item
        // AVPlayerItem.nowPlayingInfo we stamp. With YES, nowPlayingInfoCenter must NOT be written (we never do).
        // The host supplies a guaranteed-valid, force-decoded, @Sendable-wrapped artwork so the system never has to
        // fall back to (and decode) the asset's own embedded cover, which crashes on a corrupt one. This replaced a
        // manual-publish design whose MPMediaItemArtwork closure was non-@Sendable and tripped
        // dispatch_assert_queue_fail when MediaPlayer requested the bitmap off-actor.
        nowPlayingSession.automaticallyPublishesNowPlayingInfo = true
        if ownsNowPlaying { nowPlayingSession.becomeActiveIfPossible(completion: { _ in }) }
        #endif
    }

    /// Re-assert this session as active Now-Playing app on track start, reclaiming ownership if lost (keeps the
    /// Home overlay + remote commands alive across a background pause).
    func becomeActiveNowPlaying() {
        #if os(tvOS) || os(iOS)
        guard ownsNowPlaying else { return }
        nowPlayingSession.becomeActiveIfPossible(completion: { _ in })
        #endif
    }

    // MARK: - Load

    func load(url: URL, startPosition: Double?, httpHeaders: [String: String]) async throws {
        // Clean prior observers before swapping in a new item so a back-to-back load() doesn't leak or double-fire.
        teardownObservers()

        let asset: AVURLAsset
        if httpHeaders.isEmpty {
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": httpHeaders])
        }
        let item = AVPlayerItem(asset: asset)
        AudioRatePolicy.apply(to: item)
        // externalMetadata is unavailable on macOS (package builds there for tests/aetherctl).
        #if !os(macOS)
        item.externalMetadata = pendingExternalMetadata
        #endif
        // Stamp the per-item Now-Playing dict the auto-publishing session reads (iOS/tvOS 16+). Replays across swaps.
        #if os(iOS) || os(tvOS)
        item.nowPlayingInfo = pendingNowPlayingInfo.isEmpty ? nil : pendingNowPlayingInfo
        #endif
        playerItem = item
        let diagnostics = AVPlayerItemDiagnostics(item: item, pool: diagnosticPool, read: diagnosticRead)
        itemDiagnostics = diagnostics
        diagnostics.onSnapshot = { [weak self, weak diagnostics] snapshot, _ in
            guard let self, let diagnostics, self.itemDiagnostics === diagnostics else { return }
            for event in diagnostics.newErrors(in: snapshot) {
                guard self.itemDiagnostics === diagnostics else { return }
                EngineLog.emit(
                    "[AudioAVPlayerHost] item error log: domain=\(event.domain) status=\(event.code) "
                    + "comment=\(event.comment ?? "-") uri=\(event.uri ?? "-")",
                    category: .swPlayback)
            }
        }

        failure = nil
        didReachEnd = false
        isReady = false
        currentTime = 0
        duration = 0
        hasStartedPlaying = false
        stalledSinceLastPlaying = false
        waitingReason = nil
        isRebuffering = false
        if let start = startPosition, start > 0 {
            pendingSeek = start
            currentTime = start
        } else {
            pendingSeek = nil
        }

        EngineLog.emit(
            "[AudioAVPlayerHost] load url=\(url.absoluteString) "
            + "startPos=\(startPosition.map { String(format: "%.2fs", $0) } ?? "nil") "
            + "headers=\(httpHeaders.isEmpty ? "none" : "\(httpHeaders.count)")",
            category: .swPlayback
        )

        // Status KVO: readyToPlay publishes duration + isReady and performs the pending seek; failed publishes the
        // error. Observer hops to its own queue, so round-trip back to MainActor.
        statusObservation = item.observe(\.status, options: []) { [weak self] item, _ in
            switch item.status {
            case .readyToPlay:
                Task { @MainActor [weak self] in
                    guard let self, let item = self.playerItem else { return }
                    let itemDuration = CMTimeGetSeconds(item.duration)
                    var resolved = itemDuration.isFinite && itemDuration > 0 ? itemDuration : 0
                    if resolved == 0 {
                        // item.duration can still be indefinite at the first readyToPlay edge; try the asset's.
                        if let assetDuration = try? await item.asset.load(.duration) {
                            let s = CMTimeGetSeconds(assetDuration)
                            if s.isFinite, s > 0 { resolved = s }
                        }
                    }
                    self.duration = resolved
                    self.isReady = true
                    // Belt-and-suspenders for the M4A/MP4 shape that exposes the cover as a still-image VIDEO track:
                    // disable it so AVPlayer never decodes it. FLAC/MP3 embedded pictures arrive as common metadata
                    // (no track here, tracks=1) and are handled by supplying our own artwork on item.nowPlayingInfo.
                    self.disableEmbeddedImageTracks(on: item)
                    if let seek = self.pendingSeek {
                        self.pendingSeek = nil
                        await self.avPlayer.seek(
                            to: CMTime(seconds: seek, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                    }
                }
            case .failed:
                let message = item.error?.localizedDescription ?? "AVPlayerItem failed (no description)"
                let info = PlaybackErrorInfo(kind: .audioSessionFailed, message: message, underlying: item.error)
                Task { @MainActor [weak self] in
                    self?.failure = info
                }
            default:
                break
            }
        }

        // Mirror player rate into published `rate`. timeControlStatus and rate move together; rate is simplest.
        rateObservation = avPlayer.observe(\.rate, options: []) { [weak self] player, _ in
            let r = player.rate
            Task { @MainActor [weak self] in
                self?.rate = r
            }
        }

        // Mirror timeControlStatus so the engine reconciles transport on system-driven play/pause, and fold
        // it into the rebuffer flag: the first `.playing` opens the window in which a wait is a stall.
        timeControlObservation = avPlayer.observe(\.timeControlStatus, options: []) { [weak self] player, _ in
            let status = player.timeControlStatus
            let reason = player.reasonForWaitingToPlay?.rawValue
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.waitingReason = reason.map(AVPlayer.WaitingReason.init(rawValue:))
                self.timeControlStatus = status
                if status == .playing {
                    self.hasStartedPlaying = true
                    self.stalledSinceLastPlaying = false
                }
                self.refreshRebuffering()
            }
        }
        waitingReasonObservation = avPlayer.observe(\.reasonForWaitingToPlay, options: []) { [weak self] player, _ in
            // A cleared reason arrives just ahead of the status that ends the wait; that edge settles it.
            guard let reason = player.reasonForWaitingToPlay?.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.waitingReason = AVPlayer.WaitingReason(rawValue: reason)
                self.refreshRebuffering()
            }
        }

        // currentTime mirror at 4 Hz (matches AudioPlaybackHost's 250 ms). The auto-publishing session derives the
        // system scrubber/elapsed from the player itself, so we only mirror our own published clock here.
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite, seconds >= 0 else { return }
            Task { @MainActor [weak self] in
                self?.currentTime = seconds
            }
        }

        // End-of-track: only fire for THIS item (the notification is filtered
        // by `object: item`, but guard the published flag on MainActor too).
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.didReachEnd = true
            }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let err = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            let message = err?.localizedDescription ?? "Playback failed to reach end"
            let info = PlaybackErrorInfo(kind: .audioSessionFailed, message: message, underlying: err)
            Task { @MainActor [weak self] in
                self?.failure = info
            }
        }

        // A dry buffer mid-item. With `automaticallyWaitsToMinimizeStalling` (this host never turns it off)
        // the status flips to `.waitingToPlayAtSpecifiedRate` alongside; latch it anyway so the order of the
        // two signals cannot leave a stall unpublished.
        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                EngineLog.emit("[AudioAVPlayerHost] playback stalled (buffer ran dry)", category: .swPlayback)
                self.stalledSinceLastPlaying = true
                self.refreshRebuffering()
            }
        }

        // The item's own account of a failing fetch, otherwise invisible: no demuxer / reader logs on this path.
        errorLogObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak diagnostics] _ in
            MainActor.assumeIsolated {
                diagnostics?.request(.error)
            }
        }

        avPlayer.replaceCurrentItem(with: item)
        // No auto-play: the engine calls play() after load(), mirroring
        // AudioPlaybackHost.
    }

    /// Disable any embedded still-image presented as a video track (e.g. MP4/M4A cover art), so the audio path never
    /// decodes it. Logs the asset's track makeup so a device run can confirm what was excluded.
    private func disableEmbeddedImageTracks(on item: AVPlayerItem) {
        #if os(iOS) || os(tvOS)
        var disabled = 0
        for track in item.tracks where track.assetTrack?.mediaType == .video {
            track.isEnabled = false
            disabled += 1
        }
        EngineLog.emit(
            "[AudioAVPlayerHost] tracks=\(item.tracks.count) disabledImageTracks=\(disabled) autoPublish=on",
            category: .swPlayback
        )
        #endif
    }

    // MARK: - Transport

    /// Set now-playing metadata applied to current and subsequent items' externalMetadata.
    func setExternalMetadata(_ items: [AVMetadataItem]) {
        pendingExternalMetadata = items
        #if !os(macOS)
        playerItem?.externalMetadata = items
        #endif
    }

    /// Stage the per-item Now-Playing dictionary (current and subsequent items). The auto-publishing session merges
    /// these keys with the player's elapsed/rate/duration. Pass an empty dict to clear. Writing the per-item
    /// AVPlayerItem.nowPlayingInfo property is the documented, queue-safe channel (no MPNowPlayingInfoCenter write).
    #if os(iOS) || os(tvOS)
    func setNowPlayingInfo(_ info: [String: Any]) {
        pendingNowPlayingInfo = info
        playerItem?.nowPlayingInfo = info.isEmpty ? nil : info
    }
    #endif

    func play() {
        // #436: the speed rides on `defaultRate`, which is the rate play() starts at, so a resume no
        // longer needs a second rate write behind AVPlayer's back (that write also lost every play()
        // this host does not issue itself, e.g. from the remote command centre).
        avPlayer.play()
        rate = lastRate
    }

    func pause() {
        avPlayer.pause()
        rate = 0
    }

    func setRate(_ newRate: Float) {
        // #436: zero is a pause, not a speed. Remembered as one it becomes the rate the next play()
        // resumes at, and the session comes back paused from its own resume.
        if newRate != 0 {
            lastRate = newRate
            avPlayer.defaultRate = newRate
        }
        if avPlayer.timeControlStatus != .paused {
            avPlayer.rate = newRate
        }
        rate = newRate
    }

    func setResumeRate(_ rate: Float) {
        guard rate != 0 else { return }
        lastRate = rate
        avPlayer.defaultRate = rate
    }

    func seek(to seconds: Double) async {
        await avPlayer.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = seconds
    }

    func stop() {
        teardownObservers()
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        isReady = false
        playerItem = nil
        hasStartedPlaying = false
        stalledSinceLastPlaying = false
        waitingReason = nil
        isRebuffering = false
        // Clear the staged dict so the next track starts clean; the auto-publishing session drops the Now-Playing
        // entry when the player has no current item.
        #if os(iOS) || os(tvOS)
        pendingNowPlayingInfo = [:]
        #endif
        // Host is persistent across tracks; clear terminal flags so the next load's subscriptions (wired before
        // host.load) don't replay them: stale didReachEnd=true fired .idle mid-load (double-skip on auto-advance
        // hosts), stale failure flipped the new track to .error before it started.
        didReachEnd = false
        failure = nil
    }

    var volume: Float {
        get { avPlayer.volume }
        set { avPlayer.volume = newValue }
    }

    // MARK: - Internal

    /// Remove time observer, invalidate KVO, unregister notification observers. Idempotent: each handle is niled
    /// after removal so a second call (load() then stop()) can't double-remove.
    private func teardownObservers() {
        itemDiagnostics?.cancel()
        itemDiagnostics = nil
        if let timeObserver {
            avPlayer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        waitingReasonObservation?.invalidate()
        waitingReasonObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
            self.failObserver = nil
        }
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
        if let errorLogObserver {
            NotificationCenter.default.removeObserver(errorLogObserver)
            self.errorLogObserver = nil
        }
    }

    // MARK: - Rebuffering

    /// Idempotent recompute; publishes only on change so a redundant status write never fires the engine.
    private func refreshRebuffering() {
        let next = Self.rebufferingFlag(
            hasStartedPlaying: hasStartedPlaying,
            status: timeControlStatus,
            waitingReason: waitingReason,
            stalledSinceLastPlaying: stalledSinceLastPlaying
        )
        if isRebuffering != next { isRebuffering = next }
    }

    /// Pure fold behind `isRebuffering`: a wait counts only once the item has played (`.playing` seen for
    /// this item), never while the player is paused; a stall latched since the last `.playing` counts on
    /// its own so a notification that lands ahead of the status change is not lost. A resume's
    /// `evaluatingBufferingRate` wait is not a stall (Sodalite#168).
    nonisolated static func rebufferingFlag(
        hasStartedPlaying: Bool,
        status: AVPlayer.TimeControlStatus,
        waitingReason: AVPlayer.WaitingReason?,
        stalledSinceLastPlaying: Bool
    ) -> Bool {
        guard hasStartedPlaying, status != .paused else { return false }
        return AetherEngine.nativeWaitIsRebuffer(status: status, reason: waitingReason) || stalledSinceLastPlaying
    }
}
