import Foundation
import CoreGraphics
import Testing
@testable import AetherEngine

/// AE#879: a dense PGS track retained thousands of full-RGBA cue images inside the 300 s window
/// (reported on tvOS: 2,207 cues, 290 MB of pixels, 560 of them ever handed to the overlay). The
/// retained history is now bounded by bytes, evicting the cues that ended longest ago, while the
/// floor behind the playhead and everything ahead of it stay. A backward seek brings evicted cues
/// back through the drain's window re-decode.
struct Issue879CueByteBudgetTests {

    /// One cue whose image holds exactly `kib` KiB (width * 4 bytes per row, 256 rows).
    private func bitmapCue(id: Int, start: Double, end: Double, kib: Int = 1) -> SubtitleCue {
        let width = kib * 1024 / (4 * 256)
        let ctx = CGContext(data: nil, width: width, height: 256, bitsPerComponent: 8,
                            bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SubtitleCue(id: id, startTime: start, endTime: end,
                           body: .image(SubtitleImage(cgImage: ctx.makeImage()!, position: .zero)))
    }

    @Test("a history within budget is left alone")
    func withinBudgetUntouched() {
        var cues = (0..<4).map { bitmapCue(id: $0, start: Double($0) * 10, end: Double($0) * 10 + 2) }
        #expect(!AetherEngine.pruneCues(&cues, toBitmapBytes: 4 * 1024, endedBefore: 1_000))
        #expect(cues.count == 4)
    }

    @Test("over budget, the cues that ended longest ago go first and only until it fits")
    func evictsOldestEndFirst() {
        var cues = (0..<6).map { bitmapCue(id: $0, start: Double($0) * 10, end: Double($0) * 10 + 2) }
        #expect(AetherEngine.pruneCues(&cues, toBitmapBytes: 4 * 1024, endedBefore: 1_000))
        #expect(cues.map(\.id) == [2, 3, 4, 5])
    }

    @Test("the floor and everything ahead survive even when the total stays over budget")
    func floorIsNeverEvicted() {
        // Playhead 100, floor 60 s: cues ending at or after 40 are protected.
        var cues = [bitmapCue(id: 0, start: 10, end: 12),
                    bitmapCue(id: 1, start: 50, end: 52),
                    bitmapCue(id: 2, start: 99, end: 103),
                    bitmapCue(id: 3, start: 130, end: 132)]
        #expect(AetherEngine.pruneCues(&cues, toBitmapBytes: 1024, endedBefore: 100 - 60))
        #expect(cues.map(\.id) == [1, 2, 3])
        #expect(!AetherEngine.pruneCues(&cues, toBitmapBytes: 1024, endedBefore: 100 - 60))
    }

    @Test("text cues cost nothing and are never evicted by the byte budget")
    func textCuesUntouched() {
        var cues = [SubtitleCue(id: 0, startTime: 1, endTime: 2, body: .text("old")),
                    bitmapCue(id: 1, start: 3, end: 4),
                    bitmapCue(id: 2, start: 5, end: 6)]
        #expect(AetherEngine.pruneCues(&cues, toBitmapBytes: 1024, endedBefore: 1_000))
        #expect(cues.map(\.id) == [0, 2])
        #expect(cues[0].bitmapBytes == 0)
    }

    @Test("an open-ended placeholder is protected like any cue ahead")
    func openEndedPlaceholderSurvives() {
        var cues = [bitmapCue(id: 0, start: 10, end: 10 + 3_600),
                    bitmapCue(id: 1, start: 20, end: 22)]
        #expect(AetherEngine.pruneCues(&cues, toBitmapBytes: 1024, endedBefore: 500))
        #expect(cues.map(\.id) == [0])
    }

    /// The budget relies on this: a seek back into an evicted stretch, even one well inside the
    /// 300 s window, resets the drain onto a fresh backscan window decoded from the packet store,
    /// and the insert funnel takes the re-decoded cue back in.
    @Test("a backward seek inside the retention window re-decodes the stretch the budget evicted")
    func backwardSeekReDecodes() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 460, lastPlayhead: 400)
        let plan = SubtitleOverlayDrainer.drainPlan(
            cursor: cursor, playhead: 280,
            lead: AetherEngine.subtitleDrainLeadSeconds,
            backscan: AetherEngine.subtitleDrainBackscanSeconds,
            jumpThreshold: AetherEngine.subtitleDrainJumpThresholdSeconds)
        #expect(plan == .resetAndDecode(from: 280 - AetherEngine.subtitleDrainBackscanSeconds,
                                        through: 280 + AetherEngine.subtitleDrainLeadSeconds))

        var cues = [bitmapCue(id: 0, start: 270, end: 272), bitmapCue(id: 1, start: 390, end: 392)]
        #expect(AetherEngine.pruneCues(&cues, toBitmapBytes: 1024, endedBefore: 400 - 60))
        #expect(cues.map(\.id) == [1])
        #expect(AetherEngine.insertCueSorted(bitmapCue(id: 2, start: 270, end: 272), into: &cues))
        #expect(cues.map(\.startTime) == [270, 390])
    }
}
