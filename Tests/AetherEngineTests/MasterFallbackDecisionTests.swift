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

    @Test("Non-rejection codes never advance the chain")
    func nonRejectionStops() {
        #expect(MasterFallbackDecision.nextFallbackTarget(
            errorCode: -12889, currentStage: .primaryMaster, reducedMasterAvailable: true) == .none)
    }

    @Test("Primary master rejection goes to the reduced master when one is available")
    func primaryToReduced() {
        #expect(MasterFallbackDecision.nextFallbackTarget(
            errorCode: -11868, currentStage: .primaryMaster, reducedMasterAvailable: true) == .reducedMaster)
        #expect(MasterFallbackDecision.nextFallbackTarget(
            errorCode: -11848, currentStage: .primaryMaster, reducedMasterAvailable: true) == .reducedMaster)
    }

    @Test("Primary master rejection goes straight to media when no reduced master exists")
    func primaryToMediaWithoutReduced() {
        #expect(MasterFallbackDecision.nextFallbackTarget(
            errorCode: -11868, currentStage: .primaryMaster, reducedMasterAvailable: false) == .media)
    }

    @Test("Reduced master rejection goes to the bare media playlist")
    func reducedToMedia() {
        #expect(MasterFallbackDecision.nextFallbackTarget(
            errorCode: -11868, currentStage: .reducedMaster, reducedMasterAvailable: true) == .media)
    }

    @Test("Media rejection stops the chain (single pass, no loop)")
    func mediaStops() {
        #expect(MasterFallbackDecision.nextFallbackTarget(
            errorCode: -11868, currentStage: .media, reducedMasterAvailable: true) == .none)
    }
}
