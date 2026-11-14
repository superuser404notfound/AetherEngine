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
}
