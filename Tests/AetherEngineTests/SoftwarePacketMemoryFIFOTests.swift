import Foundation
import Testing
@testable import AetherEngine

/// The purgeable-memory packet store (tvOS's software VOD packet store) must behave like the
/// disk store for everything the read-ahead relies on: FIFO order across chunks, cursors that
/// restore backwards and forwards, the still walk, and history that is bounded and evictable.
@Suite("Software packet memory FIFO", .offCooperativePool)
struct SoftwarePacketMemoryFIFOTests {

    /// Records of 1000 bytes filled with their index, so a read can be checked by content.
    private func record(_ i: Int) -> Data { Data(repeating: UInt8(i & 0xff), count: 1000) }

    /// Page-sized chunks (16 KiB on arm64) hold 16 records each.
    private func filled(_ count: Int, historyCap: Int = .max) throws
        -> (SoftwarePacketMemoryFIFO, [SoftwarePacketDiskFIFO.Cursor]) {
        let fifo = SoftwarePacketMemoryFIFO(chunkTargetBytes: 1, historyCapBytes: historyCap)
        var cursors: [SoftwarePacketDiskFIFO.Cursor] = []
        for i in 0..<count { cursors.append(try fifo.append(record(i))) }
        return (fifo, cursors)
    }

    @Test("pops every record in order across chunk boundaries")
    func fifoOrder() throws {
        let (fifo, _) = try filled(100)
        #expect(fifo.snapshot.chunkCount > 1)
        for i in 0..<100 { #expect(try fifo.pop() == record(i)) }
        #expect(try fifo.pop() == nil)
        #expect(fifo.snapshot.count == 0)
    }

    @Test("consumed chunks leave the non-volatile byte count, unread ones stay in it")
    func consumedHistoryIsNotResident() throws {
        let (fifo, _) = try filled(100)
        let before = fifo.snapshot.diskByteCount
        for _ in 0..<80 { _ = try fifo.pop() }
        let after = fifo.snapshot.diskByteCount
        #expect(after < before)
        #expect(after >= 20 * 1008)
    }

    @Test("a cursor behind the reader restores and re-reads the same records")
    func restoreBackward() throws {
        let (fifo, cursors) = try filled(100)
        for _ in 0..<90 { _ = try fifo.pop() }
        try fifo.restore(to: cursors[10])
        #expect(fifo.snapshot.count == 90)
        for i in 10..<100 { #expect(try fifo.pop() == record(i)) }
    }

    @Test("a cursor ahead of the reader skips forward")
    func restoreForward() throws {
        let (fifo, cursors) = try filled(100)
        try fifo.restore(to: cursors[70])
        #expect(fifo.snapshot.count == 30)
        #expect(try fifo.pop() == record(70))
    }

    @Test("the still walk visits history without moving the reader")
    func readHistory() throws {
        let (fifo, cursors) = try filled(100)
        for _ in 0..<60 { _ = try fifo.pop() }
        var seen: [Data] = []
        try fifo.readHistory(from: cursors[20]) { seen.append($0); return seen.count < 30 }
        #expect(seen == (20..<50).map(record))
        #expect(try fifo.pop() == record(60))
    }

    @Test("history over the cap is dropped and its cursors become cache misses")
    func historyCap() throws {
        let (fifo, cursors) = try filled(200, historyCap: 40_000)
        for _ in 0..<190 { _ = try fifo.pop() }
        try fifo.trimConsumed(toByteBudget: 0)
        let oldest = try #require(fifo.snapshot.oldestRetainedChunkID)
        #expect(oldest > cursors[0].chunkID)
        #expect(throws: SoftwarePacketDiskFIFO.Failure.invalidCursor) { try fifo.restore(to: cursors[0]) }
        // Recent history is still there.
        try fifo.restore(to: cursors[185])
        #expect(try fifo.pop() == record(185))
    }

    @Test("history the kernel emptied is a cache miss, and the store stays usable")
    func purgedHistoryRestore() throws {
        let (fifo, cursors) = try filled(100)
        for _ in 0..<90 { _ = try fifo.pop() }
        fifo.purgeHistoryForTesting()
        #expect(throws: SoftwarePacketDiskFIFO.Failure.invalidCursor) { try fifo.restore(to: cursors[10]) }
        #expect(fifo.purgedChunks > 0)
        // The reader did not move and unread data was never volatile.
        for i in 90..<100 { #expect(try fifo.pop() == record(i)) }
        try fifo.append(record(100))
        #expect(try fifo.pop() == record(100))
    }

    @Test("emptied history is evicted on a check, before any restore walks into it (#759)")
    func evictPurgedHistory() throws {
        let (fifo, cursors) = try filled(100)
        for _ in 0..<90 { _ = try fifo.pop() }
        #expect(!fifo.evictPurgedHistory())
        let before = try #require(fifo.snapshot.oldestRetainedChunkID)
        fifo.purgeHistoryForTesting()
        #expect(fifo.evictPurgedHistory())
        #expect(try #require(fifo.snapshot.oldestRetainedChunkID) > before)
        #expect(!fifo.evictPurgedHistory())
        #expect(throws: SoftwarePacketDiskFIFO.Failure.invalidCursor) { try fifo.restore(to: cursors[10]) }
        for i in 90..<100 { #expect(try fifo.pop() == record(i)) }
    }

    @Test("a still walk into emptied history is refused and releases the store")
    func purgedHistoryWalk() async throws {
        let (fifo, cursors) = try filled(100)
        for _ in 0..<90 { _ = try fifo.pop() }
        fifo.purgeHistoryForTesting()
        #expect(throws: SoftwarePacketDiskFIFO.Failure.invalidCursor) {
            try fifo.readHistory(from: cursors[10]) { _ in true }
        }
        // A lock left held (or released twice) by the refusal would hang or trap here, so the next
        // operation runs on its own thread.
        let popped = await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            Thread.detachNewThread { done.resume(returning: try? fifo.pop()) }
        }
        #expect(popped == record(90))
    }

    @Test("reset invalidates old cursors and starts empty")
    func reset() throws {
        let (fifo, cursors) = try filled(50)
        try fifo.reset()
        #expect(fifo.snapshot.count == 0)
        #expect(throws: SoftwarePacketDiskFIFO.Failure.invalidCursor) { try fifo.restore(to: cursors[0]) }
        try fifo.append(record(7))
        #expect(try fifo.pop() == record(7))
    }

    @Test("the read-ahead plays from the memory store and a backward seek into history hits")
    func readAheadSeekBackHits() throws {
        // 25 fps video, every picture a keyframe, 4 s, then EOF. No audio.
        let packets = (0..<100).map { i in
            SoftwareStoredPacket(
                pts: Int64(i * 40), dts: Int64(i * 40), duration: 40, position: 0, streamIndex: 0,
                flags: 0x1, timeBaseNumerator: 1, timeBaseDenominator: 1000,
                bytes: Data(repeating: UInt8(i), count: 2000), sideData: [])
        }
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        }
        let counter = Counter()
        let source = SoftwarePacketReadAhead(
            video: .init(index: 0, numerator: 1, denominator: 1000), audio: nil,
            byteBudget: 64 << 20, forwardSeconds: 100, initialSourceClock: 0,
            fifo: SoftwarePacketMemoryFIFO(chunkTargetBytes: 16 * 1024, historyCapBytes: 64 << 20)
        ) { _ in
            let index = counter.next() - 1
            return index < packets.count ? packets[index] : nil
        }
        defer { source.close() }
        source.start()
        // Play 3 s: those chunks become volatile history.
        for i in 0..<75 { #expect(try source.read()?.pts == Int64(i * 40)) }
        let token = source.beginSeek(to: 1.0)
        #expect(try source.prepareSeek(token, to: 1.0))
        source.endSeek(token, sourceClock: 1.0)
        let first = try #require(try source.read())
        #expect(first.pts <= 1000)
        #expect(first.bytes == packets[Int(first.pts / 40)].bytes)
    }
}
