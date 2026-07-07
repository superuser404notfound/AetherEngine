import XCTest
@testable import AetherEngine

final class BDDiscReaderTests: XCTestCase {
    private func bdImage() -> Data {
        func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8((v>>24)&0xff),UInt8((v>>16)&0xff),UInt8((v>>8)&0xff),UInt8(v&0xff)] }
        // Build with incremental += (not one long + chain) so the Swift type
        // checker stays fast; the chained form trips "unable to type-check in
        // reasonable time" on CI.
        var pi: [UInt8] = []
        pi += Array("00001".utf8); pi += Array("M2TS".utf8); pi += be16(0); pi.append(0)
        pi += be32(0); pi += be32(90000); pi += [UInt8](repeating: 0, count: 8)
        var playlist: [UInt8] = []
        playlist += be32(0); playlist += be16(0); playlist += be16(1); playlist += be16(0)
        playlist += be16(pi.count); playlist += pi
        var mpls: [UInt8] = []
        mpls += Array("MPLS".utf8); mpls += Array("0200".utf8); mpls += be32(40); mpls += be32(0)
        mpls += [UInt8](repeating: 0, count: 40 - mpls.count); mpls += playlist
        var m2ts: [UInt8] = []
        for _ in 0..<400 { m2ts += [0x00, 0x00, 0x00, 0x00, 0x47]; m2ts += [UInt8](repeating: 0x10, count: 187) }
        return UDFFixture.make(mplsBytes: mpls, m2tsBytes: m2ts)
    }

    func test_wrapReturnsMpegtsConcatForBD() throws {
        let info = try XCTUnwrap(try DiscReader.wrap(DataIOReader(data: bdImage())))
        XCTAssertEqual(info.formatHint, "mpegts")
        XCTAssertEqual(info.titles.count, 1)  // single-playlist fixture -> one title
        XCTAssertEqual(info.selectedTitleIndex, 0)
        XCTAssertTrue(info.clipTimeline.isEmpty)  // AE#105: single-clip title needs no normalization (no-op)
        var buf = [UInt8](repeating: 0, count: 5)
        _ = buf.withUnsafeMutableBufferPointer { info.reader.read($0.baseAddress, size: 5) }
        XCTAssertEqual(buf, [0x00,0x00,0x00,0x00,0x47])
    }

    func test_nilForNonDisc() throws {
        XCTAssertNil(try DiscReader.wrap(DataIOReader(data: Data(repeating: 0, count: 600*1024))))
    }

    // Regression for #62: a real UDF 2.50 Blu-ray stores directory data inside the
    // metadata partition (short_ad, metadata-virtual) while the m2ts payload lives in
    // the physical partition (long_ad, ref 0). The old extentPartRef mapped a metadata
    // FE's short_ad to the physical partition, so the root directory read garbage and
    // BDMV was never found. The inspector must now report a recognized Blu-ray.
    func test_inspectReportsBluRay() throws {
        let d = DiscInspector.inspect(DataIOReader(data: bdImage()))
        XCTAssertEqual(d.kind, .bluRay)
        XCTAssertTrue(d.bdmvPresent)
        XCTAssertEqual(d.selectedTitleClipIDs, ["00001"])
        XCTAssertGreaterThanOrEqual(d.resolvedM2TSExtentCount, 2)
        XCTAssertTrue(d.wrapRecognized)
        XCTAssertEqual(d.wrapFormatHint, "mpegts")
    }

    // #67: selectTitle threads a title id into wrap. An out-of-range id must clamp to the main
    // title (index 0), not crash or leak a stale id from a previously played disc. This is the
    // cross-disc-bleed safety net selectTitle(id:) and the bg-resume reload both rely on.
    func test_wrapSelectTitleIDOutOfRangeClampsToMain() throws {
        let info = try XCTUnwrap(try DiscReader.wrap(DataIOReader(data: bdImage()), selectTitleID: 7))
        XCTAssertEqual(info.titles.count, 1)
        XCTAssertEqual(info.selectedTitleIndex, 0)
    }

    func test_wrapSelectTitleIDInRangeSelectsIt() throws {
        let info = try XCTUnwrap(try DiscReader.wrap(DataIOReader(data: bdImage()), selectTitleID: 0))
        XCTAssertEqual(info.selectedTitleIndex, 0)
        XCTAssertEqual(info.selectedTitle?.id, 0)
    }

    func test_inspectListsTitles() throws {
        let d = DiscInspector.inspect(DataIOReader(data: bdImage()))
        XCTAssertEqual(d.titles.count, 1)                          // single-playlist fixture -> one title
        XCTAssertEqual(d.titles[0].id, 0)
        XCTAssertEqual(d.selectedTitleIndex, 0)
        XCTAssertTrue(d.titles[0].chapterStartsSeconds.isEmpty)    // the fixture playlist declares no PlayListMarks
    }
}
