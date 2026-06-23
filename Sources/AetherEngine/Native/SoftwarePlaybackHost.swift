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
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    @Published private(set) var failureMessage: String?
    @Published private(set) var didReachEnd: Bool = false

    /// Fires (off-main) once per session the first time HDR10+ dynamic
    /// metadata appears on a decoded frame. Hooked by `AetherEngine` to
    /// upgrade the published `videoFormat` from `.hdr10` → `.hdr10Plus`.
    nonisolated(unsafe) var onFirstHDR10PlusDetected: (@Sendable () -> Void)?

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
        feedLock.unlock()
    }

    /// Whether the synchronizer clock has been anchored this session. Shared with seek paths so a DVR seek before feeder arming is not overwritten by a late re-arm.
    nonisolated(unsafe) private var _clockArmed = false
    nonisolated private var clockArmed: Bool {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _clockArmed }
        set { feedLock.lock(); _clockArmed = newValue; feedLock.unlock() }
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

    /// Caching the chosen rate so resume() restores the right speed
    /// after a pause without the host needing to know its history.
    private var lastRate: Float = 1.0

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

        // HEVC -> VTDecompressionSession (HW); everything else -> libavcodec. Replace wholesale to prevent state bleed.
        if let codecpar = vStream.pointee.codecpar,
           codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
            videoDecoder.close()
            videoDecoder = HardwareVideoDecoder()
            EngineLog.emit(
                "[SWHost] selected HardwareVideoDecoder (VT HEVC) for codec_id=\(codecpar.pointee.codec_id.rawValue)",
                category: .swPlayback
            )
        } else if !(videoDecoder is SoftwareVideoDecoder) {
            videoDecoder.close()
            videoDecoder = SoftwareVideoDecoder()
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
        // Resume after pause() BEFORE the demuxLoopStarted flip: distinguishes real resume (clock armed) from pause-before-first-play (un-anchored clock must not tick forward via eager setRate).
        if pausedByHost {
            pausedByHost = false
            if demuxLoopStarted {
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

    func pause() {
        audioOutput?.pause()
        pausedByHost = true
        rate = 0
        isPlaying = false
    }

    func setRate(_ newRate: Float) {
        lastRate = newRate
        audioOutput?.setRate(newRate)
        rate = newRate
    }

    func seek(to seconds: Double) async {
        guard let dem = demuxer else { return }
        // Stop loop + bump generation to invalidate in-flight packets.
        bumpSeekGeneration()
        let wasPlaying = isPlaying
        isPlaying = false

        videoDecoder.flush()
        audioDecoder?.flush()
        renderer.flush()
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
        audioTimeBaseSeconds: Double
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
        let initialRate = lastRate
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
                    onSourceEnded: setSourceEnded
                )
            }
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
                    videoTimeBaseSeconds: vTbSec,
                    audioTimeBaseSeconds: aTbSec,
                    readCursor: readCursor,
                    advanceCursor: advanceCursor,
                    clampCursor: clampCursor,
                    initialRate: initialRate,
                    isPlaying: getIsPlaying,
                    stopRequested: getStopRequested,
                    sourceEnded: getSourceEnded,
                    clockArmed: getClockArmed,
                    markClockArmed: setClockArmed,
                    onEnd: onEnd
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
                initialRate: initialRate,
                ring: ring,
                videoTimeBaseSeconds: vTbSec,
                audioTimeBaseSeconds: aTbSec,
                isLive: liveSession,
                noteEdge: noteEdge,
                isPlaying: getIsPlaying,
                stopRequested: getStopRequested,
                clockArmed: getClockArmed,
                markClockArmed: setClockArmed,
                seekGeneration: getSeekGeneration,
                onError: onError,
                onEnd: onEnd
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
        onSourceEnded: @Sendable () -> Void
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
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        readCursor: @Sendable () -> Int,
        advanceCursor: @Sendable (Int) -> Void,
        clampCursor: @Sendable (Int, Int) -> Void,
        initialRate: Float,
        isPlaying: @Sendable () -> Bool,
        stopRequested: @Sendable () -> Bool,
        sourceEnded: @Sendable () -> Bool,
        clockArmed: @Sendable () -> Bool,
        markClockArmed: @Sendable () -> Void,
        onEnd: @Sendable () -> Void
    ) {
        while !stopRequested() {
            if !isPlaying() {
                condition.lock()
                while !isPlaying() && !stopRequested() {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                }
                condition.unlock()
                continue
            }

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
                while !renderer.isReadyForMoreMediaData && !stopRequested() && isPlaying() {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                if stopRequested() { break }
                if !isPlaying() { continue }
            }

            let producedAudio = feedRingPacket(
                pkt,
                videoDecoder: videoDecoder,
                audioDecoder: audioDecoder,
                audioOutput: audioOutput,
                videoStreamIndex: videoStreamIndex,
                audioStreamIndex: audioStreamIndex,
                videoTimeBaseSeconds: videoTimeBaseSeconds,
                audioTimeBaseSeconds: audioTimeBaseSeconds
            )

            // Arm clock once on first packet PTS (anchoring at .zero caused delay). Audio: first decoded buffers; video-only: first video packet (no clock without audio = frozen frame).
            if !clockArmed(), let aOut = audioOutput {
                let shouldArm = (audioDecoder == nil) ? pkt.isVideo : producedAudio
                if shouldArm {
                    let armTime = CMTime(seconds: pkt.pts, preferredTimescale: 90000)
                    // Use initialRate (not 1.0) to preserve any rate set before arming.
                    aOut.seekClock(to: armTime, rate: initialRate)
                    markClockArmed()
                }
            }

            advanceCursor(cursor)
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
        initialRate: Float,
        ring: PacketRingBuffer?,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        isLive: Bool,
        noteEdge: @Sendable (Double) -> Void,
        isPlaying: @Sendable () -> Bool,
        stopRequested: @Sendable () -> Bool,
        clockArmed: @Sendable () -> Bool,
        markClockArmed: @Sendable () -> Void,
        seekGeneration: @Sendable () -> UInt64,
        onError: @Sendable (String) -> Void,
        onEnd: @Sendable () -> Void
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
                // Back-pressure via SampleBufferRenderer.isReadyForMoreMediaData (not the deprecated layer property). Park on condition while paused to avoid 200 Hz CPU spin.
                while !renderer.isReadyForMoreMediaData && !stopRequested() {
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
                    aOut.seekClock(to: initialClockTime, rate: initialRate)
                    markClockArmed()
                }
            } else if streamIdx == audioStreamIndex, let aDec = audioDecoder, let aOut = audioOutput {
                audioPacketsSeen += 1
                let buffers = aDec.decode(packet: packet)
                if !buffers.isEmpty { audioBuffersProduced = true }
                for buf in buffers {
                    aOut.enqueue(sampleBuffer: buf)
                }
                // Arm clock on first decoded audio buffer; latch so subsequent packets don't snap clock back.
                if !clockArmed(), !buffers.isEmpty {
                    aOut.seekClock(to: initialClockTime, rate: initialRate)
                    markClockArmed()
                }
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
                    // Live: subtract sessionStartPts to convert to "seconds since first frame"; VOD keeps the raw clock.
                    if self.isLive {
                        let start: Double = {
                            self.liveEdgeLock.lock(); defer { self.liveEdgeLock.unlock() }
                            return self.sessionStartPts.isFinite ? self.sessionStartPts : 0
                        }()
                        self.currentTime = max(0, raw - start)
                    } else {
                        self.currentTime = raw
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
