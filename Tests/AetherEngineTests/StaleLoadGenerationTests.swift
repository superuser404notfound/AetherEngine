import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// A load that a stop() or a newer load() superseded while it was suspended must unwind without
/// touching the engine: the state it would write belongs to its successor.
@Suite("Superseded loads unwind without touching the successor")
@MainActor
struct StaleLoadGenerationTests {

    /// Audit CORE-6: the remote-HLS bypass read `loadGeneration` itself, after load()'s first
    /// suspension. A stale load resuming there adopted its successor's generation, so every later
    /// guard in the bypass passed, and it mounted its own URL on the shared native host.
    @Test("The remote-HLS bypass refuses a generation that has moved")
    func bypassRefusesStaleGeneration() async throws {
        let engine = try AetherEngine()
        let stale = engine.loadGeneration
        engine.stop()

        await #expect(throws: CancellationError.self) {
            try await engine.loadRemoteHLS(
                url: URL(string: "http://127.0.0.1:9/vod.m3u8")!,
                options: LoadOptions(nativeRemoteHLS: true),
                generation: stale)
        }
        #expect(engine.nativeHost == nil)
        #expect(engine.playbackBackend == .none)
    }

    /// Audit LOAD-201: with a text sidecar declared, the bypass fetches the master for its stand-in
    /// before it mounts anything. A load that a stop() superseded during that fetch used to go on and
    /// mount its URL on the host the stop() had just torn down, and play it: sound with no player.
    @Test("A remote-HLS load stopped during its stand-in fetch mounts nothing", .timeLimit(.minutes(3)))
    func standInFetchThenStopMountsNothing() async throws {
        let origin = try #require(HeldHTTPOrigin())
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        // The origin holds every request until release(), so the stand-in's 5 s budget is the only
        // clock left. On a loaded runner it ran out before stop() and the load mounted the origin.
        engine.remoteHLSStandInBudgetSeconds = 600

        let stale = Task { @MainActor in
            try await engine.load(url: origin.url("/stopped/master.m3u8"),
                                  options: Self.bypassWithSidecar(origin))
        }
        // The stand-in's master fetch, not the sidecar's: everything is held, so the sidecar stays
        // pending and the stand-in runs, and nothing but the stand-in asks for the master first.
        try await waitFor { origin.heldRequests(for: "/stopped/master.m3u8") > 0 }
        let host = try #require(engine.nativeHost)
        engine.stop()
        origin.release()

        await #expect(throws: CancellationError.self) { try await stale.value }
        #expect(host.avPlayer.currentItem == nil)
        #expect(host.avPlayer.rate == 0)
        #expect(engine.nativeHost == nil)
        #expect(engine.state == .idle)
    }

    /// Audit LOAD-201: the same fetch outlived by a zap. The native host survives a native-to-native
    /// load, so the stale load mounted its own URL over the successor's item on the shared player.
    @Test("A remote-HLS load superseded during its stand-in fetch leaves the successor's item alone",
          .timeLimit(.minutes(3)))
    func standInFetchThenZapLeavesSuccessor() async throws {
        let origin = try #require(HeldHTTPOrigin())
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        // The origin holds every request until release(), so the stand-in's 5 s budget is the only
        // clock left. On a loaded runner it ran out before stop() and the load mounted the origin.
        engine.remoteHLSStandInBudgetSeconds = 600

        let stale = Task { @MainActor in
            try await engine.load(url: origin.url("/zapped/master.m3u8"),
                                  options: Self.bypassWithSidecar(origin))
        }
        try await waitFor { origin.heldRequests(for: "/zapped/master.m3u8") > 0 }
        let successorURL = URL(string: "http://127.0.0.1:9/successor.m3u8")!
        _ = try await engine.load(url: successorURL, options: LoadOptions(nativeRemoteHLS: true))
        origin.release()

        await #expect(throws: CancellationError.self) { try await stale.value }
        let mounted = engine.nativeHost?.avPlayer.currentItem?.asset as? AVURLAsset
        #expect(mounted?.url == successorURL)
    }

    private static func bypassWithSidecar(_ origin: HeldHTTPOrigin) -> LoadOptions {
        LoadOptions(nativeRemoteHLS: true,
                    externalSubtitles: [ExternalSubtitleTrack(url: origin.url("/en.srt"),
                                                              name: "English", language: "en")])
    }
}
