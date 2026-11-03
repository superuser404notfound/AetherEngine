#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
import AetherLibavformat
import AetherLibavcodec
@_spi(Diagnostics) @testable import AetherEngine

/// A base-layer frame whose enhancement layer is missing or late is released by its presentation
/// deadline against the render clock, not by a count of newer base frames, and at once when the access
/// unit carried no enhancement layer. Everything is synthetic: tagged pixel buffers into the frame
/// handlers, a recording composer, an injected clock and uptime, no media and no GPU.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct DualLayerDeadlineBypassTests {

    // MARK: - Fixtures

    private static let frame = 1.0 / 24
    private static var margin: Double { max(Double(DualLayerVideoDecoder.deadlineMarginFrames) * frame, DualLayerVideoDecoder.deadlineMarginFloor) }
    /// Longer than the grace a waiting frame is given at 24 fps (one interval, 41.7 ms).
    private static let pastGrace = 0.05

    private static func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                                         &out)
        return status == kCVReturnSuccess ? out : nil
    }
    private static func baseLayer() throws -> CVPixelBuffer { try #require(buffer(width: 64, height: 64)) }
    private static func enhancementLayer() throws -> CVPixelBuffer { try #require(buffer(width: 32, height: 32)) }

    private static func params() -> DoviMetalParams {
        var p = DoviMetalParams()
        p.blWidth = 64; p.blHeight = 64; p.elWidth = 32; p.elHeight = 32
        return p
    }

    /// 24 fps at 90 kHz, offset so the frames sit well ahead of a clock at 0.
    private static func pts(_ frameNumber: Int64) -> CMTime { CMTime(value: frameNumber * 3750, timescale: 90000) }

    private struct Pair { let base: CVPixelBuffer; let enhancement: CVPixelBuffer }

    private final class RecordingComposer: FelComposing, @unchecked Sendable {
        private let lock = NSLock()
        private var _pairs: [Pair] = []
        var pairs: [Pair] { lock.lock(); defer { lock.unlock() }; return _pairs }
        func acquireSlot() {}
        func releaseSlot() {}
        func flush() {}
        func composeAsync(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer, params: DoviMetalParams,
                          frameIndex: UInt32, completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            composeAsyncWithAcquiredSlot(baseBuffer: baseBuffer, enhancementBuffer: enhancementBuffer,
                                         params: params, frameIndex: frameIndex, completion: completion)
        }
        func composeAsyncWithAcquiredSlot(baseBuffer: CVPixelBuffer, enhancementBuffer: CVPixelBuffer,
                                          params: DoviMetalParams, frameIndex: UInt32,
                                          completion: @escaping @Sendable (CVPixelBuffer?) -> Void) {
            lock.lock(); _pairs.append(Pair(base: baseBuffer, enhancement: enhancementBuffer)); lock.unlock()
            completion(baseBuffer)
        }
    }

    private final class FakeSession: SingleLayerVideoDecoder, @unchecked Sendable {
        var onFrame: DecodedFrameHandler?
        var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
        var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?
        var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
        var skipUntilPTS: CMTime?
        var feedEpoch: UInt64 = 0
        func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {}
        func open(parameterSets: [[UInt8]], timeBase: AVRational, onFrame: @escaping DecodedFrameHandler) throws {}
        func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?) {}
        func flush() {}
        func close() {}
    }

    private final class Deliveries: @unchecked Sendable {
        struct Frame { let buffer: CVPixelBuffer; let pts: CMTime }
        private let lock = NSLock()
        private var frames: [Frame] = []
        func record(_ buffer: CVPixelBuffer, _ pts: CMTime) { lock.lock(); frames.append(Frame(buffer: buffer, pts: pts)); lock.unlock() }
        var all: [Frame] { lock.lock(); defer { lock.unlock() }; return frames }
        var count: Int { all.count }
    }

    /// A clock and an uptime the test moves by hand.
    private final class Clocks: @unchecked Sendable {
        private let lock = NSLock()
        private var _seconds = 0.0, _running = true, _prerolling = false, _uptime = 1000.0
        var prerolling: Bool { get { lock.lock(); defer { lock.unlock() }; return _prerolling } set { lock.lock(); _prerolling = newValue; lock.unlock() } }
        var seconds: Double { get { lock.lock(); defer { lock.unlock() }; return _seconds } set { lock.lock(); _seconds = newValue; lock.unlock() } }
        var running: Bool { get { lock.lock(); defer { lock.unlock() }; return _running } set { lock.lock(); _running = newValue; lock.unlock() } }
        var uptime: Double { get { lock.lock(); defer { lock.unlock() }; return _uptime } set { lock.lock(); _uptime = newValue; lock.unlock() } }
    }

    private struct Rig {
        let decoder: DualLayerVideoDecoder
        let composer: RecordingComposer
        let deliveries: Deliveries
        let clocks: Clocks
    }

    private static func rig(withClock: Bool = true, running: Bool = true, frameRate: Double = 24) -> Rig {
        let composer = RecordingComposer()
        let deliveries = Deliveries()
        let clocks = Clocks()
        clocks.running = running
        let decoder = DualLayerVideoDecoder(composer: composer, primaryDecoder: FakeSession(), enhancementDecoder: FakeSession())
        decoder.onFrame = { buffer, pts, _ in deliveries.record(buffer, pts) }
        decoder.primeForTesting(enhancementLayer: true)
        decoder.uptimeProvider = { clocks.uptime }
        if withClock {
            decoder.setRenderClock({ RenderClockSample(seconds: clocks.seconds, running: clocks.running, prerolling: clocks.prerolling) }, frameRate: frameRate)
        }
        return Rig(decoder: decoder, composer: composer, deliveries: deliveries, clocks: clocks)
    }

    private typealias RenderClockSample = DualLayerVideoDecoder.RenderClockSample

    private static func feedBase(_ r: Rig, _ n: Int64) throws -> CVPixelBuffer {
        r.decoder.seedRPUForTesting(pts: pts(n), params: params(), displayMetadataNAL: nil)
        let bl = try baseLayer()
        r.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: pts(n), hdr10Data: nil)
        return bl
    }

    // MARK: - 1. Enhancement layer known absent

    @Test("an access unit with no enhancement layer goes out as its base layer on arrival, with no hold at all")
    func absentEnhancementLayerBypassesAtOnce() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        // Every frame is far ahead of the clock (10 s): a deadline rule would hold each of them.
        r.clocks.seconds = 0
        var sent: [CVPixelBuffer] = []
        let count = 12   // more than the count rule and the deadline backstop together
        for i in 0..<Int64(count) {
            r.decoder.noteEnhancementAbsentForTesting(pts: Self.pts(240 + i))
            sent.append(try Self.feedBase(r, 240 + i))
            #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0, "frame \(i) must not wait")
        }
        try await waitFor { r.deliveries.count == count }
        #expect(r.composer.pairs.isEmpty)
        #expect(zip(r.deliveries.all, sent).allSatisfy { $0.buffer === $1 })
    }

    @Test("a frame whose access unit did carry an enhancement layer is not treated as absent")
    func presentEnhancementLayerStillPairs() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        r.decoder.noteEnhancementAbsentForTesting(pts: Self.pts(241))
        let el = try Self.enhancementLayer()
        r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(240))
        let bl = try Self.feedBase(r, 240)
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.composer.pairs.first?.base === bl && r.composer.pairs.first?.enhancement === el)
    }

    // MARK: - 2. Late enhancement layer inside the margin stays paired

    @Test("an enhancement layer that lags its base layer, inside the margin, pairs; nothing is released early")
    func lagInsideMarginStaysPaired() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        // Clock at 10.0 s; frames 10.0 + 0.25 s ahead (6 frames), margin 3 frames.
        r.clocks.seconds = 10
        let first: Int64 = 240 + 6
        var bases: [CVPixelBuffer] = [], enhancements: [CVPixelBuffer] = []
        // Base frames arrive first and the clock keeps moving; more arrivals than the old count rule
        // (3) tolerated, all still ahead of their deadline.
        for i in 0..<Int64(5) {
            bases.append(try Self.feedBase(r, first + i))
            r.clocks.seconds += 0.001
        }
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 5, "5 newer arrivals, deadlines not reached: all wait")
        for i in 0..<Int64(5) {
            let el = try Self.enhancementLayer()
            enhancements.append(el)
            r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(first + i))
        }
        try await waitFor { r.deliveries.count == 5 }
        let pairs = r.composer.pairs
        #expect(pairs.count == 5)
        #expect(zip(pairs, zip(bases, enhancements)).allSatisfy { $0.base === $1.0 && $0.enhancement === $1.1 })
    }

    @Test("a frame whose enhancement layer never comes is released exactly when its deadline less the margin is reached")
    func releasedAtTheDeadline() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let n: Int64 = 252   // 10.5 s
        let due = Self.pts(n).seconds - Self.margin
        r.clocks.seconds = due - 0.010
        let bl = try Self.feedBase(r, n)
        r.clocks.uptime += Self.pastGrace
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1, "10 ms short of the release time")
        r.clocks.seconds = due
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0)
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.deliveries.all.first?.buffer === bl)
        #expect(r.composer.pairs.isEmpty)
    }

    @Test("a waiting frame is due when a frame behind it in delivery order is due, because that frame cannot show first")
    func deadlineIsTheEarliestBehindIt() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        // Decode order A (frame 252) then B (frame 249): B shows first but queues behind A's ticket.
        let a: Int64 = 252, b: Int64 = 249
        let a0 = try Self.feedBase(r, a)
        let el = try Self.enhancementLayer()
        r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(b))
        let b0 = try Self.feedBase(r, b)   // pairs at once and composes
        r.clocks.uptime += Self.pastGrace
        // A's own deadline is 3 frames later than B's; B's is what matters.
        let dueB = Self.pts(b).seconds - Self.margin
        r.clocks.seconds = dueB - 0.010
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1)
        r.clocks.seconds = dueB
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0)
        try await waitFor { r.deliveries.count == 2 }
        #expect(r.deliveries.all.map(\.buffer) == [a0, b0], "ticket order is kept")
    }

    @Test("the timer releases a waiting frame with no further arrival")
    func timerReleasesWithoutArrivals() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let n: Int64 = 252
        r.clocks.seconds = Self.pts(n).seconds - Self.margin - 0.5
        _ = try Self.feedBase(r, n)
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1)
        r.clocks.uptime += Self.pastGrace
        r.clocks.seconds = Self.pts(n).seconds - Self.margin
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0)
    }

    @Test("without a render clock the count rule is unchanged")
    func countRuleWithoutClock() async throws {
        let r = Self.rig(withClock: false)
        defer { r.decoder.close() }
        let k = Int64(DualLayerVideoDecoder.maxLayerSkewFrames)
        for i in 0...k { _ = try Self.feedBase(r, 240 + i) }
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == Int(k))
    }

    @Test("a running clock bounds the wait by the backstop below the stall threshold, however far the deadline")
    func backstopBoundsTheQueue() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        r.clocks.seconds = 0
        let hold = DualLayerVideoDecoder.maxDeadlineHoldFrames
        var sent: [CVPixelBuffer] = []
        for i in 0..<Int64(hold + 6) {
            sent.append(try Self.feedBase(r, 2400 + i))
            let released = max(0, Int(i) - hold + 1)
            // The frame that has seen `hold` newer arrivals goes out base-only under its own ticket,
            // one per arrival from then on; the queue never holds more than `hold`.
            try await waitFor { r.deliveries.count == released }
            #expect(r.decoder.stateSnapshotForTesting.blQueueCount == Int(i) + 1 - released)
            #expect(r.decoder.stateSnapshotForTesting.blQueueCount <= hold)
        }
        #expect(zip(r.deliveries.all, sent).allSatisfy { $0.buffer === $1 }, "released in ticket order")
        #expect(r.composer.pairs.isEmpty)
        // And the backstop sits below the point where delivery would skip the missing ticket.
        let stall = DoviFelComposer.maxFramesInFlight + DualLayerVideoDecoder.maxLayerSkewFrames + 2
        #expect(hold + 2 <= stall + 1, "delivery skips a ticket past \(stall) pending; the backstop holds back at most \(hold)")
    }

    // MARK: - 3. Preroll after a seek

    @Test("with the clock held for a preroll, a frame waiting on its enhancement layer is released after the margin, not after the preroll timeout")
    @MainActor func prerollCompletesWithoutTheTimeout() async throws {
        let r = Self.rig(running: false)
        r.clocks.prerolling = true
        defer { r.decoder.close() }
        let renderer = SampleBufferRenderer()
        renderer.setFELLookahead(enabled: true, frameRate: 24)
        renderer.setArrivalOrderHandover(frameRate: 24)
        // The seek lands at 20.0 s with the clock held at rate 0. Frame 1's enhancement layer is lost;
        // its neighbours pair.
        let first: Int64 = 480
        let target = Self.pts(first).seconds
        r.clocks.seconds = target
        var delivered = 0
        func handOver() {
            let all = r.deliveries.all
            for f in all.dropFirst(delivered) { renderer.enqueue(pixelBuffer: f.buffer, pts: f.pts) }
            delivered = all.count
        }
        for i in [0, 2, 3, 4, 5] as [Int64] {
            let el = try Self.enhancementLayer()
            r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(first + i))
            _ = try Self.feedBase(r, first + i)
        }
        // Frame 1 arrives last, with no partner, as if the other layer's frame was dropped in the flush.
        _ = try Self.feedBase(r, first + 1)
        try await waitFor { r.deliveries.count >= 1 }
        handOver()
        #expect(renderer.prerollSatisfied(clock: target, live: false) == false, "the hole at frame 1 holds the gate shut")
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1)

        // Wall time passes by the margin; nothing else arrives and the gate admits nothing.
        r.clocks.uptime += Self.margin - 0.001
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1, "inside the margin the late layer may still come")
        r.clocks.uptime += 0.001
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0)
        try await waitFor { r.deliveries.count == 6 }
        handOver()
        #expect(renderer.prerollSatisfied(clock: target, live: false) == true)
        #expect(Self.margin < AudioOutput.prerollTimeout / 10, "an order of magnitude inside the 2 s timeout")
    }

    // MARK: - 4. Absence note against queued enhancement frames and reordered streams

    @Test("an absence noted for a key whose enhancement frame is already queued still pairs, and the note is consumed")
    func queuedEnhancementFrameWinsOverAbsenceNote() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        r.decoder.noteEnhancementAbsentForTesting(pts: Self.pts(240))
        let el = try Self.enhancementLayer()
        r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(240))
        let bl = try Self.feedBase(r, 240)
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.composer.pairs.first?.base === bl && r.composer.pairs.first?.enhancement === el)
        #expect(r.decoder.absentEnhancementKeyCountForTesting == 0)
        // The note is gone: a later frame at the same time would wait for a partner like any other.
        _ = try Self.feedBase(r, 240)
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1)
    }

    typealias B = HEVCSyntheticBitstream
    typealias T = HEVCSyntheticBitstream.T

    /// One access unit as `decode(packet:)` receives it: a base slice, and unless `el` is nil an
    /// enhancement slice wrapped in NAL type 63 (with its parameter sets on the first unit, which have no
    /// other way in). The base layer's parameter sets ride in band on the first unit too.
    private static func unit(_ blType: Int, _ blPoc: Int, el: (type: Int, poc: Int)?, parameterSets: Bool = false) -> [UInt8] {
        var nals: [[UInt8]] = []
        if parameterSets { nals.append(B.sps(pocLsbBits: 8)); nals.append(B.pps()) }
        nals.append(B.slice(type: blType, pocLsb: blPoc & 0xFF, pocLsbBits: 8))
        if let el {
            if parameterSets { nals.append(B.wrappedEL(B.sps(pocLsbBits: 8))); nals.append(B.wrappedEL(B.pps())) }
            nals.append(B.wrappedEL(B.slice(type: el.type, pocLsb: el.poc & 0xFF, pocLsbBits: 8)))
        }
        return B.accessUnit(nals)
    }

    /// Feeds one access unit through the production `decode(packet:)`, stamped with frame `n`'s time in
    /// the decoder's 90 kHz time base.
    private static func decodeUnit(_ decoder: DualLayerVideoDecoder, _ bytes: [UInt8], frame n: Int64) throws {
        let packet = try #require(av_packet_alloc())
        defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
        #expect(av_new_packet(packet, Int32(bytes.count)) >= 0)
        bytes.withUnsafeBufferPointer { packet.pointee.data.update(from: $0.baseAddress!, count: bytes.count) }
        packet.pointee.pts = pts(n).value
        packet.pointee.dts = pts(n).value
        decoder.decode(packet: packet, epoch: nil)
    }

    /// A rig whose decoder takes access units through `decode(packet:)`.
    private static func packetRig() -> Rig {
        let r = rig()
        r.decoder.markPrimaryDecoderOpenForTesting()
        return r
    }

    /// The opening units of a stream whose enhancement pictures sit in other units than their base
    /// frames: unit 2's enhancement picture (POC 3) is the base frame one unit on, so it is restamped.
    private static func openingUnits() -> [[UInt8]] {
        [unit(T.idrNLP, 0, el: (T.idrNLP, 0), parameterSets: true),
         unit(T.trailR, 1, el: (T.trailR, 1)),
         unit(T.trailR, 2, el: (T.trailR, 3))]
    }

    @Test("on a stream whose enhancement pictures are restamped, a unit without one says nothing about its own base frame")
    func reorderedStreamNeverBypassesOnAbsence() async throws {
        let r = Self.packetRig()
        defer { r.decoder.close() }
        let first: Int64 = 240
        for (i, u) in Self.openingUnits().enumerated() { try Self.decodeUnit(r.decoder, u, frame: first + Int64(i)) }
        #expect(r.decoder.absentEnhancementKeyCountForTesting == 0)

        // The stream is reordered by now: a unit with no enhancement layer notes nothing, so its base
        // frame waits for a partner.
        try Self.decodeUnit(r.decoder, Self.unit(T.trailR, 3, el: nil), frame: first + 3)
        #expect(r.decoder.absentEnhancementKeyCountForTesting == 0, "no note on a reordered stream")
        let bl = try Self.feedBase(r, first + 3)
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1, "waits for its partner")
        let el = try Self.enhancementLayer()
        r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(first + 3))
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.composer.pairs.first?.base === bl && r.composer.pairs.first?.enhancement === el)
    }

    @Test("before any restamp, a unit without an enhancement layer is noted, and the notes are dropped in the unit that first restamps")
    func absenceNotesBeforeAndAtTheFirstRestamp() async throws {
        let r = Self.packetRig()
        defer { r.decoder.close() }
        let first: Int64 = 240
        let units = Self.openingUnits()
        try Self.decodeUnit(r.decoder, units[0], frame: first)
        try Self.decodeUnit(r.decoder, units[1], frame: first + 1)
        // A unit with no enhancement layer, while the pictures still line up: a real absence.
        try Self.decodeUnit(r.decoder, Self.unit(T.trailR, 2, el: nil), frame: first + 2)
        #expect(r.decoder.absentEnhancementKeyCountForTesting == 1)
        let alone = try Self.feedBase(r, first + 2)
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0, "released at once")
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.deliveries.all.first?.buffer === alone)

        // Another absence, then the unit whose enhancement picture is restamped: the note made before
        // the reordering was seen goes with it, in the same unit.
        try Self.decodeUnit(r.decoder, Self.unit(T.trailR, 3, el: nil), frame: first + 3)
        #expect(r.decoder.absentEnhancementKeyCountForTesting == 1)
        try Self.decodeUnit(r.decoder, Self.unit(T.trailR, 4, el: (T.trailR, 6)), frame: first + 4)
        #expect(r.decoder.absentEnhancementKeyCountForTesting == 0, "dropped by the unit that restamps")
        // And that unit's own absence is not noted either, judged after its restamp.
        try Self.decodeUnit(r.decoder, Self.unit(T.trailR, 5, el: nil), frame: first + 5)
        #expect(r.decoder.absentEnhancementKeyCountForTesting == 0)
    }

    // MARK: - 5. Grace for a late enhancement layer, and the margin at high frame rates

    @Test("an enhancement layer that arrives just after its base frame, already inside the margin, pairs; the same frame is released once the grace is over")
    func graceForALatePartner() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let n: Int64 = 252
        // The clock is already past the release time: the deadline rule would fire on arrival.
        r.clocks.seconds = Self.pts(n).seconds - Self.margin + 0.02
        let bl = try Self.feedBase(r, n)
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1, "not released on arrival")
        r.clocks.uptime += 0.01   // under max(one frame interval, 15 ms)
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1, "still inside the grace")
        let el = try Self.enhancementLayer()
        r.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(n))
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.composer.pairs.first?.base === bl && r.composer.pairs.first?.enhancement === el)

        // A partner that does not come: out once the grace is over, not before.
        let m = n + 1
        r.clocks.seconds = Self.pts(m).seconds - Self.margin + 0.02
        let alone = try Self.feedBase(r, m)
        r.clocks.uptime += Self.frame - 0.002
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1)
        r.clocks.uptime += 0.004
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0)
        try await waitFor { r.deliveries.count == 2 }
        #expect(r.deliveries.all.last?.buffer === alone)
    }

    @Test("at 60 fps the margin is the time floor, not three frame intervals")
    func marginFloorAtHighFrameRate() async throws {
        let r = Self.rig(frameRate: 60)
        defer { r.decoder.close() }
        #expect(Double(DualLayerVideoDecoder.deadlineMarginFrames) / 60 < DualLayerVideoDecoder.deadlineMarginFloor)
        let n: Int64 = 252
        let due = Self.pts(n).seconds - DualLayerVideoDecoder.deadlineMarginFloor
        r.clocks.seconds = due - 0.02
        let bl = try Self.feedBase(r, n)
        r.clocks.uptime += Self.pastGrace
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1, "120 ms ahead: not due")
        // 80 ms before the deadline: past the 50 ms three frames would give, inside the 100 ms floor.
        r.clocks.seconds = Self.pts(n).seconds - 0.08
        r.decoder.runDeadlineSweep()
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.deliveries.all.first?.buffer === bl)
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0)
    }

    // MARK: - 6. A held clock: a preroll, and a pause

    @Test("a paused clock does not release a waiting frame after the margin; only the long bound does")
    func pausedClockIsNotAPreroll() async throws {
        let r = Self.rig(running: false)   // held, no start pending
        defer { r.decoder.close() }
        r.clocks.seconds = 10
        let bl = try Self.feedBase(r, 252)
        r.clocks.uptime += Self.margin * 4
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1, "a pause is not late")
        r.clocks.uptime += DualLayerVideoDecoder.heldClockWallBound - Self.margin * 4 - 0.001
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1)
        r.clocks.uptime += 0.002
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0)
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.deliveries.all.first?.buffer === bl)
    }

    // MARK: - 7. Sweep timing

    @Test("the next sweep is armed for the earliest due time, and replaced by an earlier one")
    func sweepIsArmedForTheEarliestDueTime() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let a: Int64 = 252, b: Int64 = 249
        let dueA = Self.pts(a).seconds - Self.margin
        r.clocks.seconds = dueA - 0.2
        _ = try Self.feedBase(r, a)
        let first = try #require(r.decoder.armedSweepFireUptimeForTesting)
        #expect(abs((first - r.clocks.uptime) - 0.2) < 0.002, "not the 5 ms poll of a waiting frame")
        // B shows 125 ms before A but takes A's place behind it, so A is due 125 ms sooner.
        _ = try Self.feedBase(r, b)
        let second = try #require(r.decoder.armedSweepFireUptimeForTesting)
        #expect(abs((second - r.clocks.uptime) - 0.075) < 0.002)
        #expect(second < first)
    }

    @Test("a sweep that finds nothing waiting arms nothing")
    func sweepStopsWhenNothingWaits() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        r.clocks.seconds = 10
        #expect(r.decoder.armedSweepFireUptimeForTesting == nil)
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.armedSweepFireUptimeForTesting == nil)
    }

    /// An arrival that does not queue still puts a waiting frame behind a frame that shows earlier, and
    /// the sweep armed for the waiting frame's old time must be replaced by an earlier one.
    private enum Arrival { case composes, absentInAU, missingRPU }

    private func rearmsOnArrival(_ arrival: Arrival) async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let a: Int64 = 252, b: Int64 = 249
        let dueA = Self.pts(a).seconds - Self.margin
        r.clocks.seconds = dueA - 0.2
        _ = try Self.feedBase(r, a)
        let first = try #require(r.decoder.armedSweepFireUptimeForTesting)
        #expect(abs((first - r.clocks.uptime) - 0.2) < 0.002)

        // B shows 125 ms before A, takes a later ticket and is handled without queueing.
        switch arrival {
        case .composes:
            r.decoder.handleEnhancementLayerFrame(elBuffer: try Self.enhancementLayer(), pts: Self.pts(b))
            _ = try Self.feedBase(r, b)
        case .absentInAU:
            r.decoder.noteEnhancementAbsentForTesting(pts: Self.pts(b))
            _ = try Self.feedBase(r, b)
        case .missingRPU:
            r.decoder.handleEnhancementLayerFrame(elBuffer: try Self.enhancementLayer(), pts: Self.pts(b))
            r.decoder.handleBaseLayerFrame(baseBuffer: try Self.baseLayer(), pts: Self.pts(b), hdr10Data: nil)
        }
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1, "only A still waits")
        let second = try #require(r.decoder.armedSweepFireUptimeForTesting)
        #expect(abs((second - r.clocks.uptime) - 0.075) < 0.002, "armed for A's new, earlier due time")
        #expect(second < first)

        // With no further arrival the timer alone releases A at that time.
        r.clocks.uptime += 0.08
        r.clocks.seconds = Self.pts(b).seconds - Self.margin
        try await waitFor { r.deliveries.count == 2 }
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0)
    }

    @Test("a frame that composes on arrival and moves a waiting frame's due time earlier re-arms the sweep")
    func composingArrivalRearmsTheSweep() async throws { try await rearmsOnArrival(.composes) }

    @Test("a frame released as having no enhancement layer in its access unit re-arms the sweep")
    func absentArrivalRearmsTheSweep() async throws { try await rearmsOnArrival(.absentInAU) }

    @Test("a frame released for missing RPU metadata re-arms the sweep")
    func missingRPUArrivalRearmsTheSweep() async throws { try await rearmsOnArrival(.missingRPU) }

    // MARK: - 7b. No grace past the presentation time, and a cap on the grace

    @Test("a frame already at or past its presentation time is released on arrival: a late partner is late anyway")
    func noGraceOnceThePresentationTimeHasPassed() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let n: Int64 = 252
        r.clocks.seconds = Self.pts(n).seconds + 0.01
        let bl = try Self.feedBase(r, n)
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0, "no grace")
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.deliveries.all.first?.buffer === bl)

        // One that is inside the margin but not yet at its time keeps the grace.
        let m = n + 1
        r.clocks.seconds = Self.pts(m).seconds - 0.02
        _ = try Self.feedBase(r, m)
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1)
        // The sweep for it is not armed for "now" either: it waits out the grace.
        let fire = try #require(r.decoder.armedSweepFireUptimeForTesting)
        #expect(fire - r.clocks.uptime > 0.01)
    }

    @Test("a frame whose presentation time falls inside its grace is released then, not when the grace is over")
    func sweepIsArmedForThePresentationTimeInsideTheGrace() async throws {
        let r = Self.rig()   // 24 fps: grace 41.7 ms
        defer { r.decoder.close() }
        let n: Int64 = 252
        r.clocks.seconds = Self.pts(n).seconds - 0.02   // inside the margin, 20 ms short of its time
        let bl = try Self.feedBase(r, n)
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1)
        // The sweep is armed for the presentation time (20 ms), not the end of the grace (41.7 ms).
        let fire = try #require(r.decoder.armedSweepFireUptimeForTesting)
        #expect(fire - r.clocks.uptime < 0.03, "armed for the presentation time, not the grace end")
        // Arrivals stall; the sweep fires at the presentation time, well inside the grace.
        r.clocks.seconds += 0.02
        r.clocks.uptime += 0.02
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0)
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.deliveries.all.first?.buffer === bl)
    }

    @Test("the grace is capped at 50 ms however slow the frame rate")
    func graceIsCapped() async throws {
        let r = Self.rig(frameRate: 10)   // 100 ms per frame; margin deadlineMarginFrames x 100 ms
        defer { r.decoder.close() }
        #expect(DualLayerVideoDecoder.enhancementGraceCap == 0.05)
        let n: Int64 = 252
        let margin = Double(DualLayerVideoDecoder.deadlineMarginFrames) / 10
        r.clocks.seconds = Self.pts(n).seconds - margin + 0.02   // inside the margin, short of its time
        let bl = try Self.feedBase(r, n)
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1)
        r.clocks.uptime += 0.049
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1, "inside the cap")
        r.clocks.uptime += 0.002
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0, "past 50 ms, not past a frame interval")
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.deliveries.all.first?.buffer === bl)
    }

    // MARK: - 8. Flush and seek

    @Test("a flush with a frame waiting clears the absence notes, pauses the sweep while draining, and the sweep resumes after")
    func flushWithAWaitingFrame() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        let n: Int64 = 252
        r.clocks.seconds = Self.pts(n).seconds - 5
        _ = try Self.feedBase(r, n)
        r.decoder.noteEnhancementAbsentForTesting(pts: Self.pts(300))
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1)
        #expect(r.decoder.armedSweepFireUptimeForTesting != nil)
        #expect(r.decoder.absentEnhancementKeyCountForTesting == 1)

        // While the sessions drain, the frame is long past due by the clock, but a sweep leaves it
        // alone and arms nothing.
        nonisolated(unsafe) var drainingObserved = false
        nonisolated(unsafe) var releasedWhileDraining = -1
        nonisolated(unsafe) var armedWhileDraining = true
        nonisolated(unsafe) var absentWhileDraining = -1
        r.decoder.flushRaceHookForTesting = { [weak decoder = r.decoder, deliveries = r.deliveries, clocks = r.clocks] in
            guard let decoder else { return }
            drainingObserved = decoder.stateSnapshotForTesting.draining
            absentWhileDraining = decoder.absentEnhancementKeyCountForTesting
            clocks.seconds = Self.pts(n).seconds + 10
            clocks.uptime += 5
            decoder.runDeadlineSweep()
            releasedWhileDraining = deliveries.count
            armedWhileDraining = decoder.armedSweepFireUptimeForTesting != nil
        }
        r.decoder.flush()
        r.decoder.flushRaceHookForTesting = nil
        #expect(drainingObserved)
        #expect(absentWhileDraining == 0, "cleared in the first critical section")
        #expect(releasedWhileDraining == 0, "a pre-seek frame is not released while draining")
        #expect(!armedWhileDraining)
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 0)
        #expect(r.decoder.armedSweepFireUptimeForTesting == nil)

        // After the flush a stale note does not bypass, and a waiting frame is swept again.
        let m: Int64 = 300
        r.clocks.seconds = Self.pts(m).seconds - 5
        let waiting = try Self.feedBase(r, m)
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1, "the pre-flush absence note is gone")
        #expect(r.decoder.armedSweepFireUptimeForTesting != nil, "the sweep resumes with the first waiting frame")
        r.clocks.uptime += Self.pastGrace
        r.clocks.seconds = Self.pts(m).seconds - Self.margin
        r.decoder.runDeadlineSweep()
        try await waitFor { r.deliveries.count == 1 }
        #expect(r.deliveries.all.first?.buffer === waiting)
    }

    @Test("a clock sample taken before a flush is discarded: it cannot release a frame that arrived after it")
    func staleClockSampleAcrossAFlush() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        // The provider flushes the decoder and feeds a post-flush frame in the middle of the sweep's
        // own sample, then reports a time far past that frame's release and moves wall time on.
        final class Switches: @unchecked Sendable { var armed = false; var first = true }
        let switches = Switches()
        let n: Int64 = 252
        let decoder = r.decoder
        let clocks = r.clocks
        let feed: @Sendable () -> Void = {
            decoder.seedRPUForTesting(pts: Self.pts(n), params: Self.params(), displayMetadataNAL: nil)
            if let bl = Self.buffer(width: 64, height: 64) {
                decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(n), hdr10Data: nil)
            }
        }
        decoder.setRenderClock({
            if switches.armed, switches.first {
                switches.first = false
                decoder.flush()
                feed()
                clocks.uptime += 1
                return RenderClockSample(seconds: Self.pts(n).seconds + 10, running: true)
            }
            return RenderClockSample(seconds: clocks.seconds, running: clocks.running)
        }, frameRate: 24)
        clocks.seconds = Self.pts(n).seconds - 5
        _ = try Self.feedBase(r, n)
        switches.armed = true
        r.decoder.runDeadlineSweep()
        #expect(r.decoder.stateSnapshotForTesting.blQueueCount == 1, "the stale sample must not release the new frame")
        #expect(r.deliveries.count == 0)
    }

    // MARK: - 9. Counters

    @Test("each release rule has its own counter in the 1 Hz summary")
    func summaryCountsEachRule() async throws {
        let r = Self.rig()
        defer { r.decoder.close() }
        nonisolated(unsafe) var now: TimeInterval = 100
        nonisolated(unsafe) var lines: [String] = []
        r.decoder.summaryTimestampProviderForTesting = { now }
        r.decoder.summarySinkForTesting = { line, _ in lines.append(line) }

        // In the access unit.
        r.decoder.noteEnhancementAbsentForTesting(pts: Self.pts(240))
        _ = try Self.feedBase(r, 240)
        // Deadline.
        r.clocks.seconds = 0
        _ = try Self.feedBase(r, 252)
        r.clocks.uptime += Self.pastGrace
        r.clocks.seconds = Self.pts(252).seconds - Self.margin
        r.decoder.runDeadlineSweep()
        // Held clock, start pending.
        r.clocks.running = false
        r.clocks.prerolling = true
        _ = try Self.feedBase(r, 260)
        r.clocks.uptime += Self.margin
        r.decoder.runDeadlineSweep()
        // Backstop.
        r.clocks.running = true
        r.clocks.prerolling = false
        r.clocks.seconds = 0
        for i in 0...Int64(DualLayerVideoDecoder.maxDeadlineHoldFrames) { _ = try Self.feedBase(r, 2400 + i) }
        try await waitFor { r.deliveries.count == 4 }

        now = 101.5
        r.decoder.maybeEmitSummary()
        let line = try #require(lines.last)
        for expected in ["bypassNoELInAU=1", "bypassDeadline=1", "bypassHeldWall=1", "bypassBackstop=1",
                         "bypassNoELDecoder=0", "bypassEndOfStream=0"] {
            #expect(line.contains(expected), "\(expected) in \(line)")
        }
    }
}

#endif
