import Testing
import Foundation
@testable import AetherEngine

private final class MasterMockProvider: HLSSegmentProvider, @unchecked Sendable {
    let renditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)]
    init(renditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)]) { self.renditions = renditions }
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { 1 }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { "hvc1.1.6.L120.90,mp4a.40.2" }
    var masterVideoRange: HLSVideoRange? { .sdr }
    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] { renditions }
}

/// VOD provider with a fixed segment count + per-segment cue windows for the windowed subtitle playlist.
private final class WindowedSubsProvider: HLSSegmentProvider, @unchecked Sendable {
    let segCount: Int
    let segDuration: Double
    /// cues[segmentIndex] -> overlapping cues for that segment.
    let cues: [Int: [(start: Double, end: Double, text: String)]]
    init(segCount: Int, segDuration: Double = 4.0,
         cues: [Int: [(start: Double, end: Double, text: String)]] = [:]) {
        self.segCount = segCount
        self.segDuration = segDuration
        self.cues = cues
    }
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { segCount }
    func segmentDuration(at index: Int) -> Double { segDuration }
    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { "hvc1.1.6.L120.90,mp4a.40.2" }
    var masterVideoRange: HLSVideoRange? { .sdr }
    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] { [(0, "eng", "English", false)] }
    func nativeSubtitleVTT(ordinal: Int, segmentIndex: Int) -> String? {
        guard ordinal == 0, segmentIndex >= 0, segmentIndex < segCount else { return nil }
        let start = Double(segmentIndex) * segDuration
        return WebVTTBuilder.segment(cues: cues[segmentIndex] ?? [], segmentStart: start)
    }
}

struct SubtitleRenditionPlaylistTests {
    @Test("VOD subtitle playlist mirrors the video segment count with per-segment .vtt URIs")
    func vodWindowedPlaylist() {
        let p = WindowedSubsProvider(segCount: 3)
        let pl = HLSLocalServer.buildSubtitleMediaPlaylistText(ordinal: 0, provider: p)
        #expect(pl.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(pl.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        #expect(pl.contains("#EXT-X-TARGETDURATION:4"))
        #expect(pl.contains("#EXTINF:4.000,"))
        #expect(pl.contains("subs_0_0.vtt"))
        #expect(pl.contains("subs_0_1.vtt"))
        #expect(pl.contains("subs_0_2.vtt"))
        #expect(!pl.contains("subs_0_3.vtt"))
        #expect(pl.contains("#EXT-X-ENDLIST"))
        // No init map on a WebVTT rendition.
        #expect(!pl.contains("#EXT-X-MAP"))
    }

    @Test("subtitle playlist uses the requested ordinal in every segment URI")
    func ordinalSegments() {
        let p = WindowedSubsProvider(segCount: 2)
        let pl = HLSLocalServer.buildSubtitleMediaPlaylistText(ordinal: 3, provider: p)
        #expect(pl.contains("subs_3_0.vtt"))
        #expect(pl.contains("subs_3_1.vtt"))
    }

    @Test("a segment .vtt carries the cues in its window with the segment header")
    func segmentVTTBody() {
        // Segment 1 spans [4, 8); two cues land in it.
        let p = WindowedSubsProvider(segCount: 3, cues: [
            1: [(start: 4.5, end: 5.0, text: "first"), (start: 6.0, end: 7.0, text: "second")]
        ])
        let vtt = p.nativeSubtitleVTT(ordinal: 0, segmentIndex: 1)
        #expect(vtt != nil)
        let body = vtt ?? ""
        #expect(body.hasPrefix("WEBVTT\n"))
        #expect(body.contains("X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000"))
        #expect(body.contains("00:00:04.500 --> 00:00:05.000\nfirst"))
        #expect(body.contains("00:00:06.000 --> 00:00:07.000\nsecond"))
    }

    @Test("a segment with no cues still yields a valid WEBVTT segment")
    func emptySegmentVTT() {
        let p = WindowedSubsProvider(segCount: 1)
        let vtt = p.nativeSubtitleVTT(ordinal: 0, segmentIndex: 0)
        #expect(vtt == "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n")
    }

    @Test("out-of-range segment returns nil")
    func outOfRangeSegmentVTT() {
        let p = WindowedSubsProvider(segCount: 2)
        #expect(p.nativeSubtitleVTT(ordinal: 0, segmentIndex: 5) == nil)
        #expect(p.nativeSubtitleVTT(ordinal: 9, segmentIndex: 0) == nil)
    }

    @Test("parseSubsPath extracts ordinal and optional segment index")
    func parsesSubsPath() {
        #expect(HLSLocalServer.parseSubsPath("/subs_0.m3u8")?.ordinal == 0)
        #expect(HLSLocalServer.parseSubsPath("/subs_0.m3u8")?.segment == nil)
        #expect(HLSLocalServer.parseSubsPath("/subs_11.m3u8")?.ordinal == 11)
        let seg = HLSLocalServer.parseSubsPath("/subs_2_7.vtt")
        #expect(seg?.ordinal == 2)
        #expect(seg?.segment == 7)
        let big = HLSLocalServer.parseSubsPath("/subs_3_128.vtt")
        #expect(big?.ordinal == 3)
        #expect(big?.segment == 128)
        #expect(HLSLocalServer.parseSubsPath("/garbage") == nil)
        #expect(HLSLocalServer.parseSubsPath("/subs_x.vtt") == nil)
    }

