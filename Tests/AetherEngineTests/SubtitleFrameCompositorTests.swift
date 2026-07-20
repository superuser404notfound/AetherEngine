import Testing
import CoreGraphics
@testable import AetherEngine

@Suite("Subtitle frame compositor logic")
struct SubtitleFrameCompositorTests {
    private func cue(_ id: Int, _ start: Double, _ end: Double) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text("line \(id)"))
    }

    @Test("active cue selection is a plain window check on the source axis")
    func activeCueWindow() {
        let cues = [cue(1, 0, 4), cue(2, 3, 8), cue(3, 10, 12)]
        #expect(SubtitleFrameCompositor.activeCues(in: cues, at: 3.5).map(\.id) == [1, 2])
        #expect(SubtitleFrameCompositor.activeCues(in: cues, at: 9.0).isEmpty)
        #expect(SubtitleFrameCompositor.activeCues(in: cues, at: 10.0).map(\.id) == [3])
        #expect(SubtitleFrameCompositor.activeCues(in: cues, at: 12.0).isEmpty)
    }

    @Test("text layout scales with frame height and keeps a safe bottom margin")
    func textLayoutScales() {
        let layout = SubtitleFrameCompositor.textLayout(frameWidth: 1920, frameHeight: 1080)
        #expect(abs(layout.fontSize - 54) < 0.5)
        #expect(abs(layout.bottomMargin - 64.8) < 0.5)
        #expect(abs(layout.maxTextWidth - 1728) < 0.5)
    }

    @Test("bitmap cue maps width-aligned and center-anchored from its canvas onto the frame")
    func bitmapCanvasMapping() {
        // Canvas 1920x1280 (taller than video), video frame 1280x720: scale by width (1280/1920),
        // vertical center anchored (canvas center -> frame center).
        let rect = SubtitleFrameCompositor.imageRect(
            position: CGRect(x: 660, y: 1100, width: 600, height: 100),
            canvasSize: CGSize(width: 1920, height: 1280),
            frameWidth: 1280, frameHeight: 720
        )
        #expect(abs(rect.width - 400) < 0.5)
        #expect(abs(rect.minX - 440) < 0.5)
        // canvas y 1100 is 460 below canvas center (640); frame center 360 + 460*(2/3) = 666.67
        #expect(abs(rect.minY - 666.67) < 1.0)
    }

    @Test("bitmap cue with unknown canvas treats canvas as the frame")
    func bitmapUnknownCanvas() {
        let rect = SubtitleFrameCompositor.imageRect(
            position: CGRect(x: 100, y: 200, width: 300, height: 50),
            canvasSize: .zero,
            frameWidth: 1920, frameHeight: 1080
        )
        #expect(rect == CGRect(x: 100, y: 200, width: 300, height: 50))
    }
}
