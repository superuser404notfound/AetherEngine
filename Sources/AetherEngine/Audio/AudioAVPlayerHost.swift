import Foundation
import AVFoundation
import Combine

/// Native audio-only playback host: hands the source URL directly to an
/// AVPlayer (no HLS, no loopback, no display layer). Used for audio whose
/// codec AVPlayer can decode natively (AAC, MP3, ALAC, FLAC, AC-3, ...),
/// for hardware-accelerated, energy-efficient playback and native system
/// integration. Codecs AVPlayer cannot decode use AudioPlaybackHost
/// (FFmpeg) instead. Mirrors AudioPlaybackHost's published surface so the
/// engine wires both paths the same way.
@MainActor
final class AudioAVPlayerHost {

    // MARK: - Published state (mirrors AudioPlaybackHost surface)

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    /// Mirrors `avPlayer.timeControlStatus` so the engine can reconcile its
    /// transport state when the system (Control Center, Siri Remote, AirPods)
    /// plays/pauses the AVPlayer directly rather than through our play()/
    /// pause(). Without this our `state` goes stale and the play/pause toggle
    /// is swallowed (looks like "only pause works").
    @Published private(set) var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    @Published private(set) var failureMessage: String?
    @Published private(set) var didReachEnd: Bool = false

    // MARK: - Output

    /// The underlying AVPlayer. Created once and reused across
    /// `replaceCurrentItem` swaps for the lifetime of this host.
    let avPlayer = AVPlayer()

    // MARK: - Private state

    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

    /// Cached rate so play() restores the right speed after a pause.
    private var lastRate: Float = 1.0

    /// Start-position seconds stashed at load(); performed once the item
    /// reaches readyToPlay, then cleared.
    private var pendingSeek: Double?

    // MARK: - Init

    init() {}

    // MARK: - Load

    func load(url: URL, startPosition: Double?, httpHeaders: [String: String]) async throws {
        // Clean any prior session's observers before swapping in a new
        // item, so a back-to-back load() doesn't leak or double-fire.
        teardownObservers()

        let asset: AVURLAsset
        if httpHeaders.isEmpty {
            asset = AVURLAsset(url: url)
        } else {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": httpHeaders])
        }
        let item = AVPlayerItem(asset: asset)
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

        // Status KVO: readyToPlay publishes duration + isReady and performs
        // the pending seek; failed publishes the error description. The
        // observer hops to its own queue, so round-trip back to MainActor.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            switch item.status {
            case .readyToPlay:
                Task { @MainActor [weak self] in
                    guard let self, let item = self.playerItem else { return }
                    let itemDuration = CMTimeGetSeconds(item.duration)
                    var resolved = itemDuration.isFinite && itemDuration > 0 ? itemDuration : 0
                    if resolved == 0 {
                        // item.duration can still be indefinite at the first
                        // readyToPlay edge; try the asset's loaded duration.
                        if let assetDuration = try? await item.asset.load(.duration) {
                            let s = CMTimeGetSeconds(assetDuration)
                            if s.isFinite, s > 0 { resolved = s }
                        }
                    }
                    self.duration = resolved
                    self.isReady = true
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

        // Mirror the player's rate into the published `rate`. timeControlStatus
        // and rate move together; observing rate is the simplest source.
        rateObservation = avPlayer.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let r = player.rate
            Task { @MainActor [weak self] in
                self?.rate = r
            }
        }

        // Mirror timeControlStatus so the engine reconciles transport state
        // on system-driven play/pause (Control Center / remote / AirPods).
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
            Task { @MainActor [weak self] in
                self?.failureMessage = message
            }
        }

        avPlayer.replaceCurrentItem(with: item)
        // No auto-play: the engine calls play() after load(), mirroring
        // AudioPlaybackHost.
    }

    // MARK: - Transport

    func play() {
        avPlayer.play()
        // AVPlayer.play() sets rate to 1.0; restore a non-default speed.
        if lastRate != 1.0 {
            avPlayer.rate = lastRate
        }
        rate = lastRate
    }

    func pause() {
        avPlayer.pause()
        rate = 0
    }

    func setRate(_ newRate: Float) {
        lastRate = newRate
        if avPlayer.timeControlStatus != .paused {
            avPlayer.rate = newRate
        }
        rate = newRate
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
    }

    var volume: Float {
        get { avPlayer.volume }
        set { avPlayer.volume = newValue }
    }

    // MARK: - Internal

    /// Remove the periodic time observer, invalidate the KVO observations,
    /// and unregister the notification observers. Idempotent: each handle
    /// is niled after removal so a second call (e.g. load() then stop())
    /// can't double-remove.
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
