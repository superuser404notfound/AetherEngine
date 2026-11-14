import Foundation
import Testing
@testable import AetherEngine

/// PR #512 follow-up: the software VOD read-ahead must stop at its forward window on material
/// whose presentation coverage cannot be described.
///
/// The forward-second limit used to be keyed on the coverage frontier alone, which reports nothing
/// once a single late presentation timestamp invalidates the H.264 successor model, and freezes at
/// a hole in the packet-duration model. Either one removed the seconds limit entirely and left the
/// disk budget as the only bound, which in a session is the difference between a window and the
/// whole file. The limit is measured on the reservoir instead: the newest stored video timestamp
/// against the one the consumer last took.
@Suite("Software VOD read-ahead park (#512)", .offCooperativePool)
struct SoftwarePacketReadAheadParkTests {

    private final class SourceCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// 25 pictures a second on a 1/1000 time base: one packet holds 0.04 s.
    private static let tickRate: Int32 = 1000
    private static let holdTicks: Int64 = 40

    private static func packet(pts: Int64) -> SoftwareStoredPacket {
        SoftwareStoredPacket(pts: pts, dts: pts, duration: Self.holdTicks, position: 0,
                             streamIndex: 0, flags: 0x1, timeBaseNumerator: 1,
                             timeBaseDenominator: Self.tickRate,
                             bytes: Data(repeating: 7, count: 100), sideData: [])
    }

    /// Runs a producer that never reaches EOF and never has a consumer, and answers how many
    /// packets it read from the source before it parked.
    private func packetsReadBeforePark(
        forwardSeconds: Double, byteBudget: Int, reorderDepth: Int?,
        lateTimestampAt: Int? = nil, holeAfter: Int? = nil, spikeAt: Int? = nil
    ) throws -> Int {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("readahead-park-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = SourceCounter()
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                              parentDirectory: root)
        let source = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: Self.tickRate), audio: nil,
            byteBudget: byteBudget, forwardSeconds: forwardSeconds, initialSourceClock: 0,
            fifo: fifo, videoReorderDepth: reorderDepth
        ) { _ in
            let index = counter.next()
            if let lateTimestampAt, index == lateTimestampAt { return Self.packet(pts: 0) }
            // AE#1053: one packet stamped 347 s ahead, then the original timeline again.
            if let spikeAt, index == spikeAt { return Self.packet(pts: Int64(index - 1) * Self.holdTicks + 347_000) }
            let skew: Int64 = (holeAfter.map { index > $0 } ?? false) ? Self.holdTicks : 0
            return Self.packet(pts: Int64(index - 1) * Self.holdTicks + skew)
        }
        source.start()
        defer { source.close() }

        // Park is the absence of further reads, so it is read as a count that stops moving.
        let deadline = Date().addingTimeInterval(10)
        var previous = -1
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            let now = counter.value
            if now == previous, now > 0 { return now }
            previous = now
        }
        return counter.value
    }

    /// 10 s of a 25 fps stream is 250 pictures; the byte budget is far above that, so a count near
    /// the budget's ~3700 packets means the seconds limit did not hold.
    private let forwardSeconds = 10.0
    private let byteBudget = 400_000
    private let packetsInWindow = 250
    private let packetsInBudget = 1_300

    @Test("A clean H.264 stream parks at the forward window")
    func h264CleanParksAtWindow() throws {
        let read = try packetsReadBeforePark(forwardSeconds: forwardSeconds,
                                             byteBudget: byteBudget, reorderDepth: 32)
        #expect(read < packetsInWindow + 100)
        #expect(read < packetsInBudget)
    }

    @Test("One late presentation timestamp does not lift the forward window")
    func h264LateTimestampStillParks() throws {
        let read = try packetsReadBeforePark(forwardSeconds: forwardSeconds,
                                             byteBudget: byteBudget, reorderDepth: 32,
                                             lateTimestampAt: 100)
        // Before the fix this ran to the byte budget: 1316 packets against the window's 283.
        #expect(read < packetsInWindow + 100)
        #expect(read < packetsInBudget)
    }

    @Test("A hole ahead of a stalled clock does not lift the forward window")
    func durationModelHoleStillParks() throws {
        let read = try packetsReadBeforePark(forwardSeconds: forwardSeconds,
                                             byteBudget: byteBudget, reorderDepth: nil,
                                             holeAfter: 100)
        // The coverage span containing the clock ends at the hole, four seconds in, so the frontier
        // rule can never reach ten and only the reservoir measurement stops the producer.
        #expect(read < packetsInWindow + 100)
        #expect(read < packetsInBudget)
    }

    @Test("A timestamp spike is a seam, not a full reservoir (AE#1053)")
    func timestampSpikeDoesNotParkEarly() throws {
        let read = try packetsReadBeforePark(forwardSeconds: forwardSeconds,
                                             byteBudget: byteBudget, reorderDepth: nil,
                                             spikeAt: 50)
        // Before the fix the spike read as a 347 s reservoir and parked the producer at packet 50,
        // with four of its ten seconds unread.
        #expect(read > packetsInWindow - 20)
        #expect(read < packetsInWindow + 100)
    }

    @Test("The disk budget still bounds a window wider than the source")
    func byteBudgetStillBounds() throws {
        let read = try packetsReadBeforePark(forwardSeconds: 3600, byteBudget: 40_000,
                                             reorderDepth: nil)
        #expect(read > 0)
        #expect(read < 400)
    }
}
