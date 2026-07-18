import Foundation
import AVFoundation
import CoreMedia
import Combine
import Libavformat
import Libavcodec
import Libavutil

/// Software-decode playback host (FFmpeg/dav1d pipeline): AV1 on Apple TV (no HW AV1 on tvOS), VP9.
/// AVSampleBufferRenderSynchronizer is the master clock; display layer attached for A/V sync.
/// Intentionally skips EAC3+JOC and DV HDMI handshake (AV1 sources rarely carry Atmos or DV).
@MainActor
final class SoftwarePlaybackHost {

    // MARK: - Published state (mirrors NativeAVPlayerHost surface)

    /// Frames enqueued on the display layer; read by LiveTelemetrySampler at 1 Hz for observed FPS. Lock-guarded (demux thread writes, main-actor reads).
    nonisolated var framesEnqueued: Int {
        framesEnqueuedLock.lock()
        defer { framesEnqueuedLock.unlock() }
        return _framesEnqueued
    }
    nonisolated private func bumpFramesEnqueued() -> Int {
        framesEnqueuedLock.lock()
        defer { framesEnqueuedLock.unlock() }
        let previous = _framesEnqueued
        _framesEnqueued &+= 1
        return previous
    }
    private let framesEnqueuedLock = NSLock()
    nonisolated(unsafe) private var _framesEnqueued: Int = 0

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    /// Raw synchronizer clock in the SOURCE axis (same axis as demuxed packet PTS and
    /// subtitle cues). Equals `currentTime` for zero-based sources; diverges by the
    /// session-zero offset on live and mid-stream-joined sources (#107). The engine
    /// publishes this as `clock.sourceTime` so the subtitle overlay drainer scans the
    /// packet store on the right axis.
    @Published private(set) var sourceClockSeconds: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    @Published private(set) var failureMessage: String?
    @Published private(set) var didReachEnd: Bool = false

    /// Fires (off-main) once per session the first time HDR10+ dynamic
    /// metadata appears on a decoded frame. Hooked by `AetherEngine` to
    /// upgrade the published `videoFormat` from `.hdr10` → `.hdr10Plus`.
    nonisolated(unsafe) var onFirstHDR10PlusDetected: (@Sendable () -> Void)?

    /// #131: forwarded from the video decoder; decoded-frame A53 cc_data triplets, presentation order.
    nonisolated(unsafe) var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?

    // MARK: - Output

    /// The display layer the engine attaches to the bound `AetherPlayerView`.
    /// Owned by `SampleBufferRenderer`; surfaced here so the engine can
    /// hand it to the view via the same `attach(_ layer: CALayer)` entry
    /// point it uses for `AVPlayerLayer`.
    var displayLayer: AVSampleBufferDisplayLayer { renderer.displayLayer }

    // MARK: - Internals

    private let renderer: SampleBufferRenderer
    /// Swapped per codec at load(): SoftwareVideoDecoder for AV1/VP9, HardwareVideoDecoder for HEVC. Protocol keeps the demux loop codec-agnostic.
    private var videoDecoder: any VideoDecodingPipeline
    private var audioDecoder: AudioDecoder?
    private var audioOutput: AudioOutput?
    private var demuxer: Demuxer?

    private let demuxQueue = DispatchQueue(label: "engine.sw.demux", qos: .userInitiated)

    /// Guards isPlaying/stopRequested across demux thread reads and main-actor writes.
    private let flagsLock = NSLock()
    nonisolated(unsafe) private var _isPlaying: Bool = false
    nonisolated(unsafe) private var _stopRequested: Bool = false

    /// Condition the demux thread waits on while paused so it doesn't
    /// busy-loop reading packets that would just stack up.
    private let demuxCondition = NSCondition()

    private var videoStreamIndex: Int32 = -1
    private var audioStreamIndex: Int32 = -1

    private var videoTimeBaseSeconds: Double = 0
    private var audioTimeBaseSeconds: Double = 0

    // MARK: - Live / DVR

    /// Disk-spooled DVR rewind ring; non-nil for live sessions with dvrWindowSeconds set. Demux-thread appended (internally locked).
    nonisolated(unsafe) private var dvrRing: PacketRingBuffer?

    /// True for a live session. Gates ring fill, edge publishing, and the
    /// live-DVR seek branch so the non-live SW path is untouched.
    private var isLive: Bool = false

    /// First packet's PTS (seconds); SW timeline is "seconds since first frame" = newestPts - sessionStartPts. nan until first packet.
    nonisolated(unsafe) private var sessionStartPts: Double = .nan

    nonisolated(unsafe) private var newestSourcePts: Double = .nan

    /// Guards `sessionStartPts` / `newestSourcePts` against the demux
    /// thread writing while the main-actor time tick reads them.
    private let liveEdgeLock = NSLock()

    /// SW path's buffered frontier (AetherEngine#54): newest demuxed source PTS in session time. Published as clock.bufferedPosition.
    nonisolated var bufferedSessionTime: Double {
        liveEdgeLock.lock()
        defer { liveEdgeLock.unlock() }
        guard sessionStartPts.isFinite, newestSourcePts.isFinite else { return 0 }
        return max(0, newestSourcePts - sessionStartPts)
    }

    // MARK: - Live reader/feeder split (DVR sessions)
    //
    // DVR live sessions: reader (demuxQueue) fills ring regardless of play/pause; feeder (feedQueue) decodes from ring cursor with renderer back-pressure.
    // Pause = timeshift (reader keeps filling); DVR rewind = cursor move. Replaces synchronous whole-tail replay (multi-second UI freeze, queue overflow).
    // Live-only (no ring): combined loop; pause parks the loop.

    /// Background queue for the live feeder loop.
    private let feedQueue = DispatchQueue(label: "engine.sw.feed", qos: .userInitiated)

    /// Guards `_feedCursor` / `_sourceEnded`.
    private let feedLock = NSLock()
    nonisolated(unsafe) private var _feedCursor: Int = 0
    nonisolated(unsafe) private var _sourceEnded = false

    /// Audio look-ahead pump cursor (#107 audio chopping): the feeder advances it ahead of
    /// `_feedCursor`, seek paths reset it alongside `setFeedCursor`.
    private let audioLookahead = AudioLookaheadState()

    nonisolated private func readFeedCursor() -> Int {
        feedLock.lock(); defer { feedLock.unlock() }
        return _feedCursor
    }

    /// Compare-and-advance: only advance when the cursor is still at
    /// `old`, so a concurrent DVR seek (which repositions the cursor)
    /// is never overwritten by the feeder's post-decode increment.
    nonisolated private func advanceFeedCursor(from old: Int) {
        feedLock.lock()
        if _feedCursor == old { _feedCursor = old + 1 }
        feedLock.unlock()
    }

    nonisolated private func setFeedCursor(_ value: Int) {
        feedLock.lock()
        _feedCursor = value
        feedLock.unlock()
        audioLookahead.reset(to: value)
        demuxCondition.lock()
        demuxCondition.broadcast()
        demuxCondition.unlock()
    }

    nonisolated private func clampFeedCursor(from old: Int, to first: Int) {
        feedLock.lock()
        if _feedCursor == old { _feedCursor = first }
        feedLock.unlock()
    }

