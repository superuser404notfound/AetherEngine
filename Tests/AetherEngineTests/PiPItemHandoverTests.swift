import Testing
@testable import AetherEngine

/// AE#158: a system PiP window closes the moment its source layer's player drops its item, so a
/// native->native load while PiP is active keeps the running item attached until the new master
/// swaps in place. See AetherEngine.shouldHandOverItemInPlace.
@Suite("PiP in-place item handover policy")
struct PiPItemHandoverTests {
    @Test("hands over in place only while PiP is active on a native session")
    func handsOverOnlyForNativePiP() {
        #expect(AetherEngine.shouldHandOverItemInPlace(pipActive: true, priorBackendWasNative: true) == true)
        #expect(AetherEngine.shouldHandOverItemInPlace(pipActive: false, priorBackendWasNative: true) == false)
        #expect(AetherEngine.shouldHandOverItemInPlace(pipActive: true, priorBackendWasNative: false) == false)
        #expect(AetherEngine.shouldHandOverItemInPlace(pipActive: false, priorBackendWasNative: false) == false)
    }
}
