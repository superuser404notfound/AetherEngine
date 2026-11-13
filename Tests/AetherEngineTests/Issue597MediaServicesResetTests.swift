import Foundation
import Testing
@testable import AetherEngine

/// AE#597: when mediaserverd resets or is lost, every audio and video object the process holds is
/// invalid and has to be rebuilt. The engine keeps its `AVPlayer` across a load on purpose
/// (Sodalite#149: a preserved host keeps the Now Playing registration alive), which after a reset
/// means reusing the one object the platform has already invalidated, on every recovery rung.
///
/// The rule this pins is the narrow one: a reset outranks every reason to keep the host.
@Suite("A media services reset outranks host preservation (#597)")
struct Issue597MediaServicesResetTests {

    @Test("without a reset the preservation rule is unchanged")
    func preservationIsUnchangedWithoutAReset() {
        #expect(AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .native, nativeHostSurvives: false, mediaServicesWereReset: false))
        #expect(AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .software, nativeHostSurvives: true, mediaServicesWereReset: false))
        #expect(!AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .software, nativeHostSurvives: false, mediaServicesWereReset: false))
    }

    @Test("a reset forbids preserving the host whatever else argues for it")
    func resetForbidsPreservation() {
        #expect(!AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .native, nativeHostSurvives: true, mediaServicesWereReset: true))
        #expect(!AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .native, nativeHostSurvives: false, mediaServicesWereReset: true))
        #expect(!AetherEngine.shouldPreserveNativeHostAcrossLoad(
            backend: .software, nativeHostSurvives: true, mediaServicesWereReset: true))
    }

    private static let missingSource = URL(fileURLWithPath: "/nonexistent/aether-597-reset.m4a")

    /// Audit CORE-4: the audio-only host is kept across every teardown so its Now Playing session
    /// persists between tracks, and the reset only ever dropped the video host. Music after a reset
    /// went to the dead AVPlayer, and the first load of any kind cleared the flag.
    @Test("the load that consumes a reset drops the audio-only player too")
    @MainActor
    func resetDropsTheAudioOnlyPlayer() async throws {
        let engine = try AetherEngine()
        engine.audioAVPlayerHost = AudioAVPlayerHost()
        engine.noteMediaServicesReset(lost: false)

        _ = try? await engine.load(url: Self.missingSource)

        #expect(engine.audioAVPlayerHost == nil)
        #expect(!engine.consumeMediaServicesReset())
    }

    /// PR #740: the Atmos output activator holds an `AVQueuePlayer` of its own, which a reset invalidates
    /// like the engine's, so the reset drops it and the next native player builds a fresh one.
    @Test("a reset drops the Atmos output activator with its invalidated player")
    @MainActor
    func resetDropsTheAtmosOutputActivator() throws {
        let engine = try AetherEngine()
        engine.atmosOutputActivator = AtmosOutputActivator()

        engine.noteMediaServicesReset(lost: false)

        #expect(engine.atmosOutputActivator == nil)
    }

    /// Audit LIF-104: `reloadWithAudioOverride` (the audio pick, the disc-title pick, the custom-source
    /// reload) keeps the native host on the native route, and it never read the flag, so the first
    /// rebuild after a reset mounted the item on the invalidated AVPlayer while the flag stayed up.
    @Test("a custom-source rebuild after a reset builds a fresh native player and consumes the reset",
          .timeLimit(.minutes(3)))
    @MainActor
    func customRebuildConsumesTheReset() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(
            source: .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4"))
        let invalidated = try #require(engine.nativeHost)
        engine.audioAVPlayerHost = AudioAVPlayerHost()
        engine.noteMediaServicesReset(lost: false)

        try await engine.reloadAtCurrentPosition()

        #expect(engine.nativeHost != nil)
        #expect(engine.nativeHost !== invalidated)
        #expect(engine.audioAVPlayerHost == nil)
        #expect(!engine.consumeMediaServicesReset())
    }

    @Test("without a reset a custom-source rebuild keeps its native player (issue #15)",
          .timeLimit(.minutes(3)))
    @MainActor
    func customRebuildKeepsTheHostWithoutAReset() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(
            source: .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4"))
        let host = try #require(engine.nativeHost)

        try await engine.reloadAtCurrentPosition()

        #expect(engine.nativeHost === host)
    }

    @Test("without a reset the audio-only player survives a load, as its Now Playing session must")
    @MainActor
    func audioOnlyPlayerSurvivesWithoutAReset() async throws {
        let engine = try AetherEngine()
        let host = AudioAVPlayerHost()
        engine.audioAVPlayerHost = host

        _ = try? await engine.load(url: Self.missingSource)

        #expect(engine.audioAVPlayerHost === host)
    }
}
