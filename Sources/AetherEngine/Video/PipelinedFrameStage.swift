import Foundation
import CoreMedia
import CoreVideo
import Metal

/// One frame's GPU work, encoded and not yet committed. `PipelinedFrameStage` adds its completion handler
/// and commits it; a synchronous caller commits and waits. `finish()` reads the result once the work
/// completed: the GPU time in milliseconds, or the command buffer's error.
struct EncodedGPUWork: @unchecked Sendable {
    let commandBuffer: MTLCommandBuffer
    /// The plane textures (and their Core Video wrappers) the work reads and writes, held until it is done.
    let keepAlive: Any
    let failure: (MTLCommandBufferStatus, Error?) -> Error

    func finish() throws -> Double {
        withExtendedLifetime(keepAlive) {}
        guard commandBuffer.status == .completed else { throw failure(commandBuffer.status, commandBuffer.error) }
        return max(0, (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
    }

    /// Commits and waits on the calling thread, as the stages did before the pipeline.
    func commitAndWait() throws -> Double {
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return try finish()
    }
}

/// AE#957: a per-frame GPU stage (the upscaler, the tone map, any later frame chain) with up to `depth`
/// frames on the GPU at once, delivered in the order they came in.
///
/// A stage that commits one frame and waits for it leaves the GPU idle between frames. On an A12 Apple TV,
/// MetalFX 720p to 2160p took 17.7 ms per frame one at a time and 9.9 ms with two in flight (three gave
/// nothing more), measured 2026-11-15. So the decoder's frame handler hands each frame to `submit`, which
/// encodes it, commits it and returns; the frame is delivered from `deliveryQueue` when its work completed.
///
/// - Order: frames leave in `submit` order, pass-through frames included.
/// - Back-pressure: `submit` waits while `depth` frames are not yet delivered.
/// - Flush and end of stream: the host calls `settle()` right after every decoder flush or drain, so what
///   is still on the GPU is delivered before the renderer flushes or drains, as when the stage waited.
/// - Budget: `begin`'s completion gets the time the frame held the decoder's thread (waiting for a free
///   slot, then encoding). In steady state that is the stage's cost per frame, the number its overrun
///   check must compare with the frame interval.
final class PipelinedFrameStage: @unchecked Sendable {

    /// What a stage did with one frame.
    enum Begun {
        /// Deliver the original frame.
        case passThrough
        /// Deliver this buffer; nothing is on the GPU.
        case ready(CVPixelBuffer)
        /// Deliver what `complete` returns once `work` completed (nil: the original frame). `complete` gets
        /// the hold time in milliseconds and runs on a Metal completion thread.
        case gpu(EncodedGPUWork, complete: @Sendable (_ holdMs: Double) -> CVPixelBuffer?)
    }

    /// Two frames in flight: the A12 measurement above.
    static let defaultDepth = 2
    /// How long `settle()` waits for the frames in flight before it gives up (logged).
    static let settleTimeout = 2.0

    let depth: Int
    private let deliver: DecodedFrameHandler
    private let begin: (CVPixelBuffer, CMTime, Data?) -> Begun
    private let slots: DispatchSemaphore
    private let undelivered = DispatchGroup()
    private let deliveryQueue = DispatchQueue(label: "AetherEngine.PipelinedFrameStage.delivery", qos: .userInteractive)
    private let lock = NSLock()
    private var entries: [Entry] = []
    /// True while `drain` delivers entries it already took off `entries`.
    private var delivering = false

    private final class Entry: @unchecked Sendable {
        let original: CVPixelBuffer
        let pts: CMTime
        let hdr10Plus: Data?
        var output: CVPixelBuffer?
        var done = false
        init(original: CVPixelBuffer, pts: CMTime, hdr10Plus: Data?) {
            self.original = original
            self.pts = pts
            self.hdr10Plus = hdr10Plus
        }
    }

    /// `deliver` is the decoder's own frame handler; `begin` runs on the submitting thread.
    init(depth: Int = defaultDepth, deliver: @escaping DecodedFrameHandler,
         begin: @escaping (CVPixelBuffer, CMTime, Data?) -> Begun) {
        self.depth = max(1, depth)
        self.deliver = deliver
        self.begin = begin
        slots = DispatchSemaphore(value: self.depth)
    }

    /// The frame handler to give the decoder.
    var frameHandler: DecodedFrameHandler {
        { [self] buffer, pts, hdr10Plus in submit(buffer, pts: pts, hdr10Plus: hdr10Plus) }
    }

    func submit(_ buffer: CVPixelBuffer, pts: CMTime, hdr10Plus: Data?) {
        let start = DispatchTime.now().uptimeNanoseconds
        slots.wait()
        undelivered.enter()
        let entry = Entry(original: buffer, pts: pts, hdr10Plus: hdr10Plus)
        lock.lock()
        // Nothing ahead of it: a frame that needs no GPU goes out on this thread, as without the pipeline.
        let alone = entries.isEmpty && !delivering
        entries.append(entry)
        lock.unlock()

        switch begin(buffer, pts, hdr10Plus) {
        case .passThrough:
            finish(entry, output: nil, inline: alone)
        case let .ready(output):
            finish(entry, output: output, inline: alone)
        case let .gpu(work, complete):
            let holdMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            work.commandBuffer.addCompletedHandler { [self] _ in
                finish(entry, output: complete(holdMs), inline: false)
            }
            work.commandBuffer.commit()
        }
    }

    /// Delivers every frame still in flight, then returns. Call it after a decoder flush or drain, never
    /// from the delivery itself.
    func settle() {
        if undelivered.wait(timeout: .now() + Self.settleTimeout) == .timedOut {
            lock.lock(); let left = entries.count; lock.unlock()
            EngineLog.emit("[FramePipeline] settle: \(left) frame(s) still in flight after "
                           + "\(Int(Self.settleTimeout)) s", category: .swPlayback)
        }
    }

    /// Frames submitted and not yet delivered.
    var inFlight: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    private func finish(_ entry: Entry, output: CVPixelBuffer?, inline: Bool) {
        lock.lock()
        entry.output = output
        entry.done = true
        if inline, entries.first === entry, !delivering {
            entries.removeFirst()
            lock.unlock()
            hand(entry)
            return
        }
        lock.unlock()
        deliveryQueue.async { [self] in drain() }
    }

    /// Delivers the leading frames whose work is done, in order.
    private func drain() {
        while true {
            lock.lock()
            guard let head = entries.first, head.done else { delivering = false; lock.unlock(); return }
            entries.removeFirst()
            delivering = true
            lock.unlock()
            hand(head)
        }
    }

    private func hand(_ entry: Entry) {
        deliver(entry.output ?? entry.original, entry.pts, entry.hdr10Plus)
        slots.signal()
        undelivered.leave()
    }
}

/// Carries a value the compiler cannot prove `Sendable` into a `@Sendable` closure, where the code
/// guarantees it is not used from two threads at once (a frame buffer handed from encode to completion).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
