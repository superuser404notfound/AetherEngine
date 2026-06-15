import XCTest
@testable import AetherEngine

final class UDFReaderTests: XCTestCase {
    private func image() -> Data {
        // tiny mpls (2s clip 00001) + a recognizable m2ts payload
        func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8((v>>24)&0xff),UInt8((v>>16)&0xff),UInt8((v>>8)&0xff),UInt8(v&0xff)] }
        var pi = [UInt8](); pi += Array("00001".utf8) + Array("M2TS".utf8) + be16(0) + [0] + be32(0) + be32(90000) + [UInt8](repeating:0,count:8)
        let playlist = be32(0) + be16(0) + be16(1) + be16(0) + (be16(pi.count) + pi)
        var mpls = Array("MPLS".utf8) + Array("0200".utf8) + be32(40) + be32(0)
        mpls += [UInt8](repeating: 0, count: 40 - mpls.count) + playlist
        // m2ts: BDAV-ish: 4-byte TP_extra header then 0x47 sync, repeated; make it 2 sectors
        var m2ts = [UInt8]()
        for _ in 0..<400 { m2ts += [0x00,0x00,0x00,0x00, 0x47] + [UInt8](repeating: 0x10, count: 187) }
        return UDFFixture.make(mplsBytes: mpls, m2tsBytes: m2ts)
    }

    func test_listsBDMVChildren() throws {
        let udf = try UDFReader(reader: DataIOReader(data: image()))
        let root = try udf.list(path: [])
        XCTAssertTrue(root.contains { $0.name == "BDMV" && $0.isDir })
        let bdmv = try udf.list(path: ["BDMV"])
        let names = bdmv.map(\.name).sorted()
        XCTAssertEqual(names, ["PLAYLIST", "STREAM"])
    }

    func test_resolvesPlaylistFileExtents() throws {
        let udf = try UDFReader(reader: DataIOReader(data: image()))
        let pl = try udf.list(path: ["BDMV", "PLAYLIST"])
        let mpls = try XCTUnwrap(pl.first { $0.name == "00000.mpls" })
        let extents = try udf.extents(of: mpls)
        XCTAssertFalse(extents.isEmpty)
        // read the bytes via a ConcatIOReader over those extents; must start with "MPLS"
        let reader = ConcatIOReader(base: DataIOReader(data: image()), extents: extents)
        var buf = [UInt8](repeating: 0, count: 4)
        _ = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 4) }
        XCTAssertEqual(buf, Array("MPLS".utf8))
    }

    func test_resolvesFragmentedM2TS() throws {
        let udf = try UDFReader(reader: DataIOReader(data: image()))
        let stream = try udf.list(path: ["BDMV", "STREAM"])
        let m2ts = try XCTUnwrap(stream.first { $0.name == "00001.m2ts" })
        let extents = try udf.extents(of: m2ts)
        XCTAssertEqual(extents.count, 2) // fragmented: two extents
        let reader = ConcatIOReader(base: DataIOReader(data: image()), extents: extents)
        var buf = [UInt8](repeating: 0, count: 5)
        _ = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 5) }
        XCTAssertEqual(buf, [0x00,0x00,0x00,0x00,0x47]) // first TP_extra + sync
    }

    func test_rejectsNonUDF() {
        XCTAssertThrowsError(try UDFReader(reader: DataIOReader(data: Data(repeating: 0, count: 600*1024)))) { err in
            guard case DiscError.notUDF = err else { return XCTFail("wrong error: \(err)") }
        }
    }

    func test_truncatedImageThrowsNotTrap() throws {
        // A valid UDF image truncated before its volume structure must throw,
        // not trap. Build the full fixture then cut it to just past the AVDP.
        func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8((v>>24)&0xff),UInt8((v>>16)&0xff),UInt8((v>>8)&0xff),UInt8(v&0xff)] }
        let pi = Array("00001".utf8) + Array("M2TS".utf8) + be16(0) + [0] + be32(0) + be32(90000) + [UInt8](repeating:0,count:8)
        let playlist = be32(0) + be16(0) + be16(1) + be16(0) + (be16(pi.count) + pi)
        var mpls = Array("MPLS".utf8) + Array("0200".utf8) + be32(40) + be32(0)
        mpls += [UInt8](repeating: 0, count: 40 - mpls.count) + playlist
        var m2ts = [UInt8](); for _ in 0..<400 { m2ts += [0x00,0x00,0x00,0x00,0x47] + [UInt8](repeating:0x10,count:187) }
        let full = UDFFixture.make(mplsBytes: mpls, m2tsBytes: m2ts)
        let truncated = full.prefix(258 * 2048) // AVDP present (sector 256), VDS cut off
        XCTAssertThrowsError(try {
            let udf = try UDFReader(reader: DataIOReader(data: Data(truncated)))
            _ = try udf.list(path: ["BDMV"])
        }())
    }
}
