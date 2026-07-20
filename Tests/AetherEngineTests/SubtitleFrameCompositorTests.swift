import Testing
import CoreGraphics
import CoreVideo
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

    @Test("composite draws into the cue region and passthrough returns the input instance")
    func compositeSyntheticBuffer() throws {
        let compositor = SubtitleFrameCompositor()
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
        let buffer = try #require(pb)
        // Fill luma with 0 (black) so drawn subtitle pixels are detectable.
        CVPixelBufferLockBaseAddress(buffer, [])
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            memset(luma, 0, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        // Disabled: passthrough must be the same instance.
        compositor.update(cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("HELLO"))], enabled: false)
        #expect(compositor.composite(buffer, ptsSeconds: 5) === buffer)

        // Enabled with an active cue: output keeps the format and the bottom region gains bright pixels.
        compositor.update(cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("HELLO"))], enabled: true)
        let out = compositor.composite(buffer, ptsSeconds: 5)
        #expect(CVPixelBufferGetPixelFormatType(out) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(out !== buffer)
        CVPixelBufferLockBaseAddress(out, [.readOnly])
        var maxLuma: UInt8 = 0
        if let luma = CVPixelBufferGetBaseAddressOfPlane(out, 0) {
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
            // Scan the bottom third where the text box lands.
            for row in 240..<360 {
                let p = luma.advanced(by: row * bpr).assumingMemoryBound(to: UInt8.self)
                for col in 0..<640 { maxLuma = max(maxLuma, p[col]) }
            }
        }
        CVPixelBufferUnlockBaseAddress(out, [.readOnly])
        #expect(maxLuma > 100)

        // No active cue at this PTS: passthrough again.
        #expect(compositor.composite(buffer, ptsSeconds: 20) === buffer)
    }
}
