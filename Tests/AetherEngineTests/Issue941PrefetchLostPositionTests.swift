import Testing
import Foundation
@testable import AetherEngine

/// #941 round 2: the side reader's re-anchor claimed ground it never read.
///
/// Reported on 7.56.0 over a link at about 1x a 70 Mbit/s file: play to 40 s, seek to 70 s, and
/// seek back to 40 s right after the forward landing. The side reader is moved back to 40 s, its
/// bounded seek does not complete on the saturated link, and it keeps reading from about 70 s. The
/// ledger was anchored on the requested 40 s regardless, so the first progress step at 70 s (under
/// the 30 s unannounced-advance limit) stretched the run over 40..70, the hole between run A's
/// sets and the island at 71 s read as read, and the drain decoded the island at a playhead of
/// 44.86 s. A back seek from further away (45 s from 80 s) stayed clean, because that step was
/// over the limit and opened a new run.
@Suite("#941: a side-reader reposition that did not complete anchors nothing")
struct Issue941PrefetchLostPositionTests {

    /// Pump runs as reported: A up to 47 s, B from seg 17 to the forward landing, C from seg 9.
    private func pumpRuns(_ store: SubtitlePacketStore) {
        store.noteHarvestAnchor(.pump, at: 30)
        store.noteHarvestReach(.pump, through: 49.0)
        store.noteHarvestAnchor(.pump, at: 68.0)
        store.noteHarvestReach(.pump, through: 70.1)
        store.noteHarvestAnchor(.pump, at: 36.0)
        store.noteHarvestReach(.pump, through: 44.86)
    }

    private func sideReaderBackAt40(_ landed: SubtitleForwardPrefetcher.Positioning,
                                    store: SubtitlePacketStore) {
        // Forward session from 70 s, then the in-place move back to 40 s.
        store.noteHarvestAnchor(.prefetch, at: 70.1)
        store.noteHarvestProgress(.prefetch, through: 71.0)
        SubtitleForwardPrefetcher.noteRepositionCoverage(landed, at: 40.1, store: store)
        // Where the reader actually reads next: still on the far side for a failed move.
        let next: [Double] = landed == .seek ? [38.2, 38.7, 39.3] : [71.4, 71.9, 72.5]
        for position in next { store.noteHarvestProgress(.prefetch, through: position) }
    }

    @Test("a failed or estimated move leaves the stretch behind the reader unread",
          arguments: [SubtitleForwardPrefetcher.Positioning.failed, .byteEstimate])
    func lostMoveClaimsNothing(_ landed: SubtitleForwardPrefetcher.Positioning) {
        let store = SubtitlePacketStore()
        pumpRuns(store)
        sideReaderBackAt40(landed, store: store)
        let isRead = store.harvestReadCheck()
        #expect(!isRead(49.0, 71.0))
        // The run it is really on is still recorded, from its first observed step.
        #expect(isRead(71.4, 72.5))
    }

    @Test("the reported window stops at the hole instead of decoding the island")
    func drainStopsAtTheHole() {
        let store = SubtitlePacketStore()
        pumpRuns(store)
        sideReaderBackAt40(.failed, store: store)
        // C re-harvested 41..47 with clears, then the side reader re-harvested the island, so the
        // sequence ascends across the hole and only the ledger can see it.
        let pts: [Double] = [47.0, 49.0, 71.0, 73.0]
        let sequence: [UInt64] = [40, 41, 50, 51]
        let cut = SubtitleOverlayDrainer.harvestGapCut(
            count: pts.count, ptsAt: { pts[$0] }, sequenceAt: { sequence[$0] },
            resumeFrom: (44.0, 39), notBefore: 44.86 + 2, isRead: store.harvestReadCheck())
        #expect(cut?.index == 2)
        #expect(cut?.at == 49.0)
    }

    @Test("a completed seek still anchors on the request")
    func completedSeekAnchors() {
        let store = SubtitlePacketStore()
        sideReaderBackAt40(.seek, store: store)
        let spans = store.harvestCoverageSpans
        #expect(spans.contains { $0.from == 40.1 })
    }

    @Test("a lost position keeps the run that was read before it")
    func lostPositionClosesTheRun() {
        var coverage = SubtitleHarvestCoverage()
        coverage.noteAnchor(.prefetch, at: 10)
        coverage.noteProgress(.prefetch, through: 20)
        coverage.noteLostPosition(.prefetch)
        coverage.noteProgress(.prefetch, through: 35)
        coverage.noteProgress(.prefetch, through: 36)
        #expect(coverage.covers(from: 10, through: 20))
        #expect(!coverage.covers(from: 20, through: 35))
        #expect(coverage.covers(from: 35, through: 36))
    }
}
