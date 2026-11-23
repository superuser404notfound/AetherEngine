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

    private func makeEngine(optedIn: Bool) throws -> (AetherEngine, ProbeTestBox<[String]>) {
        let engine = try AetherEngine()
        engine.nativeAudioSessionActivationEnabled = optedIn
        let journal = ProbeTestBox<[String]>([])
        engine.nativeAudioActivationForTesting = { [weak engine] in
            let host = engine?.nativeHost
            journal.update {
                $0.append("activation host=\(host != nil) "
                          + "playIntent=\(host?.transportIntentIsPlaying ?? false) "
                          + "gate=\(engine?.isAwaitingDisplaySwitch ?? false)")
            }
        }
        return (engine, journal)
    }

    private func load(_ engine: AetherEngine, autoplay: Bool) async throws {
        _ = try await engine.load(
            source: .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4"),
            options: LoadOptions(autoplay: autoplay))
    }

    @Test("An autostarting load activates once, after the gate, before it plays")
    func autostartActivatesAfterGate() async throws {
        let (engine, journal) = try makeEngine(optedIn: true)
        defer { engine.stop() }
        try await load(engine, autoplay: true)

        #expect(engine.playbackBackend == .native)
        #expect(journal.value == ["activation host=true playIntent=false gate=false"])
        #expect(engine.nativeHost?.transportIntentIsPlaying == true)
    }

    @Test("A paused mount still activates, so a later play() finds an active session")
    func pausedMountActivatesAfterGate() async throws {
        let (engine, journal) = try makeEngine(optedIn: true)
        defer { engine.stop() }
        try await load(engine, autoplay: false)

        #expect(journal.value == ["activation host=true playIntent=false gate=false"])
        #expect(engine.nativeHost?.transportIntentIsPlaying == false)
    }

    @Test("An in-place reload activates again after its own gate")
    func reloadActivatesAfterGate() async throws {
        let (engine, journal) = try makeEngine(optedIn: true)
        defer { engine.stop() }
        try await load(engine, autoplay: true)
        let host = try #require(engine.nativeHost)

        try await engine.reloadAtCurrentPosition()

        #expect(engine.nativeHost === host)
        #expect(journal.value.count == 2)
        #expect(journal.value.last?.hasSuffix("gate=false") == true)
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
