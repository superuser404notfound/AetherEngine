import Testing
@testable import AetherEngine

struct StartupReadinessGateTests {

    @Test("A ready item always proceeds, regardless of attempt")
    func readyProceeds() {
        #expect(StartupReadinessGate.nextAction(
            outcome: .ready, attempt: 1,
            masterAlreadyFellBack: false, hasMediaFallbackURL: true) == .proceed)
        #expect(StartupReadinessGate.nextAction(
            outcome: .ready, attempt: 2,
            masterAlreadyFellBack: false, hasMediaFallbackURL: false) == .proceed)
    }

    @Test("A cold failure with master budget remaining reloads the master")
    func reloadsWhileMasterBudgetRemains() {
        #expect(StartupReadinessGate.nextAction(
            outcome: .dead, attempt: 1, masterAttempts: 2,
            masterAlreadyFellBack: false, hasMediaFallbackURL: true) == .reloadMaster)
        // The silent 0-track park (timedOut) reloads too, not just a hard .failed.
        #expect(StartupReadinessGate.nextAction(
            outcome: .timedOut, attempt: 1, masterAttempts: 2,
            masterAlreadyFellBack: false, hasMediaFallbackURL: true) == .reloadMaster)
    }

    @Test("Exhausted master budget falls back to the media playlist")
    func fallsBackToMediaWhenExhausted() {
        #expect(StartupReadinessGate.nextAction(
            outcome: .dead, attempt: 2, masterAttempts: 2,
            masterAlreadyFellBack: false, hasMediaFallbackURL: true) == .fallBackToMedia)
        #expect(StartupReadinessGate.nextAction(
            outcome: .timedOut, attempt: 2, masterAttempts: 2,
            masterAlreadyFellBack: false, hasMediaFallbackURL: true) == .fallBackToMedia)
    }

    @Test("No media URL, or already fell back, gives up rather than looping")
    func givesUpWhenNoMediaOrAlreadyFellBack() {
        #expect(StartupReadinessGate.nextAction(
            outcome: .dead, attempt: 2, masterAttempts: 2,
            masterAlreadyFellBack: false, hasMediaFallbackURL: false) == .giveUp)
        #expect(StartupReadinessGate.nextAction(
            outcome: .timedOut, attempt: 2, masterAttempts: 2,
            masterAlreadyFellBack: true, hasMediaFallbackURL: true) == .giveUp)
    }

    @Test("Once the budget is spent every non-ready outcome terminates (no infinite 0-track park)")
    func alwaysTerminates() {
        for outcome in [StartupReadiness.dead, .timedOut] {
            // Budget spent, no media: terminates with giveUp instead of another reload.
            #expect(StartupReadinessGate.nextAction(
                outcome: outcome, attempt: StartupReadinessGate.masterAttempts,
                masterAlreadyFellBack: false, hasMediaFallbackURL: false) == .giveUp)
            // Budget spent, media available: terminates with a single media fallback.
            #expect(StartupReadinessGate.nextAction(
                outcome: outcome, attempt: StartupReadinessGate.masterAttempts,
                masterAlreadyFellBack: false, hasMediaFallbackURL: true) == .fallBackToMedia)
        }
    }

    // #169 Symptom 2: resuming into the tail anchors the master on the final segment, which is still
    // being produced over a slow link, so awaitStartupReadiness times out with NO media loaded. That is
    // not the cold DV/HDCP decode failure the gate was written for; reloading and falling back needlessly
    // drops DV. The gate must wait for the first segment's data before judging the master dead.

    @Test("An unstarted first segment (no data loaded yet) keeps awaiting instead of dropping DV")
    func awaitsFirstSegmentBeforeFailingMaster() {
        #expect(StartupReadinessGate.nextAction(
            outcome: .awaitingData, attempt: 1, masterAttempts: 2,
            masterAlreadyFellBack: false, hasMediaFallbackURL: true,
            dataWaitRounds: 0) == .keepAwaitingData)
        // Even at the last master attempt, it must not drop DV while data has never arrived.
        #expect(StartupReadinessGate.nextAction(
            outcome: .awaitingData, attempt: 2, masterAttempts: 2,
            masterAlreadyFellBack: false, hasMediaFallbackURL: true,
            dataWaitRounds: StartupReadinessGate.maxDataWaitRounds - 1) == .keepAwaitingData)
    }

    @Test("A first segment that never arrives falls through so a stuck producer still terminates")
    func awaitingDataIsBounded() {
        // Data-wait budget exhausted: fall through to the normal cold-failure logic (reload, then fallback).
        #expect(StartupReadinessGate.nextAction(
            outcome: .awaitingData, attempt: 1, masterAttempts: 2,
            masterAlreadyFellBack: false, hasMediaFallbackURL: true,
            dataWaitRounds: StartupReadinessGate.maxDataWaitRounds) == .reloadMaster)
        #expect(StartupReadinessGate.nextAction(
            outcome: .awaitingData, attempt: 2, masterAttempts: 2,
            masterAlreadyFellBack: false, hasMediaFallbackURL: true,
            dataWaitRounds: StartupReadinessGate.maxDataWaitRounds) == .fallBackToMedia)
    }

    @Test("The timeout outcome distinguishes an unserved first segment from a served-but-dead master")
    func timeoutOutcomeSplitsOnLoadedMedia() {
        // No media loaded when the window elapses: the first segment has not been served (slow production).
        #expect(StartupReadinessGate.timeoutOutcome(hasLoadedMedia: false) == .awaitingData)
        // Media loaded but still 0 tracks: the cold DV/HDCP decode failure the gate was written for.
        #expect(StartupReadinessGate.timeoutOutcome(hasLoadedMedia: true) == .timedOut)
    }
}
