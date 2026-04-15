import Foundation
import AVFoundation
import CoreMedia

/// Audio engine using AVPlayer for EAC3 playback with Dolby Atmos passthrough.
///
/// AVPlayer wraps EAC3+JOC (Atmos) as Dolby MAT 2.0 automatically, enabling
/// object-based audio output to compatible receivers via HDMI.
///
/// ## Streaming Pattern
///
/// Uses AVAssetResourceLoader with a custom URL scheme. The key insight for
/// streaming: when `requestsAllDataToEndOfResource` is true, we must NOT call
/// `finishLoading()`. Instead, we keep the request open and feed data
/// incrementally via `respond(with:)` as new packets arrive from the demuxer.
///
/// ## Video Sync
///
/// Provides a `CMTimebase` that tracks AVPlayer's playback position.
/// Set as `displayLayer.controlTimebase` for A/V sync.
final class AVPlayerAudioEngine: NSObject, @unchecked Sendable {

    // MARK: - Properties

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var muxer: FMP4AudioMuxer?

    /// CMTimebase for video sync — tracks AVPlayer's current time.
    private(set) var videoTimebase: CMTimebase?

    private var _rate: Float = 1.0
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    /// Called when AVPlayer fails to open the audio stream.
    var onPlaybackFailed: (() -> Void)?

    // MARK: - Streaming Buffer

    /// All fMP4 data produced so far (init segment + media segments).
    /// Protected by `bufferLock`.
    private let bufferLock = NSLock()
    private var buffer = Data()
    private var bufferStartOffset = 0
    private var pendingRequests: [AVAssetResourceLoadingRequest] = []

    /// Queue for resource loader delegate callbacks.
    private let loaderQueue = DispatchQueue(label: "com.steelplayer.resourceloader")

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

        bufferLock.lock()
        buffer = Data()
        bufferStartOffset = 0
        buffer.append(initSegment)
        buffer.append(firstMedia)
        pendingRequests.removeAll()
        bufferLock.unlock()

        // Custom URL scheme → intercepted by our resource loader delegate
        let url = URL(string: "steelplayer-audio://stream.mp4")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: loaderQueue)

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
                    if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError {
                        print("[AVPlayerAudioEngine]   underlying: \(u.domain) code=\(u.code)")
                    }
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

        bufferLock.lock()
        buffer.append(segment)
        fulfillPendingRequests()
        trimBuffer()
        bufferLock.unlock()
    }

    /// Prepare for seek.
    func prepareForSeek() {
        player?.pause()
        removeTimeSync()
        statusObservation = nil

        bufferLock.lock()
        for req in pendingRequests where !req.isFinished && !req.isCancelled {
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

        let url = URL(string: "steelplayer-audio://stream.mp4")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: loaderQueue)

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

        bufferLock.lock()
        for req in pendingRequests where !req.isFinished && !req.isCancelled {
            req.finishLoading(with: URLError(.cancelled))
        }
        pendingRequests.removeAll()
        buffer = Data()
        bufferStartOffset = 0
        bufferLock.unlock()
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

    // MARK: - Streaming Buffer Management

    /// Feed available data to all pending resource loader requests.
    /// Called with bufferLock held.
    private func fulfillPendingRequests() {
        pendingRequests.removeAll { req in
            guard !req.isFinished, !req.isCancelled else { return true }

            guard let dataReq = req.dataRequest else {
                req.finishLoading()
                return true
            }

            let localOffset = Int(dataReq.currentOffset) - bufferStartOffset
            guard localOffset >= 0, localOffset < buffer.count else {
                return false  // No new data for this request yet
            }

            // Feed all available data from current position
            let respondData = buffer.subdata(in: localOffset..<buffer.count)
            dataReq.respond(with: respondData)

            // For streaming requests (requestsAllDataToEndOfResource):
            // keep the request open — more data will arrive.
            if dataReq.requestsAllDataToEndOfResource {
                return false
            }

            // For fixed-length requests: finish if fully satisfied
            let requestedEnd = Int(dataReq.requestedOffset) + dataReq.requestedLength
            if Int(dataReq.currentOffset) >= requestedEnd {
                req.finishLoading()
                return true
            }

            return false
        }
    }

    /// Trim consumed data. Called with bufferLock held.
    private func trimBuffer() {
        let minNeeded: Int
        if let minReq = pendingRequests
            .compactMap({ $0.dataRequest.map { Int($0.currentOffset) } })
            .min() {
            minNeeded = minReq
        } else {
            minNeeded = bufferStartOffset + max(0, buffer.count - 65536)
        }
        let safeToTrim = minNeeded - bufferStartOffset
        guard safeToTrim > 1024 * 1024 else { return }
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
        #if DEBUG
        if let dr = loadingRequest.dataRequest {
            print("[AVPlayerAudioEngine] ResourceLoader: offset=\(dr.requestedOffset) len=\(dr.requestedLength) allData=\(dr.requestsAllDataToEndOfResource) contentInfo=\(loadingRequest.contentInformationRequest != nil)")
        }
        #endif

        bufferLock.lock()
        defer { bufferLock.unlock() }

        // Fill content info on the first request
        if let contentInfo = loadingRequest.contentInformationRequest {
            contentInfo.contentType = "public.mpeg-4"
            contentInfo.isByteRangeAccessSupported = false
            // Don't set contentLength — streaming with unknown total size
        }

        guard let dataReq = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let localOffset = Int(dataReq.currentOffset) - bufferStartOffset
        if localOffset >= 0 && localOffset < buffer.count {
            // Respond with all available data
            let respondData = buffer.subdata(in: localOffset..<buffer.count)
            dataReq.respond(with: respondData)

            #if DEBUG
            print("[AVPlayerAudioEngine] Responded with \(respondData.count) bytes (buffer=\(buffer.count))")
            #endif
        }

        // For streaming (requestsAllDataToEndOfResource): keep request open.
        // For small fixed-length probes: check if satisfied.
        if !dataReq.requestsAllDataToEndOfResource {
            let requestedEnd = Int(dataReq.requestedOffset) + dataReq.requestedLength
            if Int(dataReq.currentOffset) >= requestedEnd {
                loadingRequest.finishLoading()
                return true
            }
        }

        // Keep request in pending queue — more data will arrive via feedPacket()
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
