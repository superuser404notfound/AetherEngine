import Foundation
import Testing
@testable import AetherEngine

/// A session that prefetched the rest of a title from a resume point, then seeked back before that
/// point, restarted its producer there and cut every resident segment again, to the end of the
/// source. On the AE#1109 reporter's 6.7 GB film one rewind pulled 4.8 GB a second time.
///
/// The producer now stops in front of a resident run it could only reproduce: segments written on
/// the same axis by an earlier producer of the session, none of them an epoch's first. Measured with
/// `aetherctl play --start-position 300 --forward-buffer-segments 2700` and a seek to 0 on a 597 MB,
/// 10 minute MKV over HTTP (569 MB fetched after the seek before, 301 MB after), and with
/// `--picture-probe` across the seam on the timecode fixtures.
@Suite("Resident run park: a restarted producer keeps what it could only reproduce")
struct ResidentRunParkTests {

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resident-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let axis = SegmentLineage.Axis(videoShiftPts: 0, audioShiftPts: 0, audioDelaySeconds: 0)
    private var midRun: SegmentLineage { SegmentLineage(axis: axis, opensEpoch: false) }

    /// Adopts a staging file at `index`, the way the producer stores a segment it cut.
    private func adopt(_ cache: SegmentCache, _ index: Int, in dir: URL,
                       lineage: SegmentLineage?) throws {
        let staging = dir.appendingPathComponent("staging-\(index)-\(UUID().uuidString)")
        try Data(repeating: UInt8(index & 0xff), count: 64).write(to: staging)
        #expect(cache.adopt(index: index, stagingPath: staging, byteCount: 64, lineage: lineage))
    }

    // MARK: - Which runs a producer may keep

