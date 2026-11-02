import Foundation

/// AE#936: how far the cutter has read into the open live segment, and how fast that is moving.
///
/// The fastZap grace exists to let one more segment finalize. On a long GOP after a burst it cannot:
/// the backlog is drained, media now arrives at 1x, and the next keyframe is further away than the
/// whole grace. Only the read side knows that, because nothing finalizes while it is true.
struct LiveReadHead {
    private var samples: [(at: TimeInterval, ptsSeconds: Double)] = []
    private static let retainedSeconds: TimeInterval = 1.0

    /// Newest video presentation time read, on the same axis as the finalized segments' starts.
    var latestPtsSeconds: Double? { samples.last?.ptsSeconds }

    mutating func note(ptsSeconds: Double, at now: TimeInterval) {
        guard ptsSeconds.isFinite else { return }
        if let last = samples.last, ptsSeconds < last.ptsSeconds - 1 {
            // A discontinuity restarts the axis, and a rate across it means nothing.
            samples.removeAll(keepingCapacity: true)
        }
        samples.append((now, ptsSeconds))
        let floor = now - Self.retainedSeconds
        if let keep = samples.firstIndex(where: { $0.at >= floor }), keep > 0 {
            samples.removeFirst(keep)
        }
    }

    /// Media seconds read per wall second over the trailing `window`, or nil until the samples span
    /// at least `minimumSpan` (too short a span reads one demuxer chunk as a rate).
    func deliveryRate(now: TimeInterval, window: TimeInterval, minimumSpan: TimeInterval) -> Double? {
        guard let last = samples.last,
              let first = samples.first(where: { $0.at >= now - window }) else { return nil }
        let span = now - first.at
        guard span >= minimumSpan else { return nil }
        return max(0, last.ptsSeconds - first.ptsSeconds) / span
    }
}

extension LiveEdgePolicy {
    /// AE#936: the trailing window the grace reads the source's delivery rate over.
    static let graceRateWindowSeconds: TimeInterval = 0.5
    static let graceRateMinimumSpanSeconds: TimeInterval = 0.25
    /// How far the read head may trail the source: one demuxer read is about a third of a second of
    /// 6 Mbit/s TS, and a grace sized to exactly one GOP otherwise sits on the boundary (measured: a
    /// 1 s GOP at 1x lost its third segment and drew a -16832 without it).
    static let graceReachSlackSeconds: TimeInterval = 0.5

    /// Whether the rest of a fastZap grace can still change what the first manifest serves.
    ///
    /// Only a finalized segment adds depth, and the open one finalizes at the next keyframe. So the
    /// grace can help only if, at the rate the source is delivering (never assumed below 1x, a live
    /// source cannot sustain less), the open segment could still grow to the shortest segment seen so
    /// far. If it cannot, waiting serves the same window later. A burst still in progress reads as a
    /// high rate and keeps the grace.
    static func fastZapGraceIsFutile(
        openSegmentSeconds: Double,
        shortestSegmentSeconds: Double,
        deliveryRate: Double?,
        remainingGraceSeconds: TimeInterval
    ) -> Bool {
        guard let deliveryRate, deliveryRate.isFinite,
              openSegmentSeconds.isFinite, openSegmentSeconds >= 0,
              shortestSegmentSeconds.isFinite, shortestSegmentSeconds > 0,
              remainingGraceSeconds.isFinite, remainingGraceSeconds > 0
        else { return false }
        let reachable = openSegmentSeconds + max(1, deliveryRate) * remainingGraceSeconds
        return reachable + graceReachSlackSeconds < shortestSegmentSeconds
    }
}
