import Foundation
import Testing
@testable import AetherEngine

/// Audit LIF-R201: every background decision goes through one pure function. Before it, `pause()`
/// carried a copy that skipped the owed rule (LIF-201) and assumed a teardown, a pause the player made
/// itself reached no copy at all (LIF-202), and the interruption end refused a native video that
/// AE#1080 keeps playing in the background (LIF-203).
@Suite("One background decision for every entry point", .timeLimit(.minutes(3)))
struct BackgroundDecisionFunnelTests {

    typealias Inputs = AetherEngine.BackgroundDecisionInputs
    typealias Trigger = AetherEngine.BackgroundTrigger

    private static let everyTrigger: [Trigger] = [
        .enteredBackground, .owedDecisionSettled, .paused, .pictureInPictureClosed,
        .graceWindowExpired, .graceAssertionReclaimed,
    ]

    private func decide(_ inputs: Inputs, _ trigger: Trigger = .paused) -> AetherEngine.BackgroundDecision {
        AetherEngine.backgroundDecision(inputs, trigger: trigger)
    }

    @Test("in the foreground nothing is decided")
    func foregroundDecidesNothing() {
        for trigger in Self.everyTrigger {
            #expect(decide(Inputs(isBackgrounded: false, state: .paused), trigger) == .none)
        }
    }

    @Test("a pause during a load or seek is owed, never a teardown under it (audit LIF-201)",
          arguments: [Trigger.enteredBackground, .owedDecisionSettled, .paused, .pictureInPictureClosed,
                      .graceWindowExpired])
    func inFlightIsOwed(trigger: Trigger) {
        #expect(decide(Inputs(loadInFlight: true, state: .paused), trigger) == .owe)
        #expect(decide(Inputs(loadInFlight: true, state: .playing), trigger) == .owe)
        #expect(decide(Inputs(state: .loading), trigger) == .owe)
        #expect(decide(Inputs(state: .seeking), trigger) == .owe)
    }

