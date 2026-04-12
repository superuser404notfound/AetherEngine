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
    private let reorderDepth = 3  // B-frame reorder (~120ms latency, handles 2 B-frames)

    init() {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
    }

    /// Enqueue a decoded video frame. Frames are buffered and reordered
    /// by PTS before being sent to the display layer.
    func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        reorderLock.lock()

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

    /// Flush all buffered frames to the display layer (call on seek/stop).
    func flush() {
        reorderLock.lock()
        let remaining = reorderBuffer
        reorderBuffer.removeAll()
        reorderLock.unlock()

        // Don't enqueue remaining frames — they're stale after seek
        displayLayer.flush()
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
        displayLayer.enqueue(sampleBuffer)
    }

    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let desc = formatDesc else { return nil }

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
