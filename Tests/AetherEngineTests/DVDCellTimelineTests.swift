import Foundation
import Testing
@testable import AetherEngine

/// A DVD title folded by cell (each cell's timestamp base read from its navigation packs) and sought by
/// its VTS time map: the IFO tables, the spans and map recognition builds from them, and the PCI read.
@Suite("DVD cell timeline and time map")
struct DVDCellTimelineTests {

    // MARK: - IFO fixture

    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private static func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }
    /// dvd_time_t at 29.97 fps: BCD hours, minutes, seconds, then the frame-rate code and BCD frames.
    private static func dvdTime(_ seconds: Int) -> [UInt8] {
        func bcd(_ v: Int) -> UInt8 { UInt8(((v / 10) << 4) | (v % 10)) }
        return [bcd(seconds / 3600), bcd((seconds % 3600) / 60), bcd(seconds % 60), 0xC0]
    }

    struct CellSpec {
        var seconds: Int
        var first: Int
        var last: Int
        var angleBlock = false
    }

    /// A PGC whose cell playback table holds `cells`, one program per cell.
    static func pgc(_ cells: [CellSpec]) -> [UInt8] {
        var pgc = [UInt8](repeating: 0, count: 0xEC)
        pgc[2] = UInt8(cells.count)
        pgc[3] = UInt8(cells.count)
        let total = dvdTime(cells.reduce(0) { $0 + $1.seconds })
        pgc[4..<8] = ArraySlice(total)
        let programMap = 0xEC
        let cellTable = programMap + cells.count
        pgc[0xE6..<0xE8] = ArraySlice(be16(programMap))
        pgc[0xE8..<0xEA] = ArraySlice(be16(cellTable))
        pgc += (1...cells.count).map { UInt8($0) }
        for cell in cells {
            var entry = [UInt8](repeating: 0, count: 24)
            if cell.angleBlock { entry[0] = 0x50 }  // block mode 1 (first cell), block type 1 (angle)
            entry[4..<8] = ArraySlice(dvdTime(cell.seconds))
            entry[8..<12] = ArraySlice(be32(cell.first))
            entry[20..<24] = ArraySlice(be32(cell.last))
            pgc += entry
        }
        return pgc
    }

    /// A VTS IFO with `pgcs` in its VTS_PGCIT (sector 1) and, when given, a VTS_TMAPT (sector 2) holding
    /// one time map per PGC: (unit seconds, sectors).
    static func vtsIFO(pgcs: [[UInt8]], timeMaps: [(unit: Int, sectors: [Int])]? = nil) -> [UInt8] {
        let headerSize = 8 + pgcs.count * 8
        var srps: [UInt8] = []
        var body: [UInt8] = []
        for pgc in pgcs {
            srps += [0x81, 0, 0, 0] + be32(headerSize + body.count)
            body += pgc
        }
        var ifo: [UInt8] = Array("DVDVIDEO-VTS".utf8)
        ifo += [UInt8](repeating: 0, count: 0xCC - ifo.count)
        ifo += be32(1)                                    // VTS_PGCIT at sector 1
        ifo += [UInt8](repeating: 0, count: 0xD4 - ifo.count)
        ifo += be32(timeMaps == nil ? 0 : 2)              // VTS_TMAPT at sector 2
        ifo += [UInt8](repeating: 0, count: 2048 - ifo.count)
        ifo += be16(pgcs.count) + be16(0) + be32(headerSize + body.count - 1) + srps + body
        guard let timeMaps else { return ifo }
        ifo += [UInt8](repeating: 0, count: 2 * 2048 - ifo.count)
        var tables: [[UInt8]] = []
        for map in timeMaps {
            tables.append([UInt8(map.unit), 0] + be16(map.sectors.count) + map.sectors.flatMap { be32($0) })
        }
        let header = 8 + 4 * timeMaps.count
        var offsets: [UInt8] = []
        var at = header
        for table in tables { offsets += be32(at); at += table.count }
        ifo += be16(timeMaps.count) + be16(0) + be32(at - 1) + offsets + tables.flatMap { $0 }
        return ifo
    }

    static let threeCells = [CellSpec(seconds: 600, first: 0, last: 999),
                             CellSpec(seconds: 1200, first: 1000, last: 2999),
                             CellSpec(seconds: 300, first: 3000, last: 3499)]

    // MARK: - IFO tables

    @Test("the main PGC's cells come out in playback order with their sectors and times")
    func parsesCells() throws {
        let ifo = Self.vtsIFO(pgcs: [Self.pgc(Self.threeCells)])
        let cells = try #require(DVDIFOParser.parseMainPGCCells(ifo))
        #expect(cells.map(\.firstSector) == [0, 1000, 3000])
        #expect(cells.map(\.lastSector) == [999, 2999, 3499])
        #expect(cells.map(\.durationSec) == [600, 1200, 300])
        #expect(cells.allSatisfy { !$0.inAngleBlock })
    }

    @Test("the time map is the one at the main PGC's own index")
    func timeMapFollowsTheMainPGC() throws {
        // The longer second PGC is the main one, so the second map is its own.
        let short = Self.pgc([CellSpec(seconds: 30, first: 0, last: 9)])
        let ifo = Self.vtsIFO(pgcs: [short, Self.pgc(Self.threeCells)],
                              timeMaps: [(unit: 1, sectors: [5, 9]), (unit: 4, sectors: [100, 200, 300])])
        let map = try #require(DVDIFOParser.parseMainTimeMap(ifo))
        #expect(map.unitSec == 4)
        #expect(map.sectors == [100, 200, 300])
        #expect(DVDIFOParser.parseMainTimeMap(Self.vtsIFO(pgcs: [Self.pgc(Self.threeCells)])) == nil)
    }

    @Test("a discontinuity flag in a time map entry is not part of its sector")
    func timeMapDiscontinuityFlag() throws {
        let ifo = Self.vtsIFO(pgcs: [Self.pgc(Self.threeCells)], timeMaps: [(unit: 4, sectors: [100, 0x8000_00C8])])
        #expect(DVDIFOParser.parseMainTimeMap(ifo)?.sectors == [100, 200])
    }

    // MARK: - Spans and map

    @Test("contiguous cells become clip spans on the title timeline, and the map turns into bytes")
    func cellTimeline() throws {
        let ifo = Self.vtsIFO(pgcs: [Self.pgc(Self.threeCells)], timeMaps: [(unit: 4, sectors: [10, 20, 30])])
        let (spans, map) = DiscReader.dvdCellTimeline(ifo)
        #expect(spans.map(\.concatByteStart) == [0, 1000 * 2048, 3000 * 2048] as [Int64])
        #expect(spans.map(\.cumulativeBeforeSec) == [0, 600, 1800] as [Double])
        #expect(spans.map(\.predictedShiftSec) == [0, -600, -1800] as [Double])
        #expect(map == DVDTimeMap(unitSec: 4, titleStartByte: 0, byteOffsets: [10 * 2048, 20 * 2048, 30 * 2048] as [Int64]))
    }

    @Test("a title outside the common shape is left as it was read", arguments: [
        [CellSpec(seconds: 600, first: 0, last: 999)],                                                  // one cell
        [CellSpec(seconds: 600, first: 50, last: 999), CellSpec(seconds: 60, first: 1000, last: 1099)], // late start
        [CellSpec(seconds: 600, first: 0, last: 999), CellSpec(seconds: 60, first: 1200, last: 1299)],  // a gap
        [CellSpec(seconds: 600, first: 0, last: 999), CellSpec(seconds: 60, first: 1000, last: 1099, angleBlock: true)],
    ])
    func uncommonShapes(cells: [CellSpec]) {
        let (spans, map) = DiscReader.dvdCellTimeline(Self.vtsIFO(pgcs: [Self.pgc(cells)], timeMaps: [(unit: 4, sectors: [1])]))
        #expect(spans.isEmpty)
        #expect(map == nil)
    }

    @Test("a time map seek lands on the VOBU at or before the title time")
    func timeMapLookup() {
        let map = DVDTimeMap(unitSec: 4, titleStartByte: 0, byteOffsets: [100, 200, 300])
        #expect(map.byteOffset(forTitleSeconds: 0) == 0)
        #expect(map.byteOffset(forTitleSeconds: 3.9) == 0)
        #expect(map.byteOffset(forTitleSeconds: 4) == 100)
        #expect(map.byteOffset(forTitleSeconds: 9.5) == 200)
        #expect(map.byteOffset(forTitleSeconds: 500) == 300)
        #expect(map.byteOffset(forTitleSeconds: -1) == 0)
    }

    // MARK: - Navigation pack

    /// A PCI as libavformat hands it over: the substream byte 0x00, then PCI_GI with the VOBU start PTS at
    /// 0x0C and the cell elapsed time at 0x18 (one further in for the substream byte).
    static func pci(startPTS: UInt32, elapsed: [UInt8]) -> [UInt8] {
        var pci = [UInt8](repeating: 0, count: 980)
        pci[0x0D..<0x11] = ArraySlice(be32(Int(startPTS)))
        pci[0x19..<0x1D] = ArraySlice(elapsed)
        return pci
    }

    @Test("a PCI gives its cell's start: the VOBU's start PTS less the cell's elapsed time")
    func cellBaseFromPCI() throws {
        // 29.97 fps: 1 min 5 s and 15 frames into the cell, at 3700 s of raw PTS.
        let ntsc = Self.pci(startPTS: 3700 * 90000, elapsed: [0x00, 0x01, 0x05, 0xC0 | 0x15])
        let base = try #require(ntsc.withUnsafeBufferPointer { Demuxer.dvdCellBaseSeconds(pci: $0) })
        #expect(abs(base - (3700 - 65 - 15 / (30000.0 / 1001.0))) < 0.0001)

        // 25 fps, 12 frames.
        let pal = Self.pci(startPTS: 90000 * 100, elapsed: [0x00, 0x00, 0x10, 0x40 | 0x12])
        let palBase = try #require(pal.withUnsafeBufferPointer { Demuxer.dvdCellBaseSeconds(pci: $0) })
        #expect(abs(palBase - (100 - 10 - 12.0 / 25)) < 0.0001)

        var dsi = ntsc
        dsi[0] = 0x01
        #expect(dsi.withUnsafeBufferPointer { Demuxer.dvdCellBaseSeconds(pci: $0) } == nil)
        #expect(Array(ntsc.prefix(0x1C)).withUnsafeBufferPointer { Demuxer.dvdCellBaseSeconds(pci: $0) } == nil)
    }
}
