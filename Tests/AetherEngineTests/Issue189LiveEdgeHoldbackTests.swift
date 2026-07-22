// Tests/AetherEngineTests/Issue189LiveEdgeHoldbackTests.swift
// AE#189 root cause (reporter-confirmed on 5.18.3): the served TARGETDURATION is correct (TD=6 for the
// reporter's 4.8-5.76s long-GOP HEVC-in-TS segments), but the loopback advertised no explicit HOLD-BACK,
// so AVPlayer fell back to its implicit 3 x TD (18s) holdback while the fixed 2-segment startup cushion
// only built ~9.6s. AVPlayer then restarted inside its own stall-danger zone (-16832) until the realtime
// window naturally deepened. Fix: (1) advertise EXT-X-SERVER-CONTROL:HOLD-BACK=3xTD, (2) size the startup
// cushion to that same holdback depth. These tests pin both, and that the two derive TD identically.
import XCTest
@testable import AetherEngine

/// Reporter's builder-visible outputs on 5.18.3: finalized live segments of 4.8s (keyframe-aligned at the
/// upstream GOP), cut target 4.0s, cadence floor absent (worst case for the TD floor). Blocking-reload left
/// at the default so the combined SERVER-CONTROL line carries both attributes.
private final class Reporter189HoldbackProvider: HLSSegmentProvider, @unchecked Sendable {
    let n: Int
    let segSeconds: Double
    init(n: Int, segSeconds: Double = 4.800) { self.n = n; self.segSeconds = segSeconds }

    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { n }
    func segmentDuration(at index: Int) -> Double { segSeconds }
    var playlistType: HLSPlaylistType { .live }
    var liveTargetSegmentDuration: Double? { 4.0 }
    var liveTargetDurationFloorSeconds: Double? { nil }

    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int) {
        (n, 0, 1, false, 0)
    }
}

final class Issue189LiveEdgeHoldbackTests: XCTestCase {

    // MARK: - Shared TARGETDURATION / holdback policy

    func testTargetDurationFlooredByCutTargetForLongGOP() {
        // 4.8s segments: ceil(4.8)=5, floored up to ceil(1.5*4.0)=6.
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 4.8, cutTargetSeconds: 4.0, cadenceFloorSeconds: nil), 6)
        // 5.76s segments: ceil(5.76)=6 already dominates the cut-target floor.
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 5.76, cutTargetSeconds: 4.0, cadenceFloorSeconds: nil), 6)
        // Observed cadence dominates when the upstream is bursty.
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 4.8, cutTargetSeconds: 4.0, cadenceFloorSeconds: 9.2), 10)
    }

    func testHoldBackIsThreeTargetDurations() {
        XCTAssertEqual(LiveEdgePolicy.holdBackSeconds(targetDuration: 6), 18.0, accuracy: 0.0001)
    }

    // MARK: - Startup cushion sizing

    func testStartupCushionRejectsSubHoldbackWindow() {
        // Two 4.8s segments = 9.6s < 18s holdback -> the reporter's exact failing startup window.
        XCTAssertFalse(LiveEdgePolicy.startupCushionSatisfied(
            segmentCount: 2, summedDurationSeconds: 9.6, maxSegmentDuration: 4.8,
            cutTargetSeconds: 4.0, cadenceFloorSeconds: nil, windowSegmentCount: 15))
    }

    func testStartupCushionAcceptsHoldbackDepth() {
        // Four 4.8s segments = 19.2s >= 18s holdback.
        XCTAssertTrue(LiveEdgePolicy.startupCushionSatisfied(
            segmentCount: 4, summedDurationSeconds: 19.2, maxSegmentDuration: 4.8,
            cutTargetSeconds: 4.0, cadenceFloorSeconds: nil, windowSegmentCount: 15))
    }

    func testStartupCushionNeverServesSingleSegment() {
        // Even a single huge segment that already covers the holdback must not be served alone (-12888).
        XCTAssertFalse(LiveEdgePolicy.startupCushionSatisfied(
            segmentCount: 1, summedDurationSeconds: 30.0, maxSegmentDuration: 30.0,
            cutTargetSeconds: 4.0, cadenceFloorSeconds: nil, windowSegmentCount: 15))
    }

    func testStartupCushionBoundedByWindowForTinySegments() {
        // Tiny 2s segments: 3xTD (TD floored to 6) = 18s would need 9 segments, but the window only ever
        // holds windowSegmentCount; reaching that count releases the gate so a full window never blocks.
        XCTAssertTrue(LiveEdgePolicy.startupCushionSatisfied(
            segmentCount: 8, summedDurationSeconds: 16.0, maxSegmentDuration: 2.0,
            cutTargetSeconds: 4.0, cadenceFloorSeconds: nil, windowSegmentCount: 8))
    }

    // MARK: - Served playlist

    func testServedPlaylistAdvertisesHoldBack() {
        let provider = Reporter189HoldbackProvider(n: 4)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        print("=== AE#189 served loopback media.m3u8 (holdback) ===\n\(playlist)\n=== end ===")

        let td = playlist.split(separator: "\n")
            .first { $0.hasPrefix("#EXT-X-TARGETDURATION:") }
            .flatMap { Int($0.dropFirst("#EXT-X-TARGETDURATION:".count)) }
        XCTAssertEqual(td, 6, "TD must cover the long-GOP segment")

        let serverControl = playlist.split(separator: "\n").first { $0.hasPrefix("#EXT-X-SERVER-CONTROL:") }
        XCTAssertNotNil(serverControl, "live playlist must advertise EXT-X-SERVER-CONTROL")
        XCTAssertTrue(serverControl?.contains("HOLD-BACK=18.000") ?? false,
                      "holdback must be pinned to 3 x TD so AVPlayer stops falling back to the implicit default: \(serverControl ?? "")")
        // Single SERVER-CONTROL line carrying both attributes (spec: one tag, comma-separated attributes).
        XCTAssertTrue(serverControl?.contains("CAN-BLOCK-RELOAD=YES") ?? false,
                      "blocking-reload attribute must ride the same line: \(serverControl ?? "")")
        XCTAssertEqual(playlist.components(separatedBy: "#EXT-X-SERVER-CONTROL:").count - 1, 1,
                       "exactly one EXT-X-SERVER-CONTROL line")
    }
}
