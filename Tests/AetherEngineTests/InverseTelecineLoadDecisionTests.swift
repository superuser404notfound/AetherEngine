import Testing
import Foundation
@testable import AetherEngine

/// #853: the load decides inverse telecine before it asks the display for a rate, and the session keeps
/// that decision through every rebuild, so the panel's refresh rate never moves mid-session. On macOS the
/// criteria write does nothing, so the requested rate is read off `lastRequestedDisplayRate`.
@Suite("Inverse telecine load decision", .timeLimit(.minutes(3)))
@MainActor
struct InverseTelecineLoadDecisionTests {

    private func writeFixture(_ data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ivtc-\(UUID().uuidString).mkv")
        try data.write(to: file)
        return file
    }

    private func load(_ data: Data, mode: InverseTelecineMode = .auto) async throws -> (AetherEngine, URL) {
        let file = try writeFixture(data)
        let engine = try AetherEngine()
        var options = LoadOptions()
        options.autoplay = false
        options.inverseTelecine = mode
        _ = try await engine.load(url: file, options: options)
        return (engine, file)
    }

    @Test("hard-telecined film plays inverse telecined at 23.976 and a rebuild keeps it without a new sample")
    func filmEngagesAndRebuildsKeepIt() async throws {
        let (engine, file) = try await load(TelecineCadenceFixtures.telecinedFilm)
        defer { engine.stop(); try? FileManager.default.removeItem(at: file) }
        #expect(engine.lastInverseTelecineVerdict?.isFilm == true, "\(String(describing: engine.lastInverseTelecineVerdict))")
        #expect(engine.lastInverseTelecine)
        #expect(engine.lastRequestedDisplayRate == 23.976)
        #expect(engine.sourceVideoFrameRate.map { abs($0 - 29.97) < 0.01 } == true, "the source rate stays the source's")
        try await waitFor { engine.decodedVideoFormat?.deinterlace?.inverseTelecine == true }
        #expect(engine.decodedVideoFormat?.deinterlace?.outputFrameRateFactor == 0.8)

        try await engine.reloadAtCurrentPosition()
        #expect(engine.lastInverseTelecine, "the rebuild carries the session's decision")
        #expect(engine.lastInverseTelecineVerdict == nil, "and samples nothing")
        #expect(engine.lastRequestedDisplayRate == 23.976)

        engine.stop()
        #expect(!engine.lastInverseTelecine)
    }

    @Test("an audio-override rebuild keeps the decision")
    func audioOverrideRebuildKeepsIt() async throws {
        let (engine, file) = try await load(TelecineCadenceFixtures.telecinedFilm)
        defer { engine.stop(); try? FileManager.default.removeItem(at: file) }
        #expect(engine.lastInverseTelecine)
        let failure = await engine.reloadWithAudioOverride(
            url: file, audioStreamIndex: nil, expectedGeneration: engine.loadGeneration)
        #expect(failure == nil)
        #expect(engine.lastInverseTelecine)
        try await waitFor { engine.decodedVideoFormat?.deinterlace?.inverseTelecine == true }
    }

