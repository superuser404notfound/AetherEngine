import Testing
@testable import AetherEngine

/// Pure derivation of the unified playback phase (#85). Covers the full precedence truth table:
/// error > ended > idle > loading > seeking > stalled > rebuffering > playing/paused.
@Suite("PlaybackPhase.derive (#85)")
struct PlaybackPhaseDeriveTests {

    @Test("error beats every other signal")
    func errorWins() {
        #expect(PlaybackPhase.derive(state: .error("boom"), isBuffering: true, isSeeking: true, stall: .reconnecting) == .error("boom"))
    }

    @Test("ended beats idle/loading/playing signals")
    func endedWins() {
        #expect(PlaybackPhase.derive(state: .ended, isBuffering: true, isSeeking: true, stall: .reconnecting) == .ended)
    }

    @Test("idle maps straight through")
    func idlePassThrough() {
        #expect(PlaybackPhase.derive(state: .idle, isBuffering: false, isSeeking: false, stall: .flowing) == .idle)
    }

    @Test("loading outranks a reconnect happening underneath startup")
    func loadingOutranksStall() {
        #expect(PlaybackPhase.derive(state: .loading, isBuffering: false, isSeeking: false, stall: .reconnecting) == .loading)
    }

    @Test("a user seek outranks stall and rebuffer")
    func seekingOutranksStallAndRebuffer() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: true, stall: .reconnecting) == .seeking)
    }

    @Test("state == .seeking but isSeeking already cleared reads as playing")
    func optimisticSeekStateWithoutInFlightIsPlaying() {
        #expect(PlaybackPhase.derive(state: .seeking, isBuffering: false, isSeeking: false, stall: .flowing) == .playing)
    }

    @Test("reconnect outranks a plain rebuffer")
    func stallOutranksRebuffer() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false, stall: .reconnecting) == .stalled(reconnecting: true))
    }

    @Test("rebuffer when only the buffer underran, connection healthy")
    func rebufferWhenOnlyBuffering() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false, stall: .flowing) == .rebuffering)
    }

    @Test("clean playing")
    func playing() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: false, isSeeking: false, stall: .flowing) == .playing)
    }

    @Test("paused is preserved when nothing else is in flight")
    func paused() {
        #expect(PlaybackPhase.derive(state: .paused, isBuffering: false, isSeeking: false, stall: .flowing) == .paused)
    }

    @Test("paused while reconnecting still reports the stall")
    func pausedWhileStalled() {
        #expect(PlaybackPhase.derive(state: .paused, isBuffering: false, isSeeking: false, stall: .reconnecting) == .stalled(reconnecting: true))
    }
}

/// Engine-level wiring of #85: the published phase tracks the four inputs and only re-emits on change.
@Suite("AetherEngine.playbackPhase wiring (#85)")
@MainActor
struct PlaybackPhaseEngineTests {

    @Test("phase starts idle and follows state/buffer/stall/seek transitions")
    func followsInputs() throws {
        let engine = try AetherEngine()
        #expect(engine.playbackPhase == .idle)

        engine.state = .loading
        #expect(engine.playbackPhase == .loading)

        engine.state = .playing
        #expect(engine.playbackPhase == .playing)

        engine.isBuffering = true
        #expect(engine.playbackPhase == .rebuffering)

        engine.setReaderNetworkPhase(.reconnecting)
        #expect(engine.playbackPhase == .stalled(reconnecting: true))   // stall outranks rebuffer

        engine.isSeeking = true
        #expect(engine.playbackPhase == .seeking)                       // seek outranks stall

        engine.isSeeking = false
        engine.setReaderNetworkPhase(.flowing)
        engine.isBuffering = false
        #expect(engine.playbackPhase == .playing)
    }

    @Test("setReaderNetworkPhase clears back to a non-stalled phase")
    func stallClears() throws {
        let engine = try AetherEngine()
        engine.state = .playing
        engine.setReaderNetworkPhase(.reconnecting)
        #expect(engine.playbackPhase == .stalled(reconnecting: true))
        engine.setReaderNetworkPhase(.flowing)
        #expect(engine.playbackPhase == .playing)
    }
}