    @Test("relative cue timing rebases cues to segment start")
    func relativeCueTiming() {
        // segmentStart 4.0; cue at absolute 6.0 -> relative 2.0.
        let vtt = WebVTTBuilder.segment(cues: [(start: 6.0, end: 7.0, text: "x")],
                                        segmentStart: 4.0, relativeToStart: true)
        #expect(vtt.contains("00:00:02.000 --> 00:00:03.000\nx"))
    }

    @Test("master declares SUBTITLES rendition + group when native subs present")
    func masterHasSubtitleRendition() {
        let provider = MasterMockProvider(renditions: [(0, "eng", "English", false)])
        let m = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        #expect(m.contains("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\""))
        #expect(m.contains("LANGUAGE=\"eng\""))
        #expect(m.contains("URI=\"subs_0.m3u8\""))
        #expect(m.contains("SUBTITLES=\"subs\""))
        #expect(!m.contains("FORCED"))
    }

    @Test("a source-forced rendition is NOT emitted FORCED=YES (host owns fullscreen subs)")
    func masterForcedAttribute() {
        // AVKit force-displays a FORCED rendition matching the audio language regardless of
        // DEFAULT/AUTOSELECT and the CC-off preference, self-engaging a rendition the overlay owns
        // (Sodalite#38 follow-on: forced German track shown on German audio with subtitles off). The
        // forced/full pair stays disambiguated by NAME, so neither carries FORCED=YES.
        let provider = MasterMockProvider(renditions: [(0, "ger", "Deutsch", true),
                                                       (1, "ger", "Deutsch 2", false)])
        let m = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        #expect(m.contains("NAME=\"Deutsch\",LANGUAGE=\"ger\",DEFAULT=NO,AUTOSELECT=NO,URI=\"subs_0.m3u8\""))
        #expect(m.contains("NAME=\"Deutsch 2\",LANGUAGE=\"ger\",DEFAULT=NO,AUTOSELECT=NO,URI=\"subs_1.m3u8\""))
        #expect(!m.contains("FORCED"))
    }

    @Test("master omits SUBTITLES when no native subs")
    func masterNoSubtitleRendition() {
        let provider = MasterMockProvider(renditions: [])
        let m = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        #expect(!m.contains("EXT-X-MEDIA:TYPE=SUBTITLES"))
        #expect(!m.contains("SUBTITLES=\"subs\""))
    }
}

/// P8.1-on-DV-panel shape: hvc1 primary + DV via SUPPLEMENTAL + PQ range + one subtitle rendition.
private final class ReducedMasterMockProvider: HLSSegmentProvider, @unchecked Sendable {
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { 1 }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { "hvc1.2.4.L150,ec-3" }
    var masterSupplementalCodecs: String? { "dvh1.08.06/db1p" }
    var masterVideoRange: HLSVideoRange? { .pq }
    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] {
        [(ordinal: 0, language: "en", name: "English", isForced: false)]
    }
}

struct ReducedMasterPlaylistTests {

    @Test("reducedSDR drops SUPPLEMENTAL, forces VIDEO-RANGE=SDR, keeps SUBTITLES + codecs")
    func reducedSDR() {
        let sdr = HLSLocalServer.buildMasterPlaylistText(provider: ReducedMasterMockProvider(), variant: .reducedSDR)
        #expect(sdr.contains("VIDEO-RANGE=SDR"))
        #expect(!sdr.contains("VIDEO-RANGE=PQ"))
        #expect(!sdr.contains("SUPPLEMENTAL-CODECS"))
        #expect(sdr.contains("CODECS=\"hvc1.2.4.L150,ec-3\""))
        #expect(sdr.contains("#EXT-X-MEDIA:TYPE=SUBTITLES"))
        #expect(sdr.contains("SUBTITLES=\"subs\""))
        #expect(sdr.contains("media.m3u8"))
    }

    @Test("reducedHDR drops SUPPLEMENTAL, keeps the source range, keeps SUBTITLES")
    func reducedHDR() {
        let hdr = HLSLocalServer.buildMasterPlaylistText(provider: ReducedMasterMockProvider(), variant: .reducedHDR)
        #expect(hdr.contains("VIDEO-RANGE=PQ"))
        #expect(!hdr.contains("VIDEO-RANGE=SDR"))
        #expect(!hdr.contains("SUPPLEMENTAL-CODECS"))
        #expect(hdr.contains("SUBTITLES=\"subs\""))
    }

    @Test("primary keeps SUPPLEMENTAL and the source range")
    func primaryUnchanged() {
        let primary = HLSLocalServer.buildMasterPlaylistText(provider: ReducedMasterMockProvider(), variant: .primary)
        #expect(primary.contains("SUPPLEMENTAL-CODECS=\"dvh1.08.06/db1p\""))
        #expect(primary.contains("VIDEO-RANGE=PQ"))
    }
}
