import Foundation

/// Pure cursor over successive live playlist refreshes. Returns each segment exactly once. Handles join, forward growth, and window-slide (rejoin + discontinuity flag for downstream PTS rebase).
///
/// Join policy: target duration coverage `max(minJoinCoverageSeconds, 1.5 * targetDuration)`, bounded by `edgeOffset` segments and by the eviction margin. Count-only join burst up to 36s of backlog on long-segment providers, which caused a one-time AVPlayer pacing stall a few seconds into every direct session (device repro 2026-06-11). The 1.5x term ensures at least one upstream cadence of buffer across the bursty inter-batch arrival gap (device repro 2026-06-11: ~5s stalls every ~20s with a single-segment join). A shrinking playlist (spec-violating server) is treated as a stall.
///
/// `edgeOffset` is a sanity bound on the burst, not the policy. It used to be 3, which is a COUNT standing in for a burst measured in SECONDS, and the coverage term above already bounds long segments on its own (6s segments break at 12s, 12s segments at 24s). So the count only ever bound SHORT segments, which are exactly the sources the 8s coverage floor was written for, and it cut them to a third of it. The cost was not only buffer: three joined segments yield only TWO finalized ones downstream, because the last one is still open until the next arrives, and the loopback startup cushion wants three. The live join therefore waited one upstream segment duration in wall clock for content the origin was already holding. Measured on `hlsfixture --window 8` with `play --live --fast-zap` (three runs per row, engine 6.76.1 against this change): first picture on a 2s-segment channel 2.22s before, 0.20s after; on 1s segments 0.41 to 1.22s before (it depended on where in the upstream segment cycle the tune landed) against 0.18 to 0.20s after, the phase dependency gone with it. A window three segments deep has nothing deeper to join into and is unchanged. The origin request log is what says the depth is not paid back later: both arms fetch up to the same upstream segment number at the same wall clock, so the burst is caught up at I/O speed rather than becoming a standing lag behind the live edge.
struct HLSPlaylistTracker {
    private let edgeOffset: Int          // max segments behind the live edge on join
    private let minJoinCoverageSeconds: Double // floor for the duration-coverage target
    private(set) var nextSequence: Int?  // next media-sequence not yet returned; nil until primed
    private(set) var stallCount = 0
    /// #199: consecutive refreshes whose whole window sits BEHIND the cursor (MEDIA-SEQUENCE went
    /// backward: encoder restart, looped test pool). One or two can be a stale CDN edge; at the
    /// threshold the axis is treated as reset and the tracker rejoins at the new edge. Regressions
    /// never feed `stallCount`: they are reset evidence, not upstream silence, and must not push
    /// the reader toward its ingestStalled terminal trip.
    private var sequenceRegressionCount = 0

    /// Third consecutive regression = reset. A stale-edge flap alternates with fresh windows and
    /// resets the counter; a real MSN reset regresses on every refresh and crosses this in ~3
    /// refresh intervals, well inside the reader's stall budget.
    static let sequenceResetRejoinThreshold = 3

    /// A window this shallow is joined whole; deeper than this, the oldest listed segment is left
    /// where it is. It is the one closest to being dropped, and a join burst that reaches for it
    /// races the origin for a 404 on a server that removes rather than retires. The margin is free:
    /// the coverage target is met from the rest of the window in every shape that meets it at all.
    static let joinEvictionMarginWindowDepth = 3

    /// Segments the join may take, which is the count cap narrowed by the eviction margin above.
    static func joinSegmentLimit(edgeOffset: Int, windowSegmentCount: Int) -> Int {
        guard windowSegmentCount > joinEvictionMarginWindowDepth else { return edgeOffset }
        return min(edgeOffset, windowSegmentCount - 1)
    }

    init(edgeOffset: Int = 8, minJoinCoverageSeconds: Double = 8) {
        self.edgeOffset = edgeOffset
        self.minJoinCoverageSeconds = minJoinCoverageSeconds
    }

    mutating func newSegments(in playlist: HLSMediaPlaylist) -> [HLSMediaSegment] {
        let windowStart = playlist.mediaSequence
        let windowEnd = playlist.mediaSequence + playlist.segments.count // exclusive

        func segments(from sequence: Int, markFirstDiscontinuity: Bool) -> [HLSMediaSegment] {
            let startIndex = sequence - windowStart
            guard startIndex < playlist.segments.count else { return [] }
            var result = Array(playlist.segments[max(0, startIndex)...])
            if markFirstDiscontinuity, !result.isEmpty {
                let first = result[0]
                result[0] = HLSMediaSegment(
                    uri: first.uri, duration: first.duration,
                    discontinuityBefore: true, crypt: first.crypt,
                    programDateTime: first.programDateTime
                )
            }
            return result
        }

        func joinStart() -> Int {
            let coverage = max(minJoinCoverageSeconds, 1.5 * playlist.targetDuration)
            let limit = Self.joinSegmentLimit(edgeOffset: edgeOffset,
                                              windowSegmentCount: playlist.segments.count)
            var taken = 0
            var seconds = 0.0
            for segment in playlist.segments.reversed() {
                if taken >= limit { break }
                if taken > 0, seconds >= coverage { break }
                taken += 1
                seconds += segment.duration
            }
            return windowEnd - taken
        }

        guard let cursor = nextSequence else {
            nextSequence = windowEnd
            return segments(from: joinStart(), markFirstDiscontinuity: false)
        }

        if cursor < windowStart {
            // Window slid past cursor: rejoin and mark the seam.
            nextSequence = windowEnd
            stallCount = 0
            sequenceRegressionCount = 0
            return segments(from: joinStart(), markFirstDiscontinuity: true)
        }

        if cursor > windowEnd {
            // #199: the whole window is behind the cursor, MEDIA-SEQUENCE went backward. The old
            // behavior returned empty batches forever, starving the reader into ingestStalled and
            // tearing down the session for a condition the stream itself survives.
            sequenceRegressionCount += 1
            guard sequenceRegressionCount >= Self.sequenceResetRejoinThreshold else { return [] }
            nextSequence = windowEnd
            stallCount = 0
            sequenceRegressionCount = 0
            return segments(from: joinStart(), markFirstDiscontinuity: true)
        }
        sequenceRegressionCount = 0

        let fresh = segments(from: cursor, markFirstDiscontinuity: false)
        if fresh.isEmpty {
            stallCount += 1
        } else {
            stallCount = 0
            nextSequence = windowEnd
        }
        return fresh
    }
}
