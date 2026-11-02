import Foundation

/// Pure cursor over successive live playlist refreshes. Returns each segment exactly once. Handles join, forward growth, and window-slide (rejoin + discontinuity flag for downstream PTS rebase).
///
/// Join policy: target duration coverage `max(minJoinCoverageSeconds, 1.5 * targetDuration, loopback cushion)`, bounded by `edgeOffset` segments and by the eviction margin. Count-only join burst up to 36s of backlog on long-segment providers, which caused a one-time AVPlayer pacing stall a few seconds into every direct session (device repro 2026-06-11). The 1.5x term ensures at least one upstream cadence of buffer across the bursty inter-batch arrival gap (device repro 2026-06-11: ~5s stalls every ~20s with a single-segment join). A shrinking playlist (spec-violating server) is treated as a stall.
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

    /// AE#678: the join has to carry the cushion the loopback's first serve will ask for, or every zap
    /// ends at the bounded start's grace. The served TARGETDURATION is floored by the longest upstream
    /// segment (`ceil(longest / 1.5)`, AE#447), so the gate wants `3 x` that, and `1.5 x TD` alone is
    /// always a hair short of it: two 10 s segments are 20 s against a 21 s holdback. The last joined
    /// segment's final GOP also stays open downstream until the next upstream segment arrives, so one
    /// GOP of margin on top, bounded by the segment and by `openGOPMarginSeconds`. A whole segment of
    /// margin would be the strict bound, and on a 10 s provider it is a fourth 10 s download the start
    /// then waits for on a shared link (measured 3.7 s to first picture against 40 Mbit/s).
    ///
    /// AE#684: the seal now also covers the upstream segment whole, and this coverage deliberately
    /// does NOT follow it. A join one segment deeper is one more download before the first picture on
    /// every zap (the fourth segment AE#678 declined above), so the join keeps this depth and the seal
    /// rises only as far as what was joined can pay (`LiveEdgePolicy.targetDurationTheJoinCanPay`).
    /// The one thing added on top is `phaseEqualisedJoinDepth`, which never exceeds the depth this
    /// same coverage already takes in another phase of the same listing.
    static func loopbackCushionCoverageSeconds(segments: [HLSMediaSegment]) -> Double {
        guard let longest = segments.map(\.duration).max(), longest > 0 else { return 0 }
        let targetDuration = LiveEdgePolicy.targetDurationForCadence(longest)
        return LiveEdgePolicy.holdBackSeconds(targetDuration: targetDuration)
            + min(longest, openGOPMarginSeconds)
    }

    /// The 7.24.0 coverage rule on its own: how many segments a tune takes when `durations` (oldest
    /// first) is what the upstream lists. nil when the listing runs out before the coverage is met and
    /// before the count limit, so the depth of that tune cannot be read off this listing.
    static func coverageJoinDepth(durations: ArraySlice<Double>, coverage: Double, limit: Int) -> Int? {
        var taken = 0
        var seconds = 0.0
        for duration in durations.reversed() {
            if taken >= limit { return taken }
            if taken > 0, seconds >= coverage { return taken }
            taken += 1
            seconds += duration
        }
        return (taken >= limit || seconds >= coverage) ? taken : nil
    }

    /// AE#684: the join, equalised over the phases of one upstream.
    ///
    /// The coverage loop counts seconds back from the newest segment, so on an upstream whose segment
    /// lengths alternate its depth depends on which one happens to be newest. The channel this issue
    /// was reported on alternates 6 s and 4 s: `4 + 6 + 4` is under the 16 s target and a fourth is
    /// taken (20 s listed, 18 s cut, seal 6), while `6 + 4 + 6` meets it at three (16 s listed, 14 s
    /// cut, seal 4, which is 7.25.1's value and its stalls). About four tunes in ten landed in the
    /// second phase, and the same channel behaved differently from one zap to the next.
    ///
    /// The rule: a tune never loads more than the deepest tune of the same channel already did. The
    /// depth is the deepest the coverage rule takes over the actual tune and the tunes that would
    /// have happened one, two, ... segments earlier, as far back as the newest segment of such a tune
    /// is still one this join takes itself (a rhythm shorter than the join shows all its phases in
    /// that span; looking further back would let one stray segment anywhere in the listing deepen
    /// every tune). So 6 s / 4 s joins four in both phases, and the three-segment phase pays one
    /// additional short segment that the other phase always loaded.
    ///
    /// It deliberately does nothing where no phase is deeper. 10 s / 8 s segments join three in both
    /// phases and 6 s / 6 s / 4 s three in all three, exactly as before, and their seal is what that
    /// join pays, as for a uniform upstream: a deeper join on EVERY tune is the cost AE#678 declined.
    /// A lone short segment on an otherwise uniform upstream deepens the join only while it sits
    /// within that span: for the tunes that needed the extra segment anyway, and the two after them.
    ///
    /// Bounded at one segment above the actual tune's own depth. Phases of one listing differ by more
    /// than that only when lengths swing wildly (a run of 2 s segments behind a 10 s one), and there
    /// the listing is describing a change of source, not a rhythm to equalise.
    static func phaseEqualisedJoinDepth(durations: [Double], coverage: Double, limit: Int) -> Int {
        guard let own = coverageJoinDepth(durations: durations[...], coverage: coverage, limit: limit) else {
            return min(durations.count, limit)
        }
        var deepest = own
        for earlier in 1..<max(1, own) {
            guard let depth = coverageJoinDepth(durations: durations.dropLast(earlier),
                                                coverage: coverage, limit: limit) else { break }
            deepest = max(deepest, depth)
        }
        return min(deepest, own + 1, limit, durations.count)
    }

    /// Longest GOP the join margin plans for. IPTV and broadcast GOPs run 0.5 to 4 s; a longer one
    /// only costs the bounded start's grace, which is what every join paid before AE#678.
    static let openGOPMarginSeconds: Double = 4

    init(edgeOffset: Int = 8, minJoinCoverageSeconds: Double = 8) {
        self.edgeOffset = edgeOffset
        self.minJoinCoverageSeconds = minJoinCoverageSeconds
    }

    /// A tracker whose join covers a host's `liveEdgeCushionSeconds` as well as the loopback's own
    /// holdback, so a listing that holds the backlog fills the cushion at link speed instead of at 1x.
    /// The segment cap grows with it on the assumption of segments of a second or longer; the
    /// coverage, not the cap, ends the join on every listing deep enough to meet it.
    static func joining(cushion: Double?) -> HLSPlaylistTracker {
        guard let cushion, cushion.isFinite, cushion > 0 else { return HLSPlaylistTracker() }
        let coverage = cushion + openGOPMarginSeconds
        return HLSPlaylistTracker(edgeOffset: max(8, Int(coverage.rounded(.up))),
                                  minJoinCoverageSeconds: max(8, coverage))
    }

    mutating func newSegments(in playlist: HLSMediaPlaylist) -> [HLSMediaSegment] {
        let windowStart = playlist.mediaSequence
        // The parser rejects a MEDIA-SEQUENCE outside `0...Int.max/2` (audit NET-3), but the struct
        // itself can be built directly (tests, or a future caller), so this combines with `&+`/`&-`
        // rather than trapping on a value that slipped past that guard.
        let windowEnd = playlist.mediaSequence &+ playlist.segments.count // exclusive

        func segments(from sequence: Int, markFirstDiscontinuity: Bool) -> [HLSMediaSegment] {
            let startIndex = sequence &- windowStart
            guard startIndex < playlist.segments.count else { return [] }
            var result = Array(playlist.segments[max(0, startIndex)...])
            if markFirstDiscontinuity, !result.isEmpty {
                let first = result[0]
                result[0] = HLSMediaSegment(
                    uri: first.uri, duration: first.duration,
                    discontinuityBefore: true, crypt: first.crypt,
                    programDateTime: first.programDateTime, byteRange: first.byteRange
                )
            }
            return result
        }

        func joinStart() -> Int {
            let coverage = max(minJoinCoverageSeconds, 1.5 * playlist.targetDuration,
                               Self.loopbackCushionCoverageSeconds(segments: playlist.segments))
            let limit = Self.joinSegmentLimit(edgeOffset: edgeOffset,
                                              windowSegmentCount: playlist.segments.count)
            let taken = Self.phaseEqualisedJoinDepth(durations: playlist.segments.map(\.duration),
                                                     coverage: coverage, limit: limit)
            return windowEnd &- taken
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
