// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import CoreMedia
import CoreVideo
import Foundation
@testable import AetherEngine

extension HeavyDualLayerSuites {
    /// The GPU slot wait must not hold the decoder lock.
    ///
    /// With a composer whose in-flight limit is 1 and whose first completion is
    /// held by the test, a second composition started on another thread blocks in
    /// `acquireSlot()` with no lock held, so `flush()` returns promptly. On the
    /// pre-fix code the wait sat inside `composeAsync` while the VideoToolbox
    /// thread held the decoder lock, and `flush()` hung behind it.
    @Suite(.serialized, .offCooperativePool, .timeLimit(.minutes(5)))
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
            private(set) var grantedCalls = 0
            private(set) var completedCount = 0
            private var hook: (@Sendable (_ call: Int) -> Bool?)?
            private var instant = false
            var acquireCallCount: Int { lock.lock(); defer { lock.unlock() }; return acquireCalls }
            /// Timed waits that returned a slot.
            var grantedCount: Int { lock.lock(); defer { lock.unlock() }; return grantedCalls }

            /// Called, with the 1-based number of the timed wait, before each timed wait and outside the fake's
            /// lock (it may sleep or call back into the decoder). `false` makes the wait time out with nothing
            /// taken; nil lets it run for real.
            func setTimedWaitHook(_ newHook: (@Sendable (_ call: Int) -> Bool?)?) {
                lock.lock(); hook = newHook; lock.unlock()
            }

            /// Every timed wait returns at once: the slot if one is free, a timeout if not. The slices of a stall
            /// verdict then pass without sleeping, so the tests need no wall clock.
            func setInstantTimeouts(_ on: Bool) {
                lock.lock(); instant = on; lock.unlock()
            }

            func acquireSlot() {
                lock.lock(); acquireCalls += 1; lock.unlock()
                slots.wait()
            }

