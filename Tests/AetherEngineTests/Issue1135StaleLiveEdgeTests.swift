import Foundation
import Testing
@testable import AetherEngine

/// AE#1135: a software live channel loaded after a native live session published the previous
/// item's seekable end as its own edge. The native 1 Hz window timer ran one more pass after
/// `stopInternal` cancelled it, by then the load had already adopted the new session's liveness, and
/// the edge is a running maximum. In the reporter's log the edge sat at 398.16 s (the last native
/// item's seekable end) while the ring held about 302 s, and Go Live landed 95 s ahead.
@Suite("AE#1135: a live window tick never outlives its session", .timeLimit(.minutes(3)))
@MainActor
struct Issue1135StaleLiveEdgeTests {

    private static let staleEnd = 398.16

    private static func liveOptions() -> LoadOptions {
        LoadOptions(isLive: true, dvrWindowSeconds: 1_800)
    }

    private static func liveHost() -> NativeAVPlayerHost {
        let host = NativeAVPlayerHost()
        host.setSeekableRangeForTesting(start: 0, end: staleEnd)
        return host
    }

    @Test("the tick of a stopped session writes nothing into the next session's window")
    func cancelledTickPublishesNothing() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let host = Self.liveHost()

        engine.adoptSessionLiveness(from: Self.liveOptions())
        engine.startLiveWindowTimer(host: host)
        // The reporter's timer had been asleep for minutes, so the cancel has to reach it mid-sleep.
        try await Task.sleep(nanoseconds: 100_000_000)
        // What `load` does: stop the old session, then adopt the new one's liveness synchronously.
        engine.stopInternal(resetDisplayCriteria: false)
        engine.adoptSessionLiveness(from: Self.liveOptions())

        // The cancelled task resumes at the next suspension point.
        try await Task.sleep(nanoseconds: 200_000_000)
        withExtendedLifetime(host) {}

        let edge = try #require(engine.liveWindow).edgeTime
        #expect(edge == 0, "the new session's edge came from the previous item: \(edge)")
        #expect(engine.clock.liveEdgeTime == 0)
    }

    /// The generation half on its own: a sleep that finished just before the stop leaves a pass
    /// queued that no cancel reaches any more. Only the generation it started under stops that one.
    @Test("a tick that wakes under a newer session generation publishes nothing")
    func tickUnderNewerGenerationPublishesNothing() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let host = Self.liveHost()

        engine.adoptSessionLiveness(from: Self.liveOptions())
        engine.startLiveWindowTimer(host: host)
        engine.loadGeneration &+= 1

        try await Task.sleep(nanoseconds: 1_500_000_000)
        withExtendedLifetime(host) {}

        #expect(try #require(engine.liveWindow).edgeTime == 0)
    }

    @Test("the tick still publishes within its own session")
    func tickPublishesWhileItsSessionRuns() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let host = Self.liveHost()

        engine.adoptSessionLiveness(from: Self.liveOptions())
        engine.startLiveWindowTimer(host: host)

        // Counted polls, not a wall-clock deadline. Under a busy main actor (a full parallel CI run)
        // the poll and the timer pass wake together after the deadline, and the poll ran first and
        // gave up with the edge still 0. Every poll needs a main-actor turn, so after 20 of them the
        // 1 s tick is due and queued ahead of the next one.
        var polls = 0
        while (engine.liveWindow?.edgeTime ?? 0) == 0, polls < 400 {
            polls += 1
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        withExtendedLifetime(host) {}

        let edge = try #require(engine.liveWindow).edgeTime
        #expect(abs(edge - Self.staleEnd) < 0.001)
    }
}
