import Testing
import Foundation
@testable import AetherEngine

/// #112 rework: embedded overlay selection targets the playhead-paced drainer instead of a
/// side-demuxer reader, on both channels. Successor of the deleted side-reader wedge/rearm
/// suites: what must survive seeks, wedge reconciles, and audio-switch reloads is the DRAIN
/// TARGET (the reload path re-selects via selectSubtitleTrack), not a reader task.
@MainActor
struct SubtitleDrainSelectionTests {

    private func makeLoadedEngine() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        return engine
    }

    @Test("embedded selection sets the primary drain target and activates subtitles")
    func primarySelectionTargetsDrainer() throws {
        let engine = try makeLoadedEngine()
        engine.selectSubtitleTrack(index: 3)
        #expect(engine.subtitleDrainTargets[.primary] == 3)
        #expect(engine.isSubtitleActive)
        #expect(engine.activeEmbeddedSubtitleStreamIndex == 3)
        #expect(engine.activeSubtitleTrackIndex == 3)
        #expect(engine.isLoadingSubtitles == false)
    }

    @Test("clearSubtitle drops the primary drain target")
    func clearDropsPrimaryTarget() throws {
        let engine = try makeLoadedEngine()
        engine.selectSubtitleTrack(index: 3)
        engine.clearSubtitle()
        #expect(engine.subtitleDrainTargets[.primary] == nil)
        #expect(engine.isSubtitleActive == false)
    }

    @Test("secondary embedded selection rides its own channel target")
    func secondarySelectionTargetsDrainer() throws {
        let engine = try makeLoadedEngine()
        engine.selectSecondarySubtitleTrack(index: 5)
        #expect(engine.subtitleDrainTargets[.secondary] == 5)
        #expect(engine.isSecondarySubtitleActive)
        engine.clearSecondarySubtitle()
        #expect(engine.subtitleDrainTargets[.secondary] == nil)
    }

    @Test("track switch replaces the target instead of stacking readers")
    func switchReplacesTarget() throws {
        let engine = try makeLoadedEngine()
        engine.selectSubtitleTrack(index: 3)
        engine.selectSubtitleTrack(index: 7)
        #expect(engine.subtitleDrainTargets[.primary] == 7)
        #expect(engine.subtitleDrainTargets.count == 1)
    }

    @Test("external selection clears the embedded drain target")
    func externalSelectionClearsTarget() throws {
        let engine = try makeLoadedEngine()
        engine.selectSubtitleTrack(index: 3)
        let info = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(string: "https://s/x.srt")!, name: "x", language: "de"))
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.subtitleDrainTargets[.primary] == nil)
        #expect(engine.activeSubtitleTrackIndex == info.id)
    }
}
