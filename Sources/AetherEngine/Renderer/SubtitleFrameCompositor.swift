import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation

/// SW-PiP Phase C: composites active subtitle cues into decoded software-path frames so the system
/// PiP window (which renders only the sample-buffer layer) shows subtitles. Enabled ONLY while
/// pictureInPictureActive; fullscreen subtitles stay with the host's on-frame overlay. Playback wins
/// over subtitles: every failure path returns the original buffer untouched.
///
/// Text cues follow the user's system caption style (`SubtitleCaptionStyle`), read once when the
/// compositor is first enabled and re-read when the setting changes; with nothing customised the
/// look is the default one.
final class SubtitleFrameCompositor: @unchecked Sendable {

    /// Nothing is read from the system here: the compositor sits in every software renderer and
    /// stays disabled outside PiP, so the style is loaded on the first `update(enabled: true)`.
    init(styleProvider: @escaping @Sendable () -> SubtitleCaptionStyle = SubtitleCaptionStyle.current,
         observesSystemStyle: Bool = true) {
        self.styleProvider = styleProvider
        self.observesSystemStyle = observesSystemStyle
    }

    struct TextLayout: Equatable {
        let fontSize: CGFloat
        let bottomMargin: CGFloat
        let maxTextWidth: CGFloat
    }

    /// Cue times and frame PTS share the source axis. Shift subtitle presentation only;
    /// playback rate already advances the frame clock in media seconds.
    nonisolated static func activeCues(in cues: [SubtitleCue], at seconds: Double,
                                       delaySeconds: Double = 0) -> [SubtitleCue] {
        let subtitleTime = seconds - delaySeconds
        guard seconds.isFinite, delaySeconds.isFinite, subtitleTime.isFinite else { return [] }
        return cues.filter { $0.startTime <= subtitleTime && subtitleTime < $0.endTime }
    }

