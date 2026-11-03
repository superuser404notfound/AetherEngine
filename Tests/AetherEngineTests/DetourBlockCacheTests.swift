import Testing
import Foundation
@testable import AetherEngine

/// Issue #69: the persistent AVIOReader used to tear down + reopen its HTTP connection on every
/// non-sequential read during the MP4 parse ping-pong (non-faststart / coarsely interleaved remote
/// files), driving the origin into a 429 storm. The fix routes those random-access reads through a
/// fixed-block LRU detour cache over the pooled keep-alive session. These tests pin the pure
/// copy + eviction math the cache is responsible for; the network fetch path is exercised on device.
struct DetourBlockCacheTests {

    /// A 16-byte block whose byte i holds (base + i) & 0xFF, so a copied range is identifiable.
    private func patternBlock(base: Int, count: Int = 16) -> Data {
        Data((0..<count).map { UInt8((base + $0) & 0xFF) })
    }

    @Test("serveCached returns nil for a non-resident block")
    func missWhenEmpty() {
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 3)
        var dst = [UInt8](repeating: 0xEE, count: 16)
        let n = dst.withUnsafeMutableBufferPointer { cache.serveCached(into: $0.baseAddress!, maxLen: 16, at: 0) }
        #expect(n == nil)
    }

    @Test("serveCached copies the exact covered range from a resident block")
    func copyWithinBlock() {
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 3)
        cache.insert(0, patternBlock(base: 0))     // bytes 0..15
        var dst = [UInt8](repeating: 0xEE, count: 16)

        // Read 8 bytes from offset 0.
        let a = dst.withUnsafeMutableBufferPointer { cache.serveCached(into: $0.baseAddress!, maxLen: 8, at: 0) }
        #expect(a == 8)
        #expect(Array(dst[0..<8]) == [0, 1, 2, 3, 4, 5, 6, 7])

        // Read from a mid-block offset; maxLen exceeds the bytes remaining in the block.
        var dst2 = [UInt8](repeating: 0xEE, count: 16)
        let b = dst2.withUnsafeMutableBufferPointer { cache.serveCached(into: $0.baseAddress!, maxLen: 100, at: 10) }
        #expect(b == 6)                                       // 16 - 10
        #expect(Array(dst2[0..<6]) == [10, 11, 12, 13, 14, 15])
    }

    @Test("serveCached clamps a spanning read at the block boundary (caller re-enters next block)")
    func clampsAtBoundary() {
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 3)
        cache.insert(0, patternBlock(base: 0))
        cache.insert(1, patternBlock(base: 16))    // block 1: bytes 16..31
        var dst = [UInt8](repeating: 0xEE, count: 16)

        // Offset 14, want 10: only 2 bytes (14,15) are in block 0.
        let a = dst.withUnsafeMutableBufferPointer { cache.serveCached(into: $0.baseAddress!, maxLen: 10, at: 14) }
        #expect(a == 2)
        #expect(Array(dst[0..<2]) == [14, 15])

        // Re-enter at the advanced offset 16: served from block 1.
        var dst2 = [UInt8](repeating: 0xEE, count: 16)
        let b = dst2.withUnsafeMutableBufferPointer { cache.serveCached(into: $0.baseAddress!, maxLen: 8, at: 16) }
        #expect(b == 8)
        #expect(Array(dst2[0..<8]) == [16, 17, 18, 19, 20, 21, 22, 23])
    }

    @Test("a short (partial) block serves its covered range but MISSES its uncovered tail")
    func shortBlockTailMisses() {
        // The #69 red-team required change: a truncated body must not shadow the re-fetch path for
        // bytes it does not cover. Modeled here by inserting a 5-byte block at index 2 (blockStart 32).
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 3)
        cache.insert(2, patternBlock(base: 32, count: 5))    // covers offsets 32..36 only
        var dst = [UInt8](repeating: 0xEE, count: 16)

        let covered = dst.withUnsafeMutableBufferPointer { cache.serveCached(into: $0.baseAddress!, maxLen: 16, at: 32) }
        #expect(covered == 5)
        #expect(Array(dst[0..<5]) == [32, 33, 34, 35, 36])

        // Offset 37 lands in the uncovered tail of the short block: a miss, so the caller re-fetches.
        var dst2 = [UInt8](repeating: 0xEE, count: 16)
        let tail = dst2.withUnsafeMutableBufferPointer { cache.serveCached(into: $0.baseAddress!, maxLen: 16, at: 37) }
        #expect(tail == nil)
    }

    @Test("LRU evicts the oldest block beyond maxBlocks")
    func lruEviction() {
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 3)
        for i in 0..<4 { cache.insert(Int64(i), patternBlock(base: i * 16)) }
        #expect(cache.residentCount == 3)
        #expect(cache.block(0) == nil)               // oldest evicted
        #expect(cache.block(1) != nil)
        #expect(cache.block(2) != nil)
        #expect(cache.block(3) != nil)
    }

    @Test("accessing a block bumps its recency so it survives the next eviction")
    func recencyBump() {
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 3)
        cache.insert(0, patternBlock(base: 0))
        cache.insert(1, patternBlock(base: 16))
        cache.insert(2, patternBlock(base: 32))
        _ = cache.block(0)                           // bump 0 to most-recent
        cache.insert(3, patternBlock(base: 48))      // evicts the now-oldest, which is 1
        #expect(cache.block(1) == nil)
        #expect(cache.block(0) != nil)
        #expect(cache.block(2) != nil)
        #expect(cache.block(3) != nil)
    }

    @Test("re-inserting an existing index updates the value without double-counting the LRU")
    func reinsertSameIndex() {
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 3)
        cache.insert(0, patternBlock(base: 0))
        cache.insert(0, patternBlock(base: 100))     // overwrite, must not add a second LRU entry
        cache.insert(1, patternBlock(base: 16))
        cache.insert(2, patternBlock(base: 32))
        #expect(cache.residentCount == 3)            // 0 counted once
        var dst = [UInt8](repeating: 0, count: 16)
        let n = dst.withUnsafeMutableBufferPointer { cache.serveCached(into: $0.baseAddress!, maxLen: 4, at: 0) }
        #expect(n == 4)
        #expect(Array(dst[0..<4]) == [100, 101, 102, 103])   // newest value served
    }

    /// A clock a test moves by hand.
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 1000
        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return seconds }
        func advance(_ by: TimeInterval) { lock.lock(); seconds += by; lock.unlock() }
    }

    // audit PERF-108: only close() emptied the cache, so the blocks of a backward scrub stayed
    // resident (up to 32 MB per reader) for the rest of the session.
    @Test("a block idle past the threshold is evicted and a recently hit one survives")
    func idleEviction() {
        let clock = ManualClock()
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 8, now: { clock.now })
        cache.insert(0, patternBlock(base: 0))
        cache.insert(1, patternBlock(base: 16))
        cache.insert(2, patternBlock(base: 32))

        clock.advance(20)
        _ = cache.block(1)
        var dst = [UInt8](repeating: 0, count: 16)
        #expect(dst.withUnsafeMutableBufferPointer { cache.serveCached(into: $0.baseAddress!, maxLen: 4, at: 32) } == 4)
        clock.advance(20)

        // Block 0 has been idle 40 s; blocks 1 and 2 were hit 20 s ago.
        #expect(cache.evictIdle(olderThan: 30) == 1)
        #expect(cache.residentCount == 2)
        #expect(cache.block(0) == nil)
        #expect(cache.block(1) != nil)
        #expect(cache.block(2) != nil)

        clock.advance(31)
        #expect(cache.evictIdle(olderThan: 30) == 2)
        #expect(cache.residentCount == 0)
        #expect(cache.evictIdle(olderThan: 30) == 0)
    }

    @Test("a block that was evicted for age leaves the LRU order, so a later insert does not trip on it")
    func evictedBlockLeavesTheOrder() {
        let clock = ManualClock()
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 2, now: { clock.now })
        cache.insert(0, patternBlock(base: 0))
        clock.advance(60)
        cache.insert(1, patternBlock(base: 16))
        #expect(cache.evictIdle(olderThan: 30) == 1)

        cache.insert(2, patternBlock(base: 32))
        cache.insert(3, patternBlock(base: 48))
        #expect(cache.residentCount == 2)
        #expect(cache.block(1) == nil, "the oldest surviving block is the one the size cap evicts")
        #expect(cache.block(2) != nil)
        #expect(cache.block(3) != nil)
    }

    @Test("clear empties the cache")
    func clearEmpties() {
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 3)
        cache.insert(0, patternBlock(base: 0))
        cache.insert(1, patternBlock(base: 16))
        cache.clear()
        #expect(cache.residentCount == 0)
        #expect(cache.block(0) == nil)
    }

    /// Walks `cycle` blocks round-robin the way the detour path does (look up, insert on a miss) and
    /// returns how many lookups missed in each pass.
    private func missesPerPass(_ cache: DetourBlockCache, cycle: Int, passes: Int) -> [Int] {
        (0..<passes).map { _ in
            var misses = 0
            for i in 0..<cycle where cache.block(Int64(i)) == nil {
                misses += 1
                cache.insert(Int64(i), patternBlock(base: i * 16))
            }
            return misses
        }
    }

    // #909: 14 subtitle tracks, each in its own byte range, against 8 blocks missed on every lookup.
    @Test("a cyclic working set larger than the resting size grows the cache until every lookup hits")
    func cyclicWorkingSetGrows() {
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 8, ceilingBlocks: 24)
        let misses = missesPerPass(cache, cycle: 14, passes: 4)
        #expect(misses[0] == 14)
        #expect(misses.last == 0)
        #expect(cache.capacity == 14)
        #expect(cache.residentCount == 14)
    }

    @Test("the same cycle without a ceiling keeps missing every lookup")
    func cyclicWorkingSetWithoutCeilingThrashes() {
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 8)
        #expect(missesPerPass(cache, cycle: 14, passes: 4) == [14, 14, 14, 14])
        #expect(cache.capacity == 8)
    }

    @Test("a cycle exactly the ceiling's size grows the cache to the ceiling")
    func cycleAtTheCeilingGrowsToIt() {
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 4, ceilingBlocks: 6)
        #expect(missesPerPass(cache, cycle: 6, passes: 3).last == 0)
        #expect(cache.capacity == 6)
    }

    // Nine blocks in turn miss on every lookup under any capacity below nine, so growing to five would
    // only hold more memory for the same fetches.
    @Test("a cycle the ceiling could not hold either does not grow the cache")
    func cycleBeyondTheCeilingStaysAtRestingSize() {
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 3, ceilingBlocks: 5)
        #expect(missesPerPass(cache, cycle: 9, passes: 4) == [9, 9, 9, 9])
        #expect(cache.capacity == 3)
    }

    @Test("a forward scan that never returns to a block does not grow the cache")
    func forwardScanStaysAtRestingSize() {
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 8, ceilingBlocks: 24)
        for i in 0..<100 { cache.insert(Int64(i), patternBlock(base: i * 16)) }
        #expect(cache.capacity == 8)
        #expect(cache.residentCount == 8)
    }

    @Test("the idle sweep shrinks a grown cache back, and clear resets it")
    func idleSweepAndClearShrink() {
        let clock = ManualClock()
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 8, ceilingBlocks: 24, now: { clock.now })
        _ = missesPerPass(cache, cycle: 14, passes: 3)
        #expect(cache.capacity == 14)

        clock.advance(60)
        for i in 0..<3 { _ = cache.block(Int64(i)) }
        #expect(cache.evictIdle(olderThan: 30) == 11)
        #expect(cache.capacity == 8, "never below the resting size")

        _ = missesPerPass(cache, cycle: 14, passes: 3)
        #expect(cache.capacity == 14)
        cache.clear()
        #expect(cache.capacity == 8)
    }
}

