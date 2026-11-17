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

    @Test("a call that paused a playing session holds the decision until it ends (audit LIF-203)")
    func interruptionHoldsTheDecision() {
        let held = Inputs(state: .paused, interruptionHoldsResume: true)
        #expect(decide(held, .paused) == .owe)
        #expect(decide(held, .graceWindowExpired) == .owe)
        #expect(decide(held, .graceAssertionReclaimed) == .step(.perform(.teardownVideo)))
        // Ended without a resume: the hold is gone and the paused session gets the normal decision.
        #expect(decide(Inputs(state: .paused), .owedDecisionSettled) == .step(.deferTeardown(afterSeconds: 15)))
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
        #expect(safe(false, false, false, false), "foreground always resumes")
        #expect(safe(true, true, false, false), "audio backend")
        #expect(safe(true, false, true, false), "software host in audio-only mode")
        #expect(safe(true, false, false, true), "native video kept for its audio (AE#1080)")
        #expect(!safe(true, false, false, false), "a released video never restarts unseen")
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

    @Test("a call that paused a playing session holds it until the call ends (audit LIF-203)")
    func interruptionHoldsUntilItEnds() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let log = Self.observe(engine)
        engine.state = .playing
        engine.noteDidEnterBackground()
        engine.resumeAfterInterruption = true
        engine.noteAudioInterruptionBegan()
        engine.state = .paused
        try await waitFor { !log.entries.isEmpty }
        #expect(log.entries.map(\.1) == [.owe])

        // Ended without a resume: the owed decision is settled and the grace window starts.
        _ = engine.noteAudioInterruptionEnded()
        engine.resumeAfterInterruption = false
        engine.settleOwedBackgroundAction()
        try await waitFor { log.entries.count == 2 }
        #expect(log.entries.last?.0 == .owedDecisionSettled)
        #expect(log.entries.last?.1 == .step(.deferTeardown(afterSeconds: 15)))
    }
}
