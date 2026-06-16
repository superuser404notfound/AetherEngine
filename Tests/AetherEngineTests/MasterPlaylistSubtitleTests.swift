import XCTest
@testable import AetherEngine

/// Covers the opt-in decoy-subtitle-rendition advertising
/// (`LoadOptions.advertiseSubtitleRenditions`): the master playlist must
/// emit one `#EXT-X-MEDIA:TYPE=SUBTITLES` line per rendition and bind the
/// variant to the group, while staying byte-identical to the pre-feature
/// bare playlist when nothing is advertised.
final class MasterPlaylistSubtitleTests: XCTestCase {

    /// Minimal `HLSSegmentProvider`. Only the non-defaulted protocol
    /// members are implemented; `masterCodecs` and `subtitleRenditions`
    /// are injected per test (everything else uses the extension defaults).
    private final class StubProvider: HLSSegmentProvider {
        let codecs: String?
        let renditions: [(renditionID: String, name: String, language: String)]

        init(codecs: String?,
             renditions: [(renditionID: String, name: String, language: String)]) {
            self.codecs = codecs
            self.renditions = renditions
        }

        func initSegment() -> Data? { nil }
        func mediaSegment(at index: Int) -> Data? { nil }
        var segmentCount: Int { 1 }
        func segmentDuration(at index: Int) -> Double { 4.0 }
        var playlistType: HLSPlaylistType { .vod }

        var masterCodecs: String? { codecs }
        var subtitleRenditions: [(renditionID: String, name: String, language: String)] { renditions }
    }

    func testMasterEmitsSubtitleRenditionsWhenAdvertising() {
        let provider = StubProvider(
            codecs: "hvc1.2.4.L150.90",
            renditions: [
                (renditionID: "sub2", name: "English (SRT)", language: "en"),
                (renditionID: "sub3", name: "Chinese Simplified (PGS)", language: "zh"),
            ]
        )
        let text = HLSLocalServer.buildMasterPlaylistText(provider: provider)

        // One EXT-X-MEDIA SUBTITLES line per rendition, in the "subs" group,
        // each pointing at its decoy media playlist.
        XCTAssertTrue(text.contains(#"#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs","#))
        XCTAssertTrue(text.contains(#"NAME="English (SRT)",LANGUAGE="en""#))
        XCTAssertTrue(text.contains(#"URI="subs_sub2.m3u8""#))
        XCTAssertTrue(text.contains(#"NAME="Chinese Simplified (PGS)",LANGUAGE="zh""#))
        XCTAssertTrue(text.contains(#"URI="subs_sub3.m3u8""#))

        // The variant is bound to the subtitle group, and video CODECS
        // survive (video variant metadata is present).
        XCTAssertTrue(text.contains(#"SUBTITLES="subs""#))
        XCTAssertTrue(text.contains(#"CODECS="hvc1.2.4.L150.90""#))

        // Media renditions precede the STREAM-INF they attach to.
        let mediaIdx = text.range(of: "#EXT-X-MEDIA:TYPE=SUBTITLES")?.lowerBound
        let streamIdx = text.range(of: "#EXT-X-STREAM-INF")?.lowerBound
        XCTAssertNotNil(mediaIdx)
        XCTAssertNotNil(streamIdx)
        if let mediaIdx, let streamIdx {
            XCTAssertLessThan(mediaIdx, streamIdx)
        }
    }

    func testMasterServedForSDRWithSubtitlesOmitsCodecs() {
        // No video variant metadata (masterCodecs nil) but subtitles are
        // advertised: a master is still produced (not the bare playlist),
        // the STREAM-INF omits CODECS, and the subtitle group still attaches.
        let provider = StubProvider(
            codecs: nil,
            renditions: [(renditionID: "sub0", name: "English (SRT)", language: "en")]
        )
        let text = HLSLocalServer.buildMasterPlaylistText(provider: provider)

        XCTAssertNotEqual(text, "#EXTM3U\n")
        XCTAssertTrue(text.contains("#EXT-X-STREAM-INF:"))
        XCTAssertFalse(text.contains("CODECS="))
        XCTAssertTrue(text.contains(#"SUBTITLES="subs""#))
        XCTAssertTrue(text.contains(#"URI="subs_sub0.m3u8""#))
    }

    func testMasterIsBareWhenNotAdvertisingAndNoVideoMetadata() {
        // Feature off + no video variant metadata: byte-identical to the
        // pre-feature bare playlist (no subtitle lines, no STREAM-INF).
        let provider = StubProvider(codecs: nil, renditions: [])
        let text = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        XCTAssertEqual(text, "#EXTM3U\n")
    }

    func testVideoMasterHasNoSubtitleLinesWhenNotAdvertising() {
        // Video variant metadata but feature off: normal master, with no
        // subtitle group lines (proves the lines are gated on the opt-in).
        let provider = StubProvider(codecs: "hvc1.2.4.L150.90", renditions: [])
        let text = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        XCTAssertTrue(text.contains("#EXT-X-STREAM-INF:"))
        XCTAssertFalse(text.contains("EXT-X-MEDIA:TYPE=SUBTITLES"))
        XCTAssertFalse(text.contains("SUBTITLES="))
    }
}
