import CoreGraphics
import CoreText
import Foundation
import MediaAccessibility

/// The user's system caption style (Settings > Accessibility > Subtitles & Captioning), for the
/// software host's text rendering, which has no AVKit legible output to apply it for it.
///
/// A field is non-nil only where the user chose something: the system's value in the user domain
/// differs from its factory default. (The system's `UseValue` / `UseContentIfAvailable` flag says
/// nothing about that. It only ranks the user's value against the content's, so it is carried per
/// field as a `Precedence` instead.) A system with nothing customised reads as `.standard` and
/// renders exactly as it did before this type existed.
///
/// Bitmap subtitles (PGS, DVB, VobSub) are pictures and are never restyled.
public struct SubtitleCaptionStyle: Sendable, Equatable {

    /// Text edge treatment, in the system's own vocabulary.
    public enum EdgeStyle: Sendable, Equatable {
        case none, raised, depressed, uniform, dropShadow
    }

    /// Who wins when a cue carries its own value for a field (an SRT `<font color>`, an ASS `\fn`).
    /// The engine's default look comes last either way.
    public enum Precedence: Sendable, Equatable {
        /// User, then cue, then engine default (the system's `UseValue`).
        case overridesCue
        /// Cue, then user, then engine default (the system's `UseContentIfAvailable`).
        case yieldsToCue
    }

    /// A value the user chose, and how it ranks against a cue's own.
    public struct Choice<Value: Sendable & Equatable>: Sendable, Equatable {
        public var value: Value
        public var precedence: Precedence
        public init(_ value: Value, precedence: Precedence = .overridesCue) {
            self.value = value
            self.precedence = precedence
        }

        /// The value to use given what the cue carries, by this field's precedence: `overridesCue`
        /// returns the user's value, `yieldsToCue` returns the cue's when it has one and the user's
        /// otherwise. A host applies this only to a field whose `Choice` is non-nil, and falls back to
        /// its own default for one that is nil.
        public func resolved(cue: Value?) -> Value {
            switch precedence {
            case .overridesCue: return value
            case .yieldsToCue: return cue ?? value
            }
        }
    }

    /// Family name or PostScript name of the font the user chose.
    public var fontName: Choice<String>?
    /// The user's character size relative to the default, 1 when untouched. Applied on top of the
    /// frame-relative base size, so the text stays proportionate at any resolution.
    public var sizeScale: Double
    public var textColor: Choice<SubtitleColor>?
    public var textOpacity: Choice<Double>?
    public var backgroundColor: Choice<SubtitleColor>?
    public var backgroundOpacity: Choice<Double>?
    /// The window is the rectangle behind the whole caption block, behind the per-line background.
    public var windowColor: Choice<SubtitleColor>?
    public var windowOpacity: Choice<Double>?
    public var edgeStyle: Choice<EdgeStyle>?

    public init(fontName: Choice<String>? = nil, sizeScale: Double = 1,
                textColor: Choice<SubtitleColor>? = nil, textOpacity: Choice<Double>? = nil,
                backgroundColor: Choice<SubtitleColor>? = nil, backgroundOpacity: Choice<Double>? = nil,
                windowColor: Choice<SubtitleColor>? = nil, windowOpacity: Choice<Double>? = nil,
                edgeStyle: Choice<EdgeStyle>? = nil) {
        self.fontName = fontName
        self.sizeScale = sizeScale
        self.textColor = textColor
        self.textOpacity = textOpacity
        self.backgroundColor = backgroundColor
        self.backgroundOpacity = backgroundOpacity
        self.windowColor = windowColor
        self.windowOpacity = windowOpacity
        self.edgeStyle = edgeStyle
    }

    /// No user preference: the engine's default look.
    public static let standard = SubtitleCaptionStyle()

    /// Default line background when the user has not chosen one: the engine's long-standing look.
    static let defaultBackgroundOpacity = 0.6

    // MARK: - Resolved values

    /// Text colour for a run, by the field's precedence; white when neither the user nor the cue has one.
    func resolvedTextColor(cueColor: SubtitleColor?) -> CGColor {
        let color = textColor?.resolved(cue: cueColor) ?? cueColor ?? SubtitleColor(r: 255, g: 255, b: 255)
        return Self.cgColor(color, opacity: textOpacity?.value ?? 1)
    }

    /// Font name for a run, by the field's precedence; nil when neither has one.
    func resolvedFontName(cueFont: String?) -> String? {
        fontName?.resolved(cue: cueFont) ?? cueFont
    }

    /// Line background; nil when the user has made it fully transparent.
    var resolvedBackground: CGColor? {
        let opacity = backgroundOpacity?.value ?? Self.defaultBackgroundOpacity
        guard opacity > 0 else { return nil }
        return Self.cgColor(backgroundColor?.value ?? SubtitleColor(r: 0, g: 0, b: 0), opacity: opacity)
    }

