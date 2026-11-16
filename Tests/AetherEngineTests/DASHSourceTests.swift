import Foundation
import AetherLibavcodec
import Testing
@testable import AetherEngine

/// AE#859: remote MPEG-DASH on-demand manifests (SegmentBase), opened as one virtual fragmented MP4.
@Suite("DASH manifests")
struct DASHManifestTests {

    /// The sanitized manifest from the AE#859 report, verbatim apart from whitespace.
    static let reportManifest = """
    <MPD xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="urn:mpeg:dash:schema:mpd:2011" xsi:schemaLocation="urn:mpeg:dash:schema:mpd:2011 DASH-MPD.xsd" type="static" mediaPresentationDuration="PT1450S" minBufferTime="PT1.5S" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011">
    <Period duration="PT1450S" start="PT0S">
    <AdaptationSet>
    <ContentComponent contentType="video"/>
    <Representation id="80_7" bandwidth="975745" codecs="avc1.640032" mimeType="video/mp4" height="1080" width="1920" frameRate="23.973" sar="1:1" startWithSAP="1">
    <BaseURL><![CDATA[https://media.example.invalid/video.m4s]]></BaseURL>
    <SegmentBase indexRange="915-4458">
    <Initialization range="0-914"/>
    </SegmentBase>
    </Representation>
    </AdaptationSet>
    <AdaptationSet>
    <ContentComponent contentType="audio"/>
    <Representation id="30280_" bandwidth="156755" codecs="mp4a.40.2" mimeType="audio/mp4" numChannels="2" sampleRate="44100" startWithSAP="">
    <BaseURL><![CDATA[https://media.example.invalid/audio-156k.m4s]]></BaseURL>
    <SegmentBase indexRange="849-4368">
    <Initialization range="0-848"/>
    </SegmentBase>
    </Representation>
    </AdaptationSet>
    <AdaptationSet>
    <ContentComponent contentType="audio"/>
    <Representation id="30216_" bandwidth="65679" codecs="mp4a.40.2" mimeType="audio/mp4" numChannels="2" sampleRate="44100" startWithSAP="">
    <BaseURL><![CDATA[https://media.example.invalid/audio-65k.m4s]]></BaseURL>
    <SegmentBase indexRange="849-4368">
    <Initialization range="0-848"/>
    </SegmentBase>
    </Representation>
    </AdaptationSet>
    <AdaptationSet>
    <ContentComponent contentType="audio"/>
    <Representation id="30232_" bandwidth="90164" codecs="mp4a.40.2" mimeType="audio/mp4" numChannels="2" sampleRate="44100" startWithSAP="">
    <BaseURL><![CDATA[https://media.example.invalid/audio-90k.m4s]]></BaseURL>
    <SegmentBase indexRange="849-4368">
    <Initialization range="0-848"/>
    </SegmentBase>
    </Representation>
    </AdaptationSet>
    </Period>
    </MPD>
    """

    private static let base = URL(string: "http://127.0.0.1:9/play")!

    private static func parse(_ text: String, url: URL = base) throws -> DASHManifest {
        try DASHManifest.parse(Data(text.utf8), manifestURL: url)
    }

    private static func wrap(_ period: String, attributes: String = #"type="static""#) -> String {
        #"<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" "# + attributes + ">" + period + "</MPD>"
    }

    @Test("the report's manifest selects its video and all three audio adaptation sets")
    func reportManifest() throws {
        let manifest = try Self.parse(Self.reportManifest)
        #expect(manifest.durationSeconds == 1450)
        let selected = try manifest.selectRepresentations()
        #expect(selected.map(\.id) == ["80_7", "30280_", "30216_", "30232_"])
        #expect(selected.map(\.kind) == [.video, .audio, .audio, .audio])
        #expect(selected[0].url.absoluteString == "https://media.example.invalid/video.m4s")
        #expect(selected[0].segmentBase == .init(initialization: 0...914, index: 915...4458))
        #expect(selected[1].segmentBase == .init(initialization: 0...848, index: 849...4368))
        #expect(selected[0].width == 1920 && selected[0].height == 1080)
    }

