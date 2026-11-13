import Foundation
import Testing
@testable import AetherEngine

// #131: lazy track surfacing keys off the first REAL caption pair; padding-only cc_data (which many
// encoders send continuously with no caption service) must never surface a track.
@Suite("ClosedCaptionTap A53 detection criterion")
@MainActor
struct ClosedCaptionTapA53Tests {

    @Test("Null padding and parity-only bytes are not real caption data")
    func padding() {
        #expect(!ClosedCaptionTap.containsRealCaptionData([]))
        #expect(!ClosedCaptionTap.containsRealCaptionData([.init(d0: 0x00, d1: 0x00)]))
        // 0x80 0x80 is the classic parity-bearing null pad: both bytes strip to 0.
        #expect(!ClosedCaptionTap.containsRealCaptionData([.init(d0: 0x80, d1: 0x80)]))
    }

    @Test("Any non-null pair after parity strip is real caption data")
    func realData() {
        #expect(ClosedCaptionTap.containsRealCaptionData([.init(d0: 0x94, d1: 0x20)]))   // control
        #expect(ClosedCaptionTap.containsRealCaptionData([.init(d0: 0x80, d1: 0xC1)]))   // char pair
        #expect(ClosedCaptionTap.containsRealCaptionData(
            [.init(d0: 0x00, d1: 0x00), .init(d0: 0x94, d1: 0x20)]))
    }

    @Test("Synthetic track id sits between real stream indices and external ids")
    func syntheticID() {
        #expect(AetherEngine.a53ClosedCaptionTrackID == 99_608)
        #expect(AetherEngine.a53ClosedCaptionTrackID < AetherEngine.externalSubtitleTrackIDBase)
    }

    /// Regression for the tap-identity guard: `notifyA53CaptionsDetected` must surface the synthetic
    /// track exactly once, and a stray tap that is never assigned to `engine.closedCaptionTap` (a
    /// torn-down or superseded session's tap) must not resurrect or duplicate it.
    @Test("Detection surfaces the synthetic track exactly once, even across a repeat and a stray tap",
          .timeLimit(.minutes(3)))
    func onceOnlyNotify() async throws {
        let engine = try AetherEngine()
        let tap = ClosedCaptionTap(engine: engine, ccStreamIndex: Int32(AetherEngine.a53ClosedCaptionTrackID))
        engine.closedCaptionTap = tap

        let triplet = CCDataParser.CCTriplet(type: 0, data0: 0x94, data1: 0x20)
        tap.ingestA53Ordered([triplet], ptsSeconds: 1.0)
        tap.ingestA53Ordered([triplet], ptsSeconds: 2.0)

        try await waitFor { engine.subtitleTracks.contains { $0.id == AetherEngine.a53ClosedCaptionTrackID } }
        #expect(engine.subtitleTracks.filter { $0.id == AetherEngine.a53ClosedCaptionTrackID }.count == 1)

        // A tap never assigned as the engine's active tap (stale/torn-down session): its detection
        // notify must be dropped, not resurrect or duplicate the track (Fix 5).
        let strayTap = ClosedCaptionTap(engine: engine, ccStreamIndex: Int32(AetherEngine.a53ClosedCaptionTrackID))

        // Remove the track first to ensure the stray tap's identity guard is what prevents track
        // resurrection, not the dedupe guard that would swallow a duplicate-append anyway.
        engine.subtitleTracks.removeAll { $0.id == AetherEngine.a53ClosedCaptionTrackID }
        strayTap.ingestA53Ordered([triplet], ptsSeconds: 1.0)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!engine.subtitleTracks.contains { $0.id == AetherEngine.a53ClosedCaptionTrackID })
    }
}
