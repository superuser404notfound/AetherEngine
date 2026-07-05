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
