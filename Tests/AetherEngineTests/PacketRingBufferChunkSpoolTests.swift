import Darwin
import Foundation
import Testing
@testable import AetherEngine

/// Audit PERF-101 / SEG-106 / VPERF-101 / SEG-105: the software live DVR ring spools into a few
/// append-only chunk files behind a compact index, bounds its disk use by bytes as well as by time,
/// makes room when a write fails, and marks its directory live for the segment cache's sweep.
@Suite("DVR ring chunk spool")
struct PacketRingBufferChunkSpoolTests {

    private func makeScratch(_ dirs: ScratchDirs) -> URL { dirs.make(prefix: "prbspool") }

    private func packetFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != "session.lock" }
    }

    private func bytesOnDisk(in dir: URL) -> Int {
        packetFiles(in: dir).reduce(0) { sum, url in
            var info = stat()
            return lstat(url.path, &info) == 0 ? sum + Int(info.st_size) : sum
        }
    }

    @Test("Packets spool into a few chunk files, not one file per packet")
    func spoolsIntoChunkFiles() throws {
        let dirs = ScratchDirs()
        let scratch = makeScratch(dirs)
        let ring = try PacketRingBuffer(windowSeconds: 3600, scratch: scratch)
        defer { ring.close() }
        let payload = Data(repeating: 0x5A, count: 1024)
        for i in 0..<2000 {
            try ring.append(pts: Double(i) * 0.04, isKeyframe: i % 50 == 0, isVideo: true, bytes: payload)
        }
        #expect(ring.seqBounds.end == 2000)
        #expect(packetFiles(in: scratch).count <= 2,
                "2 MB of packets fit one 4 MB chunk; a file per packet is the PERF-101 defect")
        let last = try #require(ring.packet(atSeq: 1999))
        #expect(last.bytes == payload)
    }

    @Test("A ring directory with a held marker survives the segment cache's stale sweep")
    func heldRingDirectorySurvivesSweep() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("prbsweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let scratch = base.appendingPathComponent("dvr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let ring = try PacketRingBuffer(windowSeconds: 5400, scratch: scratch)
        defer { ring.close() }
        try ring.append(pts: 0, isKeyframe: true, isVideo: true, bytes: Data([1, 2, 3]))

        // Ninety minutes into a DVR session: the directory is as old as the session.
        let past = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.creationDate: past], ofItemAtPath: scratch.path)
        let created = try scratch.resourceValues(forKeys: [.creationDateKey]).creationDate
        #expect(created.map { $0 < Date().addingTimeInterval(-3600) } == true)

        let cache = SegmentCache(baseDirectory: base)
        defer { cache.close() }

        #expect(FileManager.default.fileExists(atPath: scratch.path),
                "a live ring's directory must not be swept by age alone")
        #expect(ring.packet(atSeq: 0)?.bytes == Data([1, 2, 3]))
    }

    // MARK: - Index footprint

    @Test("The index is a flat record per packet, not a heap object per packet")
    func indexIsCompact() throws {
        let dirs = ScratchDirs()
        #expect(MemoryLayout<PacketRingBuffer.Entry>.stride == 24)
        let ring = try PacketRingBuffer(windowSeconds: .infinity, scratch: makeScratch(dirs))
        defer { ring.close() }
        let payload = Data(repeating: 1, count: 64)
        let count = 100_000
        for i in 0..<count {
            try ring.append(pts: Double(i) * 0.0125, isKeyframe: i % 100 == 0, isVideo: i % 2 == 0, bytes: payload)
        }
        #expect(ring.seqBounds.end == count)
        // The file-per-packet ring kept 554-586 B per entry (a URL each): 55 MB for these 100k. The
        // footprint is array CAPACITY, which moves with growth and allocator rounding (4.2 MB measured
        // alone, over 5 MB once in a full parallel run), so the bound is a multiple of the flat minimum
        // that still sits far under the defect.
        let flatMinimum = count * MemoryLayout<PacketRingBuffer.Entry>.stride
        #expect(ring.indexFootprintBytes < flatMinimum * 6,
                "footprint \(ring.indexFootprintBytes) against a flat minimum of \(flatMinimum)")
    }

    // MARK: - Byte budget

    @Test("A byte budget bounds the disk use, even with an infinite window, and the span opens on a keyframe")
    func byteBudgetBoundsDiskAndKeepsKeyframeAlignment() throws {
        let dirs = ScratchDirs()
        let scratch = makeScratch(dirs)
        let budget = 8 << 20
        let ring = try PacketRingBuffer(windowSeconds: .infinity, scratch: scratch, byteBudget: budget)
        defer { ring.close() }
        let size = 256 << 10
        func body(_ i: Int) -> Data { Data(repeating: UInt8(truncatingIfNeeded: i), count: size) }
        var retainedBound = 0
        for i in 0..<200 {
            try ring.append(pts: Double(i) * 0.5, isKeyframe: i % 8 == 0, isVideo: true, bytes: body(i))
            retainedBound = max(retainedBound, bytesOnDisk(in: scratch))
        }
        // 512 KB chunks: the budget plus the one chunk the writer is filling.
        #expect(retainedBound <= budget + (512 << 10), "on-disk bytes stayed within budget plus one chunk")
        #expect(ring.diskBytes <= budget + (512 << 10))
        let bounds = ring.seqBounds
        #expect(bounds.end == 200)
        #expect(bounds.first > 0, "50 MB of packets cannot fit an 8 MB budget")
        let first = try #require(ring.packet(atSeq: bounds.first))
        #expect(first.isKeyframe && first.isVideo)
        #expect(first.bytes == body(bounds.first))
        #expect(ring.packet(atSeq: bounds.end - 1)?.bytes == body(199))
        #expect(ring.packet(atSeq: bounds.first - 1) == nil)
    }

    @Test("The budget holds when the window is finite too, and the stricter bound wins")
    func strictestBoundWins() throws {
        let dirs = ScratchDirs()
        let ring = try PacketRingBuffer(windowSeconds: 20, scratch: makeScratch(dirs), byteBudget: 64 << 20)
        defer { ring.close() }
        let payload = Data(repeating: 3, count: 4 << 10)
        for i in 0..<400 {
            try ring.append(pts: Double(i), isKeyframe: i % 5 == 0, isVideo: true, bytes: payload)
        }
        let oldest = try #require(ring.oldestPts)
        #expect(oldest <= 399 - 20 && oldest > 399 - 20 - 5, "time still bounds it when bytes do not")
    }

    @Test("A budget smaller than one chunk never evicts the only chunk")
    func tinyBudgetKeepsTheTail() throws {
        let dirs = ScratchDirs()
        let ring = try PacketRingBuffer(windowSeconds: .infinity, scratch: makeScratch(dirs), byteBudget: 1)
        defer { ring.close() }
        for i in 0..<50 {
            try ring.append(pts: Double(i), isKeyframe: i % 5 == 0, isVideo: true, bytes: Data(repeating: 9, count: 10_000))
        }
        let bounds = ring.seqBounds
        #expect(bounds.end == 50)
        #expect(bounds.first > 0)
        #expect(ring.diskBytes <= (64 << 10) + 10_000, "the chunk being written is what stays")
        let newest = try #require(ring.packet(atSeq: 49))
        #expect(newest.bytes.count == 10_000)
        #expect(ring.packet(atSeq: bounds.first) != nil)
    }

    @Test("A GOP larger than the whole budget still cannot grow the directory without bound")
    func hugeGopIsBoundedToo() throws {
        let dirs = ScratchDirs()
        let scratch = makeScratch(dirs)
        let budget = 1 << 20
        let ring = try PacketRingBuffer(windowSeconds: .infinity, scratch: scratch, byteBudget: budget)
        defer { ring.close() }
        // One keyframe, then nothing but delta frames: no pivot exists.
        try ring.append(pts: 0, isKeyframe: true, isVideo: true, bytes: Data(repeating: 0, count: 1000))
        for i in 1..<2000 {
            try ring.append(pts: Double(i), isKeyframe: false, isVideo: true, bytes: Data(repeating: 1, count: 8 << 10))
        }
        #expect(bytesOnDisk(in: scratch) <= 3 * budget)
        #expect(ring.seqBounds.end == 2000)
    }

    // MARK: - Writes that fail

    private final class FlakyDisk: @unchecked Sendable {
        private let lock = NSLock()
        private var failures = 0
        private var failureCode = ENOSPC
        private var capacity: Int?
        var ring: PacketRingBuffer?
        private(set) var rejected = 0

        func failNext(_ n: Int, code: Int32 = ENOSPC) {
            lock.lock(); failures = n; failureCode = code; lock.unlock()
        }
        func setCapacity(_ bytes: Int?) { lock.lock(); capacity = bytes; lock.unlock() }

        var writer: PacketRingBuffer.WriteAll {
            { [self] fd, bytes, offset in
                lock.lock()
                var fail = false
                var code = ENOSPC
                if failures > 0 { failures -= 1; fail = true; code = failureCode }
                let cap = capacity
                lock.unlock()
                if !fail, let cap, let ring, ring.diskBytes + bytes.count > cap { fail = true }
                if fail {
                    lock.lock(); rejected += 1; lock.unlock()
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
                try PacketRingBuffer.pwriteAll(fd, bytes, offset)
            }
        }
    }

    private func flakyRing(disk: FlakyDisk, dirs: ScratchDirs, byteBudget: Int = .max) throws -> PacketRingBuffer {
        let ring = try PacketRingBuffer(windowSeconds: .infinity, scratch: makeScratch(dirs),
                                        byteBudget: byteBudget, chunkTargetBytes: 64 << 10,
                                        writeAll: disk.writer)
        disk.ring = ring
        return ring
    }

    @Test("A write that fails once for want of space is retried after the oldest chunk is freed, and nothing is dropped",
          arguments: [ENOSPC, EDQUOT])
    func failedWriteMakesRoomAndRetries(code: Int32) throws {
        let dirs = ScratchDirs()
        let disk = FlakyDisk()
        let ring = try flakyRing(disk: disk, dirs: dirs)
        defer { ring.close() }
        let body = Data(repeating: 7, count: 32 << 10)
        for i in 0..<10 {
            try ring.append(pts: Double(i), isKeyframe: i % 2 == 0, isVideo: true, bytes: body)
        }
        #expect(ring.seqBounds.first == 0)
        disk.failNext(1, code: code)
        try ring.append(pts: 10, isKeyframe: true, isVideo: true, bytes: body)

        let bounds = ring.seqBounds
        #expect(bounds.end == 11, "the packet that hit the full disk was stored, not dropped")
        #expect(bounds.first > 0, "the window shrank to make the room")
        let first = try #require(ring.packet(atSeq: bounds.first))
        #expect(first.isKeyframe)
        #expect(ring.packet(atSeq: 10)?.bytes == body)
    }

    @Test("A write that fails for any other reason drops that packet and keeps the whole history",
          arguments: [EMFILE, EIO, ENOENT])
    func otherWriteFailuresKeepTheWindow(code: Int32) throws {
        let dirs = ScratchDirs()
        let disk = FlakyDisk()
        let ring = try flakyRing(disk: disk, dirs: dirs)
        defer { ring.close() }
        let body = { (i: Int) in Data(repeating: UInt8(truncatingIfNeeded: i), count: 32 << 10) }
        for i in 0..<10 {
            try ring.append(pts: Double(i), isKeyframe: i % 2 == 0, isVideo: true, bytes: body(i))
        }
        let before = ring.seqBounds
        let diskBefore = ring.diskBytes
        #expect(before.first == 0)

        for keyframe in [false, true] {
            disk.failNext(1, code: code)
            #expect(throws: (any Error).self) {
                try ring.append(pts: 10, isKeyframe: keyframe, isVideo: true, bytes: body(10))
            }
            let after = ring.seqBounds
            #expect(after.first == before.first && after.end == before.end,
                    "errno \(code): nothing evicted, nothing indexed (keyframe \(keyframe))")
            #expect(ring.diskBytes == diskBefore)
        }
        for i in 0..<10 { #expect(ring.packet(atSeq: i)?.bytes == body(i)) }

        try ring.append(pts: 10, isKeyframe: false, isVideo: true, bytes: body(10))
        #expect(ring.seqBounds.end == before.end + 1, "the next write goes through")
        #expect(ring.seqBounds.first == 0)
    }

    @Test("A full volume shrinks the rewind window and the live feed keeps flowing")
    func fullVolumeKeepsFeedingWithAShrinkingWindow() throws {
        let dirs = ScratchDirs()
        let disk = FlakyDisk()
        disk.setCapacity(1 << 20)
        let ring = try flakyRing(disk: disk, dirs: dirs)
        defer { ring.close() }
        let body = { (i: Int) in Data(repeating: UInt8(truncatingIfNeeded: i), count: 16 << 10) }
        for i in 0..<500 {
            try ring.append(pts: Double(i) * 0.04, isKeyframe: i % 5 == 0, isVideo: true, bytes: body(i))
            #expect(ring.seqBounds.end == i + 1, "append \(i) must not freeze at the live edge")
        }
        #expect(disk.rejected > 0)
        #expect(ring.diskBytes <= 1 << 20)
        let bounds = ring.seqBounds
        #expect(bounds.first > 0)
        let first = try #require(ring.packet(atSeq: bounds.first))
        #expect(first.isKeyframe)
        #expect(ring.packet(atSeq: 499)?.bytes == body(499))
    }

    @Test("With nothing reclaimable the append throws cleanly, and the ring recovers when space returns")
    func nothingToFreeThrowsWithoutCorruption() throws {
        let dirs = ScratchDirs()
        let disk = FlakyDisk()
        let ring = try flakyRing(disk: disk, dirs: dirs)
        defer { ring.close() }
        let body = { (i: Int) in Data(repeating: UInt8(truncatingIfNeeded: i), count: 4 << 10) }
        try ring.append(pts: 0, isKeyframe: true, isVideo: true, bytes: body(0))
        try ring.append(pts: 1, isKeyframe: false, isVideo: true, bytes: body(1))

        disk.failNext(1)
        #expect(throws: (any Error).self) {
            try ring.append(pts: 2, isKeyframe: false, isVideo: true, bytes: body(2))
        }
        #expect(ring.seqBounds.end == 2, "a dropped packet leaves no entry behind")

        try ring.append(pts: 3, isKeyframe: false, isVideo: true, bytes: body(3))
        #expect(ring.seqBounds.end == 3)
        #expect(ring.packet(atSeq: 0)?.bytes == body(0))
        #expect(ring.packet(atSeq: 1)?.bytes == body(1))
        #expect(ring.packet(atSeq: 2)?.bytes == body(3))
    }

    @Test("An incoming keyframe may replace a retained span that cannot otherwise make room")
    func incomingKeyframeReplacesATailOnlySpan() throws {
        let dirs = ScratchDirs()
        let disk = FlakyDisk()
        let ring = try flakyRing(disk: disk, dirs: dirs)
        defer { ring.close() }
        let body = Data(repeating: 5, count: 4 << 10)
        for i in 0..<3 {
            try ring.append(pts: Double(i), isKeyframe: i == 0, isVideo: true, bytes: body)
        }
        disk.failNext(1)
        try ring.append(pts: 3, isKeyframe: true, isVideo: true, bytes: Data(repeating: 6, count: 4 << 10))

        let bounds = ring.seqBounds
        #expect(bounds.end == 4)
        #expect(bounds.first == 3)
        let only = try #require(ring.packet(atSeq: 3))
        #expect(only.isKeyframe && only.bytes == Data(repeating: 6, count: 4 << 10))
    }

    // MARK: - Reads beside the writer

    @Test("Readers racing eviction only ever see the bytes of the sequence they asked for")
    func concurrentReadersSeeConsistentBytes() async throws {
        let dirs = ScratchDirs()
        let ring = try PacketRingBuffer(windowSeconds: .infinity, scratch: makeScratch(dirs),
                                        byteBudget: 2 << 20, chunkTargetBytes: 128 << 10)
        defer { ring.close() }
        let total = 6000
        @Sendable func body(_ i: Int) -> Data { Data(repeating: UInt8(truncatingIfNeeded: i), count: 2000 + i % 500) }

        let finished = Counter()
        let mismatches = Counter()
        let writerDone = Counter()
        let writer = Thread {
            for i in 0..<total {
                try? ring.append(pts: Double(i) * 0.01, isKeyframe: i % 25 == 0, isVideo: i % 3 != 0, bytes: body(i))
            }
            writerDone.add(1)
            finished.add(1)
        }
        var readers: [Thread] = []
        for r in 0..<3 {
            readers.append(Thread {
                var state = UInt64(r + 1) &* 0x9E3779B97F4A7C15
                while writerDone.value == 0 {
                    let bounds = ring.seqBounds
                    guard bounds.end > bounds.first else { continue }
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    let seq = bounds.first + Int(state >> 33) % (bounds.end - bounds.first)
                    if let p = ring.packet(atSeq: seq) {
                        if p.bytes != body(seq) || p.isVideo != (seq % 3 != 0) { mismatches.add(1) }
                    }
                    if let v = ring.isVideo(atSeq: seq), v != (seq % 3 != 0) { mismatches.add(1) }
                }
                finished.add(1)
            })
        }
        writer.start()
        readers.forEach { $0.start() }
        try await waitFor { finished.value == 4 }
        #expect(mismatches.value == 0)
        #expect(ring.seqBounds.end == total)
    }

    @Test("isVideo(atSeq:) answers from the index: resident kinds, nil outside the span")
    func isVideoAnswersFromTheIndex() throws {
        let dirs = ScratchDirs()
        let ring = try PacketRingBuffer(windowSeconds: .infinity, scratch: makeScratch(dirs), byteBudget: 1 << 20)
        defer { ring.close() }
        #expect(ring.isVideo(atSeq: 0) == nil)
        for i in 0..<300 {
            try ring.append(pts: Double(i), isKeyframe: i % 6 == 0, isVideo: i % 2 == 0,
                            bytes: Data(repeating: 1, count: 16 << 10))
        }
        let bounds = ring.seqBounds
        #expect(bounds.first > 0)
        for seq in bounds.first..<bounds.end {
            #expect(ring.isVideo(atSeq: seq) == (seq % 2 == 0))
        }
        #expect(ring.isVideo(atSeq: bounds.first - 1) == nil)
        #expect(ring.isVideo(atSeq: bounds.end) == nil)
    }

    @Test("A chunk file that vanished reads as an unreadable packet, not a crash")
    func missingChunkFileIsAnUnreadablePacket() throws {
        let dirs = ScratchDirs()
        let scratch = makeScratch(dirs)
        let ring = try PacketRingBuffer(windowSeconds: .infinity, scratch: scratch, chunkTargetBytes: 64 << 10)
        defer { ring.close() }
        for i in 0..<60 {
            try ring.append(pts: Double(i), isKeyframe: i % 4 == 0, isVideo: true,
                            bytes: Data(repeating: UInt8(i), count: 30 << 10))
        }
        // The oldest chunk is well outside the read-handle cache by now.
        try FileManager.default.removeItem(at: scratch.appendingPathComponent("chunk-0.bin"))
        #expect(ring.seqBounds.first == 0)
        #expect(ring.packet(atSeq: 0) == nil)
        #expect(ring.packet(atSeq: 59)?.bytes.count == 30 << 10)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func add(_ d: Int) { lock.lock(); n += d; lock.unlock() }
}

/// Removes every directory it handed out when the test that owns it ends. `PacketRingBuffer.close()`
/// unlinks in the background, which a finished test process does not wait for.
private final class ScratchDirs: @unchecked Sendable {
    private let lock = NSLock()
    private var dirs: [URL] = []
    func make(prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lock.lock(); dirs.append(dir); lock.unlock()
        return dir
    }
    deinit { for dir in dirs { try? FileManager.default.removeItem(at: dir) } }
}
