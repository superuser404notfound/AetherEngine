import Testing
import Foundation
@testable import AetherEngine

/// #1021: a pair whose span the ledger counts as read is not a hole, whatever its order says.
///
/// A track selected at load starts the forward prefetch with the session. The prefetch stores the
/// next 75 s first, then the main reader reads each of those packets again a few seconds ahead of
/// the playhead, and a re-harvest takes the fresh sequence (#362). Every pair at the main reader's
/// front therefore descends in sequence, and the order rule read each one as a hole: the drain
/// decoded one packet per release and never got more than about 4 s ahead (reported and measured
/// with `aetherctl play --sw --subs srt --host-calls subsatload`), so a host's advance offset
/// showed nothing. The ledger saw the prefetch read all of it.
@Suite("#1021: the ledger outranks harvest order")
struct Issue1021LedgerReadPairTests {

    /// The store as the reported session leaves it at a playhead of 0.73 s: the prefetch has read
    /// 0..77 s (cues every 5 s from 2 s), then the main reader re-harvested the cues at 2 and 7 s.
    private func reportedStore() -> SubtitlePacketStore {
        let store = SubtitlePacketStore()
        store.noteHarvestAnchor(.prefetch, at: 0)
        for n in 0..<16 {
            let pts = 2.0 + Double(n) * 5
            store.append(streamIndex: 2, ptsSeconds: pts, durationSeconds: 3, payload: payload(pts))
            store.noteHarvestProgress(.prefetch, through: pts)
        }
        store.noteHarvestAnchor(.pump, at: 0)
        for pts in [2.0, 7.0] {
            store.append(streamIndex: 2, ptsSeconds: pts, durationSeconds: 3, payload: payload(pts))
        }
        store.noteHarvestReach(.pump, through: 0.73)
        return store
    }

    private func payload(_ pts: Double) -> Data { Data("cue \(pts)".utf8) }

    @Test("the main reader's re-harvest over the prefetch's run is decoded through")
    func reharvestOverReadGroundIsNotAHole() throws {
        let store = reportedStore()
        let entries = store.entries(streamIndex: 2, from: 2.0, through: 61.0)
        // The window past the cursor on the cue at 2 s: 7 s carries the main reader's newer
        // sequence, 12 s and on the prefetch's older ones.
        let window = Array(entries.dropFirst())
        let cursor = try #require(entries.first)
        #expect(window[0].sequence > window[1].sequence)
        let step = SubtitleOverlayDrainer.harvestGapStep(
            count: window.count, ptsAt: { window[$0].ptsSeconds },
            sequenceAt: { window[$0].sequence },
            held: nil, resumeFrom: (cursor.ptsSeconds, cursor.sequence), isReset: false,
            releaseAt: 0.73 + AetherEngine.subtitleDrainHarvestGapReleaseLeadSeconds,
            isRead: store.harvestReadCheck())
        #expect(step.decodeEnd == window.count)
        #expect(step.hold == nil)
    }

    @Test("a hold left by an earlier build of the rule resumes on read ground")
    func holdOnReadGroundResumes() {
        let store = reportedStore()
        let window = store.entries(streamIndex: 2, from: 12.0, through: 61.0)
        let held = SubtitleOverlayDrainer.HarvestGapHold(at: 7.0, sequence: 18)
        let step = SubtitleOverlayDrainer.harvestGapStep(
            count: window.count, ptsAt: { window[$0].ptsSeconds },
            sequenceAt: { window[$0].sequence },
            held: held, resumeFrom: (7.0, 18), isReset: false,
            releaseAt: 0.73 + AetherEngine.subtitleDrainHarvestGapReleaseLeadSeconds,
            isRead: store.harvestReadCheck())
        #expect(step.decodeEnd == window.count)
        #expect(step.hold == nil)
    }

    @Test("a descending pair over ground nobody read is still a hole")
    func descendingPairOverUnreadGroundCuts() {
        var coverage = SubtitleHarvestCoverage()
        coverage.noteAnchor(.prefetch, at: 30)
        coverage.noteProgress(.prefetch, through: 50)
        coverage.noteAnchor(.pump, at: 0)
        coverage.noteReach(.pump, through: 12)
        // Pump front at 10 s (newer), the prefetch's island from 31 s (older): 12..30 unread.
        let pts: [Double] = [10, 31, 36]
        let sequence: [UInt64] = [20, 3, 4]
        let cut = SubtitleOverlayDrainer.harvestGapCut(
            count: pts.count, ptsAt: { pts[$0] }, sequenceAt: { sequence[$0] },
            resumeFrom: (5, 19), notBefore: 7,
            isRead: { coverage.covers(from: $0, through: $1) })
        #expect(cut?.index == 1)
    }

    @Test("a silent ledger keeps the order rule")
    func silentLedgerKeepsOrder() {
        let store = SubtitlePacketStore()
        #expect(store.harvestReadCheck() == nil)
        let pts: [Double] = [7, 12]
        let sequence: [UInt64] = [18, 3]
        let cut = SubtitleOverlayDrainer.harvestGapCut(
            count: pts.count, ptsAt: { pts[$0] }, sequenceAt: { sequence[$0] },
            resumeFrom: (2, 17), notBefore: 2.73, isRead: store.harvestReadCheck())
        #expect(cut?.index == 1)
    }
}
