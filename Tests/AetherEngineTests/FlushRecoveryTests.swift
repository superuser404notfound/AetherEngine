import Foundation
import AVFoundation
import AetherLibavformat
import AetherLibavcodec
import CoreMedia
import CoreVideo
import Testing
@testable import AetherEngine

/// The system can flush or fail the video queue and the audio renderer under the software host, and
/// AVPlayer recovers from that by itself. The host keeps the audio playing and lets the picture resume
/// at the next keyframe, and puts the whole session back at the playhead only when that keyframe lies
/// further away than the audio lead.
@Suite("Flush recovery policy")
struct FlushRecoveryPolicyTests {
    typealias Policy = FlushRecoveryPolicy

    private static func state(gap: Double?, lead: Double) -> Policy.State {
        var s = Policy.State()
        s.videoGapSeconds = gap
        s.audioLeadSeconds = lead
        return s
    }

    @Test("a keyframe inside the audio lead is waited for, one beyond it (or none read yet) repositions")
    func gapAgainstLead() {
        for trigger in [FlushRecoveryTrigger.videoQueueRequiresFlush, .videoQueueFailed] {
            #expect(Policy.decide(trigger, Self.state(gap: 1.5, lead: 4)) == .flushVideoOnly)
            #expect(Policy.decide(trigger, Self.state(gap: 4, lead: 4)) == .flushVideoOnly)
            #expect(Policy.decide(trigger, Self.state(gap: 4.01, lead: 4)) == .reposition)
            #expect(Policy.decide(trigger, Self.state(gap: nil, lead: 4)) == .reposition)
            #expect(Policy.decide(trigger, Self.state(gap: 0, lead: 0)) == .flushVideoOnly)
            #expect(Policy.decide(trigger, Self.state(gap: nil, lead: 0)) == .reposition)
        }
        #expect(Policy.videoGapOutlastsAudioLead(gap: nil, lead: .infinity))
    }

    @Test("a gone session, a seek in flight or a recovery under way ignore every trigger")
    func ignored() {
        for trigger in FlushRecoveryTrigger.allCases {
            var s = Policy.State(); s.stopRequested = true
            #expect(Policy.decide(trigger, s) == .ignore)
            s = .init(); s.hasSource = false
            #expect(Policy.decide(trigger, s) == .ignore)
            s = .init(); s.seekInFlight = true
            #expect(Policy.decide(trigger, s) == .ignore)
            s = .init(); s.recoveryPending = true
            #expect(Policy.decide(trigger, s) == .ignore)
        }
    }

    @Test("a failed audio renderer is flushed and never repositions, whatever the video gap is")
    func audioFailed() {
        #expect(Policy.decide(.audioRendererFailed, Self.state(gap: nil, lead: 0)) == .flushAudioOnly)
        var s = Self.state(gap: 99, lead: 0); s.backgroundAudioOnly = true
        #expect(Policy.decide(.audioRendererFailed, s) == .flushAudioOnly)
        s.firstFramePresented = false
        #expect(Policy.decide(.audioRendererFailed, s) == .flushAudioOnly)
    }

    @Test("a failed audio renderer is flushed a bounded number of times per window, then left alone")
    func audioFlushStormCap() {
        var s = Self.state(gap: nil, lead: 0)
        for n in 0..<Policy.maxAudioFlushesPerWindow {
            s.audioFlushesInWindow = n
            #expect(Policy.decide(.audioRendererFailed, s) == .flushAudioOnly)
        }
        s.audioFlushesInWindow = Policy.maxAudioFlushesPerWindow
        #expect(Policy.decide(.audioRendererFailed, s) == .ignore)
        // The video triggers do not count audio flushes.
        #expect(Policy.decide(.videoQueueFailed, s) != .ignore)
    }

    @Test("in the background the video side waits for the foreground")
    func background() {
        var s = Policy.State(); s.backgroundAudioOnly = true
        #expect(Policy.decide(.videoQueueRequiresFlush, s) == .deferToForeground)
        #expect(Policy.decide(.videoQueueFailed, s) == .deferToForeground)
        // Before the first frame too: the background is the one case that still has something to pay.
        s.firstFramePresented = false
        #expect(Policy.decide(.videoQueueFailed, s) == .deferToForeground)
    }

    @Test("before the first frame is presented a video trigger is ignored: the failed-enqueue path already flushed")
    func beforeFirstFrame() {
        var s = Self.state(gap: nil, lead: 0); s.firstFramePresented = false
        #expect(Policy.decide(.videoQueueRequiresFlush, s) == .ignore)
        #expect(Policy.decide(.videoQueueFailed, s) == .ignore)
    }

    @Test("a live source with no rewind ring cannot go back: the video queue is flushed whatever the gap")
    func liveWithoutRing() {
        var s = Self.state(gap: nil, lead: 0); s.canReposition = false
        #expect(Policy.decide(.videoQueueRequiresFlush, s) == .flushVideoOnly)
        s.videoGapSeconds = 300
        #expect(Policy.decide(.videoQueueFailed, s) == .flushVideoOnly)
    }

    @Test("with no frame presented since the last recovery: a reposition degrades to a plain flush, a plain flush is not repeated")
    func stormDegrades() {
        var s = Self.state(gap: nil, lead: 0)
        s.framesPresentedSinceLastVideoRecovery = 0
        s.lastVideoRecovery = .reposition
        #expect(Policy.decide(.videoQueueFailed, s) == .flushVideoOnly)
        s.lastVideoRecovery = .flushVideoOnly
        #expect(Policy.decide(.videoQueueFailed, s) == .ignore)
        // A frame since then: the recovery worked, this is a new episode and the gap rule applies again.
        s.framesPresentedSinceLastVideoRecovery = 1
        #expect(Policy.decide(.videoQueueFailed, s) == .reposition)
        s.framesPresentedSinceLastVideoRecovery = nil
        s.lastVideoRecovery = nil
        #expect(Policy.decide(.videoQueueFailed, s) == .reposition)
    }

