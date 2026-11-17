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

    /// Audit LOAD-205: the live and VOD thumbnail paths returned the decoded still without looking at
    /// the generation again, so a zap during the decode handed the new item the old one's picture.
    @Test("a still decoded across a stop is not returned, one decoded within its session is")
    @MainActor
    func stillAcrossAStopIsDropped() async throws {
        let engine = try AetherEngine()
        let extractor = FrameExtractor(reader: DataIOReader(data: Data()), formatHint: "mp4")
        defer { Task { await extractor.shutdown() } }

        let kept: Int? = await engine.decodeScrubStill(on: extractor, generation: engine.loadGeneration) { 1 }
        #expect(kept == 1)

        let dropped: Int? = await engine.decodeScrubStill(on: extractor, generation: engine.loadGeneration) {
            engine.stop()
            return 2
        }
        #expect(dropped == nil)

        let abandoned: Int? = await engine.decodeScrubStill(
            on: extractor, generation: engine.loadGeneration, stillWanted: { false }) { 3 }
        #expect(abandoned == nil)
    }

    /// Audit LOAD-R201: one lookup for every still path. The live path kept its own copy that trimmed
    /// the shared list to two, so a host using both preview APIs on a live session lost four warm
    /// decoders on every live still.
    @Test("the shared lookup keeps six, moves a hit to the newest end, and replaces a stale identity")
    @MainActor
    func sharedLookupRules() async throws {
        let engine = try AetherEngine()
        for key in 0..<6 {
            _ = engine.scrubExtractor(key: key) {
                FrameExtractor(reader: DataIOReader(data: Data()), formatHint: "mp4")
            }
        }
        #expect(engine.scrubThumbnailExtractors.map(\.segmentIndex) == Array(0..<6))

        let hit = engine.scrubThumbnailExtractors[2].extractor
        #expect(engine.scrubExtractor(key: 2) { nil } === hit)
        #expect(engine.scrubThumbnailExtractors.map(\.segmentIndex) == [0, 1, 3, 4, 5, 2])

        _ = engine.scrubExtractor(key: 6) {
            FrameExtractor(reader: DataIOReader(data: Data()), formatHint: "mp4")
        }
        #expect(engine.scrubThumbnailExtractors.map(\.segmentIndex) == [1, 3, 4, 5, 2, 6])

        let resident = FrameExtractor(residentReader: DataIOReader(data: Data()), formatHint: "mp4",
                                      identity: "seg7-a")
        _ = engine.scrubExtractor(key: 7, identity: "seg7-a") { resident }
        let replacement = FrameExtractor(residentReader: DataIOReader(data: Data()), formatHint: "mp4",
                                         identity: "seg7-b")
        #expect(engine.scrubExtractor(key: 7, identity: "seg7-a") { nil } === resident)
        #expect(engine.scrubExtractor(key: 7, identity: "seg7-b") { replacement } === replacement)
        #expect(engine.scrubThumbnailExtractors.filter { $0.segmentIndex == 7 }.count == 1)

        let retained = engine.scrubThumbnailExtractors.map { $0.extractor }
        engine.scrubThumbnailExtractors.removeAll()
        for extractor in retained {
            await extractor.shutdown()
        }
    }
}
