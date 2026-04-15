import Foundation
import AVFoundation
import CoreMedia
import Libavformat
import Libavcodec

/// Audio engine that uses AVPlayer + local HLS for EAC3 Dolby Atmos passthrough.
///
/// ## How It Works
///
/// 1. Raw EAC3 packets from the demuxer are buffered in `frameBuffer`
/// 2. Every 64 frames (~2s), a fMP4 media segment is created via FMP4AudioMuxer
/// 3. The segment is added to HLSAudioServer which serves it via HTTP
/// 4. AVPlayer connects to `http://127.0.0.1:{port}/audio.m3u8` (HLS playlist)
/// 5. AVPlayer fetches init segment + media segments, decodes EAC3
/// 6. For EAC3+JOC (Atmos), AVPlayer wraps as Dolby MAT 2.0 → HDMI passthrough
///
/// ## A/V Sync
///
/// Video uses a CMTimebase (controlTimebase on display layer).
/// The timebase starts at rate=1.0 immediately to prevent deadlocks.
/// Once AVPlayer is playing, the timebase is synced to AVPlayer.currentTime().
final class HLSAudioEngine: @unchecked Sendable {

    // MARK: - Properties

    private var muxer: FMP4AudioMuxer?
    private var server: HLSAudioServer?
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?

    /// CMTimebase for video sync — starts at rate=1.0 immediately.
    private(set) var videoTimebase: CMTimebase?

    private var _rate: Float = 1.0
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    /// Called when AVPlayer fails — host should fall back to CompressedAudioFeeder.
    var onPlaybackFailed: (() -> Void)?

    // MARK: - Segment Buffering

    private let bufferLock = NSLock()
    private var frameBuffer: [Data] = []
    private var isPlayerCreated = false

    /// Frames per HLS segment. 64 × 1536 samples / 48kHz = 2.048 seconds.
    /// AVPlayer requires segments >= ~2s for HLS to become readyToPlay.
    private let framesPerSegment = 64

    /// Duration of one segment in seconds.
    private var segmentDuration: Double = 2.048

    // MARK: - Init

