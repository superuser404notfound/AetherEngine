import Foundation
import Testing
@testable import AetherEngine

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

/// A scanner has to retry a still that yielded and give up on one that failed, so the two must not
/// share the bare nil `thumbnail(at:)` returns (Sodalite#118).
@Suite("FrameExtractor still outcome")
struct FrameExtractorOutcomeTests {
    @Test("a starved pipeline reports yielded",
          .enabled(if: fixtureExists("sdr-h264.mp4"), "run Scripts/fetch-fixtures.sh"),
          .timeLimit(.minutes(3)))
    func yieldReportsYielded() async {
        let extractor = FrameExtractor(url: fixtureURL("sdr-h264.mp4"), yieldWhile: { true })
        let outcome = await extractor.thumbnailOutcome(at: 1.0, maxWidth: 320)
        guard case .yielded = outcome else {
            Issue.record("expected .yielded, got \(outcome)")
            await extractor.shutdown()
            return
        }
        await extractor.shutdown()
    }

    @Test("no gate decodes an image",
          .enabled(if: fixtureExists("sdr-h264.mp4"), "run Scripts/fetch-fixtures.sh"),
          .timeLimit(.minutes(3)))
    func noGateReturnsImage() async {
        let extractor = FrameExtractor(url: fixtureURL("sdr-h264.mp4"))
        let outcome = await extractor.thumbnailOutcome(at: 1.0, maxWidth: 320)
        guard case .image(let image) = outcome else {
            Issue.record("expected .image, got \(outcome)")
            await extractor.shutdown()
            return
        }
        #expect(image.width <= 320)
        await extractor.shutdown()
    }

    @Test("a source that cannot open is unavailable", .timeLimit(.minutes(3)))
    func badURLIsUnavailable() async {
        let missing = URL(fileURLWithPath: "/nonexistent/aether-\(UUID().uuidString).mp4")
        let extractor = FrameExtractor(url: missing)
        let outcome = await extractor.thumbnailOutcome(at: 1.0, maxWidth: 320)
        guard case .unavailable = outcome else {
            Issue.record("expected .unavailable, got \(outcome)")
            await extractor.shutdown()
            return
        }
        await extractor.shutdown()
    }

    @Test("a cancelled request is worth repeating, not a failure", .timeLimit(.minutes(3)))
    func cancelledIsYielded() async {
        let missing = URL(fileURLWithPath: "/nonexistent/aether-\(UUID().uuidString).mp4")
        let extractor = FrameExtractor(url: missing)
        let task = Task { () -> StillOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await extractor.thumbnailOutcome(at: 1.0, maxWidth: 320)
        }
        let outcome = await task.value
        guard case .yielded = outcome else {
            Issue.record("expected .yielded, got \(outcome)")
            await extractor.shutdown()
            return
        }
        await extractor.shutdown()
    }
}
