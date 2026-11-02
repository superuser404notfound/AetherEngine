import Foundation
import Testing
@testable import AetherEngine

/// A DVD-Video served as a `VIDEO_TS` folder (`DiscDirectoryReader`): the same title sets, cell spans
/// and time map as an image, over files instead of sectors.
@Suite("DVD-Video folder sources")
struct DVDFolderTests {
    typealias Folder = BluRayFolderTests.MemoryFolder

    static func bytes(_ seed: UInt8, _ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: Int(seed) &* 41 &+ $0) })
    }

    /// Two title sets; the first one's content is two VOBs. `vts1IFO` stands in for VTS_01_0.IFO; the
    /// default is unreadable, so the title sets come from the VOB names alone.
    static func folder(vts1IFO: [UInt8]? = nil) -> Folder {
        Folder([
            ("VIDEO_TS/VIDEO_TS.IFO", bytes(1, 2048)),
            ("VIDEO_TS/VIDEO_TS.VOB", bytes(2, 2048)),
            ("VIDEO_TS/VTS_01_0.IFO", vts1IFO.map { Data($0) } ?? bytes(3, 2048)),
            ("VIDEO_TS/VTS_01_0.VOB", bytes(4, 2048)),
            ("VIDEO_TS/VTS_01_1.VOB", bytes(5, 7000)),
            ("VIDEO_TS/VTS_01_2.VOB", bytes(6, 4000)),
            ("VIDEO_TS/VTS_02_1.VOB", bytes(7, 3000)),
        ])
    }

    @Test("the main title set's VOBs play back to back in part order, and the other title is selectable")
    func titleSetsFromAFolder() throws {
        let folder = Self.folder()
        let info = try #require(try DiscReader.wrap(folder))
        #expect(info.formatHint == "mpeg")
        #expect(info.titles.map(\.dvdVTSN) == [1, 2])
        #expect(BluRayFolderTests.readToEnd(info.reader) == Self.bytes(5, 7000) + Self.bytes(6, 4000))
        #expect(info.reader.seek(offset: 0, whence: 65536) == 11000)
        // The menu VOBs are never opened, and no Blu-ray path is tried.
        #expect(!folder.openedPaths.contains("VIDEO_TS/VTS_01_0.VOB"))

        let second = try #require(try DiscReader.wrap(Self.folder(), selectTitleID: 1))
        #expect(BluRayFolderTests.readToEnd(second.reader) == Self.bytes(7, 3000))
    }

    @Test("the selected title's cells and time map apply to the folder's concatenated VOBs")
    func cellTimelineFromAFolder() throws {
        let ifo = DVDCellTimelineTests.vtsIFO(pgcs: [DVDCellTimelineTests.pgc(DVDCellTimelineTests.threeCells)],
                                              timeMaps: [(unit: 4, sectors: [10, 20])])
        let info = try #require(try DiscReader.wrap(Self.folder(vts1IFO: ifo)))
        #expect(info.clipTimeline.map(\.concatByteStart) == [0, 1000 * 2048, 3000 * 2048] as [Int64])
        #expect(info.dvdTimeMap?.byteOffsets == [10 * 2048, 20 * 2048] as [Int64])
        #expect(info.titles.first?.durationTicks == UInt64(2100 * discTickRate))
    }

    @Test("a listing with both trees plays its Blu-ray title, and falls back to the DVD when BDMV has none")
    func hybridListing() throws {
        let bluRay = BluRayFolderTests.tinyStreamFolder().folder
        let dvd = Self.folder()
        let both = Folder(bluRay.order.map { ($0, bluRay.files[$0]!) } + dvd.order.map { ($0, dvd.files[$0]!) })
        let info = try #require(try DiscReader.wrap(both))
        #expect(info.formatHint == "mpegts")
        #expect(!both.openedPaths.contains { $0.hasPrefix("VIDEO_TS/") })

        let emptyBDMV = Folder([("BDMV/index.bdmv", Data([0x49, 0x4E, 0x44, 0x58]))]
                               + dvd.order.map { ($0, dvd.files[$0]!) })
        let fallback = try #require(try DiscReader.wrap(emptyBDMV))
        #expect(fallback.formatHint == "mpeg")
        #expect(BluRayFolderTests.readToEnd(fallback.reader) == Self.bytes(5, 7000) + Self.bytes(6, 4000))
    }

    @Test("a VIDEO_TS folder without title VOBs is not a disc")
    func noTitleVOBs() throws {
        let folder = Folder([("VIDEO_TS/VIDEO_TS.IFO", Self.bytes(1, 2048)), ("VIDEO_TS/VIDEO_TS.VOB", Self.bytes(2, 2048))])
        #expect(try DiscReader.wrap(folder) == nil)
    }
}
