import Foundation
import AVFoundation
import CoreMedia
import Combine
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Software-decode playback host (FFmpeg/dav1d pipeline): AV1 on Apple TV (no HW AV1 on tvOS), VP9.
/// AVSampleBufferRenderSynchronizer is the master clock; display layer attached for A/V sync.
/// Atmos: E-AC-3 JOC goes to the renderer compressed; TrueHD Atmos and DTS:X render to APAC when
/// `ObjectAudioRendering` asks for it (see `SoftwareAtmosRoute`). Everything else decodes to PCM.
@MainActor
final class SoftwarePlaybackHost {
    /// Codecs whose presentation reordering has an established bound get the read-ahead's
    /// successor-PTS coverage; every other codec keeps strict packet-duration coverage. HEVC's bound
    /// is FFmpeg's own: `sps_max_num_reorder_pics > HEVC_MAX_DPB_SIZE - 1` (15) is rejected
    /// (n8.1.2 hevc/ps.c:1397-1403), inside the 32-timestamp queue. VC-1's max_b_frames is at most
    /// 7 (n8.1.2 vc1.c:346,426), also within that queue including a field-picture margin. Its
    /// 33 ms packet durations over 33/34 ms timestamps otherwise create the same tiny holes.
    /// On the duration model a Matroska
    /// file muxed with 41 ms durations against 41/42 ms deltas split at every 42 ms step (#613).
    nonisolated static func presentationReorderDepth(codecID: UInt32) -> Int? {
        switch codecID {
        case AV_CODEC_ID_H264.rawValue, AV_CODEC_ID_HEVC.rawValue, AV_CODEC_ID_VC1.rawValue: return 32
        default: return nil
        }
    }

    /// Only codec sample geometry is admitted, never the WMA bitrate fallback in
    /// av_get_audio_frame_duration2. Parameters are copied before the read-ahead thread starts.
    /// Variable/packed or reservoir-dependent packet layouts stay strict until proven separately.
    nonisolated static func audioPacketTiming(_ parameters: UnsafeMutablePointer<AVCodecParameters>)
        -> SoftwareAudioPacketTiming? {
        let p = parameters.pointee
        guard p.sample_rate > 0, p.sample_rate <= 768_000 else { return nil }
        let samples: Int32
        switch p.codec_id {
        case AV_CODEC_ID_AC3: samples = 1536
        case AV_CODEC_ID_MP1: samples = 384
        case AV_CODEC_ID_MP2: samples = 1152
        case AV_CODEC_ID_MP3: samples = p.sample_rate <= 24000 ? 576 : 1152
        case AV_CODEC_ID_AAC, AV_CODEC_ID_EAC3:
            // Includes known AAC 960/1024/SBR geometry. A packet with a different declared
            // duration fails the sample-clock admission instead of inheriting the initial size.
            guard p.frame_size > 1 else { return nil }
            samples = p.frame_size
        case AV_CODEC_ID_WMAV1, AV_CODEC_ID_WMAV2:
            let flagOffset = p.codec_id == AV_CODEC_ID_WMAV1 ? 2 : 4
            guard p.sample_rate <= 50_000, p.ch_layout.nb_channels > 0,
                  p.ch_layout.nb_channels <= 2, p.block_align > 0,
                  Int(p.extradata_size) >= flagOffset + 2, let data = p.extradata else { return nil }
            let flags = UInt16(data[flagOffset]) | (UInt16(data[flagOffset + 1]) << 8)
            // A reservoir superframe can depend on the previous packet and yield several
            // frames: byte length/bitrate is not proof of its sample count.
            guard flags & 2 == 0 else { return nil }
            if p.sample_rate <= 16_000 { samples = 512 }
            else if p.sample_rate <= 22_050 || (p.codec_id == AV_CODEC_ID_WMAV1 && p.sample_rate <= 32_000) {
                samples = 1024
            } else { samples = 2048 }
            return .init(sampleRate: p.sample_rate,
                         layout: .fixed(samples: samples, packetBytes: Int(p.block_align)))
        default:
            let bits = av_get_exact_bits_per_sample(p.codec_id)
            guard bits > 0, bits % 8 == 0, p.ch_layout.nb_channels > 0,
                  p.ch_layout.nb_channels <= 64 else { return nil }
            return .init(sampleRate: p.sample_rate,
                         layout: .pcm(bytesPerSampleFrame: Int(bits / 8) * Int(p.ch_layout.nb_channels)))
        }
        return .init(sampleRate: p.sample_rate, layout: .fixed(samples: samples, packetBytes: nil))
    }

    /// Bounds of the memory store wherever it runs, by platform default or `.memory` (#827).
    nonisolated static let memoryPacketStoreBounds = (forwardBytes: 96 << 20, historyBytes: 128 << 20)

    /// The software VOD packet store's bounds on tvOS, which keeps it in purgeable memory
    /// (`SoftwarePacketMemoryFIFO`) instead of session files; nil elsewhere, where the disk store and
    /// the session retention budget apply. On an Apple TV 4K (A12) the disk store's appends took
    /// 100 to 600 ms while a download ran and the demux thread stalled behind them, so video it had
    /// parked was decoded late and dropped: 22 to 42 drops in a 150 s soak of a 4K title, against
    /// 0 to 3 in 8 of 9 runs with the store in memory (one run had 26, not seen again). The forward
    /// window is 96 MB (about 8 s of a 95 Mbit/s title, on top of the forward-seconds limit); played
    /// history up to 128 MB stays volatile, so the kernel may take it back and a seek into what it
    /// took refetches. Peak footprint of a 4K
    /// FEL session on the A12: ~655 MB against ~580 MB with the disk store.
    nonisolated static let memoryPacketStoreBudget: (forwardBytes: Int, historyBytes: Int)? = {
        #if os(tvOS)
        return memoryPacketStoreBounds
        #else
        return nil
        #endif
    }()


    /// Zero still needs a working spool; every choice retains the volume and shared-claim clamp.
    nonisolated static func packetCacheBudgetBytes(requestedBytes: Int?, availableBytes: Int64?,
                                                   capRelaxed: Bool) -> Int {
        let budget = HLSVideoEngine.resolveSessionCacheBudget(
            requestedBytes: requestedBytes, volumeAvailableBytes: availableBytes, capRelaxed: capRelaxed)
        return min(budget.volumeSafetyLimitBytes,
                   budget.baseEffectiveBytes > 0 ? budget.baseEffectiveBytes : 32 << 20)
    }

