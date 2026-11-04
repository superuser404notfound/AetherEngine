import Foundation
import Testing
@testable import AetherEngine

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct DolbyVisionSourceCapabilityLifecycleTests {
    private func seedPriorDV(_ engine: AetherEngine) {
        engine.sourceDVBLCompatID = 1
        engine.sourceDolbyVisionBaseLayerPresentable = true
    }

    @Test func stopClearsPriorCapabilities() throws {
        let engine = try AetherEngine()
        seedPriorDV(engine)
        engine.stop()
        #expect(engine.sourceDVBLCompatID == nil)
        #expect(!engine.sourceDolbyVisionBaseLayerPresentable)
    }

    @Test func nonDVLoadDoesNotInheritPriorCapabilities() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions(autoplay: false)
        options.preferredDecodePath = .software
        options.dolbyVisionHandling = .baseLayerOnly
        // Reuse the generated HEVC fixture, remuxed with a P5 record over an HDR10 VUI.
        // This is the counterexample to deciding capability from the profile alone.
        try await engine.load(source: .custom(DataIOReader(data:
            try SupersededProbeGeometryTests.dolbyVisionProfile5OverHDR10()), formatHint: "mp4"),
            options: options)
        #expect(engine.sourceDVProfile == 5)
        #expect(engine.sourceDVBLCompatID == 0)
        #expect(engine.sourceDolbyVisionBaseLayerPresentable)
        try await engine.load(source: .custom(
            DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4"), options: options)
        #expect(engine.sourceDVProfile == nil)
        #expect(engine.sourceDVBLCompatID == nil)
        #expect(!engine.sourceDolbyVisionBaseLayerPresentable)
    }

    @Test func pendingAndCancelledLoadClearPriorCapabilities() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        seedPriorDV(engine)
        let reader = CancellableLoadTests.ParkedReader()
        let load = Task { try await engine.load(source: .custom(reader, formatHint: "mp4")) }
        defer { load.cancel(); reader.close() }
        try await waitFor { reader.entered }
        #expect(engine.sourceDVBLCompatID == nil)
        #expect(!engine.sourceDolbyVisionBaseLayerPresentable)
        load.cancel()
        do {
            _ = try await load.value
            Issue.record("cancelled load returned successfully")
        } catch is CancellationError { }
        #expect(engine.sourceDVBLCompatID == nil)
        #expect(!engine.sourceDolbyVisionBaseLayerPresentable)
    }
}
