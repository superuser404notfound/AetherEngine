import Foundation
import Testing
@testable import AetherEngine

/// #93 retest (rrgomes): a user seek that wedges never lands, so the frozen AVPlayer clock still
/// reports the PRE-seek position (#37 semantics); the stall recovery then nudged/reloaded at that
/// frozen position (391.9 s) instead of the requested target (341.9 s), so the seek was silently
/// lost. The engine now keeps the unlanded seek target as recovery intent: the nudge and the
/// stage-2 reload aim at it. The intent clears when the seek demonstrably lands (rendered near
/// the target) or goes stale (organic playback progress far from the target, meaning AVPlayer
/// abandoned the seek and the user is watching elsewhere).
struct RecoverySeekTargetTests {

    @Test("recovery aims at the pending seek target when one exists")
    func anchorDecision() {
        // rrgomes shape: frozen pre-seek clock 391.9, requested target 341.9. The user's
        // backward seek intent wins even over a rendered clock that ran further ahead.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: 341.9, currentRendered: 400.0) == 341.9)
        // No pending seek, clock frozen: recover in place.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: nil, currentRendered: 391.9) == 391.9)
    }

    @Test("the nudge target is never below the current rendered position (#115)")
    func nudgeNeverRewinds() {
        // #115 shape (dlev02): wedge trips at 391.9, VOD keeps draining buffered segments
        // through the re-engage grace window, on-screen frame is at 400.0 when the nudge
        // fires. Seeking to the pre-grace capture replayed ~8s; the anchor must track the
        // rendered frame instead.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: nil, currentRendered: 400.0) == 400.0)
        // A lagging/zero rendered read must not drag the anchor backward either.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: nil, currentRendered: 0.0) == 391.9)
    }

    @Test("a pending target counts as landed once rendered output reaches its neighbourhood")
    func landedDecision() {
        #expect(AetherEngine.pendingSeekLanded(rendered: 341.9, target: 341.9))
        #expect(AetherEngine.pendingSeekLanded(rendered: 344.0, target: 341.9))
        // Frozen at the pre-seek position: not landed.
        #expect(!AetherEngine.pendingSeekLanded(rendered: 391.9, target: 341.9))
    }

    @Test("organic playback progress far from the target marks the intent stale")
    func staleDecision() {
        // A frozen clock accumulates no progress: intent survives the whole wedge.
        #expect(!AetherEngine.isPendingSeekStale(progressWhilePending: 0.0))
        #expect(!AetherEngine.isPendingSeekStale(progressWhilePending: 2.0))
        // AVPlayer abandoned the seek and playback runs elsewhere: drop the intent so a later,
        // unrelated stall cannot teleport to a minutes-old target.
        #expect(AetherEngine.isPendingSeekStale(progressWhilePending: 3.5))
    }

    @Test("deadline recovery restarts a starved producer or one that cannot reach the target")
    func deadlineRestartDecision() {
        #expect(AetherEngine.shouldReanchorProducerAfterSeekDeadline(
            isStarved: true, targetBeyondProducerCoverage: false))
        // AE#141: a progressing producer whose march cannot reach the pending target must be
        // re-anchored; "healthy at the old position" rode 3x30 s serve timeouts into item death.
        #expect(AetherEngine.shouldReanchorProducerAfterSeekDeadline(
            isStarved: false, targetBeyondProducerCoverage: true))
        #expect(AetherEngine.shouldReanchorProducerAfterSeekDeadline(
            isStarved: true, targetBeyondProducerCoverage: true))
        // #129: a healthy march filling toward a reachable target keeps its progress.
        #expect(!AetherEngine.shouldReanchorProducerAfterSeekDeadline(
            isStarved: false, targetBeyondProducerCoverage: false))
        #expect(AetherEngine.shouldReanchorSubtitlesOnLateSeekLanding(
            alreadyReanchored: false
        ))
        #expect(!AetherEngine.shouldReanchorSubtitlesOnLateSeekLanding(
            alreadyReanchored: true
        ))
    }

    @Test("a published completion is the authoritative deadline catch-up signal")
    func completionPublicationDecision() {
        #expect(AetherEngine.shouldCatchUpDeadlineLanding(renderedTimePublished: true))
        #expect(!AetherEngine.shouldCatchUpDeadlineLanding(renderedTimePublished: false))
    }

    @Test("a short seek needs rendered movement or completion evidence")
    func shortSeekLandingEvidence() {
        #expect(!AetherEngine.pendingSeekHasRenderedLandingEvidence(
            rendered: 40,
            target: 43,
            initialRendered: 40,
            completionRenderedTimePublished: false
        ))
        #expect(AetherEngine.pendingSeekHasRenderedLandingEvidence(
            rendered: 43,
            target: 43,
            initialRendered: 40,
            completionRenderedTimePublished: false
        ))
        #expect(AetherEngine.pendingSeekHasRenderedLandingEvidence(
            rendered: 40,
            target: 43,
            initialRendered: 40,
            completionRenderedTimePublished: true
        ))
    }

    @MainActor
    @Test("starting or clearing a recovery target resets deadline lifecycle state")
    func targetLifecycleReset() throws {
        let engine = try AetherEngine()
        engine.setPendingRecoverySeekTarget(42)
        engine.pendingRecoverySeekDeadlineExpired = true
        engine.pendingRecoverySeekSubtitlesReanchored = true

        // A superseding seek to the same target is still a new lifecycle.
        engine.setPendingRecoverySeekTarget(42)
        #expect(!engine.pendingRecoverySeekDeadlineExpired)
        #expect(!engine.pendingRecoverySeekSubtitlesReanchored)

        engine.pendingRecoverySeekDeadlineExpired = true
        engine.pendingRecoverySeekSubtitlesReanchored = true
        engine.setPendingRecoverySeekTarget(nil)
        #expect(!engine.pendingRecoverySeekDeadlineExpired)
        #expect(!engine.pendingRecoverySeekSubtitlesReanchored)
    }

    @Test("seek recovery reasserts only pauses covered by the bounded recovery policy")
    func recoveredStateDecision() {
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: false,
            statusIsPaused: false,
            shouldReassertPausedStatus: true
        ) == .playing)
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: false,
            statusIsPaused: true,
            shouldReassertPausedStatus: true
        ) == .paused)
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: true,
            statusIsPaused: true,
            shouldReassertPausedStatus: false
        ) == .paused)
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: true,
            statusIsPaused: true,
            shouldReassertPausedStatus: true
        ) == .playing)
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: true,
            statusIsPaused: false,
            shouldReassertPausedStatus: false
        ) == .playing)
    }
}
