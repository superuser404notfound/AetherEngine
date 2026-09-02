import Testing
import Foundation
@testable import AetherEngine

/// #377: the reader fetches over four URLSession pools whose `httpMaximumConnectionsPerHost` caps
/// do not compose, so an origin that meters concurrency sees a ceiling nobody declared. The budget
/// counts requests per origin (which is what such an origin counts) and caps them once a limit is
/// known, without ever blocking a read forever on a guess.
@Suite("Origin request budget", .serialized)
struct OriginRequestBudgetTests {

    private let url = URL(string: "https://cdn.example.com:443/signed/movie.mkv?token=a")!
    /// Same host, different signed path and token: a metered CDN rotates these, so a per-URL
    /// budget would start at zero on every refresh.
    private let sameOriginRotatedToken = URL(string: "https://cdn.example.com:443/signed/movie.mkv?token=b")!
    private let otherOrigin = URL(string: "https://other.example.com:443/movie.mkv")!

    private func freshBudget(now: @escaping () -> DispatchTime = { .now() }) -> OriginRequestBudget {
        let budget = OriginRequestBudget(now: now)
        return budget
    }

    @Test("an uncapped origin hands out tickets without waiting and only tallies")
    func uncappedNeverWaits() {
        let budget = freshBudget()
        let a = budget.acquire(for: url, label: "pump", timeout: 0.1)
        let b = budget.acquire(for: url, label: "detour", timeout: 0.1)
        let c = budget.acquire(for: url, label: "probe", timeout: 0.1)

        #expect(a?.granted == true)
        #expect(b?.granted == true)
        #expect(c?.granted == true)
        #expect(a?.waitedMs == 0, "an uncapped acquire must not spend time in the semaphore")
        #expect(budget.snapshot(for: url)?.inflight == 3)
        #expect(budget.snapshot(for: url)?.peakInflight == 3,
                "the peak is the measurement the reporter could not take from outside")

