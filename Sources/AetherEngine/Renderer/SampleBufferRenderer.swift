import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Video renderer using AVSampleBufferDisplayLayer for optimal frame pacing.
///
/// Includes a small reorder buffer (4 frames) to handle B-frame decode
/// order from VTDecompressionSession. Frames are sorted by PTS before
/// being enqueued to the display layer in strict presentation order.
final class SampleBufferRenderer {

    let displayLayer: AVSampleBufferDisplayLayer

    /// Reorder buffer: collects frames from the decoder (which may arrive
    /// out of display order due to B-frames) and flushes them to the
    /// display layer in ascending PTS order.
    private let reorderLock = NSLock()
    private var reorderBuffer: [(CVPixelBuffer, CMTime)] = []
    private let reorderDepth = 4  // B-frame reorder (handles up to 3 consecutive B-frames)

    /// After a seek, frames decoded between the keyframe and the actual
    /// seek target should be dropped to prevent visual "fast forward".
    /// Set via `setSkipThreshold(_:)`, cleared automatically.
    private var skipUntilPTS: CMTime?

    /// Cached CMVideoFormatDescription for sample-buffer wrapping.
    /// Format descriptions are expensive to create (allocation + Core
    /// Foundation refcount) — cache keyed by pixel buffer dimensions +
    /// format so we only rebuild when the stream changes.
    private var cachedFormatDesc: CMVideoFormatDescription?
    private var cachedFormatKey: UInt64 = 0

    #if DEBUG
    private var loggedLayerFailed = false
    #endif

    init() {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        // HDR10 / Dolby Vision output: without this the compositor
        // treats the layer as SDR and clips BT.2020/PQ to Rec.709 —
        // we end up with a black or washed-out image on an HDR TV
        // that was correctly switched into HDR mode via AVDisplayCriteria.
        // tvOS 18+ replaced `wantsExtendedDynamicRangeContent` with the
        // more explicit `preferredDynamicRange` API.
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, *) {
            displayLayer.preferredDynamicRange = .high
        } else {
            #if os(iOS) || os(macOS)
            if #available(iOS 16.0, macOS 13.0, *) {
                displayLayer.wantsExtendedDynamicRangeContent = true
            }
            #endif
        }
    }

    /// After seek, drop frames with PTS before the target to prevent
    /// the visual "fast forward" effect from keyframe to seek target.
    func setSkipThreshold(_ time: CMTime?) {
        reorderLock.lock()
        skipUntilPTS = time
        reorderLock.unlock()
    }

    /// Enqueue a decoded video frame. Frames are buffered and reordered
    /// by PTS before being sent to the display layer.
    func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        reorderLock.lock()

        // Drop pre-seek frames (between keyframe and actual seek target)
        if let threshold = skipUntilPTS {
            if CMTimeCompare(pts, threshold) < 0 {
                reorderLock.unlock()
                return
            }
            skipUntilPTS = nil
        }

        // Insert into reorder buffer, sorted by PTS
        let ptsSeconds = CMTimeGetSeconds(pts)
        let insertIdx = reorderBuffer.firstIndex(where: {
            CMTimeGetSeconds($0.1) > ptsSeconds
        }) ?? reorderBuffer.endIndex
        reorderBuffer.insert((pixelBuffer, pts), at: insertIdx)

        // Flush oldest frames when buffer exceeds reorder depth
        while reorderBuffer.count > reorderDepth {
            let (pb, t) = reorderBuffer.removeFirst()
            reorderLock.unlock()
            flushFrame(pixelBuffer: pb, pts: t)
            reorderLock.lock()
        }

        reorderLock.unlock()
    }

    /// Discard all buffered and displayed frames (call on seek/stop).
    /// Uses flushAndRemoveImage to clear the currently visible frame
    /// immediately — prevents showing stale content after seeking.
    func flush() {
        reorderLock.lock()
        reorderBuffer.removeAll()
        // Drop the cached format description — a following load() may open
        // a stream with different color attachments at the same resolution,
        // and CMVideoFormatDescriptionCreateForImageBuffer snapshots those
        // into the description at creation time.
        cachedFormatDesc = nil
        cachedFormatKey = 0
        reorderLock.unlock()

        displayLayer.flushAndRemoveImage()
    }

    /// Flush the reorder buffer and send all frames to the display layer
    /// (call at EOF to drain the last frames).
    func drainReorderBuffer() {
        reorderLock.lock()
        let remaining = reorderBuffer
        reorderBuffer.removeAll()
        reorderLock.unlock()

        for (pb, t) in remaining {
            flushFrame(pixelBuffer: pb, pts: t)
        }
    }

    // MARK: - Internal

    private func flushFrame(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer, pts: pts) else {
            return
        }
        #if DEBUG
        if displayLayer.status == .failed, !loggedLayerFailed {
            loggedLayerFailed = true
            print("[Renderer] display layer failed: \(displayLayer.error?.localizedDescription ?? "nil")")
        }
        #endif
        displayLayer.enqueue(sampleBuffer)
    }

    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        // Reuse the format description unless dimensions or pixel format
        // changed — rebuilding per frame wastes an allocation and Core
        // Foundation refcount churn in the hot path.
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let key = (UInt64(width) << 40) | (UInt64(height) << 16) | UInt64(fmt & 0xFFFF)

        let desc: CMVideoFormatDescription
        if let cached = cachedFormatDesc, key == cachedFormatKey {
            desc = cached
        } else {
            var formatDesc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc
            )
            guard status == noErr, let new = formatDesc else { return nil }
            cachedFormatDesc = new
            cachedFormatKey = key
            desc = new
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr else { return nil }
        return sampleBuffer
    }
}
