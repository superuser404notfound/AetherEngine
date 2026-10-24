import Testing
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import MediaAccessibility
@testable import AetherEngine

/// The software host reads the system caption style itself (there is no AVKit legible output to
/// apply it), so what is tested is the mapping from the system's values to a style, how a style
/// resolves against a cue's own styling, and that a style change reaches the rendered overlay.
@Suite("System caption style for software subtitles")
struct SubtitleCaptionStyleTests {

    private typealias System = SubtitleCaptionStyle.SystemValues

    private static let white = SubtitleColor(r: 255, g: 255, b: 255)
    private static let black = SubtitleColor(r: 0, g: 0, b: 0)

    /// A system with nothing customised: the user domain reads what the factory default does.
    /// The window opacity is 0.5 with `UseValue` on purpose: the flag ranks the value against a
    /// cue's, it does not say the user changed anything.
    private static func untouched() -> System {
        System(fontName: .init(user: "Helvetica", factory: "Helvetica", useValue: true),
               sizeScale: .init(user: 1, factory: 1),
               textColor: .init(user: white, factory: white),
               textOpacity: .init(user: 1, factory: 1, useValue: true),
               backgroundColor: .init(user: black, factory: black),
               backgroundOpacity: .init(user: 0.5, factory: 0.5),
               windowColor: .init(user: black, factory: black),
               windowOpacity: .init(user: 0.5, factory: 0.5, useValue: true),
               edgeStyle: .init(user: .dropShadow, factory: .dropShadow, useValue: true))
    }

    private func components(_ color: CGColor) -> [CGFloat] { color.components ?? [] }

    // MARK: - Mapping

    @Test("a system with no customisation reads as the standard look, whatever its behaviour flags say")
    func untouchedIsStandard() {
        #expect(SubtitleCaptionStyle(Self.untouched()) == .standard)
    }

    @Test("only the properties that differ from the factory come through, each with its precedence")
    func overridesOnly() {
        var system = Self.untouched()
        system.fontName = .init(user: "Courier", factory: "Helvetica", useValue: true)
        system.textColor = .init(user: SubtitleColor(r: 255, g: 255, b: 0), factory: Self.white, useValue: false)
        system.backgroundOpacity = .init(user: 0, factory: 0.5, useValue: true)
        system.edgeStyle = .init(user: .uniform, factory: .dropShadow, useValue: true)
        system.sizeScale = .init(user: 1.5, factory: 1)

        let style = SubtitleCaptionStyle(system)
        #expect(style.fontName == .init("Courier", precedence: .overridesCue))
        #expect(style.textColor == .init(SubtitleColor(r: 255, g: 255, b: 0), precedence: .yieldsToCue))
        #expect(style.backgroundOpacity == .init(0, precedence: .overridesCue))
        #expect(style.edgeStyle == .init(.uniform, precedence: .overridesCue))
        #expect(style.sizeScale == 1.5)
        #expect(style.windowOpacity == nil)
        #expect(style.textOpacity == nil)
        #expect(style.backgroundColor == nil)
    }

    @Test("a user colour under UseContentIfAvailable is honoured when the cue has none, and yields when it has")
    func contentIfAvailable() {
        var system = Self.untouched()
        let green = SubtitleColor(r: 0, g: 255, b: 0)
        system.textColor = .init(user: green, factory: Self.white, useValue: false)
        let style = SubtitleCaptionStyle(system)
        #expect(components(style.resolvedTextColor(cueColor: nil)) == [0, 1, 0, 1])
        #expect(components(style.resolvedTextColor(cueColor: SubtitleColor(r: 255, g: 0, b: 0))) == [1, 0, 0, 1])

        system.textColor = .init(user: green, factory: Self.white, useValue: true)
        #expect(components(SubtitleCaptionStyle(system).resolvedTextColor(cueColor: SubtitleColor(r: 255, g: 0, b: 0))) == [0, 1, 0, 1])
    }

    @Test("a nonsense character size falls back to one")
    func invalidSize() {
        for bad in [0.0, -1.0, .nan] {
            var system = Self.untouched()
            system.sizeScale = .init(user: bad, factory: 1)
            #expect(SubtitleCaptionStyle(system).sizeScale == 1)
        }
    }

