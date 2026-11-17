import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// What leaves with an item: `stop()`, the next `load()` and a load its caller cancelled
/// (Sodalite#173) clear the same per-item state through one reset (audit LIF-R202), and the
/// published native item follows the player to nil (audit LIF-207).
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

    @Test("the published native item goes nil with the player's (audit LIF-207, regression of AE#998)")
    func currentItemFollowsThePlayerToNil() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lif207-\(UUID().uuidString).mp4")
        let item = AVPlayerItem(url: file)
        let player = AVPlayer(playerItem: item)
        engine.currentAVPlayer = player
        #expect(engine.currentAVPlayerItem === item)

        player.replaceCurrentItem(with: nil)
        try await waitFor { engine.currentAVPlayerItem == nil }
        engine.currentAVPlayer = nil
    }
}
