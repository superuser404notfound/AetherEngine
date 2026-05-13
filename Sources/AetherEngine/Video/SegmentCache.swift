import Foundation

/// Sliding-window cache for HLS-fMP4 segment bytes plus a pinned
/// init.mp4 slot. Indexed by absolute segment number; eviction is
/// index-window-based, centred on the highest segment AVPlayer has
/// actually fetched (`highWaterFetchIndex`).
///
/// Window semantics replace the earlier LRU-by-access scheme. LRU was
/// wrong here: the producer racing ahead would write seg N and touch
/// it as "recent"; AVPlayer fetching seg M (M < N) would touch M as
/// "more recent"; the producer's older unfetched stores for indices
/// between M and N then aged toward eviction even though AVPlayer was
/// about to need them in sequential playback. Index-window eviction
/// keeps a tight band `[highWater - backwardWindow, highWater +
/// forwardWindow]` regardless of when the entries were created, so
/// AVPlayer's next-up segments stay resident.
///
/// The producer pauses (via `awaitFetchHighWater`) once it's
/// `forwardWindow` segments past `highWaterFetchIndex`; the
/// `bufferAheadSegments` constant on `HLSSegmentProducer` matches
/// that, so the muxer never writes beyond the cache's forward edge.
final class SegmentCache {

    private let condition = NSCondition()

    /// How many segments past `highWaterFetchIndex` the cache keeps
    /// resident. The producer's backpressure setting uses the same
    /// number so the cache never sees a write past this edge.
    private let forwardWindow: Int

    /// How many segments behind `highWaterFetchIndex` the cache keeps
    /// resident. Bounds the cheap-backward-scrub distance: smaller
    /// scrubs hit cache, larger ones trigger a producer restart.
    private let backwardWindow: Int

    private var entries: [Int: Data] = [:]

    /// Pinned init segment. Never evicted — identical bytes are valid
    /// for every fragment in the session (and across producer restarts,
    /// because the same stream configs deterministically reproduce the
    /// same moov / track IDs).
    private var initSegment: Data?

    /// True once `close()` has been called. Pending `fetch` calls wake
    /// up and return nil instead of looping forever.
    private var closed = false

    /// Highest absolute segment index AVPlayer has actually fetched
    /// (via `fetch` or `peek` hits). The producer pump uses this to
    /// pace itself; cache pruning uses it as the window centre.
    private var highWaterFetchIndex: Int = -1

    init(forwardWindow: Int = 20, backwardWindow: Int = 15) {
        self.forwardWindow = forwardWindow
        self.backwardWindow = backwardWindow
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
        entries[index] = data
        pruneOutsideWindow()
        condition.broadcast()
    }

    func close() {
        condition.lock()
        closed = true
        entries.removeAll(keepingCapacity: false)
        initSegment = nil
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Reader side

    /// Non-blocking lookup. Raises the producer-backpressure high-water
    /// mark on hit, which slides the cache window forward and may evict
    /// stale back-edge entries.
    func peek(index: Int) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        let hit = entries[index]
        if hit != nil { markFetched(index: index) }
        return hit
    }

    /// Blocking lookup. Returns nil on timeout, on close, or when the
    /// producer never stores this index. Raises the high-water mark
    /// on hit, same as `peek`.
    func fetch(index: Int, timeout: TimeInterval = 15.0) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        if let hit = entries[index] {
            markFetched(index: index)
            return hit
        }
        if closed { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while !closed, entries[index] == nil {
            if !condition.wait(until: deadline) { break }
        }
        if let hit = entries[index] {
            markFetched(index: index)
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

    /// Pump-side backpressure: block until AVPlayer's fetch high-water
    /// reaches `target`, or `timeout` elapses, or the cache is closed.
    /// The producer calls this right after storing segment N with
    /// `target = N - forwardWindow` so it can't race more than
    /// `forwardWindow` segments past AVPlayer's actual playhead.
    /// Returns `true` on progress, `false` on close / timeout.
    func awaitFetchHighWater(reaching target: Int, timeout: TimeInterval = 60.0) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if highWaterFetchIndex >= target { return true }
        if closed { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while !closed, highWaterFetchIndex < target {
            if !condition.wait(until: deadline) { break }
        }
        return highWaterFetchIndex >= target
    }

    // MARK: - Diagnostics

    /// (lowestIndex, highestIndex) currently held, or nil when empty.
    /// Used by the restart-decision logic in `VideoSegmentProvider`.
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

    /// Combined high-water bump + window slide. Both fetch and peek
    /// call this on hit; the broadcast wakes any pump worker blocked
    /// in `awaitFetchHighWater`.
    private func markFetched(index: Int) {
        if index > highWaterFetchIndex {
            highWaterFetchIndex = index
            pruneOutsideWindow()
            condition.broadcast()
        }
    }

    /// Drop any entries outside `[highWater - backwardWindow, highWater
    /// + forwardWindow]`. Bounds the cache to a fixed segment window
    /// regardless of how fast the producer ran or how AVPlayer's fetch
    /// pattern interleaved with the stores.
    private func pruneOutsideWindow() {
        let lo = highWaterFetchIndex - backwardWindow
        let hi = highWaterFetchIndex + forwardWindow
        for k in Array(entries.keys) {
            if k < lo || k > hi {
                entries.removeValue(forKey: k)
            }
        }
    }
}
