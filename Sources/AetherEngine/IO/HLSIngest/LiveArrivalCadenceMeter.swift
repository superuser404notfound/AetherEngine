import Foundation

/// Measures the OBSERVED segment-arrival cadence of a live ingest upstream: the wall-clock interval
/// between successive batches of newly-appeared segments, plus the currently-open gap since the last
/// arrival. This is the signal the engine trusts for LL-HLS playlist shaping instead of the upstream's
/// self-reported `#EXT-X-TARGETDURATION`, which says nothing about real delivery discipline: a relay /
/// budget IPTV origin can advertise a normal target while pushing segments in irregular batches
/// (AetherEngine#167).
///
/// Value type; the ingest reader records arrivals under its own lock and reads the estimate the same way.
struct LiveArrivalCadenceMeter {
    /// Trailing window of closed inter-arrival intervals; the max over it is the recent cadence. A window
    /// (not an all-time max) lets the estimate recover once an origin stops bursting.
    private var recentIntervals: [Double] = []
    private var lastArrival: Double?
    private let windowSize = 8

    /// Record that new segment(s) appeared at monotonic time `now`. The first call only anchors the clock
    /// (the join itself is not a gap); later calls close the interval since the previous arrival.
    mutating func recordArrival(at now: Double) {
        if let last = lastArrival, now > last {
            recentIntervals.append(now - last)
            if recentIntervals.count > windowSize { recentIntervals.removeFirst() }
        }
        lastArrival = now
    }

    /// Observed cadence in seconds at monotonic time `now`: the larger of the recent max closed interval
    /// and the currently-open gap since the last arrival. nil before the first arrival. The open-gap term
    /// makes a lengthening quiet stretch raise the estimate in real time, so the TARGETDURATION floor
    /// widens before AVPlayer's unchanged-playlist patience runs out (-12888).
    func observedCadence(at now: Double) -> Double? {
        guard let last = lastArrival else { return nil }
        let ongoing = max(0, now - last)
        let closedMax = recentIntervals.max() ?? 0
        return max(closedMax, ongoing)
    }
}
