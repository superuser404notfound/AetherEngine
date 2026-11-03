import Testing
import CoreMedia
import Foundation
@testable import AetherEngine

/// The history keeps the enhancement-layer packets of the last stretch played in a ring file, so a seek
/// back into content the segment cache still holds finds its enhancement layer.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct VideoPacketHistoryTests {

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 90000) }

    @discardableResult
    private static func append(_ history: VideoPacketHistory, _ bytes: [UInt8], at seconds: Double, key: Bool = false,
                               epoch: UInt64 = 1) -> UInt64? {
        bytes.withUnsafeBytes {
            history.append($0, item: time(seconds), decode: time(seconds), epoch: epoch, isKeyframe: key)
        }
    }

    @Test("packets read back in order with their served time and keyframe flag")
    func packetsReadBack() throws {
        let history = try #require(VideoPacketHistory(capacityBytes: 1 << 20))
        Self.append(history, [1, 2, 3], at: 0, key: true)
        Self.append(history, [4, 5], at: 0.5)
        let first = try #require(history.entry(seq: 0))
        let second = try #require(history.entry(seq: 1))
        #expect(history.read(first) == Data([1, 2, 3]))
        #expect(history.read(second) == Data([4, 5]))
        #expect(first.isKeyframe && !second.isKeyframe)
        #expect(second.item == 0.5)
        #expect(history.newestSeq == 1)
        #expect(history.coveredSeconds == 0...0.5)
    }

    @Test("the ring overwrites its oldest packets, which then read as gone")
    func oldestPacketsAreOverwritten() throws {
        let history = try #require(VideoPacketHistory(capacityBytes: 1 << 20))
        let chunk = [UInt8](repeating: 7, count: 400_000)
        for n in 0..<4 { Self.append(history, chunk, at: Double(n), key: n == 0) }
        #expect(history.entry(seq: 0) == nil, "the first packet no longer fits")
        let newest = try #require(history.entry(seq: 3))
        #expect(history.read(newest)?.count == chunk.count)
        #expect(history.count < 4)
    }

    @Test("packets of random sizes survive many wraps byte for byte, and an overwritten one never reads back")
    func randomSizesAcrossManyWraps() throws {
        let history = try #require(VideoPacketHistory(capacityBytes: 1 << 20))
        var generator: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 {
            generator = generator &* 6364136223846793005 &+ 1442695040888963407
            return generator >> 33
        }
        // Each packet is its own sequence number repeated, so a read that returns another packet's bytes
        // (or a mix) cannot match. Sizes jump between tiny and about a third of the ring, so a write that
        // wraps early leaves a gap at the end of the file, the layout that used to keep overwritten entries.
        var appended = 0
        for n in 0..<3_000 {
            let size = next() % 4 == 0 ? 1 + Int(next() % 330_000) : 1 + Int(next() % 9_000)
            let fill = UInt8(truncatingIfNeeded: n)
            let bytes = [UInt8](repeating: fill, count: size)
            let seq = try #require(Self.append(history, bytes, at: Double(n) / 24, key: n % 12 == 0))
            #expect(seq == UInt64(n))
            appended += 1
            if n % 25 != 0 { continue }
            // Every sequence number from the oldest held to the newest resolves to its own entry and bytes.
            var held = 0
            var cursor = UInt64(0)
            while cursor <= UInt64(n) {
                if let entry = history.entry(seq: cursor) {
                    #expect(entry.seq == cursor)
                    let data = try #require(history.read(entry), "entry \(cursor) is held, so it reads back")
                    #expect(data.allSatisfy { $0 == UInt8(truncatingIfNeeded: cursor) }, "entry \(cursor) holds its own bytes")
                    held += 1
                }
                cursor += 1
            }
            #expect(held == history.count)
        }
        #expect(appended == 3_000)
        // The held entries are the newest ones, with no hole.
        let newest = try #require(history.newestSeq)
        var oldest = newest
        while oldest > 0, history.entry(seq: oldest - 1) != nil { oldest -= 1 }
        #expect(UInt64(history.count) == newest - oldest + 1)
    }

    @Test("a restart point is the latest keyframe at or before the playhead, within the look-back")
    func restartPointFollowsThePlayhead() throws {
        let history = try #require(VideoPacketHistory(capacityBytes: 1 << 20))
        Self.append(history, [1], at: 0, key: true)
        Self.append(history, [2], at: 1)
        Self.append(history, [3], at: 2, key: true)
        Self.append(history, [4], at: 3)
        #expect(history.restartPoint(atOrBefore: 3.5)?.item == 2)
        #expect(history.restartPoint(atOrBefore: 1.5)?.item == 0)
        #expect(history.restartPoint(atOrBefore: 2)?.item == 2)
        #expect(history.restartPoint(atOrBefore: 40, maximumLookBack: 12) == nil, "too far from any held keyframe")
        #expect(history.restartPoint(atOrBefore: -1) == nil)
    }

    @Test("a producer restart that rewrites a time wins the tie, the later append")
    func laterAppendWinsATie() throws {
        let history = try #require(VideoPacketHistory(capacityBytes: 1 << 20))
        Self.append(history, [1], at: 4, key: true, epoch: 1)
        Self.append(history, [2], at: 4, key: true, epoch: 2)
        #expect(history.restartPoint(atOrBefore: 4.2)?.epoch == 2)
    }

    @Test("a packet larger than the ring is refused and an empty one is too")
    func unusablePacketsAreRefused() throws {
        let history = try #require(VideoPacketHistory(capacityBytes: 1 << 20))
        #expect(Self.append(history, [UInt8](repeating: 0, count: (1 << 20) + 1), at: 0) == nil)
        #expect(Self.append(history, [], at: 0) == nil)
        #expect(history.count == 0)
    }
}
