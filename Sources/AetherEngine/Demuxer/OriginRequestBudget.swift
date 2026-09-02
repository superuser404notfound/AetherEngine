import Foundation

/// #377: one request budget per origin, shared by every path the reader fetches on.
///
/// `httpMaximumConnectionsPerHost` is a per-`URLSession` cap, and `AVIOReader` fetches over four
/// pools: `persistentSession` (2) for the pump's ranges, `chunkSession` (2) for detour blocks,
/// `probeSession` on `URLSessionConfiguration.default` (6) for size probes and HEAD, plus a
/// per-call streaming session. Those caps do not compose. Against one signed CDN URL a pump range,
/// a detour block and a probe can all be open at once, and a second reader (the subtitle side
/// demuxer) shares the same static pools, so the ceiling is a sum nobody wrote down.
///
/// The cap also measures the wrong thing. `httpMaximumConnectionsPerHost` bounds TCP connections,
/// and over HTTP/2 URLSession multiplexes every request of a session onto one of them, so a cap of
/// 1 there bounds nothing at all while the origin still counts the requests. This budget counts
/// requests, which is what an origin metering us counts, and is therefore equally true on h2 and
/// http/1.1. `ReaderTransportLog` records which one is actually in use.
///
/// Counting is unconditional; capping is not. With no limit set, `acquire` hands out a ticket
/// immediately and only tallies, so a healthy origin sees exactly the behaviour it saw before this
/// existed. A limit arrives one of two ways: the host names it (`LoadOptions.maxConcurrentSourceRequests`),
/// or the origin does, by answering 429/503/509, after which the budget halves from the concurrency
/// it had actually reached. There is no automatic increase: an origin that has metered us once is
/// treated as metering for the rest of the process, which costs some parallelism and no correctness.
/// A refusal also arms a request-rate pacer for that origin. It is deliberately learned rather than
/// host-configured: the measured CDN served eight parallel 32 MB reads but first refused a run of
/// 256 KB reads after 36 requests in 10 seconds, so concurrency and request rate are separate limits.
/// Twenty clean grants or 60 seconds without another refusal disarm pacing; the learned concurrency
/// ceiling remains because its recovery policy belongs to the existing budget.
///
/// A redirect chain is ONE origin here (#388). A metered source is routinely a portal that 302s to
/// the host serving the bytes, and the host loading it can only name the portal: keeping a separate
/// bucket per hop meant the declared ceiling stopped at the proxy, the pump's slot was booked
/// against an origin it had stopped fetching from, and a detour block opened as a second request
/// against a host whose books showed nothing in flight. `noteRedirect` folds them.
///
/// Deadlock is excluded structurally rather than managed. A reader that already holds a ticket must
/// never block on a second one, so at `limit == 1` the speculative parallel paths (detour blocks,
/// the tail prefetch, the staggered probe fan) are switched off instead of queued, and each of them
/// already has a serial fallback: the detour's is repositioning the persistent connection, the
/// probe fan's is running its probes in order. What remains queueing on the semaphore are requests
/// that no reader holds a ticket across.
final class OriginRequestBudget: @unchecked Sendable {

    static let shared = OriginRequestBudget()

    /// The measured origin first refused 36 requests in 10 seconds. A four-request bucket refilling
    /// at three per second stays just below that observed window while retaining a small read burst.
    static let pacerCapacity = 4.0
    static let pacerRefillPerSecond = 3.0
    private static let firstQuietPeriod: TimeInterval = 2
    private static let maximumQuietPeriod: TimeInterval = 15
    private static let cleanGrantsToDisarm = 20
    private static let quietSecondsToDisarm: TimeInterval = 60

    /// Scheme + host + port, matching `SuffixRangeSupport.originKey`. Deliberately NOT the full
    /// URL: a metered CDN hands out signed URLs with a rotating token, so a per-URL budget would
    /// start at zero on every refresh and cap nothing. What meters us is the host.
    static func originKey(for url: URL) -> String? {
        SuffixRangeSupport.originKey(for: url)
    }

    /// A held slot. Released exactly once, by `release`, whoever ends the request. Not a
    /// `deinit`-based guard on purpose: the pump's slot is held across a connection, so its
    /// lifetime is the connection's, not a scope's.
    struct Ticket {
        /// The origin key the request was made against, NOT the chain it belongs to: a redirect
        /// folds this origin into a chain after the slot was taken, so the bucket is resolved when
        /// the ticket is returned rather than when it was handed out (#388).
        let key: String
        let label: String
        /// Time spent waiting for a concurrency slot or the refusal pacer. Diagnostic only.
        let waitedMs: Double
        /// False when no room came free within the caller's budget and it proceeded anyway.
        let granted: Bool
    }

