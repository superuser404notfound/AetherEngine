// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Side data that travels with a waiting base-layer frame (dolby-vision-fel.md
/// §5.3). The base-layer queue stores only buffer + PTS by itself, so a
/// frame whose enhancement layer arrives last would otherwise reach `onFrame`
/// with `hdr10Data` dropped; carrying it here makes delivery independent of
/// arrival order. `dmNAL` is the Profile 8.1 display-metadata NAL cached for
/// this frame's PTS, resolved once at base-layer arrival for the same reason:
/// `OrderedDelivery.emit` runs on the delivery queue and does not reach
/// into the decoder's frame state (`dmRpuCache`, the queues) itself. `HardwareVideoDecoder` passes
/// `hdr10Data: nil` today (latent), so that field is unused in practice, with
/// room for params if they migrate here too.
private struct FrameSideData: Sendable {
    let hdr10Data: Data?
    let dmNAL: [UInt8]?
}

/// What `DualLayerVideoDecoder` needs from its composer.
///
/// Splitting the GPU-slot wait (`acquireSlot`) from encode-and-commit
/// (`composeAsyncWithAcquiredSlot`) is what lets the decoder decide under its
/// lock and block outside it (dolby-vision-fel.md §5.5, §5.6). `DoviFelComposer` is the
/// production implementation; tests inject a gated fake through
/// `DualLayerVideoDecoder(composer:)`.
protocol FelComposing: Sendable {
    func composeAsync(
        baseBuffer: CVPixelBuffer,
        enhancementBuffer: CVPixelBuffer,
        params: DoviMetalParams,
        frameIndex: UInt32,
        completion: @escaping @Sendable (CVPixelBuffer?) -> Void
    )
    func composeAsyncWithAcquiredSlot(
        baseBuffer: CVPixelBuffer,
        enhancementBuffer: CVPixelBuffer,
        params: DoviMetalParams,
        frameIndex: UInt32,
        completion: @escaping @Sendable (CVPixelBuffer?) -> Void
    )
    func acquireSlot()
    func releaseSlot()
    func flush()
    func releaseOutputPool()
    func flushTextureCache()
    func takePeakSlotsInUse() -> Int
    var allocatedPoolBuffers: Int { get }
    var meanGPUTimeMs: Double? { get }
}

extension FelComposing {
    func releaseOutputPool() {}
    func flushTextureCache() {}
    func takePeakSlotsInUse() -> Int { 0 }
    var allocatedPoolBuffers: Int { 0 }
    var meanGPUTimeMs: Double? { nil }
}

extension DoviFelComposer: FelComposing {}

/// What `DualLayerVideoDecoder` needs from each single-layer VideoToolbox
/// decoder (dolby-vision-fel.md §5.8).
///
/// A small protocol over `HardwareVideoDecoder` so tests can inject a fake
/// that emits a frame from inside `flush()`, proving pre-seek frames drained
/// there never reach delivery.
protocol SingleLayerVideoDecoder: VideoDecodingPipeline {
    /// Opens a decoder session from raw HEVC parameter sets (VPS, SPS, PPS),
    /// used for both layers when they arrive in-band.
    func open(
        parameterSets: [[UInt8]],
        timeBase: AVRational,
        onFrame: @escaping DecodedFrameHandler
    ) throws

    /// Moves the decoder's feed epoch to its owner's. Called from inside the owner's `flush()`
    /// critical section, so it must not take any lock a VideoToolbox callback can be waiting behind.
    func adoptFeedEpoch(_ epoch: UInt64)
    /// The flush the owner makes after `adoptFeedEpoch`: drains and discontinues the session without
    /// moving the epoch again.
    func flushKeepingEpoch()
}

extension SingleLayerVideoDecoder {
    func adoptFeedEpoch(_ epoch: UInt64) {}
    func flushKeepingEpoch() { flush() }
}

extension HardwareVideoDecoder: SingleLayerVideoDecoder {}

extension DualLayerVideoDecoder: VideoSessionRebuilding {}

/// Video decoding pipeline that transparently coordinates dual VideoToolbox HEVC decoders
/// (base layer, typically 4K, plus an enhancement layer, typically 1080p) and reconstructs the 12-bit master on Apple GPU
/// using `DoviFelComposer`. Falls back smoothly to single-layer BL if no EL is present (MEL / P8.1).
final class DualLayerVideoDecoder: VideoDecodingPipeline, @unchecked Sendable {

    // The callback itself is owned by `orderedDelivery`, not this
    // decoder, so a call already queued for delivery when the host reassigns
    // it (or `close()` clears it) is ordered against that write rather than
    // racing it under a lock the delivery path no longer takes.
    var onFrame: DecodedFrameHandler? {
        get { orderedDelivery.currentOnFrame }
        set { orderedDelivery.setOnFrame(newValue) }
    }

