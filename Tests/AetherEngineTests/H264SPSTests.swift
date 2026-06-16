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
}
