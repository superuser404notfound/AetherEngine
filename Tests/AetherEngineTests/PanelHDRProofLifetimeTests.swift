import Testing
@testable import AetherEngine

// An Apple TV 4K (1st gen, tvOS 26.6) read an EDR headroom of 1.00 through every HDR and Dolby Vision
// session, so the only proof it ever gave was AVFoundation accepting an HDR master. A host that builds
// an engine per item (one `DisplayCriteriaController` each) lost that proof at every load, and a
// software-host session (the Dolby Vision FEL route, which has no master to accept) kept its SDR label
// right after an AVPlayer session on the same display had proven HDR. The proof now belongs to the
// process. Its invalidation on leaving for the background is a UIKit notification and is not driven
// here; the refusal path goes through `AetherEngine.panelRefusedHDRMaster`, which other suites own.
@Suite("Panel HDR proof lifetime", .serialized)
@MainActor
struct PanelHDRProofLifetimeTests {

    init() { DisplayCriteriaController.forgetPanelProof("test setup") }

    @Test("an accepted HDR master proves the panel for every engine in the process")
    func proofOutlivesTheController() {
        let first = DisplayCriteriaController()
        #expect(!first.panelProvenToEngageHDR)
        first.notePanelEngagedHDR("test")
        let next = DisplayCriteriaController()
        #expect(next.panelProvenToEngageHDR)
        DisplayCriteriaController.forgetPanelProof("test teardown")
    }

    @Test("forgetting the proof clears it for every engine")
    func forgettingClearsIt() {
        let controller = DisplayCriteriaController()
        controller.notePanelEngagedHDR("test")
        DisplayCriteriaController.forgetPanelProof("a return from the background")
        #expect(!controller.panelProvenToEngageHDR)
        #expect(!DisplayCriteriaController().panelProvenToEngageHDR)
    }
}
