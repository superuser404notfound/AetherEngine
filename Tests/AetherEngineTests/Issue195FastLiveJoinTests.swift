// Tests/AetherEngineTests/Issue195FastLiveJoinTests.swift
// AE#195: raw-TS live over HTTP (IPTV zapping) took 10-18s to first frame on the native path. The AE#189
// startup cushion gates the first manifest on HOLD-BACK = 3 x TARGETDURATION of content, and TD never fell
// below 6 because the ceil(1.5 x cut target) floor with the fixed 4.0s cut target dominates, so a
// strict-realtime origin had to produce 18s of content in wall-clock time before the join.
// Fix: LoadOptions.liveJoinProfile = .fastZap shrinks the live cut target to 0.5s. Segments then quantize
// to the source keyframe cadence, TD is driven by the real GOP length (ceil(max EXTINF)), and the holdback
// the join waits for follows it (typically 3-6s wall-clock on short-GOP IPTV). The AE#189 contract itself
// (first serve only once the window carries >= 3 x TD; HOLD-BACK advertised at the RFC 8216bis floor) is
// unchanged, so long-GOP sources degrade to .standard behavior automatically and -16832 stays fixed.
import XCTest
@testable import AetherEngine

/// Reporter's source shape (progressive 1080p50 H.264, short GOP) under the fastZap profile: keyframe
/// cadence ~0.96s, cut target 0.5s, no cadence floor (plain-URL live has no cadence signal).
private final class Issue195FastZapProvider: HLSSegmentProvider, @unchecked Sendable {
    let n: Int
    let segSeconds: Double
    init(n: Int, segSeconds: Double = 0.960) { self.n = n; self.segSeconds = segSeconds }

    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { n }
    func segmentDuration(at index: Int) -> Double { segSeconds }
    var playlistType: HLSPlaylistType { .live }
    var liveTargetSegmentDuration: Double? { HLSVideoEngine.fastZapLiveCutTargetSeconds }
    var liveTargetDurationFloorSeconds: Double? { nil }

    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int) {
        (n, 0, 1, false, 0)
    }
}

final class Issue195FastLiveJoinTests: XCTestCase {

    // MARK: - Profile mapping

    func testProfileCutTargets() {
        XCTAssertEqual(HLSVideoEngine.liveCutTargetSeconds(for: .standard),
                       HLSVideoEngine.targetSegmentDuration,
                       ".standard must keep the historical 4s cut target")
        XCTAssertEqual(HLSVideoEngine.liveCutTargetSeconds(for: .fastZap), 0.5, accuracy: 0.0001)
    }

    func testLoadOptionsDefaultIsStandard() {
        XCTAssertEqual(LoadOptions().liveJoinProfile, .standard,
                       "fast join is an explicit host opt-in; the default must not change AE#189 behavior")
    }

    // MARK: - TARGETDURATION / holdback under fastZap

