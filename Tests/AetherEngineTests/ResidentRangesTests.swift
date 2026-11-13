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
        private var expectation: (([ClosedRange<Double>]) -> Bool)?
        private var cursor = 0
        private(set) var values: [[ClosedRange<Double>]] = []

        init(engine: AetherEngine) {
            cancellable = engine.$residentRanges.dropFirst().sink { [weak self] ranges in
                Task { @MainActor in self?.receive(ranges) }
            }
        }

        private func receive(_ ranges: [ClosedRange<Double>]) {
            values.append(ranges)
            matchFromCursor()
        }

        private func matchFromCursor() {
            guard let expectation else { return }
            while cursor < values.count {
                let value = values[cursor]
                cursor += 1
                guard expectation(value) else { continue }
                self.expectation = nil
                waiter?.resume()
                waiter = nil
                return
            }
        }

        /// Wait for the next band that satisfies `isExpected`, skipping the ones an earlier wait
        /// already consumed. Waiting on a publication COUNT instead would tie the test to the
        /// coalescing window: the snapshot the session is asked for on assignment and the store's
        /// snapshot are one publication when they fall inside the same 250 ms and two when they
        /// do not, and which of those happens is the machine's business, not the fold's.
        func wait(for isExpected: @escaping ([ClosedRange<Double>]) -> Bool) async {
            expectation = isExpected
            matchFromCursor()
            guard expectation != nil else { return }
            await withCheckedContinuation { continuation in
                if expectation == nil { continuation.resume() } else { waiter = continuation }
            }
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

    @Test("index islands map onto the playlist axis the plan is cut on")
    func mapping() {
        let session = HLSVideoEngine(url: URL(string: "https://example.com/video.mkv")!)
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        session.segmentPlan = plan()
        session.cache = cache
        for index in [0, 1, 3] { cache.store(index: index, data: Data([0])) }

        #expect(session.residentPlaylistRanges() == [0...12, 20...30])
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

        #expect(session.residentPlaylistRanges().isEmpty)
    }

    @MainActor
    @Test("a store and eviction publish their two resident shapes", .timeLimit(.minutes(3)))
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
        // A shift the fold has to survive end to end: with the plan seconds published raw this reads
        // 5...12, which is the AE#468 follow-up defect and not what a host draws its scrubber on.
        engine.sourcePresentationOrigin = 100
        engine.playlistShiftSeconds = 103
        engine.nativeVideoSession = session
        let recorder = Recorder(engine: engine)

        cache.store(index: 1, data: Data([0]))
        await recorder.wait { !$0.isEmpty }
        cache.evictBelow(2)
        await recorder.wait { $0.isEmpty }

        #expect(recorder.values.contains([8...15]))
        #expect(recorder.values.allSatisfy { $0.isEmpty || $0 == [8...15] })
        #expect(recorder.values.last?.isEmpty == true)
        engine.nativeVideoSession = nil
    }

    /// AE#468 follow-up. The plan is cut on the playlist axis; `currentTime`, `duration` and
    /// `seek(to:)` live on the 0-based display axis, and AE#270 made the two differ on exactly this
    /// path (the origin is the container's start, the shift also carries the producer's drift).
    /// Publishing plan seconds raw put the band beside the host's own scrubber.
    @MainActor
    @Test("the published band folds onto the display axis, not the plan's")
    func foldsOntoDisplayAxis() throws {
        let engine = try AetherEngine()
        engine.sourcePresentationOrigin = 100
        engine.playlistShiftSeconds = 102.5
        engine.residentPlaylistRanges = [0...12, 20...30]

        engine.republishResidentRanges()

        #expect(engine.residentRanges == [2.5...14.5, 22.5...32.5])
    }

    /// The seam map decides the shift per position, so bytes below a seam keep folding with the
    /// producer that muxed them, the same rule the clock fold follows.
    @MainActor
    @Test("a seam folds the spans below it with the retired producer's shift")
    func foldsPerSeam() throws {
        let engine = try AetherEngine()
        engine.sourcePresentationOrigin = 0
        engine.playlistShiftSeconds = 5
        var map = PresentationAxisMap.anchored(shiftSeconds: 1)
        map.appendSeam(shiftSeconds: 5, activatingAtItemSeconds: 20)
        engine.setPresentationAxis(map)
        engine.residentPlaylistRanges = [0...12, 20...30]

        engine.republishResidentRanges()

        #expect(engine.residentRanges == [1...13, 25...35])
    }

    /// A producer restart republishes the shift without touching the cache. The band has to re-fold
    /// then, or it carries the retired epoch's offset until the next segment happens to land.
    @MainActor
    @Test("a shift change re-folds a band the cache did not touch")
    func shiftChangeRefolds() throws {
        let engine = try AetherEngine()
        engine.sourcePresentationOrigin = 0
        engine.playlistShiftSeconds = 0
        engine.residentPlaylistRanges = [10...20]
        engine.republishResidentRanges()
        #expect(engine.residentRanges == [10...20])

        engine.playlistShiftSeconds = 2
        engine.republishResidentRanges()

        #expect(engine.residentRanges == [12...22])
    }
}