    @Test("an adaptation set contributes its highest-bandwidth representation only")
    func bitrateAlternatives() throws {
        let manifest = try Self.parse(Self.wrap("""
            <Period><AdaptationSet mimeType="video/mp4">
            <Representation id="low" bandwidth="100"><BaseURL>low.mp4</BaseURL><SegmentBase indexRange="10-20"/></Representation>
            <Representation id="high" bandwidth="900"><BaseURL>high.mp4</BaseURL><SegmentBase indexRange="10-20"/></Representation>
            <Representation id="mid" bandwidth="500"><BaseURL>mid.mp4</BaseURL><SegmentBase indexRange="10-20"/></Representation>
            </AdaptationSet></Period>
            """))
        let selected = try manifest.selectRepresentations()
        #expect(selected.map(\.id) == ["high"])
        // No Initialization element: the initialization segment is everything before the index.
        #expect(selected[0].segmentBase == .init(initialization: 0...9, index: 10...20))
    }

    @Test("BaseURLs resolve level by level against the manifest's own location")
    func baseURLResolution() throws {
        let manifest = try Self.parse(Self.wrap("""
            <BaseURL>https://cdn.example.invalid/root/</BaseURL>
            <Period><BaseURL>p1/</BaseURL>
            <AdaptationSet mimeType="audio/mp4"><BaseURL>../shared/</BaseURL>
            <Representation id="a" bandwidth="1"><BaseURL>a.mp4?token=x</BaseURL><SegmentBase indexRange="10-20"/></Representation>
            </AdaptationSet>
            <AdaptationSet mimeType="video/mp4">
            <Representation id="v" bandwidth="1"><BaseURL>v.mp4</BaseURL><SegmentBase indexRange="10-20"/></Representation>
            </AdaptationSet></Period>
            """))
        let selected = try manifest.selectRepresentations()
        #expect(selected.map(\.url.absoluteString) == [
            "https://cdn.example.invalid/root/p1/v.mp4",
            "https://cdn.example.invalid/root/shared/a.mp4?token=x",
        ])
        let relative = try Self.parse(Self.wrap("""
            <Period><AdaptationSet mimeType="video/mp4">
            <Representation id="v" bandwidth="1"><BaseURL>media/v.mp4</BaseURL><SegmentBase indexRange="10-20"/></Representation>
            </AdaptationSet></Period>
            """), url: URL(string: "https://host.example.invalid/a/b/manifest")!)
        #expect(try relative.selectRepresentations()[0].url.absoluteString
                == "https://host.example.invalid/a/b/media/v.mp4")
    }

    @Test("lang and ContentComponent carry through, and the language reaches the representation")
    func languageAndKind() throws {
        let manifest = try Self.parse(DASHFixture.manifest())
        let selected = try manifest.selectRepresentations()
        #expect(selected.map(\.language) == [nil, "en", "de-DE"])
        #expect(selected.map(\.kind) == [.video, .audio, .audio])
    }

    @Test("refusals name the reason instead of failing as invalid data")
    func refusals() throws {
        let dynamic = try Self.parse(Self.wrap("<Period/>", attributes: #"type="dynamic""#))
        #expect(throws: DASHSourceError.liveManifest) { try dynamic.selectRepresentations() }

        let twoPeriods = try Self.parse(Self.wrap("<Period/><Period/>"))
        #expect(throws: DASHSourceError.periodCount(2)) { try twoPeriods.selectRepresentations() }

        let template = try Self.parse(Self.wrap("""
            <Period><AdaptationSet mimeType="video/mp4"><SegmentTemplate media="$Number$.m4s"/>
            <Representation id="v" bandwidth="1"><BaseURL>v/</BaseURL></Representation>
            </AdaptationSet></Period>
            """))
        #expect(throws: DASHSourceError.noPlayableRepresentation(
            "no video representation is playable: it is addressed by SegmentTemplate")) {
            try template.selectRepresentations()
        }

        let protected = try Self.parse(Self.wrap("""
            <Period><AdaptationSet mimeType="video/mp4"><ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011"/>
            <Representation id="v" bandwidth="1"><BaseURL>v.mp4</BaseURL><SegmentBase indexRange="10-20"/></Representation>
            </AdaptationSet></Period>
            """))
        #expect(throws: DASHSourceError.noPlayableRepresentation(
            "no video representation is playable: it is encrypted (ContentProtection)")) {
            try protected.selectRepresentations()
        }

        #expect(throws: DASHSourceError.notAManifest) {
            _ = try DASHManifest.parse(Data("<html><body/></html>".utf8), manifestURL: Self.base)
        }
    }

    @Test("a representation's own SegmentBase wins over its set's SegmentTemplate")
    func innermostAddressingWins() throws {
        let manifest = try Self.parse(Self.wrap("""
            <Period><AdaptationSet mimeType="audio/mp4"><SegmentTemplate media="$Number$.m4s"/>
            <Representation id="a" bandwidth="1"><BaseURL>a.mp4</BaseURL><SegmentBase indexRange="10-20"/></Representation>
            </AdaptationSet></Period>
            """))
        #expect(try manifest.selectRepresentations().map(\.id) == ["a"])
    }

    @Test("an unplayable audio set is skipped when a video track plays")
    func unplayableAudioIsSkipped() throws {
        let manifest = try Self.parse(Self.wrap("""
            <Period>
            <AdaptationSet mimeType="video/mp4"><Representation id="v" bandwidth="1"><BaseURL>v.mp4</BaseURL><SegmentBase indexRange="10-20"/></Representation></AdaptationSet>
            <AdaptationSet mimeType="audio/mp4"><SegmentList/><Representation id="a" bandwidth="1"><BaseURL>a/</BaseURL></Representation></AdaptationSet>
            <AdaptationSet mimeType="text/vtt"><Representation id="t" bandwidth="1"><BaseURL>t.vtt</BaseURL></Representation></AdaptationSet>
            </Period>
            """))
        #expect(try manifest.selectRepresentations().map(\.id) == ["v"])
    }

    @Test("the body sniff accepts an MPD root in every spelling and nothing else")
    func bodySniff() {
        func sniff(_ s: String) -> Bool { DASHManifest.bodyBeginsWithManifest(Array(s.utf8)) }
        #expect(sniff("<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\">"))
        #expect(sniff("\u{FEFF}\n  <?xml version=\"1.0\"?>\n<!-- generated -->\n<MPD>"))
        #expect(sniff("<mpd:MPD xmlns:mpd=\"urn:mpeg:dash:schema:mpd:2011\">"))
        #expect(!sniff("#EXTM3U\n#EXT-X-VERSION:3"))
        #expect(!sniff("<?xml version=\"1.0\"?><html>"))
        #expect(!sniff("<MPDX>"))
        #expect(!DASHManifest.bodyBeginsWithManifest([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70]))
    }

    @Test("durations and byte ranges parse the way the MPD writes them")
    func scalars() {
        #expect(DASHManifest.parseDuration("PT1450S") == 1450)
        #expect(DASHManifest.parseDuration("PT0H4M0.000S") == 240)
        #expect(DASHManifest.parseDuration("P1DT2H") == 93_600)
        #expect(DASHManifest.parseDuration("PT1.5S") == 1.5)
        #expect(DASHManifest.parseDuration("P1M") == nil)
        #expect(DASHManifest.parseDuration("1450") == nil)
        #expect(DASHManifest.parseByteRange("915-4458") == 915...4458)
        #expect(DASHManifest.parseByteRange("10-5") == nil)
        #expect(DASHManifest.parseByteRange("-5") == nil)
    }
}

