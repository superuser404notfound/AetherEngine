import Testing
@testable import AetherEngine

/// A #409 repair that synthesizes the decode ladder moves a late-written IDR back onto its sequence,
/// so the keyframe arrives before the index entry the segment plan was built from. The cutter and the
/// restart gate reach back for it; without that the keyframe stayed in the previous segment and the
/// next one opened on audio mid-GOP (25 of 40 segments on the 23 fps reporting asset).
@Suite("Segment boundaries reach a repaired keyframe placed before its index entry")
struct RepairedKeyframeSegmentReachTests {

    // 3913 ticks per picture (23 fps at 90 kHz); boundaries are the index entries.
    private let boundaries: [Int64] = [0, 352_170, 716_087, 1_056_522]

    @Test("a keyframe three pictures early opens its segment once the boundary reaches for it")
    func earlyKeyframeOpensSegmentWithinReach() {
        var without = VODSegmentCutter(sourceBoundaries: boundaries, planAnchorPts: 0, baseIndex: 0)
        _ = without.index(pts: 0, isKeyframe: true)
        #expect(without.index(pts: 352_170, isKeyframe: true) == 1)
        #expect(without.index(pts: 716_087 - 3 * 3913, isKeyframe: true) == 1)

        var with = VODSegmentCutter(sourceBoundaries: boundaries, planAnchorPts: 0, baseIndex: 0,
                                    reachTicks: [0, 17_608, 17_608, 17_608])
        _ = with.index(pts: 0, isKeyframe: true)
        #expect(with.index(pts: 352_170, isKeyframe: true) == 1)
        #expect(with.index(pts: 716_087 - 3 * 3913, isKeyframe: true) == 2)
        // Pictures after it stay with it, and non-keyframes never cut, reach or not.
        #expect(with.index(pts: 1_056_522 - 3913, isKeyframe: false) == 2)
    }

    @Test("each boundary's reach stops short of the keyframe before it")
    func reachStopsShortOfPreviousKeyframe() {
        // Two keyframes four pictures apart at the third boundary: the advance (17 608) would let the
        // first one open that boundary's segment.
        let keyframes: [Int64] = [0, 352_170, 716_087 - 4 * 3913, 716_087, 1_056_522]
        let reach = HLSVideoEngine.keyframeReachTicks(advance: 17_608, keyframes: keyframes,
                                                      boundaries: [0, 352_170, 716_087, 1_056_522])
        #expect(reach == [17_608, 17_608, 4 * 3913 - 1, 17_608])
        var cutter = VODSegmentCutter(sourceBoundaries: [0, 352_170, 716_087, 1_056_522, 1_400_000],
                                      planAnchorPts: 0, baseIndex: 0, reachTicks: reach)
        _ = cutter.index(pts: 0, isKeyframe: true)
        _ = cutter.index(pts: 352_170, isKeyframe: true)
        #expect(cutter.index(pts: 716_087 - 4 * 3913, isKeyframe: true) == 1)
        #expect(cutter.index(pts: 716_087, isKeyframe: true) == 2)
    }

    @Test("the reach is read off the plan after its short segments are folded")
    func reachFollowsCollapsedPlan() {
        // 90 kHz. Keyframes at 8.0 s and 8.11 s make a 0.11 s segment, which folds into the one before.
        let starts: [Int64] = [0, 360_000, 720_000, 730_000, 1_080_000]
        let plan = zip(starts, starts.dropFirst() + [1_440_000]).map { start, end in
            HLSVideoEngine.Segment(startPts: start, endPts: end, startSeconds: Double(start) / 90_000,
                                   durationSeconds: Double(end - start) / 90_000)
        }
        let final = HLSVideoEngine.finalizedPlan(plan, minDurationSeconds: 1, keyframeAdvance: 17_608,
                                                 keyframes: starts)
        // The fold keeps the later keyframe as the boundary, so its reach stops short of the one at 8.0 s.
        #expect(final.plan.map(\.startPts) == [0, 360_000, 730_000, 1_080_000])
        #expect(final.reach == [17_608, 17_608, 9_999, 17_608])
        // Read off the unfolded plan instead, 730 000 took 720 000's reach (so the keyframe before it
        // could open its segment) and 1 080 000 took 730 000's (so its own keyframe could miss it).
        let unfolded = HLSVideoEngine.keyframeReachTicks(advance: 17_608, keyframes: starts, boundaries: starts)
        #expect(Array(unfolded[2...3]) == [17_608, 9_999])
    }

    @Test("no repair, no reach")
    func noAdvanceNoReach() {
        #expect(HLSVideoEngine.keyframeReachTicks(advance: 0, keyframes: [0, 1000], boundaries: [0, 1000]).isEmpty)
        let cutter = VODSegmentCutter(sourceBoundaries: boundaries, planAnchorPts: 0, baseIndex: 0)
        #expect(cutter.reach(at: 1) == 0)
    }

    @Test("the restart gate opens on the early keyframe instead of waiting a GOP")
    func restartGateTakesEarlyKeyframe() {
        let target: Int64 = 716_087
        #expect(!HLSSegmentProducer.videoGateTargetSatisfied(pts: target - 2 * 3913, dts: target - 4 * 3913,
                                                             targetPts: target))
        #expect(HLSSegmentProducer.videoGateTargetSatisfied(pts: target - 2 * 3913, dts: target - 4 * 3913,
                                                            targetPts: target, reachTicks: 17_608))
    }

    @Test("only a synthesized ladder moves keyframes, by the reorder delay plus two and a half pictures")
    func keyframeAdvanceLimit() {
        var plan = H264CompositionOffsetRepair.Plan(step: 3913, decodeLead: 7826, shift: 7826, pocStep: 2)
        #expect(plan.keyframeAdvanceLimit == 0)
        plan.synthesizesDecodeLadder = true
        #expect(plan.keyframeAdvanceLimit == 7826 + 2 * 3913 + 1956)
    }
}
