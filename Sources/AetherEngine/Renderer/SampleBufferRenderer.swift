import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Video renderer using AVSampleBufferDisplayLayer for optimal frame pacing.
///
/// Includes a small reorder buffer to handle B-frame decode order from VTDecompressionSession
/// (4 frames, see `reorderDepth(forHardwareDecoder:)`). Frames are sorted by PTS before
/// being enqueued to the display layer in strict presentation order. The FEL path skips it and
/// hands frames over in decode order with a floor on upcoming timestamps instead
/// (`setArrivalOrderHandover(frameRate:)`).
final class SampleBufferRenderer: @unchecked Sendable {

    struct ResumeQueue {
        let status: @MainActor () -> AVQueuedSampleBufferRenderingStatus
        let flush: @MainActor () -> Void
    }

    @MainActor private let resumeQueue: ResumeQueue?
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

    /// Arrival-order handover: frames go to the renderer the moment they arrive, in decode order,
    /// and `presentationTimeExpectation = .minimumUpcoming(_:)` tells it the lowest timestamp still to
    /// come (`PresentationFloor`), so the renderer sorts by presentation time itself. The reorder
    /// buffer is bypassed. Used on the FEL path, where the held frames came out of the look-ahead
    /// budget: with 4 held inside a 9-frame window the layer dropped about 1 frame in 5 on the Apple
    /// TV (A12), and handing them over instead took that to the 4 to 6 a run drops with the compose
    /// skipped altogether, at no extra memory (2026-10-13, three interleaved rounds each).
    /// Guarded by `reorderLock`; nil uses the reorder buffer.
    private var arrivalFloor: PresentationFloor?

    /// The seek threshold on the arrival-order path, which outlives the first frame past it:
    /// `skipUntilPTS` is cleared by that frame, but in decode order it is the GOP's next anchor, and
    /// B-frames below the target still follow it. Cleared by `flush`. Guarded by `reorderLock`.
    private var arrivalSkipBelow: Double?

    /// Frames that arrived below a floor the renderer had already been promised. Still handed over
    /// (the renderer may drop them), counted so a stream that breaks the promise is visible.
    /// Guarded by `reorderLock`.
    private var _framesBelowFloor = 0
    var framesBelowFloor: Int {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return _framesBelowFloor
    }

