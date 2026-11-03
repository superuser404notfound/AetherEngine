import Testing
import Foundation
@testable import AetherEngine

/// AE#958: a sequential origin can only be read from byte 0, so the session is forward-only, but what
/// the loopback cache already holds is still playable. These pin which seeks the engine forwards, the
/// item axis those resident spans are published on, and that an audio switch is left to a fresh load.
@Suite("Sequential origin seek and audio switch")
struct SequentialOriginSeekTests {

    // MARK: - Resident spans on the item axis

    @Test("spans follow the muxed durations, not the plan stride")
    func spansFollowMuxedDurations() {
        // The field plan was a 4 s stride while the cutter produced ~5.7 s segments (drift 2.8 s).
        let ranges = VideoSegmentProvider.itemRanges(
            durations: [5.68, 6.0, 4.32], residentIndexes: [0...2])
        #expect(ranges == [0...16.0])
    }

    @Test("a zero-duration hole joins its neighbours")
    func holeJoinsNeighbours() {
        // A plan index a long GOP folded has no URI and no cache entry, so it is not a gap in playback.
        let ranges = VideoSegmentProvider.itemRanges(
            durations: [6.0, 0, 6.0, 4.0], residentIndexes: [0...0, 2...3])
        #expect(ranges == [0...16.0])
    }

    @Test("an evicted segment splits the span")
    func evictedSegmentSplits() {
        let ranges = VideoSegmentProvider.itemRanges(
            durations: [6.0, 6.0, 6.0, 6.0], residentIndexes: [0...0, 2...3])
        #expect(ranges == [0...6.0, 12.0...24.0])
    }

    @Test("a stored segment without a final duration is not advertised, so not resident")
    func unfinalizedSegmentIsExcluded() {
        let ranges = VideoSegmentProvider.itemRanges(
            durations: [6.0, 6.0], residentIndexes: [0...2])
        #expect(ranges == [0...12.0])
    }

    // MARK: - Which seeks are forwarded

    @Test("a seek inside the span that reaches the frontier is forwarded")
    func seekInsideFrontierSpan() {
        // Field: a short skip to 48.4 s in a session that had read ~35 s at ~15x real time.
        #expect(AetherEngine.sequentialSeekStaysResident(
            target: 48.4, sequentialOrigin: true, loopbackSession: true,
            residentRanges: [20.0...30.0, 36.0...300.0]))
    }

    @Test("a seek into a detached earlier span is rejected")
    func seekIntoDetachedSpan() {
        // Playing on from there would reach the evicted gap, and the origin cannot refill it.
        #expect(!AetherEngine.sequentialSeekStaysResident(
            target: 25.0, sequentialOrigin: true, loopbackSession: true,
            residentRanges: [20.0...30.0, 36.0...300.0]))
    }

    @Test("a seek past what is held is rejected")
    func seekBeyondResident() {
        #expect(!AetherEngine.sequentialSeekStaysResident(
            target: 25_000, sequentialOrigin: true, loopbackSession: true,
            residentRanges: [0...300.0]))
        #expect(!AetherEngine.sequentialSeekStaysResident(
            target: 10, sequentialOrigin: true, loopbackSession: true, residentRanges: []))
    }

    @Test("only a loopback session on a declared sequential origin qualifies")
    func onlyLoopbackSequential() {
        #expect(!AetherEngine.sequentialSeekStaysResident(
            target: 50, sequentialOrigin: true, loopbackSession: false, residentRanges: [0...300.0]),
                "the software host has no cache to land in")
        #expect(!AetherEngine.sequentialSeekStaysResident(
            target: 50, sequentialOrigin: false, loopbackSession: true, residentRanges: [0...300.0]),
                "a forward-only source on another path keeps its rejection")
        #expect(!AetherEngine.sequentialSeekStaysResident(
            target: .nan, sequentialOrigin: true, loopbackSession: true, residentRanges: [0...300.0]))
    }

    // MARK: - Audio switch

    @Test("a VOD sequential origin switches audio by a fresh load")
    func audioSwitchNeedsFreshLoad() {
        #expect(AetherEngine.audioSwitchNeedsFreshLoad(isLive: false, sequentialOrigin: true))
        #expect(!AetherEngine.audioSwitchNeedsFreshLoad(isLive: false, sequentialOrigin: false))
        #expect(!AetherEngine.audioSwitchNeedsFreshLoad(isLive: true, sequentialOrigin: true))
    }
}
