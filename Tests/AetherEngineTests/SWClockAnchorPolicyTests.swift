import Testing
@testable import AetherEngine

@Suite("SWClockAnchorPolicy (#107 mid-stream-joined sources on the SW demux loop)")
struct SWClockAnchorPolicyTests {

    @Test("fresh load of a zero-based file keeps the load anchor (head-of-stream offset preserved)")
    func freshLoadZeroBased() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: 0.256)
        #expect(r.anchorSeconds == 0)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("resume keeps the load anchor when the first sample lands at the resume position")
    func resumeAligned() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 1000, firstSampleSeconds: 1000.4)
        #expect(r.anchorSeconds == 1000)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("mid-stream join anchors at the first sample PTS and exposes it as session zero")
    func midStreamJoin() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: 64000.5)
        #expect(r.anchorSeconds == 64000.5)
        #expect(r.sessionZeroSeconds == 64000.5)
    }

    @Test("deviating resume re-anchors and maps position relative to the requested start")
    func midStreamJoinWithResume() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 30, firstSampleSeconds: 53126)
        #expect(r.anchorSeconds == 53126)
        #expect(r.sessionZeroSeconds == 53096)
    }

    @Test("non-finite first sample PTS keeps the load anchor")
    func nonFiniteFirstSample() {
        for pts in [Double.nan, .infinity, -.infinity] {
            let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: pts)
            #expect(r.anchorSeconds == 0)
            #expect(r.sessionZeroSeconds == 0)
        }
    }

    @Test("small negative first PTS stays on the load anchor")
    func smallNegativeFirstPts() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: -0.3)
        #expect(r.anchorSeconds == 0)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("deviation exactly at the tolerance keeps the load anchor")
    func deviationAtTolerance() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: 2.0)
        #expect(r.anchorSeconds == 0)
        #expect(r.sessionZeroSeconds == 0)
    }

    @Test("deviation just past the tolerance re-anchors")
    func deviationPastTolerance() {
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 0, firstSampleSeconds: 2.01)
        #expect(r.anchorSeconds == 2.01)
        #expect(r.sessionZeroSeconds == 2.01)
    }

    @Test("session zero never goes negative when the stream starts before the anchor")
    func firstSampleBehindAnchor() {
        // A first sample far BEHIND the requested anchor (broken seek) still re-anchors
        // so samples present, but session zero clamps at 0 to keep positions monotonic.
        let r = SWClockAnchorPolicy.resolve(initialSeconds: 64000, firstSampleSeconds: 10)
        #expect(r.anchorSeconds == 10)
        #expect(r.sessionZeroSeconds == 0)
    }
}
