import Foundation
import CoreGraphics
import Testing
@testable import AetherEngine

/// AE#1031: a later subtitle offset needs bitmap history behind the playhead, an earlier one needs
/// cues ahead of it and the forward prefetch that reads the source a second time. One reach for
/// both made a host that wanted 60 s of later offsets pay for that second read.
@MainActor
struct Issue1031SplitOffsetReachTests {

    private func track(id: Int, codec: String) -> TrackInfo {
        TrackInfo(id: id, name: codec, codec: codec, language: nil, isDefault: false)
    }

    @Test("the offset reach sets both directions and reads back the larger one")
    func offsetSetsBoth() throws {
        let engine = try AetherEngine()
        #expect(engine.maximumSubtitleDelaySeconds == 60)
        #expect(engine.maximumSubtitleAdvanceSeconds == 60)
        engine.maximumSubtitleOffsetSeconds = 12
        #expect(engine.maximumSubtitleDelaySeconds == 12)
        #expect(engine.maximumSubtitleAdvanceSeconds == 12)
        engine.maximumSubtitleAdvanceSeconds = 0
        engine.maximumSubtitleDelaySeconds = 40
        #expect(engine.maximumSubtitleOffsetSeconds == 40)
    }

    @Test("negative and non-finite values are ignored per direction")
    func invalidIgnored() throws {
        let engine = try AetherEngine()
        engine.maximumSubtitleDelaySeconds = 7
        engine.maximumSubtitleAdvanceSeconds = 3
        engine.maximumSubtitleDelaySeconds = -1
        engine.maximumSubtitleAdvanceSeconds = .nan
        engine.maximumSubtitleOffsetSeconds = .infinity
        #expect(engine.maximumSubtitleDelaySeconds == 7)
        #expect(engine.maximumSubtitleAdvanceSeconds == 3)
    }

    @Test("declaring one direction alone gives up the history behind the floor")
    func eitherDirectionDeclares() throws {
        let delayOnly = try AetherEngine()
        delayOnly.maximumSubtitleDelaySeconds = 60
        #expect(delayOnly.bitmapCueHistoryByteBudget == 0)
        let advanceOnly = try AetherEngine()
        advanceOnly.maximumSubtitleAdvanceSeconds = 0
        #expect(advanceOnly.bitmapCueHistoryByteBudget == 0)
    }

    @Test("a later reach keeps history without reading ahead")
    func delayReachReadsNothingAhead() throws {
        let engine = try AetherEngine()
        engine.maximumSubtitleAdvanceSeconds = 0
        engine.maximumSubtitleDelaySeconds = 60
        #expect(engine.subtitleAdvanceReach == 0)
        #expect(engine.bitmapSubtitleHistoryReach == 60)
        engine.subtitleTracks = [track(id: 4, codec: "hdmv_pgs_subtitle")]
        #expect(engine.subtitleDrainLead(for: .primary, streamIndex: 4) == 15)
        #expect(AetherEngine.bitmapCueFloorSeconds(offsetReach: engine.bitmapSubtitleHistoryReach) == 60)
    }

    @Test("an earlier reach sizes the lead and leaves the history at the minimum")
    func advanceReachLeadsOnly() throws {
        let engine = try AetherEngine()
        engine.maximumSubtitleDelaySeconds = 0
        engine.maximumSubtitleAdvanceSeconds = 30
        engine.subtitleTracks = [track(id: 4, codec: "hdmv_pgs_subtitle")]
        #expect(engine.subtitleDrainLead(for: .primary, streamIndex: 4) == 30)
        #expect(AetherEngine.bitmapCueFloorSeconds(offsetReach: engine.bitmapSubtitleHistoryReach) == 15)
    }

    @Test("a later reach stops a running prefetch, an earlier one starts it again")
    func onlyAdvanceDrivesPrefetch() throws {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        engine.softwareSubtitlePacketStore = SubtitlePacketStore()
        engine.subtitleDrainTargets[.primary] = 3
        engine.subtitleForwardPrefetchTask = Task {}
        engine.maximumSubtitleAdvanceSeconds = 0
        engine.maximumSubtitleDelaySeconds = 60
        #expect(engine.subtitleForwardPrefetchTask == nil)
        #expect(engine.lastSubtitleDrainStopReason == .noAdvanceReach)
        engine.maximumSubtitleAdvanceSeconds = 5
        #expect(engine.subtitleForwardPrefetchTask != nil)
    }

    @Test("the reporter's cues 7 and 12 s survive at 32 s under a later reach of 60")
    func reporterHistorySurvives() throws {
        let engine = try AetherEngine()
        engine.maximumSubtitleAdvanceSeconds = 0
        engine.maximumSubtitleDelaySeconds = 60
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = SubtitleImage(cgImage: ctx.makeImage()!, position: .zero)
        var cues = stride(from: 2.0, to: 48, by: 5).enumerated().map {
            SubtitleCue(id: $0.offset, startTime: $0.element, endTime: $0.element + 3, body: .image(image))
        }
        let playhead = 32.0
        _ = AetherEngine.pruneCues(&cues, toBitmapBytes: engine.bitmapCueHistoryByteBudget,
                                   endedBefore: playhead - AetherEngine.bitmapCueFloorSeconds(
                                       offsetReach: engine.bitmapSubtitleHistoryReach))
        #expect(cues.contains { $0.startTime == 7 })
        #expect(cues.contains { $0.startTime == 12 })
    }
}
