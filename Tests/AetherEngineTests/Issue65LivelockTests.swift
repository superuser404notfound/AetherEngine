import Testing
@testable import AetherEngine

@Suite("Issue65 livelock breakers")
struct Issue65LivelockTests {

    // MARK: - BackpressureWedgeDetector (Piece A)

    @Test("Frozen consumer target trips the wedge after the threshold")
    func frozenTargetTrips() {
        var d = BackpressureWedgeDetector(breakThresholdSeconds: 3, initialTarget: 53)
        // Target never advances past the entry value: each poll is one more stuck second.
        #expect(d.observe(currentTarget: 53) == false) // 1s
        #expect(d.observe(currentTarget: 53) == false) // 2s
        #expect(d.observe(currentTarget: 53) == true)  // 3s -> wedge
    }

    @Test("An advancing consumer target never trips the wedge")
    func advancingTargetNeverTrips() {
        var d = BackpressureWedgeDetector(breakThresholdSeconds: 3, initialTarget: 50)
        // Slow but steady forward progress (cold cache / throttled CDN): must stay healthy forever.
        for t in 51...80 {
            #expect(d.observe(currentTarget: t) == false)
        }
    }

    @Test("A target that climbs then freezes trips only after the freeze, measured from the freeze")
    func climbThenFreezeResetsTheTimer() {
        var d = BackpressureWedgeDetector(breakThresholdSeconds: 3, initialTarget: 50)
        #expect(d.observe(currentTarget: 51) == false) // advance -> reset
        #expect(d.observe(currentTarget: 52) == false) // advance -> reset
        #expect(d.observe(currentTarget: 53) == false) // advance -> reset, now frozen at 53
        #expect(d.observe(currentTarget: 53) == false) // 1s stuck
        #expect(d.observe(currentTarget: 53) == false) // 2s stuck
        #expect(d.observe(currentTarget: 53) == true)  // 3s stuck -> wedge
    }

    @Test("A late single advance after near-threshold freeze resets and prevents the trip")
    func lateAdvanceRescues() {
        var d = BackpressureWedgeDetector(breakThresholdSeconds: 3, initialTarget: 53)
        #expect(d.observe(currentTarget: 53) == false) // 1s
        #expect(d.observe(currentTarget: 53) == false) // 2s
        #expect(d.observe(currentTarget: 54) == false) // advance -> reset (consumer resumed)
        #expect(d.observe(currentTarget: 54) == false) // 1s
        #expect(d.observe(currentTarget: 54) == false) // 2s
        #expect(d.observe(currentTarget: 54) == true)  // 3s -> wedge again
    }

    // MARK: - BackpressureWedgeDetector pause guard (#65 pause false-positive)

    @Test("A frozen target never trips while the consumer is paused, however long the pause")
    func pausedConsumerNeverTrips() {
        var d = BackpressureWedgeDetector(breakThresholdSeconds: 3, initialTarget: 24)
        // Reporter case: the consumer is paused, so its fetch target is frozen by design. Far past the
        // threshold this must stay healthy: a paused player issues no forward fetch, so it is not a wedge.
        for _ in 0..<100 {
            #expect(d.observe(currentTarget: 24, wantsToPlay: false) == false)
        }
    }

