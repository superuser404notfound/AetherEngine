import Testing
import Foundation
@testable import AetherEngine

/// Same-language subtitle renditions need unique NAMEs and synonym-aware option matching.
/// Device repro (Cars, [ger forced, ger, eng]): duplicate NAME="Deutsch" made AVFoundation
/// collapse three declared renditions into two legible options (groupOpts=2), and the option
/// matcher compared the matroska tag "ger" against AVFoundation's normalized "de" with hasPrefix,
/// found nothing, and the positional fallback selected the ENGLISH option for the second German
/// track. PiP rendered English subtitles for a German selection.
@MainActor
struct NativeSubtitleRenditionTests {

    private func entry(_ lang: String?, forced: Bool = false) -> AetherEngine.NativeSubtitleTrackEntry {
        AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 0, language: lang, isForced: forced)
    }

    @Test("same-language renditions get unique numbered names")
    func uniqueNames() {
        let infos = AetherEngine.nativeSubtitleRenditionInfos(
            for: [entry("ger", forced: true), entry("ger"), entry("eng")])
        #expect(infos.count == 3)
        #expect(infos[0].name != infos[1].name)
        #expect(infos[1].name == "\(infos[0].name) 2")
        #expect(infos[0].isForced)
        #expect(!infos[1].isForced)
        #expect(infos[2].name != infos[0].name)
    }

    @Test("nil language falls back to a positional name")
    func nilLanguageName() {
        let infos = AetherEngine.nativeSubtitleRenditionInfos(for: [entry(nil), entry(nil)])
        #expect(infos[0].name == "Subtitle 1")
        #expect(infos[1].name == "Subtitle 2")
    }

    @Test("option index resolves matroska tags against normalized AVFoundation tags by rank")
    func optionIndexSynonyms() {
        // Options as AVFoundation exposes them after HLS normalization: [de, de, en].
        let tags: [String?] = ["de", "de", "en"]
        #expect(AetherEngine.nativeOptionIndex(forLanguage: "ger", rank: 0, optionLanguageTags: tags) == 0)
        #expect(AetherEngine.nativeOptionIndex(forLanguage: "ger", rank: 1, optionLanguageTags: tags) == 1)
        #expect(AetherEngine.nativeOptionIndex(forLanguage: "eng", rank: 0, optionLanguageTags: tags) == 2)
    }

    @Test("region subtags are ignored when matching")
    func optionIndexRegionSubtag() {
        #expect(AetherEngine.nativeOptionIndex(forLanguage: "ger", rank: 0,
                                               optionLanguageTags: ["de-DE"]) == 0)
    }

    @Test("no cross-language fallback: unmatched rank or language selects nothing")
    func noCrossLanguageFallback() {
        let tags: [String?] = ["de", "en"]
        // Rank 1 German does not exist among the options: nil, NOT the English option.
        #expect(AetherEngine.nativeOptionIndex(forLanguage: "ger", rank: 1, optionLanguageTags: tags) == nil)
        #expect(AetherEngine.nativeOptionIndex(forLanguage: "jpn", rank: 0, optionLanguageTags: tags) == nil)
        #expect(AetherEngine.nativeOptionIndex(forLanguage: nil, rank: 0, optionLanguageTags: tags) == nil)
    }

    // MARK: - AE#1050: names from the track title

    private func titled(_ lang: String?, _ title: String?, sdh: Bool = false) -> AetherEngine.NativeSubtitleTrackEntry {
        AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 0, language: lang, title: title, isHearingImpaired: sdh)
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    @Test("AE#1050: two same-language tracks are told apart by their titles")
    func titlesSeparateSameLanguage() {
        let infos = AetherEngine.nativeSubtitleRenditionInfos(
            for: [titled("eng", "SDH", sdh: true), titled("eng", "CC")])
        let en = languageName("eng")
        // AVFoundation appends "SDH" itself to an option with the SDH characteristic.
        #expect(infos[0].name == en)
        #expect(infos[1].name == "\(en) (CC)")
        #expect(infos[0].isHearingImpaired)
        #expect(!infos[1].isHearingImpaired)
    }

    @Test("AE#1050: a title that names the language stands alone, one that is the code is dropped")
    func titleNamingTheLanguage() {
        let en = languageName("eng")
        #expect(AetherEngine.nativeSubtitleRenditionBaseName(language: "eng", title: "\(en) SDH") == "\(en) SDH")
        #expect(AetherEngine.nativeSubtitleRenditionBaseName(language: "eng", title: "eng") == en)
        #expect(AetherEngine.nativeSubtitleRenditionBaseName(language: "eng", title: "  ") == en)
        #expect(AetherEngine.nativeSubtitleRenditionBaseName(language: nil, title: "Signs") == "Signs")
        #expect(AetherEngine.nativeSubtitleRenditionBaseName(language: nil, title: nil) == nil)
    }

    @Test("AE#1050: an SDH track drops SDH from its title, AVFoundation adds it back")
    func sdhTitleStripped() {
        let en = languageName("eng")
        #expect(AetherEngine.nativeSubtitleRenditionBaseName(language: "eng", title: "SDH", isHearingImpaired: true) == en)
        #expect(AetherEngine.nativeSubtitleRenditionBaseName(language: "eng", title: "\(en) [SDH]", isHearingImpaired: true) == en)
        #expect(AetherEngine.nativeSubtitleRenditionBaseName(language: "eng", title: "Forced SDH", isHearingImpaired: true)
                == "\(en) (Forced)")
        // Without the disposition there is no characteristic, so the title keeps its SDH.
        #expect(AetherEngine.nativeSubtitleRenditionBaseName(language: "eng", title: "SDH") == "\(en) (SDH)")
    }

    @Test("AE#1050: a quote or line break in a title cannot break the master tag")
    func titleIsSanitized() {
        let name = AetherEngine.nativeSubtitleRenditionBaseName(language: nil, title: "Say \"hi\"\nnow") ?? ""
        #expect(!name.contains("\""))
        #expect(!name.contains("\n"))
    }

    @Test("AE#1050: identical titles still get the numbered suffix")
    func identicalTitlesStayUnique() {
        let infos = AetherEngine.nativeSubtitleRenditionInfos(for: [titled("eng", "Full"), titled("eng", "Full")])
        #expect(infos[1].name == "\(infos[0].name) 2")
    }

    // MARK: - Phase D: bitmap OCR renditions

    @Test("bitmap tracks become needsOCR entries; text tracks and live sessions are excluded")
    func bitmapOCREntries() {
        let tracks = [
            TrackInfo(id: 2, name: "English", codec: "subrip", language: "en", isDefault: false),
            TrackInfo(id: 3, name: "German (PGS)", codec: "pgssub", language: "de", isDefault: false, isForced: true),
            TrackInfo(id: 900_001, name: "External PGS", codec: "pgssub", language: "en", isDefault: false, isExternal: true),
        ]
        let entries = AetherEngine.bitmapOCRSubtitleEntries(from: tracks, isLive: false)
        #expect(entries.count == 2)
        #expect(entries[0].sourceStreamIndex == 3)
        #expect(entries[0].externalID == nil)
        #expect(entries[0].needsOCR)
        #expect(entries[0].isForced)
        #expect(entries[1].sourceStreamIndex == nil)
        #expect(entries[1].externalID == 900_001)
        #expect(AetherEngine.bitmapOCRSubtitleEntries(from: tracks, isLive: true).isEmpty)
    }

    @Test("combined rendition names keep text names stable and suffix same-language bitmap entries")
    func combinedRenditionNames() {
        let text = AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 2, language: "de")
        let bitmap = AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 3, language: "de", needsOCR: true)
        let infos = AetherEngine.nativeSubtitleRenditionInfos(for: [text, bitmap])
        #expect(infos[0].name != infos[1].name)
        #expect(infos[1].name.hasPrefix(infos[0].name))
    }
}
