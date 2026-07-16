import Testing
import CoreGraphics
@testable import AetherEngine

@Suite("Teletext text-cue trim (#107 page-state semantics)")
struct TeletextCueTrimTests {

    private func textCue(id: Int, start: Double, end: Double, _ text: String = "line") -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(text))
    }

    private func tinyImage() -> SubtitleImage {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SubtitleImage(cgImage: ctx.makeImage()!, position: .zero)
    }

    @Test("an open text cue covering the trim point is closed at it")
    func openCueClosed() {
        var cues = [textCue(id: 0, start: 100, end: 100 + 4_294_967)]
        AetherEngine.trimTextCues(&cues, at: 110)
        #expect(cues.count == 1)
        #expect(cues[0].endTime == 110)
        #expect(cues[0].startTime == 100)
    }

    @Test("a cue already closed before the trim point is untouched")
    func closedCueUntouched() {
        var cues = [textCue(id: 0, start: 100, end: 105)]
        AetherEngine.trimTextCues(&cues, at: 110)
        #expect(cues[0].endTime == 105)
    }

    @Test("a cue starting at or after the trim point is untouched (the successor's own cues)")
    func successorCuesUntouched() {
        var cues = [textCue(id: 0, start: 110, end: 120), textCue(id: 1, start: 115, end: 125)]
        AetherEngine.trimTextCues(&cues, at: 110)
        #expect(cues[0].endTime == 120)
        #expect(cues[1].endTime == 125)
    }

    @Test("simultaneous same-start lines are both closed by the next event")
    func simultaneousLinesBothClosed() {
        var cues = [
            textCue(id: 0, start: 100, end: 100 + 4_294_967, "speaker one"),
            textCue(id: 1, start: 100, end: 100 + 4_294_967, "speaker two"),
        ]
        AetherEngine.trimTextCues(&cues, at: 104)
        #expect(cues.allSatisfy { $0.endTime == 104 })
    }

    @Test("image cues are not touched by the text trim")
    func imageCuesUntouched() {
        var cues: [SubtitleCue] = [
            SubtitleCue(id: 0, startTime: 100, endTime: 200, body: .image(tinyImage())),
            textCue(id: 1, start: 100, end: 200),
        ]
        AetherEngine.trimTextCues(&cues, at: 150)
        guard case .image = cues[0].body else {
            Issue.record("image cue must keep its position in the store")
            return
        }
        #expect(cues[0].endTime == 200)
        #expect(cues[1].endTime == 150)
    }

    @Test("cue ids and text survive the trim")
    func identityPreserved() {
        var cues = [textCue(id: 7, start: 100, end: 100 + 4_294_967, "hello")]
        AetherEngine.trimTextCues(&cues, at: 101)
        #expect(cues[0].id == 7)
        #expect(cues[0].text == "hello")
    }
}
