import Testing
import Foundation
@testable import AetherEngine

/// `pinQuietPeriodCapForTesting` replaces the suites that set `quietPeriodCapForTesting` on the shared
/// budget in `init` and never put it back. Each test builds its own budget, so none of this touches the
/// process-wide one.
@Suite("Quiet-period cap pin")
struct OriginBudgetQuietCapPinTests {

    @Test("A pin holds the cap while it lives and restores the earlier value on release")
    func releaseRestoresPreviousCap() {
        let budget = OriginRequestBudget()
        budget.quietPeriodCapForTesting = 5
        let pin = budget.pinQuietPeriodCapForTesting(0)
        #expect(budget.quietPeriodCapForTesting == 0)
        pin.release()
        #expect(budget.quietPeriodCapForTesting == 5)
    }

    @Test("Dropping the token restores the cap, which is how a suite instance lets go")
    func deinitRestoresCap() {
        let budget = OriginRequestBudget()
        do {
            let pin = budget.pinQuietPeriodCapForTesting(0)
            withExtendedLifetime(pin) { #expect(budget.quietPeriodCapForTesting == 0) }
        }
        #expect(budget.quietPeriodCapForTesting == nil)
    }

    @Test("With overlapping pins the cap comes back only when the last one is released")
    func overlappingPinsCount() {
        let budget = OriginRequestBudget()
        let first = budget.pinQuietPeriodCapForTesting(0)
        let second = budget.pinQuietPeriodCapForTesting(0)
        first.release()
        #expect(budget.quietPeriodCapForTesting == 0, "the second suite is still running")
        second.release()
        #expect(budget.quietPeriodCapForTesting == nil)
    }

    @Test("Releasing a pin twice gives back only once")
    func releaseIsIdempotent() {
        let budget = OriginRequestBudget()
        let first = budget.pinQuietPeriodCapForTesting(0)
        let second = budget.pinQuietPeriodCapForTesting(0)
        first.release()
        first.release()
        #expect(budget.quietPeriodCapForTesting == 0, "a repeated release must not drop the other pin")
        second.release()
        #expect(budget.quietPeriodCapForTesting == nil)
    }

    @Test("A pinned zero leaves the pacer unarmed, and the refusal ladder is back after release")
    func pinnedZeroDisarmsPacerUntilReleased() throws {
        let budget = OriginRequestBudget()
        let url = try #require(URL(string: "http://127.0.0.1:9/movie.bin"))
        let pin = budget.pinQuietPeriodCapForTesting(0)
        budget.noteRefusal(for: url, status: 429)
        #expect(!budget.isPaced(url), "a zero cap must leave the pacer unarmed")
        pin.release()
        budget.noteRefusal(for: url, status: 429)
        #expect(budget.isPaced(url), "without the pin a refusal arms the quiet ladder again")
    }
}
