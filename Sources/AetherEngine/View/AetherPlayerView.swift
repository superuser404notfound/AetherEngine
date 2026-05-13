import Foundation
import QuartzCore
import AVFoundation

#if canImport(UIKit)
import UIKit
import SwiftUI
#elseif canImport(AppKit)
import AppKit
import SwiftUI
#endif

/// A single render surface owned by AetherEngine.
///
/// The host embeds one instance (UIKit on iOS/tvOS, AppKit on macOS) and
/// hands it to `engine.bind(view:)`. The engine then attaches whichever
/// `CALayer` is active for the current source (an `AVPlayerLayer` for
/// AVPlayer-backed sessions, an `AVSampleBufferDisplayLayer` while the
/// legacy aether path still exists). The view swaps internally on layer
/// changes so the host never needs to know which backend is rendering.
///
/// During phases 1–3 of the engine refactor, both backends can be active
/// across sessions and the view may briefly host either kind of layer.
/// After the native-only collapse (1.0.0) the hosted layer is always an
/// `AVPlayerLayer`.
@MainActor
public final class AetherPlayerView: PlatformBaseView {

    private var hostedLayer: CALayer?

    #if canImport(UIKit)
    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    #elseif canImport(AppKit)
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    #endif

    private func commonInit() {
        #if canImport(UIKit)
        backgroundColor = .black
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.backgroundColor = CGColor.black
        #endif
    }

    // MARK: - Layout

    #if canImport(UIKit)
    public override func layoutSubviews() {
        super.layoutSubviews()
        applyLayerFrame()
    }
    #elseif canImport(AppKit)
    public override func layout() {
        super.layout()
        applyLayerFrame()
    }
    #endif

    private func applyLayerFrame() {
        guard let hosted = hostedLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Engine-only attachment

    /// Engine-internal. Replace whichever layer is currently hosted with
    /// `layer`. Synchronous, runs on the main actor, no implicit
    /// animations so swaps don't flash. Idempotent if the same layer is
    /// already attached.
    func attach(_ layer: CALayer) {
        if hostedLayer === layer { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer?.removeFromSuperlayer()
        #if canImport(UIKit)
        self.layer.addSublayer(layer)
        #elseif canImport(AppKit)
        self.layer?.addSublayer(layer)
        #endif
        layer.frame = bounds
        hostedLayer = layer
        CATransaction.commit()
    }

    /// Engine-internal. Remove the current hosted layer without
    /// replacement (used on unbind / teardown).
    func detach() {
        guard let hosted = hostedLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.removeFromSuperlayer()
        hostedLayer = nil
        CATransaction.commit()
    }
}

// MARK: - Platform base view alias

#if canImport(UIKit)
public typealias PlatformBaseView = UIView
#elseif canImport(AppKit)
public typealias PlatformBaseView = NSView
#endif

// MARK: - SwiftUI wrapper

#if canImport(UIKit)
/// SwiftUI surface for embedding AetherEngine playback.
///
/// ```swift
/// AetherPlayerSurface(engine: engine)
///     .ignoresSafeArea()
/// ```
public struct AetherPlayerSurface: UIViewRepresentable {
    private let engine: AetherEngine

    public init(engine: AetherEngine) {
        self.engine = engine
    }

    public func makeUIView(context: Context) -> AetherPlayerView {
        let view = AetherPlayerView()
        engine.bind(view: view)
        return view
    }

    public func updateUIView(_ uiView: AetherPlayerView, context: Context) {
        // No-op. State updates flow through engine's @Published properties.
    }

    public static func dismantleUIView(_ uiView: AetherPlayerView, coordinator: ()) {
        // The engine releases its weak ref when the view deinits, but
        // explicit unbind keeps the layer removed promptly on teardown.
        Task { @MainActor in
            uiView.detach()
        }
    }
}
#elseif canImport(AppKit)
public struct AetherPlayerSurface: NSViewRepresentable {
    private let engine: AetherEngine

    public init(engine: AetherEngine) {
        self.engine = engine
    }

    public func makeNSView(context: Context) -> AetherPlayerView {
        let view = AetherPlayerView()
        engine.bind(view: view)
        return view
    }

    public func updateNSView(_ nsView: AetherPlayerView, context: Context) {}

    public static func dismantleNSView(_ nsView: AetherPlayerView, coordinator: ()) {
        Task { @MainActor in
            nsView.detach()
        }
    }
}
#endif
