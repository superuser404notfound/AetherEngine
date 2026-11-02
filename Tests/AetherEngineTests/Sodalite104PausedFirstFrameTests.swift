import AVFoundation
import Combine
import Foundation
import Testing
@testable import AetherEngine

@Suite("PausedFirstFrame (Sodalite#104 round 4: a pause before the first frame still presents it)")
struct Sodalite104PausedFirstFrameTests {

    @Test("a pause before the first frame keeps the loops running, one after it parks them")
    func holdsOnlyBeforeTheFirstFrame() {
        #expect(PausedFirstFrame.holdsForFirstFrame(loopsStarted: true, framesEnqueued: 0))
        #expect(!PausedFirstFrame.holdsForFirstFrame(loopsStarted: true, framesEnqueued: 1))
        #expect(!PausedFirstFrame.holdsForFirstFrame(loopsStarted: false, framesEnqueued: 0))
    }

    @Test("the loops run while playing or while waiting for the first frame, and park otherwise")
    func loopsMayRun() {
        #expect(PausedFirstFrame.loopsMayRun(isPlaying: true, pausedBeforeFirstFrame: false))
        #expect(PausedFirstFrame.loopsMayRun(isPlaying: false, pausedBeforeFirstFrame: true))
        #expect(!PausedFirstFrame.loopsMayRun(isPlaying: false, pausedBeforeFirstFrame: false))
    }

    @Test("a clock arming under that pause starts stopped, otherwise at the last speed")
    func armingRate() {
        #expect(PausedFirstFrame.armingRate(lastRate: 1.5, pausedBeforeFirstFrame: true) == 0)
        #expect(PausedFirstFrame.armingRate(lastRate: 1.5, pausedBeforeFirstFrame: false) == 1.5)
    }

