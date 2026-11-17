import Foundation
import Testing
@testable import AetherEngine

/// What leaves with an item: `stop()`, the next `load()` and a load its caller cancelled
/// (Sodalite#173) clear the same per-item state through one reset (audit LIF-R202).
@Suite("Per-item state leaves with its item", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct ItemScopedResetTests {

    private static func loadedEngine() async throws -> AetherEngine {
        let engine = try AetherEngine()
        _ = try await engine.load(source: .custom(DataIOReader(data: try ProbeTestFixtures.combined()), formatHint: "mp4"))
        return engine
    }

    private static func expectNoItemState(_ engine: AetherEngine, _ comment: Comment) {
        #expect(engine.audioTracks.isEmpty, comment)
        #expect(engine.subtitleTracks.isEmpty, comment)
        #expect(engine.duration == 0, comment)
        #expect(engine.metadata == nil, comment)
        #expect(engine.videoFormat == .sdr, comment)
        #expect(engine.sourceVideoFormat == .sdr, comment)
        #expect(engine.sourceVideoWidth == 0, comment)
        #expect(engine.sourceVideoHeight == 0, comment)
        #expect(engine.sourceVideoCodecName == nil, comment)
        #expect(engine.sourceContainerFormat == nil, comment)
        #expect(engine.mediaChapters.isEmpty, comment)
        #expect(engine.currentTime == 0, comment)
    }

    @Test("a cancelled load leaves no trace of its item behind (audit LIF-R202, Sodalite#173)")
    func cancelledGenerationClearsTheItem() async throws {
        let engine = try await Self.loadedEngine()
        defer { engine.stop() }
        #expect(!engine.audioTracks.isEmpty)
        #expect(engine.sourceVideoWidth > 0)

        engine.endCancelledGeneration(engine.loadGeneration)
        #expect(engine.state == .idle)
        #expect(engine.loadedURL == nil)
        Self.expectNoItemState(engine, "after a cancelled generation")
    }

    @Test("stop() clears the same per-item state (audit LIF-R202)")
    func stopClearsTheItem() async throws {
        let engine = try await Self.loadedEngine()
        engine.stop()
        Self.expectNoItemState(engine, "after stop()")
    }
}