    struct Snapshot {
        var inflight: Int
        var peakInflight: Int
        var limit: Int?
        var paced: Bool
        var refusals: Int
        var secondsSinceLastRefusal: Double?
        /// How many callers are parked waiting for a slot right now. Reported so a test can wait on
        /// the state it means to set up rather than on a sleep long enough to "probably" reach it,
        /// which is a margin against a derived time bound and fails on a slower machine.
        var waiting: Int
    }

    private struct OriginState {
        var inflight = 0
        var peakInflight = 0
        /// nil = count only. Set by the host, or learned from a refusal.
        var limit: Int?
        var hostLimit: Int?
        var refusals = 0
        var lastRefusalAt: DispatchTime?
        /// nil `quietUntil` means the request-rate pacer is inert. The bucket remains untouched
        /// until the first refusal so an unmetered origin keeps its old request shape exactly.
        var tokens = 0.0
        var lastRefillAt: DispatchTime?
        var quietUntil: DispatchTime?
        var refusalStreak = 0
        var cleanGrants = 0
        /// FIFO of waiters. Front is served first, so the pump cannot re-take the slot it just
        /// released ahead of a detour that has been waiting.
        var waiters: [DispatchSemaphore] = []
        /// #377 round 5: targets this chain resolved to and then DROPPED for refusals, by origin
        /// key, until one is seen answering again. Kept HERE rather than on the reader because the
        /// reader is the one thing in this picture that does not survive: a metered revive builds a
        /// fresh demuxer, and a fresh demuxer's reader starts with an empty history, so the target
        /// the previous reader dropped seconds ago reads to it as one the source resolved freshly.
        /// That is the single verdict that puts metering back on the table, and the readers that
        /// most need the history were the only ones without it, because the rebuild is what creates
        /// them (reporter's capture: the same host answered as `dropped and minted again` 8 times
        /// from the reader that dropped it and as `resolved freshly` 32 times from the rebuilds).
        var droppedTargets: Set<String> = []
    }

    private let lock = NSLock()
    private var origins: [String: OriginState] = [:]
    /// #388: member origin key -> the key its chain is kept under. A redirect target is not a
    /// second origin as far as a request budget is concerned: every request keyed on either end is
    /// answered by the same server, so both ends share one set of books.
    private var chainHead: [String: String] = [:]
    private let now: () -> DispatchTime

    init(now: @escaping () -> DispatchTime = { .now() }) {
        self.now = now
    }

    /// Resolve an origin key to the key its chain is kept under. Called under `lock`.
    private func headLocked(_ key: String) -> String {
        var current = key
        // Bounded rather than trusting the map to be acyclic: `noteRedirect` never builds a cycle,
        // and a walk that cannot terminate is not worth the certainty it would need.
        for _ in 0..<8 {
            guard let next = chainHead[current], next != current else { return current }
            current = next
        }
        return current
    }

    // MARK: - Redirect chains

