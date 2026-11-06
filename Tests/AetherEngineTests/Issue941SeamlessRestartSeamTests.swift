import Testing
import Foundation
@testable import AetherEngine

/// #941 round 2, Mac repro: a set lost at a seamless producer restart.
///
/// The pump opened at seg 7 and had cut segs 7..15 when AVPlayer fetched seg 16, which it had not
/// written yet, so the provider restarted it at seg 16 (65.42 s). The outgoing run had read up to
/// 65.42 s, but the ledger only knew it through its last harvested subtitle packet, 64.42 s. The
/// stretch 64.42..65.42 read as a hole no run would ever fill, the drain held at 64.42 until its tick
/// budget ran out, then decoded the island 69.42.. before the new run had harvested 67.42, and the
/// cursor never came back for it (measured: 3 of 5 runs on main lost 67.42).
@Suite("#941: a restart that continues the pump's run carries its coverage up to the seam")
struct Issue941SeamlessRestartSeamTests {

    @Test("continuation is recognised only when the run cut every segment before the restart")
    func continuation() {
        #expect(HLSVideoEngine.restartContinuesHarvestRun(runStartIndex: 7, runHighestCaptured: 15,
                                                          restartIndex: 16))
        // Restart behind its own head, inside the run: everything up to it was read too.
        #expect(HLSVideoEngine.restartContinuesHarvestRun(runStartIndex: 7, runHighestCaptured: 15,
                                                          restartIndex: 12))
        // A forward jump past the head skips ground.
        #expect(!HLSVideoEngine.restartContinuesHarvestRun(runStartIndex: 7, runHighestCaptured: 15,
                                                           restartIndex: 17))
        // A backward jump below where the run opened.
        #expect(!HLSVideoEngine.restartContinuesHarvestRun(runStartIndex: 14, runHighestCaptured: 15,
                                                           restartIndex: 7))
        // Nothing cut yet, or no known run.
        #expect(!HLSVideoEngine.restartContinuesHarvestRun(runStartIndex: 16, runHighestCaptured: Int.min,
                                                           restartIndex: 17))
        #expect(!HLSVideoEngine.restartContinuesHarvestRun(runStartIndex: nil, runHighestCaptured: 15,
                                                           restartIndex: 16))
    }

    /// Ledger and store as the diagnostic line showed them at the tick that lost 67.42.
    @Test("with the seam claimed the hold resumes on the new run instead of timing out")
    func holdResumesAcrossTheSeam() {
        var coverage = SubtitleHarvestCoverage()
        coverage.noteAnchor(.pump, at: 57.42)
        coverage.noteReach(.pump, through: 64.42)
        coverage.noteAnchor(.pump, at: 29.42)
        coverage.noteReach(.pump, through: 64.42)   // last harvested subtitle packet of run C
        var seamless = coverage
        coverage.noteAnchor(.pump, at: 65.42)       // restart at seg 16, as main did it
        coverage.noteReach(.pump, through: 66.42)
        seamless.noteReach(.pump, through: 65.42)   // the claim this change adds
        seamless.noteAnchor(.pump, at: 65.42)
        seamless.noteReach(.pump, through: 66.42)

        // Held at 64.42 (sequence 18); the window now opens with the new run's 66.42 (sequence 45).
        #expect(!SubtitleOverlayDrainer.harvestGapHoldResumes(
            firstSequence: 45, heldSequence: 18, firstPts: 66.42, heldAt: 64.42,
            isRead: { coverage.covers(from: $0, through: $1) }))
        #expect(SubtitleOverlayDrainer.harvestGapHoldResumes(
            firstSequence: 45, heldSequence: 18, firstPts: 66.42, heldAt: 64.42,
            isRead: { seamless.covers(from: $0, through: $1) }))

        // And the next pair, the new run's 66.42 against the older island at 69.42, still stops it.
        let pts: [Double] = [66.42, 69.42, 70.42]
        let sequence: [UInt64] = [45, 9, 10]
        let cut = SubtitleOverlayDrainer.harvestGapCut(
            count: pts.count, ptsAt: { pts[$0] }, sequenceAt: { sequence[$0] },
            resumeFrom: (64.42, 18), notBefore: 63.82 + 2,
            isRead: { seamless.covers(from: $0, through: $1) })
        #expect(cut?.index == 1)
        #expect(cut?.at == 66.42)
    }
}