    @Test("a reposition is not repeated within the backoff, whatever the frames did; the flush it degrades to is")
    func repositionBackoff() {
        var s = Self.state(gap: nil, lead: 0)
        s.framesPresentedSinceLastVideoRecovery = 5
        s.lastVideoRecovery = .reposition
        s.secondsSinceLastReposition = Policy.repositionBackoffSeconds - 0.1
        #expect(Policy.decide(.videoQueueFailed, s) == .flushVideoOnly)
        s.secondsSinceLastReposition = Policy.repositionBackoffSeconds
        #expect(Policy.decide(.videoQueueFailed, s) == .reposition)
        s.secondsSinceLastReposition = nil
        #expect(Policy.decide(.videoQueueFailed, s) == .reposition)
        // A flush that is already enough is not made a reposition by the clock running out.
        s.secondsSinceLastReposition = 0
        s.videoGapSeconds = 1; s.audioLeadSeconds = 4
        #expect(Policy.decide(.videoQueueFailed, s) == .flushVideoOnly)
    }

    @Test("a queue needs a flush when it says so or when it is failed")
    func needsFlush() {
        #expect(Policy.videoQueueNeedsFlush(requiresFlush: true, failed: false))
        #expect(Policy.videoQueueNeedsFlush(requiresFlush: false, failed: true))
        #expect(!Policy.videoQueueNeedsFlush(requiresFlush: false, failed: false))
    }

    @Test("renderer reasons map to the video triggers")
    func reasons() {
        #expect(SampleBufferRenderer.QueueFlushReason.requiresFlush.trigger == .videoQueueRequiresFlush)
        #expect(SampleBufferRenderer.QueueFlushReason.failed.trigger == .videoQueueFailed)
    }
}

@Suite("Flush recovery keyframe ledger")
struct KeyframeLedgerTests {
    @Test("the next keyframe is the oldest one read and not yet handed to the decoder")
    func nextKeyframe() {
        let ledger = SWKeyframeLedger()
        #expect(ledger.nextKeyframe == nil)
        ledger.noteKeyframeRead(pts: 10)
        ledger.noteKeyframeRead(pts: 14)
        ledger.noteKeyframeRead(pts: 18)
        #expect(ledger.nextKeyframe == 10)
        ledger.noteHandedToDecoder(pts: 12.5, isKeyframe: false)   // a delta frame retires nothing
        #expect(ledger.nextKeyframe == 10)
        ledger.noteHandedToDecoder(pts: 10, isKeyframe: true)
        #expect(ledger.nextKeyframe == 14)
        ledger.noteHandedToDecoder(pts: 18, isKeyframe: true)   // a later keyframe retires the earlier ones
        #expect(ledger.nextKeyframe == nil)
    }

    @Test("the gate drops everything until a keyframe, lets that one through, and is open again after")
    func gate() {
        let ledger = SWKeyframeLedger()
        #expect(ledger.gate(isKeyframe: false) == .pass)
        ledger.requireKeyframe()
        #expect(ledger.isAwaitingKeyframe)
        #expect(ledger.gate(isKeyframe: false) == .drop)
        #expect(ledger.gate(isKeyframe: false) == .drop)
        #expect(ledger.gate(isKeyframe: true) == .passAndOpen)
        #expect(!ledger.isAwaitingKeyframe)
        #expect(ledger.gate(isKeyframe: false) == .pass)
        // Raised again (the keyframe was refused by a flush that landed during the hand-off).
        ledger.requireKeyframe()
        #expect(ledger.gate(isKeyframe: false) == .drop)
    }

    @Test("a source whose keyframes carry no flag is not starved for good")
    func gateLimit() {
        let ledger = SWKeyframeLedger()
        ledger.requireKeyframe()
        for _ in 0..<SWKeyframeLedger.gateDropLimit { #expect(ledger.gate(isKeyframe: false) == .drop) }
        #expect(ledger.gate(isKeyframe: false) == .passAndOpen)
        #expect(ledger.gate(isKeyframe: false) == .pass)
    }

    @Test("a seek's reset opens the gate; discarding parked packets leaves it alone")
    func gateAndResets() {
        let ledger = SWKeyframeLedger()
        ledger.requireKeyframe()
        ledger.noteKeyframeRead(pts: 3)
        ledger.discardPending()
        #expect(ledger.nextKeyframe == nil)
        #expect(ledger.isAwaitingKeyframe)
        ledger.reset()
        #expect(!ledger.isAwaitingKeyframe)
    }

    @Test("a keyframe discarded before it reached the decoder leaves the ledger")
    func dropped() {
        let ledger = SWKeyframeLedger()
        ledger.noteKeyframeRead(pts: 10)
        ledger.noteKeyframeRead(pts: 14)
        ledger.noteDropped(pts: 12, isKeyframe: false)
        ledger.noteDropped(pts: 10, isKeyframe: false)   // a delta frame was never in it
        #expect(ledger.nextKeyframe == 10)
        ledger.noteDropped(pts: 10, isKeyframe: true)
        #expect(ledger.nextKeyframe == 14)
    }

    @Test("a reposition empties it, a timestamp that is not a time is refused, and it stays bounded")
    func resetAndBounds() {
        let ledger = SWKeyframeLedger()
        ledger.noteKeyframeRead(pts: .nan)
        #expect(ledger.nextKeyframe == nil)
        for i in 0..<(SWKeyframeLedger.capacity + 10) { ledger.noteKeyframeRead(pts: Double(i)) }
        #expect(ledger.nextKeyframe == 10)
        ledger.reset()
        #expect(ledger.nextKeyframe == nil)
    }
}

/// Test pictures: a 10-bit buffer is what the renderer is handed on the HDR routes.
private func makePixelBuffer(width: Int = 64, height: Int = 64) -> CVPixelBuffer? {
    var out: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &out)
    return status == kCVReturnSuccess ? out : nil
}

