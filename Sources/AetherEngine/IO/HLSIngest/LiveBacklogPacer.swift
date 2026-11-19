import Foundation

/// AE#1090: releases the backlog of a join behind the live edge at the rate it plays.
///
/// A live session downstream is source-paced: it cuts what the reader hands over as fast as it arrives
/// and slides its window behind that. A join at the start of an hour-long listing that handed the hour
/// over at link speed would therefore slide the window past the viewer within seconds. So the join
/// delivers what an edge join would (`leadSeconds`, the burst `HLSPlaylistTracker.behindEdgeJoinBurstDepth`
/// picks) at once, and every later segment becomes due when its END is `leadSeconds` ahead of a playhead
/// that started at the join and runs at 1x. Downstream that is indistinguishable from tuning in when the
/// listing began: same first-serve wait, same cadence, same window.
///
/// The schedule never catches up with the real edge. That is the point: the session stays as far behind
/// live as the listing was deep when it joined, plus whatever it paused. A fetch that falls behind its
/// due time is caught up at link speed, the way an edge join catches up a slow segment.
struct LiveBacklogPacer {
    /// Monotonic seconds at which the join batch began.
    let anchor: Double
    /// Seconds of media the join delivered at once.
    let leadSeconds: Double
    /// Media seconds from the join to the end of the last segment scheduled.
    private(set) var scheduledEndSeconds: Double = 0

    init(anchor: Double, leadSeconds: Double) {
        self.anchor = anchor
        self.leadSeconds = max(0, leadSeconds)
    }

    /// Monotonic time at which the next segment, `duration` seconds long, may be fetched. Call once per
    /// segment, in playlist order.
    mutating func dueTime(forNextSegmentOfDuration duration: Double) -> Double {
        if duration.isFinite, duration > 0 { scheduledEndSeconds += duration }
        return anchor + max(0, scheduledEndSeconds - leadSeconds)
    }
}
