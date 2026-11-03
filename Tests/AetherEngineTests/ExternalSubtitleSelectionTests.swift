import Testing
import Foundation
@testable import AetherEngine

/// AetherEngine#88: selecting an external id through the unified selectSubtitleTrack routes onto
/// the sidecar decode path and publishes the external id as the active track (the old sidecar API
/// nilled it, so hosts could not highlight an external selection).
@MainActor
struct ExternalSubtitleSelectionTests {

    private func makeTrack(_ name: String = "x") -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(url: URL(string: "https://s/\(name).srt")!, name: name, language: "de")
    }

    @Test("selecting an external id activates it and publishes activeSubtitleTrackIndex")
    func selectExternal() throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(makeTrack())
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.isSubtitleActive)
        #expect(engine.activeSubtitleTrackIndex == info.id)
        #expect(engine.activeEmbeddedSubtitleStreamIndex == -1)
    }

    @Test("external selection works without a loaded URL (no loadedURL guard on the external path)")
    func selectExternalWithoutLoad() throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(makeTrack())
        #expect(engine.loadedURL == nil)
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.isSubtitleActive)
    }

    @Test("unknown external-range id no-ops")
    func unknownIDNoop() throws {
        let engine = try AetherEngine()
        engine.selectSubtitleTrack(index: AetherEngine.externalSubtitleTrackIDBase + 7)
        #expect(!engine.isSubtitleActive)
    }

    @Test("secondary channel routes external ids")
    func secondaryExternal() throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(makeTrack())
        engine.selectSecondarySubtitleTrack(index: info.id)
        #expect(engine.isSecondarySubtitleActive)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == info.id)
        #expect(engine.activeSecondaryEmbeddedSubtitleStreamIndex == -1)
    }

    @Test("explicit clear latches hostExplicitSubtitleAction; a late add does not re-enable")
    func lateAddGate() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(preferredSubtitleLanguages: ["de"]))
        engine.clearSubtitle()
        #expect(engine.hostExplicitSubtitleAction)
        _ = engine.addExternalSubtitleTrack(makeTrack())
        #expect(!engine.isSubtitleActive)
    }

    @Test("without an explicit action, a late add matching the preference auto-selects")
    func lateAddAutoSelect() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(preferredSubtitleLanguages: ["de"]))
        let info = engine.addExternalSubtitleTrack(makeTrack())
        #expect(engine.activeSubtitleTrackIndex == info.id)
        #expect(engine.isSubtitleActive)
    }
}

extension ExternalSubtitleSelectionTests {
    @Test("Internal teardown clears active identity but preserves the rebuild registry", .timeLimit(.minutes(3)))
    func teardownIdentity() throws {
        let engine = try AetherEngine()
        let url = URL(fileURLWithPath: "/nonexistent/subtitle.srt")
        let track = engine.addExternalSubtitleTrack(.init(url: url, name: "external"))
        engine.activeSecondaryExternalSubtitleTrackID = track.id
        engine.isSecondarySubtitleActive = true
        engine.stopInternal(resetDisplayCriteria: false)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == nil)
        #expect(engine.externalSubtitleRegistry[track.id] != nil)
        #expect(!engine.isSecondarySubtitleActive)
        engine.stop()
    }

    @Test("Embedded selection removes the old one-shot sidecar URL", .timeLimit(.minutes(3)))
    func embeddedSelectionClearsSidecar() throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.loadedURL = URL(fileURLWithPath: "/nonexistent/movie.mkv")
        engine.loadedSecondarySidecarURL = URL(fileURLWithPath: "/nonexistent/subtitle.srt")
        engine.selectSecondarySubtitleTrack(index: 3)
        #expect(engine.loadedSecondarySidecarURL == nil)
        #expect(engine.activeSecondaryEmbeddedSubtitleStreamIndex == 3)
    }

    @Test("A rebuilt external companion retains its selected container stream", .timeLimit(.minutes(3)))
    func registryStreamRestoration() async throws {
        let url = try MultiSubtitleContainerFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let info = engine.addExternalSubtitleTrack(.init(
            url: url, name: "Spanish", language: "es", httpHeaders: ["X-Test": "track"],
            sourceStreamIndex: MultiSubtitleContainerFixture.spanishStreamIndex))
        engine.selectSecondarySubtitleTrack(index: info.id)
        await engine.secondarySidecarTask?.value
        #expect(engine.secondarySubtitleCues.compactMap(\.text) == MultiSubtitleContainerFixture.spanishLines)
        let savedID = engine.activeSecondaryExternalSubtitleTrackID
        let savedURL = engine.loadedSecondarySidecarURL
        engine.stopInternal(resetDisplayCriteria: false)
        engine.restoreSecondarySubtitleAfterRebuild(externalID: savedID, sidecarURL: savedURL,
                                                    embeddedIndex: -1, startAt: 0)
        await engine.secondarySidecarTask?.value
        #expect(engine.activeSecondaryExternalSubtitleTrackID == info.id)
        #expect(engine.secondarySubtitleCues.compactMap(\.text) == MultiSubtitleContainerFixture.spanishLines)
        #expect(engine.externalSubtitleRegistry[info.id]?.httpHeaders == ["X-Test": "track"])
        engine.removeExternalSubtitleTrack(id: info.id)
        #expect(!engine.isSecondarySubtitleActive)
        #expect(engine.secondarySubtitleCues.isEmpty)
    }
}

extension ExternalSubtitleSelectionTests {
    @Test("A prior load's decode cannot change current cues or loading state", .timeLimit(.minutes(3)))
    func staleDecodeDoesNotPublish() async throws {
        let url = try MultiSubtitleContainerFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let info = engine.addExternalSubtitleTrack(.init(
            url: url, name: "Spanish", sourceStreamIndex: MultiSubtitleContainerFixture.spanishStreamIndex))
        engine.selectSecondarySubtitleTrack(index: info.id)
        let oldTask = engine.secondarySidecarTask
        // Advance ownership without cancellation to exercise the independent generation fence.
        engine.loadGeneration &+= 1
        engine.secondarySubtitleCues = []
        engine.isLoadingSecondarySubtitles = true
        await oldTask?.value
        #expect(engine.secondarySubtitleCues.isEmpty)
        #expect(engine.isLoadingSecondarySubtitles)
    }
}

extension ExternalSubtitleSelectionTests {
    @Test("The same registered track remains selectable in both channels", .timeLimit(.minutes(3)))
    func noDownstreamExclusivityRule() async throws {
        let url = try MultiSubtitleContainerFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let info = engine.addExternalSubtitleTrack(.init(
            url: url, name: "Spanish", sourceStreamIndex: MultiSubtitleContainerFixture.spanishStreamIndex))
        engine.selectSubtitleTrack(index: info.id)
        engine.selectSecondarySubtitleTrack(index: info.id)
        await engine.sidecarTask?.value
        await engine.secondarySidecarTask?.value
        #expect(engine.activeSubtitleTrackIndex == info.id)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == info.id)
        #expect(engine.subtitleCues.compactMap(\.text) == engine.secondarySubtitleCues.compactMap(\.text))
        #expect(!engine.secondarySubtitleCues.isEmpty)
    }
}
