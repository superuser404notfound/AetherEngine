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
