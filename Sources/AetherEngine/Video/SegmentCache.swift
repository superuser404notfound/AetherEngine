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

    /// AVPlayer's current target segment index, declared by the
    /// provider at the top of each `mediaSegment(at:)` call. Both
    /// pruning and producer-backpressure read this. Not monotonic:
    /// a backward scrub legitimately moves the target back, so the
    /// cache window can slide either direction. Initial value -1
    /// means "no request yet"; pruning with the default window
    /// `[-16, 19]` is a no-op for the producer's natural start
    /// (segments 0..19 fit), and the first real declareTarget snaps
    /// it into the player's actual region.
    private var currentTargetIndex: Int = -1

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

    /// Declare AVPlayer's current target segment index. Slides the
    /// cache window to centre on that target, evicts any entries
    /// outside the new window, and wakes any pump worker waiting in
    /// `awaitFetchHighWater`. Called by the provider at the top of
    /// each `mediaSegment(at:)` so the cache learns the player's
    /// intent BEFORE the producer's restart-fires-and-immediately-
    /// evicts-its-own-output race window opens.
    func declareTarget(_ index: Int) {
        condition.lock()
        defer { condition.unlock() }
        if index != currentTargetIndex {
            currentTargetIndex = index
            pruneOutsideWindow()
            condition.broadcast()
        }
    }

    /// Non-blocking lookup.
    func peek(index: Int) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        return entries[index]
    }

    /// Blocking lookup. Returns nil on timeout, on close, or when the
    /// producer never stores this index.
    func fetch(index: Int, timeout: TimeInterval = 15.0) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        if let hit = entries[index] { return hit }
        if closed { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while !closed, entries[index] == nil {
            if !condition.wait(until: deadline) { break }
        }
        return entries[index]
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

    /// Pump-side backpressure: block until AVPlayer's declared target
    /// reaches `target`, or `timeout` elapses, or the cache is closed.
    /// The producer calls this right after storing segment N with
    /// `target = N - forwardWindow` so it can't race more than
    /// `forwardWindow` segments past AVPlayer's actual playhead.
    /// Returns `true` on progress, `false` on close / timeout.
    ///
    /// Short timeouts let the caller poll its own shouldStop flag
    /// between awaits — the producer restart path uses 1 s waits in
    /// a check-stop-then-await loop so it can be torn down within a
    /// second of `stop()` being called instead of leaking for the
    /// full 60 s.
    func awaitFetchHighWater(reaching target: Int, timeout: TimeInterval = 1.0) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if currentTargetIndex >= target { return true }
        if closed { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while !closed, currentTargetIndex < target {
            if !condition.wait(until: deadline) { break }
        }
        return currentTargetIndex >= target
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

    /// Drop any entries outside `[currentTarget - backwardWindow,
    /// currentTarget + forwardWindow]`. Bounds the cache to a fixed
    /// segment window centred on AVPlayer's declared target,
    /// regardless of how fast the producer ran.
    private func pruneOutsideWindow() {
        let lo = currentTargetIndex - backwardWindow
        let hi = currentTargetIndex + forwardWindow
        for k in Array(entries.keys) {
            if k < lo || k > hi {
                entries.removeValue(forKey: k)
            }
        }
    }
}
