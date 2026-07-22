// Tests/AetherEngineTests/Issue189ServedTargetDurationTests.swift
// AE#189 ground-truth: reproduce the EXACT served loopback media playlist for the reporter's
// scenario (4K50 HEVC-in-TS, cut target 4.0s, actual keyframe-aligned segments 5.76s) and pin
// what #EXT-X-TARGETDURATION the real builder emits. The reporter inferred TD=3 from AVFoundation's
// -16832 message; this pins what the loopback ACTUALLY serves.
import XCTest
@testable import AetherEngine

/// Mirrors the real VideoSegmentProvider's builder-visible outputs for the reporter's stream:
/// finalized live segments of 5.76s (GOP at 50fps), cut target 4.0s, cadence floor still nil
/// (LiveCadencePolicy not yet converged / absent), which is the WORST case for the TD floor.
private final class Reporter189Provider: HLSSegmentProvider, @unchecked Sendable {
    let n: Int
    init(n: Int) { self.n = n }

    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { n }
    func segmentDuration(at index: Int) -> Double { 5.760 }   // real finalized duration from the reporter's logs
    var playlistType: HLSPlaylistType { .live }
    var liveTargetSegmentDuration: Double? { 4.0 }            // liveWindowSizing.targetSegmentDurationSeconds
    var liveTargetDurationFloorSeconds: Double? { nil }       // cadence floor absent / unconverged: worst case

    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int) {
        (n, 0, 1, false, 0)
    }
}

final class Issue189ServedTargetDurationTests: XCTestCase {
    func testServedTargetDurationNeverBelowSegmentDuration() {
        let provider = Reporter189Provider(n: 6)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        print("=== AE#189 served loopback media.m3u8 ===\n\(playlist)\n=== end ===")

        let td = playlist
            .split(separator: "\n")
            .first { $0.hasPrefix("#EXT-X-TARGETDURATION:") }
            .flatMap { Int($0.dropFirst("#EXT-X-TARGETDURATION:".count)) }
        XCTAssertNotNil(td)
        // HLS spec: TARGETDURATION >= ceil(max EXTINF). Reporter claims served TD=3 while EXTINF=5.76.
        XCTAssertGreaterThanOrEqual(td ?? 0, 6, "served TD must cover the 5.76s segment; builder can never emit 3")
    }
}