    @Test("Resuming after a long pause starts a fresh window, not an instant trip")
    func resumeAfterPauseStartsFresh() {
        var d = BackpressureWedgeDetector(breakThresholdSeconds: 3, initialTarget: 24)
        // Long pause with a frozen target: suspended, re-baselined every poll.
        for _ in 0..<50 { #expect(d.observe(currentTarget: 24, wantsToPlay: false) == false) }
        // On resume the target is still frozen, but the window restarts from zero (no carried-over stuck time).
        #expect(d.observe(currentTarget: 24, wantsToPlay: true) == false) // 1s
        #expect(d.observe(currentTarget: 24, wantsToPlay: true) == false) // 2s
        #expect(d.observe(currentTarget: 24, wantsToPlay: true) == true)  // 3s -> wedge
    }

    @Test("A genuine starved wedge still trips while the player wants to play")
    func wantsToPlayStillTrips() {
        // The legit wedge (AVPlayer in .waitingToPlay, starved) keeps wantsToPlay true and must still fire.
        var d = BackpressureWedgeDetector(breakThresholdSeconds: 3, initialTarget: 53)
        #expect(d.observe(currentTarget: 53, wantsToPlay: true) == false)
        #expect(d.observe(currentTarget: 53, wantsToPlay: true) == false)
        #expect(d.observe(currentTarget: 53, wantsToPlay: true) == true)
    }

    @Test("A pause partway through a freeze defers the trip until play resumes")
    func pauseMidFreezeDefersTrip() {
        var d = BackpressureWedgeDetector(breakThresholdSeconds: 3, initialTarget: 53)
        #expect(d.observe(currentTarget: 53, wantsToPlay: true) == false)  // 1s stuck
        #expect(d.observe(currentTarget: 53, wantsToPlay: true) == false)  // 2s stuck
        #expect(d.observe(currentTarget: 53, wantsToPlay: false) == false) // pause -> reset
        #expect(d.observe(currentTarget: 53, wantsToPlay: false) == false) // still paused
        #expect(d.observe(currentTarget: 53, wantsToPlay: true) == false)  // resume, 1s
        #expect(d.observe(currentTarget: 53, wantsToPlay: true) == false)  // 2s
        #expect(d.observe(currentTarget: 53, wantsToPlay: true) == true)   // 3s -> wedge
    }

    // MARK: - BackpressureWedgeDetector backward scrub (AE#528)

    @Test("A backward scrub is a fetching consumer, so a receding target never trips the slow path")
    func recedingTargetNeverTripsSlowPath() {
        // Field capture on #528: a viewer scrubbing backwards through a 49 s storm declared
        // 194, 185, 182 ... one new GET every ~100 ms, and the breaker tore the pump down anyway
        // because none of those targets ever passed the high-water mark left by the forward run.
        var d = BackpressureWedgeDetector(breakThresholdSeconds: 3, initialTarget: 220)
        for t in stride(from: 219, through: 190, by: -1) {
            #expect(d.observe(currentTarget: t, renderedPosition: Double(t)) == false)
        }
    }

    @Test("A target that recedes and then freezes trips, measured from the freeze")
    func recedeThenFreezeTrips() {
        // The #93 wedge itself: one backward seek, then the consumer goes silent. The move resets
        // the window exactly as an advance does, and the freeze after it still trips on time.
        var d = BackpressureWedgeDetector(breakThresholdSeconds: 3, initialTarget: 220)
        #expect(d.observe(currentTarget: 181) == false) // the seek's own GET -> reset
        #expect(d.observe(currentTarget: 181) == false) // 1s stuck
        #expect(d.observe(currentTarget: 181) == false) // 2s stuck
        #expect(d.observe(currentTarget: 181) == true)  // 3s stuck -> wedge
    }

    @Test("A receding target with a flat clock still fast-trips")
    func recedingTargetWithFlatClockStillFastTrips() {
        // The deliberate split between the two paths: a scrub burst that keeps declaring targets
        // while NOTHING renders is the #35/#79 wedge, and breaking that in single digits is what the
        // fast path is for. Only the slow path treats a move as proof of life.
        var d = BackpressureWedgeDetector(
            breakThresholdSeconds: 24, fastBreakThresholdSeconds: 3,
            initialTarget: 220, initialRenderedPosition: 728.3)
        #expect(d.observe(currentTarget: 200, renderedPosition: 728.3) == false) // 1s flat
        #expect(d.observe(currentTarget: 190, renderedPosition: 728.3) == false) // 2s flat
        #expect(d.observe(currentTarget: 180, renderedPosition: 728.3) == true)  // 3s flat -> fast wedge
        #expect(d.lastTripFast == true)
    }

    // MARK: - ParkClock (AE#528: a wakeup is not a second)

    @Test("Wakeups inside the same second count once")
    func wakeupsInsideOneSecondCountOnce() {
        // The measured rate in the capture: the cache broadcast roughly every 240 ms while the
        // viewer scrubbed, which drove the old counter from 12 to 22 "seconds" in 2.4 s.
        var clock = ParkClock(nowNanos: 0)
        for ms in stride(from: 240, through: 960, by: 240) {
            #expect(clock.advance(nowNanos: UInt64(ms) * 1_000_000) == nil)
        }
        #expect(clock.advance(nowNanos: 1_000_000_000) == 1)
        #expect(clock.advance(nowNanos: 1_240_000_000) == nil)
        #expect(clock.advance(nowNanos: 1_990_000_000) == nil)
        #expect(clock.advance(nowNanos: 2_000_000_000) == 2)
    }

    @Test("A busy park reaches its threshold on the clock, not on the wakeup count")
    func busyParkReachesThresholdOnTheClock() {
        // 24 wakeups inside 10 s of wall clock: the old loop had spent its whole 24 s break budget,
        // this one has counted 10 s.
        var clock = ParkClock(nowNanos: 0)
        var seconds = 0
        for i in 1...24 {
            if let s = clock.advance(nowNanos: UInt64(i) * 416_666_667) { seconds = s }
        }
        #expect(seconds == 10)
    }

    @Test("A missed second is reported once at the age, never replayed")
    func missedSecondsAreNotReplayed() {
        // A starved loop counts slower than the clock, never faster: the jump reports the park's
        // age and the seconds inside it are gone, so a gap can only delay a trip.
        var clock = ParkClock(nowNanos: 0)
        #expect(clock.advance(nowNanos: 3_400_000_000) == 3)
        #expect(clock.advance(nowNanos: 3_900_000_000) == nil)
        #expect(clock.advance(nowNanos: 4_000_000_000) == 4)
    }

    // MARK: - BackpressureWedgeDetector fast path (#93 retest: park + flat clock)

    @Test("Frozen target plus flat rendered clock trips at the fast threshold, well before the slow one")
    func fastTripOnFrozenTargetAndFlatClock() {
        // rrgomes' trace: consumer fetch target frozen AND FreezeDiag clock flat within ~3s of the park,
        // while the slow counter would need 24s. Both signals frozen -> fast trip.
        var d = BackpressureWedgeDetector(
            breakThresholdSeconds: 24, fastBreakThresholdSeconds: 3,
            initialTarget: 84, initialRenderedPosition: 391.9)
        #expect(d.observe(currentTarget: 84, renderedPosition: 391.9) == false) // 1s flat
        #expect(d.observe(currentTarget: 84, renderedPosition: 391.9) == false) // 2s flat
        #expect(d.observe(currentTarget: 84, renderedPosition: 391.9) == true)  // 3s flat -> fast wedge
        #expect(d.lastTripFast == true)
    }

    @Test("An advancing rendered clock never fast-trips, however long the target freezes")
    func advancingClockNeverFastTrips() {
        // Healthy steady-state playback: the consumer fetches a new segment only every ~segment duration,
        // so the target freezes for stretches, but the clock advances every poll. Must never fast-trip.
        var d = BackpressureWedgeDetector(
            breakThresholdSeconds: 60, fastBreakThresholdSeconds: 3,
            initialTarget: 84, initialRenderedPosition: 100.0)
        for i in 1...20 {
            #expect(d.observe(currentTarget: 84, renderedPosition: 100.0 + Double(i)) == false)
        }
    }

    @Test("An advancing fetch target suppresses the fast path even while the clock is flat")
    func advancingTargetSuppressesFastTrip() {
        // Decode ramp after a landed seek: AVPlayer holds the old frame (clock flat) but keeps
        // prefetching forward segments. A fetching consumer is alive, not wedged.
        var d = BackpressureWedgeDetector(
            breakThresholdSeconds: 60, fastBreakThresholdSeconds: 3,
            initialTarget: 84, initialRenderedPosition: 341.9)
        for t in 85...105 {
            #expect(d.observe(currentTarget: t, renderedPosition: 341.9) == false)
        }
    }

    @Test("Without a rendered position the fast path stays inert and the slow threshold governs")
    func nilRenderedPositionKeepsSlowPath() {
        var d = BackpressureWedgeDetector(
            breakThresholdSeconds: 3, fastBreakThresholdSeconds: 2, initialTarget: 53)
        #expect(d.observe(currentTarget: 53) == false) // 1s
        #expect(d.observe(currentTarget: 53) == false) // 2s (fast would fire here if it wrongly counted)
        #expect(d.observe(currentTarget: 53) == true)  // 3s -> slow wedge
        #expect(d.lastTripFast == false)
    }

    @Test("Fast path disabled by default: a flat clock alone never accelerates the slow trip")
    func fastPathDisabledByDefault() {
        var d = BackpressureWedgeDetector(
            breakThresholdSeconds: 4, initialTarget: 53, initialRenderedPosition: 10.0)
        #expect(d.observe(currentTarget: 53, renderedPosition: 10.0) == false) // 1s
        #expect(d.observe(currentTarget: 53, renderedPosition: 10.0) == false) // 2s
        #expect(d.observe(currentTarget: 53, renderedPosition: 10.0) == false) // 3s
        #expect(d.observe(currentTarget: 53, renderedPosition: 10.0) == true)  // 4s -> slow wedge
        #expect(d.lastTripFast == false)
    }

    @Test("A pause suspends the fast window and resume restarts it from zero")
    func pauseSuspendsFastPath() {
        var d = BackpressureWedgeDetector(
            breakThresholdSeconds: 60, fastBreakThresholdSeconds: 3,
            initialTarget: 84, initialRenderedPosition: 200.0)
        #expect(d.observe(currentTarget: 84, renderedPosition: 200.0) == false) // 1s flat
        #expect(d.observe(currentTarget: 84, renderedPosition: 200.0) == false) // 2s flat
        #expect(d.observe(currentTarget: 84, wantsToPlay: false, renderedPosition: 200.0) == false) // pause
        #expect(d.observe(currentTarget: 84, renderedPosition: 200.0) == false) // resume, 1s
        #expect(d.observe(currentTarget: 84, renderedPosition: 200.0) == false) // 2s
        #expect(d.observe(currentTarget: 84, renderedPosition: 200.0) == true)  // 3s -> fast wedge
    }

    @Test("Cold pre-roll (no first frame yet) never trips, even fully frozen")
    func preFirstFrameSuspendsDetector() {
        // The DV-master "loads forever" repro: producer parked, consumer wants to play
        // (waitingToMinimizeStalls), fetch target frozen and rendered clock pinned at the resume
        // position because no frame has decoded yet. Before the first frame this is pre-roll, not a
        // wedge; tripping here would re-anchor and nudge-flush AVPlayer's forward buffer forever.
        var d = BackpressureWedgeDetector(
            breakThresholdSeconds: 60, fastBreakThresholdSeconds: 3,
            initialTarget: 840, initialRenderedPosition: 3355.35)
        for _ in 0..<10 {
            #expect(d.observe(currentTarget: 840, renderedPosition: 3355.35,
                              hasStartedRendering: false) == false)
        }
        // First frame lands: the detector arms and the fast window trips on the next 3 frozen polls.
        #expect(d.observe(currentTarget: 840, renderedPosition: 3355.35, hasStartedRendering: true) == false)
        #expect(d.observe(currentTarget: 840, renderedPosition: 3355.35, hasStartedRendering: true) == false)
        #expect(d.observe(currentTarget: 840, renderedPosition: 3355.35, hasStartedRendering: true) == true)
        #expect(d.lastTripFast == true)
    }

    @Test("A rendered clock jump in either direction resets the flat window")
    func clockJumpResetsFlatWindow() {
        // A backward jump is a new seek landing mid-park; the window must restart, not trip on stale flatness.
        var d = BackpressureWedgeDetector(
            breakThresholdSeconds: 60, fastBreakThresholdSeconds: 3,
            initialTarget: 84, initialRenderedPosition: 391.9)
        #expect(d.observe(currentTarget: 84, renderedPosition: 391.9) == false) // 1s flat
        #expect(d.observe(currentTarget: 84, renderedPosition: 391.9) == false) // 2s flat
        #expect(d.observe(currentTarget: 84, renderedPosition: 341.9) == false) // jump -> reset
        #expect(d.observe(currentTarget: 84, renderedPosition: 341.9) == false) // 1s
        #expect(d.observe(currentTarget: 84, renderedPosition: 341.9) == false) // 2s
        #expect(d.observe(currentTarget: 84, renderedPosition: 341.9) == true)  // 3s -> fast wedge
    }

    @Test("Sub-epsilon clock jitter still counts as flat")
    func microJitterCountsAsFlat() {
        // The mirror is fed by a periodic observer; representation-level wiggle far below a real
        // frame step must not defeat the fast path.
        var d = BackpressureWedgeDetector(
            breakThresholdSeconds: 60, fastBreakThresholdSeconds: 3,
            initialTarget: 84, initialRenderedPosition: 391.900)
        #expect(d.observe(currentTarget: 84, renderedPosition: 391.905) == false) // 1s
        #expect(d.observe(currentTarget: 84, renderedPosition: 391.898) == false) // 2s
        #expect(d.observe(currentTarget: 84, renderedPosition: 391.902) == true)  // 3s -> fast wedge
    }

    // MARK: - BackpressureWedgeDetector quiet but rendering consumer (AE#649)

    @Test("A consumer that goes quiet while it keeps rendering never trips the slow path (AE#649)")
    func quietRenderingConsumerNeverTrips() {
        // Field shape, cellular iPhone: AVPlayer fetched a burst of segments, then nothing for 58 s while
        // it played through its forward buffer. Production thresholds: the old slow path tripped at 24 s
        // and its nudge seek flushed the buffer on screen.
        var d = BackpressureWedgeDetector(
            breakThresholdSeconds: 24, fastBreakThresholdSeconds: 5,
            initialTarget: 453, initialRenderedPosition: 1697.1)
        for i in 1...58 {
            #expect(d.observe(currentTarget: 453, renderedPosition: 1697.1 + Double(i)) == false)
        }
        #expect(d.secondsSinceTargetMoved == 58)
        #expect(d.secondsWithoutProgress == 0)
        #expect(d.lastPollRendered == true)
    }

    @Test("A quiet consumer that plays its buffer dry still breaks on the fast path (AE#649)")
    func quietConsumerThatRunsDryFastTrips() {
        // A consumer that really stopped fetching looks exactly like the healthy one above until its
        // buffer runs out; from then it renders nothing, and that has to break in single digits.
        var d = BackpressureWedgeDetector(
            breakThresholdSeconds: 24, fastBreakThresholdSeconds: 5,
            initialTarget: 453, initialRenderedPosition: 100.0)
        for i in 1...30 {
            #expect(d.observe(currentTarget: 453, renderedPosition: 100.0 + Double(i)) == false)
        }
        for _ in 1...4 {
            #expect(d.observe(currentTarget: 453, renderedPosition: 130.0) == false)
        }
        #expect(d.observe(currentTarget: 453, renderedPosition: 130.0) == true) // 5th flat poll
        #expect(d.lastTripFast == true)
        #expect(d.lastPollRendered == false)
    }

    @Test("Rendering seconds hold the slow count rather than reset it (AE#649)")
    func renderingHoldsTheSlowCount() {
        // A consumer that neither fetches nor plays steadily (a frame now and then) is not saved by
        // the odd frame: only the seconds without progress count, and they add up across the frames.
        var d = BackpressureWedgeDetector(breakThresholdSeconds: 3, initialTarget: 53,
                                          initialRenderedPosition: 10.0)
        #expect(d.observe(currentTarget: 53, renderedPosition: 11.0) == false) // rendered, idle 0
        #expect(d.observe(currentTarget: 53, renderedPosition: 11.0) == false) // idle 1
        #expect(d.observe(currentTarget: 53, renderedPosition: 12.0) == false) // rendered, held at 1
        #expect(d.observe(currentTarget: 53, renderedPosition: 12.0) == false) // idle 2
        #expect(d.observe(currentTarget: 53, renderedPosition: 13.0) == false) // rendered, held at 2
        #expect(d.observe(currentTarget: 53, renderedPosition: 13.0) == true)  // idle 3 -> slow wedge
        #expect(d.lastTripFast == false)
        #expect(d.secondsSinceTargetMoved == 6)
    }

    @Test("A fetch still restarts the slow count from zero (AE#649)")
    func fetchResetsTheSlowCount() {
        var d = BackpressureWedgeDetector(breakThresholdSeconds: 3, initialTarget: 53,
                                          initialRenderedPosition: 10.0)
        #expect(d.observe(currentTarget: 53, renderedPosition: 10.0) == false) // idle 1
        #expect(d.observe(currentTarget: 53, renderedPosition: 10.0) == false) // idle 2
        #expect(d.observe(currentTarget: 54, renderedPosition: 10.0) == false) // fetch -> 0
        #expect(d.secondsWithoutProgress == 0)
        #expect(d.observe(currentTarget: 54, renderedPosition: 10.0) == false) // idle 1
        #expect(d.observe(currentTarget: 54, renderedPosition: 10.0) == false) // idle 2
        #expect(d.observe(currentTarget: 54, renderedPosition: 10.0) == true)  // idle 3
    }

    // MARK: - seekIsWedged (Piece B)

    @Test("Empty forward buffer at the rendered position is a wedge")
    func emptyForwardBufferIsWedged() {
        // Reporter signature: avpClock frozen, loaded=[] (bufferedEnd == renderedTime).
        #expect(seekIsWedged(renderedTime: 149.9, bufferedEnd: 149.9, forwardBufferFloor: 1.0) == true)
        // Tiny range [147-151] around a 149.9 playhead: ~1.1s ahead, still below a healthy floor.
        #expect(seekIsWedged(renderedTime: 149.9, bufferedEnd: 150.5, forwardBufferFloor: 1.0) == true)
    }

    @Test("Healthy forward buffer is not a wedge")
    func healthyForwardBufferIsNotWedged() {
        // AVPlayer has buffered several seconds ahead: slow-but-buffering, leave it to land.
        #expect(seekIsWedged(renderedTime: 149.9, bufferedEnd: 158.0, forwardBufferFloor: 1.0) == false)
        #expect(seekIsWedged(renderedTime: 100.0, bufferedEnd: 130.0, forwardBufferFloor: 1.0) == false)
    }

    @Test("Floor is exclusive at exactly the floor distance")
    func floorBoundary() {
        // Exactly forwardBufferFloor ahead counts as healthy (not wedged).
        #expect(seekIsWedged(renderedTime: 10.0, bufferedEnd: 11.0, forwardBufferFloor: 1.0) == false)
        // Just under the floor is wedged.
        #expect(seekIsWedged(renderedTime: 10.0, bufferedEnd: 10.9, forwardBufferFloor: 1.0) == true)
    }
}
