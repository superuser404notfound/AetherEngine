import Foundation
import Testing
@testable import AetherEngine

/// #166: the per-stream byte cap (`perStreamByteCap`) bounds each subtitle stream to 32MB, but the
/// pump tap and the forward prefetcher both harvest EVERY embedded subtitle stream into the session
/// store (so a track switch backfills instantly, #112). Nothing bounded the SUM across streams: a
/// source with many embedded tracks (99 in the field repro, mostly bitmap/PGS) climbed toward
/// N x 32MB (~3.2GB) of raw heap and the host hit the iOS jetsam limit.
///
/// The fix adds an aggregate byte budget across all streams. The active drain targets are protected
/// (a switch to them still backfills from a full window); the coldest non-protected streams evict
/// oldest-first once the aggregate budget is exceeded. Caps are injectable so these tests stay small.
struct Issue166AggregateByteCapTests {

    @Test("aggregate cap bounds total retained bytes across many non-selected streams")
    func aggregateCapBoundsTotalAcrossStreams() {
        let store = SubtitlePacketStore(perStreamByteCap: 400, aggregateByteCap: 1_000)
        // 20 streams, each under its per-stream cap; unbounded this would retain 6,000 bytes.
        for s in 0..<20 {
            store.append(streamIndex: Int32(s), ptsSeconds: 10, durationSeconds: 2,
                         payload: Data(repeating: 0, count: 300))
        }
        #expect(store.totalRetainedBytes <= 1_000)
    }

    @Test("a protected active stream is never evicted under aggregate pressure")
    func protectedStreamSurvivesAggregatePressure() {
        let store = SubtitlePacketStore(perStreamByteCap: 400, aggregateByteCap: 1_000)
        store.setProtectedStreams([7])
        store.append(streamIndex: 7, ptsSeconds: 10, durationSeconds: 2,
                     payload: Data(repeating: 1, count: 300))
        // Flood 19 other streams to force aggregate eviction well past the budget.
        for s in 0..<20 where s != 7 {
            store.append(streamIndex: Int32(s), ptsSeconds: 10, durationSeconds: 2,
                         payload: Data(repeating: 0, count: 300))
        }
        #expect(!store.entries(streamIndex: 7, from: 0, through: 100).isEmpty)
        #expect(store.totalRetainedBytes <= 1_000)
    }

    @Test("aggregate eviction drops the least-recently-touched non-selected stream first")
    func coldestNonSelectedStreamEvictsFirst() {
        // Per-stream cap high so only the aggregate budget drives eviction here.
        let store = SubtitlePacketStore(perStreamByteCap: 10_000, aggregateByteCap: 1_000)
        store.append(streamIndex: 1, ptsSeconds: 10, durationSeconds: 2,
                     payload: Data(repeating: 0, count: 400))   // coldest
        store.append(streamIndex: 2, ptsSeconds: 10, durationSeconds: 2,
                     payload: Data(repeating: 0, count: 400))   // warmer
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2,
                     payload: Data(repeating: 0, count: 400))   // pushes total to 1,200 > 1,000
        #expect(store.entries(streamIndex: 1, from: 0, through: 100).isEmpty)     // coldest gone
        #expect(!store.entries(streamIndex: 2, from: 0, through: 100).isEmpty)    // warmer kept
        #expect(!store.entries(streamIndex: 3, from: 0, through: 100).isEmpty)    // just-added kept
    }

    @Test("re-touching a stream re-warms it so an older peer evicts first")
    func reTouchingReWarmsStream() {
        let store = SubtitlePacketStore(perStreamByteCap: 10_000, aggregateByteCap: 1_000)
        store.append(streamIndex: 1, ptsSeconds: 10, durationSeconds: 2,
                     payload: Data(repeating: 0, count: 400))
        store.append(streamIndex: 2, ptsSeconds: 10, durationSeconds: 2,
                     payload: Data(repeating: 0, count: 400))
        store.append(streamIndex: 1, ptsSeconds: 12, durationSeconds: 2,   // re-warm stream 1
                     payload: Data(repeating: 0, count: 100))
        // Total is now 900; the next append tips it over and stream 2 is now the coldest.
        store.append(streamIndex: 3, ptsSeconds: 10, durationSeconds: 2,
                     payload: Data(repeating: 0, count: 400))
        #expect(store.entries(streamIndex: 2, from: 0, through: 100).isEmpty)     // coldest now
        #expect(!store.entries(streamIndex: 1, from: 0, through: 100).isEmpty)    // re-warmed, kept
    }

    @Test("per-stream cap still evicts oldest within one stream")
    func perStreamCapStillHoldsWithInjectedCap() {
        let store = SubtitlePacketStore(perStreamByteCap: 500, aggregateByteCap: 100_000)
        for p in [10.0, 20.0, 30.0] {
            store.append(streamIndex: 4, ptsSeconds: p, durationSeconds: 2,
                         payload: Data(repeating: 0, count: 200))   // 3 x 200 = 600 > 500
        }
        let remaining = store.entries(streamIndex: 4, from: 0, through: 100).map(\.ptsSeconds)
        #expect(!remaining.contains(10))   // oldest evicted
        #expect(remaining.contains(30))    // newest kept
    }

    @Test("clearing protection lets a formerly protected stream evict again")
    func clearingProtectionReleasesStream() {
        let store = SubtitlePacketStore(perStreamByteCap: 10_000, aggregateByteCap: 1_000)
        store.setProtectedStreams([1])
        store.append(streamIndex: 1, ptsSeconds: 10, durationSeconds: 2,
                     payload: Data(repeating: 0, count: 500))
        store.setProtectedStreams([])   // subtitles turned off: nothing protected anymore
        for s in 2..<6 {
            store.append(streamIndex: Int32(s), ptsSeconds: 10, durationSeconds: 2,
                         payload: Data(repeating: 0, count: 300))
        }
        #expect(store.totalRetainedBytes <= 1_000)
    }
}

/// #166 engine wiring: the active drain targets (`subtitleDrainTargets`) must be propagated to the
/// store as protected streams, so aggregate eviction never drops the window the drainer is reading.
@MainActor
struct Issue166ProtectionWiringTests {

    private func makeLoadedEngine(store: SubtitlePacketStore) throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        engine.softwareSubtitlePacketStore = store
        return engine
    }

    @Test("refreshing store protection propagates both active drain targets")
    func refreshProtectsActiveDrainTargets() throws {
        let store = SubtitlePacketStore(perStreamByteCap: 400, aggregateByteCap: 1_000)
        let engine = try makeLoadedEngine(store: store)
        engine.subtitleDrainTargets[.primary] = 5
        engine.subtitleDrainTargets[.secondary] = 8
        engine.refreshSubtitleStoreProtection()

        store.append(streamIndex: 5, ptsSeconds: 10, durationSeconds: 2,
                     payload: Data(repeating: 1, count: 300))
        store.append(streamIndex: 8, ptsSeconds: 10, durationSeconds: 2,
                     payload: Data(repeating: 1, count: 300))
        for s in 10..<25 {   // flood many non-selected streams
            store.append(streamIndex: Int32(s), ptsSeconds: 10, durationSeconds: 2,
                         payload: Data(repeating: 0, count: 300))
        }
        #expect(!store.entries(streamIndex: 5, from: 0, through: 100).isEmpty)
        #expect(!store.entries(streamIndex: 8, from: 0, through: 100).isEmpty)
        #expect(store.totalRetainedBytes <= 1_000 + 300)   // budget + one in-flight append
    }
}
