import Foundation
import Testing
@testable import AetherEngine

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct SecondarySidecarReplacementTests {
    private func text(_ value: String = "replacement") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replace-\(UUID()).srt")
        try "1\n00:00:10,000 --> 00:00:12,000\n\(value)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    private func player() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.clock.sourceTime = 11
        engine.loadedURL = URL(fileURLWithPath: "/nonexistent/media.mkv")
        engine.state = .paused
        return engine
    }
    private func finish(_ engine: AetherEngine) async {
        await engine.secondarySidecarTask?.value
        while let tick = engine.subtitleDrainTickInFlight { await tick.value }
    }

    @Test func failedBitmapReplacementKeepsSourceAndSuccessfulTextReleasesIt() async throws {
        let url = try Issue921SidecarBitmapDrainTests.writeSup(sets: 20)
        let textURL = try text()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: textURL) }
        let engine = try player()
        defer { engine.stop() }
        let original = engine.registerExternalSubtitleTrack(.init(url: url))
        engine.selectSecondarySubtitleTrack(index: original.id)
        await finish(engine)
        weak var source = engine.sidecarBitmapSources[.secondary]
        try #require(source != nil)
        #expect(!engine.secondarySubtitleCues.isEmpty)
        let missing = engine.registerExternalSubtitleTrack(.init(url: textURL.appendingPathExtension("missing")))
        engine.selectSecondarySubtitleTrack(index: missing.id)
        #expect(engine.sidecarBitmapSources[.secondary] === source)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == original.id)
        await finish(engine)
        #expect(engine.sidecarBitmapSources[.secondary] === source)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == original.id)
        #expect(!engine.isLoadingSecondarySubtitles)
        #expect(engine.pendingSecondaryExternalSubtitleTrackID == nil)
        // Failure did not merely retain a picture: the old packet source can still answer a seek.
        engine.clock.sourceTime = 51
        engine.requestSubtitleDrainTick()
        await finish(engine)
        #expect(engine.secondarySubtitleCues.contains { $0.startTime <= 51 && $0.endTime > 51 })
        let next = engine.registerExternalSubtitleTrack(.init(url: textURL))
        engine.selectSecondarySubtitleTrack(index: next.id)
        await finish(engine)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == next.id)
        #expect(engine.sidecarBitmapSources[.secondary] == nil)
        #expect(source == nil, "old source has no remaining owner after commit/drain completion")
        #expect(engine.secondarySubtitleCues.compactMap(\.text) == ["replacement"])
    }

    @Test func textToBitmapAndDecoderFailureAreTransactional() async throws {
        let bitmap = try Issue921SidecarBitmapDrainTests.writeSup(sets: 4)
        let url = try text("old text")
        defer { try? FileManager.default.removeItem(at: bitmap); try? FileManager.default.removeItem(at: url) }
        let engine = try player()
        defer { engine.stop() }
        let old = engine.registerExternalSubtitleTrack(.init(url: url))
        let next = engine.registerExternalSubtitleTrack(.init(url: bitmap))
        engine.selectSecondarySubtitleTrack(index: old.id)
        await finish(engine)
        #if DEBUG
        engine.secondarySidecarDecoderFactoryForTesting = { _ in nil }
        engine.selectSecondarySubtitleTrack(index: next.id)
        await finish(engine)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == old.id)
        #expect(engine.secondarySubtitleCues.compactMap(\.text) == ["old text"])
        #expect(!engine.isLoadingSecondarySubtitles)
        #expect(engine.pendingSecondaryExternalSubtitleTrackID == nil)
        engine.secondarySidecarDecoderFactoryForTesting = nil
        #endif
        engine.selectSecondarySubtitleTrack(index: next.id)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == old.id)
        await finish(engine)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == next.id)
        #expect(engine.sidecarBitmapSources[.secondary] != nil)
        #expect(engine.secondarySubtitleCues.contains { if case .image = $0.body { true } else { false } })
        engine.clearSecondarySubtitle()
        #expect(engine.sidecarBitmapSources[.secondary] == nil)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == nil)
    }

    @Test(arguments: ["clear", "stop", "remove", "embedded", "newLoad"])
    func pendingCandidateCannotResurrectAfterInvalidation(_ action: String) async throws {
        let url = try text()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try player()
        defer { engine.stop() }
        let next = engine.registerExternalSubtitleTrack(.init(url: url))
        engine.selectSecondarySubtitleTrack(index: next.id)
        let pending = engine.secondarySidecarTask
        switch action {
        case "clear": engine.clearSecondarySubtitle()
        case "stop": engine.stop()
        case "remove": engine.removeExternalSubtitleTrack(id: next.id)
        case "embedded": engine.selectSecondarySubtitleTrack(index: 2)
        default:
            try await engine.load(source: .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4"),
                                  options: LoadOptions(autoplay: false, preferredDecodePath: .software))
        }
        await pending?.value
        #expect(engine.activeSecondaryExternalSubtitleTrackID == nil)
        #expect(engine.loadedSecondarySidecarURL == nil)
        #expect(engine.secondarySubtitleCues.isEmpty)
        #expect(!engine.isLoadingSecondarySubtitles)
        #expect(engine.pendingSecondaryExternalSubtitleTrackID == nil)
        if action == "embedded" { #expect(engine.activeSecondaryEmbeddedSubtitleStreamIndex == 2) }
    }

    @Test func rapidReplacementAndPreparedCommitWinOverCancelledCandidates() async throws {
        let a = try text("A"), b = try text("B")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let engine = try player()
        defer { engine.stop() }
        let first = engine.registerExternalSubtitleTrack(.init(url: a))
        let second = engine.registerExternalSubtitleTrack(.init(url: b))
        let prepared = try await engine.prepareExternalSubtitle(id: second.id)
        engine.selectSecondarySubtitleTrack(index: first.id)
        let cancelled = engine.secondarySidecarTask
        engine.selectSecondarySubtitleTrack(index: second.id)
        await finish(engine)
        await cancelled?.value
        #expect(engine.activeSecondaryExternalSubtitleTrackID == second.id)
        #expect(engine.secondarySubtitleCues.compactMap(\.text) == ["B"])
        // Selection invalidates a preparation made before it; it cannot roll the transaction back.
        #expect(throws: ExternalSubtitlePreparationError.stale) {
            try engine.commitExternalSubtitle(prepared, secondary: true)
        }
        let current = try await engine.prepareExternalSubtitle(id: first.id)
        // An internal restore can start a candidate without replacing the host's explicit intent.
        engine.selectSecondarySubtitleTrack(index: second.id, startAt: 11)
        let oldDecode = engine.secondarySidecarTask
        _ = try engine.commitExternalSubtitle(current, secondary: true)
        await oldDecode?.value
        #expect(engine.activeSecondaryExternalSubtitleTrackID == first.id)
        #expect(engine.secondarySubtitleCues.compactMap(\.text) == ["A"])
    }

    @Test func oneShotURLStillReplacesOnStart() async throws {
        let url = try text()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try player()
        defer { engine.stop() }
        let old = engine.registerExternalSubtitleTrack(.init(url: url))
        engine.selectSecondarySubtitleTrack(index: old.id)
        await finish(engine)
        engine.selectSecondarySidecarSubtitle(url: url.appendingPathExtension("missing"))
        #expect(engine.activeSecondaryExternalSubtitleTrackID == nil)
        #expect(engine.secondarySubtitleCues.isEmpty)
        await finish(engine)
        #expect(engine.isSecondarySubtitleActive)
        #expect(!engine.isLoadingSecondarySubtitles)
        #expect(engine.pendingSecondaryExternalSubtitleTrackID == nil)
    }
    @Test func pendingSelectionSurvivesBothSnapshotPathsAndRepeatedRestore() async throws {
        let a = try text("A"), b = try text("B")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let engine = try player()
        defer { engine.stop() }
        let old = engine.registerExternalSubtitleTrack(.init(url: a))
        let next = engine.registerExternalSubtitleTrack(.init(url: b))
        engine.selectSecondarySubtitleTrack(index: old.id)
        await finish(engine)
        engine.selectSecondarySubtitleTrack(index: next.id)
        // No yield: the candidate cannot have completed, just as during a slow fetch.
        #expect(engine.activeSecondaryExternalSubtitleTrackID == old.id)
        #expect(engine.pendingSecondaryExternalSubtitleTrackID == next.id)
        for _ in 0..<2 {
            let audioSnapshot = engine.secondarySelectionForRebuild
            let carryover = engine.captureSubtitleSessionCarryover()
            #expect(audioSnapshot.externalID == next.id)
            #expect(audioSnapshot.sidecarURL == b)
            #expect(carryover.secondaryTrackIndex == next.id)
            engine.stopInternal(resetDisplayCriteria: false)
            #expect(engine.pendingSecondaryExternalSubtitleTrackID == nil)
            engine.restoreSecondarySubtitleAfterRebuild(externalID: audioSnapshot.externalID,
                sidecarURL: audioSnapshot.sidecarURL, embeddedIndex: audioSnapshot.embeddedIndex, startAt: 11)
            #expect(engine.activeSecondaryExternalSubtitleTrackID == nil)
            #expect(engine.pendingSecondaryExternalSubtitleTrackID == next.id)
        }
        await finish(engine)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == next.id)
        #expect(engine.pendingSecondaryExternalSubtitleTrackID == nil)
        #expect(engine.secondarySubtitleCues.compactMap(\.text) == ["B"])
    }

    @Test func pendingPickSurvivesActualSessionReload() async throws {
        let url = try text()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await engine.load(source: .custom(DataIOReader(data: try ProbeTestFixtures.hdr10Plus()), formatHint: "mp4"),
                              options: LoadOptions(autoplay: false, preferredDecodePath: .software))
        let next = engine.registerExternalSubtitleTrack(.init(url: url))
        engine.selectSecondarySubtitleTrack(index: next.id)
        try await engine.reloadAtCurrentPosition()
        await finish(engine)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == next.id)
        #expect(engine.pendingSecondaryExternalSubtitleTrackID == nil)
        #expect(engine.secondarySubtitleCues.compactMap(\.text) == ["replacement"])
    }

}
