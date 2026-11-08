import Testing
import Combine
@testable import AetherEngine

/// AE#1000: an autostarting native or software load published `.paused` at item readiness and held
/// it across the post-load play gate (a display switch, about 2.3 s on the report), so a host's pause
/// UI flashed on every start that switched the TV's mode. Readiness settles `.paused` only for a
/// paused mount now, and `isAwaitingDisplaySwitch` says the gate is waiting for the panel.
@Suite("Issue 1000: the play gate holds .loading")
@MainActor
struct Issue1000PlayGateHoldsLoadingTests {

    private final class HostFixture: ObservableObject {
        @Published var duration: Double = 0
        @Published var isReady = false
        @Published var failure: PlaybackErrorInfo?
        @Published var didReachEnd = false
    }

    private func wire(_ engine: AetherEngine, _ host: HostFixture, autostarts: Bool) -> Set<AnyCancellable> {
        var cancellables = Set<AnyCancellable>()
        engine.wireCommonHostSinks(
            duration: host.$duration,
            isReady: host.$isReady,
            settlePausedAtReadiness: AetherEngine.readinessSettlesPaused(autostarts: autostarts),
            failure: host.$failure,
            didReachEnd: host.$didReachEnd,
            storeIn: &cancellables
        )
        return cancellables
    }

    @Test("Only a paused mount settles .paused at readiness")
    func policy() {
        #expect(!AetherEngine.readinessSettlesPaused(autostarts: true))
        #expect(AetherEngine.readinessSettlesPaused(autostarts: false))
    }

    @Test("An autostarting load stays .loading when its item becomes ready")
    func autostartHoldsLoading() throws {
        let engine = try AetherEngine()
        let host = HostFixture()
        engine.state = .loading
        let cancellables = wire(engine, host, autostarts: true)
        host.isReady = true
        #expect(engine.state == .loading)
        #expect(engine.isSessionReady)
        withExtendedLifetime(cancellables) {}
    }

    @Test("A paused mount still settles .loading -> .paused at readiness (#124)")
    func pausedMountSettles() throws {
        let engine = try AetherEngine()
        let host = HostFixture()
        engine.state = .loading
        let cancellables = wire(engine, host, autostarts: false)
        host.isReady = true
        #expect(engine.state == .paused)
        withExtendedLifetime(cancellables) {}
    }

    @Test("The flag is raised for exactly the length of the gate")
    func flagSpansGate() async throws {
        let engine = try AetherEngine()
        #expect(!engine.isAwaitingDisplaySwitch)
        var raisedInside = false
        await engine.awaitingDisplaySwitch(generation: 1) {
            raisedInside = engine.isAwaitingDisplaySwitch
        }
        #expect(raisedInside)
        #expect(!engine.isAwaitingDisplaySwitch)
    }

    @Test("A superseded gate returning late leaves its successor's flag up")
    func supersededGateDoesNotLower() async throws {
        let engine = try AetherEngine()
        let (firstRelease, firstContinuation) = AsyncStream<Void>.makeStream()
        let (secondRelease, secondContinuation) = AsyncStream<Void>.makeStream()

        let first = Task { @MainActor in
            await engine.awaitingDisplaySwitch(generation: 1) {
                for await _ in firstRelease { break }
            }
        }
        await Task.yield()
        let second = Task { @MainActor in
            await engine.awaitingDisplaySwitch(generation: 2) {
                for await _ in secondRelease { break }
            }
        }
        await Task.yield()

        firstContinuation.yield()
        await first.value
        #expect(engine.isAwaitingDisplaySwitch)

        secondContinuation.yield()
        await second.value
        #expect(!engine.isAwaitingDisplaySwitch)
    }

    @Test("A teardown lowers the flag")
    func teardownClears() async throws {
        let engine = try AetherEngine()
        let (release, continuation) = AsyncStream<Void>.makeStream()
        let gate = Task { @MainActor in
            await engine.awaitingDisplaySwitch(generation: 7) {
                for await _ in release { break }
            }
        }
        await Task.yield()
        #expect(engine.isAwaitingDisplaySwitch)
        engine.clearDisplaySwitchGate()
        #expect(!engine.isAwaitingDisplaySwitch)
        continuation.yield()
        await gate.value
        #expect(!engine.isAwaitingDisplaySwitch)
    }
}
