import Foundation
import Testing
@testable import AetherEngine

/// AE#605: a software VOD session decodes scrub stills out of the packet cache its seeks already
/// land in, instead of opening a second connection a single-slot origin refuses.
///
/// Two properties carry the feature. The run a still needs has to be read from HISTORY without
/// moving the consumer, or every preview would rewind playback. And the run is offered exactly where
/// a commit would be a cache hit: a target past the retained frontier has a real frame the store
/// does not hold yet, so the frame before it is the wrong answer rather than a close one.
@Suite("Software VOD scrub stills from the packet cache (AE#605)", .offCooperativePool, .timeLimit(.minutes(3)))
struct Issue605SoftwareVODStillTests {

    // MARK: - FIFO history walk

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue605-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func record(_ value: UInt8) -> Data { Data(repeating: value, count: 20) }

    @Test("A history walk crosses chunks and leaves the consumer where it stood")
    func historyWalkDoesNotMoveConsumer() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 64-byte chunks hold two 28-byte records, so ten records span five chunks.
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64, retainConsumed: true,
                                              parentDirectory: root)
        var cursors: [SoftwarePacketDiskFIFO.Cursor] = []
        for value in UInt8(0)..<10 { cursors.append(try fifo.append(Self.record(value))) }

        var seen: [UInt8] = []
        try fifo.readHistory(from: cursors[3]) { data in
            seen.append(data.first ?? 255)
            return true
        }
        #expect(seen == Array(3..<10))
        #expect(try fifo.pop() == Self.record(0))
        #expect(fifo.snapshot.count == 9)
    }

    @Test("A history walk stops when the visitor says so")
    func historyWalkStopsEarly() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64, retainConsumed: true,
                                              parentDirectory: root)
        var cursors: [SoftwarePacketDiskFIFO.Cursor] = []
        for value in UInt8(0)..<10 { cursors.append(try fifo.append(Self.record(value))) }

        var seen: [UInt8] = []
        try fifo.readHistory(from: cursors[1]) { data in
            seen.append(data.first ?? 255)
            return seen.count < 3
        }
        #expect(seen == [1, 2, 3])
    }

    @Test("A cursor from before a reset is refused, and the store stays usable")
    func historyWalkRefusesStaleCursor() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64, retainConsumed: true,
                                              parentDirectory: root)
        let stale = try fifo.append(Self.record(1))
        try fifo.reset()
        try fifo.append(Self.record(2))

        #expect(throws: SoftwarePacketDiskFIFO.Failure.invalidCursor) {
            try fifo.readHistory(from: stale) { _ in true }
        }
        #expect(!fifo.snapshot.hasFailure)
        #expect(try fifo.pop() == Self.record(2))
    }

    @Test("A cursor whose chunk was evicted is refused")
    func historyWalkRefusesEvictedCursor() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64, retainConsumed: true,
                                              parentDirectory: root)
        var cursors: [SoftwarePacketDiskFIFO.Cursor] = []
        for value in UInt8(0)..<10 { cursors.append(try fifo.append(Self.record(value))) }
        for _ in 0..<6 { _ = try fifo.pop() }
        try fifo.trimConsumed(toByteBudget: 0)

        #expect(throws: SoftwarePacketDiskFIFO.Failure.invalidCursor) {
            try fifo.readHistory(from: cursors[0]) { _ in true }
        }
        var seen: [UInt8] = []
        try fifo.readHistory(from: cursors[6]) { seen.append($0.first ?? 255); return true }
        #expect(seen == Array(6..<10))
    }

    // MARK: - Still run planning

    /// 25 pictures a second on a 1/1000 time base, a keyframe every second, and a non-video packet
    /// after every picture so the run has something to filter out.
    private static let tickRate: Int32 = 1000
    private static let holdTicks: Int64 = 40
    private static let pictureRate = 25

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private static func sourcePacket(index: Int, keyframeEvery: Int) -> SoftwareStoredPacket {
        let picture = (index - 1) / 2
        let pts = Int64(picture) * holdTicks
        let isVideo = (index - 1) % 2 == 0
        let isKey = isVideo && picture % keyframeEvery == 0
        return SoftwareStoredPacket(pts: pts, dts: pts, duration: holdTicks, position: 0,
                                    streamIndex: isVideo ? 0 : 5, flags: isKey ? 0x1 : 0,
                                    timeBaseNumerator: 1, timeBaseDenominator: tickRate,
                                    bytes: Data(repeating: 7, count: 100), sideData: [])
    }

    /// A producer that has filled its forward window and parked, with no consumer yet.
    private static func parkedCache(root: URL, forwardSeconds: Double,
                                    keyframeEvery: Int = pictureRate) throws -> SoftwarePacketReadAhead {
        let counter = Counter()
        let fifo = try SoftwarePacketDiskFIFO(chunkTargetBytes: 64 * 1024, retainConsumed: true,
                                              parentDirectory: root)
        let cache = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: tickRate), audio: nil,
            byteBudget: 50_000_000, forwardSeconds: forwardSeconds, initialSourceClock: 0,
            fifo: fifo
        ) { _ in Self.sourcePacket(index: counter.next(), keyframeEvery: keyframeEvery) }
        cache.start()
        // The park itself, not a counter that held still for 150 ms: a producer that is merely slow
        // on a loaded machine looked parked to that, and the still past its frontier came back nil.
        while !cache.producerParkedForTesting {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return cache
    }

    private static func seconds(_ packet: SoftwareStoredPacket) -> Double {
        Double(packet.pts) / Double(tickRate)
    }

    @Test("A run opens on the keyframe before the target and reaches past it, video only")
    func runOpensOnKeyframeAndReachesTarget() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try Self.parkedCache(root: root, forwardSeconds: 10)
        defer { cache.close() }

        let run = try #require(cache.stillRun(atSeconds: 3.5, maxPackets: 900,
                                              maxSpanSeconds: 12, reorderTail: 4))
        #expect(run.first.map(Self.seconds) == 3.0)
        #expect(run.first.map { $0.flags & 1 != 0 } == true)
        #expect(run.allSatisfy { $0.streamIndex == 0 })
        // 3.00 through 3.52 is fourteen pictures (the first at or past 3.5), plus the tail of four.
        #expect(run.count == 18)
        #expect(run.contains { Self.seconds($0) >= 3.5 })
    }

    @Test("A still leaves the consumer at the packet it would have read next")
    func runDoesNotMoveConsumer() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try Self.parkedCache(root: root, forwardSeconds: 10)
        defer { cache.close() }

        #expect(cache.stillRun(atSeconds: 6.2, maxPackets: 900, maxSpanSeconds: 12,
                               reorderTail: 4) != nil)
        let next = try #require(try cache.read())
        #expect(next.pts == 0)
        #expect(next.streamIndex == 0)
    }

    @Test("A target past the retained frontier gets no still, not the frame before it")
    func runRefusesPastFrontier() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try Self.parkedCache(root: root, forwardSeconds: 10)
        defer { cache.close() }

        #expect(cache.stillRun(atSeconds: 60, maxPackets: 900, maxSpanSeconds: 12,
                               reorderTail: 4) == nil)
    }

    @Test("A keyframe further back than the span bound gets no still")
    func runRefusesWideSpan() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // One keyframe every eight seconds.
        let cache = try Self.parkedCache(root: root, forwardSeconds: 10, keyframeEvery: 200)
        defer { cache.close() }

        #expect(cache.stillRun(atSeconds: 5, maxPackets: 900, maxSpanSeconds: 2,
                               reorderTail: 4) == nil)
        #expect(cache.stillRun(atSeconds: 5, maxPackets: 900, maxSpanSeconds: 12,
                               reorderTail: 4) != nil)
    }

    @Test("A run longer than the packet bound gets no still")
    func runRefusesPacketOverflow() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try Self.parkedCache(root: root, forwardSeconds: 10)
        defer { cache.close() }

        #expect(cache.stillRun(atSeconds: 0.9, maxPackets: 10, maxSpanSeconds: 12,
                               reorderTail: 4) == nil)
    }
}