    /// A request against `source` is being answered by `target`, i.e. the reader has just been
    /// redirected. Fold the two origins into one budget.
    ///
    /// The ceiling is the reason this exists. A host that declares
    /// `LoadOptions.maxConcurrentSourceRequests` knows what its PROVIDER allows and can only name
    /// the URL it loads; on the shape this comes from (an Xtream portal that 302s to the media host
    /// that actually counts the connections) that ceiling stopped at the proxy hop, and the host
    /// cannot route around it - resolving the redirect itself before `load` would spend the one
    /// connection the panel allows.
    ///
    /// Counting is the other half. The pump takes its slot against the URL it asks for, so after a
    /// 302 it streams from a host whose books show nothing in flight, and the next reader to look
    /// there sees a free slot that is not free. Folding the chain fixes both without re-keying a
    /// ticket mid-connection: the slot the pump holds is already the chain's.
    ///
    /// Deliberate consequence: a refusal now lowers the whole chain, including the portal. #377
    /// kept them apart on the reasoning that the proxy did not refuse us, which is true and no
    /// longer the point - a request to the proxy for this source IS a request to the host that
    /// refused, because the proxy only ever answers it with a redirect there.
    ///
    /// A target that already belongs to a chain keeps it: two portals handing out links on one edge
    /// host would otherwise let a ceiling declared for one of them spread to the other.
    func noteRedirect(from source: URL, to target: URL) {
        guard let sourceKey = Self.originKey(for: source),
              let targetKey = Self.originKey(for: target) else { return }
        lock.lock()
        let head = headLocked(sourceKey)
        let targetHead = headLocked(targetKey)
        guard head != targetHead else { lock.unlock(); return }
        // Already somebody's redirect target: leave it on the chain it joined first.
        guard targetHead == targetKey else { lock.unlock(); return }

        var merged = origins[head] ?? OriginState()
        let joining = origins[targetHead]
        if let joining {
            merged.inflight += joining.inflight
            merged.peakInflight = max(max(merged.peakInflight, joining.peakInflight), merged.inflight)
            merged.refusals += joining.refusals
            merged.limit = Self.tighter(merged.limit, joining.limit)
            merged.hostLimit = Self.tighter(merged.hostLimit, joining.hostLimit)
            if let hostLimit = merged.hostLimit {
                merged.limit = Self.tighter(merged.limit, hostLimit)
            }
            if let theirs = joining.lastRefusalAt {
                merged.lastRefusalAt = merged.lastRefusalAt.map { max($0, theirs) } ?? theirs
            }
            if let theirQuiet = joining.quietUntil {
                if let ourQuiet = merged.quietUntil {
                    merged.tokens = min(merged.tokens, joining.tokens)
                    if let theirRefill = joining.lastRefillAt {
                        merged.lastRefillAt = merged.lastRefillAt.map { max($0, theirRefill) }
                            ?? theirRefill
                    }
                    merged.quietUntil = max(ourQuiet, theirQuiet)
                    merged.refusalStreak = max(merged.refusalStreak, joining.refusalStreak)
                    merged.cleanGrants = min(merged.cleanGrants, joining.cleanGrants)
                } else {
                    merged.tokens = joining.tokens
                    merged.lastRefillAt = joining.lastRefillAt
                    merged.quietUntil = theirQuiet
                    merged.refusalStreak = joining.refusalStreak
                    merged.cleanGrants = joining.cleanGrants
                }
            }
            merged.droppedTargets.formUnion(joining.droppedTargets)
            // Their waiters are parked on semaphores this bucket now owns; dropping them would hang
            // every one of them for its full acquire budget.
            merged.waiters.append(contentsOf: joining.waiters)
        }
        origins[targetHead] = nil
        chainHead[targetHead] = head
        origins[head] = merged
        let limit = merged.limit
        lock.unlock()

        // #377 round 4: this fires on a target's FIRST fold and never again, because the chain is
        // process-wide and only ever grows. Read as "a fresh target was reached just now" it says
        // something it cannot know, and a grep that took its absence for an absent hop is what put
        // a whole round on the wrong shape. The scope belongs in the line: the reader of a capture
        // has no other way to see it.
        EngineLog.emit(
            "[OriginBudget] \(targetKey) is served through \(head); one request budget for both"
            + (limit.map { " (limit \($0))" } ?? "")
            + ". First fold of this target this process, later hops through it are silent, "
            + "so an absent line is not an absent hop.",
            category: .demux)
    }

    private static func tighter(_ a: Int?, _ b: Int?) -> Int? {
        guard let a else { return b }
        guard let b else { return a }
        return min(a, b)
    }

    // MARK: - Acquire / release

    private static func elapsedSeconds(from earlier: DispatchTime, to later: DispatchTime) -> Double {
        guard later.uptimeNanoseconds >= earlier.uptimeNanoseconds else { return 0 }
        return Double(later.uptimeNanoseconds - earlier.uptimeNanoseconds) / 1_000_000_000
    }

    private func disarmPacerLocked(_ state: inout OriginState) {
        state.tokens = 0
        state.lastRefillAt = nil
        state.quietUntil = nil
        state.refusalStreak = 0
        state.cleanGrants = 0
    }

    private func disarmPacerIfQuietLocked(_ state: inout OriginState, at instant: DispatchTime) {
        guard state.quietUntil != nil, let refusedAt = state.lastRefusalAt,
              Self.elapsedSeconds(from: refusedAt, to: instant) >= Self.quietSecondsToDisarm
        else { return }
        disarmPacerLocked(&state)
    }