    func testFastZapShortGOPTargetDurationTracksGOP() {
        // 0.96s keyframe cadence: ceil(0.96)=1, cut floor ceil(1.5*0.5)=1 -> TD=1 -> 3s holdback.
        let cut = HLSVideoEngine.liveCutTargetSeconds(for: .fastZap)
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 0.96, cutTargetSeconds: cut, cadenceFloorSeconds: nil), 1)
        XCTAssertEqual(LiveEdgePolicy.holdBackSeconds(targetDuration: 1), 3.0, accuracy: 0.0001)
        // 2s GOP: ceil(1.92)=2 -> TD=2 -> 6s holdback. Still 3x faster than the standard 18s.
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 1.92, cutTargetSeconds: cut, cadenceFloorSeconds: nil), 2)
    }

    func testFastZapLongGOPDegradesToStandardBehavior() {
        // AE#189's 5.76s long-GOP segments: the cut target cannot shorten a GOP, so TD (and with it the
        // 18s holdback and the -16832 guarantee) is identical under both profiles.
        let fast = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 5.76,
                                                        cutTargetSeconds: HLSVideoEngine.liveCutTargetSeconds(for: .fastZap),
                                                        cadenceFloorSeconds: nil)
        let standard = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 5.76,
                                                            cutTargetSeconds: HLSVideoEngine.liveCutTargetSeconds(for: .standard),
                                                            cadenceFloorSeconds: nil)
        XCTAssertEqual(fast, standard)
        XCTAssertEqual(fast, 6)
    }

    func testFastZapObservedCadenceFloorStillDominates() {
        // A bursty ingest origin (AE#167) keeps its observed-cadence TD floor under fastZap: fast join
        // never trades away the raised patience that bursty delivery requires.
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 0.96,
                                                            cutTargetSeconds: HLSVideoEngine.liveCutTargetSeconds(for: .fastZap),
                                                            cadenceFloorSeconds: 4.2), 5)
    }

    // MARK: - Startup cushion under fastZap

    func testFastZapStartupCushionReleasesAtThreeSeconds() {
        let cut = HLSVideoEngine.liveCutTargetSeconds(for: .fastZap)
        // 3 x 0.96s = 2.88s < 3s holdback -> keep holding.
        XCTAssertFalse(LiveEdgePolicy.startupCushionSatisfied(
            segmentCount: 3, summedDurationSeconds: 2.88, maxSegmentDuration: 0.96,
            cutTargetSeconds: cut, cadenceFloorSeconds: nil, windowSegmentCount: 120))
        // 4 x 0.96s = 3.84s >= 3s holdback -> first manifest may serve (~4s wall-clock join).
        XCTAssertTrue(LiveEdgePolicy.startupCushionSatisfied(
            segmentCount: 4, summedDurationSeconds: 3.84, maxSegmentDuration: 0.96,
            cutTargetSeconds: cut, cadenceFloorSeconds: nil, windowSegmentCount: 120))
        // The two-segment minimum still applies (-12888 guard) even when one long segment covers 3s.
        XCTAssertFalse(LiveEdgePolicy.startupCushionSatisfied(
            segmentCount: 1, summedDurationSeconds: 4.0, maxSegmentDuration: 4.0,
            cutTargetSeconds: cut, cadenceFloorSeconds: nil, windowSegmentCount: 120))
    }

    // MARK: - Window sizing under fastZap

    func testFastZapWindowStillCoversHoldback() {
        // 60s live-only floor at a 0.5s cut target: 120 visible segments. The window (>= 60s of content)
        // stays far above the 3s holdback, so the startup gate's windowSegmentCount upper bound can never
        // release a sub-holdback first manifest.
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: HLSVideoEngine.fastZapLiveCutTargetSeconds,
                                      dvrWindowSeconds: nil)
        XCTAssertEqual(sizing.windowSegmentCount, 120)
    }

    // MARK: - Served playlist under fastZap

    func testServedPlaylistFastZapAdvertisesShrunkHoldback() {
        let provider = Issue195FastZapProvider(n: 4)
        let playlist = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        print("=== AE#195 served loopback media.m3u8 (fastZap) ===\n\(playlist)\n=== end ===")

        let td = playlist.split(separator: "\n")
            .first { $0.hasPrefix("#EXT-X-TARGETDURATION:") }
            .flatMap { Int($0.dropFirst("#EXT-X-TARGETDURATION:".count)) }
        XCTAssertEqual(td, 1, "TD must track the real GOP-quantized segment duration, not the 4s-era floor")

        let serverControl = playlist.split(separator: "\n").first { $0.hasPrefix("#EXT-X-SERVER-CONTROL:") }
        XCTAssertNotNil(serverControl, "fastZap must keep advertising the AE#189 explicit holdback")
        XCTAssertTrue(serverControl?.contains("HOLD-BACK=3.000") ?? false,
                      "holdback stays pinned at the RFC 8216bis floor of 3 x TD: \(serverControl ?? "")")
        XCTAssertTrue(serverControl?.contains("CAN-BLOCK-RELOAD=YES") ?? false,
                      "blocking reload rides the same SERVER-CONTROL line: \(serverControl ?? "")")
    }
}