    @Test("AE#1109: mid-epoch segments on the producer's axis are kept up to the first hole",
          .timeLimit(.minutes(3)))
    func keepsMidEpochRun() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = SegmentCache(retentionBudgetBytes: 1 << 30, baseDirectory: base)
        defer { cache.close() }
        // The resume epoch opened at 33 and cut 34...40; 41 was never fetched.
        try adopt(cache, 33, in: base, lineage: SegmentLineage(axis: axis, opensEpoch: true))
        for index in 34...40 { try adopt(cache, index, in: base, lineage: midRun) }
        #expect(cache.keepableResidentRun(from: 34, axis: axis) == .init(frontier: 40, breaker: nil))
        // The epoch's first segment is cut again: its gate may have opened below the boundary.
        #expect(cache.keepableResidentRun(from: 33, axis: axis) == nil)
        #expect(cache.keepableResidentRun(from: 41, axis: axis) == nil, "nothing resident there")
        #expect(cache.keepableResidentRun(from: 34, axis: axis, through: 37) == .init(frontier: 37, breaker: nil))
    }

    @Test("AE#1109: a segment written another way ends the run and is named as its breaker",
          .timeLimit(.minutes(3)))
    func otherLineageEndsTheRun() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = SegmentCache(retentionBudgetBytes: 1 << 30, baseDirectory: base)
        defer { cache.close() }
        let shifted = SegmentLineage.Axis(videoShiftPts: 42, audioShiftPts: 0, audioDelaySeconds: 0)
        let delayed = SegmentLineage.Axis(videoShiftPts: 0, audioShiftPts: 0, audioDelaySeconds: 0.05)
        for index in 10...40 { try adopt(cache, index, in: base, lineage: midRun) }
        try adopt(cache, 25, in: base, lineage: SegmentLineage(axis: shifted, opensEpoch: false))
        try adopt(cache, 32, in: base, lineage: SegmentLineage(axis: axis, opensEpoch: true))
        #expect(cache.store(index: 38, data: Data(repeating: 38, count: 64)), "a plain store has no lineage")
        #expect(cache.keepableResidentRun(from: 10, axis: axis) == .init(frontier: 24, breaker: 25))
        #expect(cache.keepableResidentRun(from: 26, axis: axis) == .init(frontier: 31, breaker: 32))
        #expect(cache.keepableResidentRun(from: 33, axis: axis) == .init(frontier: 37, breaker: 38))
        #expect(cache.keepableResidentRun(from: 26, axis: delayed) == nil)
    }

    @Test("AE#1109: the breaker is evicted so the consumer misses there, unless it already asked for it",
          .timeLimit(.minutes(3)))
    func breakerIsDroppedOnlyAheadOfTheConsumer() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = SegmentCache(retentionBudgetBytes: 1 << 30, baseDirectory: base)
        defer { cache.close() }
        for index in 0...30 { try adopt(cache, index, in: base, lineage: midRun) }
        cache.declareTarget(5)
        #expect(cache.dropForRecut(index: 20))
        #expect(cache.peekURL(index: 20) == nil)
        #expect(cache.keepableResidentRun(from: 10, axis: axis) == .init(frontier: 19, breaker: nil))
        cache.declareTarget(25)
        #expect(!cache.dropForRecut(index: 22), "the consumer has been served past it")
        #expect(cache.peekURL(index: 22) != nil)
    }

    @Test("AE#1109: segments parked across a stop keep their lineage in the next session",
          .timeLimit(.minutes(3)))
    func parkedSegmentsKeepTheirLineage() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = SegmentCache(retentionBudgetBytes: 1 << 30, baseDirectory: base)
        old.setInit(Data("init".utf8))
        try adopt(old, 10, in: base, lineage: SegmentLineage(axis: axis, opensEpoch: true))
        for index in 11...30 { try adopt(old, index, in: base, lineage: midRun) }
        let parkedDir = base.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: parkedDir, withIntermediateDirectories: true)
        let parked = try #require(old.detachForParking(into: parkedDir))
        old.close()
        let new = SegmentCache(retentionBudgetBytes: 1 << 30, baseDirectory: base)
        defer { new.close() }
        new.adoptParked(parked, below: 31)
        #expect(new.keepableResidentRun(from: 11, axis: axis) == .init(frontier: 30, breaker: nil))
        #expect(new.keepableResidentRun(from: 10, axis: axis) == nil)
    }

    @Test("AE#1109: an evicted segment loses its lineage with its bytes", .timeLimit(.minutes(3)))
    func evictionClearsLineage() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = SegmentCache(retentionBudgetBytes: 1 << 30, baseDirectory: base)
        defer { cache.close() }
        for index in 0...9 { try adopt(cache, index, in: base, lineage: midRun) }
        cache.evictBelow(5)
        // Bytes stored there later without a lineage must not inherit the old one.
        #expect(cache.store(index: 3, data: Data(repeating: 3, count: 64)))
        #expect(cache.keepableResidentRun(from: 3, axis: axis) == nil)
        #expect(cache.keepableResidentRun(from: 5, axis: axis) == .init(frontier: 9, breaker: nil))
    }

    // MARK: - When the pump stops, and when it goes back to cutting

    @Test("AE#1109: a run reaching the minimum depth past the head holds the pump, like the provider's rule",
          .timeLimit(.minutes(3)))
    func depthMatchesTheProvider() {
        let depth = HLSSegmentProducer.residentRunMinimumDepth
        #expect(HLSSegmentProducer.residentRunHoldsPump(head: 34, frontier: 34 + depth, lastIndex: 500))
        #expect(!HLSSegmentProducer.residentRunHoldsPump(head: 34, frontier: 34 + depth - 1, lastIndex: 500))
        // The same boundary the provider keeps a producer on for a resident backward target.
        #expect(VideoSegmentProvider.residentBackwardTargetKeepsProducer(
            index: 34, residentFrontier: 34 + depth, activeMarchFront: 1000, prefetchDepth: depth))
        #expect(!VideoSegmentProvider.residentBackwardTargetKeepsProducer(
            index: 34, residentFrontier: 34 + depth - 1, activeMarchFront: 1000, prefetchDepth: depth))
    }

    @Test("AE#1109: a run that reaches the last segment holds the pump at any depth",
          .timeLimit(.minutes(3)))
    func runToTheEndHolds() {
        #expect(HLSSegmentProducer.residentRunHoldsPump(head: 497, frontier: 497, lastIndex: 497))
        #expect(HLSSegmentProducer.residentRunHoldsPump(head: 495, frontier: 499, lastIndex: 497))
        #expect(!HLSSegmentProducer.residentRunHoldsPump(head: 34, frontier: 33, lastIndex: 497))
    }

    @Test("AE#1109: a parked pump goes back to cutting only for a gap the consumer has not reached",
          .timeLimit(.minutes(3)))
    func releaseOnlyForAGapAheadOfTheConsumer() {
        // The run thinned before the consumer got there: cutting from the head is what it will need.
        #expect(HLSSegmentProducer.residentRunParkReleases(consumerTarget: 20, firstGap: 34))
        // The head was evicted behind a consumer at seg 200: resuming would fetch played segments.
        #expect(!HLSSegmentProducer.residentRunParkReleases(consumerTarget: 200, firstGap: 34))
        // A hole right ahead of a consumer past the head: the provider waits on this producer there,
        // because the index is that close to its base, so nobody else would fill it.
        #expect(HLSSegmentProducer.residentRunParkReleases(consumerTarget: 36, firstGap: 37))
        #expect(!HLSSegmentProducer.residentRunParkReleases(consumerTarget: 20, firstGap: nil))
    }
}
