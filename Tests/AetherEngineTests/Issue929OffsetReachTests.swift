import Foundation
import Testing
@testable import AetherEngine

/// AE#929: a bitmap channel keeps its decoded RGBA sized by the host's declared subtitle offset
/// reach instead of a fixed 60 s on each side. On the reporter's dense PGS title the fixed floor
/// and lead held 360 images that a PNG-backed history kept 110 MB smaller, while the host applies
/// no offset at all.
@MainActor
struct Issue929OffsetReachTests {

    private func track(id: Int, codec: String) -> TrackInfo {
        TrackInfo(id: id, name: codec, codec: codec, language: nil, isDefault: false)
    }

    @Test("the default reach keeps the floor and lead that shipped with AE#879")
    func defaultUnchanged() throws {
        let engine = try AetherEngine()
        #expect(engine.maximumSubtitleOffsetSeconds == AetherEngine.subtitleCueBitmapFloorSeconds)
        #expect(AetherEngine.bitmapCueFloorSeconds(offsetReach: engine.bitmapSubtitleOffsetReach) == 60)
        #expect(AetherEngine.subtitleDrainLead(isBitmap: true, offsetReach: engine.bitmapSubtitleOffsetReach)
                == AetherEngine.subtitleDrainLeadSeconds)
    }

    @Test("no offset shrinks both bitmap edges to the minimum, never below it")
    func zeroReachUsesMinimum() {
        #expect(AetherEngine.bitmapCueFloorSeconds(offsetReach: 0) == 15)
        #expect(AetherEngine.subtitleDrainLead(isBitmap: true, offsetReach: 0) == 15)
        #expect(AetherEngine.bitmapCueFloorSeconds(offsetReach: 10) == 15)
        #expect(AetherEngine.subtitleDrainLead(isBitmap: true, offsetReach: 30) == 30)
    }

    @Test("a reach past the drain lead extends the floor but not the lead")
    func largeReach() {
        #expect(AetherEngine.bitmapCueFloorSeconds(offsetReach: 120) == 120)
        #expect(AetherEngine.subtitleDrainLead(isBitmap: true, offsetReach: 120)
                == AetherEngine.subtitleDrainLeadSeconds)
    }

    @Test("a text channel keeps the full lead whatever the reach")
    func textUnaffected() throws {
        #expect(AetherEngine.subtitleDrainLead(isBitmap: false, offsetReach: 0)
                == AetherEngine.subtitleDrainLeadSeconds)
        let engine = try AetherEngine()
        engine.maximumSubtitleOffsetSeconds = 0
        engine.subtitleTracks = [track(id: 3, codec: "subrip"), track(id: 4, codec: "hdmv_pgs_subtitle")]
        #expect(engine.subtitleDrainLead(for: .primary, streamIndex: 3) == AetherEngine.subtitleDrainLeadSeconds)
        #expect(engine.subtitleDrainLead(for: .primary, streamIndex: 4) == 15)
    }

    @Test("the software PiP delay is covered even when the host declared less")
    func softwareDelayWidensReach() throws {
        let engine = try AetherEngine()
        engine.maximumSubtitleOffsetSeconds = 0
        engine.setSoftwareSubtitleDelay(-25)
        #expect(engine.bitmapSubtitleOffsetReach == 25)
    }

    @Test("negative and non-finite reaches are ignored")
    func invalidIgnored() throws {
        let engine = try AetherEngine()
        engine.maximumSubtitleOffsetSeconds = 5
        engine.maximumSubtitleOffsetSeconds = -1
        engine.maximumSubtitleOffsetSeconds = .nan
        engine.maximumSubtitleOffsetSeconds = .infinity
        #expect(engine.maximumSubtitleOffsetSeconds == 5)
    }

    @Test("a reach shrunk mid-session leaves the cursor's decoded lead alone until playback reaches it")
    func shrinkIsIdleNotReset() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 160, lastPlayhead: 100)
        let plan = SubtitleOverlayDrainer.drainPlan(
            cursor: cursor, playhead: 100.5,
            lead: AetherEngine.subtitleDrainLead(isBitmap: true, offsetReach: 0),
            backscan: AetherEngine.subtitleDrainBackscanSeconds,
            jumpThreshold: AetherEngine.subtitleDrainJumpThresholdSeconds)
        #expect(plan == .idle)
    }
}
