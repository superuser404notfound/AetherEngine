import Foundation
import Testing
@testable import AetherEngine

/// AetherEngine#122 (rrgomes): a seek issued while the host was PAUSED spontaneously re-engaged
/// playback. Root cause: the normal seek finalize forced `state = .playing` regardless of the
/// transport intent in effect when the seek was issued. That was wrong on its own (the engine
/// reported playing after a paused scrub) and it weaponised the #93 stall-recovery reassert: the
/// seek's own paused landing (`timeControlStatus == .paused`) arriving while `state == .playing`
/// inside an open recovery window is misread as a spurious pause, so the engine calls
/// `host.play()`. The finalize now derives state from the durable transport intent (the host's
/// `playIntent`, which a seek never touches), so a paused scrub lands paused and keeps state
/// honest, and the reassert's `engineStateIsPlaying` guard is naturally false.
struct Issue122PausedSeekTests {

    @Test("a seek issued while playing lands playing")
    func playingSeekLandsPlaying() {
        #expect(AetherEngine.seekFinalizeState(transportIntentIsPlaying: true) == .playing)
    }

    @Test("a seek issued while paused lands paused, not forced .playing")
    func pausedSeekLandsPaused() {
        #expect(AetherEngine.seekFinalizeState(transportIntentIsPlaying: false) == .paused)
    }

    @Test("keeping state honest vetoes the stall-recovery reassert for a paused seek")
    func honestStateVetoesReassert() {
        let now = Date(timeIntervalSince1970: 100)
        let windowOpen = Date(timeIntervalSince1970: 130)   // recovery window still open
        // After the fix a paused seek leaves engineStateIsPlaying == false, so the spurious-pause
        // reassert never fires even with the window open and the seek's paused landing present.
        #expect(!AetherEngine.shouldReassertPlayDuringRecovery(
            statusIsPaused: true, engineStateIsPlaying: false,
            now: now, windowUntil: windowOpen, reasserts: 0))
        // Documents the pre-fix bug: the forced `.playing` (engineStateIsPlaying == true) DID fire
        // the reassert on the seek's own paused landing.
        #expect(AetherEngine.shouldReassertPlayDuringRecovery(
            statusIsPaused: true, engineStateIsPlaying: true,
            now: now, windowUntil: windowOpen, reasserts: 0))
    }

    @Test("a genuine spurious pause during a PLAYING seek still recovers")
    func playingSeekStillRecovers() {
        let now = Date(timeIntervalSince1970: 100)
        let windowOpen = Date(timeIntervalSince1970: 130)
        // A playing seek keeps engineStateIsPlaying == true, so a real spurious pause inside the
        // window is still re-asserted (no regression to #93 recovery).
        #expect(AetherEngine.seekFinalizeState(transportIntentIsPlaying: true) == .playing)
        #expect(AetherEngine.shouldReassertPlayDuringRecovery(
            statusIsPaused: true, engineStateIsPlaying: true,
            now: now, windowUntil: windowOpen, reasserts: 0))
    }
}
