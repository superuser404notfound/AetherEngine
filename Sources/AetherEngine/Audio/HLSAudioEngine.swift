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

    private let playerPlayingLock = NSLock()
    nonisolated(unsafe) private var _isPlayerPlaying = false
    var isPlayerPlaying: Bool {
        playerPlayingLock.lock()
        defer { playerPlayingLock.unlock() }
        return _isPlayerPlaying
    }
    private func setPlayerPlaying(_ value: Bool) {
        playerPlayingLock.lock()
        _isPlayerPlaying = value
        playerPlayingLock.unlock()
    }

    private var _rate: Float = 1.0
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    /// Opaque tokens for `NotificationCenter.addObserver(forName:…)` so
    /// `stop()` can remove the corresponding handlers. Previously the
    /// observers lived as long as NotificationCenter itself.
    private var notificationTokens: [NSObjectProtocol] = []

    var onPlaybackFailed: (@Sendable () -> Void)?

    /// Called right before the timebase starts — host should flush the
    /// video renderer and re-set the skip threshold to the given PTS.
    var onWillStartTimebase: ((_ skipToPTS: CMTime) -> Void)?

    // MARK: - Segment Buffering

    private let bufferLock = NSLock()
    private var frameBuffer: [Data] = []
    private var isPlayerCreated = false

    /// Small segments reduce HLS pipeline latency. 64 frames = 2.048s
    /// caused ~2 seconds of audio delay. 16 frames = 0.512s ≈ 0.5s latency.
    private let framesPerSegment = 16
    private(set) var segmentDuration: Double = 2.048

    var segmentCount: Int {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return server?.segmentCount ?? 0
    }

    // MARK: - Stream Offset

    /// Offset between AVPlayer's 0-based timeline and the stream's PTS.
    /// Set to the actual first audio packet PTS (not the seek target) for
    /// precise sync after seek.
    private var streamOffset: Double = 0

    /// Whether the initial timebase snap has been performed.
    private var hasSnapped = false

    /// Whether the clock offset has been calibrated from measured drift.
    private var hasCalibrated = false

    /// User-configurable audio delay compensation in seconds.
    /// Positive = delay video (audio comes first from HLS pipeline).
    /// Set this from the host app based on the user's audio setup.
    /// Default 0 = no compensation (timebase matches AVPlayer.currentTime).
    var audioDelayCompensation: Double = 0

    /// Measured offset between CMTimebase (host clock) and AVPlayer's clock.
    /// Captured at the first snap, then used for drift correction.
    /// Varies by device/OS — not hardcoded.
    private var clockOffset: Double = 0

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
        hasSnapped = false
        hasCalibrated = false
        clockOffset = 0

        let srv = HLSAudioServer()
        try srv.start()
        server = srv

        segmentDuration = Double(framesPerSegment) * 1536.0 / Double(sampleRate)

        // Start timebase PAUSED — no video frames shown until AVPlayer starts.
        // The three-thread architecture ensures audio flows independently
        // even though the video decode thread blocks on the paused display.
        // When AVPlayer starts: flush video renderer (clear stale frames),
        // then start timebase at player position → perfect sync.
        if let tb = videoTimebase {
            CMTimebaseSetTime(tb, time: startTime)
            CMTimebaseSetRate(tb, rate: 0)
        }

        #if DEBUG
        let codecName = codecType == .eac3 ? "EAC3" : "AC3"
        print("[HLSAudioEngine] Prepared: \(codecName) \(sampleRate)Hz \(channelCount)ch, offset=\(String(format: "%.1f", streamOffset))s")
        #endif
    }

    func feedPacket(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard packet.pointee.size > 0, packet.pointee.data != nil else { return }
        let packetData = Data(bytes: packet.pointee.data, count: Int(packet.pointee.size))
        feedAudioData(packetData)
    }

    /// Feed raw audio data (already copied from AVPacket).
    /// Used by the background audio drain queue.
    func feedAudioData(_ packetData: Data) {

        bufferLock.lock()

        if muxer == nil {
            if var config = FMP4AudioMuxer.detectConfig(
                codecType: storedCodecType,
                sampleRate: storedSampleRate,
                channelCount: storedChannelCount,
                bitRate: storedBitRate,
                firstPacketData: packetData
            ) {
                // Always declare JOC in the dec3 box when routed through HLS.
                // AVPlayer needs this signaling to activate Dolby Atmos (MAT 2.0)
                // passthrough. The actual JOC data may be in the bitstream even
                // when our simple scan doesn't find dependent substreams
                // (FFmpeg may deliver them differently depending on the container).
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

        // Throttle: don't create more than 6 segments before AVPlayer starts.
        // Without this, the audio drain creates 20+ segments by the time
        // AVPlayer polls the playlist, causing it to start from the live edge
        // (seg16+) instead of seg0 → massive A/V content offset.
        if !isPlayerPlaying && (server?.segmentCount ?? 0) >= 6 && isPlayerCreated {
            bufferLock.unlock()
            // Wait for AVPlayer to start before creating more segments.
            // Bounded wait: ~10s max. If AVPlayer fails to start (network
            // error, stop() called, etc.) we must not block the demux thread
            // indefinitely. muxer==nil after stop() tears everything down.
            var waited: Double = 0
            while !isPlayerPlaying && waited < 10.0 {
                Thread.sleep(forTimeInterval: 0.05)
                waited += 0.05
                bufferLock.lock()
                let tornDown = (muxer == nil || server == nil)
                bufferLock.unlock()
                if tornDown { return }
            }
            bufferLock.lock()
            // Re-check state — stop() may have run during the wait
            guard muxer != nil, server != nil else {
                bufferLock.unlock()
                return
            }
        }

        if frameBuffer.count >= framesPerSegment, let m = muxer {
            let frames = Array(frameBuffer.prefix(framesPerSegment))
            frameBuffer.removeFirst(framesPerSegment)

            let segment = m.createMediaSegment(frames: frames)
            server?.addMediaSegment(segment, duration: segmentDuration)

            #if DEBUG
            let count = server?.segmentCount ?? 0
            print("[HLSAudioEngine] Segment \(count - 1) created (\(segment.count) bytes)")
            #endif

            // Create AVPlayer after 3 segments (~6s buffer). This prevents
            // the initial PlaybackStalled that occurs with only 1 segment.
            // Combined with automaticallyWaitsToMinimizeStalling=false and
            // no timebase pausing, this gives both zero-offset sync AND
            // enough initial buffer for uninterrupted playback.
            // With 0.5s segments, need more initial segments for ~3s buffer
            if !isPlayerCreated && (server?.segmentCount ?? 0) >= 6 {
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
        // Remove the per-item notification observers we registered in
        // createPlayer(). Without this they leak across playbacks.
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        muxer = nil
        server?.stop()
        server = nil
        videoTimebase = nil
        setPlayerPlaying(false)
        bufferLock.lock()
        frameBuffer.removeAll()
        isPlayerCreated = false
        bufferLock.unlock()
        // Reset sync state so the next prepare() starts fresh. Without
        // this a second playback kept the prior hasSnapped/calibrated
        // state and skipped the initial timebase snap → silent or
        // out-of-sync audio.
        hasSnapped = false
        hasCalibrated = false
        clockOffset = 0
        streamOffset = 0
    }

    func prepareForSeek() {
        removeTimeSync()
        statusObservation = nil
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        player = nil
        muxer = nil
        server?.stop()
        server = nil
        videoTimebase = nil
        setPlayerPlaying(false)
        bufferLock.lock()
        frameBuffer.removeAll()
        isPlayerCreated = false
        bufferLock.unlock()
        hasSnapped = false
        hasCalibrated = false
        clockOffset = 0
        streamOffset = 0
    }

    func restartAfterSeek(stream: UnsafeMutablePointer<AVStream>, seekTime: CMTime) throws {
        try prepare(stream: stream, startTime: seekTime)
    }

    /// Update streamOffset to the actual first audio packet PTS after seek.
    /// Called from the demux loop when the first non-skipped audio packet
    /// arrives. This corrects the offset from the seek target to the real
    /// audio position, fixing A/V sync after seek.
    func updateStreamOffset(_ actualPTSSeconds: Double) {
        let old = streamOffset
        streamOffset = actualPTSSeconds
        // Also update the timebase position to match (still paused at this point)
        if let tb = videoTimebase {
            let newTime = CMTimeMakeWithSeconds(actualPTSSeconds, preferredTimescale: 90000)
            CMTimebaseSetTime(tb, time: newTime)
        }
        #if DEBUG
        print("[HLSAudioEngine] streamOffset corrected: \(String(format: "%.3f", old)) → \(String(format: "%.3f", actualPTSSeconds))s (Δ\(String(format: "%.3f", old - actualPTSSeconds))s)")
        #endif
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

                // Snap timebase to match AVPlayer's position.
                // This eliminates the ~4s offset from the buffering period.
                // The display layer may briefly hold frames while the timebase
                // catches up, but this is short (~200ms for a few buffered frames)
                // and doesn't block the demux long enough to starve audio.
                // Don't snap here — player.currentTime() is unreliable at
                // readyToPlay. The snap happens at the first sync tick
                // (100ms later) when the player is actually playing.
                #if DEBUG
                if let tb = self.videoTimebase {
                    let tbTime = CMTimeGetSeconds(CMTimebaseGetTime(tb))
                    print("[HLSAudioEngine] PlayerItem ready -> play() (timebase at \(String(format: "%.1f", tbTime))s, snap pending)")
                }
                #endif
            } else if item.status == .failed {
                #if DEBUG
                print("[HLSAudioEngine] PlayerItem FAILED: \(item.error?.localizedDescription ?? "?")")
                if let log = item.errorLog() {
                    for event in log.events {
                        print("[HLSAudioEngine]   errorLog: domain=\(event.errorDomain) code=\(event.errorStatusCode) comment=\(event.errorComment ?? "nil")")
                    }
                }
                #endif
                failureCallback?()
            }
        }

        // Notifications — store tokens so stop() can remove them. Without
        // this, every createPlayer() added handlers that outlived the item
        // and accumulated across sessions — 20+ orphaned callbacks firing
        // on every playback event after ~10 plays.
        let failedToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            #if DEBUG
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            print("[HLSAudioEngine] FailedToPlayToEndTime: \(error?.localizedDescription ?? "unknown")")
            #endif
            self.onPlaybackFailed?()
        }
        let stalledToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item, queue: .main
        ) { _ in
            #if DEBUG
            print("[HLSAudioEngine] PlaybackStalled!")
            #endif
        }
        notificationTokens = [failedToken, stalledToken]

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

    private var syncLogCounter = 0

    private func syncTimebase() {
        guard let tb = videoTimebase, let player else { return }
        let playerTime = player.currentTime()
        guard playerTime.isValid else { return }

        let playerSeconds = CMTimeGetSeconds(playerTime)
        let playerStreamTime = playerSeconds + streamOffset
        let tbTime = CMTimeGetSeconds(CMTimebaseGetTime(tb))

        // One-time snap: wait until player is actually playing (currentTime > 0.5)
        // then snap the timebase to match. At readyToPlay, currentTime is
        // unreliable (player hasn't started decoding yet).
        if !hasSnapped && playerSeconds > 0.5 {
            hasSnapped = true

            // Flush video renderer and re-set skip threshold to our start PTS.
            let startPTS = CMTimeMakeWithSeconds(playerStreamTime, preferredTimescale: 90000)
            onWillStartTimebase?(startPTS)

            // Set timebase directly to player position (no offset yet).
            // The natural clock drift will be measured after ~2s and used
            // as clockOffset for all subsequent corrections.
            let corrected = CMTimeMakeWithSeconds(playerStreamTime, preferredTimescale: 90000)
            CMTimebaseSetTime(tb, time: corrected)
            CMTimebaseSetRate(tb, rate: Float64(_rate))
            #if DEBUG
            print("[HLSAudioEngine] Timebase started at \(String(format: "%.3f", playerStreamTime))s")
            #endif
            return
        }

        // Drift = audio position - video position.
        // Positive = audio ahead (video late), negative = video ahead (audio late).
        let drift = playerStreamTime - tbTime

        // Calibrate: after ~2s of playback, capture the natural drift as the
        // clock offset. This accounts for the inherent difference between
        // CMTimebase (host clock) and AVPlayer's internal clock, which varies
        // by device and OS version.
        if !hasCalibrated && hasSnapped && playerSeconds > 2.5 {
            hasCalibrated = true
            clockOffset = drift
            #if DEBUG
            print("[HLSAudioEngine] Clock offset calibrated: \(String(format: "%+.3f", clockOffset))s")
            #endif
            return
        }

        let realDrift = drift - clockOffset

        #if DEBUG
        syncLogCounter += 1
        if syncLogCounter % 20 == 0 {
            let status: String
            switch player.timeControlStatus {
            case .paused: status = "paused"
            case .playing: status = "playing"
            case .waitingToPlayAtSpecifiedRate: status = "waiting(\(player.reasonForWaitingToPlay?.rawValue ?? "?"))"
            @unknown default: status = "unknown"
            }
            let errInfo = playerItem?.errorLog()?.events.last.map { "lastErr=\($0.errorStatusCode)" } ?? "noErrors"
            print("[HLSAudioEngine] Status: playerTime=\(String(format: "%.1f", playerSeconds))s status=\(status) rate=\(player.rate) drift=\(String(format: "%+.3f", realDrift))s \(errInfo)")
        }
        #endif

        // Correct drift when it exceeds 50ms. The display layer handles
        // small time adjustments smoothly (holds or skips one frame).
        if abs(realDrift) > 0.05 {
            snapTimebaseToPlayer(playerStreamTime: playerStreamTime, tb: tb)
            #if DEBUG
            print("[HLSAudioEngine] Drift correction: \(String(format: "%+.3f", realDrift))s → snapped")
            #endif
        }
    }

    /// Snap the timebase to match the player's current position,
    /// accounting for the constant CMTimebase-to-AVPlayer clock offset.
    private func snapTimebaseToPlayer(playerStreamTime: Double, tb: CMTimebase) {
        let target = playerStreamTime - clockOffset
        let corrected = CMTimeMakeWithSeconds(target, preferredTimescale: 90000)
        CMTimebaseSetTime(tb, time: corrected)
    }
}

enum HLSAudioEngineError: Error {
    case noCodecParameters
}
