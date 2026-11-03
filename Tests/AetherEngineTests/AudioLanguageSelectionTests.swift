import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// Issue #72: the engine resolves the first-frame audio track from its single internal probe,
/// honoring an ordered language preference, so a host avoids a separate audio pre-probe or a
/// post-load `selectAudioTrack` reload. These cover the pure resolution in isolation.
struct AudioLanguageSelectionTests {

    private func track(_ id: Int, _ lang: String?, isDefault: Bool = false) -> TrackInfo {
        TrackInfo(id: id, name: "a\(id)", codec: "aac", language: lang, channels: 2, isDefault: isDefault)
    }

    @Test("language matching is case-insensitive across ISO 639-1/2 and English names")
    func matches() {
        #expect(AetherEngine.languageMatches("en", "en"))
        #expect(AetherEngine.languageMatches("eng", "en"))
        #expect(AetherEngine.languageMatches("EN", "eng"))
        #expect(AetherEngine.languageMatches("german", "de"))
        #expect(AetherEngine.languageMatches("ger", "deu"))
        #expect(AetherEngine.languageMatches(" en ", "english"))
    }

    @Test("language matching rejects mismatches and empty/nil inputs")
    func noMatch() {
        #expect(!AetherEngine.languageMatches("en", "de"))
        #expect(!AetherEngine.languageMatches(nil, "en"))
        #expect(!AetherEngine.languageMatches("", "en"))
        #expect(!AetherEngine.languageMatches("en", ""))
    }

