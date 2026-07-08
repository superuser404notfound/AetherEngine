import Foundation
import CoreGraphics
import Testing
@testable import AetherEngine

/// #112 full umbau: the retained store insert keeps cues sorted by start and de-dupes image cues sharing a start.
/// A PGS composition has a unique start PTS, so a same-start image cue is the same line re-decoded (the audio-switch
/// preserved placeholder vs its reconstruction). Without the replace it would render the bitmap twice until the next
/// composition trims it. Text cues at the same start are distinct simultaneous speakers and are both kept.
struct Issue112PGSInsertDedupTests {

    private func img() -> SubtitleCue.Body {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return .image(SubtitleImage(cgImage: ctx.makeImage()!, position: .zero))
    }
    private func imageCue(id: Int, start: Double, end: Double) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: img())
    }
    private func textCue(id: Int, start: Double, end: Double, _ s: String) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(s))
    }

    @Test("insertion keeps ascending start order")
    func keepsSortedOrder() {
        var cues: [SubtitleCue] = []
        AetherEngine.insertCueSorted(imageCue(id: 1, start: 200, end: 210), into: &cues)
        AetherEngine.insertCueSorted(imageCue(id: 2, start: 100, end: 110), into: &cues)
        AetherEngine.insertCueSorted(imageCue(id: 3, start: 150, end: 160), into: &cues)
        #expect(cues.map(\.startTime) == [100, 150, 200])
    }

    @Test("a same-start image cue replaces the existing one instead of duplicating")
    func sameStartImageReplaces() {
        var cues: [SubtitleCue] = [imageCue(id: 1, start: 100, end: 4_296_178)]
        // The reconstruction re-decodes the same composition at start=100 with a real (trimmed) end.
        AetherEngine.insertCueSorted(imageCue(id: 2, start: 100, end: 118), into: &cues)
        #expect(cues.count == 1)
        #expect(cues[0].id == 2)
        #expect(cues[0].endTime == 118)
    }

    @Test("two text cues at the same start are both kept (distinct speakers)")
    func sameStartTextKept() {
        var cues: [SubtitleCue] = [textCue(id: 1, start: 100, end: 110, "left")]
        AetherEngine.insertCueSorted(textCue(id: 2, start: 100, end: 110, "right"), into: &cues)
        #expect(cues.count == 2)
    }

    @Test("an image cue does not replace a text cue at the same start")
    func imageDoesNotReplaceText() {
        var cues: [SubtitleCue] = [textCue(id: 1, start: 100, end: 110, "caption")]
        AetherEngine.insertCueSorted(imageCue(id: 2, start: 100, end: 110), into: &cues)
        #expect(cues.count == 2)
    }
}
