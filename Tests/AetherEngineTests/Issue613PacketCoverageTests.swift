import Foundation
import AetherLibavcodec
import Testing
@testable import AetherEngine

/// #613, found while answering #592: the software VOD read-ahead's packet coverage broke in two
/// ways that both leave the frontier describing less than the store holds.
///
/// HEVC kept the strict `pts + duration` model, and a Matroska file muxed with 41 ms durations
/// against 41/42 ms deltas opens a one-tick hole at every 42 ms step: 0.70 islands a frame,
/// `bufferedPosition` stuck at the end of the current island. And a coverage that reached its range
/// cap stopped describing new packets (plain) or invalidated itself (successor model) instead of
/// forgetting the history behind the playhead.
@Suite("Software VOD packet coverage (#613)", .offCooperativePool)
struct Issue613PacketCoverageTests {

    private static let tickRate: Int32 = 1000

    /// 23.976 fps on a 1/1000 time base, the fixture's own timestamps: PTS rounded to the
    /// millisecond, every duration 41, so each 42 ms delta leaves a one-tick hole.
    private static func fragmentedPTS(_ index: Int) -> Int64 {
        Int64((Double(index) * 1000 * 1001 / 24000).rounded())
    }

    private static func packet(pts: Int64, duration: Int64 = 41) -> SoftwareStoredPacket {
        SoftwareStoredPacket(pts: pts, dts: pts, duration: duration, position: 0,
                             streamIndex: 0, flags: 0x1, timeBaseNumerator: 1,
                             timeBaseDenominator: Self.tickRate,
                             bytes: Data(repeating: 7, count: 100), sideData: [])
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    private func makeReadAhead(
        root: URL, reorderDepth: Int?, forwardSeconds: Double, rangeCap: Int = 4096,
        pts: @escaping @Sendable (Int) -> Int64
    ) throws -> SoftwarePacketReadAhead {
        let counter = Counter()
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                              parentDirectory: root)
        return SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: Self.tickRate), audio: nil,
            byteBudget: 50_000_000, forwardSeconds: forwardSeconds, initialSourceClock: 0,
            fifo: fifo, videoReorderDepth: reorderDepth, coverageRangeCap: rangeCap
        ) { _ in Self.packet(pts: pts(counter.next() - 1)) }
    }

    private func withRoot<T>(_ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue613-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    /// Waits for the producer to park. The park itself, not a packet count that held still: a
    /// producer that is merely slow on a loaded machine looks parked to that. Sync, so the bound is
    /// a generous hang catcher rather than a verdict.
    private func waitForPark(_ source: SoftwarePacketReadAhead) {
        let deadline = Date().addingTimeInterval(120)
        while !source.producerParkedForTesting, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    // MARK: - 1. HEVC gets the successor model

    /// The bound that lets HEVC in: FFmpeg rejects more than 15 reorder pictures, inside the
    /// 32-timestamp queue. Codecs without an established bound keep the strict model.
    @Test("H.264, HEVC and VC-1 take the successor model, other codecs keep the duration model")
    func reorderDepthByCodec() {
        #expect(SoftwarePlaybackHost.presentationReorderDepth(
            codecID: AV_CODEC_ID_H264.rawValue) == 32)
        #expect(SoftwarePlaybackHost.presentationReorderDepth(
            codecID: AV_CODEC_ID_HEVC.rawValue) == 32)
        #expect(SoftwarePlaybackHost.presentationReorderDepth(
            codecID: AV_CODEC_ID_VC1.rawValue) == 32)
        for other in [AV_CODEC_ID_AV1, AV_CODEC_ID_VP9, AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_WMV3] {
            #expect(SoftwarePlaybackHost.presentationReorderDepth(codecID: other.rawValue) == nil)
        }
    }

    /// The reported shape. On the duration model the frontier ends at the first rounding hole, 41 ms
    /// in; on the successor model it reaches what the producer stored before it parked.
    @Test("Rounded durations do not fragment the successor model")
    func roundedDurationsStayOneIsland() throws {
        try withRoot { root in
            let strict = try makeReadAhead(root: root, reorderDepth: nil, forwardSeconds: 10,
                                           pts: Self.fragmentedPTS)
            strict.start()
            waitForPark(strict)
            let strictFrontier = strict.snapshot.frontier
            strict.close()

            let successor = try makeReadAhead(root: root, reorderDepth: 32, forwardSeconds: 10,
                                              pts: Self.fragmentedPTS)
            successor.start()
            waitForPark(successor)
            let successorFrontier = successor.snapshot.frontier
            successor.close()

            #expect((strictFrontier ?? 0) < 0.05, "the premise: the duration model splits at 41 ms")
            // Ten seconds stored, less the 32 timestamps the reorder queue holds back (1.33 s).
            #expect((successorFrontier ?? 0) > 8, "the frontier must reach the store, not the first hole")
        }
    }

    private func withAsyncRoot<T>(_ body: (URL) async throws -> T) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc1-coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(root)
    }

    /// Synthetic VC-1 timing only: one reference followed by up to seven B pictures,
    /// 30 fps rounded to milliseconds, and presentation-ordered audio with explicit duration.
    /// Missing audio duration is covered separately by upstream #775, not this VC-1 regression.
    /// No private media, packet payloads or source identifiers are needed to reproduce it.
    private func vc1ReadAhead(root: URL, count: Int, strict: Bool = false,
                              discontinuity: Bool = false) async throws -> SoftwarePacketReadAhead {
        var order = [0]
        for first in stride(from: 1, to: count, by: 8) {
            let reference = min(first + 7, count - 1)
            order.append(reference)
            order.append(contentsOf: first..<reference)
        }
        var packets: [SoftwareStoredPacket] = []
        func timestamp(_ index: Int) -> Int64 {
            Int64(index) * 100 / 3 + (discontinuity && index >= 150 ? 2000 : 0)
        }
        for (decodeIndex, picture) in order.enumerated() {
            packets.append(SoftwareStoredPacket(pts: timestamp(picture), dts: timestamp(decodeIndex),
                duration: 33, position: 0, streamIndex: 0, flags: picture % 240 == 0 ? 1 : 0,
                timeBaseNumerator: 1, timeBaseDenominator: 1000,
                bytes: Data(repeating: 7, count: 100), sideData: []))
            if decodeIndex % 5 == 0 {
                packets.append(SoftwareStoredPacket(pts: timestamp(decodeIndex), dts: timestamp(decodeIndex),
                    duration: Int64(decodeIndex + 5) * 100 / 3 - Int64(decodeIndex) * 100 / 3,
                    position: 0, streamIndex: 1, flags: 1,
                    timeBaseNumerator: 1, timeBaseDenominator: 1000,
                    bytes: Data(repeating: 3, count: 16), sideData: []))
            }
        }
        let all = packets
        let counter = Counter()
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                              parentDirectory: root)
        let source = SoftwarePacketReadAhead(video: .init(index: 0, numerator: 1, denominator: 1000),
            audio: .init(index: 1, numerator: 1, denominator: 1000), byteBudget: 50_000_000,
            forwardSeconds: 10_000, initialSourceClock: 0, fifo: fifo,
            videoReorderDepth: strict ? nil : SoftwarePlaybackHost.presentationReorderDepth(
                codecID: AV_CODEC_ID_VC1.rawValue)) { _ in
                    let index = counter.next() - 1
                    return index < all.count ? all[index] : nil
                }
        source.start()
        do { try await waitFor { source.snapshot.sourceEnded } }
        catch { source.close(); throw error }
        return source
    }

    @Test("VC-1 rounded durations and seven-picture reorder retain one long A/V range", .timeLimit(.minutes(3)))
    func vc1RoundedDurationsAndCacheSeek() async throws {
        try await withAsyncRoot { root in
            let old = try await vc1ReadAhead(root: root, count: 15_000, strict: true)
            #expect(old.residentRanges.count == 4096, "old codec selection saturates coverage")
            #expect((old.residentRanges.last?.upperBound ?? 0) < 420)
            old.close()

            let source = try await vc1ReadAhead(root: root, count: 15_000)
            defer { source.close() }
            #expect(source.residentRanges.count == 1)
            #expect((source.residentRanges.last?.upperBound ?? 0) > 499)
            // A former one-millisecond hole, then a retained position beyond the old cap.
            for target in [0.0995, 450.0] {
                let token = source.beginSeek(to: target)
                #expect(try source.prepareSeek(token, to: target))
            }
            source.close()
            #expect(source.residentRanges.isEmpty, "discard must clear the published cache")
        }
    }

    @Test("VC-1 successor coverage preserves a genuine two-second A/V discontinuity", .timeLimit(.minutes(3)))
    func vc1DiscontinuityRemainsUncached() async throws {
        try await withAsyncRoot { root in
            let source = try await vc1ReadAhead(root: root, count: 600, discontinuity: true)
            defer { source.close() }
            #expect(source.residentRanges.count == 2)
            #expect(!source.residentRanges.contains { $0.contains(6) })
            let token = source.beginSeek(to: 6)
            #expect(try source.prepareSeek(token, to: 6) == false)
        }
    }

    @Test("VC-1 admission retains the existing fail-closed late-timestamp guard")
    func vc1LateTimestampInvalidates() throws {
        let depth = try #require(SoftwarePlaybackHost.presentationReorderDepth(codecID: AV_CODEC_ID_VC1.rawValue))
        var model = SoftwareVideoPacketCoverage(timeBaseNumerator: 1, timeBaseDenominator: 1000,
                                                reorderDepth: depth)
        for index: Int64 in 0..<100 { model.insert(pts: index * 100 / 3) }
        #expect(!model.rangesSeconds.isEmpty)
        let admitted = model.insert(pts: 1)
        #expect(!admitted)
        #expect(model.isInvalidated)
        #expect(model.rangesSeconds.isEmpty)
    }

    // MARK: - 2. A full coverage forgets history instead of freezing

    /// Consumes `count` packets, moving the playhead onto each, and answers the frontier at the end.
    /// Every read waits for 40 stored packets first, the way a real consumer trails the producer:
    /// the successor model describes a picture only once 32 later timestamps have arrived, so a
    /// consumer that drains the store as fast as it fills sees no coverage at all.
    private func frontierAfterConsuming(_ count: Int, source: SoftwarePacketReadAhead) throws -> Double? {
        source.start()
        for _ in 0..<count {
            let deadline = Date().addingTimeInterval(120)
            while source.snapshot.packetCount < 40, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            guard let packet = try source.read() else { break }
            source.updatePlayhead(Double(packet.pts) / Double(Self.tickRate))
        }
        return source.snapshot.frontier
    }

    /// Duration model at a cap of 64 ranges: 400 fragmented packets are about 280 islands. Before
    /// the fix the coverage stopped at the sixty-fourth and the playhead left it behind. The cap has
    /// to hold what lies AHEAD of the playhead, about 34 islands in a two-second window here, as
    /// 4096 holds a forty-second one in a session.
    @Test("A full duration-model coverage keeps describing new packets")
    func fullDurationCoverageKeepsUp() throws {
        try withRoot { root in
            let source = try makeReadAhead(root: root, reorderDepth: nil, forwardSeconds: 2,
                                           rangeCap: 64, pts: Self.fragmentedPTS)
            defer { source.close() }
            #expect(try frontierAfterConsuming(400, source: source) != nil)
        }
    }

    /// Successor model at a cap of 16: a two-second jump every fifth picture is a real
    /// discontinuity and opens an island each time. Before the fix the seventeenth one invalidated
    /// the whole model until the next seek. 403 packets leave the playhead on the third picture of
    /// a group: the fifth one's hold ends at the jump and is deliberately uncovered.
    @Test("A full successor-model coverage keeps describing new packets")
    func fullSuccessorCoverageKeepsUp() throws {
        try withRoot { root in
            let source = try makeReadAhead(root: root, reorderDepth: 32, forwardSeconds: 30,
                                           rangeCap: 16) { index in
                Int64(index) * 40 + Int64(index / 5) * 2000
            }
            defer { source.close() }
            #expect(try frontierAfterConsuming(403, source: source) != nil)
        }
    }
}
