import Testing
import Foundation
@testable import AetherEngine

/// #941: the #362 hole, with the island NEWER than the ground in front of it.
///
/// Play to 40 s, seek past the producer's front to 70 s (run B re-anchors at 69.42 s and skips
/// 11..16), then straight back to 40 s (run C restarts at 37.04 s). The first tick at the landing
/// sees run A's entries up to 47 s and run B's island from 71 s, and B harvested AFTER A, so the
/// sequence ascends across the hole and #362's order rule reads one contiguous run. The tick decodes
/// the island, the cursor lands at 71 s, and the sets C harvests at 50..68 s a moment later sit
/// behind it for good. A re-harvest of the island by a later reader does the same to a hold that
/// did fire: the island turns newer than the held position and the hold releases over unread ground.
///
/// #362 round 2 already established that no arrangement of the packets that arrived can express a
/// forward re-anchor. The #416 ledger can: every reader announces where it opened, so the stretch
/// between A's reach and B's anchor is known to be unread.
@Suite("#941: a forward re-anchor's hole is seen by the ledger, not by harvest order")
struct Issue941ForwardReanchorHoleTests {

    /// Run A to 47 s (sets 41, 44, 47 with clears), run B's island from 71 s, harvest order A then B.
    private let pts: [Double] = [41.0, 43.0, 44.0, 46.0, 47.0, 49.0, 71.0, 73.0, 74.0]
    private let sequence: [UInt64] = [10, 11, 12, 13, 14, 15, 30, 31, 32]

    /// The ledger at that tick: A read up to its last packet, B from its anchor, C from its own
    /// anchor up to the playhead.
    private func ledger() -> SubtitleHarvestCoverage {
        var coverage = SubtitleHarvestCoverage()
        coverage.noteAnchor(.pump, at: 0)
        coverage.noteReach(.pump, through: 49.0)
        coverage.noteAnchor(.pump, at: 69.42)
        coverage.noteReach(.pump, through: 74.0)
        coverage.noteAnchor(.pump, at: 37.04)
        coverage.noteReach(.pump, through: 40.0)
        return coverage
    }

    @Test("order alone reads the reported window as one run")
    func orderAloneMissesIt() {
        #expect(SubtitleOverlayDrainer.harvestGapCut(
            count: pts.count, ptsAt: { pts[$0] }, sequenceAt: { sequence[$0] },
            resumeFrom: nil, notBefore: 40) == nil)
    }

    @Test("the ledger stops the reset tick at the last packet run A read")
    func ledgerStopsAtTheUnreadStretch() {
        let coverage = ledger()
        let cut = SubtitleOverlayDrainer.harvestGapCut(
            count: pts.count, ptsAt: { pts[$0] }, sequenceAt: { sequence[$0] },
            resumeFrom: nil, notBefore: 40,
            isRead: { coverage.covers(from: $0, through: $1) })
        #expect(cut?.index == 6)       // A's sets decode, B's island does not
        #expect(cut?.at == 49.0)
        #expect(cut?.sequence == 15)
    }

    @Test("a hole at the cursor is seen by the ledger as well")
    func ledgerHoleAtTheCursor() {
        let coverage = ledger()
        let island: [Double] = [71.0, 73.0]
        let cut = SubtitleOverlayDrainer.harvestGapCut(
            count: 2, ptsAt: { island[$0] }, sequenceAt: { [30, 31][$0] },
            resumeFrom: (49.0, 15), notBefore: 40,
            isRead: { coverage.covers(from: $0, through: $1) })
        #expect(cut?.index == 0)
        #expect(cut?.at == 49.0)
    }

    @Test("a hold does not release on a newer island while the ground before it is unread")
    func holdWaitsForTheGroundNotForTheOrder() {
        let coverage = ledger()
        // The island re-harvested by a later reader carries a sequence newer than the held one.
        #expect(!SubtitleOverlayDrainer.harvestGapHoldResumes(
            firstSequence: 40, heldSequence: 15, firstPts: 71.0, heldAt: 49.0,
            isRead: { coverage.covers(from: $0, through: $1) }))
    }

    @Test("the hold releases once the filling run has read up to the next entry")
    func holdReleasesWhenRunCReachesIt() {
        var coverage = ledger()
        coverage.noteReach(.pump, through: 50.0)   // run C harvested the 50 s set
        #expect(SubtitleOverlayDrainer.harvestGapHoldResumes(
            firstSequence: 41, heldSequence: 15, firstPts: 50.0, heldAt: 49.0,
            isRead: { coverage.covers(from: $0, through: $1) }))
    }

    @Test("the playhead passing the near side does not release a hole still ahead of it")
    func playheadBetweenTheSides() {
        // The reproduced shape: the refill runs at about 1x, so the playhead passes the set at 48 s
        // while 48..56 s is still unread and the island waits at 57 s.
        var coverage = SubtitleHarvestCoverage()
        coverage.noteAnchor(.pump, at: 36.02)
        coverage.noteReach(.pump, through: 48.32)
        coverage.noteAnchor(.prefetch, at: 56.02)
        coverage.noteProgress(.prefetch, through: 71.02)
        let window: [Double] = [57.02, 59.02, 60.02]
        let cut = SubtitleOverlayDrainer.harvestGapCut(
            count: 3, ptsAt: { window[$0] }, sequenceAt: { [50, 51, 52][$0] },
            resumeFrom: (48.02, 44), notBefore: 48.32 + 2,
            isRead: { coverage.covers(from: $0, through: $1) })
        #expect(cut?.index == 0)
        #expect(cut?.at == 48.02)
        // Within the release lead of the island it is decoded: it is due.
        #expect(SubtitleOverlayDrainer.harvestGapCut(
            count: 3, ptsAt: { window[$0] }, sequenceAt: { [50, 51, 52][$0] },
            resumeFrom: (48.02, 44), notBefore: 55.5 + 2,
            isRead: { coverage.covers(from: $0, through: $1) }) == nil)
    }

    @Test("an authored silence one run read never stops the tick")
    func authoredSilenceStaysContiguous() {
        var coverage = SubtitleHarvestCoverage()
        coverage.noteAnchor(.pump, at: 0)
        coverage.noteReach(.pump, through: 200)
        let quiet: [Double] = [41.0, 43.0, 133.0, 135.0]
        #expect(SubtitleOverlayDrainer.harvestGapCut(
            count: 4, ptsAt: { quiet[$0] }, sequenceAt: { [1, 2, 3, 4][$0] },
            resumeFrom: nil, notBefore: 40,
            isRead: { coverage.covers(from: $0, through: $1) }) == nil)
    }

    @Test("a store that never heard from a reader answers every span as read")
    func silentLedgerChangesNothing() {
        let store = SubtitlePacketStore()
        let isRead = store.harvestReadCheck()
        #expect(isRead(49, 71))
    }

    @Test("the store's snapshot answers like the ledger it was taken from")
    func storeSnapshotMatchesLedger() {
        let store = SubtitlePacketStore()
        store.noteHarvestAnchor(.pump, at: 0)
        store.noteHarvestReach(.pump, through: 49)
        store.noteHarvestAnchor(.pump, at: 69.42)
        store.noteHarvestReach(.pump, through: 74)
        let isRead = store.harvestReadCheck()
        #expect(!isRead(49, 71))
        #expect(isRead(41, 47))
        #expect(isRead(70, 73))
    }
}
