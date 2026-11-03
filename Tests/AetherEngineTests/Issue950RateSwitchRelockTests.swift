import Testing
@testable import AetherEngine

// AE#950: on an LG C2 an SDR 23.976 start from the 50 Hz home screen released the play gate 50 to 135 ms
// after the switch started, through the #449 exact-rate exit: the display link already read 23.976 while
// the HDMI sink was still re-locking (tvOS reports such switches ending after ~2.5 s), and three of six
// starts flashed pink noise over the black. The exact reading now settles only a panel that was already at
// the rate before the write, which is the #449 case; one that had to switch waits for the end.
@Suite("AE#950 a rate the panel switched to does not settle the gate on sight")
struct Issue950RateSwitchRelockTests {

    @Test("The reporter's start: 50 Hz before the write, 23.976 at the gate, keeps waiting")
    func switchedExactReadingKeepsWaiting() {
        let preWrite = DisplayCriteriaController.panelRateRelation(requestedRate: 23.976, panelNominalRate: 50.001)
        #expect(preWrite == .different(panelRate: 50.001))
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: .exact(panelRate: 23.976), heldForMs: 0, preWrite: preWrite))
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: .exact(panelRate: 23.976), heldForMs: 5000, preWrite: preWrite))
    }

    @Test("A multiple reached by switching keeps waiting past the dwell too")
    func switchedMultipleKeepsWaiting() {
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: .multiple(panelRate: 50.0, factor: 2),
            heldForMs: DisplayCriteriaController.panelMultipleDwellMs * 10,
            preWrite: .different(panelRate: 60.0)))
    }

    @Test("The #449 panel, already at the rate before the write, keeps its fast exit")
    func panelAlreadyAtRateStillSettles() {
        #expect(DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: .exact(panelRate: 50.002), heldForMs: 0,
            preWrite: .exact(panelRate: 50.002)))
        #expect(DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: .multiple(panelRate: 50.002, factor: 2),
            heldForMs: DisplayCriteriaController.panelMultipleDwellMs,
            preWrite: .multiple(panelRate: 50.002, factor: 2)))
    }

    @Test("No pre-write reading behaves as before #950")
    func missingPreWriteReadingChangesNothing() {
        for preWrite in [nil, DisplayCriteriaController.PanelRateRelation.unmeasured] {
            #expect(DisplayCriteriaController.rateOnlySwitchIsSettled(
                attribution: .engineRateOnly, relation: .exact(panelRate: 23.976), heldForMs: 0, preWrite: preWrite))
        }
    }
}
