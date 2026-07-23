import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Drives one playback session's read-to-mux pipeline via a per-segment
/// `MP4SegmentMuxer` writing into `SegmentCache`. Forward-only; backward
/// scrubs restart with a new instance at a non-zero `baseIndex`.
final class HLSSegmentProducer: @unchecked Sendable {

    // MARK: - Errors

    enum ProducerError: Error, CustomStringConvertible {
        case muxerAllocFailed(code: Int32)
        case streamCreationFailed
        case copyParametersFailed(code: Int32)
        case writeHeaderFailed(code: Int32)

        var description: String {
            switch self {
            case .muxerAllocFailed(let c):     return "HLSSegmentProducer: avformat_alloc_output_context2 for hls failed (\(c))"
            case .streamCreationFailed:        return "HLSSegmentProducer: avformat_new_stream failed"
            case .copyParametersFailed(let c): return "HLSSegmentProducer: avcodec_parameters_copy failed (\(c))"
            case .writeHeaderFailed(let c):    return "HLSSegmentProducer: avformat_write_header failed (\(c))"
            }
        }
    }

    /// Per-stream codec config carried from `HLSVideoEngine` into the muxer setup.
    struct StreamConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let timeBase: AVRational
        /// Override the codec_tag emitted by the mp4 sub-muxer. Used to
        /// force `dvh1` / `hvc1` / `avc1` instead of FFmpeg's defaults
        /// of `hev1` / `h264`, which AVPlayer rejects.
        let codecTagOverride: String?
        /// Strip the dvcC record (P7 on non-DV panel, P8.2). Mutually exclusive with `rewriteDoviConfigTo81`.
        let stripDolbyVisionMetadata: Bool
        /// Per-packet RPU conversion P7 -> 8.1 (HEVC P7 on DV panel). Container dvcC rewrite is separate (`rewriteDoviConfigTo81`).
        let convertP7ToProfile81: Bool
        /// Rewrite container dvcC to valid P8.1 in init.mp4; true for P7-on-DV-panel and malformed-P8.6-on-DV-panel routes.
        let rewriteDoviConfigTo81: Bool
        /// Optional color-signaling override forwarded to `MP4SegmentMuxer.ColorOverride`.
        let colorOverride: MP4SegmentMuxer.ColorOverride?
        /// Optional replacement for `codecpar.extradata` before write_header.
        let extradataOverride: [UInt8]?

