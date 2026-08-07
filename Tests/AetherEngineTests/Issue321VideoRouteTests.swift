import Combine
import Testing
@testable import AetherEngine

/// Pure derivation of the effective video route (#321). `LoadOptions.nativeRemoteHLS` records the
/// request; the route records what actually ended up serving the session after the internal reroutes
/// (#168 carriage watchdog, #199 remembered verdict, AE#268 carriage probe, AE#154 / AE#246).
@Suite("VideoRoute.derive (#321)")
struct VideoRouteDeriveTests {

    @Test("no backend means no route, whatever the request asked for")
    func noBackendHasNoRoute() {
        #expect(VideoRoute.derive(backend: .none, nativeRemoteHLS: false) == VideoRoute.none)
        #expect(VideoRoute.derive(backend: .none, nativeRemoteHLS: true) == VideoRoute.none)
    }

    @Test("a native backend splits on the remote-HLS bit, which is the whole point")
    func nativeSplitsOnRemoteHLS() {
        #expect(VideoRoute.derive(backend: .native, nativeRemoteHLS: true) == .remoteBypass)
        #expect(VideoRoute.derive(backend: .native, nativeRemoteHLS: false) == .loopback)
    }

    @Test("the software path is a route of its own, the request bit cannot reach it")
    func softwareIgnoresRequest() {
        #expect(VideoRoute.derive(backend: .software, nativeRemoteHLS: false) == .software)
        #expect(VideoRoute.derive(backend: .software, nativeRemoteHLS: true) == .software)
    }

    @Test("an audio-only session reports no video route")
    func audioIgnoresRequest() {
        #expect(VideoRoute.derive(backend: .audio, nativeRemoteHLS: false) == .audio)
        #expect(VideoRoute.derive(backend: .audio, nativeRemoteHLS: true) == .audio)
    }

    @Test("the retired .aether backend carries no route")
    func retiredBackendHasNoRoute() {
        #expect(VideoRoute.derive(backend: .aether, nativeRemoteHLS: false) == VideoRoute.none)
    }
}

/// Engine-level wiring: the published route is derived from `playbackBackend` + `loadedOptions`, the
/// two properties every reroute site already writes, so it cannot drift away from the running session.
@Suite("AetherEngine.videoRoute wiring (#321)")
@MainActor
struct VideoRouteEngineTests {

    @Test("a declared bypass is not a route until a backend exists")
    func requestAloneIsNotARoute() throws {
        let engine = try AetherEngine()
        #expect(engine.videoRoute == VideoRoute.none)

        engine.setLoadedOptionsForTesting(LoadOptions(nativeRemoteHLS: true))
        #expect(engine.videoRoute == VideoRoute.none)

        engine.playbackBackend = .native
        #expect(engine.videoRoute == .remoteBypass)
    }

    /// The #168 watchdog and the #199 remembered verdict both take a declared bypass onto the
    /// live-ingest loopback by clearing the bit on the options the session actually runs with.
    @Test("clearing the bit mid-session republishes the loopback route")
    func rerouteOntoLoopbackRepublishes() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(nativeRemoteHLS: true))
        engine.playbackBackend = .native
        #expect(engine.videoRoute == .remoteBypass)

        engine.setLoadedOptionsForTesting(LoadOptions(nativeRemoteHLS: false))
        #expect(engine.videoRoute == .loopback)
    }

    /// AE#154 / AE#246 run the other direction: a playlist that reached the loopback is handed to the
    /// bypass, and `loadedOptions.nativeRemoteHLS` flips to true underneath the same native backend.
    @Test("setting the bit mid-session republishes the bypass route")
    func rerouteOntoBypassRepublishes() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(nativeRemoteHLS: false))
        engine.playbackBackend = .native
        #expect(engine.videoRoute == .loopback)

        engine.setLoadedOptionsForTesting(LoadOptions(nativeRemoteHLS: true))
        #expect(engine.videoRoute == .remoteBypass)
    }

    @Test("a software dispatch reports the software route even with the bit still set")
    func softwareDispatch() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(nativeRemoteHLS: true))
        engine.playbackBackend = .software
        #expect(engine.videoRoute == .software)
    }

    @Test("teardown drops the route back to none")
    func teardownClearsRoute() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(nativeRemoteHLS: true))
        engine.playbackBackend = .native
        #expect(engine.videoRoute == .remoteBypass)

        engine.playbackBackend = .none      // what stopInternal() writes
        #expect(engine.videoRoute == VideoRoute.none)
    }

    @Test("an options write that leaves the route alone does not re-emit")
    func unchangedRouteDoesNotReemit() throws {
        let engine = try AetherEngine()
        var seen: [VideoRoute] = []
        let sub = engine.$videoRoute.sink { seen.append($0) }
        defer { sub.cancel() }

        engine.playbackBackend = .native                                    // -> .loopback
        engine.setLoadedOptionsForTesting(LoadOptions(isLive: true))        // still .loopback
        engine.setLoadedOptionsForTesting(LoadOptions(dvrWindowSeconds: 90))// still .loopback

        #expect(seen == [VideoRoute.none, .loopback])
    }
}
