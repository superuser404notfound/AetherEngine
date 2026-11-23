import Combine
import Foundation
import Testing
@testable import AetherEngine

/// AE#1110: a host on the bare player layer has no AVKit view to activate the audio session at play(),
/// and no moment of its own between the display mode switch and the engine's play(). With
/// `nativeAudioSessionActivationEnabled` the engine activates there, as the software path does since
/// AE#1099. The session cannot be driven on macOS, so the test hook marks where the activation is asked for.
@Suite("Issue 1110: an opted-in native load activates its audio session after the play gate",
       .serialized, .timeLimit(.minutes(3)))
@MainActor
struct Issue1110NativeAudioAfterPlayGateTests {

    /// The gate's own publishes go into the journal too, so "after the gate" is checked, not assumed:
    /// on macOS no mode switch happens and the flag reads false on both sides of a gate that never waits.
    private func makeEngine(optedIn: Bool) throws
        -> (AetherEngine, ProbeTestBox<[String]>, AnyCancellable) {
        let engine = try AetherEngine()
        engine.nativeAudioSessionActivationEnabled = optedIn
        let journal = ProbeTestBox<[String]>([])
        let gate = engine.$isAwaitingDisplaySwitch.dropFirst().removeDuplicates().sink { waiting in
            journal.update { $0.append(waiting ? "gate entered" : "gate left") }
        }
        engine.nativeAudioActivationForTesting = { [weak engine] in
            let host = engine?.nativeHost
            journal.update {
                $0.append("activation host=\(host != nil) "
                          + "playIntent=\(host?.transportIntentIsPlaying ?? false) "
                          + "gate=\(engine?.isAwaitingDisplaySwitch ?? false)")
            }
        }
        return (engine, journal, gate)
    }

    private func load(_ engine: AetherEngine, autoplay: Bool) async throws {
        _ = try await engine.load(
            source: .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4"),
            options: LoadOptions(autoplay: autoplay))
    }

    @Test("An autostarting load activates once, after the gate, before it plays")
    func autostartActivatesAfterGate() async throws {
        let (engine, journal, gate) = try makeEngine(optedIn: true)
        defer { gate.cancel(); engine.stop() }
        try await load(engine, autoplay: true)

        #expect(engine.playbackBackend == .native)
        #expect(journal.value == ["gate entered", "gate left",
                                  "activation host=true playIntent=false gate=false"])
        #expect(engine.nativeHost?.transportIntentIsPlaying == true)
    }

    @Test("A paused mount still activates, so a later play() finds an active session")
    func pausedMountActivatesAfterGate() async throws {
        let (engine, journal, gate) = try makeEngine(optedIn: true)
        defer { gate.cancel(); engine.stop() }
        try await load(engine, autoplay: false)

        #expect(journal.value == ["gate entered", "gate left",
                                  "activation host=true playIntent=false gate=false"])
        #expect(engine.nativeHost?.transportIntentIsPlaying == false)
    }

    @Test("An in-place reload activates again after its own gate")
    func reloadActivatesAfterGate() async throws {
        let (engine, journal, gate) = try makeEngine(optedIn: true)
        defer { gate.cancel(); engine.stop() }
        try await load(engine, autoplay: true)
        let host = try #require(engine.nativeHost)

        try await engine.reloadAtCurrentPosition()

        #expect(engine.nativeHost === host)
        let activations = journal.value.filter { $0.hasPrefix("activation") }
        #expect(activations.count == 2)
        #expect(Array(journal.value.suffix(3)) == ["gate entered", "gate left",
                                                   "activation host=true playIntent=false gate=false"])
    }

    @Test("Off by default: an AVKit host keeps activating through its player view")
    func defaultLeavesTheSessionToAVKit() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        #expect(engine.nativeAudioSessionActivationEnabled == false)
        var activations = 0
        engine.nativeAudioActivationForTesting = { activations += 1 }

        try await load(engine, autoplay: true)
        try await engine.reloadAtCurrentPosition()

        #expect(engine.playbackBackend == .native)
        #expect(activations == 0)
    }
}
