import Foundation

/// One-shot localization of a pathologically slow `AVIOReader.read()` call (#93 restart latency).
///
/// rrgomes' LAN trace: a producer's first post-restart read waits 19-46 s while a side reader's
/// read issued 19 s later completes in 300 ms, against a source that answers range requests in
/// milliseconds. The wait is client-side, but which branch of the persistent read loop eats the
/// time (detour fetch queueing, connStallTimeout waits, reconnect backoff, stale-generation data
/// drops) is invisible in the standard log. The read loop accumulates counters into this struct
/// and emits ONE summary line when the whole read exceeded the threshold, so a single device
/// trace answers where the time went. A slow read with all-zero counters is itself a finding:
/// the wait was upstream of the loop (seek, scheduling), not inside it.
struct SlowReadDiagnostics {
    let thresholdMs: Double

    private(set) var detourServes = 0
    private(set) var detourFetches = 0
    private(set) var detourMs: Double = 0
    private(set) var stallWaits = 0
    private(set) var stallWaitMs: Double = 0
    private(set) var stallWaitsSignaled = 0
    private(set) var reconnects = 0
    private(set) var backoffMs: Double = 0
    private(set) var staleGenDroppedBytes: Int64 = 0
    private(set) var iterations = 0
    // #93/#96 residual: the two branches the "empty counters" case pointed at but that were never
    // timed. lockWaitMs = time the loop head spent ACQUIRING winCond (a delegate thread holding it
    // across a copy/backpressure window blocks the read here, invisibly). connectMs = time inside the
    // synchronous reconnect/connect path on the demux thread (seekReconnect + startPersistentConnection,
    // incl. the old session's invalidateAndCancel). Whichever eats the ~15-35s finally lands on a name.
    private(set) var lockWaitMs: Double = 0
    private(set) var connectMs: Double = 0

    init(thresholdMs: Double = 2000) {
        self.thresholdMs = thresholdMs
    }

    /// One pass of the read loop. Separates a single blocked call (few iterations, large
    /// unaccounted time) from a spin (many iterations) when the recorded counters are near zero.
    mutating func recordIteration() {
        iterations += 1
    }

    mutating func recordDetourServe(ms: Double, fetched: Bool) {
        detourServes += 1
        if fetched { detourFetches += 1 }
        detourMs += ms
    }

    mutating func recordStallWait(ms: Double, signaled: Bool) {
        stallWaits += 1
        stallWaitMs += ms
        if signaled { stallWaitsSignaled += 1 }
    }

    mutating func recordReconnect() {
        reconnects += 1
    }

    mutating func recordBackoff(ms: Double) {
        backoffMs += ms
    }

    mutating func recordStaleGenerationDrop(bytes: Int64) {
        staleGenDroppedBytes += bytes
    }

    mutating func recordLockWait(ms: Double) {
        lockWaitMs += ms
    }

    mutating func recordConnect(ms: Double) {
        connectMs += ms
    }

    /// The summary line for a completed read, or nil while under the threshold.
    func line(elapsedMs: Double, offset: Int64, generationSpan: (Int, Int)) -> String? {
        guard elapsedMs >= thresholdMs else { return nil }
        // Time not attributable to any recorded branch: the read was blocked upstream of the loop
        // (fresh-connection first byte, a starved detour fetch not yet timed out, scheduling). This
        // is the #93/#96 residual's signature, so surfacing it turns "empty counters" into a number.
        let unaccounted = max(0, elapsedMs - stallWaitMs - detourMs - backoffMs - lockWaitMs - connectMs)
        return "[AVIOReader] slow read: \(Int(elapsedMs))ms at offset=\(offset) "
            + "detour=\(detourServes)(\(Int(detourMs))ms,\(detourFetches)fetch) "
            + "stallWaits=\(stallWaits)(\(Int(stallWaitMs))ms,\(stallWaitsSignaled)signaled) "
            + "reconnects=\(reconnects) backoff=\(Int(backoffMs))ms "
            + "lockWait=\(Int(lockWaitMs))ms connect=\(Int(connectMs))ms "
            + "staleGenDropped=\(staleGenDroppedBytes)b "
            + "iters=\(iterations) unaccounted=\(Int(unaccounted))ms "
            + "gen=\(generationSpan.0)->\(generationSpan.1)"
    }
}
