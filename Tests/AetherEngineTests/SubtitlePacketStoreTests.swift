import Foundation
import Testing
@testable import AetherEngine

struct SubtitlePacketStoreTests {
    private func pkt(_ pts: Double, dur: Double = 2, size: Int = 8) -> (Double, Double, Data) {
        (pts, dur, Data(repeating: 0xAB, count: size))
    }

    @Test("entries returns the inclusive pts window in ascending order")
    func windowQuery() {
        let store = SubtitlePacketStore()
        for p in [30.0, 10.0, 20.0] {
            let (pts, dur, data) = pkt(p)
            store.append(streamIndex: 3, ptsSeconds: pts, durationSeconds: dur, payload: data)
        }
        let got = store.entries(streamIndex: 3, from: 10, through: 20).map(\.ptsSeconds)
        #expect(got == [10, 20])
    }

    @Test("same-pts append replaces instead of duplicating (producer restart overlap)")
    func dedupOnRestartOverlap() {
        let store = SubtitlePacketStore()
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: Data([1]))
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2, payload: Data([2, 2]))
        let got = store.entries(streamIndex: 3, from: 0, through: 100)
        #expect(got.count == 1)
        #expect(got[0].payload == Data([2, 2]))
    }

    @Test("prune drops entries strictly before the cutoff")
    func pruneTrailing() {
        let store = SubtitlePacketStore()
        for p in [10.0, 320.0] {
            let (pts, dur, data) = pkt(p)
            store.append(streamIndex: 0, ptsSeconds: pts, durationSeconds: dur, payload: data)
        }
        store.prune(before: 20)
        #expect(store.entries(streamIndex: 0, from: 0, through: 1_000).map(\.ptsSeconds) == [320])
    }

    @Test("per-stream byte cap evicts oldest entries first")
    func capEvictsOldestFirst() {
        let store = SubtitlePacketStore()
        let big = SubtitlePacketStore.perStreamByteCap / 3
        for p in [10.0, 20.0, 30.0, 40.0] {
            store.append(streamIndex: 1, ptsSeconds: p, durationSeconds: 2,
                         payload: Data(repeating: 0, count: big))
        }
        let remaining = store.entries(streamIndex: 1, from: 0, through: 1_000).map(\.ptsSeconds)
        #expect(remaining.first != 10)
        #expect(remaining.contains(40))
    }

    @Test("frontier reports the largest stored pts per stream")
    func frontierPerStream() {
        let store = SubtitlePacketStore()
        let (pts, dur, data) = pkt(55)
        store.append(streamIndex: 2, ptsSeconds: pts, durationSeconds: dur, payload: data)
        #expect(store.frontier(streamIndex: 2) == 55)
        #expect(store.frontier(streamIndex: 9) == nil)
    }

    @Test("clear empties every stream")
    func clearAll() {
        let store = SubtitlePacketStore()
        let (pts, dur, data) = pkt(5)
        store.append(streamIndex: 0, ptsSeconds: pts, durationSeconds: dur, payload: data)
        store.clear()
        #expect(store.entries(streamIndex: 0, from: 0, through: 100).isEmpty)
    }
}
