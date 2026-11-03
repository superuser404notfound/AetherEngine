import CoreGraphics
import Foundation
import Testing
@testable import AetherEngine

@Suite("Bounded source-backed still extraction")
struct BoundedFrameExtractorTests {
    @Test("Input and deadline budgets cover open before decode", .timeLimit(.minutes(3)))
    func openIsBudgeted() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(".bounded-frame-\(UUID().uuidString).mp4")
        try ProbeTestFixtures.hdr10Plus().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let zeroInput = FrameExtractor(url: url)
        let inputResult = await zeroInput.boundedSnapshot(at: 0,
            maxSize: CGSize(width: 320, height: 320),
            limits: ProbeLimits(maxInputBytes: 0, maxPackets: 900,
                                maxPacketBytes: 4 * 1_024 * 1_024, timeBudget: 10),
            cancellation: ProbeCancellation())
        #expect(inputResult.map { _ in true } == nil)
        await zeroInput.shutdown()

        let zeroTime = FrameExtractor(url: url)
        let timeResult = await zeroTime.boundedSnapshot(at: 0,
            maxSize: CGSize(width: 320, height: 320),
            limits: ProbeLimits(maxInputBytes: 16 * 1_024 * 1_024, maxPackets: 900,
                                maxPacketBytes: 4 * 1_024 * 1_024, timeBudget: 0),
            cancellation: ProbeCancellation())
        #expect(timeResult.map { _ in true } == nil)
        await zeroTime.shutdown()
    }

    @Test("A decoded still returns its measured presentation timestamp", .timeLimit(.minutes(3)))
    func measuredPTS() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(".bounded-frame-\(UUID().uuidString).mp4")
        try ProbeTestFixtures.hdr10Plus().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let extractor = FrameExtractor(url: url)
        let result = await extractor.boundedSnapshot(at: 0,
            maxSize: CGSize(width: 320, height: 320),
            limits: ProbeLimits(maxInputBytes: 16 * 1_024 * 1_024, maxPackets: 900,
                                maxPacketBytes: 4 * 1_024 * 1_024, timeBudget: 30),
            cancellation: ProbeCancellation())
        await extractor.shutdown()
        let frame = try #require(result)
        #expect(frame.actualSeconds?.isFinite == true)
    }

    @Test("The deadline interrupts a stalled HTTP open", .timeLimit(.minutes(3)))
    func stalledHTTPHeader() async throws {
        let origin = try ProbeHTTPTestOrigin(data: ProbeTestFixtures.hdr10Plus(), stage: .headers)
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/still.mp4"))
        let extractor = FrameExtractor(url: url)
        let result = await extractor.boundedSnapshot(at: 0,
            maxSize: CGSize(width: 320, height: 320),
            limits: ProbeLimits(maxInputBytes: 16 * 1_024 * 1_024, maxPackets: 900,
                                maxPacketBytes: 4 * 1_024 * 1_024, timeBudget: 1),
            cancellation: ProbeCancellation())
        #expect(result.map { _ in true } == nil)
        await extractor.shutdown()
    }
}