    @Test("system edge styles map one to one, and undefined means no preference")
    func edgeStyles() {
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 1) == SubtitleCaptionStyle.EdgeStyle.none)
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 2) == .raised)
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 3) == .depressed)
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 4) == .uniform)
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 5) == .dropShadow)
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 0) == nil)
        #expect(SubtitleCaptionStyle.edgeStyle(forSystem: 99) == nil)
    }

    @Test("reading the live system does not trap and is stable between reads")
    func liveRead() {
        #expect(SubtitleCaptionStyle.current() == SubtitleCaptionStyle.current())
    }

    // MARK: - Resolution

    @Test("text colour: the user's beats the cue's, the cue's beats white")
    func textColorPrecedence() {
        let cue = SubtitleColor(r: 255, g: 0, b: 0)
        #expect(components(SubtitleCaptionStyle.standard.resolvedTextColor(cueColor: cue)) == [1, 0, 0, 1])
        #expect(components(SubtitleCaptionStyle.standard.resolvedTextColor(cueColor: nil)) == [1, 1, 1, 1])
        let user = SubtitleCaptionStyle(textColor: .init(SubtitleColor(r: 0, g: 255, b: 0)), textOpacity: .init(0.5))
        #expect(components(user.resolvedTextColor(cueColor: cue)) == [0, 1, 0, 0.5])
    }

    @Test("background keeps the old look until the user changes it, and can be switched off")
    func backgroundResolution() {
        #expect(components(SubtitleCaptionStyle.standard.resolvedBackground!) == [0, 0, 0, 0.6])
        #expect(SubtitleCaptionStyle(backgroundOpacity: .init(0)).resolvedBackground == nil)
        let blue = SubtitleCaptionStyle(backgroundColor: .init(SubtitleColor(r: 0, g: 0, b: 255)), backgroundOpacity: .init(1))
        #expect(components(blue.resolvedBackground!) == [0, 0, 1, 1])
    }

    @Test("the window is off unless the user turned it on")
    func windowResolution() {
        #expect(SubtitleCaptionStyle.standard.resolvedWindow == nil)
        #expect(SubtitleCaptionStyle(windowOpacity: .init(0)).resolvedWindow == nil)
        #expect(components(SubtitleCaptionStyle(windowOpacity: .init(0.4)).resolvedWindow!) == [0, 0, 0, 0.4])
    }

    @Test("the user's font beats the cue's, and the size scales the frame-relative base")
    func fontAndSize() {
        let run = SubtitleTextRun(text: "x", color: nil, fontName: "Times-Roman")
        let cue = SubtitleFrameCompositor.font(for: run, baseSize: 40)
        let user = SubtitleFrameCompositor.font(for: run, baseSize: 40, style: SubtitleCaptionStyle(fontName: .init("Courier")))
        #expect(CTFontCopyPostScriptName(cue) as String == "Times-Roman")
        #expect(CTFontCopyPostScriptName(user) as String == "Courier")

        let yielding = SubtitleFrameCompositor.font(
            for: run, baseSize: 40, style: SubtitleCaptionStyle(fontName: .init("Courier", precedence: .yieldsToCue)))
        #expect(CTFontCopyPostScriptName(yielding) as String == "Times-Roman")
        let bare = SubtitleTextRun(text: "x", color: nil)
        let fallback = SubtitleFrameCompositor.font(
            for: bare, baseSize: 40, style: SubtitleCaptionStyle(fontName: .init("Courier", precedence: .yieldsToCue)))
        #expect(CTFontCopyPostScriptName(fallback) as String == "Courier")

        let base = SubtitleFrameCompositor.textLayout(frameWidth: 1920, frameHeight: 1080)
        let big = SubtitleFrameCompositor.textLayout(frameWidth: 1920, frameHeight: 1080, sizeScale: 2)
        #expect(big.fontSize == base.fontSize * 2)
        #expect(big.maxTextWidth == base.maxTextWidth)
    }

    // MARK: - Rendering

    /// How many pixels hold each exact RGBA value (nothing for fully transparent ones).
    private func histogram(_ image: CGImage) -> [UInt32: Int] {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return [:] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let words = data.assumingMemoryBound(to: UInt32.self)
        var out: [UInt32: Int] = [:]
        for i in 0..<(image.width * image.height) where words[i] >> 24 != 0 { out[words[i], default: 0] += 1 }
        return out
    }

    /// Pixels with alpha above zero, and pixels that are exactly opaque white.
    private func pixelCounts(_ image: CGImage) -> (visible: Int, white: Int) {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return (-1, -1) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var visible = 0, white = 0
        for i in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            if bytes[i + 3] > 0 { visible += 1 }
            if bytes[i] == 255 && bytes[i + 1] == 255 && bytes[i + 2] == 255 && bytes[i + 3] == 255 { white += 1 }
        }
        return (visible, white)
    }

    private static let goldenStandardVisible = 4352
    private static let goldenStandardWhite = 410

    private let cue = SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .text("Caption style"))

    @Test("a transparent background, a window and an outline change what is drawn")
    func overlayFollowsStyle() throws {
        func render(_ style: SubtitleCaptionStyle) throws -> (visible: Int, white: Int) {
            pixelCounts(try #require(SubtitleFrameCompositor.renderOverlay(
                for: [cue], frameWidth: 640, frameHeight: 360, style: style)))
        }
        let standard = try render(.standard)
        let bare = try render(SubtitleCaptionStyle(backgroundOpacity: .init(0)))
        let windowed = try render(SubtitleCaptionStyle(backgroundOpacity: .init(0), windowOpacity: .init(1)))
        let outlined = try render(SubtitleCaptionStyle(backgroundOpacity: .init(0), edgeStyle: .init(.uniform)))
        #expect(bare.visible > 0)
        #expect(bare.visible < standard.visible)
        #expect(windowed.visible > bare.visible)
        #expect(outlined.visible > bare.visible)
        // The outline sits behind the glyphs: it adds pixels around them and takes none from them.
        #expect(bare.white > 0)
        #expect(outlined.white == bare.white)
    }

    @Test("a translucent text colour is not laid over the outline, with or without a line background",
          arguments: [0.0, 0.6])
    func translucentTextOverOutline(backgroundOpacity: Double) throws {
        func render(_ edge: SubtitleCaptionStyle.Choice<SubtitleCaptionStyle.EdgeStyle>?) throws -> [UInt32: Int] {
            histogram(try #require(SubtitleFrameCompositor.renderOverlay(
                for: [cue], frameWidth: 640, frameHeight: 360,
                style: SubtitleCaptionStyle(textOpacity: .init(0.5),
                                            backgroundOpacity: .init(backgroundOpacity), edgeStyle: edge))))
        }
        let bare = try render(nil)
        let outlined = try render(.init(.uniform))
        // The glyph interior is the translucent text over whatever is behind it: the most common
        // pixel value that is not the line background itself.
        let backgroundValue: UInt32 = backgroundOpacity > 0 ? 0x99000000 : 0
        let interior = try #require(bare.filter { $0.key != backgroundValue }.max { $0.value < $1.value }?.key)
        #expect(bare[interior]! > 100)
        #expect(outlined[interior] == bare[interior])
        // The line background survives under the outline's layer.
        #expect(outlined[backgroundValue, default: 0] >= bare[backgroundValue, default: 0] - 2000)
    }

    @Test("opaque text keeps solid glyph edges inside its outline")
    func opaqueEdgesStaySolid() throws {
        func alphas(_ style: SubtitleCaptionStyle) throws -> [UInt8] {
            let image = try #require(SubtitleFrameCompositor.renderOverlay(
                for: [cue], frameWidth: 640, frameHeight: 360, style: style))
            let ctx = try #require(CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<(image.width * image.height)).map { bytes[$0 * 4 + 3] }
        }
        let bare = try alphas(SubtitleCaptionStyle(backgroundOpacity: .init(0)))
        let outlined = try alphas(SubtitleCaptionStyle(backgroundOpacity: .init(0), edgeStyle: .init(.uniform)))
        // Every pixel the bare glyph only partly covers sits inside the outline, so it is solid ink.
        // The few hairline pixels (glyph coverage in the single digits) lie on the outline's own
        // antialiased outer boundary and may be a little under, so those are held to a lower bar.
        // The knock-out this replaced left 65% of these edge pixels below 230.
        let edges = bare.indices.filter { bare[$0] > 0 && bare[$0] < 255 }
        #expect(edges.count > 100)
        let thin = edges.filter { outlined[$0] < 250 }
        #expect(thin.count * 20 <= edges.count, "\(thin.count) of \(edges.count) edge pixels below alpha 250")
        let weak = edges.filter { bare[$0] >= 64 && outlined[$0] < 240 }
        #expect(weak.isEmpty, "\(weak.count) edge pixels of real coverage below alpha 240")
    }

    @Test("the default style renders the same overlay as before styles existed")
    func standardIsUnchanged() throws {
        let plain = try #require(SubtitleFrameCompositor.renderOverlay(for: [cue], frameWidth: 640, frameHeight: 360))
        let styled = try #require(SubtitleFrameCompositor.renderOverlay(for: [cue], frameWidth: 640, frameHeight: 360,
                                                                        style: .standard))
        #expect(plain.dataProvider?.data == styled.dataProvider?.data)
        // Not only equal to itself: the long-standing look measured when this type was introduced
        // (opaque white text on a 60% black line background), so a change to the defaults shows here.
        // The tolerance absorbs glyph-rendering differences between system versions.
        let counts = pixelCounts(plain)
        #expect(abs(counts.visible - Self.goldenStandardVisible) <= Self.goldenStandardVisible / 25,
                "visible \(counts.visible)")
        #expect(abs(counts.white - Self.goldenStandardWhite) <= max(20, Self.goldenStandardWhite / 10),
                "white \(counts.white)")
        let background = histogram(plain).filter { $0.key == 0x99000000 }   // alpha 0.6, premultiplied black
        #expect(background.values.first ?? 0 > counts.visible / 2)
    }

    private func frameBytes(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return Data(bytes: CVPixelBufferGetBaseAddress(buffer)!,
                    count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }

    @Test("a style change reaches the next composited frame, not just the next cue")
    func styleChangeInvalidatesCache() throws {
        var source: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &source)
        try #require(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        let input = try #require(source)
        CVPixelBufferLockBaseAddress(input, [])
        memset(CVPixelBufferGetBaseAddress(input), 0x40, CVPixelBufferGetBytesPerRow(input) * 180)
        CVPixelBufferUnlockBaseAddress(input, [])

        let compositor = SubtitleFrameCompositor(styleProvider: { .standard }, observesSystemStyle: false)
        compositor.update(cues: [cue], enabled: true, delaySeconds: 0)
        let before = frameBytes(compositor.composite(input, ptsSeconds: 1))
        #expect(before != frameBytes(input))
        #expect(before == frameBytes(compositor.composite(input, ptsSeconds: 1.1)))

        compositor.setStyle(SubtitleCaptionStyle(backgroundOpacity: .init(0), windowOpacity: .init(1)))
        let after = frameBytes(compositor.composite(input, ptsSeconds: 1.2))
        #expect(after != before)
    }

    @Test("the system style is read once, on the first enable, and never while disabled")
    func styleReadIsLazyAndSingle() {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let reads = Counter()
        let compositor = SubtitleFrameCompositor(styleProvider: { _ = reads.bump(); return .standard },
                                                 observesSystemStyle: true)
        #expect(reads.value == 0)
        compositor.update(cues: [], enabled: false, delaySeconds: 0)
        #expect(reads.value == 0)
        compositor.update(cues: [], enabled: true, delaySeconds: 0)
        compositor.update(cues: [], enabled: true, delaySeconds: 0)
        #expect(reads.value == 1)
    }

    @Test("an overlay is never served in a style other than the current one")
    func cacheKeyedByStyle() throws {
        var source: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &source)
        try #require(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        let input = try #require(source)
        let compositor = SubtitleFrameCompositor(styleProvider: { .standard }, observesSystemStyle: false)
        compositor.update(cues: [cue], enabled: true, delaySeconds: 0)
        let standard = frameBytes(compositor.composite(input, ptsSeconds: 1))
        // Same cue set, different style: the cache entry from the first frame must not answer.
        compositor.setStyle(SubtitleCaptionStyle(backgroundOpacity: .init(0)))
        let bare = frameBytes(compositor.composite(input, ptsSeconds: 1.1))
        #expect(bare != standard)
        compositor.setStyle(.standard)
        #expect(frameBytes(compositor.composite(input, ptsSeconds: 1.2)) == standard)
    }

    @Test("a notification already in flight cannot reach the handler once the token is released")
    func observationStops() {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            private var fire: (@Sendable (Notification) -> Void)?
            func bump() { lock.lock(); calls += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
            func store(_ f: @escaping @Sendable (Notification) -> Void) { lock.lock(); fire = f; lock.unlock() }
            func deliver() { lock.lock(); let f = fire; lock.unlock(); f?(Notification(name: .init("x"))) }
        }
        // The seeded style differs from the live one, so an open observation always has news to deliver.
        let seed = SubtitleCaptionStyle(backgroundOpacity: .init(0.123))

        // Control, on an observation of its own: an open one delivers.
        let control = Box()
        let open = SubtitleCaptionStyle.observeChanges(startingFrom: seed, fireSink: { control.store($0) }) { _ in
            control.bump()
        }
        control.deliver()
        #expect(control.count == 1)
        withExtendedLifetime(open) {}

        // The observation under test never delivers before release, so the delivery after it is its
        // first and nothing but the gate can stop it (dedup has nothing to drop). Releasing the token
        // removes the observers, but a delivery already under way holds the closure.
        let box = Box()
        var observation: SubtitleCaptionStyle.Observation? = SubtitleCaptionStyle.observeChanges(
            startingFrom: seed, fireSink: { box.store($0) }) { _ in box.bump() }
        observation = nil
        box.deliver()
        #expect(box.count == 0)
        _ = observation
    }
}
