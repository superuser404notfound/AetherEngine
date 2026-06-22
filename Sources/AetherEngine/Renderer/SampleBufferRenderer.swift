import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Video renderer using AVSampleBufferDisplayLayer for optimal frame pacing.
///
/// Includes a small reorder buffer (4 frames) to handle B-frame decode
/// order from VTDecompressionSession. Frames are sorted by PTS before
/// being enqueued to the display layer in strict presentation order.
final class SampleBufferRenderer: @unchecked Sendable {

    private(set) var displayLayer: AVSampleBufferDisplayLayer

    /// B-frame reorder buffer (4 frames): collects decoder output, flushes to display layer in ascending PTS order. Third tuple slot carries per-frame HDR10+ T.35 SEI bytes, paired through the reorder to kCMSampleAttachmentKey_HDR10PlusPerFrameData.
    private let reorderLock = NSLock()
    private var reorderBuffer: [(CVPixelBuffer, CMTime, Data?)] = []
    private let reorderDepth = 4  // handles up to 3 consecutive B-frames

    /// Drop frames before this PTS after a seek (prevents keyframe-to-target fast-forward). Cleared after the first passing frame.
    private var skipUntilPTS: CMTime?

    /// Cached CMVideoFormatDescription keyed by dimensions + pixel format + colorimetry. CMVideoFormatDescriptionCreateForImageBuffer snapshots color attachments at creation, so a mid-stream colorimetry change at same dimensions must invalidate the cache. Guarded by reorderLock; nil'd by flush().
    private var cachedFormatDesc: CMVideoFormatDescription?
    private var cachedFormatKey: FormatDescriptionKey?

    /// Cache key for cachedFormatDesc. Colorimetry fields are Strings (not CF references) so the struct stays Equatable without CF identity traps.
    private struct FormatDescriptionKey: Equatable {
        var width: Int
        var height: Int
        var pixelFormat: OSType
        var primaries: String?
        var transfer: String?
        var matrix: String?
    }

    private var loggedLayerFailed = false
    private var loggedNotReady = false
    private var enqueueCount = 0
    private var hdr10PlusAttachedCount = 0

    init() {
        displayLayer = Self.makeDisplayLayer(isHDR: false)
    }

    // MARK: - Queue rendering target

