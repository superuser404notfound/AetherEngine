import Foundation
import Testing
@testable import AetherEngine

/// AE#1061: an audio pick that landed while the load was still in its display handshake superseded
/// it, and the rebuild found none of the load's panel answers, so a Dolby Vision title went
/// media-direct. A pick now waits for the load in flight to return. These pin the wait itself:
/// it holds across the load, and it lets go the moment that load is no longer the one running.
@Suite("A track pick during a load waits for the load to return (AE#1061)", .serialized)
@MainActor
struct Issue1061PickWaitsForLoadTests {

    final class Flag { var value = false }

    @Test("no load in flight: the pick goes straight through")
    func noLoadReturnsAtOnce() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        await engine.awaitLoadInFlightSettled(pick: "test")
    }

    @Test("held until the load returns, released when it does")
    func heldUntilLoadReturns() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.stopInternal(resetDisplayCriteria: false)
        let generation = engine.loadGeneration
        engine.beginLoadInFlight(generation)
        let done = Flag()
        let waiter = Task { @MainActor in
            await engine.awaitLoadInFlightSettled(pick: "test")
            done.value = true
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!done.value)
        engine.endLoadInFlight(generation)
        await waiter.value
        #expect(done.value)
        // The pick must not have moved the generation the load held.
        #expect(engine.loadGeneration == generation)
    }

    @Test("released by a stop even while the replaced load has not unwound")
    func releasedByStopAlone() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.stopInternal(resetDisplayCriteria: false)
        let generation = engine.loadGeneration
        engine.beginLoadInFlight(generation)
        let waiter = Task { @MainActor in
            await engine.awaitLoadInFlightSettled(pick: "test")
        }
        try await Task.sleep(for: .milliseconds(100))
        engine.stopInternal(resetDisplayCriteria: false)
        await waiter.value
        #expect(engine.loadGeneration != generation)
        engine.endLoadInFlight(generation)
    }

    @Test("released when a stop and a newer load take over")
    func releasedBySupersede() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.stopInternal(resetDisplayCriteria: false)
        let first = engine.loadGeneration
        engine.beginLoadInFlight(first)
        let done = Flag()
        let waiter = Task { @MainActor in
            await engine.awaitLoadInFlightSettled(pick: "test")
            done.value = true
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!done.value)
        engine.stopInternal(resetDisplayCriteria: false)
        let second = engine.loadGeneration
        engine.beginLoadInFlight(second)
        await waiter.value
        #expect(done.value)
        // The superseded load's own exit must not end the newer one's flight.
        engine.endLoadInFlight(first)
        #expect(engine.loadInFlight)
        engine.endLoadInFlight(second)
    }

    /// Audit LIF-208: every title pick made during a load waited for it and then rebuilt with the
    /// generation it had captured. The first one to run moved that generation with its own teardown,
    /// so every later pick was dropped as superseded: pick title 3, correct to title 5, get title 3.
    @Test("two title picks during a load: the later one is the one that rebuilds",
          .timeLimit(.minutes(3)))
    func laterTitlePickWins() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let log = EngineLogCapture()
        defer { log.end() }
        engine.stopInternal(resetDisplayCriteria: false)
        engine.loadedURL = URL(fileURLWithPath: "/nonexistent/lif208-disc.iso")
        engine.discTitles = [7013, 7015].map {
            TitleInfo(id: $0, name: "Title \($0)", durationSeconds: 60, chapterCount: 1)
        }
        let generation = engine.loadGeneration
        engine.beginLoadInFlight(generation)

        engine.selectTitle(id: 7013)
        engine.selectTitle(id: 7015)
        try await waitFor { !log.matching("selectTitle(7015) waits for the load in flight").isEmpty }
        engine.endLoadInFlight(generation)

        try await waitFor { !log.matching("selectTitle: switching to title 7015").isEmpty }
        #expect(log.matching("selectTitle: switching to title 7013").isEmpty)
    }
}