    init() {
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb
        )
        videoTimebase = tb
        // Start immediately at rate=1.0 to prevent video deadlock.
        // The display layer needs an advancing timebase to consume frames,
        // which unblocks the demux loop to feed us audio packets.
        if let tb = tb {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
        }
    }

    // MARK: - Public API

    var currentTime: CMTime { player?.currentTime() ?? .zero }

    /// True once AVPlayer is actively playing audio.
    /// During HLS buffering this is false — the demux loop should skip
    /// video back-pressure to keep audio packets flowing.
    var isPlayerPlaying: Bool {
        player?.timeControlStatus == .playing
    }

    var currentTimeSeconds: Double {
        let t = CMTimeGetSeconds(currentTime)
        return t.isFinite ? t : 0
    }

    /// Prepare the engine with codec parameters from the audio stream.
    /// Call once from load(), before feedPacket().
    func prepare(
        stream: UnsafeMutablePointer<AVStream>,
        startTime: CMTime = .zero
    ) throws {
        guard let codecpar = stream.pointee.codecpar else {
            throw HLSAudioEngineError.noCodecParameters
        }

        let codecId = codecpar.pointee.codec_id
        let codecType: FMP4AudioMuxer.CodecType = (codecId == AV_CODEC_ID_EAC3) ? .eac3 : .ac3
        let sampleRate = max(UInt32(codecpar.pointee.sample_rate), 48000)
        let channelCount = max(UInt32(codecpar.pointee.ch_layout.nb_channels), 2)
        let bitRate = UInt32(codecpar.pointee.bit_rate)

        // We need the first packet to detect codec config (fscod, acmod, etc.)
        // Store params for later use in feedPacket()
        bufferLock.lock()
        storedCodecType = codecType
        storedSampleRate = sampleRate
        storedChannelCount = channelCount
        storedBitRate = bitRate
        storedStartTime = startTime
        frameBuffer.removeAll()
        isPlayerCreated = false
        bufferLock.unlock()

        // Start the HLS server
        let srv = HLSAudioServer()
        try srv.start()
        server = srv

        segmentDuration = Double(framesPerSegment) * 1536.0 / Double(sampleRate)

        #if DEBUG
        let codecName = codecType == .eac3 ? "EAC3" : "AC3"
        print("[HLSAudioEngine] Prepared: \(codecName) \(sampleRate)Hz \(channelCount)ch, segment=\(String(format: "%.3f", segmentDuration))s")
        #endif
    }

    private var storedCodecType: FMP4AudioMuxer.CodecType = .eac3
    private var storedSampleRate: UInt32 = 48000
    private var storedChannelCount: UInt32 = 6
    private var storedBitRate: UInt32 = 0
    private var storedStartTime: CMTime = .zero

    /// Feed a raw EAC3/AC3 packet. Buffers frames and creates segments.
    /// On the first packet, initializes the muxer. After enough frames,
    /// creates AVPlayer.
    func feedPacket(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard packet.pointee.size > 0, packet.pointee.data != nil else { return }
        let packetData = Data(bytes: packet.pointee.data, count: Int(packet.pointee.size))

        bufferLock.lock()

        // Initialize muxer from first packet (needs bitstream header for dec3 box)
        if muxer == nil {
            if let config = FMP4AudioMuxer.detectConfig(
                codecType: storedCodecType,
                sampleRate: storedSampleRate,
                channelCount: storedChannelCount,
                bitRate: storedBitRate,
                firstPacketData: packetData
            ) {
                let m = FMP4AudioMuxer(config: config)
                let startSeconds = CMTimeGetSeconds(storedStartTime)
                if startSeconds > 0 {
                    m.reset(atTimeSeconds: startSeconds)
                }
                muxer = m

                // Generate and register init segment
                let initSegment = m.createInitSegment()
                server?.setInitSegment(initSegment)

                #if DEBUG
                let atmos = config.numDepSub > 0 ? " (Atmos: \(config.numDepSub) dep sub)" : ""
                print("[HLSAudioEngine] Muxer ready: \(config.codecType == .eac3 ? "EAC3" : "AC3")\(atmos)")
                #endif
            }
        }

        frameBuffer.append(packetData)

        // Check if we have enough frames for a segment
        if frameBuffer.count >= framesPerSegment, let m = muxer {
            let frames = Array(frameBuffer.prefix(framesPerSegment))
            frameBuffer.removeFirst(framesPerSegment)

            let segment = m.createMediaSegment(frames: frames)
            server?.addMediaSegment(segment, duration: segmentDuration)

            #if DEBUG
            let count = server?.segmentCount ?? 0
            print("[HLSAudioEngine] Segment \(count - 1) created (\(segment.count) bytes)")
            #endif

            // Create AVPlayer after first segment is ready
            if !isPlayerCreated {
                isPlayerCreated = true
                bufferLock.unlock()
                createPlayer()
                return
            }
        }

        bufferLock.unlock()
    }

    func pause() {
        player?.pause()
        if let tb = videoTimebase { CMTimebaseSetRate(tb, rate: 0) }
    }

    func resume() {
        player?.play()
        if let tb = videoTimebase {
            syncTimebase()
            CMTimebaseSetRate(tb, rate: Float64(_rate))
        }
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
        initialSyncDone = false
        bufferLock.lock()
        frameBuffer.removeAll()
        isPlayerCreated = false
        bufferLock.unlock()
    }

    func prepareForSeek() {
        removeTimeSync()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        muxer = nil
        server?.stop()
        server = nil
        initialSyncDone = false
        bufferLock.lock()
        frameBuffer.removeAll()
        isPlayerCreated = false
        bufferLock.unlock()
    }

    func restartAfterSeek(stream: UnsafeMutablePointer<AVStream>, seekTime: CMTime) throws {
        try prepare(stream: stream, startTime: seekTime)
    }

    // MARK: - AVPlayer Creation

    private func createPlayer() {
        guard let url = server?.playlistURL else {
            #if DEBUG
            print("[HLSAudioEngine] No playlist URL")
            #endif
            onPlaybackFailed?()
            return
        }

        #if DEBUG
        print("[HLSAudioEngine] Creating AVPlayer: \(url)")
        #endif

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4.0

        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        self.playerItem = item
        self.player = p

        let failureCallback = self.onPlaybackFailed
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            if item.status == .readyToPlay {
                self?.player?.play()
                #if DEBUG
                print("[HLSAudioEngine] PlayerItem ready → play()")
                #endif
            } else if item.status == .failed {
                #if DEBUG
                print("[HLSAudioEngine] PlayerItem FAILED: \(item.error?.localizedDescription ?? "?")")
                if let e = item.error as NSError? {
                    print("[HLSAudioEngine]   domain=\(e.domain) code=\(e.code)")
                }
                #endif
                failureCallback?()
            }
        }

        setupTimeSync()
    }

    // MARK: - Video Timebase Sync

    private func setupTimeSync() {
        guard let player = player else { return }
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

    /// True once AVPlayer has started and we've done the initial sync.
    private var initialSyncDone = false

    private func syncTimebase() {
        guard let tb = videoTimebase, let player = player else { return }
        let playerTime = player.currentTime()
        guard playerTime.isValid else { return }
        let playerSec = CMTimeGetSeconds(playerTime)
        let tbSec = CMTimeGetSeconds(CMTimebaseGetTime(tb))

        if !initialSyncDone && playerSec > 0.1 {
            // First sync: snap video to where AVPlayer is.
            // The video timebase may have been running ahead during HLS buffering.
            initialSyncDone = true
            CMTimebaseSetTime(tb, time: playerTime)
            CMTimebaseSetRate(tb, rate: Float64(_rate))
            #if DEBUG
            print("[HLSAudioEngine] Initial sync: video snapped to audio t=\(String(format: "%.2f", playerSec))s (was \(String(format: "%.2f", tbSec))s)")
            #endif
            return
        }

        guard initialSyncDone else { return }

        // Ongoing sync: only correct small drifts (< 2s).
        // Never jump backward by more than 2s — causes video stutter.
        let drift = playerSec - tbSec
        if abs(drift) > 0.05 && abs(drift) < 2.0 {
            CMTimebaseSetTime(tb, time: playerTime)
        }
    }
}

enum HLSAudioEngineError: Error {
    case noCodecParameters
}
