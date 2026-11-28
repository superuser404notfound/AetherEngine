import Combine
import Foundation
import Testing
@testable import AetherEngine

/// AE#1117 round 3 (en0x): a host `play()` while a fresh `load()` was running reached the transport
/// and wrote `.playing` at once. Measured on the harness that was 30 ms into the load, 2 s before
/// the first frame and before AVPlayer had an item, so a host spinner fell early, and on a mounted
/// host the press started AVPlayer ahead of the play gate. The press now waits for the load's own
/// start, a paused mount the host pressed Play on starts there, and a `pause()` withdraws it.
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
    private func duringLoad(
        of engine: AetherEngine, _ body: @escaping @MainActor () -> Void,
        load: () async throws -> Void
    ) async throws -> PlaybackState? {
        var fired = false
        var stateAfterPress: PlaybackState?
        let observer = engine.$state.sink { next in
            MainActor.assumeIsolated {
                guard !fired, next == .loading else { return }
                fired = true
                // The sink runs inside the didSet; the press goes out right after it, while the
                // load is still suspended in its open.
                Task { @MainActor in
                    body()
                    stateAfterPress = engine.state
                }
            }
        }
        defer { observer.cancel() }
        try await load()
        #expect(fired)
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

    @Test("a held press turns a paused mount into an autostart")
    func autostartPolicy() {
        #expect(AetherEngine.loadPerformsAutostart(LoadOptions(autoplay: false), playRequestedDuringLoad: true))
        #expect(!AetherEngine.loadPerformsAutostart(LoadOptions(autoplay: false), playRequestedDuringLoad: false))
        #expect(AetherEngine.loadPerformsAutostart(LoadOptions(autoplay: true), playRequestedDuringLoad: false))
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

    @Test("a press that came after the load's own start is given at its exit")
    func exitGivesALatePress() throws {
        let engine = try AetherEngine()
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

    @Test("a load that ended playing gets nothing extra at its exit")
    func exitLeavesAStartedLoadAlone() throws {
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

    private final class HostFixture: ObservableObject {
        @Published var duration: Double = 0
        @Published var isReady = false
        @Published var failure: PlaybackErrorInfo?
        @Published var didReachEnd = false
    }

    @Test("readiness of a paused mount with a held press keeps .loading (no pause flash, AE#1000)")
    func readinessHoldsLoadingForAHeldPress() throws {
        let engine = try AetherEngine()
        let host = HostFixture()
        engine.state = .loading
        engine.playRequestedDuringLoad = true
        var cancellables = Set<AnyCancellable>()
        engine.wireCommonHostSinks(
            duration: host.$duration, isReady: host.$isReady,
            settlePausedAtReadiness: AetherEngine.readinessSettlesPaused(autostarts: false),
            failure: host.$failure, didReachEnd: host.$didReachEnd, storeIn: &cancellables)
        host.isReady = true
        #expect(engine.state == .loading)
        withExtendedLifetime(cancellables) {}
    }
}
