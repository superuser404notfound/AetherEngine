import Foundation
import AVFoundation
import CoreMedia

/// Audio engine using AVPlayer for EAC3 playback with Dolby Atmos passthrough.
///
/// Uses a local HTTP server (LocalAudioServer) to stream fMP4 data to AVPlayer.
/// Custom URL schemes don't work on tvOS because media playback runs
/// out-of-process (mediaserverd). HTTP on localhost bypasses this.
///
/// ## Data Flow
///
/// ```
/// FFmpeg demuxer → raw EAC3 packets
///   → FMP4AudioMuxer (wraps in fMP4 segments)
///   → LocalAudioServer (HTTP on 127.0.0.1)
///   → AVPlayer (decodes EAC3, handles Dolby MAT 2.0 for Atmos)
///   → HDMI → Receiver shows "Dolby Atmos"
/// ```
final class AVPlayerAudioEngine: @unchecked Sendable {

    // MARK: - Properties

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var muxer: FMP4AudioMuxer?
    private var server: LocalAudioServer?

    /// CMTimebase for video sync — tracks AVPlayer's current time.
    private(set) var videoTimebase: CMTimebase?

    private var _rate: Float = 1.0
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    /// Called when AVPlayer fails to open the audio stream.
    var onPlaybackFailed: (() -> Void)?

    // MARK: - Init