    @Test("an arm that raced a pause() is stopped, one that raced a play() is started, one that did not is left")
    func rateCorrectionAtArm() {
        #expect(PausedFirstFrame.rateCorrectionAtArm(
            transportPlaying: false, pausedBeforeFirstFrame: false, synchronizerRate: 1, lastRate: 1) == 0)
        #expect(PausedFirstFrame.rateCorrectionAtArm(
            transportPlaying: true, pausedBeforeFirstFrame: false, synchronizerRate: 0, lastRate: 1.25) == 1.25)
        #expect(PausedFirstFrame.rateCorrectionAtArm(
            transportPlaying: true, pausedBeforeFirstFrame: false, synchronizerRate: 1.25, lastRate: 1.25) == nil)
        #expect(PausedFirstFrame.rateCorrectionAtArm(
            transportPlaying: false, pausedBeforeFirstFrame: true, synchronizerRate: 0, lastRate: 1) == nil)
    }

    @Test("the reporter's tune: armed on audio ahead of the keyframe, the stopped clock moves onto the frame")
    func anchorsAClockStandingBeforeTheFrame() {
        #expect(PausedFirstFrame.presentationAnchor(
            framePTS: 26116.9, clockArmed: true, clockSeconds: 26115.74) == 26116.9)
    }

    @Test("a clock already at or past the frame presents it where it stands")
    func leavesAClockAtOrPastTheFrame() {
        #expect(PausedFirstFrame.presentationAnchor(framePTS: 10, clockArmed: true, clockSeconds: 10) == nil)
        #expect(PausedFirstFrame.presentationAnchor(framePTS: 10, clockArmed: true, clockSeconds: 12) == nil)
    }

    @Test("an unarmed or unreadable clock is left to the loop that arms it")
    func leavesAnUnarmedClock() {
        #expect(PausedFirstFrame.presentationAnchor(framePTS: 10, clockArmed: false, clockSeconds: 0) == nil)
        #expect(PausedFirstFrame.presentationAnchor(framePTS: 10, clockArmed: true, clockSeconds: .nan) == nil)
        #expect(PausedFirstFrame.presentationAnchor(framePTS: .nan, clockArmed: true, clockSeconds: 0) == nil)
    }

    @MainActor
    @Test("clock-arm reconciliation cannot restart the clock halfway through pause()", .timeLimit(.minutes(3)))
    func clockArmDuringPause() async throws {
        let host = SoftwarePlaybackHost()
        let output = AudioOutput()
        defer { output.stop() }
        host.installClockOutputForTesting(output, armed: true)
        host.isPlaying = true
        output.seekClock(to: .zero, rate: 1)
        let arm = host.makeClockArmCallback(audioOutput: output)
        let revisionBeforePause = output.clockCommandRevision

        var correctionEntered = false
        // @Published emits synchronously: pause() has issued its stop command here, but has not yet
        // set isPlaying=false. Re-entering the real arm callback pins the feeder's bad ordering
        // without relying on two threads happening to hit that window on a loaded runner.
        let observation = host.$rate.dropFirst().sink { rate in
            guard rate == 0 else { return }
            #expect(host.isPlaying)
            let pauseRevision = output.clockCommandRevision
            #expect(pauseRevision == revisionBeforePause &+ 1)
            correctionEntered = true
            arm()
            #expect(output.clockCommandRevision == pauseRevision,
                    "arming must not issue a transport command while pause intent is being published")
        }
        defer { observation.cancel() }
        host.pause()

        #expect(correctionEntered)
        #expect(!host.isPlaying)
        // The synchronizer reports its rate asynchronously, so a stop can still read 1 for a while
        // on a starved runner. Block the main actor while it settles: the queued correction must
        // not run yet, or it would mask a restart. A real restart keeps reading 1.
        let settleDeadline = Date().addingTimeInterval(2)
        while output.rate != 0, Date() < settleDeadline { usleep(5_000) }
        #expect(output.rate == 0, "the feeder must not restart a clock pause() just stopped")
        try await drainClockArmCallbacks()
        #expect(output.rate == 0, "the queued correction sees the completed pause")
    }

    @MainActor
    @Test("an arm reconciles a pause that preceded the armed latch", .timeLimit(.minutes(3)))
    func pauseBeforeClockArm() async throws {
        let host = SoftwarePlaybackHost()
        let output = AudioOutput()
        defer { output.stop() }
        host.installClockOutputForTesting(output)
        host.isPlaying = true
        host.pause()
        // The feeder had already read the old playback intent before pause() latched it.
        output.seekClock(to: .zero, rate: 1)
        #expect(output.rate == 0, "the stale arm must never restart an explicitly paused clock")
        output.setRate(1)
        #expect(output.rate == 0, "a feeder's stale rebuffer release also yields to explicit pause")
        host.makeClockArmCallback(audioOutput: output)()
        try await drainClockArmCallbacks()
        #expect(output.rate == 0)
        #expect(!host.isPlaying)
    }

    @MainActor
    @Test("a queued arm uses the current playback intent and speed", .timeLimit(.minutes(3)))
    func clockArmUsesLatestPlaybackIntent() async throws {
        let host = SoftwarePlaybackHost()
        let output = AudioOutput()
        defer { output.stop() }
        host.installClockOutputForTesting(output)
        host.setRate(1.5)
        host.makeClockArmCallback(audioOutput: output)()
        host.isPlaying = true
        try await drainClockArmCallbacks()
        #expect(output.rate == 1.5, "a play before reconciliation must not be lost")
    }

    @MainActor
    @Test("a queued arm cannot restart an output after stop was requested", .timeLimit(.minutes(3)))
    func clockArmAfterStopRequest() async throws {
        let host = SoftwarePlaybackHost()
        let output = AudioOutput()
        defer { output.stop() }
        host.installClockOutputForTesting(output)
        host.isPlaying = true
        host.makeClockArmCallback(audioOutput: output)()
        host.stopRequested = true
        try await drainClockArmCallbacks()
        #expect(output.rate == 0)
    }

    @MainActor
    @Test("a queued arm cannot change an output replaced by another session", .timeLimit(.minutes(3)))
    func clockArmAfterOutputReplacement() async throws {
        let host = SoftwarePlaybackHost()
        let oldOutput = AudioOutput()
        let newOutput = AudioOutput()
        defer { oldOutput.stop(); newOutput.stop() }
        host.installClockOutputForTesting(oldOutput)
        host.isPlaying = true
        host.makeClockArmCallback(audioOutput: oldOutput)()
        host.installClockOutputForTesting(newOutput)
        try await drainClockArmCallbacks()
        #expect(oldOutput.rate == 0)
        #expect(newOutput.rate == 0)
    }

    @MainActor
    @Test("an arm under pause cancels a pending preroll start even while the clock reads zero",
          .timeLimit(.minutes(3)))
    func pausedClockArmCancelsPreroll() async throws {
        let host = SoftwarePlaybackHost()
        let output = AudioOutput()
        defer { output.stop() }
        host.installClockOutputForTesting(output)
        output.holdPrerollForTesting(rate: 1)
        #expect(output.rate == 0)
        #expect(output.prerollPending)
        host.makeClockArmCallback(audioOutput: output)()
        try await drainClockArmCallbacks()
        #expect(!output.prerollPending, "rate zero must not hide a pending positive start")
        #expect(output.rate == 0)
    }

    @MainActor
    @Test("a queued arm leaves the running audio tail to the end-of-media park", .timeLimit(.minutes(3)))
    func clockArmAfterEndOfMedia() async throws {
        let host = SoftwarePlaybackHost()
        let output = AudioOutput()
        defer { output.stop() }
        host.installClockOutputForTesting(output)
        host.isPlaying = true
        output.seekClock(to: .zero, rate: 1)
        host.makeClockArmCallback(audioOutput: output)()
        // EOF clears playback intent before the queued audio tail's deferred clock park.
        host.finishClockOutputForTesting()
        try await drainClockArmCallbacks()
        #expect(output.rate == 1, "reconciliation must not truncate the remaining audio tail")
    }

    @MainActor
    @Test("EOF cannot discard an explicit pause that preceded the armed latch", .timeLimit(.minutes(3)))
    func pausedClockArmAfterEndOfMedia() async throws {
        let host = SoftwarePlaybackHost()
        let output = AudioOutput()
        defer { output.stop() }
        host.installClockOutputForTesting(output)
        host.isPlaying = true
        host.pause()
        // The feeder had read the previous intent before pause() found an unarmed clock.
        output.seekClock(to: .zero, rate: 1)
        host.makeClockArmCallback(audioOutput: output)()
        host.finishClockOutputForTesting()
        try await drainClockArmCallbacks()
        #expect(output.rate == 0, "EOF must preserve the user's explicit pause")
    }

    @MainActor
    @Test("a queued arm cannot undo a feeder's rebuffer pause", .timeLimit(.minutes(3)))
    func clockArmAfterFeederPause() async throws {
        let host = SoftwarePlaybackHost()
        let output = AudioOutput()
        defer { output.stop() }
        host.installClockOutputForTesting(output)
        host.isPlaying = true
        output.seekClock(to: .zero, rate: 1)
        host.makeClockArmCallback(audioOutput: output)()
        // The DVR feeder owns this hold locally; the host still reports playing and its
        // combined-loop rebuffer diagnostics do not change.
        output.pause()
        try await drainClockArmCallbacks()
        #expect(output.rate == 0)
    }

    @MainActor
    @Test("a queued arm cannot overwrite a newer seek", .timeLimit(.minutes(3)))
    func clockArmAfterNewerSeek() async throws {
        let host = SoftwarePlaybackHost()
        let output = AudioOutput()
        defer { output.stop() }
        host.installClockOutputForTesting(output)
        host.isPlaying = true
        output.seekClock(to: .zero, rate: 1)
        host.makeClockArmCallback(audioOutput: output)()
        output.seekClock(to: CMTime(seconds: 42, preferredTimescale: 90000), rate: 0)
        try await drainClockArmCallbacks()
        #expect(output.rate == 0)
        #expect(output.currentTimeSeconds == 42)
    }

    @MainActor
    @Test("a queued arm cannot overwrite a newer speed", .timeLimit(.minutes(3)))
    func clockArmAfterNewerRate() async throws {
        let host = SoftwarePlaybackHost()
        let output = AudioOutput()
        defer { output.stop() }
        host.installClockOutputForTesting(output)
        host.isPlaying = true
        host.makeClockArmCallback(audioOutput: output)()
        output.setRate(1.5)
        try await drainClockArmCallbacks()
        #expect(output.rate == 1.5)
    }

    @MainActor
    @Test("a queued arm cannot overwrite a newer pending preroll speed", .timeLimit(.minutes(3)))
    func clockArmAfterNewerPrerollRate() async throws {
        let host = SoftwarePlaybackHost()
        let output = AudioOutput()
        defer { output.stop() }
        host.installClockOutputForTesting(output)
        host.isPlaying = true
        output.holdPrerollForTesting(rate: 1)
        host.makeClockArmCallback(audioOutput: output)()
        output.setRate(1.5)
        try await drainClockArmCallbacks()
        #expect(output.prerollRateForTesting == 1.5)
        #expect(output.rate == 0)
    }

    @Test("a correction rechecks its revision after the preroll preflight",
          .timeLimit(.minutes(3)), arguments: [false, true])
    func clockCorrectionAfterPreflightPause(usesPreroll: Bool) {
        let output = AudioOutput()
        defer { output.videoPrerollSatisfied = nil; output.stop() }
        let revision = output.clockCommandRevision
        // This callback runs outside the clock lock. A pause can win while readiness is
        // being checked; both the direct-rate and seek/preroll branches must reject the
        // earlier correction when they acquire the lock to apply it.
        output.videoPrerollSatisfied = { _ in
            output.pause()
            return usesPreroll ? false : nil
        }
        output.setRate(1, ifRevision: revision)
        #expect(output.clockCommandRevision != revision)
        #expect(output.rate == 0)
        #expect(!output.prerollPending)
    }

    @MainActor
    @Test("play before the armed latch preserves the feeder's pending rate correction",
          .timeLimit(.minutes(3)))
    func playBetweenRevisionReadAndArmedLatch() {
        let host = SoftwarePlaybackHost()
        let output = AudioOutput()
        host.installClockOutputForTesting(output)
        defer { host.stop() }
        host.pause()
        output.seekClock(to: .zero, rate: 1)
        // The feeder reads this revision before publishing clockArmed. A concurrent play sees
        // the clock as unarmed, so it must leave this pending correction responsible for starting it.
        let armRevision = output.clockCommandRevision
        host.play()
        #expect(host.isPlaying)
        #expect(output.rate == 0, "play must not start an unanchored clock")
        host.installClockOutputForTesting(output, armed: true)
        output.setRate(1, ifRevision: armRevision)
        #expect(output.rate == 1, "enabling transport cannot invalidate the only pending clock start")
    }

    @MainActor
    private func drainClockArmCallbacks() async throws {
        // The marker follows every correction queued by this test on the same serial queue.
        // waitFor keeps the wait cancellable and leaves the main actor free to execute them.
        var drained = false
        DispatchQueue.main.async { drained = true }
        try await waitFor { drained }
    }
}
