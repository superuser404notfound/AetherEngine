import Testing
import Foundation
@testable import AetherEngine

/// #941 round 3: a hole hold has no tick budget any more.
///
/// The hold used to give up after 20 ticks (10 s) and decode across the hole. Ticks run on wall
/// time, so they kept counting while the playhead stood still: through a seek (reported: the
/// cursor sits on the set at 47 s when the seek to 70 s harvests the island at 71 s, and the
/// budget burns through that seek, the one straight back to 40 s and the rebuffer behind it) and
/// through a stall (reproduced: a hold at 64.4 s, island at 69.4 s, the playhead parked at 61.31 s
/// until the budget ran out). Either way the drain decoded the island early and the cursor passed
/// the sets the refill was about to harvest. The far-side release (#941 round 1) is the bound: it
/// ends the hold exactly when the island is due, whatever the wall clock did meanwhile.
@Suite("#941: a hole hold waits for the playhead, not for a tick count")
struct Issue941StalledHoldTests {

    /// Cursor on run A's set at 47 s, run B's island from 71 s, harvested after A.
    private let island: [Double] = [71.0, 73.0, 74.0]
    private let islandSequence: [UInt64] = [30, 31, 32]

    private func ledger() -> SubtitleHarvestCoverage {
        var coverage = SubtitleHarvestCoverage()
        coverage.noteAnchor(.pump, at: 0)
        coverage.noteReach(.pump, through: 49.0)
        coverage.noteAnchor(.pump, at: 69.42)
        coverage.noteReach(.pump, through: 74.0)
        coverage.noteAnchor(.pump, at: 37.04)
        coverage.noteReach(.pump, through: 44.86)
        return coverage
    }

    private func step(_ window: [Double], _ sequence: [UInt64],
                      held: SubtitleOverlayDrainer.HarvestGapHold?,
                      cursor: (pts: Double, sequence: UInt64),
                      playhead: Double, coverage: SubtitleHarvestCoverage)
        -> (decodeEnd: Int, hold: SubtitleOverlayDrainer.HarvestGapHold?) {
        SubtitleOverlayDrainer.harvestGapStep(
            count: window.count, ptsAt: { window[$0] }, sequenceAt: { sequence[$0] },
            held: held, resumeFrom: cursor, isReset: false,
            releaseAt: playhead + AetherEngine.subtitleDrainHarvestGapReleaseLeadSeconds,
            isRead: { coverage.covers(from: $0, through: $1) })
    }

    @Test("a playhead standing still keeps the hold however many ticks pass")
    func stalledPlayheadKeepsTheHold() {
        let coverage = ledger()
        var result = step(island, islandSequence, held: nil, cursor: (47.0, 14),
                          playhead: 44.86, coverage: coverage)
        #expect(result.decodeEnd == 0)
        #expect(result.hold == .init(at: 47.0, sequence: 14))
        for _ in 0..<120 {
            result = step(island, islandSequence, held: result.hold, cursor: (47.0, 14),
                          playhead: 44.86, coverage: coverage)
            #expect(result.decodeEnd == 0)
        }
        #expect(result.hold == .init(at: 47.0, sequence: 14))
    }

    @Test("the hold ends when the island is due")
    func releasesWithinTheLead() {
        let coverage = ledger()
        let held = SubtitleOverlayDrainer.HarvestGapHold(at: 47.0, sequence: 14)
        #expect(step(island, islandSequence, held: held, cursor: (47.0, 14),
                     playhead: 68.5, coverage: coverage).decodeEnd == 0)
        let due = step(island, islandSequence, held: held, cursor: (47.0, 14),
                       playhead: 69.1, coverage: coverage)
        #expect(due.decodeEnd == island.count)
        #expect(due.hold == nil)
    }

    @Test("the filling run reaching the hold moves it to its own front")
    func fillingRunMovesTheHold() {
        var coverage = ledger()
        coverage.noteReach(.pump, through: 53.5)
        let window: [Double] = [50.0, 52.0, 53.0] + island
        let sequence: [UInt64] = [40, 41, 42] + islandSequence
        let result = step(window, sequence, held: .init(at: 47.0, sequence: 14),
                          cursor: (47.0, 14), playhead: 46.0, coverage: coverage)
        #expect(result.decodeEnd == 3)
        #expect(result.hold == .init(at: 53.0, sequence: 42))
    }

    @Test("the reproduced stall: a hold at 64.4 s with the playhead parked at 61.31 s")
    func reproducedStall() {
        var coverage = SubtitleHarvestCoverage()
        coverage.noteAnchor(.pump, at: 37.04)
        coverage.noteReach(.pump, through: 65.0)
        coverage.noteAnchor(.pump, at: 69.42)
        coverage.noteReach(.pump, through: 80.0)
        let window: [Double] = [69.4, 70.4, 72.4, 73.4]
        let sequence: [UInt64] = [20, 21, 22, 23]
        var hold: SubtitleOverlayDrainer.HarvestGapHold? = .init(at: 64.4, sequence: 90)
        for _ in 0..<60 {
            let result = step(window, sequence, held: hold, cursor: (64.4, 90),
                              playhead: 61.31, coverage: coverage)
            #expect(result.decodeEnd == 0)
            hold = result.hold
        }
        #expect(hold == .init(at: 64.4, sequence: 90))
    }

    @Test("a reset never inherits a hold")
    func resetDropsTheHold() {
        let coverage = ledger()
        let window: [Double] = [41.0, 43.0, 44.0, 46.0, 47.0]
        let sequence: [UInt64] = [50, 51, 52, 53, 54]
        let result = SubtitleOverlayDrainer.harvestGapStep(
            count: window.count, ptsAt: { window[$0] }, sequenceAt: { sequence[$0] },
            held: .init(at: 47.0, sequence: 14), resumeFrom: (47.0, 14), isReset: true,
            releaseAt: 44.86 + 2, isRead: { coverage.covers(from: $0, through: $1) })
        #expect(result.decodeEnd == window.count)
        #expect(result.hold == nil)
    }
}
