import Foundation
import Testing
@testable import AetherEngine

// Fixtures/ is local-only (gitignored; Scripts/fetch-fixtures.sh regenerates); tests skip when absent.
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

/// #93 startup: the elective still extraction (scrub-preview warm-seed, chapter thumbnails)
/// pulls megabytes over the same link the segment producer needs. During startup and recovery
/// that contention tipped the first segment past CoreMedia's ~4 s media timeout, the AVPlayer
/// loader died (-15628) and the session played 1-2 s then needed the stage-2 item reload.
/// Session-coupled extractors therefore yield while the playback pipeline is starved.
struct FrameExtractorYieldTests {

    @Test("yield while a restart is in flight or the forward buffer is thin/unknown")
    func yieldDecision() {
        #expect(FrameExtractor.shouldYield(restartInFlight: true, forwardBufferSeconds: 10.0))
        #expect(FrameExtractor.shouldYield(restartInFlight: false, forwardBufferSeconds: nil))
        #expect(FrameExtractor.shouldYield(restartInFlight: false, forwardBufferSeconds: 0.0))
        #expect(FrameExtractor.shouldYield(restartInFlight: false, forwardBufferSeconds: 2.9))
        #expect(!FrameExtractor.shouldYield(restartInFlight: false, forwardBufferSeconds: 3.0))
        #expect(!FrameExtractor.shouldYield(restartInFlight: false, forwardBufferSeconds: 8.0))
    }

    @Test("a yielded thumbnail returns nil cheaply; extraction resumes once healthy",
          .enabled(if: fixtureExists("restart-witness-subs.mkv"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clip"),
          .timeLimit(.minutes(1)))
    func yieldedThumbnailResumes() async {
        let starved = AtomicBool(true)
        let extractor = FrameExtractor(
            url: fixtureURL("restart-witness-subs.mkv"),
            yieldWhile: { starved.get() }
        )
        let yielded = await extractor.thumbnail(at: 1.0)
        #expect(yielded == nil, "a starved pipeline must not pay for a warm-seed decode")

        starved.set(false)
        let healthy = await extractor.thumbnail(at: 1.0)
        #expect(healthy != nil, "the yield must not poison the extractor")
        await extractor.shutdown()
    }
}
