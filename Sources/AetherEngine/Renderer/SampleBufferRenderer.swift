import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Video renderer using AVSampleBufferDisplayLayer for optimal frame pacing.
///
/// Includes a small reorder buffer to handle B-frame decode order from VTDecompressionSession
/// (4 frames, see `reorderDepth(forHardwareDecoder:)`). Frames are sorted by PTS before
/// being enqueued to the display layer in strict presentation order.
final class SampleBufferRenderer: @unchecked Sendable {

    let displayLayer: AVSampleBufferDisplayLayer

    /// The layer's queue surface, taken once on the main actor at construction (#351). The 27 SDKs
    /// isolate `AVSampleBufferDisplayLayer` to the main actor, `AVSampleBufferVideoRenderer` is not, so
    /// the decode thread enqueues, flushes and reads status through this and never touches the layer.
    /// A stored reference cannot drift from the layer: neither is ever replaced, HDR output flips
    /// `preferredDynamicRange` on the same layer.
    ///
    /// tvOS 26+ fails the deprecated layer enqueue/flush/isReadyForMoreMediaData under an
    /// AVSampleBufferRenderSynchronizer with FigVideoQueueRemote -12080 after the first enqueue, so
    /// this renderer is the only queue target, and the one the synchronizer is given.
    let videoRenderer: AVSampleBufferVideoRenderer

    /// SW-PiP Phase C: composites active subtitle cues into frames while PiP is active (the system
    /// window renders only this layer, the host overlay cannot reach it).
    let subtitleCompositor = SubtitleFrameCompositor()

    /// B-frame reorder buffer: collects decoder output, flushes to display layer in ascending PTS order. Third tuple slot carries per-frame HDR10+ T.35 SEI bytes, paired through the reorder to kCMSampleAttachmentKey_HDR10PlusPerFrameData.
    private let reorderLock = NSLock()
    private var reorderBuffer: [(CVPixelBuffer, CMTime, Data?)] = []

    /// Audit PERF-104: VideoToolbox HEVC with temporal processing emits B-frames out of presentation
    /// order (19479fc5, -12080 from the layer), so its renderer holds 4 frames, enough for 3
    /// consecutive B-frames. libavcodec and dav1d emit presentation order, and 3 held frames are 75 MB
    /// of IOSurface at 4K P010 for nothing. One frame stays held either way: #407 reads each frame's
    /// duration off its held successor.
    static let hardwareDecoderReorderDepth = 4
    static let presentationOrderReorderDepth = 1
    static func reorderDepth(forHardwareDecoder hardware: Bool) -> Int {
        hardware ? hardwareDecoderReorderDepth : presentationOrderReorderDepth
    }

    /// Guarded by `reorderLock`. Starts at the hardware depth, so a renderer nobody configured keeps the
    /// behaviour it always had.
    private var reorderDepth = SampleBufferRenderer.hardwareDecoderReorderDepth

    /// Set once by the host when it picks the decoder; a depth below the current one takes effect on
    /// the next enqueue, which hands the surplus over in order.
    func setReorderDepth(_ depth: Int) {
        reorderLock.lock()
        reorderDepth = max(1, min(depth, Self.hardwareDecoderReorderDepth))
        reorderLock.unlock()
    }

    /// [MovieClaw P17] Wait until the first frame leaves the renderer's current reorder window.
    var framesBeforeFirstPresentation: Int {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return reorderDepth + 1
    }

    /// Frames waiting for a smaller presentation time. Diagnostics and tests.
    var heldFrameCount: Int {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return reorderBuffer.count
    }

    /// Drop frames before this PTS after a seek (prevents keyframe-to-target fast-forward). Cleared after the first passing frame.
    private var skipUntilPTS: CMTime?

    /// #311: fires for every frame handed to the queue target, on the decode thread. Guarded by
    /// `reorderLock` for the swap only; the call itself happens with no lock held, so a host that
    /// re-enters the renderer from it cannot deadlock.
    private var _frameEnqueuedObserver: SoftwareVideoFrameTimeObserver?
    func setFrameEnqueuedObserver(_ observer: SoftwareVideoFrameTimeObserver?) {
        reorderLock.lock()
        _frameEnqueuedObserver = observer
        reorderLock.unlock()
    }

    /// #311: moved on by every flush, so a consumer can drop the frame times it recorded for frames the
    /// compositor has since discarded. Guarded by `reorderLock`.
    ///
    /// Drawn from a process-wide allocator rather than counted from zero (#314). A load builds a new
    /// renderer, and a renderer that started at zero would report below the outgoing one, which is the
    /// order a consumer reads as "stale". The first value is drawn at init for the same reason: the
    /// generation a renderer reports before its first flush has to rank above the previous renderer's
    /// last, not tie with it. Successive values are therefore strictly increasing but not consecutive.
    private static let flushGenerations = FrameTimeSequence()
    private var _flushGeneration: UInt64 = SampleBufferRenderer.flushGenerations.next()
    var flushGeneration: UInt64 {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return _flushGeneration
    }

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
    /// Guarded by `reorderLock` since #407: the 1 Hz diagnostic reads it off the main actor while the
    /// decode thread writes it, and the two counts it is compared against are read under the same lock.
    private(set) var enqueueCount = 0
    private var hdr10PlusAttachedCount = 0

    /// #407: frames that reached `flushFrame` and still never got to the layer, because the sample
    /// buffer could not be built. Separate from `_untimedFramesDropped` (refused before the reorder
    /// buffer) and from the post-seek skip, which is a decision rather than a loss. Guarded by
    /// `reorderLock`.
    private var _sampleBuildFailures = 0

    /// #407: spacing of the timestamps actually handed to the layer, over the interval since the last
    /// snapshot. `framesEnqueued` counts DECODER OUTPUT, so a per-second frame count reads healthy for
    /// an even 24 fps timeline and for one carrying a doubled or a duplicate interval alike; only the
    /// spacing separates them. Guarded by `reorderLock`, reset by `takeCadence()`.
    private var _lastHandedPtsSeconds: Double?
    /// Audit PERF-104: the newest timestamp that LEFT the reorder buffer, recorded under the same lock
    /// that pops it. The late-frame guard reads this, not `_lastHandedPtsSeconds`, which is written
    /// after the layer enqueue: a second enqueuer (a drain beside the decode thread) landing in that
    /// gap would be judged against the frame before and slip through out of order. Reset by `flush`.
    /// Guarded by `reorderLock`.
    private var _lastReleasedPtsSeconds: Double?
    private var _minHandedDeltaSeconds = Double.infinity
    private var _maxHandedDeltaSeconds = -Double.infinity

    /// Audit PERF-104: frames that arrived after a later one had already been handed over, so they can
    /// no longer be enqueued in presentation order. Dropped rather than enqueued out of order, and the
    /// first one raises the depth to the hardware decoder's for the rest of this renderer's life, which
    /// covers an HEVC stream whose SPS understates its reorder and PTS derived by the demuxer.
    /// Guarded by `reorderLock`.
    private var _outOfOrderFramesDropped = 0
    var outOfOrderFramesDropped: Int {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return _outOfOrderFramesDropped
    }

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

    /// #353: the size the picture presents at, which is the coded frame under the pixel aspect ratio
    /// the decoder attached; nil before the first sample buffer is built. Read off the description
    /// that is enqueued rather than recomputed from the SAR: the ratio is resolved per frame across
    /// three sources (#177) and a ratio whose display aspect is impossible is dropped (#290), so a
    /// second computation of the same answer is a second thing that can disagree with the screen.
    /// Guarded by `reorderLock`.
    private var _displaySize: CGSize?
    var displaySize: CGSize? {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return _displaySize
    }

    /// #353: fires when the settled display size CHANGES, on the decode thread, plus once on
    /// installation if the picture already settled. Compared against the value and not against the
    /// description, because `flush()` drops the cached description and every seek therefore rebuilds
    /// one for a picture that never changed shape. The late-installation call is what a host relies
    /// on: on a source with one format, the only report ever due has already happened.
    private var _displaySizeObserver: (@Sendable (CGSize) -> Void)?
    func setDisplaySizeObserver(_ observer: (@Sendable (CGSize) -> Void)?) {
        reorderLock.lock()
        _displaySizeObserver = observer
        let settled = _displaySize
        reorderLock.unlock()
        if let settled { observer?(settled) }
    }

