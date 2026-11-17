import Foundation
import Testing
@testable import AetherEngine

/// Audit 2026-11-17 NET-201..204: a hostile MPD or init, index and fragment bytes must end an open
/// with an error, never a trap, and its BaseURL must not collect the host's credentials.
@Suite("DASH hostile input")
struct DASHHostileInputTests {

    // MARK: NET-203 box walkers

    @Test("a box whose largesize overflows p + size is refused (NET-203)")
    func childrenLargeSize() {
        let tail = MP4Box.be32(1) + Array("free".utf8) + MP4Box.be64(UInt64(Int.max))
        let bytes = MP4Box.box("free", []) + tail
        #expect(throws: DASHSourceError.self) { try MP4Box.children(bytes, in: 0..<bytes.count) }
    }

    private static func mvhd(version: UInt8 = 0) -> [UInt8] {
        MP4Box.fullBox("mvhd", version: version, flags: 0, payload: [UInt8](repeating: 0, count: 100))
    }

    @Test("an 8-byte mvhd or tkhd that ends the init fails the open instead of indexing past it (NET-203)")
    func shortInitBoxes() {
        let shortMvhd = MP4Box.box("moov", MP4Box.box("mvhd", []))
        #expect(throws: DASHSourceError.self) { _ = try MP4Init(bytes: shortMvhd) }
        let shortTkhd = MP4Box.box("moov", Self.mvhd() + MP4Box.box("trak", MP4Box.box("tkhd", [])))
        #expect(throws: DASHSourceError.self) { _ = try MP4Init(bytes: shortTkhd) }
    }

    @Test("a trak with a cut tkhd, elst or mdhd is returned as it was (NET-203)")
    func shortTrakBoxes() {
        let cutTkhd = MP4Box.box("trak", MP4Box.box("tkhd", []))
        let cutElst = MP4Box.box("trak", MP4Box.box("edts", MP4Box.box("elst", [1])))
        let noElstBody = MP4Box.box("trak", MP4Box.box("edts", MP4Box.box("elst", [])))
        let cutMdhd = MP4Box.box("trak", MP4Box.box("mdia", MP4Box.box("mdhd", [])))
        for bytes in [cutTkhd, cutElst, noElstBody, cutMdhd] {
            let trak = MP4Init.Trak(bytes: bytes, trackID: 1)
            let out = trak.rewritten(trackID: 2, fromMovieTimescale: 1000, toMovieTimescale: 2000, language: "en")
            #expect(out == bytes)
        }
    }

    private static func sidxV1(earliest: UInt64, refs: [(UInt32, UInt32, UInt32)]) -> [UInt8] {
        var payload = MP4Box.be32(1) + MP4Box.be32(1000) + MP4Box.be64(earliest) + MP4Box.be64(0)
        payload += [0, 0] + MP4Box.be16(UInt16(refs.count))
        for (size, duration, sap) in refs { payload += MP4Box.be32(size) + MP4Box.be32(duration) + MP4Box.be32(sap) }
        return MP4Box.fullBox("sidx", version: 1, flags: 0, payload: payload)
    }

    @Test("a sidx clock that overflows UInt64 refuses the index, with and without a SAP delta (NET-203)")
    func sidxClockOverflow() {
        let plain = Self.sidxV1(earliest: .max, refs: [(100, 1, 0)])
        #expect(throws: DASHSourceError.self) { _ = try SegmentIndex(bytes: plain, fileOffset: 0) }
        let withSAP = Self.sidxV1(earliest: .max, refs: [(100, 0, 0x9000_0001)])
        #expect(throws: DASHSourceError.self) { _ = try SegmentIndex(bytes: withSAP, fileOffset: 0) }
    }

    @Test("a sidx whose offsets overflow Int64 refuses the index (NET-203)")
    func sidxOffsetOverflow() {
        let bytes = Self.sidxV1(earliest: 0, refs: [(100, 1, 0)])
        #expect(throws: DASHSourceError.self) { _ = try SegmentIndex(bytes: bytes, fileOffset: .max - 10) }
    }

    @Test("a tfhd base_data_offset near Int64.max stays unpatched while the track ID still moves (NET-203)")
    func tfhdBaseOverflow() {
        let tfhd = MP4Box.fullBox("tfhd", version: 0, flags: 0x01,
                                  payload: MP4Box.be32(7) + MP4Box.be64(UInt64(Int64.max - 1)))
        let moof = MP4Box.box("moof", MP4Box.box("traf", tfhd))
        let patches = DASHFragmentPatcher.moofPatches(moof, idMap: [7: 2], sourceToVirtualDelta: 1234)
        #expect(patches.count == 1)
        #expect(patches.first?.bytes == MP4Box.be32(2))
    }

