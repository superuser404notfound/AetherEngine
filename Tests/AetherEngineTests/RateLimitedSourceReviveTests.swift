import Testing
import Foundation
@testable import AetherEngine

/// #377: a 429 is a NOT-YET, and the engine used to read it as a death.
///
/// The reader classifies the refusal (`isRateLimitStatus`) and then throws the classification away:
/// its give-up arm returns a bare `-1`, so `handleVODReadErrorExit` saw the same code a genuinely
/// dead source produces. It spent the ordinary two-attempt budget inside a minute, each attempt
/// reopening from byte 0 against an origin refusing exactly that, and declared the source "not
/// readable in this session" while the same stream plays instantly on a fresh press of play.
@Suite("Rate-limited VOD source revive", .serialized)
struct RateLimitedSourceReviveTests {

    /// A host of this suite's own, per test instance. `OriginRequestBudget` is one process-wide
    /// object keyed by origin, and the way to start from nothing on it is to be somewhere nobody
    /// else is: `resetForTesting()` used to stand here instead, and it empties the budget for every
    /// suite running alongside, which reads as a flake in whichever one was mid-assertion.
    private let meteredURL = URL(
        string: "https://cdn-\(UUID().uuidString).example.com/signed/movie.mkv?token=a")!

    private final class Surfaced: @unchecked Sendable {
        private let lock = NSLock()
        private var _code: Int32?
        private var _reason: String?
        private var _kind: PlaybackErrorKind?
        var code: Int32? { lock.lock(); defer { lock.unlock() }; return _code }
        var reason: String? { lock.lock(); defer { lock.unlock() }; return _reason }
        var kind: PlaybackErrorKind? { lock.lock(); defer { lock.unlock() }; return _kind }
        func set(_ c: Int32, _ r: String, _ k: PlaybackErrorKind) {
            lock.lock(); _code = c; _reason = r; _kind = k; lock.unlock()
        }
    }

    private func makeEngine() -> HLSVideoEngine {
        HLSVideoEngine(url: meteredURL, dvModeAvailable: false)
    }

    @Test("an exhausted rate-limit revive says metered, not unreadable")
    func exhaustedMeteredGateSurfacesRateLimited() {
        OriginRequestBudget.shared.noteRefusal(for: meteredURL, status: 429)

        let engine = makeEngine()
        engine.rateLimitReviveGate = RefusingSourceReviveBudget(budgetSeconds: 0)
        let surfaced = Surfaced()
        engine.onVODSourceFailed = { code, reason, kind in surfaced.set(code, reason, kind) }

        engine.handleVODReadErrorExit(-1)

        #expect(surfaced.kind == .sourceRateLimited,
                "a host that reads this as a dead source hands off to another player, which the same origin refuses")
        #expect(surfaced.code == -1)
        #expect(surfaced.reason?.contains("rate limiting") == true)
    }

    @Test("a metered read error spends the rate-limit budget, not the ordinary one")
    func meteredExitDoesNotSpendTheOrdinaryGate() {
        OriginRequestBudget.shared.noteRefusal(for: meteredURL, status: 429)

        let engine = makeEngine()
        engine.readErrorReviveGate = ReviveBudget(maxAttempts: 2)
        engine.rateLimitReviveGate = RefusingSourceReviveBudget()

        engine.handleVODReadErrorExit(-1)
        engine.handleVODReadErrorExit(-1)
        engine.handleVODReadErrorExit(-1)

        #expect(engine.readErrorReviveGate.attempts == 0, """
            three refusals must not exhaust the budget meant for a source that may be gone; \
            that is what killed the session inside a minute
            """)
        #expect(engine.rateLimitReviveGate.attempts == 3)
    }

    @Test("with no refusal on record the ordinary read-error path is unchanged")
    func unmeteredExitKeepsTheOldBehaviour() {

        let engine = makeEngine()
        engine.readErrorReviveGate = ReviveBudget(maxAttempts: 0)
        let surfaced = Surfaced()
        engine.onVODSourceFailed = { code, reason, kind in surfaced.set(code, reason, kind) }

        engine.handleVODReadErrorExit(-5)

        #expect(surfaced.kind == .vodSourceFailed,
                "only an origin that actually refused us may be reported as metering")
        #expect(surfaced.reason == "Source read failed")
    }

    @Test("a refusal older than the verdict window is not read as metering")
    func staleRefusalDoesNotClassify() {
        OriginRequestBudget.shared.noteRefusal(for: meteredURL, status: 429)

        // The window is what separates "the read that just failed was refused" from "this origin
        // refused something ten minutes ago", and only the first says anything about this failure.
        #expect(OriginRequestBudget.shared.refusedRecently(meteredURL, within: 60))
        #expect(!OriginRequestBudget.shared.refusedRecently(meteredURL, within: 0))
        #expect(HLSVideoEngine.rateLimitVerdictWindowSeconds == 60)
    }

    @Test("the backoff ladder grows and then holds, so re-asking stops being immediate")
    func backoffLadderGrows() {
        let delays = (1...6).map { HLSVideoEngine.rateLimitReviveDelay(attempt: $0) }
        #expect(delays[0] == 3, "the first retry still waits: reopening at once is what met the same limiter")
        #expect(delays == delays.sorted(), "the ladder must never step backwards")
        #expect(delays.last == 45, "past the ladder it holds at the widest step rather than growing forever")
        #expect(HLSVideoEngine.rateLimitReviveDelay(attempt: 0) == 3, "a nonsense attempt index still waits")
    }
}