            func acquireSlot(timeout: DispatchTime) -> Bool {
                lock.lock()
                acquireCalls += 1
                let call = acquireCalls
                let hook = self.hook
                let instant = self.instant
                lock.unlock()
                let got: Bool
                if hook?(call) == false {
                    got = false
                } else {
                    got = slots.wait(timeout: instant ? .now() : timeout) == .success
                }
                if got { lock.lock(); grantedCalls += 1; lock.unlock() }
                return got
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

        /// A stall timeout no test run reaches, for the tests that hold a slot on purpose and are not about the
        /// verdict: load cannot turn a held slot into a stall.
        private static let noStall: TimeInterval = 600

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
            let decoder = DualLayerVideoDecoder(composer: composer, composeStallTimeout: Self.noStall)
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

        /// The frame handlers are VideoToolbox output callbacks, and VideoToolbox can make one on the thread
        /// that submitted the frame while `HardwareVideoDecoder.lock` is held: a handler that waits for a GPU
        /// slot there stalls that session's whole output, and with it decode of both layers. Before the compose
        /// queue, the second pair's base-layer handler parked in `acquireSlot()` until the first composition
        /// retired; now it hands the composition to the queue and returns while every slot is still held.
        @Test("the VideoToolbox-side handler returns promptly while every composer slot is held")
        func handlerReturnsWhileSlotsAreHeld() async throws {
            let bl0 = try #require(Self.makeBuffer(width: 64, height: 64))
            let el0 = try #require(Self.makeBuffer(width: 32, height: 32))
            let bl1 = try #require(Self.makeBuffer(width: 64, height: 64))
            let el1 = try #require(Self.makeBuffer(width: 32, height: 32))

            let composer = GatedFakeComposer()
            let deliveries = Deliveries()
            let decoder = DualLayerVideoDecoder(composer: composer, composeStallTimeout: Self.noStall)
            defer { decoder.close() }
            decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
            decoder.primeForTesting(enhancementLayer: true)
            decoder.seedRPUForTesting(pts: Self.pts(0), params: DoviMetalParams(), displayMetadataNAL: nil)
            decoder.seedRPUForTesting(pts: Self.pts(1), params: DoviMetalParams(), displayMetadataNAL: nil)

            // First pair takes the only slot and holds it.
            decoder.handleEnhancementLayerFrame(elBuffer: el0, pts: Self.pts(0))
            decoder.handleBaseLayerFrame(baseBuffer: bl0, pts: Self.pts(0), hdr10Data: nil)
            try await waitFor { composer.acquireCallCount == 1 }

            // Second pair on a dedicated thread, standing in for the VideoToolbox callback.
            let bl1Box = SendablePixelBuffer(value: bl1)
            let el1Box = SendablePixelBuffer(value: el1)
            let workerDone = Flag()
            let worker = Thread {
                decoder.handleEnhancementLayerFrame(elBuffer: el1Box.value, pts: Self.pts(1))
                decoder.handleBaseLayerFrame(baseBuffer: bl1Box.value, pts: Self.pts(1), hdr10Data: nil)
                workerDone.set()
            }
            worker.start()
            // The bound is the assertion: the handlers do no waiting of their own, so a loaded machine
            // finishes them in far less; a handler parked on the slot never does until it is released.
            let returnedWhileHeld = try await waitFor(upTo: .seconds(5)) { workerDone.isSet }
            #expect(returnedWhileHeld, "the base-layer handler waited for a GPU slot on the callback thread")

            // The composition it handed off is the one now waiting for the slot.
            try await waitFor { composer.acquireCallCount == 2 }
            composer.releaseFirst()
            try await waitFor { workerDone.isSet }
            try await waitFor { deliveries.count >= 2 }
            decoder.quiesceForTesting()
            let points = deliveries.points
            #expect(points.count == 2)
            if points.count == 2 {
                #expect(CMTimeCompare(points[0], Self.pts(0)) == 0)
                #expect(CMTimeCompare(points[1], Self.pts(1)) == 0)
            }
        }

        /// A composition handed to the compose queue before a `flush()` belongs to the old feed: it must
        /// neither be delivered nor take a GPU slot once it reaches the front of the queue.
        @Test("a composition still queued when flush() runs never reaches the GPU or delivery")
        func queuedCompositionIsRetiredByFlush() async throws {
            let composer = GatedFakeComposer()
            let deliveries = Deliveries()
            let decoder = DualLayerVideoDecoder(composer: composer, composeStallTimeout: Self.noStall)
            defer { decoder.close() }
            decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
            decoder.primeForTesting(enhancementLayer: true)
            for i in 0...2 {
                decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: DoviMetalParams(), displayMetadataNAL: nil)
            }
            let pairs = try (0...2).map { _ -> (SendablePixelBuffer, SendablePixelBuffer) in
                let bl = try #require(Self.makeBuffer(width: 64, height: 64))
                let el = try #require(Self.makeBuffer(width: 32, height: 32))
                return (SendablePixelBuffer(value: bl), SendablePixelBuffer(value: el))
            }
            let workerDone = Flag()
            let worker = Thread {
                for (i, pair) in pairs.enumerated() {
                    decoder.handleEnhancementLayerFrame(elBuffer: pair.1.value, pts: Self.pts(Int64(i)))
                    decoder.handleBaseLayerFrame(baseBuffer: pair.0.value, pts: Self.pts(Int64(i)), hdr10Data: nil)
                }
                workerDone.set()
            }
            worker.start()
            // Frame 0 holds the slot, frame 1 waits for it on the compose queue, frame 2 is queued behind.
            // Bounded, so a handler that parks on the slot itself fails here instead of hanging the suite.
            let queued = try await waitFor(upTo: .seconds(5)) { workerDone.isSet && composer.acquireCallCount == 2 }
            #expect(queued, "the handlers waited for a GPU slot on the callback thread")
            guard queued else {
                composer.releaseFirst()
                try await waitFor { workerDone.isSet }
                return
            }
            decoder.flush()
            composer.releaseFirst()
            decoder.quiesceForTesting()
            #expect(deliveries.count == 0, "frames composed or queued before flush() must not be delivered after it")
            #expect(composer.acquireCallCount == 2, "a composition queued before flush() must not take a GPU slot")
        }

        /// The callback threads no longer absorb GPU backpressure, so the feed does: with
        /// `maxComposesAwaitingSlot` compositions queued behind a held slot, `decode(packet:)`'s wait holds
        /// the demux thread until the backlog drains.
        @Test("the feed waits while the compose backlog is full, and resumes once it drains")
        func feedWaitsOnComposeBacklog() async throws {
            let composer = GatedFakeComposer()
            let deliveries = Deliveries()
            let decoder = DualLayerVideoDecoder(composer: composer, composeStallTimeout: Self.noStall)
            defer { decoder.close() }
            decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
            decoder.primeForTesting(enhancementLayer: true)
            let backlog = DualLayerVideoDecoder.maxComposesAwaitingSlot
            for i in 0...backlog {
                decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: DoviMetalParams(), displayMetadataNAL: nil)
            }
            // Frame 0 holds the only slot; the next `backlog` frames queue behind it.
            for i in 0...backlog {
                let bl = try #require(Self.makeBuffer(width: 64, height: 64))
                let el = try #require(Self.makeBuffer(width: 32, height: 32))
                decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
                decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
            }
            try await waitFor { composer.acquireCallCount == 2 }

            let feedDone = Flag()
            let entryEpoch = decoder.feedEpochForTesting
            let feeder = Thread {
                decoder.waitForComposeBacklog(entryEpoch: entryEpoch)
                feedDone.set()
            }
            feeder.start()
            // The bound is the assertion, and it can only err towards passing: the wait cannot end while the
            // slot is held (the stall timeout is far out), however late the thread starts.
            let endedWhileFull = try await waitFor(upTo: .milliseconds(200)) { feedDone.isSet }
            #expect(!endedWhileFull, "the feed did not wait for a full compose backlog")