    private func refillPacerLocked(_ state: inout OriginState, at instant: DispatchTime) {
        guard let lastRefillAt = state.lastRefillAt else {
            state.lastRefillAt = instant
            return
        }
        let elapsed = Self.elapsedSeconds(from: lastRefillAt, to: instant)
        state.tokens = min(Self.pacerCapacity,
                           state.tokens + elapsed * Self.pacerRefillPerSecond)
        state.lastRefillAt = instant
    }

    private func noteCleanGrantLocked(_ state: inout OriginState) {
        state.cleanGrants += 1
        if state.cleanGrants >= Self.cleanGrantsToDisarm {
            disarmPacerLocked(&state)
        }
    }

    /// The caller already owns a concurrency slot. Hold it while the pacer waits: taking the slot
    /// first keeps the two admission rules in one order, so two callers cannot each hold one gate
    /// while waiting for the other. Polling is bounded and intentionally short so an injected test
    /// clock can advance without making the test spend the production quiet period on wall time.
    private func ticketAfterPacing(raw: String, label: String, started: DispatchTime,
                                   timeout: TimeInterval, slotWaitedMs: Double) -> Ticket {
        var pacingStarted: DispatchTime?
        let poller = DispatchSemaphore(value: 0)
        while true {
            let instant = now()
            lock.lock()
            let key = headLocked(raw)
            var state = origins[key] ?? OriginState()
            disarmPacerIfQuietLocked(&state, at: instant)

            guard let quietUntil = state.quietUntil else {
                origins[key] = state
                lock.unlock()
                let waitedMs = slotWaitedMs > 0
                    ? Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds)
                        / 1_000_000
                    : 0
                return Ticket(key: raw, label: label, waitedMs: waitedMs, granted: true)
            }

            let waitNeeded: TimeInterval
            if instant < quietUntil {
                waitNeeded = Self.elapsedSeconds(from: instant, to: quietUntil)
            } else {
                refillPacerLocked(&state, at: instant)
                if state.tokens >= 1 {
                    state.tokens -= 1
                    noteCleanGrantLocked(&state)
                    origins[key] = state
                    lock.unlock()
                    let waitedMs = slotWaitedMs > 0 || pacingStarted != nil
                        ? Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds)
                            / 1_000_000
                        : 0
                    if let pacingStarted {
                        let pacedMs = Self.elapsedSeconds(from: pacingStarted, to: DispatchTime.now())
                            * 1_000
                        EngineLog.emit(
                            "[OriginBudget] \(label) paced \(Int(pacedMs))ms",
                            category: .demux, level: .verbose)
                    }
                    return Ticket(key: raw, label: label, waitedMs: waitedMs, granted: true)
                }
                waitNeeded = (1 - state.tokens) / Self.pacerRefillPerSecond
            }
            origins[key] = state
            lock.unlock()

            let elapsed = Self.elapsedSeconds(from: started, to: DispatchTime.now())
            let remaining = timeout - elapsed
            guard remaining > 0 else {
                let waitedMs = elapsed * 1_000
                if let pacingStarted {
                    let pacedMs = Self.elapsedSeconds(from: pacingStarted, to: DispatchTime.now())
                        * 1_000
                    EngineLog.emit(
                        "[OriginBudget] \(label) paced \(Int(pacedMs))ms",
                        category: .demux, level: .verbose)
                }
                return Ticket(key: raw, label: label, waitedMs: waitedMs, granted: false)
            }

