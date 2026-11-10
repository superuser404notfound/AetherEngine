import Foundation
import Testing
@testable import AetherEngine

/// AE#1015 (samimt55): selecting an embedded subtitle on a remote source doubled the bytes read
/// (104.5 MB against 243.6 MB for a minute of 1080p MKV, the same for MP4), because the #151
/// forward prefetch is a second reader of the interleaved stream. Its cues only serve an advance
/// offset or the OCR worker, so a host that declared no offset reach no longer pays for it.
@MainActor
struct Issue1015PrefetchAdvanceReachTests {

    private func engineWithLivePrefetcher() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        engine.softwareSubtitlePacketStore = SubtitlePacketStore()
        engine.subtitleDrainTargets[.primary] = 3
        engine.subtitleForwardPrefetchTask = Task {}
        return engine
    }

    @Test("no advance reach and no OCR worker means no prefetch, either one brings it back")
    func gating() {
        #expect(!AetherEngine.shouldRunSubtitleForwardPrefetch(
            isLive: false, hasEmbeddedDrainTargets: true, hasSource: true,
            advanceReach: 0, ocrArmed: false))
        #expect(AetherEngine.shouldRunSubtitleForwardPrefetch(
            isLive: false, hasEmbeddedDrainTargets: true, hasSource: true,
            advanceReach: 0, ocrArmed: true))
        #expect(AetherEngine.shouldRunSubtitleForwardPrefetch(
            isLive: false, hasEmbeddedDrainTargets: true, hasSource: true,
            advanceReach: 2, ocrArmed: false))
    }

    @Test("the default reach keeps today's prefetch")
    func defaultReachReadsAhead() throws {
        let engine = try AetherEngine()
        #expect(engine.subtitleAdvanceReach == AetherEngine.subtitleCueBitmapFloorSeconds)
    }

    @Test("only a negative software delay reads ahead")
    func softwareDelaySign() throws {
        let engine = try AetherEngine()
        engine.maximumSubtitleOffsetSeconds = 0
        #expect(engine.subtitleAdvanceReach == 0)
        engine.setSoftwareSubtitleDelay(4)
        #expect(engine.subtitleAdvanceReach == 0)
        engine.setSoftwareSubtitleDelay(-4)
        #expect(engine.subtitleAdvanceReach == 4)
    }

    @Test("declaring zero reach mid-session stops a running prefetch under its own reason")
    func zeroReachStopsRunningPrefetch() throws {
        let engine = try engineWithLivePrefetcher()
        engine.maximumSubtitleOffsetSeconds = 0
        #expect(engine.subtitleForwardPrefetchTask == nil)
        #expect(engine.lastSubtitleDrainStopReason == .noAdvanceReach)
    }

    @Test("a positive delay keeps it stopped, a negative one starts it, zero stops it again")
    func softwareDelayStartsAndStops() throws {
        let engine = try engineWithLivePrefetcher()
        engine.maximumSubtitleOffsetSeconds = 0
        engine.setSoftwareSubtitleDelay(3)
        #expect(engine.subtitleForwardPrefetchTask == nil)
        engine.setSoftwareSubtitleDelay(-3)
        #expect(engine.subtitleForwardPrefetchTask != nil)
        engine.setSoftwareSubtitleDelay(0)
        #expect(engine.subtitleForwardPrefetchTask == nil)
        #expect(engine.lastSubtitleDrainStopReason == .noAdvanceReach)
    }

    @Test("without an embedded drain target a reach change starts nothing")
    func noTargetNoStart() throws {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        engine.maximumSubtitleOffsetSeconds = 0
        engine.maximumSubtitleOffsetSeconds = 10
        #expect(engine.subtitleForwardPrefetchTask == nil)
    }
}
