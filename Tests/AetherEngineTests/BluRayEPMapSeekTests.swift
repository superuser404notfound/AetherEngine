import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// Seeking a Blu-ray title by its clips' EP maps (`CLPIParser`, `DiscSeekTable`) instead of searching
/// by timestamp, which cannot tell apart clips that run their clocks over the same range.
@Suite("Blu-ray EP-map seek", .offCooperativePool)
struct BluRayEPMapSeekTests {

    // MARK: - Fixtures

    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private static func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    /// A CLPI whose EP map holds `streams`, each a PID and its entries. Entries are encoded one coarse
    /// entry per fine entry, so `pts45k` must be a multiple of 256 (the map's own precision).
    static func clpi(_ streams: [(pid: Int, entries: [CLPIEntryPoint])]) -> [UInt8] {
        let cpiOffset = 40
        var tables: [[UInt8]] = []
        for stream in streams {
            var coarse: [UInt8] = []
            var fine: [UInt8] = []
            for (i, entry) in stream.entries.enumerated() {
                let ptsCoarse = Int(entry.pts45k >> 19) << 1
                coarse += be32((i << 14) | ptsCoarse)
                coarse += be32(Int(entry.spn) & ~0x1FFFF)
                let ptsFine = Int(entry.pts45k >> 8) & 0x7FF
                fine += be32((ptsFine << 17) | (Int(entry.spn) & 0x1FFFF))
            }
            tables.append(be32(4 + coarse.count) + coarse + fine)
        }
        // The EP map: reserved, stream count, 12 bytes per stream, then the stream tables.
        var epMap: [UInt8] = [0, UInt8(streams.count)]
        var start = 2 + 12 * streams.count
        for (stream, table) in zip(streams, tables) {
            let packed = (UInt64(stream.entries.count) << 34) | (UInt64(stream.entries.count) << 16)
                | (UInt64(start) >> 16)
            epMap += be16(stream.pid)
            epMap += be32(Int(packed >> 32)) + be32(Int(packed & 0xFFFF_FFFF))
            epMap += be16(start & 0xFFFF)
            start += table.count
        }
        epMap += tables.flatMap { $0 }
        let cpi = be32(2 + epMap.count) + [0x00, 0x01] + epMap
        var out: [UInt8] = Array("HDMV0200".utf8)
        out += be32(0); out += be32(0); out += be32(cpiOffset); out += be32(0); out += be32(0)
        out += [UInt8](repeating: 0, count: cpiOffset - out.count)
        return out + cpi
    }

    static func mpls(_ clips: [(id: String, inT: Int, outT: Int)]) -> [UInt8] {
        var items: [UInt8] = []
        for clip in clips {
            var body: [UInt8] = []
            body += Array(clip.id.utf8); body += Array("M2TS".utf8); body += be16(0); body.append(0)
            body += be32(clip.inT); body += be32(clip.outT); body += [UInt8](repeating: 0, count: 8)
            items += be16(body.count); items += body
        }
        var playlist: [UInt8] = []
        playlist += be32(0); playlist += be16(0); playlist += be16(clips.count); playlist += be16(0)
        playlist += items
        var out: [UInt8] = Array("MPLS0200".utf8)
        out += be32(40); out += be32(0)
        out += [UInt8](repeating: 0, count: 40 - out.count)
        return out + playlist
    }

    /// The tiny 8 s transport stream as an `.m2ts`: every 188-byte packet behind a 4-byte header, so the
    /// source packet number of packet `n` is `n`.
    static var tinyM2TS: [UInt8] {
        let ts = [UInt8](TinyTransportStreamFixture.data)
        return stride(from: 0, to: ts.count, by: 188).flatMap { [0, 0, 0, 0] + ts[$0..<$0 + 188] }
    }

    /// The stream's video keyframes: one per second from 1.4 s, at these packets (read off the fixture).
    static let keyframes: [(seconds: Double, packet: UInt32)] = [
        (1.4, 3), (2.4, 10), (3.4, 14), (4.4, 18), (5.4, 22), (6.4, 26), (7.4, 30), (8.4, 34),
    ]

    /// The EP map for those keyframes, at the map's 256-tick precision.
    static var tinyEntries: [CLPIEntryPoint] {
        keyframes.map { CLPIEntryPoint(pts45k: UInt64($0.seconds * 45000) / 256 * 256, spn: $0.packet) }
    }

    // MARK: - CLPI

    @Test("the EP map's coarse and fine entries combine into each keyframe's time and packet")
    func parsesEntryPoints() {
        let entries = [CLPIEntryPoint(pts45k: 63_232, spn: 3),
                       CLPIEntryPoint(pts45k: 900_096, spn: 131_075),  // past the fine field's 17 bits
                       CLPIEntryPoint(pts45k: 27_000_064, spn: 2_000_000)]
        #expect(CLPIParser.entryPoints(Self.clpi([(pid: 0x1011, entries: entries)])) == entries)
    }