            let poll = min(remaining, max(0.001, min(waitNeeded, 0.01)))
            if pacingStarted == nil { pacingStarted = DispatchTime.now() }
            _ = poller.wait(timeout: .now() + poll)
        }
    }

    /// Take a slot for one request against `url`, waiting up to `timeout` when the origin is
    /// capped and full, or after a refusal while its request-rate pacer has no token.
    ///
    /// Always returns a ticket. A caller that could not be given room within its budget gets one
    /// with `granted == false` and proceeds: the budget is a throttle over an origin's tolerance,
    /// not a correctness barrier, and blocking a read forever to honour a guess about someone
    /// else's rate limiter trades a slow session for a dead one. The un-granted case is counted
    /// and logged, because a budget that is being routinely overrun is worth seeing.
    func acquire(for url: URL, label: String, timeout: TimeInterval) -> Ticket? {
        guard let raw = Self.originKey(for: url) else { return nil }

        let started = DispatchTime.now()
        lock.lock()
        let key = headLocked(raw)
        var state = origins[key] ?? OriginState()
        if state.limit == nil || state.inflight < (state.limit ?? Int.max) {
            state.inflight += 1
            state.peakInflight = max(state.peakInflight, state.inflight)
            origins[key] = state
            lock.unlock()
            return ticketAfterPacing(raw: raw, label: label, started: started,
                                     timeout: timeout, slotWaitedMs: 0)
        }
        let semaphore = DispatchSemaphore(value: 0)
        state.waiters.append(semaphore)
        origins[key] = state
        lock.unlock()

        let signalled = semaphore.wait(timeout: .now() + timeout) == .success
        let waitedMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000

        if signalled {
            // `release` counted us in before signalling, so the slot is already ours.
            return ticketAfterPacing(raw: raw, label: label, started: started,
                                     timeout: timeout, slotWaitedMs: waitedMs)
        }

        // Timed out. Drop out of the queue and proceed uncounted-for: a slot handed to us between
        // the timeout and the lock would otherwise be leaked by a waiter that is no longer waiting.
        lock.lock()
        // Resolved again: a redirect seen while this caller was parked folds its origin into a
        // chain, and the bucket it queued on is then kept under the chain's key.
        let keyNow = headLocked(raw)
        var timedOut = origins[keyNow] ?? OriginState()
        if let i = timedOut.waiters.firstIndex(where: { $0 === semaphore }) {
            timedOut.waiters.remove(at: i)
            timedOut.inflight += 1   // proceeding anyway; stay honest about what is on the link
        }
        // The `else` is the race where a release signalled us between the timeout firing and this
        // lock: it already removed us from the queue AND counted the slot in, so there is nothing
        // to add. Counting again here would inflate `inflight` by one permanently, since the
        // matching `release` only ever subtracts one.
        timedOut.peakInflight = max(timedOut.peakInflight, timedOut.inflight)
        let limitDesc = timedOut.limit.map(String.init) ?? "none"
        origins[keyNow] = timedOut
        lock.unlock()

        EngineLog.emit(
            "[OriginBudget] \(label) proceeded without a slot after \(Int(waitedMs))ms "
            + "(limit \(limitDesc))",
            category: .demux, level: .verbose)
        return Ticket(key: raw, label: label, waitedMs: waitedMs, granted: false)
    }

    /// Take a slot only if one is free right now, never waiting. For SPECULATIVE requests: the tail
    /// prefetch exists to save a round trip it is already racing, so a version of it that queues has
    /// given up the only thing it was for and still costs the origin a request. nil means "do not
    /// make this request at all", which is a complete answer for a fetch nobody is waiting on.
    func tryAcquire(for url: URL, label: String) -> Ticket? {
        guard let raw = Self.originKey(for: url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let key = headLocked(raw)
        var state = origins[key] ?? OriginState()
        let instant = now()
        disarmPacerIfQuietLocked(&state, at: instant)
        guard state.inflight < (state.limit ?? Int.max) else {
            origins[key] = state
            return nil
        }
        if let quietUntil = state.quietUntil {
            guard instant >= quietUntil else {
                origins[key] = state
                return nil
            }
            refillPacerLocked(&state, at: instant)
            guard state.tokens >= 1 else {
                origins[key] = state
                return nil
            }
            state.tokens -= 1
            noteCleanGrantLocked(&state)
        }
        state.inflight += 1
        state.peakInflight = max(state.peakInflight, state.inflight)
        origins[key] = state
        return Ticket(key: raw, label: label, waitedMs: 0, granted: true)
    }

    func release(_ ticket: Ticket?) {
        guard let ticket else { return }
        lock.lock()
        // Resolved at RELEASE time, not at acquire time: the redirect that folds this request's
        // origin into a chain arrives after the slot was taken, which is the whole shape of #388.
        let key = headLocked(ticket.key)
        guard var state = origins[key] else { lock.unlock(); return }
        state.inflight = max(0, state.inflight - 1)
        // Hand the slot straight to the front of the queue rather than dropping the count and
        // letting whoever locks first take it: without that, a pump reconnecting at a range
        // boundary beats a detour that has been waiting since the last one.
        if !state.waiters.isEmpty, state.inflight < (state.limit ?? Int.max) {
            let next = state.waiters.removeFirst()
            state.inflight += 1
            origins[key] = state
            lock.unlock()
            next.signal()
            return
        }
        origins[key] = state
        lock.unlock()
    }

    // MARK: - Learning the limit

    /// The origin answered 429/503/509. Halve the concurrency it was actually given, floor 1,
    /// and arm its request-rate pacer.
    ///
    /// Halving from the observed peak rather than dropping straight to 1 keeps the answer
    /// proportionate to what we were doing: an origin refused while four requests were open has
    /// said something about four, not about one. Repeated refusals halve again, so an origin that
    /// really allows one connection reaches 1 within a few refusals. A host limit always wins.
    /// Returns the limit now in force, if any.
    ///
    /// #388: on a chain the answer is charged to the chain. The host that refused and the host we
    /// asked are one origin as far as requests are concerned, so halving only the far end would
    /// leave the near end free to open exactly the request that was just refused.
    @discardableResult
    func noteRefusal(for url: URL, status: Int, retryAfter: TimeInterval? = nil) -> Int? {
        guard let raw = Self.originKey(for: url) else { return nil }
        let instant = now()
        lock.lock()
        let key = headLocked(raw)
        var state = origins[key] ?? OriginState()
        disarmPacerIfQuietLocked(&state, at: instant)
        state.refusals += 1
        state.lastRefusalAt = instant
        state.refusalStreak += 1
        state.cleanGrants = 0
        state.tokens = 0
        state.lastRefillAt = instant
        let exponent = min(state.refusalStreak - 1, 3)
        let exponentialQuiet = min(
            Self.maximumQuietPeriod,
            Self.firstQuietPeriod * pow(2, Double(exponent)))
        let quiet = retryAfter.map { max(0, $0) } ?? exponentialQuiet
        state.quietUntil = instant + quiet
        let previous = state.limit
        if let hostLimit = state.hostLimit {
            state.limit = hostLimit
        } else {
            let basis = state.limit ?? max(1, state.peakInflight)
            state.limit = max(1, basis / 2)
        }
        let limitNow = state.limit
        let peak = state.peakInflight
        origins[key] = state
        lock.unlock()

        if previous != limitNow, let limitNow {
            EngineLog.emit(
                "[OriginBudget] \(key) answered \(status); concurrency budget "
                + "\(previous.map(String.init) ?? "uncapped") -> \(limitNow) (peak was \(peak))",
                category: .demux)
        }
        return limitNow
    }

    /// Record that a refusal happened while fetching this source, WITHOUT touching the concurrency
    /// budget of the URL passed in.
    ///
    /// A metered source is routinely two origins: a proxy that mints signed links and 302s to a CDN
    /// that serves them. The refusal comes back from the CDN, so that is the host whose concurrency
    /// budget must come down. But the engine's revive arm only ever knows the URL the host loaded,
    /// which is the proxy's, and asking the proxy's key whether the CDN refused us returns false
    /// forever: the classification would be built, published, and silently never reached. So the
    /// source URL carries the timestamp too, and only the timestamp.
    func noteRefusalWitnessed(for url: URL) {
        guard let raw = Self.originKey(for: url) else { return }
        let instant = now()
        lock.lock(); defer { lock.unlock() }
        let key = headLocked(raw)
        var state = origins[key] ?? OriginState()
        state.lastRefusalAt = instant
        origins[key] = state
    }

    /// True when this origin refused a request within `window`. The engine's revive arm asks this
    /// to tell "the source is gone" from "the source is metering us", which the FFmpeg-side error
    /// code (-1) cannot carry.
    func refusedRecently(_ url: URL, within window: TimeInterval) -> Bool {
        guard let raw = Self.originKey(for: url) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let last = origins[headLocked(raw)]?.lastRefusalAt else { return false }
        let elapsed = Self.elapsedSeconds(from: last, to: now())
        return elapsed <= window
    }

    // MARK: - Dropped redirect targets (#377 round 5)

    /// The ladder dropped `target` because requests through it were being refused. Recorded on the
    /// SOURCE's chain, so the next reader for the same source finds it whatever instance it is.
    ///
    /// A pin is only ever written down from a 2xx, deliberately: pinning a target that just refused
    /// would key the whole session on it. The consequence is that a re-resolve landing back on a
    /// refusing target is recorded nowhere, and off the responding host alone the three shapes that
    /// need three different fixes are indistinguishable. The reader kept this ledger and the reader
    /// is replaced by the very recovery that most needs it, so it lives here.
    func noteTargetDropped(_ target: URL, from source: URL) {
        guard let targetKey = Self.originKey(for: target),
              let sourceKey = Self.originKey(for: source) else { return }
        lock.lock(); defer { lock.unlock() }
        // Keyed under the SOURCE's chain head, which is the only side a later reader can ask from:
        // it knows the URL it was handed, not the target the last reader was redirected to.
        let head = headLocked(sourceKey)
        var state = origins[head] ?? OriginState()
        state.droppedTargets.insert(targetKey)
        origins[head] = state
    }

    /// `target` answered. It is no longer a dropped target, so a refusal from it later in the
    /// session describes that later window rather than dragging an old one forward: "dropped and
    /// minted again" has to mean dropped and NOT seen healthy since, or it becomes true for the
    /// rest of the process and says nothing.
    func noteTargetHealthy(_ target: URL) {
        guard let targetKey = Self.originKey(for: target) else { return }
        lock.lock(); defer { lock.unlock() }
        let head = headLocked(targetKey)
        guard var state = origins[head], state.droppedTargets.contains(targetKey) else { return }
        state.droppedTargets.remove(targetKey)
        origins[head] = state
    }

    /// Targets dropped for refusals on this source's chain and not seen answering since.
    func droppedTargets(for url: URL) -> Set<String> {
        guard let raw = Self.originKey(for: url) else { return [] }
        lock.lock(); defer { lock.unlock() }
        return origins[headLocked(raw)]?.droppedTargets ?? []
    }

    /// #377 round 5: what the books can say about WHY this origin refused, for the line that ends
    /// a session. Empty when they have nothing to add.
    ///
    /// Two facts are held here and nowhere else, and they pick different fixes. A peak of one
    /// request in flight cannot have exceeded a concurrency ceiling, whatever the status code says,
    /// so a session refused throughout at peak 1 was not refused for asking too much at once. And a
    /// target that was dropped and handed back by the source is one refusing target rather than an
    /// origin metering us. Stated as counts, not as a conclusion about the far end: the engine sees
    /// its own asks, not the quota behind them.
    func refusalShapeNote(for url: URL) -> String {
        guard let snapshot = snapshot(for: url), snapshot.refusals > 0 else { return "" }
        let dropped = droppedTargets(for: url).sorted()
        var parts = ["peak \(snapshot.peakInflight) in flight", "\(snapshot.refusals) refusals"]
        if !dropped.isEmpty {
            parts.append("\(dropped.count) target\(dropped.count == 1 ? "" : "s") dropped for "
                         + "refusals and not seen answering since (\(dropped.joined(separator: ", ")))")
        }
        var note = " Books for this origin: " + parts.joined(separator: ", ") + "."
        if snapshot.peakInflight <= 1 && !dropped.isEmpty {
            note += " One request at a time cannot exceed a concurrency ceiling, so what refused is"
                + " that target, not our concurrency."
        }
        return note
    }

    /// Host-declared ceiling for this origin. Takes precedence over anything learned, in both
    /// directions: a host that knows its provider allows one connection should not have to wait
    /// for the engine to be refused a few times to find that out.
    func setHostLimit(_ limit: Int?, for url: URL) {
        guard let raw = Self.originKey(for: url) else { return }
        lock.lock(); defer { lock.unlock() }
        let key = headLocked(raw)
        var state = origins[key] ?? OriginState()
        state.hostLimit = limit.map { max(1, $0) }
        if let hostLimit = state.hostLimit { state.limit = hostLimit }
        origins[key] = state
    }

    /// The effective ceiling for this origin, or nil while it is uncapped. On a redirect chain that
    /// is the chain's ceiling, which is the point of #388: the host names the URL it loads, the
    /// bytes come from somewhere else, and both answers have to be the same one.
    func limit(for url: URL) -> Int? {
        guard let raw = Self.originKey(for: url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return origins[headLocked(raw)]?.limit
    }

    /// True when this origin is down to one request at a time. The reader asks this to switch OFF
    /// its speculative parallel paths rather than queue them: a detour block, the tail prefetch and
    /// the staggered probe fan all exist to overlap with the pump, and overlapping is the one thing
    /// a single-slot origin does not allow. Each has a serial fallback, so switching them off costs
    /// throughput and nothing else, while queueing them behind a slot the caller itself holds would
    /// deadlock.
    func requiresSerialRequests(_ url: URL) -> Bool {
        limit(for: url) == 1
    }

    func snapshot(for url: URL) -> Snapshot? {
        guard let raw = Self.originKey(for: url) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let key = headLocked(raw)
        guard var state = origins[key] else { return nil }
        let instant = now()
        disarmPacerIfQuietLocked(&state, at: instant)
        origins[key] = state
        let since = state.lastRefusalAt.map {
            Self.elapsedSeconds(from: $0, to: instant)
        }
        return Snapshot(inflight: state.inflight, peakInflight: state.peakInflight,
                        limit: state.limit, paced: state.quietUntil != nil,
                        refusals: state.refusals,
                        secondsSinceLastRefusal: since, waiting: state.waiters.count)
    }

    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        for (_, state) in origins {
            for waiter in state.waiters { waiter.signal() }
        }
        origins.removeAll()
        chainHead.removeAll()
    }
}