    @Test("a subsegment box with largesize Int64.max after a first box is served unpatched, not trapped (NET-203)")
    func scanLargeSize() throws {
        var video = [UInt8](DASHFixture.video)
        let layout = try DASHVirtualMP4Tests.layout()
        let piece = try #require(layout.pieces.first { $0.source == 0 })
        let moofSize = Int(MP4Box.u32(video, Int(piece.sourceOffset)))
        let mdat = Int(piece.sourceOffset) + moofSize
        video.replaceSubrange(mdat..<(mdat + 16), with: MP4Box.be32(1) + Array("mdat".utf8) + MP4Box.be64(UInt64(Int64.max)))
        let reader = DASHVirtualMP4Reader(layout: layout, sources: [
            DASHVirtualMP4Tests.ForkableData(Data(video)),
            DASHVirtualMP4Tests.ForkableData(DASHFixture.audio1),
            DASHVirtualMP4Tests.ForkableData(DASHFixture.audio2),
        ])
        #expect(Int64(DASHVirtualMP4Tests.readAll(reader).count) == layout.totalSize)
    }

    // MARK: NET-202 manifest numbers

    @Test("a duration beyond the media ceiling or beyond Double parses as none (NET-202)")
    func hugeDuration() {
        #expect(DASHManifest.parseDuration("PT100000000000000000000S") == nil)
        #expect(DASHManifest.parseDuration("PT" + String(repeating: "9", count: 400) + "S") == nil)
        #expect(DASHManifest.parseDuration("PT3600S") == 3600)
    }

    @Test("a byte range wider than the head bound or ending at Int64.max parses as none (NET-202)")
    func hugeByteRange() {
        #expect(DASHManifest.parseByteRange("1-9223372036854775807") == nil)
        #expect(DASHManifest.parseByteRange("0-67108864") == nil)
        #expect(DASHManifest.parseByteRange("0-67108863") == 0...67_108_863)
    }

    @Test("the virtual layout takes an absurd duration without trapping on mehd (NET-202)")
    func hugeLayoutDuration() throws {
        func source(_ data: Data, _ head: (initialization: ClosedRange<Int64>, index: ClosedRange<Int64>),
                    isVideo: Bool) -> DASHVirtualLayout.Source {
            .init(initialization: [UInt8](data[Int(head.initialization.lowerBound)...Int(head.initialization.upperBound)]),
                  index: [UInt8](data[Int(head.index.lowerBound)...Int(head.index.upperBound)]),
                  indexOffset: head.index.lowerBound, language: nil, isVideo: isVideo)
        }
        for duration in [1e20, Double.infinity, Double.nan] {
            let layout = try DASHVirtualLayout.build(
                sources: [source(DASHFixture.video, DASHFixture.videoHead, isVideo: true)], durationSeconds: duration)
            #expect(layout.totalSize > 0)
        }
    }

    // MARK: NET-204 audio cap

    @Test("a manifest with dozens of audio sets carries the video and the first sixteen (NET-204)")
    func audioCap() throws {
        func audioSet(_ i: Int) -> String {
            """
            <AdaptationSet><ContentComponent contentType="audio"/><Representation id="a\(i)" bandwidth="\(i + 1)" \
            mimeType="audio/mp4"><BaseURL>a\(i).mp4</BaseURL><SegmentBase indexRange="10-20"><Initialization range="0-9"/>\
            </SegmentBase></Representation></AdaptationSet>
            """
        }
        let video = """
            <AdaptationSet><ContentComponent contentType="video"/><Representation id="v" bandwidth="9" \
            mimeType="video/mp4"><BaseURL>v.mp4</BaseURL><SegmentBase indexRange="10-20"><Initialization range="0-9"/>\
            </SegmentBase></Representation></AdaptationSet>
            """
        let mpd = """
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"><Period>\(video)\((0..<40).map(audioSet).joined())</Period></MPD>
            """
        let manifest = try DASHManifest.parse(Data(mpd.utf8), manifestURL: URL(string: "http://127.0.0.1:9/m.mpd")!)
        let selected = try manifest.selectRepresentations()
        #expect(selected.count == 1 + DASHManifest.maxAudioRepresentations)
        #expect(selected.dropFirst().map(\.id) == (0..<DASHManifest.maxAudioRepresentations).map { "a\($0)" })
    }
}