@Suite("DASH virtual MP4")
struct DASHVirtualMP4Tests {

    static func layout() throws -> DASHVirtualLayout {
        func source(_ data: Data, _ head: (initialization: ClosedRange<Int64>, index: ClosedRange<Int64>),
                    _ language: String?, isVideo: Bool = false) -> DASHVirtualLayout.Source {
            .init(initialization: [UInt8](data[Int(head.initialization.lowerBound)...Int(head.initialization.upperBound)]),
                  index: [UInt8](data[Int(head.index.lowerBound)...Int(head.index.upperBound)]),
                  indexOffset: head.index.lowerBound, language: language, isVideo: isVideo)
        }
        return try DASHVirtualLayout.build(sources: [
            source(DASHFixture.video, DASHFixture.videoHead, nil, isVideo: true),
            source(DASHFixture.audio1, DASHFixture.audioHead, "en"),
            source(DASHFixture.audio2, DASHFixture.audioHead, "de-DE"),
        ], durationSeconds: 12)
    }

    /// `DataIOReader` with the fork a representation's HTTP reader offers.
    final class ForkableData: IOReader, @unchecked Sendable {
        let data: Data
        private let inner: DataIOReader
        init(_ data: Data) { self.data = data; inner = DataIOReader(data: data) }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { inner.read(buffer, size: size) }
        func seek(offset: Int64, whence: Int32) -> Int64 { inner.seek(offset: offset, whence: whence) }
        func close() {}
        func makeIndependentReader() -> IOReader? { ForkableData(data) }
    }