    /// Run off-main: disk construction queries volume capacity and opens temporary files.
    nonisolated static func makePacketStore(
        storage: SoftwarePacketCacheStorage, forwardSegments: Int?,
        requestedBytes: Int? = nil, directory: URL = FileManager.default.temporaryDirectory,
        claims: RetentionClaims = .shared
    ) throws -> (any SoftwarePacketStore, Int, RetentionClaims.Claim?)? {
        let memoryBudget: (forwardBytes: Int, historyBytes: Int)?
        switch storage {
        case .automatic: memoryBudget = memoryPacketStoreBudget
        case .disk: memoryBudget = nil
        case .memory: memoryBudget = memoryPacketStoreBounds
        }
        let segments = HLSVideoEngine.clampedForwardWindow(forwardSegments)
        let fifo: any SoftwarePacketStore
        let bytes: Int
        var claim: RetentionClaims.Claim?
        if let memory = memoryBudget {
            bytes = memory.forwardBytes
            fifo = SoftwarePacketMemoryFIFO(historyCapBytes: memory.historyBytes)
            EngineLog.emit("[SWHost] packet cache in memory: forward \(memory.forwardBytes >> 20) MB, "
                   + "history \(memory.historyBytes >> 20) MB", category: .swPlayback)
        } else {
            let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let available = (try? temp.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
                .volumeAvailableCapacity.map(Int64.init)
            let capRelaxed = HLSVideoEngine.retentionCapRelaxed(forwardWindowSegments: segments)
            let diskClaim = claims.claim(volumeAvailableBytes: available) {
                packetCacheBudgetBytes(requestedBytes: requestedBytes, availableBytes: $0, capRelaxed: capRelaxed)
            }
            bytes = diskClaim.bytes
            guard bytes > 0 else { return nil }
            fifo = try SoftwarePacketDiskFIFO(
                chunkTargetBytes: min(4 << 20, max(8, bytes)), retainConsumed: true,
                parentDirectory: directory)
            claim = diskClaim
        }
        return (fifo, bytes, claim)
    }

    // MARK: - Published state (mirrors NativeAVPlayerHost surface)

    /// Frames enqueued on the display layer; read by LiveTelemetrySampler at 1 Hz for observed FPS. Lock-guarded (demux thread writes, main-actor reads).
    nonisolated var framesEnqueued: Int {
        framesEnqueuedLock.lock()
        defer { framesEnqueuedLock.unlock() }
        return _framesEnqueued
    }
    nonisolated private func bumpFramesEnqueued() -> Int {
        framesEnqueuedLock.lock()
        defer { framesEnqueuedLock.unlock() }
        let previous = _framesEnqueued
        _framesEnqueued &+= 1
        return previous
    }
    private let framesEnqueuedLock = NSLock()
    nonisolated(unsafe) private var _framesEnqueued: Int = 0

    /// #220: the pump demuxer's network sliding window, for the periodic memprobe. Paired with
    /// the subtitle side reader's own window, the two connections are separately attributable.
    var ioWindowDiagnostics: (windowBytes: Int, aheadBytes: Int, parked: Bool)? {
        demuxer?.ioWindowDiagnostics
    }

    /// #240: lifetime bytes this pump pulled from the source, so the memprobe can put it next to the
    /// subtitle side reader's own total and say which one took the link.
    var demuxerBytesFetched: Int64? {
        demuxer?.avioBytesFetched
    }

    /// AE#514: bytes of the played streams by presentation time on the source axis (the axis of
    /// `sourceClockSeconds`), fed by the read loops once the timeline fold has been applied.
    nonisolated let playedMediaLedger = PlayedMediaLedger()

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    /// Raw synchronizer clock in the SOURCE axis (same axis as demuxed packet PTS and
    /// subtitle cues). Equals `currentTime` for zero-based sources; diverges by the
    /// session-zero offset on live and mid-stream-joined sources (#107). The engine
    /// publishes this as `clock.sourceTime` so the subtitle overlay drainer scans the
    /// packet store on the right axis.
    @Published private(set) var sourceClockSeconds: Double = 0
    /// The pump has paused the synchronizer to refill: the live feeder at a dry ring (#107, a
    /// source that paused or delivers below real time) or the on-demand loop with its audio lead
    /// exhausted. The engine folds it into `isBuffering`, so `playbackPhase` reads `.rebuffering`
    /// from the moment the clock stops, as it does on the AVPlayer-backed hosts; before, the phase
    /// stayed `.playing` over a standing picture until the reader's own stall timeout promoted it
    /// to `.stalled`, and a host app watching the clock had nothing to tell a paused source from a
    /// dead session.
    @Published private(set) var isRebuffering: Bool = false
    /// A position on the session axis the live feeder wants the picture moved up to after an edge
    /// rebuffer resumed behind a backlog the source handed over at once (the join lead behind the
    /// newest media, decided by `SoftwareLiveJoinPolicy` as the join itself was). The engine seeks
    /// there as its own rejoin; the host does not move the cursor itself.
    let liveResumeCatchUp = PassthroughSubject<Double, Never>()
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    /// #376: carries the classification with the message, so the engine can publish both.
    @Published private(set) var failure: PlaybackErrorInfo?
    @Published private(set) var didReachEnd: Bool = false

    /// Enhancement layer type for Profile 7 streams (FEL or MEL), used for decoder selection
    var elType: String? = nil

    /// Which layer of a Dolby Vision source to present (.automatic or .baseLayerOnly).
    var dolbyVisionHandling: DolbyVisionHandling = .automatic

    /// Opt-in to full dual-layer Dolby Vision (Profile 7 FEL) decoding and Metal GPU composition over single-layer fallback.
    var preferDualLayerDolbyVision: Bool = false

    /// #846: set by the load before `load(demuxer:...)`; non-nil runs the upscale stage on every decoded frame.
    var upscalePlan: UpscalePlan?

    /// The stage built for the current plan (a `FrameUpscaler`), nil when none was.
    /// Typed loosely because the class does not exist in simulator builds or before OS 26.
    private(set) var frameUpscaler: AnyObject?

    /// Forwarded Dolby Vision profile number (e.g. 7, 8) if detected from bitstream or container
    var configuredDVProfile: Int?

    /// #315: `AVSampleBufferDisplayLayer.isReadyForDisplay` for the renderer's layer, this path's
    /// answer to "there is a picture". Frames enqueued is not that answer: it counts what the
    /// decoder handed over, and #298 is the report where every one of them went into a layer no
    /// host had bound.
    ///
    /// A LEVEL that falls whenever the layer loses its picture; the engine folds it into the
    /// load-scoped `AetherEngine.hasFirstFrameReadyForDisplay`, which is what hosts consume. A
    /// session with no video stream never arms the observation and leaves this false.
    @Published private(set) var isVideoReadyForDisplay: Bool = false

    /// #315: `readyForDisplay` observation on the renderer's layer, re-armed per load and torn down
    /// with the session.
    private var readyForDisplayObserver: NSObjectProtocol?

    /// #353: the size this session's picture presents at, coded dimensions under the pixel aspect
    /// ratio the decoder attached; nil until the renderer builds its first sample buffer and on
    /// sources with no video. The engine mirrors it as `AetherEngine.softwareDisplaySize`, which is
    /// what hosts read; this host is built per load, so it starts unknown by construction.
    @Published private(set) var videoDisplaySize: CGSize?

    /// Fires (off-main) once per session the first time HDR10+ dynamic
    /// metadata appears on a decoded frame. Hooked by `AetherEngine` to
    /// upgrade the published `videoFormat` from `.hdr10` → `.hdr10Plus`.
    nonisolated(unsafe) var onFirstHDR10PlusDetected: (@Sendable () -> Void)?

    /// Fires (off-main) when the demux loop re-anchors the clock at a first sample past the load anchor,
    /// with the session zero it resolved. Hooked by `AetherEngine` to republish `mediaChapters` from the
    /// clock's real zero.
    nonisolated(unsafe) var onClockSessionZero: (@Sendable (Double) -> Void)?

    /// #800: every hold of the clock by the preroll and its end, forwarded from `AudioOutput`, off-main.
    nonisolated(unsafe) var onClockHoldTransition: (@Sendable (AudioOutput.PrerollTransition) -> Void)?

    /// AE#658: forwarded from the video decoder, off-main.
    nonisolated(unsafe) var onDecodedVideoFormat: (@Sendable (DecodedVideoFormat) -> Void)?

    /// #131: forwarded from the video decoder; decoded-frame A53 cc_data triplets, presentation order.
    nonisolated(unsafe) var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?

    // MARK: - Output

    /// The display layer the engine attaches to the bound `AetherPlayerView`.
    /// Owned by `SampleBufferRenderer`; surfaced here so the engine can
    /// hand it to the view via the same `attach(_ layer: CALayer)` entry
    /// point it uses for `AVPlayerLayer`.
    var displayLayer: AVSampleBufferDisplayLayer { renderer.displayLayer }

    /// Whether load selected VideoToolbox rather than libavcodec / dav1d for video decoding.
    /// Only meaningful after load has returned successfully.
    var usesHardwareVideoDecoder: Bool { videoDecoder is HardwareVideoDecoder || decodesDualLayer }

    /// AE#711 follow-up: the picture on screen now, read back from the renderer before a rebuild's
    /// `stop()` flushes it, so the engine can hold it over the new host's startup. Falls back to the
    /// newest frame enqueued, which a layer that is not on screen is all there is of.
    func displayedFrame() -> CVPixelBuffer? {
        if #available(visionOS 1.1, *),
           let shown = renderer.displayLayer.sampleBufferRenderer.displayedPixelBuffer() {
            return shown
        }
        return renderer.lastEnqueuedFrame
    }

    /// SW-PiP Phase C: engine-fed cue mirror + PiP gate for the renderer's frame compositor.
    func updateSubtitleCompositor(cues: [SubtitleCue], enabled: Bool, delaySeconds: Double) {
        renderer.subtitleCompositor.update(cues: cues, enabled: enabled, delaySeconds: delaySeconds)
    }

    // MARK: - Internals

    private let renderer: SampleBufferRenderer
    /// Swapped per codec at load(): SoftwareVideoDecoder for AV1 and unsupported hardware formats, HardwareVideoDecoder for HEVC/VP9. Protocol keeps the demux loop codec-agnostic.
    private var videoDecoder: any VideoDecodingPipeline
    private var audioDecoder: (any SoftwareAudioProducing)?
    /// How this session's audio reaches the renderer (`SoftwareAtmosRoute`), for the logs and the tests.
    private(set) var audioRoute: SoftwareAtmosRoute = .pcm
    /// The route carries Dolby Atmos (`SoftwareAtmosRoute.carriesDolbyAtmos`), for `AtmosOutputActivator`.
    private(set) var audioRouteCarriesDolbyAtmos = false
    /// The host's object-audio setting, set before `load`. Anything but `.off` lets Atmos tracks reach
    /// the renderer as Atmos instead of as the PCM decode of their core.
    var objectAudioRendering: ObjectAudioRendering = .off

    /// AE#923: the host's audio shaping. Active shaping keeps the track on the PCM decode, past both
    /// Atmos routes, and the decoder carries it. Set before the decoder opens.
    var audioShaping = AudioShaping()

    /// AE#923: whether the producer this host built carries `audioShaping`.
    private(set) var audioShapingApplied = false
    private var audioOutput: AudioOutput?
    private var demuxer: Demuxer?
    private var vodPacketReadAhead: SoftwarePacketReadAhead?
    /// #687: this host's entries in the process-wide retention ledger, released on `stop()`.
    private var retentionClaims: [RetentionClaims.Claim] = []
    @Published private(set) var residentRanges: [ClosedRange<Double>] = []
    private let residentRangePublication = SoftwareResidentRangePublication()

    /// The same public buffered-position axis as the live and native hosts, but backed by
    /// actual compressed A/V packet coverage. nil when no continuous cache span contains the clock.
    var cachedVODSessionTime: Double? {
        guard let frontier = vodPacketReadAhead?.snapshot.frontier else { return nil }
        return max(0, frontier - max(0, clockSessionZero))
    }

    var cachedVODBytes: Int64? { vodPacketReadAhead.map { Int64($0.snapshot.residentBytes) } }
    var vodPacketCacheSnapshot: SoftwarePacketReadAhead.Snapshot? { vodPacketReadAhead?.snapshot }

    /// #107 round 2: a session-axis position on the source axis. The one place that mapping is
    /// made, for callers inside the host and outside it alike; the identity for a zero-based
    /// source, which is why the omissions only ever showed on a mid-stream-joined one.
    ///
    /// The two session shapes anchor on different things and always have: the live feeder anchors
    /// on the first packet's PTS as it arrives, the VOD path on the anchor `SWClockAnchorPolicy`
    /// resolved at the first decoded sample, which carries the resume offset with it.
    func sourceSeconds(forSession seconds: Double) -> Double {
        guard isLive else {
            return SWClockAnchorPolicy.sourceSeconds(forSession: seconds,
                                                     sessionZeroSeconds: clockSessionZero)
        }
        liveEdgeLock.lock()
        defer { liveEdgeLock.unlock() }
        return (sessionStartPts.isFinite ? sessionStartPts : 0) + seconds
    }

    /// The live feeder's inverse of `sourceSeconds(forSession:)`: a source PTS on the session axis,
    /// nil before the first packet has anchored the session.
    func liveSessionSeconds(forSource pts: Double) -> Double? {
        liveEdgeLock.lock()
        defer { liveEdgeLock.unlock() }
        guard isLive, sessionStartPts.isFinite, pts.isFinite else { return nil }
        return max(0, pts - sessionStartPts)
    }

    private let demuxQueue = DispatchQueue(label: "engine.sw.demux", qos: .userInitiated)

    /// #254: every demuxer reposition runs here, never on the main actor. See
    /// `Demuxer.seekBounded(to:anchorStreamIndex:timeout:on:isSuperseded:)` for why the main actor is
    /// the wrong thread for it. Serial and separate from `demuxQueue`, whose block never returns.
    private let seekQueue = DispatchQueue(label: "engine.sw.seek", qos: .userInitiated)

    /// Bound foreground VOD positioning independently of speculative side-reader work.
    /// Index-less containers can require several remote keyframe probes; cloud-mounted
    /// sources may take 2-3 seconds per successful range response. The former 8-second
    /// side-reader budget aborted these progressing seeks. Keep a finite total bound;
    /// repositioning still runs off-main and failed/cancelled results remain failures.
    static let seekBudgetSeconds: TimeInterval = 30.0

    /// True while a reposition is awaiting `seekQueue`. Gates the 0.25 s time tick: the synchronizer
    /// still carries the pre-seek anchor, so an ungated tick would walk the OLD position forward for
    /// the length of the reposition and then snap to the target.
    private var seekInFlight = false

    /// Transport intent for the reposition currently in flight (#292). `seek` clears `isPlaying` to park
    /// the loops, so a seek entering while another is suspended in its off-main reposition (#254) would
    /// read that cleared flag as "was paused" and land a playing session at rate 0. Rewritten by
    /// `pause()` / `play()` so an explicit transport call inside the window still wins.
    private var inFlightSeekResumeIntent = false

    /// Guards isPlaying/stopRequested across demux thread reads and main-actor writes.
    private let flagsLock = NSLock()
    nonisolated(unsafe) private var _isPlaying: Bool = false
    nonisolated(unsafe) private var _stopRequested: Bool = false

    /// Sodalite#104 round 4: a pause arrived before the first frame, so the loops keep reading until one
    /// is in (`PausedFirstFrame`). Set by `pause()`, cleared by `play()`, `stop()` and that frame.
    nonisolated private var pausedBeforeFirstFrame: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _pausedBeforeFirstFrame }
        set { flagsLock.lock(); _pausedBeforeFirstFrame = newValue; flagsLock.unlock() }
    }
    nonisolated(unsafe) private var _pausedBeforeFirstFrame = false

    /// Clears the flag and says whether it was set, in one step, so the first frame and a `play()` cannot
    /// both act on it.
    nonisolated private func takePausedBeforeFirstFrame() -> Bool {
        flagsLock.lock(); defer { flagsLock.unlock() }
        let was = _pausedBeforeFirstFrame
        _pausedBeforeFirstFrame = false
        return was
    }

    /// Condition the demux thread waits on while paused so it doesn't
    /// busy-loop reading packets that would just stack up.
    private let demuxCondition = NSCondition()

    private var videoStreamIndex: Int32 = -1
    /// The audio stream this host actually serves, or -1 when it serves none: the source had no audio
    /// track, or `AudioDecoder.open` refused it and the session went video-only (AE#462). Read by the
    /// engine for the published decoder label, which used to be built from the PROBE and therefore
    /// named a decoder that never opened. Also the host's own resolve, which is not always the
    /// engine's pick (#133 live-TS by-type fallback).
    private(set) var audioStreamIndex: Int32 = -1

    /// AE#464: the host's audio presentation offset in seconds, positive = audio later. Kept here as
    /// well as on the decoder so a decoder opened later in the session (an audio-track switch, a
    /// rebuild) starts out carrying it rather than at zero.
    private(set) var audioDelaySeconds: Double = 0

    /// AE#462: how this host delivers audio, as a typed fact for the engine's published
    /// `audioDelivery`. Set once the audio decoder has been given its chance.
    private(set) var audioDelivery: AudioDelivery = .none

    private var videoTimeBaseSeconds: Double = 0
    private var audioTimeBaseSeconds: Double = 0

    /// dav1d decoding AV1, set per session: seeks land on the nearest indexed keyframe (`SWKeyframeSnap`),
    /// out of the index's keyframes in source seconds as `refreshSnapKeyframes` last read them.
    private var snapsSeeksToKeyframes = false
    private var snapKeyframeSeconds: [Double] = []

    // MARK: - Live / DVR

    /// #544: decodes a scrub still out of `dvrRing`. Built beside the playback decoder so it never
    /// holds a stream pointer of its own, and driven only from `stillQueue`, off the demux and feed
    /// loops, so a preview frame never costs playback a packet.
    ///
    /// AE#595: built on the first request rather than at session start. It is a second decoder and
    /// its frame buffers, roughly 12 MB on a 1080i channel, standing for the whole session on a box
    /// with under 4 GB of RAM, for a feature most viewers of a live channel never touch. The first
    /// scrub already pays a decode of a whole GOP out of the ring, so the codec open rides along
    /// inside a cost the caller is waiting on anyway. The slot is what keeps a source it cannot
    /// open from being retried sixteen times a second.
    private var stillExtractorSlot = OneShotSlot<SoftwareStillExtractor>()
    private let stillQueue = DispatchQueue(label: "engine.sw.still", qos: .userInitiated)
    private let stillRequests = StillRequestCounter()

    /// Newest-wins ticket for still requests. A held scrub asks about sixteen times a second and the
    /// queue is serial, so without a ticket the queue takes work faster than it retires it: the card
    /// falls further behind the thumb with every request, and the decoding outlives the commit.
    final class StillRequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            value &+= 1
            return value
        }

        var latest: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Disk-spooled DVR rewind ring; non-nil for live sessions with dvrWindowSeconds set. Demux-thread appended (internally locked).
    nonisolated(unsafe) private var dvrRing: PacketRingBuffer?

    /// Same construction path for the live decoder and controlled-source contract fixtures.
    @discardableResult
    func prepareLiveDVR(windowSeconds window: Double, retention: SoftwareDVRRetentionOptions? = nil) -> PacketRingBuffer? {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aether-segments", isDirectory: true)
        let scratch = base.appendingPathComponent("dvr-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            // The chunk spool's disk budget and the caller's lease cap both apply.
            let available = (try? base.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
                .volumeAvailableCapacity.map(Int64.init)
            let claim = RetentionClaims.shared.claim(volumeAvailableBytes: available) {
                PacketRingBuffer.liveByteBudget(volumeAvailableBytes: $0)
            }
            let budget = claim.bytes
            let ring = try PacketRingBuffer(windowSeconds: window, scratch: scratch,
                                            byteBudget: budget, retention: retention)
            claim.track { [weak ring] in ring?.diskBytes ?? 0 }
            retentionClaims.append(claim)
            dvrRing = ring
            EngineLog.emit("[SWHost] DVR ring armed window=\(String(format: "%.0f", window))s budget=\(budget >> 20)MiB scratch=\(scratch.lastPathComponent)", category: .swPlayback)
            return ring
        } catch {
            EngineLog.emit("[SWHost] DVR ring create failed (\(error)); live-only fallback", category: .swPlayback)
            dvrRing = nil
            return nil
        }
    }

    @discardableResult
    func setLiveDVRLimits(_ limits: LiveDVRLimits, availableBytes: Int64?) -> Bool {
        guard let ring = dvrRing, !dvrRingHoldsCushionOnly else { return false }
        return ring.setLimits(limits, availableBytes: availableBytes)
    }
    var liveDVRBytes: Int? { dvrRing?.retainedBytes }
    /// A live session without a DVR window that asked for `liveEdgeCushionSeconds`: the ring exists
    /// only so the join can wait for the cushion and play behind the reader, and the session still
    /// publishes no rewind window, so a seek stays refused as on any live-only session.
    nonisolated(unsafe) private var dvrRingHoldsCushionOnly = false

    var liveDVRWindowSeconds: Double? { dvrRingHoldsCushionOnly ? nil : dvrRing?.retainedWindowSeconds }
    var liveDVRResidentFloor: Double? {
        guard !dvrRingHoldsCushionOnly, let pts = dvrRing?.oldestKeyframePts else { return nil }
        liveEdgeLock.lock(); defer { liveEdgeLock.unlock() }
        guard sessionStartPts.isFinite else { return nil }
        return max(0, pts - sessionStartPts)
    }

    /// AE#560: the live recording sink, read on the demux thread for every source packet.
    nonisolated(unsafe) fileprivate var recordingSink: LiveRecordingSink?
    fileprivate let recordingSinkLock = NSLock()

    /// True for a live session. Gates ring fill, edge publishing, and the
    /// live-DVR seek branch so the non-live SW path is untouched.
    private var isLive: Bool = false

    /// First packet's PTS (seconds); SW timeline is "seconds since first frame" = newestPts - sessionStartPts. nan until first packet.
    nonisolated(unsafe) private var sessionStartPts: Double = .nan

    nonisolated(unsafe) private var newestSourcePts: Double = .nan
    /// Where a live session's picture starts once the source's connect burst has landed; read and
    /// advanced by the live feeder under `liveEdgeLock`, reset with the session.
    nonisolated(unsafe) private var liveJoinPolicy = SoftwareLiveJoinPolicy()

    /// AE#813: the unit a live source delivers in, read on demand because a live ingest learns it
    /// as segments arrive. Set by the engine before `load()`; nil for a continuous source.
    nonisolated(unsafe) var liveDeliveryUnit: (@Sendable () -> Double?)?
    /// `LoadOptions.liveEdgeCushionSeconds`. Set by the engine before `load()`.
    nonisolated(unsafe) var liveEdgeCushionSeconds: Double?

    /// AE#813: how far behind the newest media this live session holds.
    nonisolated var liveHoldback: SoftwareLiveHoldback {
        SoftwareLiveHoldback(deliveryUnitSeconds: liveDeliveryUnit?(), edgeCushionSeconds: liveEdgeCushionSeconds)
    }

    /// Guards `sessionStartPts` / `newestSourcePts` against the demux
    /// thread writing while the main-actor time tick reads them.
    private let liveEdgeLock = NSLock()

    /// #303: seconds of decoded video queued ahead of the clock, nil before the first frame. This is
    /// the cushion an IO hiccup eats into, and the reason a blocked read reaches the picture here
    /// while the native path swallows the same event. Distinct from `bufferedSessionTime`, which is
    /// the DEMUXED frontier and is only fed on live sessions.
    var displayCushionSeconds: Double? {
        SoftwareBufferFrontier.cushionSeconds(newestEnqueuedPts: renderer.newestEnqueuedPtsSeconds,
                                              sourceClock: sourceClockSeconds)
    }

    /// #311: the timebase the master clock runs on, or nil before the session owns one. This is the
    /// `AVSampleBufferRenderSynchronizer`'s timebase, and it is created unconditionally, including for
    /// a source with no audio track, so on this path it exists for the whole session rather than only
    /// when something is playing.
    ///
    /// It reads the SOURCE axis, the same axis as `SoftwareVideoFrameTime.presentation` and as the
    /// subtitle cues, so an overlay paced against it needs no conversion.
    var presentationTimebase: CMTimebase? {
        audioOutput?.sourceTimebase
    }

    /// #311: forwarded to the renderer, which is where a frame is actually handed over. Set through
    /// the host rather than on the renderer directly so the engine has one place to re-arm it across
    /// a `load()`, the same shape the native path uses for its own observer.
    func setVideoFrameTimeObserver(_ observer: SoftwareVideoFrameTimeObserver?) {
        renderer.setFrameEnqueuedObserver(observer)
    }

    /// #303: the renderer's own view of what reached the display. Async because the AVFoundation
    /// accessor is; the memprobe already runs in an async context, so it is read there rather than
    /// cached, and the line never carries a stale snapshot.
    func loadRenderMetrics() async -> SampleBufferRenderer.RenderMetrics? {
        await renderer.loadRenderMetrics()
    }

    /// SW path's buffered frontier (AetherEngine#54): newest demuxed source PTS in session time. Published as clock.bufferedPosition.
    nonisolated var bufferedSessionTime: Double {
        liveEdgeLock.lock()
        defer { liveEdgeLock.unlock() }
        guard sessionStartPts.isFinite, newestSourcePts.isFinite else { return 0 }
        return max(0, newestSourcePts - sessionStartPts)
    }

    /// The DVR ring's rewind floor on the session axis once byte or time eviction has moved it past
    /// the start; nil before that and when no ring is armed. Published as the resident floor so the
    /// seekable range follows what the ring still holds (audit VPERF-101).
    nonisolated var dvrResidentFloorSessionSeconds: Double? {
        guard let ring = dvrRing, !dvrRingHoldsCushionOnly else { return nil }
        liveEdgeLock.lock()
        let start = sessionStartPts
        liveEdgeLock.unlock()
        return ring.residentFloorSessionSeconds(sessionStartPts: start)
    }

    // MARK: - Live reader/feeder split (DVR sessions)
    //
    // DVR live sessions: reader (demuxQueue) fills ring regardless of play/pause; feeder (feedQueue) decodes from ring cursor with renderer back-pressure.
    // Pause = timeshift (reader keeps filling); DVR rewind = cursor move. Replaces synchronous whole-tail replay (multi-second UI freeze, queue overflow).
    // Live-only (no ring): combined loop; pause parks the loop.

    /// Background queue for the live feeder loop.
    private let feedQueue = DispatchQueue(label: "engine.sw.feed", qos: .userInitiated)

    /// Guards `_feedCursor` / `_sourceEnded`.
    private let feedLock = NSLock()
    nonisolated(unsafe) private var _feedCursor: Int = 0
    nonisolated(unsafe) private var _sourceEnded = false
    nonisolated(unsafe) private var _dvrRecoveryTicket: UUID?

    /// Audio look-ahead pump cursor (#107 audio chopping): the feeder advances it ahead of
    /// `_feedCursor`, seek paths reset it alongside `setFeedCursor`.
    private let audioLookahead = AudioLookaheadState()

    nonisolated private func readFeedCursor() -> Int {
        feedLock.lock(); defer { feedLock.unlock() }
        return _feedCursor
    }

    /// Compare-and-advance: only advance when the cursor is still at
    /// `old`, so a concurrent DVR seek (which repositions the cursor)
    /// is never overwritten by the feeder's post-decode increment.
    nonisolated private func advanceFeedCursor(from old: Int) {
        feedLock.lock()
        if _feedCursor == old { _feedCursor = old + 1 }
        feedLock.unlock()
    }

    nonisolated private func setFeedCursor(_ value: Int) {
        feedLock.lock()
        _feedCursor = value
        feedLock.unlock()
        audioLookahead.reset(to: value)
        demuxCondition.lock()
        demuxCondition.broadcast()
        demuxCondition.unlock()
    }

    /// The live join's placement (#797), compare-and-set on the seek generation: a seek that landed
    /// between the feeder's decision and this write already moved the cursor where the viewer asked.
    nonisolated private func placeFeedCursor(_ value: Int, ifGeneration generation: UInt64) -> Bool {
        feedLock.lock()
        guard _seekGeneration == generation else {
            feedLock.unlock()
            return false
        }
        _feedCursor = value
        feedLock.unlock()
        audioLookahead.reset(to: value)
        demuxCondition.lock()
        demuxCondition.broadcast()
        demuxCondition.unlock()
        return true
    }

    nonisolated private var dvrRecoveryPending: Bool {
        feedLock.lock(); defer { feedLock.unlock() }
        return _dvrRecoveryTicket != nil
    }

    /// Park the feeder before scheduling a timeline transition. A cursor-only clamp leaves
    /// future samples queued against the old clock, freezing the last frame until it catches up.
    nonisolated private func recoverEvictedFeedCursor(from old: Int, ring: PacketRingBuffer) {
        let ticket = UUID()
        feedLock.lock()
        guard _feedCursor == old, _dvrRecoveryTicket == nil,
              _seekGeneration == _settledSeekGeneration else {
            feedLock.unlock()
            return
        }
        let generation = _seekGeneration
        _dvrRecoveryTicket = ticket
        feedLock.unlock()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishDVREvictionRecovery(ticket: ticket) }
            // A user seek, pause, stop or replacement wins over the queued recovery.
            guard !self.stopRequested, self.dvrRing === ring,
                  self.seekGeneration == generation, self.readFeedCursor() == old,
                  old < ring.seqBounds.first,
                  PausedFirstFrame.loopsMayRun(isPlaying: self.isPlaying,
                      pausedBeforeFirstFrame: self.pausedBeforeFirstFrame),
                  let target = self.liveDVRResidentFloor else { return }
            EngineLog.emit("[SWHost] DVR eviction recovery: cursor=\(old) targetSession=\(target)",
                           category: .swPlayback)
            // Reuse the live seek's decoder/renderer/audio flush, look-ahead reset and
            // clock anchor; source reader and finite retention caps remain in place.
            await self.seek(to: target)
        }
    }

    nonisolated private func finishDVREvictionRecovery(ticket: UUID) {
        feedLock.lock()
        if _dvrRecoveryTicket == ticket { _dvrRecoveryTicket = nil }
        feedLock.unlock()
        demuxCondition.lock()
        demuxCondition.broadcast()
        demuxCondition.unlock()
    }

    nonisolated private var sourceEnded: Bool {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _sourceEnded }
        set { feedLock.lock(); _sourceEnded = newValue; feedLock.unlock() }
    }

    nonisolated private func resetFeederState() {
        feedLock.lock()
        _feedCursor = 0
        _sourceEnded = false
        _dvrRecoveryTicket = nil
        _clockArmed = false
        _clockSessionZero = 0
        feedLock.unlock()
        audioLookahead.reset(to: 0)
    }

    /// Whether the synchronizer clock has been anchored this session. Shared with seek paths so a DVR seek before feeder arming is not overwritten by a late re-arm.
    nonisolated(unsafe) private var _clockArmed = false
    nonisolated private var clockArmed: Bool {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _clockArmed }
        set { feedLock.lock(); _clockArmed = newValue; feedLock.unlock() }
    }

    /// Session-zero offset for non-live sources whose first decoded sample deviated from
    /// the load anchor (mid-stream-joined TS, #107): raw clock minus this is the published
    /// position. 0 for zero-based sources and aligned resumes. Written once by the demux
    /// thread at clock arming, read by the main-actor time tick.
    nonisolated(unsafe) private var _clockSessionZero: Double = 0
    nonisolated private var clockSessionZero: Double {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _clockSessionZero }
        set { feedLock.lock(); _clockSessionZero = newValue; feedLock.unlock() }
    }

    /// Bumped at every seek; demux loop re-checks around blocking readPacket to discard stale pre-seek packets that would clear the skip threshold (visible fast-forward burst).
    nonisolated(unsafe) private var _seekGeneration: UInt64 = 0
    nonisolated private var seekGeneration: UInt64 {
        feedLock.lock(); defer { feedLock.unlock() }; return _seekGeneration
    }
    nonisolated private func bumpSeekGeneration() {
        feedLock.lock(); _seekGeneration &+= 1; feedLock.unlock()
    }

    /// AE#491 round 2: the generation whose seek is FINISHED, meaning the source stands at that
    /// target and the clock has been re-anchored there. The gap to `_seekGeneration` is the seek
    /// window; see `SeekWindow` for what a packet read inside it does to the frontier and to the
    /// audio lead.
    nonisolated(unsafe) private var _settledSeekGeneration: UInt64 = 0

    nonisolated var seekWindowOpen: Bool {
        feedLock.lock(); defer { feedLock.unlock() }
        return SeekWindow.isOpen(requested: _seekGeneration, settled: _settledSeekGeneration)
    }

    /// A single seek-state snapshot is needed for packet, EOF and error admission. Reading the
    /// generation and window separately can straddle a seek that opens and settles between them.
    nonisolated private func admitsRead(generation: UInt64) -> Bool {
        feedLock.lock()
        let requested = _seekGeneration
        let settled = _settledSeekGeneration
        feedLock.unlock()
        return SoftwareReadAdmission.admits(readGeneration: generation,
            requestedGeneration: requested, settledGeneration: settled, stopRequested: stopRequested)
    }

    nonisolated private func noteSeekSettled(_ generation: UInt64) {
        feedLock.lock()
        if SeekWindow.closes(settling: generation, live: _seekGeneration) {
            _settledSeekGeneration = generation
        }
        feedLock.unlock()
        demuxCondition.lock()
        demuxCondition.broadcast()
        demuxCondition.unlock()
    }

    /// AE#491: the generation the packet now in the decoder was read under. The decoder callback
    /// compares it against the live one, because a flush cannot reach a frame that is already
    /// inside the decoder: `videoDecoder.flush()` runs on the actor while the demux thread sits in
    /// `decode(packet:)`, and the hardware decoder answers on its own thread later still. A frame
    /// that comes out under a newer generation belongs to the position the seek left behind, and
    /// handing it over makes it the renderer's newest timestamp - the frame after it then reports
    /// the whole seek distance as one inter-frame interval.
    nonisolated(unsafe) private var _decodeGeneration: UInt64 = 0
    nonisolated private var decodeGeneration: UInt64 {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _decodeGeneration }
        set { feedLock.lock(); _decodeGeneration = newValue; feedLock.unlock() }
    }

    /// Set when pause() stopped the synchronizer; play() restores the rate (previously play() only flipped isPlaying, leaving the clock frozen).
    private var pausedByHost = false

    /// AE#374: end of media parks the clock exactly once. Both demux loops can reach `onEnd`, and the
    /// park is deferred by the queued audio tail, so the guard covers a second arrival mid-defer.
    private var didParkClockAtEnd = false

    /// Invoked on the main-actor time-update cadence with the current
    /// session-relative live edge (seconds since first frame) while live.
    /// Wired by the engine to `publishLiveWindow(edgeSessionTime:)`.
    var onLiveEdge: (@MainActor (Double) -> Void)?

    /// Session-relative live edge in seconds, or nil before the first
    /// packet. Read on the main actor by the time tick.
    private var liveEdgeSessionTime: Double? {
        liveEdgeLock.lock()
        defer { liveEdgeLock.unlock() }
        guard sessionStartPts.isFinite, newestSourcePts.isFinite else { return nil }
        return max(0, newestSourcePts - sessionStartPts)
    }

    private var timeTimer: AnyCancellable?

    // MARK: - Surface visibility (#298)

    /// Where a software session's frames end up on screen, or why they cannot.
    enum SurfaceVisibility: Equatable {
        case onScreen
        /// The display layer is in no view hierarchy: the host never bound a render surface.
        case notInViewHierarchy
        /// Attached, but the bound view never got a layout, so nothing can be visible.
        case zeroSized(width: Int, height: Int)
    }

    /// #298: a software session renders into `renderer.displayLayer`, which only reaches the screen
    /// once the host binds a surface (`AetherEngine.bind(view:)` / `AetherPlayerSurface`). A host that
    /// presents an AVPlayerViewController instead gets audio, a completely healthy engine log, and no
    /// picture, because this path has no AVPlayerItem for AVKit to show (its own spinner then sits
    /// there forever). Neither condition left a trace before, so the report reads as a renderer stall.
    /// "Never bound" wins over the size: an unbound layer is usually zero-sized as well, and the bind
    /// is the actionable half.
    nonisolated static func assessSurface(hasSuperlayer: Bool, size: CGSize) -> SurfaceVisibility {
        guard hasSuperlayer else { return .notInViewHierarchy }
        guard size.width > 0, size.height > 0 else {
            return .zeroSized(width: Int(size.width), height: Int(size.height))
        }
        return .onScreen
    }

    /// Ticks (0.25 s each) the surface check waits after the first enqueued frame. A host binding its
    /// view during load, and the first layout pass after that, both land well inside this.
    private static let surfaceCheckTicks = 8

    private var surfaceCheckTicksSeen = 0
    private var surfaceChecked = false

    /// Runs once per session, ~2 s after frames start flowing. Reads CALayer state, so main actor only.
    private func checkSurfaceVisibilityIfDue() {
        guard !surfaceChecked, !backgroundAudioOnly, framesEnqueued > 0 else { return }
        surfaceCheckTicksSeen += 1
        guard surfaceCheckTicksSeen >= Self.surfaceCheckTicks else { return }
        surfaceChecked = true

        let layer = renderer.displayLayer
        switch Self.assessSurface(hasSuperlayer: layer.superlayer != nil, size: layer.bounds.size) {
        case .onScreen:
            return
        case .notInViewHierarchy:
            EngineLog.emit(
                "[SWHost] \(framesEnqueued) frames decoded into a display layer that is in no view "
                + "hierarchy: the host never bound a render surface (AetherEngine.bind(view:) / "
                + "AetherPlayerSurface). The software path renders into that layer, not through "
                + "AVPlayerViewController, so audio plays and no picture can appear",
                category: .swPlayback
            )
        case .zeroSized(let width, let height):
            EngineLog.emit(
                "[SWHost] display layer is bound but sized \(width)x\(height) after "
                + "\(framesEnqueued) frames: the bound view has no layout, so no frame can be visible",
                category: .swPlayback
            )
        }
    }

    /// #315: publish the renderer layer's own `readyForDisplay` as `isVideoReadyForDisplay`.
    /// AVFoundation posts a notification for it rather than supporting KVO, and it arrived in
    /// tvOS/iOS 17.4, macOS 14.4 and visionOS 1.1. Only visionOS still has a floor below that (1.0).
    /// Where it is missing the fallback is the first frame handed to the renderer
    /// (`disarmedFallbackFirstFrame`), which is one hop earlier than presentation and is documented as
    /// such on the public property.
    ///
    /// #344: visionOS has to be named. Falling through to `*` resolves it to the package's declared
    /// visionOS floor, which is 1.0, and that is a compile error rather than a runtime fallback.
    private func armReadyForDisplayObserver() {
        disarmReadyForDisplayObserver()
        guard #available(visionOS 1.1, *) else { return }
        let layer = renderer.displayLayer
        readyForDisplayObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
            object: layer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let ready = self.renderer.displayLayer.isReadyForDisplay
                guard ready != self.isVideoReadyForDisplay else { return }
                EngineLog.emit(
                    "[SWHost] layer.isReadyForDisplay=\(ready) after \(self.framesEnqueued) frames",
                    category: .swPlayback
                )
                self.isVideoReadyForDisplay = ready
            }
        }
    }

    private func disarmReadyForDisplayObserver() {
        if let readyForDisplayObserver {
            NotificationCenter.default.removeObserver(readyForDisplayObserver)
            self.readyForDisplayObserver = nil
        }
    }

    /// #315 fallback below visionOS 1.1, the one floor that predates `readyForDisplay` on the layer,
    /// so the first frame the decoder hands the renderer is the closest observable. Called off-main.
    /// Mirrors the observer's list exactly: a platform named there and not here would get neither the
    /// notification nor the fallback, so it would never publish readiness at all.
    nonisolated private func noteFirstFrameEnqueuedForDisplayFallback() {
        guard #unavailable(visionOS 1.1) else { return }
        Task { @MainActor [weak self] in self?.isVideoReadyForDisplay = true }
    }

    /// Caching the chosen rate so resume() restores the right speed after a pause without the
    /// host needing to know its history. Lock-guarded: the demux/feeder threads read it at clock
    /// arming so a host rate change between load and arm is not lost (#107).
    nonisolated(unsafe) private var _lastRate: Float = 1.0
    nonisolated private var lastRate: Float {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _lastRate }
        set { flagsLock.lock(); _lastRate = newValue; flagsLock.unlock() }
    }

    /// Start position captured so the demux loop aligns the synchronizer clock to the first sample's PTS; non-zero resume without this would cause "frozen frame, no audio".
    private var initialClockTime: CMTime = .zero

    nonisolated var isPlaying: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _isPlaying }
        set {
            flagsLock.lock(); _isPlaying = newValue; flagsLock.unlock()
            demuxCondition.lock()
            demuxCondition.broadcast()
            demuxCondition.unlock()
        }
    }

    nonisolated var stopRequested: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _stopRequested }
        set {
            flagsLock.lock(); _stopRequested = newValue; flagsLock.unlock()
            demuxCondition.lock()
            demuxCondition.broadcast()
            demuxCondition.unlock()
        }
    }

    /// Set by the engine on background-enter (iOS keepalive) and cleared on foreground. While true the
    /// combined demux loop drops video packets and paces on the audio renderer, so audio keeps playing in
    /// the background. The setter broadcasts the demux condition so a parked loop re-evaluates immediately.
    /// AE#739: the hardware decoder lost its session while nothing could act on it, or VT refused the
    /// rebuild. Paid by `exitBackgroundAudioOnly()`. Main actor only.
    private var videoSessionRecoveryOwed = false
    /// How many keyframes have retried a refused rebuild in the foreground. Main actor only.
    private var videoSessionRetry = VideoSessionRetryPolicy()
    /// Nothing shows the picture: the app is in the background with no picture-in-picture window. That covers
    /// audio-only mode and a retained paused session, where VideoToolbox refuses a rebuild by design. The engine
    /// reports it through `noteAppInBackground(_:)`. Main actor only.
    private var appInBackground = false
    nonisolated(unsafe) private var _backgroundAudioOnly = false
    nonisolated var backgroundAudioOnly: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _backgroundAudioOnly }
        set {
            flagsLock.lock(); _backgroundAudioOnly = newValue; flagsLock.unlock()
            demuxCondition.lock()
            demuxCondition.broadcast()
            demuxCondition.unlock()
        }
    }

    // MARK: - Init

    typealias Reposition = @Sendable (Demuxer, Double, TimeInterval, DispatchQueue,
                                      @escaping @Sendable () -> Bool) async -> Demuxer.RepositionOutcome
    private let reposition: Reposition

    init(videoGravity: AVLayerVideoGravity = .resizeAspect,
         renderer: SampleBufferRenderer? = nil,
         reposition: @escaping Reposition = { dem, target, budget, queue, superseded in
             await dem.seekBounded(to: target, timeout: budget, on: queue,
                                   isSuperseded: superseded)
         }) {
        self.reposition = reposition
        self.renderer = renderer ?? SampleBufferRenderer(videoGravity: videoGravity)
        // Default to the software decoder; load() swaps it for the
        // VT-backed one when the source's video codec is HEVC.
        self.videoDecoder = SoftwareVideoDecoder()
        armDisplaySizeObserver()
        armQueueFlushObserver()
    }

    /// #353: the renderer settles the picture size on the decode thread, where it builds the format
    /// description; publish it on the main actor like every other mirror on this host. Armed in init
    /// rather than at load: the renderer is this host's own and lives exactly as long as it does.
    private func armDisplaySizeObserver() {
        renderer.setDisplaySizeObserver { [weak self] size in
            Task { @MainActor in
                guard let self, self.videoDisplaySize != size else { return }
                self.videoDisplaySize = size
                EngineLog.emit(
                    "[SWHost] picture settles at \(Int(size.width))x\(Int(size.height)) "
                    + "after \(self.framesEnqueued) frames",
                    category: .swPlayback
                )
            }
        }
    }

    // MARK: - Audio stream resolution (#133)

    /// AE#462: how this host's audio ended up, from the two facts that decide it. Silence has two
    /// causes here exactly as it does in the loopback cascade, and only one of them is a reason for
    /// a host to demote to a source that carries the audio differently.
    ///
    /// AE#641: an unresolved index is not a source without audio. On VOD nothing falls back past
    /// `av_find_best_stream`, which passes over an audio stream whose parameters the probe left empty,
    /// so the source's own streams decide which of the two silences this is.
    ///
    /// The route decides the rest, in the loopback route's terms: the PCM decode is `.decoded`, compressed
    /// E-AC-3 JOC reaches the renderer as authored (`.streamCopy`), and TrueHD Atmos / DTS:X rendered into
    /// a bed and re-encoded as APAC is `.bridged`, which is how the loopback route reports the same APAC.
    nonisolated static func audioDelivery(resolvedAudioIndex: Int32, decoderOpened: Bool,
                                          sourceCarriesAudio: Bool,
                                          route: SoftwareAtmosRoute = .pcm) -> AudioDelivery {
        guard resolvedAudioIndex >= 0 else { return sourceCarriesAudio ? .droppedNoPipeline : .noAudioInSource }
        guard decoderOpened else { return .droppedNoPipeline }
        switch route {
        case .pcm: return .decoded
        case .compressedEAC3JOC: return .streamCopy
        case .apac, .pcmBed: return .bridged
        }
    }

    /// Whether this session plays audio at all, on whichever route.
    var deliversAudio: Bool {
        audioDelivery == .decoded || audioDelivery == .bridged || audioDelivery == .streamCopy
    }

    /// Resolve the audio stream index for a SW-host session. `av_find_best_stream` (`bestStream`)
    /// returns -1 for a live-MPEG-TS AAC stream whose codecpar the probe left empty
    /// (sample_rate/channels=0 because find_stream_info bailed before decoding a frame). On live
    /// sources fall back to the first audio-type stream (`firstByType`) so the AudioDecoder, which
    /// fills rate/channels from the first decoded frame, is reachable and the session is not silent.
    /// Mirrors HLSVideoEngine's native live-audio fallback; VOD keeps av_find_best_stream semantics.
    nonisolated static func resolveAudioStreamIndex(
        explicit: Int32?, bestStream: Int32, firstByType: Int32, isLive: Bool
    ) -> Int32 {
        if let explicit, explicit >= 0 { return explicit }
        if bestStream >= 0 { return bestStream }
        if isLive, firstByType >= 0 { return firstByType }
        return -1
    }

    /// True when a live-MPEG-TS AAC stream needs codecpar repair before the decoder opens: the probe
    /// left `sample_rate=0`. Mirrors HLSVideoEngine's native repair (fill 48 kHz stereo AAC-LC). VOD
    /// probes the whole file, so its codecpar is trusted and never repaired.
    nonisolated static func shouldRepairLiveAACCodecpar(
        isLive: Bool, codecID: AVCodecID, sampleRate: Int32
    ) -> Bool {
        isLive && codecID == AV_CODEC_ID_AAC && sampleRate == 0
    }

    /// Pure decision: whether the demux loop folds PTS discontinuities into one continuous
    /// timeline. Live always folds (encoder restarts mid-session). A forward-only non-live
    /// source folds too: sequential-origin IPTV timeshift archives are chunked recordings
    /// whose every chunk restarts at PTS ~0, FFmpeg's wrap correction turns that backward
    /// jump into a ~26.5 h forward one, and a non-seekable pb offers no seek-based recovery.
    /// Seekable VOD keeps its trusted container timeline untouched.
    nonisolated static func shouldFoldTimeline(isLive: Bool, sourceSeekable: Bool) -> Bool {
        isLive || !sourceSeekable
    }

    /// Pure decision: whether the combined demux loop stops pulling packets. It stops once
    /// decoded audio holds `AudioLookaheadPolicy.targetLeadSeconds` over the clock, which is
    /// what the parked-video FIFO exists to allow; the packet cap is only a memory backstop,
    /// and letting it do the pacing would make the effective lead a function of frame rate.
    /// Before the clock is armed the lead is meaningless (the clock reads garbage), so only
    /// the backstop applies: the loop has to keep reading to produce the buffers that arm it.
    nonisolated static func shouldHoldDemuxRead(
        parkedCount: Int,
        parkedCap: Int,
        clockArmed: Bool,
        lastAudioPts: Double,
        clockSeconds: Double
    ) -> Bool {
        if parkedCount >= parkedCap { return true }
        guard clockArmed, clockSeconds.isFinite else { return false }
        return AudioLookaheadPolicy.decide(
            clockArmed: true,
            preArmPacketsFed: 0,
            lastFedAudioPTS: lastAudioPts,
            clockSeconds: clockSeconds
        ) == .stop
    }

    /// How long the parked demux loop waits before it re-checks the renderer, in seconds. The renderer
    /// drains at frame cadence and the audio lead shrinks with the clock, and nothing signals either,
    /// so this is a timed wait (audit PERF-110: the fixed 5 ms sleep was 200 wakeups a second in every
    /// software VOD session). It is bounded by the time the read gate needs to open (the lead's excess
    /// over its target at the playback rate), never below 5 ms, and never above 20 ms: a renderer queue
    /// of about ten frames cannot drain in that, so the parked video still reaches the decoder in time.
    nonisolated static func parkedRendererWaitSeconds(
        clockArmed: Bool, lastAudioPts: Double, clockSeconds: Double, rate: Float
    ) -> TimeInterval {
        let floor = 0.005, ceiling = 0.020
        guard clockArmed, lastAudioPts.isFinite, clockSeconds.isFinite, rate > 0 else { return floor }
        let untilGateOpens = (lastAudioPts - clockSeconds - AudioLookaheadPolicy.targetLeadSeconds) / Double(rate)
        guard untilGateOpens.isFinite else { return floor }
        return min(max(untilGateOpens, floor), ceiling)
    }

    /// Pure decoder selection predicate for Profile 7 / HEVC streams on the software host.
    /// DualLayerVideoDecoder is selected ONLY when dvProfile == 7 && elType == "FEL" && preferDualLayerDolbyVision
    /// && dolbyVisionHandling == .automatic, in a build with the DualLayerDolbyVision trait.
    /// All other combinations (e.g. MEL, baseLayerOnly, preferDualLayerDolbyVision == false) pick HardwareVideoDecoder.
    nonisolated static func shouldUseDualLayerDecoder(
        dvProfile: Int?,
        elType: String?,
        preferDualLayerDolbyVision: Bool,
        dolbyVisionHandling: DolbyVisionHandling
    ) -> Bool {
        DualLayerRouteDecision.isBuiltIn
            && dvProfile == 7
            && elType == "FEL"
            && preferDualLayerDolbyVision
            && dolbyVisionHandling == .automatic
    }

    /// Whether `decoder` is a `DualLayerVideoDecoder`; always false without the trait.
    nonisolated static func isDualLayer(_ decoder: any VideoDecodingPipeline) -> Bool {
        #if DualLayerDolbyVision
        return decoder is DualLayerVideoDecoder
        #else
        return false
        #endif
    }

    var decodesDualLayer: Bool { Self.isDualLayer(videoDecoder) }

    /// Selects and instantiates the appropriate VideoDecodingPipeline based on stream and host options.
    func selectVideoDecoder(
        codecID: AVCodecID,
        canHardwareDecode: Bool,
        dvProfile: Int?
    ) -> any VideoDecodingPipeline {
        if codecID == AV_CODEC_ID_VP9 && canHardwareDecode {
            return HardwareVideoDecoder()
        }
        if codecID == AV_CODEC_ID_HEVC && canHardwareDecode {
            if Self.shouldUseDualLayerDecoder(
                dvProfile: dvProfile,
                elType: elType,
                preferDualLayerDolbyVision: preferDualLayerDolbyVision,
                dolbyVisionHandling: dolbyVisionHandling
            ) {
                #if DualLayerDolbyVision
                // No Metal device: the composer cannot be built, so decode the base layer alone (the
                // decoder the software host uses for any other Profile 7 stream) instead of opening a
                // decoder whose `open()` can only throw. A shader that fails to compile is caught later,
                // once: every frame then goes out as its base layer.
                if let composer = DoviFelComposer() {
                    return DualLayerVideoDecoder(composer: composer)
                }
                EngineLog.emit("[SWHost] DV P7 dual-layer route: no Metal device for the composer, decoding the base layer alone", category: .swPlayback)
                #endif
                return HardwareVideoDecoder()
            } else {
                return HardwareVideoDecoder()
            }
        } else {
            return SoftwareVideoDecoder()
        }
    }

    /// #846: `handler` wrapped in the upscale stage when a plan is set and a stage builds, else unchanged.
    /// Never for the dual-layer decoder (FEL sources are HDR and refused upstream).
    func upscaledFrameHandler(
        _ handler: @escaping DecodedFrameHandler,
        decoder: any VideoDecodingPipeline,
        frameRate: Double?
    ) -> DecodedFrameHandler {
        frameUpscaler = nil
        guard let plan = upscalePlan, !Self.isDualLayer(decoder) else { return handler }
        #if !targetEnvironment(simulator)
        if #available(tvOS 26, iOS 26, macOS 26, visionOS 26, *) {
            let interval = frameRate.flatMap { $0.isFinite && $0 > 0 ? 1 / $0 : nil } ?? 1.0 / 25
            guard let stage = FrameUpscaler(plan: plan, frameInterval: interval) else { return handler }
            frameUpscaler = stage
            return UpscalingFrameHandler.wrap(handler) { stage.upscale($0, pts: $1) }
        }
        #endif
        return handler
    }

    // MARK: - Load

    func load(
        demuxer dem: Demuxer,
        startPosition: Double?,
        audioSourceStreamIndex: Int32?,
        isLive: Bool = false,
        dvrWindowSeconds: Double? = nil,
        dvrRetention: SoftwareDVRRetentionOptions? = nil,
        forwardBufferSegments: Int? = nil,
        packetCacheStorage: SoftwarePacketCacheStorage = .automatic,
        sessionCacheByteBudget: Int? = nil
    ) async throws {
        self.demuxer = dem
        self.duration = dem.duration
        self.isLive = isLive

        guard dem.videoStreamIndex >= 0,
              let vStream = dem.stream(at: dem.videoStreamIndex) else {
            throw HostError.noVideoStream
        }
        self.videoStreamIndex = dem.videoStreamIndex
        let vtb = vStream.pointee.time_base
        self.videoTimeBaseSeconds = vtb.den > 0 ? Double(vtb.num) / Double(vtb.den) : 0
        if let codecpar = vStream.pointee.codecpar {
            videoYieldsStills = FrameDecodeContext.yieldsStill(
                dolbyVisionNoBaseLayer: FrameDecodeContext.isDVNoBaseLayer(codecpar: codecpar))
        }
        // #315: armed once there is a video stream to display. A fresh host means a fresh layer, so
        // there is no carried-in picture to guard against here (the native path's problem).
        armReadyForDisplayObserver()

        dvrRingHoldsCushionOnly = false
        if isLive, let window = dvrWindowSeconds {
            _ = prepareLiveDVR(windowSeconds: window, retention: dvrRetention)
        } else if isLive, let cushion = LiveEdgePolicy.edgeCushion(liveEdgeCushionSeconds) {
            // The plain live feeder plays packets as the demuxer reads them, so there is nothing to
            // play behind. A ring as deep as the loopback's cushion window gives the join one.
            dvrRingHoldsCushionOnly = prepareLiveDVR(
                windowSeconds: cushion + LiveWindowSizing.edgeCushionWindowMarginSeconds, retention: nil) != nil
        }

        // Resolve the audio stream up front so the session-start log and the decoder agree. #133:
        // live-TS AAC whose codecpar the probe left empty makes av_find_best_stream return -1; the
        // by-type fallback (live-only) is what keeps SW-routed live TS from coming up silent.
        let bestAudioIdx = dem.audioStreamIndex
        let resolvedAudioIdx = Self.resolveAudioStreamIndex(
            explicit: audioSourceStreamIndex,
            bestStream: bestAudioIdx,
            firstByType: dem.firstAudioStreamIndexByType,
            isLive: isLive
        )
        if audioSourceStreamIndex == nil, bestAudioIdx < 0, resolvedAudioIdx >= 0 {
            EngineLog.emit(
                "[SWHost] audio: av_find_best_stream found no usable audio "
                + "(live probe left empty codecpar?); falling back to first audio-type stream \(resolvedAudioIdx)",
                category: .swPlayback
            )
        }

        // Release-visible session-start log: SW-path black-screens were indistinguishable from "never dispatched" (DrHurt #4).
        let vCodecID = vStream.pointee.codecpar?.pointee.codec_id.rawValue ?? 0
        let aCodecID: UInt32 = resolvedAudioIdx >= 0
            ? (dem.stream(at: resolvedAudioIdx)?.pointee.codecpar?.pointee.codec_id.rawValue ?? 0)
            : 0
        EngineLog.emit(
            "[SWHost] session start: videoCodecID=\(vCodecID) "
            + "audioCodecID=\(aCodecID == 0 ? "none" : String(aCodecID)) "
            + "duration=\(String(format: "%.1f", dem.duration))s",
            category: .swPlayback
        )

        // A Profile 7 FEL session on a freshly opened demuxer (the load's probe completes its own) still
        // has the empty hvcC of an in-band-parameter-set source: complete it, or the verdict below sends
        // the stream to libavcodec and the enhancement layer is never composed. No-op otherwise.
        if !isLive,
           Self.shouldUseDualLayerDecoder(
               dvProfile: configuredDVProfile ?? AetherEngine.dvProfile(stream: vStream),
               elType: elType,
               preferDualLayerDolbyVision: preferDualLayerDolbyVision,
               dolbyVisionHandling: dolbyVisionHandling) {
            let vIdx = dem.videoStreamIndex
            await BlockingWork.detached(priority: .userInitiated) {
                _ = VideoConfigRecord.completeHEVCRecordFromInBandParameterSets(demuxer: dem, streamIndex: vIdx)
            }.value
            // A stop() can land on this suspension as on the start-position seek below.
            guard !stopRequested else { return }
        }

        // VP9 tries a hardware session with a software fallback at open. HEVC uses VideoToolbox
        // only when the probe proves that this exact format opens a hardware session;
        // everything else -> libavcodec. Replace wholesale to prevent state bleed. #2: HardwareVideoDecoder
        // requires a HW decoder and has no software fallback, so an HEVC Rext stream on hardware without a
        // HW decoder must go to libavcodec. AE#461: so must every format the probe cannot classify (in-band
        // parameter sets, Annex-B extradata), which the routing gate reads as "keep native" but which
        // HardwareVideoDecoder, building from the hvcC alone, can never open.
        if let codecpar = vStream.pointee.codecpar,
           codecpar.pointee.codec_id == AV_CODEC_ID_VP9
            || (codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
                && VTCapabilityProbe.hardwareDecodeVerdict(codecpar: codecpar).opensHardwareDecoder) {
            videoDecoder.close()
            let dvProfile = configuredDVProfile ?? AetherEngine.dvProfile(stream: vStream)
            let chosen = selectVideoDecoder(
                codecID: codecpar.pointee.codec_id,
                canHardwareDecode: true,
                dvProfile: dvProfile
            )
            videoDecoder = chosen
            #if DualLayerDolbyVision
            if let dual = chosen as? DualLayerVideoDecoder {
                // An in-band primary open failure (no hvcC to open from) leaves nothing to show. Surface it
                // through the same `failure` the read loops use for a decode error. It belongs to the
                // decoder session, not to a seek: the decoder reports it once and a seek does not reopen the
                // primary decoder, so gating it by seek generation would lose it for good when a seek lands
                // between the report and the main-actor hop (black video, no error). Only a stopped host
                // drops it.
                dual.onFatalDecodeError = { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, SoftwareReadAdmission.admitsSessionFailure(stopRequested: self.stopRequested) else { return }
                        self.failure = PlaybackErrorInfo(
                            kind: .softwarePipelineFailed,
                            message: "Playback error: \(error.localizedDescription)")
                    }
                }
            }
            #endif
            if decodesDualLayer {
                EngineLog.emit(
                    "[SWHost] selected DualLayerVideoDecoder (Metal P7 FEL) for codec_id=\(codecpar.pointee.codec_id.rawValue)",
                    category: .swPlayback
                )
            } else {
                EngineLog.emit(
                    "[SWHost] selected HardwareVideoDecoder (VT) for codec_id=\(codecpar.pointee.codec_id.rawValue)",
                    category: .swPlayback
                )
            }
        } else if HardwareVideoDecoder.decodesAV1DolbyVision(stream: vStream) {
            // AV1 Dolby Vision 10.1: AVFoundation drops the RPU, so the Dolby Vision is only reachable
            // from a host that decodes the frame and attaches it (AV1DolbyVisionRPU).
            videoDecoder.close()
            videoDecoder = HardwareVideoDecoder()
            EngineLog.emit(
                "[SWHost] selected HardwareVideoDecoder (VT AV1, Dolby Vision 10.1 RPU attached) for codec_id="
                + "\(vStream.pointee.codecpar?.pointee.codec_id.rawValue ?? 0)",
                category: .swPlayback
            )
        } else if !(videoDecoder is SoftwareVideoDecoder) {
            videoDecoder.close()
            videoDecoder = SoftwareVideoDecoder()
            EngineLog.emit(
                "[SWHost] selected SoftwareVideoDecoder (libavcodec) for codec_id="
                + "\(vStream.pointee.codecpar?.pointee.codec_id.rawValue ?? 0)",
                category: .swPlayback
            )
        }

        // The parser is lazy and producer-owned; this copies only stream configuration. The
        // observer must be installed before open so libavcodec propagates opaque identities.
        let cacheTiming: SoftwarePacketCacheTiming?
        if !isLive, !dem.readsSourceDirectly, dem.isSourceSeekable,
           dem.usesAVIMPEG4CacheTiming(at: videoStreamIndex),
           let software = videoDecoder as? SoftwareVideoDecoder {
            let p = vStream.pointee.codecpar?.pointee
            let extra = p.flatMap { par -> Data? in
                guard par.extradata_size > 0, let bytes = par.extradata else { return nil }
                return Data(bytes: bytes, count: Int(par.extradata_size))
            } ?? Data()
            let timing = SoftwarePacketCacheTiming(numerator: vtb.num, denominator: vtb.den, extradata: extra)
            software.onCacheTiming = { epoch, position, pts in timing.observe(epoch: epoch, position: position, pts: pts) }
            cacheTiming = timing
        } else {
            (videoDecoder as? SoftwareVideoDecoder)?.onCacheTiming = nil
            cacheTiming = nil
        }

        // Audit PERF-104: only the VideoToolbox decoders emit out of presentation order. That includes the
        // DualLayerVideoDecoder: OrderedDelivery keeps its frames in the order the base layer came out of
        // VideoToolbox, which is decode order (measured on the real fixtures, `DoviFelRealFileTests`). It gets
        // the same reorder depth as the single-layer hardware decoder, used only when arrival-order handover
        // below is off (no frame rate).
        renderer.setReorderDepth(SampleBufferRenderer.reorderDepth(
            forHardwareDecoder: videoDecoder is HardwareVideoDecoder || decodesDualLayer))
        renderer.setFELLookahead(
            enabled: decodesDualLayer,
            frameRate: AetherEngine.detectFrameRate(stream: vStream))
        // The FEL look-ahead window only holds if none of it waits in the reorder buffer; see
        // `SampleBufferRenderer.arrivalFloor`. Without a frame rate it stays on the reorder buffer.
        renderer.setArrivalOrderHandover(
            frameRate: decodesDualLayer ? AetherEngine.detectFrameRate(stream: vStream) : nil)

        // Flip display layer into HDR mode before frames arrive; without this preferredDynamicRange stays .standard and PQ/HLG renders desaturated.
        if let codecpar = vStream.pointee.codecpar {
            let trc = codecpar.pointee.color_trc
            let sourceIsHDR = trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67
            if sourceIsHDR {
                renderer.setHDROutput(true)
                EngineLog.emit(
                    "[SWHost] HDR mode ON on display layer (transfer=\(trc.rawValue))",
                    category: .swPlayback
                )
            }
        }

        // Applied here (not init) so it also covers a decoder replaced above.
        (videoDecoder as? SoftwareVideoDecoder)?.deinterlaceConfig = deinterlaceConfig

        let baseOnFrame: DecodedFrameHandler = { [weak self] pixelBuffer, pts, hdr10PlusData in
            guard let self else { return }
            // AE#491: a frame decoded from a pre-seek packet is not late, it is from somewhere else.
            guard self.decodeGeneration == self.seekGeneration else { return }
            // Decoder callback is off-main; SampleBufferRenderer is internally locked.
            self.renderer.enqueue(pixelBuffer: pixelBuffer, pts: pts, hdr10PlusData: hdr10PlusData)
            // First-frame milestone: demux reached a video packet + decoder produced a pixel buffer.
            if self.bumpFramesEnqueued() == 0 {
                self.noteFirstFrameEnqueuedForDisplayFallback()
                if self.takePausedBeforeFirstFrame() {
                    // The reorder buffer holds frames before it hands one to the layer, and the
                    // loops park again from here: without the drain the frame never leaves it.
                    self.renderer.drainReorderBuffer()
                    self.presentFirstFrameUnderPause(pts: pts.seconds, generation: self.decodeGeneration)
                }
                let pfType = CVPixelBufferGetPixelFormatType(pixelBuffer)
                EngineLog.emit(
                    "[SWHost] first video frame enqueued: "
                    + "pixfmt=0x\(String(pfType, radix: 16)) "
                    + "size=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) "
                    + "pts=\(String(format: "%.3f", pts.seconds))s",
                    category: .swPlayback
                )
            }
        }

        let onFrame = upscaledFrameHandler(
            baseOnFrame, decoder: videoDecoder, frameRate: AetherEngine.detectFrameRate(stream: vStream))

        if vStream.pointee.codecpar?.pointee.codec_id == AV_CODEC_ID_VP9 {
            let opened = try VideoDecoderOpener.openPreferredOrFallback(
                preferred: videoDecoder,
                makeFallback: {
                    let decoder = SoftwareVideoDecoder()
                    decoder.deinterlaceConfig = self.deinterlaceConfig
                    return decoder
                },
                stream: vStream,
                onFrame: onFrame)
            videoDecoder = opened.decoder
            renderer.setReorderDepth(SampleBufferRenderer.reorderDepth(
                forHardwareDecoder: videoDecoder is HardwareVideoDecoder))
            if let reason = opened.preferredFailureDescription {
                EngineLog.emit("[SWHost] VP9 hardware open failed; using libavcodec: \(reason)",
                               category: .swPlayback)
            }
        } else {
            try videoDecoder.open(stream: vStream, onFrame: onFrame)
        }

        videoDecoder.onFirstHDR10PlusDetected = { [weak self] in
            self?.onFirstHDR10PlusDetected?()
        }
        videoDecoder.onDecodedFormat = { [weak self] format in
            self?.onDecodedVideoFormat?(format)
        }
        // Both VideoToolbox decoders, the dual-layer one included: its two sessions can be lost the same way.
        (videoDecoder as? any VideoSessionRebuilding)?.onSessionLost = { [weak self] in
            Task { @MainActor [weak self] in self?.handleVideoSessionLost() }
        }
        (videoDecoder as? any VideoSessionKeyframeReporting)?.onKeyframeWhileLost = { [weak self] in
            Task { @MainActor [weak self] in self?.handleKeyframeWhileSessionLost() }
        }
        videoDecoder.onA53Captions = { [weak self] triplets, pts in
            self?.onA53Captions?(triplets, pts)
        }

        if resolvedAudioIdx >= 0, let aStream = dem.stream(at: resolvedAudioIdx),
           let acp = aStream.pointee.codecpar {
            // Live AAC the probe never filled (sample_rate=0): assume 48 kHz stereo AAC-LC so channel
            // negotiation and the published track are correct. The AudioDecoder otherwise recovers
            // rate/channels from the first decoded frame, but not before the session reports zero.
            if Self.shouldRepairLiveAACCodecpar(
                isLive: isLive, codecID: acp.pointee.codec_id, sampleRate: acp.pointee.sample_rate) {
                acp.pointee.sample_rate = 48000
                if acp.pointee.ch_layout.nb_channels <= 0 {
                    av_channel_layout_default(&acp.pointee.ch_layout, 2)
                }
                if acp.pointee.profile < 0 {
                    acp.pointee.profile = 1  // FF_PROFILE_AAC_LOW
                }
                EngineLog.emit(
                    "[SWHost] audio: live AAC had no codec parameters from the probe; "
                    + "assuming 48 kHz stereo AAC-LC",
                    category: .swPlayback
                )
            }
            do {
                // AE#462 harness (TEST-ONLY): same forced drop the loopback cascade honors.
                if AetherEngine.forceAudioPipelineFailureForTesting {
                    throw NSError(domain: "AetherEngineTestHook", code: -462, userInfo: [
                        NSLocalizedDescriptionKey: "audio pipeline forced to fail (TEST-ONLY)"])
                }
                let made = try await makeAudioProducer(demuxer: dem, streamIndex: resolvedAudioIdx, isLive: isLive)
                // A stop() can land on the suspension above, as on the ones below.
                guard !stopRequested else { made.producer.close(); return }
                self.audioDecoder = made.producer
                self.audioShapingApplied = audioShaping.isActive && made.route == .pcm
                self.audioRoute = made.route
                self.audioRouteCarriesDolbyAtmos = made.route.carriesDolbyAtmos(sourceCodec: acp.pointee.codec_id)
                self.audioStreamIndex = resolvedAudioIdx
                let atb = aStream.pointee.time_base
                self.audioTimeBaseSeconds = atb.den > 0 ? Double(atb.num) / Double(atb.den) : 0
            } catch is CancellationError {
                // stop() landed while the audio route was being chosen; the demuxer is closing.
                return
            } catch {
                EngineLog.emit("[SWHost] audio open failed (\(error)); video-only", category: .swPlayback)
                self.audioStreamIndex = -1
            }
        }
        // AE#462: after the decoder has had its chance, whichever way the block above left it, so a
        // stream present but unusable (no codecpar) classifies as the drop it is rather than as a
        // source without audio.
        self.audioDelivery = Self.audioDelivery(resolvedAudioIndex: resolvedAudioIdx,
                                                decoderOpened: self.audioDecoder != nil,
                                                sourceCarriesAudio: dem.firstAudioStreamIndexByType >= 0,
                                                route: self.audioRoute)
        // #112 rework: capture embedded subtitle stream indices + time bases for the demux
        // loop's subtitle tap dispatch.
        var subIndices: Set<Int32> = []
        var subTimeBases: [Int32: AVRational] = [:]
        for info in dem.subtitleTrackInfos() {
            let idx = Int32(info.id)
            subIndices.insert(idx)
            subTimeBases[idx] = dem.stream(at: idx)?.pointee.time_base ?? AVRational(num: 1, den: 1000)
        }
        self.subtitleStreamIndices = subIndices
        self.subtitleStreamTimeBases = subTimeBases
        // #112: split-PES PGS streams (MPEG-TS) need display-set reassembly in the packet
        // store; the tap sink consults this per packet.
        self.splitDisplaySetSubtitleStreamIndices = dem.splitDisplaySetSubtitleStreamIndices()

        // AudioOutput owns the AVSampleBufferRenderSynchronizer (master clock). Created unconditionally: video-only previously got no clock (frozen frame, currentTime=0). Layer attached in play() after the engine hangs it in the view hierarchy (attaching free-floating fails FigVideoQueueRemote -12080 on tvOS 26+).
        let audioOutput = AudioOutput()
        self.audioOutput = audioOutput
        renderer.setTimeline(audioOutput.timeline)   // AE#395
        self.audioOutput?.volume = volume
        self.audioOutput?.setPresentationOffset(seconds: audioDelaySeconds)   // AE#464
        // The clock waits until frames from its position on are queued, then starts a little ahead
        // (`AudioOutput.videoPrerollSatisfied`, #774, #800). A live stream off the FEL path starts at
        // once, and so does a session playing audio only in the background, which feeds the renderer
        // nothing.
        #if DualLayerDolbyVision
        // The dual-layer decoder releases a base frame that lost its enhancement layer by presentation
        // deadline, which needs this clock.
        if let dual = videoDecoder as? DualLayerVideoDecoder {
            // The fields are read one after another, not as one atomic snapshot, so a clock that moves
            // between them (a start, a rate change) can pair a time with a stale flag. The decoder
            // samples again at its next arrival or sweep, within one sweep delay, which corrects it.
            dual.setRenderClock({ [weak audioOutput] in
                guard let audioOutput else { return nil }
                return .init(seconds: audioOutput.currentTimeSeconds, running: audioOutput.rate > 0,
                             prerolling: audioOutput.prerollPending, rate: Double(audioOutput.rate))
            }, frameRate: AetherEngine.detectFrameRate(stream: vStream))
        }
        #endif
        let prerollRenderer = renderer
        let prerollLive = isLive
        self.audioOutput?.videoPrerollSatisfied = { [weak self] clock in
            guard self?.backgroundAudioOnly != true else { return nil }
            return prerollRenderer.prerollSatisfied(clock: clock, live: prerollLive)
        }
        // A decoder still working up to the target holds the clock past the plain timeout (#800).
        let prerollDecoder = videoDecoder
        self.audioOutput?.videoPrerollProgress = { prerollDecoder.framesDecoded }
        self.audioOutput?.onPrerollTransition = { [weak self] transition in
            self?.onClockHoldTransition?(transition)
        }
        // dav1d decoding AV1: seeks land on keyframes (`SWKeyframeSnap`).
        snapsSeeksToKeyframes = SWKeyframeSnap.enabled && videoDecoder is SoftwareVideoDecoder
            && vStream.pointee.codecpar?.pointee.codec_id == AV_CODEC_ID_AV1
        snapKeyframeSeconds = []
        refreshSnapKeyframes()
        // AE#395: the route this session plays into, the counterpart of the native host's line. Without
        // it a silent software session on a long-latency route and an audible one on HDMI log the same.
        if let route = AudioRouteDescription.current() {
            EngineLog.emit("[SoftwarePlaybackHost] audioRoute \(route) (session start, live=\(isLive))",
                           category: .swPlayback)
        }

        // Reset the live feeder state for the new session.
        resetFeederState()

        // The session zero a cold load predicts from the source's origin, the way a resume derives it.
        // Set for every non-live source, not only a resume: a seek or a scrub still before the first play
        // converts with it, and the demux loop only resolves the real zero when it first arms the clock
        // (a pre-play seek arms the clock itself, so the loop never would). Reported, so the engine's
        // chapter axis, harvest anchors and stills all read the same zero.
        if !isLive {
            let predictedZero = SWClockAnchorPolicy.resumeSessionZero(sourceOriginSeconds: dem.resolvedSourceStartOrigin)
            if predictedZero != clockSessionZero {
                clockSessionZero = predictedZero
                onClockSessionZero?(predictedZero)
            }
        }

        if let start = startPosition, start.isFinite, start > 0 {
            // AE#724: the anchor is a session-axis position; on an offset-origin source it is carried
            // over before it reaches the demuxer, the skip threshold and the clock, as a seek's is.
            let zero = clockSessionZero
            let sourceStart = SWClockAnchorPolicy.sourceSeconds(forSession: start, sessionZeroSeconds: zero)
            // #254: same off-main, deadline-bounded reposition the transport seek uses. A resume into a
            // remote source that has to scan for its landing would otherwise block the main thread here.
            let outcome = await reposition(dem, sourceStart, Self.seekBudgetSeconds, seekQueue,
                                           { [weak self] in self?.stopRequested ?? true })
            // Like the others (the audio route choice, the cache setup, the primer wait), this
            // suspension is a place a stop() can land mid-load. Arming the clock and publishing isReady on a session already torn down would
            // hand the engine a host it has stopped.
            guard !stopRequested, !Task.isCancelled, outcome != .superseded else {
                throw CancellationError()
            }
            EngineLog.emit("[SWReposition] flags=\(outcome == .landed ? 0 : 1)", category: .swPlayback)
            guard outcome == .landed else { throw HostError.repositionFailed }
            // Mirror seek() skip-PTS + clock alignment so demux drops pre-keyframe frames and synchronizer starts at the resume offset.
            let startTime = CMTime(seconds: sourceStart, preferredTimescale: 90000)
            videoDecoder.skipUntilPTS = startTime
            renderer.setSkipThreshold(startTime)
            initialClockTime = startTime
            currentTime = start
            sourceClockSeconds = sourceStart
        } else {
            initialClockTime = .zero
        }

        // A local path is left on the direct loop: the spool exists to avoid a second trip to a
        // SOURCE, and re-reading a file is a page-cache hit. Measured on a file:// session, the
        // cache wrote 14 MB of temporary chunks in 25 s (the source bitrate) for a seek that would
        // have cost nothing anyway.
        if !isLive, dem.isSourceSeekable, !dem.readsSourceDirectly {
            let video = SoftwarePacketReadAhead.Stream(index: videoStreamIndex,
                                                       numerator: vtb.num, denominator: vtb.den)
            let audio: SoftwarePacketReadAhead.Stream? = audioStreamIndex >= 0
                ? dem.stream(at: audioStreamIndex).map {
                    .init(index: audioStreamIndex, numerator: $0.pointee.time_base.num,
                          denominator: $0.pointee.time_base.den,
                          audioTiming: Self.audioPacketTiming($0.pointee.codecpar))
                } : nil
            let initialSourceClock = initialClockTime.seconds
            let videoReorderDepth = Self.presentationReorderDepth(codecID: vCodecID)
            let anchorsOnLastKeyframe = snapsSeeksToKeyframes
            let cacheResult = await BlockingWork.detached(priority: .utility) { () throws -> (SoftwarePacketReadAhead, RetentionClaims.Claim?)? in
                let segments = HLSVideoEngine.clampedForwardWindow(forwardBufferSegments)
                guard let (fifo, bytes, claim) = try Self.makePacketStore(
                    storage: packetCacheStorage, forwardSegments: segments,
                    requestedBytes: sessionCacheByteBudget) else { return nil }
                let readAhead = SoftwarePacketReadAhead(
                    video: video, audio: audio, byteBudget: bytes,
                    forwardSeconds: Double(segments) * 4,
                    initialSourceClock: initialSourceClock, fifo: fifo,
                    videoReorderDepth: videoReorderDepth, cacheTiming: cacheTiming,
                    anchorsOnLastKeyframe: anchorsOnLastKeyframe
                ) { isCurrent in
                    guard let packet = try dem.readPacket(isCurrent: isCurrent) else { return nil }
                    defer { av_packet_unref(packet); av_packet_free_safe(packet) }
                    return try SoftwareStoredPacket(copying: packet)
                }
                claim?.track { [weak readAhead] in readAhead?.snapshot.residentBytes ?? 0 }
                return (readAhead, claim)
            }.result
            let readAhead: SoftwarePacketReadAhead?
            switch cacheResult {
            case .success(let cache):
                readAhead = cache?.0
                if !stopRequested, let claim = cache?.1 ?? nil { retentionClaims.append(claim) }
            case .failure:
                // A cache-directory failure must not stop a source that the old direct loop can
                // still play. Runtime spool corruption is explicit, never silently skipped.
                EngineLog.emit("[SWHost] packet cache unavailable; retaining direct playback", category: .swPlayback)
                readAhead = nil
            }
            guard !stopRequested else { readAhead?.close(); return }
            vodPacketReadAhead = readAhead
            readAhead?.start()
        }

        // The Atmos decoder registration started when the route was chosen and has run alongside the
        // resume seek and the cache setup; only what is left of its window is waited out here, and
        // only on the compressed-JOC route (`AtmosDecoderPrimer`). The first enqueue is after load().
        await Self.awaitAtmosPrimer(for: audioRoute, wait: atmosPrimerWait)
        guard !stopRequested else { return }

        startTimeUpdates()
        isReady = true
    }

    /// How the host waits for the Atmos decoder registration. Replaced by tests.
    var atmosPrimerWait: @MainActor () async -> Void = { await AtmosDecoderPrimer.shared.ensurePrimed() }

    /// Waits for the registration on the route that needs it and never on any other.
    static func awaitAtmosPrimer(for route: SoftwareAtmosRoute, wait: @MainActor () async -> Void) async {
        guard route == .compressedEAC3JOC else { return }
        await wait()
    }

    // MARK: - Transport

    func play() {
        guard !stopRequested, failure == nil else { return }
        renderer.recoverAfterSuspensionIfNeeded()
        audioOutput?.setPlaybackEnabled(true)
        // Resume after pause(): gate on clockArmed, not demuxLoopStarted. A rate change on the
        // un-anchored synchronizer (no media at its clock time yet) wedges the delayed-rate-change
        // machinery permanently frozen; the arming seekClock applies the current lastRate (#107).
        switch RendererClockResume.onPlay(
            hostPaused: pausedByHost,
            clockArmed: clockArmed,
            // A clock a preroll holds (#774) is about to start, not stalled.
            synchronizerRate: audioOutput?.prerollPending == true ? lastRate : audioOutput?.rate ?? 0,
            rebuffering: demuxDiag.snapshot.rebuffering,
            parkedAtEndOfMedia: didParkClockAtEnd
        ) {
        case .resumeHostPause:
            pausedByHost = false
            _ = takePausedBeforeFirstFrame()
            if clockArmed {
                audioOutput?.setRate(lastRate)
            }
        case .restartStalledClock:
            restartStalledClock()
        case .none:
            break
        }
        if !demuxLoopStarted, let aOut = audioOutput {
            aOut.attachVideoLayer(renderer.displayLayer)
        }
        if !demuxLoopStarted {
            demuxLoopStarted = true
            startDemuxLoop()
        }
        // Cold start: demux loop arms the clock on first decoded audio sample; don't eager-start.
        rate = lastRate
        isPlaying = true
        inFlightSeekResumeIntent = true
    }

    private var demuxLoopStarted: Bool = false

    /// #95 audio tap: mirrors every decoded audio CMSampleBuffer to the tap (nil = tap off).
    /// Set/cleared on the main actor by AetherEngine+AudioTap; read per packet on the demux and
    /// feeder threads (same unsynchronized-flag pattern as `_isPlaying`; worst case one buffer
    /// reaches a just-removed sink).
    nonisolated(unsafe) var audioTapSink: (@Sendable (CMSampleBuffer) -> Void)?

    /// #112 rework subtitle tap: the demux loop hands every embedded subtitle packet to this
    /// sink (nil = tap off), which copies the payload into the session's SubtitlePacketStore.
    /// Same unsynchronized-flag pattern as `audioTapSink`; the sink copies synchronously, so
    /// the packet pointer never escapes the demux thread. The trailing Bool marks packets of
    /// split-PES PGS streams (MPEG-TS) that need display-set reassembly in the store.
    nonisolated(unsafe) var subtitleTapSink: (@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational, Bool) -> Void)?

    /// #112 rework: embedded subtitle stream indices + time bases, captured at load before the
    /// demux loop starts (the SW host applies no stream discard, so these packets already flow).
    private(set) var subtitleStreamIndices: Set<Int32> = []
    private(set) var subtitleStreamTimeBases: [Int32: AVRational] = [:]
    /// #112: streams whose PGS display sets arrive split across PES packets (MPEG-TS) and need
    /// reassembly in the packet store. Captured at load, read by the tap sink per packet.
    private(set) var splitDisplaySetSubtitleStreamIndices: Set<Int32> = []

    /// Host's ASS markup preference for overlay decoders (mirrors the HLS session flag).
    var preserveASSMarkupForSubtitleTap = false
    var teletextPageForSubtitleTap: Int? = nil
    var deinterlaceConfig = DeinterlaceConfig()

    /// #112 rework: build an overlay decoder for any embedded subtitle stream, seeded from the
    /// session's video dims like the HLS tap routes. The drainer owns the returned decoder.
    func makeOverlayDecoder(streamIndex: Int32) -> EmbeddedSubtitleDecoder? {
        guard let dem = demuxer, let stream = dem.stream(at: streamIndex) else { return nil }
        let vpar = dem.stream(at: videoStreamIndex)?.pointee.codecpar
        let w = vpar?.pointee.width ?? 1920
        let h = vpar?.pointee.height ?? 1080
        return EmbeddedSubtitleDecoder(stream: stream,
                                       sourceVideoWidth: w > 0 ? w : 1920,
                                       sourceVideoHeight: h > 0 ? h : 1080,
                                       preserveASSMarkup: preserveASSMarkupForSubtitleTap,
                                       teletextPage: teletextPageForSubtitleTap)
    }

    #if DEBUG
    /// AE#549 drill: stop the master clock the way an interrupted audio session does, leaving
    /// `pausedByHost` alone. Nothing outside the drill may do this.
    func stallClockForTesting() -> Bool {
        guard let aOut = audioOutput, clockArmed else { return false }
        aOut.pause()
        return true
    }

    var clockRateForTesting: Float? { audioOutput?.rate }

    func installClockOutputForTesting(_ output: AudioOutput, armed: Bool = false) {
        audioOutput = output
        clockArmed = armed
    }

    func finishClockOutputForTesting() {
        didReachEnd = true
        isPlaying = false
    }
    #endif

    /// The latch is synchronous for the feeder; transport reconciliation shares play/pause's actor.
    func makeClockArmCallback(audioOutput aOut: AudioOutput?) -> @Sendable () -> Void {
        { [weak self] in
            guard let self, let aOut else { return }
            let generation = self.seekGeneration
            let revision = aOut.clockCommandRevision
            self.clockArmed = true
            // A transport change before arming still needs correction, but the feeder must not
            // restart the clock between pause() stopping it and publishing isPlaying=false.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.audioOutput === aOut,
                      self.admitsRead(generation: generation) else { return }
                // EOF may drain its queued audio tail, but an explicit pre-arm pause still wins.
                guard self.pausedByHost || (!self.didParkClockAtEnd && !self.didReachEnd) else { return }
                if !self.isPlaying || self.pausedBeforeFirstFrame {
                    // A pending preroll can own a future start even while the clock reads zero.
                    aOut.setRate(0, ifRevision: revision)
                } else if let rate = PausedFirstFrame.rateCorrectionAtArm(
                    transportPlaying: true, pausedBeforeFirstFrame: false,
                    synchronizerRate: aOut.synchronizer.rate, lastRate: self.lastRate) {
                    // A later rebuffer pause, seek or rate command owns the output now. The
                    // comparison and correction are atomic with those commands inside AudioOutput.
                    aOut.setRate(rate, ifRevision: revision)
                }
            }
        }
    }

    /// AE#549: re-anchor a master clock that stopped without a pause of ours, where it stands.
    ///
    /// The one re-anchor this path can make: the demuxer is an audio lead ahead of the clock by now
    /// and the sources this happens to are the ones that cannot seek backwards, so moving the clock
    /// anywhere but onto itself would either skip content or ask for a rewind the source refuses.
    /// The rate and the flush count go in the line because they are what the next field log needs to
    /// separate a zeroed rate from a timebase that stalled under a deactivated audio session.
    private func restartStalledClock() {
        guard let aOut = audioOutput else { return }
        EngineLog.emit(
            "[SWHost] AE#549: the clock stopped without a pause of ours; restarting at "
            + "\(String(format: "%.3f", aOut.currentTimeSeconds))s rate=\(lastRate) "
            + "(was \(aOut.rate), renderer self-flushes=\(aOut.automaticFlushCount))",
            category: .swPlayback
        )
        aOut.seekClock(to: aOut.currentTime, rate: lastRate)
    }

    func pause() {
        // Latch even before arming: stale decoder and rebuffer work cannot restart the clock
        // after this pause while the host publishes its transport state.
        audioOutput?.setPlaybackEnabled(false)
        pausedByHost = true
        rate = 0
        if PausedFirstFrame.holdsForFirstFrame(loopsStarted: demuxLoopStarted, framesEnqueued: framesEnqueued),
           !stopRequested {
            pausedBeforeFirstFrame = true
            EngineLog.emit(
                "[SWHost] #104 paused before the first frame: the loops keep reading at a stopped clock until it presents",
                category: .swPlayback
            )
        }
        isPlaying = false
        inFlightSeekResumeIntent = false
    }

    /// Sodalite#104 round 4: the first frame of a session paused before it is in. Moves the stopped clock
    /// onto it where it stands before the frame (`PausedFirstFrame.presentationAnchor`). On the main actor,
    /// so a `play()` either runs first and finds the flag gone, or runs after and restarts this clock.
    nonisolated private func presentFirstFrameUnderPause(pts: Double, generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopRequested, !self.isPlaying, self.pausedByHost,
                  generation == self.seekGeneration, let aOut = self.audioOutput else { return }
            let clock = aOut.currentTimeSeconds
            let anchor = PausedFirstFrame.presentationAnchor(
                framePTS: pts, clockArmed: self.clockArmed, clockSeconds: clock)
            if let anchor {
                aOut.seekClock(to: CMTime(seconds: anchor, preferredTimescale: 90000), rate: 0)
            }
            EngineLog.emit(
                "[SWHost] #104 first frame in under the pause: pts=\(String(format: "%.3f", pts))s "
                + "clock=\(String(format: "%.3f", clock))s"
                + (anchor != nil ? ", stopped clock moved onto the frame" : ", presented where the clock stands"),
                category: .swPlayback
            )
        }
    }

    /// AE#374: stop the master clock on the last sample instead of letting it free-run past the end.
    ///
    /// `.ended` is terminal, so nothing will consume the clock again, but the synchronizer used to keep
    /// its rate: `currentTime` then walked past `duration` without bound (measured: 20.13 s published on
    /// a 12.0 s source, against a native session that parks on 11.97 s and stays there). Deferred by the
    /// audio still queued ahead of the playhead, because parking the synchronizer stops its renderers
    /// too and an immediate park would cut that tail. `pausedByHost` stays false: the viewer did not
    /// pause this, the source ran out.
    private func parkClockAtEndOfMedia() {
        guard !didParkClockAtEnd else { return }
        didParkClockAtEnd = true
        guard clockArmed, let aOut = audioOutput else { return }
        let tail = SoftwareEndOfMediaClock.tailPlayoutSeconds(
            clockSeconds: aOut.currentTimeSeconds,
            lastAudioPts: demuxDiag.snapshot.lastAudioPts
        )
        guard tail > 0 else { return parkClockNow() }
        // The deferral aims at the end of the queued tail; a task that runs late must not park past it.
        let target = aOut.currentTimeSeconds + tail
        let generation = seekGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(tail * 1_000_000_000))
            guard let self, self.admitsRead(generation: generation) else { return }
            self.parkClockNow(notAfter: target)
        }
    }

    private func parkClockNow(notAfter latest: Double = .infinity) {
        guard !stopRequested, let aOut = audioOutput else { return }
        aOut.pause(notAfter: latest)
        rate = 0
        EngineLog.emit(
            "[SWHost] end of media: clock parked at "
            + "\(String(format: "%.3f", aOut.currentTimeSeconds))s",
            category: .swPlayback
        )
    }

    /// Background-enter (iOS keepalive): keep audio flowing, stop feeding video. The demux loop reads the flag.
    func enterBackgroundAudioOnly() {
        guard !backgroundAudioOnly else { return }
        backgroundAudioOnly = true
        EngineLog.emit("[SWHost] background audio-only: dropping video, audio keeps playing",
                       category: .swPlayback)
    }

    /// Foreground return: resume video. Flush the video decoder + renderer (NOT audio) so video resyncs at the
    /// next keyframe; the synchronizer is already at the audio time, so the keyframe presents promptly. Order
    /// matters: while backgroundAudioOnly is still true the loop drops video and never touches videoDecoder /
    /// renderer, so flushing here from the main actor cannot race the demux queue. Clear the flag last.
    ///
    /// AE#739: the hardware session is rebuilt unconditionally. A screen lock invalidates it, and in
    /// audio-only mode nothing decodes video, so nothing could have noticed. Called on every foreground
    /// return, so a recovery owed from a loss seen outside audio-only mode (a PiP session, a refused
    /// rebuild) is paid here as well.
    func exitBackgroundAudioOnly() {
        // A foreground return is a new episode: the retries spent before it do not count against this one.
        videoSessionRetry.reset()
        if backgroundAudioOnly {
            flushVideoForRecovery(removingDisplayedImage: true)
            let rebuilt = (videoDecoder as? any VideoSessionRebuilding)?.rebuildSession()
            if rebuilt == false { videoSessionRecoveryOwed = true }
            if rebuilt == true { videoSessionRetry.reset() }
            backgroundAudioOnly = false
            EngineLog.emit(
                "[SWHost] background audio-only left, video resumes at the next keyframe"
                + (rebuilt.map { ", hardware session rebuilt=\($0)" } ?? ""),
                category: .swPlayback)
        }
        let repositioned = videoSessionRecoveryOwed ? recoverVideoSession() : false
        // The video queue failed while video was not wanted. It was flushed above and resumes at the
        // next keyframe; whether that is soon enough is the same question as for a failure in the
        // foreground, so it goes through the same rule. An ignored answer (a seek already running) drops
        // the debt on purpose: that seek repositions the session anyway.
        if videoQueueFlushOwed {
            videoQueueFlushOwed = false
            if !repositioned { handleFlushTrigger(.videoQueueRequiresFlush) }
        }
    }

    #if DEBUG
    func invalidateVideoSessionForTesting() -> Bool {
        #if DualLayerDolbyVision
        if let dual = videoDecoder as? DualLayerVideoDecoder {
            dual.invalidateSessionsForTesting()
            return true
        }
        #endif
        guard let hw = videoDecoder as? HardwareVideoDecoder else { return false }
        hw.invalidateSessionForTesting()
        return true
    }
    #endif

    /// AE#739: the hardware decoder reported its session invalidated by the system. In audio-only mode
    /// video is not wanted yet, so the recovery is owed to the foreground return.
    private func handleVideoSessionLost() {
        guard !stopRequested else { return }
        if backgroundAudioOnly {
            videoSessionRecoveryOwed = true
            EngineLog.emit("[SWHost] AE#739 video session lost in the background, recovery owed to the foreground return",
                           category: .swPlayback)
            return
        }
        recoverVideoSession()
    }

    /// A keyframe was fed while the session is lost. A rebuild that VideoToolbox refused is retried here, once
    /// per keyframe: quickly for the first `VideoSessionRetryPolicy.maxAttempts`, then every
    /// `VideoSessionRetryPolicy.slowSpacing` seconds, so a session the system gives back later still recovers
    /// without a load. Nothing is spent while the picture is off screen (see `appInBackground`), nor while the
    /// first rebuild after a loss is still in flight. No failure is published for a refused rebuild: the
    /// engine's `.error` state is terminal until the next load, so a later rebuild could not clear it.
    private func handleKeyframeWhileSessionLost() {
        guard !stopRequested, !backgroundAudioOnly, !appInBackground else { return }
        switch videoSessionRetry.onKeyframe(owed: videoSessionRecoveryOwed, now: ProcessInfo.processInfo.systemUptime) {
        case .none:
            break
        case .retry(let attempt):
            EngineLog.emit(
                "[SWHost] AE#739 video session still lost at a keyframe, rebuild retry \(attempt)",
                category: .swPlayback)
            recoverVideoSession()
        }
    }

    /// The engine reports whether the picture is off screen (backgrounded with no picture-in-picture window).
    /// Coming back on screen is a new episode for the keyframe retries, as `exitBackgroundAudioOnly()` says,
    /// so the budget spent before it does not count against the next loss.
    func noteAppInBackground(_ inBackground: Bool) {
        if appInBackground && !inBackground { videoSessionRetry.reset() }
        appInBackground = inBackground
    }

    /// Rebuild the session, then reposition to the playhead: the demuxer lands on the keyframe before it
    /// and the seek's skip threshold hides the preroll, so the picture returns on the frame the audio is
    /// at instead of freezing until the next keyframe. A live source without a rewind ring cannot go
    /// back and picks up at the next keyframe. A refused rebuild stays owed to the next foreground return.
    @discardableResult
    private func recoverVideoSession() -> Bool {
        guard !stopRequested, let hw = videoDecoder as? any VideoSessionRebuilding else {
            videoSessionRecoveryOwed = false
            return false
        }
        guard hw.rebuildSession() else {
            videoSessionRecoveryOwed = true
            return false
        }
        videoSessionRecoveryOwed = false
        videoSessionRetry.reset()
        if isLive && dvrRing == nil {
            EngineLog.emit("[SWHost] AE#739 video session rebuilt on a live source, resuming at the next keyframe",
                           category: .swPlayback)
            return false
        }
        let target = currentTime
        EngineLog.emit(
            "[SWHost] AE#739 video session rebuilt, repositioning to the playhead at "
            + "\(String(format: "%.3f", target))s",
            category: .swPlayback)
        Task { @MainActor [weak self] in
            await self?.seek(to: target)
        }
        return true
    }

    // MARK: - Flush recovery

    /// The video queue (or the audio renderer) was flushed or failed by the system and holds none of what
    /// the demuxer already handed over. See `FlushRecoveryPolicy` for the rules: audio keeps playing and
    /// the picture resumes at the next keyframe, unless that keyframe is further away than the audio
    /// lead, in which case the recovery is a seek to the playhead.
    ///
    /// Main actor only, like every transport call here. The renderers report from arbitrary threads and
    /// hop here, so a trigger runs after any seek the user already started has set its in-flight flag.
    private var flushRecoveryPending = false
    /// AE#739 sibling: a video recovery the background could not pay. Paid by `exitBackgroundAudioOnly()`.
    private var videoQueueFlushOwed = false
    /// Recovery repositions that have finished, whatever they landed on. Diagnostics and tests.
    private(set) var flushRecoveriesCompleted = 0
    /// What the last video recovery was, and how many frames the clock had passed on a healthy queue when it ran.
    private var lastVideoRecovery: (action: FlushRecoveryPolicy.Action, presentedFrames: Int)?
    /// When the last reposition was started (`ProcessInfo.systemUptime`); the backoff rule's input.
    private var lastRepositionUptime: Double?
    /// The shortest time between two repositions; tests shorten it.
    private var repositionBackoffSeconds = FlushRecoveryPolicy.repositionBackoffSeconds
    /// The audio renderer's status as the last poll saw it, so a failure is acted on once, when it begins.
    private var audioRendererWasFailed = false
    /// When the audio flushes of the last `FlushRecoveryPolicy.audioFlushWindowSeconds` ran (`ProcessInfo.systemUptime`).
    private var audioFlushUptimes: [Double] = []
    /// The last few decisions, newest last, for the diagnostic line and the tests.
    private(set) var flushRecoveryLog: [(trigger: FlushRecoveryTrigger, action: FlushRecoveryPolicy.Action)] = []
    /// Keyframes read and not yet handed to the decoder; see `SWKeyframeLedger`.
    private let keyframeLedger = SWKeyframeLedger()

    private func armQueueFlushObserver() {
        renderer.setQueueFlushObserver { [weak self] reason in
            Task { @MainActor [weak self] in self?.handleFlushTrigger(reason.trigger) }
        }
    }

    /// The audio the synchronizer's clock has still to play: what the feed has queued, less the clock.
    private func audioLeadSeconds(clock: Double) -> Double {
        let fedUntil = Self.diagAudioMarker(
            demuxLoopPts: demuxDiag.snapshot.lastAudioPts,
            dvrPumpPts: audioLookahead.lastFedAudioPTS,
            isDVRSession: isLive && dvrRing != nil)
        guard fedUntil.isFinite, clock.isFinite else { return 0 }
        return max(0, fedUntil - clock)
    }

    private func flushRecoveryState() -> FlushRecoveryPolicy.State {
        var state = FlushRecoveryPolicy.State()
        state.stopRequested = stopRequested
        state.hasSource = demuxer != nil && isReady && failure == nil
        state.seekInFlight = seekInFlight
        state.recoveryPending = flushRecoveryPending
        state.backgroundAudioOnly = backgroundAudioOnly
        let clock = audioOutput?.currentTimeSeconds ?? .nan
        // Before the first frame, any frame handed to a healthy queue is enough: it holds nothing worth
        // recovering otherwise. After a recovery the storm rule wants more than an enqueue the queue
        // may still refuse: a frame the clock has passed while the queue stayed healthy.
        state.firstFramePresented = renderer.acceptedFrameCount > 0
        state.canReposition = !(isLive && dvrRing == nil)
        if let last = lastVideoRecovery {
            state.framesPresentedSinceLastVideoRecovery =
                renderer.presentedFrameCount(clockSeconds: clock) - last.presentedFrames
            state.lastVideoRecovery = last.action
        }
        state.repositionBackoffSeconds = repositionBackoffSeconds
        if let at = lastRepositionUptime {
            state.secondsSinceLastReposition = ProcessInfo.processInfo.systemUptime - at
        }
        let now = ProcessInfo.processInfo.systemUptime
        audioFlushUptimes.removeAll { now - $0 >= FlushRecoveryPolicy.audioFlushWindowSeconds }
        state.audioFlushesInWindow = audioFlushUptimes.count
        state.audioLeadSeconds = audioLeadSeconds(clock: clock)
        if clock.isFinite, let keyframe = keyframeLedger.nextKeyframe {
            state.videoGapSeconds = max(0, keyframe - clock)
        }
        return state
    }

    /// The position the recovery returns to, on the session axis `seek(to:)` takes. The synchronizer is
    /// read directly on VOD (the published `currentTime` lags it by up to a tick); a live DVR session
    /// keeps its own offset and uses the published value.
    private func recoveryPlayheadSeconds() -> Double {
        if !isLive, let raw = audioOutput?.currentTimeSeconds, raw.isFinite, raw >= 0 {
            let zero = clockSessionZero
            return zero > 0 ? max(0, raw - zero) : raw
        }
        return currentTime
    }

    /// Flushes the video decoder and the video queue, with the audio left alone, and puts the skip
    /// threshold at the playhead. The decoder restarts on a keyframe that can sit past the playhead,
    /// and the renderer's floor, restarted from nothing, would start at that
    /// keyframe: the B-frames that follow it in decode order but precede it in display order would
    /// then arrive below it. A floor at the playhead is below every frame still to be shown (the start
    /// a seek gives it too), and frames under it are late by definition.
    ///
    /// The demux thread keeps handing packets to the decoder while this runs, and what follows the flush
    /// is usually delta frames of a group of pictures whose keyframe the flush just discarded. The
    /// keyframe gate makes the demux thread drop video until the next keyframe; it is raised before the
    /// flush, so no delta frame is handed over between the two, and again after it, so a keyframe handed
    /// over in between and discarded by the flush does not end the wait.
    private func flushVideoForRecovery(removingDisplayedImage: Bool) {
        keyframeLedger.requireKeyframe()
        let clock = audioOutput?.currentTimeSeconds
        let threshold = clock.flatMap { $0.isFinite && $0 >= 0 ? CMTime(seconds: $0, preferredTimescale: 90000) : nil }
        videoDecoder.flush()
        renderer.flush(removingDisplayedImage: removingDisplayedImage, skipThreshold: threshold)
        if let threshold { videoDecoder.skipUntilPTS = threshold }
        // The second raise covers a keyframe the demux thread handed over after the first raise and
        // before the flush above: the gate opened for it, the flush discarded it, and the delta frames
        // behind it must not follow. The cost is that a keyframe decoded under the new epoch in this
        // short window is gated too, one extra group of pictures with the old picture held, never garbage.
        keyframeLedger.requireKeyframe()
    }

    #if DEBUG
    /// Tests drive the recovery through the same entry the renderers use, without a session that has
    /// decoded a frame.
    var videoQueueFlushOwedForTesting: Bool { videoQueueFlushOwed }
    var audioRendererForTesting: AVSampleBufferAudioRenderer? { audioOutput?.renderer }
    var videoRendererForTesting: SampleBufferRenderer { renderer }
    var keyframeLedgerForTesting: SWKeyframeLedger { keyframeLedger }
    func setLiveForTesting(_ live: Bool) { isLive = live }
    func setVideoDecoderForTesting(_ decoder: any VideoDecodingPipeline) { videoDecoder = decoder }
    func seekClockForTesting(to seconds: Double) {
        audioOutput?.seekClock(to: CMTime(seconds: seconds, preferredTimescale: 90000), rate: 0)
    }
    func setAudioFedUntilForTesting(_ pts: Double) {
        demuxDiag.update(lastAudioPts: pts, parked: 0, rebuffering: false, generation: .max)
    }
    /// A feed marker written under the current generation, as the demux loop writes it on every iteration.
    func setAudioFedUntilUnderCurrentGenerationForTesting(_ pts: Double) {
        demuxDiag.update(lastAudioPts: pts, parked: 0, rebuffering: false, generation: seekGeneration)
    }
    var audioFedUntilForTesting: Double { demuxDiag.snapshot.lastAudioPts }
    var recoveryPendingForTesting: Bool { flushRecoveryPending }
    func setRepositionBackoffForTesting(_ seconds: Double) { repositionBackoffSeconds = seconds }
    var audioAutomaticFlushCountForTesting: Int? { audioOutput?.automaticFlushCount }
    /// A session the system has invalidated and whose rebuild is owed, as `handleVideoSessionLost()` leaves it.
    func setVideoSessionRecoveryOwedForTesting() { videoSessionRecoveryOwed = true }
    func keyframeWhileSessionLostForTesting() { handleKeyframeWhileSessionLost() }
    /// A budget with every quick retry spent, so the next keyframe waits out the slow spacing.
    func spendVideoSessionRetriesForTesting() {
        var policy = VideoSessionRetryPolicy()
        for i in 0..<VideoSessionRetryPolicy.maxAttempts {
            _ = policy.onKeyframe(owed: true, now: Double(i) * VideoSessionRetryPolicy.minSpacing)
        }
        videoSessionRetry = policy
    }
    var videoSessionRetryAttemptsForTesting: Int { videoSessionRetry.attempts }
    var appInBackgroundForTesting: Bool { appInBackground }
    #endif

    @discardableResult
    func handleFlushTrigger(_ trigger: FlushRecoveryTrigger) -> FlushRecoveryPolicy.Action {
        let state = flushRecoveryState()
        let action = FlushRecoveryPolicy.decide(trigger, state)
        guard action != .ignore else { return action }
        flushRecoveryLog.append((trigger, action))
        if flushRecoveryLog.count > 16 { flushRecoveryLog.removeFirst(flushRecoveryLog.count - 16) }
        // A deferral did nothing yet; counting it would turn the recovery it is owed to into a repeat.
        switch action {
        case .reposition, .flushVideoOnly:
            lastVideoRecovery = (action, renderer.presentedFrameCount(clockSeconds: audioOutput?.currentTimeSeconds ?? .nan))
            if action == .reposition { lastRepositionUptime = ProcessInfo.processInfo.systemUptime }
        default:
            break
        }
        switch action {
        case .ignore:
            break
        case .deferToForeground:
            videoQueueFlushOwed = true
            EngineLog.emit("[SWHost] flush recovery (\(trigger.rawValue)): video not wanted now, paid on the foreground return",
                           category: .swPlayback)
        case .flushVideoOnly:
            flushVideoForRecovery(removingDisplayedImage: false)
            EngineLog.emit("[SWHost] flush recovery (\(trigger.rawValue)): video queue and decoder flushed, resuming at the next keyframe"
                           + (state.canReposition ? "" : " (live, no rewind)"),
                           category: .swPlayback)
        case .flushAudioOnly:
            audioFlushUptimes.append(ProcessInfo.processInfo.systemUptime)
            audioOutput?.flush()
            // The flush emptied the queue the diagnostic's audio marker describes (as a seek's does), so
            // the lead read from it would stay overstated until the feed wrote a new one; the demux
            // loop republishes its own marker every iteration, so the stale value itself is retired.
            demuxDiag.audioQueueEmptied()
            EngineLog.emit("[SWHost] flush recovery (\(trigger.rawValue)): audio queue flushed",
                           category: .swPlayback)
        case .reposition:
            let target = recoveryPlayheadSeconds()
            flushRecoveryPending = true
            EngineLog.emit(
                "[SWHost] flush recovery (\(trigger.rawValue)): repositioning to the playhead at "
                + "\(String(format: "%.3f", target))s (next keyframe "
                + "\(state.videoGapSeconds.map { String(format: "%.1fs", $0) } ?? "not read") ahead, audio lead "
                + "\(String(format: "%.1fs", state.audioLeadSeconds)))",
                category: .swPlayback)
            Task { @MainActor [weak self] in
                await self?.seek(to: target)
                self?.flushRecoveryPending = false
                self?.flushRecoveriesCompleted += 1
            }
        }
        return action
    }

    /// The audio renderer's status, read on the time-update cadence: a failed renderer posts nothing,
    /// so its status is the only witness. Acted on when the failure begins, not on every read of it.
    func pollAudioRendererStatus(_ status: AVQueuedSampleBufferRenderingStatus) {
        guard status == .failed else {
            audioRendererWasFailed = false
            return
        }
        guard !audioRendererWasFailed else { return }
        // Latched only once the failure was acted on: a trigger the rule ignored (a seek in flight, a
        // recovery pending, no source yet) is still owed, and the next poll offers it again.
        if handleFlushTrigger(.audioRendererFailed) != .ignore { audioRendererWasFailed = true }
    }

    func setRate(_ newRate: Float) {
        // #436: zero is a pause, not a speed. `lastRate` is what the clock arms at and what a
        // rebuffer resumes at, so storing a zero there brings the session back frozen while it
        // reports itself playing. Park it the way pause() does and keep the last real speed.
        if newRate == 0 {
            pause()
            return
        }
        lastRate = newRate
        rate = newRate
        // Same rule as play(): never rate-change the un-anchored synchronizer. A host setRate
        // right after load(), before the demux/feeder loop armed the clock, wedged the
        // delayed-rate-change machinery and froze live sessions on the first frame; the arming
        // seekClock picks up lastRate instead (#107).
        if clockArmed {
            audioOutput?.setRate(newRate)
        }
    }

    /// AE#464: set the audio presentation offset. Positive delivers audio later relative to video.
    ///
    /// Only the stamp changes; nothing is flushed here. The samples already decoded (up to
    /// `AudioLookaheadPolicy.targetLeadSeconds` of them on the decoupled VOD arm) still carry the
    /// previous offset, so a caller that wants the change to be audible now re-anchors at the
    /// playhead afterwards. `AetherEngine.setAudioDelay` does exactly that.
    func setAudioDelay(_ seconds: Double) {
        audioDelaySeconds = seconds
        audioOutput?.setPresentationOffset(seconds: seconds)
    }

    func setResumeRate(_ rate: Float) {
        guard rate != 0 else { return }
        lastRate = rate
    }

    /// Reads the index's video keyframes for `SWKeyframeSnap` off the main actor and keeps them for the
    /// next seek. Never read at the seek itself: `indexedKeyframes` takes the demuxer's access lock,
    /// which a slow remote read holds (#254). Matroska reads its Cues only when the demuxer
    /// repositions, so the list is read again after every landing; until then the packet cache's
    /// retained keyframes are the ones a seek can snap to (`SWKeyframeSnap.candidates`).
    private func refreshSnapKeyframes() {
        guard snapsSeeksToKeyframes, let dem = demuxer else { return }
        let streamIndex = videoStreamIndex
        let timeBase = videoTimeBaseSeconds
        Task { [weak self] in
            let keys = await BlockingWork.detached(priority: .utility) {
                dem.indexedKeyframes(streamIndex: streamIndex).map { Double($0) * timeBase }.sorted()
            }.value
            guard let self, self.demuxer === dem else { return }
            if keys.count != self.snapKeyframeSeconds.count {
                EngineLog.emit("[SWHost] keyframe-snapped seeks: \(keys.count) indexed keyframes",
                               category: .swPlayback)
            }
            self.snapKeyframeSeconds = keys
        }
    }

    /// #254: the demuxer reposition is awaited off the main actor. It used to run inline here, and
    /// because `Demuxer.readPacket` holds the access lock across the whole `av_read_frame`, a seek
    /// issued while the demux loop sat in a slow remote read parked the main thread for the length of
    /// that read (App Hangs of 4.4 s and 5.2 s in the field on a WAN source).
    @discardableResult
    func seek(to seconds: Double) async -> Demuxer.RepositionOutcome {
        guard !stopRequested else { return .superseded }
        guard failure == nil, let dem = demuxer else { return .stalled }
        // Stop loop + bump generation to invalidate in-flight packets. Captured right after, so the
        // reposition can tell on `seekQueue` whether a newer seek has already taken over.
        bumpSeekGeneration()
        let generation = seekGeneration
        residentRangePublication.invalidate()
        didReachEnd = false
        didParkClockAtEnd = false
        didEmitParkedDiag = false
        let packetSource = vodPacketReadAhead
        // #107 round 2: `seconds` is the SESSION axis. The demuxer, the packet
        // store, the decoder's skip threshold and the synchronizer clock all
        // speak the source's own timestamps, so the target is carried back over
        // before it reaches any of them, the same conversion `liveScrubStill`
        // already makes with `sessionStartPts`. For a zero-based source the two
        // axes coincide and this is the identity, which is why the omission only
        // ever showed on a mid-stream-joined one.
        var sourceSeconds = SWClockAnchorPolicy.sourceSeconds(
            forSession: seconds,
            sessionZeroSeconds: clockSessionZero
        )
        var seconds = seconds
        if snapsSeeksToKeyframes, !isLive,
           let snapped = SWKeyframeSnap.snappedSeconds(
               target: sourceSeconds, current: sourceClockSeconds,
               keyframes: SWKeyframeSnap.candidates(retained: packetSource?.retainedKeyframeSeconds ?? [],
                                                    indexed: snapKeyframeSeconds)) {
            EngineLog.emit("[SWHost] seek snapped to keyframe target_s=\(String(format: "%.3f", sourceSeconds)) "
                           + "keyframe_s=\(String(format: "%.3f", snapped))", category: .swPlayback)
            seconds += snapped - sourceSeconds
            sourceSeconds = snapped
        }
        let cacheGeneration = packetSource?.beginSeek(to: sourceSeconds)
        // #292: inside another seek's window `isPlaying` is that seek's parked flag, not the transport's
        // intent. Inherit what it captured, and hand the same value on to whoever supersedes this one.
        let wasPlaying = SeekResumeIntent.resolve(isPlaying: isPlaying,
                                                  seekInFlight: seekInFlight,
                                                  inFlightIntent: inFlightSeekResumeIntent)
        inFlightSeekResumeIntent = wasPlaying
        isPlaying = false

        #if DualLayerDolbyVision
        // The dual-layer decoder's deadline rule reads this clock, and `seekClock` below moves it after
        // this flush. That is safe only because the demux loop resumes after `noteSeekSettled`, past the
        // `seekClock` call: until then no post-seek frame reaches the decoder to be judged against the
        // pre-seek clock. Keep that order if either step moves. (The clock sample is not atomic either,
        // see where `setRenderClock` is called; a skewed sample corrects itself within one sweep.)
        #endif
        videoDecoder.flush()
        audioDecoder?.flush()
        // Hold the last frame through the seek (don't blank the display) so the viewer sees the previous
        // frame until the post-seek frame decodes, instead of a black flash (issue #90). Stop/teardown and
        // background-return still clear via the default.
        renderer.flush(removingDisplayedImage: false)
        audioOutput?.flush()
        // AE#479: the flush just emptied the queue the diag marker describes, and the pump learns of
        // this seek only at its next iteration, which a paused landing never reaches until play().
        demuxDiag.audioFlushed(generation: generation)
        keyframeLedger.reset()

        // Live source is forward-only; DVR rewind reseeds decoders from the ring without touching the live demuxer's read position.
        if isLive, let ring = dvrRing {
            await seekLiveDVR(to: seconds, ring: ring, wasPlaying: wasPlaying)
            noteSeekSettled(generation)
            return .landed
        }

        // Publish the target and hold it across the await, so the scrub clock snaps the way the native
        // path's optimistic publish does instead of drifting on the stale synchronizer anchor.
        currentTime = seconds
        seekInFlight = true

        // AE#491: armed BEFORE the reposition, not after it. The flushes above emptied both queues,
        // but the reposition is awaited and the decode thread runs under it, so a frame from a
        // packet read before the seek used to meet a renderer with no threshold standing and was
        // taken. It then owns the newest handed-over timestamp, and the first real post-seek frame
        // reports the entire seek distance as one inter-frame interval.
        let targetTime = CMTime(seconds: sourceSeconds, preferredTimescale: 90000)
        videoDecoder.skipUntilPTS = targetTime
        renderer.setSkipThreshold(targetTime)

        var cacheHit = false
        if let packetSource, let cacheGeneration {
            let preparation = await BlockingWork.detached(priority: .userInitiated) {
                try packetSource.prepareSeek(cacheGeneration, to: sourceSeconds)
            }.result
            guard seekGeneration == generation, !stopRequested else { return .superseded }
            switch preparation {
            case .success(let hit):
                cacheHit = hit
                if !hit { residentRanges = [] }
                EngineLog.emit(
                    "[SWHost] packet cache seek generation=\(generation) "
                    + "result=\(hit ? "hit" : "miss") "
                    + "target_s=\(String(format: "%.3f", sourceSeconds)) "
                    + "resident_bytes=\(packetSource.snapshot.residentBytes)",
                    category: .swPlayback
                )
            case .failure(SoftwarePacketReadAhead.ReadError.interrupted),
                 .failure(SoftwarePacketReadAhead.ReadError.closed):
                return .superseded
            case .failure:
                // A corrupt/unreadable retained packet must not be silently skipped or treated as
                // a normal cache miss. Leave playback parked and publish an explicit failure.
                seekInFlight = false
                packetSource.close()
                residentRanges = []
                noteSeekSettled(generation)
                EngineLog.emit("[SWHost] packet cache seek generation=\(generation) result=error",
                               category: .swPlayback)
                failure = PlaybackErrorInfo(kind: .softwarePipelineFailed,
                                            message: "Playback cache could not reposition.")
                return .stalled
            }
        }
        let outcome: Demuxer.RepositionOutcome
        if cacheHit {
            // The decode cursor now points at retained preroll. The source reader remains at its
            // existing frontier; seeking it too would duplicate or skip already retained packets.
            outcome = .landed
        } else {
            outcome = await reposition(dem, sourceSeconds, Self.seekBudgetSeconds, seekQueue,
                { [weak self] in
                    self?.seekGeneration != generation || (self?.stopRequested ?? true)
                })
        }
        // A newer seek owns the state from here: it published its own target and clears the hold itself.
        // stop() can also land in the await now that this suspends, and re-arming the clock or flipping
        // isPlaying on a torn-down session would resurrect a loop that has already been told to quit.
        guard seekGeneration == generation, !stopRequested, outcome != .superseded else { return .superseded }
        seekInFlight = false
        EngineLog.emit("[SWReposition] flags=\(outcome == .landed ? 2 : 3)", category: .swPlayback)
        guard outcome == .landed else {
            // No target clock, decoder run or cache producer may follow an undefined read position.
            // Keep the last observed clock; the engine must not finalize this request as a landing.
            isPlaying = false
            pausedByHost = true
            audioOutput?.setPlaybackEnabled(false)
            currentTime = clockSessionZero > 0
                ? max(0, sourceClockSeconds - clockSessionZero) : sourceClockSeconds
            packetSource?.close()
            residentRanges = []
            noteSeekSettled(generation)
            failure = PlaybackErrorInfo(kind: .softwarePipelineFailed,
                                       message: "Playback source could not reposition.")
            return .stalled
        }

        // Re-armed after the landing: a pre-seek frame PAST the target (a backward seek) clears the
        // threshold on its way through, and the generation guard on the decoder callback is what
        // stops it. Both stand, because neither alone covers both seek directions.
        videoDecoder.skipUntilPTS = targetTime
        renderer.setSkipThreshold(targetTime)

        currentTime = seconds

        // #292: the intent is read HERE, not from what this seek captured on entry. `pause()` / `play()`
        // during the reposition rewrite the stash, and a landing that ignored them either overrode the
        // pause (kept playing) or, from the other side, anchored at rate 0 under a running loop.
        if inFlightSeekResumeIntent {
            // Anchor clock at seek target: clock at .zero + PTS=seekTarget would stall rendering for seekTarget seconds (FigVideoQueueRemote -12080).
            audioOutput?.seekClock(to: targetTime, rate: lastRate)
            isPlaying = true
        } else {
            // Paused seek: anchor at target with rate 0 so play() resumes from the seek position (without this, scrubs freeze or drop all samples).
            audioOutput?.seekClock(to: targetTime, rate: 0)
            pausedByHost = true
        }
        // Arm now so the demux loop doesn't re-arm at stale initialClockTime (a pre-first-audio seek snapped back to session start without this).
        clockArmed = true
        // The source stands at the target and the clock is anchored on it: everything the loop
        // reads from here belongs to this position. Closing the window releases the loop.
        noteSeekSettled(generation)
        if let cacheGeneration { packetSource?.endSeek(cacheGeneration, sourceClock: sourceSeconds) }
        refreshSnapKeyframes()
        return outcome
    }

    /// AE#595: the extractor, built on the first ask and kept for the rest of the session.
    ///
    /// The stream pointer is re-read from the demuxer rather than held from session start: the
    /// demuxer is assigned once and closed once, both on this actor, so it is valid for exactly as
    /// long as a still can be asked for, and re-reading it means nothing has to outlive teardown.
    private func resolveStillExtractor() -> SoftwareStillExtractor? {
        stillExtractorSlot.resolve {
            guard let dem = demuxer, let stream = dem.stream(at: videoStreamIndex) else {
                EngineLog.emit("[SWHost] #544 still extractor unavailable (no video stream)",
                               category: .swPlayback)
                return nil
            }
            do {
                let built = try SoftwareStillExtractor(
                    stream: stream,
                    videoStreamIndex: videoStreamIndex,
                    timeBaseSeconds: videoTimeBaseSeconds,
                    deinterlace: deinterlaceConfig)
                // Once per session, and its absence is the point: a session that never scrubs
                // should never print it, which is the whole of AE#595 stated as an observable.
                EngineLog.emit("[SWHost] #595 still extractor built on the first request",
                               category: .swPlayback)
                return built
            } catch {
                // A session without scrub stills still plays; the preview just stays empty.
                EngineLog.emit("[SWHost] #544 still extractor unavailable (\(error))",
                               category: .swPlayback)
                return nil
            }
        }
    }

    /// Resident preview only; selection and decode run on the existing still queue.
    /// The frozen source/session delta maps actual PTS back through the same axis as seek.
    func scrubPreviewFrame(atSessionSeconds seconds: Double, refined: Bool, maxWidth: Int,
                           isCancelled: @escaping @Sendable () -> Bool) async -> ScrubFrame? {
        guard let extractor = resolveStillExtractor() else { return nil }
        let source = sourceSeconds(forSession: seconds)
        let ring = isLive ? dvrRing : nil
        let cache = isLive ? nil : vodPacketReadAhead
        let requests = stillRequests
        let ticket = requests.next()
        return await withCheckedContinuation { continuation in
            stillQueue.async {
                let cancelled = { isCancelled() || ticket != requests.latest }
                guard !cancelled() else { continuation.resume(returning: nil); return }
                var actual: Double?
                var didRefine = false
                var sourceRange: Range<Double>?
                let reportRange = { (range: Range<Double>) in sourceRange = range }
                let report = { (pts: Double, precise: Bool) in actual = pts; didRefine = precise }
                let image: CGImage?
                if let ring {
                    image = extractor.still(from: ring, targetPts: source, maxWidth: maxWidth,
                        precise: refined, isCancelled: cancelled, reportTime: report, reportRange: reportRange)
                } else if let cache, let run = cache.stillRun(atSeconds: source,
                    maxPackets: 900, maxSpanSeconds: 12, reorderTail: 16, isCancelled: cancelled) {
                    image = extractor.still(from: run, targetPts: source, maxWidth: maxWidth,
                        precise: refined, isCancelled: cancelled, reportTime: report, reportRange: reportRange)
                } else { image = nil }
                guard let image, let actual, actual.isFinite, !cancelled() else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: ScrubFrame(image: image,
                    actualSeconds: seconds + actual - source, refined: didRefine,
                    validRange: sourceRange.map { (seconds + $0.lowerBound - source)..<(seconds + $0.upperBound - source) }))
            }
        }
    }

    /// #544: a scrub still for the live DVR window, decoded out of the packet ring.
    ///
    /// Takes the session axis, exactly as `seek` does, and converts it with the same `sessionStartPts`
    /// the rewind uses, so the still and the commit can never name two different moments. Runs on its
    /// own queue: the ring is internally locked and safe to read alongside the feeder, but decoding on
    /// the demux or feed loop would make the viewer pay for the preview in dropped packets.
    func liveScrubStill(atSessionSeconds seconds: Double, maxWidth: Int) async -> CGImage? {
        guard isLive, let ring = dvrRing, let extractor = resolveStillExtractor() else { return nil }
        let targetSource = sourceSeconds(forSession: seconds)
        let requests = stillRequests
        let ticket = requests.next()
        return await withCheckedContinuation { continuation in
            stillQueue.async {
                guard ticket == requests.latest else {
                    // Superseded while it waited: decoding it would only push the newer one later.
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: extractor.still(from: ring, targetPts: targetSource, maxWidth: maxWidth))
            }
        }
    }

    /// AE#605: true when this VOD session keeps a packet cache a still can be decoded from. A local
    /// file has none (it is read directly, see the spool's setup), and neither does a session whose
    /// cache could not be built.
    var servesPacketCacheStills: Bool { !isLive && vodPacketReadAhead != nil }

    /// Whether this session's video can become a still in this build. False for a Dolby Vision
    /// Profile 5 / 10.0 stream without the `DolbyVisionStillReshaping` trait, the same verdict
    /// `FrameDecodeContext` gives every still decode of it; set at `load`.
    private(set) var videoYieldsStills = true

    /// AE#605: the VOD twin of `liveScrubStill`, decoded out of the retained packet cache.
    ///
    /// Same queue, same newest-wins ticket and same extractor as the live still, and the same session
    /// axis conversion `seek` uses, so the card and the commit name one moment. The disk read runs on
    /// the still queue too, never on the demux or feed loop.
    func vodScrubStill(atSessionSeconds seconds: Double, maxWidth: Int) async -> CGImage? {
        guard !isLive, let cache = vodPacketReadAhead, let extractor = resolveStillExtractor() else {
            return nil
        }
        let targetSource = sourceSeconds(forSession: seconds)
        let limits = SoftwareStillExtractor.Limits.vod
        let requests = stillRequests
        let ticket = requests.next()
        return await withCheckedContinuation { continuation in
            stillQueue.async {
                guard ticket == requests.latest,
                      let run = cache.stillRun(atSeconds: targetSource,
                                               maxPackets: limits.maxPackets,
                                               maxSpanSeconds: limits.maxSpanSeconds,
                                               reorderTail: limits.reorderTail) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: extractor.still(from: run, targetPts: targetSource, maxWidth: maxWidth))
            }
        }
    }

    /// Live DVR rewind: reseeds decoder from the ring (source PTS axis; maps via sessionStartPts) without touching the live demuxer. After return, the loop reads new packets forward and plays back to live.
    private func seekLiveDVR(to targetSession: Double, ring: PacketRingBuffer, wasPlaying: Bool) async {
        let targetSource = sourceSeconds(forSession: targetSession)

        let targetTime = CMTime(seconds: targetSource, preferredTimescale: 90000)
        videoDecoder.skipUntilPTS = targetTime
        renderer.setSkipThreshold(targetTime)

        // Anchor clock at target (paused scrubs: rate 0 so resume continues from seek position).
        if wasPlaying {
            audioOutput?.seekClock(to: targetTime, rate: lastRate)
        } else {
            audioOutput?.seekClock(to: targetTime, rate: 0)
            pausedByHost = true
        }
        clockArmed = true

        // Reposition cursor to the newest keyframe at or before target. If the target precedes every
        // retained keyframe, fall to the EARLIEST keyframe, not seqBounds.first, which can be a mid-GOP
        // leading entry before the ring's first eviction and would decode as garbage until the next keyframe.
        let seq = ring.seq(forKeyframeAtOrBefore: targetSource)
            ?? ring.firstKeyframeSeq()
            ?? ring.seqBounds.first
        setFeedCursor(seq)
        EngineLog.emit(
            "[SWHost] DVR rewind: targetSession=\(String(format: "%.2f", targetSession)) "
            + "targetSource=\(String(format: "%.2f", targetSource)) -> cursor seq=\(seq)",
            category: .swPlayback
        )

        currentTime = targetSession
        if wasPlaying {
            isPlaying = true
        }
    }

    /// Reconstruct AVPacket from ring entry, convert PTS from seconds back to stream time_base, and route to decoders. Returns true when audio buffers were enqueued (used for feeder clock arming).
    @discardableResult
    nonisolated static func feedRingPacket(
        _ pkt: PacketRingBuffer.Packet,
        videoDecoder: any VideoDecodingPipeline,
        audioDecoder: (any SoftwareAudioProducing)?,
        audioOutput: AudioOutput?,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        audioTapSink: (@Sendable (CMSampleBuffer) -> Void)?,
        audioEpoch: UInt64,
        noteDecodeGeneration: @Sendable () -> Void
    ) -> Bool {
        let tbSec = pkt.isVideo ? videoTimeBaseSeconds : audioTimeBaseSeconds
        guard tbSec > 0, !pkt.bytes.isEmpty else { return false }

        guard let p = trackedPacketAlloc() else { return false }
        var avPkt: UnsafeMutablePointer<AVPacket>? = p
        defer { trackedPacketFree(&avPkt) }

        if av_new_packet(p, Int32(pkt.bytes.count)) < 0 { return false }
        pkt.bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let dst = p.pointee.data {
                memcpy(dst, base, pkt.bytes.count)
            }
        }
        p.pointee.pts = SourceTimestampBounds.roundedTicks(pkt.pts / tbSec) ?? Int64.min
        p.pointee.dts = p.pointee.pts
        p.pointee.flags = pkt.isKeyframe ? AV_PKT_FLAG_KEY : 0
        p.pointee.stream_index = pkt.isVideo ? videoStreamIndex : audioStreamIndex

        if pkt.isVideo {
            noteDecodeGeneration()
            // AE#492: no epoch. This replays from the DVR ring after a reseed, so there is no batch
            // of packets decided on before a flush for one to invalidate.
            videoDecoder.decode(packet: p, epoch: nil)
            return false
        } else if let aDec = audioDecoder, let aOut = audioOutput {
            var enqueued = false
            for buf in aDec.decode(packet: p) {
                // DEC-106 on the DVR path: `audioEpoch` was read before the ring read, so a rewind's flush
                // retires what this packet decodes to. A pre-seek buffer kept at the head of the fresh queue
                // carries a higher stamp than the new clock and mutes audio for the rewind distance.
                guard aOut.enqueue(sampleBuffer: buf, ifEpoch: audioEpoch) else { return enqueued }
                audioTapSink?(buf)   // #95: mirrored behind the accept
                enqueued = true
            }
            return enqueued
        }
        return false
    }

    func stop() {
        stopRequested = true
        pausedBeforeFirstFrame = false
        isPlaying = false
        isRebuffering = false
        seekInFlight = false
        videoQueueFlushOwed = false
        // A teardown inside a seek's window would otherwise leave it open on this instance.
        noteSeekSettled(seekGeneration)
        timeTimer?.cancel()
        timeTimer = nil
        residentRangePublication.invalidate()
        residentRanges = []
        vodPacketReadAhead?.close()
        vodPacketReadAhead = nil
        renderer.subtitleCompositor.reset()

        if let extractor = stillExtractorSlot.reset() {
            // Torn down ON the still queue, so a decode already in flight finishes against a codec
            // context that is still open rather than one freed out from under it.
            stillQueue.async { extractor.close() }
        }
        dvrRing?.close()
        dvrRing = nil
        retentionClaims.forEach { $0.release() }
        retentionClaims.removeAll()
        liveEdgeLock.lock()
        sessionStartPts = .nan
        liveJoinPolicy = SoftwareLiveJoinPolicy()
        newestSourcePts = .nan
        liveEdgeLock.unlock()

        if let aOut = audioOutput {
            aOut.stop()
            aOut.detachVideoLayer(renderer.displayLayer)
        }
        audioOutput = nil
        audioDecoder?.close()
        audioDecoder = nil
        videoDecoder.close()
        renderer.flush()
        demuxer?.close()
        demuxer = nil

        isReady = false
        // #315: the session's picture goes with the session. `flush()` above already removed it.
        disarmReadyForDisplayObserver()
        isVideoReadyForDisplay = false
    }

    /// #660: held here, not only on the output, because the engine sets it before `load()` builds one.
    var volume: Float = 1.0 {
        didSet { audioOutput?.volume = volume }
    }

    // MARK: - Demux loop

    /// Capture dependencies as locals so the demux loop runs off-main without re-entering the actor.
    private func startDemuxLoop() {
        guard let dem = demuxer else { return }
        let vDec = videoDecoder
        let vIdx = videoStreamIndex
        let aDec = audioDecoder
        let aOut = audioOutput
        let aIdx = audioStreamIndex
        let rndr = renderer
        let condition = demuxCondition
        let initialClock = initialClockTime
        // Read at arm time, not captured: a host setRate between load and arming must reach
        // the anchor (the eager synchronizer call it replaced is gated on clockArmed, #107).
        let currentRate: @Sendable () -> Float = { [weak self] in
            guard let self else { return 1.0 }
            return PausedFirstFrame.armingRate(lastRate: self.lastRate,
                                               pausedBeforeFirstFrame: self.pausedBeforeFirstFrame)
        }
        let ring = dvrRing
        let vTbSec = videoTimeBaseSeconds
        let aTbSec = audioTimeBaseSeconds
        let liveSession = isLive
        // Pump-thread side of `isRebuffering`: hops to the main actor and writes only on a change.
        let noteRebuffering: @Sendable (Bool) -> Void = { [weak self] rebuffering in
            Task { @MainActor [weak self] in
                guard let self, self.isRebuffering != rebuffering else { return }
                self.isRebuffering = rebuffering
            }
        }
        // The feeder's resume re-placement, handed to the engine on the session axis: the engine's
        // own live seek carries it through the tickets, the subtitle anchor and the clock like any
        // other. The feeder states the target on the source axis; the mapping is `sourceSeconds
        // (forSession:)` inverted, under the same lock.
        // Carries the seek generation it was decided under: a seek that lands in between is the
        // viewer's choice of position, and a catch-up decided before it must not undo it.
        let noteLiveResumeCatchUp: @Sendable (Double, UInt64) -> Void = { [weak self] targetPts, generation in
            Task { @MainActor [weak self] in
                guard let self, !self.stopRequested, self.seekGeneration == generation,
                      let target = self.liveSessionSeconds(forSource: targetPts) else { return }
                self.liveResumeCatchUp.send(target)
            }
        }
        let noteEdge: @Sendable (Double) -> Void = { [weak self] ptsSec in
            guard let self, ptsSec.isFinite else { return }
            self.liveEdgeLock.lock()
            if self.sessionStartPts.isNaN { self.sessionStartPts = ptsSec }
            if self.newestSourcePts.isNaN || ptsSec > self.newestSourcePts {
                self.newestSourcePts = ptsSec
            }
            self.liveEdgeLock.unlock()
        }
        // Sodalite#104 round 4: the LOOPS' flag, which also runs them under a pause that arrived before
        // the first frame. The transport's own flag stays `isPlaying`.
        let getIsPlaying: @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return PausedFirstFrame.loopsMayRun(isPlaying: self.isPlaying,
                                                pausedBeforeFirstFrame: self.pausedBeforeFirstFrame)
        }
        let getStopRequested: @Sendable () -> Bool = { [weak self] in self?.stopRequested ?? true }
        // #95: resolved per packet so a tap installed mid-session is picked up by running loops.
        let getAudioTapSink: @Sendable () -> ((@Sendable (CMSampleBuffer) -> Void)?) = { [weak self] in
            self?.audioTapSink
        }
        // #112 rework: same late-install resolution for the subtitle tap.
        let getSubtitleTapSink: @Sendable () -> ((@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational, Bool) -> Void)?) = { [weak self] in
            self?.subtitleTapSink
        }
        let playedMediaLedger = playedMediaLedger
        // AE#560: both read loops hand every source packet to this before any branching.
        let recordingTap: @Sendable (UnsafeMutablePointer<AVPacket>) -> Void = { [weak self] pkt in
            self?.tapForRecording(pkt)
        }
        let subIndices = subtitleStreamIndices
        let subTimeBases = subtitleStreamTimeBases
        let subSplitSetIndices = splitDisplaySetSubtitleStreamIndices
        let onErrorForGeneration: @Sendable (String, UInt64) -> Void = { [weak self] msg, generation in
            Task { @MainActor [weak self] in
                guard let self, self.admitsRead(generation: generation) else { return }
                self.failure = PlaybackErrorInfo(kind: liveSession ? .liveSourceUnavailable : .softwarePipelineFailed, message: msg)
            }
        }
        let onEndForGeneration: @Sendable (UInt64) -> Void = { [weak self] generation in
            Task { @MainActor [weak self] in
                guard let self, self.admitsRead(generation: generation) else { return }
                // Only current EOF may mark the diagnostic source exhausted or stop playback.
                // A queued pre-seek EOF task must not end a freshly positioned generation.
                self.demuxDiag.markSourceExhausted()
                self.parkClockAtEndOfMedia()
                self.didReachEnd = true
                self.isPlaying = false
            }
        }
        let onError: @Sendable (String) -> Void = { [weak self] message in
            guard let self else { return }
            onErrorForGeneration(message, self.seekGeneration)
        }
        let onEnd: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            onEndForGeneration(self.seekGeneration)
        }

        // Live + DVR ring: reader/feeder split; live-only and VOD use the combined loop below.
        let getClockArmed: @Sendable () -> Bool = { [weak self] in
            self?.clockArmed ?? true
        }
        let setClockArmed = makeClockArmCallback(audioOutput: aOut)
        let getSeekGeneration: @Sendable () -> UInt64 = { [weak self] in
            self?.seekGeneration ?? 0
        }
        let admitsRead: @Sendable (UInt64) -> Bool = { [weak self] generation in
            self?.admitsRead(generation: generation) ?? false
        }
        let getSeekWindowOpen: @Sendable () -> Bool = { [weak self] in
            self?.seekWindowOpen ?? false
        }
        let setDecodeGeneration: @Sendable (UInt64) -> Void = { [weak self] gen in
            self?.decodeGeneration = gen
        }
        let noteDecodeGeneration: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.decodeGeneration = self.seekGeneration
        }
        let getBackgroundAudioOnly: @Sendable () -> Bool = { [weak self] in
            self?.backgroundAudioOnly ?? false
        }
        // #107: the demux loop reports the resolved session-zero offset when it re-anchors
        // the clock at a first-sample PTS far past the anchor (mid-stream-joined source).
        let onClockAnchored: @Sendable (Double) -> Void = { [weak self] zero in
            self?.clockSessionZero = zero
            self?.onClockSessionZero?(zero)
        }

        if liveSession, let ring {
            let getFeederPlaying: @Sendable () -> Bool = { [weak self] in
                guard let self else { return false }
                return !self.dvrRecoveryPending && !self.seekWindowOpen && getIsPlaying()
            }
            let readCursor: @Sendable () -> Int = { [weak self] in
                self?.readFeedCursor() ?? 0
            }
            let advanceCursor: @Sendable (Int) -> Void = { [weak self] old in
                self?.advanceFeedCursor(from: old)
            }
            let recoverCursor: @Sendable (Int) -> Void = { [weak self] old in
                self?.recoverEvictedFeedCursor(from: old, ring: ring)
            }
            // Where the live join starts, once the connect burst has landed (see the policy). Nil
            // while it is still landing; the feeder asks again a moment later.
            let liveJoinPlacement: @Sendable () -> SoftwareLiveJoinPolicy.Decision? = { [weak self] in
                guard let self else { return .fromStart }
                self.liveEdgeLock.lock()
                defer { self.liveEdgeLock.unlock() }
                guard self.sessionStartPts.isFinite, self.newestSourcePts.isFinite else { return nil }
                return self.liveJoinPolicy.observe(firstPts: self.sessionStartPts,
                                                   newestPts: self.newestSourcePts,
                                                   at: ProcessInfo.processInfo.systemUptime,
                                                   leadSeconds: self.liveHoldback.joinLeadSeconds,
                                                   minimumSpanSeconds: self.liveHoldback.edgeCushionSeconds)
            }
            let liveHoldback: @Sendable () -> SoftwareLiveHoldback = { [weak self] in
                self?.liveHoldback ?? .continuous
            }
            let newestSourcePts: @Sendable () -> Double = { [weak self] in
                guard let self else { return .nan }
                self.liveEdgeLock.lock()
                defer { self.liveEdgeLock.unlock() }
                return self.newestSourcePts
            }
            let placeCursor: @Sendable (Int, UInt64) -> Bool = { [weak self] seq, generation in
                self?.placeFeedCursor(seq, ifGeneration: generation) ?? false
            }
            let setSourceEnded: @Sendable () -> Void = { [weak self] in
                self?.sourceEnded = true
            }
            let getSourceEnded: @Sendable () -> Bool = { [weak self] in
                self?.sourceEnded ?? true
            }
            demuxQueue.async {
                Self.runLiveReaderLoop(
                    demuxer: dem,
                    videoStreamIndex: vIdx,
                    audioStreamIndex: aIdx,
                    condition: condition,
                    ring: ring,
                    videoTimeBaseSeconds: vTbSec,
                    audioTimeBaseSeconds: aTbSec,
                    noteEdge: noteEdge,
                    readerMayAdvance: { [weak self] in
                        guard let self else { return false }
                        return !self.dvrRecoveryPending && !self.seekWindowOpen
                    },
                    stopRequested: getStopRequested,
                    onError: onError,
                    onSourceEnded: setSourceEnded,
                    subtitleStreamIndices: subIndices,
                    subtitleTimeBases: subTimeBases,
                    splitDisplaySetSubtitleStreamIndices: subSplitSetIndices,
                    subtitleTapSink: getSubtitleTapSink,
                    recordingTap: recordingTap,
                    playedMedia: playedMediaLedger
                )
            }
            let lookahead = audioLookahead
            feedQueue.async {
                Self.runLiveFeederLoop(
                    videoDecoder: vDec,
                    audioDecoder: aDec,
                    audioOutput: aOut,
                    videoStreamIndex: vIdx,
                    audioStreamIndex: aIdx,
                    renderer: rndr,
                    condition: condition,
                    ring: ring,
                    audioLookahead: lookahead,
                    videoTimeBaseSeconds: vTbSec,
                    audioTimeBaseSeconds: aTbSec,
                    readCursor: readCursor,
                    advanceCursor: advanceCursor,
                    recoverCursor: recoverCursor,
                    liveJoinPlacement: liveJoinPlacement,
                    liveHoldback: liveHoldback,
                    newestSourcePts: newestSourcePts,
                    placeCursor: placeCursor,
                    seekGeneration: getSeekGeneration,
                    currentRate: currentRate,
                    isPlaying: getFeederPlaying,
                    stopRequested: getStopRequested,
                    sourceEnded: getSourceEnded,
                    clockArmed: getClockArmed,
                    markClockArmed: setClockArmed,
                    onEnd: onEnd,
                    audioTapSink: getAudioTapSink,
                    noteDecodeGeneration: noteDecodeGeneration,
                    noteRebuffering: noteRebuffering,
                    noteLiveResumeCatchUp: noteLiveResumeCatchUp
                )
            }
            return
        }

        let diag = demuxDiag
        let keyframeLedger = keyframeLedger
        let readAhead = vodPacketReadAhead
        demuxQueue.async {
            Self.runDemuxLoop(
                demuxer: dem,
                readAhead: readAhead,
                videoDecoder: vDec,
                videoStreamIndex: vIdx,
                audioDecoder: aDec,
                audioOutput: aOut,
                audioStreamIndex: aIdx,
                renderer: rndr,
                condition: condition,
                initialClockTime: initialClock,
                currentRate: currentRate,
                diag: diag,
                ring: ring,
                videoTimeBaseSeconds: vTbSec,
                audioTimeBaseSeconds: aTbSec,
                isLive: liveSession,
                foldTimeline: Self.shouldFoldTimeline(
                    isLive: liveSession, sourceSeekable: dem.isSourceSeekable),
                noteEdge: noteEdge,
                isPlaying: getIsPlaying,
                stopRequested: getStopRequested,
                clockArmed: getClockArmed,
                markClockArmed: setClockArmed,
                onClockAnchored: onClockAnchored,
                seekGeneration: getSeekGeneration,
                admitsRead: admitsRead,
                seekWindowOpen: getSeekWindowOpen,
                setDecodeGeneration: setDecodeGeneration,
                noteDecodeGeneration: noteDecodeGeneration,
                backgroundAudioOnly: getBackgroundAudioOnly,
                onError: onErrorForGeneration,
                onEnd: onEndForGeneration,
                audioTapSink: getAudioTapSink,
                subtitleStreamIndices: subIndices,
                subtitleTimeBases: subTimeBases,
                splitDisplaySetSubtitleStreamIndices: subSplitSetIndices,
                subtitleTapSink: getSubtitleTapSink,
                recordingTap: recordingTap,
                playedMedia: playedMediaLedger,
                keyframeLedger: keyframeLedger,
                noteRebuffering: noteRebuffering
            )
        }
    }

    // MARK: - Live reader loop (DVR sessions)

    /// Source -> ring (runs regardless of play/pause). Discontinuity reconciliation before ring append so the ring carries one continuous timeline.
    nonisolated static func runLiveReaderLoop(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32,
        condition: NSCondition,
        ring: PacketRingBuffer,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        noteEdge: @Sendable (Double) -> Void,
        readerMayAdvance: @Sendable () -> Bool = { true },
        stopRequested: @Sendable () -> Bool,
        onError: @Sendable (String) -> Void,
        onSourceEnded: @Sendable () -> Void,
        subtitleStreamIndices: Set<Int32> = [],
        subtitleTimeBases: [Int32: AVRational] = [:],
        splitDisplaySetSubtitleStreamIndices: Set<Int32> = [],
        subtitleTapSink: @Sendable () -> ((@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational, Bool) -> Void)?) = { nil },
        recordingTap: @escaping @Sendable (UnsafeMutablePointer<AVPacket>) -> Void = { _ in },
        playedMedia: PlayedMediaLedger? = nil
    ) {
        let discontinuityThresholdSeconds = 10.0
        var prevRawVideoPtsSec = Double.nan
        var frameIntervalSec = 0.0
        var discontinuityOffsetSec = 0.0
        var loggedSWDiscontinuity = false
        var lastSeenExtradata: Data? = nil
        let replayReader = LiveReplayPacketReader(videoIndex: videoStreamIndex, audioIndex: audioStreamIndex,
            videoTimeBase: videoTimeBaseSeconds, audioTimeBase: audioTimeBaseSeconds)

        func awaitReaderAdmission() -> Bool {
            condition.lock()
            while !readerMayAdvance() && !stopRequested() {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
            condition.unlock()
            return !stopRequested()
        }

        defer {
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }

        func readerIteration() -> Bool {
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                guard awaitReaderAdmission() else { return false }
                packet = try replayReader.read(isCurrent: { !stopRequested() }) { try demuxer.readPacket() }
            } catch {
                // Audit SEG-104: a stop closes the demuxer, which aborts a parked read. That is the
                // stop arriving, not a lost source.
                if stopRequested() { return false }
                EngineLog.emit("[SWHost] live reader read failed: \(error)", category: .swPlayback)
                onError("Playback error: \(error.localizedDescription)")
                onSourceEnded()
                return false
            }
            guard let packet else {
                EngineLog.emit("[SWHost] live reader EOF (source lost)", category: .swPlayback)
                onSourceEnded()
                return false
            }

            // Keep the recovery target resident until its decoder/clock transition settles,
            // including a source read that was already in flight when recovery began.
            guard awaitReaderAdmission() else {
                var stale: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&stale)
                return false
            }

            // AE#560: record before any branch. The DVR ring append further down sits inside
            // `if let ring`, so a tap placed there would silently do nothing for a live session
            // loaded without dvrWindowSeconds.
            recordingTap(packet)

            let streamIdx = packet.pointee.stream_index

            // In-band codec parameter change detection. libavcodec SW
            // decoders pick up in-band SPS/PPS changes on their own; the
            // VT HEVC path keeps its session-start format description and
            // would wedge or corrupt on a real change. Log loudly so a
            // real-world repro is identifiable; the
            // VTDecompressionSession reinit is gated on one.
            if streamIdx == videoStreamIndex {
                var sdSize: Int = 0
                if let sd = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &sdSize),
                   sdSize > 0 {
                    let newExtra = Data(bytes: sd, count: sdSize)
                    if newExtra != lastSeenExtradata {
                        lastSeenExtradata = newExtra
                        EngineLog.emit(
                            "[SWHost] WARNING: in-band video extradata change (\(sdSize) bytes) "
                            + "on the live source. SW decoders follow in-band parameter sets; "
                            + "the VT HEVC decoder keeps its session-start format description "
                            + "and needs a reinit if artifacts follow.",
                            category: .swPlayback
                        )
                    }
                }
            }

            // NOPTS repair: ring gates on valid PTS; MPEG-TS/H.264 field packets with NOPTS would starve the decoder. Synthesize PTS from DTS.
            if streamIdx == videoStreamIndex || streamIdx == audioStreamIndex,
               packet.pointee.pts == Int64.min, packet.pointee.dts != Int64.min {
                packet.pointee.pts = packet.pointee.dts
            }

            // Live PTS-discontinuity: same accrual as combined loop.
            if streamIdx == videoStreamIndex, videoTimeBaseSeconds > 0,
               packet.pointee.pts != Int64.min {
                let rawPtsSec = Double(packet.pointee.pts) * videoTimeBaseSeconds
                if !prevRawVideoPtsSec.isNaN {
                    let deltaSec = rawPtsSec - prevRawVideoPtsSec
                    if abs(deltaSec) >= discontinuityThresholdSeconds {
                        let expectedContinuation = prevRawVideoPtsSec
                            + (frameIntervalSec > 0 ? frameIntervalSec : 0)
                        discontinuityOffsetSec += (rawPtsSec - expectedContinuation)
                        if !loggedSWDiscontinuity {
                            loggedSWDiscontinuity = true
                            EngineLog.emit(
                                "[SWHost] live PTS discontinuity (reader): prevPts="
                                + "\(String(format: "%.2f", prevRawVideoPtsSec))s "
                                + "rawPts=\(String(format: "%.2f", rawPtsSec))s "
                                + "delta=\(String(format: "%.2f", deltaSec))s -> "
                                + "offset=\(String(format: "%.2f", discontinuityOffsetSec))s "
                                + "(timeline held continuous)",
                                category: .swPlayback
                            )
                        }
                    } else if deltaSec > 0 {
                        frameIntervalSec = deltaSec
                    }
                }
                prevRawVideoPtsSec = rawPtsSec
            }
            if discontinuityOffsetSec != 0 {
                let tbSec = (streamIdx == videoStreamIndex)
                    ? videoTimeBaseSeconds : audioTimeBaseSeconds
                if tbSec > 0 {
                    // Audit NAT-101: the offset spans twice the input range and converts per stream
                    // base, so a packet on the far side of a seam can still leave Int64.
                    let offsetTicks = SourceTimestampBounds.roundedTicks(discontinuityOffsetSec / tbSec)
                    packet.pointee.pts = SourceTimestampBounds.shifted(packet.pointee.pts, back: offsetTicks)
                    packet.pointee.dts = SourceTimestampBounds.shifted(packet.pointee.dts, back: offsetTicks)
                }
            }

            let isVideo = streamIdx == videoStreamIndex
            let isAudio = streamIdx == audioStreamIndex
            if isVideo || isAudio {
                let tbSec = isVideo ? videoTimeBaseSeconds : audioTimeBaseSeconds
                let rawPts = packet.pointee.pts
                if rawPts != Int64.min, tbSec > 0 {
                    let ptsSec = Double(rawPts) * tbSec
                    noteEdge(ptsSec)
                    playedMedia?.record(isVideo ? .video : .audio, pts: ptsSec, bytes: Int(packet.pointee.size))
                    if let data = packet.pointee.data, packet.pointee.size > 0 {
                        let isKey = isVideo && (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                        // Best-effort: a write failure just shrinks the
                        // rewind window, it must not stall the reader.
                        try? ring.append(pts: ptsSec, isKeyframe: isKey, isVideo: isVideo,
                                         bytes: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)))
                        condition.lock()
                        condition.broadcast()
                        condition.unlock()
                    }
                }
            } else if subtitleStreamIndices.contains(streamIdx), let sink = subtitleTapSink() {
                // #107: the ring holds only A/V; subtitle packets tap into the session packet
                // store here, mirroring the combined demux loop (the playhead-paced drainer
                // decodes them on selection).
                sink(streamIdx, packet,
                     subtitleTimeBases[streamIdx] ?? AVRational(num: 1, den: 1000),
                     splitDisplaySetSubtitleStreamIndices.contains(streamIdx))
            }

            av_packet_unref(packet)
            av_packet_free_safe(packet)
            return true
        }

        while !stopRequested() {
            let keepGoing: Bool = autoreleasepool {
                readerIteration()
            }
            if !keepGoing { break }
        }
    }

    // MARK: - Live feeder loop (DVR sessions)

    /// Ring cursor -> decoders -> renderer with back-pressure. Pause = timeshift (reader keeps filling); DVR seek = cursor move.
    nonisolated private static func runLiveFeederLoop(
        videoDecoder: any VideoDecodingPipeline,
        audioDecoder: (any SoftwareAudioProducing)?,
        audioOutput: AudioOutput?,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32,
        renderer: SampleBufferRenderer,
        condition: NSCondition,
        ring: PacketRingBuffer,
        audioLookahead: AudioLookaheadState,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        readCursor: @Sendable () -> Int,
        advanceCursor: @Sendable (Int) -> Void,
        recoverCursor: @Sendable (Int) -> Void,
        liveJoinPlacement: @Sendable () -> SoftwareLiveJoinPolicy.Decision? = { .fromStart },
        liveHoldback: @Sendable () -> SoftwareLiveHoldback = { .continuous },
        newestSourcePts: @Sendable () -> Double = { .nan },
        placeCursor: @Sendable (Int, UInt64) -> Bool = { _, _ in false },
        seekGeneration: @Sendable () -> UInt64,
        currentRate: @Sendable () -> Float,
        isPlaying: @Sendable () -> Bool,
        stopRequested: @Sendable () -> Bool,
        sourceEnded: @Sendable () -> Bool,
        clockArmed: @Sendable () -> Bool,
        markClockArmed: @Sendable () -> Void,
        onEnd: @Sendable () -> Void,
        audioTapSink: @Sendable () -> ((@Sendable (CMSampleBuffer) -> Void)?),
        noteDecodeGeneration: @Sendable () -> Void,
        noteRebuffering: @Sendable (Bool) -> Void = { _ in },
        noteLiveResumeCatchUp: @Sendable (Double, UInt64) -> Void = { _, _ in }
    ) {
        // The join's start is placed once, before the first packet is fed; a seek before then is
        // the viewer's own choice of position and retires it.
        var liveJoinPending = true
        // AE#844: once placed, a join that kept its cursor moves to the first keyframe past it. Set
        // while that is pending: when the join was decided.
        var liveJoinAlignSince: TimeInterval?
        var liveJoinAlignLead: Double?
        // After an edge rebuffer resumes, watches what the source hands over on its way back and
        // moves the picture up behind it once (see the `.none` arm below). Nil when nothing is
        // being watched.
        var resumePlacement: SoftwareLiveJoinPolicy? = nil
        // Audio look-ahead pump (#107 audio chopping): feed audio packets ahead of the
        // combined cursor so the audio renderer holds AudioLookaheadPolicy.targetLeadSeconds
        // of decoded audio regardless of video decode pace. Without it audio lead is capped
        // by the video renderer queue (<1 s) and any feeder stall is an audible dropout.
        var preArmPacketsFed = 0
        var hadLead = false
        var rebuffering = false
        var lastLowLeadLog = DispatchTime(uptimeNanoseconds: 0)
        var feederGeneration = seekGeneration()
        func pumpAudio(epoch audioEpoch: UInt64) {
            guard let aDec = audioDecoder, let aOut = audioOutput, audioStreamIndex >= 0 else { return }
            var seq = audioLookahead.align(to: readCursor())
            func pumpIteration() -> Bool {
                guard readCursor() >= ring.seqBounds.first,
                      seekGeneration() == feederGeneration else { return false }
                let armed = clockArmed()
                guard AudioLookaheadPolicy.decide(
                    clockArmed: armed,
                    preArmPacketsFed: preArmPacketsFed,
                    lastFedAudioPTS: audioLookahead.lastFedAudioPTS,
                    clockSeconds: aOut.currentTimeSeconds
                ) == .feed else { return false }
                guard seq < ring.seqBounds.end else { return false }  // live edge: nothing to pump yet
                // Audit PERF-101: the kind is in the index, so the video packets this pump skips are
                // never read off the disk (the feeder reads each of them once, for decode).
                guard ring.isVideo(atSeq: seq) == false, let pkt = ring.packet(atSeq: seq) else {
                    // Video, or evicted/unreadable under the pump: skip, same as the combined loop.
                    guard audioLookahead.advance(from: seq, fedPTS: nil) else { return false }
                    seq += 1
                    return true
                }
                let producedAudio = feedRingPacket(
                    pkt,
                    videoDecoder: videoDecoder,
                    audioDecoder: aDec,
                    audioOutput: aOut,
                    videoStreamIndex: videoStreamIndex,
                    audioStreamIndex: audioStreamIndex,
                    videoTimeBaseSeconds: videoTimeBaseSeconds,
                    audioTimeBaseSeconds: audioTimeBaseSeconds,
                    audioTapSink: audioTapSink(),
                    audioEpoch: audioEpoch,
                    noteDecodeGeneration: noteDecodeGeneration
                )
                if !armed {
                    preArmPacketsFed += 1
                    if producedAudio {
                        // First decoded buffers arm the clock at their packet PTS, exactly as
                        // the combined loop did before the pump took over audio delivery.
                        let armTime = CMTime(seconds: pkt.pts, preferredTimescale: 90000)
                        aOut.seekClock(to: armTime, rate: currentRate())
                        markClockArmed()
                    }
                }
                guard audioLookahead.advance(from: seq, fedPTS: pkt.pts) else { return false }
                seq += 1
                return true
            }

            while !stopRequested() && isPlaying() {
                let keepGoing: Bool = autoreleasepool {
                    pumpIteration()
                }
                if !keepGoing { break }
            }
            // Live-edge underrun handling (#107): a source delivering below real time would
            // otherwise leave the free-running clock permanently ahead of the stream, and
            // every later sample lands in the clock's past (continuous chopping that never
            // recovers). Pause the clock, refill, resume; the native path gets the same
            // behavior from AVPlayer's stall handling.
            if clockArmed(), isPlaying(), readCursor() >= ring.seqBounds.first,
               seekGeneration() == feederGeneration {
                let lastPTS = audioLookahead.lastFedAudioPTS
                let clock = aOut.currentTimeSeconds
                let lead = lastPTS.isFinite ? lastPTS - clock : 0
                let newest = newestSourcePts()
                let ahead = newest.isFinite ? newest - clock : 0
                let cushion = liveHoldback().resumeCushionSeconds
                switch AudioLookaheadPolicy.clockAction(
                    rebuffering: rebuffering,
                    lastFedAudioPTS: lastPTS,
                    clockSeconds: clock,
                    atRingEnd: audioLookahead.current >= ring.seqBounds.end,
                    sourceEnded: sourceEnded(),
                    bufferedAheadSeconds: ahead,
                    resumeCushionSeconds: cushion
                ) {
                case .pauseForRebuffer:
                    rebuffering = true
                    noteRebuffering(true)
                    resumePlacement = nil
                    let resumesAt = cushion.map { ", resumes at \(String(format: "%.1f", $0))s ahead" } ?? ""
                    EngineLog.emit(
                        "[SWHost] live source underrun: pausing clock to rebuffer "
                        + "(lead=\(String(format: "%.2f", lead))s\(resumesAt))",
                        category: .swPlayback
                    )
                    aOut.pause()
                case .resume:
                    rebuffering = false
                    noteRebuffering(false)
                    EngineLog.emit(
                        "[SWHost] rebuffered: resuming clock (lead=\(String(format: "%.2f", lead))s "
                        + "ahead=\(String(format: "%.2f", ahead))s)",
                        category: .swPlayback
                    )
                    aOut.setRate(currentRate())
                    // A source that paused comes back one of two ways: it skips what it missed and
                    // continues near real time, or it hands the whole backlog over at once. The
                    // second leaves the picture the length of the pause behind the newest media,
                    // and nothing on this path ever catches up. So the join's own rule watches the
                    // resume the way it watched the connect burst, and moves the picture up once
                    // the backlog has landed: `.fromStart` is a source that skipped (nothing worth
                    // moving for), `.place` the lead behind what it handed over.
                    resumePlacement = SoftwareLiveJoinPolicy()
                case .none:
                    if var placement = resumePlacement, newest.isFinite, clock.isFinite {
                        let holdback = liveHoldback()
                        switch placement.observe(firstPts: clock, newestPts: newest,
                                                 at: ProcessInfo.processInfo.systemUptime,
                                                 leadSeconds: holdback.joinLeadSeconds) {
                        case nil:
                            resumePlacement = placement
                        case .fromStart?:
                            resumePlacement = nil
                        case .place(let targetPts)?:
                            resumePlacement = nil
                            // A segmented source resumes up to its cushion plus one unit behind on its
                            // own, which passes the join's threshold and is still the edge.
                            guard newest - clock >= holdback.resumeCatchUpSpanSeconds else { break }
                            EngineLog.emit(
                                "[SWHost] live resume re-placed \(String(format: "%.1f", holdback.joinLeadSeconds))s "
                                + "behind the newest media: the source handed over "
                                + "\(String(format: "%.1f", newest - clock))s at once after the pause "
                                + "(target pts=\(String(format: "%.2f", targetPts)))",
                                category: .swPlayback
                            )
                            noteLiveResumeCatchUp(targetPts, feederGeneration)
                        }
                    }
                    // Decode-lag visibility for device logs: only after lead was once
                    // healthy (startup fill must not trip it), rate-limited to one per 5 s.
                    if lead >= 0.5 { hadLead = true }
                    if hadLead, lead < 0.1, !rebuffering {
                        let now = DispatchTime.now()
                        if now.uptimeNanoseconds &- lastLowLeadLog.uptimeNanoseconds > 5_000_000_000 {
                            lastLowLeadLog = now
                            EngineLog.emit(
                                "[SWHost] audio lead low: \(String(format: "%.2f", lead))s "
                                + "(ring end=\(ring.seqBounds.end) audioSeq=\(audioLookahead.current))",
                                category: .swPlayback
                            )
                        }
                    }
                }
            }
        }

        func feederIteration() -> Bool {
            // Read before anything else: a DVR seek clears `isPlaying`, then flushes the audio output, then
            // moves the cursor, so an epoch read ahead of the playing check is retired by any flush that
            // lands after the cursor this iteration reads (audit DEC-106).
            let audioEpoch = audioOutput?.epoch ?? 0
            if !isPlaying() {
                condition.lock()
                while !isPlaying() && !stopRequested() {
                    autoreleasepool {
                        _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                    }
                }
                condition.unlock()
                return true
            }

            let generation = seekGeneration()
            if generation != feederGeneration {
                feederGeneration = generation
                preArmPacketsFed = 0
                hadLead = false
                if rebuffering { noteRebuffering(false) }
                rebuffering = false
                resumePlacement = nil
                liveJoinPending = false
                liveJoinAlignSince = nil
            }
            if liveJoinPending {
                switch liveJoinPlacement() {
                case nil:
                    if sourceEnded() {
                        // Nothing more will land; play what there is from its start.
                        liveJoinPending = false
                    } else {
                        condition.lock()
                        autoreleasepool {
                            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                        }
                        condition.unlock()
                        return true
                    }
                case .fromStart?:
                    liveJoinPending = false
                case .place(let targetPts)?:
                    liveJoinPending = false
                    let holdback = liveHoldback()
                    let unit = holdback.deliveryUnitSeconds.map { String(format: "%.1f", $0) + "s" } ?? "continuous"
                    let cursor = readCursor()
                    if let seq = ring.seq(forKeyframeAtOrBefore: targetPts), seq > cursor,
                       let keyframe = ring.packet(atSeq: seq), placeCursor(seq, generation) {
                        let skipped = keyframe.pts - (ring.packet(atSeq: cursor)?.pts ?? keyframe.pts)
                        EngineLog.emit(
                            "[SWHost] live join placed \(String(format: "%.1f", holdback.joinLeadSeconds))s "
                            + "behind the newest media (delivery unit \(unit)): skipped \(String(format: "%.1f", skipped))s of the "
                            + "connect burst (cursor seq=\(cursor) -> \(seq), keyframe pts=\(String(format: "%.2f", keyframe.pts)))",
                            category: .swPlayback
                        )
                        return true
                    }
                }
                if !liveJoinPending {
                    liveJoinAlignSince = ProcessInfo.processInfo.systemUptime
                    liveJoinAlignLead = SoftwareLiveJoinPolicy.alignmentLead(
                        cursorPts: ring.pts(atSeq: readCursor()), newestPts: newestSourcePts())
                }
            }
            if let since = liveJoinAlignSince {
                let cursor = readCursor()
                let keyframe = ring.keyframe(atOrAfterSeq: cursor)
                let cursorPts = ring.pts(atSeq: cursor)
                let newest = newestSourcePts()
                let waited = ProcessInfo.processInfo.systemUptime - since
                switch SoftwareLiveJoinPolicy.alignment(cursorSeq: cursor, keyframe: keyframe,
                                                        wantedLead: liveJoinAlignLead, newestPts: newest,
                                                        waited: waited, sourceEnded: sourceEnded()) {
                case .wait:
                    condition.lock()
                    autoreleasepool {
                        _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                    }
                    condition.unlock()
                    return true
                case .snap:
                    liveJoinAlignSince = nil
                    if let keyframe, placeCursor(keyframe.seq, generation) {
                        EngineLog.emit(
                            "[SWHost] live join moved to the first keyframe: skipped "
                            + "\(String(format: "%.2f", keyframe.pts - (cursorPts ?? keyframe.pts)))s before it "
                            + "(cursor seq=\(cursor) -> \(keyframe.seq), keyframe pts=\(String(format: "%.2f", keyframe.pts)), "
                            + "lead \(String(format: "%.2f", newest - keyframe.pts))s, waited \(String(format: "%.0f", waited * 1000)) ms)",
                            category: .swPlayback
                        )
                        return true
                    }
                case .stay:
                    liveJoinAlignSince = nil
                    if keyframe == nil {
                        EngineLog.emit(
                            "[SWHost] live join found no keyframe in \(String(format: "%.0f", waited * 1000)) ms; "
                            + "starting at the cursor (seq=\(cursor))",
                            category: .swPlayback
                        )
                    }
                }
            }
            let cursor = readCursor()
            let bounds = ring.seqBounds
            if cursor < bounds.first {
                // Recover BEFORE audio look-ahead can enqueue retained packets on the old clock.
                // Empty/oversized GOPs wait for a retained keyframe instead of inventing a target.
                if ring.oldestKeyframePts != nil {
                    recoverCursor(cursor)
                } else {
                    condition.lock()
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.25))
                    condition.unlock()
                }
                return true
            }
            // Audio is pumped only after an evicted cursor has been recovered onto the new clock.
            pumpAudio(epoch: audioEpoch)
            guard isPlaying(), seekGeneration() == generation, readCursor() == cursor,
                  cursor >= ring.seqBounds.first else { return true }
            // Audio the pump already delivered: consume the slot without reading it back, the
            // pump read it once already (audit PERF-101).
            if cursor < audioLookahead.current, ring.isVideo(atSeq: cursor) == false {
                advanceCursor(cursor)
                return true
            }
            guard let pkt = ring.packet(atSeq: cursor) else {
                // Resident entry whose file read failed (disk hiccup,
                // pruned mid-read): skip it, or the feeder would spin on
                // the same sequence number forever in a silent freeze.
                if cursor < bounds.end {
                    EngineLog.emit(
                        "[SWHost] feeder: packet seq=\(cursor) unreadable; skipping",
                        category: .swPlayback
                    )
                    advanceCursor(cursor)
                    return true
                }
                // At the live edge (cursor == end): wait for the reader's
                // next append, or finish when the source is gone and the
                // ring is fully drained.
                if sourceEnded() {
                    videoDecoder.drainForEndOfStream()
                    videoDecoder.flush()
                    audioDecoder?.flush()
                    renderer.drainReorderBuffer()
                    onEnd()
                    return false
                }
                condition.lock()
                autoreleasepool {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.25))
                }
                condition.unlock()
                return true
            }

            if pkt.isVideo {
                // Back-pressure against renderer queue; also bail on pause without consuming.
                // The wait can outlast the audio lead, so keep pumping audio while parked.
                var waitTicks = 0
                // The FEL look-ahead gate (`mayEnqueueVideoFrame`) holds a packet until its timestamp is
                // inside the clock's window; a seek, including a backward DVR seek, moves the cursor and
                // releases it here rather than waiting for its old timestamp to come round.
                while !renderer.mayEnqueueVideoFrame(
                    ptsSeconds: pkt.pts, clockSeconds: audioOutput?.currentTimeSeconds ?? .nan,
                    clockArmed: clockArmed()) && !stopRequested() && isPlaying()
                    && seekGeneration() == generation && readCursor() == cursor
                    && cursor >= ring.seqBounds.first {
                    autoreleasepool {
                        Thread.sleep(forTimeInterval: 0.005)
                        waitTicks += 1
                        if waitTicks % 20 == 0 { pumpAudio(epoch: audioEpoch) }
                        // #337: the pump is what can still arm the clock from here, so its spent
                        // pre-arm budget is what turns this park terminal (an audio track that
                        // never decodes a buffer). The renderer cannot drain at a stopped clock,
                        // so waiting past that point is a deadlock, not patience.
                        if SWClockAnchorPolicy.shouldArmFromParkedVideo(
                            clockArmed: clockArmed(),
                            isPlaying: isPlaying(),
                            rendererReadyForMoreData: renderer.isReadyForMoreMediaData,
                            audioArmingStillPossible: preArmPacketsFed < AudioLookaheadPolicy.preArmPacketBudget),
                           let aOut = audioOutput {
                            EngineLog.emit(
                                "[SWHost] clock unarmed at the video gate: the look-ahead pump spent its "
                                + "pre-arm budget (\(preArmPacketsFed) packets) without a decoded buffer; "
                                + "anchoring on video at \(String(format: "%.3f", pkt.pts))s",
                                category: .swPlayback
                            )
                            aOut.seekClock(to: CMTime(seconds: pkt.pts, preferredTimescale: 90000),
                                           rate: currentRate())
                            markClockArmed()
                        }
                    }
                }
                if stopRequested() { return false }
                if !isPlaying() || seekGeneration() != generation || readCursor() != cursor
                    || cursor < ring.seqBounds.first { return true }
            } else if cursor < audioLookahead.current {
                // Audio the pump already delivered: consume the slot without re-decoding.
                advanceCursor(cursor)
                return true
            }

            let producedAudio = feedRingPacket(
                pkt,
                videoDecoder: videoDecoder,
                audioDecoder: audioDecoder,
                audioOutput: audioOutput,
                videoStreamIndex: videoStreamIndex,
                audioStreamIndex: audioStreamIndex,
                videoTimeBaseSeconds: videoTimeBaseSeconds,
                audioTimeBaseSeconds: audioTimeBaseSeconds,
                audioTapSink: audioTapSink(),
                audioEpoch: audioEpoch,
                noteDecodeGeneration: noteDecodeGeneration
            )

            // Arm clock once on first packet PTS (anchoring at .zero caused delay). Audio: first decoded buffers; video-only: first video packet (no clock without audio = frozen frame).
            if !clockArmed(), let aOut = audioOutput {
                let shouldArm = (audioDecoder == nil) ? pkt.isVideo : producedAudio
                if shouldArm {
                    let armTime = CMTime(seconds: pkt.pts, preferredTimescale: 90000)
                    // Latest host rate, read at arm time (a setRate before arming is deferred here, #107).
                    aOut.seekClock(to: armTime, rate: currentRate())
                    markClockArmed()
                }
            }

            advanceCursor(cursor)
            return true
        }

        while !stopRequested() {
            let keepGoing: Bool = autoreleasepool {
                feederIteration()
            }
            if !keepGoing { break }
        }
    }

    /// Apply a resolved clock anchor: seek the synchronizer, report a non-zero session
    /// zero to the host, and log a re-anchor (release-visible; a mid-stream join is
    /// otherwise indistinguishable from a frozen-frame wedge, #107).
    nonisolated private static func armClock(
        _ aOut: AudioOutput,
        resolution: SWClockAnchorPolicy.Resolution,
        initialClockTime: CMTime,
        rate: Float,
        onClockAnchored: @Sendable (Double) -> Void
    ) {
        let anchorTime = resolution.anchorSeconds == initialClockTime.seconds
            ? initialClockTime
            : CMTime(seconds: resolution.anchorSeconds, preferredTimescale: 90000)
        aOut.seekClock(to: anchorTime, rate: rate)
        if resolution.anchorSeconds != initialClockTime.seconds {
            EngineLog.emit(
                "[SWHost] clock re-anchored to first sample: anchor=\(String(format: "%.3f", resolution.anchorSeconds))s "
                + "(load anchor \(String(format: "%.3f", initialClockTime.seconds))s, "
                + "sessionZero=\(String(format: "%.3f", resolution.sessionZeroSeconds))s)",
                category: .swPlayback
            )
            onClockAnchored(resolution.sessionZeroSeconds)
        }
    }

    /// Demux loop: reads packets, dispatches by stream index, back-pressures against renderer's isReadyForMoreMediaData, flushes decoders at EOF.
    nonisolated private static func runDemuxLoop(
        demuxer: Demuxer,
        readAhead: SoftwarePacketReadAhead?,
        videoDecoder: any VideoDecodingPipeline,
        videoStreamIndex: Int32,
        audioDecoder: (any SoftwareAudioProducing)?,
        audioOutput: AudioOutput?,
        audioStreamIndex: Int32,
        renderer: SampleBufferRenderer,
        condition: NSCondition,
        initialClockTime: CMTime,
        currentRate: @Sendable () -> Float,
        diag: SWPlaybackDiagState? = nil,
        ring: PacketRingBuffer?,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        isLive: Bool,
        foldTimeline: Bool,
        noteEdge: @Sendable (Double) -> Void,
        isPlaying: @Sendable () -> Bool,
        stopRequested: @Sendable () -> Bool,
        clockArmed: @Sendable () -> Bool,
        markClockArmed: @Sendable () -> Void,
        onClockAnchored: @Sendable (Double) -> Void,
        seekGeneration: @Sendable () -> UInt64,
        admitsRead: @Sendable (UInt64) -> Bool,
        seekWindowOpen: @Sendable () -> Bool,
        setDecodeGeneration: @Sendable (UInt64) -> Void,
        noteDecodeGeneration: @Sendable () -> Void,
        backgroundAudioOnly: @Sendable () -> Bool,
        onError: @Sendable (String, UInt64) -> Void,
        onEnd: @Sendable (UInt64) -> Void,
        audioTapSink: @Sendable () -> ((@Sendable (CMSampleBuffer) -> Void)?),
        subtitleStreamIndices: Set<Int32> = [],
        subtitleTimeBases: [Int32: AVRational] = [:],
        splitDisplaySetSubtitleStreamIndices: Set<Int32> = [],
        subtitleTapSink: @Sendable () -> ((@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational, Bool) -> Void)?) = { nil },
        recordingTap: @escaping @Sendable (UnsafeMutablePointer<AVPacket>) -> Void = { _ in },
        playedMedia: PlayedMediaLedger? = nil,
        keyframeLedger: SWKeyframeLedger? = nil,
        noteRebuffering: @Sendable (Bool) -> Void = { _ in }
    ) {
        // The video packet's time on the clock's axis and whether it is a keyframe, for `keyframeLedger`.
        func keyframeTime(of packet: UnsafeMutablePointer<AVPacket>) -> (pts: Double, isKey: Bool)? {
            let pts = packet.pointee.pts
            guard pts != Int64.min, videoTimeBaseSeconds > 0 else { return nil }
            return (Double(pts) * videoTimeBaseSeconds, (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0)
        }
        func noteVideoPacketParked(_ packet: UnsafeMutablePointer<AVPacket>) {
            if let t = keyframeTime(of: packet), t.isKey { keyframeLedger?.noteKeyframeRead(pts: t.pts) }
        }
        func noteVideoPacketDecoded(_ packet: UnsafeMutablePointer<AVPacket>) {
            if let t = keyframeTime(of: packet) { keyframeLedger?.noteHandedToDecoder(pts: t.pts, isKeyframe: t.isKey) }
        }
        func noteVideoPacketDropped(_ packet: UnsafeMutablePointer<AVPacket>) {
            if let t = keyframeTime(of: packet) { keyframeLedger?.noteDropped(pts: t.pts, isKeyframe: t.isKey) }
        }
        // A recovery flush leaves the decoder with no reference chain: until a keyframe comes the packets
        // that follow decode against nothing, so they are dropped here, at the one place both routes hand
        // video to the decoder. A dropped packet is never a keyframe, so the ledger needs no correction.
        func recoveryGate(_ packet: UnsafeMutablePointer<AVPacket>) -> SWKeyframeLedger.GateVerdict {
            keyframeLedger?.gate(isKeyframe: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0) ?? .pass
        }
        // The decoder refuses a packet whose epoch a flush has moved on from. If that was the keyframe
        // the gate had just let through, the recovery is still waiting for one.
        func reassertGateIfRefused(_ verdict: SWKeyframeLedger.GateVerdict, epoch: UInt64) {
            if verdict == .passAndOpen, videoDecoder.feedEpoch != epoch { keyframeLedger?.requireKeyframe() }
        }
        // Clock arming: one-shot latch (seekClock is not idempotent -- re-calling snaps clock back to initialClockTime). Shared with host so a seek before first audio isn't overridden by a late re-arm.

        // PTS-discontinuity fold (SW): accrue (jumpedPts - expectedContinuation) into discontinuityOffset; subtract from all subsequent PTS so the whole pipeline sees one continuous timeline. Threshold 10s (mirrors native producer); flush decoders at the seam.
        // Runs for live AND for forward-only (sequential-origin) VOD: IPTV timeshift archives are
        // chunked recordings whose every chunk restarts at PTS ~0 (device trace: 89 s chunk ending
        // at raw 2717.9 s, next chunk at 0.04 s; FFmpeg's 33-bit wrap correction turned that -2718 s
        // into +92726 s, the renderer then waited 25 h for the frame's display time and died with
        // -12080). Seekable VOD keeps the fold off: its timeline is trusted, and a threshold-sized
        // jump there is a container seek artifact the native path also leaves alone.
        let discontinuityThresholdSeconds = 10.0
        var prevRawVideoPtsSec = Double.nan
        var frameIntervalSec = 0.0
        var discontinuityOffsetSec = 0.0
        var loggedSeamCount = 0
        let replayReader = isLive ? LiveReplayPacketReader(videoIndex: videoStreamIndex,
            audioIndex: audioStreamIndex, videoTimeBase: videoTimeBaseSeconds,
            audioTimeBase: audioTimeBaseSeconds) : nil
        var replayGeneration = seekGeneration()

        // Clock-arming fallback bookkeeping: a declared audio track whose
        // decoder never produces buffers (corrupt stream) must not leave
        // the session unarmed forever. See the video-branch arming below.
        // The bound is the producer's own: the APAC route's first buffer is ~100 packets in.
        var audioPacketsSeen = 0
        var audioBuffersProduced = false
        let audioFirstBufferPacketBudget = audioDecoder?.firstBufferPacketBudget ?? 0
        // AE#844: a live join reads the source from wherever it stands, mid-GOP as a rule, and
        // would arm the clock on audio the picture only catches up with at the next keyframe.
        // Audio up to that keyframe is dropped while the clock is unarmed
        // (`SoftwareLiveJoinPolicy.dropsAudioBeforeFirstKeyframe`).
        var liveJoinAwaitsKeyframe = isLive && videoStreamIndex >= 0 && audioDecoder != nil
        var liveJoinDropStartedAt: TimeInterval?
        var liveJoinFirstDroppedPts = Double.nan
        var liveJoinDroppedPackets = 0

        // VOD audio decoupling (#107 family). The combined loop paced EVERYTHING on the video
        // renderer's ~10-frame queue, so interleaved audio could never build more than ~0.3 s
        // of lead over the synchronizer clock. Any decode/deinterlace jitter beyond that
        // starved the audio renderer, the synchronizer leapt to the next sample's PTS, the
        // whole queued video was suddenly late and the layer dropped it - a visible forward
        // skip (1080i50 archive replay trace: periodic +0.25 s clock leaps, 17 % renderer
        // drops). Video packets now PARK in a bounded FIFO while audio keeps decoding up to
        // AudioLookaheadPolicy.targetLeadSeconds ahead of the clock, and a genuine underrun
        // pauses the clock for a rebuffer (AudioLookaheadPolicy.clockAction) instead of
        // letting it free-run, mirroring the DVR feeder arm. Live sessions keep the historical
        // lockstep pacing: their delivery is origin-paced realtime, and the ones that need a
        // pump get it from the DVR feeder arm on its own thread.
        var parkedVideo: [UnsafeMutablePointer<AVPacket>] = []
        let parkedVideoCap = 256
        var terminalGeneration = SoftwareTerminalGeneration()
        var lastEnqueuedAudioPtsSec = Double.nan
        var rebuffering = false
        // The pause/rebuffer arm stays off until the source has proven it can deliver a real
        // lead once: an exactly-realtime origin whose lead never leaves the start offset must
        // not eat a rebuffer pause at every session start.
        var everHadLead = false
        var parkedSeekGeneration = seekGeneration()
        let decoupleAudio = !isLive && audioDecoder != nil && audioOutput != nil
        // AE#395: the diagnostic line's audio marker, written on every route. `lastEnqueuedAudioPtsSec`
        // is the pacing input and only exists where audio is decoupled, so a live session's line read
        // `aLead=-` throughout, on exactly the sessions where the lead decides whether a long-latency
        // route plays anything. The generation is the one the buffer was produced under (AE#479).
        var diagAudioPtsSec = Double.nan
        var diagAudioPtsGeneration = parkedSeekGeneration

        func freeParkedVideo() {
            for p in parkedVideo {
                av_packet_unref(p)
                av_packet_free_safe(p)
            }
            parkedVideo.removeAll()
            keyframeLedger?.discardPending()
        }

        // Decode+enqueue parked video while the renderer will take it. Never blocks.
        // Generation-checked: the blocking waits below can sit here across a seek, and the
        // lockstep gate discards a pre-seek packet for the same reason (decoding one clears
        // the decoder's skip threshold = visible fast-forward burst).
        //
        // AE#492: the check is per PACKET, and the epoch travels with it. Read once at the top, this
        // loop emptied the whole four-second FIFO into the decoder while a seek was landing, so the
        // packets kept arriving AFTER that seek's `videoDecoder.flush()` and refilled what the flush
        // had just cleared. Their own frames were still refused at the decoder callback, but the last
        // one stayed inside the deinterlacer's lookahead and came out on the FIRST post-seek decode,
        // by which time `decodeGeneration` was the new one and every gate passed it. One such frame
        // is a sample whose presentation time is the whole seek distance in the future: the layer
        // takes it, holds it, stops reporting `isReadyForMoreMediaData`, and the loop parks on that
        // signal until its FIFO caps out. Measured here as three to four seconds of `enq=+0` with the
        // audio lead decaying under it, on a session that reports playing and never rebuffers.
        func mayDecodeVideoPacket(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
            let pts = packet.pointee.pts
            let seconds = pts != Int64.min && videoTimeBaseSeconds > 0
                ? Double(pts) * videoTimeBaseSeconds : Double.nan
            return renderer.mayEnqueueVideoFrame(
                ptsSeconds: seconds, clockSeconds: audioOutput?.currentTimeSeconds ?? .nan,
                clockArmed: clockArmed())
        }

        func drainParkedVideoNonblocking() {
            if seekGeneration() != parkedSeekGeneration { return }
            while let head = parkedVideo.first, mayDecodeVideoPacket(head),
                  !stopRequested(), !backgroundAudioOnly() {
                // The epoch is read per packet, before the generation check below. A seek bumps the
                // generation before it flushes the decoder, so an epoch read ahead of its flush is refused
                // by the decoder and one read after it is behind a generation check that fails: either
                // way a pre-seek packet is retired (AE#492). Read once per pass, a flush from a recovery
                // in the middle of a batch made the decoder refuse the rest of packets that had already
                // left the FIFO and the ledger, which the recovery's own gate now accounts for instead.
                let epoch = videoDecoder.feedEpoch
                // Leave the rest standing: the next iteration of the loop frees the FIFO as a batch
                // once it has read the new generation.
                if seekGeneration() != parkedSeekGeneration { return }
                let p = parkedVideo.removeFirst()
                let verdict = recoveryGate(p)
                if verdict != .drop {
                    setDecodeGeneration(parkedSeekGeneration)
                    noteVideoPacketDecoded(p)
                    videoDecoder.decode(packet: p, epoch: epoch)
                    reassertGateIfRefused(verdict, epoch: epoch)
                }
                av_packet_unref(p)
                av_packet_free_safe(p)
            }
        }

        func releaseRebufferHold(_ why: String) {
            guard rebuffering else { return }
            rebuffering = false
            noteRebuffering(false)
            EngineLog.emit("[SWHost] releasing rebuffer hold: \(why)", category: .swPlayback)
            audioOutput?.setRate(currentRate())
        }

        // #337 on the decoupled path. The lockstep gate arms the clock off the packet it is
        // holding when the renderer is full and the selected audio stream will never produce
        // the buffer the clock waits for; parked, the equivalent packet is the FIFO head. The
        // gate below is the same shape of park, so it needs the same exit.
        func armFromParkedVideoIfStuck() {
            guard let head = parkedVideo.first, let aOut = audioOutput,
                  SWClockAnchorPolicy.shouldArmFromParkedVideo(
                    clockArmed: clockArmed(),
                    isPlaying: isPlaying(),
                    rendererReadyForMoreData: renderer.isReadyForMoreMediaData,
                    audioArmingStillPossible: false)
            else { return }
            EngineLog.emit(
                "[SWHost] clock unarmed with \(parkedVideo.count) video packets parked: the selected "
                + "audio stream (index \(audioStreamIndex)) has produced nothing by the renderer's "
                + "fill point (audioPacketsSeen=\(audioPacketsSeen)); anchoring on video",
                category: .swPlayback
            )
            armFromVideoPacket(head, aOut)
        }

        enum ParkWait {
            /// Hold the read until audio is back under its lead target / the FIFO under its cap.
            case readGate
            /// Feed the whole parked tail out (seam flush, end of media).
            case drainAll
        }

        // The one place the loop waits on the renderer. A rebuffer hold stops the synchronizer,
        // and a stopped synchronizer never drains the renderer: this thread is the only one that
        // could lift the hold, so waiting under it waits forever (the DVR arm may wait because
        // its pump runs on a second thread). Lift first, then wait.
        func waitForRenderer(_ reason: ParkWait) {
            func stillWaiting() -> Bool {
                switch reason {
                case .readGate:
                    return Self.shouldHoldDemuxRead(
                        parkedCount: parkedVideo.count, parkedCap: parkedVideoCap,
                        clockArmed: clockArmed(), lastAudioPts: lastEnqueuedAudioPtsSec,
                        clockSeconds: audioOutput?.currentTimeSeconds ?? .nan)
                case .drainAll:
                    return !parkedVideo.isEmpty
                }
            }
            while stillWaiting(), !stopRequested(), !backgroundAudioOnly() {
                if seekGeneration() != parkedSeekGeneration { return }
                if !isPlaying() {
                    condition.lock()
                    while !isPlaying() && !stopRequested() {
                        autoreleasepool {
                            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                        }
                    }
                    condition.unlock()
                    continue
                }
                releaseRebufferHold("the renderer needs a running clock to take parked video")
                armFromParkedVideoIfStuck()
                drainParkedVideoNonblocking()
                diag?.update(lastAudioPts: diagAudioPtsSec,
                             parked: parkedVideo.count, rebuffering: rebuffering,
                             generation: diagAudioPtsGeneration)
                if stillWaiting() {
                    // The condition is broadcast on play, stop, background, seek-settled and feed-cursor
                    // changes, so those cut the wait short where the sleep used to ride them out.
                    let wait = Self.parkedRendererWaitSeconds(
                        clockArmed: clockArmed(), lastAudioPts: lastEnqueuedAudioPtsSec,
                        clockSeconds: audioOutput?.currentTimeSeconds ?? .nan, rate: currentRate())
                    condition.lock()
                    autoreleasepool {
                        _ = condition.wait(until: Date(timeIntervalSinceNow: wait))
                    }
                    condition.unlock()
                }
            }
        }

        // Pause the master clock when the audio lead is genuinely exhausted, resume once the
        // rebuffer target is met. In this loop there is no ring to distinguish decode lag
        // from a dry source, so a sub-threshold lead IS treated as source-starved - the
        // everHadLead latch keeps that from firing on realtime-paced sources that never had
        // a lead to lose.
        func applyAudioClockAction() {
            guard decoupleAudio, clockArmed(), let aOut = audioOutput else { return }
            let lead = lastEnqueuedAudioPtsSec.isFinite
                ? lastEnqueuedAudioPtsSec - aOut.currentTimeSeconds : 0
            if lead >= AudioLookaheadPolicy.rebufferResumeLeadSeconds { everHadLead = true }
            guard everHadLead, isPlaying() || rebuffering else { return }
            switch AudioLookaheadPolicy.clockAction(
                rebuffering: rebuffering,
                lastFedAudioPTS: lastEnqueuedAudioPtsSec,
                clockSeconds: aOut.currentTimeSeconds,
                atRingEnd: true,
                // End of media releases the hold explicitly in the read path below; there is no
                // ring here whose end this could be read from.
                sourceEnded: false
            ) {
            case .pauseForRebuffer:
                rebuffering = true
                noteRebuffering(true)
                EngineLog.emit(
                    "[SWHost] audio lead exhausted (\(String(format: "%.2f", lead))s); "
                    + "pausing clock for rebuffer",
                    category: .swPlayback
                )
                aOut.pause()
            case .resume:
                rebuffering = false
                noteRebuffering(false)
                EngineLog.emit(
                    "[SWHost] rebuffered to \(String(format: "%.2f", lead))s audio lead; "
                    + "resuming clock",
                    category: .swPlayback
                )
                aOut.setRate(currentRate())
            case .none:
                break
            }
        }

        // Anchor the clock on a video packet. SWClockAnchorPolicy keeps the load anchor unless the
        // source joined mid-stream, so the frames already queued still present. Shared by the
        // undecodable-audio fallback and the #337 parked-gate exit.
        func armFromVideoPacket(_ packet: UnsafeMutablePointer<AVPacket>, _ aOut: AudioOutput) {
            // #107: a mid-stream-joined source delivers first samples far past the load
            // anchor; anchor at the packet PTS so they ever present (see SWClockAnchorPolicy).
            let pktPtsSec = (packet.pointee.pts != Int64.min && videoTimeBaseSeconds > 0)
                ? Double(packet.pointee.pts) * videoTimeBaseSeconds : Double.nan
            let resolution = SWClockAnchorPolicy.resolve(
                initialSeconds: initialClockTime.seconds, firstSampleSeconds: pktPtsSec)
            armClock(aOut, resolution: resolution, initialClockTime: initialClockTime,
                     rate: currentRate(), onClockAnchored: onClockAnchored)
            markClockArmed()
        }

        func demuxIteration() -> Bool {
            // A valid EOF/error can be queued for MainActor just before a newer seek supersedes
            // it. Keep the VOD consumer parked (without duplicate callbacks), not permanently
            // exited, so that newer generation still has a loop to consume its retained packets.
            if !isLive, terminalGeneration.shouldPark(generation: seekGeneration()) {
                condition.lock()
                while terminalGeneration.shouldPark(generation: seekGeneration()), !stopRequested() {
                    autoreleasepool {
                        _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                    }
                }
                condition.unlock()
                return !stopRequested()
            }
            // AE#491 round 2: the seek window is part of this park, not a second one. Keyed on it,
            // the loop stands still from the generation bump until the source and the clock are
            // both at the target, so nothing it does can be measured against, or fed from, the
            // position the seek left behind.
            if !SeekWindow.loopMayRead(isPlaying: isPlaying(), windowOpen: seekWindowOpen()) {
                condition.lock()
                while !SeekWindow.loopMayRead(isPlaying: isPlaying(), windowOpen: seekWindowOpen()),
                      !stopRequested() {
                    autoreleasepool {
                        _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                    }
                }
                condition.unlock()
                return true
            }

            if decoupleAudio {
                // Parked packets are pre-seek stale once the generation moves; the seek path
                // has already flushed decoders and re-anchored the clock.
                let gen = seekGeneration()
                if gen != parkedSeekGeneration {
                    parkedSeekGeneration = gen
                    freeParkedVideo()
                    lastEnqueuedAudioPtsSec = .nan
                    diagAudioPtsSec = .nan
                    diagAudioPtsGeneration = gen
                    if rebuffering { noteRebuffering(false) }
                    rebuffering = false
                    // The lead is zero again after a seek, so the latch has to earn itself back:
                    // keeping it set pauses the clock for a rebuffer on the first post-seek check.
                    everHadLead = false
                }
                drainParkedVideoNonblocking()
                applyAudioClockAction()
                // Read gate: stop pulling once decoded audio holds its target lead. The FIFO cap
                // is the memory backstop, not the pacing rule - what bounds the lead has to be
                // the lead itself, or the effective ceiling becomes "however many seconds of
                // video fit in 256 packets" and moves with frame rate.
                if Self.shouldHoldDemuxRead(
                    parkedCount: parkedVideo.count, parkedCap: parkedVideoCap,
                    clockArmed: clockArmed(), lastAudioPts: lastEnqueuedAudioPtsSec,
                    clockSeconds: audioOutput?.currentTimeSeconds ?? .nan) {
                    waitForRenderer(.readGate)
                    return true
                }
            }

            let genBeforeRead = seekGeneration()
            // AE#492: captured before the read, so a flush that lands during it retires this packet
            // inside the decoder rather than leaving the caller to re-check a value it cannot hold
            // across the call.
            var epochBeforeRead = videoDecoder.feedEpoch
            // Audit DEC-106: the audio side of the same rule, compared under the output's lock by `enqueue`.
            let audioEpochBeforeRead = audioOutput?.epoch ?? 0
            // And the producer's own: a seek's flush that lands between the generation check below and
            // the feed would let a pre-seek packet re-anchor the APAC bridge for the whole post-seek run.
            let audioFeedEpochBeforeRead = audioDecoder?.feedEpoch ?? 0
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                if let readAhead {
                    packet = try readAhead.read(isCurrent: { admitsRead(genBeforeRead) })?.makeAVPacket()
                } else {
                    if replayGeneration != genBeforeRead {
                        replayReader?.reset()
                        replayGeneration = genBeforeRead
                    }
                    if let replayReader {
                        packet = try replayReader.read(isCurrent: { admitsRead(genBeforeRead) }) {
                            try demuxer.readPacket(isCurrent: { admitsRead(genBeforeRead) })
                        }
                    } else {
                        packet = try demuxer.readPacket(isCurrent: { admitsRead(genBeforeRead) })
                    }
                }
            } catch {
                // Stop/seek cancellation is not a playback failure, including a normal .closed
                // returned by the packet source during teardown. Errors belong to the read's
                // captured host generation, just like packets and EOF.
                guard admitsRead(genBeforeRead) else { return !stopRequested() }
                if case SoftwarePacketReadAhead.ReadError.interrupted = error { return true }
                EngineLog.emit("[SWHost] demux read failed: \(error)", category: .swPlayback)
                if terminalGeneration.record(genBeforeRead) {
                    onError("Playback error: \(error.localizedDescription)", genBeforeRead)
                }
                return !isLive
            }

            // Admit every result BEFORE interpreting nil as EOF. Otherwise an old read can drain
            // or end the new seek generation without ever reaching the old packet-only gate.
            guard admitsRead(genBeforeRead) else {
                if let packet { av_packet_unref(packet); av_packet_free_safe(packet) }
                return !stopRequested()
            }
            guard let packet else {
                // Play the parked tail out before the flush: nothing more will arrive, the queues
                // must drain to end-of-media. The wait lifts a rebuffer hold on its own - held,
                // the clock would never take the tail and end-of-media would never be reached.
                // What the audio producer still holds (the APAC encoder's last packets) goes in
                // first, so the drain below plays it too.
                if let aDec = audioDecoder, let aOut = audioOutput {
                    for buf in aDec.endOfStream() {
                        guard aOut.enqueue(sampleBuffer: buf, ifEpoch: audioEpochBeforeRead) else { break }
                    }
                }
                releaseRebufferHold("end of media, nothing left to rebuffer from")
                waitForRenderer(.drainAll)
                guard admitsRead(genBeforeRead) else { return !stopRequested() }
                freeParkedVideo()
                // The dual-layer decoder's flush drops what its sessions and the GPU still hold,
                // which here is the last frames of the stream: hand those over first.
                videoDecoder.drainForEndOfStream()
                videoDecoder.flush()
                audioDecoder?.flush()
                renderer.drainReorderBuffer()
                if terminalGeneration.record(genBeforeRead) { onEnd(genBeforeRead) }
                return !isLive
            }

            // AE#560: record before any branch. The DVR ring append further down sits inside
            // `if let ring`, so a tap placed there would silently do nothing for a live session
            // loaded without dvrWindowSeconds.
            recordingTap(packet)

            let streamIdx = packet.pointee.stream_index

            // Discontinuity runs before any timestamp read; offset applied to both streams.
            if foldTimeline, streamIdx == videoStreamIndex, videoTimeBaseSeconds > 0,
               packet.pointee.pts != Int64.min {
                let rawPtsSec = Double(packet.pointee.pts) * videoTimeBaseSeconds
                if !prevRawVideoPtsSec.isNaN {
                    let deltaSec = rawPtsSec - prevRawVideoPtsSec
                    if abs(deltaSec) >= discontinuityThresholdSeconds {
                        // Accrue (jumpedPts - expectedContinuation) into offset; flush decoders at the seam.
                        let expectedContinuation = prevRawVideoPtsSec
                            + (frameIntervalSec > 0 ? frameIntervalSec : 0)
                        discontinuityOffsetSec += (rawPtsSec - expectedContinuation)
                        // Feed the parked pre-seam tail to the decoder before the flush drops
                        // its reference chain; the seam packet itself parks after this block.
                        waitForRenderer(.drainAll)
                        freeParkedVideo()
                        videoDecoder.drainForEndOfStream()
                        videoDecoder.flush()
                        // AE#492: this flush is THIS thread's, made after the read and on behalf of
                        // the packet in hand. Retiring that packet along with the seam it opens
                        // would drop the first picture of every new segment, so the epoch moves with
                        // it. A seek's flush comes from the other thread and is not re-read here.
                        epochBeforeRead = videoDecoder.feedEpoch
                        audioDecoder?.flush()
                        renderer.drainReorderBuffer()
                        // Chunked archives seam every minute or two; log each seam (bounded by the
                        // 10 s threshold to at most one line per 10 s of content) with a soft cap
                        // so a pathological source cannot flood the log.
                        if loggedSeamCount < 20 {
                            loggedSeamCount += 1
                            EngineLog.emit(
                                "[SWHost] PTS discontinuity #\(loggedSeamCount): prevPts="
                                + "\(String(format: "%.2f", prevRawVideoPtsSec))s "
                                + "rawPts=\(String(format: "%.2f", rawPtsSec))s "
                                + "delta=\(String(format: "%.2f", deltaSec))s -> "
                                + "offset=\(String(format: "%.2f", discontinuityOffsetSec))s "
                                + "(timeline held continuous)"
                                + (loggedSeamCount == 20 ? " [further seams unlogged]" : ""),
                                category: .swPlayback
                            )
                        }
                    } else if deltaSec > 0 {
                        frameIntervalSec = deltaSec
                    }
                }
                prevRawVideoPtsSec = rawPtsSec
            }

            // Apply discontinuity offset to timestamps in-place; converts seconds to stream TB ticks.
            if foldTimeline, discontinuityOffsetSec != 0 {
                let tbSec = (streamIdx == videoStreamIndex)
                    ? videoTimeBaseSeconds : audioTimeBaseSeconds
                if tbSec > 0 {
                    // Audit NAT-101: the offset spans twice the input range and converts per stream
                    // base, so a packet on the far side of a seam can still leave Int64.
                    let offsetTicks = SourceTimestampBounds.roundedTicks(discontinuityOffsetSec / tbSec)
                    packet.pointee.pts = SourceTimestampBounds.shifted(packet.pointee.pts, back: offsetTicks)
                    packet.pointee.dts = SourceTimestampBounds.shifted(packet.pointee.dts, back: offsetTicks)
                }
            }

            // AE#514: on the folded axis the clock runs on, which is what the sampler reads the playhead off.
            if let playedMedia, streamIdx == videoStreamIndex || streamIdx == audioStreamIndex {
                let tbSec = streamIdx == videoStreamIndex ? videoTimeBaseSeconds : audioTimeBaseSeconds
                let ticks = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
                if ticks != Int64.min, tbSec > 0 {
                    playedMedia.record(streamIdx == videoStreamIndex ? .video : .audio,
                                       pts: Double(ticks) * tbSec, bytes: Int(packet.pointee.size))
                }
            }

            // Fill ring before decode so the ring holds every packet. Audio appended for sync; only video keyframes tagged for eviction alignment.
            if isLive {
                let isVideo = streamIdx == videoStreamIndex
                let isAudio = streamIdx == audioStreamIndex
                if isVideo || isAudio {
                    let tbSec = isVideo ? videoTimeBaseSeconds : audioTimeBaseSeconds
                    let rawPts = packet.pointee.pts
                    if rawPts != Int64.min, tbSec > 0 {
                        let ptsSec = Double(rawPts) * tbSec
                        noteEdge(ptsSec)
                        if let ring {
                            let isKey = isVideo && (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                            if let data = packet.pointee.data, packet.pointee.size > 0 {
                                // Append is a small file write; off-main and
                                // internally locked, so it never touches the
                                // decoders' state. Best-effort: a write failure
                                // just shrinks the rewind window, it must not
                                // stall live playback.
                                try? ring.append(pts: ptsSec, isKeyframe: isKey, isVideo: isVideo,
                                                 bytes: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)))
                            }
                        }
                    }
                }
            }

            if liveJoinAwaitsKeyframe {
                if clockArmed() || backgroundAudioOnly() {
                    liveJoinAwaitsKeyframe = false
                } else if streamIdx == videoStreamIndex, packet.pointee.flags & AV_PKT_FLAG_KEY != 0 {
                    liveJoinAwaitsKeyframe = false
                    if liveJoinDroppedPackets > 0 {
                        let keyPts = packet.pointee.pts != Int64.min
                            ? Double(packet.pointee.pts) * videoTimeBaseSeconds : Double.nan
                        EngineLog.emit(
                            "[SWHost] live join starts on the first keyframe: dropped \(liveJoinDroppedPackets) audio "
                            + "packets (\(String(format: "%.2f", keyPts - liveJoinFirstDroppedPts))s) before it, "
                            + "keyframe pts=\(String(format: "%.2f", keyPts))",
                            category: .swPlayback
                        )
                    }
                } else if streamIdx == audioStreamIndex {
                    let now = ProcessInfo.processInfo.systemUptime
                    let pts = packet.pointee.pts != Int64.min
                        ? Double(packet.pointee.pts) * audioTimeBaseSeconds : Double.nan
                    if liveJoinDropStartedAt == nil {
                        liveJoinDropStartedAt = now
                        liveJoinFirstDroppedPts = pts
                    }
                    if SoftwareLiveJoinPolicy.dropsAudioBeforeFirstKeyframe(
                        waited: now - (liveJoinDropStartedAt ?? now),
                        droppedSpanSeconds: pts - liveJoinFirstDroppedPts) {
                        liveJoinDroppedPackets += 1
                        av_packet_unref(packet)
                        av_packet_free_safe(packet)
                        return true
                    }
                    liveJoinAwaitsKeyframe = false
                    EngineLog.emit(
                        "[SWHost] live join found no keyframe after \(liveJoinDroppedPackets) audio packets; "
                        + "starting on the audio",
                        category: .swPlayback
                    )
                }
            }

            if streamIdx == videoStreamIndex {
                // Background audio-only: drop video, don't gate on the non-draining display layer.
                if backgroundAudioOnly() {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    // What is parked is behind a hole now: the foreground return flushes the decoder and
                    // reads on from here. Keeping it would hand the decoder packets that no longer
                    // follow what it last saw, and leave the ledger describing keyframes that are gone.
                    freeParkedVideo()
                    return true
                }
                if decoupleAudio {
                    // Park; the drains at the iteration top and the bounded-park gate feed the
                    // renderer. Ownership moves to the FIFO - no free here.
                    noteVideoPacketParked(packet)
                    parkedVideo.append(packet)
                    // Broken-audio clock-arming fallback still applies (decoupleAudio only
                    // requires a DECLARED audio track, not a producing one). The stream that
                    // produces NO packets at all is #337's case and exits at the read gate.
                    if !clockArmed(), let aOut = audioOutput,
                       audioPacketsSeen >= audioFirstBufferPacketBudget, !audioBuffersProduced {
                        armFromVideoPacket(packet, aOut)
                    }
                    drainParkedVideoNonblocking()
                    return true
                }
                noteVideoPacketParked(packet)
                // Back-pressure via SampleBufferRenderer.isReadyForMoreMediaData (not the deprecated layer property). Park on condition while paused to avoid 200 Hz CPU spin.
                // Queue readiness plus the FEL-only look-ahead cap. Hold the compressed packet here,
                // rather than letting an asynchronous decode allocate another composed buffer.
                while !mayDecodeVideoPacket(packet) && !stopRequested() && !backgroundAudioOnly() {
                    // A seek can move the clock backwards while this compressed FEL packet is
                    // held. Leave the wait so the generation check below discards it immediately.
                    if Self.isDualLayer(videoDecoder), seekGeneration() != genBeforeRead { break }
                    autoreleasepool {
                        if !isPlaying() {
                            condition.lock()
                            while !isPlaying() && !stopRequested() {
                                autoreleasepool {
                                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                                }
                            }
                            condition.unlock()
                        } else {
                            // #337: this loop is the only reader, so an unarmed clock here is a
                            // deadlock and not latency: the renderer waits for the clock, the clock
                            // waits for a selected-stream audio buffer, and that packet is behind
                            // this park. Anchor on the video the renderer is holding instead.
                            if SWClockAnchorPolicy.shouldArmFromParkedVideo(
                                clockArmed: clockArmed(),
                                isPlaying: isPlaying(),
                                rendererReadyForMoreData: renderer.isReadyForMoreMediaData,
                                audioArmingStillPossible: false),
                               let aOut = audioOutput {
                                EngineLog.emit(
                                    "[SWHost] clock unarmed at the video gate: the selected audio stream "
                                    + "(index \(audioStreamIndex)) has produced nothing by the renderer's "
                                    + "fill point (audioPacketsSeen=\(audioPacketsSeen)); anchoring on video",
                                    category: .swPlayback
                                )
                                armFromVideoPacket(packet, aOut)
                            }
                            Thread.sleep(forTimeInterval: 0.005)
                        }
                    }
                }
                // Entered background while parked on back-pressure: drop this frame.
                if backgroundAudioOnly() {
                    noteVideoPacketDropped(packet)
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    return true
                }
                if stopRequested() {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    return false
                }
                // A recovery flush can land during the wait. The packet in hand is still current, and the
                // epoch read before the read would make the decoder refuse it; if it is the keyframe the
                // gate waits for, the picture would wait another group of pictures. Read again here, before
                // the generation check: a seek bumps the generation before it flushes the decoder, so an
                // epoch read ahead of a seek's flush is refused by the decoder, and one read after it is
                // behind a generation check that fails.
                epochBeforeRead = videoDecoder.feedEpoch
                // Re-check generation after the back-pressure wait (seek can land there; pre-seek packet would clear skip thresholds).
                if seekGeneration() != genBeforeRead {
                    noteVideoPacketDropped(packet)
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    return true
                }
                let verdict = recoveryGate(packet)
                if verdict == .drop {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    return true
                }
                setDecodeGeneration(genBeforeRead)
                noteVideoPacketDecoded(packet)
                videoDecoder.decode(packet: packet, epoch: epochBeforeRead)
                reassertGateIfRefused(verdict, epoch: epochBeforeRead)
                // Video-only / undecodable audio fallback: arm clock off first video packet (no buffer within the producer's first-buffer budget = decoder not recovering).
                if !clockArmed(), let aOut = audioOutput,
                   audioDecoder == nil || (audioPacketsSeen >= audioFirstBufferPacketBudget && !audioBuffersProduced) {
                    armFromVideoPacket(packet, aOut)
                }
            } else if streamIdx == audioStreamIndex, let aDec = audioDecoder, let aOut = audioOutput {
                // Background audio-only: the video gate is bypassed, so pace on the audio renderer to avoid
                // buffering the rest of the file. Park on condition while paused (same shape as the video gate).
                if backgroundAudioOnly() {
                    while !aOut.isReadyForMoreMediaData && !stopRequested() && backgroundAudioOnly() {
                        autoreleasepool {
                            if !isPlaying() {
                                condition.lock()
                                while !isPlaying() && !stopRequested() {
                                    autoreleasepool {
                                        _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                                    }
                                }
                                condition.unlock()
                            } else {
                                Thread.sleep(forTimeInterval: 0.005)
                            }
                        }
                    }
                    if stopRequested() {
                        av_packet_unref(packet)
                        av_packet_free_safe(packet)
                        return false
                    }
                }
                // AE#491: the video branch discards a pre-seek packet here and audio has to do the
                // same. `audioOutput.flush()` has already emptied the queue these buffers would
                // join, and their PTS is the marker `applyAudioClockAction` measures the lead
                // against: one pre-seek buffer past this point reads as a lead the size of the
                // seek and pauses the clock for a rebuffer that is not happening.
                if seekGeneration() != genBeforeRead {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    return true
                }
                audioPacketsSeen += 1
                let buffers = aDec.decode(packet: packet, epoch: audioFeedEpochBeforeRead)
                if !buffers.isEmpty { audioBuffersProduced = true }
                let tapSink = audioTapSink()
                // The flush can also land inside `decode`, so the buffers are checked out again.
                if seekGeneration() != genBeforeRead {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    return true
                }
                for buf in buffers {
                    guard aOut.enqueue(sampleBuffer: buf, ifEpoch: audioEpochBeforeRead) else {
                        av_packet_unref(packet)
                        av_packet_free_safe(packet)
                        return true
                    }
                }
                // #95: mirrored behind the accept, so a refused buffer is not transcribed. The tap
                // transcribes PCM, so a producer that hands the renderer compressed audio decodes it here.
                if let tapSink {
                    for buf in aDec.tapBuffers(for: packet, produced: buffers) { tapSink(buf) }
                }
                if let last = buffers.last {
                    let pts = CMSampleBufferGetPresentationTimeStamp(last)
                    if pts.isValid {
                        if decoupleAudio { lastEnqueuedAudioPtsSec = pts.seconds }
                        diagAudioPtsSec = pts.seconds
                        diagAudioPtsGeneration = genBeforeRead
                    }
                }
                // Arm clock on first decoded audio buffer; latch so subsequent packets don't snap clock back.
                if !clockArmed(), !buffers.isEmpty {
                    // #107: anchor at the buffer PTS when it lies far past the load anchor
                    // (mid-stream-joined source); aligned sources keep the anchor verbatim.
                    let firstPts = CMSampleBufferGetPresentationTimeStamp(buffers[0])
                    let resolution = SWClockAnchorPolicy.resolve(
                        initialSeconds: initialClockTime.seconds,
                        firstSampleSeconds: firstPts.isValid ? firstPts.seconds : Double.nan)
                    armClock(aOut, resolution: resolution, initialClockTime: initialClockTime,
                             rate: currentRate(), onClockAnchored: onClockAnchored)
                    markClockArmed()
                }
            } else if subtitleStreamIndices.contains(streamIdx), let sink = subtitleTapSink() {
                // #112 rework: hand embedded subtitle packets to the tap sink (copies the payload
                // into the session's SubtitlePacketStore). The SW host applies no stream discard,
                // so these packets were already being read and dropped here.
                sink(streamIdx, packet,
                     subtitleTimeBases[streamIdx] ?? AVRational(num: 1, den: 1000),
                     splitDisplaySetSubtitleStreamIndices.contains(streamIdx))
            }

            av_packet_unref(packet)
            av_packet_free_safe(packet)
            return true
        }

        while !stopRequested() {
            let keepGoing: Bool = autoreleasepool {
                demuxIteration()
            }
            diag?.update(lastAudioPts: diagAudioPtsSec,
                         parked: parkedVideo.count,
                         rebuffering: rebuffering,
                         generation: diagAudioPtsGeneration)
            if !keepGoing { break }
        }
        freeParkedVideo()
    }

    // MARK: - Time updates

    nonisolated static func displayResidentRanges(_ ranges: [ClosedRange<Double>],
                                                  sessionZeroSeconds: Double) -> [ClosedRange<Double>] {
        guard sessionZeroSeconds.isFinite else { return [] }
        let zero = max(0, sessionZeroSeconds)
        return ranges.compactMap { range in
            let start = max(0, range.lowerBound - zero), end = range.upperBound - zero
            return start.isFinite && end.isFinite && start < end ? start...end : nil
        }
    }

    /// Also runs while paused, independently of rendered-time events. At most one bounded
    /// metadata calculation is pending. Cached seeks keep the last valid spans; a miss clears
    /// them at the actual discard decision. Seek/stop invalidate any pre-operation result.
    private func sampleResidentRanges() {
        guard !isLive, !stopRequested, !seekInFlight,
              let source = vodPacketReadAhead else { return }
        let zero = clockSessionZero
        residentRangePublication.sample {
            Self.displayResidentRanges(source.residentRanges, sessionZeroSeconds: zero)
        } publish: { [weak self] ranges in
            guard let self, self.vodPacketReadAhead === source, !self.stopRequested,
                  self.clockSessionZero == zero else { return }
            if self.residentRanges != ranges { self.residentRanges = ranges }
        }
    }

    private func startTimeUpdates() {
        timeTimer = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                // Independent of the clock below: a seek in flight must not defer the one check.
                self.checkSurfaceVisibilityIfDue()
                self.sampleResidentRanges()
                guard let aOut = self.audioOutput else { return }
                self.pollAudioRendererStatus(aOut.renderer.status)
                // Counted while the queue is healthy: by the time a recovery trigger arrives the queue
                // has failed or been flushed, and the frames the clock passed would be uncounted.
                _ = self.renderer.presentedFrameCount(clockSeconds: aOut.currentTimeSeconds)
                // #254: a reposition in flight holds `currentTime` at its target; the synchronizer is
                // still on the pre-seek anchor and would drag the published position backwards.
                guard !self.seekInFlight, self.failure == nil else { return }
                let raw = aOut.currentTimeSeconds
                self.emitDiagIfDue(clock: raw)
                // AE#724: until the first sample arms it, the synchronizer still reads 0, and a paused
                // resume would publish that over the anchor load() set.
                if !self.isLive, !self.clockArmed { return }
                if raw.isFinite, raw >= 0 {
                    self.vodPacketReadAhead?.updatePlayhead(raw)
                    // Raw clock = source/subtitle axis; published alongside the mapped position (#107).
                    self.sourceClockSeconds = raw
                    // Live: subtract sessionStartPts to convert to "seconds since first frame"; VOD
                    // subtracts the anchor's session zero (0 for zero-based sources, #107).
                    if self.isLive {
                        let start: Double = {
                            self.liveEdgeLock.lock(); defer { self.liveEdgeLock.unlock() }
                            return self.sessionStartPts.isFinite ? self.sessionStartPts : 0
                        }()
                        self.currentTime = max(0, raw - start)
                    } else {
                        let zero = self.clockSessionZero
                        self.currentTime = zero > 0 ? max(0, raw - zero) : raw
                    }
                }
                // Feed the live edge; publishLiveWindow in the engine reads currentTime for the playhead.
                if self.isLive, let edge = self.liveEdgeSessionTime {
                    self.onLiveEdge?(edge)
                }
            }
    }

    // MARK: - SW diagnostics (1 Hz)

    private let demuxDiag = SWPlaybackDiagState()
    private var diagTickCounter = 0
    private var diagPrevClock = Double.nan
    private var diagPrevDropped = 0
    private var diagPrevEnqueued = 0
    private var diagPrevDelay: TimeInterval = 0
    /// #407: the layer's side of the frame count. `framesEnqueued` is bumped in the decoder callback,
    /// so it counts frames PRODUCED; anything lost between there and the layer is invisible in it and
    /// invisible in the layer's own drop counter too, which only sees frames it received.
    private var diagPrevHandedOver = 0
    private var diagPrevLost = 0
    /// #407: smallest video cushion seen since the last emitted line. The tick runs at 4 Hz and the
    /// line at 1 Hz, so an instantaneous read would miss three quarters of the interval, and a
    /// cushion that dips is exactly what a report of a picture that hitches while the per-second
    /// frame count stays at rate would look like.
    private var diagMinVideoLead = Double.infinity
    /// AE#374: the post-end line reporting the parked clock has been emitted; the session is over and
    /// the line stops rather than repeating itself at 1 Hz for as long as the host holds the engine.
    private var didEmitParkedDiag = false

    /// AE#395: a DVR session feeds audio from the ring pump, which never writes `demuxDiag`, so its
    /// line read `aLead=-` throughout. The pump's own fed PTS is the marker it paces on, and a DVR
    /// seek clears it, so it carries no pre-seek value.
    nonisolated static func diagAudioMarker(
        demuxLoopPts: Double, dvrPumpPts: Double, isDVRSession: Bool
    ) -> Double {
        isDVRSession ? dvrPumpPts : demuxLoopPts
    }

    /// 1 Hz [SWDiag] line: clock + clock delta, decoded-audio and video lead over the clock, parked
    /// video PACKET FIFO depth, rebuffer state, frames produced vs frames handed to the layer with
    /// the spacing of the timestamps they carried, and the display layer's OWN drop counter with its
    /// per-second delta. The layer counter is the one place render-deadline misses are
    /// visible - swDropped in the memprobe only counts pre-enqueue drops, so a session can
    /// stutter visibly while every 30 s probe reads clean.
    ///
    /// #407: `enq` alone cannot describe cadence. It is a count per wall second taken on the
    /// decoder's side of the layer, so an even 24 fps timeline and one carrying a doubled interval,
    /// a duplicate timestamp or a frame that never reached the layer all read `+24`. `disp`, `lost`
    /// and `dpts` are the three that separate them, and `vLead` says whether the frames were queued
    /// ahead of their presentation time or handed over at their deadline.
    private func emitDiagIfDue(clock: Double) {
        diagTickCounter += 1
        if let frontier = renderer.newestEnqueuedPtsSeconds, clock.isFinite {
            diagMinVideoLead = min(diagMinVideoLead, frontier - clock)
        }
        guard diagTickCounter % 4 == 0 else { return }
        let prevClock = diagPrevClock
        let d = demuxDiag.snapshot
        // AE#374: past end of media the line has no news left, and a 1 Hz report of a falling aLead
        // over a frozen audio PTS is a finding that does not exist. Keep reporting while the tail is
        // still playing out, name the exhaustion, and fall silent on the tick that shows the clock
        // parked on it.
        if d.sourceExhausted {
            if didEmitParkedDiag { return }
            if prevClock.isFinite, clock == prevClock { didEmitParkedDiag = true }
        }
        diagPrevClock = clock
        let audioMarker = Self.diagAudioMarker(
            demuxLoopPts: d.lastAudioPts,
            dvrPumpPts: audioLookahead.lastFedAudioPTS,
            isDVRSession: isLive && dvrRing != nil)
        let lead = audioMarker.isFinite && clock.isFinite ? audioMarker - clock : Double.nan
        let enqueued = framesEnqueued
        let dEnq = enqueued - diagPrevEnqueued
        diagPrevEnqueued = enqueued
        let cadence = renderer.takeCadence()
        let dHanded = cadence.handedOver - diagPrevHandedOver
        diagPrevHandedOver = cadence.handedOver
        let dLost = cadence.lostBeforeLayer - diagPrevLost
        diagPrevLost = cadence.lostBeforeLayer
        // #407: how far ahead of the clock the newest admitted frame sat, at its LOWEST over the
        // interval. `parkedPkts` counts undecoded PACKETS, so it says nothing about the video
        // pipeline's depth in TIME, which is what a report of frames arriving late needs.
        let videoLead = diagMinVideoLead.isFinite ? diagMinVideoLead : nil
        diagMinVideoLead = .infinity
        let spacing: String
        if let lo = cadence.minDeltaSeconds, let hi = cadence.maxDeltaSeconds {
            spacing = String(format: "%.1f/%.1f", lo * 1000, hi * 1000)
        } else {
            spacing = "-"
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let m = await self.loadRenderMetrics()
            let dropped = m?.dropped ?? -1
            let dDrop = dropped >= 0 ? dropped - self.diagPrevDropped : 0
            if dropped >= 0 { self.diagPrevDropped = dropped }
            // Accumulated render delay is the one metric that shows frames displayed LATE:
            // a layer that stalls a few seconds and then catches up (picture leaps forward,
            // audio uninterrupted) drops nothing and enqueues on pace - only this grows.
            let delay = m?.accumulatedDelay ?? -1
            let dDelay = delay >= 0 ? delay - self.diagPrevDelay : 0
            if delay >= 0 { self.diagPrevDelay = delay }
            let dclk = clock.isFinite && prevClock.isFinite ? clock - prevClock : Double.nan
            let layer = self.renderer.displayLayer
            let surface = layer.superlayer != nil
                ? "\(Int(layer.bounds.width))x\(Int(layer.bounds.height))" : "DETACHED"
            let r4d: String
            // #344: `*` is visionOS's declared floor (1.0), not "anything newer", and
            // isReadyForDisplay arrived in 1.1. Name the platform or the visionOS build breaks.
            if #available(visionOS 1.1, *) {
                r4d = layer.isReadyForDisplay ? "y" : "n"
            } else {
                r4d = "-"
            }
            EngineLog.emit(
                "[SWDiag] clk=\(String(format: "%.2f", clock)) "
                + "dclk=\(dclk.isFinite ? String(format: "%.2f", dclk) : "-") "
                // AE#549: a stopped clock and a running one whose timebase stalled under a
                // deactivated audio session are the same "dclk=0.00" and different defects.
                + "rate=\(String(format: "%.2f", self.audioOutput?.rate ?? 0)) "
                + "aLead=\(lead.isFinite ? String(format: "%.2f", lead) : "-") "
                // AE#395: status/sufficient/error of the audio renderer, the one stage after the feed
                // that nothing on this line described.
                + "aRend=\(self.audioOutput?.diagRendererState ?? "-") "
                + "vLead=\(videoLead.map { String(format: "%.2f", $0) } ?? "-") "
                + "parkedPkts=\(d.parked) rebuf=\(d.rebuffering ? "y" : "n") "
                + (d.sourceExhausted ? "eof=y " : "")
                + "enq=+\(dEnq) disp=+\(dHanded) "
                + "lost=\(cadence.lostBeforeLayer)(\(dLost >= 0 ? "+" : "")\(dLost)) "
                + "skip=\(cadence.arrivalSkipped) "
                + "dpts=\(spacing) layerDrop=\(dropped)(\(dDrop >= 0 ? "+" : "")\(dDrop)) "
                + "delay=\(delay >= 0 ? String(format: "%.2f", delay) : "-")"
                + "(\(dDelay >= 0 ? "+" : "")\(String(format: "%.2f", dDelay))) "
                + "corrupt=\(m?.corrupted ?? -1) "
                + "status=\(self.renderer.diagStatusName) surf=\(surface) "
                + "r4d=\(r4d)",
                category: .swPlayback
            )
        }
    }

    // MARK: - Errors

    enum HostError: Error, LocalizedError {
        case noVideoStream, repositionFailed

        var errorDescription: String? {
            switch self {
            case .noVideoStream: return "Source has no video stream"
            case .repositionFailed: return "Playback source could not resume at the requested position."
            }
        }
    }
}

