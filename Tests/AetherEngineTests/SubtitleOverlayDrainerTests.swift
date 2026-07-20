import Testing
@testable import AetherEngine

struct SubtitleOverlayDrainerTests {
    @Test("fresh target decodes from playhead minus backscan")
    func freshTargetBackscans() {
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: nil, playhead: 100,
                                                    lead: 60, backscan: 15, jumpThreshold: 2.5)
        guard case .resetAndDecode(let from, let through) = plan else {
            Issue.record("expected resetAndDecode, got \(plan)"); return
        }
        #expect(from == 85)
        #expect(through == 160)
    }

    @Test("steady playback advances from the cursor without reset")
    func steadyAdvance() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 150, lastPlayhead: 100)
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 100.5,
                                                    lead: 60, backscan: 15, jumpThreshold: 2.5)
        guard case .decode(let from, let through) = plan else {
            Issue.record("expected decode, got \(plan)"); return
        }
        #expect(from > 150)
        #expect(through == 160.5)
    }

    @Test("a playhead jump beyond the threshold resets the decoder and backscans")
    func seekResets() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 150, lastPlayhead: 100)
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 400,
                                                    lead: 60, backscan: 15, jumpThreshold: 2.5)
        guard case .resetAndDecode(let from, _) = plan else {
            Issue.record("expected resetAndDecode, got \(plan)"); return
        }
        #expect(from == 385)
    }

    @Test("backward jump beyond the threshold also resets and backscans")
    func backwardSeekResets() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 150, lastPlayhead: 100)
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 40,
                                                    lead: 60, backscan: 15, jumpThreshold: 2.5)
        guard case .resetAndDecode(let from, let through) = plan else {
            Issue.record("expected resetAndDecode, got \(plan)"); return
        }
        #expect(from == 25)
        #expect(through == 100)
    }

    @Test("caught-up cursor idles instead of scanning sub-second windows")
    func caughtUpIdles() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 160, lastPlayhead: 100)
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 100.2,
                                                    lead: 60, backscan: 15, jumpThreshold: 2.5)
        #expect(plan == .idle)
    }

    // #143 follow-up: a reconstruction pass whose landing line is the newest composition in the
    // drain window has no successor to trigger admitDuringReconstruction's flush. The drain
    // finalizes it once it confirms a candidate is seeded and no composition is stored ahead in the
    // lead window.

    @Test("reconstruction with a seeded candidate and no successor ahead should finalize")
    func finalizeWhenNoSuccessorAhead() {
        #expect(SubtitleOverlayDrainer.shouldFinalizeReconstruction(
            reconstructing: true, hasCandidate: true, hasSuccessorAhead: false))
    }

    @Test("a stored successor in the lead window ends the pass the normal way, not by finalize")
    func noFinalizeWhenSuccessorAhead() {
        #expect(!SubtitleOverlayDrainer.shouldFinalizeReconstruction(
            reconstructing: true, hasCandidate: true, hasSuccessorAhead: true))
    }

    @Test("finalize needs a seeded candidate: a true gap with nothing behind ends nothing")
    func noFinalizeWithoutCandidate() {
        #expect(!SubtitleOverlayDrainer.shouldFinalizeReconstruction(
            reconstructing: true, hasCandidate: false, hasSuccessorAhead: false))
    }

    @Test("finalize only applies inside a reconstruction pass")
    func noFinalizeOutsideReconstruction() {
        #expect(!SubtitleOverlayDrainer.shouldFinalizeReconstruction(
            reconstructing: false, hasCandidate: true, hasSuccessorAhead: false))
    }
}