    init() {
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb
        )
        videoTimebase = tb
    }

    // MARK: - Public API

    var currentTime: CMTime {
        player?.currentTime() ?? .zero
    }

    var currentTimeSeconds: Double {
        let t = CMTimeGetSeconds(currentTime)
        return t.isFinite ? t : 0
    }

    var volume: Float {
        get { player?.volume ?? 1.0 }
        set { player?.volume = newValue }
    }

    /// Start the audio engine with the first audio packet.
    func start(
        firstPacketData: Data,
        codecType: FMP4AudioMuxer.CodecType,
        sampleRate: UInt32,
        channelCount: UInt32,
        bitRate: UInt32,
        startTime: CMTime = .zero
    ) {
        guard let config = FMP4AudioMuxer.detectConfig(
            codecType: codecType,
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitRate: bitRate,
            firstPacketData: firstPacketData
        ) else {
            #if DEBUG
            print("[AVPlayerAudioEngine] Failed to parse codec config")
            #endif
            onPlaybackFailed?()
            return
        }

        let muxer = FMP4AudioMuxer(config: config)
        let startSeconds = CMTimeGetSeconds(startTime)
        if startSeconds > 0 {
            muxer.reset(atTimeSeconds: startSeconds)
        }
        self.muxer = muxer

        let initSegment = muxer.createInitSegment()
        let firstMedia = muxer.createMediaSegment(frames: [firstPacketData])

        #if DEBUG
        let hexPrefix = initSegment.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[AVPlayerAudioEngine] Init: \(initSegment.count)B + media: \(firstMedia.count)B")
        print("[AVPlayerAudioEngine] ftyp hex: \(hexPrefix)")
        #endif

        // Start local HTTP server and send initial data
        let srv = LocalAudioServer()
        do {
            try srv.start()
        } catch {
            #if DEBUG
            print("[AVPlayerAudioEngine] Server start failed: \(error)")
            #endif
            onPlaybackFailed?()
            return
        }
        self.server = srv

        // Send init segment + first media segment to server buffer
        srv.send(initSegment)
        srv.send(firstMedia)

        guard let url = srv.streamURL else {
            #if DEBUG
            print("[AVPlayerAudioEngine] No server URL")
            #endif
            onPlaybackFailed?()
            return
        }

        #if DEBUG
        print("[AVPlayerAudioEngine] Streaming from: \(url)")
        #endif

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4.0

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.playerItem = item
        self.player = player

        let failureCallback = self.onPlaybackFailed
        statusObservation = item.observe(\.status) { item, _ in
            if item.status == .failed {
                #if DEBUG
                print("[AVPlayerAudioEngine] PlayerItem FAILED: \(item.error?.localizedDescription ?? "?")")
                if let e = item.error as NSError? {
                    print("[AVPlayerAudioEngine]   domain=\(e.domain) code=\(e.code)")
                }
                #endif
                failureCallback?()
            }
            #if DEBUG
            if item.status == .readyToPlay {
                print("[AVPlayerAudioEngine] PlayerItem ready to play")
            }
            #endif
        }

        setupTimeSync()

        if startSeconds > 0 {
            player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.rate = _rate

        #if DEBUG
        let atmosStr = config.numDepSub > 0 ? " (Atmos: \(config.numDepSub) dep sub)" : ""
        print("[AVPlayerAudioEngine] Started: EAC3\(atmosStr), \(config.sampleRate)Hz, \(config.channelCount)ch")
        #endif
    }

    /// Feed a subsequent audio packet (raw EAC3 frame data).
    func feedPacket(_ data: Data) {
        guard let muxer = muxer else { return }
        let segment = muxer.createMediaSegment(frames: [data])
        server?.send(segment)
    }

    /// Prepare for seek.
    func prepareForSeek() {
        player?.pause()
        removeTimeSync()
        statusObservation = nil
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        server?.stop()
        server = nil
    }

    /// Restart after seek with packets from the new position.
    func restartAfterSeek(firstPacketData: Data, atTime time: CMTime) {
        guard let config = muxer?.config else { return }

        let newMuxer = FMP4AudioMuxer(config: config)
        newMuxer.reset(atTimeSeconds: CMTimeGetSeconds(time))
        self.muxer = newMuxer

        let initSegment = newMuxer.createInitSegment()
        let firstMedia = newMuxer.createMediaSegment(frames: [firstPacketData])

        let srv = LocalAudioServer()
        do {
            try srv.start()
        } catch {
            #if DEBUG
            print("[AVPlayerAudioEngine] Server restart failed: \(error)")
            #endif
            onPlaybackFailed?()
            return
        }
        self.server = srv

        srv.send(initSegment)
        srv.send(firstMedia)

        guard let url = srv.streamURL else {
            onPlaybackFailed?()
            return
        }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4.0
        player?.replaceCurrentItem(with: item)
        playerItem = item

        let failureCallback = self.onPlaybackFailed
        statusObservation = item.observe(\.status) { item, _ in
            if item.status == .failed {
                #if DEBUG
                print("[AVPlayerAudioEngine] PlayerItem failed after seek: \(item.error?.localizedDescription ?? "?")")
                #endif
                failureCallback?()
            }
        }

        setupTimeSync()
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        player?.rate = _rate
    }

    func pause() {
        player?.pause()
        if let tb = videoTimebase { CMTimebaseSetRate(tb, rate: 0) }
    }

    func resume() {
        if let tb = videoTimebase {
            syncTimebase()
            CMTimebaseSetRate(tb, rate: Float64(_rate))
        }
        player?.rate = _rate
    }

    func setRate(_ rate: Float) {
        _rate = rate
        player?.rate = rate
        if let tb = videoTimebase { CMTimebaseSetRate(tb, rate: Float64(rate)) }
    }

    func stop() {
        removeTimeSync()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        muxer = nil
        server?.stop()
        server = nil
    }

    // MARK: - Video Timebase Sync

    private func setupTimeSync() {
        guard let player = player else { return }
        if let tb = videoTimebase {
            CMTimebaseSetTime(tb, time: player.currentTime())
            CMTimebaseSetRate(tb, rate: Float64(_rate))
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] _ in
            self?.syncTimebase()
        }
    }

    private func removeTimeSync() {
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
    }

    private func syncTimebase() {
        guard let tb = videoTimebase, let player = player else { return }
        let drift = CMTimeGetSeconds(player.currentTime()) - CMTimeGetSeconds(CMTimebaseGetTime(tb))
        if abs(drift) > 0.03 {
            CMTimebaseSetTime(tb, time: player.currentTime())
        }
    }
}
