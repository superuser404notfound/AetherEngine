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

    @Test("clear empties the cache")
    func clearEmpties() {
        let cache = DetourBlockCache(blockSize: 16, maxBlocks: 3)
        cache.insert(0, patternBlock(base: 0))
        cache.insert(1, patternBlock(base: 16))
        cache.clear()
        #expect(cache.residentCount == 0)
        #expect(cache.block(0) == nil)
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
