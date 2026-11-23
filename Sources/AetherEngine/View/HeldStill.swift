import Foundation
import QuartzCore
import AVFoundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A surface the engine can hold a picture on across an in-place item swap (AE#711 follow-up):
/// `AetherPlayerView` when the engine renders into it, `AetherStillView` when the host renders the
/// native path through AVKit and binds one for this alone.
@MainActor
protocol HeldStillSurface: AnyObject {
    /// `gravity` is the engine's; a surface that takes its fill from the host ignores it.
    func showStill(_ frame: CVPixelBuffer, gravity: AVLayerVideoGravity, isHDR: Bool) -> Bool
    /// Shows the frame `offset` seconds past the first frame of a video-only file through a player of
    /// its own, so the system compositor colours it (Dolby Vision without a displayable base layer).
    /// `deletesFileOnClear` hands the file to the surface, which deletes it when the still goes.
    func showCompositorStill(file: URL, pastFirstFrameBy offset: Double, gravity: AVLayerVideoGravity,
                             budgetSeconds: Double, deletesFileOnClear: Bool) async -> Bool
    func clearStill()
    var isHoldingStill: Bool { get }
}

/// The one-sample layer both surfaces show the held picture with. A sample-buffer layer rather than
/// `contents`, so an HDR frame is presented through its colour attachments the way the software path
/// presents every frame.
@MainActor
final class HeldStillPresenter {
    /// Where a still goes. `AetherPlayerView` lays it into its own layer tree and sizes it in
    /// `layout(_:)`. `AetherStillView` gives each still a subview of its own whose layer IS the still
    /// (AE#1113): a host animates that view's frame (the Up Next tile), and a bare sublayer resized
    /// from `layoutSubviews` runs Core Animation's own 0.25 s default instead of the host's curve,
    /// so the picture would trail its tile. An autoresizing subview moves inside the host's animation.
    enum Mount {
        case sublayer(of: CALayer?, bounds: CGRect)
        case subview(of: PlatformBaseView)
    }

    private(set) var layer: AVSampleBufferDisplayLayer?
    private(set) var playerLayer: AVPlayerLayer?
    private var player: AVPlayer?
    /// The subview a `.subview` mount put the still in, removed with it.
    private var mountedView: PlatformBaseView?
    /// A compositor file the still owns, deleted with it.
    private var ownedFile: URL?

    var isShowing: Bool { layer != nil || playerLayer != nil }

    /// The still's own view on a `.subview` mount, for tests.
    var mountedStillView: PlatformBaseView? { mountedView }

    /// The compositor form of `show`: a muted player seeks frame-exactly to `offset` past the video
    /// track's first frame, on the player's own clock (AVFoundation applies the init's edit list, so the
    /// file's raw timestamps are not that clock), behind an invisible layer that turns visible once the
    /// frame is displayable. False (and nothing shown)
    /// when the item fails, a `clear()` intervenes, or `budgetSeconds` runs out first.
    func show(file: URL, pastFirstFrameBy offset: Double, gravity: AVLayerVideoGravity,
              mount: Mount, budgetSeconds: Double, deletesFileOnClear: Bool = false) async -> Bool {
        clear()
        if deletesFileOnClear { ownedFile = file }
        let player = AVPlayer()
        player.isMuted = true
        player.actionAtItemEnd = .pause
        #if os(iOS) || os(tvOS)
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        #endif
        let item = AVPlayerItem(url: file)
        player.replaceCurrentItem(with: item)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard let still = mountPlayerLayer(mount) else {
            CATransaction.commit()
            clear()
            return false
        }
        still.player = player
        still.videoGravity = gravity
        setVisible(false, still)
        CATransaction.commit()
        self.player = player
        playerLayer = still

        let deadline = ContinuousClock.now + .seconds(budgetSeconds)
        // Audit GPU-206: through `gateTick`, so a cancelled task ends the wait instead of spinning the main
        // actor until the deadline (a cancelled `Task.sleep` returns at once).
        func waitFor(_ condition: () -> Bool) async -> Bool {
            while !condition() {
                guard item.status != .failed, ContinuousClock.now < deadline,
                      await DisplayCriteriaController.gateTick(milliseconds: 4, isCurrent: { playerLayer === still })
                else { return false }
            }
            return playerLayer === still
        }
        guard await waitFor({ item.status == .readyToPlay }) else { abandon(still); return false }
        let track = try? await item.asset.loadTracks(withMediaType: .video).first
        let firstFrame = (try? await track?.load(.timeRange))?.start ?? .zero
        guard playerLayer === still else { return false }
        let target = CMTimeAdd(firstFrame.isNumeric ? firstFrame : .zero,
                               CMTime(seconds: max(0, offset), preferredTimescale: 90_000))
        guard await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero),
              await waitFor({ still.isReadyForDisplay }) else { abandon(still); return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setVisible(true, still)
        CATransaction.commit()
        return true
    }

    private func abandon(_ still: AVPlayerLayer) {
        guard playerLayer === still else { return }
        clear()
    }

    /// False when the frame cannot be wrapped for display; nothing is shown then.
    func show(_ frame: CVPixelBuffer, gravity: AVLayerVideoGravity, isHDR: Bool, mount: Mount) -> Bool {
        clear()
        guard let sample = Self.sample(frame) else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard let still = mountSampleLayer(mount) else {
            CATransaction.commit()
            return false
        }
        still.videoGravity = gravity
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            still.preferredDynamicRange = isHDR ? .high : .standard
        } else {
            #if os(iOS) || os(macOS)
            still.wantsExtendedDynamicRangeContent = isHDR
            #endif
        }
        still.sampleBufferRenderer.enqueue(sample)
        layer = still
        CATransaction.commit()
        return true
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let view = mountedView {
            view.removeFromSuperview()
            mountedView = nil
        } else {
            playerLayer?.removeFromSuperlayer()
            layer?.removeFromSuperlayer()
        }
        CATransaction.commit()
        if playerLayer != nil {
            player?.replaceCurrentItem(with: nil)
            player = nil
            playerLayer = nil
        }
        layer?.sampleBufferRenderer.flush()
        layer = nil
        if let file = ownedFile {
            ownedFile = nil
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Hides the compositor still until it is displayable. On a subview mount through the view:
    /// AppKit owns a backing layer's opacity and may write it back from the view.
    private func setVisible(_ visible: Bool, _ still: CALayer) {
        guard let view = mountedView else {
            still.opacity = visible ? 1 : 0
            return
        }
        #if canImport(UIKit)
        view.alpha = visible ? 1 : 0
        #else
        view.alphaValue = visible ? 1 : 0
        #endif
    }

    /// Sizes a `.sublayer` mount's still. A `.subview` mount resizes itself with its parent.
    func layout(_ bounds: CGRect) {
        guard mountedView == nil else { return }
        layer?.frame = bounds
        playerLayer?.frame = bounds
    }

    private func mountSampleLayer(_ mount: Mount) -> AVSampleBufferDisplayLayer? {
        switch mount {
        case .sublayer(let host, let bounds):
            guard let host else { return nil }
            let still = AVSampleBufferDisplayLayer()
            host.addSublayer(still)
            still.frame = bounds
            return still
        case .subview(let parent):
            #if canImport(UIKit)
            let view = SampleStillView(frame: parent.bounds)
            guard let still = view.layer as? AVSampleBufferDisplayLayer else { return nil }
            #else
            let still = AVSampleBufferDisplayLayer()
            let view = LayerBackedStillView(frame: parent.bounds, backing: still)
            #endif
            install(view, in: parent)
            return still
        }
    }

    private func mountPlayerLayer(_ mount: Mount) -> AVPlayerLayer? {
        switch mount {
        case .sublayer(let host, let bounds):
            guard let host else { return nil }
            let still = AVPlayerLayer()
            host.addSublayer(still)
            still.frame = bounds
            return still
        case .subview(let parent):
            #if canImport(UIKit)
            let view = PlayerStillView(frame: parent.bounds)
            guard let still = view.layer as? AVPlayerLayer else { return nil }
            #else
            let still = AVPlayerLayer()
            let view = LayerBackedStillView(frame: parent.bounds, backing: still)
            #endif
            install(view, in: parent)
            return still
        }
    }

    private func install(_ view: PlatformBaseView, in parent: PlatformBaseView) {
        #if canImport(UIKit)
        view.isUserInteractionEnabled = false
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        view.autoresizingMask = [.width, .height]
        #endif
        parent.addSubview(view)
        mountedView = view
    }

    private static func sample(_ frame: CVPixelBuffer) -> CMSampleBuffer? {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescriptionOut: &description
        ) == noErr, let description else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

#if canImport(UIKit)
/// A still's own view, so UIKit resizes the still inside the host's animation (see `Mount`).
private final class SampleStillView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
}

private final class PlayerStillView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
}
#elseif canImport(AppKit)
/// A still's own view, backed by the still layer itself (see `Mount`).
private final class LayerBackedStillView: NSView {
    private let backing: CALayer

    init(frame: NSRect, backing: CALayer) {
        self.backing = backing
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { backing }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif
