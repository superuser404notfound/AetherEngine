import Foundation
import Testing
@testable import AetherEngine

@Suite(.serialized, .timeLimit(.minutes(3)))
struct BackgroundScrubPreviewOptionTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ladder-option-\(UUID()).mp4")
        try ScrubLadderFixture.data.write(to: url)
        return url
    }

    @Test func defaultAndReloadClassification() {
        let original = LoadOptions()
        #expect(original.generatesBackgroundScrubPreviews)
        let changed = LoadOptions(generatesBackgroundScrubPreviews: false)
        #expect(SessionOptionCorrection.refusedFields(from: original, to: changed).isEmpty)
        #expect(SessionOptionCorrection.changedFields(from: original, to: changed) == ["generatesBackgroundScrubPreviews"])
    }

    @Test(.offCooperativePool) func disabledLadderCannotCreateOrReadItsSource() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        for enabled in [true, false] {
            let session = HLSVideoEngine(url: url, dvModeAvailable: false)
            session.generatesBackgroundScrubPreviews = enabled
            session.requestIFramePlaylist()
            _ = try session.start()
            defer { session.stop() }
            try #require(session.planBoundariesClaimRandomAccess)
            try #require(session.segmentPlan.count > 1)
            // Exercise the actual side-reader constructor and payload read, not only a policy flag.
            let source = session.makeStillLadderSource(plan: session.segmentPlan)
            if enabled {
                let source = try #require(source)
                #expect(source.keyframes.keyframePayload(at: 1)?.isEmpty == false)
            } else {
                #expect(source == nil)
                session.stillLadderTick(playheadPlaylistSeconds: 0, forwardBufferSeconds: 120)
                #expect(session.stillLadderFrame(atSeconds: 0) == nil)
            }
            // The independent, explicitly requested I-frame reader remains usable in either case.
            #expect(session.iFrameRenditionVerdict == .served)
            #expect(session.provider?.iFrameSegment(at: 1)?.isEmpty == false)
            let plan = session.segmentPlan
            session.stop()
            #expect(session.makeStillLadderSource(plan: plan) == nil)
            #expect(session.stillLadderFrame(atSeconds: 0) == nil)
            if let source {
                try await waitFor { source.keyframes.keyframePayload(at: 1) == nil }
            }
        }
    }

    @MainActor
    @Test func optionReachesLoadAndReplacementSession() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        try await engine.load(url: url, options: LoadOptions(generatesBackgroundScrubPreviews: false, autoplay: false))
        let first = try #require(engine.nativeVideoSession)
        #expect(!first.generatesBackgroundScrubPreviews)
        try await engine.reloadAtCurrentPosition { $0.generatesBackgroundScrubPreviews = true }
        let second = try #require(engine.nativeVideoSession)
        #expect(second !== first)
        #expect(second.generatesBackgroundScrubPreviews)
        #expect(engine.state != .playing)
        try await engine.reloadAtCurrentPosition { $0.generatesBackgroundScrubPreviews = false }
        #expect(engine.nativeVideoSession?.generatesBackgroundScrubPreviews == false)
    }
}
