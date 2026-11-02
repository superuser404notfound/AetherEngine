import Foundation
import Testing
@testable import AetherEngine

@Suite("Keyframe still ladder")
struct KeyframeStillLadderTests {
    /// 4 s segments over 600 s.
    private let starts = stride(from: 0.0, to: 600.0, by: 4.0).map { $0 }

    private func idle() -> KeyframeStillLadder.LinkState {
        .init(restartInFlight: false, seeking: false, forwardBufferSeconds: 120,
              originInflight: 0, originWaiting: 0, originPaced: false, originSerial: false,
              secondsSinceOriginRefusal: nil, secondsSinceSessionStart: 60, secondsSinceLastRung: nil)
    }

    @Test("the coarse stride is finished before any gap is narrowed, nearest the playhead first")
    func coarseFirstNearestPlayhead() {
        var cached = Set<Int>()
        var order: [Int] = []
        while let next = KeyframeStillLadder.nextRung(
            segmentStarts: starts, totalSeconds: 600, playheadSeconds: 300,
            isCached: { cached.contains($0) }, isResident: { _ in false }) {
            order.append(next)
            cached.insert(next)
        }
        let seconds = order.map { starts[$0] }
        #expect(seconds.first == 300)
        let coarse = Set(stride(from: 0.0, to: 600.0, by: 60.0))
        #expect(Set(seconds.prefix(coarse.count)) == coarse)
        #expect(seconds.count == 20)
        // A rung is the segment starting at or before its time: 30 s falls inside the one at 28 s.
        #expect(Set(seconds) == Set(stride(from: 0.0, to: 600.0, by: 30.0).map { ($0 / 4).rounded(.down) * 4 }))
    }

    @Test("resident segments are not read")
    func skipsResident() {
        let next = KeyframeStillLadder.nextRung(
            segmentStarts: starts, totalSeconds: 600, playheadSeconds: 0,
            isCached: { _ in false }, isResident: { $0 <= 30 })
        #expect(next.map { starts[$0] } == 180)
    }

    @Test("an empty or degenerate plan has no rung")
    func degenerate() {
        #expect(KeyframeStillLadder.nextRung(segmentStarts: [], totalSeconds: 600, playheadSeconds: 0,
                                             isCached: { _ in false }, isResident: { _ in false }) == nil)
        #expect(KeyframeStillLadder.nextRung(segmentStarts: starts, totalSeconds: .nan, playheadSeconds: 0,
                                             isCached: { _ in false }, isResident: { _ in false }) == nil)
    }

    @Test("a scrub is answered by the rung at or before it, else the one after, within the distance")
    func answeringRung() {
        let cached = [15, 30, 45]  // 60 s, 120 s, 180 s
        #expect(KeyframeStillLadder.answeringRung(for: 130, segmentStarts: starts, cached: cached) == 30)
        #expect(KeyframeStillLadder.answeringRung(for: 120, segmentStarts: starts, cached: cached) == 30)
        #expect(KeyframeStillLadder.answeringRung(for: 10, segmentStarts: starts, cached: cached) == 15)
        #expect(KeyframeStillLadder.answeringRung(for: 300, segmentStarts: starts, cached: cached) == nil)
        #expect(KeyframeStillLadder.answeringRung(for: 130, segmentStarts: starts, cached: []) == nil)
        #expect(KeyframeStillLadder.answeringRung(for: 130, segmentStarts: starts, cached: [9999]) == nil)
    }

    @Test("the link is idle only with nothing in flight and every guard clear")
    func linkGate() {
        #expect(KeyframeStillLadder.linkIsIdle(idle()))
        var s = idle(); s.originInflight = 1
        #expect(!KeyframeStillLadder.linkIsIdle(s))
        s = idle(); s.originWaiting = 1
        #expect(!KeyframeStillLadder.linkIsIdle(s))
        s = idle(); s.originPaced = true
        #expect(!KeyframeStillLadder.linkIsIdle(s))
        s = idle(); s.restartInFlight = true
        #expect(!KeyframeStillLadder.linkIsIdle(s))
        s = idle(); s.seeking = true
        #expect(!KeyframeStillLadder.linkIsIdle(s))
        s = idle(); s.forwardBufferSeconds = 29
        #expect(!KeyframeStillLadder.linkIsIdle(s))
        s = idle(); s.secondsSinceSessionStart = 5
        #expect(!KeyframeStillLadder.linkIsIdle(s))
        s = idle(); s.secondsSinceOriginRefusal = 60
        #expect(!KeyframeStillLadder.linkIsIdle(s))
        s = idle(); s.secondsSinceOriginRefusal = 200
        #expect(KeyframeStillLadder.linkIsIdle(s))
        s = idle(); s.secondsSinceLastRung = 1
        #expect(!KeyframeStillLadder.linkIsIdle(s))
    }

    @Test("a one-request origin is never read, however idle the link looks (AE#937)")
    func serialOriginNeverRead() {
        var s = idle(); s.originSerial = true
        #expect(!KeyframeStillLadder.linkIsIdle(s))
        s.secondsSinceSessionStart = 3600; s.forwardBufferSeconds = 600
        #expect(!KeyframeStillLadder.linkIsIdle(s))
    }

    @Test("ladder extractor keys never collide with segments or the local-file still")
    func extractorKeys() {
        #expect(AetherEngine.ladderStillKey(segmentIndex: 0) < AetherEngine.localSoftwareStillKey)
        #expect(AetherEngine.ladderStillKey(segmentIndex: 0) != AetherEngine.ladderStillKey(segmentIndex: 1))
    }

    @Test("a cached keyframe is answered without a read, a missing one is not read")
    func cachedPayloadNeverReads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ladder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = IFramePayloadCache(directory: dir)
        cache.store(Data([1, 2, 3]), for: 1)
        let reads = Counter()
        let rendition = IFrameRendition(
            entries: (0..<3).map { .init(startPts: Int64($0), startSeconds: Double($0), durationSeconds: 1) },
            cache: cache,
            readPayload: { _ in reads.increment(); return Data([9]) },
            buildFragment: { _, _, _ in nil })
        #expect(rendition.cachedKeyframePayload(at: 1) == Data([1, 2, 3]))
        #expect(rendition.cachedKeyframePayload(at: 0) == nil)
        #expect(rendition.cachedKeyframePayload(at: 7) == nil)
        #expect(reads.value == 0)
        rendition.shutdown()
        #expect(rendition.cachedKeyframePayload(at: 1) == nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