    static func reader() throws -> DASHVirtualMP4Reader {
        try DASHVirtualMP4Reader(layout: layout(), sources: [
            ForkableData(DASHFixture.video), ForkableData(DASHFixture.audio1), ForkableData(DASHFixture.audio2),
        ])
    }

    static func readAll(_ reader: IOReader, chunk: Int32 = 4096) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: Int(chunk))
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: chunk) }
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<Int(n)])
        }
        return out
    }

    @Test("every subsegment of every file is placed once, interleaved by start time")
    func layoutShape() throws {
        let layout = try Self.layout()
        #expect(layout.pieces.count == 18)
        #expect(layout.pieces.map(\.source).prefix(3) == [0, 1, 2])
        #expect(layout.pieces.map(\.startSeconds) == layout.pieces.map(\.startSeconds).sorted())
        var end = Int64(layout.header.count)
        for piece in layout.pieces {
            #expect(piece.virtualOffset == end)
            end += piece.size
        }
        #expect(end == layout.totalSize)
        #expect(layout.trackIDMaps.map { $0.values.sorted() } == [[1], [2], [3]])
        let sourceBytes = [DASHFixture.video, DASHFixture.audio1, DASHFixture.audio2].map { Int64($0.count) }
        let indexEnds = [DASHFixture.videoHead.index.upperBound, DASHFixture.audioHead.index.upperBound,
                         DASHFixture.audioHead.index.upperBound].map { $0 + 1 }
        let mediaBytes = zip(sourceBytes, indexEnds).map { $0 - $1 }.reduce(0, +)
        #expect(layout.totalSize == Int64(layout.header.count) + mediaBytes)
    }

    @Test("the video sidx declares a SAP at every subsegment, and the audio sets the read-order lead (AE#1075)")
    func declaredRandomAccess() throws {
        let layout = try Self.layout()
        #expect(layout.randomAccessStartsSeconds == [0, 2, 4, 6, 8, 10])
        let audio = [UInt8](DASHFixture.audio1[Int(DASHFixture.audioHead.index.lowerBound)...Int(DASHFixture.audioHead.index.upperBound)])
        let audioIndex = try SegmentIndex(bytes: audio, fileOffset: DASHFixture.audioHead.index.lowerBound)
        let longest = audioIndex.references.map { Double($0.duration) / Double(audioIndex.timescale) }.max()
        #expect(layout.interleaveLeadSeconds == longest)
        #expect(layout.interleaveLeadSeconds > 2)
        // AE#1079: the other direction, a video subsegment read whole before the audio inside it.
        #expect(layout.videoSubsegmentSeconds == 2)
    }

    /// A one-level sidx (version 0, timescale 1000, earliest presentation time 500) with one
    /// reference per entry: (duration in ms, SAP word).
    static func sidx(_ refs: [(UInt32, UInt32)]) -> [UInt8] {
        var payload = MP4Box.be32(1) + MP4Box.be32(1000) + MP4Box.be32(500) + MP4Box.be32(0)
        payload += [0, 0] + MP4Box.be16(UInt16(refs.count))
        for (duration, sap) in refs { payload += MP4Box.be32(100) + MP4Box.be32(duration) + MP4Box.be32(sap) }
        return MP4Box.fullBox("sidx", version: 0, flags: 0, payload: payload)
    }

    @Test("SAP times read starts_with_SAP, the type and the delta; types 3 and up or a missing SAP declare nothing")
    func sapParsing() throws {
        // Type 1, type 2 with a 40 ms delta (leading pictures shown before the IDR), type 1.
        let closed = try SegmentIndex(bytes: Self.sidx([(2000, 0x9000_0000), (2000, 0xA000_0028), (2000, 0x9000_0000)]), fileOffset: 0)
        #expect(closed.references.map(\.sapSeconds) == [0.5, 2.54, 4.5])
        #expect(DASHVirtualLayout.randomAccessStarts(closed).map { ($0 * 1000).rounded() } == [0, 2040, 4000])

        let openGOP = try SegmentIndex(bytes: Self.sidx([(2000, 0x9000_0000), (2000, 0xB000_0000)]), fileOffset: 0)
        #expect(openGOP.references[1].sapSeconds == nil)
        #expect(DASHVirtualLayout.randomAccessStarts(openGOP).isEmpty)

        let noSAP = try SegmentIndex(bytes: Self.sidx([(2000, 0x9000_0000), (2000, 0x1000_0000)]), fileOffset: 0)
        #expect(DASHVirtualLayout.randomAccessStarts(noSAP).isEmpty)
    }

    @Test("libavformat reads the virtual file as three streams with the manifest's languages")
    func demuxes() throws {
        let demuxer = Demuxer()
        try demuxer.open(reader: try Self.reader(), formatHint: "mp4")
        defer { demuxer.close() }
        #expect(demuxer.videoStreamIndex == 0)
        let audio = demuxer.audioTrackInfos()
        #expect(audio.map(\.language) == ["eng", "deu"])
        #expect(audio.map(\.codec) == ["aac", "aac"])
        var counts: [Int32: Int] = [:]
        var last: [Int32: Int64] = [:]
        var monotonic = true
        while let packet = try demuxer.readPacket() {
            let index = packet.pointee.stream_index
            counts[index, default: 0] += 1
            if let previous = last[index], packet.pointee.dts <= previous { monotonic = false }
            last[index] = packet.pointee.dts
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&owned)
        }
        #expect(counts[0] == 48)
        #expect((counts[1] ?? 0) > 90 && counts[1] == counts[2])
        #expect(monotonic)
    }

    @Test("a stream seek lands on the sync sample next to the target, in both directions")
    func seeks() throws {
        let demuxer = Demuxer()
        var profile = DemuxerOpenProfile.playback
        profile.skipStreamInfo = true
        try demuxer.open(reader: try Self.reader(), formatHint: "mp4", profile: profile)
        defer { demuxer.close() }
        let video = demuxer.videoStreamIndex
        let tb = try #require(demuxer.stream(at: video)).pointee.time_base
        func firstVideoSeconds() throws -> Double? {
            while let packet = try demuxer.readPacket() {
                defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&owned) }
                if packet.pointee.stream_index == video {
                    return Double(packet.pointee.pts) * Double(tb.num) / Double(tb.den)
                }
            }
            return nil
        }
        // A time seek lands at or before the target; in a fragmented MP4 libavformat takes the sync
        // sample of the fragment before (an ffmpeg-written fragmented file with a global sidx lands
        // at 8.13 s for the same target, the unfragmented original at 10.0 s).
        #expect(demuxer.seek(to: 10.0))
        let far = try #require(try firstVideoSeconds())
        #expect(far >= 8.0 && far <= 10.0, "landed at \(far) s")
        let target = Int64(5.5 * Double(tb.den) / Double(tb.num))
        #expect(demuxer.seek(to: target, streamIndex: video))
        let back = try #require(try firstVideoSeconds())
        #expect(back >= 4.0 && back <= 6.0, "landed at \(back) s")
    }

    @Test("reads stop at piece boundaries, and a fork serves the same bytes")
    func readerContract() throws {
        let layout = try Self.layout()
        let reader = try Self.reader()
        let whole = Self.readAll(reader, chunk: 1 << 20)
        #expect(Int64(whole.count) == layout.totalSize)
        #expect(reader.seek(offset: 0, whence: 65536) == layout.totalSize)

        let piece = layout.pieces[3]
        #expect(reader.seek(offset: piece.virtualOffset + 1, whence: SEEK_SET) == piece.virtualOffset + 1)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        let n = buffer.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 1 << 20) }
        #expect(Int64(n) == piece.size - 1)

        let fork = try #require(reader.makeIndependentReader())
        #expect(Self.readAll(fork, chunk: 777) == whole)
    }

    @Test("an explicit base_data_offset moves with its moof, and track IDs are renumbered")
    func moofPatches() throws {
        // traf > tfhd with base-data-offset-present (flag 0x01) for track 7 at absolute 5000.
        let tfhd = MP4Box.fullBox("tfhd", version: 0, flags: 0x01,
                                  payload: MP4Box.be32(7) + MP4Box.be64(5000))
        let moof = MP4Box.box("moof", MP4Box.box("traf", tfhd))
        let patches = DASHFragmentPatcher.moofPatches(moof, idMap: [7: 2], sourceToVirtualDelta: 1234)
        var patched = moof
        for p in patches { patched.replaceSubrange(Int(p.offset)..<(Int(p.offset) + p.bytes.count), with: p.bytes) }
        #expect(MP4Box.u32(patched, 8 + 8 + 12) == 2)
        #expect(MP4Box.u64(patched, 8 + 8 + 16) == 6234)
    }

    @Test("manifest languages become ISO 639-2/T, undetermined ones stay unwritten")
    func languages() {
        func letters(_ packed: UInt16?) -> String? {
            packed.map { p in String((0..<3).map { Character(UnicodeScalar(UInt8((p >> (10 - 5 * $0)) & 0x1F) + 0x60)) }) }
        }
        #expect(letters(MP4Init.packedLanguage("en")) == "eng")
        #expect(letters(MP4Init.packedLanguage("de-DE")) == "deu")
        #expect(letters(MP4Init.packedLanguage("fra")) == "fra")
        #expect(MP4Init.packedLanguage("und") == nil)
        #expect(MP4Init.packedLanguage("") == nil)
    }
}

