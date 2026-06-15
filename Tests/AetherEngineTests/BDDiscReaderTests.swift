import XCTest
@testable import AetherEngine

final class BDDiscReaderTests: XCTestCase {
    private func bdImage() -> Data {
        func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8((v>>24)&0xff),UInt8((v>>16)&0xff),UInt8((v>>8)&0xff),UInt8(v&0xff)] }
        let pi = Array("00001".utf8) + Array("M2TS".utf8) + be16(0) + [0] + be32(0) + be32(90000) + [UInt8](repeating:0,count:8)
        let playlist = be32(0) + be16(0) + be16(1) + be16(0) + (be16(pi.count) + pi)
        var mpls = Array("MPLS".utf8) + Array("0200".utf8) + be32(40) + be32(0)
        mpls += [UInt8](repeating: 0, count: 40 - mpls.count) + playlist
        var m2ts = [UInt8]()
        for _ in 0..<400 { m2ts += [0x00,0x00,0x00,0x00, 0x47] + [UInt8](repeating: 0x10, count: 187) }
        return UDFFixture.make(mplsBytes: mpls, m2tsBytes: m2ts)
    }

    func test_wrapReturnsMpegtsConcatForBD() throws {
        let (reader, hint) = try XCTUnwrap(try DiscReader.wrap(DataIOReader(data: bdImage())))
        XCTAssertEqual(hint, "mpegts")
        var buf = [UInt8](repeating: 0, count: 5)
        _ = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 5) }
        XCTAssertEqual(buf, [0x00,0x00,0x00,0x00,0x47])
    }

    func test_nilForNonDisc() throws {
        XCTAssertNil(try DiscReader.wrap(DataIOReader(data: Data(repeating: 0, count: 600*1024))))
    }
}
