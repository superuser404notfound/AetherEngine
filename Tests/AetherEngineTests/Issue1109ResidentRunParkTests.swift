import Foundation
import Testing
@testable import AetherEngine

/// AE#1109: a session that prefetched the rest of a title from a resume point, then seeked back
/// before that point, restarted its producer there and cut every resident segment again, to the end
/// of the source. On the reporter's 6.7 GB film one rewind pulled 4.8 GB a second time.
///
/// The producer now stops in front of a resident run it could only reproduce: every segment of it
/// written on the same axis by an earlier producer of the session, none of them an epoch's first.
/// Measured with `aetherctl play --start-position 200 --forward-buffer-segments 2700` and a seek to 0
/// on a 300 s, 48 MB MKV over HTTP: the origin served 55 MB after the seek before, 40 MB after
/// (32 MB of it the stretch that was never fetched, the rest the reader's window), and the picture
/// probe read the clock on the picture across the seam on all three timecode fixtures.
@Suite("AE#1109: a restarted producer stops at the resident run instead of cutting it again")
struct Issue1109ResidentRunParkTests {

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae1109-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let axis = SegmentLineage.Axis(videoShiftPts: 0, audioShiftPts: 0, audioDelaySeconds: 0)

    /// Adopts a staging file at `index`, the way the producer stores a segment it cut.
    private func adopt(_ cache: SegmentCache, _ index: Int, in dir: URL,
                       lineage: SegmentLineage?) throws {
        let staging = dir.appendingPathComponent("staging-\(index)-\(UUID().uuidString)")
        try Data(repeating: UInt8(index & 0xff), count: 64).write(to: staging)
        #expect(cache.adopt(index: index, stagingPath: staging, byteCount: 64, lineage: lineage))
    }

    // MARK: - Which runs a producer may keep

    @Test("a run of mid-epoch segments on the producer's axis is kept up to its first hole",
          .timeLimit(.minutes(3)))
    func keepsMidEpochRun() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = SegmentCache(retentionBudgetBytes: 1 << 30, baseDirectory: base)
        defer { cache.close() }
        // The resume epoch opened at 33 and cut 34...40; 41 was never fetched.
        try adopt(cache, 33, in: base, lineage: SegmentLineage(axis: axis, opensEpoch: true))
        for index in 34...40 {
            try adopt(cache, index, in: base, lineage: SegmentLineage(axis: axis, opensEpoch: false))
        }
        #expect(cache.keepableResidentRun(from: 34, axis: axis) == 40)
        // The epoch's first segment is cut again: its gate may have opened below the boundary.
        #expect(cache.keepableResidentRun(from: 33, axis: axis) == nil)
        #expect(cache.keepableResidentRun(from: 41, axis: axis) == nil, "nothing resident there")
    }

    @Test("a run with one segment written on another axis is not kept at all",
          .timeLimit(.minutes(3)))
    func otherAxisBreaksTheRun() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = SegmentCache(retentionBudgetBytes: 1 << 30, baseDirectory: base)
        defer { cache.close() }
        let shifted = SegmentLineage.Axis(videoShiftPts: 42, audioShiftPts: 0, audioDelaySeconds: 0)
        let delayed = SegmentLineage.Axis(videoShiftPts: 0, audioShiftPts: 0, audioDelaySeconds: 0.05)
        for index in 10...20 {
            try adopt(cache, index, in: base, lineage: SegmentLineage(axis: axis, opensEpoch: false))
        }
        try adopt(cache, 15, in: base, lineage: SegmentLineage(axis: shifted, opensEpoch: false))
        // The consumer is served whatever sits at an index, so the shifted segment would play as the
        // continuation of this producer's run. Stopping in front of 10 would serve it.
        #expect(cache.keepableResidentRun(from: 10, axis: axis) == nil)
        #expect(cache.keepableResidentRun(from: 16, axis: axis) == 20)
        #expect(cache.keepableResidentRun(from: 16, axis: delayed) == nil)
    }

    @Test("an epoch's first segment inside the run stops it from being kept",
          .timeLimit(.minutes(3)))
    func laterEpochOpeningBreaksTheRun() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = SegmentCache(retentionBudgetBytes: 1 << 30, baseDirectory: base)
        defer { cache.close() }
        for index in 10...20 {
            try adopt(cache, index, in: base, lineage: SegmentLineage(axis: axis, opensEpoch: index == 14))
        }
        #expect(cache.keepableResidentRun(from: 10, axis: axis) == nil)
        #expect(cache.keepableResidentRun(from: 15, axis: axis) == 20)
    }

    @Test("a segment of unknown lineage is never kept", .timeLimit(.minutes(3)))
    func unknownLineageIsNotKept() throws {
        let base = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = SegmentCache(retentionBudgetBytes: 1 << 30, baseDirectory: base)
        defer { cache.close() }
        for index in 0...9 {
            try adopt(cache, index, in: base, lineage: SegmentLineage(axis: axis, opensEpoch: false))
        }
        // A plain store (the I-frame and test paths) says nothing about how the bytes were written.
        #expect(cache.store(index: 5, data: Data(repeating: 5, count: 64)))
        #expect(cache.keepableResidentRun(from: 0, axis: axis) == nil)
        #expect(cache.keepableResidentRun(from: 6, axis: axis) == 9)
        try adopt(cache, 5, in: base, lineage: nil)
        #expect(cache.keepableResidentRun(from: 0, axis: axis) == nil)
    }

    // MARK: - When the pump stops in front of it

    @Test("a run deep enough to cushion the restart at its end holds the pump", .timeLimit(.minutes(3)))
    func deepRunHolds() {
        let depth = HLSSegmentProducer.residentRunMinimumDepth
        #expect(HLSSegmentProducer.residentRunHoldsPump(head: 34, frontier: 34 + depth - 1, lastIndex: 500))
        #expect(!HLSSegmentProducer.residentRunHoldsPump(head: 34, frontier: 34 + depth - 2, lastIndex: 500))
    }

    @Test("a run that reaches the last segment holds the pump at any depth", .timeLimit(.minutes(3)))
    func runToTheEndHolds() {
        #expect(HLSSegmentProducer.residentRunHoldsPump(head: 497, frontier: 497, lastIndex: 497))
        #expect(HLSSegmentProducer.residentRunHoldsPump(head: 495, frontier: 499, lastIndex: 497))
    }

    @Test("no run, no hold", .timeLimit(.minutes(3)))
    func noRunNoHold() {
        #expect(!HLSSegmentProducer.residentRunHoldsPump(head: 34, frontier: 33, lastIndex: 497))
    }
}
