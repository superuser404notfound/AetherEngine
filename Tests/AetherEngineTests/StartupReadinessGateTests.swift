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
}
