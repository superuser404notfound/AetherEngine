import Testing
import Foundation
@testable import AetherEngine

/// `LoadOptions.initialSubtitleTrackID`: a host that already knows which subtitle track it wants (a
/// server's default subtitle index) names it at load instead of ranking by language. Pure selection,
/// no media fixture and no decoder path involved. MainActor only because
/// `externalSubtitleTrackIDBase` is.
@MainActor
struct InitialSubtitleTrackTests {

    private func track(_ id: Int, _ lang: String?, isForced: Bool = false,
                       isExternal: Bool = false) -> TrackInfo {
        TrackInfo(id: id, name: "t\(id)", codec: "subrip", language: lang, isDefault: false,
                  isForced: isForced, isExternal: isExternal)
    }

    @Test("an id that names a track wins over the language preference")
    func idWinsOverLanguage() {
        let tracks = [track(2, "eng"), track(3, "deu"), track(4, "fra")]
        #expect(AetherEngine.resolveInitialSubtitleIndex(
            tracks: tracks, initialTrackID: 4, preferredLanguages: ["en"]) == 4)
    }

    @Test("an id works without any language preference")
    func idWithoutLanguages() {
        let tracks = [track(2, "eng"), track(3, "deu")]
        #expect(AetherEngine.resolveInitialSubtitleIndex(
            tracks: tracks, initialTrackID: 3, preferredLanguages: []) == 3)
    }

    @Test("an id that names no track falls through to the language preference")
    func staleIdFallsThrough() {
        let tracks = [track(2, "eng"), track(3, "deu")]
        #expect(AetherEngine.resolveInitialSubtitleIndex(
            tracks: tracks, initialTrackID: 99, preferredLanguages: ["de"]) == 3)
    }

    @Test("a stale id with no preference leaves subtitles off")
    func staleIdNoPreference() {
        let tracks = [track(2, "eng")]
        #expect(AetherEngine.resolveInitialSubtitleIndex(
            tracks: tracks, initialTrackID: 99, preferredLanguages: []) == nil)
    }

    @Test("no id keeps the language selection exactly as it was")
    func noIdIsTheLanguageSelection() {
        let tracks = [track(2, "eng", isForced: true), track(3, "eng")]
        let expected = AetherEngine.selectSubtitleIndex(tracks: tracks, preferredLanguages: ["en"])
        #expect(expected == 3)
        #expect(AetherEngine.resolveInitialSubtitleIndex(
            tracks: tracks, initialTrackID: nil, preferredLanguages: ["en"]) == expected)
    }

    @Test("an id can name a forced track the language ranking would not pick")
    func idCanNameForcedTrack() {
        let tracks = [track(2, "eng", isForced: true), track(3, "eng")]
        #expect(AetherEngine.resolveInitialSubtitleIndex(
            tracks: tracks, initialTrackID: 2, preferredLanguages: ["en"]) == 2)
    }

    @Test("an external track is named by its synthetic id")
    func externalTrackById() {
        let externalID = AetherEngine.externalSubtitleTrackIDBase + 1
        let tracks = [track(2, "eng"),
                      track(AetherEngine.externalSubtitleTrackIDBase, "deu", isExternal: true),
                      track(externalID, "fra", isExternal: true)]
        #expect(AetherEngine.resolveInitialSubtitleIndex(
            tracks: tracks, initialTrackID: externalID, preferredLanguages: []) == Int32(externalID))
    }

    @Test("the option defaults to nil and takes part in LoadOptions equality")
    func optionDefaultsAndEquality() {
        #expect(LoadOptions().initialSubtitleTrackID == nil)
        #expect(LoadOptions(initialSubtitleTrackID: 3).initialSubtitleTrackID == 3)
        #expect(LoadOptions(initialSubtitleTrackID: 3) != LoadOptions())
    }

    @Test("a track id is a tuning field: a reload may change it without being refused")
    func notAnIdentityField() {
        #expect(!SessionOptionCorrection.loadIdentityFields.contains("initialSubtitleTrackID"))
        #expect(SessionOptionCorrection.knownFields.contains("initialSubtitleTrackID"))
    }

    @Test("an id with no language preference activates a late-added external track it names")
    func idAloneReachesTheApplyGuard() throws {
        let engine = try AetherEngine()
        let id = AetherEngine.externalSubtitleTrackIDBase
        engine.setLoadedOptionsForTesting(LoadOptions(initialSubtitleTrackID: id))
        #expect(engine.loadedOptions.preferredSubtitleLanguages.isEmpty)
        let info = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(string: "https://s/x.srt")!, name: "x", language: "de"))
        #expect(info.id == id)
        #expect(engine.isSubtitleActive)
        #expect(engine.activeSubtitleTrackIndex == id)
    }

    @Test("a host choice made first still wins over the id")
    func hostChoiceBeatsTheId() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(
            initialSubtitleTrackID: AetherEngine.externalSubtitleTrackIDBase))
        engine.clearSubtitle()
        _ = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(string: "https://s/x.srt")!, name: "x", language: "de"))
        #expect(!engine.isSubtitleActive)
    }

    @Test("a disc title switch drops the id, since stream indices belong to one title")
    func titleSwitchDropsTheId() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(initialSubtitleTrackID: 4))
        engine.loadedURL = URL(fileURLWithPath: "/nonexistent/disc.iso")
        engine.discTitles = [TitleInfo(id: 0, name: "Main", durationSeconds: 7200, chapterCount: 12),
                             TitleInfo(id: 1, name: "Extra", durationSeconds: 600, chapterCount: 1)]
        engine.activeDiscTitleID = 0
        engine.selectTitle(id: 0)   // already selected: a no-op, the id stays
        #expect(engine.loadedOptions.initialSubtitleTrackID == 4)
        engine.selectTitle(id: 1)
        #expect(engine.loadedOptions.initialSubtitleTrackID == nil)
    }
}
