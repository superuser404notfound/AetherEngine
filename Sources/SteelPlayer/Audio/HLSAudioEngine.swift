import Foundation
import AVFoundation
import CoreMedia
import Libavformat
import Libavcodec

/// Audio engine that uses AVPlayer + local HLS for EAC3 Dolby Atmos passthrough.
///
/// ## A/V Sync Strategy
///
/// The video timebase starts at rate=1.0 immediately — video plays from
/// frame 1. The demux loop runs normally (video back-pressure + audio feed).
/// AVPlayer takes ~2-4 seconds to buffer and start. During this time, video
/// is already 2-4 seconds ahead of audio.
///
/// When AVPlayer starts, the drift correction detects that the timebase is
/// ahead and **pauses it** (rate=0). Video freezes for 2-4 seconds while
/// AVPlayer catches up. Once caught up, the timebase resumes at rate=1.0.
/// From that point, audio and video are perfectly in sync.
///
/// This approach has zero complexity: no video buffering, no replay queues,
/// no skipping, no seek-back. Just start-pause-resume.
final class HLSAudioEngine: @unchecked Sendable {

    // MARK: - Properties

    private var muxer: FMP4AudioMuxer?
    private var server: HLSAudioServer?
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?

    private(set) var videoTimebase: CMTimebase?

    private let _isPlayerPlaying = NSLock()
    nonisolated(unsafe) private var __isPlayerPlaying = false
    var isPlayerPlaying: Bool {
        _isPlayerPlaying.lock()
        defer { _isPlayerPlaying.unlock() }
        return __isPlayerPlaying
    }
    private func setPlayerPlaying(_ value: Bool) {
        _isPlayerPlaying.lock()
        __isPlayerPlaying = value
        _isPlayerPlaying.unlock()
    }

    private var _rate: Float = 1.0
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    var onPlaybackFailed: (@Sendable () -> Void)?

    // MARK: - Segment Buffering

    private let bufferLock = NSLock()
    private var frameBuffer: [Data] = []
    private var isPlayerCreated = false

    private let framesPerSegment = 64
    private(set) var segmentDuration: Double = 2.048

    var segmentCount: Int {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return server?.segmentCount ?? 0
    }

    // MARK: - Stream Offset

    /// Offset between AVPlayer's 0-based timeline and the stream's PTS.
    private var streamOffset: Double = 0

    // MARK: - Stored Config

    private var storedCodecType: FMP4AudioMuxer.CodecType = .eac3
    private var storedSampleRate: UInt32 = 48000
    private var storedChannelCount: UInt32 = 6
    private var storedBitRate: UInt32 = 0
    private var storedStartTime: CMTime = .zero

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

    var currentTime: CMTime { player?.currentTime() ?? .zero }

    var currentTimeSeconds: Double {
        let t = CMTimeGetSeconds(currentTime)
        return t.isFinite ? t + streamOffset : 0
    }

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

        let startSeconds = CMTimeGetSeconds(startTime)
        streamOffset = startSeconds.isFinite ? startSeconds : 0

        bufferLock.lock()
        storedCodecType = codecType
        storedSampleRate = sampleRate
        storedChannelCount = channelCount
        storedBitRate = bitRate
        storedStartTime = startTime
        frameBuffer.removeAll()
        isPlayerCreated = false
        bufferLock.unlock()

        setPlayerPlaying(false)

        let srv = HLSAudioServer()
        try srv.start()
        server = srv

        segmentDuration = Double(framesPerSegment) * 1536.0 / Double(sampleRate)

        // Start timebase immediately at rate=1.0 so the display layer
        // consumes video frames from the start. No deadlocks, no skipping.
        if let tb = videoTimebase {
            CMTimebaseSetTime(tb, time: startTime)
            CMTimebaseSetRate(tb, rate: 1.0)
        }