@Suite("DASH hostile origin")
struct DASHHostileOriginTests {

    private static func manifest(video: String, audio1: String, audio2: String,
                                 videoIndex: String = "896-999") -> String {
        DASHFixture.manifest(videoURL: video, audio1URL: audio1, audio2URL: audio2)
            .replacingOccurrences(of: "896-999", with: videoIndex)
    }

    @Test("credential headers reach the manifest's origin and never another one (NET-201)",
          .timeLimit(.minutes(3)))
    func crossOriginBaseURL() throws {
        let home = try #require(RangeFilesOrigin())
        let other = try #require(RangeFilesOrigin())
        defer { home.stop(); other.stop() }
        home.serve("/play", Data(Self.manifest(video: "\(other.baseURL)/v.mp4", audio1: "a1.mp4",
                                               audio2: "a2.mp4").utf8),
                   contentType: "application/dash+xml")
        home.serve("/a1.mp4", DASHFixture.audio1)
        home.serve("/a2.mp4", DASHFixture.audio2)
        other.serve("/v.mp4", DASHFixture.video)
        let headers = ["X-Emby-Token": "secret", "Cookie": "sid=1", "Authorization": "Bearer t", "X-Session": "s1"]
        let demuxer = Demuxer()
        try demuxer.open(url: URL(string: "\(home.baseURL)/play")!, extraHeaders: headers)
        defer { demuxer.close() }

        let foreign = other.requests
        #expect(!foreign.isEmpty)
        for request in foreign {
            #expect(request.headers["x-emby-token"] == nil)
            #expect(request.headers["cookie"] == nil)
            #expect(request.headers["authorization"] == nil)
            #expect(request.headers["x-session"] == "s1")
        }
        let own = home.requests
        #expect(Set(own.map(\.path)) == ["/play", "/a1.mp4", "/a2.mp4"])
        #expect(own.allSatisfy { $0.headers["x-emby-token"] == "secret" && $0.headers["cookie"] == "sid=1" })
    }

    @Test("a manifest over the byte bound is refused as too large (NET-204)", .timeLimit(.minutes(3)))
    func oversizedManifest() throws {
        let origin = try #require(RangeFilesOrigin())
        defer { origin.stop() }
        let body = Data("<MPD>".utf8) + Data(repeating: 0x20, count: DASHSourceOpener.manifestByteLimit + 1024)
        origin.serve("/big.mpd", body, contentType: "application/dash+xml")
        let opener = DASHSourceOpener(manifestURL: URL(string: "\(origin.baseURL)/big.mpd")!, headers: [:])
        #expect(throws: DASHSourceError.manifestTooLarge(DASHSourceOpener.manifestByteLimit)) { _ = try opener.open() }
    }

    @Test("an indexRange that ends at Int64.max fails the open without a trap (NET-202)",
          .timeLimit(.minutes(3)))
    func hugeRangeInManifest() throws {
        let origin = try #require(RangeFilesOrigin())
        defer { origin.stop() }
        origin.serve("/play", Data(Self.manifest(video: "v.mp4", audio1: "a1.mp4", audio2: "a2.mp4",
                                                 videoIndex: "896-9223372036854775807").utf8))
        origin.serve("/v.mp4", DASHFixture.video)
        origin.serve("/a1.mp4", DASHFixture.audio1)
        origin.serve("/a2.mp4", DASHFixture.audio2)
        let opener = DASHSourceOpener(manifestURL: URL(string: "\(origin.baseURL)/play")!, headers: [:])
        #expect(throws: DASHSourceError.self) { _ = try opener.open() }
    }

    @Test("a 20-digit presentation duration opens, with the duration taken from the sidx (NET-202)",
          .timeLimit(.minutes(3)))
    func hugeDurationOpens() throws {
        let origin = try #require(RangeFilesOrigin())
        defer { origin.stop() }
        let mpd = DASHFixture.manifest().replacingOccurrences(of: "mediaPresentationDuration=\"PT12S\"", with: "mediaPresentationDuration=\"PT100000000000000000000S\"")
        origin.serve("/play", Data(mpd.utf8))
        origin.serve("/v.mp4", DASHFixture.video)
        origin.serve("/a1.mp4", DASHFixture.audio1)
        origin.serve("/a2.mp4", DASHFixture.audio2)
        let opener = DASHSourceOpener(manifestURL: URL(string: "\(origin.baseURL)/play")!, headers: [:])
        let reader = try opener.open()
        reader.close()
    }
}
