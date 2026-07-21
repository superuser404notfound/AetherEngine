import Testing
@testable import AetherEngine

@Suite("Restart coalescing")
struct RestartCoalescerTests {

    @Test("First request runs; concurrent requests coalesce to the latest target")
    func coalescesBurst() {
        var c = RestartCoalescer()
        #expect(c.begin(10) == true)
        #expect(c.begin(20) == false)
        #expect(c.begin(35) == false)   // latest target wins
        #expect(c.next(justRan: 10) == 35)
        #expect(c.next(justRan: 35) == nil)
        #expect(c.begin(40) == true)
    }

    @Test("No coalescing when requests are fully sequential")
    func sequentialRequestsEachRun() {
        var c = RestartCoalescer()
        #expect(c.begin(5) == true)
        #expect(c.next(justRan: 5) == nil)   // nothing pending
        #expect(c.begin(6) == true)          // free to run again
        #expect(c.next(justRan: 6) == nil)
    }

    @Test("A pending target equal to what just ran does not loop forever")
    func samePendingTargetTerminates() {
        var c = RestartCoalescer()
        #expect(c.begin(12) == true)
        #expect(c.begin(12) == false)        // duplicate while in-flight
        #expect(c.next(justRan: 12) == nil)  // same index → no redundant restart
    }

    // MARK: - Authoritative re-anchor (#79)

    @Test("An authoritative re-anchor is not clobbered by a later scrub target")
    func authoritativePendingSurvivesLaterScrub() {
        // #79 repro: scrubs are in-flight (618 running), the seek-deadline reconcile re-anchors to
        // AVPlayer's real rendered position (978), then a stale burst-tail scrub (1393) arrives. The
        // reconcile target must win so the producer ends where the clock was reconciled to.
        var c = RestartCoalescer()
        #expect(c.begin(618) == true)                          // scrub burst in-flight
        #expect(c.begin(700) == false)                         // scrub coalesces
        #expect(c.begin(978, authoritative: true) == false)    // reconcile re-anchor (authoritative)
        #expect(c.begin(1393) == false)                        // stale burst-tail scrub: must NOT clobber
        #expect(c.next(justRan: 618) == 978)                   // authoritative target wins
        #expect(c.next(justRan: 978) == nil)
    }

    @Test("A newer authoritative re-anchor replaces an older one")
    func newerAuthoritativeReplacesOlder() {
        // The reconcile can fire twice as AVPlayer's rendered position moves; the latest real position wins.
        var c = RestartCoalescer()
        #expect(c.begin(100) == true)
        #expect(c.begin(500, authoritative: true) == false)
        #expect(c.begin(560, authoritative: true) == false)    // AVPlayer moved; newer authoritative wins
        #expect(c.next(justRan: 100) == 560)
    }

    @Test("An authoritative re-anchor with nothing in flight runs immediately")
    func authoritativeRunsImmediatelyWhenIdle() {
        var c = RestartCoalescer()
        #expect(c.begin(978, authoritative: true) == true)     // no in-flight worker: run it now
        #expect(c.next(justRan: 978) == nil)
    }

    // MARK: - Superseded authoritative pending (#178)

    @Test("A superseding user seek releases the authoritative slot so the next scrub is not dropped")
    func supersedeReleasesAuthoritativeSlot() {
        // #178 repro: seek #1's deadline reconcile parks an authoritative re-anchor in the pending
        // slot; the user then issues seek #2. Without the release, seek #2's segment-driven restart
        // is dropped and the producer lands on the stale recovery position (~13 s off in the report).
        var c = RestartCoalescer()
        #expect(c.begin(618) == true)                        // worker in-flight
        #expect(c.begin(978, authoritative: true) == false)  // recovery re-anchor for seek #1
        c.clearSupersededAuthoritativePending()              // user issued seek #2
        #expect(c.begin(1120) == false)                      // seek #2's segment GET must take the slot
        #expect(c.next(justRan: 618) == 1120)                // not dropped, not 978
        #expect(c.next(justRan: 1120) == nil)
    }

    @Test("Superseding drops an obsolete recovery target that has no follow-up scrub")
    func supersedeDropsObsoleteRecoveryTarget() {
        // The recovery anchor served the SUPERSEDED seek; if the new seek's segments are already
        // resident (no restart fires), running the stale re-anchor would move the producer away
        // from where AVPlayer is now playing.
        var c = RestartCoalescer()
        #expect(c.begin(618) == true)
        #expect(c.begin(978, authoritative: true) == false)
        c.clearSupersededAuthoritativePending()
        #expect(c.next(justRan: 618) == nil)
        #expect(c.begin(700) == true)                        // coalescer idle again
    }

    @Test("Superseding leaves an ordinary pending untouched")
    func supersedeLeavesOrdinaryPending() {
        var c = RestartCoalescer()
        #expect(c.begin(10) == true)
        #expect(c.begin(20) == false)
        c.clearSupersededAuthoritativePending()
        #expect(c.next(justRan: 10) == 20)
    }

    @Test("Superseding when idle is a no-op")
    func supersedeIdleNoOp() {
        var c = RestartCoalescer()
        c.clearSupersededAuthoritativePending()
        #expect(c.begin(5) == true)
        #expect(c.next(justRan: 5) == nil)
    }

    @Test("After an authoritative target is consumed, ordinary scrubs coalesce normally again")
    func scrubResumesAfterAuthoritativeConsumed() {
        var c = RestartCoalescer()
        #expect(c.begin(618) == true)
        #expect(c.begin(978, authoritative: true) == false)
        #expect(c.next(justRan: 618) == 978)                   // consume authoritative, flag clears
        #expect(c.next(justRan: 978) == nil)
        // A fresh burst now coalesces by latest target as before (no sticky authoritative left behind).
        #expect(c.begin(200) == true)
        #expect(c.begin(210) == false)
        #expect(c.begin(230) == false)
        #expect(c.next(justRan: 200) == 230)
    }
}
