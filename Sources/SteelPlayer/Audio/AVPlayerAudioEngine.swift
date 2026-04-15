import Foundation
import AVFoundation
import CoreMedia

/// Audio engine using AVPlayer for EAC3/AC3 playback with Dolby Atmos passthrough.
///
/// AVPlayer wraps EAC3+JOC (Atmos) as Dolby MAT 2.0 automatically, enabling
/// object-based audio output to compatible receivers via HDMI. This is the same
/// approach used by Infuse and other premium media players.
///
/// ## Architecture
///
/// ```
/// FFmpeg demuxer → raw EAC3/AC3 packets
///   → FMP4AudioMuxer (wraps in fMP4 segments)
///   → AVAssetResourceLoaderDelegate (serves to AVPlayer)
///   → AVPlayer (handles Dolby MAT 2.0 wrapping)
///   → HDMI → Receiver shows "Dolby Atmos"
/// ```
///
/// ## Video Sync
///
/// Provides a `CMTimebase` that tracks AVPlayer's playback position.
/// The host sets this as `AVSampleBufferDisplayLayer.controlTimebase`
/// so video frames are presented in sync with AVPlayer's audio output.
final class AVPlayerAudioEngine: NSObject, @unchecked Sendable {

    // MARK: - Properties

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var muxer: FMP4AudioMuxer?

    /// CMTimebase for video sync — tracks AVPlayer's current time.
    /// Set as `displayLayer.controlTimebase` for A/V sync.
    private(set) var videoTimebase: CMTimebase?

    private var _rate: Float = 1.0
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    // MARK: - Streaming Buffer

    /// All fMP4 data produced so far (init segment + media segments).
    /// Protected by `bufferLock`. Trimmed periodically to avoid unbounded growth.
    private let bufferLock = NSLock()
    private var buffer = Data()
    private var bufferStartOffset = 0
    private var pendingRequests: [AVAssetResourceLoadingRequest] = []
    private var isFirstPacket = true

    // MARK: - Init