    @Test("the primary video PID's map wins over another stream's")
    func primaryVideoMapWins() {
        let base = [CLPIEntryPoint(pts45k: 45_056, spn: 10)]
        let enhancement = [CLPIEntryPoint(pts45k: 45_056, spn: 99)]
        #expect(CLPIParser.entryPoints(Self.clpi([(pid: 0x1015, entries: enhancement),
                                                   (pid: 0x1011, entries: base)])) == base)
    }

    @Test("a file that is not a readable CLPI has no entry points")
    func malformedCLPI() {
        let good = Self.clpi([(pid: 0x1011, entries: Self.tinyEntries)])
        #expect(CLPIParser.entryPoints([]).isEmpty)
        #expect(CLPIParser.entryPoints(Array("MPLS0200".utf8) + good.dropFirst(8)).isEmpty)
        #expect(CLPIParser.entryPoints(Array(good.prefix(good.count - 5))).isEmpty)
        #expect(CLPIParser.entryPoints(Self.clpi([])).isEmpty)
    }

    // MARK: - The table

    /// Two clips that both run their clock from 11.6 s, 6149.6 s and 388 s long: the shape of a real
    /// two-clip UHD title a timestamp seek could not land in.
    static let overlappingClips = DiscSeekTable(clips: [
        .init(concatByteStart: 0, cumulativeBeforeSec: 0, inTimeSec: 11.6,
              entries: (0..<6150).map { CLPIEntryPoint(pts45k: UInt64((11.6 + Double($0)) * 45000), spn: UInt32($0 * 1000)) }),
        .init(concatByteStart: 50_000_000_000, cumulativeBeforeSec: 6149.6, inTimeSec: 11.6,
              entries: (0..<388).map { CLPIEntryPoint(pts45k: UInt64((11.6 + Double($0)) * 45000), spn: UInt32($0 * 1000)) }),
    ])

    @Test("folded title time picks the clip, and the clip's own clock picks the keyframe")
    func keyframeLookupAcrossOverlappingClips() throws {
        let table = Self.overlappingClips
        let inFirst = try #require(table.keyframe(forSourceSeconds: 11.6 + 3000.5, base0Sec: 11.6))
        #expect(inFirst.clip == 0)
        #expect(abs(inFirst.keyframeSec - (11.6 + 3000)) < 0.001)
        #expect(inFirst.offset == 3000 * 1000 * 192)

        let inSecond = try #require(table.keyframe(forSourceSeconds: 11.6 + 6149.6 + 100.2, base0Sec: 11.6))
        #expect(inSecond.clip == 1)
        #expect(abs(inSecond.keyframeSec - (11.6 + 100)) < 0.001)
        #expect(inSecond.offset == 50_000_000_000 + 100 * 1000 * 192)
    }

    @Test("before clip 0's base is read, its in_time stands in for it")
    func inTimeStandsInForAnUnreadBase() throws {
        let hit = try #require(Self.overlappingClips.keyframe(forSourceSeconds: 11.6 + 42.5, base0Sec: .nan))
        #expect(hit.clip == 0)
        #expect(abs(hit.keyframeSec - (11.6 + 42)) < 0.001)
    }

    @Test("a target before the first keyframe lands on the first one")
    func targetBeforeFirstKeyframe() throws {
        let hit = try #require(Self.overlappingClips.keyframe(forSourceSeconds: 0, base0Sec: 11.6))
        #expect(hit.clip == 0)
        #expect(hit.offset == 0)
    }

    @Test("a table is built only when every clip has a map, and reads a repeated clip once")
    func buildingTheTable() {
        let title = DiscTitle(id: 0, durationTicks: 2 * 360_000, bdClipIDs: ["00001", "00002", "00001"],
                              bdClipCumulativeBeforeTicks: [0, 360_000, 720_000],
                              bdClipInTimes: [63_000, 63_000, 63_000])
        let resolved: [(item: Int, clip: String, byteStart: Int64)] = [(0, "00001", 0), (1, "00002", 6912), (2, "00001", 13824)]
        let map = Self.clpi([(pid: 0x1011, entries: Self.tinyEntries)])
        var reads: [String] = []
        let table = DiscReader.buildSeekTable(title: title, resolved: resolved) { clip in
            reads.append(clip)
            return map
        }
        #expect(table?.clips.map(\.concatByteStart) == [0, 6912, 13824])
        #expect(table?.clips.map(\.cumulativeBeforeSec) == [0, 8, 16])
        #expect(reads == ["00001", "00002"])

        let partial = DiscReader.buildSeekTable(title: title, resolved: resolved) { $0 == "00002" ? nil : map }
        #expect(partial == nil)
        let noInTimes = DiscTitle(id: 0, durationTicks: 1, bdClipIDs: ["00001"])
        #expect(DiscReader.buildSeekTable(title: noInTimes, resolved: [(0, "00001", 0)]) { _ in map } == nil)
    }

    // MARK: - Through the demuxer

    static func image() -> Data {
        UDFFixture.make(mplsBytes: mpls([(id: "00001", inT: 63_000, outT: 63_000 + 8 * 45_000)]),
                        m2tsBytes: tinyM2TS,
                        clpiBytes: clpi([(pid: 0x1011, entries: tinyEntries)]))
    }

    @Test("recognizing an image reads its clips' CLPI into the title's seek table")
    func recognitionBuildsTheTable() throws {
        let info = try #require(try DiscReader.wrap(DataIOReader(data: Self.image())))
        let table = try #require(info.seekTable)
        #expect(table.clips.count == 1)
        #expect(table.clips[0].entries == Self.tinyEntries)
        #expect(table.clips[0].inTimeSec == 1.4)
    }

    @Test("an image without CLIPINF has no table, and seeks as before")
    func noCLIPINFNoTable() throws {
        let image = UDFFixture.make(mplsBytes: Self.mpls([(id: "00001", inT: 63_000, outT: 423_000)]),
                                    m2tsBytes: Self.tinyM2TS)
        #expect(try DiscReader.wrap(DataIOReader(data: image))?.seekTable == nil)
    }

    static func folder(withCLPI: Bool) -> BluRayFolderTests.MemoryFolder {
        var files: [(String, Data)] = [
            ("BDMV/index.bdmv", Data([0x49, 0x4E, 0x44, 0x58])),
            ("BDMV/PLAYLIST/00800.mpls", Data(mpls([(id: "00001", inT: 63_000, outT: 63_000 + 8 * 45_000)]))),
            ("BDMV/STREAM/00001.m2ts", Data(tinyM2TS)),
        ]
        if withCLPI { files.append(("BDMV/CLIPINF/00001.clpi", Data(clpi([(pid: 0x1011, entries: tinyEntries)])))) }
        return BluRayFolderTests.MemoryFolder(files)
    }

    @Test("a Blu-ray folder reads its clips' CLPI into the seek table too")
    func folderBuildsTheTable() throws {
        let info = try #require(DiscReader.wrapBluRayFolder(Self.folder(withCLPI: true), selectTitleID: nil))
        let table = try #require(info.seekTable)
        #expect(table.clips.map(\.entries) == [Self.tinyEntries])
        #expect(DiscReader.wrapBluRayFolder(Self.folder(withCLPI: false), selectTitleID: nil)?.seekTable == nil)
    }

    @Test("a seek goes to the keyframe's byte, and the first picture read is that keyframe", arguments: [
        (target: 5.0, keyframe: 4.4), (target: 2.4, keyframe: 2.4), (target: 8.9, keyframe: 8.4), (target: 1.0, keyframe: 1.4),
    ])
    func seekLandsOnTheKeyframe(target: Double, keyframe: Double) throws {
        let capture = EngineLogCapture()
        defer { capture.end() }
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: Self.image()))
        defer { demuxer.close() }
        let video = demuxer.videoStreamIndex
        #expect(demuxer.seekBounded(to: target, timeout: 5))
        var first: Double?
        while first == nil, let packet = try demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            guard packet.pointee.stream_index == video, packet.pointee.pts != Int64.min else { continue }
            first = Double(packet.pointee.pts) / 90000
        }
        let landed = try #require(first)
        #expect(abs(landed - keyframe) < 0.01)
        #expect(!capture.matching(String(format: "EP map seek: source=%.3fs", target)).isEmpty)
    }

    // DMX-R206: the stream-timestamp entry point used to skip the EP map.
    @Test("the stream-timestamp seek goes by the EP map too", .timeLimit(.minutes(3)))
    func streamTimestampSeekUsesTheEPMap() throws {
        let capture = EngineLogCapture()
        defer { capture.end() }
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: Self.image()))
        defer { demuxer.close() }
        let video = demuxer.videoStreamIndex
        #expect(demuxer.seek(to: Int64(5.0 * 90000), streamIndex: video))
        var first: Double?
        while first == nil, let packet = try demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            guard packet.pointee.stream_index == video, packet.pointee.pts != Int64.min else { continue }
            first = Double(packet.pointee.pts) / 90000
        }
        #expect(abs(try #require(first) - 4.4) < 0.01)
        #expect(!capture.matching("EP map seek: source=5.000s").isEmpty)
    }
}