            composer.releaseFirst()
            try await waitFor { feedDone.isSet }
            try await waitFor { deliveries.count == backlog + 1 }
            decoder.quiesceForTesting()
            #expect(deliveries.count == backlog + 1)
        }

        /// Frame 0 holds the only slot and `maxComposesAwaitingSlot` more queue behind it: the backlog is full.
        private func fillComposeBacklog(_ decoder: DualLayerVideoDecoder, _ composer: GatedFakeComposer) async throws {
            decoder.primeForTesting(enhancementLayer: true)
            let backlog = DualLayerVideoDecoder.maxComposesAwaitingSlot
            for i in 0...backlog {
                decoder.seedRPUForTesting(pts: Self.pts(Int64(i)), params: DoviMetalParams(), displayMetadataNAL: nil)
            }
            for i in 0...backlog {
                let bl = try #require(Self.makeBuffer(width: 64, height: 64))
                let el = try #require(Self.makeBuffer(width: 32, height: 32))
                decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(Int64(i)))
                decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(Int64(i)), hdr10Data: nil)
            }
            try await waitFor { composer.acquireCallCount == 2 }
        }

        /// A seek must not wait for the GPU: `flush()` wakes a feed parked on the full backlog at once,
        /// where it used to sit out a fixed 0.5 s.
        @Test("flush() releases a feed waiting on a full compose backlog at once")
        func flushReleasesBacklogWaiter() async throws {
            let composer = GatedFakeComposer()
            let decoder = DualLayerVideoDecoder(composer: composer, composeStallTimeout: Self.noStall)
            defer { composer.releaseFirst(); decoder.close() }
            decoder.onFrame = { _, _, _ in }
            try await fillComposeBacklog(decoder, composer)

            let feedDone = Flag()
            let result = ResultBox()
            let entryEpoch = decoder.feedEpochForTesting
            let feeder = Thread {
                result.set(decoder.waitForComposeBacklog(entryEpoch: entryEpoch))
                feedDone.set()
            }
            feeder.start()
            let early = try await waitFor(upTo: .milliseconds(150)) { feedDone.isSet }
            #expect(!early, "the feed did not wait for a full compose backlog")
            let flusher = Thread { decoder.flush() }
            flusher.start()
            try await waitFor { feedDone.isSet }
            // The epoch moved while it waited: the packet is a pre-seek one and is refused.
            #expect(result.value == false)
        }

        private final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: Bool?
            func set(_ v: Bool) { lock.lock(); stored = v; lock.unlock() }
            var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
        }

        @Test("a frame with no usable RPU borrows the previous frame's parameters, but only for a short run")
        func missingRpuBorrowsPreviousParameters() async throws {
            let composer = GatedFakeComposer()
            let decoder = DualLayerVideoDecoder(composer: composer, composeStallTimeout: Self.noStall)
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
            // The handlers hand compositions to the compose queue and return: wait for the queue too.
            decoder.quiesceForTesting()
            #expect(composer.acquireCallCount == 1 + limit)
            decoder.close()
        }

        @Test("borrowed parameters carry display metadata only within the borrow limit, and flush clears it")
        func missingRpuBorrowsPreviousDisplayMetadata() async throws {
            let composer = GatedFakeComposer()
            let deliveries = Deliveries()
            let decoder = DualLayerVideoDecoder(composer: composer, composeStallTimeout: Self.noStall)
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

        // MARK: - Recoverable compose stall (dolby-vision-fel.md §5.6, §5.12)

        private static let composedNAL: [UInt8] = [0x7C, 0x01, 0x19, 0x42, 0x03]
        private static let baseLayerNAL: [UInt8] = [0x7C, 0x01, 0x1A, 0x43, 0x04]
        /// What a delivered frame carries for each RPU form (the first two bytes are the NAL header).
        private static let composedPayload = Data(composedNAL.dropFirst(2))
        private static let baseLayerPayload = Data(baseLayerNAL.dropFirst(2))

        private struct Rig {
            let composer: GatedFakeComposer
            let deliveries: Deliveries
            let decoder: DualLayerVideoDecoder
            /// Set if the decoder reported a fatal error, which a stall must never do.
            let fatal: Flag
        }

        private func makeRig(stallTimeout: TimeInterval) -> Rig {
            let composer = GatedFakeComposer()
            let deliveries = Deliveries()
            let decoder = DualLayerVideoDecoder(composer: composer, composeStallTimeout: stallTimeout)
            let fatal = Flag()
            decoder.onFrame = { buffer, pts, hdr10 in deliveries.record(buffer, pts, hdr10) }
            decoder.onFatalDecodeError = { _ in fatal.set() }
            decoder.primeForTesting(enhancementLayer: true)
            return Rig(composer: composer, deliveries: deliveries, decoder: decoder, fatal: fatal)
        }

        /// Seeds both RPU forms for each frame and hands the decoder its enhancement and base layers, in order.
        /// The handlers return at once (they only enqueue), whatever the GPU does.
        private func feedPairs(_ rig: Rig, _ frames: ClosedRange<Int64>) throws {
            for i in frames {
                rig.decoder.seedRPUForTesting(pts: Self.pts(i), params: DoviMetalParams(),
                                              displayMetadataNAL: Self.composedNAL, baseLayerNAL: Self.baseLayerNAL)
                let bl = try #require(Self.makeBuffer(width: 64, height: 64))
                let el = try #require(Self.makeBuffer(width: 32, height: 32))
                rig.decoder.handleEnhancementLayerFrame(elBuffer: el, pts: Self.pts(i))
                rig.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(i), hdr10Data: nil)
            }
        }

        /// A base-only frame (its access unit carried no enhancement layer): a bypass through the compose queue.
        private func feedBypass(_ rig: Rig, frame: Int64) throws {
            rig.decoder.seedRPUForTesting(pts: Self.pts(frame), params: DoviMetalParams(),
                                          displayMetadataNAL: Self.composedNAL, baseLayerNAL: Self.baseLayerNAL)
            rig.decoder.noteEnhancementAbsentForTesting(pts: Self.pts(frame))
            let bl = try #require(Self.makeBuffer(width: 64, height: 64))
            rig.decoder.handleBaseLayerFrame(baseBuffer: bl, pts: Self.pts(frame), hdr10Data: nil)
        }

        /// Frame 0 holds the only slot; the next frames' timed waits return at once, so frame 1 reaches the
        /// stall verdict and the frames behind it go out as the base layer. Waits for exactly that state.
        private func stallTheGpu(_ rig: Rig, frames: ClosedRange<Int64> = 0...2) async throws {
            rig.composer.setInstantTimeouts(true)
            try feedPairs(rig, frames)
            try await waitFor { rig.decoder.composeStallCount == 1 && rig.decoder.outstandingComposeRequestsForTesting == 1 }
        }

        @Test("a GPU that never completes sends queued frames out as the base layer with its mapping RPU, and the feed goes on")
        func stalledGpuSendsBaseLayerAndTheFeedGoesOn() async throws {
            let rig = makeRig(stallTimeout: 0.2)
            defer { rig.composer.releaseFirst(); rig.decoder.close() }
            try await stallTheGpu(rig)
            #expect(!rig.fatal.isSet, "a GPU stall must not end playback")
            #expect(rig.decoder.isComposeStalledForTesting)

            // The feed is not refused and does not wait: the backlog drains on its own.
            let result = ResultBox()
            let entryEpoch = rig.decoder.feedEpochForTesting
            let decoder = rig.decoder
            let feeder = Thread { result.set(decoder.waitForComposeBacklog(entryEpoch: entryEpoch)) }
            feeder.start()
            let returned = try await waitFor(upTo: .seconds(5)) { result.value != nil }
            #expect(returned && result.value == true)

            // Later frames go out the same way while the GPU is still stuck.
            try feedPairs(rig, 3...4)
            try await waitFor { rig.decoder.outstandingComposeRequestsForTesting == 1 }
            #expect(rig.composer.grantedCount == 1, "nothing but frame 0 got a slot")

            rig.composer.releaseFirst()
            rig.decoder.quiesceForTesting()
            try await waitFor { rig.deliveries.count == 5 }
            let points = rig.deliveries.points
            #expect(points.count == 5)
            for (i, pts) in points.enumerated() { #expect(CMTimeCompare(pts, Self.pts(Int64(i))) == 0) }
            let payloads = rig.deliveries.metadataPayloads
            #expect(payloads == [Optional(Self.composedPayload)] + Array(repeating: Optional(Self.baseLayerPayload), count: 4))
            #expect(rig.decoder.composeStallCount == 1)
            #expect(!rig.fatal.isSet)
        }

        @Test("a slot that frees ends stall mode and the next frame composes")
        func aFreedSlotEndsStallMode() async throws {
            let rig = makeRig(stallTimeout: 0.2)
            defer { rig.decoder.close() }
            try await stallTheGpu(rig)
            rig.composer.releaseFirst()
            rig.decoder.quiesceForTesting()
            try await waitFor { rig.deliveries.count == 3 }

            try feedPairs(rig, 3...3)
            try await waitFor { rig.deliveries.count == 4 }
            #expect(rig.deliveries.metadataPayloads.last == Optional(Self.composedPayload), "the frame after the GPU recovered was composed")
            #expect(!rig.decoder.isComposeStalledForTesting)
            #expect(rig.decoder.composeStallCount == 1, "the total is kept")
            #expect(rig.composer.grantedCount == 2)
            #expect(!rig.fatal.isSet)
        }

        @Test("a GPU that frees a slot within every K-1 waits is never declared stalled")
        func progressWithinTheSlicesIsNotAStall() async throws {
            // 20 s: a slice is 5 s, so only the hook's refusals time out, never a real wait.
            let rig = makeRig(stallTimeout: 20)
            defer { rig.composer.releaseFirst(); rig.decoder.close() }
            let slices = DualLayerVideoDecoder.composeStallSlices
            // Per request: slices - 1 timed-out waits, then a real one. Every request issues exactly that many.
            rig.composer.setTimedWaitHook { call in call % slices != 0 ? false : nil }
            try feedPairs(rig, 0...5)
            try await waitFor { rig.composer.grantedCount >= 1 }
            rig.composer.releaseFirst()
            try await waitFor { rig.deliveries.count == 6 }
            rig.decoder.quiesceForTesting()
            #expect(rig.decoder.composeStallCount == 0)
            #expect(rig.composer.grantedCount == 6)
            #expect(rig.deliveries.metadataPayloads == Array(repeating: Optional(Self.composedPayload), count: 6))
        }

        /// A suspended process resumes with the wait that was running returning late: that is one timed-out
        /// wait, not an elapsed time to compare with the timeout. A design that compared clock readings
        /// against the timeout would call this a stall.
        @Test("a wait that returns late, as after a process suspension, counts as one timed-out wait")
        func aLateWaitIsOneTimedOutWait() async throws {
            let stallTimeout: TimeInterval = 0.1
            let rig = makeRig(stallTimeout: stallTimeout)
            defer { rig.composer.releaseFirst(); rig.decoder.close() }
            let composer = rig.composer
            // Frame 0's wait is call 1. Frame 1's first wait (call 2) is held up for three timeouts, the slot
            // frees meanwhile, and it then reports a timeout.
            composer.setTimedWaitHook { call in
                guard call == 2 else { return nil }
                Thread.sleep(forTimeInterval: stallTimeout * 3)
                composer.releaseFirst()
                return false
            }
            try feedPairs(rig, 0...1)
            try await waitFor { rig.deliveries.count == 2 }
            #expect(rig.decoder.composeStallCount == 0)
            #expect(rig.deliveries.metadataPayloads == [Optional(Self.composedPayload), Optional(Self.composedPayload)])
            #expect(!rig.fatal.isSet)
        }

        // MARK: - The stall bound (dolby-vision-fel.md §5.6)

        /// Records what the fatal handler saw. The handler reads the decoder's own state, which takes the
        /// locks the report must not hold: a report made under `lock` or `composeBacklog` deadlocks it.
        private final class FatalProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var errors: [Error] = []
            private var held: [Bool] = []
            func record(_ error: Error, sawStoredError: Bool) {
                lock.lock(); errors.append(error); held.append(sawStoredError); lock.unlock()
            }
            var count: Int { lock.lock(); defer { lock.unlock() }; return errors.count }
            var first: Error? { lock.lock(); defer { lock.unlock() }; return errors.first }
            var sawStoredError: [Bool] { lock.lock(); defer { lock.unlock() }; return held }
        }

        private func installFatalProbe(_ rig: Rig) -> FatalProbe {
            let probe = FatalProbe()
            rig.decoder.onFatalDecodeError = { [weak decoder = rig.decoder] error in
                // Takes `lock`, then `composeBacklog`: both must be free when the handler runs.
                let stored = decoder?.fatalDecodeError is VideoDecoderError
                _ = decoder?.isComposeStalledForTesting
                probe.record(error, sawStoredError: stored)
            }
            return probe
        }

        /// Call numbers of the timed slot waits that must time out so the frames marked `true` reach the
        /// stall verdict. Frame 0 (a normal frame) is the first call. A stalling frame outside stall mode
        /// makes `composeStallSlices` waits; every other frame makes one (a frame in stall mode tries once).
        /// So each stalling frame must be followed by a normal one, which then ends stall mode.
        private func failingCalls(for plan: [Bool]) -> Set<Int> {
            var failing = Set<Int>()
            var call = 0
            for stalls in plan {
                if stalls {
                    for _ in 0..<DualLayerVideoDecoder.composeStallSlices { call += 1; failing.insert(call) }
                } else {
                    call += 1
                }
            }
            return failing
        }

        /// Runs `plan` (true = that frame reaches a stall verdict) through the decoder with a GPU that is
        /// free except when a wait is told to time out. Frame 0 is composed first, so it is plan[0] == false.
        private func runPlan(_ rig: Rig, _ plan: [Bool]) throws {
            let failing = failingCalls(for: plan)
            rig.composer.setTimedWaitHook { call in failing.contains(call) ? false : nil }
            try feedPairs(rig, 0...Int64(plan.count - 1))
        }

        @Test("a stall that never ends is reported once as a fatal error, with no lock held, and later packets are refused")
        func endlessStallIsReported() async throws {
            let rig = makeRig(stallTimeout: 0.2)
            defer { rig.composer.releaseFirst(); rig.decoder.close() }
            let probe = installFatalProbe(rig)
            rig.composer.setInstantTimeouts(true)
            // Frame 0 holds the only slot for good; frame 1 reaches the verdict and every frame after it is
            // sent out as the base layer, `maxComposeStallBypassFrames` of them in a row.
            try feedPairs(rig, 0...Int64(DualLayerVideoDecoder.maxComposeStallBypassFrames + 1))
            let reported = try await waitFor(upTo: .seconds(30)) { probe.count >= 1 }
            #expect(reported, "an endless stall must end in a reported error")
            guard reported else { return }
            #expect(probe.first as? VideoDecoderError != nil)
            if case .composerStalled? = probe.first as? VideoDecoderError {} else { Issue.record("wrong error: \(String(describing: probe.first))") }
            #expect(probe.sawStoredError == [true], "the handler saw fatalDecodeError set and could take the decoder's locks")
            #expect(rig.decoder.fatalDecodeError is VideoDecoderError)

            // Frames keep arriving until the host acts: reported once, never again.
            try feedPairs(rig, Int64(DualLayerVideoDecoder.maxComposeStallBypassFrames + 2)...Int64(DualLayerVideoDecoder.maxComposeStallBypassFrames + 4))
            rig.composer.releaseFirst()
            rig.decoder.quiesceForTesting()
            #expect(probe.count == 1)
            #expect(rig.decoder.composeStallCount == 1)
        }

        @Test("a GPU that recovers and stalls again, over and over, is reported at the episode limit")
        func repeatedStallsAreReported() async throws {
            let rig = makeRig(stallTimeout: 0.2)
            defer { rig.decoder.close() }
            let probe = installFatalProbe(rig)
            // Frame 0 composes (its completion is held, then released: the slot is free from here on).
            rig.composer.setTimedWaitHook { _ in nil }
            try feedPairs(rig, 0...0)
            try await waitFor { rig.composer.grantedCount == 1 }
            rig.composer.releaseFirst()
            try await waitFor { rig.deliveries.count == 1 }

            // maxComposeStallEpisodes + 1 stall verdicts, each followed by one frame that composes.
            var plan: [Bool] = [false]
            for _ in 0...DualLayerVideoDecoder.maxComposeStallEpisodes { plan += [true, false] }
            let failing = failingCalls(for: plan)
            // Frame 0's wait was call 1 and already ran; the plan's numbering starts there too.
            rig.composer.setTimedWaitHook { call in failing.contains(call) ? false : nil }
            try feedPairs(rig, 1...Int64(plan.count - 1))
            let reported = try await waitFor(upTo: .seconds(30)) { probe.count >= 1 }
            #expect(reported, "stalls that keep coming back must end in a reported error")
            rig.decoder.quiesceForTesting()
            #expect(probe.count == 1)
            #expect(rig.decoder.composeStallCount == DualLayerVideoDecoder.maxComposeStallEpisodes + 1)
            #expect(probe.sawStoredError == [true])
        }

        @Test("a healthy stretch between stalls restarts the episode count; one frame short of it does not",
              arguments: [DualLayerVideoDecoder.composeHealthyFramesToResetStalls, DualLayerVideoDecoder.composeHealthyFramesToResetStalls - 1])
        func healthyStretchResetsTheEpisodeCount(healthyFrames: Int) async throws {
            let rig = makeRig(stallTimeout: 0.2)
            defer { rig.decoder.close() }
            let probe = installFatalProbe(rig)
            rig.composer.setTimedWaitHook { _ in nil }
            try feedPairs(rig, 0...0)
            try await waitFor { rig.composer.grantedCount == 1 }
            rig.composer.releaseFirst()
            try await waitFor { rig.deliveries.count == 1 }

            let limit = DualLayerVideoDecoder.maxComposeStallEpisodes
            var plan: [Bool] = [false]
            for _ in 0..<limit { plan += [true, false] }          // limit verdicts, the last followed by one healthy frame
            plan += Array(repeating: false, count: healthyFrames - 1)
            plan += [true, false]                                   // one more verdict
            let failing = failingCalls(for: plan)
            rig.composer.setTimedWaitHook { call in failing.contains(call) ? false : nil }
            try feedPairs(rig, 1...Int64(plan.count - 1))
            try await waitFor(upTo: .seconds(30)) { rig.deliveries.count == plan.count }
            rig.decoder.quiesceForTesting()
            #expect(rig.decoder.composeStallCount == limit + 1)
            if healthyFrames >= DualLayerVideoDecoder.composeHealthyFramesToResetStalls {
                #expect(probe.count == 0, "a full healthy stretch between stalls is a recovery, not a dead GPU")
            } else {
                #expect(probe.count == 1, "stalls without a full healthy stretch between them add up")
            }
        }

        @Test("flush() ends stall mode, and a new frame after it composes")
        func flushEndsStallMode() async throws {
            let rig = makeRig(stallTimeout: 0.2)
            defer { rig.decoder.close() }
            try await stallTheGpu(rig)
            #expect(rig.decoder.isComposeStalledForTesting)
            rig.decoder.flush()
            #expect(!rig.decoder.isComposeStalledForTesting)

            rig.composer.releaseFirst()
            try feedPairs(rig, 10...10)
            try await waitFor { rig.deliveries.count == 1 }
            rig.decoder.quiesceForTesting()
            #expect(rig.deliveries.count == 1, "nothing from before the flush is delivered after it")
            #expect(CMTimeCompare(rig.deliveries.points[0], Self.pts(10)) == 0)
            #expect(rig.deliveries.metadataPayloads == [Optional(Self.composedPayload)])
            #expect(rig.composer.grantedCount == 2)
            #expect(rig.decoder.composeStallCount == 1)
            #expect(!rig.decoder.isComposeStalledForTesting)
        }

        @Test("a stall verdict that races a flush is not carried into the new epoch")
        func verdictRacingAFlushIsDropped() async throws {
            let rig = makeRig(stallTimeout: 0.2)
            defer { rig.composer.releaseFirst(); rig.decoder.close() }
            let decoder = rig.decoder
            let flushed = DispatchSemaphore(value: 0)
            let hookRan = Flag()
            let flushFinishedInTime = Flag()
            // Between the last retired check and the verdict, with no lock held, a flush runs to the end on
            // another thread. If the head held a lock across its wait, or the verdict ignored the epoch, this
            // would hang or leave the new epoch in stall mode.
            decoder.stallVerdictHookForTesting = { [weak decoder] in
                guard let decoder, !hookRan.isSet else { return }
                hookRan.set()
                Thread.detachNewThread { decoder.flush(); flushed.signal() }
                if flushed.wait(timeout: .now() + 10) == .success { flushFinishedInTime.set() }
            }
            rig.composer.setInstantTimeouts(true)
            try feedPairs(rig, 0...1)
            try await waitFor { hookRan.isSet }
            try await waitFor { decoder.outstandingComposeRequestsForTesting == 1 }
            #expect(flushFinishedInTime.isSet, "flush() waited behind the compose queue")
            #expect(decoder.composeStallCount == 0)
            #expect(!decoder.isComposeStalledForTesting)
            #expect(!rig.fatal.isSet)
            rig.composer.releaseFirst()
            decoder.quiesceForTesting()
            #expect(rig.deliveries.count == 0, "nothing from before the flush is delivered after it")
        }

        @Test("close() releases a waiting feed and reports nothing")
        func closeReleasesTheFeedQuietly() async throws {
            let rig = makeRig(stallTimeout: Self.noStall)
            defer { rig.composer.releaseFirst(); rig.decoder.close() }
            try feedPairs(rig, 0...2)
            try await waitFor { rig.composer.acquireCallCount == 2 }

            let result = ResultBox()
            let decoder = rig.decoder
            let entryEpoch = decoder.feedEpochForTesting
            let feeder = Thread { result.set(decoder.waitForComposeBacklog(entryEpoch: entryEpoch)) }
            feeder.start()
            let early = try await waitFor(upTo: .milliseconds(150)) { result.value != nil }
            #expect(!early, "the feed did not wait for a full compose backlog")
            decoder.close()
            let returned = try await waitFor(upTo: .seconds(5)) { result.value != nil }
            #expect(returned && result.value == false)
            #expect(!rig.fatal.isSet, "teardown must not report an error")
        }

        @Test("a feed that passed the gate before a flush or close does not wait on the backlog", arguments: ["flush", "close"])
        func staleFeedDoesNotWait(how: String) async throws {
            let rig = makeRig(stallTimeout: Self.noStall)
            defer { rig.composer.releaseFirst(); rig.decoder.close() }
            try feedPairs(rig, 0...2)
            try await waitFor { rig.composer.acquireCallCount == 2 }
            let decoder = rig.decoder
            let staleEpoch = decoder.feedEpochForTesting
            if how == "flush" { decoder.flush() } else { decoder.close() }

            // The packet entered under the old epoch and only now reaches the gate.
            let result = ResultBox()
            let stale = Thread { result.set(decoder.waitForComposeBacklog(entryEpoch: staleEpoch)) }
            stale.start()
            let returned = try await waitFor(upTo: .seconds(5)) { result.value != nil }
            #expect(returned && result.value == false, "the stale feed waited on the backlog")

            if how == "flush" {
                // A feed of the new epoch still waits: the queued compositions have not left yet.
                let freshDone = Flag()
                let freshEpoch = decoder.feedEpochForTesting
                let fresh = Thread { decoder.waitForComposeBacklog(entryEpoch: freshEpoch); freshDone.set() }
                fresh.start()
                let early = try await waitFor(upTo: .milliseconds(150)) { freshDone.isSet }
                #expect(!early, "the new epoch's feed did not wait for the backlog")
                rig.composer.releaseFirst()
                try await waitFor { freshDone.isSet }
            }
        }

        @Test("a closed decoder's queued head leaves within one slice")
        func closedDecoderHeadLeavesWithinASlice() async throws {
            // A slice is 0.5 s; the verdict needs 2 s without a slot, which close() beats.
            let rig = makeRig(stallTimeout: 2)
            defer { rig.composer.releaseFirst(); rig.decoder.close() }
            try feedPairs(rig, 0...2)
            try await waitFor { rig.composer.grantedCount == 1 && rig.composer.acquireCallCount >= 2 }
            rig.decoder.close()
            let left = try await waitFor(upTo: .seconds(5)) { rig.decoder.outstandingComposeRequestsForTesting == 1 }
            #expect(left, "the queued head kept waiting for a slot after close()")
            // It left through the in-slice retired check, not by running out the stall slices.
            #expect(rig.composer.acquireCallCount < 1 + DualLayerVideoDecoder.composeStallSlices,
                    "the head ran through every stall slice instead of leaving at the retired check")
            #expect(rig.composer.grantedCount == 1, "only frame 0 ever held a slot")
            #expect(!rig.fatal.isSet)
        }

        @Test("a bypass queued behind a composition waiting for a slot goes out no later than the stall verdict")
        func bypassBehindAWaitingCompositionLeavesAtTheVerdict() async throws {
            let rig = makeRig(stallTimeout: 0.2)
            defer { rig.composer.releaseFirst(); rig.decoder.close() }
            try feedPairs(rig, 0...1)
            try await waitFor { rig.composer.grantedCount == 1 }
            try feedBypass(rig, frame: 2)
            // Frame 1 is the head and finds no slot; the verdict comes after 4 slices of 50 ms, and the bypass
            // behind it goes out once the head has.
            try await waitFor { rig.decoder.composeStallCount == 1 && rig.decoder.outstandingComposeRequestsForTesting == 1 }
            rig.composer.releaseFirst()
            rig.decoder.quiesceForTesting()
            try await waitFor { rig.deliveries.count == 3 }
            let points = rig.deliveries.points
            for (i, pts) in points.enumerated() { #expect(CMTimeCompare(pts, Self.pts(Int64(i))) == 0) }
            #expect(rig.deliveries.metadataPayloads == [Optional(Self.composedPayload), Optional(Self.baseLayerPayload), Optional(Self.baseLayerPayload)])
        }

        @Test("with a distant verdict, a bypass waits behind the composition at the head of the queue (documented head-of-line wait)")
        func bypassWaitsBehindTheHeadWhileNoVerdict() async throws {
            let rig = makeRig(stallTimeout: Self.noStall)
            defer { rig.composer.releaseFirst(); rig.decoder.close() }
            try feedPairs(rig, 0...1)
            try await waitFor { rig.composer.acquireCallCount == 2 }
            try feedBypass(rig, frame: 2)
            let leftEarly = try await waitFor(upTo: .milliseconds(150)) { rig.decoder.outstandingComposeRequestsForTesting == 1 }
            #expect(!leftEarly, "the bypass overtook the composition waiting for a slot")
            rig.composer.releaseFirst()
            rig.decoder.quiesceForTesting()
            try await waitFor { rig.deliveries.count == 3 }
            let points = rig.deliveries.points
            for (i, pts) in points.enumerated() { #expect(CMTimeCompare(pts, Self.pts(Int64(i))) == 0) }
        }

        private final class SummaryBox: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [(String, EngineLog.Level)] = []
            func record(_ line: String, _ level: EngineLog.Level) { lock.lock(); lines.append((line, level)); lock.unlock() }
            var last: (String, EngineLog.Level)? { lock.lock(); defer { lock.unlock() }; return lines.last }
        }

        @Test("the 1 Hz summary counts frames sent out in stall mode and goes out at info")
        func summaryCountsStalledBypasses() async throws {
            let rig = makeRig(stallTimeout: 0.2)
            defer { rig.composer.releaseFirst(); rig.decoder.close() }
            let summaries = SummaryBox()
            rig.decoder.summarySinkForTesting = { line, level in summaries.record(line, level) }
            nonisolated(unsafe) var now: TimeInterval = 100
            rig.decoder.summaryTimestampProviderForTesting = { now }
            try await stallTheGpu(rig)   // frames 1 and 2 left as the base layer
            rig.decoder.maybeEmitSummary()
            now = 102
            rig.decoder.maybeEmitSummary()
            let last = try #require(summaries.last)
            #expect(last.0.contains("bypassComposeStalled=2"), "\(last.0)")
            #expect(last.1 == .info)
            // Reset by the summary.
            now = 104
            rig.decoder.maybeEmitSummary()
            #expect(summaries.last?.0.contains("bypassComposeStalled=0") == true)
            #expect(summaries.last?.1 == .verbose)
        }

        @Test("ordering still holds across two gated compositions")
        func gatedCompositionsDeliverInOrder() async throws {
            let bl0 = try #require(Self.makeBuffer(width: 64, height: 64))
            let el0 = try #require(Self.makeBuffer(width: 32, height: 32))
            let bl1 = try #require(Self.makeBuffer(width: 64, height: 64))
            let el1 = try #require(Self.makeBuffer(width: 32, height: 32))

            let composer = GatedFakeComposer()
            let deliveries = Deliveries()
            let decoder = DualLayerVideoDecoder(composer: composer, composeStallTimeout: Self.noStall)
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
}
#endif
