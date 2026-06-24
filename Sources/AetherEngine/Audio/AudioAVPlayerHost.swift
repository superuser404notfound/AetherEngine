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
    @Published private(set) var failureMessage: String?
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

    // MARK: - Private state

    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

    private var lastRate: Float = 1.0

    /// Start-position seconds stashed at load(); performed once readyToPlay, then cleared.
    private var pendingSeek: Double?

    /// Now-playing metadata applied to each loaded item's externalMetadata so it survives a back-to-back swap.
    /// externalMetadata feeds AVKit's on-screen info pane; on a bare AVPlayer (no AVPlayerViewController) it does
    /// NOT surface in system Now-Playing. The Now-Playing channel is `nowPlayingInfo` below.
    private var pendingExternalMetadata: [AVMetadataItem] = []

    /// Now-Playing metadata (MPMediaItemProperty keys + the host's already-force-decoded MPMediaItemArtwork) the
    /// host stages via setNowPlayingInfo. We publish it manually to the session's OWN center (see publishNowPlaying);
    /// stashed so a back-to-back item swap (replaceCurrentItem) and the 4 Hz elapsed/rate refresh can replay it.
    #if os(iOS) || os(tvOS)
    private var pendingNowPlayingInfo: [String: Any] = [:]
    #endif

    // MARK: - Init

    init() {
        #if os(tvOS) || os(iOS)
        nowPlayingSession = MPNowPlayingSession(players: [avPlayer])
        // Do NOT auto-publish. With automaticallyPublishesNowPlayingInfo = true the session harvests Now-Playing
        // from the asset's OWN contained metadata (AVKit AVPlayerItem.h externalMetadata: "Supplements metadata
        // contained in the asset ... will also be published as Now Playing Info"). For a Jellyfin FLAC/MP3 with an
        // embedded cover that means decoding the embedded picture as a still image; a corrupt/truncated one
        // ("Error -17102 decompressing image -- possibly corrupt") is then decoded on MediaPlayer's serial queue at
        // item-bind time (replaceCurrentItem -> dispatch_barrier_async) and trips dispatch_assert_queue_fail.
        // Instead we publish manually to the session's own center (publishNowPlaying), carrying only the host's
        // force-decoded artwork, so the embedded asset cover is never decoded. Writing the session's OWN center
        // (not MPNowPlayingInfoCenter.default()) from the MainActor is the sanctioned manual channel when off.
        nowPlayingSession.automaticallyPublishesNowPlayingInfo = false
        nowPlayingSession.becomeActiveIfPossible(completion: { _ in })
        #endif
    }

    /// Re-assert this session as active Now-Playing app on track start, reclaiming ownership if lost (keeps the
    /// Home overlay + remote commands alive across a background pause).
    func becomeActiveNowPlaying() {
        #if os(tvOS) || os(iOS)
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
        // externalMetadata is unavailable on macOS (package builds there for tests/aetherctl).
        #if !os(macOS)
        item.externalMetadata = pendingExternalMetadata
        #endif
        playerItem = item

        failureMessage = nil
        didReachEnd = false
        isReady = false
        currentTime = 0
        duration = 0
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
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
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
                    // Belt-and-suspenders: if a container exposes the embedded cover as a still-image VIDEO track
                    // (some MP4/M4A), disable it so nothing decodes it on the audio path. FLAC/MP3 embedded pictures
                    // usually arrive as common metadata (no track here), which auto-publish-off already covers.
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
                Task { @MainActor [weak self] in
                    self?.failureMessage = message
                }
            default:
                break
            }
        }

        // Mirror player rate into published `rate`. timeControlStatus and rate move together; rate is simplest.
        rateObservation = avPlayer.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let r = player.rate
            Task { @MainActor [weak self] in
                self?.rate = r
            }
        }

        // Mirror timeControlStatus so the engine reconciles transport on system-driven play/pause.
        timeControlObservation = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                self?.timeControlStatus = status
            }
        }

        // currentTime mirror at 4 Hz (matches AudioPlaybackHost's 250 ms).
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite, seconds >= 0 else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = seconds
                // Auto-publish is off: keep the system scrubber live ourselves (light patch, no artwork re-ship).
                self.refreshNowPlayingTiming()
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
            Task { @MainActor [weak self] in
                self?.failureMessage = message
            }
        }

        avPlayer.replaceCurrentItem(with: item)
        // Auto-publish is off, so seed the session's Now-Playing entry for this item now (the host has already
        // staged metadata via setNowPlayingInfo before load()).
        publishNowPlaying()
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
            "[AudioAVPlayerHost] tracks=\(item.tracks.count) disabledImageTracks=\(disabled) autoPublish=off",
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

    /// Stage the Now-Playing metadata (title/artist/album + the host's force-decoded artwork) and publish it. The
    /// host supplies it; we append the player-derived elapsed/rate/duration in publishNowPlaying. Pass an empty
    /// dict to clear. Auto-publish is off (see init), so we write the session's OWN center, never the shared default.
    #if os(iOS) || os(tvOS)
    func setNowPlayingInfo(_ info: [String: Any]) {
        pendingNowPlayingInfo = info
        publishNowPlaying()
    }
    #endif

    /// Publish the full Now-Playing entry (metadata + current elapsed/rate/duration) to the session's own center.
    /// MainActor-pinned (the host is @MainActor); never touches MPNowPlayingInfoCenter.default(). Clears on empty.
    private func publishNowPlaying() {
        #if os(iOS) || os(tvOS)
        guard !pendingNowPlayingInfo.isEmpty else {
            nowPlayingSession.nowPlayingInfoCenter.nowPlayingInfo = nil
            return
        }
        var info = pendingNowPlayingInfo
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        nowPlayingSession.nowPlayingInfoCenter.nowPlayingInfo = info
        #endif
    }

    /// Light refresh: patch only elapsed/rate/duration on the existing entry (no artwork re-ship). Driven by the
    /// 4 Hz time observer so the scrubber moves and a pause publishes rate 0. No-op until the first full publish.
    private func refreshNowPlayingTiming() {
        #if os(iOS) || os(tvOS)
        guard !pendingNowPlayingInfo.isEmpty,
              var info = nowPlayingSession.nowPlayingInfoCenter.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        nowPlayingSession.nowPlayingInfoCenter.nowPlayingInfo = info
        #endif
    }

    func play() {
        avPlayer.play()
        // play() forces rate 1.0; restore a non-default speed.
        if lastRate != 1.0 {
            avPlayer.rate = lastRate
        }
        rate = lastRate
        // Auto-publish is off: publish the rate change so the play button / scrubber reflect it (esp. on resume).
        publishNowPlaying()
    }

    func pause() {
        avPlayer.pause()
        rate = 0
        publishNowPlaying()
    }

    func setRate(_ newRate: Float) {
        lastRate = newRate
        if avPlayer.timeControlStatus != .paused {
            avPlayer.rate = newRate
        }
        rate = newRate
        publishNowPlaying()
    }

    func seek(to seconds: Double) async {
        await avPlayer.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = seconds
        publishNowPlaying()
    }

    func stop() {
        teardownObservers()
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        isReady = false
        playerItem = nil
        // Auto-publish is off, so the system no longer clears the entry on item teardown: do it explicitly here, or
        // the Home / Control-Center Now-Playing card lingers after stop. (Self-contained: the host's clearNowPlayingInfo
        // can't reach the session center once audioAVPlayerActive has flipped to false.)
        #if os(iOS) || os(tvOS)
        pendingNowPlayingInfo = [:]
        nowPlayingSession.nowPlayingInfoCenter.nowPlayingInfo = nil
        #endif
        // Host is persistent across tracks; clear terminal flags so the next load's subscriptions (wired before
        // host.load) don't replay them: stale didReachEnd=true fired .idle mid-load (double-skip on auto-advance
        // hosts), stale failureMessage flipped the new track to .error before it started.
        didReachEnd = false
        failureMessage = nil
    }

    var volume: Float {
        get { avPlayer.volume }
        set { avPlayer.volume = newValue }
    }

    // MARK: - Internal

    /// Remove time observer, invalidate KVO, unregister notification observers. Idempotent: each handle is niled
    /// after removal so a second call (load() then stop()) can't double-remove.
    private func teardownObservers() {
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
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
            self.failObserver = nil
        }
    }
}
