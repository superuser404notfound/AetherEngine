import Testing
import Foundation
@testable import AetherEngine

private final class AudioMenuMasterProvider: HLSSegmentProvider, @unchecked Sendable {
    let alternates: [AudioRenditionChoice]
    let primary: (language: String?, name: String)?
    init(primary: (language: String?, name: String)?, alternates: [AudioRenditionChoice]) {
        self.primary = primary
        self.alternates = alternates
    }
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { 1 }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { "hvc1.1.6.L120.90,mp4a.40.2" }
    var masterVideoRange: HLSVideoRange? { .sdr }
    var masterAudioRendition: (language: String?, name: String)? { primary }
    var masterAudioAlternates: [AudioRenditionChoice] { primary == nil ? [] : alternates }
}

/// AE#1049: every source audio track in the master's audio group, the served one muxed and the
/// rest as URI-less entries a viewer can pick from AVKit's audio menu.
struct AudioMenuRenditionTests {

    private func choice(_ id: Int, _ lang: String?, _ name: String, _ ch: Int = 2) -> AudioRenditionChoice {
        AudioRenditionChoice(trackID: id, language: lang, name: name, channels: ch)
    }

    @Test("alternates follow the served rendition without a URI and never autoselect")
    func masterListsAlternates() {
        let provider = AudioMenuMasterProvider(primary: ("jpn", "Japanese"),
                                               alternates: [choice(2, "eng", "English", 6)])
        let lines = HLSLocalServer.buildMasterPlaylistText(provider: provider)
            .split(separator: "\n").filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }
        #expect(lines.count == 2)
        #expect(lines[0].contains("NAME=\"Japanese\"") && lines[0].contains("DEFAULT=YES"))
        #expect(lines[1].contains("NAME=\"English\""))
        #expect(lines[1].contains("LANGUAGE=\"eng\""))
        #expect(lines[1].contains("DEFAULT=NO,AUTOSELECT=NO"))
        #expect(lines[1].contains("CHANNELS=\"6\""))
        #expect(!lines[1].contains("URI="))
        #expect(lines[1].contains("GROUP-ID=\"aud\""))
    }

    @Test("no served rendition, no alternates")
    func noPrimaryNoAlternates() {
        let provider = AudioMenuMasterProvider(primary: nil, alternates: [choice(2, "eng", "English")])
        let master = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        #expect(!master.contains("TYPE=AUDIO"))
    }

    @Test("names are made unique once over the whole track list, so a switch renames nothing")
    func uniqueNames() {
        let named = VideoSegmentProvider.uniquelyNamed(
            [choice(1, "eng", "English"), choice(2, "eng", "English"), choice(3, "ger", "German")])
        #expect(named.map(\.name) == ["English", "English 2", "German"])
        #expect(named.map(\.trackID) == [1, 2, 3])
    }

    @Test("track titles name the entries, language and number are the fallback")
    func choicesFromTracks() {
        let tracks = [
            TrackInfo(id: 1, name: "JPN (aac)", codec: "aac", language: "jpn", channels: 2, isDefault: true),
            TrackInfo(id: 2, name: "Track 2 (ac3)", codec: "ac3", language: nil, channels: 6, isDefault: false),
        ]
        var commentary = TrackInfo(id: 3, name: "Commentary", codec: "aac", language: "eng", channels: 2, isDefault: false)
        commentary.sourceTitle = "Commentary"
        let choices = AetherEngine.audioMenuChoices(for: tracks + [commentary])
        let ja = Locale.current.localizedString(forIdentifier: "jpn") ?? "jpn"
        let en = Locale.current.localizedString(forIdentifier: "eng") ?? "eng"
        #expect(choices.map(\.name) == [ja, "Audio 2", "\(en) (Commentary)"])
        #expect(choices.map(\.channels) == [2, 6, 2])
    }

    @Test("a repeated language never names a track by the bare language")
    func repeatedLanguageGetsTrackNumber() {
        var english = TrackInfo(id: 2, name: "English", codec: "aac", language: "eng", channels: 2, isDefault: false)
        english.sourceTitle = "English"
        var commentary = TrackInfo(id: 3, name: "Commentary", codec: "aac", language: "eng", channels: 2, isDefault: false)
        commentary.sourceTitle = "Commentary"
        let japanese = TrackInfo(id: 1, name: "JPN (aac)", codec: "aac", language: "jpn", channels: 2, isDefault: true)
        let en = Locale.current.localizedString(forIdentifier: "eng") ?? "eng"
        let ja = Locale.current.localizedString(forIdentifier: "jpn") ?? "jpn"
        let names = AetherEngine.audioMenuChoices(for: [japanese, english, commentary]).map(\.name)
        #expect(names == [ja, "\(en) (Track 2)", "\(en) (Commentary)"])
    }

    @Test("a pick maps by NAME first, then by language and rank")
    func pickMapping() {
        let declared = [choice(1, "jpn", "Japanese"), choice(2, "eng", "English"), choice(3, "eng", "English 2")]
        #expect(AetherEngine.audioMenuTrackID(selectedName: "English 2", selectedLanguage: "en",
                                              rankInLanguage: 0, declared: declared) == 3)
        // A NAME that matches nothing falls back to language and rank: rank 1 is the second English.
        #expect(AetherEngine.audioMenuTrackID(selectedName: "Englisch", selectedLanguage: "en",
                                              rankInLanguage: 1, declared: declared) == 3)
        #expect(AetherEngine.audioMenuTrackID(selectedName: "Französisch", selectedLanguage: "fr",
                                              rankInLanguage: 0, declared: declared) == nil)
        #expect(AetherEngine.audioMenuTrackID(selectedName: nil, selectedLanguage: "en",
                                              rankInLanguage: 0, declared: declared) == 2)
        #expect(AetherEngine.audioMenuTrackID(selectedName: "Unknown", selectedLanguage: nil,
                                              rankInLanguage: 0, declared: declared) == nil)
    }
}
