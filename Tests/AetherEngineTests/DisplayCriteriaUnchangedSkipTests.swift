import Testing
import CoreMedia
@testable import AetherEngine

// #133 Issue B: on a same-format live zap (e.g. SDR 50 Hz -> SDR 50 Hz), the engine re-applied identical
// AVDisplayCriteria unconditionally. On a Dolby-Vision panel that redundant write triggers an unobservable
// mode switch, and the unconditional post-load waitForSwitch() then burns the full ~3000 ms cap on every
// zap. The controller retains no last-applied criteria, so it cannot tell the mode is already active.
//
// The fix retains the last-applied criteria and skips the panel write (and the settle wait) only when we
// previously applied exactly these criteria and have not reset since. This suite covers that pure DECISION.
@Suite("DisplayCriteria unchanged-apply skip")
struct DisplayCriteriaUnchangedSkipTests {

    private let hvc1: CMVideoCodecType = kCMVideoCodecType_HEVC
    private let dvh1: CMVideoCodecType = 0x64766831

    private func sdr50() -> DisplayCriteriaController.AppliedCriteria {
        .init(isHDR: false, effectiveRate: 50, codecType: hvc1, hasExtensions: false)
    }

    @Test("First apply of a session (nothing applied yet) is never skipped")
    func firstApplyNotSkipped() {
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: false, last: nil, target: sdr50()) == .applied)
    }

    @Test("Re-applying identical SDR criteria after a prior apply is skipped as unchanged")
    func identicalSdrSkipped() {
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: true, last: sdr50(), target: sdr50()) == .unchanged)
    }

    @Test("A rate change is applied, not skipped")
    func rateChangeApplied() {
        let target = DisplayCriteriaController.AppliedCriteria(
            isHDR: false, effectiveRate: 60, codecType: hvc1, hasExtensions: false)
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: true, last: sdr50(), target: target) == .applied)
    }

    @Test("A format change into HDR yields willSwitch (caller must settle the panel)")
    func hdrChangeWillSwitch() {
        let target = DisplayCriteriaController.AppliedCriteria(
            isHDR: true, effectiveRate: 24, codecType: hvc1, hasExtensions: true)
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: true, last: sdr50(), target: target) == .willSwitch)
    }

    @Test("A codec change (hvc1 -> dvh1, Dolby Vision) at the same rate is applied, not skipped")
    func codecChangeApplied() {
        let target = DisplayCriteriaController.AppliedCriteria(
            isHDR: true, effectiveRate: 50, codecType: dvh1, hasExtensions: true)
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: true, last: sdr50(), target: target) == .willSwitch)
    }

    @Test("Identical HDR criteria re-applied is still skipped (unobservable-DV zap between two HDR channels)")
    func identicalHdrSkipped() {
        let hdr = DisplayCriteriaController.AppliedCriteria(
            isHDR: true, effectiveRate: 50, codecType: dvh1, hasExtensions: true)
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: true, last: hdr, target: hdr) == .unchanged)
    }

    @Test("After a reset (didApply cleared) the same criteria are applied fresh, not skipped")
    func afterResetNotSkipped() {
        // reset() nils lastApplied and clears didApply; the next load must re-establish the panel mode.
        #expect(DisplayCriteriaController.applyOutcome(
            didApply: false, last: nil, target: sdr50()) == .applied)
    }
}
