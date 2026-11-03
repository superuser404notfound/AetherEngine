import Foundation
import CoreGraphics
import Testing
@testable import AetherEngine

/// AE#929: after a backward seek the old position's floor and lead stayed in `subtitleCues` as cues
/// "ahead", which the AE#879 budget never evicts, so on a dense PGS track (measured with 4 MB cues
/// every 3 s, playhead 144 s back to 20 s) the retained images grew from 165 MB to 246 MB and stayed
/// there. A cue the drain cursor has not reached yet is decoded again when it gets there, so past
/// the lead it is the cheapest thing to drop.
struct Issue929BitmapBudgetAheadTests {

    private func bitmapCue(id: Int, start: Double, end: Double) -> SubtitleCue {
        let ctx = CGContext(data: nil, width: 1, height: 256, bitsPerComponent: 8,
                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SubtitleCue(id: id, startTime: start, endTime: end,
                           body: .image(SubtitleImage(cgImage: ctx.makeImage()!, position: .zero)))
    }

    @Test("past the re-decode horizon, the furthest cue goes first and before any history behind")
    func farAheadGoesFirst() {
        // Playhead 20 after a seek back from 144: 0 is history, 1 is in the lead, 2 to 4 are the old
        // position's cues that the cursor has not reached.
        var cues = [bitmapCue(id: 0, start: 5, end: 7),
                    bitmapCue(id: 1, start: 30, end: 32),
                    bitmapCue(id: 2, start: 120, end: 122),
                    bitmapCue(id: 3, start: 150, end: 152),
                    bitmapCue(id: 4, start: 200, end: 202)]
        #expect(AetherEngine.pruneCues(&cues, toBitmapBytes: 3 * 1024, endedBefore: 20 - 60,
                                       startingAfter: 20 + 75))
        #expect(cues.map(\.id) == [0, 1, 2])
    }

    @Test("history behind is evicted only once nothing past the horizon is left")
    func behindAfterAhead() {
        var cues = [bitmapCue(id: 0, start: 10, end: 12),
                    bitmapCue(id: 1, start: 50, end: 52),
                    bitmapCue(id: 2, start: 130, end: 132),
                    bitmapCue(id: 3, start: 300, end: 302)]
        #expect(AetherEngine.pruneCues(&cues, toBitmapBytes: 2 * 1024, endedBefore: 130 - 60,
                                       startingAfter: 130 + 75))
        #expect(cues.map(\.id) == [1, 2])
    }

    @Test("the lead the cursor has already decoded is protected however far it reaches")
    func decodedLeadSurvives() {
        var cues = [bitmapCue(id: 0, start: 100, end: 102),
                    bitmapCue(id: 1, start: 160, end: 162),
                    bitmapCue(id: 2, start: 175, end: 177)]
        #expect(!AetherEngine.pruneCues(&cues, toBitmapBytes: 1024, endedBefore: 100 - 60,
                                        startingAfter: 180))
        #expect(cues.map(\.id) == [0, 1, 2])
    }

    @Test("without a horizon the budget behaves as AE#879 shipped it")
    func defaultHorizonKeepsAhead() {
        var cues = [bitmapCue(id: 0, start: 10, end: 12),
                    bitmapCue(id: 1, start: 900, end: 902)]
        #expect(AetherEngine.pruneCues(&cues, toBitmapBytes: 0, endedBefore: 100))
        #expect(cues.map(\.id) == [1])
    }
}
