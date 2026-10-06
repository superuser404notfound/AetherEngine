import CoreMedia
import Testing
@testable import AetherEngine

/// 7.28 同步时上游行为与 MovieClaw 补丁的交界处；播放回归另用 PlayerUITests 与 faultlab。
struct DownstreamPlaybackIntegrationTests {
    @Test @MainActor func clockHoldFollowsTheRendererReorderWindow() {
        let renderer = SampleBufferRenderer()
        renderer.setReorderDepth(SampleBufferRenderer.reorderDepth(forHardwareDecoder: false))
        #expect(renderer.framesBeforeFirstPresentation == 2)
        renderer.setReorderDepth(SampleBufferRenderer.reorderDepth(forHardwareDecoder: true))
        #expect(renderer.framesBeforeFirstPresentation == 5)
    }

    @Test func shortFirstSegmentKeepsTheCheckedTimeline() {
        let plan = HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: .init(num: 1, den: 90_000), sourceDurationSeconds: 10,
            startPts0: 54_000_000, strideSeconds: 4, firstSegmentSeconds: 1)
        #expect(plan.map(\.startSeconds) == [0, 1, 5, 9])
        #expect(plan.first?.startPts == 54_000_000)
        #expect(plan.last?.endPts == 54_900_000)
        #expect(plan.last?.durationSeconds == 1)
    }

    @Test func shortFirstSegmentStillBoundsAnOversizedPlan() {
        let plan = HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: .init(num: 1, den: 90_000), sourceDurationSeconds: 604_800,
            strideSeconds: 0.001, firstSegmentSeconds: 0.001)
        #expect(plan.count <= HLSVideoEngine.maxPlanSegments)
        #expect(plan.last?.endPts == 54_432_000_000)
        #expect(HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: .init(num: 1, den: 90_000), sourceDurationSeconds: .infinity).isEmpty)
        #expect(HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: .init(num: 1, den: 90_000), sourceDurationSeconds: 10,
            startPts0: .max).isEmpty)
    }

    @Test func discSeekMetadataFollowsTheBoundedTitleAssembly() {
        let title = DiscReader.assembleBluRayTitle(
            clipIDs: ["00001", "missing", "00001", "00002"],
            subtractTicks: [0, 0, 45_000, 90_000],
            cumulativeBeforeTicks: [0, 45_000, 90_000, 135_000]) { clip in
                switch clip {
                case "00001": return [(offset: 100, length: 200)]
                case "00002": return [(offset: 500, length: 300)]
                default: return nil
                }
            }
        #expect(title.resolvedClips.map(\.index) == [0, 2, 3])
        #expect(title.resolvedClips.map(\.byteStart) == [0, 200, 400])
        #expect(title.clipTimeline.map(\.concatByteStart) == [0, 200, 400])
        #expect(title.extents.count == 3)
    }
}
