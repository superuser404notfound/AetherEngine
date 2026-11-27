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

@Suite("Picture area end to end")
struct PictureAreaEndToEndTests {
    @Test("the scanner finds the bars a real decode carries",
          .enabled(if: FileManager.default.fileExists(atPath: fixtureURL("letterbox239.mp4").path),
                   "run Scripts/fetch-fixtures.sh"),
          .timeLimit(.minutes(3)))
    func scannerFindsBakedLetterbox() async throws {
        let extractor = FrameExtractor(url: fixtureURL("letterbox239.mp4"))
        let scanner = PictureAreaScanner(source: extractor, duration: 10, displayAspect: 16.0 / 9.0)
        let area = try #require(await scanner.firstPass())
        await extractor.shutdown()
        #expect(area.snappedRatio.map { (2.35...2.40).contains($0) } == true)
        #expect(abs(area.rect.height - 268.0 / 360.0) <= 0.02)
    }
}
