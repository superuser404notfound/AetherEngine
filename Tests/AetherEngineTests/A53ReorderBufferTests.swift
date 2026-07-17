import Testing
@testable import AetherEngine

// #131: SEI caption data arrives in decode order; the CEA-608 decoder needs presentation order.
@Suite("A53ReorderBuffer decode-to-presentation ordering")
struct A53ReorderBufferTests {

    private func pair(_ n: UInt8) -> A53ReorderBuffer.Pair { .init(d0: n, d1: n) }

    @Test("No-B-frame stream (pts == dts) drains immediately")
    func immediateDrain() {
        var buf = A53ReorderBuffer()
        let out = buf.insert(pts: 0, pairs: [pair(1)], dts: 0)
        #expect(out == [.init(pts: 0, pairs: [pair(1)])])
    }

    @Test("B-frame decode order comes out in presentation order")
    func bFrameReorder() {
        var buf = A53ReorderBuffer()
        // Decode order (pts, dts): (0,0) (3,1) (1,2) (2,3). Presentation order: 0,1,2,3.
        #expect(buf.insert(pts: 0, pairs: [pair(0)], dts: 0).map(\.pts) == [0])
        #expect(buf.insert(pts: 3, pairs: [pair(3)], dts: 1).isEmpty)
        #expect(buf.insert(pts: 1, pairs: [pair(1)], dts: 2).map(\.pts) == [1])
        #expect(buf.insert(pts: 2, pairs: [pair(2)], dts: 3).map(\.pts) == [2, 3])
    }

    @Test("Backward DTS jump (live-reopen re-anchor) clears stale pending groups")
    func backwardDtsJump() {
        var buf = A53ReorderBuffer()
        _ = buf.insert(pts: 101, pairs: [pair(1)], dts: 100)   // pending: 101 undrained
        let out = buf.insert(pts: 5, pairs: [pair(2)], dts: 5)
        #expect(out == [.init(pts: 5, pairs: [pair(2)])])       // stale 101 gone, fresh group drains
    }

    @Test("nil DTS never advances the drain watermark")
    func nilDts() {
        var buf = A53ReorderBuffer()
        #expect(buf.insert(pts: 1, pairs: [pair(1)], dts: nil).isEmpty)
        #expect(buf.insert(pts: 2, pairs: [pair(2)], dts: 2).map(\.pts) == [1, 2])
    }

    @Test("Overflow drops the oldest group and latches the flag")
    func overflow() {
        var buf = A53ReorderBuffer()
        for i in 0...A53ReorderBuffer.capacity {   // capacity + 1 inserts, nothing drains
            _ = buf.insert(pts: Double(i), pairs: [pair(1)], dts: nil)
        }
        #expect(buf.overflowed)
        // Watermark past everything: pts 0 was dropped, the rest drain in order.
        let out = buf.insert(pts: 9_999, pairs: [pair(9)], dts: 10_000)
        #expect(out.first?.pts == 1)
        #expect(out.count == A53ReorderBuffer.capacity + 1)   // 1...capacity plus the 9_999 group
    }

    @Test("reset clears pending groups and the watermark")
    func reset() {
        var buf = A53ReorderBuffer()
        _ = buf.insert(pts: 50, pairs: [pair(1)], dts: 10)
        buf.reset()
        #expect(buf.insert(pts: 0, pairs: [pair(2)], dts: 0).map(\.pts) == [0])
    }
}