/// #377: which transport a source is actually being fetched over, recorded once per origin.
///
/// The reporter's open question was whether a `httpMaximumConnectionsPerHost` cap does anything
/// against their CDN, and it cannot be answered from outside the engine: over HTTP/2 a URLSession
/// multiplexes its requests onto one connection and the cap bounds nothing, over http/1.1 it bounds
/// connections exactly. `URLSessionTaskMetrics.networkProtocolName` is the only place that says
/// which, so it gets logged once per origin, at the first metrics callback we receive.
///
/// One line per origin, not per request: it is a property of the server, and a line per 32 MB range
/// would say the same thing a few hundred times a session.
///
/// Connection reuse used to ride along on that same line, and it could not be read. Emitted at the
/// FIRST metrics callback for an origin, "connection new" is what a first connection nearly always
/// is, so every http/1.1 origin reported it and the line invited the reading "a fresh handshake per
/// range". Whether reads share a connection is a property of a session, not of its first request,
/// so it is now tallied across the connections to that origin and reported once, when there is a
/// sample worth reading. The line says "reader connections" rather than "requests" because only the
/// persistent read path reports metrics: detour blocks, probes and the tail prefetch run on
/// completion-handler tasks with no delegate, so they are outside this tally and the wording must
/// not imply otherwise.
enum ReaderTransportLog {
    /// How many connections an origin has to show before the reuse tally is worth a line. Low on
    /// purpose: these are streaming (re)connects rather than ranges, so a whole session produces a
    /// handful of them, and a threshold that reads well in theory would never print in the traces
    /// this line exists for.
    static let reuseSampleSize = 4