    override init() {
        super.init()

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb
        )
        videoTimebase = tb
    }

    // MARK: - Public API

    /// Current playback time from AVPlayer.
    var currentTime: CMTime {
        player?.currentTime() ?? .zero
    }

    /// Current playback time in seconds.
    var currentTimeSeconds: Double {
        let t = CMTimeGetSeconds(currentTime)
        return t.isFinite ? t : 0
    }

    /// Playback volume.
    var volume: Float {
        get { player?.volume ?? 1.0 }
        set { player?.volume = newValue }
    }

    /// Start the audio engine with the first audio packet.
    /// Parses codec config from the packet, generates the fMP4 init segment,
    /// and creates the AVPlayer instance.
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
            print("[AVPlayerAudioEngine] Failed to parse codec config from first packet")
            #endif
            return
        }

        let muxer = FMP4AudioMuxer(config: config)
        let startSeconds = CMTimeGetSeconds(startTime)
        if startSeconds > 0 {
            muxer.reset(atTimeSeconds: startSeconds)
        }
        self.muxer = muxer

        // Generate init segment + first media segment
        let initSegment = muxer.createInitSegment()
        let firstMedia = muxer.createMediaSegment(frames: [firstPacketData])

        bufferLock.lock()
        buffer = Data()
        bufferStartOffset = 0
        buffer.append(initSegment)
        buffer.append(firstMedia)
        pendingRequests.removeAll()
        isFirstPacket = false
        bufferLock.unlock()

        // Create AVPlayer with custom URL scheme (intercepted by resource loader)
        let url = URL(string: "steelplayer-audio://stream.mp4")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: DispatchQueue(label: "com.steelplayer.resourceloader"))

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2.0

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.playerItem = item
        self.player = player

        // Observe player status for error handling
        statusObservation = item.observe(\.status) { item, _ in
            if item.status == .failed {
                #if DEBUG
                print("[AVPlayerAudioEngine] PlayerItem failed: \(item.error?.localizedDescription ?? "unknown")")
                #endif
            }
        }

        // Start timebase sync
        setupTimeSync()

        // Seek if starting mid-stream
        if startSeconds > 0 {
            player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        player.rate = _rate

        #if DEBUG
        let atmosStr = config.numDepSub > 0 ? " (Atmos: \(config.numDepSub) dep sub)" : ""
        print("[AVPlayerAudioEngine] Started: \(config.codecType == .ac3 ? "AC3" : "EAC3")\(atmosStr), \(config.sampleRate)Hz, \(config.channelCount)ch")
        #endif
    }

    /// Feed a subsequent audio packet (raw AC3/EAC3 frame data).
    func feedPacket(_ data: Data) {
        guard let muxer = muxer else { return }

        let segment = muxer.createMediaSegment(frames: [data])

        bufferLock.lock()
        buffer.append(segment)
        processPendingRequests()
        trimBuffer()
        bufferLock.unlock()
    }

    /// Prepare for seek — cancel in-flight data, stop current playback.
    func prepareForSeek() {
        player?.pause()
        removeTimeSync()
        statusObservation = nil

        bufferLock.lock()
        for req in pendingRequests where !req.isFinished {
            req.finishLoading(with: URLError(.cancelled))
        }
        pendingRequests.removeAll()
        bufferLock.unlock()

        player?.replaceCurrentItem(with: nil)
        playerItem = nil
    }

    /// Restart after seek with packets from the new position.
    func restartAfterSeek(firstPacketData: Data, atTime time: CMTime) {
        guard let config = muxer?.config else { return }

        let newMuxer = FMP4AudioMuxer(config: config)
        newMuxer.reset(atTimeSeconds: CMTimeGetSeconds(time))
        self.muxer = newMuxer

        let initSegment = newMuxer.createInitSegment()
        let firstMedia = newMuxer.createMediaSegment(frames: [firstPacketData])

        bufferLock.lock()
        buffer = Data()
        bufferStartOffset = 0
        buffer.append(initSegment)
        buffer.append(firstMedia)
        pendingRequests.removeAll()
        bufferLock.unlock()

        // New player item with fresh resource loader
        let url = URL(string: "steelplayer-audio://stream.mp4")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: DispatchQueue(label: "com.steelplayer.resourceloader"))

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2.0

        player?.replaceCurrentItem(with: item)
        playerItem = item

        statusObservation = item.observe(\.status) { item, _ in
            if item.status == .failed {
                #if DEBUG
                print("[AVPlayerAudioEngine] PlayerItem failed after seek: \(item.error?.localizedDescription ?? "unknown")")
                #endif
            }
        }

        setupTimeSync()
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        player?.rate = _rate
    }

    func pause() {
        player?.pause()
        if let tb = videoTimebase {
            CMTimebaseSetRate(tb, rate: 0)
        }
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
        if let tb = videoTimebase {
            CMTimebaseSetRate(tb, rate: Float64(rate))
        }
    }

    func stop() {
        removeTimeSync()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        muxer = nil

        bufferLock.lock()
        for req in pendingRequests where !req.isFinished {
            req.finishLoading(with: URLError(.cancelled))
        }
        pendingRequests.removeAll()
        buffer = Data()
        bufferStartOffset = 0
        bufferLock.unlock()
    }

    // MARK: - Video Timebase Sync

    /// Periodically sync the video timebase to AVPlayer's current time.
    /// Corrects drift > 30ms to keep video and audio in sync.
    private func setupTimeSync() {
        guard let player = player else { return }

        // Initial sync
        if let tb = videoTimebase {
            CMTimebaseSetTime(tb, time: player.currentTime())
            CMTimebaseSetRate(tb, rate: Float64(_rate))
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10),  // 100ms
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
        let playerTime = player.currentTime()
        let tbTime = CMTimebaseGetTime(tb)
        let drift = CMTimeGetSeconds(playerTime) - CMTimeGetSeconds(tbTime)
        if abs(drift) > 0.03 {  // Correct if > 30ms drift
            CMTimebaseSetTime(tb, time: playerTime)
        }
    }

    // MARK: - Buffer Management

    /// Attempt to fulfill pending resource loader requests. Called with bufferLock held.
    private func processPendingRequests() {
        pendingRequests.removeAll { req in
            guard !req.isFinished, !req.isCancelled else { return true }
            return respondToRequest(req)
        }
    }

    /// Try to respond to a loading request with available data.
    /// Returns true if the request is fully satisfied. Called with bufferLock held.
    private func respondToRequest(_ request: AVAssetResourceLoadingRequest) -> Bool {
        // Content information (first request)
        if let contentInfo = request.contentInformationRequest {
            contentInfo.contentType = "public.mpeg-4"
            contentInfo.isByteRangeAccessSupported = false
        }

        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }

        let currentOffset = Int(dataRequest.currentOffset)
        let requestedEnd = Int(dataRequest.requestedOffset) + dataRequest.requestedLength

        // Convert absolute offset to local buffer offset
        let localOffset = currentOffset - bufferStartOffset
        guard localOffset >= 0 else {
            // Data before buffer start was trimmed — can't serve
            request.finishLoading(with: URLError(.resourceUnavailable))
            return true
        }

        guard localOffset < buffer.count else {
            return false  // Data not yet available
        }

        let localEnd = min(requestedEnd - bufferStartOffset, buffer.count)
        let respondData = buffer.subdata(in: localOffset..<localEnd)
        dataRequest.respond(with: respondData)

        if currentOffset + respondData.count >= requestedEnd {
            request.finishLoading()
            return true
        }

        return false
    }

    /// Trim consumed data from the buffer. Called with bufferLock held.
    private func trimBuffer() {
        // Find the minimum offset any pending request still needs
        let minNeeded: Int
        if let minReq = pendingRequests
            .compactMap({ $0.dataRequest.map { Int($0.currentOffset) } })
            .min() {
            minNeeded = minReq
        } else {
            // No pending requests — keep last 64KB for potential re-reads
            minNeeded = bufferStartOffset + max(0, buffer.count - 65536)
        }

        let safeToTrim = minNeeded - bufferStartOffset
        guard safeToTrim > 1024 * 1024 else { return }  // Only trim when > 1MB of old data

        buffer = buffer.subdata(in: safeToTrim..<buffer.count)
        bufferStartOffset += safeToTrim
    }
}

// MARK: - AVAssetResourceLoaderDelegate

extension AVPlayerAudioEngine: AVAssetResourceLoaderDelegate {

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        if respondToRequest(loadingRequest) {
            return true
        }

        // Not enough data yet — queue for later fulfillment
        pendingRequests.append(loadingRequest)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        bufferLock.lock()
        pendingRequests.removeAll { $0 === loadingRequest }
        bufferLock.unlock()
    }
}
