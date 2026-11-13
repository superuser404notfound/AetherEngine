import Testing
import Foundation
@testable import AetherEngine

/// #388: `LoadOptions.maxConcurrentSourceRequests` was registered for the origin of the URL the
/// host loaded, and nothing carried it across the 302 that an Xtream-style panel answers with. The
/// media host behind the redirect is what counts the provider's connections, and it ran under its
/// own, uncapped key: the pump streamed from it holding a ticket booked against the portal, and the
/// first backward read opened a detour block against it as a second request.
///
/// The budget now treats an observed redirect chain as ONE origin. That is the only reading that
/// matches what the bytes do: every request keyed on either end of the chain is answered by the
/// same server, so a ceiling declared for one of them is a ceiling for both, and a request booked
/// against one of them is a request the other one sees.
@Suite("#388 the request ceiling follows the redirect", .serialized)
struct Issue388RedirectChainBudgetTests {

    /// The portal an Xtream host loads: it mints a signed link and 302s to the media host.
    private let portal = URL(string: "http://portal.example.com:8080/movie/user/pass/1325105.mkv")!
    private let mediaHost = URL(string: "https://nexus-128.example.net/signed/1325105.mkv?exp=1&sig=a")!
    /// Same media host, re-signed by a later resolve. The budget keys on scheme+host+port, so this
    /// is the same origin and must not start a second, empty bucket.
    private let mediaHostResigned = URL(string: "https://nexus-128.example.net/signed/1325105.mkv?exp=2&sig=b")!
    private let secondEdge = URL(string: "https://nexus-175.example.net/signed/1325105.mkv?exp=1&sig=c")!

    // MARK: - The ceiling

    @Test("the ceiling declared for the loaded URL binds the host that serves the bytes")
    func declaredCeilingCrossesTheRedirect() {
        let budget = OriginRequestBudget()
        budget.setHostLimit(1, for: portal)
        #expect(!budget.requiresSerialRequests(mediaHost),
                "before the 302 has been seen the media host is a stranger, correctly uncapped")

        budget.noteRedirect(from: portal, to: mediaHost)