    /// Caption window; nil unless the user turned it on (the default has none).
    var resolvedWindow: CGColor? {
        guard let opacity = windowOpacity?.value, opacity > 0 else { return nil }
        return Self.cgColor(windowColor?.value ?? SubtitleColor(r: 0, g: 0, b: 0), opacity: opacity)
    }

    private static func cgColor(_ color: SubtitleColor, opacity: Double) -> CGColor {
        CGColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255, alpha: CGFloat(min(max(opacity, 0), 1)))
    }

    // MARK: - System values

    /// What MediaAccessibility reports, reduced to plain values so the mapping to a style can be
    /// tested without the user's settings. Each property is read from the user domain and from the
    /// factory default; it is the user's choice only when the two differ.
    struct SystemValues: Equatable {
        struct Reading<Value: Equatable>: Equatable {
            var user: Value
            var factory: Value
            /// The user domain's behaviour flag: precedence against content, not a sign of a change.
            var useValue: Bool
            init(user: Value, factory: Value, useValue: Bool = false) {
                self.user = user; self.factory = factory; self.useValue = useValue
            }
        }
        var fontName: Reading<String?>
        var sizeScale: Reading<Double>
        var textColor: Reading<SubtitleColor>
        var textOpacity: Reading<Double>
        var backgroundColor: Reading<SubtitleColor>
        var backgroundOpacity: Reading<Double>
        var windowColor: Reading<SubtitleColor>
        var windowOpacity: Reading<Double>
        var edgeStyle: Reading<EdgeStyle?>
    }

    init(_ system: SystemValues) {
        func chosen<V>(_ r: SystemValues.Reading<V>) -> Choice<V>? {
            r.user == r.factory ? nil : Choice(r.user, precedence: r.useValue ? .overridesCue : .yieldsToCue)
        }
        func chosenValue<V>(_ r: SystemValues.Reading<V?>) -> Choice<V>? {
            guard let value = r.user, r.user != r.factory else { return nil }
            return Choice(value, precedence: r.useValue ? .overridesCue : .yieldsToCue)
        }
        let size = system.sizeScale
        let scale = size.user.isFinite && size.user > 0 && size.user != size.factory ? size.user : 1
        self.init(fontName: chosenValue(system.fontName), sizeScale: scale,
                  textColor: chosen(system.textColor), textOpacity: chosen(system.textOpacity),
                  backgroundColor: chosen(system.backgroundColor),
                  backgroundOpacity: chosen(system.backgroundOpacity),
                  windowColor: chosen(system.windowColor), windowOpacity: chosen(system.windowOpacity),
                  edgeStyle: chosenValue(system.edgeStyle))
    }

    nonisolated static func edgeStyle(forSystem raw: Int) -> EdgeStyle? {
        switch MACaptionAppearanceTextEdgeStyle(rawValue: raw) {
        case .none?: return EdgeStyle.none
        case .raised?: return .raised
        case .depressed?: return .depressed
        case .uniform?: return .uniform
        case .dropShadow?: return .dropShadow
        default: return nil   // undefined: leave it to the default look
        }
    }

    /// The user's current style. Reads the system on every call, so it is cheap to call again after
    /// `observeChanges` fires but not meant for a per-frame loop.
    public static func current() -> SubtitleCaptionStyle {
        SubtitleCaptionStyle(systemValues())
    }

    private static func systemValues() -> SystemValues {
        typealias Domain = MACaptionAppearanceDomain
        func color(_ read: (Domain, UnsafeMutablePointer<MACaptionAppearanceBehavior>?) -> Unmanaged<CGColor>)
            -> SystemValues.Reading<SubtitleColor> {
            var behavior = MACaptionAppearanceBehavior.useContentIfAvailable
            let user = subtitleColor(read(.user, &behavior).takeRetainedValue())
            let factory = subtitleColor(read(.default, nil).takeRetainedValue())
            return .init(user: user, factory: factory, useValue: behavior == .useValue)
        }
        func opacity(_ read: (Domain, UnsafeMutablePointer<MACaptionAppearanceBehavior>?) -> CGFloat)
            -> SystemValues.Reading<Double> {
            var behavior = MACaptionAppearanceBehavior.useContentIfAvailable
            let user = Double(read(.user, &behavior))
            return .init(user: user, factory: Double(read(.default, nil)), useValue: behavior == .useValue)
        }
        func fontName(_ domain: Domain, _ behavior: UnsafeMutablePointer<MACaptionAppearanceBehavior>?) -> String? {
            let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(domain, behavior, .default)
                .takeRetainedValue()
            return CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        }

        var fontBehavior = MACaptionAppearanceBehavior.useContentIfAvailable
        let userFont = fontName(.user, &fontBehavior)
        var edgeBehavior = MACaptionAppearanceBehavior.useContentIfAvailable
        let userEdge = MACaptionAppearanceGetTextEdgeStyle(.user, &edgeBehavior)

        return SystemValues(
            fontName: .init(user: userFont, factory: fontName(.default, nil), useValue: fontBehavior == .useValue),
            sizeScale: .init(user: Double(MACaptionAppearanceGetRelativeCharacterSize(.user, nil)),
                             factory: Double(MACaptionAppearanceGetRelativeCharacterSize(.default, nil))),
            textColor: color(MACaptionAppearanceCopyForegroundColor),
            textOpacity: opacity(MACaptionAppearanceGetForegroundOpacity),
            backgroundColor: color(MACaptionAppearanceCopyBackgroundColor),
            backgroundOpacity: opacity(MACaptionAppearanceGetBackgroundOpacity),
            windowColor: color(MACaptionAppearanceCopyWindowColor),
            windowOpacity: opacity(MACaptionAppearanceGetWindowOpacity),
            edgeStyle: .init(user: edgeStyle(forSystem: userEdge.rawValue),
                             factory: edgeStyle(forSystem: MACaptionAppearanceGetTextEdgeStyle(.default, nil).rawValue),
                             useValue: edgeBehavior == .useValue))
    }

    private static func subtitleColor(_ color: CGColor) -> SubtitleColor {
        let rgb = CGColorSpace(name: CGColorSpace.sRGB).flatMap { color.converted(to: $0, intent: .defaultIntent, options: nil) } ?? color
        let c = rgb.components ?? []
        func byte(_ i: Int) -> UInt8 { i < c.count ? UInt8((min(max(c[i], 0), 1) * 255).rounded()) : 255 }
        // A grey-scale colour carries one component; the three channels are then the same.
        return c.count >= 3 ? SubtitleColor(r: byte(0), g: byte(1), b: byte(2))
                            : SubtitleColor(r: byte(0), g: byte(0), b: byte(0))
    }

    // MARK: - Change observation

    /// Token for `observeChanges`; the observation ends when it is released, and once it has the
    /// handler is not called again (a call already running on another thread may still finish).
    public final class Observation: @unchecked Sendable {
        private let tokens: [NSObjectProtocol]
        private let gate: Gate
        fileprivate init(tokens: [NSObjectProtocol], gate: Gate) {
            self.tokens = tokens
            self.gate = gate
        }
        deinit {
            gate.close()
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
                #if os(macOS)
                DistributedNotificationCenter.default().removeObserver(token)
                #endif
            }
        }
    }

    /// Closed when the token is released, so a notification that was already being delivered
    /// cannot reach the handler afterwards.
    fileprivate final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true
        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
        func close() { lock.lock(); open = false; lock.unlock() }
    }

    /// Calls `handler` with the new style whenever the user changes a caption setting. Fires only
    /// when the resolved style differs from the last one delivered, so a settings write that
    /// touches nothing this type reads is silent. Hold the returned token for as long as updates
    /// are wanted.
    ///
    /// The handler runs on an arbitrary thread, not the main actor, so hop before touching UI.
    public static func observeChanges(_ handler: @escaping @Sendable (SubtitleCaptionStyle) -> Void) -> Observation {
        observeChanges(startingFrom: current(), handler)
    }

    /// `observeChanges` for a caller that has just read the style and wants no second read.
    static func observeChanges(startingFrom initial: SubtitleCaptionStyle,
                               fireSink: (@Sendable (@escaping @Sendable (Notification) -> Void) -> Void)? = nil,
                               _ handler: @escaping @Sendable (SubtitleCaptionStyle) -> Void) -> Observation {
        let last = LastStyle(initial)
        let gate = Gate()
        let name = Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)
        let fire: @Sendable (Notification) -> Void = { _ in
            guard gate.isOpen else { return }
            let style = current()
            guard gate.isOpen, last.replace(with: style) else { return }
            handler(style)
        }
        fireSink?(fire)   // test seam: lets a test deliver a notification that is already in flight
        var tokens = [NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil, using: fire)]
        #if os(macOS)
        // The setting is changed in another process, and macOS delivers it on the distributed centre.
        tokens.append(DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: nil, using: fire))
        #endif
        return Observation(tokens: tokens, gate: gate)
    }

    private final class LastStyle: @unchecked Sendable {
        private let lock = NSLock()
        private var style: SubtitleCaptionStyle
        init(_ style: SubtitleCaptionStyle) { self.style = style }
        /// True when `new` differs from what was held.
        func replace(with new: SubtitleCaptionStyle) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard new != style else { return false }
            style = new
            return true
        }
    }
}
