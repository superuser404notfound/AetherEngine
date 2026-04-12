import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Video renderer using AVSampleBufferDisplayLayer for optimal frame pacing.
///
/// Apple handles NV12→RGB conversion, vsync alignment, and cadence
/// correction internally — eliminating the 33/50ms judder that occurs
/// with CAMetalLayer + CADisplayLink at non-matching frame rates
/// (e.g. 25fps content on a 60Hz display).
///
/// The display layer is added to the same AVSampleBufferRenderSynchronizer
/// as the audio renderer, so Apple handles A/V sync automatically.
final class SampleBufferRenderer {

    /// The display layer to embed in the host view hierarchy.
    let displayLayer: AVSampleBufferDisplayLayer

    init() {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
    }

    /// Enqueue a decoded video frame for display.
    /// Apple handles frame pacing, color conversion (NV12→RGB),
    /// and vsync alignment.
    func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer, pts: pts) else {
            return
        }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }

    /// Flush pending frames (call on seek).
    func flush() {
        displayLayer.flush()
    }

    // MARK: - Internal

    /// Create a CMSampleBuffer wrapping a decoded CVPixelBuffer with timing info.
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
