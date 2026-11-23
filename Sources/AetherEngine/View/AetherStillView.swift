import Foundation
import QuartzCore
import AVFoundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A transparent surface the engine holds a picture on. Two uses:
///
/// - A host that renders the native path through AVKit rather than through `AetherPlayerView`
///   binds one with `AetherEngine.bindStillView(_:)`, so the engine has somewhere to hold the picture
///   across the item swap of an audio-track switch (`replaceCurrentItem` blanks the player layer
///   until the next item's first frame). Place it above the video and below the host's own chrome,
///   for instance at the top of `AVPlayerViewController.contentOverlayView`.
/// - A host hands one to `AetherEngine.holdOutgoingPicture(on:)` to keep the outgoing episode's
///   picture across its own next `load()` (AE#1113). The host may animate this view's frame and
///   alpha; the picture follows the frame inside the same animation.
///
/// It draws nothing and takes no input outside a hold.
@MainActor
public final class AetherStillView: PlatformBaseView, HeldStillSurface {

    /// How the held picture fills the view. Set it to the fill the host's own player uses, since the
    /// engine's `videoGravity` does not reach an AVKit-rendered picture.
    public var videoGravity: AVLayerVideoGravity = .resizeAspect

    private let presenter = HeldStillPresenter()

    #if canImport(UIKit)
    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }
    #elseif canImport(AppKit)
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }
    #endif

    // The still sits in an autoresizing subview of its own (`HeldStillPresenter.Mount`), so there
    // is no layout pass here: a resize inside the host's animation carries it along.
    func showStill(_ frame: CVPixelBuffer, gravity: AVLayerVideoGravity, isHDR: Bool) -> Bool {
        presenter.show(frame, gravity: videoGravity, isHDR: isHDR, mount: .subview(of: self))
    }

    func showCompositorStill(file: URL, pastFirstFrameBy offset: Double, gravity: AVLayerVideoGravity,
                             budgetSeconds: Double, deletesFileOnClear: Bool) async -> Bool {
        await presenter.show(file: file, pastFirstFrameBy: offset, gravity: videoGravity,
                             mount: .subview(of: self), budgetSeconds: budgetSeconds,
                             deletesFileOnClear: deletesFileOnClear)
    }

    func clearStill() { presenter.clear() }

    var isHoldingStill: Bool { presenter.isShowing }

    /// The subview the held picture is drawn in, nil while nothing is held. For tests.
    var heldStillMountView: PlatformBaseView? { presenter.mountedStillView }
}
