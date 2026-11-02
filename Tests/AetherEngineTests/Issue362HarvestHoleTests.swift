import Testing
import Foundation
@testable import AetherEngine

/// #362, second mechanism: a hole in the harvest, read as a silence in the source.
///
/// After a seek the pump restarts behind the landing and fills forward, while the store still holds
/// an island the previous run harvested further ahead. The drain window then reads as "packets,
/// hole, packets", and decoding straight across it carries the cursor to the far side. The cursor
/// only ever moves forward, so the hole's packets, which land a second later, are never read: a
/// stretch of the film has no subtitles at all, and the set before the hole is closed at the island
/// instead of at its own clear (report: eleven authored sets delivered as two).
///
/// The gap's SIZE cannot tell a hole from an authored silence, and a threshold on it does real
/// damage: a PGS set is separated from its own clear by its display duration, so a 3 s rule stopped
/// the tick at every authored line and delivery fell to a sixth of the sets in a fixture run.
/// Harvest ORDER tells them apart, because a run reads forwards: within one run PTS and sequence
/// rise together, and a PTS-ascending pair whose sequence descends is two runs meeting over a span
/// neither has read.
@Suite("#362: a hole in the harvest is not a silence in the source")
struct Issue362HarvestHoleTests {

    /// The reported shape: 275 s and 280 s freshly harvested by the restarted pump (sequences 40,
    /// 41), 295 s and 300 s left by the run that served the earlier landing (sequences 8, 9). The
    /// packets between 280 and 295 have not been read by anyone.
    private let pts: [Double] = [275.023, 280.023, 295.023, 300.023]
    private let sequence: [UInt64] = [40, 41, 8, 9]

    private func cut(from index: Int = 0, resumeFrom: (pts: Double, sequence: UInt64)? = nil,
                     playhead: Double = 231) -> (index: Int, at: Double, sequence: UInt64)? {
        SubtitleOverlayDrainer.harvestGapCut(
            count: pts.count - index,
            ptsAt: { pts[$0 + index] },
            sequenceAt: { sequence[$0 + index] },
            resumeFrom: resumeFrom,
            notBefore: playhead)
    }

    // MARK: - The reported case

    @Test("the tick stops where the harvest order breaks, not where the gap is widest")
    func stopsAtTheRunBoundary() {
        let boundary = cut()
        #expect(boundary?.index == 2)          // 275 and 280 decode, the island does not
        #expect(boundary?.at == 280.023)       // the hold sits on the last packet of this run
        #expect(boundary?.sequence == 41)
    }

    @Test("a hole that opens AT the cursor is still seen, which is where the report's window was")
    func holeAtTheCursor() {
        // The window a steady tick reads starts past the cursor, so when the hole opens right there
        // the window holds nothing but the island and no pair inside it can reveal anything. The
        // cursor's own harvest sequence is the missing half of the comparison: without it the tick
        // decodes the island, moves the cursor to 295 s and the four packets in between are lost
        // for the rest of the session.
        let islandOnly = SubtitleOverlayDrainer.harvestGapCut(
            count: 2, ptsAt: { [295.023, 300.023][$0] }, sequenceAt: { [8, 9][$0] },
            resumeFrom: (280.023, 41), notBefore: 231)
        #expect(islandOnly?.index == 0)        // nothing may decode this tick
        #expect(islandOnly?.at == 280.023)
    }