@Suite("DASH over HTTP")
struct DASHOverHTTPTests {

    private static func origin(manifestPath: String = "/play") throws -> RangeFilesOrigin {
        let origin = try #require(RangeFilesOrigin())
        origin.serve(manifestPath, Data(DASHFixture.manifest(videoURL: "\(origin.baseURL)/media/v.mp4").utf8),
                     contentType: "application/dash+xml; charset=utf-8")
        origin.serve("/a1.mp4", DASHFixture.audio1)
        origin.serve("/a2.mp4", DASHFixture.audio2)
        origin.serve("/media/v.mp4", DASHFixture.video)
        return origin
    }

    @Test("an extensionless manifest URL opens as DASH, with the headers on every request")
    func extensionlessManifest() throws {
        let origin = try Self.origin()
        defer { origin.stop() }
        let demuxer = Demuxer()
        let url = URL(string: "\(origin.baseURL)/play")!
        try demuxer.open(url: url, extraHeaders: ["X-Session": "s1"])
        defer { demuxer.close() }
        // Its readers fixed their headers at open, so a header update must not promise live requests.
        #expect(DASHSourceOpener.isKnownManifest(url))
        #expect(demuxer.videoStreamIndex >= 0)
        #expect(demuxer.audioTrackInfos().map(\.language) == ["eng", "deu"])
        let requests = origin.requests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0.headers["x-session"] == "s1" })
        #expect(Set(requests.map(\.path)) == ["/play", "/media/v.mp4", "/a1.mp4", "/a2.mp4"])
    }

    @Test("a .mpd URL goes straight to the DASH opener: one manifest request")
    func mpdExtension() throws {
        let origin = try Self.origin(manifestPath: "/movie.mpd")
        defer { origin.stop() }
        let demuxer = Demuxer()
        try demuxer.open(url: URL(string: "\(origin.baseURL)/movie.mpd")!)
        defer { demuxer.close() }
        #expect(demuxer.audioTrackInfos().count == 2)
        #expect(origin.requests(to: "/movie.mpd").count == 1)
    }

    @Test("a DASH source skips the cue prewarm, the same file served as plain MP4 keeps it (AE#1075)")
    func dashSkipsCuePrewarm() throws {
        let origin = try Self.origin(manifestPath: "/movie.mpd")
        defer { origin.stop() }

        let dash = Demuxer()
        try dash.open(url: URL(string: "\(origin.baseURL)/movie.mpd")!)
        defer { dash.close() }
        #expect(dash.isDASHSource)
        #expect(dash.isSourceSeekable && dash.timeSeekableReader == nil)
        #expect(!HLSVideoEngine.cuePrewarmMayRun(hasSegmentedReader: false,
                                                 isSourceSeekable: dash.isSourceSeekable,
                                                 isDASHSource: dash.isDASHSource))

        // Same container format name, so the flag must come from the open path, not from "mp4".
        let plain = Demuxer()
        try plain.open(url: URL(string: "\(origin.baseURL)/media/v.mp4")!)
        defer { plain.close() }
        #expect(dash.dashRandomAccessStartsSeconds == [0, 2, 4, 6, 8, 10])
        #expect(dash.dashInterleaveLeadSeconds > 2)
        #expect(!plain.isDASHSource)
        #expect(plain.dashRandomAccessStartsSeconds.isEmpty)
        #expect(HLSVideoEngine.cuePrewarmMayRun(hasSegmentedReader: false,
                                                isSourceSeekable: plain.isSourceSeekable,
                                                isDASHSource: plain.isDASHSource))
    }

    @Test("an origin that ignores Range is refused with that reason")
    func rangeIgnoringOrigin() throws {
        let origin = try Self.origin()
        defer { origin.stop() }
        origin.ignoresRange = true
        let demuxer = Demuxer()
        defer { demuxer.close() }
        do {
            try demuxer.open(url: URL(string: "\(origin.baseURL)/play")!)
            Issue.record("the open succeeded")
        } catch let error as DASHSourceError {
            #expect(error.description.contains("ignores Range"))
        }
    }

    /// The open runs on its own thread, not in a `Task`: on a CI runner with few cores the parallel
    /// synchronous tests hold every cooperative thread, and a detached task then did not start for
    /// 14 s, past a deadline counted from the test's start. Elapsed time is counted from the close.
    @Test("markClosed ends an open that waits on a representation, instead of its request timeout")
    func closeDuringOpen() throws {
        let origin = try Self.origin()
        defer { origin.stop() }
        origin.stall("/a2.mp4")
        let demuxer = Demuxer()
        defer { demuxer.close() }
        let url = URL(string: "\(origin.baseURL)/play")!
        let finished = DispatchSemaphore(value: 0)
        let failed = ProbeTestBox(false)
        Thread.detachNewThread {
            do { try demuxer.open(url: url) } catch { failed.update { $0 = true } }
            finished.signal()
        }
        let waitStarted = Date()
        while !origin.requests.contains(where: { $0.path == "/a2.mp4" }) {
            usleep(10_000)
            if Date().timeIntervalSince(waitStarted) > 60 { Issue.record("the stalled request never arrived"); return }
        }
        let closed = Date()
        demuxer.markClosed()
        // The opener's request timeout is 10 s; anything well under it was ended by the close.
        #expect(finished.wait(timeout: .now() + 8) == .success, "the open waited out its request timeout")
        #expect(failed.value)
        #expect(Date().timeIntervalSince(closed) < 8)
    }

    @Test("the metadata probe reads a DASH source, with and without limits")
    func probe() throws {
        let origin = try Self.origin()
        defer { origin.stop() }
        let url = URL(string: "\(origin.baseURL)/play")!
        let plain = try AetherEngine.probe(url: url)
        #expect(plain.videoCodecName == "h264")
        #expect(abs(plain.durationSeconds - 12) < 0.5)
        let limited = try AetherEngine.probe(url: url, limits: ProbeLimits())
        #expect(limited.videoCodecName == "h264")
    }
}
