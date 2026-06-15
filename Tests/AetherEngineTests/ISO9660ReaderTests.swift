import XCTest
@testable import AetherEngine

final class ISO9660ReaderTests: XCTestCase {
    func test_listsVideoTSFiles() throws {
        let data = ISO9660Fixture.make(files: [
            .init(name: "VIDEO_TS.IFO", length: 12_000),
            .init(name: "VTS_01_1.VOB", length: 1_000_000_000),
            .init(name: "VTS_01_2.VOB", length: 500_000_000),
        ])
        let iso = try ISO9660Reader(reader: DataIOReader(data: data))
        let files = try iso.list(directory: "VIDEO_TS")
        let names = files.map(\.name).sorted()
        XCTAssertEqual(names, ["VIDEO_TS.IFO", "VTS_01_1.VOB", "VTS_01_2.VOB"])
        let vob1 = try XCTUnwrap(files.first { $0.name == "VTS_01_1.VOB" })
        XCTAssertEqual(vob1.length, 1_000_000_000)
        XCTAssertEqual(vob1.startSector, 20) // sector 19 = IFO, 20 = VOB1 (declaration order)
    }

    func test_rejectsNonISO() throws {
        let data = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]) // mp4 'ftyp'
        XCTAssertThrowsError(try ISO9660Reader(reader: DataIOReader(data: data))) { err in
            guard case DiscError.notISO9660 = err else { return XCTFail("wrong error: \(err)") }
        }
    }

    func test_directoryNotFound() throws {
        let data = ISO9660Fixture.make(files: [.init(name: "VTS_01_1.VOB", length: 100)])
        let iso = try ISO9660Reader(reader: DataIOReader(data: data))
        XCTAssertThrowsError(try iso.list(directory: "BDMV")) { err in
            guard case DiscError.directoryNotFound = err else { return XCTFail("wrong error: \(err)") }
        }
    }

    func test_truncatedImageThrowsMalformedOrNotISO() throws {
        // A valid-looking ISO whose backing data is cut off before the PVD's
        // referenced root extent must throw, not trap.
        let full = ISO9660Fixture.make(files: [.init(name: "VTS_01_1.VOB", length: 100)])
        let truncated = full.prefix(17 * ISO9660Fixture.sectorSize) // PVD present, root extent cut
        XCTAssertThrowsError(try {
            let iso = try ISO9660Reader(reader: DataIOReader(data: Data(truncated)))
            _ = try iso.list(directory: "VIDEO_TS")
        }())
    }
}
