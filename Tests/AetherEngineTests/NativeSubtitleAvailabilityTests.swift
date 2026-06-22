// Tests/AetherEngineTests/NativeSubtitleAvailabilityTests.swift
import XCTest
@testable import AetherEngine

final class NativeSubtitleAvailabilityTests: XCTestCase {
    private func textCue(_ id: Int, _ start: Double, _ end: Double, _ text: String) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(text))
    }

    func test_storeWithCuesMakesRenditionAvailable_clearResets() {
        let store = NativeSubtitleCueStore()
        store.appendCues([textCue(1, 0, 1, "x")])
        XCTAssertEqual(store.cueCount, 1)
        store.clear()
        XCTAssertEqual(store.cueCount, 0)
    }

    func test_replaceCuesPopulatesStore() {
        let store = NativeSubtitleCueStore()
        store.replaceCues([textCue(1, 0, 1, "a"), textCue(2, 2, 3, "b")])
        XCTAssertEqual(store.cueCount, 2)
    }

    func test_appendCuesAccumulates() {
        let store = NativeSubtitleCueStore()
        store.appendCues([textCue(1, 0, 1, "a")])
        store.appendCues([textCue(2, 1, 2, "b")])
        XCTAssertEqual(store.cueCount, 2)
    }

    // Mirrors the engine's "available once ANY store in the set has cues,
    // reset when ALL are cleared" rule (#55, all-tracks).
    private func renditionAvailable(_ stores: [NativeSubtitleCueStore]) -> Bool {
        stores.contains { $0.cueCount > 0 }
    }

    func test_setAvailabilityFlipsWhenAnyStorePopulated_resetsOnClearAll() {
        let stores = [NativeSubtitleCueStore(), NativeSubtitleCueStore()]
        XCTAssertFalse(renditionAvailable(stores), "empty set => unavailable")

        // Populate only the second store: the set is still available.
        stores[1].appendCues([textCue(1, 0, 1, "deu")])
        XCTAssertTrue(renditionAvailable(stores), "one populated store => available")

        // Populate the first too; still available.
        stores[0].appendCues([textCue(2, 0, 1, "eng")])
        XCTAssertTrue(renditionAvailable(stores))

        // Clearing only one keeps it available (the other still has cues).
        stores[0].clear()
        XCTAssertTrue(renditionAvailable(stores), "one remaining populated store => still available")

        // Clearing ALL stores resets availability.
        stores[1].clear()
        XCTAssertFalse(renditionAvailable(stores), "all cleared => unavailable")
    }

    func test_eachStoreInSetAccumulatesIndependently() {
        let stores = [NativeSubtitleCueStore(), NativeSubtitleCueStore()]
        stores[0].appendCues([textCue(1, 0, 1, "a"), textCue(2, 1, 2, "b")])
        stores[1].appendCues([textCue(3, 0, 1, "c")])
        XCTAssertEqual(stores[0].cueCount, 2)
        XCTAssertEqual(stores[1].cueCount, 1)
    }

    func test_loadOptionsPrepareNativeSubtitleDefaultsFalse() {
        let opts = LoadOptions()
        XCTAssertFalse(opts.prepareNativeSubtitles)
    }

    func test_loadOptionsPrepareNativeSubtitleRoundTrips() {
        let opts = LoadOptions(prepareNativeSubtitles: true)
        XCTAssertTrue(opts.prepareNativeSubtitles)
    }

    // MARK: - NativeSubtitleTrack shape (Task 4)

    func test_nativeSubtitleTracks_carryOrdinalAndLanguage() {
        // Construct two NativeSubtitleTrack values and assert ordinal /
        // language / displayName are stored and retrieved correctly.
        let t0 = NativeSubtitleTrack(ordinal: 0, language: "en", displayName: "English")
        let t1 = NativeSubtitleTrack(ordinal: 1, language: "de", displayName: "German")
        XCTAssertEqual(t0.ordinal, 0)
        XCTAssertEqual(t0.language, "en")
        XCTAssertEqual(t0.displayName, "English")
        XCTAssertEqual(t1.ordinal, 1)
        XCTAssertEqual(t1.language, "de")
        XCTAssertEqual(t1.displayName, "German")
    }

    func test_nativeSubtitleTrack_nilLanguageFallbackDisplayName() {
        // A track with no language tag must still carry a non-empty displayName.
        let t = NativeSubtitleTrack(ordinal: 2, language: nil, displayName: "Subtitle 3")
        XCTAssertNil(t.language)
        XCTAssertEqual(t.displayName, "Subtitle 3")
    }

    func test_nativeSubtitleTrack_equatableByValue() {
        let a = NativeSubtitleTrack(ordinal: 0, language: "en", displayName: "English")
        let b = NativeSubtitleTrack(ordinal: 0, language: "en", displayName: "English")
        let c = NativeSubtitleTrack(ordinal: 1, language: "en", displayName: "English")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - sameLanguageRank (same-language selection fix)

    /// Two eng tracks followed by one deu track.
    /// rank(0 eng) = 0, rank(1 eng) = 1, rank(2 deu) = 0.
    func test_sameLanguageRank_twoEngOneDeu() {
        let tracks = [
            NativeSubtitleTrack(ordinal: 0, language: "en", displayName: "English"),
            NativeSubtitleTrack(ordinal: 1, language: "en", displayName: "English SDH"),
            NativeSubtitleTrack(ordinal: 2, language: "de", displayName: "German"),
        ]
        XCTAssertEqual(NativeSubtitleTrack.sameLanguageRank(of: 0, in: tracks), 0)
        XCTAssertEqual(NativeSubtitleTrack.sameLanguageRank(of: 1, in: tracks), 1)
        XCTAssertEqual(NativeSubtitleTrack.sameLanguageRank(of: 2, in: tracks), 0)
    }

    func test_sameLanguageRank_outOfRange_returnsZero() {
        let tracks = [NativeSubtitleTrack(ordinal: 0, language: "en", displayName: "English")]
        XCTAssertEqual(NativeSubtitleTrack.sameLanguageRank(of: 5, in: tracks), 0)
    }

    func test_sameLanguageRank_nilLanguage_returnsZero() {
        let tracks = [NativeSubtitleTrack(ordinal: 0, language: nil, displayName: "Subtitle 1")]
        XCTAssertEqual(NativeSubtitleTrack.sameLanguageRank(of: 0, in: tracks), 0)
    }

    func test_sameLanguageRank_singleTrack_isZero() {
        let tracks = [NativeSubtitleTrack(ordinal: 0, language: "fr", displayName: "French")]
        XCTAssertEqual(NativeSubtitleTrack.sameLanguageRank(of: 0, in: tracks), 0)
    }
}
