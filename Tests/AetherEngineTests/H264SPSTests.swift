import XCTest
@testable import AetherEngine

final class H264SPSTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    // Real Pluto ad creative SPS (NAL incl 0x67 header), high profile.
    func testAdSPSIs1280x720() {
        let sps = hex("6764001facd9405005bb016a02040280000003008000001e078c18cb")
        let dim = H264SPS.dimensions(fromNAL: sps)
        XCTAssertEqual(dim?.width, 1280)
        XCTAssertEqual(dim?.height, 720)
    }

    // Real Pluto program (content) SPS, high profile, cropped to 684.
    func testContentSPSIs1216x684() {
        let sps = hex("6764001facd9404c057fbc05a828282a000003000200000300781e30632c")
        let dim = H264SPS.dimensions(fromNAL: sps)
        XCTAssertEqual(dim?.width, 1216)
        XCTAssertEqual(dim?.height, 684)
    }

    func testRejectsNonSPS() {
        XCTAssertNil(H264SPS.dimensions(fromNAL: hex("68efbcb0"))) // PPS
        XCTAssertNil(H264SPS.dimensions(fromNAL: []))
        XCTAssertNil(H264SPS.dimensions(fromNAL: hex("67")))       // header only
    }

    // #133: a real 720p SPS + PPS + IDR-slice access unit (Annex-B, 4-byte start codes).
    private let sc: [UInt8] = [0, 0, 0, 1]
    private var sps720: [UInt8] { hex("6764001facd9405005bb016a02040280000003008000001e078c18cb") }
    private var pps: [UInt8] { hex("68efbcb0") }

    private func annexB(_ nals: [[UInt8]]) -> [UInt8] {
        nals.reduce(into: [UInt8]()) { $0 += sc + $1 }
    }

    private func withBuf<R>(_ bytes: [UInt8], _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        bytes.withUnsafeBufferPointer { body($0) }
    }

    // #133: a mid-stream join must start on a true IDR (NAL type 5), not an open-GOP recovery
    // point (non-IDR slice, type 1), or the panel renders references it never received (green frames).
    func testContainsIDRDetectsType5Slice() {
        let au = annexB([sps720, pps, [0x65, 0x88, 0x84, 0x00]]) // 0x65 = IDR slice (type 5)
        XCTAssertTrue(withBuf(au) { H264SPS.containsIDR(fromAnnexB: $0) })
    }

    func testContainsIDRRejectsNonIDRAccessUnit() {
        let au = annexB([sps720, pps, [0x41, 0x9a, 0x00, 0x00]]) // 0x41 = non-IDR slice (type 1)
        XCTAssertFalse(withBuf(au) { H264SPS.containsIDR(fromAnnexB: $0) })
    }

    func testContainsIDRRejectsBareParameterSets() {
        let au = annexB([sps720, pps]) // params only, no coded slice
        XCTAssertFalse(withBuf(au) { H264SPS.containsIDR(fromAnnexB: $0) })
    }

    func testContainsIDRHandlesThreeByteStartCodes() {
        let sc3: [UInt8] = [0, 0, 1]
        let au = sc3 + sps720 + sc3 + pps + sc3 + [0x65, 0x88]
        XCTAssertTrue(withBuf(au) { H264SPS.containsIDR(fromAnnexB: $0) })
    }

    // #133 join gate: the decodable-access-unit predicate needs SPS + PPS + IDR all present.
    // A recovery-point AU (params present, but slice is non-IDR) must NOT satisfy it.
    func testExtractSPSandPPSStillSucceedsOnRecoveryPointAU() {
        let au = annexB([sps720, pps, [0x41, 0x9a]])
        let got = withBuf(au) { H264SPS.extractSPSandPPS(fromAnnexB: $0) }
        XCTAssertNotNil(got)                                    // params are there
        XCTAssertEqual(H264SPS.dimensions(fromNAL: got!.sps)?.width, 1280)
        XCTAssertFalse(withBuf(au) { H264SPS.containsIDR(fromAnnexB: $0) }) // but no IDR -> gate stays closed
    }
}
