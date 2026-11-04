// #369: the advance park's release is a consumer fetch of `target`, but a sequential append
// playlist advertises only what the pump's own finalize reports have fed it. A target beyond
// that frontier is a self-deadlock (field: fold-to-tail parked at target=364 while the playlist
// ended at seg61, freezing it for good); a negative target releases instantly and is none.
import Testing
@testable import AetherEngine

@Suite("Sequential park frontier (#369)")
struct SequentialParkFrontierTests {

    @Test("A target beyond the advertisable frontier is a self-deadlock")
    func beyondFrontierDeadlocks() {
        #expect(HLSSegmentProducer.sequentialParkWouldSelfDeadlock(target: 364, highestAdvertised: 61))
        #expect(HLSSegmentProducer.sequentialParkWouldSelfDeadlock(target: 0, highestAdvertised: Int.min))
    }

    @Test("A target the playlist already advertises parks normally")
    func atOrBelowFrontierParks() {
        #expect(!HLSSegmentProducer.sequentialParkWouldSelfDeadlock(target: 52, highestAdvertised: 60))
        #expect(!HLSSegmentProducer.sequentialParkWouldSelfDeadlock(target: 60, highestAdvertised: 60))
    }

    @Test("A negative target releases instantly and never counts as a deadlock")
    func negativeTargetIsNoDeadlock() {
        // Session start: head < window makes the target negative while the frontier is still empty.
        #expect(!HLSSegmentProducer.sequentialParkWouldSelfDeadlock(target: -8, highestAdvertised: Int.min))
    }

    @Test("AE#958: a playing consumer gets one segment per segment duration")
    func trickleWhilePlaying() {
        #expect(!HLSSegmentProducer.sequentialParkTrickleDue(parkedSeconds: 3, cadenceSeconds: 4,
                                                            consumerRendering: true))
        #expect(HLSSegmentProducer.sequentialParkTrickleDue(parkedSeconds: 4, cadenceSeconds: 4,
                                                           consumerRendering: true))
    }

    @Test("AE#958: a paused or frozen consumer gets no trickle, so the wedge detector keeps its case")
    func noTrickleWithoutRendering() {
        #expect(!HLSSegmentProducer.sequentialParkTrickleDue(parkedSeconds: 60, cadenceSeconds: 4,
                                                            consumerRendering: false))
    }

    @Test("AE#958: a degenerate cadence still waits a second")
    func cadenceFloor() {
        #expect(!HLSSegmentProducer.sequentialParkTrickleDue(parkedSeconds: 0, cadenceSeconds: 0,
                                                            consumerRendering: true))
    }
}
