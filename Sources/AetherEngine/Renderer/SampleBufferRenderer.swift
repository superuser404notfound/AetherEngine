import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Video renderer using AVSampleBufferDisplayLayer for optimal frame pacing.
///
/// Includes a small reorder buffer (4 frames) to handle B-frame decode
/// order from VTDecompressionSession. Frames are sorted by PTS before
/// being enqueued to the display layer in strict presentation order.
/// Which display-layer flush operation a flush request maps to. Split out of SampleBufferRenderer.flush()
/// as a pure value so the seek-holds-frame contract (issue #90) is testable without a live
/// AVSampleBufferDisplayLayer.
enum DisplayFlushOp: Equatable {
    /// tvOS 18+/iOS 18+/macOS 15+: AVSampleBufferVideoRenderer.flush(removingDisplayedImage:).
    case rendererFlush(removingDisplayedImage: Bool)
    /// Legacy AVSampleBufferDisplayLayer.flushAndRemoveImage(), clears the visible frame.
    case removeImage
    /// Legacy AVSampleBufferDisplayLayer.flush(), keeps the last frame on screen (hold through seek).
    case holdImage

    static func resolve(removingDisplayedImage: Bool, modernRenderer: Bool) -> DisplayFlushOp {
        if modernRenderer {
            return .rendererFlush(removingDisplayedImage: removingDisplayedImage)
        }
        return removingDisplayedImage ? .removeImage : .holdImage
    }
}

final class SampleBufferRenderer: @unchecked Sendable {

    private(set) var displayLayer: AVSampleBufferDisplayLayer

    /// SW-PiP Phase C: composites active subtitle cues into frames while PiP is active (the system
    /// window renders only this layer, the host overlay cannot reach it).
    let subtitleCompositor = SubtitleFrameCompositor()

    /// B-frame reorder buffer (4 frames): collects decoder output, flushes to display layer in ascending PTS order. Third tuple slot carries per-frame HDR10+ T.35 SEI bytes, paired through the reorder to kCMSampleAttachmentKey_HDR10PlusPerFrameData.
    private let reorderLock = NSLock()
    private var reorderBuffer: [(CVPixelBuffer, CMTime, Data?)] = []
    private let reorderDepth = 4  // handles up to 3 consecutive B-frames

    /// Drop frames before this PTS after a seek (prevents keyframe-to-target fast-forward). Cleared after the first passing frame.
    private var skipUntilPTS: CMTime?

    /// Cached CMVideoFormatDescription keyed by dimensions + pixel format + colorimetry + pixel aspect ratio. CMVideoFormatDescriptionCreateForImageBuffer snapshots color AND aspect attachments at creation, so a mid-stream change at same dimensions must invalidate the cache; a PAR-less first frame froze a PAR-less description for the whole stream and collapsed anamorphic content to coded dimensions (#177). Guarded by reorderLock; nil'd by flush().
    private var cachedFormatDesc: CMVideoFormatDescription?
    private var cachedFormatKey: FormatDescriptionKey?

    /// Cache key for cachedFormatDesc. Colorimetry fields are Strings (not CF references) so the struct stays Equatable without CF identity traps.
    struct FormatDescriptionKey: Equatable {
        var width: Int
        var height: Int
        var pixelFormat: OSType
        var primaries: String?
        var transfer: String?
        var matrix: String?
        var parH: Int?
        var parV: Int?
    }

    private var loggedLayerFailed = false
    private var loggedNotReady = false
    /// Internal (not private) for #298 tests: the gate's job is that untimed frames never get here.
    private(set) var enqueueCount = 0
    private var hdr10PlusAttachedCount = 0

    /// #298: frames refused at the enqueue gate for carrying an unschedulable PTS. Guarded by `reorderLock`.
    private var _untimedFramesDropped = 0
    var untimedFramesDropped: Int {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return _untimedFramesDropped
    }

    /// #303: newest presentation timestamp this renderer has admitted, in seconds on the source
    /// axis, nil before the first frame. Recorded at admission into the reorder buffer, so it is
    /// past the unschedulable-PTS gate and the post-seek skip: everything counted here is decoded
    /// and will be displayed. Its lead over the synchronizer is the cushion an IO hiccup eats into.
    /// Guarded by `reorderLock`.
    private var _newestEnqueuedPtsSeconds: Double?
    var newestEnqueuedPtsSeconds: Double? {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return _newestEnqueuedPtsSeconds
    }

    init() {
        displayLayer = Self.makeDisplayLayer(isHDR: false)
    }

    /// #303: what the display did with the frames, as the renderer itself counts them. Our own
    /// counters can only see what we refuse; `numberOfDroppedFrames` also covers frames dropped for
    /// missing their display deadline, which is the class that shows up as a stutter.
    struct RenderMetrics: Sendable {
        let total: Int
        let dropped: Int
        let corrupted: Int
        let accumulatedDelay: TimeInterval
    }

