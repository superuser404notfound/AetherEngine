import Testing
@testable import AetherEngine

struct MasterFallbackDecisionTests {

    @Test("Display-rejection codes are the two AVFoundation display-reject codes")
    func recognisesRejectionCodes() {
        #expect(MasterFallbackDecision.isDisplayRejectionCode(-11868))
        #expect(MasterFallbackDecision.isDisplayRejectionCode(-11848))
        #expect(!MasterFallbackDecision.isDisplayRejectionCode(-12889)) // media timeout
        #expect(!MasterFallbackDecision.isDisplayRejectionCode(-11800)) // generic unknown
        #expect(!MasterFallbackDecision.isDisplayRejectionCode(0))
    }

    @Test("#130: -1002 (all variants filtered at master parse) is a master rejection, not a display rejection")
    func recognisesVariantFilterRejection() {
        #expect(MasterFallbackDecision.isMasterRejectionCode(-1002))
        #expect(MasterFallbackDecision.isMasterRejectionCode(-11868))
        #expect(MasterFallbackDecision.isMasterRejectionCode(-11848))
        #expect(!MasterFallbackDecision.isMasterRejectionCode(-12889))
        #expect(!MasterFallbackDecision.isMasterRejectionCode(0))
        // The display-rejection set stays exactly the two AVFoundation codes.
        #expect(!MasterFallbackDecision.isDisplayRejectionCode(-1002))
    }

    @Test("#130: -1002 while serving the master falls back to media, single-shot")
    func variantFilterFallsBack() {
        #expect(MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -1002, servingMasterPlaylist: true, alreadyFellBack: false))
        #expect(!MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -1002, servingMasterPlaylist: false, alreadyFellBack: false))
        #expect(!MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -1002, servingMasterPlaylist: true, alreadyFellBack: true))
    }

    @Test("Fall back only for a rejection code while serving the master and not yet fallen back")
    func fallbackGate() {
        // Eligible: rejection code, serving master, first time.
        #expect(MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -11868, servingMasterPlaylist: true, alreadyFellBack: false))
        #expect(MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -11848, servingMasterPlaylist: true, alreadyFellBack: false))
        // Not a rejection code.
        #expect(!MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -12889, servingMasterPlaylist: true, alreadyFellBack: false))
        // Already serving media (not the master).
        #expect(!MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -11868, servingMasterPlaylist: false, alreadyFellBack: false))
        // Already fell back once this session (no loop).
        #expect(!MasterFallbackDecision.shouldFallBackToMediaPlaylist(
            errorCode: -11868, servingMasterPlaylist: true, alreadyFellBack: true))
    }
}
