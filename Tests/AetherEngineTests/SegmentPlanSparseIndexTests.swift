// Sparse / clustered keyframe-index detection for the VOD segment plan (#64).
//
// MPEG-TS / M2TS have no upfront keyframe table (unlike MKV Cues / MP4 stss). The libavformat index
// holds only what avformat_find_stream_info plus the mid-file cue-prewarm seek happened to scan, so it
// comes back sparse and clustered (one entry near the start, a handful near the seek point). Trusting
// that as a complete plan yields a single multi-thousand-second first segment; the frag_custom muxer
// then buffers that whole span in libavformat's interleaver before its first flush, which on a 110 min
// Blu-ray grew to ~13 GB of RAM and swapped until the device disk filled. keyframeIndexIsTrustworthy
// is the guard that routes such an index to the uniform-stride fallback instead.
import Foundation
import Testing
import Libavutil
@testable import AetherEngine

@Suite("HLSVideoEngine sparse keyframe-index detection (#64)")
struct SegmentPlanSparseIndexTests {

    /// MPEG-TS 90 kHz video time base.
    private let ts90k = AVRational(num: 1, den: 90_000)

    /// The reported #64 case: one keyframe at 11.609 s, nine clustered ~0.5 s apart past the 3299.8 s
    /// mid-file seek point. duration 6599 s.
    private func clusteredTSIndex() -> [Int64] {
        let firstKf: Int64 = 1_044_806                 // 11.609 s
        let clusterStart: Int64 = Int64(3299.8 * 90_000) // 296_982_000
        var kfs: [Int64] = [firstKf]
        for i in 0..<9 { kfs.append(clusterStart + Int64(i) * 45_000) } // +0.5 s each
        return kfs
    }

    @Test("A clustered TS index is not trustworthy (largest gap is thousands of seconds)")
    func clusteredIndexRejected() {
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: clusteredTSIndex(),
            videoTimeBase: ts90k,
            sourceDurationSeconds: 6599
        ) == false)
    }

    @Test("Trusting the clustered index would have produced a multi-thousand-second first segment")
    func clusteredIndexProducesGiantSegment() {
        // Documents the exact bug the guard prevents: buildKeyframeSegmentPlan on the clustered input
        // yields a seg-0 spanning the 11.6 s -> 3288 s hole (#EXTINF:3288.076 in the field report).
        let plan = HLSVideoEngine.buildKeyframeSegmentPlan(
            keyframes: clusteredTSIndex(),
            videoTimeBase: ts90k,
            sourceDurationSeconds: 6599
        )
        #expect(plan.first != nil)
        #expect((plan.first?.durationSeconds ?? 0) > 3000)
    }

    @Test("A dense 4 s-GOP index across the whole title is trustworthy")
    func denseIndexAccepted() {
        let stride: Int64 = 4 * 90_000
        var kfs: [Int64] = []
        var t: Int64 = 0
        while t <= Int64(6599 * 90_000) { kfs.append(t); t += stride }
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: kfs,
            videoTimeBase: ts90k,
            sourceDurationSeconds: 6599
        ) == true)
    }

    @Test("The trusted-gap cap is pinned at 30 s (boundary)")
    func gapCapBoundary() {
        // 30.000 s gap is trusted, 30.001 s is not. Pins the cap so a future targetSegmentDuration
        // change becomes a visible test break.
        let exactly30: [Int64] = [0, Int64(30.0 * 90_000)]
        let justOver30: [Int64] = [0, Int64(30.001 * 90_000)]
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: exactly30, videoTimeBase: ts90k, sourceDurationSeconds: 6599) == true)
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: justOver30, videoTimeBase: ts90k, sourceDurationSeconds: 6599) == false)
    }

    @Test("A trailing gap from the last keyframe to EOF is not counted")
    func tailGapNotCounted() {
        // Keyframes spaced 4 s up to 60% of the duration, then nothing. The last-keyframe-to-EOF span
        // is not an inter-keyframe gap and must not demote an otherwise-dense index.
        let stride: Int64 = 4 * 90_000
        var kfs: [Int64] = []
        var t: Int64 = 0
        let lastIndexed = Int64(0.6 * 6599 * 90_000)
        while t <= lastIndexed { kfs.append(t); t += stride }
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: kfs, videoTimeBase: ts90k, sourceDurationSeconds: 6599) == true)
    }

    @Test("Degenerate inputs are never trustworthy")
    func degenerateInputs() {
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: [], videoTimeBase: ts90k, sourceDurationSeconds: 6599) == false)
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: [42], videoTimeBase: ts90k, sourceDurationSeconds: 6599) == false)
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: [0, 360_000], videoTimeBase: AVRational(num: 0, den: 0),
            sourceDurationSeconds: 6599) == false)
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: [0, 360_000], videoTimeBase: ts90k, sourceDurationSeconds: 0) == false)
    }

    @Test("Unsorted input is handled (gaps computed on the sorted order)")
    func unsortedInput() {
        // indexedKeyframes does not guarantee sort order; the helper must sort before measuring gaps.
        let dense: [Int64] = [4 * 90_000, 0, 8 * 90_000, 2 * 90_000, 6 * 90_000]
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: dense, videoTimeBase: ts90k, sourceDurationSeconds: 12) == true)
    }

    @Test("The uniform fallback plan covers the duration in target-sized segments")
    func uniformPlanShape() {
        // buildUniformSegmentPlan had no test before #64; lock its shape since Fix A routes the
        // showstopper case through it.
        let plan = HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: ts90k, sourceDurationSeconds: 6599)
        #expect(plan.count == Int(ceil(6599.0 / 4.0)))
        for seg in plan {
            #expect(seg.durationSeconds <= 4.0 + 0.001)
            #expect(seg.durationSeconds > 0)
        }
        // Monotonic non-decreasing starts, last clamped to the source duration.
        for i in 1..<plan.count {
            #expect(plan[i].startSeconds >= plan[i - 1].startSeconds)
        }
        #expect((plan.last?.startSeconds ?? 0) < 6599)
    }
}
