import Testing
import Foundation
@testable import AetherEngine

/// Audit DMX-112: a pump parked in `OriginRequestBudget.acquire` ignored `markClosed()`, so a torn
/// down session stayed in the origin's FIFO and in the race for the next pacer token, and could take
/// the very slot the new session was waiting for. `shouldAbort` is polled once per slice in both
/// waits, and an aborted caller consumes nothing.
@Suite("Origin request budget abort", .serialized)
struct OriginRequestBudgetAbortTests {

    @Test("a strict metadata caller never overcommits a full origin on timeout")
    func strictSlotTimeout() {
        let budget = OriginRequestBudget()
        budget.setHostLimit(1, for: url)
        let held = budget.acquire(for: url, label: "holder", timeout: 1)
        defer { budget.release(held) }
        let refused = budget.acquire(for: url, label: "metadata", timeout: 0.01, allowOvercommit: false)
        #expect(refused == nil)
        #expect(budget.snapshot(for: url)?.inflight == 1)
        #expect(budget.snapshot(for: url)?.peakInflight == 1)
        #expect(budget.snapshot(for: url)?.waiting == 0)
    }

    private let url = URL(string: "https://abort.example.com:443/movie.mkv")!

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.withLock { _value } }
        func set() { lock.withLock { _value = true } }
    }

    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var _done = false
        private var _ticket: OriginRequestBudget.Ticket?
        var done: Bool { lock.withLock { _done } }
        var ticket: OriginRequestBudget.Ticket? { lock.withLock { _ticket } }
        func finish(_ ticket: OriginRequestBudget.Ticket?) { lock.withLock { _ticket = ticket; _done = true } }
    }

    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var nanoseconds: UInt64 = 1_000_000_000
        func now() -> DispatchTime { lock.withLock { DispatchTime(uptimeNanoseconds: nanoseconds) } }
        func advance(by seconds: TimeInterval) {
            lock.withLock { nanoseconds += UInt64((seconds * 1_000_000_000).rounded()) }
        }
    }

    @Test("a caller parked for a slot leaves on abort without taking or holding one",
          .timeLimit(.minutes(3)))
    func slotWaitAborts() async throws {
        let budget = OriginRequestBudget()
        budget.setHostLimit(1, for: url)
        let held = budget.acquire(for: url, label: "holder", timeout: 1)
        let abort = Flag()
        let outcome = Result()
        let target = url
        Thread.detachNewThread {
            // 120 s: the abort, not this budget, is what must end the wait.
            outcome.finish(budget.acquire(for: target, label: "pump", timeout: 120,
                                          shouldAbort: { abort.value }))
        }
        try await waitFor { budget.snapshot(for: url)?.waiting == 1 }

        abort.set()
        try await waitFor { outcome.done }
        #expect(outcome.ticket == nil, "an aborted acquire must not hand out a ticket")
        #expect(budget.snapshot(for: url)?.waiting == 0, "the aborted caller left the FIFO")
        #expect(budget.snapshot(for: url)?.inflight == 1, "only the holder is on the books")

        // The slot the holder gives back goes to the next caller, not to a waiter that left.
        budget.release(held)
        let next = budget.acquire(for: url, label: "next", timeout: 1)
        #expect(next?.granted == true)
        #expect(next?.waitedMs == 0)
        budget.release(next)
        #expect(budget.snapshot(for: url)?.inflight == 0)
    }

    @Test("a caller parked for the pacer leaves on abort and leaves the tokens alone",
          .timeLimit(.minutes(3)))
    func pacerWaitAborts() async throws {
        let clock = ManualClock()
        let budget = OriginRequestBudget(now: clock.now)
        budget.noteRefusal(for: url, status: 429)
        let abort = Flag()
        let outcome = Result()
        let target = url
        Thread.detachNewThread {
            outcome.finish(budget.acquire(for: target, label: "pump", timeout: 120,
                                          shouldAbort: { abort.value }))
        }
        try await waitFor { budget.snapshot(for: url)?.paced == true && budget.snapshot(for: url)?.inflight == 0 }

        abort.set()
        try await waitFor { outcome.done }
        #expect(outcome.ticket == nil)
        #expect(budget.snapshot(for: url)?.inflight == 0, "an aborted caller is not on the link")

        // The bucket holds its full burst of two once the quiet period has passed: the aborted
        // caller consumed none of it.
        clock.advance(by: 4)
        for _ in 0..<2 {
            let ticket = budget.tryAcquire(for: url, label: "next")
            #expect(ticket?.granted == true, "a token went to the caller that had left")
            budget.release(ticket)
        }
    }

    @Test("an abort that is already set returns before anything is taken")
    func abortBeforeTheWait() {
        let budget = OriginRequestBudget()
        #expect(budget.acquire(for: url, label: "pump", timeout: 1, shouldAbort: { true }) == nil)
        #expect(budget.snapshot(for: url) == nil, "nothing was counted for an aborted caller")
    }

    @Test("a caller that is never aborted waits and is granted as before")
    func noAbortKeepsTheOldBehaviour() async throws {
        let budget = OriginRequestBudget()
        budget.setHostLimit(1, for: url)
        let held = budget.acquire(for: url, label: "holder", timeout: 1)
        let outcome = Result()
        let target = url
        Thread.detachNewThread {
            outcome.finish(budget.acquire(for: target, label: "pump", timeout: 120,
                                          shouldAbort: { false }))
        }
        try await waitFor { budget.snapshot(for: url)?.waiting == 1 }
        budget.release(held)
        try await waitFor { outcome.done }
        #expect(outcome.ticket?.granted == true)
        budget.release(outcome.ticket)
        #expect(budget.snapshot(for: url)?.inflight == 0)
    }
}