// MARK: - AVPacket free helper

/// av_packet_free wrapper for the double-pointer FFmpeg API.
func av_packet_free_safe(_ packet: UnsafeMutablePointer<AVPacket>) {
    var p: UnsafeMutablePointer<AVPacket>? = packet
    trackedPacketFree(&p)
}

/// 1 Hz SW-session diagnostics shared between the combined demux loop (writes once per
/// iteration) and the host's time-update timer (reads + emits the [SWDiag] line). The native
/// path has LagDiag; the SW path had only the 30 s memprobe, which is too coarse to see the
/// clock leaps and layer-drop bursts a stuttering session is made of. Lock-guarded.
final class SWPlaybackDiagState: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastAudioPts = Double.nan
    private var _audioFlushGeneration: UInt64 = 0
    /// The newest PTS that described a queue a recovery has since emptied; a write that does not go
    /// beyond it is that same stale value coming round again, and is refused.
    private var _emptiedAudioPts = -Double.infinity
    private var _parked = 0
    private var _rebuffering = false
    private var _sourceExhausted = false

    /// `lastAudioPts` names the newest audio the pump has enqueued, and the pump is the only writer.
    /// AE#479: a seek flushes that audio on the main actor while the pump is still on the pre-seek
    /// generation, so its next write (one more after a playing seek, none at all while a paused
    /// landing parks it until `play()`) republished a PTS the queue no longer held, and the line read
    /// `aLead` as old PTS minus re-anchored clock (475 s in the field). The write carries the
    /// generation the pump produced it under and is refused for the marker when the flush is newer;
    /// `parked` and `rebuffering` are the pump's own state and stay unconditional.
    func update(lastAudioPts: Double, parked: Int, rebuffering: Bool, generation: UInt64) {
        lock.lock()
        if generation >= _audioFlushGeneration, !(lastAudioPts.isFinite && lastAudioPts <= _emptiedAudioPts) {
            _lastAudioPts = lastAudioPts
        }
        _parked = parked
        _rebuffering = rebuffering
        lock.unlock()
    }

    /// The seek path emptied the audio queue: nothing is enqueued, so there is no newest PTS, and
    /// writes from before `generation` describe the queue that was flushed.
    func audioFlushed(generation: UInt64) {
        lock.lock()
        if generation >= _audioFlushGeneration {
            _audioFlushGeneration = generation
            _lastAudioPts = .nan
            _emptiedAudioPts = -.infinity
            _sourceExhausted = false
        }
        lock.unlock()
    }

    /// A recovery emptied the audio queue without a new generation: the pump is on the same one and its
    /// local marker still names the flushed audio, so it is the value rather than the generation that
    /// is retired. The next audio the pump enqueues goes beyond it and is taken.
    func audioQueueEmptied() {
        lock.lock()
        if _lastAudioPts.isFinite { _emptiedAudioPts = max(_emptiedAudioPts, _lastAudioPts) }
        _lastAudioPts = .nan
        lock.unlock()
    }

    /// AE#374: the producer will yield nothing further. Set from the demux loops' end-of-media exit,
    /// read by the diagnostic line, which without it describes a finished session as a drifting one.
    func markSourceExhausted() {
        lock.lock()
        _sourceExhausted = true
        lock.unlock()
    }

    var snapshot: (lastAudioPts: Double, parked: Int, rebuffering: Bool, sourceExhausted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (_lastAudioPts, _parked, _rebuffering, _sourceExhausted)
    }
}

