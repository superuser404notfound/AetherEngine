import Testing
@testable import AetherEngine

/// F3: a renderer path pauses when the route it was playing to is removed, as AVPlayer does. The
/// notification exists on iOS and tvOS only; the tests drive the decision and the reaction directly.
@Suite("F3: pause on audio route removal")
@MainActor
struct RouteRemovalPauseTests {

    private func engine(software: Bool = true, state: PlaybackState = .playing) throws -> AetherEngine {
        let engine = try AetherEngine()
        if software { engine.softwareHost = SoftwarePlaybackHost(videoGravity: .resizeAspect) }
        engine.state = state
        return engine
    }

    @Test("decision: only old-device-unavailable of an external output pauses")
    func decision() {
        let removed = AetherEngine.routeChangeReasonOldDeviceUnavailableRaw
        #expect(AetherEngine.routeRemovalShouldPause(reasonRaw: removed, previousOutputsWereExternal: true))
        #expect(!AetherEngine.routeRemovalShouldPause(reasonRaw: removed, previousOutputsWereExternal: false))
        #expect(!AetherEngine.routeRemovalShouldPause(reasonRaw: 1, previousOutputsWereExternal: true))   // newDeviceAvailable
        #expect(!AetherEngine.routeRemovalShouldPause(reasonRaw: 3, previousOutputsWereExternal: true))   // categoryChange
        #expect(!AetherEngine.routeRemovalShouldPause(reasonRaw: nil, previousOutputsWereExternal: true))
    }

    @Test("a playing software session pauses")
    func pausesWhilePlaying() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.noteOutputRouteRemoved()
        #expect(engine.state == .paused)
    }

    @Test("a paused session stays paused and a loading one is left alone")
    func otherStatesUntouched() throws {
        for state in [PlaybackState.paused, .loading, .idle] {
            let engine = try engine(state: state)
            engine.isBuffering = true
            engine.noteOutputRouteRemoved()
            #expect(engine.isBuffering, "pause() must not have run")
            #expect(engine.state == state)
            engine.stop()
        }
    }

    @Test("the native path is left to AVPlayer")
    func nativeUntouched() throws {
        let engine = try engine(software: false)
        defer { engine.stop() }
        engine.noteOutputRouteRemoved()
        #expect(engine.state == .playing)
    }

    @Test("a route removal during a seek still pauses")
    func pausesDuringSeek() throws {
        let engine = try engine(state: .seeking)
        defer { engine.stop() }
        engine.isBuffering = true
        engine.noteOutputRouteRemoved()
        #expect(!engine.isBuffering, "pause() ran: it clears the buffering flag")
    }
}
