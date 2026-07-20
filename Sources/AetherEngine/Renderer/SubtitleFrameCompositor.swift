import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation

/// SW-PiP Phase C: composites active subtitle cues into decoded software-path frames so the system
/// PiP window (which renders only the sample-buffer layer) shows subtitles. Enabled ONLY while
/// pictureInPictureActive; fullscreen subtitles stay with the host's on-frame overlay. Playback wins
/// over subtitles: every failure path returns the original buffer untouched.
final class SubtitleFrameCompositor: @unchecked Sendable {

    struct TextLayout: Equatable {
        let fontSize: CGFloat
        let bottomMargin: CGFloat
        let maxTextWidth: CGFloat
    }

    /// Plain window check; cue times and SW frame PTS share the source axis.
    nonisolated static func activeCues(in cues: [SubtitleCue], at seconds: Double) -> [SubtitleCue] {
        cues.filter { $0.startTime <= seconds && seconds < $0.endTime }
    }

    /// Default look: readable in a small window, resolution-independent.
    nonisolated static func textLayout(frameWidth: CGFloat, frameHeight: CGFloat) -> TextLayout {
        TextLayout(
            fontSize: frameHeight * 0.05,
            bottomMargin: frameHeight * 0.06,
            maxTextWidth: frameWidth * 0.9
        )
    }

    /// Canvas -> frame mapping per the SubtitleImage contract: `position` is NORMALIZED against the
    /// canvas; go to canvas pixels first, then map width-aligned and center-anchored vertically (a
    /// cropped rip's canvas can be taller than the coded video). A .zero canvas means the position is
    /// normalized against the video frame itself.
    nonisolated static func imageRect(position: CGRect, canvasSize: CGSize, frameWidth: CGFloat, frameHeight: CGFloat) -> CGRect {
        guard canvasSize != .zero, canvasSize.width > 0 else {
            return CGRect(
                x: position.minX * frameWidth,
                y: position.minY * frameHeight,
                width: position.width * frameWidth,
                height: position.height * frameHeight
            )
        }
        let px = position.minX * canvasSize.width
        let py = position.minY * canvasSize.height
        let scale = frameWidth / canvasSize.width
        let frameCenterY = frameHeight / 2
        let canvasCenterY = canvasSize.height / 2
        return CGRect(
            x: px * scale,
            y: frameCenterY + (py - canvasCenterY) * scale,
            width: position.width * canvasSize.width * scale,
            height: position.height * canvasSize.height * scale
        )
    }

    // MARK: - State

    private let lock = NSLock()
    private var cues: [SubtitleCue] = []
    private var enabled = false
    /// Cache key of the overlay currently rendered (active cue ids); nil = no overlay cached.
    private var cachedCueIDs: [Int]?
    private var cachedOverlay: CIImage?
    private var loggedFailure = false

    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolFormat: (width: Int, height: Int, pixelFormat: OSType)?

    /// Any thread; called by the engine when its published cues or the PiP flag change.
    func update(cues: [SubtitleCue], enabled: Bool) {
        lock.lock()
        self.cues = cues
        self.enabled = enabled
        lock.unlock()
    }