    @Test("explicit override wins when it names a real track")
    func overrideWins() {
        let tracks = [track(0, "en"), track(1, "de")]
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: 1, preferredLanguages: ["en"]) == 1)
    }

    @Test("an out-of-range override falls through to the preference")
    func invalidOverrideFallsThrough() {
        let tracks = [track(0, "en"), track(1, "de")]
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: 9, preferredLanguages: ["de"]) == 1)
    }

    @Test("preference order beats track order")
    func preferenceOrder() {
        let tracks = [track(0, "fr"), track(1, "de"), track(2, "en")]
        // en is on a later track than de, but en is the earlier preference -> en wins.
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: ["en", "de"]) == 2)
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: ["de", "en"]) == 1)
    }

    @Test("no preference match selects nothing (caller keeps the default)")
    func noMatchIsNil() {
        let tracks = [track(0, "fr"), track(1, "es")]
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: ["en"]) == nil)
    }

    @Test("empty preferences with no override select nothing (a #72 no-op)")
    func emptyPreferences() {
        let tracks = [track(0, "fr"), track(1, "es")]
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: []) == nil)
    }

    @Test("a no-audio source selects nothing")
    func noAudio() {
        #expect(AetherEngine.selectAudioIndex(
            tracks: [], override: nil, preferredLanguages: ["en"]) == nil)
    }

    @Test("preference matches a track tagged with a 3-letter code")
    func synonymTrack() {
        let tracks = [track(0, "jpn"), track(1, "eng")]
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: ["en"]) == 1)
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: ["ja"]) == 0)
    }

    // MARK: - #731: TrueHD Atmos and DTS:X win within a language when object rendering is on

    private func audio(_ id: Int, _ lang: String?, codec: String, atmos: Bool = false, commentary: Bool = false,
                       described: Bool = false, profile: Int32? = nil) -> TrackInfo {
        let codecID = codec == "dca" ? AV_CODEC_ID_DTS : AV_CODEC_ID_TRUEHD
        return TrackInfo(id: id, name: "a\(id)", codec: codec, language: lang, channels: 8, isDefault: id == 1,
                         isCommentary: commentary, isVisualImpaired: described,
                         profile: atmos ? VideoStreamFormat.profileName(codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS)
                             : profile.flatMap { VideoStreamFormat.profileName(codecID: codecID, profile: $0) })
    }

    @Test("with rendering on, DTS:X wins within its language like TrueHD Atmos; plain DTS-HD MA does not",
          .enabled(if: AetherEngine.linksDTSXObjectDecoder))
    func dtsxWinsWithinLanguage() {
        // `dca` is what the probe reports for DTS: TrackInfo.codec is the decoder's name.
        let tracks = [audio(1, "eng", codec: "ac3"), audio(2, "eng", codec: "dca", profile: AV_PROFILE_DTS_HD_MA_X),
                      audio(3, "ger", codec: "dca", profile: AV_PROFILE_DTS_HD_MA_X)]
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: ["en"],
                                              prefersObjectAudio: true) == 2)
        // Independence Day: no track flagged default, the probe's best stream an AC-3 commentary.
        let imax = [audio(1, "eng", codec: "ac3"), audio(2, "eng", codec: "dca", profile: AV_PROFILE_DTS_HD_MA_X_IMAX)]
        #expect(AetherEngine.selectAudioIndex(tracks: imax, override: nil, preferredLanguages: [],
                                              prefersObjectAudio: true, defaultIndex: 1) == 2)
        // A plain label may still be DTS:X, but only the label can be ranked before playback.
        let plain = [audio(1, "eng", codec: "ac3"), audio(2, "eng", codec: "dca", profile: AV_PROFILE_DTS_HD_MA)]
        #expect(AetherEngine.selectAudioIndex(tracks: plain, override: nil, preferredLanguages: ["en"],
                                              prefersObjectAudio: true) == 1)
        let commentary = [audio(1, "eng", codec: "ac3"),
                          audio(2, "eng", codec: "dca", commentary: true, profile: AV_PROFILE_DTS_HD_MA_X)]
        #expect(AetherEngine.selectAudioIndex(tracks: commentary, override: nil, preferredLanguages: ["en"],
                                              prefersObjectAudio: true) == 1)
    }

    @Test("with rendering on, TrueHD Atmos beats DTS and plain TrueHD of the preferred language",
          .enabled(if: AetherEngine.linksTrueHDObjectDecoder))
    func trueHDAtmosWinsWithinLanguage() {
        let tracks = [audio(1, "eng", codec: "dts"), audio(2, "eng", codec: "truehd", atmos: true),
                      audio(3, "ger", codec: "truehd", atmos: true)]
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: ["en"],
                                              prefersObjectAudio: true) == 2)
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: ["en"]) == 1,
                "rendering off keeps the container order")
        let plain = [audio(1, "eng", codec: "truehd"), audio(2, "eng", codec: "truehd", atmos: true)]
        #expect(AetherEngine.selectAudioIndex(tracks: plain, override: nil, preferredLanguages: ["en"],
                                              prefersObjectAudio: true) == 2)
    }

    @Test("with rendering on and no track tagged, TrueHD Atmos replaces the default; any tag keeps it",
          .enabled(if: AetherEngine.linksTrueHDObjectDecoder))
    func untaggedTrueHDAtmosReplacesUntaggedDefault() {
        // Dolby's Unfold demo: every track `und`, the probe's best stream the E-AC-3 JOC at index 3.
        let unfold = [audio(1, "und", codec: "truehd", atmos: true), audio(2, "und", codec: "ac3"),
                      audio(3, nil, codec: "eac3")]
        #expect(AetherEngine.selectAudioIndex(tracks: unfold, override: nil, preferredLanguages: ["de"],
                                              prefersObjectAudio: true, defaultIndex: 3) == 1)
        #expect(AetherEngine.selectAudioIndex(tracks: unfold, override: nil, preferredLanguages: ["de"],
                                              defaultIndex: 3) == nil, "rendering off keeps the default")
        let tagged = [audio(1, "eng", codec: "truehd", atmos: true), audio(2, nil, codec: "eac3")]
        #expect(AetherEngine.selectAudioIndex(tracks: tagged, override: nil, preferredLanguages: [],
                                              prefersObjectAudio: true, defaultIndex: 2) == nil)
        let commentaryOnly = [audio(1, nil, codec: "eac3"),
                              audio(2, nil, codec: "truehd", atmos: true, commentary: true)]
        #expect(AetherEngine.selectAudioIndex(tracks: commentaryOnly, override: nil, preferredLanguages: [],
                                              prefersObjectAudio: true, defaultIndex: 1) == nil)
    }

    @Test("it never crosses a language, and an override still wins",
          .enabled(if: AetherEngine.linksTrueHDObjectDecoder))
    func neverAcrossLanguage() {
        let tracks = [audio(1, "ger", codec: "dts"), audio(2, "eng", codec: "truehd", atmos: true)]
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: ["de"],
                                              prefersObjectAudio: true) == 1)
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: 1, preferredLanguages: ["en"],
                                              prefersObjectAudio: true) == 1)
    }

    @Test("without a language preference it replaces the default track with TrueHD Atmos in that track's language",
          .enabled(if: AetherEngine.linksTrueHDObjectDecoder))
    func replacesDefaultInItsLanguage() {
        let tracks = [audio(1, "eng", codec: "dts"), audio(2, "ger", codec: "truehd", atmos: true),
                      audio(3, "eng", codec: "truehd", atmos: true)]
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: [],
                                              prefersObjectAudio: true, defaultIndex: 1) == 3)
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: [],
                                              prefersObjectAudio: false, defaultIndex: 1) == nil)
        let partlyTagged = [audio(1, nil, codec: "dts"), audio(2, nil, codec: "truehd", atmos: true),
                            audio(3, "ger", codec: "ac3")]
        #expect(AetherEngine.selectAudioIndex(tracks: partlyTagged, override: nil, preferredLanguages: [],
                                              prefersObjectAudio: true, defaultIndex: 1) == nil,
                "the file tags its dubs, so an untagged default is not compared by guess")
    }

    @Test("a commentary in TrueHD Atmos does not displace the film",
          .enabled(if: AetherEngine.linksTrueHDObjectDecoder))
    func commentaryStaysBehind() {
        let tracks = [audio(1, "eng", codec: "dts"), audio(2, "eng", codec: "truehd", atmos: true, commentary: true)]
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: ["en"],
                                              prefersObjectAudio: true) == 1)
    }

    @Test("a preference nothing matches still lets the default's language take its TrueHD Atmos track",
          .enabled(if: AetherEngine.linksTrueHDObjectDecoder))
    func unmatchedPreferenceFallsBackToDefaultLanguage() {
        // Sodalite always sends the device locale; on a German box a film with only English audio
        // matches nothing and plays its default track.
        let tracks = [audio(1, "eng", codec: "dts"), audio(2, "eng", codec: "truehd", atmos: true)]
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: ["de"],
                                              prefersObjectAudio: true, defaultIndex: 1) == 2)
    }

    @Test("the fallback keeps the dub: a region both tags state and disagree on is another track",
          .enabled(if: AetherEngine.linksTrueHDObjectDecoder))
    func fallbackKeepsTheDub() {
        let tracks = [audio(1, "es-ES", codec: "dts"), audio(2, "es-419", codec: "truehd", atmos: true)]
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: [],
                                              prefersObjectAudio: true, defaultIndex: 1) == nil)
        let same = [audio(1, "es-ES", codec: "dts"), audio(2, "es", codec: "truehd", atmos: true)]
        #expect(AetherEngine.selectAudioIndex(tracks: same, override: nil, preferredLanguages: [],
                                              prefersObjectAudio: true, defaultIndex: 1) == 2)
    }

    @Test("built without an object decoder's trait, the pick does not prefer that codec",
          .disabled(if: AetherEngine.linksTrueHDObjectDecoder && AetherEngine.linksDTSXObjectDecoder))
    func withoutTraitNothingIsPreferred() {
        let tracks = [audio(1, "eng", codec: "ac3"), audio(2, "eng", codec: "truehd", atmos: true),
                      audio(3, "eng", codec: "dca", profile: AV_PROFILE_DTS_HD_MA_X)]
        let expected = AetherEngine.linksTrueHDObjectDecoder ? 2 : AetherEngine.linksDTSXObjectDecoder ? 3 : 1
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: ["en"],
                                              prefersObjectAudio: true) == Int32(expected))
    }

    // MARK: - AE#919: audio description and commentary rank behind the programme mix

    @Test("within a language the programme mix wins over an audio description or commentary listed first")
    func describedAndCommentaryRankBehind() {
        let described = [audio(1, "eng", codec: "ac3", described: true), audio(2, "eng", codec: "ac3"),
                         audio(3, "ger", codec: "ac3")]
        #expect(AetherEngine.selectAudioIndex(tracks: described, override: nil, preferredLanguages: ["en"]) == 2)
        let commentary = [audio(1, "eng", codec: "ac3", commentary: true), audio(2, "eng", codec: "ac3")]
        #expect(AetherEngine.selectAudioIndex(tracks: commentary, override: nil, preferredLanguages: ["en"]) == 2)
    }

    @Test("an audio description still beats a later preference and is picked when it is the language's only track")
    func describedNeverCrossesLanguage() {
        let tracks = [audio(1, "ger", codec: "ac3"), audio(2, "eng", codec: "ac3", described: true)]
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: ["en", "de"]) == 2)
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: 2, preferredLanguages: ["de"]) == 2)
    }

    @Test("an audio description in TrueHD Atmos neither displaces the film nor replaces the default",
          .enabled(if: AetherEngine.linksTrueHDObjectDecoder))
    func describedAtmosStaysBehind() {
        let tracks = [audio(1, "eng", codec: "dts"), audio(2, "eng", codec: "truehd", atmos: true, described: true)]
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: ["en"],
                                              prefersObjectAudio: true) == 1)
        #expect(AetherEngine.selectAudioIndex(tracks: tracks, override: nil, preferredLanguages: [],
                                              prefersObjectAudio: true, defaultIndex: 1) == nil)
    }
}
