import XCTest
@testable import AetherEngine

final class MPLSParserTests: XCTestCase {
    private func makeMPLS() -> [UInt8] {
        func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8((v>>24)&0xff), UInt8((v>>16)&0xff), UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func playItem(clip: String, inT: Int, outT: Int) -> [UInt8] {
            var body = [UInt8]()
            body += Array(clip.utf8)
            body += Array("M2TS".utf8)
            body += be16(0)
            body.append(0)
            body += be32(inT)
            body += be32(outT)
            body += [UInt8](repeating: 0, count: 8)
            return be16(body.count) + body
        }
        let items = playItem(clip: "00002", inT: 0, outT: 90000)
                  + playItem(clip: "00005", inT: 0, outT: 180000)
        var playlist = [UInt8]()
        playlist += be32(0)
        playlist += be16(0)
        playlist += be16(2)
        playlist += be16(0)
        playlist += items
        var out = [UInt8]()
        out += Array("MPLS".utf8)
        out += Array("0200".utf8)
        let plStart = 40
        out += be32(plStart)
        out += be32(0)
        out += [UInt8](repeating: 0, count: plStart - out.count)
        out += playlist
        return out
    }

    func test_parsesClipOrderAndDuration() {
        let pl = try! XCTUnwrap(MPLSParser.parse(makeMPLS()))
        XCTAssertEqual(pl.clipIDs, ["00002", "00005"])
        XCTAssertEqual(pl.durationTicks, 270000)
    }

    func test_rejectsBadMagic() {
        XCTAssertNil(MPLSParser.parse(Array("NOPE0200".utf8) + [UInt8](repeating: 0, count: 40)))
    }
}
