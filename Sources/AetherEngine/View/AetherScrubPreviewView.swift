import Foundation
import QuartzCore
import AVFoundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The scrub preview surface for sources whose pictures only the system compositor can colour:
/// Dolby Vision Profile 5 and AV1 Profile 10.0 (`AetherEngine.scrubPreviewDrawsInView`). Their
/// base layer is IPT-PQ, and no still API applies the RPU, so the engine cannot hand out a correct
/// `CGImage` for them. This view plays a one-keyframe item through its own muted `AVPlayer`, and
/// the compositor draws it the way it draws the playing picture.
///
/// Fill it with `AetherEngine.showScrubPreview(atSeconds:in:)` and call `clear()` when the preview
/// goes away, which releases its decoder. Two players alternate, so the outgoing picture stays up
/// until the next one is ready instead of blanking between positions.
@MainActor
public final class AetherScrubPreviewView: PlatformBaseView {

    /// How the preview fills the view.
    public var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet { for layer in playerLayers { layer.videoGravity = videoGravity } }
    }

    private let players = [AVPlayer(), AVPlayer()]
    private lazy var playerLayers: [AVPlayerLayer] = players.map { AVPlayerLayer(player: $0) }
    private var front = 0
    private var shownURL: URL?
    private var request = 0

    #if canImport(UIKit)
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutPlayerLayers()
    }
    #elseif canImport(AppKit)
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setUp()
    }

    public override func layout() {
        super.layout()
        layoutPlayerLayers()
    }
    #endif

    private func setUp() {
        #if canImport(UIKit)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        #endif
        let host: CALayer? = layer
        for (player, layer) in zip(players, playerLayers) {
            player.isMuted = true
            player.actionAtItemEnd = .pause
            #if os(iOS) || os(tvOS)
            player.allowsExternalPlayback = false
            player.preventsDisplaySleepDuringVideoPlayback = false
            #endif
            layer.videoGravity = videoGravity
            layer.opacity = 0
            host?.addSublayer(layer)
        }
    }

    private func layoutPlayerLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in playerLayers { layer.frame = bounds }
        CATransaction.commit()
    }

    /// Drops both items, which releases their decoders, and clears the picture.
    public func clear() {
        request &+= 1
        shownURL = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (player, layer) in zip(players, playerLayers) {
            player.replaceCurrentItem(with: nil)
            layer.opacity = 0
        }
        CATransaction.commit()
    }

    /// Shows the one-keyframe file at `url`. False when a newer request superseded this one, or the
    /// item did not become displayable within two seconds; the previous picture stays up then.
    func present(_ url: URL, budget: Duration = .seconds(2)) async -> Bool {
        if url == shownURL { return true }
        request &+= 1
        let mine = request
        let back = 1 - front
        let item = AVPlayerItem(url: url)
        players[back].replaceCurrentItem(with: item)
        let deadline = ContinuousClock.now + budget
        while !(item.status == .readyToPlay && playerLayers[back].isReadyForDisplay) {
            // Audit GPU-206: a cancelled task ends the wait at its next tick instead of spinning the main
            // actor until the deadline (a cancelled `Task.sleep` returns at once).
            guard item.status != .failed, ContinuousClock.now < deadline,
                  await DisplayCriteriaController.gateTick(milliseconds: 4, isCurrent: { true }) else {
                if mine == request { players[back].replaceCurrentItem(with: nil) }
                return false
            }
            guard mine == request else { return false }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayers[back].opacity = 1
        playerLayers[front].opacity = 0
        CATransaction.commit()
        players[front].replaceCurrentItem(with: nil)
        front = back
        shownURL = url
        return true
    }
}