        init(
            codecpar: UnsafePointer<AVCodecParameters>,
            timeBase: AVRational,
            codecTagOverride: String?,
            stripDolbyVisionMetadata: Bool = false,
            convertP7ToProfile81: Bool = false,
            rewriteDoviConfigTo81: Bool = false,
            colorOverride: MP4SegmentMuxer.ColorOverride? = nil,
            extradataOverride: [UInt8]? = nil
        ) {
            self.codecpar = codecpar
            self.timeBase = timeBase
            self.codecTagOverride = codecTagOverride
            self.stripDolbyVisionMetadata = stripDolbyVisionMetadata
            self.convertP7ToProfile81 = convertP7ToProfile81
            self.rewriteDoviConfigTo81 = rewriteDoviConfigTo81
            self.colorOverride = colorOverride
            self.extradataOverride = extradataOverride
        }
    }

    /// Audio wiring for stream-copy (e.g. EAC3-JOC Atmos) or FLAC bridge (TrueHD/DTS/PCM).
    struct AudioConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let timeBase: AVRational
        let sourceStreamIndex: Int32
        /// TB of packets passed to av_write_frame: source TB for stream-copy, encoder TB 1/48000 for FLAC bridge.
        let inputTimeBase: AVRational
        /// TB of demuxer packets BEFORE bridge re-stamps them. Gate target is rescaled into this TB; using
        /// inputTimeBase instead landed the target 48x too far into the source for bridged DTS.
        let sourceTimeBase: AVRational
        /// Non-nil routes each packet through bridge.feed and muxes the returned FLAC packets.
        let bridge: AudioBridge?
        /// Strip 7/9-byte ADTS header per frame for MPEG-TS AAC stream-copy into fMP4; engine synthesises the ASC.
        let stripAacAdts: Bool

        init(codecpar: UnsafePointer<AVCodecParameters>,
             timeBase: AVRational,
             sourceStreamIndex: Int32,
             inputTimeBase: AVRational,
             sourceTimeBase: AVRational,
             bridge: AudioBridge?,
             stripAacAdts: Bool = false) {
            self.codecpar = codecpar
            self.timeBase = timeBase
            self.sourceStreamIndex = sourceStreamIndex
            self.inputTimeBase = inputTimeBase
            self.sourceTimeBase = sourceTimeBase
            self.bridge = bridge
            self.stripAacAdts = stripAacAdts
        }
    }

    // MARK: - State

    private let demuxer: Demuxer

    /// Non-nil for demuxed-audio HLS ingest (ARD-style: video-only variant + separate audio rendition).
    /// Pump pull-merges by DTS; audio classified by origin not stream index (numbering is independent,
    /// side index can alias main video index). Owned by HLSVideoEngine.
    private let sideAudioDemuxer: Demuxer?

    /// One-packet lookahead per source for the dual-demuxer pull-merge (yields lower-DTS first).
    private var mergeMainLookahead: UnsafeMutablePointer<AVPacket>?
    private var mergeSideLookahead: UnsafeMutablePointer<AVPacket>?

    /// Synthesized program-clock timestamps for packed-audio HLS (raw ADTS AAC rendition).
    /// FFmpeg's "aac" demuxer ignores Apple's ID3 PRIV anchor; synthesizing from the PRIV
    /// value puts side-audio on the same 90 kHz clock as the video.
    struct PackedAudioSynthClock {
        private(set) var nextPts: Int64
        /// Fallback advance (1024 samples in stream TB) when demuxer duration is zero.
        let fallbackDurationPts: Int64

        init(startPts: Int64, fallbackDurationPts: Int64) {
            self.nextPts = startPts
            self.fallbackDurationPts = max(1, fallbackDurationPts)
        }

        mutating func stamp(packetDuration: Int64) -> Int64 {
            let pts = nextPts
            nextPts += packetDuration > 0 ? packetDuration : fallbackDurationPts
            return pts
        }
    }

    private var packedSideAudioClock: PackedAudioSynthClock?
    /// First EOF on either merge source ends the stream; draining the survivor produces silent/frozen tail.
    private var mergeMainEOF = false
    private var mergeSideEOF = false
    // var (not let): SSAI ad creative arrives on a new video PID mid-pump; re-pointed at the new stream.
    private var videoStreamIndex: Int32
    private let cache: SegmentCache
    /// Segment index offset; 0 for initial-start, non-zero for restart sessions.
    private let baseIndex: Int
    /// The segment index this producer is anchored at (#93 residual: the provider skips firing
    /// restarts at indices the active producer demonstrably covers).
    var anchoredBaseIndex: Int { baseIndex }

    /// Source video TB, carried to rescale timestamps (avformat_write_header rewrites the muxer's TB).
    private let sourceVideoTimeBase: AVRational
    private let videoConfig: StreamConfig
    private let audioConfig: AudioConfig?

    /// Start PTS (source video TB) for each segment at baseIndex+i; used to detect segment crossings.
    private let segmentBoundaries: [Int64]

    /// Live mode: cuts at keyframes past targetSegmentDurationSeconds; ignores segmentBoundaries.
    private let isLive: Bool

    private var liveCurrentSegmentIndex: Int
    private var liveSegmentStartPtsSeconds: Double = 0
    private var liveFirstSegmentOpened = false

    /// Start-PTS (seconds) per live segment index; removed once reported to keep map bounded.
    private var liveSegmentStartByIndex: [Int: Double] = [:]

    /// Fires synchronously on the pump thread per finalized live segment (index, duration, startSeconds, discontinuous).
    var onLiveSegmentFinalized: (@Sendable (Int, Double, Double, Bool) -> Void)?

    /// Forward discontinuity threshold. Distinct from NOPTS-dts repair (+1 tick scale); only fires on genuine multi-second leaps.
    static let discontinuityThresholdSeconds: Double = 10.0

    /// Tighter backward threshold (1.5 s) because any backward leap past the 0.5 s monotonic-glitch ceiling is a program boundary.
    /// 10 s symmetric threshold left a dead zone for short SSAI bumpers (~5 s reset); audio stutter resulted.
    static let discontinuityBackwardThresholdSeconds: Double = 1.5

    /// Derive audio shift so boundary packet lands exactly on the video seam regardless of source base.
    /// Fixes amux ad creatives (Pluto: video clock starts at 0, audio near 2^33); copying video shift directly hangs audio.
    static func seamDerivedAudioShift(
        audioBoundarySrcDts: Int64,
        seamOutAudioTb: Int64
    ) -> Int64 {
        audioBoundarySrcDts - seamOutAudioTb
    }

    /// Raw source PTS of the previous video packet (before shift); used for live discontinuity detection.
    private var lastRawVideoPts: Int64 = Int64.min

    /// Pending #EXT-X-DISCONTINUITY for the next segment; latched on detection, cleared on segment open.
    private var pendingDiscontinuityFlag: Bool = false

    /// Forces a cut at the next keyframe regardless of the 4 s minimum; prevents #EXT-X-DISCONTINUITY arriving one segment late.
    private var pendingForceCutFlag: Bool = false

    /// Set when SSAI program switch moves videoStreamIndex to a new video PID; triggers a fresh muxer (versioned-init EXT-X-MAP).
    private var pendingVideoProgramSwitch: Bool = false

    /// #133 follow-up: whether the pending versioned-init rotation is an SSAI ad creative (new PID, carries its
    /// own DV/color signaling so the program's overrides are dropped) or a same-PID in-band parameter-set change
    /// (encoder restart / regional splice on the same program, whose overrides must be kept). Read by rotateMuxer.
    private var pendingReinitIsAdCreative: Bool = false

    /// Ad creative's video config from in-band SPS/PPS (mid-stream demuxer codecpar has width/height == 0).
    private var pendingAdVideoConfig: (width: Int32, height: Int32, extradata: [UInt8])?

    /// #133 follow-up: Annex-B SPS+PPS backing the CURRENT muxer's avcC box. The fMP4 avcC is frozen at
    /// avformat_write_header, so an in-band parameter-set change on the SAME video PID (encoder restart / regional
    /// opt-out splice, common on UK DVB via Xtream) leaves the panel decoding new slices against a stale avcC ->
    /// green frames + libav "non-existing PPS/SPS" bursts, recurring mid-stream long after the join. Comparing each
    /// keyframe's in-band sets against this triggers a versioned-init muxer rotation (the same EXT-X-MAP path SSAI
    /// uses), independent of whether the demuxer emits AV_PKT_DATA_NEW_EXTRADATA. Set at gate-open and each rotation.
    private var activeMuxerVideoExtradata: [UInt8]?

    /// #133 follow-up diag: count of same-PID in-band parameter-set changes rotated in place, surfaced in the log.
    private var samePIDReinitCount = 0

    /// #133: initial live-join video config reconstructed from the gating IDR's in-band SPS/PPS. Set when a
    /// mid-stream MPEG-TS join left the probed codecpar at 0x0 (probe joined before any SPS); consumed by the
    /// FIRST allocateMuxer so avformat_write_header gets real dimensions instead of failing -22 (dead channel).
    private var pendingJoinVideoConfig: (width: Int32, height: Int32, extradata: [UInt8])?

    /// Cross-stream rebase pairing. Video rebase is master; audio derives its shift from its OWN boundary
    /// srcDts and the shared seam OUTPUT position (not the video shift) so differing audio source bases
    /// (amux ads: video dts 0, audio near 2^33) are absorbed. Delta-based handoff accumulated per-pod A/V
    /// drift; absolute re-anchoring zeroes that. `pendingAudioInheritSeamOut` waits for audio's boundary
    /// packet (video usually crosses first). `lastIndependentAudioRebase` handles audio-first interleave.
    /// All pairing state expires after `rebasePairingWindowSeconds`.
    private var pendingAudioInheritSeamOut: (seamOutAudioTb: Int64, at: Date)? = nil
    private var lastIndependentAudioRebase: (boundarySrcDts: Int64, at: Date)? = nil
    private var pendingAudioShiftOverride: (seamOutAudioTb: Int64, boundarySrcDts: Int64, at: Date)? = nil
    private static let rebasePairingWindowSeconds: TimeInterval = 5.0

    /// Deduplicates AV_PKT_DATA_NEW_EXTRADATA detection (some demuxers re-emit identical side data periodically).
    private var lastSeenVideoExtradata: Data? = nil
    private var codecParamChangeCount = 0

    /// Discontinuity flag per live segment index; mirrors liveSegmentStartByIndex lifetime.
    private var liveSegmentDiscontinuousByIndex: [Int: Bool] = [:]
    private var loggedFirstDiscontinuity: Bool = false

    private let targetSegmentDurationSeconds: Double
    private var currentMuxer: MP4SegmentMuxer?
    private var currentMuxerSegmentIndex: Int = .min

    /// Latched once first muxer emits ftyp+moov bytes; subsequent muxers' init bytes are discarded.
    private var initCaptured: Bool = false

    /// Last valid dts per stream (source TB); used to repair NOPTS dts via lastValidDts+1.
    private var lastVideoSourceDts: Int64 = Int64.min
    private var lastAudioSourceDts: Int64 = Int64.min

    /// First dts ever seen per stream; replay detection: backward rebase landing near this + recent reconnect = server replay.
    private var firstSeenVideoSourceDts: Int64 = Int64.min
    private var firstSeenAudioSourceDts: Int64 = Int64.min

    private static let sourceReplayReconnectWindowSeconds: TimeInterval = 30
    private static let sourceReplayStartWindowSeconds: Double = 10

    /// Fallback duration (source video TB) for the last fragment packet when matroska omits BlockDuration.
    /// mp4 muxer uses pkt->duration only for the last trun sample; duration=0 writes trun.last.sample_duration=0.
    private let videoFallbackDurationPts: Int64

    /// Same for stream-copy audio (AC3/EAC3: frame_size/sample_rate; AAC: 1024/sample_rate).
    private let audioFallbackDurationPts: Int64

    /// One-packet look-behind; next packet's dts fills pending.duration when per-block duration is missing.
    private var pendingVideoPkt: UnsafeMutablePointer<AVPacket>?
    private var pendingAudioPkt: UnsafeMutablePointer<AVPacket>?

    /// Live segment index captured when pending packet was examined; the live cutter advances at keyframes.
    private var pendingVideoSegIndex: Int = 0
    private var pendingAudioSegIndex: Int = 0

    /// VOD keyframe-gated cutter: opens each segment at the IRAP that reaches its plan boundary (#92).
    private var vodCutter: VODSegmentCutter

    private var loggedFirstVideoPktInfo = false
    /// #133 follow-up diag: one-shot confirmation that the demuxer surfaces avcC changes as AV_PKT_DATA_NEW_EXTRADATA.
    private var loggedFirstVideoNewExtradata = false
    private var loggedP7ConversionFailure = false
    private var loggedEnhancementLayerType = false
    /// Latched false at SSAI program switch (ad creatives are H.264; mirrors muxer's isReinit ? false : videoConfig.convertP7ToProfile81).
    private var convertP7Active: Bool = false
    private var loggedFirstDtsBump = false
    private var loggedFirstDtsDrop = false
    private var loggedFirstAudioDtsBump = false

    /// Gate uses AV_PKT_FLAG_KEY (not libavformat's keyframe index) because MKV SimpleBlock keyframe bit can be off.
    /// Audio gate waits for video: without this, a non-IDR-keyframe miss puts video 10+ s past audio ("asynchron").
    private let restartTargetVideoPts: Int64
    private var restartTargetAudioDts: Int64
    private var audioWaitForVideo: Bool
    private var firstActualVideoDts: Int64 = Int64.min
    private var firstActualAudioDts: Int64 = Int64.min

    /// Forward-only producer restart counter; surfaced in live telemetry. Written on pump thread, read under packetCounterLock.
    var restartCount: Int {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _restartCount
    }
    private var _restartCount: Int = 0
    func bumpRestartCount() {
        packetCounterLock.lock()
        _restartCount &+= 1
        packetCounterLock.unlock()
    }

    /// Audio-gate vs. video-gate gap in source-clock ms; read under packetCounterLock by telemetry sampler.
    var lastAVGapMs: Double {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _lastAVGapMs
    }
    private var _lastAVGapMs: Double = 0
    private func setLastAVGapMs(_ value: Double) {
        packetCounterLock.lock()
        _lastAVGapMs = value
        packetCounterLock.unlock()
    }

    /// PTS of first kept video packet (AV_PKT_FLAG_KEY); used to drop HEVC RASL leading B-frames (open-GOP CRA).
    private var firstActualVideoPts: Int64 = Int64.min
    private var loggedFirstLeadingDrop: Bool = false
    /// Head-of-stream audio frames preceding the video anchor, dropped because the output
    /// timeline starts at 0 and the muxer no longer absorbs negative timestamps.
    private var droppedLeadingAudioCount: Int = 0

    /// Pre-gate drop counters; surface the "lädt unendlich" failure mode when the gate never opens.
    private var pregateVideoDropCount: Int = 0
    private var pregateWaitStart: Date?
    private static let liveKeyframeGateTimeoutSeconds: TimeInterval = 15

    private var audioGateWaitStart: Date?
    /// 5 s is generous; a backward source-clock reset between video gate-open and first audio packet strands the target.
    private static let liveAudioGateTimeoutSeconds: TimeInterval = 5
    private var pregateAudioDropCount: Int = 0

    /// #74: head-of-stream audio that arrives before the first video packet, buffered (in read order)
    /// while the video gate is still waiting, then replayed in DTS order once it opens. Each entry owns
    /// its AVPacket. Without this the gate dropped the entire leading second of a wide-interleave source
    /// (audio muxed ahead of video), leaving a constant ~1 s A/V desync. Bounded by a byte cap; above it
    /// the original drop resumes.
    private var pregateAudioBuffer: [(UnsafeMutablePointer<AVPacket>, PacketOrigin)] = []
    private var pregateAudioBufferBytes: Int = 0
    private var pregateAudioReplaySorted = false
    private var pregateAudioOverflowLogged = false
    private static let maxPregateAudioBufferBytes = 8 * 1024 * 1024

    /// Wall-clock of last finalized live segment; drives no-cut stall watchdog.
    private var lastLiveSegmentFinalizeAt: Date?
    /// Cutter-wedge timeout: pump reads at full rate but finalizes no segment (hostile SSAI ad pod).
    private static let liveSegmentStallTimeoutSeconds: TimeInterval = 10
    /// Source-starvation timeout: feed trickles (slow/flaky CDN). Ingest retries ~31 s then terminates;
    /// escalating at the tight wedge timeout turns one slow segment into a full host retune (device repro: hung on -1001).
    private static let liveSourceStarvationTimeoutSeconds: TimeInterval = 35
    /// Read rate (pkt/s) threshold classifying a no-cut stall as cutter-wedge vs. source-starvation.
    /// Healthy 1080p25: ~60 pkt/s. Rate-based to avoid misreading a trickle that accumulated a high count (Alex Berlin: 137 pkts/13 s = 10.5 pkt/s).
    private static let liveWedgeProgressRateThreshold: Double = 40
    /// #177: minimum video PTS advance (seconds) within a no-cut window for the stall to be
    /// reclassified as slow-but-healthy delivery (hold + re-arm) instead of a cutter wedge (retune).
    private static let liveSlowDeliveryPtsAdvanceSeconds: Double = 2
    /// #177: consecutive holds before a slow-delivery stall escalates to the host retune anyway.
    static let liveSlowDeliveryMaxHolds = 6

    /// #177 outcome of one no-cut watchdog evaluation.
    enum NoCutStallAction: Equatable {
        case keepReading
        case holdForSlowDelivery
        case exitForRetune
    }

    /// #177 pure decision: a wedge-classified no-cut stall whose video PTS is still advancing is a
    /// source delivering just below real-time (a 6 s segment simply has not fully arrived inside the
    /// 10 s timeout), not a stuck cutter. Retuning it re-joins behind the live edge, drains the buffer,
    /// and loops. Hold and re-arm instead, bounded by `liveSlowDeliveryMaxHolds`. A genuine SSAI wedge
    /// reads at full rate with frozen video PTS and still exits immediately; the source-starvation
    /// classification is untouched (its 35 s window with barely-advancing PTS is a dead source).
    static func noCutStallAction(
        stalledFor: TimeInterval,
        readRate: Double,
        videoPtsAdvanceSeconds: Double,
        consecutiveHolds: Int
    ) -> NoCutStallAction {
        let isWedge = readRate >= liveWedgeProgressRateThreshold
        let timeout = isWedge ? liveSegmentStallTimeoutSeconds : liveSourceStarvationTimeoutSeconds
        guard stalledFor > timeout else { return .keepReading }
        if isWedge,
           videoPtsAdvanceSeconds >= liveSlowDeliveryPtsAdvanceSeconds,
           consecutiveHolds < liveSlowDeliveryMaxHolds {
            return .holdForSlowDelivery
        }
        return .exitForRetune
    }
    private var lastPregateVideoLog: Int = 0
    private var lastPregateAudioLog: Int = 0
    private static let pregateLogInterval = 200

    /// Desired tfdt for each stream: 0 for baseIndex==0; plan[baseIndex].startSeconds for restarts.
    private let desiredFirstVideoTfdtPts: Int64
    private var desiredFirstAudioTfdtPts: Int64

    /// Dynamic PTS shift = firstActualDts - desiredFirstTfdt; Int64.min = not yet computed.
    private var videoShiftPts: Int64 = Int64.min
    private var audioShiftPts: Int64 = Int64.min

    /// Max segments ahead of AVPlayer's highest fetched segment. Historically a constant (cut from 20 to
    /// 10; 4K HEVC ~10 MB/seg = 200 MB old buffer); now per session from `LoadOptions.forwardBufferSegments`
    /// via `HLSVideoEngine.forwardWindowSegments`. MUST equal the SegmentCache's forwardWindow so the muxer
    /// never writes past the cache's forward edge (a drift is exactly what stalls AVPlayer).
    private let bufferAheadSegments: Int

    /// #65 stall diag: only log a park once it exceeds ~2 segment durations of zero playback progress, so normal
    /// backpressure (releases within one segment) stays silent and a real wedge surfaces its frozen tuple.
    private static let backpressureWedgeLogThresholdSeconds = 12

    /// #65 watchdog: break a VOD backpressure park once the consumer fetch target has been frozen this long.
    /// Set above the log threshold so the diag tuple surfaces first. The host then re-anchors the producer on
    /// AVPlayer's real position; a slow-but-advancing consumer never trips the detector (see BackpressureWedgeDetector).
    private static let backpressureWedgeBreakThresholdSeconds = 24

    /// #93 retest fast path: break the park once the consumer fetch target AND the rendered clock have
    /// both been frozen this long while the consumer wants to play (rrgomes: the clock is provably flat
    /// within ~3 s of the park; the 24 s counter alone put recovery latency at 30-70 s). Only effective
    /// when `playbackPositionProvider` is wired; the dual-freeze guard is what keeps the short window
    /// safe (see BackpressureWedgeDetector.fastBreakThresholdSeconds).
    private static let backpressureWedgeFastBreakThresholdSeconds = 5

    private let pumpQueue = DispatchQueue(
        label: "AetherEngine.HLSSegmentProducer.pump",
        qos: .userInitiated
    )

    private let stateLock = NSLock()
    private var pumpStarted = false
    private var shouldStop = false
    /// #65: set when awaitBackpressureRelease breaks a frozen VOD park. runPumpLoop maps the resulting
    /// muxer-nil exit to .backpressureWedge so the host re-anchors rather than treating it as a failure.
    private var _backpressureWedgeBroken = false

    /// Video packet write counter; excludes bridge packets (different path). Read under packetCounterLock.
    private let packetCounterLock = NSLock()
    private var _packetsWrittenCount: Int = 0
    var packetsWrittenCount: Int {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _packetsWrittenCount
    }
    private func bumpPacketsWritten() {
        packetCounterLock.lock()
        _packetsWrittenCount &+= 1
        packetCounterLock.unlock()
    }

    /// AE#169 round 3: pregate observability for the engine's starved-EOF re-anchor arm. A pump
    /// whose scan-forward gate never opened wrote nothing; the last keyframe it dropped BELOW the
    /// target is the true final random-access point the engine can re-anchor production on.
    private var _videoGateOpened = false
    private var _lastPregateDroppedKeyframePts: Int64 = Int64.min
    var videoGateOpened: Bool {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _videoGateOpened
    }
    var lastPregateDroppedKeyframePts: Int64 {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _lastPregateDroppedKeyframePts
    }
    var hasRestartTarget: Bool { restartTargetVideoPts != Int64.min }
    private func markVideoGateOpened() {
        packetCounterLock.lock()
        _videoGateOpened = true
        packetCounterLock.unlock()
    }
    private func notePregateDroppedKeyframe(pts: Int64) {
        packetCounterLock.lock()
        if pts > _lastPregateDroppedKeyframePts { _lastPregateDroppedKeyframePts = pts }
        packetCounterLock.unlock()
    }

    /// AE#169 round 3 pure decision: whether a video packet opens the restart scan-forward gate.
    /// The gate target is a plan-boundary PTS (`segmentPlan[baseIndex].startPts`), so the packet
    /// is judged by presentation time. Comparing DTS dropped the exact IRAP the restart seeked
    /// for (a keyframe's DTS sits a reorder delay below its own PTS; same defect class as the #92
    /// cutter fix): mid-file the next IRAP rescued the miss one GOP late, but at the file tail no
    /// later IRAP exists, so the unbounded VOD gate starved to EOF with zero packets written.
    static func videoGateTargetSatisfied(pts: Int64, dts: Int64, targetPts: Int64) -> Bool {
        if targetPts == Int64.min { return true }
        let ts = pts != Int64.min ? pts : dts
        return ts != Int64.min && ts >= targetPts
    }

    var muxerLifetimeFragmentBytes: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentMuxer?.lifetimeFragmentBytesEmitted ?? 0
    }

    var muxerFragmentCuts: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentMuxer?.fragmentCutCount ?? 0
    }

    private let finishCondition = NSCondition()
    private var didFinishFlag = false
    var didFinish: Bool {
        finishCondition.lock()
        defer { finishCondition.unlock() }
        return didFinishFlag
    }

    /// Fires once per producer when HDR10+ T.35 SEI prefix (B5 00 3C 00 01 04) first appears in a video packet.
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?

    /// Fires at video gate-open with videoShiftPts (source video TB); re-fires on restart (matroska seek imprecision can shift).
    var onVideoShiftKnown: (@Sendable (Int64) -> Void)?

    /// Fires at live program boundary with updated videoShiftPts and seamOutputSeconds (AVPlayer clock position of the seam).
    /// Distinct from onVideoShiftKnown: the new shift is at the producer edge, AVPlayer renders it buffer+holdback later.
    var onLiveTimelineRebase: (@Sendable (_ shiftPts: Int64, _ seamOutputSeconds: Double) -> Void)?

    enum PumpExitReason: Sendable, CustomStringConvertible {
        case eof
        case stopRequested
        case readError(code: Int32)
        case muxerFailed
        /// No AV_PKT_FLAG_KEY video packet within timeout; live only (VOD waits unbounded).
        case keyframeStarvation
        /// Backward PTS reset to session origin after unplanned reconnect: server replay-from-start, exits terminally.
        case sourceReplay
        /// Pump read packets but finalized no segment for stall window (hostile SSAI ad pod wedge).
        case segmentStall
        /// VOD backpressure park frozen past the break threshold (consumer fetch target stuck, AVPlayer
        /// wedged and issuing no forward request). Host re-anchors the producer on AVPlayer's real
        /// position (#65). Live keeps its own watchdogs; this only fires on VOD.
        case backpressureWedge

        var description: String {
            switch self {
            case .eof: return "eof"
            case .stopRequested: return "stopRequested"
            case .readError(let code): return "readError(\(code))"
            case .muxerFailed: return "muxerFailed"
            case .keyframeStarvation: return "keyframeStarvation"
            case .sourceReplay: return "sourceReplay"
            case .segmentStall: return "segmentStall"
            case .backpressureWedge: return "backpressureWedge"
            }
        }
    }

    /// Whether the pump-exit in-flight segment may be adopted into the cache. A teardown mid-VOD
    /// (restart, wedge break, read error) leaves it PARTIAL: shorter content than the playlist's
    /// EXTINF under a full segment's index, with video and audio ending at different interleave
    /// drain points. Byte-budgeted retention keeps such a segment replayable (device: seeking back
    /// to 0 played a teardown-partial with ~2 s of A/V split), so VOD adopts only the natural EOF
    /// tail (a legitimately short final segment). Live always adopts: its playlist advertises the
    /// ACTUAL duration via reportLiveSegmentFinalized, so a short live tail is not a lie.
    static func shouldAdoptTeardownSegment(exitReason: PumpExitReason, isLive: Bool) -> Bool {
        if isLive { return true }
        if case .eof = exitReason { return true }
        return false
    }

    var onPumpFinished: (@Sendable (PumpExitReason) -> Void)?

    /// #65: reads whether AVPlayer currently wants to play (`timeControlStatus != .paused`), off the main
    /// actor. nil = assume wanting to play (preserves prior behaviour for tests + the live path). A paused
    /// consumer issues no forward fetch, so the VOD backpressure wedge detector must suspend while this is
    /// false instead of misreading the frozen fetch target as a wedge (issue #65 pause false-positive).
    var wantsToPlayProvider: (@Sendable () -> Bool)?

    /// #93 retest: reads AVPlayer's rendered (playlist-axis) position off the main actor. Feeds the
    /// backpressure wedge detector's fast path (park + flat clock + frozen fetch target -> single-digit
    /// detection instead of the 24 s counter). nil (tests, live) keeps the fast path inert.
    var playbackPositionProvider: (@Sendable () -> Double?)?

    /// #35/#93 startup guard: reads whether AVPlayer has ever presented a frame this item (its
    /// `timeControlStatus` reached `.playing` at least once), off the main actor. nil = assume started
    /// (preserves prior behaviour for tests + live). While false, the VOD backpressure wedge detector
    /// suspends: a flat rendered clock during cold pre-roll is not a wedge, and re-anchoring there flushes
    /// AVPlayer's forward buffer and livelocks a slow high-bitrate DV-master start ("loads forever").
    var hasStartedRenderingProvider: (@Sendable () -> Bool)?

    /// #77: in-band CC tap. When `closedCaptionStreamIndex >= 0` that source stream is kept (not
    /// discarded) and each of its packets is handed to `closedCaptionObserver` (read-only) then dropped,
    /// never muxed (output byte-identical). Set via init so it's in the keep-set; observer attached after.
    var closedCaptionStreamIndex: Int32 = -1
    var closedCaptionObserver: (@Sendable (UnsafePointer<AVPacket>, AVRational) -> Void)?

    /// #131: A53/SEI caption extraction. When set (the session has no demuxable CC stream) and the
    /// video codec is H.264/HEVC, every muxed video packet is scanned (GA94 prefilter, see
    /// `A53SEIParser`) and extracted cc_data triplets are handed over with the packet's
    /// source-timebase pts/dts, in decode order. Same lifecycle as `closedCaptionObserver`:
    /// attached after init, re-threaded onto every restart producer.
    var a53CaptionObserver: (@Sendable ([CCDataParser.CCTriplet], Int64, Int64, AVRational) -> Void)?
    private let a53CodecKind: A53SEIParser.CodecKind?
    private let a53NALFraming: A53SEIParser.NALFraming

    /// #133: latched at init. When true, the video gate withholds until a decodable IDR access unit
    /// (in-band SPS+PPS+IDR) arrives, rather than opening on any AV_PKT_FLAG_KEY packet.
    private let liveH264AnnexBJoin: Bool

    /// Sodalite#32: text-subtitle tap, generalizing the #77 CC tap. Streams in this set are kept by the
    /// pump (not discarded) and each of their packets is handed to `subtitleTapObserver` (with the
    /// stream's time_base), then dropped below as a foreign packet, never muxed. The pump already reads
    /// the source's full interleave, so harvesting subtitle packets here costs no extra bandwidth: the
    /// session's cue stores fill for exactly the region the producer has produced, across restarts.
    /// Set at init (BEFORE the discard block: a post-init assignment came too late, the demuxer had
    /// already discarded the subtitle streams and only open-time queued packets ever reached the tap;
    /// device repro: readMax frozen at 5.2s on a resumed remote MKV).
    var subtitleTapStreamIndices: Set<Int32>
    var subtitleTapObserver: (@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational) -> Void)?
    private var subtitleTapTimeBases: [Int32: AVRational] = [:]

    /// #112 rework: ALL embedded subtitle streams stay in the keep-set; their packets feed the
    /// session's SubtitlePacketStore via this sink. Same tapped-then-dropped contract as
    /// `subtitleTapObserver`, set at init BEFORE the discard block for the same reason.
    var subtitlePacketStreamIndices: Set<Int32>
    var subtitlePacketSink: (@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational) -> Void)?
    private var closedCaptionStreamTimeBase = AVRational(num: 1, den: 1)

    /// Set by engine live-reopen path so the fresh producer marks its first segment with #EXT-X-DISCONTINUITY.
    var firstSegmentDiscontinuous = false

    private var hdr10PlusDetected = false

    /// Replay-from-start check: backward jump + lands near first-seen dts + recent unplanned reconnect = server replay.
    private func isSourceReplay(newDts: Int64,
                                jumpTicks: Int64,
                                firstSeenDts: Int64,
                                tbSeconds: Double,
                                stream: String) -> Bool {
        guard jumpTicks < 0, firstSeenDts != Int64.min, tbSeconds > 0 else { return false }
        guard let reconnectAt = demuxer.lastUnplannedSourceReconnectAt,
              Date().timeIntervalSince(reconnectAt) < Self.sourceReplayReconnectWindowSeconds
        else { return false }
        let windowTicks = Int64(Self.sourceReplayStartWindowSeconds / tbSeconds)
        guard newDts <= firstSeenDts + windowTicks else { return false }
        EngineLog.emit(
            "[HLSSegmentProducer] live source REPLAY detected on \(stream): "
            + "srcDts=\(newDts) firstSeenDts=\(firstSeenDts) jumpTicks=\(jumpTicks) "
            + "reconnect \(String(format: "%.1f", Date().timeIntervalSince(reconnectAt)))s ago; "
            + "server restarted the stream from its beginning, exiting pump for host retune",
            category: .session
        )
        return true
    }

    // MARK: - Init

    init(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        video: StreamConfig,
        audio: AudioConfig? = nil,
        sideAudioDemuxer: Demuxer? = nil,
        cache: SegmentCache,
        baseIndex: Int = 0,
        targetSegmentDurationSeconds: Double = 6.0,
        videoFallbackDurationPts: Int64,
        audioFallbackDurationPts: Int64 = 0,
        restartTargetVideoPts: Int64 = Int64.min,
        closedCaptionStreamIndex: Int32 = -1,
        subtitleTapStreamIndices: Set<Int32> = [],
        subtitlePacketStreamIndices: Set<Int32> = [],
        desiredFirstVideoTfdtPts: Int64,
        desiredFirstAudioTfdtPts: Int64 = 0,
        segmentBoundaries: [Int64],
        isLive: Bool = false,
        packedSideAudioStartPts: Int64? = nil,
        packedSideAudioFallbackDurationPts: Int64 = 0,
        bufferAheadSegments: Int = 10
    ) throws {
        self.bufferAheadSegments = bufferAheadSegments
        self.demuxer = demuxer
        self.sideAudioDemuxer = sideAudioDemuxer
        // Packed side audio: synthesize timestamps from ID3 PRIV anchor; TS-side sessions use real timestamps.
        if let startPts = packedSideAudioStartPts {
            self.packedSideAudioClock = PackedAudioSynthClock(
                startPts: startPts,
                fallbackDurationPts: packedSideAudioFallbackDurationPts
            )
        }
        self.videoStreamIndex = videoStreamIndex
        self.closedCaptionStreamIndex = closedCaptionStreamIndex   // #77: before the discard block below
        self.subtitleTapStreamIndices = subtitleTapStreamIndices   // Sodalite#32: same reason
        self.subtitlePacketStreamIndices = subtitlePacketStreamIndices   // #112 rework: same reason
        self.videoConfig = video
        switch video.codecpar.pointee.codec_id {
        case AV_CODEC_ID_H264: a53CodecKind = .h264
        case AV_CODEC_ID_HEVC: a53CodecKind = .hevc
        default: a53CodecKind = nil
        }
        a53NALFraming = A53SEIParser.nalFraming(
            codec: a53CodecKind ?? .h264,
            extradata: video.codecpar.pointee.extradata.map { UnsafePointer($0) },
            size: Int(video.codecpar.pointee.extradata_size))
        self.liveH264AnnexBJoin = Self.liveH264JoinRequiresParameterSets(
            isLive: isLive,
            codecIsH264: a53CodecKind == .h264,
            framingIsAnnexB: a53NALFraming == .annexB)
        self.convertP7Active = video.convertP7ToProfile81
        self.audioConfig = audio
        self.cache = cache
        self.baseIndex = baseIndex
        self.sourceVideoTimeBase = video.timeBase
        self.targetSegmentDurationSeconds = targetSegmentDurationSeconds
        self.segmentBoundaries = segmentBoundaries
        self.vodCutter = VODSegmentCutter(boundaries: segmentBoundaries, baseIndex: baseIndex)
        self.isLive = isLive
        self.liveCurrentSegmentIndex = baseIndex
        self.videoFallbackDurationPts = videoFallbackDurationPts
        self.audioFallbackDurationPts = audioFallbackDurationPts
        self.restartTargetVideoPts = restartTargetVideoPts
        // Audio target set dynamically once video gate opens (rescaled to audio TB).
        self.restartTargetAudioDts = Int64.min
        // Audio always waits for video: some MKV remuxes (Bluey BD) have a non-IDR first packet;
        // anchoring audio early would desync by firstVideoKeyDts - firstAudioDts even with tfdt == 0.
        self.audioWaitForVideo = true
        self.desiredFirstVideoTfdtPts = desiredFirstVideoTfdtPts
        self.desiredFirstAudioTfdtPts = desiredFirstAudioTfdtPts

        // Discard streams we don't read (matroska queues PGS bitmaps, secondary audio -- heap churn).
        // Dual-demuxer: side audio index can alias a main-demuxer stream, so keep sets are split.
        if let side = sideAudioDemuxer {
            var keep: Set<Int32> = [videoStreamIndex]
            if closedCaptionStreamIndex >= 0 { keep.insert(closedCaptionStreamIndex) }   // #77
            keep.formUnion(subtitleTapStreamIndices)   // Sodalite#32
            keep.formUnion(subtitlePacketStreamIndices)   // #112 rework
            demuxer.discardAllStreamsExcept(keep)
            if let audio = audio {
                side.discardAllStreamsExcept([audio.sourceStreamIndex])
            }
        } else {
            var keep: Set<Int32> = [videoStreamIndex]
            if let audio = audio {
                keep.insert(audio.sourceStreamIndex)
            }
            if closedCaptionStreamIndex >= 0 { keep.insert(closedCaptionStreamIndex) }   // #77
            keep.formUnion(subtitleTapStreamIndices)   // Sodalite#32
            keep.formUnion(subtitlePacketStreamIndices)   // #112 rework
            demuxer.discardAllStreamsExcept(keep)
        }
        // #77: cache the CC stream's time_base for the observer's PTS conversion.
        if closedCaptionStreamIndex >= 0 {
            closedCaptionStreamTimeBase = demuxer.stream(at: closedCaptionStreamIndex)?.pointee.time_base
                ?? AVRational(num: 1, den: 1)
        }
        // Sodalite#32 + #112 rework: same for the tapped subtitle streams.
        for idx in subtitleTapStreamIndices.union(subtitlePacketStreamIndices) {
            subtitleTapTimeBases[idx] = demuxer.stream(at: idx)?.pointee.time_base
                ?? AVRational(num: 1, den: 1000)
        }

        let audioDesc = audio.map { a -> String in
            let mode = a.bridge != nil ? "bridge" : "stream-copy"
            let origin: String
            if packedSideAudioClock != nil {
                origin = " (side demuxer, packed synth clock start=\(packedSideAudioStartPts ?? 0))"
            } else if sideAudioDemuxer != nil {
                origin = " (side demuxer)"
            } else {
                origin = ""
            }
            return " audio=\(mode)\(origin) inTb=\(a.inputTimeBase.num)/\(a.inputTimeBase.den)"
        } ?? ""
        EngineLog.emit(
            "[HLSSegmentProducer] init OK (baseIndex=\(baseIndex), "
            + "segments=\(max(0, segmentBoundaries.count - 1)), "
            + "targetDur=\(String(format: "%.3f", targetSegmentDurationSeconds))s, "
            + "srcVideoTb=\(video.timeBase.num)/\(video.timeBase.den))"
            + audioDesc,
            category: .session
        )
    }

    /// Returns absolute segment index for a live video packet; cuts on keyframes past targetSegmentDurationSeconds.
    private func liveVideoSegmentIndex(pts: Int64, isKeyframe: Bool) -> Int {
        let ptsSeconds = Double(pts) * sourceVideoTbSeconds
        if !liveFirstSegmentOpened {
            liveFirstSegmentOpened = true
            liveCurrentSegmentIndex = baseIndex
            liveSegmentStartPtsSeconds = ptsSeconds
            liveSegmentStartByIndex[liveCurrentSegmentIndex] = ptsSeconds
            liveSegmentDiscontinuousByIndex[liveCurrentSegmentIndex] = firstSegmentDiscontinuous
            // A boundary before the first segment has nothing to separate.
            pendingForceCutFlag = false
            return liveCurrentSegmentIndex
        }
        // pendingForceCutFlag cuts at the next keyframe regardless of the 4 s minimum,
        // so #EXT-X-DISCONTINUITY lands on the first IRAP of the new program (not one segment late).
        if isKeyframe,
           pendingForceCutFlag
            || ptsSeconds - liveSegmentStartPtsSeconds >= targetSegmentDurationSeconds {
            liveCurrentSegmentIndex += 1
            liveSegmentStartPtsSeconds = ptsSeconds
            liveSegmentStartByIndex[liveCurrentSegmentIndex] = ptsSeconds
            pendingForceCutFlag = false
            liveSegmentDiscontinuousByIndex[liveCurrentSegmentIndex] = pendingDiscontinuityFlag
            pendingDiscontinuityFlag = false
        }
        return liveCurrentSegmentIndex
    }

    private var sourceVideoTbSeconds: Double {
        guard sourceVideoTimeBase.num > 0, sourceVideoTimeBase.den > 0 else { return 0 }
        return Double(sourceVideoTimeBase.num) / Double(sourceVideoTimeBase.den)
    }

    /// Map post-shift pts to absolute segment index. Folds shift back before comparing against source-axis boundaries.
    private func segmentIndex(forSourcePts pts: Int64) -> Int {
        let absolute = videoShiftPts == Int64.min ? pts : pts &+ videoShiftPts
        return baseIndex + Self.segmentOffset(forAbsolutePts: absolute, boundaries: segmentBoundaries)
    }

    /// 0-based segment offset for `absolute` within the sorted-ascending `boundaries`: segment i spans
    /// [boundaries[i], boundaries[i+1]), clamped to [0, count-2]. Binary search, exactly equivalent to the
    /// former linear "first i where absolute < boundaries[i+1]" scan but O(log n) instead of O(n) per packet
    /// (the scan walked ~one compare per elapsed segment, growing across a VOD title). Returns 0 if empty.
    static func segmentOffset(forAbsolutePts absolute: Int64, boundaries: [Int64]) -> Int {
        let count = boundaries.count
        guard count > 0 else { return 0 }
        // upperBound: first index whose boundary is > absolute (i.e. how many boundaries are <= absolute).
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if boundaries[mid] <= absolute { lo = mid + 1 } else { hi = mid }
        }
        return min(max(lo - 1, 0), max(0, count - 2))
    }

    /// Returns muxer for targetIdx, advancing/allocating as needed. Forward-only: clamps late packets
    /// (HEVC RASL B-frames, FLAC bridge lag) upward to avoid premature finalize. Returns nil on stop/alloc failure.
    private func ensureMuxer(forSegmentIndex targetIdx: Int) -> MP4SegmentMuxer? {
        let effectiveIdx = max(targetIdx, currentMuxerSegmentIndex)

        if let m = currentMuxer, m.currentSegmentIndex == effectiveIdx {
            return m
        }

        if currentMuxer == nil {
            // #133: pendingJoinVideoConfig is non-nil only when a live H.264 join reconstructed dimensions
            // from in-band SPS/PPS because the probe left codecpar at 0x0. Consumed once, here.
            let joinConfig = pendingJoinVideoConfig
            pendingJoinVideoConfig = nil
            return allocateMuxer(initialSegmentIndex: effectiveIdx, reconstructedVideoConfig: joinConfig)
        }
        // SSAI program switch: new video codec params need a fresh muxer (versioned EXT-X-MAP).
        if pendingVideoProgramSwitch, effectiveIdx > currentMuxerSegmentIndex {
            return rotateMuxerForProgramSwitch(to: effectiveIdx)
        }
        return advanceMuxer(to: effectiveIdx)
    }

    private func rotateMuxerForProgramSwitch(to newIdx: Int) -> MP4SegmentMuxer? {
        let finishedIdx = currentMuxerSegmentIndex
        finalizeSessionMuxerAndAdopt() // adopts finishedIdx, nils currentMuxer
        pendingVideoProgramSwitch = false
        let isAdCreative = pendingReinitIsAdCreative
        pendingReinitIsAdCreative = false
        guard let adConfig = pendingAdVideoConfig else {
            EngineLog.emit(
                "[HLSSegmentProducer] program switch: no parsed ad video config; "
                + "cannot re-init muxer",
                category: .session
            )
            return nil
        }
        pendingAdVideoConfig = nil
        // #133 follow-up: same trigger and versioned-init path, two origins. SSAI = new video PID (ad creative,
        // its own signaling). Same-PID = in-band SPS/PPS change on the running program (encoder restart / splice),
        // whose DV/color overrides must be kept, so only versionedInit is set, not isAdCreative.
        EngineLog.emit(
            "[HLSSegmentProducer] muxer rotation (\(isAdCreative ? "SSAI program switch" : "same-PID parameter-set change")): "
            + "seg-\(finishedIdx) finalized on old init, fresh versioned init for seg-\(newIdx) "
            + "(\(adConfig.width)x\(adConfig.height))",
            category: .session
        )
        return allocateMuxer(initialSegmentIndex: newIdx,
                             reconstructedVideoConfig: adConfig,
                             versionedInit: true,
                             isAdCreative: isAdCreative)
    }

    /// Extract H.264 ad video config from in-band Annex-B SPS/PPS. nil on mid-GOP join (no parameter sets).
    private func extractAdVideoConfig(_ packet: UnsafeMutablePointer<AVPacket>) -> (width: Int32, height: Int32, extradata: [UInt8])? {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
        let buf = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
        guard let (sps, pps) = H264SPS.extractSPSandPPS(fromAnnexB: buf),
              let dim = H264SPS.dimensions(fromNAL: sps) else { return nil }
        return (Int32(dim.width), Int32(dim.height),
                H264SPS.annexBExtradata(sps: sps, pps: pps))
    }

    /// #133: whether the stricter live-join gate engages (withhold the video gate until a decodable IDR
    /// access unit arrives). Only for live H.264 with Annex-B framing, i.e. MPEG-TS ingest joining
    /// mid-broadcast: fMP4 live carries valid out-of-band avcC so its keyframes are already decodable, and
    /// VOD probes the full file up front. HEVC keeps the existing AV_PKT_FLAG_KEY gate.
    static func liveH264JoinRequiresParameterSets(isLive: Bool, codecIsH264: Bool, framingIsAnnexB: Bool) -> Bool {
        isLive && codecIsH264 && framingIsAnnexB
    }

    /// #133 follow-up pure decision: a mid-stream keyframe's in-band SPS/PPS diverge from the sets backing the
    /// current muxer's avcC, so the frozen avcC no longer describes the incoming slices (stale-avcC green frames).
    /// Returns false when there is no active baseline yet (`active == nil`, first keyframe of the epoch establishes
    /// it) or the sets are byte-identical (the routine SPS/PPS repetition MPEG-TS carries before every IDR).
    static func parameterSetsDiverged(active: [UInt8]?, incoming: [UInt8]) -> Bool {
        guard let active else { return false }
        return active != incoming
    }

    /// #133 join gate: a decodable H.264 access unit at a mid-stream join needs in-band SPS + PPS and a true
    /// IDR slice (not an open-GOP recovery point). Returns the reconstructed (width, height, Annex-B extradata)
    /// so a zero-dimension probe codecpar can be backfilled into the first muxer. nil until such an AU arrives.
    private func extractJoinVideoConfig(_ packet: UnsafeMutablePointer<AVPacket>) -> (width: Int32, height: Int32, extradata: [UInt8])? {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
        let buf = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
        guard let (sps, pps) = H264SPS.extractSPSandPPS(fromAnnexB: buf),
              H264SPS.containsIDR(fromAnnexB: buf),
              let dim = H264SPS.dimensions(fromNAL: sps) else { return nil }
        return (Int32(dim.width), Int32(dim.height),
                H264SPS.annexBExtradata(sps: sps, pps: pps))
    }

    /// Pump-side backpressure wait. Returns true on release, false when stop was requested.
    /// #65 diag: an abnormally long park (no playback progress for > threshold) surfaces the producer-vs-AVPlayer
    /// index tuple once, then every 10 s, so a VOD wedge (cacheTarget frozen below target with no watchdog to break
    /// it) is distinguishable from healthy backpressure (cacheTarget climbing toward target). VOD only; live keeps
    /// its own watchdogs.
    private func awaitBackpressureRelease(target: Int, head: Int, context: String) -> Bool {
        // Already broken on this session (e.g. a teardown-flush ensureMuxer call): stay broken, don't re-park.
        if isBackpressureWedgeBroken() { return false }
        var parked = 0
        var nextLogAt = Self.backpressureWedgeLogThresholdSeconds
        // #65 Piece A: a genuine VOD wedge is the consumer fetch target frozen past the break threshold.
        // The detector resets whenever the target advances, so healthy backpressure (slow CDN, cold cache)
        // keeps the target climbing and never trips. Live keeps its own pump watchdogs.
        // #93 retest: the fast path additionally watches the rendered clock; target AND clock both frozen
        // for the short window while the consumer wants to play breaks in single-digit seconds.
        var wedgeDetector = BackpressureWedgeDetector(
            breakThresholdSeconds: Self.backpressureWedgeBreakThresholdSeconds,
            fastBreakThresholdSeconds: Self.backpressureWedgeFastBreakThresholdSeconds,
            initialTarget: cache.targetIndex,
            initialRenderedPosition: playbackPositionProvider?()
        )
        while !checkShouldStop() {
            if cache.awaitFetchHighWater(reaching: target, timeout: 1.0) {
                if parked >= Self.backpressureWedgeLogThresholdSeconds {
                    EngineLog.emit(
                        "[HLSSegmentProducer] #65 backpressure released (\(context)) head=\(head) "
                        + "target=\(target) after=\(parked)s cacheTarget=\(cache.targetIndex) "
                        + "highStored=\(cache.highestStoredIndex) cached=\(cache.count)",
                        category: .session
                    )
                }
                return true
            }
            parked += 1
            let cacheTarget = cache.targetIndex
            // #65 pause false-positive: a paused/backgrounded VOD consumer issues no forward fetch, so its
            // frozen fetch target is not a wedge. Gate the detector on play intent (nil provider = assume
            // playing, unchanged for live + tests); the legit starved-but-wants-to-play wedge keeps tripping.
            let wantsToPlay = wantsToPlayProvider?() ?? true
            // #35/#93 cold-startup: before the first frame lands a flat clock is pre-roll, not a wedge.
            let hasStarted = hasStartedRenderingProvider?() ?? true
            if !isLive, parked >= nextLogAt {
                nextLogAt += 10
                let suspendReason = !wantsToPlay ? "(consumer paused; wedge detection suspended)"
                    : !hasStarted ? "(pre-first-frame; wedge detection suspended)"
                    : "(no playback progress)"
                EngineLog.emit(
                    "[HLSSegmentProducer] #65 backpressure PARK (\(context)) head=\(head) "
                    + "target=\(target) cacheTarget=\(cacheTarget) "
                    + "highStored=\(cache.highestStoredIndex) cached=\(cache.count) parked=\(parked)s "
                    + suspendReason,
                    category: .session
                )
            }
            if !isLive, wedgeDetector.observe(currentTarget: cacheTarget, wantsToPlay: wantsToPlay,
                                              renderedPosition: playbackPositionProvider?(),
                                              hasStartedRendering: hasStarted) {
                markBackpressureWedgeBroken()
                EngineLog.emit(
                    "[HLSSegmentProducer] #65 backpressure WEDGE BROKEN (\(context)) head=\(head) "
                    + "target=\(target) cacheTarget=\(cacheTarget) parked=\(parked)s"
                    + (wedgeDetector.lastTripFast ? " (fast path: fetch target + rendered clock both frozen)" : "")
                    + "; exiting pump for host re-anchor on AVPlayer position",
                    category: .session
                )
                return false
            }
        }
        return false
    }

    private func markBackpressureWedgeBroken() {
        stateLock.lock()
        _backpressureWedgeBroken = true
        stateLock.unlock()
    }

    private func isBackpressureWedgeBroken() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _backpressureWedgeBroken
    }

    /// Allocate the session's mp4 muxer. `reconstructedVideoConfig` overrides the probed codecpar with
    /// dimensions+extradata parsed from in-band SPS/PPS. Two orthogonal flags (#133 follow-up split the old
    /// single `isProgramSwitchReinit`):
    /// - `versionedInit`: capture the init segment as a versioned EXT-X-MAP (a mid-session avcC change: SSAI ad
    ///   creative OR a same-PID in-band SPS/PPS change). false = the primary init (session start or a #133 live
    ///   join whose probe left codecpar at 0x0).
    /// - `isAdCreative`: drop the program's DV/color overrides because the new content carries its own signaling.
    ///   True only for an SSAI ad creative on a new PID; a same-PID parameter-set change stays in the same program
    ///   and KEEPS the overrides (an HDR-live encoder restart must not lose its color signaling).
    private func allocateMuxer(initialSegmentIndex: Int,
                               reconstructedVideoConfig: (width: Int32, height: Int32, extradata: [UInt8])? = nil,
                               versionedInit: Bool = false,
                               isAdCreative: Bool = false) -> MP4SegmentMuxer? {
        // #93 residual: the FIRST alloc of a producer (its base segment) must not gate on the
        // consumer's fetch high water. An anchored initial producer (resume start) runs before ANY
        // segment fetch exists, because AVPlayer is still waiting on init.mp4, which is captured by
        // exactly this alloc; the park starved the map request into a fatal -12889. Producing the
        // base segment is never overproduction: the consumer requested it (fetch-triggered restart)
        // or is about to (anchored start). seg0 sessions are unaffected (their target is negative
        // and releases immediately).
        if initialSegmentIndex != baseIndex {
            let backpressureTarget = initialSegmentIndex - bufferAheadSegments
            if !awaitBackpressureRelease(target: backpressureTarget, head: initialSegmentIndex, context: "alloc") { return nil }
        }
        if checkShouldStop() { return nil }

        var adPar: UnsafeMutablePointer<AVCodecParameters>?
        defer { if adPar != nil { avcodec_parameters_free(&adPar) } }
        let videoCodecpar: UnsafePointer<AVCodecParameters>
        if let reconstructedVideoConfig {
            guard let par = avcodec_parameters_alloc() else { return nil }
            par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            par.pointee.codec_id = AV_CODEC_ID_H264
            par.pointee.width = reconstructedVideoConfig.width
            par.pointee.height = reconstructedVideoConfig.height
            let ed = reconstructedVideoConfig.extradata
            let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
            if let raw = av_malloc(ed.count + pad) {
                let bytes = raw.assumingMemoryBound(to: UInt8.self)
                ed.withUnsafeBytes { _ = memcpy(bytes, $0.baseAddress, ed.count) }
                memset(bytes + ed.count, 0, pad)
                par.pointee.extradata = bytes
                par.pointee.extradata_size = Int32(ed.count)
            }
            adPar = par
            videoCodecpar = UnsafePointer(par)
        } else {
            videoCodecpar = videoConfig.codecpar
        }

        let muxerVideo = MP4SegmentMuxer.VideoConfig(
            codecpar: videoCodecpar,
            timeBase: videoConfig.timeBase,
            codecTagOverride: videoConfig.codecTagOverride,
            // Ad creative carries its own signaling; don't force the program's overrides onto it. A same-PID
            // parameter-set change is still the same program, so it keeps them (isAdCreative false).
            stripDolbyVisionMetadata: isAdCreative ? false : videoConfig.stripDolbyVisionMetadata,
            rewriteDoviConfigTo81: isAdCreative ? false : videoConfig.rewriteDoviConfigTo81,
            colorOverride: isAdCreative ? nil : videoConfig.colorOverride,
            extradataOverride: isAdCreative ? nil : videoConfig.extradataOverride
        )
        let muxerAudio: MP4SegmentMuxer.AudioConfig? = audioConfig.map { a in
            MP4SegmentMuxer.AudioConfig(codecpar: a.codecpar, timeBase: a.inputTimeBase)
        }

        do {
            // #15: subtitles ship as a separate WebVTT rendition (HLSLocalServer), NOT muxed into the A/V
            // fMP4. In-band timed text is non-conformant for HLS and fails the AVPlayer open (RFC 8216 §3.1,
            // empirically -11829/-12848). The muxer carries no subtitle streams; the cue stores feed the WebVTT.
            let muxer = try MP4SegmentMuxer(
                initialSegmentIndex: initialSegmentIndex,
                sessionDir: cache.sessionDir,
                video: muxerVideo,
                audio: muxerAudio,
                // Cap the muxer's in-RAM interleaver at ~2 segments so a long/degenerate segment or an
                // audio stream that decodes to nothing can't buffer the whole span and fill the disk (#64).
                // Floored at 8s (the historical 2 x 4s value): a sub-second fastZap cut target (AE#195)
                // must not shrink the cap below typical TS A/V interleave skew.
                maxBufferedFragmentSeconds: max(8.0, 2 * targetSegmentDurationSeconds),
                onInitCaptured: { [weak self] initBytes in
                    guard let self = self else { return }
                    if versionedInit {
                        self.cache.addInitVersion(initBytes, fromSegment: initialSegmentIndex)
                        EngineLog.emit(
                            "[HLSSegmentProducer] versioned init captured for seg-\(initialSegmentIndex) "
                            + "(\(initBytes.count) B, \(isAdCreative ? "SSAI program switch" : "same-PID parameter-set change"))",
                            category: .session
                        )
                    } else if !self.initCaptured {
                        self.initCaptured = true
                        self.cache.setInit(initBytes)
                        EngineLog.emit(
                            "[HLSSegmentProducer] init.mp4 captured (\(initBytes.count) B)",
                            category: .session
                        )
                    }
                }
            )
            // Write under stateLock: telemetry getters read currentMuxer under the same lock.
            stateLock.lock()
            self.currentMuxer = muxer
            stateLock.unlock()
            self.currentMuxerSegmentIndex = initialSegmentIndex
            return muxer
        } catch {
            EngineLog.emit(
                "[HLSSegmentProducer] muxer alloc for seg-\(initialSegmentIndex) failed: \(error)",
                category: .session
            )
            return nil
        }
    }

    /// Returns [start, end) on the AVPlayer axis for subtitle injection. VOD: from segmentBoundaries+videoShiftPts. Live: from liveSegmentStartByIndex.
    private func segmentWindowAVPlayerSeconds(
        segIdx: Int,
        nextSegIdx: Int
    ) -> (start: Double, end: Double)? {
        if isLive {
            guard let t0 = liveSegmentStartByIndex[segIdx],
                  let t1 = liveSegmentStartByIndex[nextSegIdx]
            else { return nil }
            return (t0, t1)
        } else {
            guard videoShiftPts != Int64.min, sourceVideoTbSeconds > 0 else { return nil }
            let i = segIdx - baseIndex
            let iNext = nextSegIdx - baseIndex
            guard i >= 0, iNext < segmentBoundaries.count else { return nil }
            let t0 = Double(segmentBoundaries[i] - videoShiftPts) * sourceVideoTbSeconds
            let t1 = Double(segmentBoundaries[iNext] - videoShiftPts) * sourceVideoTbSeconds
            return (t0, t1)
        }
    }

    private func advanceMuxer(to newIdx: Int) -> MP4SegmentMuxer? {
        guard let muxer = currentMuxer else { return nil }

        if let result = muxer.cutFragmentForNextSegment(newIdx) {
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(currentMuxerSegmentIndex).m4s captured (\(result.bytesWritten) B)",
                category: .session, level: .verbose
            )
            cache.adopt(index: currentMuxerSegmentIndex,
                        stagingPath: result.path,
                        byteCount: result.bytesWritten)
            if isLive {
                reportLiveSegmentFinalized(index: currentMuxerSegmentIndex,
                                           nextIndex: newIdx)
            }
            // Cut succeeded but muxer failed to open the next staging fd: silently discards every subsequent byte.
            if muxer.isWedged {
                EngineLog.emit(
                    "[HLSSegmentProducer] muxer wedged after seg-\(currentMuxerSegmentIndex) cut "
                    + "(next staging fd open failed), ending pump",
                    category: .session
                )
                return nil
            }
        } else {
            // Failed cut: muxer has no open staging fd, every byte is silently discarded. Fatal.
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(currentMuxerSegmentIndex).m4s cut FAILED; "
                + "muxer is wedged, ending pump",
                category: .session
            )
            return nil
        }
        currentMuxerSegmentIndex = newIdx
        let backpressureTarget = newIdx - bufferAheadSegments
        if !awaitBackpressureRelease(target: backpressureTarget, head: newIdx, context: "advance") { return nil }
        if checkShouldStop() { return nil }

        return muxer
    }

    private func reportLiveSegmentFinalized(index: Int, nextIndex: Int?) {
        guard let startSeconds = liveSegmentStartByIndex[index] else {
            EngineLog.emit(
                "[HLSSegmentProducer] live finalize: no recorded start for seg-\(index); skipping append",
                category: .session
            )
            return
        }
        let duration: Double
        if let nextIndex = nextIndex, let nextStart = liveSegmentStartByIndex[nextIndex] {
            let d = nextStart - startSeconds
            duration = d > 0 ? d : targetSegmentDurationSeconds
        } else {
            duration = targetSegmentDurationSeconds
        }
        let discontinuous = liveSegmentDiscontinuousByIndex[index] ?? false
        liveSegmentStartByIndex.removeValue(forKey: index)
        liveSegmentDiscontinuousByIndex.removeValue(forKey: index)
        lastLiveSegmentFinalizeAt = Date()
        EngineLog.emit(
            "[HLSSegmentProducer] live seg-\(index) finalized: start=\(String(format: "%.3f", startSeconds))s "
            + "dur=\(String(format: "%.3f", duration))s"
            + (discontinuous ? " [DISCONTINUITY]" : ""),
            category: .session
        )
        onLiveSegmentFinalized?(index, duration, startSeconds, discontinuous)
    }

    private func finalizeSessionMuxerAndAdopt() {
        guard let muxer = currentMuxer else { return }
        let idx = currentMuxerSegmentIndex
        if let result = muxer.finalize() {
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(idx).m4s captured (\(result.bytesWritten) B)",
                category: .session, level: .verbose
            )
            cache.adopt(index: idx, stagingPath: result.path,
                        byteCount: result.bytesWritten)
            if isLive {
                reportLiveSegmentFinalized(index: idx, nextIndex: nil)
            }
        } else {
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(idx).m4s final finalize failed; not adopted",
                category: .session
            )
        }
        stateLock.lock()
        currentMuxer = nil
        stateLock.unlock()
        currentMuxerSegmentIndex = .min
    }

    /// Finalize the muxer to release its context and staging file, but throw the partial segment
    /// away instead of adopting it into the cache (see `shouldAdoptTeardownSegment`).
    private func discardSessionMuxer() {
        guard let muxer = currentMuxer else { return }
        let idx = currentMuxerSegmentIndex
        if let result = muxer.finalize() {
            try? FileManager.default.removeItem(at: result.path)
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(idx).m4s partial at teardown (\(result.bytesWritten) B) discarded, not adopted",
                category: .session
            )
        }
        stateLock.lock()
        currentMuxer = nil
        stateLock.unlock()
        currentMuxerSegmentIndex = .min
    }

    deinit {
        // Backstop for a pump that never exited normally; without an exit reason, a VOD in-flight
        // segment is partial by definition, so only live may adopt here.
        if currentMuxer != nil {
            if isLive {
                finalizeSessionMuxerAndAdopt()
            } else {
                discardSessionMuxer()
            }
        }
    }

    // MARK: - Public API

    func start() {
        stateLock.lock()
        guard !pumpStarted else { stateLock.unlock(); return }
        pumpStarted = true
        stateLock.unlock()

        pumpQueue.async { [weak self] in
            self?.runPumpLoop()
        }
    }

    /// Async stop; also wakes backpressure waiter so restart doesn't wait a full poll timeout.
    func stop() {
        stateLock.lock()
        shouldStop = true
        stateLock.unlock()
        cache.wakeWaiters()
    }

    fileprivate func checkShouldStop() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldStop
    }

    func waitForFinish(timeout: TimeInterval) -> Bool {
        finishCondition.lock()
        defer { finishCondition.unlock() }
        if didFinishFlag { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while !didFinishFlag {
            if !finishCondition.wait(until: deadline) { return false }
        }
        return true
    }

    // MARK: - Dual-source pull-merge

    private enum PacketOrigin { case main, side }

    /// Pump-thread-only: has the first source read of this producer been timed yet (#93 latency)?
    private var pumpFirstReadLogged = false

    /// Returns next packet in global decode order. Single-demuxer fast path; dual-demuxer yields lower-DTS first.
    /// #93 restart latency: the FIRST read of a producer is timed (one line; info when it exceeded
    /// 1 s), because rrgomes' trace shows exactly that read waiting 19-46 s client-side while a
    /// fresh side reader overtakes it in 300 ms.
    private func readNextSourcePacket() throws -> (packet: UnsafeMutablePointer<AVPacket>, origin: PacketOrigin)? {
        guard !pumpFirstReadLogged else { return try readNextSourcePacketMerged() }
        pumpFirstReadLogged = true
        let t0 = DispatchTime.now()
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            EngineLog.emit(
                "[HLSSegmentProducer] first source read after start took \(Int(ms))ms",
                category: .session, level: ms > 1000 ? .info : .verbose
            )
        }
        return try readNextSourcePacketMerged()
    }

    private func readNextSourcePacketMerged() throws -> (packet: UnsafeMutablePointer<AVPacket>, origin: PacketOrigin)? {
        guard let side = sideAudioDemuxer else {
            guard let packet = try demuxer.readPacket() else { return nil }
            return (packet, .main)
        }
        if mergeMainLookahead == nil, !mergeMainEOF {
            mergeMainLookahead = try demuxer.readPacket()
            if mergeMainLookahead == nil { mergeMainEOF = true }
        }
        if mergeSideLookahead == nil, !mergeSideEOF {
            mergeSideLookahead = try side.readPacket()
            if mergeSideLookahead == nil {
                mergeSideEOF = true
            } else if packedSideAudioClock != nil, let pkt = mergeSideLookahead {
                // Stamp at lookahead fill so ordering/gates/rebase/mux all see the same TS-like values.
                stampPackedSideAudio(pkt)
            }
        }
        guard !mergeMainEOF, !mergeSideEOF,
              let main = mergeMainLookahead, let sidePkt = mergeSideLookahead else {
            return nil
        }
        let sideTb = audioConfig?.sourceTimeBase ?? sourceVideoTimeBase
        let sideFirst = DualSourceMergeOrder.sideFirst(
            mainTicks: Self.mergeOrderingTicks(main),
            mainTimeBase: sourceVideoTimeBase,
            sideTicks: Self.mergeOrderingTicks(sidePkt),
            sideTimeBase: sideTb
        )
        if sideFirst {
            mergeSideLookahead = nil
            return (sidePkt, .side)
        }
        mergeMainLookahead = nil
        return (main, .main)
    }

    /// Ordering key: dts when valid, else pts; AV_NOPTS_VALUE (Int64.min) yields immediately (NOPTS repair handles it downstream).
    private static func mergeOrderingTicks(_ packet: UnsafeMutablePointer<AVPacket>) -> Int64 {
        if packet.pointee.dts != Int64.min { return packet.pointee.dts }
        return packet.pointee.pts
    }

    /// #74: whether a pre-video-gate audio packet should be buffered for in-DTS-order replay (instead of
    /// dropped). Buffered while the gate is still waiting, only audio, only under the byte cap, for:
    ///   - head-of-stream (any), and
    ///   - VOD restart/seek.
    /// The wide-interleave failure is the same at both: the matching audio is muxed ahead of the video in
    /// file order, so on a seek it is read during the keyframe scan-forward (gate still closed) and was
    /// dropped, leaving the post-gate restart-target filter to snap the next (~1 s-later) audio onto the
    /// keyframe. Buffering it lets that same filter pick the matching packet from the [target, …] window.
    /// Live restart still drops: its program-boundary re-anchor handles audio separately.
    static func shouldBufferPregateAudio(
        isAudioPkt: Bool,
        audioWaitForVideo: Bool,
        isHeadOfStream: Bool,
        isLive: Bool,
        bufferedBytes: Int,
        packetSize: Int,
        capBytes: Int
    ) -> Bool {
        guard isAudioPkt, audioWaitForVideo, isHeadOfStream || !isLive else { return false }
        return bufferedBytes + max(packetSize, 0) <= capBytes
    }

    /// Overwrite packed side-audio timestamps with the synthesized program clock.
    /// KNOWN LIMITATION: free-running clock does NOT follow a live video rebase; A/V sync is lost from that boundary on.
    private func stampPackedSideAudio(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard audioConfig.map({ packet.pointee.stream_index == $0.sourceStreamIndex }) ?? false,
              var clock = packedSideAudioClock else { return }
        let pts = clock.stamp(packetDuration: packet.pointee.duration)
        packedSideAudioClock = clock
        packet.pointee.pts = pts
        packet.pointee.dts = pts
        if packet.pointee.duration <= 0 {
            packet.pointee.duration = clock.fallbackDurationPts
        }
    }

    private func freeMergeLookaheads() {
        trackedPacketFree(&mergeMainLookahead)
        trackedPacketFree(&mergeSideLookahead)
    }

    // MARK: - Pump

    private func runPumpLoop() {
        if restartTargetVideoPts > Int64.min {
            bumpRestartCount()
        }
        let pumpStart = DispatchTime.now()
        var packetsRead = 0
        var lastError: Int32 = 0
        var exitReason: PumpExitReason = .eof
        var packetsReadAtLastFinalize = 0
        var lastFinalizeSeen: Date? = lastLiveSegmentFinalizeAt
        var videoPktsSinceFinalize = 0
        var audioPktsSinceFinalize = 0
        var videoKeyframesSinceFinalize = 0
        var foreignPktsSinceFinalize = 0
        var lastForeignStreamIndexSinceFinalize: Int32 = -1
        var firstVideoPtsSinceFinalize: Int64 = Int64.min
        var lastVideoPtsSinceFinalize: Int64 = Int64.min
        // #177 slow-delivery holds: a hold re-arms the watchdog window without a finalize.
        var noCutHoldRearmedAt: Date? = nil
        var consecutiveNoCutHolds = 0
        var vodLedgerLastRoutedSeg = Int.min  // #65 ledger: last VOD segment index logged at the routing site

        do {
            readLoop: while true {
                stateLock.lock()
                let stopRequested = shouldStop
                stateLock.unlock()
                if stopRequested {
                    exitReason = .stopRequested
                    break readLoop
                }

                if lastLiveSegmentFinalizeAt != lastFinalizeSeen {
                    lastFinalizeSeen = lastLiveSegmentFinalizeAt
                    packetsReadAtLastFinalize = packetsRead
                    videoPktsSinceFinalize = 0
                    audioPktsSinceFinalize = 0
                    videoKeyframesSinceFinalize = 0
                    foreignPktsSinceFinalize = 0
                    lastForeignStreamIndexSinceFinalize = -1
                    firstVideoPtsSinceFinalize = Int64.min
                    lastVideoPtsSinceFinalize = Int64.min
                    noCutHoldRearmedAt = nil
                    consecutiveNoCutHolds = 0
                }
                if isLive, let lastFinalize = lastLiveSegmentFinalizeAt {
                    // #177: a hold re-arms the window; the watchdog measures from the later anchor.
                    let stalledFor = Date().timeIntervalSince(noCutHoldRearmedAt ?? lastFinalize)
                    let progress = packetsRead - packetsReadAtLastFinalize
                    let readRate = stalledFor > 0 ? Double(progress) / stalledFor : 0
                    let ptsAdvance = (lastVideoPtsSinceFinalize != Int64.min
                        && firstVideoPtsSinceFinalize != Int64.min && sourceVideoTbSeconds > 0)
                        ? Double(lastVideoPtsSinceFinalize - firstVideoPtsSinceFinalize) * sourceVideoTbSeconds
                        : -1
                    switch Self.noCutStallAction(
                        stalledFor: stalledFor,
                        readRate: readRate,
                        videoPtsAdvanceSeconds: ptsAdvance,
                        consecutiveHolds: consecutiveNoCutHolds
                    ) {
                    case .keepReading:
                        break
                    case .holdForSlowDelivery:
                        consecutiveNoCutHolds += 1
                        EngineLog.emit(
                            "[HLSSegmentProducer] slow live delivery hold "
                            + "\(consecutiveNoCutHolds)/\(Self.liveSlowDeliveryMaxHolds): video PTS "
                            + "+\(String(format: "%.1f", ptsAdvance))s in \(Int(stalledFor))s "
                            + "(rate=\(String(format: "%.1f", readRate))pkt/s); not a wedge, "
                            + "re-arming watchdog instead of retuning",
                            category: .session
                        )
                        noCutHoldRearmedAt = Date()
                        packetsReadAtLastFinalize = packetsRead
                        videoPktsSinceFinalize = 0
                        audioPktsSinceFinalize = 0
                        videoKeyframesSinceFinalize = 0
                        foreignPktsSinceFinalize = 0
                        lastForeignStreamIndexSinceFinalize = -1
                        firstVideoPtsSinceFinalize = Int64.min
                        lastVideoPtsSinceFinalize = Int64.min
                    case .exitForRetune:
                        let isWedge = readRate >= Self.liveWedgeProgressRateThreshold
                        EngineLog.emit(
                            "[HLSSegmentProducer] no-cut stall: no segment finalized for "
                            + "\(Int(stalledFor))s (packetsRead=\(packetsRead), "
                            + "sinceFinalize=\(progress), "
                            + "rate=\(String(format: "%.1f", readRate))pkt/s, "
                            + "\(isWedge ? "cutter wedge" : "source starvation")); "
                            + "window video=\(videoPktsSinceFinalize) key=\(videoKeyframesSinceFinalize) "
                            + "audio=\(audioPktsSinceFinalize) foreign=\(foreignPktsSinceFinalize)"
                            + (lastForeignStreamIndexSinceFinalize >= 0
                                ? " lastForeignIdx=\(lastForeignStreamIndexSinceFinalize)" : "")
                            + (ptsAdvance >= 0
                                ? " videoPtsAdvance=\(String(format: "%.1f", ptsAdvance))s" : "")
                            + (consecutiveNoCutHolds > 0
                                ? " holdsExhausted=\(consecutiveNoCutHolds)" : "")
                            + "; exiting for host retune",
                            category: .session
                        )
                        exitReason = .segmentStall
                        break readLoop
                    }
                }

                let packet: UnsafeMutablePointer<AVPacket>
                let origin: PacketOrigin
                if !audioWaitForVideo, !pregateAudioBuffer.isEmpty {
                    // #74: once the video gate opens, drain the buffered head-of-stream audio in DTS
                    // order before reading further source packets. These were already counted in
                    // packetsRead when first read, so do not re-count them here.
                    if !pregateAudioReplaySorted {
                        pregateAudioBuffer.sort { Self.mergeOrderingTicks($0.0) < Self.mergeOrderingTicks($1.0) }
                        pregateAudioReplaySorted = true
                    }
                    let entry = pregateAudioBuffer.removeFirst()
                    packet = entry.0
                    origin = entry.1
                    pregateAudioBufferBytes -= Int(packet.pointee.size)
                } else {
                    guard let read = try readNextSourcePacket() else {
                        break readLoop
                    }
                    packet = read.packet
                    origin = read.origin
                    packetsRead += 1
                }
                var pktPtr: UnsafeMutablePointer<AVPacket>? = packet
                defer { trackedPacketFree(&pktPtr) }

                // Drop matroska BlockAddition side data (HDR10+/DV RPU ~6 KB/entry; metadata lives in bitstream for HEVC).
                // Exception: check AV_PKT_DATA_NEW_EXTRADATA first (live only: program boundary SPS/PPS change detection).
                if isLive, origin == .main, packet.pointee.stream_index == videoStreamIndex {
                    var sdSize: Int = 0
                    if let sd = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &sdSize),
                       sdSize > 0 {
                        // #133 follow-up diag: confirm ONCE whether the demuxer surfaces avcC changes as side data at
                        // all. On MPEG-TS it often does not (the sets are only in-band), which is why the actual
                        // rotation trigger is the keyframe SPS/PPS compare below, not this path.
                        if !loggedFirstVideoNewExtradata {
                            loggedFirstVideoNewExtradata = true
                            EngineLog.emit(
                                "[HLSSegmentProducer] diag: demuxer emitted AV_PKT_DATA_NEW_EXTRADATA (\(sdSize) B) "
                                + "on video PID stream=\(videoStreamIndex)",
                                category: .session
                            )
                        }
                        let newExtra = Data(bytes: sd, count: sdSize)
                        if newExtra != lastSeenVideoExtradata {
                            lastSeenVideoExtradata = newExtra
                            codecParamChangeCount += 1
                            // Force an early discontinuity cut; the versioned-init muxer rotation is driven by the
                            // keyframe SPS/PPS compare below (which also covers the common case where no side data is
                            // emitted at all). This side-data hit just brings the cut forward by up to one keyframe.
                            pendingDiscontinuityFlag = true
                            pendingForceCutFlag = true
                            EngineLog.emit(
                                "[HLSSegmentProducer] in-band video extradata change #\(codecParamChangeCount) "
                                + "(\(sdSize) B) signaled via side data; forcing a discontinuity cut "
                                + "(rotation handled by the keyframe parameter-set compare)",
                                category: .session
                            )
                        }
                    }
                }
                av_packet_free_side_data(packet)

                let pktStreamIdx = packet.pointee.stream_index

                // SSAI program switch: ad creative uses a different video PID; re-point videoStreamIndex.
                if isLive, origin == .main, sideAudioDemuxer == nil,
                   pktStreamIdx != videoStreamIndex,
                   pktStreamIdx != (audioConfig?.sourceStreamIndex ?? -1),
                   demuxer.isVideoStream(pktStreamIdx),
                   // Mid-stream demuxer codecpar is unparsed (width 0); only switch on a keyframe with in-band SPS/PPS.
                   let adConfig = extractAdVideoConfig(packet) {
                    EngineLog.emit(
                        "[HLSSegmentProducer] SSAI video program switch: "
                        + "videoStreamIndex \(videoStreamIndex) → \(pktStreamIdx) "
                        + "(ad/program \(adConfig.width)x\(adConfig.height) on a new video PID)",
                        category: .session
                    )
                    videoStreamIndex = pktStreamIdx
                    // Do NOT nil lastVideoSourceDts: timeline rebase (below) needs it to fire on the big backward jump.
                    lastSeenVideoExtradata = nil
                    pendingVideoProgramSwitch = true
                    pendingReinitIsAdCreative = true  // new PID carries its own DV/color signaling; drop program overrides
                    pendingAdVideoConfig = adConfig
                    activeMuxerVideoExtradata = adConfig.extradata  // #133 follow-up: rebaseline for same-PID PS-change detection
                    convertP7Active = false  // ad creatives are H.264
                    if lastLiveSegmentFinalizeAt != nil { lastLiveSegmentFinalizeAt = Date() }
                    // pendingDiscontinuityFlag / pendingForceCutFlag set by the rebase below.
                }

                // NOPTS dts repair: matroska reconstructs dts from ReferenceBlock relations; fails on some B-frames.
                // Forwarding NOPTS causes FFmpeg muxer monotonic check failure (EINVAL, -16046). Using pts as fallback
                // is WRONG for B-frames (pts < dts in decode order). Fix: lastValidDts+1.
                // Origin-aware classification: side audio index can alias main video index in dual-demuxer sessions.
                let isVideoPkt = origin == .main && (pktStreamIdx == videoStreamIndex)
                let isAudioPkt: Bool
                if sideAudioDemuxer != nil {
                    isAudioPkt = origin == .side
                        && (audioConfig.map { pktStreamIdx == $0.sourceStreamIndex } ?? false)
                } else {
                    isAudioPkt = (audioConfig.map { pktStreamIdx == $0.sourceStreamIndex }) ?? false
                }
                // #77: hand the in-band caption-track packet to the observer (read-only). It's a foreign
                // packet (the eia_608/c608 caption stream) and is dropped below, never muxed.
                if pktStreamIdx == closedCaptionStreamIndex, let observe = closedCaptionObserver {
                    observe(packet, closedCaptionStreamTimeBase)
                }
                // Sodalite#32: hand tapped subtitle packets to the session's decode tap, then drop them
                // below as foreign packets. Main demuxer only; side-demuxer indices alias a different space.
                if origin == .main, subtitleTapStreamIndices.contains(pktStreamIdx),
                   let observe = subtitleTapObserver {
                    observe(pktStreamIdx, packet,
                            subtitleTapTimeBases[pktStreamIdx] ?? AVRational(num: 1, den: 1000))
                }
                // #112 rework: hand every embedded subtitle packet to the session's packet store sink,
                // then drop it below as a foreign packet. Main demuxer only, same as the decode tap.
                if origin == .main, subtitlePacketStreamIndices.contains(pktStreamIdx),
                   let sink = subtitlePacketSink {
                    sink(pktStreamIdx, packet,
                         subtitleTapTimeBases[pktStreamIdx] ?? AVRational(num: 1, den: 1000))
                }

                if packet.pointee.dts == Int64.min {
                    let anchor: Int64 = isVideoPkt ? lastVideoSourceDts
                                      : isAudioPkt ? lastAudioSourceDts
                                      : Int64.min
                    if anchor == Int64.min {
                        // No anchor yet. Keyframes (IDR/CRA): pts == dts in decode order, safe to use.
                        // Non-keyframe NOPTS first packet: drop (corrupt seg-0 is worse than a small drop).
                        // Dropping the first IDR would shift DV5's leading SEI and break DV color init (#4).
                        let isKey = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                        guard isKey, packet.pointee.pts != Int64.min else {
                            continue
                        }
                        packet.pointee.dts = packet.pointee.pts
                    } else {
                        packet.pointee.dts = anchor + 1
                        if packet.pointee.pts == Int64.min {
                            packet.pointee.pts = packet.pointee.dts
                        }
                    }
                }

                // #74: buffer pre-video-gate audio for in-DTS-order replay once the video gate opens
                // (drained at the loop top), instead of dropping it at the audio gate. On wide-interleave
                // sources (audio muxed ahead of video in file order) the old drop discarded the matching
                // audio, leaving a constant ~1 s A/V desync. Bounded by a byte cap; over the cap the
                // original gate drop below resumes. Applies to head-of-stream (any) and VOD restart/seek:
                // on a seek the matching audio is read during the keyframe scan-forward (gate still
                // closed), and buffering it lets the post-gate restart-target filter pick it from the
                // [target, …] window. Live restart keeps the drop (program-boundary re-anchor handles it).
                if Self.shouldBufferPregateAudio(
                    isAudioPkt: isAudioPkt,
                    audioWaitForVideo: audioWaitForVideo,
                    isHeadOfStream: restartTargetVideoPts == Int64.min,
                    isLive: isLive,
                    bufferedBytes: pregateAudioBufferBytes,
                    packetSize: Int(packet.pointee.size),
                    capBytes: Self.maxPregateAudioBufferBytes
                ) {
                    pregateAudioBuffer.append((packet, origin))
                    pregateAudioBufferBytes += Int(packet.pointee.size)
                    pktPtr = nil  // ownership moves to the buffer; freed on replay or teardown
                    continue
                } else if isAudioPkt, audioWaitForVideo,
                          restartTargetVideoPts == Int64.min || !isLive,
                          !pregateAudioOverflowLogged {
                    pregateAudioOverflowLogged = true
                    EngineLog.emit(
                        "[HLSSegmentProducer] pre-gate audio buffer hit the "
                        + "\(Self.maxPregateAudioBufferBytes)-byte cap; dropping further leading audio "
                        + "(wide interleave beyond cap)",
                        category: .session
                    )
                }
                // Live timeline rebase: a program boundary resets source dts to a small value.
                // Per-frame monotonic gate would bump to lastValid+1, exceed reset pts, and DROP every subsequent packet.
                // Correct repair: rebase OUTPUT dts to one frame past last output; add #EXT-X-DISCONTINUITY at seam.
                if isLive, isVideoPkt, lastVideoSourceDts != Int64.min,
                   videoShiftPts != Int64.min, packet.pointee.dts != Int64.min {
                    let jumpTicks = packet.pointee.dts - lastVideoSourceDts
                    let thresholdSeconds = jumpTicks < 0
                        ? Self.discontinuityBackwardThresholdSeconds
                        : Self.discontinuityThresholdSeconds
                    let thresholdTicks = sourceVideoTbSeconds > 0
                        ? Int64(thresholdSeconds / sourceVideoTbSeconds)
                        : Int64.max
                    if abs(jumpTicks) >= thresholdTicks {
                        if isSourceReplay(newDts: packet.pointee.dts,
                                          jumpTicks: jumpTicks,
                                          firstSeenDts: firstSeenVideoSourceDts,
                                          tbSeconds: sourceVideoTbSeconds,
                                          stream: "video") {
                            exitReason = .sourceReplay
                            break readLoop
                        }
                        let lastOutputDts = lastVideoSourceDts - videoShiftPts
                        let continuationDts = lastOutputDts + max(videoFallbackDurationPts, 1)
                        let newShift = packet.pointee.dts - continuationDts
                        EngineLog.emit(
                            "[HLSSegmentProducer] live video timeline rebase: "
                            + "jumpTicks=\(jumpTicks) srcDts=\(packet.pointee.dts) "
                            + "lastSrcDts=\(lastVideoSourceDts) oldShift=\(videoShiftPts) "
                            + "newShift=\(newShift) lastOutDts=\(lastOutputDts)",
                            category: .session
                        )
                        if packedSideAudioClock != nil {
                            // Synth clock free-runs; audio-side inherit will not apply here (timestamps never leap).
                            EngineLog.emit(
                                "[HLSSegmentProducer] WARNING: live video rebase with a "
                                + "packed-audio synth clock active; synthesized side-audio "
                                + "timestamps do NOT follow the jump, A/V sync is lost from "
                                + "this boundary on",
                                category: .session
                            )
                        }
                        videoShiftPts = newShift
                        lastVideoSourceDts = packet.pointee.dts - 1  // dts-1 so monotonic gate is a no-op for this packet
                        // Re-anchor leading-B-frame gate to the new program (otherwise every reset-timeline packet drops).
                        if packet.pointee.pts != Int64.min {
                            firstActualVideoPts = packet.pointee.pts
                        }
                        lastRawVideoPts = Int64.min
                        pendingDiscontinuityFlag = true
                        pendingForceCutFlag = true
                        // Hand seam OUTPUT dts (not video shift) to audio: audio derives its own shift from its OWN srcDts,
                        // so differing audio source bases (Pluto amux: audio near 2^33) are absorbed.
                        if let audio = audioConfig {
                            let seamOutAudioTb = av_rescale_q(
                                continuationDts,
                                sourceVideoTimeBase,
                                audio.sourceTimeBase
                            )
                            if let prior = lastIndependentAudioRebase,
                               Date().timeIntervalSince(prior.at) < Self.rebasePairingWindowSeconds {
                                // Audio crossed first; re-derive shift from recorded boundary srcDts at next audio packet.
                                pendingAudioShiftOverride = (seamOutAudioTb, prior.boundarySrcDts, Date())
                                lastIndependentAudioRebase = nil
                            } else {
                                pendingAudioInheritSeamOut = (seamOutAudioTb, Date())
                            }
                        }
                        // Deferred handoff: shift is at producer edge; AVPlayer renders buffer+holdback later.
                        let seamOutputSeconds = Double(continuationDts) * sourceVideoTbSeconds
                        onLiveTimelineRebase?(newShift, seamOutputSeconds)
                    }
                }
                if isLive, isAudioPkt, lastAudioSourceDts != Int64.min,
                   audioShiftPts != Int64.min, packet.pointee.dts != Int64.min,
                   let audio = audioConfig {
                    let jumpTicks = packet.pointee.dts - lastAudioSourceDts
                    let tb = audio.sourceTimeBase
                    let thresholdSeconds = jumpTicks < 0
                        ? Self.discontinuityBackwardThresholdSeconds
                        : Self.discontinuityThresholdSeconds
                    let thresholdTicks = tb.num > 0
                        ? Int64(thresholdSeconds * Double(tb.den) / Double(tb.num))
                        : Int64.max
                    if abs(jumpTicks) >= thresholdTicks {
                        if isSourceReplay(newDts: packet.pointee.dts,
                                          jumpTicks: jumpTicks,
                                          firstSeenDts: firstSeenAudioSourceDts,
                                          tbSeconds: tb.den > 0
                                              ? Double(tb.num) / Double(tb.den) : 0,
                                          stream: "audio") {
                            exitReason = .sourceReplay
                            break readLoop
                        }
                        if pendingAudioShiftOverride != nil {
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio rebase: discarding stale shift override (new boundary)",
                                category: .session
                            )
                            pendingAudioShiftOverride = nil
                        }
                        let lastOutputDts = lastAudioSourceDts - audioShiftPts
                        // Independent measurement (audio-first boundary): used directly only when no video-derived shift available.
                        let measuredShift = packet.pointee.dts
                            - (lastOutputDts + max(audioFallbackDurationPts, 1))
                        var newShift = measuredShift
                        var inherited = false
                        if let p = pendingAudioInheritSeamOut,
                           Date().timeIntervalSince(p.at) < Self.rebasePairingWindowSeconds {
                            // Snap audio onto video timeline via seam-derived shift to absorb differing source bases (amux ads).
                            let candidate = Self.seamDerivedAudioShift(
                                audioBoundarySrcDts: packet.pointee.dts,
                                seamOutAudioTb: p.seamOutAudioTb
                            )
                            if let bridge = audio.bridge {
                                // Bridge: free-running encoder restamps continuously; jump its timeline by the residual gap.
                                let driftTicks = measuredShift - candidate
                                let tbSec = tb.den > 0
                                    ? Double(tb.num) / Double(tb.den) : 0
                                bridge.noteTimelineJump(
                                    deltaSeconds: Double(driftTicks) * tbSec
                                )
                                inherited = true
                            } else {
                                // Stream-copy: apply candidate verbatim (absolute, not clamped to lastOutputDts).
                                // Delta handoff accumulated A/V drift across SSAI pod creatives (device symptom: seconds late by content return).
                                // Sub-frame overlap at the seam left to OutputTimestampSanitizer; > 0.5 s re-anchors.
                                let firstOutputDts = packet.pointee.dts - candidate
                                let overlapTicks = lastOutputDts - firstOutputDts
                                let maxOverlapTicks = audio.sourceTimeBase.num > 0
                                    ? Int64(0.5 * Double(audio.sourceTimeBase.den)
                                            / Double(audio.sourceTimeBase.num))
                                    : Int64.max
                                if overlapTicks > maxOverlapTicks {
                                    newShift = packet.pointee.dts - lastOutputDts - 1
                                    EngineLog.emit(
                                        "[HLSSegmentProducer] audio rebase inherit re-anchored: "
                                        + "candidate=\(candidate) overlap=\(overlapTicks) ticks "
                                        + "exceeds \(maxOverlapTicks) (implausible reset)",
                                        category: .session
                                    )
                                } else {
                                    newShift = candidate
                                }
                                inherited = true
                            }
                        } else {
                            // Audio-first boundary: record srcDts for video rebase to re-derive shift from.
                            lastIndependentAudioRebase = (packet.pointee.dts, Date())
                        }
                        pendingAudioInheritSeamOut = nil
                        EngineLog.emit(
                            "[HLSSegmentProducer] live audio timeline rebase: "
                            + "jumpTicks=\(jumpTicks) srcDts=\(packet.pointee.dts) "
                            + "lastSrcDts=\(lastAudioSourceDts) oldShift=\(audioShiftPts) "
                            + "newShift=\(newShift) "
                            + "(\(inherited ? "video-derived" : "independent"))",
                            category: .session
                        )
                        audioShiftPts = newShift
                        lastAudioSourceDts = packet.pointee.dts - 1
                    } else if let override_ = pendingAudioShiftOverride {
                        // Video rebase arrived after audio rebased independently; correct toward video-derived value.
                        pendingAudioShiftOverride = nil
                        let derivedShift = Self.seamDerivedAudioShift(
                            audioBoundarySrcDts: override_.boundarySrcDts,
                            seamOutAudioTb: override_.seamOutAudioTb
                        )
                        if Date().timeIntervalSince(override_.at) < Self.rebasePairingWindowSeconds {
                            if let bridge = audio.bridge {
                                // Bridge: residual between applied and video-derived shift becomes an encoder-timeline jump.
                                let driftTicks = audioShiftPts - derivedShift
                                let tbSec = tb.den > 0
                                    ? Double(tb.num) / Double(tb.den) : 0
                                bridge.noteTimelineJump(
                                    deltaSeconds: Double(driftTicks) * tbSec
                                )
                                EngineLog.emit(
                                    "[HLSSegmentProducer] audio rebase corrected via bridge jump (drift=\(driftTicks) ticks)",
                                    category: .session
                                )
                            } else {
                                // Stream-copy: apply seam-derived shift; sub-frame overlap left to OutputTimestampSanitizer;
                                // only > 0.5 s overlap re-anchors.
                                let lastOutputDts = lastAudioSourceDts - audioShiftPts
                                let firstOutputDts = override_.boundarySrcDts - derivedShift
                                let overlapTicks = lastOutputDts - firstOutputDts
                                let maxOverlapTicks = tb.num > 0
                                    ? Int64(0.5 * Double(tb.den) / Double(tb.num))
                                    : Int64.max
                                let applied = overlapTicks > maxOverlapTicks
                                    ? packet.pointee.dts - lastOutputDts - 1
                                    : derivedShift
                                EngineLog.emit(
                                    "[HLSSegmentProducer] audio rebase corrected to video-derived shift: "
                                    + "old=\(audioShiftPts) new=\(applied)"
                                    + (applied != derivedShift ? " (re-anchored, overlap \(overlapTicks) ticks)" : ""),
                                    category: .session
                                )
                                audioShiftPts = applied
                                lastAudioSourceDts = packet.pointee.dts - 1
                            }
                        } else {
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio rebase: shift override expired unapplied",
                                category: .session
                            )
                        }
                    }
                }
                // Monotonic-dts enforcement (small glitches only, <= 0.5 s): MKV B-frame dts reconstruction can
                // go backward after NOPTS repair. Bump to lastValid+1 if bump does not exceed pts (muxer invariant);
                // otherwise drop the packet (at most one leading B-frame per CRA). Large backward jumps are program
                // boundaries and are left to the timeline rebase; bumping them caused cutter-wedge reloads + A/V drift.
                let monoGlitchVideoTicks = sourceVideoTbSeconds > 0
                    ? Int64(0.5 / sourceVideoTbSeconds) : Int64.max
                if isVideoPkt, lastVideoSourceDts != Int64.min,
                   packet.pointee.dts != Int64.min,
                   packet.pointee.dts <= lastVideoSourceDts,
                   lastVideoSourceDts - packet.pointee.dts <= monoGlitchVideoTicks {
                    let original = packet.pointee.dts
                    let bumped = lastVideoSourceDts + 1
                    let ptsValid = packet.pointee.pts != Int64.min
                    if !ptsValid || bumped <= packet.pointee.pts {
                        packet.pointee.dts = bumped
                        if !loggedFirstDtsBump {
                            loggedFirstDtsBump = true
                            EngineLog.emit(
                                "[HLSSegmentProducer] video dts non-monotonic at source: "
                                + "orig=\(original) lastValid=\(lastVideoSourceDts) "
                                + "pts=\(packet.pointee.pts) → bumped to \(bumped)",
                                category: .session
                            )
                        }
                    } else {
                        // Bump would violate dts<=pts. Drop the packet
                        // rather than feed the muxer a bad combo.
                        if !loggedFirstDtsDrop {
                            loggedFirstDtsDrop = true
                            EngineLog.emit(
                                "[HLSSegmentProducer] video dts unrecoverable, dropping: "
                                + "orig=\(original) lastValid=\(lastVideoSourceDts) "
                                + "pts=\(packet.pointee.pts)",
                                category: .session
                            )
                        }
                        continue
                    }
                }
                let monoGlitchAudioTicks: Int64 = {
                    let tb = audioConfig?.sourceTimeBase
                    guard let tb, tb.num > 0, tb.den > 0 else { return monoGlitchVideoTicks }
                    return Int64(0.5 * Double(tb.den) / Double(tb.num))
                }()
                if isAudioPkt, lastAudioSourceDts != Int64.min,
                   packet.pointee.dts != Int64.min,
                   packet.pointee.dts <= lastAudioSourceDts,
                   lastAudioSourceDts - packet.pointee.dts <= monoGlitchAudioTicks {
                    // Same logic for audio. Audio doesn't have B-frame
                    // pts/dts skew so dts <= pts isn't a useful gate;
                    // just bump.
                    let original = packet.pointee.dts
                    packet.pointee.dts = lastAudioSourceDts + 1
                    if !loggedFirstAudioDtsBump {
                        loggedFirstAudioDtsBump = true
                        EngineLog.emit(
                            "[HLSSegmentProducer] audio dts non-monotonic at source: "
                            + "orig=\(original) lastValid=\(lastAudioSourceDts) → bumped to \(packet.pointee.dts)",
                            category: .session
                        )
                    }
                }

                if isVideoPkt {
                    videoPktsSinceFinalize += 1
                    if (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 {
                        videoKeyframesSinceFinalize += 1
                    }
                    if packet.pointee.pts != Int64.min {
                        if firstVideoPtsSinceFinalize == Int64.min {
                            firstVideoPtsSinceFinalize = packet.pointee.pts
                        }
                        lastVideoPtsSinceFinalize = packet.pointee.pts
                    }
                    if firstSeenVideoSourceDts == Int64.min {
                        firstSeenVideoSourceDts = packet.pointee.dts
                    }
                    lastVideoSourceDts = packet.pointee.dts
                } else if isAudioPkt {
                    audioPktsSinceFinalize += 1
                    if firstSeenAudioSourceDts == Int64.min {
                        firstSeenAudioSourceDts = packet.pointee.dts
                    }
                    lastAudioSourceDts = packet.pointee.dts
                }

                if !isVideoPkt && !isAudioPkt {
                    foreignPktsSinceFinalize += 1
                    lastForeignStreamIndexSinceFinalize = pktStreamIdx
                    continue
                }

                // Scan-forward gate: wait for AV_PKT_FLAG_KEY (matroska seek can land 100+ ms early and
                // SimpleBlock keyframe bit can be off for an IDR in the Cues index). Initial-start also
                // waits: first packet is not always a sync sample (Bluey MKV: dts=0 pts=33, no key flag,
                // seg-0 rejected by AVPlayer with -12860 indefinite stall). The target is a plan-boundary
                // PTS, so the packet is judged by presentation time (AE#169 round 3): comparing DTS
                // dropped the anchor IRAP itself under B-frame reorder, and at the file tail no later
                // IRAP exists to rescue the miss, starving the unbounded VOD gate to EOF.
                if isVideoPkt {
                    if firstActualVideoDts == Int64.min {
                        let isKey = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                        let targetSatisfied = Self.videoGateTargetSatisfied(
                            pts: packet.pointee.pts, dts: packet.pointee.dts,
                            targetPts: restartTargetVideoPts)
                        // #133: on a live H.264 Annex-B mid-stream join, opening on a bare keyframe flag is not
                        // enough. A join packet must carry a decodable IDR access unit (in-band SPS+PPS+IDR);
                        // otherwise the decoder renders references it never received (green frames) or, when the
                        // probe joined before any SPS and left codecpar at 0x0, the first muxer alloc gets 0x0
                        // dimensions and avformat_write_header fails -22, dead-ending the channel. The bounded
                        // live timeout below covers the miss (keyframeStarvation -> reopen), unlike muxerFailed.
                        let joinConfig = (liveH264AnnexBJoin && isKey && targetSatisfied)
                            ? extractJoinVideoConfig(packet) : nil
                        let joinGateSatisfied = !liveH264AnnexBJoin || joinConfig != nil
                        guard isKey, targetSatisfied, joinGateSatisfied else {
                            if isKey {
                                let ts = packet.pointee.pts != Int64.min
                                    ? packet.pointee.pts : packet.pointee.dts
                                if ts != Int64.min { notePregateDroppedKeyframe(pts: ts) }
                            }
                            pregateVideoDropCount += 1
                            if pregateVideoDropCount == 1 {
                                pregateWaitStart = Date()
                            }
                            if pregateVideoDropCount - lastPregateVideoLog >= Self.pregateLogInterval {
                                lastPregateVideoLog = pregateVideoDropCount
                                let awaiting = (isKey && targetSatisfied && liveH264AnnexBJoin)
                                    ? "SPS/PPS/IDR access unit" : "video keyframe"
                                EngineLog.emit(
                                    "[HLSSegmentProducer] still waiting for \(awaiting): "
                                    + "dropped=\(pregateVideoDropCount) "
                                    + "lastDts=\(packet.pointee.dts) lastPts=\(packet.pointee.pts) "
                                    + "isKey=\(isKey) "
                                    + "target=\(restartTargetVideoPts) "
                                    + "baseIndex=\(baseIndex)",
                                    category: .session
                                )
                            }
                            // Live bounded wait: mis-flagged TS would starve forever. VOD keeps unbounded wait.
                            if isLive, let started = pregateWaitStart,
                               Date().timeIntervalSince(started) > Self.liveKeyframeGateTimeoutSeconds {
                                EngineLog.emit(
                                    "[HLSSegmentProducer] live keyframe gate timed out after "
                                    + "\(Int(Self.liveKeyframeGateTimeoutSeconds))s "
                                    + "(dropped=\(pregateVideoDropCount)); exiting pump for reopen",
                                    category: .session
                                )
                                exitReason = .keyframeStarvation
                                break readLoop
                            }
                            continue
                        }
                        // #133: probe joined before any SPS (codecpar 0x0). Backfill the first muxer's video
                        // config from the gating IDR's in-band SPS/PPS so avformat_write_header gets real
                        // dimensions instead of failing -22.
                        if let joinConfig,
                           videoConfig.codecpar.pointee.width == 0 || videoConfig.codecpar.pointee.height == 0 {
                            pendingJoinVideoConfig = joinConfig
                            EngineLog.emit(
                                "[HLSSegmentProducer] live join: reconstructed video config "
                                + "\(joinConfig.width)x\(joinConfig.height) from in-band SPS/PPS "
                                + "(probe codecpar was 0x0)",
                                category: .session
                            )
                        }
                        firstActualVideoDts = packet.pointee.dts
                        markVideoGateOpened()
                        firstActualVideoPts = packet.pointee.pts != Int64.min
                            ? packet.pointee.pts
                            : packet.pointee.dts
                        if isLive, lastLiveSegmentFinalizeAt == nil {
                            lastLiveSegmentFinalizeAt = Date()
                        }
                        videoShiftPts = firstActualVideoDts - desiredFirstVideoTfdtPts
                        if audioWaitForVideo, let audio = audioConfig {
                            // Rescale into SOURCE audio TB (not encoder TB): FLAC bridge exposes this mismatch;
                            // using inputTimeBase landed the target 48x too far for bridged DTS sources.
                            restartTargetAudioDts = av_rescale_q(
                                firstActualVideoDts,
                                sourceVideoTimeBase,
                                audio.sourceTimeBase
                            )
                            audioWaitForVideo = false
                        }
                        EngineLog.emit(
                            "[HLSSegmentProducer] video gate open: "
                            + "actual=\(firstActualVideoDts) "
                            + "anchorPts=\(firstActualVideoPts) "
                            + "target=\(restartTargetVideoPts) "
                            + "desired=\(desiredFirstVideoTfdtPts) "
                            + "shift=\(videoShiftPts) "
                            // #133 follow-up diag: PID + reconstruct state per epoch, so retest logs separate a
                            // same-PID mid-stream parameter-set change from a reopen storm (each reopen is a fresh
                            // gate-open here; a same-PID change is NOT, it stays in one epoch and rotates in place).
                            + "videoPID=\(videoStreamIndex) reconstructed=\(pendingJoinVideoConfig != nil)",
                            category: .session
                        )
                        onVideoShiftKnown?(videoShiftPts)
                        // #133 follow-up: the gating IDR's in-band SPS/PPS back this epoch's muxer avcC. Establish
                        // the baseline so a later same-PID parameter-set change (encoder restart / regional splice)
                        // is detected against it. joinConfig is non-nil only in the liveH264AnnexBJoin scope.
                        if let joinConfig {
                            activeMuxerVideoExtradata = joinConfig.extradata
                        }
                    } else {
                        // Drop HEVC RASL leading B-frames: open-GOP CRA emits B-frames with pts before CRA.pts
                        // that reference pre-CRA frames not in our stream (AVPlayer stalls in waitingToPlay forever).
                        if firstActualVideoPts != Int64.min,
                           packet.pointee.pts != Int64.min,
                           packet.pointee.pts < firstActualVideoPts {
                            if !loggedFirstLeadingDrop {
                                loggedFirstLeadingDrop = true
                                EngineLog.emit(
                                    "[HLSSegmentProducer] drop pre-keyframe "
                                    + "leading B-frame: pts=\(packet.pointee.pts) "
                                    + "dts=\(packet.pointee.dts) "
                                    + "anchor=\(firstActualVideoPts) "
                                    + "(open-GOP RASL)",
                                    category: .session
                                )
                            }
                            continue
                        }
                        // #133 follow-up: gate is open; watch mid-stream keyframes for an in-band SPS/PPS change on
                        // the SAME video PID. The fMP4 avcC froze at write_header, so without a versioned re-init the
                        // new slices decode against a stale avcC (recurring green frames + "non-existing PPS" bursts,
                        // exactly the UK-DVB-via-Xtream report). Route it through the same EXT-X-MAP rotation SSAI uses,
                        // parsing the sets ourselves so it fires whether or not the demuxer emits NEW_EXTRADATA.
                        if liveH264AnnexBJoin,
                           (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0,
                           !pendingVideoProgramSwitch,
                           let incoming = extractAdVideoConfig(packet),
                           Self.parameterSetsDiverged(active: activeMuxerVideoExtradata, incoming: incoming.extradata) {
                            samePIDReinitCount += 1
                            EngineLog.emit(
                                "[HLSSegmentProducer] same-PID in-band parameter-set change #\(samePIDReinitCount) "
                                + "on video PID stream=\(videoStreamIndex) "
                                + "(\(incoming.width)x\(incoming.height), "
                                + "\(activeMuxerVideoExtradata?.count ?? 0)->\(incoming.extradata.count) B SPS/PPS); "
                                + "forcing a discontinuity cut + versioned init so the new avcC matches the slices",
                                category: .session
                            )
                            pendingDiscontinuityFlag = true
                            pendingForceCutFlag = true
                            pendingVideoProgramSwitch = true
                            pendingReinitIsAdCreative = false
                            pendingAdVideoConfig = incoming
                            activeMuxerVideoExtradata = incoming.extradata
                        }
                    }
                }
                if isAudioPkt {
                    if audioWaitForVideo {
                        pregateAudioDropCount += 1
                        if pregateAudioDropCount - lastPregateAudioLog >= Self.pregateLogInterval {
                            lastPregateAudioLog = pregateAudioDropCount
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio waiting for video gate: "
                                + "dropped=\(pregateAudioDropCount) "
                                + "lastDts=\(packet.pointee.dts) baseIndex=\(baseIndex)",
                                category: .session
                            )
                        }
                        continue
                    }
                    if restartTargetAudioDts != Int64.min && firstActualAudioDts == Int64.min {
                        let meetsTarget = packet.pointee.dts != Int64.min
                            && packet.pointee.dts >= restartTargetAudioDts
                        // Live escape: backward PCR wrap between video gate-open and first audio packet strands the target
                        // in the old clock domain (permanently silent). Timeout + accept; VOD keeps unbounded wait.
                        var escape = false
                        if isLive, !meetsTarget {
                            if audioGateWaitStart == nil { audioGateWaitStart = Date() }
                            if let started = audioGateWaitStart,
                               Date().timeIntervalSince(started) > Self.liveAudioGateTimeoutSeconds {
                                EngineLog.emit(
                                    "[HLSSegmentProducer] live audio gate timed out after "
                                    + "\(Int(Self.liveAudioGateTimeoutSeconds))s "
                                    + "(dropped=\(pregateAudioDropCount) dts=\(packet.pointee.dts) "
                                    + "target=\(restartTargetAudioDts)); accepting current packet",
                                    category: .session
                                )
                                escape = packet.pointee.dts != Int64.min
                            }
                        }
                        guard meetsTarget || escape else {
                            pregateAudioDropCount += 1
                            if pregateAudioDropCount - lastPregateAudioLog >= Self.pregateLogInterval {
                                lastPregateAudioLog = pregateAudioDropCount
                                EngineLog.emit(
                                    "[HLSSegmentProducer] audio waiting for target dts: "
                                    + "dropped=\(pregateAudioDropCount) "
                                    + "lastDts=\(packet.pointee.dts) "
                                    + "target=\(restartTargetAudioDts) baseIndex=\(baseIndex)",
                                    category: .session
                                )
                            }
                            continue
                        }
                    }
                    if firstActualAudioDts == Int64.min {
                        firstActualAudioDts = packet.pointee.dts
                        let audioTb = audioConfig?.sourceTimeBase ?? AVRational(num: 1, den: 1000)
                        if restartTargetVideoPts == Int64.min {
                            // Head-of-stream: inherit video's shift so the audio-minus-video offset survives (Cars: EAC3 +256 ms).
                            // Snapping to desired=0 would pull the entire audio track ahead of picture.
                            audioShiftPts = av_rescale_q(
                                videoShiftPts,
                                sourceVideoTimeBase,
                                audioTb
                            )
                            pendingAudioInheritSeamOut = nil
                        } else {
                            // Restart: inherit the session mapping exactly like head-of-stream. The old snap onto
                            // the video seam (firstActualAudioDts - desiredFirstAudioTfdtPts) compensated for the
                            // fresh muxer zero-basing each restart epoch; with tfdt continuity (frag_discont) the
                            // snap itself became the divergence: it moved audio off the source frame grid by up to
                            // one frame per epoch and skewed the shift fold-back in segmentIndex(forSourcePts:) by
                            // the same amount, so a restarted segment carried a different audio timeline (and a
                            // different boundary frame) than continuous production.
                            audioShiftPts = av_rescale_q(
                                videoShiftPts,
                                sourceVideoTimeBase,
                                audioTb
                            )
                        }
                        let gapInAudioTb: Int64
                        if restartTargetVideoPts == Int64.min {
                            gapInAudioTb = 0
                        } else {
                            gapInAudioTb = restartTargetAudioDts == Int64.min
                                ? 0
                                : firstActualAudioDts - restartTargetAudioDts
                        }
                        let gapMs = audioTb.den > 0
                            ? Double(gapInAudioTb) * Double(audioTb.num) * 1000.0 / Double(audioTb.den)
                            : 0
                        self.setLastAVGapMs(gapMs)
                        EngineLog.emit(
                            "[HLSSegmentProducer] audio gate open: "
                            + "actual=\(firstActualAudioDts) "
                            + "target=\(restartTargetAudioDts) "
                            + "desired=\(desiredFirstAudioTfdtPts) "
                            + "shift=\(audioShiftPts) "
                            + "gapMs=\(String(format: "%.1f", gapMs))",
                            category: .session
                        )
                        if abs(gapMs) > 50 {
                            EngineLog.emit(
                                "[HLSSegmentProducer] WARNING: audio gate "
                                + "opened \(String(format: "%.1f", gapMs)) ms "
                                + "after video gate (baseIndex=\(baseIndex)). "
                                + "Audio content for seg-\(baseIndex)'s first "
                                + "video frame is offset from the video by "
                                + "this much, expect A/V drift to be audible.",
                                category: .session
                            )
                        }
                    }
                }

                // Live PTS discontinuity detection on raw (pre-shift) pts. Above NOPTS-repair (+1 tick) and frame-interval scales.
                if isVideoPkt, isLive, firstActualVideoDts != Int64.min,
                   packet.pointee.pts != Int64.min {
                    let rawPts = packet.pointee.pts
                    if lastRawVideoPts != Int64.min {
                        let deltaTicks = rawPts - lastRawVideoPts
                        let deltaSeconds = Double(deltaTicks) * sourceVideoTbSeconds
                        if abs(deltaSeconds) >= Self.discontinuityThresholdSeconds {
                            pendingDiscontinuityFlag = true
                            pendingForceCutFlag = true
                            if !loggedFirstDiscontinuity {
                                loggedFirstDiscontinuity = true
                                EngineLog.emit(
                                    "[HLSSegmentProducer] live PTS discontinuity detected: "
                                    + "prevRawPts=\(lastRawVideoPts) rawPts=\(rawPts) "
                                    + "delta=\(String(format: "%.2f", deltaSeconds))s "
                                    + "(threshold=\(String(format: "%.1f", Self.discontinuityThresholdSeconds))s); "
                                    + "next segment will carry #EXT-X-DISCONTINUITY",
                                    category: .session
                                )
                            }
                        }
                    }
                    lastRawVideoPts = rawPts
                }

                let activeShift: Int64 = isVideoPkt ? videoShiftPts : audioShiftPts
                if activeShift != Int64.min && activeShift != 0 {
                    if packet.pointee.dts != Int64.min {
                        packet.pointee.dts -= activeShift
                    }
                    if packet.pointee.pts != Int64.min {
                        packet.pointee.pts -= activeShift
                    }
                }

                // Defense in depth: the audio gate anchors head-of-stream audio at the video anchor,
                // so audio reaching here is non-negative in practice; rescale rounding between the
                // gate target and the inherited shift (or an exotic source) can still yield a
                // marginally negative out-dts. The muxer no longer absorbs negatives
                // (avoid_negative_ts=disabled so restarts can continue the timeline; tfdt is
                // unsigned), so drop such frames outright.
                if !isVideoPkt, packet.pointee.dts != Int64.min, packet.pointee.dts < 0 {
                    droppedLeadingAudioCount += 1
                    if droppedLeadingAudioCount == 1 {
                        EngineLog.emit(
                            "[HLSSegmentProducer] dropping leading audio before the video anchor "
                            + "(out dts=\(packet.pointee.dts)); the output timeline starts at 0",
                            category: .session
                        )
                    }
                    continue
                }

                if isVideoPkt {
                    if !loggedFirstVideoPktInfo {
                        loggedFirstVideoPktInfo = true
                        EngineLog.emit(
                            "[HLSSegmentProducer] first video pkt: "
                            + "dts=\(packet.pointee.dts) pts=\(packet.pointee.pts) "
                            + "duration=\(packet.pointee.duration) size=\(packet.pointee.size) "
                            + "(fallback=\(videoFallbackDurationPts) in srcVideoTb)",
                            category: .session
                        )
                    }
                    if convertP7Active {
                        // Probe the enhancement-layer type once (latching on the first RPU seen, before
                        // conversion strips it); a FEL source loses refinement in the P8.1 conversion.
                        if !loggedEnhancementLayerType,
                           let elType = DoviRpuConverter.enhancementLayerType(packet) {
                            loggedEnhancementLayerType = true
                            if elType == "FEL" {
                                EngineLog.emit(
                                    "[HLSSegmentProducer] DV P7 source carries a Full Enhancement Layer (FEL); "
                                    + "it is discarded in the P8.1 conversion, so some highlight/detail refinement "
                                    + "is lost versus a native P7 player",
                                    category: .session
                                )
                            }
                        }
                        if !DoviRpuConverter.convertPacketToProfile81(packet) {
                            if !loggedP7ConversionFailure {
                                loggedP7ConversionFailure = true
                                EngineLog.emit(
                                    "[HLSSegmentProducer] DV P7->8.1 conversion failed for a packet; dropped the RPU, "
                                    + "degrading affected frames to the HDR10 base",
                                    category: .session
                                )
                            }
                        }
                    }
                    // Live: keyframe cutter uses shifted pts. VOD: unused; routing uses prev.dts at look-behind site.
                    let isVideoKeyframe = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                    // VOD now cuts keyframe-gated like live (and like FFmpeg's hls muxer): a segment opens
                    // at the IRAP that reaches its plan boundary, so the IRAP is the segment's first sample
                    // and its open-GOP RASL leading pictures stay with it (#92). Routing by DTS against PTS
                    // boundaries used to drop the IRAP (dts < pts) into the previous segment.
                    let thisVideoSeg = isLive
                        ? liveVideoSegmentIndex(pts: packet.pointee.pts, isKeyframe: isVideoKeyframe)
                        : vodCutter.index(pts: packet.pointee.pts, isKeyframe: isVideoKeyframe)
                    if let prev = pendingVideoPkt {
                        let prevSeg = pendingVideoSegIndex
                        // #65 ledger: at each VOD segment open, map the segment's item-axis start (what AVPlayer and
                        // currentTime see) to the TRUE source content muxed there. drift = actual source - planned
                        // source for this index; non-zero means the presented frame leads the clock (Root B positively
                        // confirmed, with the exact idx/epoch). Zero across the whole burst means there is no
                        // content-vs-clock offset and the reported 6 s is the stall/frozen-clock artifact instead.
                        if !isLive, prevSeg != vodLedgerLastRoutedSeg, prev.pointee.dts != Int64.min,
                           sourceVideoTbSeconds > 0 {
                            vodLedgerLastRoutedSeg = prevSeg
                            let shiftTicks = videoShiftPts == Int64.min ? 0 : videoShiftPts
                            let outDts = prev.pointee.dts
                            let srcDts = outDts &+ shiftTicks
                            let localI = prevSeg - baseIndex
                            let planSrc: Int64? = (localI >= 0 && localI < segmentBoundaries.count)
                                ? segmentBoundaries[localI] : nil
                            let tb = sourceVideoTbSeconds
                            EngineLog.emit(
                                "[HLSSegmentProducer] #65 ledger seg-\(prevSeg) base=\(baseIndex) "
                                + "itemAxis=\(String(format: "%.3f", Double(outDts) * tb))s "
                                + "sourceStart=\(String(format: "%.3f", Double(srcDts) * tb))s "
                                + (planSrc != nil
                                    ? "planSource=\(String(format: "%.3f", Double(planSrc!) * tb))s "
                                      + "drift=\(String(format: "%.3f", Double(srcDts &- planSrc!) * tb))s "
                                    : "planSource=n/a drift=n/a ")
                                + "shift=\(String(format: "%.3f", Double(shiftTicks) * tb))s",
                                category: .session
                            )
                        }
                        if let muxer = ensureMuxer(forSegmentIndex: prevSeg) {
                            finalizeAndWriteVideo(prev, nextDts: packet.pointee.dts, muxer: muxer)
                            bumpPacketsWritten()
                        } else {
                            var pkt: UnsafeMutablePointer<AVPacket>? = prev
                            trackedPacketFree(&pkt)
                            pendingVideoPkt = nil
                            exitReason = .muxerFailed
                            break readLoop
                        }
                    }
                    pendingVideoPkt = packet
                    pendingVideoSegIndex = thisVideoSeg   // live: liveVideoSegmentIndex; VOD: keyframe-gated cutter
                    pktPtr = nil  // ownership transferred to pendingVideoPkt
                    continue
                }

                if let audio = audioConfig, isAudioPkt {
                    if let bridge = audio.bridge {
                        let flacPackets: [UnsafeMutablePointer<AVPacket>]
                        do {
                            flacPackets = try bridge.feed(packet: packet)
                        } catch {
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio bridge.feed failed at pkt#\(packetsRead): \(error)",
                                category: .session
                            )
                            continue
                        }
                        var bridgedMuxerGone = false
                        for fp in flacPackets {
                            var fpVar: UnsafeMutablePointer<AVPacket>? = fp
                            if bridgedMuxerGone {
                                trackedPacketFree(&fpVar)
                                continue
                            }
                            // Rescale FLAC pts to source video TB for segment lookup; live audio follows video cutter.
                            let fpSeg: Int
                            if isLive {
                                fpSeg = liveCurrentSegmentIndex
                            } else {
                                let fpPtsInVideoTb = av_rescale_q(
                                    fp.pointee.pts,
                                    audio.inputTimeBase,
                                    sourceVideoTimeBase
                                )
                                fpSeg = segmentIndex(forSourcePts: fpPtsInVideoTb)
                            }
                            guard let muxer = ensureMuxer(forSegmentIndex: fpSeg) else {
                                trackedPacketFree(&fpVar)
                                bridgedMuxerGone = true
                                continue
                            }
                            fp.pointee.stream_index = muxer.audioOutputStreamIndex
                            av_packet_rescale_ts(fp, audio.inputTimeBase, muxer.muxerAudioTimeBase)
                            _ = muxer.writePacket(fp)
                            trackedPacketFree(&fpVar)
                        }
                        if bridgedMuxerGone {
                            exitReason = .muxerFailed
                            break readLoop
                        }
                        continue
                    }
                    if audio.stripAacAdts { Self.stripADTSHeader(packet) }
                    let thisAudioSeg: Int = isLive ? liveCurrentSegmentIndex : 0
                    if let prev = pendingAudioPkt {
                        let prevSeg: Int
                        if isLive {
                            prevSeg = pendingAudioSegIndex
                        } else {
                            let prevPtsInVideoTb = av_rescale_q(
                                prev.pointee.pts,
                                audio.inputTimeBase,
                                sourceVideoTimeBase
                            )
                            prevSeg = segmentIndex(forSourcePts: prevPtsInVideoTb)
                        }
                        if let muxer = ensureMuxer(forSegmentIndex: prevSeg) {
                            finalizeAndWriteAudio(prev, nextDts: packet.pointee.dts, audio: audio, muxer: muxer)
                        } else {
                            var pkt: UnsafeMutablePointer<AVPacket>? = prev
                            trackedPacketFree(&pkt)
                            pendingAudioPkt = nil
                            exitReason = .muxerFailed
                            break readLoop
                        }
                    }
                    pendingAudioPkt = packet
                    if isLive { pendingAudioSegIndex = thisAudioSeg }
                    pktPtr = nil
                    continue
                }
            }
        } catch {
            if case DemuxerError.readFailed(let code) = error {
                lastError = code
                exitReason = .readError(code: code)
            } else {
                lastError = -1
                exitReason = .readError(code: -1)
            }
            EngineLog.emit(
                "[HLSSegmentProducer] demuxer.readPacket threw: \(error)",
                category: .session
            )
        }

        // muxerFailed from a backpressure break is a wedge (host re-anchors) or a stop (teardown), not a real failure.
        if case .muxerFailed = exitReason {
            stateLock.lock()
            let stopped = shouldStop
            let wedged = _backpressureWedgeBroken
            stateLock.unlock()
            if stopped { exitReason = .stopRequested }
            else if wedged { exitReason = .backpressureWedge }
        }

        freeMergeLookaheads()

        // #74: free any head-of-stream audio still buffered (e.g. the video gate never opened on a
        // corrupt or aborted source); replayed entries were already drained at the loop top.
        for entry in pregateAudioBuffer {
            var pkt: UnsafeMutablePointer<AVPacket>? = entry.0
            trackedPacketFree(&pkt)
        }
        pregateAudioBuffer.removeAll()
        pregateAudioBufferBytes = 0

        // Flush look-behind; fallback duration produces tail-correct trun for the final fragment.
        if let prev = pendingVideoPkt {
            let prevSeg = pendingVideoSegIndex   // unified: live + VOD both carry the routed index
            if let muxer = ensureMuxer(forSegmentIndex: prevSeg) {
                finalizeAndWriteVideo(prev, nextDts: nil, muxer: muxer)
                bumpPacketsWritten()
            } else {
                var pkt: UnsafeMutablePointer<AVPacket>? = prev
                trackedPacketFree(&pkt)
            }
            pendingVideoPkt = nil
        }
        if let prev = pendingAudioPkt, let audio = audioConfig {
            let prevSeg: Int
            if isLive {
                prevSeg = pendingAudioSegIndex
            } else {
                let prevPtsInVideoTb = av_rescale_q(
                    prev.pointee.pts,
                    audio.inputTimeBase,
                    sourceVideoTimeBase
                )
                prevSeg = segmentIndex(forSourcePts: prevPtsInVideoTb)
            }
            if let muxer = ensureMuxer(forSegmentIndex: prevSeg) {
                finalizeAndWriteAudio(prev, nextDts: nil, audio: audio, muxer: muxer)
            } else {
                var pkt: UnsafeMutablePointer<AVPacket>? = prev
                trackedPacketFree(&pkt)
            }
            pendingAudioPkt = nil
        }

        // EOF tail flush for bridge audio: drains ~100-200 ms remainder (per-feed only emits full frames).
        if case .eof = exitReason, let audio = audioConfig, let bridge = audio.bridge {
            for fp in bridge.flush() {
                let fpSeg: Int
                if isLive {
                    fpSeg = liveCurrentSegmentIndex
                } else {
                    let fpPtsInVideoTb = av_rescale_q(
                        fp.pointee.pts,
                        audio.inputTimeBase,
                        sourceVideoTimeBase
                    )
                    fpSeg = segmentIndex(forSourcePts: fpPtsInVideoTb)
                }
                if let muxer = ensureMuxer(forSegmentIndex: fpSeg) {
                    fp.pointee.stream_index = muxer.audioOutputStreamIndex
                    av_packet_rescale_ts(fp, audio.inputTimeBase, muxer.muxerAudioTimeBase)
                    _ = muxer.writePacket(fp)
                }
                var fpVar: UnsafeMutablePointer<AVPacket>? = fp
                trackedPacketFree(&fpVar)
            }
        }

        if Self.shouldAdoptTeardownSegment(exitReason: exitReason, isLive: isLive) {
            finalizeSessionMuxerAndAdopt()
        } else {
            discardSessionMuxer()
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - pumpStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit(
            "[HLSSegmentProducer] pump finished: reason=\(exitReason) "
            + "packetsRead=\(packetsRead) "
            + "packetsWritten=\(packetsWrittenCount) lastError=\(lastError) "
            + "elapsed=\(String(format: "%.0f", elapsedMs))ms cacheCount=\(cache.count)",
            category: .session
        )

        finishCondition.lock()
        didFinishFlag = true
        finishCondition.broadcast()
        finishCondition.unlock()

        onPumpFinished?(exitReason)
    }

    // MARK: - Look-behind finalize helpers

    /// Sample duration (source video TB) written for a look-behind video packet. Always telescope to
    /// the true decode-order DTS delta when a forward `nextDts` is available, so movenc's per-track
    /// `track_duration` equals the elapsed DTS and its fragment-boundary reference (`start_dts +
    /// track_duration`) can never overshoot the next real DTS. matroska hands a CONSTANT DefaultDuration
    /// for every block while the ms-quantized block timecodes make the real DTS deltas jitter; trusting
    /// the constant drifts track_duration ~one frame ahead per segment and trips `check_pkt`
    /// (`Packet duration: -N ... out of range` -> DTS clamp + `pts has no value` -> wrong trun timing,
    /// the #92 transient blocky glitch). Falls back to the source packet's own positive duration, then
    /// `fallback`, only when no usable forward delta exists (EOF tail, NOPTS, or a non-increasing next).
    static func resolveVideoSampleDuration(
        existingDuration: Int64,
        dts: Int64,
        nextDts: Int64?,
        fallback: Int64
    ) -> Int64 {
        if let next = nextDts, dts != Int64.min, next != Int64.min {
            let inferred = next - dts
            if inferred > 0 { return inferred }
        }
        return existingDuration > 0 ? existingDuration : fallback
    }

    private func finalizeAndWriteVideo(
        _ packet: UnsafeMutablePointer<AVPacket>,
        nextDts: Int64?,
        muxer: MP4SegmentMuxer
    ) {
        packet.pointee.duration = Self.resolveVideoSampleDuration(
            existingDuration: packet.pointee.duration,
            dts: packet.pointee.dts,
            nextDts: nextDts,
            fallback: videoFallbackDurationPts
        )

        packet.pointee.stream_index = muxer.videoOutputStreamIndex

        if !hdr10PlusDetected, let data = packet.pointee.data {
            let size = Int(packet.pointee.size)
            if size >= 6 {
                let needle: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]
                let found = needle.withUnsafeBufferPointer { n -> Bool in
                    memmem(data, size, n.baseAddress, n.count) != nil
                }
                if found {
                    hdr10PlusDetected = true
                    onFirstHDR10PlusDetected?()
                }
            }
        }

        // #131: A53 caption extraction rides the same per-packet spot as the HDR10+ scan: decode
        // order, repaired DTS, timestamps still in the source time base (the rescale below).
        if let kind = a53CodecKind, let observe = a53CaptionObserver,
           let data = packet.pointee.data, packet.pointee.pts != Int64.min {
            let size = Int(packet.pointee.size)
            if A53SEIParser.mayContainA53(data, size) {
                let extracted = A53SEIParser.triplets(in: data, size: size, codec: kind, framing: a53NALFraming)
                if !extracted.isEmpty {
                    observe(extracted, packet.pointee.pts, packet.pointee.dts, sourceVideoTimeBase)
                }
            }
        }

        av_packet_rescale_ts(packet, sourceVideoTimeBase, muxer.muxerVideoTimeBase)
        _ = muxer.writePacket(packet)

        var pkt: UnsafeMutablePointer<AVPacket>? = packet
        trackedPacketFree(&pkt)
    }

    /// Strip 7/9-byte ADTS header in-place (advances data pointer, shrinks size; buf untouched for unref safety).
    private static func stripADTSHeader(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard let data = packet.pointee.data, packet.pointee.size >= 7 else { return }
        guard data[0] == 0xFF, (data[1] & 0xF0) == 0xF0 else { return }  // ADTS sync word
        let headerLen: Int32 = (data[1] & 0x01) != 0 ? 7 : 9
        guard packet.pointee.size > headerLen else { return }
        packet.pointee.data = data.advanced(by: Int(headerLen))
        packet.pointee.size -= headerLen
    }

    /// Stream-copy audio only; bridge audio bypasses this (FLAC encoder sets durations correctly).
    private func finalizeAndWriteAudio(
        _ packet: UnsafeMutablePointer<AVPacket>,
        nextDts: Int64?,
        audio: AudioConfig,
        muxer: MP4SegmentMuxer
    ) {
        if packet.pointee.duration <= 0 {
            if let next = nextDts {
                let inferred = next - packet.pointee.dts
                packet.pointee.duration = inferred > 0 ? inferred : audioFallbackDurationPts
            } else {
                packet.pointee.duration = audioFallbackDurationPts
            }
        }

        packet.pointee.stream_index = muxer.audioOutputStreamIndex
        av_packet_rescale_ts(packet, audio.inputTimeBase, muxer.muxerAudioTimeBase)
        _ = muxer.writePacket(packet)

        var pkt: UnsafeMutablePointer<AVPacket>? = packet
        trackedPacketFree(&pkt)
    }

}

/// Unit-testable DTS ordering for the dual-source pull-merge.
enum DualSourceMergeOrder {

    /// Compares in a 1/1000000 common clock. Ties yield MAIN first (segment cut keys off video keyframes).
    static func sideFirst(
        mainTicks: Int64,
        mainTimeBase: AVRational,
        sideTicks: Int64,
        sideTimeBase: AVRational
    ) -> Bool {
        if sideTicks == Int64.min { return true }   // AV_NOPTS_VALUE: yield immediately
        if mainTicks == Int64.min { return false }
        let micro = AVRational(num: 1, den: 1_000_000)
        let mainUs = av_rescale_q(mainTicks, mainTimeBase, micro)
        let sideUs = av_rescale_q(sideTicks, sideTimeBase, micro)
        return sideUs < mainUs
    }
}
