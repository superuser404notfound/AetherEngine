// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import CoreVideo
import Foundation
import Metal
@testable import AetherEngine

/// `composeAsync` is the playback path: it must produce exactly what the blocking
/// `compose` produces, fire its completion exactly once per call, and never let
/// more than `maxFramesInFlight` compositions be outstanding.
@Suite(.offCooperativePool, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct DoviComposeAsyncTests {

    private static func makeBuffer(width: Int, height: Int, fill: UInt16) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                         [kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                                         &out)
        guard status == kCVReturnSuccess, let buf = out else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buf) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buf, plane) else { continue }
            let rows = CVPixelBufferGetHeightOfPlane(buf, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buf, plane)
            for r in 0..<rows {
                let row = base.advanced(by: r * stride).assumingMemoryBound(to: UInt16.self)
                for c in 0..<(stride / 2) { row[c] = fill }
            }
        }
        return buf
    }

    /// P010 carries the 10 bits in the high end of each 16-bit sample, so compare
    /// the words themselves rather than any derived value.
    private static func lumaWords(_ buffer: CVPixelBuffer) -> [UInt16] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return [] }
        let rows = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var out: [UInt16] = []
        out.reserveCapacity(rows * (stride / 2))
        for r in 0..<rows {
            let row = base.advanced(by: r * stride).assumingMemoryBound(to: UInt16.self)
            for c in 0..<(stride / 2) { out.append(row[c]) }
        }
        return out
    }

    /// Defaults, resized to the small test planes. Only the dimensions matter
    /// here — the question is the plumbing, not the curve.
    private static func identityParams(blW: Int, blH: Int, elW: Int, elH: Int) -> DoviMetalParams {
        var p = DoviMetalParams()
        p.blWidth = UInt32(blW)
        p.blHeight = UInt32(blH)
        p.elWidth = UInt32(elW)
        p.elHeight = UInt32(elH)
        return p
    }

    @Test("a command buffer that fails delivers a failure, not the half-written destination")
    func gpuErrorIsAFailure() async throws {
        let composer = try #require(DoviFelComposer())
        guard let bl = Self.makeBuffer(width: 256, height: 256, fill: 0x8000),
              let el = Self.makeBuffer(width: 128, height: 128, fill: 0x4000) else { return }
        let params = Self.identityParams(blW: 256, blH: 256, elW: 128, elH: 128)
        composer.forcedCommandBufferFailure.withLock { $0 = true }

        #expect(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 1) == nil)
        let delivered: Bool = await withCheckedContinuation { cont in
            composer.composeAsync(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 1) { out in
                cont.resume(returning: out != nil)
            }
        }
        #expect(!delivered)

        // The slot and the pool were given back: composing works again once the fault is gone.
        composer.forcedCommandBufferFailure.withLock { $0 = false }
        #expect(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 2) != nil)
    }

    @Test("after releaseOutputPool a composition is refused, its slot is returned and no pool is rebuilt",
          .timeLimit(.minutes(1)))
    func composeAfterTeardownIsRefused() async throws {
        let composer = try #require(DoviFelComposer())
        let bl = try #require(Self.makeBuffer(width: 256, height: 256, fill: 0x8000))
        let el = try #require(Self.makeBuffer(width: 128, height: 128, fill: 0x4000))
        let params = Self.identityParams(blW: 256, blH: 256, elW: 128, elH: 128)
        #expect(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 1) != nil)

        composer.releaseOutputPool()
        #expect(composer.allocatedPoolBuffers == 0)

        #expect(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 2) == nil)
        // More refusals than there are in-flight slots: a leaked slot would block here for good.
        for frame in 0..<(DoviFelComposer.maxFramesInFlight + 3) {
            let delivered: Bool = await withCheckedContinuation { cont in
                composer.composeAsync(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: UInt32(frame)) { out in
                    cont.resume(returning: out != nil)
                }
            }
            #expect(!delivered)
        }
        #expect(composer.allocatedPoolBuffers == 0, "a pool was rebuilt after teardown")
    }

    @Test("pool creation is refused once torn down, whatever the caller saw before", .timeLimit(.minutes(1)))
    func poolCreationAfterTeardownIsRefused() throws {
        let composer = try #require(DoviFelComposer())
        #expect(composer.ensurePoolForTesting(width: 256, height: 256) != nil)
        composer.releaseOutputPool()
        // The state a racing compose is in when teardown lands after its own look and before its pool request.
        #expect(composer.ensurePoolForTesting(width: 256, height: 256) == nil)
        #expect(composer.ensurePoolForTesting(width: 512, height: 512) == nil)
        #expect(composer.allocatedPoolBuffers == 0)
    }

    @Test("the blocking compose waits for an in-flight slot like composeAsync does", .timeLimit(.minutes(1)))
    func blockingComposeTakesAnInFlightSlot() throws {
        final class Box: @unchecked Sendable { let done = DispatchSemaphore(value: 0); var result: Bool? }
        let composer = try #require(DoviFelComposer())
        nonisolated(unsafe) let bl = try #require(Self.makeBuffer(width: 256, height: 256, fill: 0x8000))
        nonisolated(unsafe) let el = try #require(Self.makeBuffer(width: 128, height: 128, fill: 0x4000))
        let params = Self.identityParams(blW: 256, blH: 256, elW: 128, elH: 128)
        for _ in 0..<DoviFelComposer.maxFramesInFlight { composer.acquireSlot() }

        let box = Box()
        Thread.detachNewThread {
            box.result = composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 1) != nil
            box.done.signal()
        }
        #expect(box.done.wait(timeout: .now() + 0.3) == .timedOut, "compose ran without holding an in-flight slot")
        composer.releaseSlot()
        #expect(box.done.wait(timeout: .now() + 10) == .success)
        #expect(box.result == true)
        for _ in 1..<DoviFelComposer.maxFramesInFlight { composer.releaseSlot() }
    }

    @Test("composeAsync matches the blocking compose bit for bit")
    func asyncMatchesSync() async throws {
        let composer = try #require(DoviFelComposer())
        guard let bl = Self.makeBuffer(width: 256, height: 256, fill: 0x8000),
              let el = Self.makeBuffer(width: 128, height: 128, fill: 0x4000) else { return }
        let params = Self.identityParams(blW: 256, blH: 256, elW: 128, elH: 128)

        guard let syncOut = composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 7) else {
            Issue.record("blocking compose returned nil")
            return
        }
        let expected = Self.lumaWords(syncOut)

        let got: [UInt16] = await withCheckedContinuation { cont in
            composer.composeAsync(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 7) { out in
                cont.resume(returning: out.map { Self.lumaWords($0) } ?? [])
            }
        }

        #expect(!expected.isEmpty)
        #expect(got == expected)
    }

    @Test("every composeAsync call completes exactly once, and no more than maxFramesInFlight are outstanding",
          .timeLimit(.minutes(1)))
    func completionsAreExactlyOnceAndBounded() async throws {
        let composer = try #require(DoviFelComposer())
        guard let bl = Self.makeBuffer(width: 256, height: 256, fill: 0x8000),
              let el = Self.makeBuffer(width: 128, height: 128, fill: 0x4000) else { return }
        let params = Self.identityParams(blW: 256, blH: 256, elW: 128, elH: 128)

        let frames = 40
        let counter = Counter()
        // Issued from this thread the way the decoder issues them: the semaphore
        // inside composeAsync is what stops the loop from running away, so a
        // deadlock or a lost completion hangs here rather than passing quietly.
        //
        // The bound is on the GPU slots, read from the composer's own counter. "Issued minus
        // delivered" is not bounded: a retired frame waits on the delivery queue, which a loaded
        // runner can starve (CI measured 18 outstanding against a bound of 7).
        //
        // The loop runs on a thread of its own: `composeAsync` parks in a semaphore, which the
        // `.timeLimit` trait cannot interrupt on the test's own thread.
        let buffers = Buffers(bl: bl, el: el)
        Thread.detachNewThread {
            for i in 0..<frames {
                counter.issue()
                composer.composeAsync(baseBuffer: buffers.bl, enhancementBuffer: buffers.el, params: params, frameIndex: UInt32(i)) { out in
                    counter.record(nonNil: out != nil)
                }
            }
        }

        try await waitFor { counter.completed == frames }
        #expect(counter.completed == frames)
        #expect(counter.nonNil == frames)
        let peakSlots = composer.takePeakSlotsInUse()
        #expect(peakSlots >= 1)
        #expect(peakSlots <= DoviFelComposer.maxFramesInFlight)
    }

    /// The decoder calls `composeAsync` with its own recursive lock held, and the
    /// completion takes that same lock to deliver in order. Metal runs completion
    /// handlers on ONE serial queue, so a handler that blocks on the caller's lock
    /// also stops every later handler - including the `inFlight.signal()` the
    /// blocked caller is waiting for. On device that deadlocked after about ten
    /// seconds of playback: the demux thread parked inside the decoder, packets
    /// pinned, `enq=+0`, and the session still reporting `rendering`.
    ///
    /// The completion takes the same lock the issuing side holds across the call.
    /// That is what the real one does (it hands the frame to the display layer),
    /// and a `composeAsync` that waits for its completion while the caller holds
    /// the lock deadlocks regardless of timing.
    @Test("composeAsync makes progress while the caller holds a lock the completion also needs",
          .timeLimit(.minutes(1)))
    func doesNotDeadlockAgainstTheCallersLock() async throws {
        let composer = try #require(DoviFelComposer())
        guard let bl = Self.makeBuffer(width: 256, height: 256, fill: 0x8000),
              let el = Self.makeBuffer(width: 128, height: 128, fill: 0x4000) else { return }
        let params = Self.identityParams(blW: 256, blH: 256, elW: 128, elH: 128)

        let lock = NSRecursiveLock()
        let counter = Counter()
        let frames = 24
        // Synchronous, on a thread of its own: `NSRecursiveLock.lock()` is unavailable from an
        // async context, a lock held across the call is the whole point here, and a deadlock must
        // park that thread rather than the test's, so the `.timeLimit` trait can report it.
        let buffers = Buffers(bl: bl, el: el)
        // At most three compositions outstanding, as the decoder's own in-flight limit does: it keeps
        // the output pool from running dry (a nil output) without pacing by the wall clock.
        let inFlight = DispatchSemaphore(value: 3)
        @Sendable func issueUnderLock() {
            for i in 0..<frames {
                inFlight.wait()
                lock.lock()
                counter.issue()
                composer.composeAsync(baseBuffer: buffers.bl, enhancementBuffer: buffers.el,
                                      params: params, frameIndex: UInt32(i)) { out in
                    lock.lock()
                    counter.record(nonNil: out != nil)
                    lock.unlock()
                    inFlight.signal()
                }
                lock.unlock()
            }
        }
        Thread.detachNewThread { issueUnderLock() }

        try await waitFor { counter.completed == frames }
        #expect(counter.completed == frames)
        #expect(counter.nonNil == frames)
    }

    /// Hands the test's two buffers to the issuing thread; nothing else touches them meanwhile.
    private struct Buffers: @unchecked Sendable {
        let bl: CVPixelBuffer
        let el: CVPixelBuffer
    }

    /// Tracks completions and, from the issuing side's point of view, how many
    /// compositions were in flight at once.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _completed = 0
        private var _nonNil = 0
        private var _issued = 0
        private var _peak = 0

        var completed: Int { lock.lock(); defer { lock.unlock() }; return _completed }
        var nonNil: Int { lock.lock(); defer { lock.unlock() }; return _nonNil }
        var peakOutstanding: Int { lock.lock(); defer { lock.unlock() }; return _peak }

        func issue() {
            lock.lock(); _issued += 1; _peak = max(_peak, _issued - _completed); lock.unlock()
        }

        func record(nonNil: Bool) {
            lock.lock(); _completed += 1; if nonNil { _nonNil += 1 }; lock.unlock()
        }
    }
}
#endif