    /// Default look: readable in a small window, resolution-independent.
    nonisolated static func textLayout(frameWidth: CGFloat, frameHeight: CGFloat,
                                       sizeScale: Double = 1) -> TextLayout {
        TextLayout(
            fontSize: frameHeight * 0.05 * CGFloat(sizeScale),
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
    private var delaySeconds: Double = 0
    /// Cache key of the overlay currently rendered (active cue ids); nil = no overlay cached.
    private var cachedCueIDs: [Int]?
    private var cachedOverlay: CIImage?
    /// The style `cachedOverlay` was drawn in. Compared on a hit, so an overlay rendered from a
    /// snapshot that a `setStyle` has since superseded can never be served.
    private var cachedStyle: SubtitleCaptionStyle?
    private var loggedFailure = false
    private let styleProvider: @Sendable () -> SubtitleCaptionStyle
    private let observesSystemStyle: Bool
    private var style: SubtitleCaptionStyle = .standard
    private var styleLoaded = false
    private var styleObservation: SubtitleCaptionStyle.Observation?

    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolFormat: (width: Int, height: Int, pixelFormat: OSType)?

    /// Any thread; called by the engine when its published cues or the PiP flag change.
    func update(cues: [SubtitleCue], enabled: Bool, delaySeconds: Double) {
        lock.lock()
        self.cues = cues
        self.enabled = enabled
        if delaySeconds.isFinite { self.delaySeconds = delaySeconds }
        let needsStyle = enabled && !styleLoaded
        lock.unlock()
        if needsStyle { loadStyle() }
    }

    /// The one system read, with the observation seeded from it. Runs outside the lock: a settings
    /// change can arrive on another thread and call `setStyle`.
    private func loadStyle() {
        let initial = styleProvider()
        let observation = observesSystemStyle
            ? SubtitleCaptionStyle.observeChanges(startingFrom: initial) { [weak self] in self?.setStyle($0) }
            : nil
        lock.lock()
        // A `setStyle` that got in first is newer than what was just read.
        if !styleLoaded {
            style = initial
            styleLoaded = true
        }
        if styleObservation == nil { styleObservation = observation }
        lock.unlock()
    }

    /// Any thread; the system caption style changed. The cached overlay was drawn in the old one.
    func setStyle(_ new: SubtitleCaptionStyle) {
        lock.lock()
        styleLoaded = true
        if new != style {
            style = new
            cachedCueIDs = nil
            cachedOverlay = nil
            cachedStyle = nil
        }
        lock.unlock()
    }

    /// Render thread. Returns the input buffer untouched on passthrough or ANY failure.
    func composite(_ buffer: CVPixelBuffer, ptsSeconds: Double) -> CVPixelBuffer {
        lock.lock()
        let enabled = self.enabled
        let cues = self.cues
        let delay = self.delaySeconds
        let style = self.style
        lock.unlock()
        guard enabled else { return buffer }

        let active = Self.activeCues(in: cues, at: ptsSeconds, delaySeconds: delay)
        guard !active.isEmpty else {
            lock.lock(); cachedCueIDs = nil; cachedOverlay = nil; cachedStyle = nil; lock.unlock()
            return buffer
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let overlay: CIImage
        lock.lock()
        let cacheHit = cachedCueIDs == active.map(\.id) && cachedStyle == style ? cachedOverlay : nil
        lock.unlock()
        if let cacheHit {
            overlay = cacheHit
        } else {
            guard let rendered = Self.renderOverlay(for: active, frameWidth: CGFloat(width), frameHeight: CGFloat(height),
                                                     style: style) else {
                logFailureOnce("overlay render failed")
                return buffer
            }
            overlay = CIImage(cgImage: rendered)
            lock.lock()
            cachedCueIDs = active.map(\.id)
            cachedOverlay = overlay
            cachedStyle = style
            lock.unlock()
        }

        guard let output = dequeueBuffer(width: width, height: height, pixelFormat: CVPixelBufferGetPixelFormatType(buffer)) else {
            logFailureOnce("pool exhausted")
            return buffer
        }
        // Audit DEC-3: the renderer builds the format description from the delivered buffer, so
        // the output has to carry the source's pixel aspect ratio and colour tags, or anamorphic
        // content shows at coded size and HDR drops to SDR for as long as a cue is up. Carried
        // before the render too, because CoreImage picks the YCbCr matrix from the destination.
        Self.carryAttachments(from: buffer, to: output)
        let base = CIImage(cvPixelBuffer: buffer)
        let composited = overlay.composited(over: base)
        ciContext.render(composited, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: Self.renderColorSpace(for: buffer))
        Self.carryAttachments(from: buffer, to: output)
        return output
    }

    /// The source's own colour space, so the render encodes the picture the way it was decoded
    /// (PQ and HLG included). BT.709 only when the source carries no usable tags.
    nonisolated static func renderColorSpace(for buffer: CVPixelBuffer) -> CGColorSpace {
        if let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate),
           let space = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue() {
            return space
        }
        return CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Replaces rather than adds: a recycled pool buffer can hold a previous source's tags.
    nonisolated static func carryAttachments(from source: CVPixelBuffer, to output: CVPixelBuffer) {
        CVBufferRemoveAllAttachments(output)
        CVBufferPropagateAttachments(source, output)
    }

    /// One CGImage per cue-set change: text cues bottom-up in the default look, image cues at their
    /// canvas-mapped rects. CG coordinate origin is bottom-left; layout values are top-left based,
    /// so y flips via frameHeight.
    nonisolated static func renderOverlay(for cues: [SubtitleCue], frameWidth: CGFloat, frameHeight: CGFloat,
                                          style: SubtitleCaptionStyle = .standard) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: Int(frameWidth), height: Int(frameHeight),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let layout = textLayout(frameWidth: frameWidth, frameHeight: frameHeight, sizeScale: style.sizeScale)
        var textBaselineFromBottom = layout.bottomMargin

        for cue in cues {
            switch cue.body {
            case .image(let image):
                let rectTopLeft = imageRect(position: image.position, canvasSize: image.canvasSize, frameWidth: frameWidth, frameHeight: frameHeight)
                let rect = CGRect(x: rectTopLeft.minX, y: frameHeight - rectTopLeft.maxY, width: rectTopLeft.width, height: rectTopLeft.height)
                ctx.draw(image.cgImage, in: rect)
            case .text(let text):
                drawTextBlock([SubtitleTextRun(text: text, color: nil)], placement: cue.placement,
                              in: ctx, layout: layout, style: style, frameWidth: frameWidth,
                              frameHeight: frameHeight, baselineFromBottom: &textBaselineFromBottom)
            case .richText(let runs):
                drawTextBlock(runs, placement: cue.placement,
                              in: ctx, layout: layout, style: style, frameWidth: frameWidth,
                              frameHeight: frameHeight, baselineFromBottom: &textBaselineFromBottom)
            }
        }
        return ctx.makeImage()
    }

    /// Split a run sequence at its line breaks, keeping each run's styling. A run spanning a break
    /// contributes to both lines.
    nonisolated static func lines(from runs: [SubtitleTextRun]) -> [[SubtitleTextRun]] {
        var out: [[SubtitleTextRun]] = [[]]
        for run in runs {
            let parts = run.text.components(separatedBy: "\n")
            for (i, part) in parts.enumerated() {
                if i > 0 { out.append([]) }
                if !part.isEmpty { out[out.count - 1].append(run.withText(part)) }
            }
        }
        return out.filter { !$0.isEmpty }
    }

    /// Font for a run. ASS `\fs` is relative to libavcodec's default style size
    /// (`ASS_DEFAULT_FONT_SIZE` = 16), so it scales the layout's base size rather than naming
    /// pixels, which keeps a cue proportionate at any frame height.
    nonisolated static func font(for run: SubtitleTextRun, baseSize: CGFloat,
                                 style: SubtitleCaptionStyle = .standard) -> CTFont {
        let size = run.fontSize.map { baseSize * CGFloat($0) / 16.0 } ?? baseSize
        // The field's precedence orders the user's font and the cue's; the default comes last.
        let name = style.resolvedFontName(cueFont: run.fontName) ?? "HelveticaNeue-Medium"
        let base = CTFontCreateWithName(name as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if run.isBold { traits.insert(.traitBold) }
        if run.isItalic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    /// Bottom-left origin for a text block under an explicit placement (#233).
    ///
    /// ASS numpad alignment: 1 to 3 bottom, 4 to 6 middle, 7 to 9 top, left to right within each
    /// row. With a `\pos` the point is the anchor and the alignment says which part of the block
    /// sits on it; without one the alignment picks a corner inset by `margin`. A position with no
    /// alignment takes the ASS default of 2 (bottom centre). Normalized positions measure y from
    /// the top, the context draws bottom-up, so y flips here.
    nonisolated static func blockOrigin(placement: SubtitleTextPlacement, blockSize: CGSize,
                                        frameWidth: CGFloat, frameHeight: CGFloat,
                                        margin: CGFloat) -> CGPoint {
        let an = placement.alignment ?? 2
        let column = (an - 1) % 3     // 0 left, 1 centre, 2 right
        let row = (an - 1) / 3        // 0 bottom, 1 middle, 2 top

        guard let position = placement.position else {
            let x: CGFloat = column == 0 ? margin
                : column == 1 ? (frameWidth - blockSize.width) / 2
                : frameWidth - blockSize.width - margin
            let y: CGFloat = row == 0 ? margin
                : row == 1 ? (frameHeight - blockSize.height) / 2
                : frameHeight - blockSize.height - margin
            return CGPoint(x: x, y: y)
        }

        let anchorX = position.x * frameWidth
        let anchorY = frameHeight - position.y * frameHeight
        let x: CGFloat = column == 0 ? anchorX
            : column == 1 ? anchorX - blockSize.width / 2
            : anchorX - blockSize.width
        let y: CGFloat = row == 0 ? anchorY
            : row == 1 ? anchorY - blockSize.height / 2
            : anchorY - blockSize.height
        return CGPoint(x: x, y: y)
    }

    private nonisolated static func drawTextBlock(_ runs: [SubtitleTextRun],
                                                  placement: SubtitleTextPlacement?,
                                                  in ctx: CGContext, layout: TextLayout,
                                                  style: SubtitleCaptionStyle,
                                                  frameWidth: CGFloat, frameHeight: CGFloat,
                                                  baselineFromBottom: inout CGFloat) {
        let split = lines(from: runs)
        guard !split.isEmpty else { return }
        let pad = layout.fontSize * 0.4

        // Build every line first: a placed block needs its own measured size before it can be put
        // anywhere, and the default stack needs the same measurements anyway.
        let built: [(line: CTLine, runs: [SubtitleTextRun], bounds: CGRect)] = split.compactMap {
            guard let attributed = attributedLine($0, layout: layout, style: style) else { return nil }
            let ctLine = CTLineCreateWithAttributedString(attributed)
            return (ctLine, $0, CTLineGetBoundsWithOptions(ctLine, .useOpticalBounds))
        }
        guard !built.isEmpty else { return }

        let boxWidth = min((built.map(\.bounds.width).max() ?? 0) + pad * 2, layout.maxTextWidth)
        let lineHeights = built.map { $0.bounds.height + pad }

        var originX = (frameWidth - boxWidth) / 2
        var cursorY = baselineFromBottom
        if let placement {
            let blockHeight = lineHeights.reduce(0, +) + layout.fontSize * 0.2 * CGFloat(built.count - 1)
            let origin = blockOrigin(placement: placement,
                                     blockSize: CGSize(width: boxWidth, height: blockHeight),
                                     frameWidth: frameWidth, frameHeight: frameHeight,
                                     margin: layout.bottomMargin)
            originX = origin.x
            cursorY = origin.y
        }

        // The window sits behind every line's own background, one rectangle around the block.
        if let window = style.resolvedWindow {
            let blockHeight = lineHeights.reduce(0, +) + layout.fontSize * 0.2 * CGFloat(built.count - 1)
            ctx.setFillColor(window)
            ctx.fill(CGRect(x: originX, y: cursorY - pad / 2, width: boxWidth, height: blockHeight)
                .insetBy(dx: -layout.fontSize * 0.3, dy: -layout.fontSize * 0.3))
        }

        // Bottom-up, so the last line is drawn first and reads top-down on screen.
        for (index, entry) in built.enumerated().reversed() {
            let boxHeight = lineHeights[index]
            if let background = style.resolvedBackground {
                ctx.setFillColor(background)
                ctx.fill(CGRect(x: originX, y: cursorY - pad / 2, width: boxWidth, height: boxHeight)
                    .insetBy(dx: -2, dy: -2))
            }
            let textX = originX + pad
            let baseline = cursorY + pad / 2 - entry.bounds.minY
            let edge = style.edgeStyle?.value
            ctx.saveGState()
            if edge == .uniform {
                // The outline is its own pass underneath the text, in a transparency layer: the fill
                // is copied over the stroke inside the layer, so the glyph shows the text colour alone
                // (a translucent colour does not pick up the stroke's inner half) and the layer
                // composites onto the line background and window as one unit, leaving both intact.
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.saveGState()
                applyEdge(edge, in: ctx, fontSize: layout.fontSize)
                ctx.textPosition = CGPoint(x: textX, y: baseline)
                CTLineDraw(entry.line, ctx)
                ctx.restoreGState()
                ctx.setBlendMode(.copy)
            } else {
                applyEdge(edge, in: ctx, fontSize: layout.fontSize)
            }
            ctx.setTextDrawingMode(.fill)
            ctx.textPosition = CGPoint(x: textX, y: baseline)
            CTLineDraw(entry.line, ctx)
            if edge == .uniform { ctx.endTransparencyLayer() }
            ctx.restoreGState()
            drawStrikethrough(entry.runs, on: entry.line, in: ctx, at: CGPoint(x: textX, y: baseline),
                              layout: layout, style: style)
            cursorY += boxHeight + layout.fontSize * 0.2
        }
        if placement == nil { baselineFromBottom = cursorY }
    }

    /// Edge treatment for the glyphs about to be drawn, as the system's five styles: an outline for
    /// uniform (a stroke-only setup, drawn as a pass of its own before the fill), a soft offset
    /// shadow, and hard one-sided shadows for raised and depressed. The context's y axis points up,
    /// so raised puts the shadow below the glyph.
    nonisolated static func applyEdge(_ edge: SubtitleCaptionStyle.EdgeStyle?, in ctx: CGContext,
                                      fontSize: CGFloat) {
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let step = max(1, fontSize * 0.06)
        switch edge {
        case .uniform:
            ctx.setTextDrawingMode(.stroke)
            ctx.setStrokeColor(black)
            ctx.setLineWidth(step * 1.5 * 2)
            ctx.setLineJoin(.round)
        case .dropShadow:
            ctx.setShadow(offset: CGSize(width: step, height: -step), blur: step * 1.5, color: black)
        case .raised:
            ctx.setShadow(offset: CGSize(width: 0, height: -step), blur: 0, color: black)
        case .depressed:
            ctx.setShadow(offset: CGSize(width: 0, height: step), blur: 0, color: black)
        case .none?, nil:
            break
        }
    }

    private nonisolated static func attributedLine(_ runs: [SubtitleTextRun],
                                                   layout: TextLayout,
                                                   style: SubtitleCaptionStyle) -> CFAttributedString? {
        guard let attributed = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0) else { return nil }
        CFAttributedStringBeginEditing(attributed)
        for run in runs {
            var attributes: [CFString: Any] = [
                kCTFontAttributeName: font(for: run, baseSize: layout.fontSize, style: style),
                kCTForegroundColorAttributeName: style.resolvedTextColor(cueColor: run.color)
            ]
            if run.isUnderlined {
                attributes[kCTUnderlineStyleAttributeName] = CTUnderlineStyle.single.rawValue
            }
            guard let piece = CFAttributedStringCreate(
                kCFAllocatorDefault, run.text as CFString, attributes as CFDictionary) else { continue }
            CFAttributedStringReplaceAttributedString(
                attributed, CFRange(location: CFAttributedStringGetLength(attributed), length: 0), piece)
        }
        CFAttributedStringEndEditing(attributed)
        return CFAttributedStringGetLength(attributed) > 0 ? attributed : nil
    }

    /// CoreText has no strikethrough attribute (unlike AppKit's NSAttributedString), so struck runs
    /// get a rule drawn over their own glyph range.
    private nonisolated static func drawStrikethrough(_ runs: [SubtitleTextRun], on line: CTLine,
                                                      in ctx: CGContext, at origin: CGPoint,
                                                      layout: TextLayout, style: SubtitleCaptionStyle) {
        var index = 0
        for run in runs {
            let length = run.text.utf16.count
            defer { index += length }
            guard run.isStruckThrough, length > 0 else { continue }
            let startX = CTLineGetOffsetForStringIndex(line, index, nil)
            let endX = CTLineGetOffsetForStringIndex(line, index + length, nil)
            let size = CTFontGetSize(font(for: run, baseSize: layout.fontSize, style: style))
            ctx.setStrokeColor(style.resolvedTextColor(cueColor: run.color))
            ctx.setLineWidth(max(1, size * 0.06))
            let y = origin.y + size * 0.28
            ctx.move(to: CGPoint(x: origin.x + startX, y: y))
            ctx.addLine(to: CGPoint(x: origin.x + endX, y: y))
            ctx.strokePath()
        }
    }

    /// Audit DEC-5: `reset()` clears the pool under `lock` from the actor while the decode thread can
    /// be in here, so the pool reference is only read and replaced under the same lock.
    private func dequeueBuffer(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
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
        cachedStyle = nil
        pool = nil
        poolFormat = nil
        loggedFailure = false
        lock.unlock()
    }
}
