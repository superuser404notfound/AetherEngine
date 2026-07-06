import Testing
import Foundation
@testable import AetherEngine

/// #37 resurface (rrgomes, 8aed0db retest): during a wedged-restart recovery the scrubber clock
/// visibly bounces (engineClock 824 -> 634 -> 824 -> 634 while avpClock holds). The original #37 fix
/// suppresses the UI clock only while the host's `seekInFlight` is set; by the recovery window that
/// has cleared (the original seek reconciled), so the 100ms periodic observer resumes publishing, and
/// the recovery nudges (`reengageStalledConsumer` -> a raw AVPlayer seek to the target) bounce
/// AVPlayer's reported clock between the frozen position and the transient nudge target. The engine
/// now holds the scrub clock at the reconciled position while a recovery seek is pending, resuming
/// once it lands. nativeClockSeconds (the raw pre-shift clock) keeps tracking for shift re-derivation.
@MainActor
struct Issue37RecoveryClockHoldTests {

    @Test("the scrub clock holds while a recovery seek is pending, then resumes on landing")
    func scrubClockHeldDuringRecovery() throws {
        let engine = try AetherEngine()

        // Steady play (no recovery): the scrub clock tracks the host clock (VOD shift 0).
        engine.applyNativeHostClockTick(600.0)
        #expect(engine.clock.currentTime == 600.0)

        // Wedge reconcile snapped the clock to the frozen position 824.
        engine.applyNativeHostClockTick(824.0)
        #expect(engine.clock.currentTime == 824.0)

        // Recovery in flight (aiming at 634): the nudges bounce AVPlayer's reported clock, but the
        // scrub clock must NOT move off the reconciled 824.
        engine.setPendingRecoverySeekTarget(634.0)
        engine.applyNativeHostClockTick(634.0)
        #expect(engine.clock.currentTime == 824.0)
        engine.applyNativeHostClockTick(824.0)
        engine.applyNativeHostClockTick(634.0)
        #expect(engine.clock.currentTime == 824.0)
        // The raw clock still tracks for shift re-derivation.
        #expect(engine.nativeClockSeconds == 634.0)

        // Recovery lands: pending cleared, ticks resume driving the scrub clock.
        engine.setPendingRecoverySeekTarget(nil)
        engine.applyNativeHostClockTick(634.0)
        #expect(engine.clock.currentTime == 634.0)
    }
}