    nonisolated private var sourceEnded: Bool {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _sourceEnded }
        set { feedLock.lock(); _sourceEnded = newValue; feedLock.unlock() }
    }

    nonisolated private func resetFeederState() {
        feedLock.lock()
        _feedCursor = 0
        _sourceEnded = false
        _clockArmed = false
        _clockSessionZero = 0
        feedLock.unlock()
        audioLookahead.reset(to: 0)
    }

    /// Whether the synchronizer clock has been anchored this session. Shared with seek paths so a DVR seek before feeder arming is not overwritten by a late re-arm.
    nonisolated(unsafe) private var _clockArmed = false
    nonisolated private var clockArmed: Bool {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _clockArmed }
        set { feedLock.lock(); _clockArmed = newValue; feedLock.unlock() }
    }

    /// Session-zero offset for non-live sources whose first decoded sample deviated from
    /// the load anchor (mid-stream-joined TS, #107): raw clock minus this is the published
    /// position. 0 for zero-based sources and aligned resumes. Written once by the demux
    /// thread at clock arming, read by the main-actor time tick.
    nonisolated(unsafe) private var _clockSessionZero: Double = 0
    nonisolated private var clockSessionZero: Double {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _clockSessionZero }
        set { feedLock.lock(); _clockSessionZero = newValue; feedLock.unlock() }
    }

    /// Bumped at every seek; demux loop re-checks around blocking readPacket to discard stale pre-seek packets that would clear the skip threshold (visible fast-forward burst).
    nonisolated(unsafe) private var _seekGeneration: UInt64 = 0
    nonisolated private var seekGeneration: UInt64 {
        feedLock.lock(); defer { feedLock.unlock() }; return _seekGeneration
    }
    nonisolated private func bumpSeekGeneration() {
        feedLock.lock(); _seekGeneration &+= 1; feedLock.unlock()
    }

    /// Set when pause() stopped the synchronizer; play() restores the rate (previously play() only flipped isPlaying, leaving the clock frozen).
    private var pausedByHost = false

    /// Invoked on the main-actor time-update cadence with the current
    /// session-relative live edge (seconds since first frame) while live.
    /// Wired by the engine to `publishLiveWindow(edgeSessionTime:)`.
    var onLiveEdge: (@MainActor (Double) -> Void)?

    /// Session-relative live edge in seconds, or nil before the first
    /// packet. Read on the main actor by the time tick.
    private var liveEdgeSessionTime: Double? {
        liveEdgeLock.lock()
        defer { liveEdgeLock.unlock() }
        guard sessionStartPts.isFinite, newestSourcePts.isFinite else { return nil }
        return max(0, newestSourcePts - sessionStartPts)
    }

    private var timeTimer: AnyCancellable?

    /// Caching the chosen rate so resume() restores the right speed after a pause without the
    /// host needing to know its history. Lock-guarded: the demux/feeder threads read it at clock
    /// arming so a host rate change between load and arm is not lost (#107).
    nonisolated(unsafe) private var _lastRate: Float = 1.0
    nonisolated private var lastRate: Float {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _lastRate }
        set { flagsLock.lock(); _lastRate = newValue; flagsLock.unlock() }
    }

    /// Start position captured so the demux loop aligns the synchronizer clock to the first sample's PTS; non-zero resume without this would cause "frozen frame, no audio".
    private var initialClockTime: CMTime = .zero

    nonisolated var isPlaying: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _isPlaying }
        set {
            flagsLock.lock(); _isPlaying = newValue; flagsLock.unlock()
            demuxCondition.lock()
            demuxCondition.broadcast()
            demuxCondition.unlock()
        }
    }

    nonisolated var stopRequested: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _stopRequested }
        set {
            flagsLock.lock(); _stopRequested = newValue; flagsLock.unlock()
            demuxCondition.lock()
            demuxCondition.broadcast()
            demuxCondition.unlock()
        }
    }

    /// Set by the engine on background-enter (iOS keepalive) and cleared on foreground. While true the
    /// combined demux loop drops video packets and paces on the audio renderer, so audio keeps playing in
    /// the background. The setter broadcasts the demux condition so a parked loop re-evaluates immediately.
    nonisolated(unsafe) private var _backgroundAudioOnly = false
    nonisolated var backgroundAudioOnly: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _backgroundAudioOnly }
        set {
            flagsLock.lock(); _backgroundAudioOnly = newValue; flagsLock.unlock()
            demuxCondition.lock()
            demuxCondition.broadcast()
            demuxCondition.unlock()
        }
    }

    // MARK: - Init

    init() {
        self.renderer = SampleBufferRenderer()
        // Default to the software decoder; load() swaps it for the
        // VT-backed one when the source's video codec is HEVC.
        self.videoDecoder = SoftwareVideoDecoder()
    }

    // MARK: - Load

    func load(
        demuxer dem: Demuxer,
        startPosition: Double?,
        audioSourceStreamIndex: Int32?,
        isLive: Bool = false,
        dvrWindowSeconds: Double? = nil
    ) async throws {
        self.demuxer = dem
        self.duration = dem.duration
        self.isLive = isLive

        guard dem.videoStreamIndex >= 0,
              let vStream = dem.stream(at: dem.videoStreamIndex) else {
            throw HostError.noVideoStream
        }
        self.videoStreamIndex = dem.videoStreamIndex
        let vtb = vStream.pointee.time_base
        self.videoTimeBaseSeconds = vtb.den > 0 ? Double(vtb.num) / Double(vtb.den) : 0

        // DVR ring scratch dir mirrors SegmentCache's <tmpdir>/aether-segments/<uuid> convention.
        if isLive, let window = dvrWindowSeconds {
            let baseDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("aether-segments", isDirectory: true)
            let scratch = baseDir.appendingPathComponent("dvr-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                self.dvrRing = try PacketRingBuffer(windowSeconds: window, scratch: scratch)
                EngineLog.emit("[SWHost] DVR ring armed window=\(String(format: "%.0f", window))s scratch=\(scratch.lastPathComponent)", category: .swPlayback)
            } catch {
                EngineLog.emit("[SWHost] DVR ring create failed (\(error)); live-only fallback", category: .swPlayback)
                self.dvrRing = nil
            }
        }

        // Release-visible session-start log: SW-path black-screens were indistinguishable from "never dispatched" (DrHurt #4).
        let vCodecID = vStream.pointee.codecpar?.pointee.codec_id.rawValue ?? 0
        let aIdx = audioSourceStreamIndex ?? dem.audioStreamIndex
        let aCodecID: UInt32 = aIdx >= 0
            ? (dem.stream(at: aIdx)?.pointee.codecpar?.pointee.codec_id.rawValue ?? 0)
            : 0
        EngineLog.emit(
            "[SWHost] session start: videoCodecID=\(vCodecID) "
            + "audioCodecID=\(aCodecID == 0 ? "none" : String(aCodecID)) "
            + "duration=\(String(format: "%.1f", dem.duration))s",
            category: .swPlayback
        )

        // HEVC -> VTDecompressionSession (HW) when VideoToolbox can HW-decode this exact format; everything
        // else -> libavcodec. Replace wholesale to prevent state bleed. #2: HardwareVideoDecoder requires a
        // HW decoder and has no software fallback, so an HEVC Rext (4:2:2/4:4:4/12-bit) stream routed here on
        // hardware without a HW decoder (Intel Macs / older Apple TV) would fail VT session creation and show a
        // black screen. Route those to libavcodec instead, which decodes them. Apple Silicon HW-decodes them,
        // so the probe keeps HardwareVideoDecoder there.
        if let codecpar = vStream.pointee.codecpar,
           codecpar.pointee.codec_id == AV_CODEC_ID_HEVC,
           VTCapabilityProbe.canHardwareDecode(codecpar: codecpar) {
            videoDecoder.close()
            videoDecoder = HardwareVideoDecoder()
            EngineLog.emit(
                "[SWHost] selected HardwareVideoDecoder (VT HEVC) for codec_id=\(codecpar.pointee.codec_id.rawValue)",
                category: .swPlayback
            )
        } else if !(videoDecoder is SoftwareVideoDecoder) {
            videoDecoder.close()
            videoDecoder = SoftwareVideoDecoder()
            EngineLog.emit(
                "[SWHost] selected SoftwareVideoDecoder (libavcodec) for codec_id="
                + "\(vStream.pointee.codecpar?.pointee.codec_id.rawValue ?? 0)",
                category: .swPlayback
            )
        }

        // Flip display layer into HDR mode before frames arrive; without this preferredDynamicRange stays .standard and PQ/HLG renders desaturated.
        if let codecpar = vStream.pointee.codecpar {
            let trc = codecpar.pointee.color_trc
            let sourceIsHDR = trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67
            if sourceIsHDR {
                renderer.setHDROutput(true)
                EngineLog.emit(
                    "[SWHost] HDR mode ON on display layer (transfer=\(trc.rawValue))",
                    category: .swPlayback
                )
            }
        }

        // Applied here (not init) so it also covers a decoder replaced above.
        (videoDecoder as? SoftwareVideoDecoder)?.deinterlaceConfig = deinterlaceConfig

        try videoDecoder.open(stream: vStream) { [weak self] pixelBuffer, pts, hdr10PlusData in
            // Decoder callback is off-main; SampleBufferRenderer is internally locked.
            self?.renderer.enqueue(pixelBuffer: pixelBuffer, pts: pts, hdr10PlusData: hdr10PlusData)
            // First-frame milestone: demux reached a video packet + decoder produced a pixel buffer.
            if self?.bumpFramesEnqueued() == 0 {
                let pfType = CVPixelBufferGetPixelFormatType(pixelBuffer)
                EngineLog.emit(
                    "[SWHost] first video frame enqueued: "
                    + "pixfmt=0x\(String(pfType, radix: 16)) "
                    + "size=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) "
                    + "pts=\(String(format: "%.3f", pts.seconds))s",
                    category: .swPlayback
                )
            }
        }
        videoDecoder.onFirstHDR10PlusDetected = { [weak self] in
            self?.onFirstHDR10PlusDetected?()
        }
        videoDecoder.onA53Captions = { [weak self] triplets, pts in
            self?.onA53Captions?(triplets, pts)
        }

        let resolvedAudioIdx: Int32 = audioSourceStreamIndex ?? dem.audioStreamIndex
        if resolvedAudioIdx >= 0, let aStream = dem.stream(at: resolvedAudioIdx) {
            let aDec = AudioDecoder()
            do {
                try aDec.open(stream: aStream)
                self.audioDecoder = aDec
                self.audioStreamIndex = resolvedAudioIdx
                let atb = aStream.pointee.time_base
                self.audioTimeBaseSeconds = atb.den > 0 ? Double(atb.num) / Double(atb.den) : 0
            } catch {
                EngineLog.emit("[SWHost] audio open failed (\(error)); video-only", category: .swPlayback)
                self.audioStreamIndex = -1
            }
        }
        // #112 rework: capture embedded subtitle stream indices + time bases for the demux
        // loop's subtitle tap dispatch.
        var subIndices: Set<Int32> = []
        var subTimeBases: [Int32: AVRational] = [:]
        for info in dem.subtitleTrackInfos() {
            let idx = Int32(info.id)
            subIndices.insert(idx)
            subTimeBases[idx] = dem.stream(at: idx)?.pointee.time_base ?? AVRational(num: 1, den: 1000)
        }
        self.subtitleStreamIndices = subIndices
        self.subtitleStreamTimeBases = subTimeBases
        // #112: split-PES PGS streams (MPEG-TS) need display-set reassembly in the packet
        // store; the tap sink consults this per packet.
        self.splitDisplaySetSubtitleStreamIndices = dem.splitDisplaySetSubtitleStreamIndices()

        // AudioOutput owns the AVSampleBufferRenderSynchronizer (master clock). Created unconditionally: video-only previously got no clock (frozen frame, currentTime=0). Layer attached in play() after the engine hangs it in the view hierarchy (attaching free-floating fails FigVideoQueueRemote -12080 on tvOS 26+).
        self.audioOutput = AudioOutput()

        // Reset the live feeder state for the new session.
        resetFeederState()

        if let start = startPosition, start > 0 {
            dem.seek(to: start)
            // Mirror seek() skip-PTS + clock alignment so demux drops pre-keyframe frames and synchronizer starts at the resume offset.
            let startTime = CMTime(seconds: start, preferredTimescale: 90000)
            videoDecoder.skipUntilPTS = startTime
            renderer.setSkipThreshold(startTime)
            initialClockTime = startTime
            currentTime = start
        } else {
            initialClockTime = .zero
        }

        startTimeUpdates()
        isReady = true
    }

    // MARK: - Transport

    func play() {
        // Resume after pause(): gate on clockArmed, not demuxLoopStarted. A rate change on the
        // un-anchored synchronizer (no media at its clock time yet) wedges the delayed-rate-change
        // machinery permanently frozen; the arming seekClock applies the current lastRate (#107).
        if pausedByHost {
            pausedByHost = false
            if clockArmed {
                audioOutput?.setRate(lastRate)
            }
        }
        if !demuxLoopStarted, let aOut = audioOutput {
            aOut.attachVideoLayer(renderer.displayLayer)
        }
        if !demuxLoopStarted {
            demuxLoopStarted = true
            startDemuxLoop()
        }
        // Cold start: demux loop arms the clock on first decoded audio sample; don't eager-start.
        rate = lastRate
        isPlaying = true
    }

    private var demuxLoopStarted: Bool = false

    /// #95 audio tap: mirrors every decoded audio CMSampleBuffer to the tap (nil = tap off).
    /// Set/cleared on the main actor by AetherEngine+AudioTap; read per packet on the demux and
    /// feeder threads (same unsynchronized-flag pattern as `_isPlaying`; worst case one buffer
    /// reaches a just-removed sink).
    nonisolated(unsafe) var audioTapSink: (@Sendable (CMSampleBuffer) -> Void)?

    /// #112 rework subtitle tap: the demux loop hands every embedded subtitle packet to this
    /// sink (nil = tap off), which copies the payload into the session's SubtitlePacketStore.
    /// Same unsynchronized-flag pattern as `audioTapSink`; the sink copies synchronously, so
    /// the packet pointer never escapes the demux thread. The trailing Bool marks packets of
    /// split-PES PGS streams (MPEG-TS) that need display-set reassembly in the store.
    nonisolated(unsafe) var subtitleTapSink: (@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational, Bool) -> Void)?

    /// #112 rework: embedded subtitle stream indices + time bases, captured at load before the
    /// demux loop starts (the SW host applies no stream discard, so these packets already flow).
    private(set) var subtitleStreamIndices: Set<Int32> = []
    private(set) var subtitleStreamTimeBases: [Int32: AVRational] = [:]
    /// #112: streams whose PGS display sets arrive split across PES packets (MPEG-TS) and need
    /// reassembly in the packet store. Captured at load, read by the tap sink per packet.
    private(set) var splitDisplaySetSubtitleStreamIndices: Set<Int32> = []

    /// Host's ASS markup preference for overlay decoders (mirrors the HLS session flag).
    var preserveASSMarkupForSubtitleTap = false
    var teletextPageForSubtitleTap: Int? = nil
    var deinterlaceConfig = DeinterlaceConfig()

    /// #112 rework: build an overlay decoder for any embedded subtitle stream, seeded from the
    /// session's video dims like the HLS tap routes. The drainer owns the returned decoder.
    func makeOverlayDecoder(streamIndex: Int32) -> EmbeddedSubtitleDecoder? {
        guard let dem = demuxer, let stream = dem.stream(at: streamIndex) else { return nil }
        let vpar = dem.stream(at: videoStreamIndex)?.pointee.codecpar
        let w = vpar?.pointee.width ?? 1920
        let h = vpar?.pointee.height ?? 1080
        return EmbeddedSubtitleDecoder(stream: stream,
                                       sourceVideoWidth: w > 0 ? w : 1920,
                                       sourceVideoHeight: h > 0 ? h : 1080,
                                       preserveASSMarkup: preserveASSMarkupForSubtitleTap,
                                       teletextPage: teletextPageForSubtitleTap)
    }

    func pause() {
        // Un-anchored clock: only latch the pause; the loops park on isPlaying (#107).
        if clockArmed {
            audioOutput?.pause()
        }
        pausedByHost = true
        rate = 0
        isPlaying = false
    }

    /// Background-enter (iOS keepalive): keep audio flowing, stop feeding video. The demux loop reads the flag.
    func enterBackgroundAudioOnly() {
        backgroundAudioOnly = true
    }

    /// Foreground return: resume video. Flush the video decoder + renderer (NOT audio) so video resyncs at the
    /// next keyframe; the synchronizer is already at the audio time, so the keyframe presents promptly. Order
    /// matters: while backgroundAudioOnly is still true the loop drops video and never touches videoDecoder /
    /// renderer, so flushing here from the main actor cannot race the demux queue. Clear the flag last.
    func exitBackgroundAudioOnly() {
        guard backgroundAudioOnly else { return }
        videoDecoder.flush()
        renderer.flush()
        backgroundAudioOnly = false
    }

    func setRate(_ newRate: Float) {
        lastRate = newRate
        rate = newRate
        // Same rule as play(): never rate-change the un-anchored synchronizer. A host setRate
        // right after load(), before the demux/feeder loop armed the clock, wedged the
        // delayed-rate-change machinery and froze live sessions on the first frame; the arming
        // seekClock picks up lastRate instead (#107).
        if clockArmed {
            audioOutput?.setRate(newRate)
        }
    }

    func seek(to seconds: Double) async {
        guard let dem = demuxer else { return }
        // Stop loop + bump generation to invalidate in-flight packets.
        bumpSeekGeneration()
        let wasPlaying = isPlaying
        isPlaying = false

        videoDecoder.flush()
        audioDecoder?.flush()
        // Hold the last frame through the seek (don't blank the display) so the viewer sees the previous
        // frame until the post-seek frame decodes, instead of a black flash (issue #90). Stop/teardown and
        // background-return still clear via the default.
        renderer.flush(removingDisplayedImage: false)
        audioOutput?.flush()

        // Live source is forward-only; DVR rewind reseeds decoders from the ring without touching the live demuxer's read position.
        if isLive, let ring = dvrRing {
            await seekLiveDVR(to: seconds, ring: ring, wasPlaying: wasPlaying)
            return
        }

        dem.seek(to: seconds)

        let targetTime = CMTime(seconds: seconds, preferredTimescale: 90000)
        videoDecoder.skipUntilPTS = targetTime
        renderer.setSkipThreshold(targetTime)

        currentTime = seconds

        if wasPlaying {
            // Anchor clock at seek target: clock at .zero + PTS=seekTarget would stall rendering for seekTarget seconds (FigVideoQueueRemote -12080).
            audioOutput?.seekClock(to: targetTime, rate: lastRate)
            isPlaying = true
        } else {
            // Paused seek: anchor at target with rate 0 so play() resumes from the seek position (without this, scrubs freeze or drop all samples).
            audioOutput?.seekClock(to: targetTime, rate: 0)
            pausedByHost = true
        }
        // Arm now so the demux loop doesn't re-arm at stale initialClockTime (a pre-first-audio seek snapped back to session start without this).
        clockArmed = true
    }

    /// Live DVR rewind: reseeds decoder from the ring (source PTS axis; maps via sessionStartPts) without touching the live demuxer. After return, the loop reads new packets forward and plays back to live.
    private func seekLiveDVR(to targetSession: Double, ring: PacketRingBuffer, wasPlaying: Bool) async {
        let startPts: Double = {
            liveEdgeLock.lock(); defer { liveEdgeLock.unlock() }
            return sessionStartPts.isFinite ? sessionStartPts : 0
        }()
        let targetSource = startPts + targetSession

        let targetTime = CMTime(seconds: targetSource, preferredTimescale: 90000)
        videoDecoder.skipUntilPTS = targetTime
        renderer.setSkipThreshold(targetTime)

        // Anchor clock at target (paused scrubs: rate 0 so resume continues from seek position).
        if wasPlaying {
            audioOutput?.seekClock(to: targetTime, rate: lastRate)
        } else {
            audioOutput?.seekClock(to: targetTime, rate: 0)
            pausedByHost = true
        }
        clockArmed = true

        // Reposition cursor to the newest keyframe at or before target. If the target precedes every
        // retained keyframe, fall to the EARLIEST keyframe, not seqBounds.first, which can be a mid-GOP
        // leading entry before the ring's first eviction and would decode as garbage until the next keyframe.
        let seq = ring.seq(forKeyframeAtOrBefore: targetSource)
            ?? ring.firstKeyframeSeq()
            ?? ring.seqBounds.first
        setFeedCursor(seq)
        EngineLog.emit(
            "[SWHost] DVR rewind: targetSession=\(String(format: "%.2f", targetSession)) "
            + "targetSource=\(String(format: "%.2f", targetSource)) -> cursor seq=\(seq)",
            category: .swPlayback
        )

        currentTime = targetSession
        if wasPlaying {
            isPlaying = true
        }
    }

    /// Reconstruct AVPacket from ring entry, convert PTS from seconds back to stream time_base, and route to decoders. Returns true when audio buffers were enqueued (used for feeder clock arming).
    @discardableResult
    nonisolated private static func feedRingPacket(
        _ pkt: PacketRingBuffer.Packet,
        videoDecoder: any VideoDecodingPipeline,
        audioDecoder: AudioDecoder?,
        audioOutput: AudioOutput?,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        audioTapSink: (@Sendable (CMSampleBuffer) -> Void)?
    ) -> Bool {
        let tbSec = pkt.isVideo ? videoTimeBaseSeconds : audioTimeBaseSeconds
        guard tbSec > 0, !pkt.bytes.isEmpty else { return false }

        guard let p = trackedPacketAlloc() else { return false }
        var avPkt: UnsafeMutablePointer<AVPacket>? = p
        defer { trackedPacketFree(&avPkt) }

        if av_new_packet(p, Int32(pkt.bytes.count)) < 0 { return false }
        pkt.bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let dst = p.pointee.data {
                memcpy(dst, base, pkt.bytes.count)
            }
        }
        p.pointee.pts = Int64((pkt.pts / tbSec).rounded())
        p.pointee.dts = p.pointee.pts
        p.pointee.flags = pkt.isKeyframe ? AV_PKT_FLAG_KEY : 0
        p.pointee.stream_index = pkt.isVideo ? videoStreamIndex : audioStreamIndex

        if pkt.isVideo {
            videoDecoder.decode(packet: p)
            return false
        } else if let aDec = audioDecoder, let aOut = audioOutput {
            var enqueued = false
            for buf in aDec.decode(packet: p) {
                audioTapSink?(buf)   // #95: mirror before enqueue
                aOut.enqueue(sampleBuffer: buf)
                enqueued = true
            }
            return enqueued
        }
        return false
    }

    func stop() {
        stopRequested = true
        isPlaying = false
        timeTimer?.cancel()
        timeTimer = nil

        dvrRing?.close()
        dvrRing = nil
        liveEdgeLock.lock()
        sessionStartPts = .nan
        newestSourcePts = .nan
        liveEdgeLock.unlock()

        if let aOut = audioOutput {
            aOut.stop()
            aOut.detachVideoLayer(renderer.displayLayer)
        }
        audioOutput = nil
        audioDecoder?.close()
        audioDecoder = nil
        videoDecoder.close()
        renderer.flush()
        demuxer?.close()
        demuxer = nil

        isReady = false
    }

    var volume: Float {
        get { audioOutput?.volume ?? 1.0 }
        set { audioOutput?.volume = newValue }
    }

    // MARK: - Demux loop

    /// Capture dependencies as locals so the demux loop runs off-main without re-entering the actor.
    private func startDemuxLoop() {
        guard let dem = demuxer else { return }
        let vDec = videoDecoder
        let vIdx = videoStreamIndex
        let aDec = audioDecoder
        let aOut = audioOutput
        let aIdx = audioStreamIndex
        let rndr = renderer
        let condition = demuxCondition
        let initialClock = initialClockTime
        // Read at arm time, not captured: a host setRate between load and arming must reach
        // the anchor (the eager synchronizer call it replaced is gated on clockArmed, #107).
        let currentRate: @Sendable () -> Float = { [weak self] in self?.lastRate ?? 1.0 }
        let ring = dvrRing
        let vTbSec = videoTimeBaseSeconds
        let aTbSec = audioTimeBaseSeconds
        let liveSession = isLive
        let noteEdge: @Sendable (Double) -> Void = { [weak self] ptsSec in
            guard let self, ptsSec.isFinite else { return }
            self.liveEdgeLock.lock()
            if self.sessionStartPts.isNaN { self.sessionStartPts = ptsSec }
            if self.newestSourcePts.isNaN || ptsSec > self.newestSourcePts {
                self.newestSourcePts = ptsSec
            }
            self.liveEdgeLock.unlock()
        }
        let getIsPlaying: @Sendable () -> Bool = { [weak self] in self?.isPlaying ?? false }
        let getStopRequested: @Sendable () -> Bool = { [weak self] in self?.stopRequested ?? true }
        // #95: resolved per packet so a tap installed mid-session is picked up by running loops.
        let getAudioTapSink: @Sendable () -> ((@Sendable (CMSampleBuffer) -> Void)?) = { [weak self] in
            self?.audioTapSink
        }
        // #112 rework: same late-install resolution for the subtitle tap.
        let getSubtitleTapSink: @Sendable () -> ((@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational, Bool) -> Void)?) = { [weak self] in
            self?.subtitleTapSink
        }
        let subIndices = subtitleStreamIndices
        let subTimeBases = subtitleStreamTimeBases
        let subSplitSetIndices = splitDisplaySetSubtitleStreamIndices
        let onError: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor [weak self] in self?.failureMessage = msg }
        }
        let onEnd: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.didReachEnd = true
                self?.isPlaying = false
            }
        }

        // Live + DVR ring: reader/feeder split; live-only and VOD use the combined loop below.
        let getClockArmed: @Sendable () -> Bool = { [weak self] in
            self?.clockArmed ?? true
        }
        let setClockArmed: @Sendable () -> Void = { [weak self] in
            self?.clockArmed = true
        }
        let getSeekGeneration: @Sendable () -> UInt64 = { [weak self] in
            self?.seekGeneration ?? 0
        }
        let getBackgroundAudioOnly: @Sendable () -> Bool = { [weak self] in
            self?.backgroundAudioOnly ?? false
        }
        // #107: the demux loop reports the resolved session-zero offset when it re-anchors
        // the clock at a deviating first-sample PTS (mid-stream-joined source).
        let onClockAnchored: @Sendable (Double) -> Void = { [weak self] zero in
            self?.clockSessionZero = zero
        }

        if liveSession, let ring {
            let readCursor: @Sendable () -> Int = { [weak self] in
                self?.readFeedCursor() ?? 0
            }
            let advanceCursor: @Sendable (Int) -> Void = { [weak self] old in
                self?.advanceFeedCursor(from: old)
            }
            let clampCursor: @Sendable (Int, Int) -> Void = { [weak self] old, first in
                self?.clampFeedCursor(from: old, to: first)
            }
            let setSourceEnded: @Sendable () -> Void = { [weak self] in
                self?.sourceEnded = true
            }
            let getSourceEnded: @Sendable () -> Bool = { [weak self] in
                self?.sourceEnded ?? true
            }
            demuxQueue.async {
                Self.runLiveReaderLoop(
                    demuxer: dem,
                    videoStreamIndex: vIdx,
                    audioStreamIndex: aIdx,
                    condition: condition,
                    ring: ring,
                    videoTimeBaseSeconds: vTbSec,
                    audioTimeBaseSeconds: aTbSec,
                    noteEdge: noteEdge,
                    stopRequested: getStopRequested,
                    onError: onError,
                    onSourceEnded: setSourceEnded,
                    subtitleStreamIndices: subIndices,
                    subtitleTimeBases: subTimeBases,
                    splitDisplaySetSubtitleStreamIndices: subSplitSetIndices,
                    subtitleTapSink: getSubtitleTapSink
                )
            }
            let lookahead = audioLookahead
            feedQueue.async {
                Self.runLiveFeederLoop(
                    videoDecoder: vDec,
                    audioDecoder: aDec,
                    audioOutput: aOut,
                    videoStreamIndex: vIdx,
                    audioStreamIndex: aIdx,
                    renderer: rndr,
                    condition: condition,
                    ring: ring,
                    audioLookahead: lookahead,
                    videoTimeBaseSeconds: vTbSec,
                    audioTimeBaseSeconds: aTbSec,
                    readCursor: readCursor,
                    advanceCursor: advanceCursor,
                    clampCursor: clampCursor,
                    currentRate: currentRate,
                    isPlaying: getIsPlaying,
                    stopRequested: getStopRequested,
                    sourceEnded: getSourceEnded,
                    clockArmed: getClockArmed,
                    markClockArmed: setClockArmed,
                    onEnd: onEnd,
                    audioTapSink: getAudioTapSink
                )
            }
            return
        }

        demuxQueue.async {
            Self.runDemuxLoop(
                demuxer: dem,
                videoDecoder: vDec,
                videoStreamIndex: vIdx,
                audioDecoder: aDec,
                audioOutput: aOut,
                audioStreamIndex: aIdx,
                renderer: rndr,
                condition: condition,
                initialClockTime: initialClock,
                currentRate: currentRate,
                ring: ring,
                videoTimeBaseSeconds: vTbSec,
                audioTimeBaseSeconds: aTbSec,
                isLive: liveSession,
                noteEdge: noteEdge,
                isPlaying: getIsPlaying,
                stopRequested: getStopRequested,
                clockArmed: getClockArmed,
                markClockArmed: setClockArmed,
                onClockAnchored: onClockAnchored,
                seekGeneration: getSeekGeneration,
                backgroundAudioOnly: getBackgroundAudioOnly,
                onError: onError,
                onEnd: onEnd,
                audioTapSink: getAudioTapSink,
                subtitleStreamIndices: subIndices,
                subtitleTimeBases: subTimeBases,
                splitDisplaySetSubtitleStreamIndices: subSplitSetIndices,
                subtitleTapSink: getSubtitleTapSink
            )
        }
    }

    // MARK: - Live reader loop (DVR sessions)

    /// Source -> ring (runs regardless of play/pause). Discontinuity reconciliation before ring append so the ring carries one continuous timeline.
    nonisolated private static func runLiveReaderLoop(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32,
        condition: NSCondition,
        ring: PacketRingBuffer,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        noteEdge: @Sendable (Double) -> Void,
        stopRequested: @Sendable () -> Bool,
        onError: @Sendable (String) -> Void,
        onSourceEnded: @Sendable () -> Void,
        subtitleStreamIndices: Set<Int32> = [],
        subtitleTimeBases: [Int32: AVRational] = [:],
        splitDisplaySetSubtitleStreamIndices: Set<Int32> = [],
        subtitleTapSink: @Sendable () -> ((@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational, Bool) -> Void)?) = { nil }
    ) {
        let discontinuityThresholdSeconds = 10.0
        var prevRawVideoPtsSec = Double.nan
        var frameIntervalSec = 0.0
        var discontinuityOffsetSec = 0.0
        var loggedSWDiscontinuity = false
        var lastSeenExtradata: Data? = nil

        defer {
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }

        while !stopRequested() {
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                EngineLog.emit("[SWHost] live reader read failed: \(error)", category: .swPlayback)
                onError("Playback error: \(error.localizedDescription)")
                onSourceEnded()
                break
            }
            guard let packet else {
                EngineLog.emit("[SWHost] live reader EOF (source lost)", category: .swPlayback)
                onSourceEnded()
                break
            }

            let streamIdx = packet.pointee.stream_index

            // In-band codec parameter change detection. libavcodec SW
            // decoders pick up in-band SPS/PPS changes on their own; the
            // VT HEVC path keeps its session-start format description and
            // would wedge or corrupt on a real change. Log loudly so a
            // real-world repro is identifiable; the
            // VTDecompressionSession reinit is gated on one.
            if streamIdx == videoStreamIndex {
                var sdSize: Int = 0
                if let sd = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &sdSize),
                   sdSize > 0 {
                    let newExtra = Data(bytes: sd, count: sdSize)
                    if newExtra != lastSeenExtradata {
                        lastSeenExtradata = newExtra
                        EngineLog.emit(
                            "[SWHost] WARNING: in-band video extradata change (\(sdSize) bytes) "
                            + "on the live source. SW decoders follow in-band parameter sets; "
                            + "the VT HEVC decoder keeps its session-start format description "
                            + "and needs a reinit if artifacts follow.",
                            category: .swPlayback
                        )
                    }
                }
            }

            // NOPTS repair: ring gates on valid PTS; MPEG-TS/H.264 field packets with NOPTS would starve the decoder. Synthesize PTS from DTS.
            if streamIdx == videoStreamIndex || streamIdx == audioStreamIndex,
               packet.pointee.pts == Int64.min, packet.pointee.dts != Int64.min {
                packet.pointee.pts = packet.pointee.dts
            }

            // Live PTS-discontinuity: same accrual as combined loop.
            if streamIdx == videoStreamIndex, videoTimeBaseSeconds > 0,
               packet.pointee.pts != Int64.min {
                let rawPtsSec = Double(packet.pointee.pts) * videoTimeBaseSeconds
                if !prevRawVideoPtsSec.isNaN {
                    let deltaSec = rawPtsSec - prevRawVideoPtsSec
                    if abs(deltaSec) >= discontinuityThresholdSeconds {
                        let expectedContinuation = prevRawVideoPtsSec
                            + (frameIntervalSec > 0 ? frameIntervalSec : 0)
                        discontinuityOffsetSec += (rawPtsSec - expectedContinuation)
                        if !loggedSWDiscontinuity {
                            loggedSWDiscontinuity = true
                            EngineLog.emit(
                                "[SWHost] live PTS discontinuity (reader): prevPts="
                                + "\(String(format: "%.2f", prevRawVideoPtsSec))s "
                                + "rawPts=\(String(format: "%.2f", rawPtsSec))s "
                                + "delta=\(String(format: "%.2f", deltaSec))s -> "
                                + "offset=\(String(format: "%.2f", discontinuityOffsetSec))s "
                                + "(timeline held continuous)",
                                category: .swPlayback
                            )
                        }
                    } else if deltaSec > 0 {
                        frameIntervalSec = deltaSec
                    }
                }
                prevRawVideoPtsSec = rawPtsSec
            }
            if discontinuityOffsetSec != 0 {
                let tbSec = (streamIdx == videoStreamIndex)
                    ? videoTimeBaseSeconds : audioTimeBaseSeconds
                if tbSec > 0 {
                    let offsetTicks = Int64((discontinuityOffsetSec / tbSec).rounded())
                    if packet.pointee.pts != Int64.min { packet.pointee.pts -= offsetTicks }
                    if packet.pointee.dts != Int64.min { packet.pointee.dts -= offsetTicks }
                }
            }

            let isVideo = streamIdx == videoStreamIndex
            let isAudio = streamIdx == audioStreamIndex
            if isVideo || isAudio {
                let tbSec = isVideo ? videoTimeBaseSeconds : audioTimeBaseSeconds
                let rawPts = packet.pointee.pts
                if rawPts != Int64.min, tbSec > 0 {
                    let ptsSec = Double(rawPts) * tbSec
                    noteEdge(ptsSec)
                    if let data = packet.pointee.data, packet.pointee.size > 0 {
                        let bytes = Data(bytes: data, count: Int(packet.pointee.size))
                        let isKey = isVideo && (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                        // Best-effort: a write failure just shrinks the
                        // rewind window, it must not stall the reader.
                        try? ring.append(pts: ptsSec, isKeyframe: isKey, isVideo: isVideo, bytes: bytes)
                        condition.lock()
                        condition.broadcast()
                        condition.unlock()
                    }
                }
            } else if subtitleStreamIndices.contains(streamIdx), let sink = subtitleTapSink() {
                // #107: the ring holds only A/V; subtitle packets tap into the session packet
                // store here, mirroring the combined demux loop (the playhead-paced drainer
                // decodes them on selection).
                sink(streamIdx, packet,
                     subtitleTimeBases[streamIdx] ?? AVRational(num: 1, den: 1000),
                     splitDisplaySetSubtitleStreamIndices.contains(streamIdx))
            }

            av_packet_unref(packet)
            av_packet_free_safe(packet)
        }
    }

    // MARK: - Live feeder loop (DVR sessions)

    /// Ring cursor -> decoders -> renderer with back-pressure. Pause = timeshift (reader keeps filling); DVR seek = cursor move.
    nonisolated private static func runLiveFeederLoop(
        videoDecoder: any VideoDecodingPipeline,
        audioDecoder: AudioDecoder?,
        audioOutput: AudioOutput?,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32,
        renderer: SampleBufferRenderer,
        condition: NSCondition,
        ring: PacketRingBuffer,
        audioLookahead: AudioLookaheadState,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        readCursor: @Sendable () -> Int,
        advanceCursor: @Sendable (Int) -> Void,
        clampCursor: @Sendable (Int, Int) -> Void,
        currentRate: @Sendable () -> Float,
        isPlaying: @Sendable () -> Bool,
        stopRequested: @Sendable () -> Bool,
        sourceEnded: @Sendable () -> Bool,
        clockArmed: @Sendable () -> Bool,
        markClockArmed: @Sendable () -> Void,
        onEnd: @Sendable () -> Void,
        audioTapSink: @Sendable () -> ((@Sendable (CMSampleBuffer) -> Void)?)
    ) {
        // Audio look-ahead pump (#107 audio chopping): feed audio packets ahead of the
        // combined cursor so the audio renderer holds AudioLookaheadPolicy.targetLeadSeconds
        // of decoded audio regardless of video decode pace. Without it audio lead is capped
        // by the video renderer queue (<1 s) and any feeder stall is an audible dropout.
        var preArmPacketsFed = 0
        var hadLead = false
        var rebuffering = false
        var lastLowLeadLog = DispatchTime(uptimeNanoseconds: 0)
        func pumpAudio() {
            guard let aDec = audioDecoder, let aOut = audioOutput, audioStreamIndex >= 0 else { return }
            var seq = audioLookahead.align(to: readCursor())
            while !stopRequested() && isPlaying() {
                let armed = clockArmed()
                guard AudioLookaheadPolicy.decide(
                    clockArmed: armed,
                    preArmPacketsFed: preArmPacketsFed,
                    lastFedAudioPTS: audioLookahead.lastFedAudioPTS,
                    clockSeconds: aOut.currentTimeSeconds
                ) == .feed else { break }
                guard seq < ring.seqBounds.end else { break }  // live edge: nothing to pump yet
                guard let pkt = ring.packet(atSeq: seq) else {
                    // Evicted/unreadable under the pump: skip, same as the combined loop.
                    guard audioLookahead.advance(from: seq, fedPTS: nil) else { break }
                    seq += 1
                    continue
                }
                if pkt.isVideo {
                    guard audioLookahead.advance(from: seq, fedPTS: nil) else { break }
                    seq += 1
                    continue
                }
                let producedAudio = feedRingPacket(
                    pkt,
                    videoDecoder: videoDecoder,
                    audioDecoder: aDec,
                    audioOutput: aOut,
                    videoStreamIndex: videoStreamIndex,
                    audioStreamIndex: audioStreamIndex,
                    videoTimeBaseSeconds: videoTimeBaseSeconds,
                    audioTimeBaseSeconds: audioTimeBaseSeconds,
                    audioTapSink: audioTapSink()
                )
                if !armed {
                    preArmPacketsFed += 1
                    if producedAudio {
                        // First decoded buffers arm the clock at their packet PTS, exactly as
                        // the combined loop did before the pump took over audio delivery.
                        let armTime = CMTime(seconds: pkt.pts, preferredTimescale: 90000)
                        aOut.seekClock(to: armTime, rate: currentRate())
                        markClockArmed()
                    }
                }
                guard audioLookahead.advance(from: seq, fedPTS: pkt.pts) else { break }
                seq += 1
            }
            // Live-edge underrun handling (#107): a source delivering below real time would
            // otherwise leave the free-running clock permanently ahead of the stream, and
            // every later sample lands in the clock's past (continuous chopping that never
            // recovers). Pause the clock, refill, resume; the native path gets the same
            // behavior from AVPlayer's stall handling.
            if clockArmed(), isPlaying() {
                let lastPTS = audioLookahead.lastFedAudioPTS
                let lead = lastPTS.isFinite ? lastPTS - aOut.currentTimeSeconds : 0
                switch AudioLookaheadPolicy.clockAction(
                    rebuffering: rebuffering,
                    lastFedAudioPTS: lastPTS,
                    clockSeconds: aOut.currentTimeSeconds,
                    atRingEnd: audioLookahead.current >= ring.seqBounds.end,
                    sourceEnded: sourceEnded()
                ) {
                case .pauseForRebuffer:
                    rebuffering = true
                    EngineLog.emit(
                        "[SWHost] live source underrun: pausing clock to rebuffer "
                        + "(lead=\(String(format: "%.2f", lead))s)",
                        category: .swPlayback
                    )
                    aOut.pause()
                case .resume:
                    rebuffering = false
                    EngineLog.emit(
                        "[SWHost] rebuffered: resuming clock (lead=\(String(format: "%.2f", lead))s)",
                        category: .swPlayback
                    )
                    aOut.setRate(currentRate())
                case .none:
                    // Decode-lag visibility for device logs: only after lead was once
                    // healthy (startup fill must not trip it), rate-limited to one per 5 s.
                    if lead >= 0.5 { hadLead = true }
                    if hadLead, lead < 0.1, !rebuffering {
                        let now = DispatchTime.now()
                        if now.uptimeNanoseconds &- lastLowLeadLog.uptimeNanoseconds > 5_000_000_000 {
                            lastLowLeadLog = now
                            EngineLog.emit(
                                "[SWHost] audio lead low: \(String(format: "%.2f", lead))s "
                                + "(ring end=\(ring.seqBounds.end) audioSeq=\(audioLookahead.current))",
                                category: .swPlayback
                            )
                        }
                    }
                }
            }
        }

        while !stopRequested() {
            if !isPlaying() {
                condition.lock()
                while !isPlaying() && !stopRequested() {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                }
                condition.unlock()
                continue
            }

            // Keep the audio renderer topped up before (possibly expensive) video work.
            pumpAudio()

            let cursor = readCursor()
            let bounds = ring.seqBounds
            if cursor < bounds.first {
                // Paused/behind longer than the retention window: the
                // packets under the cursor were evicted. Clamp to the
                // oldest retained packet (keyframe-aligned by eviction).
                EngineLog.emit(
                    "[SWHost] feeder cursor \(cursor) fell below window (first=\(bounds.first)); clamping",
                    category: .swPlayback
                )
                clampCursor(cursor, bounds.first)
                continue
            }
            guard let pkt = ring.packet(atSeq: cursor) else {
                // Resident entry whose file read failed (disk hiccup,
                // pruned mid-read): skip it, or the feeder would spin on
                // the same sequence number forever in a silent freeze.
                if cursor < bounds.end {
                    EngineLog.emit(
                        "[SWHost] feeder: packet seq=\(cursor) unreadable; skipping",
                        category: .swPlayback
                    )
                    advanceCursor(cursor)
                    continue
                }
                // At the live edge (cursor == end): wait for the reader's
                // next append, or finish when the source is gone and the
                // ring is fully drained.
                if sourceEnded() {
                    videoDecoder.flush()
                    audioDecoder?.flush()
                    renderer.drainReorderBuffer()
                    onEnd()
                    break
                }
                condition.lock()
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.25))
                condition.unlock()
                continue
            }

            if pkt.isVideo {
                // Back-pressure against renderer queue; also bail on pause without consuming.
                // The wait can outlast the audio lead, so keep pumping audio while parked.
                var waitTicks = 0
                while !renderer.isReadyForMoreMediaData && !stopRequested() && isPlaying() {
                    Thread.sleep(forTimeInterval: 0.005)
                    waitTicks += 1
                    if waitTicks % 20 == 0 { pumpAudio() }
                }
                if stopRequested() { break }
                if !isPlaying() { continue }
            } else if cursor < audioLookahead.current {
                // Audio the pump already delivered: consume the slot without re-decoding.
                advanceCursor(cursor)
                continue
            }

            let producedAudio = feedRingPacket(
                pkt,
                videoDecoder: videoDecoder,
                audioDecoder: audioDecoder,
                audioOutput: audioOutput,
                videoStreamIndex: videoStreamIndex,
                audioStreamIndex: audioStreamIndex,
                videoTimeBaseSeconds: videoTimeBaseSeconds,
                audioTimeBaseSeconds: audioTimeBaseSeconds,
                audioTapSink: audioTapSink()
            )

            // Arm clock once on first packet PTS (anchoring at .zero caused delay). Audio: first decoded buffers; video-only: first video packet (no clock without audio = frozen frame).
            if !clockArmed(), let aOut = audioOutput {
                let shouldArm = (audioDecoder == nil) ? pkt.isVideo : producedAudio
                if shouldArm {
                    let armTime = CMTime(seconds: pkt.pts, preferredTimescale: 90000)
                    // Latest host rate, read at arm time (a setRate before arming is deferred here, #107).
                    aOut.seekClock(to: armTime, rate: currentRate())
                    markClockArmed()
                }
            }

            advanceCursor(cursor)
        }
    }

    /// Apply a resolved clock anchor: seek the synchronizer, report a non-zero session
    /// zero to the host, and log a re-anchor (release-visible; a mid-stream join is
    /// otherwise indistinguishable from a frozen-frame wedge, #107).
    nonisolated private static func armClock(
        _ aOut: AudioOutput,
        resolution: SWClockAnchorPolicy.Resolution,
        initialClockTime: CMTime,
        rate: Float,
        onClockAnchored: @Sendable (Double) -> Void
    ) {
        let anchorTime = resolution.anchorSeconds == initialClockTime.seconds
            ? initialClockTime
            : CMTime(seconds: resolution.anchorSeconds, preferredTimescale: 90000)
        aOut.seekClock(to: anchorTime, rate: rate)
        if resolution.anchorSeconds != initialClockTime.seconds {
            EngineLog.emit(
                "[SWHost] clock re-anchored to first sample: anchor=\(String(format: "%.3f", resolution.anchorSeconds))s "
                + "(load anchor \(String(format: "%.3f", initialClockTime.seconds))s, "
                + "sessionZero=\(String(format: "%.3f", resolution.sessionZeroSeconds))s)",
                category: .swPlayback
            )
            onClockAnchored(resolution.sessionZeroSeconds)
        }
    }

    /// Demux loop: reads packets, dispatches by stream index, back-pressures against renderer's isReadyForMoreMediaData, flushes decoders at EOF.
    nonisolated private static func runDemuxLoop(
        demuxer: Demuxer,
        videoDecoder: any VideoDecodingPipeline,
        videoStreamIndex: Int32,
        audioDecoder: AudioDecoder?,
        audioOutput: AudioOutput?,
        audioStreamIndex: Int32,
        renderer: SampleBufferRenderer,
        condition: NSCondition,
        initialClockTime: CMTime,
        currentRate: @Sendable () -> Float,
        ring: PacketRingBuffer?,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        isLive: Bool,
        noteEdge: @Sendable (Double) -> Void,
        isPlaying: @Sendable () -> Bool,
        stopRequested: @Sendable () -> Bool,
        clockArmed: @Sendable () -> Bool,
        markClockArmed: @Sendable () -> Void,
        onClockAnchored: @Sendable (Double) -> Void,
        seekGeneration: @Sendable () -> UInt64,
        backgroundAudioOnly: @Sendable () -> Bool,
        onError: @Sendable (String) -> Void,
        onEnd: @Sendable () -> Void,
        audioTapSink: @Sendable () -> ((@Sendable (CMSampleBuffer) -> Void)?),
        subtitleStreamIndices: Set<Int32> = [],
        subtitleTimeBases: [Int32: AVRational] = [:],
        splitDisplaySetSubtitleStreamIndices: Set<Int32> = [],
        subtitleTapSink: @Sendable () -> ((@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational, Bool) -> Void)?) = { nil }
    ) {
        // Clock arming: one-shot latch (seekClock is not idempotent -- re-calling snaps clock back to initialClockTime). Shared with host so a seek before first audio isn't overridden by a late re-arm.

        // Live PTS-discontinuity (SW): accrue (jumpedPts - expectedContinuation) into discontinuityOffset; subtract from all subsequent PTS so the whole pipeline sees one continuous timeline. Threshold 10s (mirrors native producer); flush decoders at the seam.
        let discontinuityThresholdSeconds = 10.0
        var prevRawVideoPtsSec = Double.nan
        var frameIntervalSec = 0.0
        var discontinuityOffsetSec = 0.0
        var loggedSWDiscontinuity = false

        // Clock-arming fallback bookkeeping: a declared audio track whose
        // decoder never produces buffers (corrupt stream) must not leave
        // the session unarmed forever. See the video-branch arming below.
        var audioPacketsSeen = 0
        var audioBuffersProduced = false

        while !stopRequested() {
            if !isPlaying() {
                condition.lock()
                while !isPlaying() && !stopRequested() {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                }
                condition.unlock()
                continue
            }

            let genBeforeRead = seekGeneration()
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                EngineLog.emit("[SWHost] demux read failed: \(error)", category: .swPlayback)
                onError("Playback error: \(error.localizedDescription)")
                break
            }

            guard let packet else {
                videoDecoder.flush()
                audioDecoder?.flush()
                renderer.drainReorderBuffer()
                onEnd()
                break
            }

            // Stale packet from before seek flush: decoding would clear the skip threshold (visible fast-forward burst). Discard.
            if seekGeneration() != genBeforeRead {
                av_packet_unref(packet)
                av_packet_free_safe(packet)
                continue
            }

            let streamIdx = packet.pointee.stream_index

            // Discontinuity runs before any timestamp read; offset applied to both streams. Non-live SW skips.
            if isLive, streamIdx == videoStreamIndex, videoTimeBaseSeconds > 0,
               packet.pointee.pts != Int64.min {
                let rawPtsSec = Double(packet.pointee.pts) * videoTimeBaseSeconds
                if !prevRawVideoPtsSec.isNaN {
                    let deltaSec = rawPtsSec - prevRawVideoPtsSec
                    if abs(deltaSec) >= discontinuityThresholdSeconds {
                        // Accrue (jumpedPts - expectedContinuation) into offset; flush decoders at the seam.
                        let expectedContinuation = prevRawVideoPtsSec
                            + (frameIntervalSec > 0 ? frameIntervalSec : 0)
                        discontinuityOffsetSec += (rawPtsSec - expectedContinuation)
                        videoDecoder.flush()
                        audioDecoder?.flush()
                        renderer.drainReorderBuffer()
                        if !loggedSWDiscontinuity {
                            loggedSWDiscontinuity = true
                            EngineLog.emit(
                                "[SWHost] live PTS discontinuity: prevPts="
                                + "\(String(format: "%.2f", prevRawVideoPtsSec))s "
                                + "rawPts=\(String(format: "%.2f", rawPtsSec))s "
                                + "delta=\(String(format: "%.2f", deltaSec))s -> "
                                + "offset=\(String(format: "%.2f", discontinuityOffsetSec))s "
                                + "(timeline held continuous)",
                                category: .swPlayback
                            )
                        }
                    } else if deltaSec > 0 {
                        frameIntervalSec = deltaSec
                    }
                }
                prevRawVideoPtsSec = rawPtsSec
            }

            // Apply discontinuity offset to timestamps in-place (live only); converts seconds to stream TB ticks.
            if isLive, discontinuityOffsetSec != 0 {
                let tbSec = (streamIdx == videoStreamIndex)
                    ? videoTimeBaseSeconds : audioTimeBaseSeconds
                if tbSec > 0 {
                    let offsetTicks = Int64((discontinuityOffsetSec / tbSec).rounded())
                    if packet.pointee.pts != Int64.min { packet.pointee.pts -= offsetTicks }
                    if packet.pointee.dts != Int64.min { packet.pointee.dts -= offsetTicks }
                }
            }

            // Fill ring before decode so the ring holds every packet. Audio appended for sync; only video keyframes tagged for eviction alignment.
            if isLive {
                let isVideo = streamIdx == videoStreamIndex
                let isAudio = streamIdx == audioStreamIndex
                if isVideo || isAudio {
                    let tbSec = isVideo ? videoTimeBaseSeconds : audioTimeBaseSeconds
                    let rawPts = packet.pointee.pts
                    if rawPts != Int64.min, tbSec > 0 {
                        let ptsSec = Double(rawPts) * tbSec
                        noteEdge(ptsSec)
                        if let ring {
                            let isKey = isVideo && (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                            if let data = packet.pointee.data, packet.pointee.size > 0 {
                                let bytes = Data(bytes: data, count: Int(packet.pointee.size))
                                // Append is a small file write; off-main and
                                // internally locked, so it never touches the
                                // decoders' state. Best-effort: a write failure
                                // just shrinks the rewind window, it must not
                                // stall live playback.
                                try? ring.append(pts: ptsSec, isKeyframe: isKey, isVideo: isVideo, bytes: bytes)
                            }
                        }
                    }
                }
            }

            if streamIdx == videoStreamIndex {
                // Background audio-only: drop video, don't gate on the non-draining display layer.
                if backgroundAudioOnly() {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    continue
                }
                // Back-pressure via SampleBufferRenderer.isReadyForMoreMediaData (not the deprecated layer property). Park on condition while paused to avoid 200 Hz CPU spin.
                while !renderer.isReadyForMoreMediaData && !stopRequested() && !backgroundAudioOnly() {
                    if !isPlaying() {
                        condition.lock()
                        while !isPlaying() && !stopRequested() {
                            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                        }
                        condition.unlock()
                    } else {
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                }
                // Entered background while parked on back-pressure: drop this frame.
                if backgroundAudioOnly() {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    continue
                }
                if stopRequested() {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    break
                }
                // Re-check generation after the back-pressure wait (seek can land there; pre-seek packet would clear skip thresholds).
                if seekGeneration() != genBeforeRead {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    continue
                }
                videoDecoder.decode(packet: packet)
                // Video-only / undecodable audio fallback: arm clock off first video packet (50+ audio packets with zero buffers = decoder not recovering).
                if !clockArmed(), let aOut = audioOutput,
                   audioDecoder == nil || (audioPacketsSeen >= 50 && !audioBuffersProduced) {
                    // #107: a mid-stream-joined source delivers first samples far past the load
                    // anchor; anchor at the packet PTS so they ever present (see SWClockAnchorPolicy).
                    let pktPtsSec = (packet.pointee.pts != Int64.min && videoTimeBaseSeconds > 0)
                        ? Double(packet.pointee.pts) * videoTimeBaseSeconds : Double.nan
                    let resolution = SWClockAnchorPolicy.resolve(
                        initialSeconds: initialClockTime.seconds, firstSampleSeconds: pktPtsSec)
                    armClock(aOut, resolution: resolution, initialClockTime: initialClockTime,
                             rate: currentRate(), onClockAnchored: onClockAnchored)
                    markClockArmed()
                }
            } else if streamIdx == audioStreamIndex, let aDec = audioDecoder, let aOut = audioOutput {
                // Background audio-only: the video gate is bypassed, so pace on the audio renderer to avoid
                // buffering the rest of the file. Park on condition while paused (same shape as the video gate).
                if backgroundAudioOnly() {
                    while !aOut.isReadyForMoreMediaData && !stopRequested() && backgroundAudioOnly() {
                        if !isPlaying() {
                            condition.lock()
                            while !isPlaying() && !stopRequested() {
                                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                            }
                            condition.unlock()
                        } else {
                            Thread.sleep(forTimeInterval: 0.005)
                        }
                    }
                    if stopRequested() {
                        av_packet_unref(packet)
                        av_packet_free_safe(packet)
                        break
                    }
                }
                audioPacketsSeen += 1
                let buffers = aDec.decode(packet: packet)
                if !buffers.isEmpty { audioBuffersProduced = true }
                let tapSink = audioTapSink()
                for buf in buffers {
                    tapSink?(buf)   // #95: mirror before enqueue
                    aOut.enqueue(sampleBuffer: buf)
                }
                // Arm clock on first decoded audio buffer; latch so subsequent packets don't snap clock back.
                if !clockArmed(), !buffers.isEmpty {
                    // #107: anchor at the buffer PTS when it deviates from the load anchor
                    // (mid-stream-joined source); aligned sources keep the anchor verbatim.
                    let firstPts = CMSampleBufferGetPresentationTimeStamp(buffers[0])
                    let resolution = SWClockAnchorPolicy.resolve(
                        initialSeconds: initialClockTime.seconds,
                        firstSampleSeconds: firstPts.isValid ? firstPts.seconds : Double.nan)
                    armClock(aOut, resolution: resolution, initialClockTime: initialClockTime,
                             rate: currentRate(), onClockAnchored: onClockAnchored)
                    markClockArmed()
                }
            } else if subtitleStreamIndices.contains(streamIdx), let sink = subtitleTapSink() {
                // #112 rework: hand embedded subtitle packets to the tap sink (copies the payload
                // into the session's SubtitlePacketStore). The SW host applies no stream discard,
                // so these packets were already being read and dropped here.
                sink(streamIdx, packet,
                     subtitleTimeBases[streamIdx] ?? AVRational(num: 1, den: 1000),
                     splitDisplaySetSubtitleStreamIndices.contains(streamIdx))
            }

            av_packet_unref(packet)
            av_packet_free_safe(packet)
        }
    }

    // MARK: - Time updates

    private func startTimeUpdates() {
        timeTimer = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let aOut = self.audioOutput else { return }
                let raw = aOut.currentTimeSeconds
                if raw.isFinite, raw >= 0 {
                    // Raw clock = source/subtitle axis; published alongside the mapped position (#107).
                    self.sourceClockSeconds = raw
                    // Live: subtract sessionStartPts to convert to "seconds since first frame"; VOD
                    // subtracts the anchor's session zero (0 for zero-based sources, #107).
                    if self.isLive {
                        let start: Double = {
                            self.liveEdgeLock.lock(); defer { self.liveEdgeLock.unlock() }
                            return self.sessionStartPts.isFinite ? self.sessionStartPts : 0
                        }()
                        self.currentTime = max(0, raw - start)
                    } else {
                        let zero = self.clockSessionZero
                        self.currentTime = zero > 0 ? max(0, raw - zero) : raw
                    }
                }
                // Feed the live edge; publishLiveWindow in the engine reads currentTime for the playhead.
                if self.isLive, let edge = self.liveEdgeSessionTime {
                    self.onLiveEdge?(edge)
                }
            }
    }

    // MARK: - Errors

    enum HostError: Error, LocalizedError {
        case noVideoStream

        var errorDescription: String? {
            switch self {
            case .noVideoStream: return "Source has no video stream"
            }
        }
    }
}

// MARK: - AVPacket free helper

/// av_packet_free wrapper for the double-pointer FFmpeg API.
func av_packet_free_safe(_ packet: UnsafeMutablePointer<AVPacket>) {
    var p: UnsafeMutablePointer<AVPacket>? = packet
    trackedPacketFree(&p)
}
