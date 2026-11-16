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
}