    @Test("only the system reclaiming the grace assertion decides under a load (it cannot wait)")
    func reclaimedAssertionDoesNotWait() {
        #expect(decide(Inputs(loadInFlight: true, state: .paused), .graceAssertionReclaimed)
                == .step(.perform(.teardownVideo)))
    }

    @Test("a paused native video is released after the grace window, whoever paused it (audit LIF-202)")
    func pausedNativeDefersTeardown() {
        let paused = Inputs(state: .paused)
        #expect(decide(paused, .paused) == .step(.deferTeardown(afterSeconds: 15)))
        #expect(decide(paused, .enteredBackground) == .step(.deferTeardown(afterSeconds: 15)))
        #expect(decide(paused, .owedDecisionSettled) == .step(.deferTeardown(afterSeconds: 15)))
        #expect(decide(paused, .graceWindowExpired) == .step(.perform(.teardownVideo)))
        var noGrace = paused
        noGrace.graceSeconds = 0
        #expect(decide(noGrace, .paused) == .step(.perform(.teardownVideo)))
    }

    @Test("a playing native video stays for its audio, unless background playback is off (AE#1080)")
    func playingNative() {
        #expect(decide(Inputs(state: .playing), .enteredBackground) == .step(.perform(.doNothing)))
        #expect(decide(Inputs(state: .playing, backgroundPlaybackEnabled: false), .enteredBackground)
                == .step(.perform(.teardownVideo)))
    }

    @Test("a paused software session is released like a native one; pause() no longer spares it (audit LIF-R201)")
    func pausedSoftwareSession() {
        let paused = Inputs(state: .paused, hasSoftwareHost: true, softwareHostHasAudio: true)
        #expect(decide(paused, .paused) == .step(.deferTeardown(afterSeconds: 15)))
        var playing = paused
        playing.state = .playing
        #expect(decide(playing, .enteredBackground) == .step(.perform(.enterSoftwareAudioOnly)))
    }

    @Test("what stays: an audio backend, a PiP window, a retained pause")
    func whatStays() {
        #expect(decide(Inputs(state: .paused, isAudioBackend: true)) == .step(.perform(.doNothing)))
        #expect(decide(Inputs(state: .paused, pipActive: true)) == .step(.perform(.doNothing)))
        #expect(decide(Inputs(state: .paused, retainsPausedVideoPipeline: true)) == .step(.perform(.doNothing)))
    }

    @Test("a session the background teardown already released is not released twice")
    func releasedPipelineIsLeftAlone() {
        for trigger in Self.everyTrigger {
            #expect(decide(Inputs(state: .paused, pipelineReleased: true), trigger) == .none)
        }
    }

    @Test("tvOS releases at once unless a PiP window is up, and has no grace window")
    func tvOS() {
        #expect(decide(Inputs(isTV: true, state: .playing), .enteredBackground) == .step(.perform(.teardownVideo)))
        #expect(decide(Inputs(isTV: true, state: .paused), .paused) == .step(.perform(.teardownVideo)))
        #expect(decide(Inputs(isTV: true, state: .paused, pipActive: true), .pictureInPictureClosed)
                == .step(.perform(.doNothing)))
        #expect(decide(Inputs(isTV: true, state: .paused), .pictureInPictureClosed) == .step(.perform(.teardownVideo)))
    }

    /// Review R-P5-1: the LIF-203 hold owed the decision for as long as the interruption lasted, which
    /// armed no assertion, so a call that never sent ENDED let the app suspend with the whole pipeline
    /// (the AE#597 wedge), on tvOS too. The hold is now the grace window: a paused session during a call
    /// gets the same decision as any other paused session, whatever the trigger.
    @Test("an interruption does not hold the background decision beyond the grace window (review R-P5-1)")
    func interruptionHoldIsTheGraceWindow() {
        let paused = Inputs(state: .paused)
        for trigger in [Trigger.enteredBackground, .paused, .owedDecisionSettled] {
            #expect(decide(paused, trigger) == .step(.deferTeardown(afterSeconds: 15)), "\(trigger)")
        }
        #expect(decide(paused, .graceWindowExpired) == .step(.perform(.teardownVideo)),
                "no ENDED inside the window: the expiry tears down")
        #expect(decide(paused, .graceAssertionReclaimed) == .step(.perform(.teardownVideo)))
    }

    @Test("tvOS: an interruption active at background entry still tears down at once (review R-P5-1)")
    func tvOSInterruptionTearsDown() {
        #expect(decide(Inputs(isTV: true, state: .paused), .enteredBackground) == .step(.perform(.teardownVideo)))
        #expect(decide(Inputs(isTV: true, state: .paused), .paused) == .step(.perform(.teardownVideo)))
    }

    private func endResumes(backgrounded: Bool = true, audioBackend: Bool = false,
                            backgroundPlayback: Bool = true, softwareHost: Bool = false,
                            nativeKept: Bool = false, shouldResume: Bool = true) -> Bool {
        let safe = AetherEngine.interruptionResumeIsBackgroundSafe(
            isBackgrounded: backgrounded, isAudioBackend: audioBackend,
            backgroundPlaybackEnabled: backgroundPlayback, hasSoftwareHost: softwareHost,
            nativeSessionKeptForAudio: nativeKept)
        return AetherEngine.interruptionEndShouldPlay(
            armed: true, shouldResume: shouldResume, deferredPlay: false, backgroundSafe: safe)
    }

    @Test("iOS: ENDED with shouldResume inside the grace window resumes, after the teardown it does not (review R-P5-1)")
    func endedInsideTheWindowResumes() {
        #expect(endResumes(nativeKept: true), "native video still up inside the window")
        #expect(endResumes(softwareHost: true), "software session still up inside the window")
        #expect(!endResumes(nativeKept: false), "the window expired and released the native video")
        #expect(!endResumes(nativeKept: true, shouldResume: false))
    }

    @Test("iOS with background playback off: an interruption end never restarts video in the background (review R-P5-1)")
    func backgroundPlaybackOffDoesNotResume() {
        #expect(decide(Inputs(state: .paused, backgroundPlaybackEnabled: false), .enteredBackground)
                == .step(.deferTeardown(afterSeconds: 15)))
        #expect(!endResumes(backgroundPlayback: false, softwareHost: true))
        #expect(!endResumes(backgroundPlayback: false, nativeKept: false))
        #expect(endResumes(audioBackend: true, backgroundPlayback: false), "music is not video")
        #expect(endResumes(backgrounded: false, backgroundPlayback: false, softwareHost: true), "foreground")
    }

    @Test("only a pause from playing asks for the decision (audit LIF-202)")
    func stateChangeTrigger() {
        #expect(AetherEngine.stateChangeRequestsBackgroundDecision(from: .playing, to: .paused))
        #expect(!AetherEngine.stateChangeRequestsBackgroundDecision(from: .paused, to: .playing))
        #expect(!AetherEngine.stateChangeRequestsBackgroundDecision(from: .loading, to: .paused))
        #expect(!AetherEngine.stateChangeRequestsBackgroundDecision(from: .seeking, to: .paused))
        #expect(!AetherEngine.stateChangeRequestsBackgroundDecision(from: .playing, to: .ended))
    }

    @Test("the end of a call may resume a native video kept playing in the background (audit LIF-203)")
    func interruptionResumeIsBackgroundSafe() {
        let safe = AetherEngine.interruptionResumeIsBackgroundSafe
        #expect(safe(false, false, true, false, false), "foreground always resumes")
        #expect(safe(true, true, true, false, false), "audio backend")
        #expect(safe(true, false, true, true, false), "software host in audio-only mode")
        #expect(safe(true, false, true, false, true), "native video kept for its audio (AE#1080)")
        #expect(!safe(true, false, true, false, false), "a released video never restarts unseen")
    }
}

