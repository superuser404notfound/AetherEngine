// Tests/AetherEngineTests/Issue670FastZapGOPHeadroomTests.swift
// AE#670: live 1080p50 H.264 TS under `.fastZap` froze at irregular intervals, with AVPlayer reporting
// -12888 (playlist unchanged for longer than 1.5 x target duration) and #524 firing on 1.5 to 2 s of
// runway. The fastZap cut target (0.5 s) sits below any real GOP, so every segment the engine cuts is one
// whole source GOP. The TARGETDURATION is sealed from the first window, which on the reported source held
// three 1.000 s GOPs: TD 1, holdback 3 s, and no headroom at all over the GOP it had seen. The source's
// GOPs are not regular (1.0 to 2.4 s), so every longer one broke `EXTINF <= TD` and left the playlist
// unchanged past 1.5 x TD. `.standard` never had the problem because its `1.5 x cut target` floor is that
// headroom; under fastZap it collapses to 1 s.
//
// Measured with `aetherctl live --fast-zap --realtime --preroll 0` on a seed with that GOP pattern, two
// passes per arm: sealed at 1 s, one stall, the playlist refused as a parse error (-12642, macOS AVPlayer
// is stricter than the reporter's tvOS one) and a fall to the software path on both passes; sealed at 2 s,
// none of the three on either.
import XCTest
@testable import AetherEngine

final class Issue670FastZapGOPHeadroomTests: XCTestCase {

    private let fastZapCut = HLSVideoEngine.liveCutTargetSeconds(for: .fastZap)
    private let standardCut = HLSVideoEngine.liveCutTargetSeconds(for: .standard)

    /// The reported seal: three 1.000 s GOPs in the first window.
    func testSelfCutFastZapSealsHeadroomOverTheFirstGOPs() {
        let td = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 1.0,
                                                      cutTargetSeconds: fastZapCut,
                                                      cadenceFloorSeconds: nil,
                                                      segmentsAreCutHere: true)
        XCTAssertEqual(td, 2)
        XCTAssertEqual(LiveEdgePolicy.holdBackSeconds(targetDuration: td), 6.0, accuracy: 1e-9)
    }

    /// What the seal has to survive afterwards: the 2.4 s GOP the reporter's log shows. It must round
    /// under TD (RFC 8216 4.3.3.1), and the playlist must not stay unchanged past AVPlayer's patience
    /// while the cutter waits for the keyframe that ends it.
    func testLaterLongGOPStaysInsideTheSealedValue() {
        let td = LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 1.0,
                                                      cutTargetSeconds: fastZapCut,
                                                      cadenceFloorSeconds: nil,
                                                      segmentsAreCutHere: true)
        let laterGOP = 2.4
        XCTAssertLessThanOrEqual(Int(laterGOP.rounded()), td)
        XCTAssertGreaterThan(Double(td) * LiveEdgePolicy.unchangedPlaylistPatienceMultiplier, laterGOP)
    }

    func testHeadroomScalesWithTheObservedGOP() {
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 0.96,
                                                            cutTargetSeconds: fastZapCut,
                                                            cadenceFloorSeconds: nil,
                                                            segmentsAreCutHere: true), 2)
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 1.92,
                                                            cutTargetSeconds: fastZapCut,
                                                            cadenceFloorSeconds: nil,
                                                            segmentsAreCutHere: true), 3)
    }

    /// AE#447: ingested segments are the upstream's own, bounded by its advertised target duration, so
    /// the field-measured TD 2 on 2.000 s segments stays.
    func testIngestedSegmentsKeepTheirTargetDuration() {
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 2.0,
                                                            cutTargetSeconds: fastZapCut,
                                                            cadenceFloorSeconds: 2.0,
                                                            segmentsAreCutHere: false), 2)
    }

    /// `.standard`'s cut target bounds its segments, and its `1.5 x cut target` floor is already the
    /// headroom: the common 1.92 s GOP shape cuts 5.76 s segments and must keep TD 6, not rise to 9.
    func testStandardProfileIsUnchanged() {
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 5.76,
                                                            cutTargetSeconds: standardCut,
                                                            cadenceFloorSeconds: nil,
                                                            segmentsAreCutHere: true), 6)
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(maxSegmentDuration: 4.0,
                                                            cutTargetSeconds: standardCut,
                                                            cadenceFloorSeconds: nil,
                                                            segmentsAreCutHere: true), 6)
    }

    func testSealAccountNamesTheHeadroomTerm() {
        let derivation = LiveTargetDurationDerivation(
            value: 2, maxSegmentDuration: 1.0, cutTargetFloor: fastZapCut,
            gopHeadroomApplies: true, cadenceFloor: .unmeasurable, selfReported: nil)
        XCTAssertTrue(derivation.account.contains("1.5 x max EXTINF 1.500s"), derivation.account)
    }
}