        #expect(budget.limit(for: mediaHost) == 1)
        #expect(budget.requiresSerialRequests(mediaHost),
                "the detour asks this about the PINNED url, which is where the host's ceiling stopped")
        #expect(budget.requiresSerialRequests(mediaHostResigned),
                "a re-signed target is the same origin and must not arrive uncapped")
    }

    @Test("a learned ceiling is not what crosses; it is the chain that is one origin")
    func aLearnedCeilingStillOnlyDescribesTheHostThatTaughtIt() {
        // Nothing was declared and no redirect was ever observed: the #377 rule stands, the host
        // that refused is the only one whose budget comes down.
        let budget = OriginRequestBudget()
        let tickets = (0..<4).map { budget.acquire(for: mediaHost, label: "path\($0)", timeout: 0.1) }
        budget.noteRefusal(for: mediaHost, status: 429)
        #expect(budget.limit(for: mediaHost) == 2)
        #expect(budget.limit(for: portal) == nil,
                "a host we have never been redirected through is not part of anything")
        tickets.forEach { budget.release($0) }
    }

    // MARK: - The counting

    @Test("the pump's ticket covers the host it actually streams from")
    func redirectedPumpCountsAtTheServingHost() {
        let budget = OriginRequestBudget()
        budget.setHostLimit(1, for: portal)
        // The pump takes its slot against the URL it asks for, microseconds before the 302 tells it
        // where the bytes live.
        let pump = budget.acquire(for: portal, label: "pump", timeout: 0.1)
        budget.noteRedirect(from: portal, to: mediaHost)

        #expect(budget.snapshot(for: mediaHost)?.inflight == 1,
                "the connection streaming from this host has to show up on its books")
        #expect(budget.tryAcquire(for: mediaHost, label: "tail prefetch") == nil,
                "a speculative fetch must see the slot as taken, not as free")

        budget.release(pump)
        #expect(budget.snapshot(for: mediaHost)?.inflight == 0,
                "a ticket booked on the portal key still frees the chain's slot")
    }

    @Test("a request against the pinned target waits for the pump instead of joining it",
          .timeLimit(.minutes(3)))
    func targetRequestQueuesBehindThePump() async throws {
        let budget = OriginRequestBudget()
        budget.setHostLimit(1, for: portal)
        let pump = budget.acquire(for: portal, label: "pump", timeout: 0.1)
        budget.noteRedirect(from: portal, to: mediaHost)

        let granted = UnsafeBox()
        let started = UnsafeBox()
        // A detached thread, not `DispatchQueue.global().async`: this waiter is what the test
        // measures, and the pool hands out a thread only once one is free. Measured against a pool
        // whose workers are all in a blocking wait, which is what a full parallel run of this suite
        // produces: the async block had not started after 35 s, a detached thread ran in 3 ms.
        Thread.detachNewThread {
            started.set(true)
            // 120 s, not 20: the acquire's own wait may not expire before the test's `.timeLimit`,
            // or `granted` turns from nil into false and the negative expectation below reports the
            // opposite of what starvation did.
            let ticket = budget.acquire(for: self.mediaHostResigned, label: "detour", timeout: 120)
            granted.set(ticket?.granted == true)
        }
        // Wait for the thread before waiting for the park, or the observation window is spent on
        // scheduling and a waiter that never ran reports a budget defect nobody measured.
        try await waitFor { started.value == true }

        // Either outcome ends the wait, so a budget that lets the detour through is still reported
        // at once, while starvation can only delay these two lines, never flip what they read.
        try await waitFor { budget.snapshot(for: mediaHost)?.waiting == 1 || granted.value != nil }
        #expect(granted.value == nil, "nothing may be granted while the pump holds the only slot")
        #expect(budget.snapshot(for: mediaHost)?.waiting == 1,
                "the second request went out alongside the pump: \(String(describing: budget.snapshot(for: mediaHost)))")

        budget.release(pump)
        try await waitFor { granted.value != nil }
        #expect(granted.value == true, "the waiter must be served once the pump's slot comes back")
    }

    @Test("slots already taken against the target survive the link")
    func countsTakenBeforeTheLinkAreCarriedOver() {
        // The link is made when a redirect is seen, which is not necessarily the first request the
        // target has open: a probe can already be running against a pinned URL from an earlier
        // generation. Merging must carry that request, or its release decrements a bucket that
        // never counted it and the chain leaks a slot upward.
        let budget = OriginRequestBudget()
        let inFlight = budget.acquire(for: mediaHost, label: "probe", timeout: 0.1)
        budget.setHostLimit(2, for: portal)
        budget.noteRedirect(from: portal, to: mediaHost)

        #expect(budget.snapshot(for: portal)?.inflight == 1,
                "the request already open against the target belongs to the chain")
        #expect(budget.snapshot(for: portal)?.peakInflight == 1)
        budget.release(inFlight)
        #expect(budget.snapshot(for: portal)?.inflight == 0)
    }

    @Test("a refusal halves from the concurrency the chain actually reached")
    func refusalHalvesFromTheChainsPeak() {
        // The report's second half: with the pump counted somewhere else, the halving basis was
        // whatever the detour alone had reached, so an origin refused with two requests open was
        // told something about one.
        let budget = OriginRequestBudget()
        let pump = budget.acquire(for: portal, label: "pump", timeout: 0.1)
        budget.noteRedirect(from: portal, to: mediaHost)
        let others = (0..<3).map { budget.acquire(for: mediaHost, label: "path\($0)", timeout: 0.1) }

        #expect(budget.snapshot(for: mediaHost)?.peakInflight == 4,
                "the chain saw four requests and every one of them was answered by this host")
        #expect(budget.noteRefusal(for: mediaHost, status: 509) == 2,
                "an origin refused with four open has said something about four; counting the pump elsewhere made the basis three and the answer one")
        #expect(budget.refusedRecently(portal, within: 30),
                "the revive arm only knows the URL the host loaded")

        budget.release(pump); others.forEach { budget.release($0) }
    }

    // MARK: - Chains

    @Test("a second hop joins the same chain rather than starting a third bucket")
    func secondHopJoinsTheChain() {
        let budget = OriginRequestBudget()
        budget.setHostLimit(1, for: portal)
        budget.noteRedirect(from: portal, to: mediaHost)
        budget.noteRedirect(from: mediaHost, to: secondEdge)

        #expect(budget.limit(for: secondEdge) == 1)
        let ticket = budget.acquire(for: secondEdge, label: "pump", timeout: 0.1)
        #expect(budget.snapshot(for: portal)?.inflight == 1, "one chain, one set of books")
        #expect(budget.tryAcquire(for: portal, label: "tail prefetch") == nil)
        budget.release(ticket)
    }

    @Test("a target already on a chain is not re-parented onto a second source")
    func targetIsNotReparented() {
        // Two portals that happen to hand out links on the same edge host. The first chain keeps
        // the target; the second portal keeps its own budget rather than inheriting a ceiling
        // declared for somebody else.
        let budget = OriginRequestBudget()
        let otherPortal = URL(string: "http://other-portal.example.com:8080/movie/u/p/9.mkv")!
        budget.setHostLimit(1, for: portal)
        budget.noteRedirect(from: portal, to: mediaHost)
        budget.noteRedirect(from: otherPortal, to: mediaHost)

        #expect(budget.limit(for: otherPortal) == nil,
                "a ceiling declared for one portal must not spread to another one")
        #expect(budget.limit(for: mediaHost) == 1, "the target stays on the chain it joined first")
    }

    @Test("linking is idempotent")
    func linkingIsIdempotent() {
        let budget = OriginRequestBudget()
        budget.setHostLimit(1, for: portal)
        let pump = budget.acquire(for: portal, label: "pump", timeout: 0.1)
        for _ in 0..<5 { budget.noteRedirect(from: portal, to: mediaHost) }
        #expect(budget.snapshot(for: mediaHost)?.inflight == 1,
                "re-linking must not re-count what is already in flight")
        budget.release(pump)
        #expect(budget.snapshot(for: mediaHost)?.inflight == 0)
    }

    @Test("an unkeyable end of a redirect links nothing")
    func unkeyableURLLinksNothing() {
        let budget = OriginRequestBudget()
        budget.setHostLimit(1, for: portal)
        budget.noteRedirect(from: portal, to: URL(fileURLWithPath: "/tmp/local.mkv"))
        #expect(budget.limit(for: portal) == 1)
    }

    // MARK: - On the wire

    /// The reporter's repro sketch: a portal that 302s to the media host, a ceiling of one declared
    /// by the host, and a read that goes backward past the retained head, which is what an MKV with
    /// cues at the tail, a non-faststart moov or a backward scrub all produce.
    ///
    /// What is asserted is what the ENGINE issues, not what the origin counted: a replacement
    /// connection briefly overlaps the one it replaces at any origin (the teardown window #307/#380
    /// is about), so a peak of one at the server is not something the reader can promise. Not
    /// opening a second request on purpose while the pump streams is, and the budget's own
    /// `peakInflight` is where the reader's side of that is readable.
    @Test("a declared ceiling of one issues no detour block behind the 302", .timeLimit(.minutes(3)))
    func declaredCeilingIssuesNoSecondRequestOnTheWire() async throws {
        let total: Int64 = 64 * 1024 * 1024
        let mediaMaybe = ThrottledOriginServer(totalSize: total, throttleUs: 1000)
        let media = try #require(mediaMaybe)
        defer { media.stop() }
        let mediaPort = media.port
        let portalMaybe = ThrottledOriginServer(
            totalSize: total,
            respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(mediaPort)/media/movie.bin") }
        )
        let portalServer = try #require(portalMaybe)
        defer { portalServer.stop() }

        let sourceURL = URL(string: "http://127.0.0.1:\(portalServer.port)/movie.bin")!
        let mediaURL = URL(string: "http://127.0.0.1:\(mediaPort)/media/movie.bin")!
        // What `AetherEngine.load` does with `LoadOptions(maxConcurrentSourceRequests: 1)`: the
        // ceiling is registered for the URL the host handed over, and only for that one.
        OriginRequestBudget.shared.setHostLimit(1, for: sourceURL)

        let reader = AVIOReader(url: sourceURL)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let chunk = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var read: Int64 = 0
        while read < 12 * 1024 * 1024 {
            let n = reader.read(into: buf, size: Int32(chunk))
            #expect(n > 0, "forward read failed at \(read)")
            if n <= 0 { break }
            read += Int64(n)
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        // The books, not the moment. `inflight` was a wall-clock reading: it is 1 only while the
        // pump still holds its connection, and by the time this line runs the pump has usually
        // finished its bounded refill and let go. Measured on an untouched main, 5 of 6 full-suite
        // runs read 0 here with every other fact intact (limit 1, chain linked, all 12 MB read),
        // while the same test passed every time in isolation and under CPU saturation. That is a
        // flake, and lowering it to `>= 0` would only have deleted the check.
        //
        // `peakInflight` is a high-water mark on the reader's own tickets, so it states both
        // halves without depending on when it is read: the host behind the 302 is the one that
        // streamed, and the reader never held a second ticket against it while it did. That is
        // also the exact promise this test is about, which `inflight` never measured.
        let books = try #require(OriginRequestBudget.shared.snapshot(for: mediaURL),
                                 "the media host behind the 302 is not on the budget's books")
        #expect(books.peakInflight == 1,
                "the streaming connection was on the media host's books, and alone there")
        #expect(OriginRequestBudget.shared.requiresSerialRequests(mediaURL),
                "the pinned target is where every request after the first is keyed")

        // Backward, past the 4 MB retained head: the read that opens a detour block.
        #expect(reader.seek(offset: 6 * 1024 * 1024, whence: Int32(SEEK_SET)) == 6 * 1024 * 1024)
        let served = reader.read(into: buf, size: Int32(chunk))
        #expect(served > 0, "the backward read must still be served, by repositioning instead")

        // A detour block is a bounded 4 MB range. The pump's own bounded refill is 32 MB and the
        // tail probe is a suffix at the end of the file, so a small bounded range in the middle can
        // only be the second request.
        let blocks = media.requestedRanges.filter {
            guard let end = $0.end, $0.start < total - 1 * 1024 * 1024 else { return false }
            return end - $0.start + 1 <= 4 * 1024 * 1024
        }
        #expect(blocks.isEmpty,
                "a detour block went out against the media host while the pump was streaming from it: \(blocks), peak concurrency there \(media.peakConcurrentRequests)")
    }
}

/// Cross-thread carrier for the one expectation that is set on another queue.
private final class UnsafeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool?
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: Bool) { lock.lock(); _value = v; lock.unlock() }
}
