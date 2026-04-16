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
/// ## EAC3+JOC Access Units
///
/// FFmpeg delivers independent and dependent substreams as separate AVPackets
/// with the same stream_index and PTS. This engine combines them into complete
/// access units: [independent frame][dependent frame(s)] before muxing to fMP4.
///
/// ## A/V Sync
///
/// Video uses a CMTimebase (controlTimebase on the display layer).
/// The timebase starts at rate=0 (paused) so video frames are buffered
/// but not displayed. The host should use a short back-pressure timeout
/// (not skip entirely) to avoid flooding VideoToolbox.
///
/// Once AVPlayer reaches readyToPlay:
/// 1. Timebase is set to player.currentTime() and rate=1.0
/// 2. Video and audio start at the same point → sync!
/// 3. Periodic drift correction (every 100ms, 50ms threshold)
final class HLSAudioEngine: @unchecked Sendable {

    // MARK: - Properties

    private var muxer: FMP4AudioMuxer?
    private var server: HLSAudioServer?
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?

    /// CMTimebase for video sync — controls the display layer's frame pacing.
    /// Starts at rate=0 (paused). Set to rate=1.0 when AVPlayer is ready.
    private(set) var videoTimebase: CMTimebase?

    /// True once AVPlayer has started playing audio.
    /// The host should use a short back-pressure timeout until this is true.
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

    /// Called when AVPlayer fails — host should fall back to CompressedAudioFeeder.
    var onPlaybackFailed: (@Sendable () -> Void)?

    // MARK: - Segment Buffering

    private let bufferLock = NSLock()
    /// Completed access units waiting to fill a segment.
    private var frameBuffer: [Data] = []
    private var isPlayerCreated = false

    /// Frames per HLS segment. 64 x 1536 samples / 48kHz = 2.048 seconds.
    private let framesPerSegment = 64

    /// Duration of one segment in seconds.
    private var segmentDuration: Double = 2.048

    // MARK: - Access Unit Assembly

    /// Pending independent frame waiting for dependent substream(s).
    /// When the next independent frame arrives, the pending one is finalized.
    private var pendingIndependent: Data?

    /// Whether we've detected a dependent substream (Atmos/JOC).
    private var hasAtmos = false

    /// Packets buffered before muxer creation to detect Atmos.
    /// We buffer up to `atmosDetectionLimit` packets before creating the muxer.
    private var earlyPackets: [(Data, Bool)]? = []  // (data, isDependent)
    private let atmosDetectionLimit = 4

    // MARK: - Stored Config (set in prepare, used in feedPacket)

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

    var currentTimeSeconds: Double {
        let t = CMTimeGetSeconds(currentTime)
        return t.isFinite ? t : 0
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

        bufferLock.lock()
        storedCodecType = codecType
        storedSampleRate = sampleRate
        storedChannelCount = channelCount
        storedBitRate = bitRate
        storedStartTime = startTime
        frameBuffer.removeAll()
        isPlayerCreated = false
        pendingIndependent = nil
        hasAtmos = false
        earlyPackets = []
        bufferLock.unlock()

        setPlayerPlaying(false)

        let srv = HLSAudioServer()
        try srv.start()
        server = srv

        segmentDuration = Double(framesPerSegment) * 1536.0 / Double(sampleRate)

        if let tb = videoTimebase {
            CMTimebaseSetTime(tb, time: startTime)
            CMTimebaseSetRate(tb, rate: 0)
        }

        #if DEBUG
        let codecName = codecType == .eac3 ? "EAC3" : "AC3"
        print("[HLSAudioEngine] Prepared: \(codecName) \(sampleRate)Hz \(channelCount)ch, segment=\(String(format: "%.3f", segmentDuration))s")
        #endif
    }

    /// Feed a raw EAC3/AC3 packet from the demuxer.
    ///
    /// FFmpeg delivers independent and dependent substreams as separate packets.
    /// This method combines them into complete access units before muxing.
    func feedPacket(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard packet.pointee.size > 0, packet.pointee.data != nil else { return }
        let packetData = Data(bytes: packet.pointee.data, count: Int(packet.pointee.size))

        // Detect substream type from EAC3 header
        let isDependent = packetData.count >= 3 && packetData[0] == 0x0B && packetData[1] == 0x77
            && ((packetData[2] >> 6) & 0x03) == 1

        bufferLock.lock()

        // Phase 1: Buffer early packets to detect Atmos before creating muxer
        if var early = earlyPackets {
            early.append((packetData, isDependent))
            if isDependent { hasAtmos = true }

            // Wait for enough packets or until we've seen a dependent substream
            if early.count < atmosDetectionLimit && !hasAtmos {
                earlyPackets = early
                bufferLock.unlock()
                return
            }

            // Create muxer with Atmos info and replay buffered packets
            earlyPackets = nil
            bufferLock.unlock()

            createMuxer(firstPacketData: early[0].0)

            for (data, dep) in early {
                processPacket(data, isDependent: dep)
            }
            return
        }

        bufferLock.unlock()

        // Create muxer from first independent packet if not yet created
        // (e.g., after seek with known Atmos — earlyPackets is nil)
        if !isDependent {
            bufferLock.lock()
            let needsMuxer = (muxer == nil)
            bufferLock.unlock()
            if needsMuxer {
                createMuxer(firstPacketData: packetData)
            }
        }

        processPacket(packetData, isDependent: isDependent)
    }