/// The funnel on a live engine. The lifecycle notifications are iOS / tvOS only, so these drive it
/// through `noteDidEnterBackground()`, the `state` writes the native sink makes, and the
/// observer seam that sees every decision.
@Suite("Background decisions on a live engine", .serialized, .timeLimit(.minutes(3)))
@MainActor
struct BackgroundDecisionEngineTests {

    final class Log {
        var entries: [(AetherEngine.BackgroundTrigger, AetherEngine.BackgroundDecision)] = []
        var steps: [AetherEngine.BackgroundDecision] { entries.map(\.1).filter { if case .step = $0 { true } else { false } } }
    }

    private static func observe(_ engine: AetherEngine) -> Log {
        let log = Log()
        engine.backgroundDecisionObserverForTesting = { log.entries.append(($0, $1)) }
        return log
    }

    @Test("a pause the player takes itself in the background gets the decision (audit LIF-202)")
    func playerSidePause() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let log = Self.observe(engine)
        engine.state = .playing
        engine.noteDidEnterBackground()
        // What the native timeControlStatus sink writes when AVPlayer pauses on its own.
        engine.state = .paused
        try await waitFor { !log.entries.isEmpty }
        #expect(log.entries.first?.0 == .paused)
        #expect(log.entries.first?.1 == .step(.deferTeardown(afterSeconds: 15)))
    }

    @Test("pause() during a load leaves the load alone and is decided when it returns (audit LIF-201)")
    func pauseDuringLoadIsOwed() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let log = Self.observe(engine)
        engine.noteDidEnterBackground()
        let reader = BackgroundDecisionWaitsForLoadTests.HeldDataReader(try ProbeTestFixtures.hdr10Plus())
        let load = Task { @MainActor in
            try await engine.load(source: .custom(reader, formatHint: "mp4"))
        }
        try await waitFor { reader.entered }
        let generation = engine.loadGeneration

        engine.pause()
        #expect(engine.loadGeneration == generation)
        let decidedMidLoad = try await waitFor(upTo: .milliseconds(300)) { !log.steps.isEmpty }
        #expect(!decidedMidLoad)
        reader.release()

        let probe = try await load.value
        #expect(probe != nil)
        try await waitFor { !log.steps.isEmpty }
        #expect(log.entries.contains { $0.0 == .owedDecisionSettled })
        #expect(engine.loadedURL != nil)
    }

    @Test("a load that starts in the background owes the decision at its exit (audit LIF-201)")
    func loadInBackgroundOwesTheDecision() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let log = Self.observe(engine)
        engine.noteDidEnterBackground()
        _ = try await engine.load(
            source: .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4"))
        try await waitFor { log.entries.contains { $0.0 == .owedDecisionSettled } }
    }

    @Test("the engine's own teardown pause does not ask for a second teardown")
    func teardownPauseIsNotDecidedAgain() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(
            source: .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4"))
        let log = Self.observe(engine)
        engine.state = .playing
        engine.noteDidEnterBackground()
        engine.releaseVideoPipelineForBackground()
        #expect(engine.state == .paused)
        try await waitFor { !log.entries.isEmpty }
        #expect(log.entries.map(\.1) == [.none])
        #expect(engine.needsForegroundVideoRestore)
    }

    @Test("a call that pauses a playing session in the background arms the grace window, not an open hold (review R-P5-1)")
    func interruptionPauseArmsTheGraceWindow() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let log = Self.observe(engine)
        engine.state = .playing
        engine.noteDidEnterBackground()
        engine.resumeAfterInterruption = true
        engine.noteAudioInterruptionBegan()
        engine.state = .paused
        try await waitFor { !log.entries.isEmpty }
        #expect(log.entries.map(\.1) == [.step(.deferTeardown(afterSeconds: 15))])
        #expect(!engine.backgroundActionOwed)
    }
}
