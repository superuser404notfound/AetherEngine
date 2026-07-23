import Testing
import Foundation
@testable import AetherEngine

/// AE#169 round 3 (rrgomes): the restart scan-forward gate compared packet DTS against a
/// plan-boundary PTS (`segmentPlan[baseIndex].startPts`). Under B-frame reorder a keyframe's DTS
/// sits a reorder delay below its own PTS, so the gate dropped the exact IRAP the restart seeked
/// for (the same defect class the #92 cutter fix removed from segment cutting). Mid-file the next
/// IRAP rescued the miss one GOP late; at the file tail there is no next IRAP, so the VOD gate
/// (unbounded by design) dropped every remaining packet to EOF and the pump exited with
/// `packetsWritten=0` ("still waiting for video keyframe: dropped=200 lastDts=2880419
/// isKey=false target=2878501"). The final segment was then unproducible under any anchoring and
/// the forward-wait escalation restarted into the same starve.
struct Issue169GateStarvationTests {

    // MARK: - videoGateTargetSatisfied (pregate opens on presentation time)

    @Test("the anchor IRAP whose dts sits a reorder delay below the target pts opens the gate")
    func anchorIRAPWithReorderedDtsOpens() {
        // rrgomes' seg718 geometry: plan boundary 2878501, IRAP pts just above it, dts ~125ms below.
        #expect(HLSSegmentProducer.videoGateTargetSatisfied(
            pts: 2_878_620, dts: 2_878_495, targetPts: 2_878_501))
        // Exact landing (dts == pts sources) is unchanged.
        #expect(HLSSegmentProducer.videoGateTargetSatisfied(
            pts: 2_878_501, dts: 2_878_501, targetPts: 2_878_501))
    }

    @Test("a keyframe before the target boundary stays dropped")
    func belowTargetKeyframeStaysDropped() {
        // The seg716 IRAP during a seg718-anchored scan: presentation time below the boundary.
        #expect(!HLSSegmentProducer.videoGateTargetSatisfied(
            pts: 2_872_411, dts: 2_872_290, targetPts: 2_878_501))
    }

    @Test("no restart target admits the first keyframe (head of stream)")
    func headOfStreamAdmitsFirstKeyframe() {
        #expect(HLSSegmentProducer.videoGateTargetSatisfied(
            pts: 33, dts: 0, targetPts: Int64.min))
        #expect(HLSSegmentProducer.videoGateTargetSatisfied(
            pts: Int64.min, dts: Int64.min, targetPts: Int64.min))
    }

    @Test("NOPTS pts falls back to dts; both missing cannot satisfy a real target")
    func noptsFallsBackToDts() {
        #expect(HLSSegmentProducer.videoGateTargetSatisfied(
            pts: Int64.min, dts: 2_878_600, targetPts: 2_878_501))
        #expect(!HLSSegmentProducer.videoGateTargetSatisfied(
            pts: Int64.min, dts: Int64.min, targetPts: 2_878_501))
    }

    // MARK: - shouldReanchorVODAfterGateStarvation (engine arm for the starved-EOF exit)

    @Test("a VOD pump that starved its gate to EOF re-anchors on the last dropped keyframe")
    func starvedGateReanchors() {
        #expect(HLSVideoEngine.shouldReanchorVODAfterGateStarvation(
            isLive: false, videoGateOpened: false, hadRestartTarget: true,
            lastDroppedKeyframePts: 2_878_620))
    }

    @Test("an opened gate, a head-of-stream pump, a live pump, or no seen keyframe never re-anchor")
    func reanchorGuards() {
        // Gate opened: normal production ran; a plain EOF is a normal end.
        #expect(!HLSVideoEngine.shouldReanchorVODAfterGateStarvation(
            isLive: false, videoGateOpened: true, hadRestartTarget: true,
            lastDroppedKeyframePts: 2_878_620))
        // Head-of-stream pump (no restart target) starving means a keyframe-less source, not a
        // tail-boundary mismatch; the #126 fatal surface owns that.
        #expect(!HLSVideoEngine.shouldReanchorVODAfterGateStarvation(
            isLive: false, videoGateOpened: false, hadRestartTarget: false,
            lastDroppedKeyframePts: 2_878_620))
        // Live has its own reopen machinery.
        #expect(!HLSVideoEngine.shouldReanchorVODAfterGateStarvation(
            isLive: true, videoGateOpened: false, hadRestartTarget: true,
            lastDroppedKeyframePts: 2_878_620))
        // No keyframe seen below the target: nowhere sane to re-anchor.
        #expect(!HLSVideoEngine.shouldReanchorVODAfterGateStarvation(
            isLive: false, videoGateOpened: false, hadRestartTarget: true,
            lastDroppedKeyframePts: Int64.min))
    }

    // MARK: - planSegmentIndex(forSourcePts:) (re-anchor target mapping)

    private func plan() -> [HLSVideoEngine.Segment] {
        (0..<720).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
    }

    @Test("a source pts maps to the segment whose span contains it")
    func planIndexMapsIntoSpan() {
        let plan = plan()
        #expect(HLSVideoEngine.planSegmentIndex(forSourcePts: 2_872_411, plan: plan) == 718)
        #expect(HLSVideoEngine.planSegmentIndex(forSourcePts: 2_872_000, plan: plan) == 718)
        #expect(HLSVideoEngine.planSegmentIndex(forSourcePts: 0, plan: plan) == 0)
        // Past the final boundary clamps into the last segment.
        #expect(HLSVideoEngine.planSegmentIndex(forSourcePts: 10_000_000, plan: plan) == 719)
    }

    @Test("an empty plan or a pts before the first boundary has no mapping")
    func planIndexRejectsUnmappable() {
        #expect(HLSVideoEngine.planSegmentIndex(forSourcePts: 100, plan: []) == nil)
        let offset = plan().map { seg in
            HLSVideoEngine.Segment(startPts: seg.startPts + 5000, endPts: seg.endPts + 5000,
                                   startSeconds: seg.startSeconds, durationSeconds: seg.durationSeconds)
        }
        #expect(HLSVideoEngine.planSegmentIndex(forSourcePts: 100, plan: offset) == nil)
    }
}
