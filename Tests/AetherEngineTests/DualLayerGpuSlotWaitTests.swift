// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
@testable import AetherEngine

/// The GPU slot wait must not hold the decoder lock.
///
/// With a composer whose in-flight limit is 1 and whose first completion is
/// held by the test, a second composition started on another thread blocks in
/// `acquireSlot()` with no lock held, so `flush()` returns promptly. On the
/// pre-fix code the wait sat inside `composeAsync` while the VideoToolbox
/// thread held the decoder lock, and `flush()` hung behind it.
@Suite(.serialized, .offCooperativePoolOneLane, .timeLimit(.minutes(5)))
struct DualLayerGpuSlotWaitTests {

    /// Fake composer with an in-flight limit of 1. The first composition's
    /// completion is held until the test releases it; the slot is held with
    /// it, the way the real composer holds the slot until the command buffer
    /// retires.
    final class GatedFakeComposer: FelComposing, @unchecked Sendable {
        private let slots = DispatchSemaphore(value: 1)
        private let lock = NSLock()
        private var held: (@Sendable (CVPixelBuffer?) -> Void)?
        private var heldBase: CVPixelBuffer?
        private(set) var acquireCalls = 0
        private(set) var completedCount = 0
        var acquireCallCount: Int { lock.lock(); defer { lock.unlock() }; return acquireCalls }

        func acquireSlot() {
            lock.lock(); acquireCalls += 1; lock.unlock()
            slots.wait()
        }

        func releaseSlot() { slots.signal() }

        func composeAsync(
            baseBuffer: CVPixelBuffer,
            enhancementBuffer: CVPixelBuffer,
            params: DoviMetalParams,
            frameIndex: UInt32,
            completion: @escaping @Sendable (CVPixelBuffer?) -> Void
        ) {
            acquireSlot()
            composeAsyncWithAcquiredSlot(
                baseBuffer: baseBuffer, enhancementBuffer: enhancementBuffer,
                params: params, frameIndex: frameIndex, completion: completion)
        }

        func composeAsyncWithAcquiredSlot(
            baseBuffer: CVPixelBuffer,
            enhancementBuffer: CVPixelBuffer,
            params: DoviMetalParams,
            frameIndex: UInt32,
            completion: @escaping @Sendable (CVPixelBuffer?) -> Void
        ) {
            lock.lock()
            let isFirst = held == nil && completedCount == 0
            if isFirst {
                held = completion
                heldBase = baseBuffer
            }
            lock.unlock()
            if !isFirst {
                // Later frames finish synchronously through the base layer once
                // the test has released the first slot. Ticket ordering in
                // `deliver` is what the ordering test exercises, not the hop.
                slots.signal()
                lock.lock(); completedCount += 1; lock.unlock()
                completion(baseBuffer)
            }
        }

        /// Releases the held first composition: delivers its base layer as the
        /// composed result and frees the slot.
        func releaseFirst() {
            let completion: (@Sendable (CVPixelBuffer?) -> Void)?
            let base: CVPixelBuffer?
            lock.lock()
            completion = held; base = heldBase
            held = nil; heldBase = nil
            completedCount += 1
            lock.unlock()
            if let completion {
                completion(base)
            }
            slots.signal()
        }

        func flush() {}
    }

    private static let frameTicks: Int64 = 3754
    private static func pts(_ frame: Int64) -> CMTime {
        CMTime(value: frame * frameTicks, timescale: 90000)
    }

