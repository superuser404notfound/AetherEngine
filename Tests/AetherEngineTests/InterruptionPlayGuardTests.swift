import Testing
@testable import AetherEngine

/// F5: a play press while an audio-session interruption is active must not restart audio on the
/// renderer paths. The notification itself only exists on iOS and tvOS, so the tests drive the same
/// entry points the observer calls.
@Suite("F5: play() during an audio interruption", .timeLimit(.minutes(3)))
@MainActor
struct InterruptionPlayGuardTests {

    private func engine(withSoftwareHost: Bool = true) throws -> AetherEngine {
        let engine = try AetherEngine()
        if withSoftwareHost { engine.softwareHost = SoftwarePlaybackHost(videoGravity: .resizeAspect) }
        engine.state = .paused
        return engine
    }

    @Test("decision: only a renderer path is held, and only while interrupted")
    func decision() {
        #expect(AetherEngine.interruptionHoldsTransport(interrupted: true, rendererPath: true))
        #expect(!AetherEngine.interruptionHoldsTransport(interrupted: true, rendererPath: false))
        #expect(!AetherEngine.interruptionHoldsTransport(interrupted: false, rendererPath: true))
    }

    @Test("play() with no interruption plays")
    func playsNormally() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.play()
        #expect(engine.state == .playing)
        #expect(!engine.playDeferredByInterruption)
    }

    @Test("play() during an interruption is held, state stays paused")
    func playHeld() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.noteAudioInterruptionBegan()
        engine.play()
        #expect(engine.state == .paused)
        #expect(engine.playDeferredByInterruption)
    }

    @Test("the held play is owed when the interruption ends, once")
    func ownedAtEnd() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.noteAudioInterruptionBegan()
        engine.play()
        #expect(engine.noteAudioInterruptionEnded())
        #expect(!engine.audioInterruptionActive)
        #expect(!engine.noteAudioInterruptionEnded())
        engine.play()
        #expect(engine.state == .playing, "the guard is gone once the interruption ended")
    }

    @Test("an interruption with no play press owes nothing")
    func nothingOwed() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.noteAudioInterruptionBegan()
        #expect(!engine.noteAudioInterruptionEnded())
    }

    @Test("a user pause() cancels the held play")
    func pauseCancels() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.noteAudioInterruptionBegan()
        engine.play()
        engine.pause()
        #expect(!engine.noteAudioInterruptionEnded())
    }

    @Test("setRate during an interruption is held: the host keeps its rate, no play press is marked")
    func setRateHeld() throws {
        let engine = try engine()
        defer { engine.stop() }
        let host = try #require(engine.softwareHost)
        engine.state = .playing
        let before = host.rate
        engine.noteAudioInterruptionBegan()
        engine.setRate(1.5)
        #expect(engine.desiredRate == 1.5)
        #expect(host.rate == before, "the speed must not reach the clock while interrupted")
        #expect(!engine.playDeferredByInterruption)
        engine.noteAudioInterruptionEnded()
        engine.setRate(1.5)
        #expect(host.rate == 1.5, "the same call applies once the interruption is over")
    }

    @Test("setRate(0) cancels a held play")
    func zeroRateCancels() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.noteAudioInterruptionBegan()
        engine.play()
        engine.setRate(0)
        #expect(!engine.noteAudioInterruptionEnded())
    }

    @Test("a second press while one is held clears the guard and plays after the session is reactivated")
    func secondPressEscapes() async throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.noteAudioInterruptionBegan()
        engine.play()
        engine.play()
        #expect(!engine.audioInterruptionActive)
        #expect(!engine.playDeferredByInterruption)
        try await waitFor { engine.state == .playing }
        #expect(engine.state == .playing)
    }

    @Test("a pause right after the escape press wins over the reactivation")
    func pauseBeatsEscape() async throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.noteAudioInterruptionBegan()
        engine.play()
        engine.play()
        engine.pause()
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.state == .paused)
    }

    @Test("setRate(0) also disarms the system resume")
    func zeroRateCountsAsPause() throws {
        let engine = try engine()
        defer { engine.stop() }
        let before = engine.userPauseCount
        engine.setRate(0)
        #expect(engine.userPauseCount == before &+ 1)
    }

    @Test("the end of an interruption: system resume needs the armed intent, a held press always plays, never unseen")
    func endDecision() {
        let f = AetherEngine.interruptionEndShouldPlay
        #expect(f(true, true, false, true))
        #expect(!f(true, false, false, true), "no shouldResume, no held press: stays paused")
        #expect(!f(false, true, false, true), "not armed: the user had paused")
        #expect(f(false, false, true, true), "a held press plays without shouldResume")
        #expect(!f(true, true, true, false), "background-unsafe never plays")
    }

    @Test("pause() counts, so an await in the end path can see it")
    func pauseIsCounted() throws {
        let engine = try engine()
        defer { engine.stop() }
        let before = engine.userPauseCount
        engine.pause()
        #expect(engine.userPauseCount == before &+ 1)
    }

    @Test("without a renderer path the engine does not hold play")
    func nativePathUntouched() throws {
        let engine = try engine(withSoftwareHost: false)
        defer { engine.stop() }
        engine.noteAudioInterruptionBegan()
        #expect(!engine.deferPlayForInterruption())
    }

    @Test("stop() clears an interruption that never reported its end")
    func stopClears() throws {
        let engine = try engine()
        engine.noteAudioInterruptionBegan()
        engine.play()
        engine.stop()
        #expect(!engine.audioInterruptionActive)
        #expect(!engine.playDeferredByInterruption)
    }
}
