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

    /// Fired when the display layer instance is replaced. The host view
    /// must swap the old sublayer out of its CALayer hierarchy and add
    /// the new one. Required because once the layer has ping-ponged
    /// between AVSampleBufferRenderSynchronizer and controlTimebase a
    /// few times, Apple's "undefined behavior" warning cashes in: the
    /// layer stays status=.rendering but silently stops consuming
    /// frames, and no flush() can revive it. Only a fresh layer works.
    var onLayerReplaced: ((AVSampleBufferDisplayLayer) -> Void)?

    /// Track the HDR output setting so we can restore it on recreated
    /// layers. Defaults match init().
    private var currentlyHDR: Bool = false

    /// Track the requested video gravity so it survives the
    /// recreate-display-layer-on-every-load() dance. The host sets it
    /// once via `setVideoGravity` and we reapply on every fresh layer.
    private var currentGravity: AVLayerVideoGravity = .resizeAspect

    /// Reorder buffer: collects frames from the decoder (which may arrive
    /// out of display order due to B-frames) and flushes them to the
    /// display layer in ascending PTS order. The third tuple slot
    /// carries optional per-frame HDR10+ metadata (T.35 SEI bytes) so
    /// the data stays paired with its frame across the reorder, then
    /// rides along to `flushFrame` where it's attached to the
    /// CMSampleBuffer via `kCMSampleAttachmentKey_HDR10PlusPerFrameData`.
    private let reorderLock = NSLock()
    private var reorderBuffer: [(CVPixelBuffer, CMTime, Data?)] = []
    private let reorderDepth = 4  // B-frame reorder (handles up to 3 consecutive B-frames)

    /// After a seek, frames decoded between the keyframe and the actual
    /// seek target should be dropped to prevent visual "fast forward".
    /// Set via `setSkipThreshold(_:)`, cleared automatically.
    private var skipUntilPTS: CMTime?

    /// Cached CMVideoFormatDescription for sample-buffer wrapping.
    /// Format descriptions are expensive to create (allocation + Core
    /// Foundation refcount), cache keyed by pixel buffer dimensions +
    /// format so we only rebuild when the stream changes.
    private var cachedFormatDesc: CMVideoFormatDescription?
    private var cachedFormatKey: UInt64 = 0

    /// Tracks whether at least one frame has reached the display layer
    /// since the last reset. Used by `AetherEngine.load()` to wait for
    /// the first video frame to actually render before returning, so
    /// callers that pause immediately after load (foreground reload)
    /// don't freeze on an empty layer (black). Touched from both the
    /// decoder callback thread (set) and the engine actor (read +
    /// reset), hence the explicit lock.
    private let firstFrameLock = NSLock()
    nonisolated(unsafe) private var _hasRenderedFirstFrame = false
    nonisolated var hasRenderedFirstFrame: Bool {
        firstFrameLock.lock(); defer { firstFrameLock.unlock() }
        return _hasRenderedFirstFrame
    }

    /// Reset the first-frame tracker. Call before waiting for the
    /// next post-flush frame so a pre-flush frame doesn't satisfy
    /// the wait spuriously.
    func resetFirstFrameTracking() {
        firstFrameLock.lock()
        _hasRenderedFirstFrame = false
        firstFrameLock.unlock()
    }

    private var loggedLayerFailed = false
    private var loggedNotReady = false
    private var enqueueCount = 0
    private var hdr10PlusAttachedCount = 0

    init() {
        displayLayer = Self.makeDisplayLayer(isHDR: false)
    }

    // MARK: - Queue rendering target

    /// The queue-rendering target the display layer exposes. On
    /// iOS 18 / tvOS 18 / macOS 15 Apple decoupled the queue ops onto a
    /// dedicated `AVSampleBufferVideoRenderer` reachable via
    /// `displayLayer.sampleBufferRenderer`; the layer's own `enqueue` /
    /// `flush` / `isReadyForMoreMediaData` were deprecated and route to
    /// the renderer internally. On tvOS 26+ at least, attaching the
    /// layer directly to `AVSampleBufferRenderSynchronizer` and calling
    /// the deprecated layer methods has been observed to fail with
    /// `FigVideoQueueRemote err=-12080` after the first enqueue,
    /// stopping rendering entirely. Going through the renderer instead
    /// resolves it. Older OSes use the layer directly via the same
    /// `AVQueuedSampleBufferRendering` protocol.
    var queueTarget: any AVQueuedSampleBufferRendering {
        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
            return displayLayer.sampleBufferRenderer
        }
        return displayLayer
    }

    /// Public wrapper around `queueTarget.isReadyForMoreMediaData` so the
    /// engine's demux loop can back-pressure against the actual queue.
    /// Reading the layer's own `isReadyForMoreMediaData` is misleading
    /// after the iOS 18 / tvOS 18 / macOS 15 split: queue ops route
    /// through `sampleBufferRenderer`, but the layer's own property
    /// stays optimistically true and never reflects actual back-pressure,
    /// so the loop happily over-enqueues into a full renderer queue and
    /// trips `FigVideoQueueRemote err=-12080`.
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

    /// Set how the rendered video frame fills its CALayer rect.
    /// Survives layer recreation across `load()` cycles, the renderer
    /// caches the value and re-applies it on every fresh layer.
    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        currentGravity = gravity
        displayLayer.videoGravity = gravity
    }

    var videoGravity: AVLayerVideoGravity { currentGravity }

    /// Opt the display layer into HDR output. Call with `true` only when
    /// the decoder is delivering HDR10/DV pixel buffers directly (no
    /// tone-map). Call with `false` (or leave at default) for SDR output
    /// including the HDR→SDR tone-mapped path.
    func setHDROutput(_ isHDR: Bool) {
        currentlyHDR = isHDR
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

    /// Swap the display layer for a fresh instance. Called by
    /// AetherEngine on every load() to avoid carrying over stale
    /// Synchronizer/controlTimebase state across sessions, the
    /// observed failure mode is status=.rendering but no frame
    /// consumption, which no in-place reset can recover from.
    /// The host view is notified via onLayerReplaced and must
    /// remove the old sublayer and add the new one.
    func recreateDisplayLayer() {
        // Drop the cached format description, it's associated with
        // the old layer's pipeline, and a new layer starts clean.
        reorderLock.lock()
        reorderBuffer.removeAll()
        cachedFormatDesc = nil
        cachedFormatKey = 0
        reorderLock.unlock()

        firstFrameLock.lock()
        _hasRenderedFirstFrame = false
        firstFrameLock.unlock()

        let newLayer = Self.makeDisplayLayer(isHDR: currentlyHDR, gravity: currentGravity)
        displayLayer = newLayer
        onLayerReplaced?(newLayer)

        #if DEBUG
        enqueueCount = 0
        loggedLayerFailed = false
        print("[Renderer] display layer recreated")
        #endif
    }

    /// After seek, drop frames with PTS before the target to prevent
    /// the visual "fast forward" effect from keyframe to seek target.
    func setSkipThreshold(_ time: CMTime?) {
        reorderLock.lock()
        skipUntilPTS = time
        reorderLock.unlock()
    }

    /// Enqueue a decoded video frame. Frames are buffered and reordered
    /// by PTS before being sent to the display layer. `hdr10PlusData`,
    /// when non-nil, carries the per-frame ST 2094-40 dynamic metadata
    /// already serialised to the T.35 SEI byte format Apple's
    /// `kCMSampleAttachmentKey_HDR10PlusPerFrameData` expects.
    func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime, hdr10PlusData: Data? = nil) {
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
        reorderBuffer.insert((pixelBuffer, pts, hdr10PlusData), at: insertIdx)

        // Flush oldest frames when buffer exceeds reorder depth
        while reorderBuffer.count > reorderDepth {
            let (pb, t, hdr) = reorderBuffer.removeFirst()
            reorderLock.unlock()
            flushFrame(pixelBuffer: pb, pts: t, hdr10PlusData: hdr)
            reorderLock.lock()
        }

        reorderLock.unlock()
    }

    /// Discard all buffered and displayed frames (call on seek/stop).
    /// Uses flushAndRemoveImage to clear the currently visible frame
    /// immediately, prevents showing stale content after seeking.
    func flush() {
        reorderLock.lock()
        reorderBuffer.removeAll()
        // Drop the cached format description, a following load() may open
        // a stream with different color attachments at the same resolution,
        // and CMVideoFormatDescriptionCreateForImageBuffer snapshots those
        // into the description at creation time.
        cachedFormatDesc = nil
        cachedFormatKey = 0
        reorderLock.unlock()

        firstFrameLock.lock()
        _hasRenderedFirstFrame = false
        firstFrameLock.unlock()

        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) { }
        } else {
            displayLayer.flushAndRemoveImage()
        }
    }

    /// Flush the reorder buffer and send all frames to the display layer
    /// (call at EOF to drain the last frames).
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
        // Attach HDR10+ dynamic metadata before enqueue. Per Apple's
        // doc this attachment overrides any HDR10+ payload baked into
        // the compressed bitstream, which is exactly what we want
        // because VT may strip per-frame SEI on the way out.
        if let hdr10PlusData {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_HDR10PlusPerFrameData,
                value: hdr10PlusData as CFData,
                attachmentMode: CMAttachmentMode(kCMAttachmentMode_ShouldPropagate)
            )
            hdr10PlusAttachedCount += 1
            if hdr10PlusAttachedCount == 1 || hdr10PlusAttachedCount == 30 || hdr10PlusAttachedCount % 600 == 0 {
                EngineLog.emit("[Renderer] HDR10+ attachment count: \(hdr10PlusAttachedCount) (last payload \(hdr10PlusData.count) bytes)")
            }
        }
        // If the queue target has entered the failed state (undefined-
        // behavior races during Synchronizer↔controlTimebase handoffs
        // push it here, and once it's failed it stays failed until
        // flushed), attempt an in-place recovery via flush.
        let target = queueTarget
        if queueStatus == .failed {
            if !loggedLayerFailed {
                loggedLayerFailed = true
                EngineLog.emit("[Renderer] queue target failed at enqueue #\(enqueueCount + 1): \(queueError?.localizedDescription ?? "nil"), attempting recovery via flush()")
            }
            target.flush()
        }
        if !target.isReadyForMoreMediaData, !loggedNotReady {
            loggedNotReady = true
            EngineLog.emit("[Renderer] isReadyForMoreMediaData=false at enqueue #\(enqueueCount + 1) status=\(statusName)")
        }
        target.enqueue(sampleBuffer)

        // Mark first frame after the most recent reset. Lock-protected
        // because flushFrame runs on the decoder callback thread while
        // AetherEngine reads / resets this from its actor.
        firstFrameLock.lock()
        _hasRenderedFirstFrame = true
        firstFrameLock.unlock()

        enqueueCount += 1
        // Sparse progress trail so a stall after enqueue #30 (the
        // existing log point) is distinguishable from "we just stop
        // logging at #30 but actually keep enqueueing". Logging cost
        // is bounded: at 60 fps for 1 hour we emit 4 lines total.
        if enqueueCount == 1 || enqueueCount == 30 || enqueueCount == 100 || enqueueCount == 1000 || enqueueCount == 5000 {
            EngineLog.emit("[Renderer] enqueue #\(enqueueCount): status=\(statusName) ready=\(queueTarget.isReadyForMoreMediaData) error=\(queueError?.localizedDescription ?? "nil")")
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

    /// Reset per-session diagnostic counters. Call on load() so the
    /// progress / status logs fire for each new video, not only the
    /// first one after app launch.
    func resetDiagnostics() {
        enqueueCount = 0
        loggedLayerFailed = false
        loggedNotReady = false
    }

    /// Explicit flush of the underlying queue target without clearing
    /// the currently displayed frame. Used by AetherEngine before
    /// assigning a new controlTimebase to coax the queue out of any
    /// leftover synchronizer state.
    func flushDisplayLayer() {
        queueTarget.flush()
    }

    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        // Reuse the format description unless dimensions or pixel format
        // changed, rebuilding per frame wastes an allocation and Core
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
