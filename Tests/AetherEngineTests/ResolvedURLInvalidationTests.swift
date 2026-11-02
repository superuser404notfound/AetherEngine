import Testing
import Foundation
@testable import AetherEngine

/// The reader pins the post-redirect URL after the first 200/206 (#12) and previously
/// dropped the pin only for auth-expiry statuses (401/403/404/410). An aggregator whose
/// redirect targets expire per connection answers every later range with a hard 5xx from
/// the pinned URL, and the reader hammered that dead URL forever instead of re-resolving
/// through the source URL for a fresh redirect.
///
/// `.serialized`: the rate-limit case mutates the process-wide backoff-scale test hook.
@Suite("Resolved-URL invalidation on hard server errors", .serialized, .offCooperativePool)
struct ResolvedURLInvalidationTests {

    /// These tests drive real 429 and 509 answers, and each one arms the request-rate pacer's
    /// wall-clock quiet ladder. Their subject is the resolved-URL verdict, not that ladder, so it is
    /// pinned away: unpinned it added 44 s to a single test here and blocked a reader thread for all
    /// of it. `.serialized` above already declares this suite a mutator of process-wide test hooks. The
    /// pin lasts for this suite instance (one test) and then puts the shared budget back.
    private let quietCapPin = OriginRequestBudget.shared.pinQuietPeriodCapForTesting(0)

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int64: Int] = [:]
        func next(for offset: Int64) -> Int {
            lock.lock(); defer { lock.unlock() }
            let n = (counts[offset] ?? 0) + 1
            counts[offset] = n
            return n
        }
    }

    /// Synchronous on purpose (`Thread.sleep` is off limits in an async test body): paces the
    /// consumer so served reads interleave with the reconnect ladder, and reads until the
    /// reader fails the read. Returns the bytes served and the terminal return value.
    private static func pacedReadToFailure(_ reader: AVIOReader, sliceCap: Int,
                                           bytesPerSecond: Int) -> (got: Int, result: Int32) {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        while true {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { return (got, n) }
            got += Int(n)
            Thread.sleep(forTimeInterval: Double(n) / Double(bytesPerSecond))
        }
    }

    /// Models an origin whose redirect targets are per-session leases: the source mints a
    /// numbered lease per resolve, and the first request that hits the metered boundary
    /// latches every lease minted so far as DEAD (the sessions that existed when the fault
    /// began). Only a lease minted by a later re-resolve is alive — the stale-edge-session
    /// shape a long pause produces.
    private final class LeaseLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var minted = 0
        private var staleCeiling: Int?
        func mint() -> Int {
            lock.lock(); defer { lock.unlock() }
            minted += 1
            return minted
        }
        func isStale(path: String) -> Bool {
            let lease = Int(path.components(separatedBy: "lease=").last ?? "") ?? 0
            lock.lock(); defer { lock.unlock() }
            if staleCeiling == nil { staleCeiling = minted }
            return lease <= staleCeiling!
        }
        /// Source resolves spent AFTER the fault began — the price of healing, which the
        /// bounded rung must keep at exactly one.
        var mintsAfterFault: Int {
            lock.lock(); defer { lock.unlock() }
            guard let staleCeiling else { return 0 }
            return minted - staleCeiling
        }
    }

    @Test("a hard 500 from the pinned URL falls back to the source URL for a fresh redirect",
          .timeLimit(.minutes(2)))
    func hard500FallsBackToSourceURL() async throws {
        let firstRange: Int64 = 256 * 1024
        let attempts = AttemptCounter()
        // CDN: serves everything except the FIRST attempt at the boundary refill, which it
        // refuses with a hard 500 — the expired-redirect-target shape.
        let cdnMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in
                offset == firstRange && attempts.next(for: offset) == 1
                    ? .status(500) : .serve206
            }
        )
        let cdn = try #require(cdnMaybe)
        defer { cdn.stop() }
        // Source: redirects every request to the CDN, like an Xtream panel's 302 hop.
        let cdnPort = cdn.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin") }
        )
        let source = try #require(sourceMaybe)
        defer { source.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                boundedInitialFetch: firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        let target = Int(firstRange) + 256 * 1024
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got == target, "read stopped at \(got) of \(target); the 500 was terminal")

        // The pin sent the refill straight to the CDN (first attempt, 500), and the fix
        // must send the RETRY through the source URL again — visible as a source-server
        // request at the boundary offset, which only exists if the pin was dropped.
        let sourceHitsAtBoundary = source.requestLog.filter { $0.start == firstRange }
        #expect(!sourceHitsAtBoundary.isEmpty,
                "retry never fell back to the source URL: \(source.requestLog)")
        let cdnAttemptsAtBoundary = cdn.requestLog.filter { $0.start == firstRange }.count
        #expect(cdnAttemptsAtBoundary >= 2,
                "the CDN should see the failed attempt plus the redirected retry")
    }

    /// The counterpart: a metered origin (429/503) must KEEP the pin. Dropping it sends the
    /// retry back through the source URL for a fresh redirect, which is a second request
    /// against the origin that is already refusing them, and on a connection-capped panel
    /// (#307) that is the request there is no room for.
    @Test("a rate-limited refill keeps the pin instead of re-resolving through the source",
          .timeLimit(.minutes(2)))
    func rateLimitedRefillKeepsThePin() async throws {

        let firstRange: Int64 = 256 * 1024
        let attempts = AttemptCounter()
        // CDN: meters the first two attempts at the boundary refill, then serves.
        let cdnMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in
                offset == firstRange && attempts.next(for: offset) <= 2
                    ? .status(503) : .serve206
            }
        )
        let cdn = try #require(cdnMaybe)
        defer { cdn.stop() }
        let cdnPort = cdn.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin") }
        )
        let source = try #require(sourceMaybe)
        defer { source.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                boundedInitialFetch: firstRange, backoffScale: 0.02)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        let target = Int(firstRange) + 256 * 1024
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got == target, "read stopped at \(got) of \(target); the 503s were terminal")

        let sourceHitsAtBoundary = source.requestLog.filter { $0.start == firstRange }
        #expect(sourceHitsAtBoundary.isEmpty,
                "a metered refill re-resolved through the source: \(source.requestLog)")
    }

    /// 509 "Bandwidth Limit Exceeded" is what a connection-capped panel answers while the
    /// slot the reader is REPLACING has not been torn down server-side yet. The slot frees
    /// in seconds and the pinned target is fine; dropping the pin sent every retry back
    /// through the portal — latency plus the one request there is no room for.
    @Test("a 509 refill keeps the pin instead of re-resolving through the source",
          .timeLimit(.minutes(2)))
    func connectionCappedRefillKeepsThePin() async throws {

        let firstRange: Int64 = 256 * 1024
        let attempts = AttemptCounter()
        // CDN: the lingering-slot shape — 509 for the first two attempts at the boundary
        // refill, then the slot has freed and it serves.
        let cdnMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in
                offset == firstRange && attempts.next(for: offset) <= 2
                    ? .status(509) : .serve206
            }
        )
        let cdn = try #require(cdnMaybe)
        defer { cdn.stop() }
        let cdnPort = cdn.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin") }
        )
        let source = try #require(sourceMaybe)
        defer { source.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                boundedInitialFetch: firstRange, backoffScale: 0.02)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        let target = Int(firstRange) + 256 * 1024
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got == target, "read stopped at \(got) of \(target); the 509s were terminal")

        let sourceHitsAtBoundary = source.requestLog.filter { $0.start == firstRange }
        #expect(sourceHitsAtBoundary.isEmpty,
                "a 509 refill re-resolved through the source: \(source.requestLog)")
    }

    /// An origin that answers 509 forever must get the PACED rate-limit ladder and its
    /// bounded give-up — not the hard-5xx treatment (pin dropped every attempt, retries
    /// through the portal at zero backoff until the unproductive cap). Past the keep-pin
    /// grace it spends the bounded re-resolve rung — one class of retries through the
    /// source, not one per attempt — and gives up on the ladder when the fresh target
    /// refuses identically.
    @Test("a permanent 509 pays the rate-limit ladder and gives up cleanly",
          .timeLimit(.minutes(2)))
    func permanent509TakesTheRateLimitLadder() async throws {

        let firstRange: Int64 = 256 * 1024
        let cdnMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in
                offset == firstRange ? .status(509) : .serve206
            }
        )
        let cdn = try #require(cdnMaybe)
        defer { cdn.stop() }
        let cdnPort = cdn.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin") }
        )
        let source = try #require(sourceMaybe)
        defer { source.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                boundedInitialFetch: firstRange, backoffScale: 0.02)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        while true {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got == Int(firstRange),
                "everything before the metered boundary must still be served (got \(got))")

        let boundaryAttempts = cdn.requestLog.filter { $0.start == firstRange }.count
        #expect(boundaryAttempts >= 2, "the ladder must retry a metered origin")
        #expect(boundaryAttempts <= 7,
                "509 must give up at the bounded rate-limit cap, not grind: \(boundaryAttempts) attempts")
        // The keep-pin grace holds for the first attempts, then the rung spends the
        // re-resolve: some retries reach the source, but bounded by the ladder — never
        // the hard-5xx shape of one portal round trip per attempt at zero backoff.
        let sourceHitsAtBoundary = source.requestLog.filter { $0.start == firstRange }
        #expect(!sourceHitsAtBoundary.isEmpty,
                "a 509 outliving the grace must re-resolve through the source: \(source.requestLog)")
        #expect(sourceHitsAtBoundary.count <= 4,
                "re-resolves must stay bounded by the ladder: \(source.requestLog)")
    }

    /// The other 509 shape, and the reason the keep-pin grace is bounded: a pinned edge
    /// target whose session died during a long pause answers 509 FOREVER, while a fresh
    /// redirect through the source connects on the first try (field trace: 20 generations
    /// of 509 against the pin across ~85 s at one offset, then a source-resolved reader
    /// delivered first data in 452 ms). Past `rateLimitRepinStreak` attempts the pin must
    /// be dropped for exactly ONE re-resolve, and the fresh target's 206 re-pins.
    @Test("a 509 outliving the keep-pin grace re-resolves once through the source",
          .timeLimit(.minutes(2)))
    func stalePinned509HealsThroughTheSource() async throws {

        let firstRange: Int64 = 256 * 1024
        let leases = LeaseLatch()
        // CDN: a lease minted before the boundary fault is a dead session and refuses that
        // offset forever; a lease minted by a later resolve serves.
        let cdnMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, path in
                guard offset == firstRange else { return .serve206 }
                return leases.isStale(path: path) ? .status(509) : .serve206
            }
        )
        let cdn = try #require(cdnMaybe)
        defer { cdn.stop() }
        let cdnPort = cdn.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, _, _ in
                .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin?lease=\(leases.mint())")
            }
        )
        let source = try #require(sourceMaybe)
        defer { source.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                boundedInitialFetch: firstRange, backoffScale: 0.02)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        let target = Int(firstRange) + 256 * 1024
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got == target, "read stopped at \(got) of \(target); the stale pin was terminal")

        // 1 free replacement of the planned range end + the grace attempts, all against the
        // dead lease; the rung's attempt is the one that goes through the source.
        let boundaryAttempts = cdn.requestLog.filter { $0.start == firstRange }.count
        #expect(boundaryAttempts == AVIOReader.rateLimitRepinStreak + 1,
                "expected the grace against the pin plus one healed attempt, got \(boundaryAttempts)")
        #expect(leases.mintsAfterFault == 1,
                "healing must cost exactly one source resolve, spent \(leases.mintsAfterFault): \(source.requestLog)")
        let sourceHitsAtBoundary = source.requestLog.filter { $0.start == firstRange }
        #expect(sourceHitsAtBoundary.count == 1,
                "the re-resolve carries the boundary range once: \(source.requestLog)")
    }

    /// The keep-pin grace answers a slot WE just released. When the edge cuts the delivering
    /// connection mid-range and then refuses the pin, nothing of ours is lingering: the edge has
    /// revoked the pinned session, and only a fresh redirect heals (StreamX on 7.50.0: a CDN cut at
    /// 16 of 32 MB, three 509s against the pin across 9 s, then the source-resolved target answered
    /// 206 on its first try, a 12 s visible stall). The first refusal must spend the re-resolve.
    @Test("a pin refused right after the edge cut its connection re-resolves on the first refusal",
          .timeLimit(.minutes(2)))
    func cutConnectionDropsThePinOnTheFirstRefusal() async throws {

        let totalSize: Int64 = 64 * 1024 * 1024
        let cutAfter: Int64 = 1024 * 1024
        let leases = LeaseLatch()
        let opens = AttemptCounter()
        let cdnMaybe = ThrottledOriginServer(
            totalSize: totalSize,
            respond: { _, offset, path in
                if offset == 0, opens.next(for: 0) == 1 { return .serveThenDrop(afterBytes: cutAfter) }
                guard offset > 0, offset < totalSize - 64 * 1024 else { return .serve206 }
                return leases.isStale(path: path) ? .status(509) : .serve206
            }
        )
        let cdn = try #require(cdnMaybe)
        defer { cdn.stop() }
        let cdnPort = cdn.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: totalSize,
            respond: { _, _, _ in
                .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin?lease=\(leases.mint())")
            }
        )
        let source = try #require(sourceMaybe)
        defer { source.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                backoffScale: 0.02)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        let target = Int(cutAfter) + 512 * 1024
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got == target, "read stopped at \(got) of \(target); the cut was terminal")

        // The refused attempt against the pin plus the healed one, both at the cut offset.
        let attemptsAtTheCut = cdn.requestLog.filter { $0.start == cutAfter }.count
        #expect(attemptsAtTheCut == 2,
                "expected one refusal, then the re-resolved attempt, got \(attemptsAtTheCut): \(cdn.requestLog)")
        #expect(leases.mintsAfterFault == 1,
                "healing must cost exactly one source resolve, spent \(leases.mintsAfterFault): \(source.requestLog)")
    }

    /// A consumer still being served from the window must not soften the ladder: window
    /// bytes are not network progress, so the streak keeps charging across served reads
    /// and both the re-resolve rung and the bounded give-up stay reachable. Before this
    /// held, a paced consumer reset the streak on every read and a refused origin was
    /// retried at streak=1 for as long as the runway lasted (the post-pause field trace:
    /// 20 generations across ~85 s, none of them counted).
    @Test("a draining window does not reset the rate-limit ladder", .timeLimit(.minutes(2)))
    func drainingWindowKeepsTheLadderCharged() async throws {

        let firstRange: Int64 = 2 * 1024 * 1024
        let cdnMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in
                offset == firstRange ? .status(509) : .serve206
            }
        )
        let cdn = try #require(cdnMaybe)
        defer { cdn.stop() }
        let cdnPort = cdn.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin") }
        )
        let source = try #require(sourceMaybe)
        defer { source.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                boundedInitialFetch: firstRange, backoffScale: 0.02)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Paced at ~2 MB/s so the 2 MB of read-ahead is worth a second of served reads
        // while the ladder runs — the window-serve/streak interleaving under test.
        let (got, result) = Self.pacedReadToFailure(reader, sliceCap: 128 * 1024,
                                                    bytesPerSecond: 2 * 1024 * 1024)

        #expect(got == Int(firstRange),
                "everything before the metered boundary must still be served (got \(got))")
        #expect(result == -1, "a permanently refused source must fail the read, not hang")
        let boundaryAttempts = cdn.requestLog.filter { $0.start == firstRange }.count
        #expect(boundaryAttempts >= 3, "the ladder must retry a metered origin")
        #expect(boundaryAttempts <= 7,
                "served reads reset the streak: \(boundaryAttempts) attempts at the boundary")
    }

    /// Arms the origin's refusal at a moment the test chooses, and counts what it refused. The
    /// arming is what makes the lease die DURING the idle rather than at open, which is the whole
    /// shape: the pin was good when it was minted and is not good when it is next used.
    private final class RefusalGate: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var refusals = 0
        func arm() { lock.lock(); armed = true; lock.unlock() }
        var isArmed: Bool { lock.lock(); defer { lock.unlock() }; return armed }
        func countRefusal() { lock.lock(); refusals += 1; lock.unlock() }
        var refusalCount: Int { lock.lock(); defer { lock.unlock() }; return refusals }
    }

    /// #392: the keep-pin grace answers ONE shape, #307's lingering slot, and that shape requires a
    /// byte of ours to have just been in flight. A pin that has carried nothing for longer than
    /// `pinIdleSeconds` cannot be producing it (the pump ends its connection at the window high
    /// water, so an idle reader holds nothing at the origin), so what refuses there is the expired
    /// lease and the grace only delays finding out. Its first refusal must be taken at face value:
    /// one refused attempt instead of three.
    ///
    /// The pause is modelled by not READING. The reader is pull-driven, so a consumer that stops is
    /// the only thing that stops the network, which is exactly what a paused player is from here.
    @Test("an idle pin is dropped by its FIRST refusal instead of riding out the grace",
          .timeLimit(.minutes(2)))
    func idlePinDropsOnTheFirstRefusal() async throws {

        let leases = LeaseLatch()
        let gate = RefusalGate()
        let cdnMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, _, path in
                guard gate.isArmed, leases.isStale(path: path) else { return .serve206 }
                gate.countRefusal()
                return .status(509)
            }
        )
        let cdn = try #require(cdnMaybe)
        defer { cdn.stop() }
        let cdnPort = cdn.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, _, _ in
                .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin?lease=\(leases.mint())")
            }
        )
        let source = try #require(sourceMaybe)
        defer { source.stop() }

        // A bounded first fetch, so the opening connection ends because its range was DELIVERED IN
        // FULL rather than because a rate was reached. What the origin will ever write at open is
        // then a fixed number, and waiting for that number is waiting for an event instead of for a
        // duration: a loaded runner delays it, it cannot change it. Waiting on a delivery rate is
        // what failed on CI, where the first connection was still running when the lease died and a
        // request already in flight is never re-offered to the origin's gate.
        let firstRange: Int64 = 1024 * 1024
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                boundedInitialFetch: firstRange, backoffScale: 0.02, pinIdleSeconds: 0.2)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // The bounded range plus the speculative 64 KB suffix is everything the open fetches, and
        // the range cannot overrun its bound, so this total is reached only once both are done.
        let openBytes = firstRange + 64 * 1024
        try await waitFor { cdn.bytesWritten >= openBytes }

        // Idle past the threshold, then let the lease die. Every wait here is a LOWER bound, so a
        // slow machine only makes the pin more idle, never less.
        try await Task.sleep(for: .milliseconds(300))
        gate.arm()

        // Resume: the window serves out of memory, and being below low water issues the refill that
        // meets the dead lease. The target is past the window's frontier on purpose, so the read
        // cannot finish until that refill has actually delivered; a target inside the window would
        // return while the healing request was still on the wire.
        let sliceCap = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        let target = 4 * 1024 * 1024
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }

        #expect(got == target, "read stopped at \(got) of \(target); the stale pin was terminal")
        #expect(gate.refusalCount == 1,
                "an idle pin must be dropped by its first refusal, not ridden out: \(gate.refusalCount) refusals")
        #expect(leases.mintsAfterFault == 1,
                "healing must cost exactly one source resolve, spent \(leases.mintsAfterFault)")
    }

    @Test("hard-server-error classification excludes rate limiting")
    func classifierExcludesRateLimiting() {
        #expect(AVIOReader.isResolvedHardServerError(500))
        #expect(AVIOReader.isResolvedHardServerError(502))
        #expect(AVIOReader.isResolvedHardServerError(504))
        #expect(!AVIOReader.isResolvedHardServerError(503), "503 is rate limiting (#71)")
        #expect(!AVIOReader.isResolvedHardServerError(429))
        #expect(!AVIOReader.isResolvedHardServerError(509),
                "509 is a connection-capped panel metering us (#307 follow-up)")
        #expect(!AVIOReader.isResolvedHardServerError(404), "auth expiry is its own class")
        #expect(!AVIOReader.isResolvedHardServerError(200))
        #expect(AVIOReader.isRateLimitStatus(429))
        #expect(AVIOReader.isRateLimitStatus(503))
        #expect(AVIOReader.isRateLimitStatus(509))
        #expect(!AVIOReader.isRateLimitStatus(500))
    }

    /// #405 (Syravo field trace): a 407 from the PINNED media host of a redirect chain fell through
    /// all three classifiers. No pin drop from the status, counted against the full mid-stream cap
    /// of 12, and the pin dropped only later by the unproductive-streak rule, so the first attempt
    /// after the refusal went back to the address that had just refused. The request went out
    /// direct (CFNetwork logs it as an unexpected proxy response), so on that chain 407 cannot mean
    /// "authenticate to your proxy": the lease is gone, and re-resolving is the only move that
    /// works.
    @Test("407, 402 and 451 are resolved-address expiry, not transients")
    func leaseRefusalsClassifyAsExpiry() {
        #expect(AVIOReader.isResolvedExpiryStatus(407), "the field case: a stale lease on a pinned target")
        #expect(AVIOReader.isResolvedExpiryStatus(402), "panels answer an expired subscription per edge")
        #expect(AVIOReader.isResolvedExpiryStatus(451), "a geo-refusing edge node; the source still mints working ones")
        #expect(AVIOReader.isResolvedExpiryStatus(401))
        #expect(AVIOReader.isResolvedExpiryStatus(403))
        #expect(AVIOReader.isResolvedExpiryStatus(404))
        #expect(AVIOReader.isResolvedExpiryStatus(410))
        #expect(!AVIOReader.isResolvedExpiryStatus(429), "metering is not expiry; re-resolving spends the request there is no room for (#307)")
        #expect(!AVIOReader.isResolvedExpiryStatus(503))
        #expect(!AVIOReader.isResolvedExpiryStatus(509))
        #expect(!AVIOReader.isResolvedExpiryStatus(500), "5xx has its own class and its own reason string")
        #expect(!AVIOReader.isResolvedExpiryStatus(200))
        #expect(!AVIOReader.isResolvedExpiryStatus(206))
    }
}