    private static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                         [kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                                         &out)
        return status == kCVReturnSuccess ? out : nil
    }

    private final class Deliveries: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var points: [CMTime] = []
        private var metadata: [Data?] = []
        func record(_ buffer: CVPixelBuffer, _ pts: CMTime, _ hdr10: Data?) {
            let payload = CVBufferCopyAttachment(buffer, DoviDisplayMetadata.rpuDataKey as CFString, nil) as? Data
            lock.lock(); points.append(pts); metadata.append(payload); lock.unlock()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return points.count }
        var metadataPayloads: [Data?] { lock.lock(); defer { lock.unlock() }; return metadata }
    }

    /// Set once by a worker thread when it has finished; read by the test.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Baton-pass box: the test thread stops touching the buffer once it is
    /// handed to the background thread, mirroring the decoder's own handoff.
    private struct SendablePixelBuffer: @unchecked Sendable {
        let value: CVPixelBuffer
    }

    @Test("a second composition blocked on the GPU slot does not stall flush()")
    func blockedSlotDoesNotStallFlush() async throws {
        let bl0 = try #require(Self.makeBuffer(width: 64, height: 64))
        let el0 = try #require(Self.makeBuffer(width: 32, height: 32))
        let bl1 = try #require(Self.makeBuffer(width: 64, height: 64))
        let el1 = try #require(Self.makeBuffer(width: 32, height: 32))

        let composer = GatedFakeComposer()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer)
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        decoder.seedRPUForTesting(pts: Self.pts(0), params: DoviMetalParams(), displayMetadataNAL: nil)
        decoder.seedRPUForTesting(pts: Self.pts(1), params: DoviMetalParams(), displayMetadataNAL: nil)

        // First pair composes and holds the only slot.
        decoder.handleEnhancementLayerFrame(elBuffer: el0, pts: Self.pts(0))
        decoder.handleBaseLayerFrame(baseBuffer: bl0, pts: Self.pts(0), hdr10Data: nil)

        // Second pair on another thread: its enhancement layer queues without
        // blocking, then its base layer matches and parks in acquireSlot().
        let bl1Box = SendablePixelBuffer(value: bl1)
        let el1Box = SendablePixelBuffer(value: el1)
        // A dedicated thread, not the global queue: other suites run concurrently and
        // can saturate GCD's pool, which starved this closure past the deadline.
        let workerDone = Flag()
        let worker = Thread {
            decoder.handleEnhancementLayerFrame(elBuffer: el1Box.value, pts: Self.pts(1))
            decoder.handleBaseLayerFrame(baseBuffer: bl1Box.value, pts: Self.pts(1), hdr10Data: nil)
            workerDone.set()
        }
        worker.start()
        // Wait until the background thread is inside the slot wait (on the
        // pre-fix code it instead holds the decoder lock here, which is what
        // made flush() hang). Then flush() must still return promptly.
        try await waitFor { composer.acquireCallCount == 2 }

        // flush() runs while the second composition is parked in `acquireSlot` and the first is held
        // by the gate. Returning at all is the proof (it would wait on the decoder lock otherwise,
        // and the suite's time limit would report the hang); no wall-clock bound is asserted.
        decoder.flush()

        // Release the held composition and let the second finish; the flush
        // retired both tickets, so neither may be delivered after it.
        composer.releaseFirst()
        try await waitFor { workerDone.isSet }
        decoder.quiesceForTesting()
        #expect(deliveries.count == 0, "frames composed before flush() must not be delivered after it")
        decoder.close()
    }

    @Test("a frame with no usable RPU borrows the previous frame's parameters, but only for a short run")
    func missingRpuBorrowsPreviousParameters() async throws {
        let composer = GatedFakeComposer()
        let decoder = DualLayerVideoDecoder(composer: composer)
        decoder.onFrame = { _, _, _ in }
        decoder.primeForTesting(enhancementLayer: true)
        let limit = DualLayerVideoDecoder.maxBorrowedParamsRun
        // Packets in decode order: frame 0 has a real RPU, every later one has none.
        decoder.seedRPUForTesting(pts: Self.pts(0), params: DoviMetalParams(), displayMetadataNAL: nil)
        for i in 1...(limit + 1) {
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: nil, displayMetadataNAL: nil)
        }
        let box = try (0...(limit + 1)).map { _ -> (SendablePixelBuffer, SendablePixelBuffer) in
            let bl = try #require(Self.makeBuffer(width: 64, height: 64))
            let el = try #require(Self.makeBuffer(width: 32, height: 32))
            return (SendablePixelBuffer(value: bl), SendablePixelBuffer(value: el))
        }
        let workerDone = Flag()
        let worker = Thread {
            for (i, pair) in box.enumerated() {
                decoder.handleEnhancementLayerFrame(elBuffer: pair.1.value, pts: Self.pts(Int64(i)))
                decoder.handleBaseLayerFrame(baseBuffer: pair.0.value, pts: Self.pts(Int64(i)), hdr10Data: nil)
            }
            workerDone.set()
        }
        worker.start()
        // Frame 0 holds the only slot. Frame 1 borrows and parks in acquireSlot (count 2). Frames after
        // the borrow limit must bypass instead of reaching the composer.
        try await waitFor { composer.acquireCallCount == 2 }
        composer.releaseFirst()
        try await waitFor { workerDone.isSet }
        #expect(composer.acquireCallCount == 1 + limit)
        decoder.close()
    }

    @Test("borrowed parameters carry display metadata only within the borrow limit, and flush clears it")
    func missingRpuBorrowsPreviousDisplayMetadata() async throws {
        let composer = GatedFakeComposer()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer)
        defer { decoder.close() }
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        let nal: [UInt8] = [0x7C, 0x01, 0x19, 0x42, 0x03]
        let payload = Data(nal.dropFirst(2))
        let limit = DualLayerVideoDecoder.maxBorrowedParamsRun
        decoder.seedRPUForTesting(pts: Self.pts(0), params: DoviMetalParams(), displayMetadataNAL: nal)
        for i in 1...(limit + 1) {
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: nil, displayMetadataNAL: nil)
        }

        for i in 0...(limit + 1) {
            let bl = try #require(Self.makeBuffer(width: 64, height: 64))
            let el = try #require(Self.makeBuffer(width: 32, height: 32))
            let pts = Self.pts(Int64(i))
            if i.isMultiple(of: 2) {
                decoder.handleEnhancementLayerFrame(elBuffer: el, pts: pts)
                decoder.handleBaseLayerFrame(baseBuffer: bl, pts: pts, hdr10Data: nil)
            } else {
                decoder.handleBaseLayerFrame(baseBuffer: bl, pts: pts, hdr10Data: nil)
                decoder.handleEnhancementLayerFrame(elBuffer: el, pts: pts)
            }
            if i == 0 { composer.releaseFirst() }
        }
        try await waitFor { deliveries.count >= limit + 2 }
        #expect(deliveries.metadataPayloads == Array(repeating: Optional(payload), count: limit + 1) + [nil])
        #expect(composer.acquireCallCount == 1 + limit)

        decoder.seedRPUForTesting(pts: Self.pts(10), params: DoviMetalParams(), displayMetadataNAL: nal)
        let bl = try #require(Self.makeBuffer(width: 64, height: 64))
        let el = try #require(Self.makeBuffer(width: 32, height: 32))
        decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(10), hdr10Data: nil)
        decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(10))
        try await waitFor { deliveries.count >= limit + 3 }
        #expect(deliveries.count == limit + 3)
        decoder.flush()
        for i in 11...12 {
            decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: nil, displayMetadataNAL: nil)
            let bl = try #require(Self.makeBuffer(width: 64, height: 64))
            let el = try #require(Self.makeBuffer(width: 32, height: 32))
            decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
            decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
        }
        try await waitFor { deliveries.count >= limit + 5 }
        #expect(deliveries.metadataPayloads == Array(repeating: Optional(payload), count: limit + 1) + [nil, payload, nil, nil])
        #expect(composer.acquireCallCount == 2 + limit)
    }

    @Test("ordering still holds across two gated compositions")
    func gatedCompositionsDeliverInOrder() async throws {
        let bl0 = try #require(Self.makeBuffer(width: 64, height: 64))
        let el0 = try #require(Self.makeBuffer(width: 32, height: 32))
        let bl1 = try #require(Self.makeBuffer(width: 64, height: 64))
        let el1 = try #require(Self.makeBuffer(width: 32, height: 32))

        let composer = GatedFakeComposer()
        let deliveries = Deliveries()
        let decoder = DualLayerVideoDecoder(composer: composer)
        defer { decoder.close() }
        decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
        decoder.primeForTesting(enhancementLayer: true)
        decoder.seedRPUForTesting(pts: Self.pts(0), params: DoviMetalParams(), displayMetadataNAL: nil)
        decoder.seedRPUForTesting(pts: Self.pts(1), params: DoviMetalParams(), displayMetadataNAL: nil)

        decoder.handleEnhancementLayerFrame(elBuffer: el0, pts: Self.pts(0))
        decoder.handleBaseLayerFrame(baseBuffer: bl0, pts: Self.pts(0), hdr10Data: nil)
        // Second composition blocks on the held slot on another thread.
        let bl1Box = SendablePixelBuffer(value: bl1)
        let el1Box = SendablePixelBuffer(value: el1)
        // A dedicated thread, not the global queue: other suites run concurrently and
        // can saturate GCD's pool, which starved this closure past the deadline.
        let worker = Thread {
            decoder.handleEnhancementLayerFrame(elBuffer: el1Box.value, pts: Self.pts(1))
            decoder.handleBaseLayerFrame(baseBuffer: bl1Box.value, pts: Self.pts(1), hdr10Data: nil)
        }
        worker.start()
        try await waitFor { composer.acquireCallCount == 2 }
        composer.releaseFirst()

        try await waitFor { deliveries.count >= 2 }
        #expect(deliveries.count == 2)
        let points = deliveries.points
        if points.count == 2 {
            #expect(CMTimeCompare(points[0], Self.pts(0)) == 0)
            #expect(CMTimeCompare(points[1], Self.pts(1)) == 0)
        }
    }
}
#endif