@Suite("Flush recovery renderer", .serialized)
@MainActor
struct FlushRecoveryRendererTests {

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _reasons: [SampleBufferRenderer.QueueFlushReason] = []
        private var _threads: [Thread] = []
        var reasons: [SampleBufferRenderer.QueueFlushReason] { lock.lock(); defer { lock.unlock() }; return _reasons }
        var threads: [Thread] { lock.lock(); defer { lock.unlock() }; return _threads }
        func add(_ r: SampleBufferRenderer.QueueFlushReason) {
            lock.lock(); _reasons.append(r); _threads.append(.current); lock.unlock()
        }
    }

    @Test("every report reaches the observer, and none after it is removed")
    func rendererReports() {
        let renderer = SampleBufferRenderer()
        let box = Box()
        renderer.setQueueFlushObserver { box.add($0) }
        renderer.reportQueueFlushForTesting(.requiresFlush)
        renderer.reportQueueFlushForTesting(.failed)
        #expect(box.reasons == [.requiresFlush, .failed])
        renderer.setQueueFlushObserver(nil)
        renderer.reportQueueFlushForTesting(.failed)
        #expect(box.reasons.count == 2)
    }

    @Test("the SDK's own notifications are observed, off the posting thread, and a queue that needs nothing reports nothing")
    func notificationsUseTheSdkConstants() {
        let renderer = SampleBufferRenderer()
        let box = Box()
        renderer.setQueueFlushObserver { box.add($0) }
        let video = renderer.videoRenderer

        // A healthy renderer: the property read back says no flush is needed.
        NotificationCenter.default.post(
            name: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification, object: video)
        NotificationCenter.default.post(
            name: AVSampleBufferVideoRenderer.didFailToDecodeNotification, object: video)
        renderer.drainQueueNotificationsForTesting()
        #expect(box.reasons.isEmpty)

        // A renderer that does need one: both notifications report, from the renderer's own queue.
        renderer.queueNeedsFlushForTesting = { true }
        NotificationCenter.default.post(
            name: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification, object: video)
        NotificationCenter.default.post(
            name: AVSampleBufferVideoRenderer.didFailToDecodeNotification, object: video,
            userInfo: [AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey:
                        NSError(domain: "test", code: 1)])
        renderer.drainQueueNotificationsForTesting()
        #expect(box.reasons == [.requiresFlush, .failed])
        #expect(box.threads.allSatisfy { $0 !== Thread.current })

        // Another renderer's notification is not ours.
        let other = SampleBufferRenderer()
        NotificationCenter.default.post(
            name: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
            object: other.videoRenderer)
        renderer.drainQueueNotificationsForTesting()
        #expect(box.reasons.count == 2)
    }

    @Test("a frame the queue took counts as presented")
    func acceptedFrames() throws {
        let renderer = SampleBufferRenderer()
        #expect(renderer.acceptedFrameCount == 0)
        renderer.enqueue(pixelBuffer: try #require(makePixelBuffer()), pts: CMTime(seconds: 0, preferredTimescale: 90000))
        renderer.drainReorderBuffer()
        #expect(renderer.acceptedFrameCount >= 1)
    }

    @Test("a frame counts as presented when the clock has passed it with the queue healthy, not when the enqueue returned")
    func presentedNeedsTheClock() throws {
        let renderer = SampleBufferRenderer()
        renderer.enqueue(pixelBuffer: try #require(makePixelBuffer()), pts: CMTime(seconds: 5, preferredTimescale: 90000))
        renderer.drainReorderBuffer()
        #expect(renderer.acceptedFrameCount == 1)
        #expect(renderer.presentedFrameCount(clockSeconds: 4.9) == 0)
        #expect(renderer.presentedFrameCount(clockSeconds: .nan) == 0)
        // The queue turned out to refuse it: no evidence while it needs a flush.
        renderer.queueNeedsFlushForTesting = { true }
        #expect(renderer.presentedFrameCount(clockSeconds: 6) == 0)
        renderer.queueNeedsFlushForTesting = nil
        #expect(renderer.presentedFrameCount(clockSeconds: 6) == 1)
        #expect(renderer.presentedFrameCount(clockSeconds: 7) == 1)
        // A flush drops the frames not yet counted, as the queue dropped them.
        renderer.enqueue(pixelBuffer: try #require(makePixelBuffer()), pts: CMTime(seconds: 9, preferredTimescale: 90000))
        renderer.drainReorderBuffer()
        renderer.flush(removingDisplayedImage: false)
        #expect(renderer.presentedFrameCount(clockSeconds: 10) == 1)
    }

    @Test("a queue that requires a flush without being failed is flushed and reported at the next enqueue")
    func requiresFlushAtEnqueue() throws {
        let renderer = SampleBufferRenderer()
        let box = Box()
        renderer.setQueueFlushObserver { box.add($0) }
        renderer.queueNeedsFlushForTesting = { true }
        renderer.enqueue(pixelBuffer: try #require(makePixelBuffer()), pts: CMTime(seconds: 1, preferredTimescale: 90000))
        renderer.drainReorderBuffer()
        #expect(box.reasons == [.requiresFlush])
        // The frame handed over right after the flush is not evidence that the queue works.
        #expect(renderer.acceptedFrameCount == 0)
        renderer.queueNeedsFlushForTesting = nil
        renderer.enqueue(pixelBuffer: try #require(makePixelBuffer()), pts: CMTime(seconds: 2, preferredTimescale: 90000))
        renderer.drainReorderBuffer()
        #expect(box.reasons == [.requiresFlush])
        #expect(renderer.acceptedFrameCount == 1)
    }

    @Test("a flush that carries the skip threshold installs it with the flush: nothing below it slips in between")
    func flushWithThreshold() throws {
        let renderer = SampleBufferRenderer()
        renderer.flush(removingDisplayedImage: false, skipThreshold: CMTime(seconds: 20, preferredTimescale: 90000))
        let before = renderer.enqueueCount
        renderer.enqueue(pixelBuffer: try #require(makePixelBuffer()), pts: CMTime(seconds: 19.5, preferredTimescale: 90000))
        renderer.drainReorderBuffer()
        #expect(renderer.enqueueCount == before)
        renderer.enqueue(pixelBuffer: try #require(makePixelBuffer()), pts: CMTime(seconds: 20.1, preferredTimescale: 90000))
        renderer.drainReorderBuffer()
        #expect(renderer.enqueueCount == before + 1)
        #expect(renderer.framesBelowFloor == 0)
    }
}

/// A video decoder stand-in that records the packets it accepted, refusing the ones a flush has retired
/// the way the real decoders do. `flushOnDecodeOf` makes a recovery flush land inside the hand-off of
/// the n-th packet it is given.
private final class PacketRecordingDecoder: VideoDecodingPipeline, @unchecked Sendable {
    private let lock = NSLock()
    private var _epoch: UInt64 = 0
    private var _accepted: [(isKey: Bool, pts: Int64)] = []
    private var _seen = 0
    private var flushDuringPacket: Int?
    private var _flushes = 0
    var onFrame: DecodedFrameHandler?
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?
    var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
    var skipUntilPTS: CMTime?
    var feedEpoch: UInt64 { lock.lock(); defer { lock.unlock() }; return _epoch }
    var accepted: [(isKey: Bool, pts: Int64)] { lock.lock(); defer { lock.unlock() }; return _accepted }
    var seen: Int { lock.lock(); defer { lock.unlock() }; return _seen }
    var flushCount: Int { lock.lock(); defer { lock.unlock() }; return _flushes }
    func flushOnDecodeOf(packetNumber n: Int) { lock.lock(); flushDuringPacket = n; lock.unlock() }
    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {}
    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) {
        lock.lock(); defer { lock.unlock() }
        _seen += 1
        if flushDuringPacket == _seen { _epoch += 1 }
        if let epoch, epoch != _epoch { return }
        _accepted.append(((packet.pointee.flags & AV_PKT_FLAG_KEY) != 0, packet.pointee.pts))
    }
    func flush() { lock.lock(); _epoch += 1; _flushes += 1; lock.unlock() }
    func close() {}
}

/// A reader over in-memory data that blocks, once armed, any read from `blockFrom` bytes on until it is
/// released, so a session cannot reach the end of media while a test looks at the state it is in before
/// it. Before it is armed, or short of `blockFrom`, it behaves as `DataIOReader` does.
private final class GatedIOReader: IOReader, @unchecked Sendable {
    private let inner: DataIOReader
    private let blockFrom: Int
    private let condition = NSCondition()
    private var armed = false
    private var released = false
    private var position = 0
    private var _blockedReads = 0
    init(data: Data, blockFrom: Int) { inner = DataIOReader(data: data); self.blockFrom = blockFrom }
    /// Arms the gate; the open of the container reads around the file and must not block.
    func arm() { condition.lock(); armed = true; condition.unlock() }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    var blockedReads: Int { condition.lock(); defer { condition.unlock() }; return _blockedReads }
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        condition.lock()
        if armed, position >= blockFrom {
            _blockedReads += 1
            while !released { condition.wait(until: Date(timeIntervalSinceNow: 0.1)) }
            _blockedReads -= 1
        }
        condition.unlock()
        let n = inner.read(buffer, size: size)
        condition.lock()
        if n > 0 { position += Int(n) }
        condition.unlock()
        return n
    }
    func seek(offset: Int64, whence: Int32) -> Int64 {
        let result = inner.seek(offset: offset, whence: whence)
        if result >= 0, whence != 65536 { condition.lock(); position = Int(result); condition.unlock() }
        return result
    }
    func close() { inner.close() }
    func cancel() { release() }
}

/// The video fixture's first packet repeated `keyFlags.count` times, each flagged as a keyframe or not,
/// optionally with the audio fixture muxed in, so the demux loop meets delta frames where a test wants them.
private func syntheticVideoFixture(keyFlags: [Bool], withAudio: Bool = false) throws -> Data {
    let video = Demuxer()
    let audio = Demuxer()
    defer { video.close(); audio.close() }
    try video.open(reader: DataIOReader(data: ProbeTestFixtures.hdr10Plus()), formatHint: "mp4")
    try audio.open(reader: DataIOReader(data: ProbeTestFixtures.eac3()), formatHint: "mp4")
    let videoStream = try #require(video.stream(at: video.videoStreamIndex))
    let audioStream = try #require(audio.stream(at: audio.audioStreamIndex))
    let first = try #require(try video.readPacket())
    defer { var owned: UnsafeMutablePointer<AVPacket>? = first; trackedPacketFree(&owned) }

    var output: UnsafeMutablePointer<AVFormatContext>?
    try #require(avformat_alloc_output_context2(&output, nil, "mp4", nil) >= 0)
    let context = try #require(output)
    defer { avformat_free_context(context) }
    var io: UnsafeMutablePointer<AVIOContext>?
    try #require(avio_open_dyn_buf(&io) >= 0)
    let buffer = try #require(io)
    context.pointee.pb = buffer
    var bytes: UnsafeMutablePointer<UInt8>?
    var bufferClosed = false
    defer {
        if !bufferClosed { _ = avio_close_dyn_buf(buffer, &bytes) }
        av_free(bytes)
    }
    let sources = withAudio ? [videoStream, audioStream] : [videoStream]
    for source in sources {
        let target = try #require(avformat_new_stream(context, nil))
        try #require(avcodec_parameters_copy(target.pointee.codecpar, source.pointee.codecpar) >= 0)
        target.pointee.time_base = source.pointee.time_base
    }
    try #require(avformat_write_header(context, nil) >= 0)
    let videoTarget = try #require(context.pointee.streams[0])
    let tb = videoTarget.pointee.time_base
    let step = Int64(max(1, Int(tb.den) / max(1, Int(tb.num)) / 24))
    for (i, isKey) in keyFlags.enumerated() {
        let copy = try #require(av_packet_clone(first))
        var owned: UnsafeMutablePointer<AVPacket>? = copy
        defer { trackedPacketFree(&owned) }
        copy.pointee.stream_index = 0
        copy.pointee.pts = Int64(i) * step
        copy.pointee.dts = Int64(i) * step
        copy.pointee.duration = step
        copy.pointee.pos = -1
        if isKey { copy.pointee.flags |= AV_PKT_FLAG_KEY } else { copy.pointee.flags &= ~AV_PKT_FLAG_KEY }
        try #require(av_interleaved_write_frame(context, copy) >= 0)
    }
    if withAudio {
        let target = try #require(context.pointee.streams[1])
        while let packet = try audio.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            av_packet_rescale_ts(packet, audioStream.pointee.time_base, target.pointee.time_base)
            packet.pointee.stream_index = 1
            packet.pointee.pos = -1
            try #require(av_interleaved_write_frame(context, packet) >= 0)
        }
    }
    try #require(av_write_trailer(context) >= 0)
    let count = avio_close_dyn_buf(buffer, &bytes)
    bufferClosed = true
    context.pointee.pb = nil
    try #require(count > 0)
    return Data(bytes: try #require(bytes), count: Int(count))
}

@Suite("Flush recovery host", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct FlushRecoveryHostTests {

    final class Targets: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Double] = []
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }
        func add(_ v: Double) { lock.lock(); _values.append(v); lock.unlock() }
    }

    private func loadedHost(_ targets: Targets) async throws -> SoftwarePlaybackHost {
        let host = SoftwarePlaybackHost(reposition: { _, target, _, _, _ in
            targets.add(target)
            return .landed
        })
        let dem = Demuxer()
        try dem.open(reader: DataIOReader(data: ProbeTestFixtures.hdr10Plus()), formatHint: "mp4")
        do {
            try await host.load(demuxer: dem, startPosition: nil, audioSourceStreamIndex: nil)
            return host
        } catch { host.stop(); throw error }
    }

    private func loadedHost(data: Data) async throws -> SoftwarePlaybackHost {
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in .landed })
        let dem = Demuxer()
        try dem.open(reader: DataIOReader(data: data), formatHint: "mp4")
        do {
            try await host.load(demuxer: dem, startPosition: nil, audioSourceStreamIndex: nil)
            return host
        } catch { host.stop(); throw error }
    }

    /// A frame in the video queue, so the host sees a session that has presented something.
    private func presentFrame(_ host: SoftwarePlaybackHost, at seconds: Double = 0) throws {
        let renderer = host.videoRendererForTesting
        renderer.enqueue(pixelBuffer: try #require(makePixelBuffer()),
                         pts: CMTime(seconds: seconds, preferredTimescale: 90000))
        renderer.drainReorderBuffer()
        try #require(renderer.acceptedFrameCount > 0)
    }

    /// A decoder in the host that produces no frames and counts nothing: the demux loop would otherwise read the
    /// fixture again after a reposition and might present it, and these tests only want what they hand the queue.
    @discardableResult
    private func installQuietDecoder(_ host: SoftwarePlaybackHost) -> PacketRecordingDecoder {
        let decoder = PacketRecordingDecoder()
        host.setVideoDecoderForTesting(decoder)
        return decoder
    }

    @Test("before a frame is presented a video trigger changes nothing")
    func notPresented() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .ignore)
        #expect(host.flushRecoveryLog.isEmpty)
        #expect(targets.values.isEmpty)
    }

    @Test("a keyframe inside the audio lead: the audio plays on, the video queue and decoder are flushed, no seek")
    func keyframeInsideLeadFlushesOnly() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        let decoder = installQuietDecoder(host)
        try presentFrame(host)
        host.seekClockForTesting(to: 20)
        host.setAudioFedUntilForTesting(30)          // lead 10 s
        host.keyframeLedgerForTesting.noteKeyframeRead(pts: 24)   // gap 4 s
        let generation = host.videoRendererForTesting.flushGeneration

        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .flushVideoOnly)
        // Synchronous: a flush spawns no seek, so none is pending and none can land later.
        #expect(!host.recoveryPendingForTesting)
        #expect(targets.values.isEmpty)
        #expect(host.flushRecoveriesCompleted == 0)

        #expect(host.videoRendererForTesting.flushGeneration > generation)
        // The decoder was flushed, which is what "resumes at the next keyframe" rests on.
        #expect(decoder.flushCount == 1)
        #expect(decoder.feedEpoch > 0)
        // The floor restarts at the playhead, not at whatever frame arrives first.
        #expect(decoder.skipUntilPTS.map { abs($0.seconds - 20) < 0.01 } == true)
        #expect(host.flushRecoveryLog.map(\.action) == [.flushVideoOnly])
    }

    @Test("a keyframe beyond the audio lead: the session goes back to the playhead")
    func keyframeBeyondLeadRepositions() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        let decoder = installQuietDecoder(host)
        try presentFrame(host)
        host.seekClockForTesting(to: 20)
        host.setAudioFedUntilForTesting(23)          // lead 3 s
        host.keyframeLedgerForTesting.noteKeyframeRead(pts: 29)   // gap 9 s
        let generation = host.videoRendererForTesting.flushGeneration

        #expect(host.handleFlushTrigger(.videoQueueFailed) == .reposition)
        #expect(host.recoveryPendingForTesting)
        // Further reports of the same event are ignored while it runs.
        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .ignore)
        try await waitFor { host.flushRecoveriesCompleted == 1 }

        let target = try #require(targets.values.first)
        #expect(targets.values.count == 1)
        #expect(abs(target - 20) < 0.05)
        #expect(host.videoRendererForTesting.flushGeneration > generation)
        #expect(decoder.flushCount >= 1)
        #expect(host.failure == nil)
    }

    @Test("no keyframe read yet counts as beyond the lead")
    func noKeyframeRepositions() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        try presentFrame(host)
        host.seekClockForTesting(to: 20)
        host.setAudioFedUntilForTesting(100)
        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .reposition)
        try await waitFor { host.flushRecoveriesCompleted == 1 }
        #expect(targets.values.count == 1)
    }

    @Test("a queue the system keeps failing: the reposition degrades to a flush, which is not repeated, until a frame gets through")
    func stormDegrades() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        // The fixture is two keyframes at the start of a short clip; after the reposition to 20 s the
        // demux loop would read it again and might present them. Nothing may reach the queue here
        // except what the test hands it, so the decoder is a stand-in that produces no frames.
        installQuietDecoder(host)
        host.setRepositionBackoffForTesting(0)
        try presentFrame(host)
        host.seekClockForTesting(to: 20)
        #expect(host.handleFlushTrigger(.videoQueueFailed) == .reposition)
        try await waitFor { host.flushRecoveriesCompleted == 1 }

        // Nothing was presented after it: it did not help.
        #expect(host.handleFlushTrigger(.videoQueueFailed) == .flushVideoOnly)
        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .ignore)
        #expect(host.handleFlushTrigger(.videoQueueFailed) == .ignore)
        #expect(targets.values.count == 1)

        // A frame that was handed over but that the clock has not reached is not evidence yet.
        try presentFrame(host, at: 25)
        host.seekClockForTesting(to: 21)
        #expect(host.handleFlushTrigger(.videoQueueFailed) == .ignore)

        // The clock passes a frame with the queue healthy: the next failure is a new episode.
        host.seekClockForTesting(to: 26)
        // The reposition to 20 s restarted the demux loop on a clip two seconds long, which hands the
        // ledger keyframes far below the clock. They are not what this test is about: no keyframe is
        // parked, so the only thing between this trigger and a reposition is the storm rule.
        host.keyframeLedgerForTesting.reset()
        #expect(host.handleFlushTrigger(.videoQueueFailed) == .reposition)
        try await waitFor { host.flushRecoveriesCompleted == 2 }
        #expect(host.flushRecoveryLog.map(\.action) == [.reposition, .flushVideoOnly, .reposition])
    }

    @Test("a frame refused by the queue after the enqueue returned does not count as presented")
    func refusedFrameIsNotPresented() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        installQuietDecoder(host)
        host.setRepositionBackoffForTesting(0)
        try presentFrame(host)
        host.seekClockForTesting(to: 20)
        #expect(host.handleFlushTrigger(.videoQueueFailed) == .reposition)
        try await waitFor { host.flushRecoveriesCompleted == 1 }

        // A frame goes in, the queue then reports it needs a flush again: the clock passing the frame
        // proves nothing, since the system never showed it.
        try presentFrame(host, at: 21)
        host.seekClockForTesting(to: 22)
        let renderer = host.videoRendererForTesting
        renderer.queueNeedsFlushForTesting = { true }
        defer { renderer.queueNeedsFlushForTesting = nil }
        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .flushVideoOnly)
        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .ignore)
    }

    @Test("a reposition is not repeated inside the backoff even when frames got through in between")
    func repositionBackoff() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        installQuietDecoder(host)
        try presentFrame(host)
        host.seekClockForTesting(to: 20)
        #expect(host.handleFlushTrigger(.videoQueueFailed) == .reposition)
        try await waitFor { host.flushRecoveriesCompleted == 1 }
        try presentFrame(host, at: 21)
        host.seekClockForTesting(to: 22)
        // A frame got through, so the storm rule is satisfied; with no keyframe parked (the demux loop
        // restarted on the short clip and left some far below the clock) only the backoff holds the
        // reposition back.
        host.keyframeLedgerForTesting.reset()
        #expect(host.handleFlushTrigger(.videoQueueFailed) == .flushVideoOnly)
        #expect(targets.values.count == 1)
    }

    @Test("a live source with no rewind ring only flushes, however far the keyframe is")
    func liveOnlyFlushes() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        host.setLiveForTesting(true)
        try presentFrame(host)
        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .flushVideoOnly)
        #expect(!host.recoveryPendingForTesting)
        #expect(targets.values.isEmpty)
        #expect(host.flushRecoveriesCompleted == 0)
    }

    @Test("the renderer's report reaches the host's rule")
    func rendererReportReachesHost() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        try presentFrame(host)
        host.seekClockForTesting(to: 20)
        host.setAudioFedUntilForTesting(25)
        host.keyframeLedgerForTesting.noteKeyframeRead(pts: 60)
        host.videoRendererForTesting.reportQueueFlushForTesting(.requiresFlush)
        try await waitFor { host.flushRecoveriesCompleted == 1 }
        #expect(host.flushRecoveryLog.first?.trigger == .videoQueueRequiresFlush)
        #expect(targets.values.count == 1)
    }

    @Test("a video failure in the background is paid on the foreground return, by the same rule")
    func backgroundDefers() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        let decoder = installQuietDecoder(host)
        try presentFrame(host)
        host.enterBackgroundAudioOnly()
        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .deferToForeground)
        #expect(host.videoQueueFlushOwedForTesting)
        #expect(!host.recoveryPendingForTesting)
        #expect(host.flushRecoveriesCompleted == 0)

        // Back in front with no keyframe read yet: the picture would stay frozen past the audio lead.
        host.exitBackgroundAudioOnly()
        #expect(!host.videoQueueFlushOwedForTesting)
        #expect(decoder.flushCount >= 1)
        try await waitFor { host.flushRecoveriesCompleted == 1 }
        #expect(host.flushRecoveryLog.map(\.action) == [.deferToForeground, .reposition])
    }

    @Test("back in front with a keyframe inside the audio lead the picture just waits for it")
    func foregroundReturnInsideLead() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        try presentFrame(host)
        host.seekClockForTesting(to: 20)
        host.enterBackgroundAudioOnly()
        #expect(host.handleFlushTrigger(.videoQueueFailed) == .deferToForeground)
        host.setAudioFedUntilForTesting(30)
        host.keyframeLedgerForTesting.noteKeyframeRead(pts: 22)
        host.exitBackgroundAudioOnly()
        #expect(!host.recoveryPendingForTesting)
        #expect(targets.values.isEmpty)
        #expect(host.flushRecoveryLog.map(\.action) == [.deferToForeground, .flushVideoOnly])
    }

    @Test("the audio renderer flushing itself is left to AE#549: no recovery of any kind")
    func audioFlushIsNotATrigger() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        try presentFrame(host)
        let renderer = try #require(host.audioRendererForTesting)
        NotificationCenter.default.post(
            name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer,
            userInfo: [AVSampleBufferAudioRendererFlushTimeKey:
                        NSValue(time: CMTime(seconds: 3, preferredTimescale: 48000))])
        // The AudioOutput's count is the witness that the renderer's notification was handled; the host
        // hears nothing from it, so its log has to stay empty once the witness has landed.
        try await waitFor { host.audioAutomaticFlushCountForTesting == 1 }
        #expect(host.flushRecoveryLog.isEmpty)
        #expect(targets.values.isEmpty)
    }

    @Test("the status poll acts once when the audio renderer fails, again only after it recovered and failed anew")
    func audioStatusPoll() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        host.pollAudioRendererStatus(.rendering)
        #expect(host.flushRecoveryLog.isEmpty)
        host.pollAudioRendererStatus(.failed)
        host.pollAudioRendererStatus(.failed)
        host.pollAudioRendererStatus(.failed)
        #expect(host.flushRecoveryLog.map(\.action) == [.flushAudioOnly])
        host.pollAudioRendererStatus(.unknown)
        host.pollAudioRendererStatus(.failed)
        #expect(host.flushRecoveryLog.map(\.action) == [.flushAudioOnly, .flushAudioOnly])
        #expect(host.flushRecoveryLog.allSatisfy { $0.trigger == .audioRendererFailed })
        #expect(!host.recoveryPendingForTesting)
        #expect(targets.values.isEmpty)
    }

    @Test("a renderer that fails again and again is flushed three times and then left alone")
    func audioStatusPollStorm() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        for _ in 0..<(FlushRecoveryPolicy.maxAudioFlushesPerWindow + 3) {
            host.pollAudioRendererStatus(.failed)
            host.pollAudioRendererStatus(.unknown)
        }
        #expect(host.flushRecoveryLog.count == FlushRecoveryPolicy.maxAudioFlushesPerWindow)
        #expect(host.flushRecoveryLog.allSatisfy { $0.action == .flushAudioOnly })
    }

    @Test("an audio failure that begins while the rule ignores triggers is acted on once the recovery in the way is over")
    func audioFailureNotLostWhileIgnored() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        installQuietDecoder(host)
        try presentFrame(host)
        host.seekClockForTesting(to: 20)
        // A video reposition is under way; every trigger is ignored until it ends.
        #expect(host.handleFlushTrigger(.videoQueueFailed) == .reposition)
        #expect(host.recoveryPendingForTesting)
        host.pollAudioRendererStatus(.failed)
        host.pollAudioRendererStatus(.failed)
        #expect(host.flushRecoveryLog.map(\.action) == [.reposition])

        try await waitFor { host.flushRecoveriesCompleted == 1 }
        // The renderer is still failed: the next poll offers the failure again and it is taken, once.
        host.pollAudioRendererStatus(.failed)
        host.pollAudioRendererStatus(.failed)
        #expect(host.flushRecoveryLog.map(\.action) == [.reposition, .flushAudioOnly])
    }

    @Test("flushing the audio queue retires the diagnostic's audio marker, including the stale value the loop republishes")
    func audioFlushResetsLeadMarker() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        host.setAudioFedUntilUnderCurrentGenerationForTesting(30)
        #expect(host.audioFedUntilForTesting == 30)
        host.pollAudioRendererStatus(.failed)
        #expect(host.flushRecoveryLog.map(\.action) == [.flushAudioOnly])
        #expect(host.audioFedUntilForTesting.isNaN)
        // The demux loop writes its own marker every iteration; the one it still holds is the flushed audio.
        host.setAudioFedUntilUnderCurrentGenerationForTesting(30)
        #expect(host.audioFedUntilForTesting.isNaN)
        host.setAudioFedUntilUnderCurrentGenerationForTesting(31.5)
        #expect(host.audioFedUntilForTesting == 31.5)
    }

    @Test("after a plain recovery flush the demux loop hands the decoder no delta frame before the next keyframe")
    func noDeltaFramesAfterRecoveryFlush() async throws {
        // delta, delta, delta, KEY, delta, delta: the demuxer stands in the middle of a group of pictures.
        let data = try syntheticVideoFixture(keyFlags: [false, false, false, true, false, false])
        let host = try await loadedHost(data: data)
        defer { host.stop() }
        let decoder = PacketRecordingDecoder()
        host.setVideoDecoderForTesting(decoder)
        try presentFrame(host)
        host.seekClockForTesting(to: 0)
        host.setAudioFedUntilForTesting(10)
        host.keyframeLedgerForTesting.noteKeyframeRead(pts: 0.5)
        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .flushVideoOnly)
        #expect(host.keyframeLedgerForTesting.isAwaitingKeyframe)

        host.play()
        try await waitFor { decoder.accepted.count == 3 }
        // The keyframe and what follows it, and nothing before.
        #expect(decoder.accepted.map(\.isKey) == [true, false, false])
        #expect(!host.keyframeLedgerForTesting.isAwaitingKeyframe)
    }

    @Test("the same on the decoupled route, where the packets are parked first")
    func noDeltaFramesAfterRecoveryFlushDecoupled() async throws {
        let data = try syntheticVideoFixture(keyFlags: [false, false, false, true, false, false], withAudio: true)
        let host = try await loadedHost(data: data)
        defer { host.stop() }
        let decoder = PacketRecordingDecoder()
        host.setVideoDecoderForTesting(decoder)
        try presentFrame(host)
        host.seekClockForTesting(to: 0)
        host.setAudioFedUntilForTesting(10)
        host.keyframeLedgerForTesting.noteKeyframeRead(pts: 0.5)
        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .flushVideoOnly)

        host.play()
        try await waitFor { decoder.accepted.count == 3 }
        #expect(decoder.accepted.map(\.isKey) == [true, false, false])
    }

    @Test("a flush that lands while the keyframe is being handed over does not end the wait: the next delta frames are dropped")
    func flushDuringHandOverKeepsGate() async throws {
        // delta, KEY(refused: a flush lands in its hand-off), delta, delta, KEY, delta.
        let data = try syntheticVideoFixture(keyFlags: [false, true, false, false, true, false])
        let host = try await loadedHost(data: data)
        defer { host.stop() }
        let decoder = PacketRecordingDecoder()
        decoder.flushOnDecodeOf(packetNumber: 1)   // the first packet the gate lets through: packet 2 of the stream
        host.setVideoDecoderForTesting(decoder)
        try presentFrame(host)
        host.seekClockForTesting(to: 0)
        host.setAudioFedUntilForTesting(10)
        host.keyframeLedgerForTesting.noteKeyframeRead(pts: 0.5)
        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .flushVideoOnly)

        host.play()
        try await waitFor { decoder.accepted.count == 2 }
        // Only the second keyframe and its follower reached the decoder; the first keyframe was lost to the
        // flush and the two delta frames behind it were not handed over.
        #expect(decoder.accepted.map(\.isKey) == [true, false])
        #expect(decoder.seen == 3)
    }

    @Test("video dropped in the background takes the parked keyframes with it, so the owed recovery sees the hole")
    func backgroundDropFreesLedger() async throws {
        // A long clip, read through a source that stops answering half way: the end of media also frees what
        // is parked, and would pass this test with the background drop taken out.
        let data = try syntheticVideoFixture(keyFlags: (0..<8000).map { $0 % 30 == 0 }, withAudio: true)
        let reader = GatedIOReader(data: data, blockFrom: data.count / 2)
        let dem = Demuxer()
        try dem.open(reader: reader, formatHint: "mp4")
        reader.arm()
        let host = SoftwarePlaybackHost(reposition: { _, _, _, _, _ in .landed })
        defer { reader.release(); host.stop() }
        do { try await host.load(demuxer: dem, startPosition: nil, audioSourceStreamIndex: nil) }
        catch { host.stop(); throw error }
        let decoder = PacketRecordingDecoder()
        host.setVideoDecoderForTesting(decoder)
        try presentFrame(host)
        host.seekClockForTesting(to: 20)
        host.setAudioFedUntilForTesting(30)
        host.enterBackgroundAudioOnly()
        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .deferToForeground)
        // A keyframe that was parked when the background began and sits below the clock: left standing it
        // reads as "a keyframe is at hand", a gap of zero.
        host.keyframeLedgerForTesting.noteKeyframeRead(pts: 3)

        host.play()
        try await waitFor { host.keyframeLedgerForTesting.nextKeyframe == nil }
        // Judged while the source is held short of its end.
        try await waitFor { reader.blockedReads >= 1 }
        #expect(decoder.seen == 0)
        host.exitBackgroundAudioOnly()
        #expect(host.flushRecoveryLog.map(\.action) == [.deferToForeground, .reposition])
    }

    /// A recovery, then `frames` frames handed to the healthy queue and passed by the clock, left for the
    /// host's own tick to count: nothing here samples the count by hand.
    private func healthyPlaybackAfterRecovery(_ host: SoftwarePlaybackHost, from start: Double, frames: Int = 4) async throws {
        let renderer = host.videoRendererForTesting
        for i in 0..<frames { try presentFrame(host, at: start + Double(i) * 0.04) }
        try #require(renderer.pendingPresentationCountForTesting > 0)
        host.seekClockForTesting(to: start + 1)
        // The host's tick counts the frames the clock passed; a hang is the suite's time limit.
        try await waitFor { renderer.pendingPresentationCountForTesting == 0 }
    }

    @Test("after a recovery, healthy playback counts as presented: a later notification with the queue needing a flush recovers again, round after round")
    func playbackAfterRecoveryCountsNotification() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        installQuietDecoder(host)
        host.setRepositionBackoffForTesting(0)
        try presentFrame(host)
        host.seekClockForTesting(to: 20)
        #expect(host.handleFlushTrigger(.videoQueueFailed) == .reposition)
        try await waitFor { host.flushRecoveriesCompleted == 1 }

        let renderer = host.videoRendererForTesting
        defer { renderer.queueNeedsFlushForTesting = nil }
        for round in 1...2 {
            try await healthyPlaybackAfterRecovery(host, from: 21 + Double(round) * 10)
            // The queue is now flagged, as it is when the system's notification reaches the host.
            renderer.queueNeedsFlushForTesting = { true }
            host.keyframeLedgerForTesting.reset()
            #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .reposition)
            renderer.queueNeedsFlushForTesting = nil
            try await waitFor { host.flushRecoveriesCompleted == round + 1 }
        }
        #expect(host.flushRecoveryLog.map(\.action) == [.reposition, .reposition, .reposition])
    }

    @Test("after a recovery, healthy playback counts as presented: a later failure found at the enqueue recovers again")
    func playbackAfterRecoveryCountsEnqueue() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        defer { host.stop() }
        installQuietDecoder(host)
        host.setRepositionBackoffForTesting(0)
        try presentFrame(host)
        host.seekClockForTesting(to: 20)
        #expect(host.handleFlushTrigger(.videoQueueFailed) == .reposition)
        try await waitFor { host.flushRecoveriesCompleted == 1 }

        try await healthyPlaybackAfterRecovery(host, from: 21)
        host.keyframeLedgerForTesting.reset()
        // The enqueue meets a queue that needs a flush: the renderer flushes it, drops the frames it was
        // tracking and reports. The report is handled on the main actor once this test suspends, by which
        // time the queue is healthy again.
        let renderer = host.videoRendererForTesting
        renderer.queueNeedsFlushForTesting = { true }
        renderer.enqueue(pixelBuffer: try #require(makePixelBuffer()), pts: CMTime(seconds: 23, preferredTimescale: 90000))
        renderer.drainReorderBuffer()
        renderer.queueNeedsFlushForTesting = nil
        try await waitFor { host.flushRecoveryLog.count == 2 }
        #expect(host.flushRecoveryLog.map(\.action) == [.reposition, .reposition])
        try await waitFor { host.flushRecoveriesCompleted == 2 }
    }

    @Test("a keyframe held by back-pressure across a recovery flush is still handed over: the decoder is not refused it, the gate is not raised again")
    func keyframeHeldAcrossRecoveryFlush() async throws {
        // KEY, delta, delta, KEY, delta, delta. The first keyframe is held in the back-pressure wait.
        let data = try syntheticVideoFixture(keyFlags: [true, false, false, true, false, false])
        let host = try await loadedHost(data: data)
        defer { host.stop() }
        let decoder = PacketRecordingDecoder()
        host.setVideoDecoderForTesting(decoder)
        try presentFrame(host)
        host.seekClockForTesting(to: 0)
        let renderer = host.videoRendererForTesting
        renderer.readyForMoreMediaDataForTesting = { false }
        defer { renderer.readyForMoreMediaDataForTesting = nil }
        host.play()
        // The packet is parked in the ledger once it has been read, which is after its epoch was.
        try await waitFor { host.keyframeLedgerForTesting.nextKeyframe != nil }
        // A recovery flush as the host makes it, while the packet is held.
        decoder.flush()
        host.keyframeLedgerForTesting.requireKeyframe()
        renderer.readyForMoreMediaDataForTesting = nil

        try await waitFor { decoder.accepted.count == 6 }
        #expect(decoder.accepted.map(\.isKey) == [true, false, false, true, false, false])
    }

    @Test("a stopped session ignores a late report")
    func stoppedIgnores() async throws {
        let targets = Targets()
        let host = try await loadedHost(targets)
        try presentFrame(host)
        host.stop()
        #expect(host.handleFlushTrigger(.videoQueueRequiresFlush) == .ignore)
        #expect(host.flushRecoveryLog.isEmpty)
    }
}
