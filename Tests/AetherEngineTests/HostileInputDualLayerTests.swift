// Only with the DualLayerDolbyVision trait: without it every Profile 7 decision is `notBuiltIn`.
#if DualLayerDolbyVision
import Testing
import AetherLibavcodec
@testable import AetherEngine

@Suite("Hostile container values in the dual-layer route decision")
struct HostileInputDualLayerTests {

    // MARK: - DEC-205 over-budget percentage

    @Test("DEC-205: an Int32.max square picture builds its over-budget log line")
    func overBudgetLineWithAbsurdGeometry() {
        let geometry = DualLayerRouteDecision.Geometry(width: Int(Int32.max), height: Int(Int32.max), frameRate: 24)
        let decision = DualLayerRouteDecision.decide(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 7, dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: true, isLive: false, isSourceSeekable: true,
            canHardwareDecode: { true }, elType: "FEL", geometry: geometry)
        #expect(decision.logLine?.contains("over the real-time budget") == true)
    }
}
#endif