    @Test("a custom-source rebuild keeps the decision")
    func customSourceRebuildKeepsIt() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.autoplay = false
        _ = try await engine.load(source: .custom(DataIOReader(data: TelecineCadenceFixtures.telecinedFilm),
                                                  formatHint: "matroska"), options: options)
        #expect(engine.lastInverseTelecine)
        try await engine.reloadAtCurrentPosition()
        #expect(engine.lastInverseTelecine)
    }

    @Test("the carryover is consumed by the rebuild that used it, so a later load decides afresh")
    func carryoverDoesNotOutliveItsLoad() async throws {
        let (engine, file) = try await load(TelecineCadenceFixtures.telecinedFilm)
        defer { engine.stop(); try? FileManager.default.removeItem(at: file) }
        try await engine.reloadAtCurrentPosition()
        #expect(engine.lastInverseTelecine)
        #expect(engine.loadedOptions.inverseTelecineCarryover == nil)
    }

    @Test("a custom-source title switch samples the new title instead of inheriting the decision")
    func customTitleSwitchDecidesAfresh() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.autoplay = false
        _ = try await engine.load(source: .custom(DataIOReader(data: TelecineCadenceFixtures.telecinedFilm),
                                                  formatHint: "matroska"), options: options)
        #expect(engine.lastInverseTelecine)
        // The title identity is all a disc adds to this decision, as in Issue232InterlaceProbeTests.
        engine.activeDiscTitleID = 11
        let url = try #require(engine.loadedURL)
        let error = await engine.reloadWithAudioOverride(
            url: url, audioStreamIndex: nil, expectedGeneration: engine.loadGeneration,
            discTitleIDOverride: 12)
        #expect(error == nil)
        #expect(engine.lastInverseTelecineVerdict?.isFilm == true,
                "another title is another stream, sampled: \(String(describing: engine.lastInverseTelecineVerdict))")
        #expect(engine.lastInverseTelecine)

        // A same-title rebuild keeps the decision without a sample.
        try await engine.reloadAtCurrentPosition()
        #expect(engine.lastInverseTelecineVerdict == nil)
        #expect(engine.lastInverseTelecine)
    }

    @Test("a correction with a session up costs no rebuild but reaches the loads the engine makes later")
    func correctionIsKeptForLaterLoads() async throws {
        let (engine, file) = try await load(TelecineCadenceFixtures.telecinedFilm)
        defer { engine.stop(); try? FileManager.default.removeItem(at: file) }
        let outcome = try await engine.reloadAtCurrentPosition { $0.inverseTelecine = .off }
        #expect(!outcome.rebuilt)
        #expect(outcome.sessionOwned == ["inverseTelecine"])
        #expect(engine.lastInverseTelecine, "the running session keeps its decision")
        #expect(engine.loadedOptions.inverseTelecine == .off)
    }

    @Test("an audio-only load is never sampled")
    func audioOnlyIsNotSampled() async throws {
        let file = try writeFixture(TelecineCadenceFixtures.telecinedFilm)
        let engine = try AetherEngine()
        defer { engine.stop(); try? FileManager.default.removeItem(at: file) }
        var options = LoadOptions()
        options.autoplay = false
        options.audioOnly = true
        _ = try? await engine.load(url: file, options: options)
        #expect(engine.lastInverseTelecineVerdict == nil)
        #expect(!engine.lastInverseTelecine)
    }

    @Test("a restore after a background teardown rebuilds even when it only corrects inverseTelecine")
    func backgroundRestoreWithLoadDecidedFieldRebuilds() async throws {
        let (engine, file) = try await load(TelecineCadenceFixtures.telecinedFilm)
        defer { engine.stop(); try? FileManager.default.removeItem(at: file) }
        #expect(engine.lastInverseTelecine)
        engine.releaseVideoPipelineForBackground()
        #expect(engine.backgroundTeardownSelection != nil)
        let outcome = try await engine.reloadAtCurrentPosition { $0.inverseTelecine = .off }
        #expect(outcome.rebuilt, "the restore is this call; returning early leaves no picture")
        #expect(outcome.sessionOwned == ["inverseTelecine"])
        #expect(engine.playbackBackend == .software)
        #expect(engine.lastInverseTelecine, "the parked decision comes back with the session")
    }

    @Test("interlaced video keeps the deinterlacer and its rate")
    func videoKeepsTheDeinterlacer() async throws {
        let (engine, file) = try await load(TelecineCadenceFixtures.interlacedVideo)
        defer { engine.stop(); try? FileManager.default.removeItem(at: file) }
        guard case .video = engine.lastInverseTelecineVerdict else {
            Issue.record("expected a video verdict, got \(String(describing: engine.lastInverseTelecineVerdict))")
            return
        }
        #expect(!engine.lastInverseTelecine)
        #expect(engine.lastRequestedDisplayRate == 29.97)
        try await waitFor { engine.decodedVideoFormat?.deinterlace != nil }
        #expect(engine.decodedVideoFormat?.deinterlace?.inverseTelecine == false)
    }

    @Test("off deinterlaces film as before, without a sample")
    func offDeinterlacesFilm() async throws {
        let (engine, file) = try await load(TelecineCadenceFixtures.telecinedFilm, mode: .off)
        defer { engine.stop(); try? FileManager.default.removeItem(at: file) }
        #expect(engine.lastInverseTelecineVerdict == nil)
        #expect(!engine.lastInverseTelecine)
        #expect(engine.lastRequestedDisplayRate == 29.97)
    }

    @Test("force matches fields without a sample, even on interlaced video")
    func forceSkipsTheSample() async throws {
        let (engine, file) = try await load(TelecineCadenceFixtures.interlacedVideo, mode: .force)
        defer { engine.stop(); try? FileManager.default.removeItem(at: file) }
        #expect(engine.lastInverseTelecineVerdict == nil)
        #expect(engine.lastInverseTelecine)
        #expect(engine.lastRequestedDisplayRate == 23.976)
    }

    @Test("a progressive source is never sampled")
    func progressiveIsNotSampled() async throws {
        let (engine, file) = try await load(TelecineCadenceFixtures.progressive)
        defer { engine.stop(); try? FileManager.default.removeItem(at: file) }
        #expect(engine.lastInverseTelecineVerdict == nil)
        #expect(!engine.lastInverseTelecine)
    }
}

/// #853: a correction of `inverseTelecine` through `reloadAtCurrentPosition(applying:)` is reported, not
/// applied: the load decided it together with the display rate, and a rebuild keeps both.
@Suite("Inverse telecine option correction")
struct InverseTelecineOptionCorrectionTests {

    @Test("the field is the load's, with or without a transport")
    func partitionReportsTheLoadsField() {
        let withTransport = SessionOptionCorrection.partitionChanges(
            ["inverseTelecine", "audioDelaySeconds", "autoplay"], sessionOwnsTransport: true)
        #expect(withTransport.applied == ["audioDelaySeconds"])
        #expect(withTransport.sessionOwned == ["autoplay"])
        #expect(withTransport.loadDecided == ["inverseTelecine"])
        let tornDown = SessionOptionCorrection.partitionChanges(
            ["inverseTelecine", "autoplay"], sessionOwnsTransport: false)
        #expect(tornDown.applied == ["autoplay"])
        #expect(tornDown.loadDecided == ["inverseTelecine"])
    }

    @Test("the load-decided list names real fields and no identity or session-owned one")
    func inventoryHolds() {
        for field in SessionOptionCorrection.loadDecidedFields {
            #expect(SessionOptionCorrection.knownFields.contains(field))
            #expect(!SessionOptionCorrection.loadIdentityFields.contains(field))
            #expect(!SessionOptionCorrection.sessionOwnedFields.contains(field))
        }
    }

    @Test("the decision needs a graph that can run: a stated rate and the filters")
    func unbuildableIsRefusedBeforeTheDecision() {
        #expect(AetherEngine.inverseTelecineUnbuildable(rate: DeinterlaceConfig.SourceFrameRate()) != nil)
        #expect(AetherEngine.inverseTelecineUnbuildable(
            rate: DeinterlaceConfig.SourceFrameRate(num: 30000, den: 1001)) == nil)
    }

    @Test("inverse telecine is on by default, decided per load")
    func defaultIsAuto() {
        #expect(LoadOptions().inverseTelecine == .auto)
        #expect(LoadOptions().inverseTelecineCarryover == nil)
    }
}
