import Foundation
import Testing
import CoreMedia
import CoreVideo
import Metal
@testable import AetherEngine

/// AE#957: the GPU stages keep two frames in flight (`PipelinedFrameStage`). Each held frame here is a
/// `.later` step the test resumes with an empty command buffer, so the test decides when a frame can
/// complete. (A command buffer waiting on a shared event did not hold on GitHub's runner VMs.) Calls that
/// block (`submit` at the depth, `settle`) run on a thread of their own, never the test's.
@Suite("Pipelined frame stage delivers in order (AE#957)", .serialized, .timeLimit(.minutes(3)),
       .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct PipelinedFrameStageDeliversInOrderTests {

    private final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(pts: Int64, upscaled: Bool)] = []
        func add(_ pts: CMTime, upscaled: Bool) { lock.lock(); items.append((pts.value, upscaled)); lock.unlock() }
        var pts: [Int64] { lock.lock(); defer { lock.unlock() }; return items.map(\.pts) }
        var upscaled: [Bool] { lock.lock(); defer { lock.unlock() }; return items.map(\.upscaled) }
    }

    /// A GPU frame held until `release(value)`: a `.later` step that the release resumes with an empty
    /// command buffer, in submit order. `complete` hands back `output` and records the hold time.
    private final class Gate: @unchecked Sendable {
        let queue: MTLCommandQueue
        init() { queue = MTLCreateSystemDefaultDevice()!.makeCommandQueue()! }
        private let lock = NSLock()
        private var holds: [Double] = []
        private var released: UInt64 = 0
        private var waiting: [(value: UInt64, next: PipelinedFrameStage.Begun,
                               resume: @Sendable (PipelinedFrameStage.Begun) -> Void)] = []
        var holdTimes: [Double] { lock.lock(); defer { lock.unlock() }; return holds }

        /// GPU work that completes as soon as it is committed.
        func gpu(output: CVPixelBuffer, fails: Bool = false) -> PipelinedFrameStage.Begun {
            let work = EncodedGPUWork(commandBuffer: queue.makeCommandBuffer()!, keepAlive: ()) { _, _ in
                NSError(domain: "test", code: 1)
            }
            let out = UncheckedSendable(output)
            return .gpu(work) { [self] hold in
                lock.lock(); holds.append(hold); lock.unlock()
                return fails ? nil : out.value
            }
        }

        func work(waitingFor value: UInt64, output: CVPixelBuffer, fails: Bool = false) -> PipelinedFrameStage.Begun {
            let next = gpu(output: output, fails: fails)
            return .later { [self] resume in
                lock.lock()
                guard value > released else { lock.unlock(); resume(next); return }
                waiting.append((value, next, resume))
                lock.unlock()
            }
        }

        func release(_ value: UInt64) {
            lock.lock()
            released = max(released, value)
            let ready = waiting.filter { $0.value <= value }
            waiting.removeAll { $0.value <= value }
            lock.unlock()
            for w in ready { w.resume(w.next) }
        }
    }

    private static func frame() -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &b)
        return b!
    }

    private static func pts(_ n: Int64) -> CMTime { CMTime(value: n, timescale: 24) }

    /// Starts `body` on a thread of its own and returns a flag that turns true when it returned.
    private static func onThread(_ body: @escaping @Sendable () -> Void) -> Flag {
        let flag = Flag()
        Thread { body(); flag.set() }.start()
        return flag
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// A pass-through frame behind a GPU frame waits for it: frames leave in the order they came in.
    @Test func issue957APassThroughFrameWaitsForTheGPUFrameAheadOfIt() async throws {
        let gate = Gate()
        let delivered = Delivered()
        let upscaled = UncheckedSendable(Self.frame()), original = UncheckedSendable(Self.frame())
        let pipeline = PipelinedFrameStage(deliver: { buffer, pts, _ in delivered.add(pts, upscaled: buffer === upscaled.value) },
                                           begin: { _, pts, _ in
            pts.value == 1 ? gate.work(waitingFor: 1, output: upscaled.value) : .passThrough
        })
        let submitted = Self.onThread {
            pipeline.submit(original.value, pts: Self.pts(1), hdr10Plus: nil)
            pipeline.submit(original.value, pts: Self.pts(2), hdr10Plus: nil)
        }
        try await waitFor { submitted.isSet }
        // Neither may leave while frame 1 is still on the GPU.
        let early1 = try await waitFor(upTo: .milliseconds(200)) { !delivered.pts.isEmpty }
        #expect(!early1)
        #expect(pipeline.inFlight == 2)
        gate.release(1)
        try await waitFor { delivered.pts.count == 2 }
        #expect(delivered.pts == [1, 2])
        #expect(delivered.upscaled == [true, false])
        #expect(pipeline.inFlight == 0)
    }

    /// With nothing ahead of it, a frame that needs no GPU goes out on the submitting thread, as before
    /// the pipeline: a stage that is still building or switched off adds no queue hop.
    @Test func issue957AFrameWithNothingAheadGoesOutInline() {
        let delivered = Delivered()
        let pipeline = PipelinedFrameStage(deliver: { _, pts, _ in delivered.add(pts, upscaled: false) },
                                           begin: { _, _, _ in .passThrough })
        pipeline.submit(Self.frame(), pts: Self.pts(7), hdr10Plus: nil)
        #expect(delivered.pts == [7])
    }

    /// `submit` waits while `depth` frames are undelivered: the GPU never holds more than two.
    @Test func issue957SubmitWaitsAtTheDepth() async throws {
        let gate = Gate()
        let delivered = Delivered()
        let pipeline = PipelinedFrameStage(deliver: { _, pts, _ in delivered.add(pts, upscaled: true) },
                                           begin: { _, pts, _ in gate.work(waitingFor: UInt64(pts.value), output: Self.frame()) })
        #expect(pipeline.depth == PipelinedFrameStage.defaultDepth && pipeline.depth == 2)
        let input = UncheckedSendable(Self.frame())
        let third = Self.onThread {
            for n in 1...3 { pipeline.submit(input.value, pts: Self.pts(Int64(n)), hdr10Plus: nil) }
        }
        try await waitFor { pipeline.inFlight == 2 }
        let early2 = try await waitFor(upTo: .milliseconds(200)) { third.isSet }
        #expect(!early2)
        gate.release(1)
        try await waitFor { third.isSet }
        gate.release(3)
        try await waitFor { delivered.pts.count == 3 }
        #expect(delivered.pts == [1, 2, 3])
        // The third frame waited for a slot, at least through the 200 ms window, and its hold time says
        // so. Completions on one queue come in order, so the third hold time is frame 3's.
        #expect(gate.holdTimes.count == 3)
        #expect((gate.holdTimes.last ?? 0) >= 150)
    }

    /// `settle()` returns once every frame in flight is delivered; the host calls it after a decoder
    /// flush, so nothing from before a seek reaches the renderer after its flush.
    @Test func issue957SettleDeliversWhatIsInFlight() async throws {
        let gate = Gate()
        let delivered = Delivered()
        // A long timeout: the test checks that settle waits for the release, not how long it waits.
        let pipeline = PipelinedFrameStage(settleTimeout: 30,
                                           deliver: { _, pts, _ in delivered.add(pts, upscaled: true) },
                                           begin: { _, pts, _ in gate.work(waitingFor: 1, output: Self.frame()) })
        let input = UncheckedSendable(Self.frame())
        let submitted = Self.onThread {
            pipeline.submit(input.value, pts: Self.pts(1), hdr10Plus: nil)
            pipeline.submit(input.value, pts: Self.pts(2), hdr10Plus: nil)
        }
        try await waitFor { submitted.isSet }
        let settled = Self.onThread { pipeline.settle() }
        let early3 = try await waitFor(upTo: .milliseconds(200)) { settled.isSet }
        #expect(!early3)
        gate.release(1)
        try await waitFor { settled.isSet }
        #expect(delivered.pts == [1, 2])
    }

    /// AE#491 through the pipeline: a frame keeps the generation it was decoded under. A seek while it is on
    /// the GPU drops it at delivery, and a frame already stale when it is handed over never reaches the GPU.
    @Test func issue957AFrameFromBeforeASeekIsNotDelivered() async throws {
        let gate = Gate()
        let delivered = Delivered()
        let generations = Generations()
        let begun = Flag()
        let pipeline = PipelinedFrameStage(stamp: { generations.decoded },
                                           isCurrent: { generations.live == $0 },
                                           deliver: { _, pts, _ in delivered.add(pts, upscaled: true) },
                                           begin: { _, _, _ in begun.set(); return gate.work(waitingFor: 1, output: Self.frame()) })
        pipeline.submit(Self.frame(), pts: Self.pts(1), hdr10Plus: nil)
        // The seek: the live generation moves on, then the demux loop reads the new position's packets.
        generations.live = 1
        generations.decoded = 1
        gate.release(1)
        try await waitFor { pipeline.inFlight == 0 }
        #expect(delivered.pts.isEmpty)

        let stale = Generations()
        stale.live = 1
        let begunStale = Flag()
        let late = PipelinedFrameStage(stamp: { stale.decoded }, isCurrent: { stale.live == $0 },
                                       deliver: { _, pts, _ in delivered.add(pts, upscaled: true) },
                                       begin: { _, _, _ in begunStale.set(); return .passThrough })
        late.submit(Self.frame(), pts: Self.pts(2), hdr10Plus: nil)
        #expect(!begunStale.isSet)
        #expect(delivered.pts.isEmpty)
        #expect(begun.isSet)
    }

    private final class Generations: @unchecked Sendable {
        private let lock = NSLock()
        private var _live: UInt64 = 0, _decoded: UInt64 = 0
        var live: UInt64 { get { lock.lock(); defer { lock.unlock() }; return _live } set { lock.lock(); _live = newValue; lock.unlock() } }
        var decoded: UInt64 { get { lock.lock(); defer { lock.unlock() }; return _decoded } set { lock.lock(); _decoded = newValue; lock.unlock() } }
    }

    /// A stage whose first step runs off the submitting thread (the VideoToolbox ML pass) lets `submit`
    /// return at once, and its frame still leaves ahead of the pass-through frame behind it.
    @Test func issue957AFrameWhoseFirstStepRunsLaterKeepsItsPlace() async throws {
        let gate = Gate()
        let delivered = Delivered()
        let resume = ResumeBox()
        let upscaled = UncheckedSendable(Self.frame()), original = UncheckedSendable(Self.frame())
        let pipeline = PipelinedFrameStage(deliver: { buffer, pts, _ in delivered.add(pts, upscaled: buffer === upscaled.value) },
                                           begin: { _, pts, _ in
            pts.value == 1 ? .later { resume.set($0) } : .passThrough
        })
        let submitted = Self.onThread {
            pipeline.submit(original.value, pts: Self.pts(1), hdr10Plus: nil)
            pipeline.submit(original.value, pts: Self.pts(2), hdr10Plus: nil)
        }
        try await waitFor { submitted.isSet }
        #expect(pipeline.inFlight == 2 && delivered.pts.isEmpty)
        // The step answers from another thread with GPU work, which completes in turn.
        resume.call(gate.gpu(output: upscaled.value))
        try await waitFor { delivered.pts.count == 2 }
        #expect(delivered.pts == [1, 2])
        #expect(delivered.upscaled == [true, false])
        #expect(gate.holdTimes.count == 1)
    }

    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resume: (@Sendable (PipelinedFrameStage.Begun) -> Void)?
        func set(_ r: @escaping @Sendable (PipelinedFrameStage.Begun) -> Void) { lock.lock(); resume = r; lock.unlock() }
        func call(_ next: PipelinedFrameStage.Begun) {
            lock.lock(); let r = resume; lock.unlock()
            r?(next)
        }
    }

    /// A frame whose GPU work failed goes out as the original.
    @Test func issue957AFailedFrameGoesOutAsTheOriginal() async throws {
        let gate = Gate()
        let original = UncheckedSendable(Self.frame())
        let delivered = Delivered()
        let pipeline = PipelinedFrameStage(deliver: { buffer, pts, _ in delivered.add(pts, upscaled: buffer !== original.value) },
                                           begin: { _, _, _ in gate.work(waitingFor: 1, output: Self.frame(), fails: true) })
        gate.release(1)
        pipeline.submit(original.value, pts: Self.pts(1), hdr10Plus: nil)
        try await waitFor { delivered.pts.count == 1 }
        #expect(delivered.upscaled == [false])
    }
}