    /// #489: the gravity is a construction parameter, not something a caller assigns afterwards.
    /// The engine holds the host app's picture mode across loads, and a layer that starts on the
    /// default and is corrected a moment later shows one frame of the wrong fill.
    ///
    /// Main-actor isolated because the layer is (#351); the only production caller,
    /// `SoftwarePlaybackHost`, already is.
    @MainActor
    init(videoGravity: AVLayerVideoGravity = .resizeAspect) {
        let layer = Self.makeDisplayLayer(isHDR: false, gravity: videoGravity)
        displayLayer = layer
        videoRenderer = layer.sampleBufferRenderer
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

    /// #407: what the renderer itself put on the layer, as opposed to what the decoder produced.
    /// `RenderMetrics` describes the layer's verdict on frames it received; this describes the frames
    /// it received, which is the half no counter covered while a report of visible judder read clean
    /// on every one of them.
    struct Cadence: Sendable {
        /// Cumulative frames handed to the queue target.
        let handedOver: Int
        /// Cumulative frames lost between the decoder callback and the layer: unschedulable
        /// timestamps plus failed sample-buffer builds. A gap between the decoder's count and
        /// `handedOver` that this does not account for is a post-seek skip.
        let lostBeforeLayer: Int
        /// Shortest and longest gap between consecutive handed-over timestamps over the interval,
        /// nil when fewer than two frames were handed over. Source axis, seconds.
        let minDeltaSeconds: Double?
        let maxDeltaSeconds: Double?
    }

    /// Reads the cadence counters and resets the per-interval spacing extremes. Called at 1 Hz by the
    /// diagnostic line; the cumulative counts survive, the min/max describe the interval only.
    func takeCadence() -> Cadence {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        let minD = _minHandedDeltaSeconds.isFinite ? _minHandedDeltaSeconds : nil
        let maxD = _maxHandedDeltaSeconds.isFinite ? _maxHandedDeltaSeconds : nil
        _minHandedDeltaSeconds = .infinity
        _maxHandedDeltaSeconds = -.infinity
        return Cadence(handedOver: enqueueCount,
                       lostBeforeLayer: _untimedFramesDropped + _sampleBuildFailures + _outOfOrderFramesDropped,
                       minDeltaSeconds: minD, maxDeltaSeconds: maxD)
    }

    /// nil only on visionOS 1.0: the metrics accessor arrived in tvOS/iOS 17.4, macOS 14.4 and visionOS
    /// 1.1, and visionOS is the one platform whose package floor still sits below it.
    ///
    /// #313: reads through the completion-handler accessor rather than the async one. A toolchain that
    /// imports the async accessor as `nonisolated` refuses to take the non-Sendable renderer across an
    /// actor boundary, and the completion form suspends without moving the renderer anywhere. Main-actor
    /// isolated because every caller is, so the annotation costs no hop.
    ///
    /// #344: visionOS has to be named. Falling through to `*` resolves it to the declared floor (1.0),
    /// which is a compile error rather than a runtime nil.
    @MainActor
    func loadRenderMetrics() async -> RenderMetrics? {
        guard #available(visionOS 1.1, *) else { return nil }
        let renderer = videoRenderer
        return await withCheckedContinuation { (cont: CheckedContinuation<RenderMetrics?, Never>) in
            renderer.loadVideoPerformanceMetrics { m in
                guard let m else { return cont.resume(returning: nil) }
                cont.resume(returning: RenderMetrics(total: m.totalNumberOfFrames,
                                                     dropped: m.numberOfDroppedFrames,
                                                     corrupted: m.numberOfCorruptedFrames,
                                                     accumulatedDelay: m.totalAccumulatedFrameDelay))
            }
        }
    }

    // MARK: - Queue rendering target

    /// `videoRenderer` as the protocol the enqueue path has always called it through, so the per-frame
    /// enqueue and back-pressure calls keep the dispatch they had.
    var queueTarget: any AVQueuedSampleBufferRendering { videoRenderer }

    /// Demux-loop back-pressure gate. Read from the renderer, never the layer: the layer's own
    /// isReadyForMoreMediaData stays optimistically true even when the renderer queue is full, causing
    /// FigVideoQueueRemote -12080 on over-enqueue.
    var isReadyForMoreMediaData: Bool {
        queueTarget.isReadyForMoreMediaData
    }

    private var queueStatus: AVQueuedSampleBufferRenderingStatus { videoRenderer.status }

    private var queueError: Error? { videoRenderer.error }

    @MainActor
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
            layer.wantsExtendedDynamicRangeContent = isHDR
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
            displayLayer.wantsExtendedDynamicRangeContent = isHDR
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
        if let handed = _lastReleasedPtsSeconds, ptsSeconds < handed {
            _outOfOrderFramesDropped += 1
            let dropped = _outOfOrderFramesDropped
            let raised = reorderDepth < Self.hardwareDecoderReorderDepth
            reorderDepth = Self.hardwareDecoderReorderDepth
            reorderLock.unlock()
            if dropped == 1 {
                EngineLog.emit(
                    "[Renderer] frame at \(String(format: "%.3f", ptsSeconds))s arrived after \(String(format: "%.3f", handed))s "
                    + "was handed over; dropped, reorder depth \(raised ? "raised to \(Self.hardwareDecoderReorderDepth)" : "already \(Self.hardwareDecoderReorderDepth)")",
                    category: .swPlayback)
            }
            return
        }
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
            _lastReleasedPtsSeconds = CMTimeGetSeconds(t)
            // #407: the successor is already held, so its timestamp is the frame's exact duration at
            // no extra latency. Read before the unlock, since enqueue() runs on the decode thread.
            let next = reorderBuffer.first?.1
            reorderLock.unlock()
            flushFrame(pixelBuffer: pb, pts: t, hdr10PlusData: hdr, nextPTS: next)
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
        // #407: the next frame handed over will not follow the last one, so the gap between them is
        // not a cadence measurement. Left standing, every seek would report one enormous interval.
        _lastHandedPtsSeconds = nil
        _lastReleasedPtsSeconds = nil
        // #303: nothing is held any more, so the frontier is not a frontier. Left standing, a
        // backward seek would keep reporting the pre-seek timestamp and read as a cushion of
        // however far the seek travelled.
        _newestEnqueuedPtsSeconds = nil
        // #311: everything reported before this point describes frames that are now gone.
        _flushGeneration = SampleBufferRenderer.flushGenerations.next()
        // Invalidate the format description cache; the next load() may open a stream with different colorimetry at the same resolution.
        cachedFormatDesc = nil
        cachedFormatKey = nil
        reorderLock.unlock()

        videoRenderer.flush(removingDisplayedImage: removingDisplayedImage) { }
    }

