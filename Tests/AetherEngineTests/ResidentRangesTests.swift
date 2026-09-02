import Combine
import Foundation
import Testing
@testable import AetherEngine

@Suite("Resident segment ranges")
struct ResidentRangesTests {
    @MainActor
    private final class Recorder {
        private var cancellable: AnyCancellable?
        private var waiter: CheckedContinuation<Void, Never>?
        private var awaitedCount = 0
        private(set) var values: [[ClosedRange<Double>]] = []

        init(engine: AetherEngine) {
            cancellable = engine.$residentRanges.dropFirst().sink { [weak self] ranges in
                Task { @MainActor in self?.receive(ranges) }
            }
        }

        private func receive(_ ranges: [ClosedRange<Double>]) {
            values.append(ranges)
            if values.count >= awaitedCount {
                waiter?.resume()
                waiter = nil
            }
        }

        func waitForCount(_ count: Int) async {
            guard values.count < count else { return }
            awaitedCount = count
            await withCheckedContinuation { waiter = $0 }
        }
    }

    private func plan() -> [HLSVideoEngine.Segment] {
        [
            .init(startPts: 0, endPts: 5, startSeconds: 0, durationSeconds: 5),
            .init(startPts: 5, endPts: 12, startSeconds: 5, durationSeconds: 7),
            .init(startPts: 12, endPts: 20, startSeconds: 12, durationSeconds: 8),
            .init(startPts: 20, endPts: 30, startSeconds: 20, durationSeconds: 10),
        ]
    }

    @Test("index islands map onto the seek presentation axis")
    func mapping() {
        let session = HLSVideoEngine(url: URL(string: "https://example.com/video.mkv")!)
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        session.segmentPlan = plan()
        session.cache = cache
        for index in [0, 1, 3] { cache.store(index: index, data: Data([0])) }

        #expect(session.residentRanges() == [0...12, 20...30])
    }

    @Test("live sessions do not publish VOD cache ranges")
    func liveIsEmpty() {
        let session = HLSVideoEngine(
            url: URL(string: "https://example.com/live.ts")!,
            isLiveSession: true
        )
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        session.segmentPlan = plan()
        session.cache = cache
        cache.store(index: 0, data: Data([0]))

        #expect(session.residentRanges().isEmpty)
    }

    @MainActor
    @Test("a store and eviction publish their two resident shapes", .timeLimit(.minutes(1)))
    func publisherStoreThenEvict() async throws {
        let session = HLSVideoEngine(url: URL(string: "https://example.com/video.mkv")!)
        let cache = SegmentCache(
            forwardWindow: 10,
            backwardWindow: 10,
            onResidentSetChanged: { [weak session] in session?.noteResidentSetChanged() }
        )
        defer { cache.close() }
        session.segmentPlan = plan()
        session.cache = cache

        let engine = try AetherEngine()
        engine.nativeVideoSession = session
        let recorder = Recorder(engine: engine)

        cache.store(index: 1, data: Data([0]))
        await recorder.waitForCount(1)
        cache.evictBelow(2)
        await recorder.waitForCount(2)

        #expect(recorder.values == [[5...12], []])
        engine.nativeVideoSession = nil
    }
}
