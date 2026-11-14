import Foundation
import Testing
@testable import AetherEngine

/// AE#1059: six resident 4K still decoders held about 750 MB on an Apple TV 4K. The engine now
/// keeps the open decoders inside a pixel budget and lets the host close them when a scrub ends.
struct Issue1059ScrubDecoderBudgetTests {

    private let uhd = 3840 * 2160
    private let hd = 1920 * 1080

    @Test("A 1080p LRU stays fully open inside the budget")
    func hdLRUKeepsEveryDecoder() {
        let released = AetherEngine.scrubDecodersToRelease(
            newestLast: Array(repeating: hd, count: 5), incomingArea: hd)
        #expect(released.isEmpty)
    }

    @Test("A 4K source keeps only the incoming decoder open")
    func uhdClosesEveryOlderDecoder() {
        let released = AetherEngine.scrubDecodersToRelease(
            newestLast: [uhd, uhd, 0, uhd], incomingArea: uhd)
        #expect(released.sorted() == [0, 1, 3])
    }

    @Test("The newest decoder wins when an unknown incoming source leaves room for one")
    func newestDecoderWinsTheRemainingRoom() {
        let released = AetherEngine.scrubDecodersToRelease(
            newestLast: [uhd, uhd], incomingArea: 0)
        #expect(released == [0])
    }

    @Test("Releasing a resident decoder keeps its cached still")
    func releaseKeepsCachedStill() async throws {
        let extractor = FrameExtractor(
            residentReader: DataIOReader(data: try LongGOPTransportStreamFixture.data()),
            formatHint: "mpegts", identity: "release-keeps-cache", residentBudget: .seconds(60))
        // A loaded runner can take longer than the 3 s resident idle close between two steps.
        await extractor.setIdleIntervalForTesting(.seconds(600))
        let first = try #require(await extractor.residentPreview(
            rawTarget: 2, refined: false, maxWidth: 16, isCancelled: { false }))
        #expect(await extractor.openDecoderPixelArea > 0)

        await extractor.releaseDecoder()
        #expect(await extractor.openDecoderPixelArea == 0)
        #expect(await extractor.knownDecoderPixelArea > 0)

        // The cached approximation answers without reopening the decoder.
        let again = try #require(await extractor.residentPreview(
            rawTarget: 2, refined: false, maxWidth: 16, isCancelled: { false }))
        #expect(again.image === first.image)
        #expect(await extractor.openDecoderPixelArea == 0)

        // A refined request reopens lazily.
        #expect(await extractor.residentPreview(
            rawTarget: 2, refined: true, maxWidth: 16, isCancelled: { false }) != nil)
        #expect(await extractor.openDecoderPixelArea > 0)
        await extractor.shutdown()
    }

    @Test("releaseScrubPreviewDecoders closes every decoder and keeps the extractors")
    @MainActor
    func engineReleasesEveryDecoder() async throws {
        let engine = try AetherEngine()
        let data = try LongGOPTransportStreamFixture.data()
        for segmentIndex in 0..<2 {
            let extractor = FrameExtractor(residentReader: DataIOReader(data: data), formatHint: "mpegts",
                                           identity: "release-\(segmentIndex)", residentBudget: .seconds(60))
            #expect(await extractor.residentPreview(
                rawTarget: 2, refined: false, maxWidth: 16, isCancelled: { false }) != nil)
            engine.scrubThumbnailExtractors.append((segmentIndex, extractor))
        }

        await engine.releaseScrubPreviewDecoders()
        #expect(engine.scrubThumbnailExtractors.count == 2)
        for entry in engine.scrubThumbnailExtractors {
            #expect(await entry.extractor.openDecoderPixelArea == 0)
        }

        let retained = engine.scrubThumbnailExtractors.map { $0.extractor }
        engine.scrubThumbnailExtractors.removeAll()
        for extractor in retained { await extractor.shutdown() }
    }

    @Test("The budget closes older decoders before a new one opens")
    @MainActor
    func budgetClosesOlderDecodersBeforeIncoming() async throws {
        let engine = try AetherEngine()
        let data = try LongGOPTransportStreamFixture.data()
        var extractors: [FrameExtractor] = []
        for segmentIndex in 0..<3 {
            let extractor = FrameExtractor(residentReader: DataIOReader(data: data), formatHint: "mpegts",
                                           identity: "budget-\(segmentIndex)", residentBudget: .seconds(60))
            await extractor.setIdleIntervalForTesting(.seconds(600))
            #expect(await extractor.residentPreview(
                rawTarget: 2, refined: false, maxWidth: 16, isCancelled: { false }) != nil)
            engine.scrubThumbnailExtractors.append((segmentIndex, extractor))
            extractors.append(extractor)
        }
        let area = await extractors[0].openDecoderPixelArea
        #expect(area > 0)
        // The fixture is small, so it fits six times over. A budget of two of its decoders has to
        // close the oldest one, and the incoming one counts at its known size.
        let states = await [extractors[0].openDecoderPixelArea, extractors[1].openDecoderPixelArea, 0]
        #expect(AetherEngine.scrubDecodersToRelease(newestLast: states, incomingArea: area,
                                                    budget: 2 * area) == [0])

        await engine.enforceScrubDecoderBudget(before: extractors[2])
        // Inside the real budget nothing closes.
        for extractor in extractors { #expect(await extractor.openDecoderPixelArea > 0) }

        engine.scrubThumbnailExtractors.removeAll()
        for extractor in extractors { await extractor.shutdown() }
    }

    @Test("Resident extractors close idle decoders after three seconds")
    func residentIdleIntervalIsShort() {
        #expect(FrameExtractor.residentIdleInterval == .seconds(3))
    }
}