    /// tvOS 18+ / iOS 18+ / macOS 15+: use AVSampleBufferVideoRenderer via displayLayer.sampleBufferRenderer. Calling the deprecated layer enqueue/flush/isReadyForMoreMediaData on tvOS 26+ with AVSampleBufferRenderSynchronizer fails with FigVideoQueueRemote -12080 after the first enqueue. Older OSes use the layer directly via AVQueuedSampleBufferRendering.
    var queueTarget: any AVQueuedSampleBufferRendering {
        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
            return displayLayer.sampleBufferRenderer
        }
        return displayLayer
    }

    /// Demux-loop back-pressure gate. Post-tvOS 18 split: reading the layer's own isReadyForMoreMediaData stays optimistically true even when the sampleBufferRenderer queue is full, causing FigVideoQueueRemote -12080 on over-enqueue.
    var isReadyForMoreMediaData: Bool {
        queueTarget.isReadyForMoreMediaData
    }

    private var queueStatus: AVQueuedSampleBufferRenderingStatus {
        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
            return displayLayer.sampleBufferRenderer.status
        }
        return displayLayer.status
    }

    private var queueError: Error? {
        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
            return displayLayer.sampleBufferRenderer.error
        }
        return displayLayer.error
    }

    private static func makeDisplayLayer(isHDR: Bool, gravity: AVLayerVideoGravity = .resizeAspect) -> AVSampleBufferDisplayLayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = gravity
        layer.preventsDisplaySleepDuringVideoPlayback = true
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, *) {
            layer.preferredDynamicRange = isHDR ? .high : .standard
        } else {
            #if os(iOS) || os(macOS)
            if #available(iOS 17.0, macOS 14.0, *) {
                layer.wantsExtendedDynamicRangeContent = isHDR
            }
            #endif
        }
        return layer
    }

    /// Opt the display layer into HDR mode. Pass true only when the decoder delivers raw HDR10/DV pixel buffers; false for SDR or tone-mapped output.
    func setHDROutput(_ isHDR: Bool) {
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, *) {
            displayLayer.preferredDynamicRange = isHDR ? .high : .standard
        } else {
            #if os(iOS) || os(macOS)
            if #available(iOS 17.0, macOS 14.0, *) {
                displayLayer.wantsExtendedDynamicRangeContent = isHDR
            }
            #endif
        }
    }

    func setSkipThreshold(_ time: CMTime?) {
        reorderLock.lock()
        skipUntilPTS = time
        reorderLock.unlock()
    }

    /// Enqueue a decoded frame through the B-frame reorder buffer. `hdr10PlusData` carries per-frame ST 2094-40 metadata serialised to T.35 SEI format for kCMSampleAttachmentKey_HDR10PlusPerFrameData.
    func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime, hdr10PlusData: Data? = nil) {
        reorderLock.lock()

        if let threshold = skipUntilPTS {
            if CMTimeCompare(pts, threshold) < 0 {
                reorderLock.unlock()
                return
            }
            skipUntilPTS = nil
        }

        let ptsSeconds = CMTimeGetSeconds(pts)
        let insertIdx = reorderBuffer.firstIndex(where: {
            CMTimeGetSeconds($0.1) > ptsSeconds
        }) ?? reorderBuffer.endIndex
        reorderBuffer.insert((pixelBuffer, pts, hdr10PlusData), at: insertIdx)

        while reorderBuffer.count > reorderDepth {
            let (pb, t, hdr) = reorderBuffer.removeFirst()
            reorderLock.unlock()
            flushFrame(pixelBuffer: pb, pts: t, hdr10PlusData: hdr)
            reorderLock.lock()
        }

        reorderLock.unlock()
    }

    /// Discard all buffered and displayed frames (seek/stop). Clears the currently visible frame immediately.
    func flush() {
        reorderLock.lock()
        reorderBuffer.removeAll()
        // Invalidate the format description cache; the next load() may open a stream with different colorimetry at the same resolution.
        cachedFormatDesc = nil
        cachedFormatKey = nil
        reorderLock.unlock()

        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) { }
        } else {
            displayLayer.flushAndRemoveImage()
        }
    }

    /// Send all buffered frames to the display layer (call at EOF).
    func drainReorderBuffer() {
        reorderLock.lock()
        let remaining = reorderBuffer
        reorderBuffer.removeAll()
        reorderLock.unlock()

        for (pb, t, hdr) in remaining {
            flushFrame(pixelBuffer: pb, pts: t, hdr10PlusData: hdr)
        }
    }

    // MARK: - Internal

    private func flushFrame(pixelBuffer: CVPixelBuffer, pts: CMTime, hdr10PlusData: Data?) {
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer, pts: pts) else {
            return
        }
        // HDR10+ attachment overrides any payload baked into the bitstream (VT may strip per-frame SEI on decode).
        if let hdr10PlusData {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_HDR10PlusPerFrameData,
                value: hdr10PlusData as CFData,
                attachmentMode: CMAttachmentMode(kCMAttachmentMode_ShouldPropagate)
            )
            hdr10PlusAttachedCount += 1
            if hdr10PlusAttachedCount == 1 || hdr10PlusAttachedCount == 30 || hdr10PlusAttachedCount % 600 == 0 {
                EngineLog.emit("[Renderer] HDR10+ attachment count: \(hdr10PlusAttachedCount) (last payload \(hdr10PlusData.count) bytes)", category: .swPlayback)
            }
        }
        // Recover from failed queue target (Synchronizer/controlTimebase handoff races can push it here; flush recovers it).
        let target = queueTarget
        if queueStatus == .failed {
            if !loggedLayerFailed {
                loggedLayerFailed = true
                EngineLog.emit("[Renderer] queue target failed at enqueue #\(enqueueCount + 1): \(queueError?.localizedDescription ?? "nil"), attempting recovery via flush()", category: .swPlayback)
            }
            target.flush()
        }
        if !target.isReadyForMoreMediaData, !loggedNotReady {
            loggedNotReady = true
            EngineLog.emit("[Renderer] isReadyForMoreMediaData=false at enqueue #\(enqueueCount + 1) status=\(statusName)", category: .swPlayback)
        }
        target.enqueue(sampleBuffer)

        enqueueCount += 1
        // Sparse milestones so a stall is distinguishable from "logging stopped at #30"; bounded to 4 lines/hour at 60 fps.
        if enqueueCount == 1 || enqueueCount == 30 || enqueueCount == 100 || enqueueCount == 1000 || enqueueCount == 5000 {
            EngineLog.emit("[Renderer] enqueue #\(enqueueCount): status=\(statusName) ready=\(queueTarget.isReadyForMoreMediaData) error=\(queueError?.localizedDescription ?? "nil")", category: .swPlayback)
        }
    }

    private var statusName: String {
        switch queueStatus {
        case .unknown: "unknown"
        case .rendering: "rendering"
        case .failed: "failed"
        @unknown default: "?"
        }
    }

    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        // Cache hit avoids CMVideoFormatDescriptionCreateForImageBuffer allocation + CF refcount churn on every frame.
        let key = FormatDescriptionKey(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
            primaries: CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil) as? String,
            transfer: CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String,
            matrix: CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        )

        // Guarded by reorderLock: flush() nils the cache from other threads.
        reorderLock.lock()
        let cachedDesc: CMVideoFormatDescription? =
            (cachedFormatKey == key) ? cachedFormatDesc : nil
        reorderLock.unlock()

        let desc: CMVideoFormatDescription
        if let cachedDesc {
            desc = cachedDesc
        } else {
            var formatDesc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc
            )
            guard status == noErr, let new = formatDesc else { return nil }
            reorderLock.lock()
            cachedFormatDesc = new
            cachedFormatKey = key
            reorderLock.unlock()
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
