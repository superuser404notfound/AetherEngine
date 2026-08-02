// Tests/AetherEngineTests/LiveWindowObservedCadenceTests.swift
// Live backpressure/blocking-reload deadlock follow-up: the sliding window must be sized by the
// OBSERVED segment cadence, not the cut target. Under .fastZap the cut target is 0.5s but real
// GOP-quantized segments run ~2s, so dividing 60s by 0.5 inflated the window to 120 segments
// (~240s) — MEDIA-SEQUENCE stayed pinned at 0 and evictBelow never fired in short sessions.
// Also pins the blocking-reload hold bound: 3 x sealed TARGETDURATION instead of hardcoded 18s.
import XCTest
@testable import AetherEngine

final class LiveWindowObservedCadenceTests: XCTestCase {

    // MARK: - LiveWindowSizing

    func testWindowUsesObservedCadenceOverCutTarget() {
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: nil)
        // Legacy path (no observation yet): 60 / 0.5 = 120.
        XCTAssertEqual(sizing.windowSegmentCount, 120)
        XCTAssertEqual(sizing.windowSegmentCount(observedSegmentDurationSeconds: nil), 120)
        // Real fastZap cadence (2s GOPs): 60 / 2 = 30.
        XCTAssertEqual(sizing.windowSegmentCount(observedSegmentDurationSeconds: 2.0), 30)
    }

    func testObservedCadenceBelowCutTargetCannotWidenTheWindow() {
        // The divisor is max(cutTarget, observed): a burst of sub-target segments (scene-cut
        // keyframes) must not inflate the window past what the cut target already allows.
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 4.0, dvrWindowSeconds: nil)
        XCTAssertEqual(sizing.windowSegmentCount(observedSegmentDurationSeconds: 0.7), 15)
    }

    func testMinSafeSegmentsFloorSurvivesLongObservedSegments() {
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 4.0, dvrWindowSeconds: nil)
        // 60 / 10 = 6 < minSafeSegments(8).
        XCTAssertEqual(sizing.windowSegmentCount(observedSegmentDurationSeconds: 10.0), 8)
    }

    // MARK: - Provider window slide

    func testPlaylistSlidesAtObservedCadenceNotCutTarget() {
        let provider = makeFastZapProvider()
        // 35 finalized 2s segments: observed mean = 2.0 -> window 30 -> firstVisible = 35 - 30 = 5.
        // Pre-fix the window was 120 and firstVisible stayed 0 for four minutes of content.
        for i in 0..<35 {
            provider.appendLiveSegment(index: i, startSeconds: Double(i) * 2.0, durationSeconds: 2.0)
        }
        let build = provider.notePlaylistBuild()
        XCTAssertEqual(build.visibleCount, 35)
        XCTAssertEqual(build.firstVisible, 5)
    }

    func testPlaylistDoesNotSlideBeforeWindowFills() {
        let provider = makeFastZapProvider()
        for i in 0..<10 {
            provider.appendLiveSegment(index: i, startSeconds: Double(i) * 2.0, durationSeconds: 2.0)
        }
        XCTAssertEqual(provider.notePlaylistBuild().firstVisible, 0)
    }

    // MARK: - Blocking-reload hold bound

    func testBlockingReloadHoldIsThreeSealedTargetDurations() {
        let provider = makeFastZapProvider()
        // Unsealed: legacy 18s (3 x fallback TD 6) so non-live/test conformers keep today's bound.
        XCTAssertEqual(provider.liveBlockingReloadHoldSeconds, 18.0, accuracy: 0.001)
        // Seal at fastZap cadence: max segment 1.92s -> TD=2 -> hold 6s.
        XCTAssertEqual(provider.liveTargetDurationSeconds(maxSegmentDuration: 1.92), 2)
        XCTAssertEqual(provider.liveBlockingReloadHoldSeconds, 6.0, accuracy: 0.001)
        // Seal is session-stable: a later, longer segment cannot stretch the hold.
        _ = provider.liveTargetDurationSeconds(maxSegmentDuration: 5.76)
        XCTAssertEqual(provider.liveBlockingReloadHoldSeconds, 6.0, accuracy: 0.001)
    }

    // MARK: - Helpers

    private func makeFastZapProvider() -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: SegmentCache(forwardWindow: 10, backwardWindow: 10),
            segments: [],
            codecsString: "avc1.640029,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 25,
            hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(
                targetSegmentDurationSeconds: 0.5,
                dvrWindowSeconds: nil
            )
        )
    }
}
