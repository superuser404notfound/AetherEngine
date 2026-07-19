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
        var au: [UInt8] = sc3
        au += sps720
        au += sc3
        au += pps
        au += sc3
        au += [0x65, 0x88]
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

    // MARK: - #150 frame_mbs_only_flag fallback

    // Main profile 4.0, 1920x1080, frame_mbs_only=0, mb_adaptive=0 (PAFF) - the reporter's channel shape.
    private var spsInterlaced1080i: [UInt8] { hex("674d4028eca03c0223ed") }

    func testInterlacedSPSParsesDimensionsAndFrameMbsOnlyFalse() {
        let dim = H264SPS.dimensions(fromNAL: spsInterlaced1080i)
        XCTAssertEqual(dim?.width, 1920)
        XCTAssertEqual(dim?.height, 1080)
        XCTAssertEqual(H264SPS.frameMbsOnly(fromNAL: spsInterlaced1080i), false)
    }

    func testProgressiveSPSFrameMbsOnlyTrue() {
        XCTAssertEqual(H264SPS.frameMbsOnly(fromNAL: sps720), true)
    }

    func testFrameMbsOnlyRejectsNonSPS() {
        XCTAssertNil(H264SPS.frameMbsOnly(fromNAL: hex("68efbcb0"))) // PPS
        XCTAssertNil(H264SPS.frameMbsOnly(fromNAL: []))
    }

    func testSPSNALFromAnnexBExtradata() {
        let extradata = annexB([spsInterlaced1080i, pps])
        let sps = H264SPS.spsNAL(fromExtradata: extradata)
        XCTAssertEqual(sps, spsInterlaced1080i)
    }

    func testSPSNALFromAvcCExtradata() {
        var avcc: [UInt8] = [0x01, 0x4d, 0x40, 0x28, 0xff, 0xe1]
        avcc += [UInt8(spsInterlaced1080i.count >> 8), UInt8(spsInterlaced1080i.count & 0xff)]
        avcc += spsInterlaced1080i
        avcc += [0x01, UInt8(pps.count >> 8), UInt8(pps.count & 0xff)]
        avcc += pps
        let sps = H264SPS.spsNAL(fromExtradata: avcc)
        XCTAssertEqual(sps, spsInterlaced1080i)
    }

    func testSPSNALRejectsGarbageOrEmpty() {
        XCTAssertNil(H264SPS.spsNAL(fromExtradata: []))
        XCTAssertNil(H264SPS.spsNAL(fromExtradata: [0xde, 0xad, 0xbe, 0xef]))
        XCTAssertNil(H264SPS.spsNAL(fromExtradata: [0x01, 0x4d])) // truncated avcC header
        XCTAssertNil(H264SPS.spsNAL(fromExtradata: annexB([pps]))) // params without SPS
    }
}
