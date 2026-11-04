import Testing
import AetherEngine

/// No @testable: host code must be able to read these without diagnostic SPI.
@MainActor
struct PublicDolbyVisionSourceCapabilityTests {
    @Test func publicDefaults() throws {
        let engine = try AetherEngine()
        let compatibility: Int? = engine.sourceDVBLCompatID
        let presentable: Bool = engine.sourceDolbyVisionBaseLayerPresentable
        #expect(compatibility == nil)
        #expect(!presentable)
    }
}
