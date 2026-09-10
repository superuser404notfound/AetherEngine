import XCTest
@testable import AetherEngine

final class HLSPlaylistTrackerTests: XCTestCase {

    private func playlist(sequence: Int, uris: [String], duration: Double = 4) -> HLSMediaPlaylist {
        HLSMediaPlaylist(
            targetDuration: duration,
            mediaSequence: sequence,
            segments: uris.map { HLSMediaSegment(uri: $0, duration: duration, discontinuityBefore: false) },
            hasEndList: false,
            isEncrypted: false,
            hasUnsupportedEncryption: false,
            hasMap: false
        )
    }

    func testPrimesAtLiveEdgeWithCoverageTarget() {
        // 4s segments: coverage = max(8, 1.5*4) = 8s -> join takes exactly two segments.
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c", "d", "e", "f"]))
        XCTAssertEqual(new.map(\.uri), ["e", "f"])
        XCTAssertEqual(tracker.stallCount, 0)
    }

    func testPrimeRespectsSegmentCountCapWhenCoverageWantsMore() {
        // 1s segments: 8s coverage would want 8 segments, edgeOffset caps at 3.
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 0, uris: ["a", "b", "c", "d", "e", "f"], duration: 1))
        XCTAssertEqual(new.map(\.uri), ["d", "e", "f"])
    }

    func testPrimeCoversUpstreamCadenceForLongSegments() {
        // 12s segments: coverage = max(8, 1.5*12) = 18s -> two segments (24s) cover a full upstream gap.
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 50, uris: ["a", "b", "c"], duration: 12))
        XCTAssertEqual(new.map(\.uri), ["b", "c"])
    }

    func testPrimeCoversBurstyTenSecondUpstream() {
        // Device-repro shape: 10s segments. Coverage = max(8, 1.5*10) = 15s -> two segments / 20s.
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 7, uris: ["a", "b", "c", "d"], duration: 10))
        XCTAssertEqual(new.map(\.uri), ["c", "d"])
    }

    func testPrimesAtWindowStartWhenWindowIsShort() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        let new = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b"]))
        XCTAssertEqual(new.map(\.uri), ["a", "b"])
    }

    func testReturnsOnlyNewSegmentsOnRefresh() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        let new = tracker.newSegments(in: playlist(sequence: 101, uris: ["b", "c", "d"]))
        XCTAssertEqual(new.map(\.uri), ["d"])
    }

    func testCountsStallsAndResets() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        XCTAssertEqual(tracker.stallCount, 1)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        XCTAssertEqual(tracker.stallCount, 2)
        _ = tracker.newSegments(in: playlist(sequence: 101, uris: ["b", "c", "d"]))
        XCTAssertEqual(tracker.stallCount, 0)
    }

    func testWindowSlidePastCursorRejoinsAtEdgeWithDiscontinuity() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        // Window slid past cursor: rejoin at edge (duration-capped to two 4s segments).
        let new = tracker.newSegments(in: playlist(sequence: 500, uris: ["x", "y", "z", "w", "v", "u"]))
        XCTAssertEqual(new.map(\.uri), ["v", "u"])
        XCTAssertTrue(new[0].discontinuityBefore, "rejoin must be marked as a discontinuity")
    }

    // MARK: - #199: MEDIA-SEQUENCE regression (encoder restart / looped test pool)

    func testSequenceResetRejoinsAtEdgeWithDiscontinuityAfterThreshold() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"])) // cursor -> 103
        // MSN regressed below the cursor: the old code starved here forever (empty batches
        // until the reader's stall counter went terminal with ingestStalled).
        XCTAssertTrue(tracker.newSegments(in: playlist(sequence: 0, uris: ["x", "y", "z"])).isEmpty)
        XCTAssertTrue(tracker.newSegments(in: playlist(sequence: 0, uris: ["x", "y", "z"])).isEmpty)
        let rejoined = tracker.newSegments(in: playlist(sequence: 0, uris: ["x", "y", "z"]))
        XCTAssertEqual(rejoined.map(\.uri), ["y", "z"], "third consecutive regression rejoins at the new edge")
        XCTAssertTrue(rejoined[0].discontinuityBefore, "reset rejoin must be marked as a discontinuity")
        // Cursor continues normally on the new sequence axis.
        let next = tracker.newSegments(in: playlist(sequence: 1, uris: ["y", "z", "w"]))
        XCTAssertEqual(next.map(\.uri), ["w"])
    }

    func testSingleStaleRegressionDoesNotRejoin() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"])) // cursor -> 103
        // One stale CDN edge serving an older window is not a reset.
        XCTAssertTrue(tracker.newSegments(in: playlist(sequence: 98, uris: ["p", "q", "r"])).isEmpty)
        // Fresh edge resumes: only the genuinely new segment comes back, no discontinuity.
        let new = tracker.newSegments(in: playlist(sequence: 101, uris: ["b", "c", "d"]))
        XCTAssertEqual(new.map(\.uri), ["d"])
        XCTAssertFalse(new[0].discontinuityBefore)
        // A later isolated regression starts counting from zero again.
        XCTAssertTrue(tracker.newSegments(in: playlist(sequence: 99, uris: ["p", "q", "r"])).isEmpty)
        let resumed = tracker.newSegments(in: playlist(sequence: 102, uris: ["c", "d", "e"]))
        XCTAssertEqual(resumed.map(\.uri), ["e"])
    }

    func testSequenceRegressionDoesNotInflateStallCount() {
        var tracker = HLSPlaylistTracker(edgeOffset: 3, minJoinCoverageSeconds: 8)
        _ = tracker.newSegments(in: playlist(sequence: 100, uris: ["a", "b", "c"]))
        _ = tracker.newSegments(in: playlist(sequence: 0, uris: ["x", "y", "z"]))
        _ = tracker.newSegments(in: playlist(sequence: 0, uris: ["x", "y", "z"]))
        // Regressions are reset evidence, not upstream silence; they must not push the
        // reader's stall counter toward its ingestStalled terminal trip.
        XCTAssertEqual(tracker.stallCount, 0)
    }

    // MARK: - Default join depth

    func testDefaultJoinReachesTheCoverageTargetOnShortSegments() {
        // The case the old count cap of 3 defeated: 1s segments want 8s of coverage, and the cap
        // handed over 3s. Three joined segments finalize only two downstream (the last is still
        // open), one short of the loopback startup cushion, so the join then waited a segment
        // duration in wall clock for content the origin already had.
        var tracker = HLSPlaylistTracker()
        let uris = (0..<12).map { "s\($0)" }
        let new = tracker.newSegments(in: playlist(sequence: 40, uris: uris, duration: 1))
        XCTAssertEqual(new.map(\.uri), ["s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11"])
    }

    func testDefaultJoinLeavesTheOldestSegmentOfADeepWindow() {
        // Eviction margin: the oldest listed segment is the one closest to being dropped, so the
        // burst stops one short of it rather than racing the origin for a 404.
        var tracker = HLSPlaylistTracker()
        let new = tracker.newSegments(
            in: playlist(sequence: 7, uris: ["a", "b", "c", "d", "e", "f", "g", "h"], duration: 1)
        )
        XCTAssertEqual(new.map(\.uri), ["b", "c", "d", "e", "f", "g", "h"])
    }

    func testDefaultJoinTakesAFloorDepthWindowWhole() {
        // Three segments is as shallow as a live window is expected to get, so there is nothing to
        // hold back and the margin does not apply. Byte-identical to the behaviour before the cap
        // was raised, which is what keeps the change invisible to a minimal origin.
        var tracker = HLSPlaylistTracker()
        let new = tracker.newSegments(in: playlist(sequence: 12, uris: ["a", "b", "c"], duration: 1))
        XCTAssertEqual(new.map(\.uri), ["a", "b", "c"])
    }

    func testDefaultJoinIsUnchangedForLongSegments() {
        // The raised cap moves nothing here: the coverage term breaks a 6s-segment provider at 12s
        // on its own, which is why the count was only ever binding on short segments.
        var tracker = HLSPlaylistTracker()
        let new = tracker.newSegments(
            in: playlist(sequence: 3, uris: ["a", "b", "c", "d", "e", "f"], duration: 6)
        )
        XCTAssertEqual(new.map(\.uri), ["e", "f"])
    }

    func testJoinSegmentLimitAppliesTheMarginOnlyBelowTheCap() {
        XCTAssertEqual(HLSPlaylistTracker.joinSegmentLimit(edgeOffset: 8, windowSegmentCount: 3), 8)
        XCTAssertEqual(HLSPlaylistTracker.joinSegmentLimit(edgeOffset: 8, windowSegmentCount: 4), 3)
        XCTAssertEqual(HLSPlaylistTracker.joinSegmentLimit(edgeOffset: 8, windowSegmentCount: 9), 8)
        XCTAssertEqual(HLSPlaylistTracker.joinSegmentLimit(edgeOffset: 8, windowSegmentCount: 20), 8)
    }
}
