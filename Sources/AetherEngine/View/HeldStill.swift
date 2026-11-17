import Foundation
import QuartzCore
import AVFoundation

/// A surface the engine can hold a picture on across an in-place item swap (AE#711 follow-up):
/// `AetherPlayerView` when the engine renders into it, `AetherStillView` when the host renders the
/// native path through AVKit and binds one for this alone.
@MainActor
protocol HeldStillSurface: AnyObject {
    /// `gravity` is the engine's; a surface that takes its fill from the host ignores it.
    func showStill(_ frame: CVPixelBuffer, gravity: AVLayerVideoGravity, isHDR: Bool) -> Bool
    /// Shows the frame `offset` seconds past the first frame of a video-only file through a player of
    /// its own, so the system compositor colours it (Dolby Vision without a displayable base layer).
    func showCompositorStill(file: URL, pastFirstFrameBy offset: Double, gravity: AVLayerVideoGravity,
                             budgetSeconds: Double) async -> Bool
    func clearStill()
    var isHoldingStill: Bool { get }
}

/// The one-sample layer both surfaces show the held picture with. A sample-buffer layer rather than
/// `contents`, so an HDR frame is presented through its colour attachments the way the software path
/// presents every frame.
@MainActor
final class HeldStillPresenter {
    private(set) var layer: AVSampleBufferDisplayLayer?
    private(set) var playerLayer: AVPlayerLayer?
    private var player: AVPlayer?

    var isShowing: Bool { layer != nil || playerLayer != nil }

    /// The compositor form of `show`: a muted player seeks frame-exactly to `offset` past the video
    /// track's first frame, on the player's own clock (AVFoundation applies the init's edit list, so the
    /// file's raw timestamps are not that clock), behind an invisible layer that turns visible once the
    /// frame is displayable. False (and nothing shown)
    /// when the item fails, a `clear()` intervenes, or `budgetSeconds` runs out first.
    func show(file: URL, pastFirstFrameBy offset: Double, gravity: AVLayerVideoGravity,
              on host: CALayer?, bounds: CGRect, budgetSeconds: Double) async -> Bool {
        clear()
        guard let host else { return false }
        let player = AVPlayer()
        player.isMuted = true
        player.actionAtItemEnd = .pause
        #if os(iOS) || os(tvOS)
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        #endif
        let item = AVPlayerItem(url: file)
        player.replaceCurrentItem(with: item)
        let still = AVPlayerLayer(player: player)
        still.videoGravity = gravity
        still.opacity = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.addSublayer(still)
        still.frame = bounds
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
        still.opacity = 1
        CATransaction.commit()
        return true
    }

    private func abandon(_ still: AVPlayerLayer) {
        guard playerLayer === still else { return }
        clear()
    }

    /// False when the frame cannot be wrapped for display; nothing is shown then.
    func show(_ frame: CVPixelBuffer, gravity: AVLayerVideoGravity, isHDR: Bool,
              on host: CALayer?, bounds: CGRect) -> Bool {
        clear()
        guard let host, let sample = Self.sample(frame) else { return false }
        let still = AVSampleBufferDisplayLayer()
        still.videoGravity = gravity
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            still.preferredDynamicRange = isHDR ? .high : .standard
        } else {
            #if os(iOS) || os(macOS)
            still.wantsExtendedDynamicRangeContent = isHDR
            #endif
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.addSublayer(still)
        still.frame = bounds
        still.sampleBufferRenderer.enqueue(sample)
        layer = still
        CATransaction.commit()
        return true
    }

    func clear() {
        if let playing = playerLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playing.removeFromSuperlayer()
            CATransaction.commit()
            player?.replaceCurrentItem(with: nil)
            player = nil
            playerLayer = nil
        }
        guard let still = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        still.removeFromSuperlayer()
        CATransaction.commit()
        still.sampleBufferRenderer.flush()
        layer = nil
    }

    func layout(_ bounds: CGRect) {
        layer?.frame = bounds
        playerLayer?.frame = bounds
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
