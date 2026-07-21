import Testing
import Foundation
@testable import AetherEngine

/// #177 issue 2: the live no-cut watchdog retuned on wall-clock since the last finalize alone,
/// so a slow-but-healthy stream (segments arrive slower than real-time, video PTS still
/// advancing) was classified a cutter wedge and force-retuned, re-joining behind the live
/// edge and draining the buffer each cycle. The decision now holds (re-arms the watchdog)
/// while video PTS advances, bounded by a max consecutive-hold count. A genuine SSAI wedge
/// (high read rate, frozen video PTS) still exits immediately.
@Suite("Live no-cut watchdog PTS-advance hold (#177)")
struct Issue177NoCutHoldTests {

    // MARK: - Below timeout

    @Test("below the wedge timeout keeps reading regardless of PTS")
    func belowTimeoutKeepsReading() {
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 8, readRate: 60, videoPtsAdvanceSeconds: 5, consecutiveHolds: 0
        ) == .keepReading)
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 10, readRate: 60, videoPtsAdvanceSeconds: 0, consecutiveHolds: 0
        ) == .keepReading) // boundary: timeout is exclusive
    }

    @Test("below the starvation timeout keeps reading at trickle rates")
    func belowStarvationTimeoutKeepsReading() {
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 20, readRate: 10, videoPtsAdvanceSeconds: -1, consecutiveHolds: 0
        ) == .keepReading)
    }

    // MARK: - Slow-but-healthy hold

    @Test("wedge-classified stall with advancing video PTS holds instead of retuning")
    func advancingPtsHolds() {
        // The field case: rate=40pkt/s, videoPtsAdvance=4.5s in a ~11s window.
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 11, readRate: 40, videoPtsAdvanceSeconds: 4.5, consecutiveHolds: 0
        ) == .holdForSlowDelivery)
        // Also seen: rate=61.3pkt/s, videoPtsAdvance=9.4s.
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 11, readRate: 61.3, videoPtsAdvanceSeconds: 9.4, consecutiveHolds: 3
        ) == .holdForSlowDelivery)
    }

    @Test("PTS advance exactly at the threshold still holds")
    func thresholdAdvanceHolds() {
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 11, readRate: 60, videoPtsAdvanceSeconds: 2.0, consecutiveHolds: 0
        ) == .holdForSlowDelivery)
    }

    // MARK: - Genuine wedge still exits

    @Test("frozen video PTS at full read rate exits for retune (SSAI ad pod)")
    func frozenPtsExits() {
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 11, readRate: 80, videoPtsAdvanceSeconds: 0, consecutiveHolds: 0
        ) == .exitForRetune)
        // No video packet seen in the window at all (advance unknown).
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 11, readRate: 80, videoPtsAdvanceSeconds: -1, consecutiveHolds: 0
        ) == .exitForRetune)
    }

    @Test("sub-threshold PTS advance exits for retune")
    func subThresholdAdvanceExits() {
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 11, readRate: 60, videoPtsAdvanceSeconds: 1.5, consecutiveHolds: 0
        ) == .exitForRetune)
    }

    // MARK: - Bounded holds

    @Test("exhausted hold budget exits even while PTS advances")
    func exhaustedHoldsExit() {
        let max = HLSSegmentProducer.liveSlowDeliveryMaxHolds
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 11, readRate: 60, videoPtsAdvanceSeconds: 5, consecutiveHolds: max
        ) == .exitForRetune)
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 11, readRate: 60, videoPtsAdvanceSeconds: 5, consecutiveHolds: max - 1
        ) == .holdForSlowDelivery)
    }

    // MARK: - Starvation path unchanged

    @Test("source starvation past its timeout exits regardless of PTS advance")
    func starvationExitUnchanged() {
        // Ingest retries ~31s then goes terminal; a 35s window with barely-advancing PTS is a
        // dead source, not slow delivery. The hold gate applies only to the wedge classification.
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 36, readRate: 10, videoPtsAdvanceSeconds: 5, consecutiveHolds: 0
        ) == .exitForRetune)
    }
}