    /// Render thread. Returns the input buffer untouched on passthrough or ANY failure.
    func composite(_ buffer: CVPixelBuffer, ptsSeconds: Double) -> CVPixelBuffer {
        lock.lock()
        let enabled = self.enabled
        let cues = self.cues
        lock.unlock()
        guard enabled else { return buffer }

        let active = Self.activeCues(in: cues, at: ptsSeconds)
        guard !active.isEmpty else {
            lock.lock(); cachedCueIDs = nil; cachedOverlay = nil; lock.unlock()
            return buffer
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let overlay: CIImage
        lock.lock()
        let cacheHit = cachedCueIDs == active.map(\.id) ? cachedOverlay : nil
        lock.unlock()
        if let cacheHit {
            overlay = cacheHit
        } else {
            guard let rendered = Self.renderOverlay(for: active, frameWidth: CGFloat(width), frameHeight: CGFloat(height)) else {
                logFailureOnce("overlay render failed")
                return buffer
            }
            overlay = CIImage(cgImage: rendered)
            lock.lock()
            cachedCueIDs = active.map(\.id)
            cachedOverlay = overlay
            lock.unlock()
        }

        guard let output = dequeueBuffer(width: width, height: height, pixelFormat: CVPixelBufferGetPixelFormatType(buffer)) else {
            logFailureOnce("pool exhausted")
            return buffer
        }
        let base = CIImage(cvPixelBuffer: buffer)
        let composited = overlay.composited(over: base)
        ciContext.render(composited, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
        return output
    }

    /// One CGImage per cue-set change: text cues bottom-up in the default look, image cues at their
    /// canvas-mapped rects. CG coordinate origin is bottom-left; layout values are top-left based,
    /// so y flips via frameHeight.
    nonisolated static func renderOverlay(for cues: [SubtitleCue], frameWidth: CGFloat, frameHeight: CGFloat) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: Int(frameWidth), height: Int(frameHeight),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let layout = textLayout(frameWidth: frameWidth, frameHeight: frameHeight)
        var textBaselineFromBottom = layout.bottomMargin

        for cue in cues {
            switch cue.body {
            case .image(let image):
                let rectTopLeft = imageRect(position: image.position, canvasSize: image.canvasSize, frameWidth: frameWidth, frameHeight: frameHeight)
                let rect = CGRect(x: rectTopLeft.minX, y: frameHeight - rectTopLeft.maxY, width: rectTopLeft.width, height: rectTopLeft.height)
                ctx.draw(image.cgImage, in: rect)
            case .text(let text):
                drawTextBlock(text, in: ctx, layout: layout, frameWidth: frameWidth, baselineFromBottom: &textBaselineFromBottom)
            case .richText(let runs):
                let flat = runs.map(\.text).joined()
                drawTextBlock(flat, in: ctx, layout: layout, frameWidth: frameWidth, baselineFromBottom: &textBaselineFromBottom)
            }
        }
        return ctx.makeImage()
    }

    private nonisolated static func drawTextBlock(_ text: String, in ctx: CGContext, layout: TextLayout, frameWidth: CGFloat, baselineFromBottom: inout CGFloat) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, layout.fontSize, nil)
        for line in trimmed.split(separator: "\n").reversed() {
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            ]
            guard let attributed = CFAttributedStringCreate(kCFAllocatorDefault, String(line) as CFString, attributes as CFDictionary) else { continue }
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(ctLine, .useOpticalBounds)
            let pad = layout.fontSize * 0.4
            let boxWidth = min(bounds.width + pad * 2, layout.maxTextWidth)
            let boxHeight = bounds.height + pad
            let boxX = (frameWidth - boxWidth) / 2
            let boxY = baselineFromBottom - pad / 2

            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
            ctx.fill(CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight).insetBy(dx: -2, dy: -2))
            ctx.textPosition = CGPoint(x: boxX + pad, y: baselineFromBottom + pad / 2 - bounds.minY)
            CTLineDraw(ctLine, ctx)
            baselineFromBottom += boxHeight + layout.fontSize * 0.2
        }
    }

    private func dequeueBuffer(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer? {
        if poolFormat?.width != width || poolFormat?.height != height || poolFormat?.pixelFormat != pixelFormat {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attrs as CFDictionary, &newPool)
            pool = newPool
            poolFormat = (width, height, pixelFormat)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        return out
    }

    private func logFailureOnce(_ reason: String) {
        lock.lock()
        let first = !loggedFailure
        loggedFailure = true
        lock.unlock()
        if first {
            EngineLog.emit("[SubtitleCompositor] degraded to passthrough: \(reason)", category: .swPlayback)
        }
    }

    /// Session teardown: drop cache and pool.
    func reset() {
        lock.lock()
        cues = []
        enabled = false
        cachedCueIDs = nil
        cachedOverlay = nil
        pool = nil
        poolFormat = nil
        loggedFailure = false
        lock.unlock()
    }
}
