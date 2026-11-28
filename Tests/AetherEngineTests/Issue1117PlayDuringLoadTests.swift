import Combine
import Foundation
import Testing
@testable import AetherEngine

/// AE#1117 round 3 (en0x): a host `play()` while a fresh `load()` was running reached the transport
/// and wrote `.playing` at once. Measured on the harness that was 30 ms into the load, 2 s before
/// the first frame and before AVPlayer had an item, so a host spinner fell early, and on a mounted
/// host the press started AVPlayer ahead of the play gate. The press is now held, and only the
/// load's exit acts on it: an autostart needs nothing, a paused mount gets the play there, and a
/// `pause()` or a second toggle withdraws it.
@Suite("AE#1117: a play() during the load waits for the load's own start", .timeLimit(.minutes(3)))
@MainActor
struct Issue1117PlayDuringLoadTests {

    private static func customSource() throws -> MediaSource {
        .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4")
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition())
    }

    /// Runs `body` once, on the first `.loading` the load publishes, and records the state it left.
    /// Fails if the press ran after load() returned, so a fast fixture cannot pass it vacuously.
    private func duringLoad(
        of engine: AetherEngine, _ body: @escaping @MainActor () -> Void,
        load: () async throws -> Void
    ) async throws -> PlaybackState? {
        var fired = false
        var pressedInFlight = false
        var stateAfterPress: PlaybackState?
        let observer = engine.$state.sink { next in
            MainActor.assumeIsolated {
                guard !fired, next == .loading else { return }
                fired = true
                // The sink runs inside the didSet; the press goes out right after it, while the
                // load is still suspended in its open.
                Task { @MainActor in
                    pressedInFlight = engine.loadInFlight
                    body()
                    stateAfterPress = engine.state
                }
            }
        }
        defer { observer.cancel() }
        try await load()
        #expect(fired)
        #expect(pressedInFlight)
        return stateAfterPress
    }

    @Test("the policy: only a fresh load in flight, in .loading or .paused, holds the press")
    func policy() {
        #expect(AetherEngine.playWaitsForLoad(state: .loading, loadInFlight: true, sessionPreservingReload: false))
        #expect(AetherEngine.playWaitsForLoad(state: .paused, loadInFlight: true, sessionPreservingReload: false))
        #expect(!AetherEngine.playWaitsForLoad(state: .playing, loadInFlight: true, sessionPreservingReload: false))
        #expect(!AetherEngine.playWaitsForLoad(state: .seeking, loadInFlight: true, sessionPreservingReload: false))
        // After load() returned, `.loading` can still be the remote HLS bypass waiting for its roll,
        // whose host already has the play; a press there goes through as before.
        #expect(!AetherEngine.playWaitsForLoad(state: .loading, loadInFlight: false, sessionPreservingReload: false))
        // A rebuild parks the press through recordTransportDuringRebuild (AE#464).
        #expect(!AetherEngine.playWaitsForLoad(state: .loading, loadInFlight: true, sessionPreservingReload: true))
    }

    @Test("the exit owes the press only to a paused mount that has not started")
    func exitPolicy() {
        #expect(AetherEngine.heldPlayIsOwedAtLoadExit(autostarted: false, state: .paused))
        // The remote HLS bypass returns before readiness.
        #expect(AetherEngine.heldPlayIsOwedAtLoadExit(autostarted: false, state: .loading))
        #expect(!AetherEngine.heldPlayIsOwedAtLoadExit(autostarted: false, state: .playing))
        #expect(!AetherEngine.heldPlayIsOwedAtLoadExit(autostarted: false, state: .error("x")))
        #expect(!AetherEngine.heldPlayIsOwedAtLoadExit(autostarted: true, state: .paused))
        #expect(!AetherEngine.heldPlayIsOwedAtLoadExit(autostarted: true, state: .loading))
    }

    @Test("a play() during an autostarting load leaves it .loading and it still starts")
    func pressDuringAutostartHoldsLoading() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let after = try await duringLoad(of: engine, { engine.play() }) {
            _ = try await engine.load(source: Self.customSource())
        }
        #expect(after == .loading)
        #expect(engine.state == .playing)
        #expect(!engine.playRequestedDuringLoad)
    }

    @Test("a play() during a paused mount starts the session")
    func pressDuringPausedMountStarts() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let after = try await duringLoad(of: engine, { engine.play() }) {
            _ = try await engine.load(source: Self.customSource(), options: LoadOptions(autoplay: false))
        }
        #expect(after == .loading)
        try await waitFor { engine.state == .playing }
        #expect(engine.nativeHost?.transportIntentIsPlaying == true)
        #expect(!engine.playRequestedDuringLoad)
    }

    @Test("a pause() after that play() keeps the paused mount paused")
    func pauseWithdrawsThePress() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await duringLoad(of: engine, { engine.play(); engine.pause() }) {
            _ = try await engine.load(source: Self.customSource(), options: LoadOptions(autoplay: false))
        }
        try await waitFor { engine.state == .paused }
        #expect(engine.nativeHost?.transportIntentIsPlaying == false)
    }

    @Test("a second toggle during the load takes the first one back")
    func secondToggleWithdraws() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await duringLoad(of: engine, { engine.togglePlayPause(); engine.togglePlayPause() }) {
            _ = try await engine.load(source: Self.customSource(), options: LoadOptions(autoplay: false))
        }
        try await waitFor { engine.state == .paused }
        #expect(engine.nativeHost?.transportIntentIsPlaying == false)
    }

    @Test("a paused mount that ended paused gets the press at its exit")
    func exitGivesThePress() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(autoplay: false))
        let generation = engine.loadGeneration
        engine.beginLoadInFlight(generation)
        engine.state = .paused
        engine.play()
        #expect(engine.playRequestedDuringLoad)
        #expect(engine.state == .paused)
        engine.endLoadInFlight(generation)
        #expect(!engine.playRequestedDuringLoad)
        #expect(engine.state == .playing)
    }

    @Test("an autostarting load gets nothing extra at its exit")
    func exitLeavesAnAutostartAlone() throws {
        let engine = try AetherEngine()
        let generation = engine.loadGeneration
        engine.beginLoadInFlight(generation)
        engine.state = .loading
        engine.play()
        engine.state = .playing
        engine.endLoadInFlight(generation)
        #expect(!engine.playRequestedDuringLoad)
        #expect(engine.state == .playing)
    }

    @Test("stop() drops a held press")
    func stopDropsThePress() throws {
        let engine = try AetherEngine()
        engine.beginLoadInFlight(engine.loadGeneration)
        engine.state = .loading
        engine.play()
        #expect(engine.playRequestedDuringLoad)
        engine.stop()
        #expect(!engine.playRequestedDuringLoad)
    }
}