    /// nil where the metrics cannot be asked for: an OS predating the API, or the pre-tvOS-18 path
    /// where the queue target is the display layer itself rather than an `AVSampleBufferVideoRenderer`.
    @MainActor
    func loadRenderMetrics() async -> RenderMetrics? {
        guard #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) else { return nil }
        guard let m = await displayLayer.sampleBufferRenderer.videoPerformanceMetrics else { return nil }
        return RenderMetrics(total: m.totalNumberOfFrames,
                             dropped: m.numberOfDroppedFrames,
                             corrupted: m.numberOfCorruptedFrames,
                             accumulatedDelay: m.totalAccumulatedFrameDelay)
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
        // Unavailable on visionOS, which has no display-sleep timer to hold off: the wearer's
        // displays follow presence, not an idle timer.
        #if !os(visionOS)
        layer.preventsDisplaySleepDuringVideoPlayback = true
        #endif
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) {
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
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) {
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

    /// #298: whether a frame's presentation timestamp can be scheduled at all. AV_NOPTS_VALUE reaches
    /// the decoder callback as `CMTime.invalid`, and CoreMedia builds a sample buffer from it without
    /// complaint (`CMSampleBufferCreateReadyWithImageBuffer` returns noErr, the sample's PTS reads back
    /// as NaN seconds), so the display queue is the first place it can do damage: the render
    /// synchronizer cannot pace an untimed sample. The deinterlace path already drops its untimestamped
    /// output for exactly this reason (see `SoftwareVideoDecoder.drainDecodedFrames`); this is the same
    /// rule one layer lower, so no producer can put an unschedulable sample in the queue.
    static func isSchedulable(_ pts: CMTime) -> Bool { pts.isNumeric }

    /// Enqueue a decoded frame through the B-frame reorder buffer. `hdr10PlusData` carries per-frame ST 2094-40 metadata serialised to T.35 SEI format for kCMSampleAttachmentKey_HDR10PlusPerFrameData.
    func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime, hdr10PlusData: Data? = nil) {
        reorderLock.lock()

        // Refused before the reorder buffer, not at flush: `CMTimeGetSeconds(.invalid)` is NaN and
        // every comparison against NaN is false, so an untimed frame lands past frames it should
        // precede and reorders its neighbours on the way out.
        guard Self.isSchedulable(pts) else {
            _untimedFramesDropped += 1
            let dropped = _untimedFramesDropped
            reorderLock.unlock()
            if dropped == 1 || dropped % 250 == 0 {
                EngineLog.emit("[Renderer] dropped \(dropped) frame(s) with no usable timestamp (unschedulable)",
                               category: .swPlayback)
            }
            return
        }

        if let threshold = skipUntilPTS {
            if CMTimeCompare(pts, threshold) < 0 {
                reorderLock.unlock()
                return
            }
            skipUntilPTS = nil
        }

        let ptsSeconds = CMTimeGetSeconds(pts)
        // #303: the frontier is the newest timestamp HELD, not the newest handed over. A B-frame run
        // arrives out of order, so taking the last call's timestamp would report a cushion that
        // shrinks and grows with the coding pattern rather than with the buffer.
        if ptsSeconds > (_newestEnqueuedPtsSeconds ?? -.greatestFiniteMagnitude) {
            _newestEnqueuedPtsSeconds = ptsSeconds
        }
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

    /// Discard all buffered frames. `removingDisplayedImage: true` (stop/teardown) also clears the visible
    /// frame; `false` (seek) holds the last frame on screen until the post-seek frame is enqueued, so a seek
    /// doesn't flash black between the old and new positions (matches the hardware path's hold-last-frame).
    func flush(removingDisplayedImage: Bool = true) {
        reorderLock.lock()
        reorderBuffer.removeAll()
        // #303: nothing is held any more, so the frontier is not a frontier. Left standing, a
        // backward seek would keep reporting the pre-seek timestamp and read as a cushion of
        // however far the seek travelled.
        _newestEnqueuedPtsSeconds = nil
        // Invalidate the format description cache; the next load() may open a stream with different colorimetry at the same resolution.
        cachedFormatDesc = nil
        cachedFormatKey = nil
        reorderLock.unlock()

        let modern: Bool
        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) { modern = true } else { modern = false }
        switch DisplayFlushOp.resolve(removingDisplayedImage: removingDisplayedImage, modernRenderer: modern) {
        case .rendererFlush(let remove):
            if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
                displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: remove) { }
            }
        case .removeImage:
            displayLayer.flushAndRemoveImage()
        case .holdImage:
            displayLayer.flush()
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
        let outputBuffer = subtitleCompositor.composite(pixelBuffer, ptsSeconds: pts.seconds)
        guard let sampleBuffer = createSampleBuffer(from: outputBuffer, pts: pts) else {
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

    /// Internal (not private) for #177 regression tests: the PAR-keyed cache behavior is the fix.
    func createSampleBuffer(from pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        // Cache hit avoids CMVideoFormatDescriptionCreateForImageBuffer allocation + CF refcount churn on every frame.
        let par = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferPixelAspectRatioKey, nil) as? NSDictionary
        let key = FormatDescriptionKey(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
            primaries: CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil) as? String,
            transfer: CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String,
            matrix: CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String,
            parH: (par?[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? NSNumber)?.intValue,
            parV: (par?[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? NSNumber)?.intValue
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