    private struct Tally {
        let proto: String
        var connections: Int
        var reused: Int
        var reportedReuse: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var tallies: [String: Tally] = [:]

    static func note(_ metrics: URLSessionTaskMetrics, for url: URL) {
        guard let key = OriginRequestBudget.originKey(for: url),
              let transaction = metrics.transactionMetrics.last,
              let proto = transaction.networkProtocolName else { return }
        note(protocolName: proto, reusedConnection: transaction.isReusedConnection, originKey: key)
    }

    /// Split out from the metrics callback so the tally is reachable from a test:
    /// `URLSessionTaskMetrics` has no public initializer, so nothing about this could be pinned
    /// through the other entry point.
    static func note(protocolName proto: String, reusedConnection reused: Bool, originKey key: String) {
        lock.lock()
        let existing = tallies[key]
        var tally = existing ?? Tally(proto: proto, connections: 0, reused: 0, reportedReuse: false)
        tally.connections += 1
        if reused { tally.reused += 1 }
        let announceTransport = existing == nil
        let announceReuse = !tally.reportedReuse && tally.connections >= reuseSampleSize
        if announceReuse { tally.reportedReuse = true }
        tallies[key] = tally
        lock.unlock()

        if announceTransport {
            let multiplexed = proto.hasPrefix("h2") || proto.hasPrefix("h3")
            EngineLog.emit(
                "[AVIOReader] origin transport: \(proto) at \(key) "
                + (multiplexed
                   ? "(multiplexed, so a per-session connection cap bounds nothing)"
                   : "(one request per connection, so a per-session connection cap bounds requests)"),
                category: .demux)
        }
        if announceReuse {
            EngineLog.emit(
                "[AVIOReader] origin connections: \(tally.reused) of \(tally.connections) reader "
                + "connections reused at \(key)"
                + (tally.reused == 0 ? ", every one paid a fresh handshake" : ""),
                category: .demux)
        }
    }

    static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        tallies.removeAll()
    }
}