    /// Send all buffered frames to the display layer (call at EOF).
    func drainReorderBuffer() {
        reorderLock.lock()
        let remaining = reorderBuffer
        reorderBuffer.removeAll()
        if let newest = remaining.last { _lastReleasedPtsSeconds = CMTimeGetSeconds(newest.1) }
        reorderLock.unlock()

        for (i, (pb, t, hdr)) in remaining.enumerated() {
            // The final frame has no successor, so it is handed over untimed in length: at end of
            // media that is the frame that stays on screen, and a length is exactly what it must not
            // have.
            let next = i + 1 < remaining.count ? remaining[i + 1].1 : nil
            flushFrame(pixelBuffer: pb, pts: t, hdr10PlusData: hdr, nextPTS: next)
        }
    }

    // MARK: - Internal

    private func flushFrame(pixelBuffer: CVPixelBuffer, pts: CMTime, hdr10PlusData: Data?,
                            nextPTS: CMTime? = nil) {
        let outputBuffer = subtitleCompositor.composite(pixelBuffer, ptsSeconds: pts.seconds)
        guard let sampleBuffer = createSampleBuffer(
            from: outputBuffer, pts: pts,
            duration: Self.frameDuration(from: pts, to: nextPTS)) else {
            // #407: a frame the decoder produced and the layer never saw. Counted, because the
            // per-second frame count is taken on the decoder's side of this line.
            reorderLock.lock()
            _sampleBuildFailures += 1
            reorderLock.unlock()
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

        // #311: reported here rather than at admission, so it describes frames the compositor has
        // been given. A frame refused for an unschedulable timestamp, skipped after a seek, or lost
        // to a failed sample-buffer creation never reaches this line and is never reported.
        reorderLock.lock()
        let observer = _frameEnqueuedObserver
        let generation = _flushGeneration
        reorderLock.unlock()
        observer?(SoftwareVideoFrameTime(presentation: pts, generation: generation))

        reorderLock.lock()
        enqueueCount += 1
        // #407: the spacing of what the layer was given, which is the thing a frame COUNT cannot say.
        if let previous = _lastHandedPtsSeconds {
            let delta = CMTimeGetSeconds(pts) - previous
            if delta.isFinite {
                _minHandedDeltaSeconds = min(_minHandedDeltaSeconds, delta)
                _maxHandedDeltaSeconds = max(_maxHandedDeltaSeconds, delta)
            }
        }
        _lastHandedPtsSeconds = CMTimeGetSeconds(pts)
        let handed = enqueueCount
        reorderLock.unlock()
        // Sparse milestones so a stall is distinguishable from "logging stopped at #30"; bounded to 4 lines/hour at 60 fps.
        if handed == 1 || handed == 30 || handed == 100 || handed == 1000 || handed == 5000 {
            EngineLog.emit("[Renderer] enqueue #\(handed): status=\(statusName) ready=\(queueTarget.isReadyForMoreMediaData) error=\(queueError?.localizedDescription ?? "nil")", category: .swPlayback)
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

    /// [SWDiag] surface: current queue-target status for the 1 Hz diagnostic line. A mid-session
    /// flip away from `rendering` is the layer-side stall the per-frame counters cannot show.
    var diagStatusName: String { statusName }

    /// #353: what the layer will draw the description at. Pixel aspect ratio and clean aperture are
    /// extensions of the description itself, so this asks the description what it presents at
    /// instead of repeating the decision that built it.
    static func presentationSize(of desc: CMVideoFormatDescription) -> CGSize {
        CMVideoFormatDescriptionGetPresentationDimensions(
            desc, usePixelAspectRatio: true, useCleanAperture: true)
    }

    /// #407: the length a frame is presented for, from the successor the reorder buffer is already
    /// holding. `.invalid` for the last frame of a stream (nothing follows it) and for a successor
    /// that cannot be a frame length: a non-positive gap is a duplicate or a reordering fault, and a
    /// gap past a second is a stream discontinuity, neither of which is a duration to present for.
    static func frameDuration(from pts: CMTime, to nextPTS: CMTime?) -> CMTime {
        guard let nextPTS, pts.isNumeric, nextPTS.isNumeric else { return .invalid }
        let delta = CMTimeSubtract(nextPTS, pts)
        let seconds = CMTimeGetSeconds(delta)
        guard seconds > 0, seconds <= 1.0 else { return .invalid }
        return delta
    }

    /// Internal (not private) for #177 regression tests: the PAR-keyed cache behavior is the fix.
    func createSampleBuffer(from pixelBuffer: CVPixelBuffer, pts: CMTime,
                            duration: CMTime = .invalid) -> CMSampleBuffer? {
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
            // #353: a new description is the only moment the picture can change shape, so the
            // settled size is taken here and reported outside the lock.
            let settled = Self.presentationSize(of: new)
            reorderLock.lock()
            cachedFormatDesc = new
            cachedFormatKey = key
            let changed = settled != _displaySize
            if changed { _displaySize = settled }
            let sizeObserver = changed ? _displaySizeObserver : nil
            reorderLock.unlock()
            sizeObserver?(settled)
            desc = new
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
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
