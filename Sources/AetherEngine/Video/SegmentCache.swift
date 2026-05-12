import Foundation

/// Thread-safe LRU cache for HLS-fMP4 segment bytes plus a pinned
/// init.mp4 slot. Backs `HLSSegmentProducer` (the writer side) and
/// `VideoSegmentProvider` (the AVPlayer-facing reader side).
///
/// `fetch(index:)` blocks the caller until the producer stores that
/// index, the deadline lapses, or the cache is closed. This lets the
/// HLSLocalServer thread sleep cheaply on AVPlayer GETs that arrive
/// before the muxer has produced the requested segment, rather than
/// busy-polling.
final class SegmentCache {

    private let condition = NSCondition()
    private let capacity: Int

    /// LRU storage. `order` is most-recent-last; the front is evicted
    /// when `entries.count > capacity`.
    private var entries: [Int: Data] = [:]
    private var order: [Int] = []

    /// Pinned init segment. Never evicted — identical bytes are valid
    /// for every fragment in the session (and across producer restarts,
    /// because the same stream configs deterministically reproduce the
    /// same moov / track IDs).
    private var initSegment: Data?

    /// True once `close()` has been called. Pending `fetch` calls wake
    /// up and return nil instead of looping forever.
    private var closed = false

    init(capacity: Int = 30) {
        self.capacity = capacity
    }

    // MARK: - Writer side

    func setInit(_ data: Data) {
        condition.lock()
        initSegment = data
        condition.broadcast()
        condition.unlock()
    }

    func store(index: Int, data: Data) {
        condition.lock()
        defer { condition.unlock() }
        if entries[index] != nil {
            order.removeAll(where: { $0 == index })
        }
        entries[index] = data
        order.append(index)
        while order.count > capacity {
            let oldest = order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        condition.broadcast()
    }

    func close() {
        condition.lock()
        closed = true
        entries.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        initSegment = nil
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Reader side

    /// Non-blocking lookup. Updates LRU recency on hit.
    func peek(index: Int) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        return entries[index]
    }

    /// Blocking lookup. Returns nil on timeout, on close, or when the
    /// producer never stores this index. Bumps LRU recency on hit.
    func fetch(index: Int, timeout: TimeInterval = 15.0) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        if let hit = entries[index] {
            touch(index: index)
            return hit
        }
        if closed { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while !closed, entries[index] == nil {
            if !condition.wait(until: deadline) { break }
        }
        if let hit = entries[index] {
            touch(index: index)
            return hit
        }
        return nil
    }

    /// Blocking init lookup. Same semantics as `fetch(index:)` but for
    /// the pinned init segment.
    func fetchInit(timeout: TimeInterval = 15.0) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        if let i = initSegment { return i }
        if closed { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while !closed, initSegment == nil {
            if !condition.wait(until: deadline) { break }
        }
        return initSegment
    }

    // MARK: - Diagnostics

    /// (lowestIndex, highestIndex) currently held, or nil when empty.
    /// Used by the restart-decision logic in Phase B.
    func indexRange() -> (Int, Int)? {
        condition.lock()
        defer { condition.unlock() }
        guard !entries.isEmpty else { return nil }
        let keys = entries.keys
        return (keys.min()!, keys.max()!)
    }

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return entries.count
    }

    // MARK: - Internal

    private func touch(index: Int) {
        order.removeAll(where: { $0 == index })
        order.append(index)
    }
}
