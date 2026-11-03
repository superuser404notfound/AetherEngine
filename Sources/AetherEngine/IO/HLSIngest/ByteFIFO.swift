import Foundation

/// Bounded blocking byte queue between the HLS fetch loop (writer) and demux thread (reader). NSCondition-based; `finish()` signals EOF, `cancel()` signals error. Capacity is a soft bound: write blocks while at/above capacity then appends the whole chunk (overshoot = at most one chunk).
///
/// Storage is a queue of whole written chunks plus a head offset into the front one, the same shape
/// `HLSVODIngestReader` uses: a consumed chunk is dropped with `Array.removeFirst` (an Array op, not
/// `Data.removeFirst`'s slice-leak, AetherEngine 70430de). Earlier this was one `Data` re-based with
/// `subdata` on every read, which re-copies whatever is still queued: draining a full 16 MB FIFO in
/// 256 KB reads did about 64 reads averaging an 8 MB copy each, roughly 512 MB of memcpy for 16 MB
/// delivered (audit NET-8).
final class ByteFIFO: @unchecked Sendable {
    private let capacity: Int
    private let condition = NSCondition()
    private var queue: [Data] = []
    private var headOffset = 0
    private var pendingCount = 0
    private var finished = false
    private var cancelled = false
    /// Callers parked in `read` or `write`, guarded by the condition above. A reader from another
    /// thread only gets the lock while a caller sits in `wait()`, so a non-zero read proves the
    /// park: that is what a test needs before it feeds or cancels the queue, and a sleep long
    /// enough to "probably" have parked the caller is a margin against scheduling instead.
    private var parked = 0
    var parkedWaiterCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return parked
    }

    /// AE#684: nothing queued and a caller waiting for more. A writer only parks at capacity, so with
    /// the queue empty the parked caller is the reader, and everything written so far is consumed.
    var isEmptyWithReaderParked: Bool {
        condition.lock()
        defer { condition.unlock() }
        return queue.isEmpty && parked > 0 && !finished && !cancelled
    }

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Append, blocking while at capacity. Returns false when finished or cancelled.
    func write(_ data: Data) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        // Empty writes neither occupy capacity nor make a reader's EOF condition true.
        if data.isEmpty { return !finished && !cancelled }
        parked += 1
        while pendingCount >= capacity && !finished && !cancelled {
            condition.wait()
        }
        parked -= 1
        if finished || cancelled { return false }
        queue.append(data)
        pendingCount += data.count
        condition.broadcast()
        return true
    }

    /// Blocking read. Returns: >0 bytes copied; 0 = EOF (finished + drained); -1 = cancelled or invalid length.
    func read(into buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        guard maxLength > 0 else { return -1 }
        condition.lock()
        defer { condition.unlock() }
        parked += 1
        while queue.isEmpty && !finished && !cancelled {
            condition.wait()
        }
        parked -= 1
        if cancelled { return -1 }
        guard !queue.isEmpty else { return 0 } // finished + drained

        var copied = 0
        while copied < maxLength, !queue.isEmpty {
            let available = queue[0].count - headOffset
            let n = min(maxLength - copied, available)
            queue[0].withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                buffer.advanced(by: copied).update(
                    from: base.assumingMemoryBound(to: UInt8.self).advanced(by: headOffset), count: n)
            }
            headOffset += n
            copied += n
            pendingCount -= n
            if headOffset == queue[0].count {
                queue.removeFirst()
                headOffset = 0
            }
        }
        condition.broadcast()
        return copied
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}
