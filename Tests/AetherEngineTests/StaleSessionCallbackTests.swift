import Foundation
import Testing
@testable import AetherEngine

/// Audit LIF-103, Vcore-101, Vcore-102: callbacks a session raises reach the engine through a hop onto
/// the main actor, and a hop that lands after the session ended used to act on whatever owned the
/// engine by then: a stopped engine, or the next load.
@Suite("A callback from an ended session does not reach its successor", .timeLimit(.minutes(3)))
@MainActor
struct StaleSessionCallbackTests {

    private static func customSource() throws -> MediaSource {
        .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4")
    }

    private static let mediaFailure = SoftwarePathEscalation.Request(
        domain: SoftwarePathEscalation.mediaErrorDomain, code: -19602,
        message: "item death at a frozen position", positionSeconds: 12)

    /// LIF-103: Back pressed in the turn between an item death and its escalation job. `stop()`
    /// resets neither the options nor the budget, so the escalation ran against a gone session, and
    /// its rebuild's `sessionNotReloadable(.noActiveSession)` flipped the stopped engine to `.error`.
    @Test("An escalation raised before stop() and run after it does nothing")
    func escalationAfterStopIsDropped() async throws {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "http://127.0.0.1:9/source.mkv")
        let raisedUnder = engine.loadGeneration
        var events: [SoftwarePathEscalationEvent] = []
        let sub = engine.softwarePathEscalations.sink { events.append($0) }
        defer { sub.cancel() }

        engine.stop()
        await engine.escalateToSoftwarePath(Self.mediaFailure, expectedGeneration: raisedUnder)

        #expect(engine.state == .idle)
        #expect(engine.errorInfo == nil)
        #expect(events.isEmpty)
        #expect(!engine.softwarePathEscalationBudget.isSpent)
    }

    /// Vcore-102: `@Published` replays its value on subscribe, and the next load subscribes before the
    /// fresh item's attach clears it, so a reused host handed the previous item's rejection to the
    /// successor's fallback. `-1002` is how AVFoundation fails an item whose URL it cannot load, and a
    /// master rejection code at startup.
    @Test("A torn-down host replays no master rejection to the next load's subscriber")
    func tearDownDropsTheRejection() async throws {
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        host.load(url: try #require(URL(string: "aether-unloadable://origin/master.m3u8")),
                  startPosition: nil, contract: .init())
        try await waitFor { host.pendingDisplayRejection != nil }

        host.tearDown()
        var replayed = 0
        let sub = host.$pendingDisplayRejection.compactMap { $0 }.sink { _ in replayed += 1 }
        defer { sub.cancel() }

        #expect(replayed == 0)
        #expect(host.pendingSoftwarePathEscalation == nil)
    }

    /// Vcore-101: the HLS session's callbacks captured only the engine, so a late emitter of a
    /// session that had ended wrote its reader stall and its scrub state into the next one.
    @Test("A stale session's network phase and scrub state leave the successor alone")
    func staleSessionCallbacksAreDropped() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(source: Self.customSource())
        let ended = try #require(engine.nativeVideoSession)
        let networkPhase = try #require(ended.onNetworkPhaseChanged)
        let seekState = try #require(ended.onSeekStateChanged)

        _ = try await engine.load(source: Self.customSource())
        #expect(engine.nativeVideoSession !== ended)
        networkPhase(.exhausted)
        seekState(true, 3)

        let touched = try await waitFor(upTo: .milliseconds(300)) {
            if case .stalled = engine.playbackPhase { return true }
            return engine.isSeeking
        }
        #expect(!touched)
    }
}
