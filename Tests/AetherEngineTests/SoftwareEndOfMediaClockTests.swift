import Testing
import Foundation
@testable import AetherEngine

/// AE#374: how long the software clock may keep running after the producer is done.
///
/// The defect this policy closes is not a crash: the synchronizer kept its rate past end of media, so
/// `currentTime` walked past `duration` (measured: 20.13 s published on a 12.0 s source) and the 1 Hz
/// `[SWDiag]` line reported an `aLead` falling at exactly 1.00 per second on a session that had simply
/// finished. Both halves read as a live defect to anyone holding the log.
@Suite("SoftwareEndOfMediaClock")
struct SoftwareEndOfMediaClockTests {

    @Test("Audio already consumed parks the clock immediately")
    func consumedTailParksNow() {
        // The normal VOD shape: the drain that precedes end of media has walked the clock to the last
        // video frame, so nothing is left ahead of it.
        #expect(SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: 11.98, lastAudioPts: 11.98) == 0)
        #expect(SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: 12.40, lastAudioPts: 11.98) == 0)
    }

    @Test("Queued audio ahead of the playhead defers the park by exactly that much")
    func queuedTailDefersPark() {
        let tail = SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: 11.87, lastAudioPts: 11.99)
        #expect(abs(tail - 0.12) < 0.0001)
    }

    @Test("A source without usable audio timing parks immediately rather than never")
    func unusableAudioPtsParksNow() {
        #expect(SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: 5, lastAudioPts: .nan) == 0)
        #expect(SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: 5, lastAudioPts: .infinity) == 0)
        #expect(SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: .nan, lastAudioPts: 5) == 0)
    }

    @Test("A broken PTS cannot buy an unbounded runway on a finished session")
    func tailIsClamped() {
        let tail = SoftwareEndOfMediaClock.tailPlayoutSeconds(clockSeconds: 10, lastAudioPts: 90_000)
        #expect(tail == SoftwareEndOfMediaClock.maxTailPlayoutSeconds)
    }

    @Test("The end stops waiting for a parked tail only once all of it is behind the clock")
    func parkedTailBehindClock() {
        // The CI state: newest parked packet at 33.4 s, clock stopped at 36.8 s.
        #expect(SoftwareEndOfMediaClock.parkedTailIsBehindClock(newestParkedSeconds: 33.4, clockSeconds: 36.8))
        #expect(!SoftwareEndOfMediaClock.parkedTailIsBehindClock(newestParkedSeconds: 36.9, clockSeconds: 36.8))
        #expect(!SoftwareEndOfMediaClock.parkedTailIsBehindClock(newestParkedSeconds: 36.8, clockSeconds: 36.8))
        #expect(!SoftwareEndOfMediaClock.parkedTailIsBehindClock(newestParkedSeconds: .nan, clockSeconds: 36.8))
        #expect(!SoftwareEndOfMediaClock.parkedTailIsBehindClock(newestParkedSeconds: 33.4, clockSeconds: .nan))
    }
}