/// AE#909, through the reader: a demuxer reading twelve regions behind the streaming window, the way a
/// flat MP4 with one region per subtitle track is read during playback. Contributed by @oxyc in #911.
@Suite("Detour cache grows to the reader's working set", .offCooperativePool)
struct DetourCacheWorkingSetReaderTests {

    private static let chunk = 256 * 1024
    private static let block: Int64 = 4 * 1024 * 1024

    @Test("a third pass over twelve regions behind the window fetches nothing", .timeLimit(.minutes(2)))
    func repeatedPassesStopFetching() throws {
        let server = try #require(ThrottledOriginServer(totalSize: 128 * 1024 * 1024, throttleUs: 1000, patternedBody: true))
        defer { server.stop() }
        // The detour fetch's interactive budget is a wall clock; see Issue782RestartReanchorTests. So is
        // idle release: on a loaded runner a pass can outlast its 30 s, and the release would shrink the
        // cache between passes. What is measured here is growth, not release.
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                detourIdleSeconds: 3600, detourFetchBudget: 30)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        reader.markOpenPhaseFinished()

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunk)
        defer { buf.deallocate() }
        var read = 0
        while read < 80 * 1024 * 1024 {
            let n = Int(reader.read(into: buf, size: Int32(Self.chunk)))
            #expect(n > 0, "forward read failed at \(read)")
            if n <= 0 { return }
            read += n
        }

        func blockFetches() -> Int {
            server.requestedRanges.filter { range in
                guard let end = range.end else { return false }
                return end - range.start + 1 == Self.block
            }.count
        }
        var perPass: [Int] = []
        for _ in 0..<3 {
            let before = blockFetches()
            for region in 0..<12 {
                let offset = Int64(region) * Self.block + 4321
                #expect(reader.seek(offset: offset, whence: Int32(SEEK_SET)) == offset)
                let n = Int(reader.read(into: buf, size: Int32(Self.chunk)))
                #expect(n > 0)
                #expect((0..<n).allSatisfy { buf[$0] == ThrottledOriginServer.patternByte(at: offset + Int64($0)) },
                        "region \(region) served the wrong bytes")
            }
            perPass.append(blockFetches() - before)
        }
        #expect(perPass.first == 12, "the first pass did not fetch each region as a detour block: \(perPass)")
        #expect(perPass.last == 0, "passes fetched \(perPass)")
    }
}

/// Issue #71: under a sustained 429, parse-driven seekReconnect kept resetting unproductiveReconnects
/// so the give-up cap was never reached (infinite gen climb). A separate rate-limit streak that
/// survives seekReconnect must give up cleanly after a bounded number of attempts.
struct AVIOReaderRateLimitStreakTests {

    @Test("recordRateLimitAndShouldGiveUp gives up only after the bounded cap")
    func boundedGiveUp() {
        let reader = AVIOReader(url: URL(string: "https://example.com/x.mp4")!)
        // rateLimitMaxStreak = 6: the first 6 attempts keep trying, the 7th gives up.
        for attempt in 1...6 {
            #expect(reader.recordRateLimitAndShouldGiveUp() == false, "attempt \(attempt) should keep trying")
        }
        #expect(reader.recordRateLimitAndShouldGiveUp() == true, "7th consecutive 429/503 must give up")
    }
}
