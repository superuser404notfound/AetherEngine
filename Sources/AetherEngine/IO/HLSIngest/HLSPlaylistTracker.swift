import Foundation

/// Pure cursor over successive live playlist refreshes. Returns each segment exactly once. Handles join, forward growth, and window-slide (rejoin + discontinuity flag for downstream PTS rebase).
///
/// Join policy: target duration coverage `max(minJoinCoverageSeconds, 1.5 * targetDuration)`, capped at `edgeOffset` segments. Count-only join burst up to 36s of backlog on long-segment providers, which caused a one-time AVPlayer pacing stall a few seconds into every direct session (device repro 2026-06-11). The 1.5x term ensures at least one upstream cadence of buffer across the bursty inter-batch arrival gap (device repro 2026-06-11: ~5s stalls every ~20s with a single-segment join). A shrinking playlist (spec-violating server) is treated as a stall.
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

    init(edgeOffset: Int = 3, minJoinCoverageSeconds: Double = 8) {
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
                    discontinuityBefore: true, crypt: first.crypt
                )
            }
            return result
        }

        func joinStart() -> Int {
            let coverage = max(minJoinCoverageSeconds, 1.5 * playlist.targetDuration)
            var taken = 0
            var seconds = 0.0
            for segment in playlist.segments.reversed() {
                if taken >= edgeOffset { break }
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