    // Set once by the host before `open()`; guarded by `lock` so a late
    // reassignment cannot race a VideoToolbox callback reading it.
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFirstHDR10PlusDetected }
        set { lock.lock(); _onFirstHDR10PlusDetected = newValue; lock.unlock() }
    }
    private var _onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onA53Captions }
        set { lock.lock(); _onA53Captions = newValue; lock.unlock() }
    }
    private var _onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?
    /// AE#658: the composed display buffer's format, reported on the first frame and when it changes.
    var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onDecodedFormat }
        set { lock.lock(); _onDecodedFormat = newValue; lock.unlock() }
    }
    private var _onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
    private var declaredFormat: (color: ColorDescription, codecID: AVCodecID, profile: Int32)?  // guarded by `lock`
    private var reportedPixelBufferType: OSType = 0  // guarded by `lock`

    /// What `onFrame` is handed is the composed buffer, so that buffer's type is the decoded format and
    /// its colour is what the stream declares. Called on the delivery queue; it takes `lock` for a moment, which is
    /// safe because nothing holds `lock` while waiting on that queue (`flush()` waits only after unlocking).
    private func reportDecodedFormat(_ buffer: CVPixelBuffer) {
        let type = CVPixelBufferGetPixelFormatType(buffer)
        lock.lock()
        let handler = _onDecodedFormat
        let declared = declaredFormat
        let isNew = type != reportedPixelBufferType
        if handler != nil, isNew { reportedPixelBufferType = type }
        lock.unlock()
        guard let handler, isNew, let declared else { return }
        handler(DecodedVideoFormat(
            frame: VideoStreamFormat(
                pixelFormat: DecodedVideoFormat.libavPixelFormat(forPixelBufferType: type),
                declaredBitDepth: 0,
                color: declared.color,
                codecID: declared.codecID,
                profile: declared.profile),
            pixelBufferFormat: DecodedVideoFormat.fourCC(type)))
    }

    var skipUntilPTS: CMTime? {
        get { lock.lock(); defer { lock.unlock() }; return _skipUntilPTS }
        set {
            // Lock ordering: `HardwareVideoDecoder.skipUntilPTS` takes that
            // decoder's own `skipLock`, while its output callback takes `skipLock`
            // and then re-enters this decoder's `lock` via the frame handlers.
            // Setting the sub-decoders while holding `lock` would nest the locks
            // in the opposite order, so capture the pointers and fan out outside.
            lock.lock()
            _skipUntilPTS = newValue
            let primary = primaryDecoder
            let enhancement = enhancementDecoder
            lock.unlock()
            primary.skipUntilPTS = newValue
            enhancement?.skipUntilPTS = newValue
        }
    }
    private var _skipUntilPTS: CMTime?

    /// AE#739: called when the system invalidates either layer's session. Both sub-decoders report
    /// through `reportSessionLost()` (installed outside `lock`, as `skipUntilPTS` is), the enhancement
    /// decoder from when it opens.
    var onSessionLost: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onSessionLost }
        set {
            lock.lock()
            _onSessionLost = newValue
            let primary = primaryDecoder
            let enhancement = enhancementDecoder
            lock.unlock()
            (primary as? HardwareVideoDecoder)?.onSessionLost = subDecoderLossHandler(newValue)
            (enhancement as? HardwareVideoDecoder)?.onSessionLost = subDecoderLossHandler(newValue)
        }
    }
    private var _onSessionLost: (@Sendable () -> Void)?
    /// Guarded by `lock`. A screen lock invalidates both sessions and each sub-decoder reports it;
    /// the owner hears one loss until `rebuildSession()` has replaced both, not one per layer
    /// (which rebuilt both sessions twice and repositioned twice).
    private var sessionLossReported = false

    private func subDecoderLossHandler(_ handler: (@Sendable () -> Void)?) -> (@Sendable () -> Void)? {
        guard handler != nil else { return nil }
        return { [weak self] in self?.reportSessionLost() }
    }

    private func reportSessionLost() {
        lock.lock()
        let first = !sessionLossReported
        sessionLossReported = true
        let handler = _onSessionLost
        lock.unlock()
        if first { handler?() }
    }

    /// The primary decoder's own methods are internally synchronized
    /// (`HardwareVideoDecoder.lock` / `skipLock`); it is safe to call without holding
    /// this decoder's `lock`, and callers must do so to preserve the lock ordering
    /// above. `composer` is immutable and `Sendable`.
    private let primaryDecoder: any SingleLayerVideoDecoder
    /// Guarded by `lock`. Captured into a local before any `decode`/`flush`/`close`
    /// call, which runs after the lock is released; swapped out under the lock and
    /// closed after releasing it in `flush()`/`close()`.
    private var enhancementDecoder: (any SingleLayerVideoDecoder)?
    private let composer: (any FelComposing)?

    /// Every outgoing frame — composed or bypassed — reaches the host through
    /// here (dolby-vision-fel.md §5.7). Owned by the decoder, not the composer.
    /// `DoviFelComposer` still keeps a small relay queue of its own
    /// (`deliveryQueue`) that a composed frame's completion hops through
    /// before calling `fulfil`. It is a §4.3 firewall against Metal's completion handler ever blocking on
    /// something downstream (`DoviComposeAsyncTests.
    /// doesNotDeadlockAgainstTheCallersLock` reproduces the deadlock shape
    /// removing it would reopen), not a second ordering mechanism — `fulfil`
    /// reorders every frame by ticket regardless of which queue called it,
    /// so a bypass arriving directly from a VideoToolbox thread and a
    /// composition arriving via that relay hop are indistinguishable once
    /// they reach `orderedDelivery`. See `OrderedDelivery`'s own type doc
    /// and dolby-vision-fel.md §5.7, §5.9 for the full justification. Sized off this
    /// decoder's own bounds (`DoviFelComposer.maxFramesInFlight`,
    /// `Self.maxLayerSkewFrames`) so the stall guard's threshold tracks them
    /// if either changes.
    private let orderedDelivery = OrderedDelivery(
        maxFramesInFlight: DoviFelComposer.maxFramesInFlight,
        maxLayerSkew: DualLayerVideoDecoder.maxLayerSkewFrames
    )

    /// Production use: builds the Metal composer (nil when there is no Metal
    /// device, in which case every frame bypasses). Tests inject a fake to
    /// control the GPU-slot wait without a GPU.
    init(composer: (any FelComposing)? = DoviFelComposer()) {
        self.composer = composer
        let primary = HardwareVideoDecoder()
        primary.useCustomBlockSource = true
        self.primaryDecoder = primary
    }

    /// Test seam: inject fake single-layer decoders, e.g. ones that
    /// emit a pre-seek frame from inside `flush()`.
    init(
        composer: (any FelComposing)?,
        primaryDecoder: any SingleLayerVideoDecoder,
        enhancementDecoder: (any SingleLayerVideoDecoder)?
    ) {
        self.composer = composer
        self.primaryDecoder = primaryDecoder
        (self.primaryDecoder as? HardwareVideoDecoder)?.useCustomBlockSource = true
        self.enhancementDecoder = enhancementDecoder
        (self.enhancementDecoder as? HardwareVideoDecoder)?.useCustomBlockSource = true
    }

    // Lock discipline: every `private var` below up to `lock` is guarded
    // by `lock` unless stated otherwise. `decode(packet:)` runs on the demux
    // thread while `handleBaseLayerFrame` / `handleEnhancementLayerFrame` run on
    // VideoToolbox output threads, so any state they all touch must be read or
    // written under the lock, with at most a pointer captured for use outside it.
    // `nextDeliveryTicket` and `resolveDisplayMetadata` require the lock (callers
    // hold it). `noteSettledBaseLayer` requires the lock. `orderedDelivery`
    // is its own, separately-confined owner, reached only through `fulfil`/`reset`/
    // `setOnFrame`, never through this lock. Sub-decoder calls (`decode`/`flush`/`close`,
    // `skipUntilPTS` fan-out, `open`) always run without the lock held — see the
    // ordering note on `skipUntilPTS`.
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)
    // Stream classification (dolby-vision-fel.md §5.2, invariant I9 in §5.12): decided once, from the
    // first RPU's `el_type`, before the enhancement decoder opens. A per-frame
    // `disable_residual_flag` is a kernel flag (`DoviComposerFlags.disableResidual`,
    // honoured by the composer) and never changes these. Guarded by `lock`.
    private var isFEL: Bool = false
    private var isMEL: Bool = false
    private var streamClassified: Bool = false
    private var frameIndex: UInt32 = 0

    private var primaryDecoderInitialized = false
    /// Set by the first failed in-band open of the primary decoder. Retrying on every later packet
    /// with parameter sets would only repeat the failure and leave the player on a black screen with
    /// one log line per keyframe; the failure is reported once, and `decode` refuses packets after it.
    /// Guarded by `lock`.
    private var primaryOpenFailure: Error?
    /// Fired once, on the thread that called `decode`, when the primary decoder cannot be opened from
    /// in-band parameter sets: nothing can be shown, so the host should fall back or surface an error
    /// (the hvcC path throws the equivalent from `open(stream:)`).
    var onFatalDecodeError: (@Sendable (Error) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFatalDecodeError }
        set { lock.lock(); _onFatalDecodeError = newValue; lock.unlock() }
    }
    private var _onFatalDecodeError: (@Sendable (Error) -> Void)?
    /// The error `onFatalDecodeError` reported, if any.
    var fatalDecodeError: Error? { lock.lock(); defer { lock.unlock() }; return primaryOpenFailure }
    /// Set by the first failed open of the enhancement decoder. Retrying on every later packet would
    /// start a new VideoToolbox session attempt and write a log line per frame for the rest of the
    /// session; the failure is logged once and the stream stays on the base layer (every frame takes
    /// the single-layer bypass). Not fatal, unlike `primaryOpenFailure`: there is still a picture to
    /// show. Cleared by `close()`. Guarded by `lock`.
    private var enhancementOpenFailure: Error?
    /// The error that stopped the enhancement decoder from opening, if any.
    var enhancementDecoderOpenError: Error? { lock.lock(); defer { lock.unlock() }; return enhancementOpenFailure }
    /// Builds the enhancement-layer session. Replaced by tests only, before the first packet.
    var makeEnhancementDecoder: () -> any SingleLayerVideoDecoder = {
        let decoder = HardwareVideoDecoder()
        decoder.useCustomBlockSource = true
        return decoder
    }
    private var blVPS: [UInt8]?
    private var blSPS: [UInt8]?
    private var blPPS: [UInt8]?

    private var elVPS: [UInt8]?
    private var elSPS: [UInt8]?
    private var elPPS: [UInt8]?
    /// Fixed-capacity side data ring for Dolby Vision metadata (dolby-vision-fel.md §5.3).
    /// Stores `{ params, dmNAL }` keyed by canonical PTS, capacity 32, no sorting.
    private var sideDataRing = FrameSideDataRing()
    /// Restamps each enhancement-layer packet with the time of the base-layer picture of the same POC,
    /// so pairing by time pairs by picture order even when the layers' GOPs differ. Guarded by `lock`.
    private var pictureAlignment = DualLayerVideoDecoder.makeAlignment()
    private var blFrameQueue: [Int64: (buffer: CVPixelBuffer, pts: CMTime, ticket: UInt64, seq: UInt64, side: FrameSideData)] = [:]
    private var elFrameQueue: [Int64: CVPixelBuffer] = [:]

    /// Maximum layer skew in frames (dolby-vision-fel.md §5.5): a waiting base-layer
    /// frame is bypassed under its own arrival ticket once this many newer
    /// base-layer frames have arrived. Starts at 3; the 1 Hz summary's maximum skew
    /// counter (§5.11) is what measures whether it can tighten.
    static let maxLayerSkewFrames = 3

    /// A waiting base frame is bypassed once K newer ones have arrived, so an enhancement picture
    /// restamped K or more frames back would find its partner gone: the alignment declines to place those.
    static func makeAlignment() -> DualLayerPictureAlignment {
        var a = DualLayerPictureAlignment()
        a.maxBackwardRestamp = maxLayerSkewFrames - 1
        return a
    }
    /// The enhancement layer can run ahead of the 4K base layer after a seek or at startup.
    /// Retain up to 10 waiting EL frames (~6 MB each) before pruning the oldest.
    static let maxEnhancementLayerQueueFrames = 10
    /// Counts base-layer arrivals. A queued entry is due for bypass once
    /// `blArrivalSeq - entry.seq >= maxLayerSkewFrames`. Guarded by `lock`.
    private var blArrivalSeq: UInt64 = 0
    /// Recently settled (composed or bypassed) base-layer keys. An enhancement
    /// frame matching one (±300 ticks) can never pair again and is dropped on
    /// arrival (dolby-vision-fel.md §5.5). Not "older than the newest": output is in decode
    /// order, so older-PTS base frames settle after newer ones. Guarded by `lock`.
    private var settledBlKeys: [Int64] = []
    /// How many settled base-layer keys are remembered (dolby-vision-fel.md §5.5).
    static let settledKeyMemory = 64
    /// Last parameters that came from a real RPU, and how many frames in a row have borrowed them. Both
    /// move in decode order, in `recordSideData`.
    private var lastGoodParams: DoviMetalParams?
    private var lastGoodDMNAL: [UInt8]?
    private var borrowedParamsRun = 0
    /// A frame whose RPU is missing or failed its CRC may borrow the previous frame's parameters
    /// for up to this many frames in a row. Reshaping and NLQ parameters are constant across a scene,
    /// so this beats dropping to the base layer; a longer run is not trusted.
    static let maxBorrowedParamsRun = 3
    private(set) var summaryBorrowedParams = 0

    // 1 Hz summary counters (dolby-vision-fel.md §5.11). Guarded by `lock`.
    /// Compose outcomes are counted from the GPU completion thread, so they get their own lock rather
    /// than `lock` (taking that one inside the delivery path perturbs the pairing races).
    private let composeResultLock = NSLock()
    private var summaryComposedFrames: Int = 0
    /// Frames the GPU composed since this decoder was created. Unlike `summaryComposedFrames` it is
    /// never reset by the 1 Hz summary or by `flush()`, so a probe can ask "did anything compose".
    /// Guarded by `composeResultLock`.
    private var totalComposedFrames: Int = 0
    private var summaryComposeFailures: Int = 0
    /// Compositions started, and compositions whose frame (composed or fallback) has been handed to
    /// `orderedDelivery`. Equal when nothing is on the GPU or in a completion handler. Guarded by
    /// `composeResultLock`; read by `drainForEndOfStream` and `quiesceForTesting`.
    private var composeRequestsStarted = 0
    private var composeRequestsHandedOff = 0
    private var summaryBypassNoEL: Int = 0
    private var summaryBypassNoRPU: Int = 0
    private var summaryDropStaleEL: Int = 0
    private var summaryPrunedEL: Int = 0
    private var summaryMaxObservedSkew: Int = 0
    private var lastSummaryTimestamp: TimeInterval = 0

    /// Held for the whole of `flush()` and `close()`, so two of them (the EOF flush on the demux
    /// thread against a seek flush on the main actor, or either against `close()`) run one after
    /// the other instead of interleaving their critical sections: without it one call could lower
    /// `draining` and clear the queues while the other was still draining the hardware decoders.
    /// Lock order: `lifecycleLock` before `lock`, never the other way round. Nothing on the pairing,
    /// delivery or VideoToolbox callback paths takes it (`handle*Frame`, `orderedDelivery`, the
    /// sub-decoders' output callbacks), so the drains inside `flush()` can wait on those paths with
    /// it held; `decode(packet:)` does not take it either.
    private let lifecycleLock = NSLock()
    private let lock = NSRecursiveLock()
    private var _feedEpoch: UInt64 = 0
    /// True while `flush()` is draining the hardware decoders (dolby-vision-fel.md
    /// §5.8). `HardwareVideoDecoder.flush()` waits for the frames VideoToolbox
    /// still owes, which arrive through the normal callbacks while the host
    /// thread is blocked inside it; those are pre-seek frames and are dropped
    /// on arrival rather than paired, ticketed or delivered. Guarded by `lock`.
    private var draining = false
    /// Single use (dolby-vision-fel.md §5.8): set by `close()`, after which `open`
    /// refuses with `VideoDecoderError.decoderClosed`. The host builds a new
    /// decoder per session, so nothing reopens one; the flag turns a latent
    /// stale-state reuse into a loud error. Guarded by `lock`.
    private var isClosed = false

    // MARK: - Ordered delivery
    //
    // Composition is asynchronous, so a frame's pixels are ready on a Metal
    // completion thread rather than at the point the decoder handed them over.
    // Every outgoing frame — composed, bypassed or pruned — takes a ticket
    // here, under `lock`, in decode order, at base-layer arrival.
    // Ordering behind that ticket, and `emit` itself, live entirely in
    // `orderedDelivery` from here on (dolby-vision-fel.md §5.7): once a ticket is
    // issued, this decoder's only remaining job is to hand `orderedDelivery`
    // the ticket, the epoch it was issued in, and the finished frame.
    private var deliveryNextTicket: UInt64 = 0

    var feedEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }; return _feedEpoch
    }

    static func canonicalKey(pts: CMTime) -> Int64 {
        guard pts.isNumeric else { return Int64.min }
        return pts.convertScale(90000, method: .roundHalfAwayFromZero).value
    }

    static func canonicalKey(rawPTS: Int64, timeBase: AVRational) -> Int64 {
        guard rawPTS != Int64.min else { return Int64.min }
        // Stream timestamps are untrusted: a product that overflows has no usable key.
        let (value, overflow) = rawPTS.multipliedReportingOverflow(by: Int64(timeBase.num))
        guard !overflow else { return Int64.min }
        let pts = CMTimeMake(value: value, timescale: max(timeBase.den, 1))
        return canonicalKey(pts: pts)
    }

    // MARK: - Lifecycle

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        // Single use: refuse before touching `stream` or mutating anything.
        lock.lock()
        let closed = isClosed
        let hasComposer = composer != nil
        lock.unlock()
        guard !closed else { throw VideoDecoderError.decoderClosed }
        // Fail fast if no composer (no Metal device or shader compilation failed).
        // The host can then fall back to the native 8.1 route instead of decoding the EL for nothing.
        guard hasComposer else {
            EngineLog.emit("[DualLayerVideoDecoder] No composer available; FEL composition disabled", category: .swPlayback)
            throw VideoDecoderError.composerUnavailable
        }
        (primaryDecoder as? HardwareVideoDecoder)?.useCustomBlockSource = true
        if let codecpar = stream.pointee.codecpar {
            lock.lock()
            declaredFormat = (ColorDescription(codecpar: codecpar), codecpar.pointee.codec_id, codecpar.pointee.profile)
            lock.unlock()
        }
        self.onFrame = { [weak self] buffer, pts, extra in
            self?.reportDecodedFormat(buffer)
            onFrame(buffer, pts, extra)
        }
        lock.lock()
        self.timeBase = stream.pointee.time_base
        // Only an hvcC record can build the session up front. Extradata of that size that is something
        // else (an Annex B parameter-set blob, say) takes the in-band path, where the parameter
        // sets are read from the packets, instead of throwing out of `open`.
        var hasHVCC = false
        if (stream.pointee.codecpar?.pointee.extradata_size ?? 0) > 23,
           let par = stream.pointee.codecpar?.pointee, let ed = par.extradata, ed[0] == 1 {
            hasHVCC = true
            // hvcC: the base layer's SPS/PPS may never repeat in band.
            pictureAlignment.seedBaseParameterSets(parseHVCCParameterSets(ed, Int(par.extradata_size)))
        }
        lock.unlock()

        if hasHVCC {
            // `HardwareVideoDecoder.open` builds the VT session; it synchronizes
            // internally, so this runs without `lock` held (see the lock ordering note above).
            try primaryDecoder.open(stream: stream) { [weak self] baseBuffer, pts, hdr10Data in
                self?.handleBaseLayerFrame(baseBuffer: baseBuffer, pts: pts, hdr10Data: hdr10Data)
            }
            lock.lock()
            primaryDecoderInitialized = true
            lock.unlock()
        } else {
            // Parameter sets are carried in-band in the video packets (e.g. hev1 MP4)
            lock.lock()
            primaryDecoderInitialized = false
            lock.unlock()
        }
    }

    // MARK: - Decode Loop

    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64? = nil) {
        // Single snapshot under the lock: the epoch gate, the primary
        // readiness flag and the time base are all shared with the VT threads.
        // A closed decoder refuses packets outright: without this,
        // `ensurePrimaryDecoder` could reopen the primary session after `close()`.
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        if let epoch, epoch != _feedEpoch {
            lock.unlock()
            return
        }
        // The epoch this packet entered under, whether or not the caller passed one: a `flush()` that
        // lands while the packet is being parsed below must stop it from touching post-flush state.
        let entryEpoch = _feedEpoch
        let primed = primaryDecoderInitialized
        let tb = timeBase
        lock.unlock()

        if !primed {
            ensurePrimaryDecoder(from: packet)
        }
        lock.lock()
        guard primaryDecoderInitialized else { lock.unlock(); return }
        lock.unlock()

        let ptsRaw = packet.pointee.pts
        let ptsKey = Self.canonicalKey(rawPTS: ptsRaw, timeBase: tb)

        // Extract EL NALs, RPU, and rewrite Base Layer packet to Profile 8.1.
        // Whether to extract is read from the (immutable once classified) stream state.
        // If not composing, skip parameter extraction entirely.
        // Per dolby-vision-fel.md §5.3, §5.4: VideoToolbox format description carries no dvcC,
        // so VT skips unspec62/63 for both FEL and MEL without rebuilding the base-layer packet.
        let (skipEL, canCompose): (Bool, Bool) = {
            lock.lock()
            defer { lock.unlock() }
            let composing = !isClosed && !isMEL && composer != nil
            return (isMEL, composing)
        }()
        // One-shot stream classification: the first definitive RPU decides, later
        // RPUs — including per-frame `disable_residual_flag`, which rides to the kernels
        // as `DoviComposerFlags.disableResidual` — never change it. In particular this
        // never closes the enhancement decoder; decoders are only torn down in
        // `flush()`/`close()`, never from `decode(packet:)`.
        let layers = DoviRpuConverter.separateDualLayers(
            packet,
            extractEL: !skipEL,
            useCustomBlockSource: true,
            extractParams: canCompose
        )
        applyStreamClassification(DoviRpuConverter.classifyStream(layers))

        // One critical section for everything this packet writes into shared state: the side-data
        // record (which also moves `lastGoodParams`) and the picture-order restamp. A `flush()` or
        // `close()` that landed while `separateDualLayers` ran (outside the lock) means this packet
        // belongs to the old feed: recording it would poison the post-flush state, or undo a close.
        lock.lock()
        guard !isClosed, _feedEpoch == entryEpoch else {
            lock.unlock()
            var stale = layers.elPacket
            trackedPacketFree(&stale)
            return
        }
        if ptsKey != Int64.min {
            // In decode order, here, so every frame carries concrete parameters by the time it pairs:
            // compose time runs in completion order, which is not stream order.
            recordSideData(key: ptsKey, params: layers.rpuParams, dmNAL: layers.convertedRpu,
                           usesPrevious: layers.usesPreviousMapping, disableResidual: layers.disableResidual)
        }

        // The enhancement decoder opens for a classified FEL stream only
        // (dolby-vision-fel.md §5.2): MEL never opens it, and the EL keeps decoding across RPUs
        // with `disable_residual_flag` set.
        // Also require a composer; without one, never engage the EL decoder.
        let engageEL = isFEL && !isMEL && composer != nil
        if engageEL, let data = packet.pointee.data {
            // `separateDualLayers` left the packet intact (custom block source), so both layers are
            // still in it. Every unit is read, with or without an EL, to keep the POC state current.
            let wasReordered = pictureAlignment.reorderedUnits > 0
            let elPTS = pictureAlignment.enhancementPTS(data, Int(packet.pointee.size), framing: .lengthPrefixed(size: 4), pts: ptsRaw)
            let nowReordered = pictureAlignment.reorderedUnits > 0
            lock.unlock()
            layers.elPacket?.pointee.pts = elPTS
            if nowReordered && !wasReordered {
                EngineLog.emit("[DualLayerVideoDecoder] enhancement layer is reordered against the base layer; pairing by picture order", category: .swPlayback)
            }
        } else {
            lock.unlock()
        }
        if engageEL, let elPacket = layers.elPacket {
            ensureEnhancementDecoder(from: elPacket)
            // Capture under the lock, decode outside it: `close()`/`flush()` may
            // swap the decoder out concurrently, and the sub-decoder call must not
            // nest inside this lock. Re-check `isClosed` from
            // the same snapshot: a `close()` that landed after the entry gate
            // must not feed the (possibly freshly installed) enhancement decoder.
            lock.lock()
            let el = enhancementDecoder
            let closedAfterEnsure = isClosed
            lock.unlock()
            if !closedAfterEnsure {
                el?.decode(packet: elPacket, epoch: epoch)
            }
            var elOpt: UnsafeMutablePointer<AVPacket>? = elPacket
            trackedPacketFree(&elOpt)
        } else if let elPacket = layers.elPacket {
            var elOpt: UnsafeMutablePointer<AVPacket>? = elPacket
            trackedPacketFree(&elOpt)
        }

        // Decode Base Layer packet.
        //
        // With `useCustomBlockSource` the packet is untouched: `separateDualLayers` only reads it, so
        // the base layer's own RPU NAL (unspec62) is still inside it, which
        // looks alarming next to a composer that is about to apply the same
        // reshaping curve itself. It is inert: the primary decoder's format
        // description is built from the base layer's VPS/SPS/PPS alone (see
        // `ensurePrimaryDecoder`) with no `dvcC`/`dvvC` record, so VideoToolbox
        // decodes plain HEVC and skips the unspec62 NAL as an unknown type. The
        // curve is applied exactly once, on the GPU. (`separateDualLayers` also backs
        // `convertPacketToProfile81`, the remux route, where it does rewrite the packet to
        // Profile 8.1 and the container declares a `dvcC`; that is not this path.)
        //
        // Re-check `isClosed` before feeding the primary — a `close()`
        // that landed after the entry gate must not reopen/feed a torn-down session.
        lock.lock()
        let closedBeforePrimary = isClosed
        lock.unlock()
        guard !closedBeforePrimary else { return }
        primaryDecoder.decode(packet: packet, epoch: epoch)
    }

    /// Applies one RPU's stream classification. The first definitive report wins and every
    /// later one is ignored, so one frame can never shut off the enhancement layer for the
    /// rest of the session (invariant I9, dolby-vision-fel.md §5.12). Called from `decode(packet:)` — which
    /// never closes a decoder — and from the test seam below.
    private func applyStreamClassification(_ kind: DoviRpuConverter.StreamKind) {
        lock.lock()
        defer { lock.unlock() }
        guard !streamClassified else { return }
        switch kind {
        case .undetermined:
            return
        case .fel:
            isFEL = true
            isMEL = false
            streamClassified = true
            EngineLog.emit("[DualLayerVideoDecoder] FEL stream detected; engaging enhancement decoder", category: .swPlayback)
        case .mel:
            isFEL = false
            isMEL = true
            streamClassified = true
            EngineLog.emit("[DualLayerVideoDecoder] MEL stream detected; secondary decoder bypassed, routing Base Layer directly", category: .swPlayback)
        }
    }

    // Lazily opens the primary decoder from in-band parameter sets. Only the demux
    // thread reaches here (from `decode`), but `primaryDecoderInitialized`, the
    // accumulated `blVPS/SPS/PPS` and `timeBase` are shared with the VT threads, so
    // every touch is under `lock`; the blocking `open` runs outside it.
    // Resurrection guard: `decode()` passes the entry gate before
    // `close()` runs, so re-check `isClosed` before opening and again before
    // installing — a post-close open is torn down immediately instead of
    // leaving a live VT session in a closed decoder.
    private func ensurePrimaryDecoder(from packet: UnsafeMutablePointer<AVPacket>) {
        lock.lock()
        guard !primaryDecoderInitialized, !isClosed, primaryOpenFailure == nil else { lock.unlock(); return }
        var v = blVPS
        var s = blSPS
        var p = blPPS
        let tb = timeBase
        lock.unlock()
        guard let data = packet.pointee.data, packet.pointee.size > 4 else { return }
        let size = Int(packet.pointee.size)

        A53SEIParser.forEachNAL(data, size, .lengthPrefixed(size: 4)) { nal, len in
            let nalType = (nal[0] >> 1) & 0x3F
            let bytes = [UInt8](UnsafeBufferPointer(start: nal, count: len))
            switch nalType {
            case 32: v = bytes
            case 33: s = bytes
            case 34: p = bytes
            default: break
            }
        }

        guard let vv = v, let ss = s, let pp = p else {
            // Incomplete set: accumulate what this packet carried for the next one.
            lock.lock()
            if blVPS == nil { blVPS = v }
            if blSPS == nil { blSPS = s }
            if blPPS == nil { blPPS = p }
            lock.unlock()
            return
        }
        do {
            try primaryDecoder.open(parameterSets: [vv, ss, pp], timeBase: tb) { [weak self] baseBuffer, pts, hdr10Data in
                self?.handleBaseLayerFrame(baseBuffer: baseBuffer, pts: pts, hdr10Data: hdr10Data)
            }
            lock.lock()
            blVPS = vv
            blSPS = ss
            blPPS = pp
            if isClosed || primaryDecoderInitialized {
                // Lost the race with `close()` (or another opener): the session
                // just built belongs to a closed decoder — tear it down outside
                // the lock instead of marking it initialized.
                lock.unlock()
                primaryDecoder.close()
                return
            }
            primaryDecoderInitialized = true
            lock.unlock()
            EngineLog.emit("[DualLayerVideoDecoder] primary decoder initialized from in-band parameter sets", category: .swPlayback)
        } catch {
            // Fail once, visibly: the same sets would fail the same way on every later packet.
            lock.lock()
            let firstFailure = primaryOpenFailure == nil
            if firstFailure { primaryOpenFailure = error }
            let handler = _onFatalDecodeError
            lock.unlock()
            guard firstFailure else { return }
            EngineLog.emit("[DualLayerVideoDecoder] failed to open the primary decoder from in-band parameter sets, no video will be produced: \(error)", category: .swPlayback)
            handler?(error)
        }
    }

    // Lazily opens the enhancement decoder. Same discipline as
    // `ensurePrimaryDecoder`: shared state under `lock`, VT session build outside
    // it, install under the lock only if still absent **and** the decoder is not
    // closed (resurrection guard: a thread past the `decode()` entry gate
    // that reaches the install after `close()` cleared `enhancementDecoder` to
    // nil must close its spare instead of planting a live VT session into the
    // closed decoder).
    func ensureEnhancementDecoder(from packet: UnsafeMutablePointer<AVPacket>) {
        lock.lock()
        // Never open the EL decoder without a composer. In production this is
        // redundant (`engageEL` in `decode()` already gates on `composer != nil`), but
        // it makes the invariant explicit and safe against future refactors.
        guard enhancementDecoder == nil, !isClosed, composer != nil, enhancementOpenFailure == nil else { lock.unlock(); return }
        var v = elVPS
        var s = elSPS
        var p = elPPS
        let skip = _skipUntilPTS
        let sessionLost = _onSessionLost
        let tb = timeBase
        lock.unlock()
        guard let data = packet.pointee.data, packet.pointee.size > 4 else { return }
        let size = Int(packet.pointee.size)

        A53SEIParser.forEachNAL(data, size, .lengthPrefixed(size: 4)) { nal, len in
            let nalType = (nal[0] >> 1) & 0x3F
            let bytes = [UInt8](UnsafeBufferPointer(start: nal, count: len))
            switch nalType {
            case 32: v = bytes
            case 33: s = bytes
            case 34: p = bytes
            default: break
            }
        }

        guard let vv = v, let ss = s, let pp = p else {
            lock.lock()
            if elVPS == nil { elVPS = v }
            if elSPS == nil { elSPS = s }
            if elPPS == nil { elPPS = p }
            lock.unlock()
            return
        }
        let decoder = makeEnhancementDecoder()
        decoder.skipUntilPTS = skip
        (decoder as? HardwareVideoDecoder)?.onSessionLost = subDecoderLossHandler(sessionLost)
        do {
            try decoder.open(parameterSets: [vv, ss, pp], timeBase: tb) { [weak self] elBuffer, pts, _ in
                self?.handleEnhancementLayerFrame(elBuffer: elBuffer, pts: pts)
            }
            lock.lock()
            elVPS = vv
            elSPS = ss
            elPPS = pp
            if enhancementDecoder == nil, !isClosed {
                // Same epoch as this decoder: a `flush()` before the first EL packet has already moved
                // `_feedEpoch`, and a decoder left at epoch 0 would drop every packet it is fed.
                // Safe under `lock`: the new decoder is not shared yet, so nothing else holds its lock.
                decoder.adoptFeedEpoch(_feedEpoch)
                enhancementDecoder = decoder
                lock.unlock()
                EngineLog.emit("[DualLayerVideoDecoder] secondary decoder initialized for the enhancement layer", category: .swPlayback)
            } else {
                // Lost the race with another opener, or `close()` cleared the
                // slot (and set `isClosed`) while the session was building: do
                // not plant a live VT session into the closed decoder; tear the
                // spare down outside the lock.
                lock.unlock()
                decoder.close()
            }
        } catch {
            // Fail once: the same sets would fail the same way on every later packet.
            lock.lock()
            elVPS = vv
            elSPS = ss
            elPPS = pp
            let firstFailure = enhancementOpenFailure == nil
            if firstFailure { enhancementOpenFailure = error }
            lock.unlock()
            guard firstFailure else { return }
            EngineLog.emit("[DualLayerVideoDecoder] failed to initialize EL decoder, continuing with the base layer only: \(error)", category: .swPlayback)
        }
    }

    // MARK: - Frame Emission

    /// Reserves this frame's place in the output order. The caller holds `lock`.
    ///
    /// Every ticket must reach ``OrderedDelivery/fulfil(ticket:epoch:_:)`` or the
    /// queue behind it stalls — `orderedDelivery`'s own stall guard is the backstop
    /// if one never does; a flush or close retires outstanding tickets wholesale.
    private func nextDeliveryTicket() -> UInt64 {
        let t = deliveryNextTicket
        deliveryNextTicket &+= 1
        return t
    }

    /// Looks up and removes this frame's Profile 8.1 display-metadata NAL,
    /// within the same jitter tolerance as the RPU cache. The caller holds
    /// `lock`.
    ///
    /// Resolved once, at base-layer arrival — the same point `hdr10Data`
    /// already enters the system as a parameter — so it can travel with the
    /// frame instead of living in a cache `OrderedDelivery.emit` would
    /// otherwise have to reach back into without the decoder's lock
    /// (dolby-vision-fel.md §5.7).
    private func resolveDisplayMetadata(key: Int64) -> [UInt8]? {
        sideDataRing.removeDisplayMetadata(key: key)
    }

    // MARK: - Frame Pairing & Metal Composition
    //
    // dolby-vision-fel.md §5.5, §5.6: decide under the lock, act outside it. Each
    // handler holds `lock` only while it matches queues, consumes caches and
    // issues the delivery ticket. The GPU slot wait, encode and commit happen
    // after the lock is released (see `runCompose`), so backpressure on the
    // calling VideoToolbox thread never stalls `orderedDelivery`, the other
    // layer's callback, `flush()` or `close()`.

    /// What one frame handler decided while holding `lock`. Payloads are a
    /// baton pass: the handler stops touching them once they are in here, and
    /// `runCompose` / `orderedDelivery` is the only reader after that.
    /// `dmNAL` and `epoch` are resolved under the same lock hold that issued
    /// `ticket` (dolby-vision-fel.md §5.7): `dmNAL` so `OrderedDelivery.emit` never
    /// touches `dmRpuCache`, `epoch` so a late completion can tell a stale
    /// delivery from a current one without the decoder lock.
    private struct ComposeRequest {
        let ticket: UInt64
        let epoch: UInt64
        let base: CVPixelBuffer
        let enhancement: CVPixelBuffer
        let params: DoviMetalParams
        let frameIndex: UInt32
        let pts: CMTime
        let hdr10Data: Data?
        let dmNAL: [UInt8]?
        /// Which arrival path produced this, for the compose-failure log.
        let arrived: String
    }

    private struct BypassRequest {
        let ticket: UInt64
        let epoch: UInt64
        let buffer: CVPixelBuffer
        let pts: CMTime
        let hdr10Data: Data?
        let dmNAL: [UInt8]?
        let reason: String
    }

    private enum PairingOutcome {
        case queued
        case bypass(BypassRequest)
        case compose(ComposeRequest)
    }

    /// Hands one bypass request straight to `orderedDelivery`. No lock held.
    private func fulfilBypass(_ req: BypassRequest) {
        orderedDelivery.fulfil(
            ticket: req.ticket, epoch: req.epoch,
            DeliveredFrame(buffer: SendableBuffer(value: req.buffer), pts: req.pts, hdr10Data: req.hdr10Data, dmNAL: req.dmNAL)
        )
    }

    /// Acquires the GPU slot with no lock held, then encodes and commits. The
    /// completed frame (or the base layer when composition fails) reaches
    /// `orderedDelivery`, which reorders by ticket. The completion closure
    /// captures `orderedDelivery` strongly and the decoder weakly for counters
    /// (dolby-vision-fel.md §5.7): a completion that outlives the decoder
    /// still calls `fulfil`, which drops it once `orderedDelivery`'s epoch has
    /// moved on, instead of silently no-oping on a `weak self`.
    private func runCompose(_ req: ComposeRequest) {
        guard let composer else {
            orderedDelivery.fulfil(
                ticket: req.ticket, epoch: req.epoch,
                DeliveredFrame(buffer: SendableBuffer(value: req.base), pts: req.pts, hdr10Data: req.hdr10Data, dmNAL: req.dmNAL)
            )
            return
        }
        if let concrete = composer as? DoviFelComposer {
            FelResidualMeasure.sampleIfDue(composer: concrete, base: req.base, enhancement: req.enhancement,
                                           params: req.params, frameIndex: req.frameIndex, pts: req.pts)
        }
        composeResultLock.lock(); composeRequestsStarted += 1; composeResultLock.unlock()
        composer.acquireSlot()
        let fallback = SendableBuffer(value: req.base)
        // Scalars (plus the strongly-captured `delivery`) copied out so the
        // `@Sendable` completion captures no CoreVideo types (Swift 6 mode
        // rejects the struct itself).
        let ticket = req.ticket
        let epoch = req.epoch
        let pts = req.pts
        let hdr10Data = req.hdr10Data
        let dmNAL = req.dmNAL
        let arrived = req.arrived
        let delivery = orderedDelivery
        composer.composeAsyncWithAcquiredSlot(
            baseBuffer: req.base,
            enhancementBuffer: req.enhancement,
            params: req.params,
            frameIndex: req.frameIndex
        ) { [weak self] composed in
            self?.recordComposeResult(success: composed != nil)
            if composed == nil {
                EngineLog.emit("[DualLayerVideoDecoder] compose failed (\(arrived)): pts=\(String(format: "%.3f", pts.seconds))", category: .swPlayback, level: .verbose)
            }
            let buffer = SendableBuffer(value: composed ?? fallback.value)
            delivery.fulfil(ticket: ticket, epoch: epoch, DeliveredFrame(buffer: buffer, pts: pts, hdr10Data: hdr10Data, dmNAL: dmNAL))
            self?.composeResultLock.lock(); self?.composeRequestsHandedOff += 1; self?.composeResultLock.unlock()
        }
    }

    private func recordComposeResult(success: Bool) {
        composeResultLock.lock()
        if success { summaryComposedFrames += 1; totalComposedFrames += 1 } else { summaryComposeFailures += 1 }
        composeResultLock.unlock()
    }

    /// Frames composed on the GPU so far (bypassed and failed frames are not counted).
    var composedFrameCount: Int {
        composeResultLock.lock(); defer { composeResultLock.unlock() }
        return totalComposedFrames
    }

    /// Internal rather than private so `DualLayerVideoDecoderTests` can drive it directly.
    func handleBaseLayerFrame(baseBuffer: CVPixelBuffer, pts: CMTime, hdr10Data: Data?) {
        // The ticket is issued when the frame arrives, so a frame that
        // waits for a late enhancement layer keeps its place in decode order.
        // The arrival may also push older waiting frames past K newer frames,
        // which go out here under their own tickets (`due`).
        let outcome: PairingOutcome
        let due: [BypassRequest]
        (outcome, due) = {
            lock.lock()
            defer { lock.unlock() }

            // Defense in depth: VT callbacks still in flight when
            // `close()` runs must not pair, ticket or queue into cleared state.
            guard !isClosed else { return (.queued, []) }
            // Pre-seek frame drained by `flush()`: drop before it can
            // take a ticket or occupy a queue slot meant for post-seek frames.
            guard !draining else { return (.queued, []) }
            guard isFEL, !isMEL, enhancementDecoder != nil, composer != nil else {
                // Not a FEL stream or secondary decoder not engaged (e.g. MEL or P8.1 fallback): emit Base Layer directly
                EngineLog.emit("[DualLayerVideoDecoder] bypass, single layer: isFEL=\(isFEL), isMEL=\(isMEL), enhDecoder=\(enhancementDecoder != nil)", category: .swPlayback, level: .verbose)
                if isFEL && !isMEL && enhancementDecoder == nil {
                    summaryBypassNoEL += 1
                }
                let singleLayerKey = Self.canonicalKey(pts: pts)
                let dmNAL = resolveDisplayMetadata(key: singleLayerKey)
                return (.bypass(BypassRequest(ticket: nextDeliveryTicket(), epoch: _feedEpoch, buffer: baseBuffer, pts: pts, hdr10Data: hdr10Data, dmNAL: dmNAL, reason: "single-layer")), [])
            }

            let key = Self.canonicalKey(pts: pts)
            let ticket = nextDeliveryTicket()
            let epoch = _feedEpoch
            let dmNAL = resolveDisplayMetadata(key: key)
            blArrivalSeq &+= 1
            let seq = blArrivalSeq

            var primary: PairingOutcome
            // A frame without a timestamp has nothing to pair on: it goes out as its base layer now, under
            // the ticket it already holds, rather than waiting for a partner that cannot match it.
            guard key != Int64.min else {
                EngineLog.emit("[DualLayerVideoDecoder] bypass, no timestamp: base-layer frame has nothing to pair on", category: .swPlayback, level: .verbose)
                return (.bypass(BypassRequest(ticket: ticket, epoch: epoch, buffer: baseBuffer, pts: pts, hdr10Data: hdr10Data, dmNAL: dmNAL, reason: "no-pts")), collectDueBypasses())
            }
            let mKey: Int64?
            if elFrameQueue[key] != nil {
                mKey = key
            } else {
                // Search within +/- 300 ticks (~3.3ms) for clock jitter tolerance
                mKey = elFrameQueue.keys.first(where: { FrameSideDataRing.isWithinJitter($0, key) })
            }

            if let mKey, let elBuffer = elFrameQueue.removeValue(forKey: mKey) {
                // Matching EL frame is already ready: compose on the Metal GPU outside the lock
                guard let params = takeParams(key: key) else {
                    // Missing RPU metadata: do NOT synthesize identity NLQ. Emit base layer directly.
                    EngineLog.emit("[DualLayerVideoDecoder] bypass, missing RPU: key=\(key)", category: .swPlayback, level: .verbose)
                    summaryBypassNoRPU += 1
                    noteSettledBaseLayer(key: key)
                    primary = .bypass(BypassRequest(ticket: ticket, epoch: epoch, buffer: baseBuffer, pts: pts, hdr10Data: hdr10Data, dmNAL: dmNAL, reason: "missing-rpu"))
                    return (primary, collectDueBypasses())
                }
                frameIndex &+= 1
                noteSettledBaseLayer(key: key)
                primary = .compose(ComposeRequest(ticket: ticket, epoch: epoch, base: baseBuffer, enhancement: elBuffer, params: params, frameIndex: frameIndex, pts: pts, hdr10Data: hdr10Data, dmNAL: dmNAL, arrived: "base layer arrived last"))
            } else {
                // EL frame has not arrived yet: queue Base Layer frame under its ticket
                EngineLog.emit("[DualLayerVideoDecoder] queued base layer: pts=\(String(format: "%.3f", pts.seconds)) key=\(key), elCount=\(elFrameQueue.count)", category: .swPlayback, level: .verbose)
                var displaced: BypassRequest?
                if let old = blFrameQueue[key] {
                    // Same canonical key twice: the old entry's ticket would stall
                    // delivery forever if dropped, so bypass it under its ticket,
                    // carrying its stored side data.
                    displaced = BypassRequest(ticket: old.ticket, epoch: epoch, buffer: old.buffer, pts: old.pts, hdr10Data: old.side.hdr10Data, dmNAL: old.side.dmNAL, reason: "duplicate-key")
                    noteSettledBaseLayer(key: key)
                }
                blFrameQueue[key] = (buffer: baseBuffer, pts: pts, ticket: ticket, seq: seq, side: FrameSideData(hdr10Data: hdr10Data, dmNAL: dmNAL))
                let currentSkew = max(blFrameQueue.count, elFrameQueue.count)
                if currentSkew > summaryMaxObservedSkew {
                    summaryMaxObservedSkew = currentSkew
                }
                primary = .queued
                var due = collectDueBypasses()
                if let displaced { due.insert(displaced, at: 0) }
                return (primary, due)
            }
            return (primary, collectDueBypasses())
        }()

        // Older tickets first; `orderedDelivery` reorders by ticket anyway.
        for req in due {
            fulfilBypass(req)
        }
        switch outcome {
        case .queued:
            break
        case .bypass(let req):
            fulfilBypass(req)
        case .compose(let req):
            runCompose(req)
        }
        maybeEmitSummary()
    }

    /// Internal rather than private so `DualLayerVideoDecoderTests` can drive it directly.
    func handleEnhancementLayerFrame(elBuffer: CVPixelBuffer, pts: CMTime) {
        let outcome: PairingOutcome = {
            lock.lock()
            defer { lock.unlock() }

            // Defense in depth: see `handleBaseLayerFrame`.
            guard !isClosed else { return .queued }
            // Pre-seek frame drained by `flush()`: drop before it can
            // pair or occupy a queue slot meant for post-seek frames.
            guard !draining else { return .queued }
            guard composer != nil else { return .queued }
            let key = Self.canonicalKey(pts: pts)
            // No timestamp, no partner: it cannot pair with anything.
            guard key != Int64.min else { return .queued }
            // This enhancement layer's base layer already went out
            // (composed or bypassed), so it can never pair; drop it.
            if settledBlKeys.contains(where: { FrameSideDataRing.isWithinJitter($0, key) }) {
                EngineLog.emit("[DualLayerVideoDecoder] dropped stale enhancement layer: key=\(key), already settled", category: .swPlayback, level: .verbose)
                summaryDropStaleEL += 1
                return .queued
            }
            var matchingBlKey: Int64?
            if blFrameQueue[key] != nil {
                matchingBlKey = key
            } else {
                matchingBlKey = blFrameQueue.keys.first(where: { FrameSideDataRing.isWithinJitter($0, key) })
            }

            if let mKey = matchingBlKey, let waiting = blFrameQueue.removeValue(forKey: mKey) {
                // Base Layer frame was waiting: compose on the Metal GPU outside the lock,
                // under the ticket its arrival took.
                let epoch = _feedEpoch
                let dmNAL = waiting.side.dmNAL
                guard let params = takeParams(key: mKey) else {
                    // Missing RPU metadata: do NOT synthesize identity NLQ. Emit base layer directly.
                    EngineLog.emit("[DualLayerVideoDecoder] bypass, missing RPU: key=\(mKey)", category: .swPlayback, level: .verbose)
                    summaryBypassNoRPU += 1
                    noteSettledBaseLayer(key: mKey)
                    return .bypass(BypassRequest(ticket: waiting.ticket, epoch: epoch, buffer: waiting.buffer, pts: waiting.pts, hdr10Data: waiting.side.hdr10Data, dmNAL: waiting.side.dmNAL, reason: "missing-rpu"))
                }
                frameIndex &+= 1
                noteSettledBaseLayer(key: mKey)
                return .compose(ComposeRequest(ticket: waiting.ticket, epoch: epoch, base: waiting.buffer, enhancement: elBuffer, params: params, frameIndex: frameIndex, pts: waiting.pts, hdr10Data: waiting.side.hdr10Data, dmNAL: dmNAL, arrived: "enhancement layer arrived last"))
            } else {
                // Base Layer frame has not arrived yet: queue EL frame under its own larger cap
                EngineLog.emit("[DualLayerVideoDecoder] queued enhancement layer: pts=\(String(format: "%.3f", pts.seconds)) key=\(key), blCount=\(blFrameQueue.count)", category: .swPlayback, level: .verbose)
                elFrameQueue[key] = elBuffer
                let currentSkew = max(blFrameQueue.count, elFrameQueue.count)
                if currentSkew > summaryMaxObservedSkew {
                    summaryMaxObservedSkew = currentSkew
                }
                if elFrameQueue.count > Self.maxEnhancementLayerQueueFrames {
                    let sortedKeys = elFrameQueue.keys.sorted()
                    for k in sortedKeys.prefix(elFrameQueue.count - Self.maxEnhancementLayerQueueFrames) {
                        EngineLog.emit("[DualLayerVideoDecoder] pruned enhancement layer: key=\(k)", category: .swPlayback, level: .verbose)
                        elFrameQueue.removeValue(forKey: k)
                        summaryPrunedEL += 1
                    }
                }
                return .queued
            }
        }()

        switch outcome {
        case .queued:
            break
        case .bypass(let req):
            fulfilBypass(req)
        case .compose(let req):
            runCompose(req)
        }
        maybeEmitSummary()
    }

    /// Resolves what one packet's RPU means for its frame and records it for pairing. Runs in decode order,
    /// from `decode(packet:)`, so "the previous mapping" is the previous frame in the stream and not whichever
    /// frame happened to finish composing last. The caller holds `lock`.
    ///
    /// - A real RPU is the frame's parameters, and the new "previous mapping".
    /// - `use_prev_vdr_rpu_flag` keeps the previous mapping by definition, for as long as the stream keeps
    ///   asking.
    /// - A missing or corrupt RPU may borrow the previous mapping for up to `maxBorrowedParamsRun` frames in
    ///   a row; reshaping and NLQ parameters are constant across a scene. Past that the frame carries none
    ///   and goes out as its base layer.
    private func recordSideData(key: Int64, params: DoviMetalParams?, dmNAL: [UInt8]?, usesPrevious: Bool, disableResidual: Bool = false) {
        var resolvedParams = params
        var resolvedNAL = dmNAL
        if let params {
            lastGoodParams = params
            lastGoodDMNAL = dmNAL
            borrowedParamsRun = 0
        } else if let last = lastGoodParams {
            if usesPrevious {
                // Only `prev_vdr_rpu_id` 0 is followed (the previous RPU in decode order), as on every
                // surveyed stream. The curves and NLQ come from that RPU; the residual switch is this
                // frame's own header flag, not the previous frame's.
                var borrowed = last
                if disableResidual { borrowed.flags.insert(.disableResidual) } else { borrowed.flags.remove(.disableResidual) }
                resolvedParams = borrowed
                resolvedNAL = dmNAL ?? lastGoodDMNAL
            } else if borrowedParamsRun < Self.maxBorrowedParamsRun {
                borrowedParamsRun += 1
                summaryBorrowedParams += 1
                resolvedParams = last
                resolvedNAL = dmNAL ?? lastGoodDMNAL
                EngineLog.emit("[DualLayerVideoDecoder] RPU missing for key=\(key); reusing the previous frame's parameters (\(borrowedParamsRun)/\(Self.maxBorrowedParamsRun))", category: .swPlayback, level: .verbose)
            }
        }
        guard resolvedParams != nil || resolvedNAL != nil else { return }
        sideDataRing.insert(key: key, params: resolvedParams, dmNAL: resolvedNAL)
    }

    /// The parameters `recordSideData` resolved for `key`, nil when the frame has none. The caller holds `lock`.
    private func takeParams(key: Int64) -> DoviMetalParams? {
        sideDataRing.removeParams(key: key)
    }

    /// Records a settled base-layer key and drops queued enhancement frames that
    /// can never pair with a future base layer (dolby-vision-fel.md §5.5). The caller
    /// holds `lock`.
    private func noteSettledBaseLayer(key: Int64) {
        // Keyed match, not "older than the newest": both layers come out of VideoToolbox in
        // decode order, so an older-PTS base frame legitimately settles after a newer one.
        settledBlKeys.append(key)
        if settledBlKeys.count > Self.settledKeyMemory { settledBlKeys.removeFirst(settledBlKeys.count - Self.settledKeyMemory) }
        for k in elFrameQueue.keys where FrameSideDataRing.isWithinJitter(k, key) {
            EngineLog.emit("[DualLayerVideoDecoder] dropped stale enhancement layer: key=\(k), base \(key) settled", category: .swPlayback, level: .verbose)
            elFrameQueue.removeValue(forKey: k)
            summaryDropStaleEL += 1
        }
    }

    /// Bypasses every queued base-layer frame that has seen K newer base-layer
    /// arrivals, oldest first, each under the ticket its arrival took.
    /// The caller holds `lock`.
    private func collectDueBypasses() -> [BypassRequest] {
        var due: [BypassRequest] = []
        for k in blFrameQueue.keys.sorted() {
            guard let entry = blFrameQueue[k],
                  blArrivalSeq &- entry.seq >= UInt64(Self.maxLayerSkewFrames) else { continue }
            blFrameQueue.removeValue(forKey: k)
            summaryBypassNoEL += 1
            EngineLog.emit("[DualLayerVideoDecoder] bypass, no enhancement layer arrived: pts=\(String(format: "%.3f", entry.pts.seconds)) key=\(k)", category: .swPlayback, level: .verbose)
            noteSettledBaseLayer(key: k)
            due.append(BypassRequest(ticket: entry.ticket, epoch: _feedEpoch, buffer: entry.buffer, pts: entry.pts, hdr10Data: entry.side.hdr10Data, dmNAL: entry.side.dmNAL, reason: "no-el"))
        }
        // Every arrival takes a new `seq`, so what survives the loop arrived within the last
        // `maxLayerSkewFrames` base frames: the queue is bounded by the skew rule alone.
        assert(blFrameQueue.count <= Self.maxLayerSkewFrames)
        return due
    }

    #if DEBUG
    var summaryTimestampProviderForTesting: (() -> TimeInterval)?
    /// Sees every summary line with the level it went out at. `.verbose` lines never reach
    /// `EngineLog.handler`, so a test cannot observe them there.
    var summarySinkForTesting: ((String, EngineLog.Level) -> Void)?
    #endif

    // MARK: - Observability (dolby-vision-fel.md §5.11)

    /// Seconds between `[DualLayerVideoDecoder] summary` lines (dolby-vision-fel.md §5.11).
    static let summaryIntervalSeconds: TimeInterval = 1.0

    func maybeEmitSummary() {
        #if DEBUG
        let now = summaryTimestampProviderForTesting?() ?? ProcessInfo.processInfo.systemUptime
        #else
        let now = ProcessInfo.processInfo.systemUptime
        #endif
        lock.lock()
        guard isFEL, !isMEL else {
            lock.unlock()
            return
        }
        if lastSummaryTimestamp == 0 {
            lastSummaryTimestamp = now
            lock.unlock()
            return
        }
        guard now - lastSummaryTimestamp >= Self.summaryIntervalSeconds else {
            lock.unlock()
            return
        }
        composeResultLock.lock()
        let composed = summaryComposedFrames
        let composeFailures = summaryComposeFailures
        summaryComposedFrames = 0
        summaryComposeFailures = 0
        composeResultLock.unlock()
        let noEL = summaryBypassNoEL
        let noRPU = summaryBypassNoRPU
        let staleEL = summaryDropStaleEL
        let prunedEL = summaryPrunedEL
        let borrowedParams = summaryBorrowedParams
        let skew = summaryMaxObservedSkew
        summaryBypassNoEL = 0
        summaryBypassNoRPU = 0
        summaryDropStaleEL = 0
        summaryPrunedEL = 0
        summaryBorrowedParams = 0
        summaryMaxObservedSkew = max(blFrameQueue.count, elFrameQueue.count)
        lastSummaryTimestamp = now
        let activeComposer = composer
        lock.unlock()

        let slots = activeComposer?.takePeakSlotsInUse() ?? 0
        let poolBuffers = activeComposer?.allocatedPoolBuffers ?? 0
        let gpuMs = activeComposer?.meanGPUTimeMs
        let pendingPeak = orderedDelivery.takePeakPendingCount()
        let gpuStr = gpuMs.map { String(format: "%.1f", $0) } ?? "n/a"
        let line = "[DualLayerVideoDecoder] summary: composed=\(composed), composeFailures=\(composeFailures), bypassNoEL=\(noEL), bypassNoRPU=\(noRPU), staleELDropped=\(staleEL), prunedEL=\(prunedEL), borrowedParams=\(borrowedParams), maxSkew=\(skew), peakGpuSlots=\(slots), poolBuffers=\(poolBuffers), deliveryPendingPeak=\(pendingPeak), meanGpuMs=\(gpuStr)"
        // Once a second is a trace, not an event: it goes to OSLog's debug level only. An interval in
        // which a composition failed is the exception, so the failure reaches the default level and the
        // host handler.
        let level: EngineLog.Level = composeFailures > 0 ? .info : .verbose
        EngineLog.emit(line, category: .swPlayback, level: level)
        #if DEBUG
        summarySinkForTesting?(line, level)
        #endif
        activeComposer?.flushTextureCache()
    }

    // MARK: - Flush & Teardown

    func flush() {
        #if DEBUG
        flushWillTakeLifecycleLockHookForTesting?()
        #endif
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        // `orderedDelivery`'s epoch is retired from THIS critical section, the same one that bumps
        // `_feedEpoch` and raises `draining`, with `resetAsync` (a plain `queue.async`, safe under
        // `lock`) and a `barrier()` once `lock` is released. Retiring it later, after the hardware
        // drain, left a gap: a VideoToolbox callback landing between the unlock and the reset (with
        // `draining` already false) took a new-epoch ticket that `orderedDelivery` still dropped as
        // stale, and the reset then skipped past it, stalling every following frame until the stall
        // guard gave up on it. Two things follow from the order used here:
        //
        // 1. **No ticket can be lost.** `draining` stays raised for the whole window in which
        //    `orderedDelivery` might still be on the old epoch: it is lowered only in the second
        //    critical section below, after `barrier()` has confirmed the `resetAsync` ran. No
        //    thread can issue a new-epoch ticket until `orderedDelivery` is on that epoch.
        // 2. **Nothing from before the flush is delivered during the drain.** A composition that
        //    was in flight before this `flush()` and retires while `primary.flush()` / `el.flush()`
        //    are still draining finds the epoch already moved and is dropped, so the draining gate
        //    covers delivery as well as pairing.
        //
        // Concurrent `flush()`/`flush()` or `flush()`/`close()`: the whole of each call runs under
        // `lifecycleLock`, so they never interleave (one cannot lower `draining` or clear the
        // queues while the other still drains). Inside a call, `_feedEpoch`/`deliveryNextTicket`
        // only ever move forward under `lock`, so `orderedDelivery`'s FIFO queue applies the
        // resets in call order and neither can ever move backwards.
        //
        // `nextTicket` is stable across this whole call: no new ticket can
        // be issued between this section and the one below, because
        // `handleBaseLayerFrame`/`handleEnhancementLayerFrame` both gate on
        // `!draining` under `lock`, and `draining` does not go false until
        // after the drain completes.
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        _feedEpoch &+= 1
        draining = true
        // Here, not with the queues below: the demux thread may feed post-seek packets while this
        // thread waits on the drain, and those must start from the next IRAP.
        pictureAlignment.reset()
        // Same reason, and the same section: RPUs the demux thread records for post-seek packets
        // during the drain must survive it, so the side data resets here, before any of them can
        // exist, and not after the drain.
        lastGoodParams = nil
        lastGoodDMNAL = nil
        borrowedParamsRun = 0
        sideDataRing.removeAll()
        let epoch = _feedEpoch
        let nextTicket = deliveryNextTicket
        let primary = primaryDecoder
        let el = enhancementDecoder
        // The sub-decoders move to the new epoch in this same critical section. The host feeds the
        // demux thread's packets concurrently with a seek's flush: it reads the new epoch the moment
        // it is published, and hands it down with the packet. Were the sub-decoders to move only when
        // their own `flush()` runs below, a post-seek packet fed in that window would pass the gate
        // here and be refused by a sub-decoder still on the old epoch, losing the post-seek IRAP
        // (garbage until the next keyframe). `adoptFeedEpoch` takes only the sub-decoder's leaf
        // `epochLock`, never its `lock`, so it cannot nest against the VideoToolbox callbacks that
        // wait on this lock. DEC-4 still holds: a pre-seek packet is refused from here on, and a
        // sub-decoder's `flush()` below serialises against any packet already inside its
        // check-and-send.
        primary.adoptFeedEpoch(epoch)
        el?.adoptFeedEpoch(epoch)
        orderedDelivery.resetAsync(epoch: epoch, nextTicket: nextTicket)
        lock.unlock()

        #if DEBUG
        // Test seam only: lets a test drive a ticket through the window a
        // post-flush ticket could be lost in if the reset moved back out of
        // the critical section above — right after this
        // section's `unlock()`, before the `barrier()` below has confirmed
        // the `resetAsync` above has run — without a real GPU or
        // VideoToolbox callback. See `raceTicketForTesting`.
        flushRaceHookForTesting?()
        #endif

        // Waits for the `resetAsync` enqueued above to actually run (and for
        // anything already ahead of it in `orderedDelivery`'s queue to
        // finish first), with no decoder lock held — this cannot nest
        // inside, or be nested by, any lock a concurrent `fulfil`/`emit`
        // might touch (I8).
        orderedDelivery.barrier()

        // Drain both hardware decoders now that `orderedDelivery` is
        // provably on the new epoch: `HardwareVideoDecoder.flush()` waits
        // for the frames VideoToolbox still owes, which arrive through the
        // normal callbacks while this thread is blocked inside it, but
        // `draining` (still up) drops them at the pairing gate before they
        // can take a ticket, and any composition that was already
        // in flight before this `flush()` is dropped by the epoch check the
        // instant it reaches `fulfil` instead.
        //
        // Post-seek frames that VideoToolbox outputs while this drain is still running (a post-seek
        // packet is now accepted from the moment the epoch moved) meet `draining` and are dropped.
        // That is deliberate and costs nothing visible: the drain cannot tell them from the pre-seek
        // frames it is waiting for, they are decoded from the IRAP onwards, which the host's
        // `skipUntilPTS` pre-roll discards anyway until the seek target; and a dropped output frame
        // does not affect decoding, VideoToolbox's reference state is intact. What it can cost is
        // pairing: a frame dropped on one layer and not on the other leaves its partner waiting, and
        // a waiting base frame goes out base-layer only once `maxLayerSkewFrames` newer ones have
        // arrived. So the first few frames after a seek can be base-layer only (how many depends on
        // how many frames the two sessions output during the drain), and the base frames dropped
        // during the drain are never shown.
        primary.flushKeepingEpoch()
        el?.flushKeepingEpoch()

        // Now that nothing more can arrive, reset pairing and let new tickets flow again. (The
        // side-data ring is not touched here: see the first critical section.)
        lock.lock()
        draining = false
        blFrameQueue.removeAll()
        elFrameQueue.removeAll()
        blArrivalSeq = 0
        settledBlKeys.removeAll()
        composeResultLock.lock(); summaryComposedFrames = 0; summaryComposeFailures = 0; composeResultLock.unlock()
        summaryBypassNoEL = 0
        summaryBypassNoRPU = 0
        summaryDropStaleEL = 0
        summaryPrunedEL = 0
        summaryBorrowedParams = 0
        summaryMaxObservedSkew = 0
        lastSummaryTimestamp = 0
        lock.unlock()

        composer?.flush()
    }

    /// How long `drainForEndOfStream()` waits for compositions still on the GPU.
    static let endOfStreamComposeWait: TimeInterval = 0.5

    /// End of stream: delivers the frames still owed, which `flush()` drops. `flush()` cannot tell the
    /// frames it drains from pre-seek ones, so it drops everything the sessions, the GPU and the pairing
    /// queues still hold, and at the end of the stream that is the last frames of the title. The host
    /// calls this once the last packet has been fed, before its end-of-stream `flush()`.
    ///
    /// The drained frames pair as usual; a base-layer frame whose enhancement layer never came goes out
    /// alone, under its own ticket. Returns once everything has reached `onFrame`, or after
    /// `endOfStreamComposeWait` if a composition is still on the GPU.
    func drainForEndOfStream() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        let primary = primaryDecoder
        let el = enhancementDecoder
        lock.unlock()

        // Without `draining`, and without moving the epoch: what the sessions still owe arrives through
        // the normal callbacks while these wait, and pairs with what the other layer already sent.
        primary.flushKeepingEpoch()
        el?.flushKeepingEpoch()

        let unpaired: [BypassRequest] = {
            lock.lock()
            defer { lock.unlock() }
            var due: [BypassRequest] = []
            for k in blFrameQueue.keys.sorted() {
                guard let entry = blFrameQueue.removeValue(forKey: k) else { continue }
                summaryBypassNoEL += 1
                noteSettledBaseLayer(key: k)
                due.append(BypassRequest(ticket: entry.ticket, epoch: _feedEpoch, buffer: entry.buffer, pts: entry.pts, hdr10Data: entry.side.hdr10Data, dmNAL: entry.side.dmNAL, reason: "end-of-stream"))
            }
            return due
        }()
        for req in unpaired {
            fulfilBypass(req)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + Self.endOfStreamComposeWait
        while ProcessInfo.processInfo.systemUptime < deadline {
            composeResultLock.lock()
            let idle = composeRequestsStarted == composeRequestsHandedOff
            composeResultLock.unlock()
            if idle { break }
            usleep(500)
        }
        orderedDelivery.barrier()
    }

    /// AE#739: rebuilds both layers' sessions after the system invalidated them, the way
    /// `HardwareVideoDecoder.rebuildSession()` does for one. Each sub-decoder's rebuild moves its own
    /// feed epoch to retire what was fed to the old session; both are put back on this decoder's epoch,
    /// which is the one the host's packets carry, or every later packet would be refused. Each layer
    /// then resumes at its next keyframe. False when VideoToolbox refused either session.
    @discardableResult
    func rebuildSession() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        lock.lock()
        guard !isClosed else { lock.unlock(); return false }
        let primary = primaryDecoder
        let enhancement = enhancementDecoder
        let primaryOpen = primaryDecoderInitialized
        let epoch = _feedEpoch
        lock.unlock()
        // A primary still waiting for its in-band parameter sets has no session to lose yet.
        let primaryRebuilt = !primaryOpen || ((primary as? HardwareVideoDecoder)?.rebuildSession() ?? true)
        let enhancementRebuilt = (enhancement as? HardwareVideoDecoder)?.rebuildSession() ?? true
        // `flush()` and `close()` wait on `lifecycleLock`, so `epoch` is still this decoder's.
        primary.adoptFeedEpoch(epoch)
        enhancement?.adoptFeedEpoch(epoch)
        // Both sessions are new (or refused, and the host owes another rebuild): the next loss is news.
        lock.lock()
        sessionLossReported = false
        lock.unlock()
        return primaryRebuilt && enhancementRebuilt
    }

    func close() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        // dolby-vision-fel.md §5.8: `close()` resets every field of stream state, so a
        // reopened instance could not inherit the MEL latch, a stale
        // `primaryDecoderInitialized`, BL parameter sets, `frameIndex` or
        // `timeBase` — and then makes reopening impossible anyway: the decoder
        // is single use and `open` after this refuses with `decoderClosed`.
        // Epoch limitation: the bump below only retires `decode(packet:epoch:)`
        // callers that pass an epoch. The DVR-reseed path calls `decode` with
        // `epoch: nil`, which never matches and is never retired by the epoch —
        // those packets (and any thread already past the entry gate) are stopped
        // by the `isClosed` checks in `decode`, `ensure*Decoder` and the frame
        // handlers, not by the epoch. Delivery itself IS stopped by the epoch,
        // via `orderedDelivery` below.
        //
        // As in `flush()`, `orderedDelivery.resetAsync` is enqueued from
        // inside THIS critical section — the same one that bumps `_feedEpoch`,
        // zeroes `deliveryNextTicket` and sets `isClosed`. Nothing can issue a ticket after
        // this section unlocks (`isClosed` gates every entry point), so
        // there is no gap for one to race `resetAsync` in, but keeping the
        // same enqueue-under-lock shape as `flush()` means a `flush()`/
        // `close()` race is decided the same way in both directions: `lock`
        // fixes the order the two calls' `resetAsync`s land in
        // `orderedDelivery`'s queue, and `_feedEpoch` only ever increases
        // under that same lock, so whichever lands later always carries the
        // larger epoch.
        lock.lock()
        _feedEpoch &+= 1
        draining = false
        deliveryNextTicket = 0
        pictureAlignment = Self.makeAlignment()
        blFrameQueue.removeAll()
        elFrameQueue.removeAll()
        blArrivalSeq = 0
        settledBlKeys.removeAll()
        lastGoodParams = nil
        lastGoodDMNAL = nil
        borrowedParamsRun = 0
        sideDataRing.removeAll()
        composeResultLock.lock(); summaryComposedFrames = 0; summaryComposeFailures = 0; composeResultLock.unlock()
        summaryBypassNoEL = 0
        summaryBypassNoRPU = 0
        summaryDropStaleEL = 0
        summaryPrunedEL = 0
        summaryBorrowedParams = 0
        summaryMaxObservedSkew = 0
        lastSummaryTimestamp = 0
        isFEL = false
        isMEL = false
        streamClassified = false
        frameIndex = 0
        primaryDecoderInitialized = false
        blVPS = nil
        blSPS = nil
        blPPS = nil
        elVPS = nil
        elSPS = nil
        elPPS = nil
        enhancementOpenFailure = nil
        timeBase = AVRational(num: 1, den: 90000)
        _skipUntilPTS = nil
        isClosed = true
        let epoch = _feedEpoch
        let nextTicket = deliveryNextTicket
        // Swap the enhancement decoder out under the lock and close it after releasing
        // it: `close()` runs on the host thread while VideoToolbox callbacks may still
        // be delivering into `handleEnhancementLayerFrame`.
        let el = enhancementDecoder
        enhancementDecoder = nil
        orderedDelivery.resetAsync(epoch: epoch, nextTicket: nextTicket)
        lock.unlock()

        // Same guarantee as `flush()`: nothing tagged with the
        // pre-close epoch reaches `onFrame` after this returns. Clearing the
        // callback only after that is what makes "nothing is delivered after
        // `close()` returns" hold even for the frame that was legitimately
        // mid-delivery when this call started.
        orderedDelivery.barrier()
        orderedDelivery.setOnFrame(nil)

        // Sessions first: closing them drains the frames VideoToolbox still owes, and those can still be
        // holding or about to take pool buffers. Only then flush the composer and release its pool.
        primaryDecoder.close()
        el?.close()
        composer?.flush()
        composer?.releaseOutputPool()
    }

    // MARK: - Test seams
    //
    // Both frame handlers are driven by VideoToolbox callbacks, which a unit test cannot produce
    // on demand. These put the decoder in the state `decode(packet:)` reaches on a real stream,
    // so `DualLayerVideoDecoderTests` can exercise pairing, ordering, metadata and flush with
    // synthetic buffers.

    #if DEBUG
    /// Regression seam for the post-flush ticket race: if set, `flush()`
    /// calls this exactly once, synchronously, in the gap right after the
    /// critical section that bumps `_feedEpoch`, captures `nextTicket` and
    /// enqueues `orderedDelivery.resetAsync` releases `lock`, but before the
    /// `orderedDelivery.barrier()` call that waits for it to actually run.
    /// This is the window a post-flush ticket could be lost in — see the
    /// comment at the top of `flush()`. Paired with `raceTicketForTesting`, this drives a ticket
    /// through that window deterministically, without a real GPU or
    /// VideoToolbox callback, so a regression that reopens the window (e.g.
    /// moving the `resetAsync` call back outside the lock) fails a test
    /// instead of waiting on a sub-microsecond production race.
    var flushRaceHookForTesting: (() -> Void)?

    /// Called at the top of every `flush()`, before it queues for `lifecycleLock`. Lets a test know a
    /// second flush has reached the lock without sleeping to find out.
    var flushWillTakeLifecycleLockHookForTesting: (() -> Void)?

    /// Waits until every composition started so far has finished and handed its frame to
    /// `orderedDelivery`, then until that queue has run everything enqueued ahead of this call. After
    /// it returns, a frame that was going to be delivered (or dropped as stale) by work already in
    /// flight has been, which is what a "nothing more arrives" assertion needs; it is a condition
    /// wait, not a delay. Compositions that never finish (a gated fake) would make it wait forever, so a
    /// test that holds one releases it first.
    func quiesceForTesting() {
        while true {
            composeResultLock.lock()
            let idle = composeRequestsStarted == composeRequestsHandedOff
            composeResultLock.unlock()
            if idle { break }
            usleep(500)
        }
        orderedDelivery.barrier()
    }

    /// Invalidates both layers' sessions without forgetting them, as the system does on an iOS screen
    /// lock (`HardwareVideoDecoder.invalidateSessionForTesting()`). For the aetherctl harness.
    func invalidateSessionsForTesting() {
        lock.lock()
        let primary = primaryDecoder
        let enhancement = enhancementDecoder
        lock.unlock()
        (primary as? HardwareVideoDecoder)?.invalidateSessionForTesting()
        (enhancement as? HardwareVideoDecoder)?.invalidateSessionForTesting()
    }

    /// Issues a ticket the same way `handleBaseLayerFrame` would — under
    /// `lock`, in decode order, tagged with the current epoch — and hands it
    /// straight to `orderedDelivery`, bypassing the `draining` gate that
    /// would otherwise stop a real VideoToolbox callback from reaching here
    /// at this point. Standing in for "a VideoToolbox callback landing in
    /// the gap": the gate no
    /// longer needs to stop it, now that the epoch is retired before
    /// `draining` can go false, but this seam drives the ordering itself,
    /// not the gate, so that guarantee is what is actually under test.
    func raceTicketForTesting(buffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        let ticket = nextDeliveryTicket()
        let epoch = _feedEpoch
        lock.unlock()
        orderedDelivery.fulfil(
            ticket: ticket, epoch: epoch,
            DeliveredFrame(buffer: SendableBuffer(value: buffer), pts: pts, hdr10Data: nil, dmNAL: nil))
    }
    #endif

    /// Marks the stream as FEL with the enhancement-layer decoder engaged, or as single layer.
    /// The engaged decoder is never opened: pairing only checks that one exists.
    func primeForTesting(enhancementLayer: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isFEL = enhancementLayer
        isMEL = false
        streamClassified = true
        if enhancementLayer {
            // Only engage the EL decoder when a composer exists. Without
            // one, the production path (`decode(packet:)`) never reaches
            // `ensureEnhancementDecoder`, so neither does the test seam.
            if enhancementDecoder == nil, composer != nil {
                let decoder = HardwareVideoDecoder()
                decoder.useCustomBlockSource = true
                enhancementDecoder = decoder
            }
        } else {
            enhancementDecoder = nil
        }
    }

    /// Puts the decoder in the classified state `decode(packet:)` reaches for `kind`
    ///: FEL engages the enhancement-layer stub, MEL never does. Fresh-decoder
    /// assumption, like `primeForTesting`: the stub is never opened, pairing only checks
    /// that one exists.
    func primeStreamForTesting(_ kind: DoviRpuConverter.StreamKind) {
        lock.lock()
        defer { lock.unlock() }
        streamClassified = true
        switch kind {
        case .fel:
            isFEL = true
            isMEL = false
            // Only engage the EL decoder when a composer exists.
            if enhancementDecoder == nil, composer != nil {
                let decoder = HardwareVideoDecoder()
                decoder.useCustomBlockSource = true
                enhancementDecoder = decoder
            }
        case .mel:
            isFEL = false
            isMEL = true
            enhancementDecoder = nil
        case .undetermined:
            isFEL = false
            isMEL = false
            enhancementDecoder = nil
        }
    }

    /// Applies one `separateDualLayers` result's classification exactly as
    /// `decode(packet:)` does, so tests can drive classification sequences without real packets.
    func classifyPacketResultForTesting(_ result: DoviRpuConverter.DualLayerPacketResult) {
        applyStreamClassification(DoviRpuConverter.classifyStream(result))
    }

    /// The feed epoch of the lazily opened enhancement decoder, nil until it exists.
    var enhancementFeedEpochForTesting: UInt64? {
        lock.lock()
        let el = enhancementDecoder
        lock.unlock()
        return (el as? HardwareVideoDecoder)?.feedEpoch
    }

    /// The stream classification `decode(packet:)` has latched so far.
    var streamClassification: DoviRpuConverter.StreamKind {
        lock.lock()
        defer { lock.unlock() }
        if isMEL { return .mel }
        if isFEL { return .fel }
        return .undetermined
    }

    var streamClassificationForTesting: DoviRpuConverter.StreamKind { streamClassification }

    /// The decode-path gate for opening and feeding the enhancement decoder: only a classified FEL stream with a composer engages it; MEL or
    /// no composer never does.
    func engagesEnhancementLayerForTesting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFEL && !isMEL && composer != nil
    }

    /// Stream state `close()` must reset: classification latch,
    /// primary-decoder readiness, composition counter and EL engagement, plus
    /// the single-use flag that makes `open` refuse after `close()`. Queue,
    /// cache, ticket and epoch counts are included so tests can assert the reset
    /// explicitly rather than relying on delivery silence alone.
    struct DecoderStateSnapshot: Sendable {
        var isClosed: Bool
        var isFEL: Bool
        var isMEL: Bool
        var streamClassified: Bool
        var primaryDecoderInitialized: Bool
        var frameIndex: UInt32
        var enhancementEngaged: Bool
        var blQueueCount: Int
        var elQueueCount: Int
        var rpuCacheCount: Int
        var dmRpuCacheCount: Int
        var deliveryPendingCount: Int
        var deliveryNextTicket: UInt64
        var deliveryNextToEmit: UInt64
        var feedEpoch: UInt64
        var draining: Bool
        var timeBaseNum: Int32
        var timeBaseDen: Int32
        var hasBLVPS: Bool
        var hasBLSPS: Bool
        var hasBLPPS: Bool
        var hasELVPS: Bool
        var hasELSPS: Bool
        var hasELPPS: Bool
        var hasSkipUntilPTS: Bool
        var hasOnFrame: Bool
        var hasComposer: Bool
    }

    var stateSnapshotForTesting: DecoderStateSnapshot {
        // Decoder-lock fields first, then release before touching
        // `orderedDelivery`: its `queue.sync` reads never need the
        // decoder lock, and not holding both at once keeps this snapshot from
        // becoming the one place that reintroduces a lock/queue dependency.
        lock.lock()
        let isClosed = self.isClosed
        let isFEL = self.isFEL
        let isMEL = self.isMEL
        let streamClassified = self.streamClassified
        let primaryDecoderInitialized = self.primaryDecoderInitialized
        let frameIndex = self.frameIndex
        let enhancementEngaged = isFEL && !isMEL && enhancementDecoder != nil && composer != nil
        let blQueueCount = blFrameQueue.count
        let elQueueCount = elFrameQueue.count
        let rpuCacheCount = sideDataRing.paramsCount
        let dmRpuCacheCount = sideDataRing.dmNALCount
        let deliveryNextTicket = self.deliveryNextTicket
        let feedEpoch = _feedEpoch
        let draining = self.draining
        let timeBaseNum = timeBase.num
        let timeBaseDen = timeBase.den
        let hasBLVPS = blVPS != nil
        let hasBLSPS = blSPS != nil
        let hasBLPPS = blPPS != nil
        let hasELVPS = elVPS != nil
        let hasELSPS = elSPS != nil
        let hasELPPS = elPPS != nil
        let hasSkipUntilPTS = _skipUntilPTS != nil
        let hasComposer = composer != nil
        lock.unlock()

        return DecoderStateSnapshot(
            isClosed: isClosed,
            isFEL: isFEL,
            isMEL: isMEL,
            streamClassified: streamClassified,
            primaryDecoderInitialized: primaryDecoderInitialized,
            frameIndex: frameIndex,
            enhancementEngaged: enhancementEngaged,
            blQueueCount: blQueueCount,
            elQueueCount: elQueueCount,
            rpuCacheCount: rpuCacheCount,
            dmRpuCacheCount: dmRpuCacheCount,
            deliveryPendingCount: orderedDelivery.pendingCountForTesting,
            deliveryNextTicket: deliveryNextTicket,
            deliveryNextToEmit: orderedDelivery.nextToEmitForTesting,
            feedEpoch: feedEpoch,
            draining: draining,
            timeBaseNum: timeBaseNum,
            timeBaseDen: timeBaseDen,
            hasBLVPS: hasBLVPS,
            hasBLSPS: hasBLSPS,
            hasBLPPS: hasBLPPS,
            hasELVPS: hasELVPS,
            hasELSPS: hasELSPS,
            hasELPPS: hasELPPS,
            hasSkipUntilPTS: hasSkipUntilPTS,
            hasOnFrame: orderedDelivery.hasOnFrameForTesting,
            hasComposer: hasComposer
        )
    }

    /// Caches what `decode(packet:)` would have cached for the packet at `pts`: the composer's
    /// reshaping parameters and the Profile 8.1 RPU NAL attached as display metadata.
    /// One call is one packet, in decode order: a nil `params` is a packet with a missing RPU (or, with
    /// `usesPrevious`, one that says to keep the previous mapping), resolved exactly as in production.
    func seedRPUForTesting(pts: CMTime, params: DoviMetalParams?, displayMetadataNAL: [UInt8]?, usesPrevious: Bool = false, disableResidual: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.canonicalKey(pts: pts)
        recordSideData(key: key, params: params, dmNAL: displayMetadataNAL, usesPrevious: usesPrevious, disableResidual: disableResidual)
    }
}
#endif
