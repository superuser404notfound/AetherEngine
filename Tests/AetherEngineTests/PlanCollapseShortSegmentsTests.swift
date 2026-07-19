import Testing
@testable import AetherEngine

/// Near-EOF resume hang (Sodalite, device-confirmed): a keyframe cluster (several IRAPs within a few
/// frames, e.g. a hard cut) makes buildKeyframeSegmentPlan emit sub-frame segments. Plan and producer share
/// one boundary list (segmentBoundaries = plan.map(startPts)), and the producer only cuts a segment when a
/// demuxed keyframe's PTS maps into its [start,end) window (segmentOffset). A ~40 ms window can miss every
/// actually-demuxed keyframe, so that advertised index is never produced (device: seg139 skipped, ledger
/// jumps 138 -> 140), AVPlayer requests it forever -> CoreMedia -15628 -> endless item reload. Collapsing the
/// degenerate segments into a neighbour widens the window so a resident keyframe is guaranteed and plan and
/// producer agree. This suite pins that pure transform.
struct PlanCollapseShortSegmentsTests {

    /// Build a segment with PTS in a 1/1000 timebase so startPts/endPts track the seconds fields.
    private func seg(_ start: Double, _ dur: Double) -> HLSVideoEngine.Segment {
        HLSVideoEngine.Segment(
            startPts: Int64((start * 1000).rounded()),
            endPts: Int64(((start + dur) * 1000).rounded()),
            startSeconds: start,
            durationSeconds: dur)
    }

    @Test("A plan with no sub-minimum segment is returned unchanged")
    func noShortSegmentsUnchanged() {
        let plan = [seg(0, 4), seg(4, 4), seg(8, 3.5)]
        let out = HLSVideoEngine.collapseShortSegments(plan, minDurationSeconds: 1.0)
        #expect(out.count == 3)
        #expect(out.map(\.durationSeconds) == [4, 4, 3.5])
    }

    @Test("An interior keyframe cluster folds into the preceding segment, boundaries preserved")
    func interiorClusterFoldsBackward() {
        // 4 s normal, then four ~40 ms cluster segments, then a normal 3.9 s segment (the device shape).
        let plan = [seg(0, 4), seg(4.00, 0.04), seg(4.04, 0.04), seg(4.08, 0.04), seg(4.12, 3.9)]
        let out = HLSVideoEngine.collapseShortSegments(plan, minDurationSeconds: 1.0)
        #expect(out.count == 2)
        // The preceding segment swallowed the whole cluster: [0, 4.12).
        #expect(out[0].startSeconds == 0)
        #expect(abs(out[0].durationSeconds - 4.12) < 1e-9)
        #expect(out[0].startPts == 0)
        #expect(out[0].endPts == 4120)
        // The following normal segment is untouched, so its start is a real plan keyframe.
        #expect(abs(out[1].startSeconds - 4.12) < 1e-9)
        #expect(abs(out[1].durationSeconds - 3.9) < 1e-9)
        // No sub-minimum segment survives.
        #expect(out.allSatisfy { $0.durationSeconds >= 1.0 })
    }

    @Test("A too-short first segment folds forward into its successor (no predecessor to take it)")
    func shortFirstFoldsForward() {
        let plan = [seg(0, 0.04), seg(0.04, 4)]
        let out = HLSVideoEngine.collapseShortSegments(plan, minDurationSeconds: 1.0)
        #expect(out.count == 1)
        #expect(out[0].startSeconds == 0)
        #expect(out[0].startPts == 0)
        #expect(abs(out[0].durationSeconds - 4.04) < 1e-9)
    }

    @Test("A too-short final segment folds into its predecessor")
    func shortFinalFoldsBackward() {
        let plan = [seg(0, 4), seg(4, 0.5)]
        let out = HLSVideoEngine.collapseShortSegments(plan, minDurationSeconds: 1.0)
        #expect(out.count == 1)
        #expect(abs(out[0].durationSeconds - 4.5) < 1e-9)
        #expect(out[0].endPts == 4500)
    }

    @Test("Total advertised duration is conserved by the collapse")
    func durationConserved() {
        let plan = [seg(0, 4), seg(4.00, 0.04), seg(4.04, 0.04), seg(4.08, 3.9)]
        let before = plan.reduce(0.0) { $0 + $1.durationSeconds }
        let out = HLSVideoEngine.collapseShortSegments(plan, minDurationSeconds: 1.0)
        let after = out.reduce(0.0) { $0 + $1.durationSeconds }
        #expect(abs(before - after) < 1e-9)
    }

    @Test("Degenerate inputs (empty, single) are returned as-is")
    func degenerateInputs() {
        #expect(HLSVideoEngine.collapseShortSegments([], minDurationSeconds: 1.0).isEmpty)
        let one = [seg(0, 0.04)]
        #expect(HLSVideoEngine.collapseShortSegments(one, minDurationSeconds: 1.0).count == 1)
    }
}
