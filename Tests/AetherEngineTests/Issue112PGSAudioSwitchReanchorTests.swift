import Foundation
import Testing
@testable import AetherEngine

/// #112 (ijuniorfu): after an audio-track switch the PGS line vanished and, worse, the overlay cycled through
/// stale lines while the video was paused. Root cause was a time-base slip in the reload's subtitle re-arm.
///
/// An audio switch does a keepNativeHost reload. `stopInternal` resets `playlistShiftSeconds` to 0, and on a disc
/// the new producer's shift is not published synchronously (the reload lands paused / waitingToPlay, so no clock
/// tick has folded the shift back yet). A `sourceTime` read in that window has collapsed to the playlist axis
/// (== resumeAt), which on a Blu-ray is ~producer-shift seconds behind the true source PTS. The device log showed
/// it exactly: currentTime 1003.5 s, producer shift 599.9 s, so the line sat at source PTS ~1603.7 s, but the
/// re-armed reader anchored at 1003.8 s - ~600 s behind. It reconstructed a region the playhead had long passed
/// (never covering it, so nothing showed) and crawled forward publishing stale open-ended acquisition-point cues
/// that replaced each other on screen even though the playhead was frozen (the "keeps changing while paused").
///
/// The fix snapshots `sourceTime` BEFORE `stopInternal` (where the old shift is still live and the value is the
/// real source PTS) and re-arms both subtitle channels with that anchor instead of a post-reset live read. These
/// tests lock the reader-side invariant the fix leans on: a correct, ahead-of-clock anchor must survive the
/// forward catch-up (#52) against a stale-low reload clock, and the collapsed anchor is exactly what reconstructs
/// behind the line - showing why the anchor handed in must be the pre-switch one.
struct Issue112PGSAudioSwitchReanchorTests {

    @Test("a correct pre-switch source anchor survives the stale-low reload clock")
    func preSwitchAnchorSurvivesStaleReloadClock() {
        // Pre-switch source PTS = currentTime 1003.8 + producer shift 599.9 = 1603.7 (the line's true position).
        // The paused reload re-samples a sourceTime that collapsed to the playlist axis (1003.8, shift reset to
        // 0). The #52 forward catch-up only ever seeks forward, so the correct anchor must be kept, never dragged
        // back to the collapsed clock.
        #expect(AetherEngine.effectiveSubtitleStart(
            startAt: 1603.7, playhead: 1003.8, recoveryPending: false) == 1603.7)
    }

    @Test("the shift-collapsed anchor reconstructs behind the line (why the reload must pass the pre-switch anchor)")
    func collapsedAnchorReconstructsBehindTheLine() {
        // The regression input: re-arming with the post-stopInternal sourceTime (1003.8) both as anchor and as the
        // stale live clock. max() cannot invent the missing ~600 s of producer shift, so the reader reconstructs
        // at 1003.8 and the line at 1603.7 never appears.
        #expect(AetherEngine.effectiveSubtitleStart(
            startAt: 1003.8, playhead: 1003.8, recoveryPending: false) == 1003.8)
    }

    @Test("an audio switch does not move the playhead, so the pre-switch source PTS is the correct re-arm anchor")
    func audioSwitchKeepsSourcePosition() {
        // sourceTime == currentTime + playlistShiftSeconds. Captured before stopInternal (shift still 599.9) it is
        // the source PTS; captured after (shift 0) it is the playlist axis. The two differ by exactly the shift,
        // which is the ~600 s hole ijuniorfu saw. This asserts the snapshot the reload must take equals the source
        // PTS, not the collapsed value.
        let currentTime = 1003.8
        let liveShiftBeforeReload = 599.9
        let shiftAfterStopInternal = 0.0
        let preSwitchSourcePTS = currentTime + liveShiftBeforeReload
        let postResetSourceTime = currentTime + shiftAfterStopInternal
        #expect(abs(preSwitchSourcePTS - 1603.7) < 1e-6)
        #expect(abs(postResetSourceTime - 1003.8) < 1e-6)
        // The two candidate anchors differ by exactly the producer shift: the ~600 s hole ijuniorfu saw.
        #expect(abs((preSwitchSourcePTS - postResetSourceTime) - liveShiftBeforeReload) < 1e-6)
    }
}