    /// Switches arrival-order handover on for a stream of `frameRate` frames per second, or off with
    /// nil. Stays off without a usable rate, since the floor walks the frame grid and a wrong grid
    /// would promise past frames still to come, and on visionOS 1.0, which has no expectation API.
    func setArrivalOrderHandover(frameRate: Double?) {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        if #available(visionOS 1.1, *), let rate = frameRate, Self.arrivalOrderFrameRates.contains(rate) {
            arrivalFloor = PresentationFloor(interval: 1 / rate)
        } else {
            arrivalFloor = nil
        }
    }

    /// Rates the floor trusts. A declared rate below the real one would promise past B-frames still to
    /// come, and a bogus `avg_frame_rate` in the thousands would walk the grid a slot at a time.
    static let arrivalOrderFrameRates: ClosedRange<Double> = 10...120

    var handsOverInArrivalOrder: Bool {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return arrivalFloor != nil
    }

    /// Frames waiting for a smaller presentation time. Diagnostics and tests.
    var heldFrameCount: Int {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return reorderBuffer.count
    }

    /// How many frame intervals of compressed video may be admitted ahead of the playback clock on
    /// the FEL path. The gate runs BEFORE decode, so the decode + EL + compose latency (a few frames)
    /// comes out of this budget: 5 left a displayed lead of ~0 and the layer dropped 9 frames/s
    /// on device, against 0.5 s and no drops with no cap. A composed 4K frame costs ~25 MB, and
    /// Apple's readiness gate alone allowed ~12 of them. The FEL path hands frames over in arrival
    /// order (`setArrivalOrderHandover`), so none of the window sits in our reorder buffer: with
    /// `hardwareDecoderReorderDepth` frames held there instead, the display layer was 4 frames short
    /// of this budget and dropped about 1 frame in 5 on the Apple TV.
    static let felVideoLookaheadFrames = 9
    private var felFrameRate: Double?  // guarded by reorderLock; nil leaves non-FEL pacing unchanged
    /// Highest compressed-packet PTS the gate has seen, and the largest amount any later packet's PTS
    /// fell below it. Packets arrive in decode order, so with B-frames a packet's PTS runs ahead of the
    /// frames still waiting to be displayed; measured on the real fixtures that lead is up to 7 frames
    /// (a hierarchical-B GOP of 8), 2 to 4 on other clips, 0 on a third. The gate subtracts it so the cap bounds
    /// display-order look-ahead rather than swinging with the position in the GOP. Guarded by
    /// `reorderLock`; reset on flush.
    private var gateMaxPacketPTS: Double?
    private var gateReorderLead: Double = 0
    /// HEVC's ceiling on `sps_max_num_reorder_pics`; a bigger PTS gap than this many frames is not reordering.
    static let maxReorderPictures: Double = 16
    /// Ceiling on the learned reorder lead, in frames. A hierarchical-B GOP of 8 makes a packet trail the
    /// highest PTS seen by up to 7 frames in decode order (measured on a UHD Blu-ray FEL remux; other
    /// clips measured 2 to 4); 8 leaves one frame to spare. It is unrelated to `hardwareDecoderReorderDepth`,
    /// which sizes the buffer behind the decoder. Without a ceiling one backward timestamp glitch inside
    /// the 16-picture window would raise the lead, and so the admitted look-ahead, for the whole session.
    static let maxLearnedReorderFrames: Double = 8

    /// Display-order PTS estimate for a packet in decode order. Pure; the state is passed in.
    ///
    /// A gap below the highest PTS seen that is larger than `maxLead` cannot be B-frame reordering
    /// (HEVC allows at most 16 pictures of it), so it is a timestamp discontinuity: the highest PTS
    /// restarts from this packet and the learned lead is left alone, instead of absorbing the jump
    /// into the lead and switching the look-ahead cap off for the rest of the session.
    /// The gate is armed only on the dual-layer route (VOD, seekable); a forward jump holds the packet
    /// until the clock reaches it, when the layer would present it anyway.
    ///
    /// The learned lead is also capped at `maxLearnedLead`: a backward step inside the 16-picture
    /// window that is still a glitch (a 12-frame one, say) would otherwise raise the lead for the whole
    /// session, and with it the look-ahead the gate admits. The gate passes `maxLearnedReorderFrames`.
    static func displayOrderPTS(packetPTS: Double, maxSeenPTS: Double?, reorderLead: Double,
                                maxLead: Double = .infinity, maxLearnedLead: Double = .infinity)
        -> (pts: Double, maxSeen: Double, lead: Double) {
        let seen = maxSeenPTS ?? packetPTS
        if seen - packetPTS > maxLead {
            return (packetPTS - reorderLead, packetPTS, reorderLead)
        }
        let maxSeen = max(seen, packetPTS)
        let lead = min(maxLearnedLead, max(reorderLead, maxSeen - packetPTS))
        return (packetPTS - lead, maxSeen, lead)
    }

    func setFELLookahead(enabled: Bool, frameRate: Double?) {
        reorderLock.lock()
        // Container avg_frame_rate -> r_frame_rate; use 24 fps if both are unavailable.
        felFrameRate = enabled ? (frameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 24) : nil
        // Whatever was learned belonged to the previous stream or setting.
        gateMaxPacketPTS = nil
        gateReorderLead = 0
        reorderLock.unlock()
    }

    /// How much composed video the FEL path hands the layer before the clock starts, in seconds
    /// (`prerollSatisfied(clock:live:)`): four frames at 24 fps, which covers a decode-order burst of a
    /// hierarchical GOP. Measured on the Apple TV 4K (A12) with 4K FEL, the preroll completes after
    /// 90 to 100 ms at a start and 0.3 to 0.9 s after a seek.
    static let felPrerollSeconds = 0.167

    /// `felPrerollSeconds`, capped one frame inside the look-ahead window: with the clock held still,
    /// `mayEnqueueAnotherFrame` admits nothing past `felVideoLookaheadFrames` frames ahead of it, so
    /// at 60 fps (nine frames, 0.15 s) a 0.167 s preroll could never fill and every start waited out
    /// `AudioOutput.prerollTimeout`.
    static func felPrerollSeconds(frameRate: Double) -> Double {
        min(felPrerollSeconds, Double(felVideoLookaheadFrames - 1) / frameRate)
    }

    /// How much video every other software route hands the layer before the clock starts, in seconds
    /// past it (`prerollSatisfied(clock:live:)`): the frame at the clock and three after it at 24 fps.
    /// Without it a start or a seek ran the clock while the decoder was still working from the keyframe
    /// up to the target, and the first frames arrived late: 0.9 s and 5 to 7 dropped frames on a 4K
    /// HEVC title with no audio after a 10 s GOP on an Apple TV 4K (A15), 0.3 s and 3 on 1080p H.264
    /// with audio (#800).
    static let videoPrerollSeconds = 0.125

    /// The preroll gate for `AudioOutput.videoPrerollSatisfied`: true once frames up to the preroll
    /// past `clock` (source seconds) are in the layer, `felPrerollSeconds` on the FEL path and
    /// `videoPrerollSeconds` on every other one. nil for a clock with no position, and off the FEL
    /// path on a live stream, whose join already starts on its first keyframe (AE#844) and lets the
    /// clock run from the audio there. On the arrival-order path only the frontier counts, the newest
    /// timestamp with every earlier slot handed over, so a frame that came early past a gap does not
    /// open the gate.
    func prerollSatisfied(clock: Double, live: Bool) -> Bool? {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        guard clock.isFinite else { return nil }
        let rate = felFrameRate
        if rate == nil, live { return nil }
        let handed = arrivalFloor != nil ? arrivalFloor?.frontier : _lastReleasedPtsSeconds
        guard let handed else { return false }
        guard let rate else { return handed - clock >= Self.videoPrerollSeconds }
        return handed + 1 / rate - clock >= Self.felPrerollSeconds(frameRate: rate)
    }

    /// Combined queue-readiness and look-ahead gate, called BEFORE decode so excess frames stay compressed.
    func mayEnqueueVideoFrame(ptsSeconds: Double, clockSeconds: Double, clockArmed: Bool) -> Bool {
        reorderLock.lock()
        let rate = felFrameRate
        let frontier = _newestEnqueuedPtsSeconds
        var gatePTS = ptsSeconds.isFinite ? ptsSeconds : frontier ?? .nan
        if rate != nil, ptsSeconds.isFinite {
            let d = Self.displayOrderPTS(packetPTS: ptsSeconds, maxSeenPTS: gateMaxPacketPTS,
                                         reorderLead: gateReorderLead,
                                         maxLead: Self.maxReorderPictures / (rate ?? 24),
                                         maxLearnedLead: Self.maxLearnedReorderFrames / (rate ?? 24))
            gateMaxPacketPTS = d.maxSeen
            gateReorderLead = d.lead
            gatePTS = d.pts
        }
        reorderLock.unlock()
        return Self.mayEnqueueAnotherFrame(
            rendererReady: isReadyForMoreMediaData, felFrameRate: rate,
            framePTS: gatePTS,
            clockSeconds: clockSeconds, clockArmed: clockArmed)
    }

    /// Pure admission decision. Before clock arming there is no meaningful lead: preserve startup
    /// and the existing broken-audio arming fallback. Late frames remain eligible for catch-up.
    static func mayEnqueueAnotherFrame(
        rendererReady: Bool, felFrameRate: Double?, framePTS: Double,
        clockSeconds: Double, clockArmed: Bool
    ) -> Bool {
        guard rendererReady else { return false }
        guard let rate = felFrameRate, rate.isFinite, rate > 0,
              clockArmed, clockSeconds.isFinite, framePTS.isFinite else { return true }
        return framePTS - clockSeconds <= Double(felVideoLookaheadFrames) / rate
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

    /// AE#395: the session's renderer axis, shared with the `AudioOutput` whose synchronizer this
    /// renderer runs on. Only the stamp on the sample buffer moves onto it; the reorder buffer, the
    /// frontier and the frame-time reports stay on the source axis. Guarded by `reorderLock`.
    private var _timeline: RendererTimeline?

    func setTimeline(_ timeline: RendererTimeline?) {
        reorderLock.lock()
        _timeline = timeline
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

    /// Frames the arrival-order path discarded for sitting below the seek threshold: the pictures of the
    /// GOP the seek landed in that precede the target. A decision rather than a loss, so it stays out of
    /// `lostBeforeLayer`, but counted so a seek that discards more than its GOP is visible.
    /// Guarded by `reorderLock`.
    private var _arrivalSkippedFramesDropped = 0
    /// Whether this seek's first skipped frame has been logged. Re-armed whenever the threshold changes
    /// or is cleared, so the line fires once per seek rather than once per renderer. Guarded by `reorderLock`.
    private var arrivalSkipLogged = false
    var arrivalSkippedFramesDropped: Int {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return _arrivalSkippedFramesDropped
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
    init(resumeQueue: ResumeQueue? = nil, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.resumeQueue = resumeQueue
        let layer = Self.makeDisplayLayer(isHDR: false, gravity: videoGravity)
        displayLayer = layer
        videoRenderer = layer.sampleBufferRenderer
        observeQueueFlushRequirements()
    }

    deinit {
        for token in queueNotificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Flush recovery

    /// Why the queue target needs a flush it did not get from the host.
    enum QueueFlushReason: Sendable, Equatable {
        /// `requiresFlushToResumeDecoding` turned true (the app lost the right to use decoder resources).
        case requiresFlush
        /// The queue target's status is `.failed`.
        case failed

        var trigger: FlushRecoveryTrigger {
            switch self {
            case .requiresFlush: .videoQueueRequiresFlush
            case .failed: .videoQueueFailed
            }
        }
    }

    /// Told, on whatever thread noticed it and with no lock held, that the queue target needs a flush
    /// and has lost what was in it. The host decides between a plain flush and a reposition to the
    /// playhead (`FlushRecoveryPolicy`). Guarded by `reorderLock`.
    private var _queueFlushObserver: (@Sendable (QueueFlushReason) -> Void)?
    func setQueueFlushObserver(_ observer: (@Sendable (QueueFlushReason) -> Void)?) {
        reorderLock.lock()
        _queueFlushObserver = observer
        reorderLock.unlock()
    }

    private func reportQueueFlush(_ reason: QueueFlushReason) {
        reorderLock.lock()
        let observer = _queueFlushObserver
        reorderLock.unlock()
        observer?(reason)
    }

    #if DEBUG
    /// Test seam: what a failed enqueue does, without a renderer to fail.
    func reportQueueFlushForTesting(_ reason: QueueFlushReason) { reportQueueFlush(reason) }
    #endif

    /// Frames the queue target took while it was neither failed nor asking for a flush, counted after
    /// the enqueue. `enqueueCount` also counts the frame handed over right after a failed queue was
    /// revived, which proves nothing about the queue. The host reads this as "the queue has been given a
    /// frame": before the first one there is nothing to recover. Whether a recovery helped is asked of
    /// `presentedFrameCount(clockSeconds:)`, which wants more than an enqueue the queue may still
    /// refuse. Guarded by `reorderLock`.
    private var _acceptedFrameCount = 0
    var acceptedFrameCount: Int {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return _acceptedFrameCount
    }

    private var loggedRequiresFlushAtEnqueue = false

    /// Frames handed to a healthy queue whose time the clock has not passed yet, in source seconds,
    /// oldest first. Guarded by `reorderLock`.
    private var _pendingPresentation: [Double] = []
    private var _presentedFrameCount = 0
    private static let pendingPresentationCapacity = 256

    /// Frames the clock has passed while the queue stayed healthy: the stronger evidence the storm rule
    /// wants, since a queue can report itself healthy right after an enqueue and refuse the frame later.
    /// A frame still ahead of the clock is not counted, and none is while the queue needs a flush; a
    /// flush drops the ones not yet counted, as the queue dropped them.
    func presentedFrameCount(clockSeconds: Double) -> Int {
        let healthy = queueFlushReasonNow() == nil
        reorderLock.lock()
        defer { reorderLock.unlock() }
        if healthy, clockSeconds.isFinite {
            let passed = _pendingPresentation.prefix { $0 <= clockSeconds }.count
            if passed > 0 {
                _pendingPresentation.removeFirst(passed)
                _presentedFrameCount += passed
            }
        }
        return _presentedFrameCount
    }

    /// The tokens for the notifications below; removed in `deinit`.
    private var queueNotificationTokens: [NSObjectProtocol] = []

    /// The renderer posts from an arbitrary thread, possibly from inside a call that already holds
    /// `reorderLock` (`presentationTimeExpectation` is set under it), and the handlers take that lock.
    /// They therefore only hop here, the way `AudioOutput` does for its renderer.
    private let queueNotificationQueue = DispatchQueue(label: "engine.renderer.queue-flush")

    /// Before this nothing here observed either: a picture that froze after backgrounding stayed frozen
    /// until the user seeked, while AVPlayer resumes by itself.
    ///
    /// The property is read back rather than taken from the payload: the notification says "changed",
    /// the property says which way.
    private func observeQueueFlushRequirements() {
        let center = NotificationCenter.default
        let renderer = videoRenderer
        queueNotificationTokens.append(center.addObserver(
            forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
            object: renderer, queue: nil
        ) { [weak self] _ in
            self?.queueNotificationQueue.async { [weak self] in
                guard let self, self.queueNeedsFlushNow() else { return }
                EngineLog.emit("[Renderer] video queue requires a flush to resume decoding (status=\(self.statusName))",
                               category: .swPlayback)
                self.reportQueueFlush(.requiresFlush)
            }
        })
        queueNotificationTokens.append(center.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: renderer, queue: nil
        ) { [weak self] note in
            let error = note.userInfo?[AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey] as? NSError
            self?.queueNotificationQueue.async { [weak self] in
                guard let self else { return }
                EngineLog.emit("[Renderer] video queue failed to decode: \(error.map { "\($0.domain)/\($0.code)" } ?? "nil") (status=\(self.statusName))",
                               category: .swPlayback)
                // One undecodable frame leaves the queue running; only a queue that is no longer is reported.
                guard self.queueNeedsFlushNow() else { return }
                self.reportQueueFlush(.failed)
            }
        })
    }

    #if DEBUG
    /// Runs the work the notification handlers queue, then returns. Tests wait on this instead of sleeping.
    func drainQueueNotificationsForTesting() { queueNotificationQueue.sync {} }

    /// The test answers below are set on one thread and read on another (the demux loop, the notification
    /// queue), so they sit behind a lock.
    private let testAnswerLock = NSLock()
    private var _queueNeedsFlushForTesting: (@Sendable () -> Bool)?
    private var _readyForMoreMediaDataForTesting: (@Sendable () -> Bool)?

    /// A renderer cannot be made to fail on demand; tests answer for it.
    var queueNeedsFlushForTesting: (@Sendable () -> Bool)? {
        get { testAnswerLock.lock(); defer { testAnswerLock.unlock() }; return _queueNeedsFlushForTesting }
        set { testAnswerLock.lock(); _queueNeedsFlushForTesting = newValue; testAnswerLock.unlock() }
    }
    #endif

    private func queueNeedsFlushNow() -> Bool { queueFlushReasonNow() != nil }

    /// Why the queue target needs a flush right now, nil if it does not. Failed is the stronger of the two.
    private func queueFlushReasonNow() -> QueueFlushReason? {
        #if DEBUG
        if let answer = queueNeedsFlushForTesting { return answer() ? .requiresFlush : nil }
        #endif
        if videoRenderer.status == .failed { return .failed }
        return videoRenderer.requiresFlushToResumeDecoding ? .requiresFlush : nil
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
        /// Cumulative frames the arrival-order path discarded below the seek threshold. A decision
        /// rather than a loss, so it is not part of `lostBeforeLayer`.
        let arrivalSkipped: Int
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
                       arrivalSkipped: _arrivalSkippedFramesDropped,
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
        #if DEBUG
        if let answer = readyForMoreMediaDataForTesting { return answer() }
        #endif
        return queueTarget.isReadyForMoreMediaData
    }

    #if DEBUG
    /// Holds the demux loop in its back-pressure wait on demand.
    var readyForMoreMediaDataForTesting: (@Sendable () -> Bool)? {
        get { testAnswerLock.lock(); defer { testAnswerLock.unlock() }; return _readyForMoreMediaDataForTesting }
        set { testAnswerLock.lock(); _readyForMoreMediaDataForTesting = newValue; testAnswerLock.unlock() }
    }
    /// Frames handed to a healthy queue that no sample has counted yet.
    var pendingPresentationCountForTesting: Int {
        reorderLock.lock(); defer { reorderLock.unlock() }
        return _pendingPresentation.count
    }
    #endif

    /// A suspended process may return with a failed queue that never admits another frame.
    /// Recover before the feeder wakes; a healthy full queue must keep its buffered frames.
    @MainActor
    func recoverAfterSuspensionIfNeeded() {
        let status = resumeQueue?.status() ?? queueStatus
        guard status == .failed else { return }
        EngineLog.emit("[Renderer] AE#870 queue target failed while paused (\(queueError?.localizedDescription ?? "nil")), flushing before the feeder resumes", category: .swPlayback)
        if let resumeQueue {
            resumeQueue.flush()
        } else {
            queueTarget.flush()
        }
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
        installSkipThresholdLocked(time)
        reorderLock.unlock()
    }

    /// `reorderLock` held.
    private func installSkipThresholdLocked(_ time: CMTime?) {
        skipUntilPTS = time
        // Nothing below the threshold will be handed over, and the first frame past it need not be
        // the lowest one to come, so the floor starts here rather than at that frame.
        if arrivalFloor != nil, let time, time.isNumeric {
            arrivalFloor?.reset(start: CMTimeGetSeconds(time))
            // A seek sets the same threshold again after the landing; only a new target is a new seek.
            if arrivalSkipBelow != CMTimeGetSeconds(time) { arrivalSkipLogged = false }
            arrivalSkipBelow = CMTimeGetSeconds(time)
        }
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
                // On the arrival-order path this is the seek's own discard: the count and the once-per-seek
                // line cover it as they cover the frames `handOverOnArrival` refuses below the threshold.
                var logFirst = false
                if arrivalFloor != nil {
                    _arrivalSkippedFramesDropped += 1
                    logFirst = !arrivalSkipLogged
                    arrivalSkipLogged = true
                }
                reorderLock.unlock()
                if logFirst {
                    EngineLog.emit(
                        "[Renderer] frame at \(String(format: "%.3f", CMTimeGetSeconds(pts)))s is below the seek threshold "
                        + "\(String(format: "%.3f", CMTimeGetSeconds(threshold)))s; skipping until the first frame at or past it",
                        category: .swPlayback)
                }
                return
            }
            skipUntilPTS = nil
        }

        let ptsSeconds = CMTimeGetSeconds(pts)
        if arrivalFloor != nil {
            handOverOnArrival(pixelBuffer: pixelBuffer, pts: pts, ptsSeconds: ptsSeconds,
                              hdr10PlusData: hdr10PlusData)
            return
        }
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

    /// Arrival-order handover (see `arrivalFloor`). Called with `reorderLock` held; returns with it
    /// released. The frame goes out with no duration: its successor in display order may not have
    /// arrived yet, and an open-ended frame is what the layer had before #407 anyway. The floor is
    /// raised after the enqueue, so it never claims a frame that is still on its way in.
    private func handOverOnArrival(pixelBuffer: CVPixelBuffer, pts: CMTime, ptsSeconds: Double,
                                   hdr10PlusData: Data?) {
        if let below = arrivalSkipBelow, ptsSeconds < below {
            _arrivalSkippedFramesDropped += 1
            let logFirst = !arrivalSkipLogged
            arrivalSkipLogged = true
            reorderLock.unlock()
            if logFirst {
                EngineLog.emit(
                    "[Renderer] frame at \(String(format: "%.3f", ptsSeconds))s is below the seek threshold "
                    + "\(String(format: "%.3f", below))s; skipping until the first frame at or past it",
                    category: .swPlayback)
            }
            return
        }
        // #303: the newest timestamp admitted, as on the reorder path.
        if ptsSeconds > (_newestEnqueuedPtsSeconds ?? -.greatestFiniteMagnitude) {
            _newestEnqueuedPtsSeconds = ptsSeconds
        }
        let timeline = _timeline
        var clock: Double?
        if let timebase = videoRenderer.timebase as CMTimebase?, CMTimebaseGetRate(timebase) > 0 {
            let rendererSeconds = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            clock = timeline?.sourceSeconds(forRenderer: rendererSeconds) ?? rendererSeconds
        }
        guard let step = arrivalFloor?.record(ptsSeconds, clockSeconds: clock) else {
            reorderLock.unlock()
            return
        }
        if step.belowFloor { _framesBelowFloor += 1 }
        let belowCount = _framesBelowFloor
        let floor = arrivalFloor?.floor
        let generation = _flushGeneration
        reorderLock.unlock()

        flushFrame(pixelBuffer: pixelBuffer, pts: pts, hdr10PlusData: hdr10PlusData,
                   displayOrderSpacing: step.contiguous)
        if let raised = step.raisedFloor, #available(visionOS 1.1, *) {
            let source = CMTime(seconds: raised, preferredTimescale: 90_000)
            // A flush in between dropped this promise along with the frames it covered; setting it
            // now would hold the first frame of a backward seek below a pre-seek floor.
            reorderLock.lock()
            if generation == _flushGeneration {
                videoRenderer.presentationTimeExpectation =
                    .minimumUpcoming(timeline?.rendererTime(forSource: source) ?? source)
            }
            reorderLock.unlock()
        }
        if step.belowFloor, belowCount == 1 || belowCount % 250 == 0 {
            EngineLog.emit(
                "[Renderer] frame at \(String(format: "%.3f", ptsSeconds))s arrived below the promised floor "
                + "\(String(format: "%.3f", floor ?? .nan))s (\(belowCount) so far); handed over anyway",
                category: .swPlayback)
        }
    }

    /// AE#711 follow-up: the newest frame handed to the layer, before the subtitle compositor, for a
    /// rebuild to hold when the layer cannot say what it is showing (off screen, or before tvOS 17.4's
    /// readback has anything). At most one buffer, released by `flush`.
    private var _lastEnqueuedFrame: CVPixelBuffer?
    var lastEnqueuedFrame: CVPixelBuffer? {
        reorderLock.lock(); defer { reorderLock.unlock() }
        return _lastEnqueuedFrame
    }

    /// Discard all buffered frames. `removingDisplayedImage: true` (stop/teardown) also clears the visible
    /// frame; `false` (seek) holds the last frame on screen until the post-seek frame is enqueued, so a seek
    /// doesn't flash black between the old and new positions (matches the hardware path's hold-last-frame).
    ///
    /// `skipThreshold` is installed under the same lock as the flush, for a recovery that restarts the
    /// decoder on a keyframe past the playhead: a frame that arrives between the flush and a separate
    /// `setSkipThreshold` call would otherwise be handed over below the playhead (and start the floor
    /// at itself).
    func flush(removingDisplayedImage: Bool = true, skipThreshold: CMTime? = nil) {
        reorderLock.lock()
        reorderBuffer.removeAll()
        _pendingPresentation.removeAll()
        _lastEnqueuedFrame = nil
        // #407: the next frame handed over will not follow the last one, so the gap between them is
        // not a cadence measurement. Left standing, every seek would report one enormous interval.
        _lastHandedPtsSeconds = nil
        _lastReleasedPtsSeconds = nil
        // The renderer's own flush below also drops the expectation it was given.
        arrivalFloor?.reset()
        arrivalSkipBelow = nil
        arrivalSkipLogged = false
        // #303: nothing is held any more, so the frontier is not a frontier. Left standing, a
        // backward seek would keep reporting the pre-seek timestamp and read as a cushion of
        // however far the seek travelled.
        _newestEnqueuedPtsSeconds = nil
        gateMaxPacketPTS = nil
        gateReorderLead = 0   // a seek relearns the lead from the new position
        // #311: everything reported before this point describes frames that are now gone.
        _flushGeneration = SampleBufferRenderer.flushGenerations.next()
        // Invalidate the format description cache; the next load() may open a stream with different colorimetry at the same resolution.
        cachedFormatDesc = nil
        cachedFormatKey = nil
        if let skipThreshold { installSkipThresholdLocked(skipThreshold) }
        reorderLock.unlock()

        videoRenderer.flush(removingDisplayedImage: removingDisplayedImage) { }
    }

    /// Send all buffered frames to the display layer (call at EOF).
    func drainReorderBuffer() {
        reorderLock.lock()
        // Arrival order: nothing is held, but a hole in the last GOP would leave the promise below
        // the tail with no further frame to move it.
        if arrivalFloor != nil, #available(visionOS 1.1, *) {
            videoRenderer.presentationTimeExpectation = .none
        }
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

    /// `displayOrderSpacing` replaces `pts` in the #407 spacing measurement on the arrival-order
    /// path, where consecutive handovers are in decode order and their gaps say nothing about cadence:
    /// it lists the timestamps that this frame made contiguous, in the order they will be shown.
    private func flushFrame(pixelBuffer: CVPixelBuffer, pts: CMTime, hdr10PlusData: Data?,
                            nextPTS: CMTime? = nil, displayOrderSpacing: [Double]? = nil) {
        let outputBuffer = subtitleCompositor.composite(pixelBuffer, ptsSeconds: pts.seconds)
        reorderLock.lock()
        let timeline = _timeline
        reorderLock.unlock()
        guard let sampleBuffer = createSampleBuffer(
            from: outputBuffer, pts: timeline?.rendererTime(forSource: pts) ?? pts,
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
        // A queue that requires a flush but is not failed is stalled just the same, and its
        // notification does not fire again: if the host ignored it (a seek was in flight, a recovery
        // pending) this is the next chance to act on it. Treated like a failed queue: flushed, and
        // reported so the host decides how the picture comes back.
        if let reason = queueFlushReasonNow() {
            if reason == .failed, !loggedLayerFailed {
                loggedLayerFailed = true
                EngineLog.emit("[Renderer] queue target failed at enqueue #\(enqueueCount + 1): \(queueError?.localizedDescription ?? "nil"), attempting recovery via flush()", category: .swPlayback)
            } else if reason == .requiresFlush, !loggedRequiresFlushAtEnqueue {
                loggedRequiresFlushAtEnqueue = true
                EngineLog.emit("[Renderer] queue target requires a flush at enqueue #\(enqueueCount + 1) (status=\(statusName)), flushing", category: .swPlayback)
            }
            target.flush()
            reorderLock.lock()
            _pendingPresentation.removeAll()
            reorderLock.unlock()
            // The flush revives the queue, but what it held is gone and the demuxer stands ahead of
            // it: the host decides how the picture comes back.
            reportQueueFlush(reason)
        }
        if !target.isReadyForMoreMediaData, !loggedNotReady {
            loggedNotReady = true
            EngineLog.emit("[Renderer] isReadyForMoreMediaData=false at enqueue #\(enqueueCount + 1) status=\(statusName)", category: .swPlayback)
        }
        target.enqueue(sampleBuffer)
        let accepted = queueFlushReasonNow() == nil
        reorderLock.lock()
        _lastEnqueuedFrame = pixelBuffer
        if accepted {
            _acceptedFrameCount += 1
            // The queue may still refuse the frame, and says so later than this read. It counts as
            // presented only once the clock has passed it with the queue still healthy.
            if pts.isNumeric {
                _pendingPresentation.append(CMTimeGetSeconds(pts))
                if _pendingPresentation.count > Self.pendingPresentationCapacity {
                    _pendingPresentation.removeFirst(_pendingPresentation.count - Self.pendingPresentationCapacity)
                }
            }
        }
        reorderLock.unlock()

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
        for shown in displayOrderSpacing ?? [CMTimeGetSeconds(pts)] {
            if let previous = _lastHandedPtsSeconds {
                let delta = shown - previous
                if delta.isFinite {
                    _minHandedDeltaSeconds = min(_minHandedDeltaSeconds, delta)
                    _maxHandedDeltaSeconds = max(_maxHandedDeltaSeconds, delta)
                }
            }
            _lastHandedPtsSeconds = shown
        }
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
