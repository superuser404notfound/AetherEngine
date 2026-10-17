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

    @Test("software PiP delay and advance use media time for both subtitle channels")
    func adjustedCueWindow() {
        let cues = [cue(1, 10, 12), cue(2, 10, 11), cue(3, 12, 14)]
        #expect(SubtitleFrameCompositor.activeCues(in: cues, at: 10.5, delaySeconds: 1.5).isEmpty)
        #expect(SubtitleFrameCompositor.activeCues(in: cues, at: 11.5, delaySeconds: 1.5).map(\.id) == [1, 2])
        #expect(SubtitleFrameCompositor.activeCues(in: cues, at: 13.5, delaySeconds: 1.5).map(\.id) == [3])
        #expect(SubtitleFrameCompositor.activeCues(in: cues, at: 8.5, delaySeconds: -1.5).map(\.id) == [1, 2])
        #expect(SubtitleFrameCompositor.activeCues(in: cues, at: .nan).isEmpty)
        #expect(SubtitleFrameCompositor.activeCues(in: cues, at: 11, delaySeconds: .infinity).isEmpty)
    }

    @MainActor
    @Test("software subtitle preference survives PiP transitions and rejects invalid values")
    func delayPreference() throws {
        let engine = try AetherEngine()
        engine.setSoftwareSubtitleDelay(1.5)
        engine.pictureInPictureActive = true
        engine.pictureInPictureActive = false
        engine.setSoftwareSubtitleDelay(.nan)
        #expect(engine.softwareSubtitleDelaySeconds == 1.5)
        engine.setSoftwareSubtitleDelay(-0.5)
        #expect(engine.softwareSubtitleDelaySeconds == -0.5)
        engine.stop()
        #expect(engine.softwareSubtitleDelaySeconds == -0.5)
    }

    @Test("text layout scales with frame height and keeps a safe bottom margin")
    func textLayoutScales() {
        let layout = SubtitleFrameCompositor.textLayout(frameWidth: 1920, frameHeight: 1080)
        #expect(abs(layout.fontSize - 54) < 0.5)
        #expect(abs(layout.bottomMargin - 64.8) < 0.5)
        #expect(abs(layout.maxTextWidth - 1728) < 0.5)
    }

    @Test("bitmap cue maps its NORMALIZED position via the canvas, width-aligned center-anchored")
    func bitmapCanvasMapping() {
        // SubtitleImage.position is normalized against the canvas (see PlayerState). Canvas 1920x1280
        // (taller than video), video frame 1280x720: canvas pixels = position * canvas, then scale by
        // width (1280/1920 = 2/3), vertical center anchored (canvas center -> frame center).
        let rect = SubtitleFrameCompositor.imageRect(
            position: CGRect(x: 660.0 / 1920.0, y: 1100.0 / 1280.0, width: 600.0 / 1920.0, height: 100.0 / 1280.0),
            canvasSize: CGSize(width: 1920, height: 1280),
            frameWidth: 1280, frameHeight: 720
        )
        #expect(abs(rect.width - 400) < 0.5)
        #expect(abs(rect.minX - 440) < 0.5)
        // canvas y 1100 is 460 below canvas center (640); frame center 360 + 460*(2/3) = 666.67
        #expect(abs(rect.minY - 666.67) < 1.0)
    }

    @Test("bitmap cue with unknown canvas is normalized against the frame itself")
    func bitmapUnknownCanvas() {
        let rect = SubtitleFrameCompositor.imageRect(
            position: CGRect(x: 0.1, y: 0.8, width: 0.8, height: 0.15),
            canvasSize: .zero,
            frameWidth: 1920, frameHeight: 1080
        )
        #expect(abs(rect.minX - 192) < 0.5)
        #expect(abs(rect.minY - 864) < 0.5)
        #expect(abs(rect.width - 1536) < 0.5)
        #expect(abs(rect.height - 162) < 0.5)
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
        compositor.update(cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("HELLO"))], enabled: false, delaySeconds: 0)
        #expect(compositor.composite(buffer, ptsSeconds: 5) === buffer)

        // Enabled with an active cue: output keeps the format and the bottom region gains bright pixels.
        compositor.update(cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("HELLO"))], enabled: true, delaySeconds: 0)
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

    @Test("rendered PiP frames apply timing changes without a cue or transport update")
    func compositeAppliesDelay() throws {
        let compositor = SubtitleFrameCompositor()
        let buffer = try blackFrame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let cues = [cue(1, 10, 12)]
        compositor.update(cues: cues, enabled: true, delaySeconds: 1.5)
        #expect(compositor.composite(buffer, ptsSeconds: 10.5) === buffer)
        #expect(compositor.composite(buffer, ptsSeconds: 11.5) !== buffer)
        #expect(compositor.composite(buffer, ptsSeconds: 13.5) === buffer)
        compositor.update(cues: cues, enabled: true, delaySeconds: -1.5)
        #expect(compositor.composite(buffer, ptsSeconds: 8.5) !== buffer)
        compositor.update(cues: cues, enabled: false, delaySeconds: -1.5)
        #expect(compositor.composite(buffer, ptsSeconds: 8.5) === buffer)
    }

    private func blackFrame(_ format: OSType) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, 720, 480, format, attrs as CFDictionary, &pb)
        return try #require(pb)
    }

    private func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> CFTypeRef? {
        CVBufferCopyAttachment(buffer, key, nil)
    }

    /// Audit DEC-3: the renderer describes the frame from the delivered buffer's attachments, so a
    /// composited frame that dropped them showed anamorphic content at coded size and HDR as SDR
    /// for exactly as long as a cue was on screen.
    @Test("a composited frame keeps the source's pixel aspect ratio and colour tags")
    func compositedFrameKeepsSourceAttachments() throws {
        let compositor = SubtitleFrameCompositor()
        compositor.update(cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("HELLO"))], enabled: true, delaySeconds: 0)

        let hdr = try blackFrame(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let aspect: NSDictionary = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 32,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: 27,
        ]
        CVBufferSetAttachment(hdr, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
        CVBufferSetAttachment(hdr, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(hdr, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(hdr, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)

        let out = compositor.composite(hdr, ptsSeconds: 5)
        #expect(out !== hdr)
        let par = attachment(out, kCVImageBufferPixelAspectRatioKey) as? NSDictionary
        #expect(par?[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? Int == 32)
        #expect(par?[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? Int == 27)
        #expect(attachment(out, kCVImageBufferTransferFunctionKey) as? String
                == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(attachment(out, kCVImageBufferColorPrimariesKey) as? String
                == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        #expect(attachment(out, kCVImageBufferYCbCrMatrixKey) as? String
                == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)

        let space = SubtitleFrameCompositor.renderColorSpace(for: hdr)
        #expect(space.name == CGColorSpace.itur_2100_PQ)
    }

    @Test("a recycled output buffer does not keep an earlier source's pixel aspect ratio")
    func recycledBufferDropsStaleAspect() throws {
        let compositor = SubtitleFrameCompositor()
        compositor.update(cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("HELLO"))], enabled: true, delaySeconds: 0)
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let anamorphic = try blackFrame(format)
        let aspect: NSDictionary = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 32,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: 27,
        ]
        CVBufferSetAttachment(anamorphic, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
        // Several rounds, so the pool hands a buffer that already held the ratio back out.
        for _ in 0..<4 { _ = compositor.composite(anamorphic, ptsSeconds: 5) }

        let square = try blackFrame(format)
        for _ in 0..<4 {
            let out = compositor.composite(square, ptsSeconds: 5)
            #expect(attachment(out, kCVImageBufferPixelAspectRatioKey) == nil)
        }
    }

    #if DualLayerDolbyVision
    /// The Profile 7 FEL route hands the renderer composed P010 frames carrying the Dolby Vision RPU
    /// and compatibility ID. In PiP with a cue up, the frame the layer receives is the compositor's
    /// copy: it has to carry the source frame's attachments (the CFString "1" among them, which the
    /// render server parses with `CFStringGetIntValue`) and must not inherit a previous frame's RPU
    /// from the recycled pool buffer, which is the stale-trims failure the design doc describes.
    @Test("a composited Dolby Vision frame carries its own RPU attachments and a recycled buffer drops stale ones")
    func compositedFrameCarriesDolbyVisionAttachments() throws {
        let compositor = SubtitleFrameCompositor()
        compositor.update(cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("HELLO"))], enabled: true, delaySeconds: 0)
        let format = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

        let rpuNAL: [UInt8] = [0x7C, 0x01, 0x19, 0x08, 0x42, 0xA5, 0x80]
        let dv = try blackFrame(format)
        DoviDisplayMetadata.attach(rpuNAL: rpuNAL, to: dv)
        let sourcePayload = try #require(attachment(dv, DoviDisplayMetadata.rpuDataKey as CFString) as? Data)

        // Several rounds, so the pool hands out a buffer that already held an RPU.
        for _ in 0..<4 {
            let out = compositor.composite(dv, ptsSeconds: 5)
            #expect(out !== dv)
            #expect(attachment(out, DoviDisplayMetadata.rpuDataKey as CFString) as? Data == sourcePayload)
            #expect(attachment(out, DoviDisplayMetadata.compatibilityIDKey as CFString) as? String == "1")
        }

        // A frame with no RPU (a bypass without display metadata) must not pick one up.
        let plain = try blackFrame(format)
        for _ in 0..<4 {
            let out = compositor.composite(plain, ptsSeconds: 5)
            #expect(attachment(out, DoviDisplayMetadata.rpuDataKey as CFString) == nil)
            #expect(attachment(out, DoviDisplayMetadata.compatibilityIDKey as CFString) == nil)
        }
    }
    #endif

    @Test("an untagged source renders through BT.709")
    func untaggedSourceFallsBackTo709() throws {
        let space = SubtitleFrameCompositor.renderColorSpace(for: try blackFrame(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        #expect(space.name == CGColorSpace.itur_709)
    }
}
