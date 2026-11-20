import Foundation
import Testing
@testable import AetherEngine

/// AE#1099: a fresh software load activated its renderer audio session before it built the host, while
/// the panel could still be switching modes for that load, and the HDMI audio link negotiated mid-switch.
/// The activation now runs after the play gate and before the host's first play() or paused mount. The
/// session cannot be driven on macOS, so the test hook marks where the activation is asked for.
@Suite("Issue 1099: a software load activates its audio session after the play gate",
       .serialized, .timeLimit(.minutes(3)))
@MainActor
struct Issue1099SoftwareAudioAfterPlayGateTests {

    private func load(autoplay: Bool) async throws -> (AetherEngine, [String]) {
        let engine = try AetherEngine()
        let journal = ProbeTestBox<[String]>([])
        engine.softwareHostLoadedForTesting = { _ in journal.update { $0.append("host loaded") } }
        engine.rendererAudioActivationForTesting = { [weak engine] in
            let host = engine?.softwareHost
            journal.update {
                $0.append("activation host=\(host != nil) playing=\(host?.isPlaying ?? false) "
                          + "loops=\(host?.loopsStartedForTesting ?? false) "
                          + "gate=\(engine?.isAwaitingDisplaySwitch ?? false)")
            }
        }
        try await engine.load(
            source: .custom(ProbeRecordingReader(data: try LongGOPTransportStreamFixture.data()),
                            formatHint: "mpegts"),
            options: LoadOptions(isLive: true, autoplay: autoplay, preferredDecodePath: .software)
        )
        return (engine, journal.value)
    }

    @Test("An autostarting load activates once, after the host build and the gate, before it plays")
    func autostartActivatesAfterGate() async throws {
        let (engine, journal) = try await load(autoplay: true)
        defer { engine.stop() }

        #expect(journal == ["host loaded", "activation host=true playing=false loops=false gate=false"])
        #expect(engine.softwareHost?.isPlaying == true)
    }

    @Test("A paused mount still activates, so a later play() finds an active session")
    func pausedMountActivatesAfterGate() async throws {
        let (engine, journal) = try await load(autoplay: false)
        defer { engine.stop() }

        #expect(journal == ["host loaded", "activation host=true playing=false loops=false gate=false"])
        #expect(engine.softwareHost?.isPlaying == false)
        #expect(engine.softwareHost?.loopsStartedForTesting == true)
    }

    @Test("A host that owns the session sees no activation from the engine")
    func hostOwnedSessionIsLeftAlone() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.rendererAudioSessionActivationEnabled = false
        var activations = 0
        engine.rendererAudioActivationForTesting = { activations += 1 }

        try await engine.load(
            source: .custom(ProbeRecordingReader(data: try LongGOPTransportStreamFixture.data()),
                            formatHint: "mpegts"),
            options: LoadOptions(isLive: true, autoplay: true, preferredDecodePath: .software)
        )

        #expect(engine.softwareHost != nil)
        #expect(activations == 0)
    }
}
