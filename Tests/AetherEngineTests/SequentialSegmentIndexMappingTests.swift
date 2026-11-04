// AE#958: a sequential session's playlist axis is the muxed durations, not the stride plan, so a
// time maps to the segment the playlist actually lists there (field: plan said seg72 at 291.88 s
// while the cut had drifted by up to 3.6 s).
import Testing
@testable import AetherEngine

@Suite("Sequential segment index mapping (AE#958)")
struct SequentialSegmentIndexMappingTests {

    @Test("Drifted cuts map by their real durations, not the 4 s stride")
    func driftedCuts() {
        let durations = [4.0, 5.6, 2.4, 4.0]   // starts 0, 4, 9.6, 12
        #expect(VideoSegmentProvider.sequentialSegmentIndex(forPlaylistTime: 8.5, durations: durations) == 1)
        #expect(VideoSegmentProvider.sequentialSegmentIndex(forPlaylistTime: 9.6, durations: durations) == 2)
        #expect(VideoSegmentProvider.sequentialSegmentIndex(forPlaylistTime: 12.1, durations: durations) == 3)
    }

    @Test("A folded hole is never the answer")
    func holeSkipped() {
        let durations = [4.0, 0, 8.2, 4.0]     // plan index 1 folded into 2
        #expect(VideoSegmentProvider.sequentialSegmentIndex(forPlaylistTime: 4.0, durations: durations) == 2)
        #expect(VideoSegmentProvider.sequentialSegmentIndex(forPlaylistTime: 6.0, durations: durations) == 2)
    }

    @Test("Past the finalized end there is no answer, so the plan stays the estimate")
    func pastEnd() {
        #expect(VideoSegmentProvider.sequentialSegmentIndex(forPlaylistTime: 16.0, durations: [4.0, 4.0]) == nil)
        #expect(VideoSegmentProvider.sequentialSegmentIndex(forPlaylistTime: 0, durations: []) == nil)
    }

    @Test("A negative time lands on the first real segment")
    func negativeTime() {
        #expect(VideoSegmentProvider.sequentialSegmentIndex(forPlaylistTime: -1, durations: [0, 4.0]) == 1)
    }
}