    @Test("with no pair and no cursor sequence there is nothing to claim, so nothing is held")
    func noSequenceNoHold() {
        // A cursor parked on a window boundary rather than on a packet carries sequence 0. It says
        // nothing about provenance and must not be read as "everything after me is old".
        let unknown = SubtitleOverlayDrainer.harvestGapCut(
            count: 2, ptsAt: { [295.023, 300.023][$0] }, sequenceAt: { [8, 9][$0] },
            resumeFrom: (280.023, 0), notBefore: 231)
        #expect(unknown == nil)
        #expect(SubtitleOverlayDrainer.harvestGapCut(
            count: 0, ptsAt: { _ in 0 }, sequenceAt: { _ in 0 },
            resumeFrom: nil, notBefore: 0) == nil)
    }

    // MARK: - What must survive it

    @Test("an authored silence is one run and never stops the tick, however long it is")
    func authoredSilenceIsNotAHole() {
        // The case a size threshold got wrong. Ninety seconds of no dialogue, harvested in order by
        // one run: nothing is missing, nothing is coming, and a tick that waited here would stall
        // delivery for its whole budget on perfectly healthy content.
        let quiet: [Double] = [275.023, 279.023, 369.023, 373.023]
        let inOrder: [UInt64] = [40, 41, 42, 43]
        #expect(SubtitleOverlayDrainer.harvestGapCut(
            count: 4, ptsAt: { quiet[$0] }, sequenceAt: { inOrder[$0] },
            resumeFrom: (270.023, 39), notBefore: 231) == nil)
    }

    @Test("a set and its own clear are a run boundary apart in time and never in order")
    func displayDurationIsNotAHole() {
        // Why the threshold rule had to go: a 4 s set is 4 s from its clear by construction, so a
        // 3 s rule fired on every authored line. In harvest order the two are adjacent.
        let set: [Double] = [280.023, 284.023, 285.023, 289.023]
        let inOrder: [UInt64] = [40, 41, 42, 43]
        #expect(SubtitleOverlayDrainer.harvestGapCut(
            count: 4, ptsAt: { set[$0] }, sequenceAt: { inOrder[$0] },
            resumeFrom: nil, notBefore: 231) == nil)
    }

    @Test("a hole whose far side the playhead has reached is decoded straight across")
    func holeBehindThePlayheadIsNotHeld() {
        // Waiting there delays content the viewer already needs, which is the one thing #143's
        // reconstruction pass must never be made to do. #941: judged on the FAR side. A playhead
        // between the two sides still has the unread ground ahead of it, and the hold stays.
        #expect(cut(playhead: 296) == nil)
        #expect(cut(playhead: 290)?.index == 2)
    }

    // MARK: - Resuming

    @Test("the hold resumes when the filling run reaches it, and only then")
    func holdResumesOnFreshHarvest() {
        // The near side is no longer in the window, so what answers is the first entry's
        // provenance: newer than the sequence held at means the run has read through to here.
        #expect(!SubtitleOverlayDrainer.harvestGapHoldResumes(firstSequence: 8, heldSequence: 41))
        #expect(SubtitleOverlayDrainer.harvestGapHoldResumes(firstSequence: 42, heldSequence: 41))
        #expect(!SubtitleOverlayDrainer.harvestGapHoldResumes(firstSequence: nil, heldSequence: 41))
    }

    @Test("a re-harvested packet takes a fresh sequence, which is what releases the hold")
    func reharvestRefreshesTheSequence() {
        // The pump re-reads what it passes, island included, and the collapse of that duplicate is
        // the moment the span behind it is known to be read. Keeping the old sequence would leave a
        // boundary the drain waits at until its budget expires, every time.
        let store = SubtitlePacketStore()
        store.append(streamIndex: 3, ptsSeconds: 295.023, durationSeconds: 0, payload: Data(count: 30))
        store.append(streamIndex: 3, ptsSeconds: 280.023, durationSeconds: 0, payload: Data(count: 900))
        let first = store.entries(streamIndex: 3, from: 0, through: 400)
        #expect(first.first(where: { $0.ptsSeconds == 295.023 })!.sequence
                < first.first(where: { $0.ptsSeconds == 280.023 })!.sequence)

        store.append(streamIndex: 3, ptsSeconds: 295.023, durationSeconds: 0, payload: Data(count: 30))
        let refreshed = store.entries(streamIndex: 3, from: 0, through: 400)
        #expect(refreshed.count == 2)   // the duplicate collapsed, it did not stack
        #expect(refreshed.first(where: { $0.ptsSeconds == 295.023 })!.sequence
                > refreshed.first(where: { $0.ptsSeconds == 280.023 })!.sequence)
    }

    @Test("the store stamps harvest order, ascending, across streams")
    func sequenceIsMonotonic() {
        let store = SubtitlePacketStore()
        for (index, pts) in [10.0, 20.0, 30.0].enumerated() {
            store.append(streamIndex: Int32(index % 2), ptsSeconds: pts, durationSeconds: 0,
                         payload: Data(count: 8))
        }
        let a = store.entries(streamIndex: 0, from: 0, through: 100)
        let b = store.entries(streamIndex: 1, from: 0, through: 100)
        #expect(a.map(\.sequence) == [1, 3])
        #expect(b.map(\.sequence) == [2])
    }
}
