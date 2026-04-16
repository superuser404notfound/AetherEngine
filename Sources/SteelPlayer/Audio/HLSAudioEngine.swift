import Foundation
import AVFoundation
import CoreMedia
import Libavformat
import Libavcodec

/// Audio engine that uses AVPlayer + local HLS for EAC3 Dolby Atmos passthrough.
///
/// ## A/V Sync with Stream Offset
///
/// AVPlayer normalizes HLS timeline to start at 0, regardless of fMP4
/// timestamps. Video frames use the original stream PTS (e.g., 476.5s
/// for a resumed playback). The engine tracks `streamOffset` to bridge
/// this gap: timebase = playerTime + streamOffset.
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

    /// Audio time covered so far in stream PTS space.
    var bufferedAudioTime: Double {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return streamOffset + Double(server?.segmentCount ?? 0) * segmentDuration
    }

    // MARK: - Stream Offset

    /// Offset between AVPlayer's 0-based timeline and the stream's PTS.
    /// Example: if playback starts at 476.5s, streamOffset = 476.5.
    /// Timebase = playerTime + streamOffset.
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
        if let tb {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 0)
        }
    }

    // MARK: - Public API

    var currentTime: CMTime { player?.currentTime() ?? .zero }

    /// Current playback time in the stream's timeline (with offset).
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

        // Timebase in stream PTS space, paused until AVPlayer starts
        if let tb = videoTimebase {
            CMTimebaseSetTime(tb, time: startTime)
            CMTimebaseSetRate(tb, rate: 0)
        }

        #if DEBUG
        let codecName = codecType == .eac3 ? "EAC3" : "AC3"
        print("[HLSAudioEngine] Prepared: \(codecName) \(sampleRate)Hz \(channelCount)ch, segment=\(String(format: "%.3f", segmentDuration))s, offset=\(String(format: "%.1f", streamOffset))s")
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
                // Always declare JOC for EAC3
                if config.codecType == .eac3 && config.numDepSub == 0 {
                    config = FMP4AudioMuxer.Config(
                        codecType: config.codecType,
                        sampleRate: config.sampleRate,
                        channelCount: config.channelCount,
                        bitRate: config.bitRate,
                        samplesPerFrame: config.samplesPerFrame,
                        fscod: config.fscod,
                        bsid: config.bsid,
                        bsmod: config.bsmod,
                        acmod: config.acmod,
                        lfeon: config.lfeon,
                        frmsizecod: config.frmsizecod,
                        numDepSub: 1,
                        depChanLoc: 0x0100
                    )
                }

                let m = FMP4AudioMuxer(config: config)
                // Muxer starts at 0 — AVPlayer normalizes HLS timeline to 0
                // regardless of internal timestamps. streamOffset bridges the gap.
                muxer = m

                let initSegment = m.createInitSegment()
                server?.setInitSegment(initSegment)

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
                self.onPlayerStarted()
                #if DEBUG
                print("[HLSAudioEngine] PlayerItem ready -> play()")
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

    private func onPlayerStarted() {
        guard let tb = videoTimebase else { return }
        // Set timebase in stream PTS space: playerTime(0) + streamOffset
        let streamTime = CMTimeMakeWithSeconds(streamOffset, preferredTimescale: 90000)
        CMTimebaseSetTime(tb, time: streamTime)
        CMTimebaseSetRate(tb, rate: Float64(_rate))
        setPlayerPlaying(true)

        #if DEBUG
        print("[HLSAudioEngine] Video timebase started at \(String(format: "%.3f", streamOffset))s (stream time)")
        #endif
    }

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
        // Convert player time (0-based) to stream time (offset-based)
        let playerSeconds = CMTimeGetSeconds(playerTime)
        let expectedStreamTime = playerSeconds + streamOffset
        let actualStreamTime = CMTimeGetSeconds(CMTimebaseGetTime(tb))
        let drift = expectedStreamTime - actualStreamTime
        if abs(drift) > 0.05 {
            let corrected = CMTimeMakeWithSeconds(expectedStreamTime, preferredTimescale: 90000)
            CMTimebaseSetTime(tb, time: corrected)
            #if DEBUG
            print("[HLSAudioEngine] Drift corrected: \(String(format: "%+.3f", drift))s (stream=\(String(format: "%.3f", expectedStreamTime))s)")
            #endif
        }
    }
}

enum HLSAudioEngineError: Error {
    case noCodecParameters
}
