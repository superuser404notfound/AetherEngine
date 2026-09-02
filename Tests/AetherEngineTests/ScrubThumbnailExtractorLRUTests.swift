import Foundation
import Testing
@testable import AetherEngine

struct ScrubThumbnailExtractorLRUTests {

    @Test("cache-backed still LRU retains the six newest segment contexts")
    @MainActor
    func retainsSixNewestContexts() async throws {
        let engine = try AetherEngine()
        for segmentIndex in 0..<6 {
            engine.scrubThumbnailExtractors.append((
                segmentIndex,
                FrameExtractor(reader: DataIOReader(data: Data()), formatHint: "mp4")))
        }

        engine.trimScrubThumbnailExtractors()
        #expect(engine.scrubThumbnailExtractors.map { $0.segmentIndex } == Array(0..<6))

        engine.scrubThumbnailExtractors.append((
            6,
            FrameExtractor(reader: DataIOReader(data: Data()), formatHint: "mp4")))
        engine.trimScrubThumbnailExtractors()
        #expect(engine.scrubThumbnailExtractors.map { $0.segmentIndex } == Array(1...6))

        let retained = engine.scrubThumbnailExtractors.map { $0.extractor }
        engine.scrubThumbnailExtractors.removeAll()
        for extractor in retained {
            await extractor.shutdown()
        }
    }
}