        #if DEBUG
        let codecName = codecType == .eac3 ? "EAC3" : "AC3"
        print("[HLSAudioEngine] Prepared: \(codecName) \(sampleRate)Hz \(channelCount)ch, offset=\(String(format: "%.1f", streamOffset))s")
        #endif
    }

    func feedPacket(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard packet.pointee.size > 0, packet.pointee.data != nil else { return }
        let packetData = Data(bytes: packet.pointee.data, count: Int(packet.pointee.size))

        bufferLock.lock()

        if muxer == nil {
            if var config = FMP4AudioMuxer.detectConfig(
                codecType: storedCodecType,
                sampleRate: storedSampleRate,
                channelCount: storedChannelCount,
                bitRate: storedBitRate,
                firstPacketData: packetData
            ) {
                if config.codecType == .eac3 && config.numDepSub == 0 {
                    config = FMP4AudioMuxer.Config(
                        codecType: config.codecType, sampleRate: config.sampleRate,
                        channelCount: config.channelCount, bitRate: config.bitRate,
                        samplesPerFrame: config.samplesPerFrame, fscod: config.fscod,
                        bsid: config.bsid, bsmod: config.bsmod, acmod: config.acmod,
                        lfeon: config.lfeon, frmsizecod: config.frmsizecod,
                        numDepSub: 1, depChanLoc: 0x0100
                    )
                }

                let m = FMP4AudioMuxer(config: config)
                muxer = m
                server?.setInitSegment(m.createInitSegment())

                #if DEBUG
                print("[HLSAudioEngine] Muxer ready: EAC3 (Atmos/JOC declared)")
                #endif
            }
        }

        frameBuffer.append(packetData)

        if frameBuffer.count >= framesPerSegment, let m = muxer {
            let frames = Array(frameBuffer.prefix(framesPerSegment))
            frameBuffer.removeFirst(framesPerSegment)

            let segment = m.createMediaSegment(frames: frames)
            server?.addMediaSegment(segment, duration: segmentDuration)

            #if DEBUG
            let count = server?.segmentCount ?? 0
            print("[HLSAudioEngine] Segment \(count - 1) created (\(segment.count) bytes)")
            #endif

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
        setPlayerPlaying(false)
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
        player = nil
        muxer = nil
        server?.stop()
        server = nil
        setPlayerPlaying(false)
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
                guard let self else { return }
                self.player?.play()
                self.setPlayerPlaying(true)
                #if DEBUG
                let tbTime = self.videoTimebase.map { CMTimeGetSeconds(CMTimebaseGetTime($0)) } ?? 0
                print("[HLSAudioEngine] PlayerItem ready -> play() (timebase at \(String(format: "%.1f", tbTime))s)")
                #endif
            } else if item.status == .failed {
                #if DEBUG
                print("[HLSAudioEngine] PlayerItem FAILED: \(item.error?.localizedDescription ?? "?")")
                #endif
                failureCallback?()
            }
        }

        setupTimeSync()
    }

    // MARK: - Video Timebase Sync

    private func setupTimeSync() {
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isPlayerPlaying else { return }
            self.syncTimebase()
        }
    }

    private func removeTimeSync() {
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
    }

    private func syncTimebase() {
        guard let tb = videoTimebase, let player else { return }
        let playerTime = player.currentTime()
        guard playerTime.isValid else { return }

        let playerStreamTime = CMTimeGetSeconds(playerTime) + streamOffset
        let tbTime = CMTimeGetSeconds(CMTimebaseGetTime(tb))
        let drift = playerStreamTime - tbTime  // positive = tb behind, negative = tb ahead

        if drift > 0.05 {
            // Timebase fell behind player → snap forward, ensure playing
            let corrected = CMTimeMakeWithSeconds(playerStreamTime, preferredTimescale: 90000)
            CMTimebaseSetTime(tb, time: corrected)
            if CMTimebaseGetRate(tb) == 0 {
                CMTimebaseSetRate(tb, rate: Float64(_rate))
                #if DEBUG
                print("[HLSAudioEngine] Video resumed at \(String(format: "%.1f", playerStreamTime))s")
                #endif
            }
        } else if drift < -0.2 {
            // Timebase ahead of player → pause video, let audio catch up
            if CMTimebaseGetRate(tb) != 0 {
                CMTimebaseSetRate(tb, rate: 0)
                #if DEBUG
                print("[HLSAudioEngine] Video paused (ahead by \(String(format: "%.1f", -drift))s, waiting for audio)")
                #endif
            }
        } else if abs(drift) <= 0.2 && CMTimebaseGetRate(tb) == 0 {
            // Within sync threshold and currently paused → resume
            let corrected = CMTimeMakeWithSeconds(playerStreamTime, preferredTimescale: 90000)
            CMTimebaseSetTime(tb, time: corrected)
            CMTimebaseSetRate(tb, rate: Float64(_rate))
            #if DEBUG
            print("[HLSAudioEngine] Video synced and resumed at \(String(format: "%.1f", playerStreamTime))s")
            #endif
        }
    }
}

enum HLSAudioEngineError: Error {
    case noCodecParameters
}