// MARK: - Live recording (AE#560)

extension SoftwarePlaybackHost: LiveRecordingHost {

    func recordingStreamDescriptors() -> [RecordingStreamDescriptor] {
        guard let demuxer else { return [] }
        var out: [RecordingStreamDescriptor] = []
        let videoIndex = demuxer.videoStreamIndex
        for index in [videoIndex, demuxer.audioStreamIndex] where index >= 0 {
            guard let stream = demuxer.stream(at: index) else { continue }
            out.append(RecordingStreamDescriptor(
                sourceStreamIndex: index,
                timeBaseNum: stream.pointee.time_base.num,
                timeBaseDen: stream.pointee.time_base.den,
                codecParameters: stream.pointee.codecpar,
                isVideo: index == videoIndex))
        }
        return out
    }

    func setRecordingSink(_ sink: LiveRecordingSink?) {
        recordingSinkLock.lock()
        recordingSink = sink
        recordingSinkLock.unlock()
    }

    /// Demux thread. Non-blocking by the sink's contract.
    nonisolated func tapForRecording(_ packet: UnsafeMutablePointer<AVPacket>) {
        recordingSinkLock.lock()
        let sink = recordingSink
        recordingSinkLock.unlock()
        guard let sink, let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        sink.accept(
            packetBytes: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)),
            sourceStreamIndex: packet.pointee.stream_index,
            pts: packet.pointee.pts,
            dts: packet.pointee.dts,
            duration: packet.pointee.duration,
            isKeyframe: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
        )
    }
}

/// A single background snapshot at a time. Invalidating at seek/stop prevents a delayed snapshot
/// from restoring a discarded range or from clearing a newer request. Main never waits for work.
@MainActor
final class SoftwareResidentRangePublication {
    private var task: Task<Void, Never>?
    private var revision: UInt64 = 0

    func invalidate() {
        revision &+= 1
        task?.cancel()
        task = nil
    }

    @discardableResult
    func sample(_ read: @escaping @Sendable () async -> [ClosedRange<Double>],
                publish: @escaping @MainActor ([ClosedRange<Double>]) -> Void) -> Task<Void, Never>? {
        guard task == nil else { return nil }
        let token = revision
        task = Task { [weak self] in
            let ranges = await BlockingWork.detached(priority: .utility, operation: read).value
            guard let self, !Task.isCancelled, self.revision == token else { return }
            self.task = nil
            publish(ranges)
        }
        return task
    }
}
