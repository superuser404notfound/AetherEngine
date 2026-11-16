import Testing
@testable import AetherEngine

@Suite("AE#550 (the cue prewarm may not run where a seek is a linear read)")
struct Issue550CuePrewarmPolicyTests {

    @Test("an ordinary seekable source prewarms, which is what loads the index")
    func seekableSourcePrewarms() {
        #expect(HLSVideoEngine.cuePrewarmMayRun(hasSegmentedReader: false, isSourceSeekable: true))
    }

    @Test("a forward-only source does not: the prefix the seek would read is the producer's only pass")
    func forwardOnlySourceDoesNotPrewarm() {
        #expect(!HLSVideoEngine.cuePrewarmMayRun(hasSegmentedReader: false, isSourceSeekable: false))
    }

    @Test("a DASH source does not (AE#1075): its virtual MP4 is fragmented, so there is no stss to load")
    func dashSourceDoesNotPrewarm() {
        #expect(!HLSVideoEngine.cuePrewarmMayRun(hasSegmentedReader: false, isSourceSeekable: true, isDASHSource: true))
        #expect(HLSVideoEngine.cuePrewarmMayRun(hasSegmentedReader: false, isSourceSeekable: true, isDASHSource: false))
    }

    @Test("a segmented reader keeps its own AE#268 exemption, seekable or not")
    func segmentedReaderNeverPrewarms() {
        #expect(!HLSVideoEngine.cuePrewarmMayRun(hasSegmentedReader: true, isSourceSeekable: true))
        #expect(!HLSVideoEngine.cuePrewarmMayRun(hasSegmentedReader: true, isSourceSeekable: false))
    }

    @Test("DASH random-access points thin to the minimum length, never off a declared SAP (AE#1075)")
    func dashCoalescing() {
        // The irregular-GOP fixture's first SAPs: the absolute hls rule kept 49.75 -> 52.0 (2.25 s),
        // whose keyframe the audio lead pushed into the next segment.
        let saps = [0, 5.25, 10.75, 19.75, 21.25, 29.75, 34.25, 41.25, 49.75, 52.0, 60.5]
        let kept = HLSVideoEngine.coalescedRandomAccessStarts(saps, minimumSeconds: 4.51)
        #expect(kept == [0, 5.25, 10.75, 19.75, 29.75, 41.25, 49.75, 60.5])
        #expect(Set(kept).isSubset(of: Set(saps)))
        #expect(zip(kept, kept.dropFirst()).allSatisfy { $1 - $0 >= 4.51 })
        #expect(HLSVideoEngine.coalescedRandomAccessStarts([1, 2], minimumSeconds: 4).isEmpty)
    }

    @Test("the DASH minimum is the target length, or the audio lead plus the boundary backoff when longer")
    func dashMinimumSegment() {
        #expect(HLSVideoEngine.dashMinimumSegmentSeconds(interleaveLeadSeconds: 2) == HLSVideoEngine.targetSegmentDuration)
        #expect(HLSVideoEngine.dashMinimumSegmentSeconds(interleaveLeadSeconds: 10) == 10.5)
    }
}
