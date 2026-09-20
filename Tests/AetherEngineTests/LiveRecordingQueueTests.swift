import Testing
import Foundation
@testable import AetherEngine

/// The bounded handoff between the demux thread and the recording writer (AE#560).
///
/// `offerNeverBlocks` is the test this whole type exists for: a recording that cannot keep up is a
/// reported failure, but a demux thread parked on a slow disk is a stalled picture.
@Suite("Live recording queue")
struct LiveRecordingQueueTests {

    private final class Locked<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        func withLock<R>(_ body: (inout T) -> R) -> R {
            lock.lock(); defer { lock.unlock() }; return body(&value)
        }
    }

    /// A gate that, once opened, stays open for every waiter.
    ///
    /// A `DispatchSemaphore` is the wrong tool here and deadlocks the test: one `signal()` releases
    /// exactly one waiter, the drain then blocks again on the next item, and `finish()` waits on a
    /// pump that will never return.
    private final class Latch: @unchecked Sendable {
        private let condition = NSCondition()
        private var isOpen = false

        func wait() {
            condition.lock()
            while !isOpen { condition.wait() }
            condition.unlock()
        }

        func open() {
            condition.lock()
            isOpen = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private func packet(_ size: Int, pts: Int64 = 0) -> LiveRecordingQueue.QueuedPacket {
        LiveRecordingQueue.QueuedPacket(bytes: Data(repeating: 0x47, count: size),
                                        sourceStreamIndex: 0,
                                        pts: pts, dts: pts, duration: 0, isKeyframe: true)
    }

    @Test("offer returns immediately while the drain is stalled")
    func offerNeverBlocks() {
        let gate = Latch()
        let q = LiveRecordingQueue(ceilingBytes: 1 << 20) { _ in gate.wait() }
        // The first item enters the stalled drain; the rest queue behind it.
        _ = q.offer(packet(1024))
        let start = DispatchTime.now()
        for _ in 0..<200 { _ = q.offer(packet(1024)) }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        #expect(elapsedMs < 250, "offer must not wait on the drain; took \(elapsedMs) ms")
        gate.open()
        q.finish()
    }

    @Test("offer refuses and accounts the drop once the ceiling is reached")
    func ceilingRefusesAndAccounts() {
        let gate = Latch()
        let q = LiveRecordingQueue(ceilingBytes: 8192) { _ in gate.wait() }
        _ = q.offer(packet(1024))          // taken by the stalled drain
        var accepted = 0
        var refused = 0
        for _ in 0..<64 {
            if q.offer(packet(1024)) { accepted += 1 } else { refused += 1 }
        }
        #expect(refused > 0, "the ceiling must be reachable")
        #expect(accepted > 0, "the queue must accept up to its ceiling")
        #expect(q.droppedBytes == Int64(refused) * 1024)
        gate.open()
        q.finish()
    }

    @Test("a queue under its ceiling drains every packet in order")
    func drainsInOrder() {
        let seen = Locked<[Int64]>([])
        let q = LiveRecordingQueue(ceilingBytes: 1 << 20) { item in
            seen.withLock { $0.append(item.pts) }
        }
        for i in 0..<100 {
            #expect(q.offer(packet(64, pts: Int64(i))))
        }
        q.finish()
        #expect(seen.withLock { $0 } == (0..<100).map(Int64.init))
    }

    @Test("a finished queue refuses further packets instead of writing past the trailer")
    func finishedQueueRefuses() {
        let q = LiveRecordingQueue(ceilingBytes: 1 << 20) { _ in }
        #expect(q.offer(packet(64)))
        q.finish()
        #expect(q.offer(packet(64)) == false)
    }
}