    /// Process a single packet — combine access units and feed to segment buffer.
    private func processPacket(_ packetData: Data, isDependent: Bool) {
        bufferLock.lock()

        if isDependent {
            // Dependent substream — append to pending independent
            if var pending = pendingIndependent {
                pending.append(packetData)
                pendingIndependent = pending
                // Finalize this access unit (independent + dependent)
                frameBuffer.append(pending)
                pendingIndependent = nil

                #if DEBUG
                if !hasAtmos {
                    print("[HLSAudioEngine] Atmos detected: dependent substream (\(packetData.count) bytes)")
                }
                #endif
                hasAtmos = true
            }
            // else: orphan dependent packet, skip it
        } else {
            // Independent substream — finalize any pending access unit first
            if let pending = pendingIndependent {
                frameBuffer.append(pending)  // Previous AU had no dependent
            }
            pendingIndependent = packetData
        }

        // Check if we have enough frames for a segment
        checkSegment()
    }

    /// Check if we have enough frames for a segment, create it if so.
    /// Must be called with bufferLock held. Releases lock before returning.
    private func checkSegment() {
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

    /// Create the FMP4 muxer from the first packet's bitstream header.
    private func createMuxer(firstPacketData: Data) {
        bufferLock.lock()
        guard muxer == nil else { bufferLock.unlock(); return }

        if var config = FMP4AudioMuxer.detectConfig(
            codecType: storedCodecType,
            sampleRate: storedSampleRate,
            channelCount: storedChannelCount,
            bitRate: storedBitRate,
            firstPacketData: firstPacketData
        ) {
            // Override numDepSub if we detected Atmos from packet stream
            if hasAtmos && config.numDepSub == 0 {
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
                    depChanLoc: 0x0100  // Lc/Rc pair (standard Atmos)
                )
            }

            let m = FMP4AudioMuxer(config: config)
            let startSeconds = CMTimeGetSeconds(storedStartTime)
            if startSeconds > 0 {
                m.reset(atTimeSeconds: startSeconds)
            }
            muxer = m

            let initSegment = m.createInitSegment()
            server?.setInitSegment(initSegment)

            #if DEBUG
            let atmos = config.numDepSub > 0 ? " (Atmos: \(config.numDepSub) dep sub)" : " (no Atmos/JOC)"
            print("[HLSAudioEngine] Muxer ready: \(config.codecType == .eac3 ? "EAC3" : "AC3")\(atmos)")
            print("[HLSAudioEngine]   fscod=\(config.fscod) bsid=\(config.bsid) acmod=\(config.acmod) lfeon=\(config.lfeon) channels=\(config.channelCount)")
            #endif
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
        pendingIndependent = nil
        earlyPackets = nil
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
        pendingIndependent = nil
        earlyPackets = nil
        bufferLock.unlock()
    }

    func restartAfterSeek(stream: UnsafeMutablePointer<AVStream>, seekTime: CMTime) throws {
        // Keep hasAtmos from before seek — don't re-detect
        let atmosDetected = hasAtmos
        try prepare(stream: stream, startTime: seekTime)
        hasAtmos = atmosDetected
        // Skip early detection phase if we already know
        if atmosDetected {
            bufferLock.lock()
            earlyPackets = nil
            bufferLock.unlock()
        }
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
                guard let self else { return }
                self.player?.play()
                self.onPlayerStarted()
                #if DEBUG
                print("[HLSAudioEngine] PlayerItem ready -> play()")
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

    private func onPlayerStarted() {
        guard let tb = videoTimebase, let player else { return }
        let playerTime = player.currentTime()
        let time = playerTime.isValid ? playerTime : storedStartTime
        CMTimebaseSetTime(tb, time: time)
        CMTimebaseSetRate(tb, rate: Float64(_rate))
        setPlayerPlaying(true)

        #if DEBUG
        let t = CMTimeGetSeconds(time)
        print("[HLSAudioEngine] Video timebase started at \(String(format: "%.3f", t))s")
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
        let playerSeconds = CMTimeGetSeconds(playerTime)
        let tbSeconds = CMTimeGetSeconds(CMTimebaseGetTime(tb))
        let drift = playerSeconds - tbSeconds
        if abs(drift) > 0.05 {
            CMTimebaseSetTime(tb, time: playerTime)
            #if DEBUG
            print("[HLSAudioEngine] Drift corrected: \(String(format: "%+.3f", drift))s (player=\(String(format: "%.3f", playerSeconds))s)")
            #endif
        }
    }
}

enum HLSAudioEngineError: Error {
    case noCodecParameters
}