        budget.release(a); budget.release(b); budget.release(c)
        #expect(budget.snapshot(for: url)?.inflight == 0, "every ticket must return its slot")
        #expect(budget.snapshot(for: url)?.peakInflight == 3, "the peak survives the release")
    }

    @Test("the budget is keyed on the origin, so a rotated signed token shares one ceiling")
    func rotatedTokenSharesTheBudget() {
        let budget = freshBudget()
        let a = budget.acquire(for: url, label: "pump", timeout: 0.1)
        let b = budget.acquire(for: sameOriginRotatedToken, label: "detour", timeout: 0.1)

        #expect(budget.snapshot(for: url)?.inflight == 2,
                "two requests against one host must count as two whatever the signed path says")
        #expect(budget.snapshot(for: otherOrigin) == nil, "a different host has its own budget")

        budget.release(a); budget.release(b)
    }

    /// Wait for a condition the budget itself reports, rather than for a duration. A sleep long
    /// enough to "probably" have parked the waiter is a margin against a derived time bound, and
    /// the first thing a slower CI machine takes away.
    private func waitUntil(_ deadlineSeconds: Double = 10,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: deadlineSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    @Test("a capped origin makes the second request wait for the first to finish")
    func cappedSerialises() async {
        let budget = freshBudget()
        budget.setHostLimit(1, for: url)

        let first = budget.acquire(for: url, label: "pump", timeout: 1)
        #expect(first?.granted == true)

        let secondGranted = UnsafeFlag()
        let secondStarted = UnsafeFlag()
        DispatchQueue.global().async {
            secondStarted.set(true)
            let second = budget.acquire(for: url, label: "detour", timeout: 20)
            secondGranted.set(second?.granted == true)
            budget.release(second)
        }
        // Waiting for the park without first waiting for the THREAD spends the observation window
        // on libdispatch. A green run and a run where the block never got a thread then look
        // identical, and the second one reports a budget defect that was never measured. Seen on
        // CI: `parked` false with `secondGranted` still nil, i.e. the acquire had not happened.
        #expect(await waitUntil(30) { secondStarted.value == true },
                "the waiter never got a thread; nothing about the budget was measured")
        let parked = await waitUntil { budget.snapshot(for: url)?.waiting == 1 }
        #expect(parked, "the second acquire must park rather than proceed")
        #expect(secondGranted.value == nil, "the second request must not proceed while the slot is held")

        budget.release(first)
        let handed = await waitUntil { secondGranted.value == true }
        #expect(handed, "releasing the slot must hand it to the waiter")
        _ = await waitUntil { budget.snapshot(for: url)?.inflight == 0 }
        #expect(budget.snapshot(for: url)?.inflight == 0)
    }

    @Test("a waiter that times out proceeds anyway rather than blocking the read forever")
    func timeoutProceedsWithoutASlot() {
        let budget = freshBudget()
        budget.setHostLimit(1, for: url)
        let held = budget.acquire(for: url, label: "pump", timeout: 1)

        let denied = budget.acquire(for: url, label: "detour", timeout: 0.2)

        #expect(denied?.granted == false,
                "a budget is a throttle over someone else's tolerance, not a correctness barrier")
        #expect((denied?.waitedMs ?? 0) >= 150, "it must actually have waited its budget")
        #expect(budget.snapshot(for: url)?.inflight == 2,
                "proceeding uncounted would hide the very concurrency this exists to measure")

        budget.release(denied)
        budget.release(held)
        #expect(budget.snapshot(for: url)?.inflight == 0,
                "a timed-out waiter must not leak its slot")
    }

    @Test("the slot goes to the waiter at the front, not to whoever locks first")
    func releaseIsFIFO() async {
        let budget = freshBudget()
        budget.setHostLimit(1, for: url)
        let held = budget.acquire(for: url, label: "pump", timeout: 1)

        let order = UnsafeOrder()
        DispatchQueue.global().async {
            let t = budget.acquire(for: url, label: "detour", timeout: 20)
            order.append("detour")
            budget.release(t)
        }
        let parked = await waitUntil { budget.snapshot(for: url)?.waiting == 1 }
        #expect(parked, "the detour must be in the queue before the pump gives the slot back")

        // The pump releasing and immediately re-taking must not beat the parked detour: that is
        // exactly the starvation a range boundary every 32 MB would produce.
        budget.release(held)
        let reacquired = budget.acquire(for: url, label: "pump", timeout: 20)
        order.append("pump")
        budget.release(reacquired)

        _ = await waitUntil { order.first != nil }
        #expect(order.first == "detour",
                "a pump reconnecting at a range boundary must not starve a waiting detour")
    }

    @Test("a refusal halves the concurrency the origin was actually given, floor 1")
    func refusalHalvesFromObservedPeak() {
        let budget = freshBudget()
        let tickets = (0..<4).map { budget.acquire(for: url, label: "path\($0)", timeout: 0.1) }
        #expect(budget.snapshot(for: url)?.peakInflight == 4)

        #expect(budget.noteRefusal(for: url, status: 429) == 2,
                "an origin refused with four requests open has said something about four, not one")
        #expect(budget.noteRefusal(for: url, status: 429) == 1)
        #expect(budget.noteRefusal(for: url, status: 429) == 1, "the floor is one, never zero")
        #expect(budget.snapshot(for: url)?.refusals == 3)

        tickets.forEach { budget.release($0) }
    }

    @Test("an unrefused origin never arms the request-rate pacer")
    func unrefusedOriginIsNeverPaced() {
        let clock = ManualDispatchClock()
        let budget = freshBudget(now: clock.now)

        let first = budget.tryAcquire(for: url, label: "tail prefetch")
        #expect(first?.granted == true)
        #expect(budget.snapshot(for: url)?.paced == false)
        budget.release(first)

        clock.advance(by: 600)
        let later = budget.tryAcquire(for: url, label: "tail prefetch")
        #expect(later?.granted == true, "time alone must not arm an origin that never refused")
        #expect(budget.snapshot(for: url)?.paced == false)
        budget.release(later)
    }

    @Test("the first refusal arms a two-second quiet period with an empty bucket")
    func firstRefusalArmsThePacer() {
        let clock = ManualDispatchClock()
        let budget = freshBudget(now: clock.now)

        budget.noteRefusal(for: url, status: 429)
        #expect(budget.snapshot(for: url)?.paced == true)
        #expect(budget.tryAcquire(for: url, label: "tail prefetch") == nil)

        clock.advance(by: 1.99)
        #expect(budget.tryAcquire(for: url, label: "tail prefetch") == nil,
                "the quiet period, not token refill, is the first gate")
        clock.advance(by: 0.02)
        let ticket = budget.tryAcquire(for: url, label: "tail prefetch")
        #expect(ticket?.granted == true)
        budget.release(ticket)
    }

    @Test("Retry-After overrides the learned quiet period")
    func retryAfterOverridesQuietPeriod() {
        let clock = ManualDispatchClock()
        let budget = freshBudget(now: clock.now)

        budget.noteRefusal(for: url, status: 429, retryAfter: 6)
        clock.advance(by: 5.99)
        #expect(budget.tryAcquire(for: url, label: "tail prefetch") == nil)
        clock.advance(by: 0.02)
        let ticket = budget.tryAcquire(for: url, label: "tail prefetch")
        #expect(ticket?.granted == true)
        budget.release(ticket)
    }

    @Test("refusals in one streak double the quiet period and cap it at fifteen seconds")
    func refusalQuietPeriodDoublesAndCaps() {
        let clock = ManualDispatchClock()
        let budget = freshBudget(now: clock.now)

        budget.noteRefusal(for: url, status: 429)
        budget.noteRefusal(for: url, status: 429)
        clock.advance(by: 3.99)
        #expect(budget.tryAcquire(for: url, label: "tail prefetch") == nil)
        clock.advance(by: 0.02)
        let afterFour = budget.tryAcquire(for: url, label: "tail prefetch")
        #expect(afterFour?.granted == true, "the second refusal in the streak waits four seconds")
        budget.release(afterFour)

        budget.noteRefusal(for: url, status: 429)
        budget.noteRefusal(for: url, status: 429)
        clock.advance(by: 14.99)
        #expect(budget.tryAcquire(for: url, label: "tail prefetch") == nil)
        clock.advance(by: 0.02)
        let afterCap = budget.tryAcquire(for: url, label: "tail prefetch")
        #expect(afterCap?.granted == true, "the fourth refusal caps at fifteen seconds, not sixteen")
        budget.release(afterCap)
    }

    @Test("an acquire inside the quiet period waits and proceeds when the injected clock advances")
    func acquireWaitsForThePacer() async {
        let clock = ManualDispatchClock()
        let budget = freshBudget(now: clock.now)
        budget.noteRefusal(for: url, status: 429)

        let started = UnsafeFlag()
        let granted = UnsafeFlag()
        DispatchQueue.global().async {
            started.set(true)
            let ticket = budget.acquire(for: self.url, label: "pump", timeout: 1)
            granted.set(ticket?.granted == true)
            budget.release(ticket)
        }

        #expect(await waitUntil { started.value == true })
        #expect(await waitUntil { budget.snapshot(for: url)?.inflight == 1 },
                "the request owns its concurrency slot while the pacer holds it")
        #expect(granted.value == nil, "the request must remain parked inside the quiet period")

        clock.advance(by: 2)
        #expect(await waitUntil { granted.value == true },
                "advancing the injected clock must release the request without a two-second sleep")
    }

    @Test("a paced acquire that exhausts its caller budget proceeds ungranted")
    func pacedAcquireRespectsTimeout() {
        let clock = ManualDispatchClock()
        let budget = freshBudget(now: clock.now)
        budget.noteRefusal(for: url, status: 429)

        let ticket = budget.acquire(for: url, label: "pump", timeout: 0)
        #expect(ticket?.granted == false,
                "request pacing is a throttle, not a correctness barrier")
        #expect(budget.snapshot(for: url)?.inflight == 1,
                "an over-budget request still counts as present on the link")
        budget.release(ticket)
        #expect(budget.snapshot(for: url)?.inflight == 0)
    }

    @Test("tokens refill at three per second and cap at four")
    func tokensRefillAndCap() {
        let clock = ManualDispatchClock()
        let budget = freshBudget(now: clock.now)
        budget.noteRefusal(for: url, status: 429)
        clock.advance(by: 2)

        for _ in 0..<4 {
            let ticket = budget.tryAcquire(for: url, label: "tail prefetch")
            #expect(ticket?.granted == true)
            budget.release(ticket)
        }
        #expect(budget.tryAcquire(for: url, label: "tail prefetch") == nil,
                "the burst capacity is four")

        clock.advance(by: 0.334)
        let refilled = budget.tryAcquire(for: url, label: "tail prefetch")
        #expect(refilled?.granted == true, "one third of a second refills one token")
        budget.release(refilled)
        #expect(budget.tryAcquire(for: url, label: "tail prefetch") == nil)

        clock.advance(by: 10)
        for _ in 0..<4 {
            let ticket = budget.tryAcquire(for: url, label: "tail prefetch")
            #expect(ticket?.granted == true)
            budget.release(ticket)
        }
        #expect(budget.tryAcquire(for: url, label: "tail prefetch") == nil,
                "a long refill must still cap the bucket at four")
    }

    @Test("twenty clean grants disarm pacing without changing the learned concurrency limit")
    func cleanGrantsDisarmPacing() {
        let clock = ManualDispatchClock()
        let budget = freshBudget(now: clock.now)
        budget.noteRefusal(for: url, status: 429)
        clock.advance(by: 2)

        for _ in 0..<19 {
            clock.advance(by: 1)
            let ticket = budget.tryAcquire(for: url, label: "tail prefetch")
            #expect(ticket?.granted == true)
            budget.release(ticket)
        }
        #expect(budget.snapshot(for: url)?.paced == true)

        clock.advance(by: 1)
        let twentieth = budget.tryAcquire(for: url, label: "tail prefetch")
        #expect(twentieth?.granted == true)
        budget.release(twentieth)
        #expect(budget.snapshot(for: url)?.paced == false)
        #expect(budget.limit(for: url) == 1,
                "disarming request pacing must not undo upstream's learned concurrency limit")
    }

    @Test("sixty seconds without a refusal disarms pacing")
    func quietOriginDisarmsPacing() {
        let clock = ManualDispatchClock()
        let budget = freshBudget(now: clock.now)
        budget.noteRefusal(for: url, status: 429)

        clock.advance(by: 59.9)
        #expect(budget.snapshot(for: url)?.paced == true)
        clock.advance(by: 0.2)
        #expect(budget.snapshot(for: url)?.paced == false)
        let ticket = budget.tryAcquire(for: url, label: "tail prefetch")
        #expect(ticket?.granted == true, "the bucket is irrelevant after the quiet disarm")
        budget.release(ticket)
    }

    @Test("a host concurrency limit still wins while request pacing is armed")
    func hostLimitStillWinsWithPacing() {
        let clock = ManualDispatchClock()
        let budget = freshBudget(now: clock.now)
        budget.setHostLimit(1, for: url)
        budget.noteRefusal(for: url, status: 429)
        clock.advance(by: 2)

        let held = budget.tryAcquire(for: url, label: "pump")
        #expect(held?.granted == true)
        #expect(budget.tryAcquire(for: url, label: "tail prefetch") == nil,
                "available tokens do not override a full host concurrency budget")
        #expect(budget.limit(for: url) == 1)
        budget.release(held)
    }

    @Test("a host limit wins over anything learned, in both directions")
    func hostLimitWins() {
        let budget = freshBudget()
        budget.setHostLimit(1, for: url)
        #expect(budget.limit(for: url) == 1,
                "a host that knows its provider allows one connection should not wait to be refused")

        _ = budget.acquire(for: url, label: "pump", timeout: 0.1)
        #expect(budget.noteRefusal(for: url, status: 429) == 1)

        budget.setHostLimit(4, for: url)
        #expect(budget.limit(for: url) == 4)
        #expect(budget.noteRefusal(for: url, status: 503) == 4,
                "a refusal must not halve past a ceiling the host declared")
    }

    @Test("a refusal is remembered with a clock, so the revive arm can tell metering from death")
    func refusedRecentlyIsTimeBounded() {
        let budget = freshBudget()
        #expect(!budget.refusedRecently(url, within: 30))

        budget.noteRefusal(for: url, status: 429)
        #expect(budget.refusedRecently(url, within: 30),
                "the FFmpeg-side error code is -1 and cannot carry this")
        #expect(!budget.refusedRecently(url, within: 0),
                "a zero window must not report a refusal that just happened as ongoing")
        #expect(!budget.refusedRecently(otherOrigin, within: 30), "refusals do not cross origins")
    }

    @Test("a speculative fetch takes a free slot but never queues for one")
    func tryAcquireNeverWaits() {
        // Measured against a metered origin: the tail prefetch went out microseconds before the
        // first data connection and got the PUMP refused, on the very first open, which is the
        // "429 before any real number of requests" in the report. It also must not queue: a
        // speculative fetch that waits has given up the round trip it existed to save and still
        // costs the origin a request.
        let budget = freshBudget()
        budget.setHostLimit(1, for: url)

        let held = budget.acquire(for: url, label: "pump", timeout: 1)
        let speculative = budget.tryAcquire(for: url, label: "tail prefetch")
        #expect(speculative == nil, "with the slot taken, the speculative fetch must not be made at all")

        budget.release(held)
        let now = budget.tryAcquire(for: url, label: "tail prefetch")
        #expect(now?.granted == true, "with a slot free it is a normal fetch")
        #expect(budget.snapshot(for: url)?.inflight == 1,
                "the speculative fetch counts like any other request; not counting it is what hid the collision")
        budget.release(now)
    }

    @Test("a refusal from a redirected CDN is still findable under the URL the host loaded")
    func refusalCrossesTheRedirect() {
        // The shape in the report: a proxy mints signed links and 302s to a CDN, the CDN is what
        // refuses, and the engine's revive arm only ever knows the proxy URL. Keying the verdict
        // solely on the refusing host would build a classification that is never once reached.
        let budget = freshBudget()
        let proxy = URL(string: "https://proxy.example.com/dl/abc")!
        let cdn = URL(string: "https://edge-7.cdn.example.net/signed/abc?exp=1&sig=x")!

        budget.noteRefusal(for: cdn, status: 429)
        budget.noteRefusalWitnessed(for: proxy)

        #expect(budget.refusedRecently(proxy, within: 60),
                "the verdict must be findable under the URL the host actually loaded")
        #expect(budget.refusedRecently(cdn, within: 60))
        #expect(budget.limit(for: cdn) == 1, "the host that refused is the one whose budget comes down")
        #expect(budget.limit(for: proxy) == nil,
                "the proxy did not refuse us and must not be throttled for the CDN's answer")
    }

    @Test("a single-slot origin reports that its speculative parallel paths must not run")
    func serialOriginSwitchesOffSpeculation() {
        let budget = freshBudget()
        #expect(!budget.requiresSerialRequests(url), "an uncapped origin keeps every optimisation")

        budget.setHostLimit(2, for: url)
        #expect(!budget.requiresSerialRequests(url))

        budget.setHostLimit(1, for: url)
        #expect(budget.requiresSerialRequests(url),
                "at one slot the speculative paths must be switched off, not queued behind a slot their own caller holds")
    }

    @Test("an origin with no host is not budgeted rather than sharing one bucket")
    func unkeyableURLIsNotBudgeted() {
        let budget = freshBudget()
        let fileURL = URL(fileURLWithPath: "/tmp/local.mkv")
        #expect(budget.acquire(for: fileURL, label: "pump", timeout: 0.1) == nil)
        #expect(budget.limit(for: fileURL) == nil)
        #expect(!budget.refusedRecently(fileURL, within: 30))
        budget.release(nil)
    }

    // MARK: - Dropped targets and the refusal shape (#377 round 5)

    /// The books answer for a chain, so a target dropped while asking one end is known from the
    /// other. Which matters because the two ends have different lifetimes: the source URL is what
    /// the host loaded and what every later reader is built from, the target is a lease.
    @Test("a dropped target is known from the source URL, and folds with the chain")
    func droppedTargetIsChainScoped() {
        let budget = freshBudget()
        let target = URL(string: "https://nexus-179.cdn.example.st/file.mkv?sig=a")!
        budget.noteRedirect(from: url, to: target)
        budget.noteTargetDropped(target, from: url)

        let targetKey = OriginRequestBudget.originKey(for: target)!
        #expect(budget.droppedTargets(for: url) == [targetKey])
        #expect(budget.droppedTargets(for: target) == [targetKey],
                "either end of one chain has to give the same answer")
        #expect(budget.droppedTargets(for: otherOrigin).isEmpty,
                "another origin's refusals are not this one's history")
    }

    /// A second target dropped in a later window does not evict the first. One slot described one
    /// window and the reporter's session refused in three.
    @Test("every dropped target of a chain is kept, not just the last")
    func everyDroppedTargetIsKept() {
        let budget = freshBudget()
        let first = URL(string: "https://nexus-042.cdn.example.st/f.mkv")!
        let second = URL(string: "https://nexus-179.cdn.example.st/f.mkv")!
        budget.noteRedirect(from: url, to: first)
        budget.noteTargetDropped(first, from: url)
        budget.noteRedirect(from: url, to: second)
        budget.noteTargetDropped(second, from: url)

        #expect(budget.droppedTargets(for: url).count == 2)
    }

    /// #377 round 5: peak concurrency is the one fact that can refute the reading the status code
    /// invites. An origin that refused while we never had more than one request open did not refuse
    /// us for asking too much at once, whatever a 429 suggests, and the fix for the two cases is
    /// different.
    @Test("the give-up note reports the books, and names peak 1 as not a concurrency ceiling")
    func refusalShapeNoteSeparatesConcurrencyFromARefusingTarget() {
        let budget = freshBudget()
        let target = URL(string: "https://nexus-179.cdn.example.st/f.mkv")!
        budget.noteRedirect(from: url, to: target)

        #expect(budget.refusalShapeNote(for: url).isEmpty,
                "an origin that never refused has nothing to say at a give-up")

        let ticket = budget.acquire(for: url, label: "pump", timeout: 0.1)
        budget.noteRefusal(for: target, status: 429)
        budget.release(ticket)
        budget.noteTargetDropped(target, from: url)

        let note = budget.refusalShapeNote(for: url)
        #expect(note.contains("peak 1 in flight"), Comment(rawValue: note))
        #expect(note.contains("1 refusals") || note.contains("1 refusal"), Comment(rawValue: note))
        #expect(note.contains("nexus-179.cdn.example.st"), Comment(rawValue: note))
        #expect(note.contains("cannot exceed a concurrency ceiling"), Comment(rawValue: note))
    }

    /// The other half of the same line: with two requests seen at once, a refusal MIGHT be about
    /// concurrency, and the note must not claim otherwise.
    @Test("a peak above one withholds the concurrency verdict")
    func refusalShapeNoteIsSilentOnConcurrencyAbovePeakOne() {
        let budget = freshBudget()
        let target = URL(string: "https://nexus-179.cdn.example.st/f.mkv")!
        budget.noteRedirect(from: url, to: target)
        let a = budget.acquire(for: url, label: "pump", timeout: 0.1)
        let b = budget.acquire(for: url, label: "detour", timeout: 0.1)
        budget.noteRefusal(for: target, status: 429)
        budget.noteTargetDropped(target, from: url)
        budget.release(a); budget.release(b)

        let note = budget.refusalShapeNote(for: url)
        #expect(note.contains("peak 2 in flight"), Comment(rawValue: note))
        #expect(!note.contains("cannot exceed a concurrency ceiling"), Comment(rawValue: note))
    }

    /// A chain fold merges two sets of books, and the dropped targets are books.
    @Test("folding a chain keeps both ends' dropped targets")
    func foldMergesDroppedTargets() {
        let budget = freshBudget()
        let target = URL(string: "https://nexus-179.cdn.example.st/f.mkv")!
        let stale = URL(string: "https://nexus-042.cdn.example.st/f.mkv")!
        budget.noteTargetDropped(stale, from: target)
        budget.noteRedirect(from: url, to: target)

        #expect(budget.droppedTargets(for: url).contains(OriginRequestBudget.originKey(for: stale)!),
                "the target's history joins the chain it is folded into")
    }
}

/// Minimal cross-thread carriers; the suite runs actual concurrency, so the expectations need a
/// safe place to land.
private final class UnsafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool?
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: Bool) { lock.lock(); _value = v; lock.unlock() }
}

private final class UnsafeOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var first: String? { lock.lock(); defer { lock.unlock() }; return items.first }
    func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
}

/// Monotonic test clock for the refusal pacer. The production wait polls this clock, so advancing
/// it releases a paced request without making the suite spend the CDN's two-to-fifteen-second
/// quiet periods on wall time.
private final class ManualDispatchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanoseconds: UInt64 = 1_000_000_000

    func now() -> DispatchTime {
        lock.lock(); defer { lock.unlock() }
        return DispatchTime(uptimeNanoseconds: nanoseconds)
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        nanoseconds += UInt64((seconds * 1_000_000_000).rounded())
    }
}
