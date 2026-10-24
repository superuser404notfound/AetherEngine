import XCTest
@testable import AetherEngine

/// #95: pure pacing core for the loopback audio tap reader. The reader decodes the engine's own
/// fMP4 segments near the playhead; this decision function is the only piece that decides whether
/// to decode the next segment, idle, or re-anchor after the playhead moved away.
final class AudioTapPacingTests: XCTestCase {

    /// One-second segments: the last decoded one starts a second before it ends.
    private func decide(_ last: Double?, _ playhead: Double) -> AudioTapPacing.Decision {
        decide(start: last.map { $0 - 1 }, end: last, playhead)
    }

    private func decide(start: Double?, end: Double?, _ playhead: Double) -> AudioTapPacing.Decision {
        AudioTapPacing.decide(lastDecodedStartPTS: start, lastDecodedEndPTS: end, playhead: playhead,
                              leadSeconds: 10, toleranceSeconds: 2)
    }

    func testFreshInstallDecodesImmediately() {
        XCTAssertEqual(decide(nil, 0), .decodeNext)
        XCTAssertEqual(decide(nil, 3512.4), .decodeNext)
    }

    func testWithinLeadKeepsDecoding() {
        XCTAssertEqual(decide(105.0, 100.0), .decodeNext)   // 5 s ahead, lead is 10
        XCTAssertEqual(decide(100.5, 100.0), .decodeNext)
    }

    func testAtLeadBoundarySleeps() {
        XCTAssertEqual(decide(110.0, 100.0), .sleep)
        XCTAssertEqual(decide(111.5, 100.0), .sleep)        // inside lead + tolerance
    }

    func testFellBehindReanchors() {
        // Forward seek: playhead jumped past everything we decoded.
        XCTAssertEqual(decide(100.0, 300.0), .reanchor)
        // Just past tolerance counts.
        XCTAssertEqual(decide(97.9, 100.0), .reanchor)
    }

    func testBehindWithinToleranceStillDecodes() {
        XCTAssertEqual(decide(98.5, 100.0), .decodeNext)
    }

    func testPlayheadJumpedBackReanchors() {
        // Backward seek: decoded position is far ahead of the new playhead.
        XCTAssertEqual(decide(300.0, 100.0), .reanchor)
        XCTAssertEqual(decide(113.5, 100.0), .reanchor)     // segment start > lead + tolerance
    }

    func testALongSegmentDecodedWithinTheLeadIsNotABackwardJump() {
        // A 10 s segment decoded while the lead had room: it starts within the lead and ends a
        // whole segment past it. That is the lead full, not the playhead gone back.
        XCTAssertEqual(decide(start: 109.5, end: 119.5, 100.0), .sleep)
        XCTAssertEqual(decide(start: 104, end: 120, 100.0), .sleep, "a 16 s segment")
    }

    func testALongSegmentStillReanchorsOnARealBackwardSeek() {
        XCTAssertEqual(decide(start: 110, end: 120, 50.0), .reanchor)
        XCTAssertEqual(decide(start: 112.5, end: 122.5, 100.0), .reanchor)
    }

    func testWithoutASegmentStartOnlyTheEndIsJudged() {
        XCTAssertEqual(decide(start: nil, end: 119.5, 100.0), .sleep)
        XCTAssertEqual(decide(start: nil, end: 90.0, 100.0), .reanchor)
    }
}
