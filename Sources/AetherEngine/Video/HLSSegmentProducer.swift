import CoreMedia
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Drives one playback session's read-to-mux pipeline via a per-segment
/// `MP4SegmentMuxer` writing into `SegmentCache`. Forward-only; backward
/// scrubs restart with a new instance at a non-zero `baseIndex`.
final class HLSSegmentProducer: @unchecked Sendable {

    // MARK: - Errors

    enum ProducerError: Error, CustomStringConvertible, LocalizedError {
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

        var errorDescription: String? { description }
    }

    /// Per-stream codec config carried from `HLSVideoEngine` into the muxer setup.
    struct StreamConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let timeBase: AVRational
        /// Override the codec_tag emitted by the mp4 sub-muxer. Used to
        /// force `dvh1` / `hvc1` / `avc1` instead of FFmpeg's defaults
        /// of `hev1` / `h264`, which AVPlayer rejects.
        let codecTagOverride: String?
        /// What the muxer does with the source dvcC record. See `MP4SegmentMuxer.DoviConfigPolicy`.
        let doviConfig: MP4SegmentMuxer.DoviConfigPolicy
        /// Per-packet RPU conversion P7 -> 8.1 (HEVC P7 on DV panel). The container dvcC is a separate
        /// decision (`doviConfig`); this one rewrites the bitstream.
        let convertP7ToProfile81: Bool
        /// Optional color-signaling override forwarded to `MP4SegmentMuxer.ColorOverride`.
        let colorOverride: MP4SegmentMuxer.ColorOverride?
        /// Optional replacement for `codecpar.extradata` before write_header.
        let extradataOverride: [UInt8]?
        /// Framing measured on real packets (#365). Nil falls back to deriving it from the extradata,
        /// which is only correct while the two agree; on a source where they do not, every walker
        /// downstream (A53 captions, the DV P7 RPU rewrite) reads the packet at the wrong offsets.
        let nalFramingOverride: VideoNALFraming?

        init(
            codecpar: UnsafePointer<AVCodecParameters>,
            timeBase: AVRational,
            codecTagOverride: String?,
            doviConfig: MP4SegmentMuxer.DoviConfigPolicy = .keep,
            convertP7ToProfile81: Bool = false,
            colorOverride: MP4SegmentMuxer.ColorOverride? = nil,
            extradataOverride: [UInt8]? = nil,
            nalFramingOverride: VideoNALFraming? = nil
        ) {
            self.codecpar = codecpar
            self.timeBase = timeBase
            self.codecTagOverride = codecTagOverride
            self.doviConfig = doviConfig
            self.convertP7ToProfile81 = convertP7ToProfile81
            self.colorOverride = colorOverride
            self.extradataOverride = extradataOverride
            self.nalFramingOverride = nalFramingOverride
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
        /// AE#458: the source track's language as ISO 639-2/T, carried into every muxer this config builds
        /// (a producer restart rebuilds one, so it has to live on the config, not on the first muxer).
        let language: String?

        init(codecpar: UnsafePointer<AVCodecParameters>,
             timeBase: AVRational,
             sourceStreamIndex: Int32,
             inputTimeBase: AVRational,
             sourceTimeBase: AVRational,
             bridge: AudioBridge?,
             stripAacAdts: Bool = false,
             language: String? = nil) {
            self.codecpar = codecpar
            self.timeBase = timeBase
            self.sourceStreamIndex = sourceStreamIndex
            self.inputTimeBase = inputTimeBase
            self.sourceTimeBase = sourceTimeBase
            self.bridge = bridge
            self.stripAacAdts = stripAacAdts
            self.language = language
        }
    }

    // MARK: - State

    private let demuxer: Demuxer

    /// Non-nil for demuxed-audio HLS ingest (ARD-style: video-only variant + separate audio rendition).
    /// Pump pull-merges by DTS; audio classified by origin not stream index (numbering is independent,
    /// side index can alias main video index). Owned by HLSVideoEngine.
    private let sideAudioDemuxer: Demuxer?

    /// AE#560: the live recording sink, read on the pump thread for every source packet. It gets
    /// its own lock rather than sharing `restartLock`: the tap is on the hot path and must never
    /// contend with a restart.
    fileprivate let recordingSinkLock = NSLock()
    fileprivate var recordingSink: LiveRecordingSink?

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

    /// Source PTS of plan time 0 (the plan's `firstKeyframePts`). The item axis every consumer sees is
    /// `sourcePts - planAnchorVideoPts`, so this is what maps an item-axis timestamp back onto a plan
    /// boundary. Deliberately NOT `videoShiftPts`: the shift additionally carries whatever this
    /// producer's gate overshot its restart target by (AE#268).
    private let planAnchorVideoPts: Int64

    /// Live mode: cuts at keyframes past targetSegmentDurationSeconds; ignores segmentBoundaries.
    private let isLive: Bool

    /// #368: a sequential-origin VOD session folds timeline discontinuities the way live does.
    /// IPTV timeshift archives are chunked recordings; each chunk restarts near PTS 0, and
    /// libavformat's 33-bit wrap correction turns the backward seam into +2^33 (device: dts delta
    /// 8226410192 ticks, 363524400 + 8226410192 = 2^33 exactly). Without a rebase that leap reaches
    /// the cutter as item-axis time and walks its index to the plan tail, after which the session is
    /// structurally dead (frozen playlist, permanent park, refused re-anchor). The SW host already
    /// folds these seams for forward-only VOD (SoftwarePlaybackHost.shouldFoldTimeline); this is the
    /// producer-path equivalent. `isSourceReplay` stays in the shared path untouched: it requires a
    /// recent unplanned reconnect, which a sequential origin (single connection, no reconnect)
    /// can never have.
    private let foldsSequentialTimeline: Bool

    /// The timeline-rebase gate for both stream rebases: live program boundaries and sequential
    /// chunk seams share one definition of "discontinuity" (the thresholds below).
    private var rebasesTimelineOnDiscontinuity: Bool { isLive || foldsSequentialTimeline }

    private var liveCurrentSegmentIndex: Int
    private var liveSegmentStartPtsSeconds: Double = 0
    private var liveFirstSegmentOpened = false

    /// Start-PTS (seconds) per live segment index; removed once reported to keep map bounded.
    private var liveSegmentStartByIndex: [Int: Double] = [:]

    /// Fires synchronously on the pump thread per finalized live segment (index, duration, startSeconds, discontinuous).
    var onLiveSegmentFinalized: (@Sendable (Int, Double, Double, Bool) -> Void)?

    /// AE#443: the resident segment count the live runaway park may use, from the session that owns the
    /// window (`VideoSegmentProvider.liveResidentParkCap`). Unset leaves the static floor, which is the
    /// pre-#443 behaviour.
    var liveResidentCapProvider: (@Sendable () -> Int)?

    /// Sequential-VOD twin of `onLiveSegmentFinalized` (index, real duration in seconds): feeds
    /// the append playlist whose EXTINF must match the media actually muxed. Set only for
    /// sequential-origin sessions; nil keeps the historical VOD behavior byte-identical.
    var onSequentialSegmentFinalized: (@Sendable (Int, Double) -> Void)?
    /// Fired once when the pump reaches true source EOF (not a stop/teardown): the append
    /// playlist completes with ENDLIST.
    var onSequentialSourceEnded: (@Sendable () -> Void)?
    /// Item-axis start (seconds) per VOD segment, recorded at the #65 ledger site as each
    /// segment opens. Pump-thread only.
    private var vodSegmentStartByIndex: [Int: Double] = [:]
    /// Capture and duration arrive in either order: the muxer rotation can fire off an AUDIO
    /// packet crossing the boundary before the first video packet of the new segment has
    /// recorded its start (the duration source). The report fires once BOTH are in. Pump-thread only.
    private var seqCapturedAwaitingDuration: Set<Int> = []
    private var seqDurationAwaitingCapture: [Int: Double] = [:]
    /// The most recent segment index the ledger recorded a start for: a long GOP can SKIP plan
    /// indices entirely (a 5.76 s cut spans two 4 s boundaries), so duration pairing runs against
    /// the last RECORDED index, and the skipped holes report duration 0 (the playlist renderer
    /// omits zero-duration entries). Pump-thread only.
    private var lastSeqLedgerSeg = Int.min
    /// The provider's append API is strictly contiguous; captures, holes and the EOF tail can
    /// resolve out of order, so reports funnel through this small reorder buffer. Pump-thread only.
    private var seqNextReportIndex: Int? = nil
    private var seqReadyReports: [Int: Double] = [:]

    /// #369: highest sequential index the append playlist can currently advertise (only entries
    /// with a real duration get a URI). Pump-thread only; read by the advance park to detect a
    /// release target beyond the advertisable frontier.
    private var seqHighestAdvertisedIndex = Int.min

    /// #369: one-shot latches for the containment logs. Pump-thread only.
    private var loggedVideoWriteFailure = false
    private var loggedSequentialParkSkip = false

    /// Order-preserving funnel for sequential finalize reports.
    private func emitSequentialReport(index: Int, duration: Double) {
        let base = seqNextReportIndex ?? index
        seqNextReportIndex = base
        seqReadyReports[index] = duration
        var next = base
        while let d = seqReadyReports.removeValue(forKey: next) {
            onSequentialSegmentFinalized?(next, d)
            if d > 0 { seqHighestAdvertisedIndex = next }   // #369: zero-duration holes get no URI
            next += 1
        }
        seqNextReportIndex = next
    }

    /// #369: the advance park releases on a consumer fetch of `target`, but a sequential append
    /// playlist can only advertise up to the frontier this pump's OWN finalize reports have fed
    /// it, so parking on an index beyond that is waiting for oneself (field case: a fold-to-tail
    /// parked at target=364 while the playlist ended at seg61). A negative target releases
    /// instantly, so it is no deadlock. Pure for the unit test.
    static func sequentialParkWouldSelfDeadlock(target: Int, highestAdvertised: Int) -> Bool {
        target >= 0 && target > highestAdvertised
    }

    /// Forward discontinuity threshold. Distinct from NOPTS-dts repair (+1 tick scale); only fires on genuine multi-second leaps.
    static let discontinuityThresholdSeconds: Double = 10.0

    /// Tighter backward threshold (1.5 s) because any backward leap past the 0.5 s monotonic-glitch ceiling is a program boundary.
    /// 10 s symmetric threshold left a dead zone for short SSAI bumpers (~5 s reset); audio stutter resulted.
    static let discontinuityBackwardThresholdSeconds: Double = 1.5

    /// #368: rebase math of the video-stream timeline rebase; pure so the 2^33 chunk-seam wrap can be
    /// pinned in a unit test against the device trace. Output dts continues one fallback frame past
    /// the last output, whatever the source leaped to.
    static func rebasedVideoShift(
        srcDts: Int64,
        lastSrcDts: Int64,
        oldShift: Int64,
        fallbackDurationPts: Int64
    ) -> (newShift: Int64, continuationDts: Int64) {
        let lastOutputDts = lastSrcDts - oldShift
        let continuationDts = lastOutputDts + max(fallbackDurationPts, 1)
        return (srcDts - continuationDts, continuationDts)
    }

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
    /// Real audio frame handed to every muxer this producer builds, so moov (with its packet-derived
    /// dec3/dac3/dmlp) is written at init instead of at the first cut. Two origins, one field:
    /// - AE#222 seeds it from the host, and only on a session that already proved its first segment
    ///   carries no audio (nil on a normal session).
    /// - Every audio frame a muxer accepts then replaces it, so a LATER allocation (same-PID
    ///   parameter-set rotation, SSAI program switch) starts primed too. Video leads audio across a seam,
    ///   so a rotated muxer's first cut can arrive before any post-seam audio packet exists; unprimed,
    ///   that cut defers for a sample entry the bridge's encoder latency will never deliver in time and
    ///   the pump dies with `muxerFailed`.
    ///
    /// Pump-thread confined: written only from the two audio write sites, read only from `allocateMuxer`,
    /// and every muxer allocation goes through `ensureMuxer` on the pump thread.
    private var audioMoovPrimeFrame: [UInt8]?
    /// True when the session's audio codec derives its mp4 sample entry from a parsed packet
    /// (AC-3/E-AC-3/TrueHD); only then is a per-frame prime copy worth the memcpy. AAC never copies.
    private let capturesAudioPrimeFrames: Bool
    /// Latched when a cut deferred for want of an audio sample entry; the pump then scans forward for one
    /// real audio frame and exits with `.needsAudioSampleEntryPrime` so the host can rebuild primed.
    private var cutDeferredAwaitingAudioSampleEntry: Bool = false
    private var _capturedAudioMoovPrimeFrame: [UInt8]?
    /// Frame captured by the pump's prime scan; read by the host after the pump exits.
    var capturedAudioMoovPrimeFrame: [UInt8]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _capturedAudioMoovPrimeFrame
    }
    private var _audioMoovPrimeUnobtainable = false
    /// AE#366: the search finished everywhere it can look and this track yielded nothing, as opposed
    /// to a read that failed on the way. Structural, so the session records it and later producers
    /// skip the search instead of paying it again per revive attempt (~256 MiB of reads each).
    var audioMoovPrimeUnobtainable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _audioMoovPrimeUnobtainable
    }
    /// Set by the host from a previous producer's verdict; skips the search entirely.
    private let audioMoovPrimeKnownUnobtainable: Bool

    /// AE#396: the bridge's own account of what it did with the source, for the pump-finished handler.
    /// Nil for a stream-copy session, which has no bridge and whose analogous verdict is
    /// `audioMoovPrimeUnobtainable`.
    var audioBridgeFeedStats: AudioBridge.FeedStats? { audioConfig?.bridge?.feedStats }
    private var currentMuxer: MP4SegmentMuxer?
    /// AE#443: totals folded off muxers this producer has ROTATED away. A rotation (program switch, ad
    /// pod, a rebuilt muxer after a failure) hands the session a fresh `ByteCounter`, so a read of the
    /// current muxer alone drops everything the previous ones emitted, and the "lifetime" it is read as
    /// silently means "since the last rotation". Guarded by `stateLock` with `currentMuxer` itself.
    private var retiredMuxerBytes: Int = 0
    private var retiredMuxerFragmentCuts: Int = 0
    private var currentMuxerSegmentIndex: Int = .min

    /// Latched once first muxer emits ftyp+moov bytes; subsequent muxers' init bytes are discarded.
    private var initCaptured: Bool = false

    /// Last valid dts per stream (source TB); used to repair NOPTS dts via lastValidDts+1.
    private var lastVideoSourceDts: Int64 = Int64.min
    private var lastAudioSourceDts: Int64 = Int64.min

    /// AE#432: last GENUINE source dts per stream and the frame stride learned from it. A repaired
    /// timestamp says nothing about the source's cadence, so it is deliberately not fed back here.
    private var lastGenuineVideoSourceDts: Int64 = Int64.min
    private var lastGenuineAudioSourceDts: Int64 = Int64.min
    private var videoSourceStrideTicks: Int64 = 0
    private var audioSourceStrideTicks: Int64 = 0
    private var loggedFirstSynthesizedTimestamp = false

    /// First dts ever seen per stream; replay detection: backward rebase landing near this + recent reconnect = server replay.
    private var firstSeenVideoSourceDts: Int64 = Int64.min
    private var firstSeenAudioSourceDts: Int64 = Int64.min

    private static let sourceReplayReconnectWindowSeconds: TimeInterval = 30
    private static let sourceReplayStartWindowSeconds: Double = 10

    /// 2^33, the MPEG-TS 33-bit PTS/DTS clock. FFmpeg's wrap correction adds exactly this when the
    /// raw timestamp jumps backward across the wrap, so a source that renumbers its clock from zero
    /// reaches us as a dts of `2^33 + (small raw value)` rather than as a backward jump (#405).
    static let mpegTSWrapTicks: Int64 = 8_589_934_592

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
    /// AE#412: item-axis timestamp of the FIRST random-access point routed into each segment this
    /// epoch has open, consumed at adopt. Keyed by the muxer's index, not the cutter's: audio can
    /// have advanced the muxer past a boundary the keyframe-gated cutter folded, and a fetch asks
    /// for the segment the bytes ended up in. Pump thread only, like every other routing field.
    private var firstSyncItemPtsBySegment: [Int: Int64] = [:]
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

    /// AE#408: whether the plan promised that `restartTargetVideoPts` is a random-access point.
    /// True only for the keyframe-aligned plan, whose boundaries ARE container index entries. The
    /// uniform grid never claimed it, and a source-declared plan deliberately aims BELOW the segment's
    /// IRAP (AE#268), so neither may be re-anchored for opening past its target.
    private let boundaryClaimsRandomAccess: Bool

    /// AE#408: the gate target actually in force. Starts at `restartTargetVideoPts` and moves BACK when
    /// the boundary turns out not to be openable, so the segment covers its own advertised start
    /// instead of carrying content from the far side of a keyframe drought.
    private var effectiveGateTargetPts: Int64
    private var gateBackoffAttempts = 0

    /// AE#408: the lowest timestamp already proven to carry no sync sample up to the boundary. Starts
    /// at the boundary itself and descends with each re-aim, so a deeper attempt escalates as soon as
    /// it reaches known-empty ground instead of re-reading it to the boundary every time.
    private var gateProvenEmptyFromPts: Int64
    private var restartTargetAudioDts: Int64
    private var audioWaitForVideo: Bool
    private var firstActualVideoDts: Int64 = Int64.min
    private var firstActualAudioDts: Int64 = Int64.min

    /// #240: link arbitration. The pump claims the link while it is pulling from the source and
    /// releases it while parked, so the subtitle side readers (a second full copy of the stream on
    /// Matroska) can tell "the video path needs the bytes" from "the buffer is full". Set once
    /// before `start()`; nil for hosts that drive the engine without one (`aetherctl`, tests).
    var sideReaderLinkGate: SideReaderLinkGate?

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
    /// AE#406: the no-cut window, and the timer that judges it. Live pumps only. Pump-thread-owned
    /// properties; the watchdog object itself is the only thing the timer touches.
    private var noCutWatchdog: NoCutStallWatchdog?
    private var noCutWatchdogTimer: DispatchSourceTimer?

    /// AE#443: is the live pump inside the runaway headroom park right now?
    ///
    /// The park looks exactly like a dead source from every consumer-side vantage point, and two
    /// separate diagnostics said so for three rounds of #443 ("the producer is starved, not the
    /// consumer", "source stopped delivering"). A held pump is not a starved one, and the difference
    /// is only knowable here. Its own lock: written on the pump thread, read from the stall ladder.
    private let parkStateLock = NSLock()
    private var _liveHeadroomParked = false
    var isLiveHeadroomParked: Bool {
        parkStateLock.lock()
        defer { parkStateLock.unlock() }
        return _liveHeadroomParked
    }
    private func setLiveHeadroomParked(_ parked: Bool) {
        parkStateLock.lock()
        _liveHeadroomParked = parked
        parkStateLock.unlock()
    }
    private let noCutWatchdogQueue = DispatchQueue(label: "aether.nocut.watchdog", qos: .userInitiated)
    /// Tick of the lifted watchdog: fine against both windows (10 s wedge, 35 s starvation) and
    /// cheap, one lock and a subtraction unless it has something to say. A private queue rather
    /// than the global pool, for the same reason `SlowServeSignal` uses one: a starving source is
    /// exactly when the pool is busiest, and a late watchdog is the defect being fixed.
    private static let noCutWatchdogTickSeconds: TimeInterval = 1
    /// Cutter-wedge timeout: pump reads at full rate but finalizes no segment (hostile SSAI ad pod).
    private static let liveSegmentStallTimeoutSeconds: TimeInterval = 10
    /// Source-starvation timeout: feed trickles (slow/flaky CDN). Ingest retries ~31 s then terminates;
    /// escalating at the tight wedge timeout turns one slow segment into a full host retune (device repro: hung on -1001).
    static let liveSourceStarvationTimeoutSeconds: TimeInterval = 35
    /// Read rate (pkt/s) threshold classifying a no-cut stall as cutter-wedge vs. source-starvation.
    /// Healthy 1080p25: ~60 pkt/s. Rate-based to avoid misreading a trickle that accumulated a high count (Alex Berlin: 137 pkts/13 s = 10.5 pkt/s).
    static let liveWedgeProgressRateThreshold: Double = 40
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
    ///
    /// AE#446 round 3: `servingOutageRunway` is the one case where a dead source must not be given up
    /// on. The session has already diagnosed the outage, closed its window with ENDLIST, and is
    /// feeding the consumer segments it holds; the exit tears down the read that is the only thing
    /// able to notice the source coming back, and takes a playing session with it. Measured on the
    /// harness with a 76 s outage: the read was aborted 35 s in while 46 s of runway were still
    /// playing, so the source delivering again at +76 s was never seen and the session held its last
    /// frame for the rest of the run. Bounded by the same hold budget, so a consumer that stops
    /// fetching with runway still listed cannot keep a dead source open for the whole session.
    /// AE#446 round 8: `hasEverProduced` is false while the producer has not cut anything at all,
    /// which is the window a JOIN is judged on rather than an outage. It decides one thing: a join
    /// is never classified as a wedge. The wedge reading is "the cutter is being fed and cannot
    /// cut", and before the first cut there is no evidence for it, because a cutter that has not
    /// reached its first keyframe reads exactly like one that cannot cut what it is given. Its
    /// deadline is 10 s, measured on a mid-session SSAI pod, and applying it to a join would retune
    /// a healthy channel with a long GOP. So a join waits out the 35 s starvation deadline, at any
    /// read rate, and neither hold applies to it: the #177 hold defers to video PTS that is still
    /// advancing, and the round-3 hold to a closed window still feeding its consumer, and a join
    /// that has cut nothing is delivering to nobody either way.
    static func noCutStallAction(
        stalledFor: TimeInterval,
        readRate: Double,
        videoPtsAdvanceSeconds: Double,
        consecutiveHolds: Int,
        servingOutageRunway: Bool = false,
        hasEverProduced: Bool = true
    ) -> NoCutStallAction {
        let isWedge = hasEverProduced && readRate >= liveWedgeProgressRateThreshold
        guard hasEverProduced else {
            return stalledFor > liveSourceStarvationTimeoutSeconds ? .exitForRetune : .keepReading
        }
        let timeout = isWedge ? liveSegmentStallTimeoutSeconds : liveSourceStarvationTimeoutSeconds
        guard stalledFor > timeout else { return .keepReading }
        if isWedge,
           videoPtsAdvanceSeconds >= liveSlowDeliveryPtsAdvanceSeconds,
           consecutiveHolds < liveSlowDeliveryMaxHolds {
            return .holdForSlowDelivery
        }
        // A wedge is a cutter that cannot cut what it is being given, which waiting does not fix; the
        // runway deferral is for a source that is not giving it anything.
        if !isWedge, servingOutageRunway, consecutiveHolds < liveSlowDeliveryMaxHolds {
            return .holdForSlowDelivery
        }
        return .exitForRetune
    }

    // MARK: - AE#432: a source that stops carrying timestamps

    /// Widest inter-packet delta still read as a frame interval. Anything past a second is a
    /// program boundary or a renumbered clock, not a cadence.
    static let maxSynthesizedStrideSeconds: Double = 1.0

    /// How far a repaired timestamp advances when the source carried neither dts nor pts.
    ///
    /// It used to advance one tick, which satisfies the muxer's monotonic invariant and nothing
    /// else: on the 90 kHz MPEG-TS axis that is 11 microseconds for a whole 20 ms frame. The live
    /// cutter's clock IS this timestamp (`liveShouldCut` below reads the pts a keyframe carries),
    /// so a run of timestamp-less packets froze the clock and the cutter could not cut again for as
    /// long as the run lasted: 1792 packets and 30 keyframes went into one 85 MB segment advertised
    /// as 0.5 s (AE#432).
    ///
    /// Cascade, most specific first: the demuxer's own claim for this packet, then the last genuine
    /// delta this stream showed, then the frame duration the producer already carries for the last
    /// trun sample, then the historical single tick for a stream that has never carried a usable
    /// timestamp at all.
    static func repairStrideTicks(packetDuration: Int64, observedStride: Int64,
                                  fallbackDuration: Int64) -> Int64 {
        if packetDuration > 0 { return packetDuration }
        if observedStride > 0 { return observedStride }
        if fallbackDuration > 0 { return fallbackDuration }
        return 1
    }

    /// Adopts `dts - previousDts` as the stream's stride when it is forward and inside
    /// `maxStrideTicks`. A backward, standing or multi-second delta is a boundary or a replay, so
    /// the stride learned before it survives.
    static func updatedStrideTicks(current: Int64, previousDts: Int64, dts: Int64,
                                   maxStrideTicks: Int64) -> Int64 {
        guard previousDts != Int64.min, dts != Int64.min, maxStrideTicks > 0 else { return current }
        let delta = dts &- previousDts
        guard delta > 0, delta <= maxStrideTicks else { return current }
        return delta
    }

    /// The live cut rule, pure: a keyframe opens a new segment once its presentation time has moved
    /// `targetSeconds` past the open segment's start, or immediately when a program boundary forced
    /// a cut. Extracted so AE#432's wedge is testable against the rule the pump actually runs.
    static func liveShouldCut(ptsSeconds: Double, segmentStartSeconds: Double,
                              targetSeconds: Double, isKeyframe: Bool, forceCut: Bool) -> Bool {
        guard isKeyframe else { return false }
        return forceCut || ptsSeconds - segmentStartSeconds >= targetSeconds
    }

    // MARK: -

    private var lastPregateVideoLog: Int = 0
    private var lastPregateAudioLog: Int = 0
    private static let pregateLogInterval = 200
    /// AE#222 prime-scan bounds. 128 MiB is ~17 s of 60 Mbit/s UHD video, well past any real interleave gap
    /// (the reported source's audio starts ~4 s in), and the timeout covers a slow source rather than a
    /// far-away audio track.
    private static let moovPrimeScanByteCap = 128 * 1024 * 1024
    private static let moovPrimeScanTimeoutSeconds: TimeInterval = 30
    /// AE#366 seek-based hunt, used only after the forward scan came back empty. Per-probe budget is
    /// smaller than the forward scan's because a probe that lands inside the track's range finds a
    /// packet within one cluster; it is the POSITION that decides, not the depth.
    private static let moovPrimeHuntProbeByteCap = 32 * 1024 * 1024
    private static let moovPrimeHuntTimeoutSeconds: TimeInterval = 20
    private static let moovPrimeHuntFractions: [Double] = [0.5, 0.9, 0.25, 0.75]

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

    /// #207: byte bound for an opt-in whole-source window. The segment ceiling is only a sanity bound,
    /// so the race-ahead parks once it has filled the session retention budget (`PrefetchDiskBudget`).
    /// 0 disables the park (live, and any host that never opted in stays far below its budget anyway).
    private let prefetchDiskBudgetBytes: Int

    /// AE#464: the host's audio offset this producer's muxers write. Fixed for the producer's life;
    /// a new value arrives as a new producer (see `MP4SegmentMuxer.audioDelaySeconds`).
    private let audioDelaySeconds: Double

    /// #65 stall diag: only log a park once it exceeds ~2 segment durations of zero playback progress, so normal
    /// backpressure (releases within one segment) stays silent and a real wedge surfaces its frozen tuple.
    private static let backpressureWedgeLogThresholdSeconds = 12

    /// #65 watchdog: break a VOD backpressure park once the consumer fetch target has been frozen this long.
    /// Set above the log threshold so the diag tuple surfaces first. The host then re-anchors the producer on
    /// AVPlayer's real position; a slow-but-advancing consumer never trips the detector (see BackpressureWedgeDetector).
    private static let backpressureWedgeBreakThresholdSeconds = 24

    /// #207: a disk park is normal steady state for an opt-in prefetch, so it stays quiet until it has
    /// held long enough to be worth a line, then repeats every 30 s.
    private static let prefetchDiskParkLogThresholdSeconds = 10

    /// #93 retest fast path: break the park once the consumer fetch target AND the rendered clock have
    /// both been frozen this long while the consumer wants to play (rrgomes: the clock is provably flat
    /// within ~3 s of the park; the 24 s counter alone put recovery latency at 30-70 s). Only effective
    /// when `playbackPositionProvider` is wired; the dual-freeze guard is what keeps the short window
    /// safe (see BackpressureWedgeDetector.fastBreakThresholdSeconds).
    private static let backpressureWedgeFastBreakThresholdSeconds = 5

    /// Live disk runaway FLOOR for awaitLiveWindowHeadroom, for a session that cannot state its own
    /// window (`liveResidentCapProvider` unset). The live cap is `max(this, provider())`, and the
    /// provider's value is the sliding window plus slack, so the park always sits ABOVE the window.
    ///
    /// AE#443: this used to be the cap itself, and the claim above it was that a session could only
    /// approach it with a dead consumer. That was false for any window deeper than 180 segments: the
    /// playlist does not start sliding until `windowSegmentCount` segments exist, so the cache fills to
    /// the cap first and the pump parks there for the rest of the session. Measured on the loopback
    /// fixture at an 1800 s window and a 1 s cadence, an edge session with no seek at all: park at
    /// resident=180 after 179 s, never released, the edge frozen from that second on. The reporter of
    /// #443 measured the same shape against Jellyfin at a 3.9 s cadence, and 180 x 3.9 s is where his
    /// session froze, three campaigns running.
    private static let liveResidentSegmentCap = 180

    /// AE#286: how much produced-but-unfetched content has to sit ahead of the consumer before the
    /// pump's work stops being latency-critical. `HLSLocalServer` answers segment requests from a
    /// `.userInitiated` work queue, and a cache miss parks that thread in `cache.fetch` until this pump
    /// produces the segment, so a permanently demoted pump is a priority inversion dispatch cannot see.
    /// Held well below the `forwardWindow` the pump parks at, so the two states cannot flap.
    private static let pumpRelaxedLeadSeconds = 16.0

    /// `pumpRelaxedLeadSeconds` in this session's segments, floor 2.
    private var pumpRelaxedLeadSegments: Int {
        Self.relaxedLeadSegments(targetSegmentDurationSeconds: targetSegmentDurationSeconds)
    }

    static func relaxedLeadSegments(targetSegmentDurationSeconds: Double) -> Int {
        max(2, Int((pumpRelaxedLeadSeconds / max(1.0, targetSegmentDurationSeconds)).rounded(.up)))
    }

    /// Whether the pump may run at the relaxed (efficiency) QoS. Pure so the guards are testable
    /// without a session: `targetIndex < 0` is a consumer that has not fetched at all,
    /// `hasStartedRendering == false` is one still filling its startup buffer, and a short lead is a
    /// consumer sitting on the production head, which is a rebuffer in progress.
    ///
    /// `epochHighestStored` is what THIS pump has written since it started, not `cache.highestStoredIndex`.
    /// The cache's high-water is monotonic across producer epochs, so a pump restarted for a seek reads
    /// the previous epoch's head, computes a comfortable lead over content it has not produced, and
    /// demotes itself in the one window where the consumer is provably blocked on it. Measured: a
    /// restart at idx=127 with the old epoch at 135 demoted 5 ms into the seek landing.
    static func pumpMayRelax(hasStartedRendering: Bool, targetIndex: Int,
                             epochHighestStored: Int, relaxedLeadSegments: Int) -> Bool {
        guard hasStartedRendering, targetIndex >= 0, epochHighestStored >= 0 else { return false }
        return epochHighestStored - targetIndex >= relaxedLeadSegments
    }

    /// Pump-thread-only: the QoS class the pump last requested for itself, the segment index the last
    /// decision was taken at, and the highest segment index THIS pump has written to the cache. No
    /// lock; only `runPumpLoop` and its callees touch these.
    private var pumpQoSCurrent: qos_class_t = QOS_CLASS_USER_INITIATED
    private var pumpQoSLastSeg = Int.min
    private var pumpEpochHighestStored = Int.min

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

    // MARK: - AE#408: a boundary that is not a random-access point

    /// How far below the boundary each successive re-aim attempt targets, in seconds.
    ///
    /// The first step is deliberately short: the point at-or-before the boundary is what the segment
    /// needs, and aiming one segment back finds it whenever the source has any random access there at
    /// all. Wider steps exist for a real drought, and the list is the whole budget.
    ///
    /// AE#423: the steps are EVEN, not doubling. Each attempt opens on the first sync sample at or
    /// above where it aimed, so the distance between two steps is the worst case by which the gate can
    /// overshoot the last sample that would have covered the boundary, and a doubling step spends that
    /// error where it is largest. On the AE#408 fixture the 8 -> 16 jump aimed at 36.0, took 38.417,
    /// and never saw the 43.0 sitting between it and the boundary at 52.0: 4.6 s of landing accuracy
    /// given away for nothing. Even steps cost no more to walk, because `gateProvenEmptyFromPts` stops
    /// each scan at the previous aim rather than at the boundary, so an attempt reads its own window
    /// and not the whole drought. Same 32 s of reach as the doubling list.
    static let gateBackoffStepsSeconds: [Double] = [4, 8, 12, 16, 20, 24, 28, 32]

    /// Floor for the tolerance below; the reorder depth of the stream widens it (see
    /// `boundaryOpenToleranceTicks`).
    static let boundaryOpenToleranceSeconds: Double = 0.5

    /// AE#408: how far past the boundary a sync sample may present before it is worth going back for.
    ///
    /// A container index entry is a DECODE timestamp while the gate judges presentation time
    /// (AE#169 round 3), so even a perfectly formed index puts the keyframe's PTS a reorder delay
    /// above the boundary it was indexed at. Charging that skew a second seek would re-aim on every
    /// restart of a B-pyramid encode, so the tolerance covers the stream's own declared depth plus a
    /// frame, and never falls below the floor.
    static func boundaryOpenToleranceTicks(
        reorderFrames: Int32, frameDurationPts: Int64, floorTicks: Int64
    ) -> Int64 {
        let frame = Swift.max(0, frameDurationPts)
        let reorder = Int64(Swift.max(0, reorderFrames)) &* frame
        return Swift.max(floorTicks, reorder &+ frame)
    }

    /// How far past the target the scan reads before calling the boundary unopenable. A seek can land
    /// a reorder window early, and those frames present past the target while their own keyframe is
    /// still to come, so a single non-key packet is not evidence on its own.
    static let boundaryProbeGraceSeconds: Double = 1.0

    /// AE#408: proof that a boundary the plan called a random-access point is not one.
    ///
    /// Matroska Cues are seek points, not sync points, and libavformat enters every one of them into
    /// the index as `AVINDEX_KEYFRAME` regardless of the block's own keyframe flag
    /// (`matroska_add_index_entries`). A plan built from that index therefore advertises boundaries
    /// the producer cannot open on, and the reporting asset in AE#408 carried 11 s of them.
    ///
    /// `sawKeyframeBeforeTarget` is the veto: when the seek landed on a keyframe of its own BELOW the
    /// target, the packets presenting past it are that keyframe's reorder window and say nothing about
    /// the boundary.
    static func boundaryProvenNotRandomAccess(
        droppedPts: Int64, targetPts: Int64,
        sawKeyframeBeforeTarget: Bool, graceTicks: Int64
    ) -> Bool {
        guard targetPts != Int64.min, droppedPts != Int64.min else { return false }
        guard !sawKeyframeBeforeTarget else { return false }
        // The packet the plan named IS the answer when it lands exactly: no random access here.
        if droppedPts == targetPts { return true }
        return droppedPts >= targetPts &+ graceTicks
    }

    /// AE#408: whether the gate must re-aim below the boundary instead of opening on this keyframe.
    ///
    /// Opening past the boundary does not just start late, it makes the segment carry content from the
    /// far side of the gap while the playlist keeps claiming the boundary's own time. Every seek into
    /// that segment then lands that far off, which is the 3 to 14 s the reporter measured.
    static func shouldReanchorBeforeOpening(
        keyframePts: Int64, boundaryPts: Int64, toleranceTicks: Int64,
        attemptsUsed: Int, maxAttempts: Int
    ) -> Bool {
        guard boundaryPts != Int64.min, keyframePts != Int64.min else { return false }
        guard attemptsUsed < maxAttempts else { return false }
        return keyframePts > boundaryPts &+ toleranceTicks
    }

    /// AE#408: which item-axis timestamp the epoch's first frame is published at.
    ///
    /// A gate that opened LATE is pinned to the advertised start, because the alternative is a hole
    /// at that time and AVPlayer waits on holes forever; the resulting shift is what moves the whole
    /// item axis. A gate that opened EARLY (a re-aim went back for a sync sample covering the
    /// boundary) keeps its own position instead: that publishes an overlap with the previous segment,
    /// which AVPlayer absorbs, and it leaves the item axis where the plan puts it, so the seek that
    /// caused the restart lands where it was aimed.
    ///
    /// Both operands must be on the ITEM axis. `actualFirstDts` is a source timestamp, and the two
    /// differ by the plan anchor on every source whose content does not start at PTS 0 (a Blu-ray
    /// beginning at 11.6 s, the restart-witness fixture at 0.083 s). Comparing them raw published
    /// every restarted epoch a whole anchor early, which is what the fixture-backed restart-continuity
    /// tests caught.
    ///
    /// AE#509: and never below zero. `tfdt` carries `unsigned int(64)` (ISO/IEC 14496-12), so a
    /// negative item axis is not expressible at all: movenc writes the value as-is and AVPlayer reads
    /// `baseMediaDecodeTime = 2^64 - |dts|`, about six million years, against a playlist that starts
    /// at 0. The item then fetches the whole window and places none of it, with no error and no
    /// stall of its own. libavformat produces those negative timestamps by design, not by accident:
    /// an MPEG-TS whose first DTS sits within 60 s of the 33-bit PTS wrap is classified
    /// `AV_PTS_WRAP_SUB_OFFSET` and every timestamp comes out 2^33 ticks low (demux.c, "correct first
    /// time stamps to negative values"). That is an ordinary live join, not an early-opening gate,
    /// and the clamp is what keeps the two apart.
    static func pinnedFirstTfdtPts(
        actualFirstDts: Int64, desiredTfdtPts: Int64, planAnchorPts: Int64
    ) -> Int64 {
        guard actualFirstDts != Int64.min else { return desiredTfdtPts }
        let actualItemPts = actualFirstDts &- planAnchorPts
        return max(0, actualItemPts < desiredTfdtPts ? actualItemPts : desiredTfdtPts)
    }

    /// AE#418: the offset the HOST folds, which is not the offset the MUXER applies.
    ///
    /// Measured with `aetherctl play --picture-probe` against a fixture whose picture states its own
    /// source time: AVPlayer presents a segment at the position the PLAYLIST gives it, not at the
    /// tfdt the segment carries. So the axis a consumer reads is the distance between the first
    /// frame's source time and the segment's ADVERTISED start, whatever the muxer wrote. On a pinned
    /// (late) gate the pin makes the two identical, which is why publishing the mux shift held until
    /// the early-opening gate of AE#408 landed; on a re-aimed gate they differ by the whole re-aim,
    /// and the clock then ran that far ahead of the picture (captions early by the same amount).
    ///
    /// AE#418 round 4: taken on the first PTS, not the first DTS. A segment opens on a random-access
    /// point in DECODE order, and with B-frames that sample is presented `video_delay` frames later
    /// than it is decoded, so the two differ by exactly the composition offset the segment carries for
    /// it. This is an offset about what AVPlayer SHOWS, so it is measured where the picture is: the
    /// gate's own line already carried both numbers (`actual=42917 anchorPts=43000` on a 24 fps h264
    /// fixture with `has_b_frames=2`), and the axis was published from the decode one. Measured with
    /// `play --picture-probe`, that put the published axis 0.083 s under the truth on every epoch of
    /// a B-frame source and 0.000 s under it on the same fixture encoded without them.
    static func presentedShiftPts(actualFirstPts: Int64, desiredTfdtPts: Int64) -> Int64 {
        guard actualFirstPts != Int64.min, desiredTfdtPts != Int64.min else { return 0 }
        return actualFirstPts &- desiredTfdtPts
    }

    /// AE#418 round 5: how far after its own decode time the gating sample is PRESENTED, named on the
    /// gate-open line so a log says what reorder depth the gate opened at.
    ///
    /// Rounds 5 to 7 also composed with it, on the premise that a placement sits below its axis by
    /// some multiple of this. Round 8 measured a clip with no frame reordering at all, whose every
    /// gate opens with a lead of zero, sitting a frame below its axis on its third placement, which
    /// no multiple of zero describes. The composition measures that distance directly now; this stays
    /// a source fact worth printing.
    static func presentationLeadPts(actualFirstPts: Int64, actualFirstDts: Int64) -> Int64 {
        guard actualFirstPts != Int64.min, actualFirstDts != Int64.min else { return 0 }
        return Swift.max(0, actualFirstPts &- actualFirstDts)
    }

    /// AE#408: aim the gate below a boundary that cannot be opened on, so the segment covers its own
    /// advertised start. Returns false when there is nothing left to try, in which case the caller
    /// keeps the old behaviour (open at the next random-access point and carry the shift).
    ///
    /// Only for a plan whose boundaries CLAIM random access. The uniform grid never made that claim,
    /// and a source-declared plan aims below its IRAP on purpose (AE#268); re-aiming either would move
    /// the producer a segment back for no reason. Live is excluded because its target is a join point,
    /// not a plan boundary, and there is nothing behind it to seek to.
    private func reanchorGateBelowBoundary(reason: String) -> Bool {
        guard boundaryClaimsRandomAccess, !isLive,
              restartTargetVideoPts > Int64.min,
              sourceVideoTbSeconds > 0,
              gateBackoffAttempts < Self.gateBackoffStepsSeconds.count else { return false }
        // A side audio demuxer is a second source the engine positions itself; seeking only the main
        // one here would leave the merge reading from two different places.
        guard sideAudioDemuxer == nil else { return false }

        let step = Self.gateBackoffStepsSeconds[gateBackoffAttempts]
        let aim = Swift.max(planAnchorVideoPts, restartTargetVideoPts &- Int64(step / sourceVideoTbSeconds))
        guard aim < effectiveGateTargetPts else { return false }
        gateBackoffAttempts += 1
        // Everything from the abandoned aim up to the boundary has now been read without a sync
        // sample, so the next attempt escalates when it reaches here rather than reading it again.
        gateProvenEmptyFromPts = effectiveGateTargetPts

        guard demuxer.seek(to: aim, streamIndex: videoStreamIndex) else {
            EngineLog.emit(
                "[HLSSegmentProducer] boundary re-aim to \(aim) failed to seek; "
                + "opening at the next random-access point instead",
                category: .session
            )
            return false
        }
        discardPregateScanState()
        effectiveGateTargetPts = aim
        EngineLog.emit(
            "[HLSSegmentProducer] boundary \(restartTargetVideoPts) is not a random-access point "
            + "(\(reason)); re-aimed the gate \(String(format: "%.0f", step))s below it at \(aim) "
            + "so the segment covers its own start "
            + "(attempt \(gateBackoffAttempts)/\(Self.gateBackoffStepsSeconds.count))",
            category: .session
        )
        return true
    }

    /// Drop everything the closed gate accumulated, so a re-aimed scan starts clean. The pre-gate
    /// audio belongs to the abandoned position, and the source-dts anchors would read the backward
    /// seek as a timeline discontinuity.
    private func discardPregateScanState() {
        for entry in pregateAudioBuffer {
            var pkt: UnsafeMutablePointer<AVPacket>? = entry.0
            trackedPacketFree(&pkt)
        }
        pregateAudioBuffer.removeAll()
        pregateAudioBufferBytes = 0
        pregateAudioReplaySorted = false
        pregateAudioOverflowLogged = false
        pregateVideoDropCount = 0
        pregateAudioDropCount = 0
        lastPregateVideoLog = 0
        lastPregateAudioLog = 0
        pregateWaitStart = nil
        firstSeenVideoSourceDts = Int64.min
        firstSeenAudioSourceDts = Int64.min
        lastVideoSourceDts = Int64.min
        lastAudioSourceDts = Int64.min
        freeMergeLookaheads()
        packetCounterLock.lock()
        _lastPregateDroppedKeyframePts = Int64.min
        packetCounterLock.unlock()
    }

    var muxerLifetimeFragmentBytes: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return retiredMuxerBytes + (currentMuxer?.lifetimeFragmentBytesEmitted ?? 0)
    }

    var muxerFragmentCuts: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return retiredMuxerFragmentCuts + (currentMuxer?.fragmentCutCount ?? 0)
    }

    /// The only way `currentMuxer` changes. Folds the outgoing muxer's totals in first, so every
    /// rotation site inherits the accounting instead of having to remember it (AE#443).
    private func installMuxer(_ new: MP4SegmentMuxer?) {
        stateLock.lock()
        if let outgoing = currentMuxer {
            retiredMuxerBytes &+= outgoing.lifetimeFragmentBytesEmitted
            retiredMuxerFragmentCuts &+= outgoing.fragmentCutCount
        }
        currentMuxer = new
        stateLock.unlock()
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

    /// #260: resolves the host's per-frame time observer at emission rather than holding it, so a host that
    /// installs one mid-session reaches the running producer without a data race on a stored closure. Set
    /// before `start()`; nil leaves the emission out entirely.
    var nativeVideoFrameTimeObserverProvider: (@Sendable () -> NativeVideoFrameTimeObserver?)?

    /// Monotonic producer generation, reported with every frame time so a consumer can drop entries from an
    /// epoch whose segments a restart has since rewritten (#260).
    let epoch: UInt64

    /// Fires at video gate-open with videoShiftPts (source video TB); re-fires on restart (matroska seek imprecision can shift).
    /// `firstItemTfdtPts` is this producer's planned first tfdt, i.e. the item-axis position (same TB) from which
    /// its shift applies. Everything below it on the item axis was muxed by an earlier producer under an earlier
    /// shift and may still be in AVPlayer's buffer, so a consumer needs the pair, not the shift alone (#260).
    var onVideoShiftKnown: (@Sendable (_ shiftPts: Int64, _ firstItemTfdtPts: Int64, _ normalizationShiftPts: Int64) -> Void)?

    /// Fires at live program boundary with updated videoShiftPts and seamOutputSeconds (AVPlayer clock position of the seam).
    /// Distinct from onVideoShiftKnown: the new shift is at the producer edge, AVPlayer renders it buffer+holdback later.
    /// #368: also fires at a sequential chunk-seam rebase too; the source-PTS consumers (A53 caption tap,
    /// subtitle mapping) need the playlist axis moved the same way there.
    var onLiveTimelineRebase: (@Sendable (_ shiftPts: Int64, _ seamOutputSeconds: Double) -> Void)?

    enum PumpExitReason: Sendable, CustomStringConvertible {
        case eof
        case stopRequested
        case readError(code: Int32)
        case muxerFailed
        /// AE#222: the first cut could not write moov because the audio sample entry is packet-derived
        /// (E-AC-3/AC-3/TrueHD) and the source's first segment carries no audio packet. The pump captured a
        /// real audio frame on its way out (`capturedAudioMoovPrimeFrame`); the host rebuilds with it as the
        /// muxer's moov prime, which keeps the stream-copy (and any Atmos) instead of falling back.
        case needsAudioSampleEntryPrime
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
            case .needsAudioSampleEntryPrime: return "needsAudioSampleEntryPrime"
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

    /// AE#446 round 3: reads whether the session is serving a window it closed with ENDLIST because
    /// the source stopped delivering, with segments the consumer has not reached yet. While that is
    /// true the no-cut watchdog's starvation exit would tear down a session that is still handing out
    /// pictures, and with it the only read able to notice the source coming back. nil = false, which
    /// is the historical behaviour for tests and every non-live path.
    var outageRunwayProvider: (@Sendable () -> Bool)?

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

    /// The two shapes a source restart reaches the producer in. Both mean the same thing (the
    /// origin restarted its stream and is re-sending content this session has already played) and
    /// both end the pump for a host retune; they differ only in how the timestamps arrive.
    enum SourceRestartShape: Equatable {
        /// Raw dts jumped BACKWARD to near where this session first joined: the server replayed
        /// from its beginning on a connection we had just rebuilt.
        case rewind
        /// The source renumbered its 33-bit clock from zero mid-connection. FFmpeg reads that as a
        /// wrap and adds 2^33, so it arrives as a large FORWARD jump whose wrap-corrected raw value
        /// sits at the start of the axis (#405).
        case axisReset
    }

    /// Pure classifier for both shapes, testable without a demuxer.
    ///
    /// #405: the old check opened with `jumpTicks < 0` and so could only ever see the rewind. The
    /// field trace was the other shape: `srcDts=8589934592` (2^33 exactly, i.e. a raw dts of 0),
    /// `jumpTicks=+8487014192`, eleven seconds of already-played content re-sent behind an
    /// EXT-X-DISCONTINUITY while the viewer watched them twice.
    ///
    /// The anchor differs per shape and that matters: the rewind lands near `firstSeenDts` because
    /// the server restarted the PROGRAM, but an axis reset lands near ZERO regardless of where this
    /// session joined the ring. In the field trace those are 1121 s apart (`oldShift=100915200`),
    /// so testing an axis reset against `firstSeenDts` would have missed it.
    ///
    /// The axis reset is live-only. A sequential origin's archive chunks legitimately open their
    /// own axis at zero (#368), and reading that as a replay would end a healthy pump.
    static func sourceRestartShape(newDts: Int64,
                                   jumpTicks: Int64,
                                   firstSeenDts: Int64,
                                   tbSeconds: Double,
                                   isLive: Bool) -> SourceRestartShape? {
        guard firstSeenDts != Int64.min, tbSeconds > 0 else { return nil }
        let windowTicks = Int64(Self.sourceReplayStartWindowSeconds / tbSeconds)
        if jumpTicks < 0 {
            return newDts <= firstSeenDts + windowTicks ? .rewind : nil
        }
        guard isLive, newDts >= Self.mpegTSWrapTicks else { return nil }
        return newDts % Self.mpegTSWrapTicks <= windowTicks ? .axisReset : nil
    }

    /// Replay-from-start check. The rewind additionally requires a recent unplanned reconnect: on
    /// that shape the discriminator against an ordinary programme boundary is that we had just
    /// rebuilt the connection. The axis reset carries its own discriminator and must NOT require
    /// one, because the origin renumbers on the connection it already holds (field trace: `gen=1->1`,
    /// `reconnects=0`); a programme boundary inside one transport stream keeps its PCR axis running,
    /// and a genuine 33-bit wrap after ~26.5 h is a continuous correction, not a jump over the
    /// discontinuity threshold.
    private func isSourceReplay(newDts: Int64,
                                jumpTicks: Int64,
                                firstSeenDts: Int64,
                                tbSeconds: Double,
                                stream: String) -> Bool {
        guard let shape = Self.sourceRestartShape(newDts: newDts,
                                                  jumpTicks: jumpTicks,
                                                  firstSeenDts: firstSeenDts,
                                                  tbSeconds: tbSeconds,
                                                  isLive: isLive)
        else { return false }
        switch shape {
        case .rewind:
            guard let reconnectAt = demuxer.lastUnplannedSourceReconnectAt,
                  Date().timeIntervalSince(reconnectAt) < Self.sourceReplayReconnectWindowSeconds
            else { return false }
            EngineLog.emit(
                "[HLSSegmentProducer] live source REPLAY detected on \(stream): "
                + "srcDts=\(newDts) firstSeenDts=\(firstSeenDts) jumpTicks=\(jumpTicks) "
                + "reconnect \(String(format: "%.1f", Date().timeIntervalSince(reconnectAt)))s ago; "
                + "server restarted the stream from its beginning, exiting pump for host retune",
                category: .session
            )
        case .axisReset:
            EngineLog.emit(
                "[HLSSegmentProducer] live source AXIS RESET detected on \(stream): "
                + "srcDts=\(newDts) (wrap-corrected raw=\(newDts % Self.mpegTSWrapTicks)) "
                + "firstSeenDts=\(firstSeenDts) jumpTicks=+\(jumpTicks); "
                + "source renumbered its 33-bit clock from zero and is re-sending content already "
                + "played, exiting pump for host retune",
                category: .session
            )
        }
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
        boundaryClaimsRandomAccess: Bool = false,
        closedCaptionStreamIndex: Int32 = -1,
        subtitleTapStreamIndices: Set<Int32> = [],
        subtitlePacketStreamIndices: Set<Int32> = [],
        desiredFirstVideoTfdtPts: Int64,
        desiredFirstAudioTfdtPts: Int64 = 0,
        segmentBoundaries: [Int64],
        planAnchorVideoPts: Int64 = 0,
        isLive: Bool = false,
        foldsSequentialTimeline: Bool = false,
        packedSideAudioStartPts: Int64? = nil,
        packedSideAudioFallbackDurationPts: Int64 = 0,
        bufferAheadSegments: Int = 10,
        prefetchDiskBudgetBytes: Int = 0,
        audioMoovPrimeFrame: [UInt8]? = nil,
        audioMoovPrimeKnownUnobtainable: Bool = false,
        audioDelaySeconds: Double = 0,
        epoch: UInt64 = 0
    ) throws {
        self.epoch = epoch
        self.audioDelaySeconds = audioDelaySeconds
        self.audioMoovPrimeFrame = audioMoovPrimeFrame
        self.audioMoovPrimeKnownUnobtainable = audioMoovPrimeKnownUnobtainable
        self.capturesAudioPrimeFrames =
            audio.map { MP4SegmentMuxer.audioNeedsParsedPacketForMoov($0.codecpar.pointee.codec_id) } ?? false
        self.bufferAheadSegments = bufferAheadSegments
        self.prefetchDiskBudgetBytes = prefetchDiskBudgetBytes
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
        // #365: the measured framing wins when the session has one. Deriving it from the extradata is
        // a guess that only holds while both ends agree, and a source where they disagree is exactly
        // the one whose packets nobody can walk.
        a53NALFraming = video.nalFramingOverride ?? A53SEIParser.nalFraming(
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
        self.planAnchorVideoPts = planAnchorVideoPts
        self.vodCutter = VODSegmentCutter(
            sourceBoundaries: segmentBoundaries,
            planAnchorPts: planAnchorVideoPts,
            baseIndex: baseIndex
        )
        self.isLive = isLive
        self.foldsSequentialTimeline = foldsSequentialTimeline
        self.liveCurrentSegmentIndex = baseIndex
        self.videoFallbackDurationPts = videoFallbackDurationPts
        self.audioFallbackDurationPts = audioFallbackDurationPts
        self.restartTargetVideoPts = restartTargetVideoPts
        self.boundaryClaimsRandomAccess = boundaryClaimsRandomAccess
        self.effectiveGateTargetPts = restartTargetVideoPts
        self.gateProvenEmptyFromPts = restartTargetVideoPts
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
    ///
    /// AE#446 round 6: seg-0's recorded start is a PRESENTATION time, and the shift anchors the first
    /// DECODE time at 0, so on a source with frame reordering the first segment of a live session
    /// begins one presentation lead above zero rather than at 0.000 (`lead=` on the gate-open line).
    /// That is the number the item's stated axis carries, and it is a property of the source: 0.033s
    /// on a 60 fps `-bf 3` seed here, 0.050s on the reporter's broadcast TS, 0.000s on the bundled
    /// seed, which is why a harness that only ran the bundled seed made zero look like a rule.
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
        if Self.liveShouldCut(ptsSeconds: ptsSeconds,
                              segmentStartSeconds: liveSegmentStartPtsSeconds,
                              targetSeconds: targetSegmentDurationSeconds,
                              isKeyframe: isKeyframe,
                              forceCut: pendingForceCutFlag) {
            liveCurrentSegmentIndex += 1
            liveSegmentStartPtsSeconds = ptsSeconds
            liveSegmentStartByIndex[liveCurrentSegmentIndex] = ptsSeconds
            pendingForceCutFlag = false
            liveSegmentDiscontinuousByIndex[liveCurrentSegmentIndex] = pendingDiscontinuityFlag
            pendingDiscontinuityFlag = false
        }
        return liveCurrentSegmentIndex
    }

    /// One stamp for both readers of "a live segment was finalized just now": the field the pump
    /// reads on its way past, and the watchdog window a timer evaluates (AE#406).
    private func stampLiveSegmentFinalize() {
        let now = Date()
        lastLiveSegmentFinalizeAt = now
        noCutWatchdog?.noteFinalize(at: now)
    }

    private var sourceVideoTbSeconds: Double {
        guard sourceVideoTimeBase.num > 0, sourceVideoTimeBase.den > 0 else { return 0 }
        return Double(sourceVideoTimeBase.num) / Double(sourceVideoTimeBase.den)
    }

    /// Source audio time base in seconds; 0 when there is no audio or it is degenerate.
    private var audioSourceTbSeconds: Double {
        guard let tb = audioConfig?.sourceTimeBase, tb.num > 0, tb.den > 0 else { return 0 }
        return Double(tb.num) / Double(tb.den)
    }

    /// AE#432: says once per pump that the source stopped carrying timestamps and what the engine
    /// put in their place. Silent before this, which is why the field trace could only show the
    /// consequence (a frozen cut clock) and not the cause.
    private func noteSynthesizedTimestamp(strideTicks: Int64, isVideo: Bool) {
        guard !loggedFirstSynthesizedTimestamp else { return }
        loggedFirstSynthesizedTimestamp = true
        let tb = isVideo ? sourceVideoTbSeconds : audioSourceTbSeconds
        EngineLog.emit(
            "[HLSSegmentProducer] source stopped carrying timestamps on the "
            + "\(isVideo ? "video" : "audio") stream; synthesizing at \(strideTicks) ticks/packet"
            + (tb > 0 ? " (\(String(format: "%.4f", Double(strideTicks) * tb))s)" : "")
            + ". The live cutter reads this timestamp, so its segments are paced by it from here on",
            category: .session
        )
    }

    /// Map post-shift (item-axis) pts to absolute segment index.
    ///
    /// AE#268: folds back the PLAN ANCHOR, not `videoShiftPts`. The two are equal whenever the gate
    /// opened on the boundary the restart aimed at, but a restart that landed off a random-access
    /// point carries the whole overshoot in the shift, and folding that back routed audio into a
    /// segment index the video cutter never opened (a 10 s GOP under a 4 s plan skewed them by up to
    /// two segments). The anchor is what the plan's item axis is defined against, so it is what maps
    /// an item-axis timestamp onto a plan boundary.
    private func segmentIndex(forSourcePts pts: Int64) -> Int {
        return baseIndex + Self.segmentOffset(
            forAbsolutePts: pts &+ planAnchorVideoPts,
            boundaries: segmentBoundaries
        )
    }

    /// Source-axis value of a timestamp the pump has already rebased onto the output axis
    /// (`pts -= videoShiftPts`). Anything the producer hands to a consumer that works in source
    /// PTS has to come back through here (#259). NOPTS and an unresolved shift pass through.
    static func foldingShiftBack(_ value: Int64, shift: Int64) -> Int64 {
        guard value != Int64.min, shift != Int64.min else { return value }
        return value &+ shift
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
        // #240: parked means the forward buffer is full and the link is free. Released here rather
        // than at the call sites so it is balanced whatever the park returns.
        sideReaderLinkGate?.videoFetchEnded()
        defer { sideReaderLinkGate?.videoFetchBegan() }
        var parked = 0
        var nextLogAt = Self.backpressureWedgeLogThresholdSeconds
        // AE#528: the wait below returns on ANY cache broadcast (a consumer GET that moves the fetch
        // target, a stored segment), not only at its timeout, so one iteration is a wakeup and not a
        // second. Everything under it is expressed in seconds, so the seconds come from the clock.
        var parkClock = ParkClock(nowNanos: DispatchTime.now().uptimeNanoseconds)
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
                retunePumpQoS()
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
            guard let parkedSeconds = parkClock.advance(nowNanos: DispatchTime.now().uptimeNanoseconds)
            else { continue }
            parked = parkedSeconds
            let cacheTarget = cache.targetIndex
            // #65 pause false-positive: a paused/backgrounded VOD consumer issues no forward fetch, so its
            // frozen fetch target is not a wedge. Gate the detector on play intent (nil provider = assume
            // playing, unchanged for live + tests); the legit starved-but-wants-to-play wedge keeps tripping.
            let wantsToPlay = wantsToPlayProvider?() ?? true
            // #35/#93 cold-startup: before the first frame lands a flat clock is pre-roll, not a wedge.
            let hasStarted = hasStartedRenderingProvider?() ?? true
            // AE#528: observed BEFORE the log line so `stuck=` names this poll and not the last one.
            let tripped = !isLive && wedgeDetector.observe(currentTarget: cacheTarget,
                                                           wantsToPlay: wantsToPlay,
                                                           renderedPosition: playbackPositionProvider?(),
                                                           hasStartedRendering: hasStarted)
            if !isLive, parked >= nextLogAt {
                nextLogAt += 10
                let suspendReason = !wantsToPlay ? "(consumer paused; wedge detection suspended)"
                    : !hasStarted ? "(pre-first-frame; wedge detection suspended)"
                    // AE#528: a park is not a stall. What decides is whether the consumer is still
                    // asking for segments, and stuck= is that number: 0 is a viewer scrubbing through
                    // resident content, a climbing one is a consumer that went quiet.
                    : wedgeDetector.secondsSinceTargetMoved == 0 ? "(consumer still fetching)"
                    : "(no playback progress)"
                EngineLog.emit(
                    "[HLSSegmentProducer] #65 backpressure PARK (\(context)) head=\(head) "
                    + "target=\(target) cacheTarget=\(cacheTarget) "
                    + "highStored=\(cache.highestStoredIndex) cached=\(cache.count) parked=\(parked)s "
                    + "stuck=\(wedgeDetector.secondsSinceTargetMoved)s "
                    + suspendReason,
                    category: .session
                )
            }
            if tripped {
                markBackpressureWedgeBroken()
                EngineLog.emit(
                    "[HLSSegmentProducer] #65 backpressure WEDGE BROKEN (\(context)) head=\(head) "
                    + "target=\(target) cacheTarget=\(cacheTarget) parked=\(parked)s "
                    // AE#421: the line has to say which repair the wedge calls for, and that is
                    // decided by whether the consumer's own target is already on disk. Without it a
                    // report can show the wedge and the recovery but not whether re-anchoring the
                    // producer could have helped at all, which is exactly what had to be inferred
                    // from two field logs.
                    + "consumerTargetStored=\(cache.peekURL(index: cacheTarget) != nil ? "y" : "n") "
                    + "highStored=\(cache.highestStoredIndex) cached=\(cache.count)"
                    + (wedgeDetector.lastTripFast ? " (fast path: fetch target + rendered clock both frozen)" : "")
                    + "; exiting pump for host re-anchor on AVPlayer position",
                    category: .session
                )
                return false
            }
        }
        return false
    }

    /// Live replacement for the advance-path backpressure park (#65). Live production is source-paced,
    /// so overproduction is bounded by the origin's real-time delivery; the only unbounded case is a
    /// consumer that stopped polling entirely, which this cap catches. Logs from the first cycle (the
    /// old live park was silent below 12 s, which is why consumer-facing 6-8 s freezes never showed a
    /// producer-side line). Returns true on release, false when stop was requested.
    ///
    /// What makes this safe against a held blocking reload is the HEIGHT of the cap, not the release
    /// path. A parked pump finalizes no segment, so `segments.count` stops growing, so the playlist
    /// window stops sliding and `notePlaylistBuild -> evictBelow` evicts nothing: while the park holds,
    /// the only thing that lowers `cache.count` is `pruneOutsideWindow` off a consumer segment GET
    /// (`declareTarget`), structurally the same release the #65 park waited on. The deadlock is out of
    /// reach only because reaching `liveResidentSegmentCap` takes a consumer that is already dead, and
    /// the engine's 12 s stall watchdogs reload the item (and thus issue a fresh GET) long before then.
    /// Lowering the cap toward the steady-state window would put that deadlock back within reach.
    /// AE#443: the resident count this pump refuses to pass. The session states it (window plus
    /// slack); the static floor only covers a session that cannot.
    private func liveResidentCap() -> Int {
        max(Self.liveResidentSegmentCap, liveResidentCapProvider?() ?? 0)
    }

    private func awaitLiveWindowHeadroom(head: Int) -> Bool {
        if cache.count < liveResidentCap() { return true }
        // #240: a parked pump is not using the link.
        sideReaderLinkGate?.videoFetchEnded()
        defer { sideReaderLinkGate?.videoFetchBegan() }
        // AE#406: nor is it reading. Inline, the watchdog could not run here at all; on a timer it
        // must not count a park as starvation, or a consumer that stopped polling would be reported
        // as a source that stopped delivering. The window re-anchors when the park releases.
        noCutWatchdog?.setReading(false, at: Date())
        defer { noCutWatchdog?.setReading(true, at: Date()) }
        // AE#443: so the stall ladder can name the pump instead of the source.
        setLiveHeadroomParked(true)
        defer { setLiveHeadroomParked(false) }
        var parked = 0
        while !checkShouldStop() {
            // AE#443: re-read per second rather than latching the entry value. The window is sized
            // from the observed cadence and segment size, so it moves while a park holds, and a park
            // that outlived its own reason would keep the origin undrained for nothing.
            let cap = liveResidentCap()
            if cache.count < cap {
                EngineLog.emit(
                    "[HLSSegmentProducer] live headroom released head=\(head) after=\(parked)s "
                    + "resident=\(cache.count)",
                    category: .session
                )
                return true
            }
            if parked % 10 == 0 {
                EngineLog.emit(
                    "[HLSSegmentProducer] live headroom PARK head=\(head) resident=\(cache.count) "
                    + "cap=\(cap) parked=\(parked)s (playlist polls stopped?). AE#443: this pump is "
                    + "not reading while it is parked, so the origin is not being drained either; a "
                    + "single-connection live source dies behind a long park",
                    category: .session
                )
            }
            Thread.sleep(forTimeInterval: 1.0)
            parked += 1
        }
        return false
    }

    /// #207 disk park. The segment window is a sanity bound; the real bound on an opt-in whole-source
    /// prefetch is the session retention budget, which `pruneOutsideWindow` cannot enforce because it
    /// never evicts the hard window. Parks the pump while the race-ahead has filled that budget AND the
    /// consumer still has a safe lead, so the footprint tracks the budget instead of the source length.
    /// Carries no wedge breaker of its own: the park only ever holds with `PrefetchDiskBudget
    /// .minAheadSegments` of produced content ahead of the consumer, and the extras eviction that
    /// follows the advancing playhead releases it. That rests on the advance park having caught a
    /// consumer that stopped advancing first, so `detectWedge` (#369: the advance park was skipped
    /// because its release target sat beyond the sequential playlist's frontier) arms the same #65
    /// detector here. Its cadence matches: this loop polls once a second, like the advance park.
    /// Returns true on release, false when stop was requested.
    private func awaitPrefetchDiskBudgetRelease(head: Int, context: String,
                                                detectWedge: Bool = false) -> Bool {
        guard prefetchDiskBudgetBytes > 0 else { return true }
        // #240: same release as the backpressure park; a parked pump is not using the link.
        sideReaderLinkGate?.videoFetchEnded()
        defer { sideReaderLinkGate?.videoFetchBegan() }
        var parked = 0
        var nextLogAt = Self.prefetchDiskParkLogThresholdSeconds
        // AE#528: same wakeup-is-not-a-second correction as the advance park; this loop's own doc
        // above claims a one second cadence and the headroom wait returns on every cache broadcast.
        var parkClock = ParkClock(nowNanos: DispatchTime.now().uptimeNanoseconds)
        var wedgeDetector = detectWedge && !isLive
            ? BackpressureWedgeDetector(
                breakThresholdSeconds: Self.backpressureWedgeBreakThresholdSeconds,
                fastBreakThresholdSeconds: Self.backpressureWedgeFastBreakThresholdSeconds,
                initialTarget: cache.targetIndex,
                initialRenderedPosition: playbackPositionProvider?())
            : nil
        while !checkShouldStop() {
            if cache.awaitPrefetchDiskHeadroom(head: head,
                                               budgetBytes: prefetchDiskBudgetBytes,
                                               timeout: 1.0) {
                if parked >= Self.prefetchDiskParkLogThresholdSeconds {
                    EngineLog.emit(
                        "[HLSSegmentProducer] #207 prefetch disk park released (\(context)) head=\(head) "
                        + "after=\(parked)s cacheTarget=\(cache.targetIndex) "
                        + "forward=\(cache.forwardBytes / (1 << 20)) MiB",
                        category: .session
                    )
                }
                return true
            }
            guard let parkedSeconds = parkClock.advance(nowNanos: DispatchTime.now().uptimeNanoseconds)
            else { continue }
            parked = parkedSeconds
            if parked >= nextLogAt {
                nextLogAt += 30
                EngineLog.emit(
                    "[HLSSegmentProducer] #207 prefetch disk PARK (\(context)) head=\(head) "
                    + "cacheTarget=\(cache.targetIndex) forward=\(cache.forwardBytes / (1 << 20)) MiB "
                    + "budget=\(prefetchDiskBudgetBytes / (1 << 20)) MiB parked=\(parked)s "
                    + "(opt-in prefetch full; resumes as playback advances)",
                    category: .session
                )
            }
            if wedgeDetector != nil,
               wedgeDetector!.observe(currentTarget: cache.targetIndex,
                                      wantsToPlay: wantsToPlayProvider?() ?? true,
                                      renderedPosition: playbackPositionProvider?(),
                                      hasStartedRendering: hasStartedRenderingProvider?() ?? true) {
                markBackpressureWedgeBroken()
                EngineLog.emit(
                    "[HLSSegmentProducer] #369 disk park WEDGE BROKEN (\(context)) head=\(head) "
                    + "cacheTarget=\(cache.targetIndex) parked=\(parked)s"
                    + (wedgeDetector!.lastTripFast ? " (fast path: fetch target + rendered clock both frozen)" : "")
                    + "; the advance park was skipped, so this park was the last hold. "
                    + "Exiting pump for host re-anchor on AVPlayer position",
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
        // Live never parks on the fetch high-water (see awaitLiveWindowHeadroom); an SSAI
        // versioned-init re-alloc mid-live must not re-enter the park either.
        if initialSegmentIndex != baseIndex, !isLive {
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
            doviConfig: isAdCreative ? .keep : videoConfig.doviConfig,
            colorOverride: isAdCreative ? nil : videoConfig.colorOverride,
            extradataOverride: isAdCreative ? nil : videoConfig.extradataOverride
        )
        let muxerAudio: MP4SegmentMuxer.AudioConfig? = audioConfig.map { a in
            MP4SegmentMuxer.AudioConfig(codecpar: a.codecpar, timeBase: a.inputTimeBase, language: a.language)
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
                // AE#222 + mid-session rotation: the last frame a muxer accepted, or the host's
                // construction-time prime while no muxer has accepted one yet.
                audioMoovPrimeFrame: audioMoovPrimeFrame,
                audioDelaySeconds: audioDelaySeconds,
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
            // Write through installMuxer: telemetry getters read currentMuxer under stateLock, and the
            // outgoing muxer's totals have to be folded before the reference goes.
            self.installMuxer(muxer)
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

    /// Returns [start, end) on the AVPlayer axis for subtitle injection. VOD: from segmentBoundaries
    /// minus the plan anchor (AE#268: the anchor defines the item axis; the shift carries a restart's
    /// gate overshoot on top of it and would move the window under the cues). Live: from liveSegmentStartByIndex.
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
            let t0 = Double(segmentBoundaries[i] - planAnchorVideoPts) * sourceVideoTbSeconds
            let t1 = Double(segmentBoundaries[iNext] - planAnchorVideoPts) * sourceVideoTbSeconds
            return (t0, t1)
        }
    }

    /// AE#222 prime scan: read forward from wherever the pump stopped until the muxed audio stream yields one
    /// packet, and copy its bytes. That single frame is all movenc needs to build the real `dec3` / `dac3` /
    /// `dmlp` sample entry, so the rebuilt session keeps its stream-copy (Atmos included) instead of bridging.
    ///
    /// Scoped to single-demuxer stream-copy audio: a bridged session's muxed frames come from the encoder, not
    /// the source, and feeding the bridge here would consume the very encoder state a restart depends on (#99
    /// root cause B). Bounded so a source whose audio never arrives (or arrives absurdly late) gives up and
    /// leaves the host's fallbacks in charge instead of stalling the session on an unbounded read.
    private func scanForAudioMoovPrimeFrame() -> [UInt8]? {
        guard let audio = audioConfig, audio.bridge == nil, sideAudioDemuxer == nil else { return nil }
        // AE#366: a previous producer of this session already looked everywhere it can look. Paying
        // the scan plus the hunt again on every revive attempt buys the same answer for a few hundred
        // MiB of reads, which on a remote source is minutes of black screen before the host is told.
        guard !audioMoovPrimeKnownUnobtainable else {
            EngineLog.emit(
                "[HLSSegmentProducer] AE#366 skipping the moov-prime search: this session already "
                + "searched the whole source for an audio frame and found none",
                category: .session
            )
            markAudioMoovPrimeUnobtainable()
            return nil
        }
        let result = readForwardForAudioFrame(
            streamIndex: audio.sourceStreamIndex,
            byteCap: Self.moovPrimeScanByteCap,
            deadline: Date().addingTimeInterval(Self.moovPrimeScanTimeoutSeconds),
            label: "AE#222 prime scan"
        )
        if let frame = result.frame { return frame }
        guard result.mayRetryElsewhere else { return nil }
        return huntAudioMoovPrimeFrameBySeeking(streamIndex: audio.sourceStreamIndex)
    }

    /// AE#366: the forward scan assumes the audio is a few seconds behind the video in FILE order.
    /// That holds for the #222 shape and fails completely for a track that is sparsely interleaved or
    /// muxed in bulk somewhere else: the first packet of a legacy dub can sit hundreds of MiB in, and
    /// no byte budget rescues that. Worse, the budget is a byte budget, so what it buys shrinks as the
    /// bitrate grows: 128 MiB is five minutes of a 3 Mbps encode and ten seconds of a 97 Mbps UHD one.
    ///
    /// The frame does not have to be the FIRST one. AC-3 and E-AC-3 are one complete syncframe per
    /// packet and movenc's `handle_eac3` builds the whole sample entry from whichever frame it gets
    /// (AE#340), and the prime frame's timestamp is discarded anyway (the muxer truncates the prime
    /// fragment and re-arms `frag_discont`). So instead of reading further and further forward, seek
    /// to a handful of positions and take any frame the track yields there.
    ///
    /// The order is picked for the two shapes that produce this failure: a track present throughout
    /// with wide gaps (the midpoint finds it immediately) and a track muxed in bulk near the end (the
    /// 90 % probe does). Nothing in the container says which one it is: measured on a fixture whose
    /// first audio packet sits at 211 MiB, `AVStream.start_time` for that track still reads 0.
    /// Probe positions in seconds, midpoint first. Empty for a source whose duration is unknown or
    /// too short to have anywhere else to look, which is also every live source.
    static func moovPrimeHuntPositions(durationSeconds: Double) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > 1 else { return [] }
        return moovPrimeHuntFractions.map { durationSeconds * $0 }
    }

    private func huntAudioMoovPrimeFrameBySeeking(streamIndex: Int32) -> [UInt8]? {
        // Live is forward-only: a seek would abandon the join point, and a live source that has not
        // produced an audio packet yet will produce one on its own.
        guard !isLive else { return nil }
        let positions = Self.moovPrimeHuntPositions(durationSeconds: demuxer.duration)
        guard !positions.isEmpty else { return nil }
        let deadline = Date().addingTimeInterval(Self.moovPrimeHuntTimeoutSeconds)

        for target in positions {
            if checkShouldStop() || Date() > deadline { break }
            guard demuxer.seek(to: target) else {
                EngineLog.emit(
                    "[HLSSegmentProducer] AE#366 prime hunt: seek to "
                    + "\(String(format: "%.1f", target))s failed; source is not seekable, giving up",
                    category: .session
                )
                markAudioMoovPrimeUnobtainable()
                return nil
            }
            let result = readForwardForAudioFrame(
                streamIndex: streamIndex,
                byteCap: Self.moovPrimeHuntProbeByteCap,
                deadline: deadline,
                label: "AE#366 prime hunt at \(String(format: "%.1f", target))s"
            )
            if let frame = result.frame { return frame }
            if !result.mayRetryElsewhere { return nil }
        }
        EngineLog.emit(
            "[HLSSegmentProducer] AE#366 prime hunt: no audio packet at any probe position; "
            + "the selected track cannot prime the moov in this session",
            category: .session
        )
        markAudioMoovPrimeUnobtainable()
        return nil
    }

    /// Records the structural verdict. Deliberately NOT set when a read threw or the pump was asked
    /// to stop: those say nothing about the track, and treating them as final would turn a transient
    /// I/O hiccup into a dead session.
    private func markAudioMoovPrimeUnobtainable() {
        stateLock.lock()
        _audioMoovPrimeUnobtainable = true
        stateLock.unlock()
    }

    /// One bounded forward read for a packet on `streamIndex`, copying its bytes.
    ///
    /// `mayRetryElsewhere` is false when the read itself failed or the caller was told to stop: those
    /// are reasons to abandon the hunt, unlike "this region carries no audio", which is a reason to
    /// look somewhere else.
    private func readForwardForAudioFrame(
        streamIndex: Int32, byteCap: Int, deadline: Date, label: String
    ) -> (frame: [UInt8]?, mayRetryElsewhere: Bool) {
        var bytesRead = 0
        var packetsRead = 0

        while true {
            if checkShouldStop() { return (nil, false) }
            if bytesRead >= byteCap || Date() > deadline {
                EngineLog.emit(
                    "[HLSSegmentProducer] \(label) gave up after \(packetsRead) packet(s) / "
                    + "\(bytesRead / (1024 * 1024)) MiB without an audio packet",
                    category: .session
                )
                return (nil, true)
            }
            let pkt: UnsafeMutablePointer<AVPacket>?
            do {
                pkt = try demuxer.readPacket()
            } catch {
                EngineLog.emit(
                    "[HLSSegmentProducer] \(label) read failed: \(error)",
                    category: .session
                )
                return (nil, false)
            }
            guard let packet = pkt else {
                EngineLog.emit(
                    "[HLSSegmentProducer] \(label) hit EOF after \(packetsRead) packet(s) "
                    + "without an audio packet",
                    category: .session
                )
                return (nil, true)
            }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            packetsRead += 1
            bytesRead += Int(max(packet.pointee.size, 0))

            guard packet.pointee.stream_index == streamIndex,
                  packet.pointee.size > 0,
                  let data = packet.pointee.data
            else { continue }

            let frame = [UInt8](UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)))
            EngineLog.emit(
                "[HLSSegmentProducer] \(label) captured a \(frame.count) B audio frame after "
                + "\(packetsRead) packet(s) / \(bytesRead / (1024 * 1024)) MiB "
                + "(srcDts=\(packet.pointee.dts))",
                category: .session
            )
            return (frame, true)
        }
    }

    private func advanceMuxer(to newIdx: Int) -> MP4SegmentMuxer? {
        guard let muxer = currentMuxer else { return nil }

        switch muxer.cutFragmentForNextSegment(newIdx) {
        case .completed(let path, let bytesWritten):
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(currentMuxerSegmentIndex).m4s captured (\(bytesWritten) B)",
                category: .session, level: .verbose
            )
            cache.adopt(index: currentMuxerSegmentIndex,
                        stagingPath: path,
                        byteCount: bytesWritten,
                        videoReach: takeVideoReach(forSegmentIndex: currentMuxerSegmentIndex))
            // AE#286: per-epoch head. cache.highestStoredIndex is monotonic across restarts and would
            // credit this pump with the previous epoch's production.
            pumpEpochHighestStored = max(pumpEpochHighestStored, currentMuxerSegmentIndex)
            if isLive {
                reportLiveSegmentFinalized(index: currentMuxerSegmentIndex,
                                           nextIndex: newIdx)
            } else if onSequentialSegmentFinalized != nil {
                reportSequentialSegmentFinalized(index: currentMuxerSegmentIndex, isFinal: false)
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
        case .deferredAwaitingAudioSampleEntry:
            // AE#222: not a failure. moov cannot carry dec3/dac3/dmlp until one audio packet has been muxed,
            // and this source's first segment has none (its audio blocks sit behind seconds of video in file
            // order). Nothing was written, so the pump exits to let the host rebuild with a prime frame; the
            // scan for that frame happens on the way out.
            cutDeferredAwaitingAudioSampleEntry = true
            // AE#396: the two ways to arrive here are not the same defect and must not read the same.
            // Stream-copy audio is missing a SOURCE packet, which the prime scan goes looking for. A
            // bridged session's muxed frames come from the encoder, so there is nothing in the source
            // to scan for and `scanForAudioMoovPrimeFrame` returns without looking: announcing a scan
            // there described an action that never happened, on the one path where the interesting
            // question ("why has the bridge emitted nothing?") had no line at all.
            if let bridge = audioConfig?.bridge {
                EngineLog.emit(
                    "[HLSSegmentProducer] AE#396 seg-\(currentMuxerSegmentIndex).m4s cut deferred: the "
                    + "audio sample entry is built from a BRIDGED packet and the bridge has muxed none. "
                    + "Bridge: \(bridge.feedStats.summary)",
                    category: .session
                )
            } else {
                EngineLog.emit(
                    "[HLSSegmentProducer] AE#222 seg-\(currentMuxerSegmentIndex).m4s cut deferred: audio sample "
                    + "entry needs a parsed packet and none has been muxed; scanning forward for a prime frame",
                    category: .session
                )
            }
            return nil
        case .failed:
            // Failed cut: muxer has no open staging fd, every byte is silently discarded. Fatal.
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(currentMuxerSegmentIndex).m4s cut FAILED; "
                + "muxer is wedged, ending pump",
                category: .session
            )
            return nil
        }
        // #358: the cut jumped over plan indices, so no keyframe reached their boundaries and no
        // segment will ever open there. The VOD playlist still offers them, which is what turns the
        // gap into a consumer that waits forever, so record them for the wedge handler.
        if !isLive, newIdx > currentMuxerSegmentIndex + 1 {
            let folded = (currentMuxerSegmentIndex + 1)..<newIdx
            cache.noteFolded(folded)
            if folded.count > SegmentCache.maxFoldRunLength {
                // #369: a leap this wide is not a long GOP, a timeline jump escaped the rebase.
                EngineLog.emit(
                    "[HLSSegmentProducer] #369 cut leap of \(folded.count) plan indices "
                    + "(discontinuity-scale; a timeline jump escaped the rebase)",
                    category: .session
                )
            }
            EngineLog.emit(
                "[HLSSegmentProducer] #358 plan indices \(folded.lowerBound)...\(folded.upperBound - 1) "
                + "folded into seg-\(newIdx) (no IRAP reached their boundary)",
                category: .session
            )
        }
        currentMuxerSegmentIndex = newIdx
        if isLive {
            // Live is source-paced: the pump only runs ahead of real time while draining the join
            // backlog, and the sliding window (notePlaylistBuild -> evictBelow) bounds resident
            // segments. Parking on the consumer's fetch high-water here deadlocked against a held
            // LL-HLS blocking reload (the hold starves the segment GET that would release the park)
            // and pushed TCP backpressure onto the single-connection origin whenever the join
            // backlog exceeded bufferAheadSegments.
            if !awaitLiveWindowHeadroom(head: newIdx) { return nil }
        } else {
            let backpressureTarget = newIdx - bufferAheadSegments
            let parkSkipped = onSequentialSegmentFinalized != nil
                && Self.sequentialParkWouldSelfDeadlock(target: backpressureTarget,
                                                        highestAdvertised: seqHighestAdvertisedIndex)
            if parkSkipped {
                // #369: skip the self-deadlocking park; the disk budget below stays the resource
                // bound, and normal parking resumes as soon as the frontier catches back up.
                if !loggedSequentialParkSkip {
                    loggedSequentialParkSkip = true
                    EngineLog.emit(
                        "[HLSSegmentProducer] #369 backpressure park skipped: "
                        + "target=\(backpressureTarget) is beyond the advertisable "
                        + "frontier=\(seqHighestAdvertisedIndex); the frontier only advances "
                        + "while this pump runs",
                        category: .session
                    )
                }
            } else if !awaitBackpressureRelease(target: backpressureTarget, head: newIdx, context: "advance") {
                return nil
            }
            // #369 follow-up: a skipped advance park hands the only remaining hold to the disk park,
            // whose "no wedge breaker needed" rests on the advance park having caught a frozen
            // consumer first. Carry the detector across, or the pump races to the budget and then
            // parks there forever on a consumer that will never move again.
            if !awaitPrefetchDiskBudgetRelease(head: newIdx, context: "advance",
                                               detectWedge: parkSkipped) { return nil }
        }
        if checkShouldStop() { return nil }

        return muxer
    }

    /// Sequential-VOD duration became known (next segment's start recorded at the ledger).
    /// Reports immediately when the segment is already captured; otherwise parks until the
    /// capture side arrives.
    private func noteSequentialDurationKnown(index: Int, duration: Double) {
        if seqCapturedAwaitingDuration.remove(index) != nil {
            emitSequentialReport(index: index, duration: duration)
        } else {
            seqDurationAwaitingCapture[index] = duration
        }
    }

    /// Sequential-VOD capture side of the pairing. `isFinal` (EOF finalize) reports with the cut
    /// target when no next ledger entry will ever supply the real duration - one estimated tail
    /// EXTINF beats a playlist that never completes.
    private func reportSequentialSegmentFinalized(index: Int, isFinal: Bool) {
        if let dur = seqDurationAwaitingCapture.removeValue(forKey: index) {
            emitSequentialReport(index: index, duration: dur)
        } else if isFinal {
            let dur: Double
            if let start = vodSegmentStartByIndex[index], lastMuxedItemAxisSeconds > start {
                dur = lastMuxedItemAxisSeconds - start
            } else {
                dur = targetSegmentDurationSeconds
            }
            emitSequentialReport(index: index, duration: dur)
        } else {
            seqCapturedAwaitingDuration.insert(index)
        }
    }

    /// Newest item-axis video segment start muxed (seconds); floors the final segment's EXTINF
    /// estimate at EOF. Pump-thread only.
    private var lastMuxedItemAxisSeconds: Double = 0

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
        stampLiveSegmentFinalize()
        EngineLog.emit(
            "[HLSSegmentProducer] live seg-\(index) finalized: start=\(String(format: "%.3f", startSeconds))s "
            + "dur=\(String(format: "%.3f", duration))s"
            + (discontinuous ? " [DISCONTINUITY]" : ""),
            category: .session
        )
        onLiveSegmentFinalized?(index, duration, startSeconds, discontinuous)
    }

    /// AE#412: what the segment finalized at `index` offers a cold arrival, as an offset from its
    /// ADVERTISED start, so the answer carries no axis with it. Consumes the recording.
    ///
    /// nil means "no claim", which is exactly today's behaviour: live (its playlist only ever offers
    /// what was finalized), an unresolved video time base, or an index outside this epoch's plan.
    /// `.none` is a claim, and a load-bearing one: audio opened a boundary the cutter folded, so the
    /// segment carries no random-access point at all and nothing in it can start a decode run.
    private func takeVideoReach(forSegmentIndex index: Int) -> SegmentCache.VideoReach? {
        let syncPts = firstSyncItemPtsBySegment.removeValue(forKey: index)
        firstSyncItemPtsBySegment = firstSyncItemPtsBySegment.filter { $0.key > index }
        guard !isLive, sourceVideoTbSeconds > 0 else { return nil }
        let localI = index - baseIndex
        guard localI >= 0, localI < segmentBoundaries.count else { return nil }
        guard let syncPts, syncPts != Int64.min else {
            EngineLog.emit(
                "[HLSSegmentProducer] #412 seg-\(index) carries no random-access point "
                + "(advertised \(String(format: "%.3f", Double(segmentBoundaries[localI]) * sourceVideoTbSeconds))s); "
                + "a cold arrival cannot start a decode run in it",
                category: .session
            )
            return SegmentCache.VideoReach.none
        }
        let shiftTicks = videoShiftPts == Int64.min ? 0 : videoShiftPts
        let syncSourcePts = syncPts &+ shiftTicks
        let offset = Double(syncSourcePts &- segmentBoundaries[localI]) * sourceVideoTbSeconds
        if offset > 0 {
            EngineLog.emit(
                "[HLSSegmentProducer] #412 seg-\(index) opens \(String(format: "%.3f", offset))s "
                + "below its first random-access point; a cold arrival below that lands late",
                category: .session, level: .verbose
            )
        }
        return .syncAt(offsetSeconds: offset)
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
                        byteCount: result.bytesWritten,
                        videoReach: takeVideoReach(forSegmentIndex: idx))
            if isLive {
                reportLiveSegmentFinalized(index: idx, nextIndex: nil)
            } else if onSequentialSegmentFinalized != nil {
                reportSequentialSegmentFinalized(index: idx, isFinal: true)
            }
        } else {
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(idx).m4s final finalize failed; not adopted",
                category: .session
            )
        }
        installMuxer(nil)
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
        installMuxer(nil)
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

        // AE#286: a thread we own rather than a dispatch queue, because the pump's urgency changes
        // within one long-running block and a queue's QoS is fixed at creation.
        let thread = Thread { [weak self] in
            self?.runPumpLoop()
        }
        thread.name = "AetherEngine.HLSSegmentProducer.pump"
        thread.stackSize = 1 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// AE#286: match the pump's QoS to whether anything is waiting on it. Called at segment
    /// boundaries and after a backpressure park, both cheap and both points where the answer can
    /// have changed. VOD only: live production is source-paced and the LL-HLS blocking reload holds
    /// an AVPlayer request open on the very next segment, so live is latency-critical throughout.
    private func retunePumpQoS() {
        guard !isLive else { return }
        let target = cache.targetIndex
        let lead = pumpEpochHighestStored >= 0 ? String(pumpEpochHighestStored - target) : "n/a"
        // A consumer that has fetched has still not necessarily started rendering: AVPlayer keeps
        // filling its startup buffer after the first segment, and demoting there cost 80 ms of
        // time-to-first-frame under load with the forward buffer already 9 segments deep.
        let relaxed = Self.pumpMayRelax(
            hasStartedRendering: hasStartedRenderingProvider?() ?? true,
            targetIndex: target,
            epochHighestStored: pumpEpochHighestStored,
            relaxedLeadSegments: pumpRelaxedLeadSegments
        )
        let desired: qos_class_t = relaxed ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INITIATED
        guard desired != pumpQoSCurrent else { return }
        pumpQoSCurrent = desired
        pthread_set_qos_class_self_np(desired, 0)
        // Read the class back: a thread that was opted out of the QoS system silently keeps the old
        // one, and then the whole mechanism is a no-op that still looks configured.
        EngineLog.emit(
            "[HLSSegmentProducer] pump qos -> \(QoSClass.name(desired)) "
            + "(now=\(QoSClass.name(qos_class_self())) epochHead=\(pumpEpochHighestStored) "
            + "target=\(target) lead=\(lead))",
            category: .session
        )
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
        guard !pumpFirstReadLogged else { return try readNextSourcePacketMergedTapped() }
        pumpFirstReadLogged = true
        let t0 = DispatchTime.now()
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            EngineLog.emit(
                "[HLSSegmentProducer] first source read after start took \(Int(ms))ms",
                category: .session, level: ms > 1000 ? .info : .verbose
            )
        }
        return try readNextSourcePacketMergedTapped()
    }

    /// AE#560: the one place every source packet of this route passes through on its way to the
    /// pump, main demuxer and side-audio demuxer already merged into global decode order. The
    /// recording tap sits here rather than on `Demuxer.readPacket` for exactly that reason: a
    /// packed AAC audio rendition in live HLS rides a SIDE demuxer, and a tap on the main one
    /// alone would record those channels silently without audio.
    ///
    /// It is also upstream of `bridge.feed`, so the recording carries the source's own audio codec
    /// while playback listens to the bridged rendition.
    private func readNextSourcePacketMergedTapped() throws -> (packet: UnsafeMutablePointer<AVPacket>, origin: PacketOrigin)? {
        let read = try readNextSourcePacketMerged()
        if let read { tapForRecording(read.packet) }
        return read
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

    // MARK: - No-cut watchdog (AE#406)

    /// Arm the watchdog and the timer that reads it. Live only: a sequential source finalizes on
    /// its own plan and has no live edge to fall behind.
    private func startNoCutWatchdog() {
        let watchdog = NoCutStallWatchdog(videoTimeBaseSeconds: sourceVideoTbSeconds)
        // AE#446 round 8: the window used to begin at the first cut, which is stamped when the video
        // gate opens. A source that stops before it delivers one video packet therefore had no
        // deadline at all: nothing to time out, nothing logged, the host never told. Arm the window
        // here, so "the pump has been reading and nothing was ever cut" is judged like any other
        // starved source.
        if let already = lastLiveSegmentFinalizeAt {
            watchdog.noteFinalize(at: already)
        } else {
            watchdog.armForJoin(at: Date())
        }
        noCutWatchdog = watchdog
        let timer = DispatchSource.makeTimerSource(queue: noCutWatchdogQueue)
        timer.schedule(deadline: .now() + Self.noCutWatchdogTickSeconds,
                       repeating: Self.noCutWatchdogTickSeconds,
                       leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tickNoCutWatchdog(watchdog) }
        noCutWatchdogTimer = timer
        timer.resume()
    }

    private func stopNoCutWatchdog() {
        noCutWatchdogTimer?.cancel()
        noCutWatchdogTimer = nil
    }

    /// One tick, off the read thread. The hold logs and re-arms; the exit logs, latches, and aborts
    /// the read the pump is parked in, because a cancel flag alone cannot reach a thread inside
    /// `av_read_frame` (which is what `HLSVideoEngine`'s own teardown already pairs `stop()` with).
    /// The abort costs nothing this exit was going to keep: `.segmentStall` delegates to a host
    /// retune, which tears the demuxer down.
    private func tickNoCutWatchdog(_ watchdog: NoCutStallWatchdog) {
        guard let decision = watchdog.evaluate(
            now: Date(), servingOutageRunway: outageRunwayProvider?() ?? false) else { return }
        switch decision {
        case .holdForOutageRunway(let w):
            EngineLog.emit(
                "[HLSSegmentProducer] #446 outage hold "
                + "\(w.consecutiveHolds)/\(Self.liveSlowDeliveryMaxHolds): nothing cut for "
                + "\(Int(w.stalledFor))s (rate=\(String(format: "%.1f", w.readRate))pkt/s), and the "
                + "closed window is still feeding the consumer; keeping the source read so the source "
                + "coming back can still be seen",
                category: .session
            )
        case .holdForSlowDelivery(let w):
            EngineLog.emit(
                "[HLSSegmentProducer] slow live delivery hold "
                + "\(w.consecutiveHolds)/\(Self.liveSlowDeliveryMaxHolds): video PTS "
                + "+\(String(format: "%.1f", w.videoPtsAdvanceSeconds))s in \(Int(w.stalledFor))s "
                + "(rate=\(String(format: "%.1f", w.readRate))pkt/s); not a wedge, "
                + "re-arming watchdog instead of retuning",
                category: .session
            )
        case .exitForRetune(let w):
            EngineLog.emit(
                (w.everProduced
                 ? "[HLSSegmentProducer] no-cut stall: no segment finalized for "
                 : "[HLSSegmentProducer] #446 the join never cut anything: nothing produced in ")
                + "\(Int(w.stalledFor))s (packetsRead=\(w.packetsRead), "
                + "sinceFinalize=\(w.progress), "
                + "rate=\(String(format: "%.1f", w.readRate))pkt/s, "
                + "\(w.everProduced ? (w.isWedge ? "cutter wedge" : "source starvation") : "the video gate never opened, so nothing was ever cut to serve")); "
                + "window video=\(w.videoPackets) key=\(w.videoKeyframes) "
                + "audio=\(w.audioPackets) foreign=\(w.foreignPackets)"
                + (w.synthesizedVideoPackets > 0
                    ? " synthesizedTs=\(w.synthesizedVideoPackets)" : "")
                + (w.lastForeignStreamIndex >= 0
                    ? " lastForeignIdx=\(w.lastForeignStreamIndex)" : "")
                + (w.videoPtsAdvanceSeconds >= 0
                    ? " videoPtsAdvance=\(String(format: "%.1f", w.videoPtsAdvanceSeconds))s" : "")
                + (w.consecutiveHolds > 0
                    ? " holdsExhausted=\(w.consecutiveHolds)" : "")
                + "; aborting the source read and exiting for host retune",
                category: .session
            )
            demuxer.markClosed()
            sideAudioDemuxer?.markClosed()
        }
    }

    // MARK: - Pump

    private func runPumpLoop() {
        // AE#286: a (re)started pump always begins latency-critical. Nothing has been produced for
        // this epoch yet, and both of its entry reasons, cold start and a seek landing, have the
        // consumer waiting on the first segment it cuts.
        pumpQoSCurrent = QOS_CLASS_USER_INITIATED
        pumpQoSLastSeg = Int.min
        pumpEpochHighestStored = Int.min
        pthread_set_qos_class_self_np(pumpQoSCurrent, 0)
        EngineLog.emit(
            "[HLSSegmentProducer] pump thread qos=\(QoSClass.name(qos_class_self()))",
            category: .session
        )
        if restartTargetVideoPts > Int64.min {
            bumpRestartCount()
        }
        // #240: a running pump is pulling from the source. Claimed for the whole loop and released
        // on every exit path; the two park helpers hand it back for the duration of their wait.
        sideReaderLinkGate?.videoFetchBegan()
        defer { sideReaderLinkGate?.videoFetchEnded() }
        let pumpStart = DispatchTime.now()
        var packetsRead = 0
        var lastError: Int32 = 0
        var exitReason: PumpExitReason = .eof
        // AE#406: the no-cut window used to live in this loop's locals, which is what tied the
        // decision to the read the loop is parked in. It lives in the watchdog now, and a timer
        // reads it; this loop only reports what it read and observes the verdict.
        if isLive { startNoCutWatchdog() }
        defer { stopNoCutWatchdog() }
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

                if noCutWatchdog?.hasLatchedExit == true {
                    exitReason = .segmentStall
                    break readLoop
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
                    noCutWatchdog?.notePacketRead()
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
                    if lastLiveSegmentFinalizeAt != nil { stampLiveSegmentFinalize() }
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

                // AE#432: learn each stream's frame stride from its GENUINE timestamps, so a run
                // that arrives without any can be advanced by a plausible interval instead of a
                // single tick. Recorded before the repair below, and never from a repaired value.
                if packet.pointee.dts != Int64.min, isVideoPkt || isAudioPkt {
                    let tb = isVideoPkt ? sourceVideoTbSeconds : audioSourceTbSeconds
                    let cap = tb > 0 ? Int64(Self.maxSynthesizedStrideSeconds / tb) : 0
                    if isVideoPkt {
                        videoSourceStrideTicks = Self.updatedStrideTicks(
                            current: videoSourceStrideTicks, previousDts: lastGenuineVideoSourceDts,
                            dts: packet.pointee.dts, maxStrideTicks: cap)
                        lastGenuineVideoSourceDts = packet.pointee.dts
                    } else {
                        audioSourceStrideTicks = Self.updatedStrideTicks(
                            current: audioSourceStrideTicks, previousDts: lastGenuineAudioSourceDts,
                            dts: packet.pointee.dts, maxStrideTicks: cap)
                        lastGenuineAudioSourceDts = packet.pointee.dts
                    }
                }

                // AE#432: true when this packet reached the loop with no timestamp of its own, so
                // everything downstream that measures time is reading a value the engine invented.
                var timestampsSynthesized = false
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
                    } else if packet.pointee.pts != Int64.min {
                        // dts alone is missing (matroska reconstructs it from ReferenceBlock relations
                        // and fails on some B-frames). pts is the real presentation time and must not
                        // be crossed, so the bump stays minimal.
                        packet.pointee.dts = anchor &+ 1
                    } else {
                        // Neither timestamp survived. One tick per packet is not a presentation time,
                        // it is a frozen clock; advance by this stream's frame interval instead.
                        let stride = Self.repairStrideTicks(
                            packetDuration: packet.pointee.duration,
                            observedStride: isVideoPkt ? videoSourceStrideTicks : audioSourceStrideTicks,
                            fallbackDuration: isVideoPkt ? videoFallbackDurationPts : audioFallbackDurationPts)
                        packet.pointee.dts = anchor &+ stride
                        packet.pointee.pts = packet.pointee.dts
                        timestampsSynthesized = true
                        noteSynthesizedTimestamp(strideTicks: stride, isVideo: isVideoPkt)
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
                // Timeline rebase: a live program boundary (or, #368, a sequential-origin archive
                // chunk seam) resets source dts to a distant value. Per-frame monotonic gate would
                // bump to lastValid+1, exceed reset pts, and DROP every subsequent packet.
                // Correct repair: rebase OUTPUT dts to one frame past last output; live additionally
                // adds #EXT-X-DISCONTINUITY at the seam.
                if rebasesTimelineOnDiscontinuity, isVideoPkt, lastVideoSourceDts != Int64.min,
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
                        let (newShift, continuationDts) = Self.rebasedVideoShift(
                            srcDts: packet.pointee.dts,
                            lastSrcDts: lastVideoSourceDts,
                            oldShift: videoShiftPts,
                            fallbackDurationPts: videoFallbackDurationPts
                        )
                        EngineLog.emit(
                            "[HLSSegmentProducer] video timeline rebase (\(isLive ? "live" : "sequential")): "
                            + "jumpTicks=\(jumpTicks) srcDts=\(packet.pointee.dts) "
                            + "lastSrcDts=\(lastVideoSourceDts) oldShift=\(videoShiftPts) "
                            + "newShift=\(newShift) continuationDts=\(continuationDts)",
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
                        if isLive {
                            // Live consumers get #EXT-X-DISCONTINUITY plus a forced cut. A sequential
                            // chunk seam (#368) wants neither: the archive is content-continuous, the
                            // output timeline stays continuous after the rebase, and the append
                            // playlist's EXTINF comes from real muxed durations. (Both flags feed
                            // only the live segment bookkeeping.)
                            pendingDiscontinuityFlag = true
                            pendingForceCutFlag = true
                        }
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
                if rebasesTimelineOnDiscontinuity, isAudioPkt, lastAudioSourceDts != Int64.min,
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
                            "[HLSSegmentProducer] audio timeline rebase (\(isLive ? "live" : "sequential")): "
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
                    noCutWatchdog?.noteVideoPacket(
                        pts: packet.pointee.pts,
                        isKeyframe: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0,
                        synthesizedTimestamp: timestampsSynthesized
                    )
                    if firstSeenVideoSourceDts == Int64.min {
                        firstSeenVideoSourceDts = packet.pointee.dts
                    }
                    lastVideoSourceDts = packet.pointee.dts
                } else if isAudioPkt {
                    noCutWatchdog?.noteAudioPacket()
                    if firstSeenAudioSourceDts == Int64.min {
                        firstSeenAudioSourceDts = packet.pointee.dts
                    }
                    lastAudioSourceDts = packet.pointee.dts
                }

                if !isVideoPkt && !isAudioPkt {
                    noCutWatchdog?.noteForeignPacket(streamIndex: pktStreamIdx)
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
                            targetPts: effectiveGateTargetPts)
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
                            // AE#408: the scan has reached ground already known to carry no sync
                            // sample (the boundary itself on the first pass, the abandoned aim after
                            // that) on a packet that cannot open a segment, so nothing between the
                            // current aim and the boundary can cover it. Re-aim now rather than read
                            // the whole drought to find that out. The comparison is never against the
                            // current aim: an aim is a probe position and claims nothing, so a non-key
                            // packet sitting on one is not evidence.
                            if !isKey, sourceVideoTbSeconds > 0,
                               Self.boundaryProvenNotRandomAccess(
                                   droppedPts: packet.pointee.pts != Int64.min
                                       ? packet.pointee.pts : packet.pointee.dts,
                                   targetPts: gateProvenEmptyFromPts,
                                   sawKeyframeBeforeTarget: lastPregateDroppedKeyframePts != Int64.min,
                                   graceTicks: Int64(Self.boundaryProbeGraceSeconds / sourceVideoTbSeconds)),
                               reanchorGateBelowBoundary(reason: "no sync sample covers it") {
                                continue
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
                                    + "target=\(effectiveGateTargetPts)"
                                    + (effectiveGateTargetPts != restartTargetVideoPts
                                        ? " (re-aimed from boundary \(restartTargetVideoPts))" : "")
                                    + " baseIndex=\(baseIndex)",
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
                        // AE#408: this keyframe opens a segment whose playlist entry starts at the
                        // boundary. Opening it well past that makes the segment carry content from the
                        // far side of the gap under the boundary's own name, and every seek into it
                        // lands that far off. Go back for a sync sample that covers the start instead.
                        if sourceVideoTbSeconds > 0,
                           Self.shouldReanchorBeforeOpening(
                               keyframePts: packet.pointee.pts != Int64.min
                                   ? packet.pointee.pts : packet.pointee.dts,
                               boundaryPts: restartTargetVideoPts,
                               toleranceTicks: Self.boundaryOpenToleranceTicks(
                                   reorderFrames: videoConfig.codecpar.pointee.video_delay,
                                   frameDurationPts: videoFallbackDurationPts,
                                   floorTicks: Int64(Self.boundaryOpenToleranceSeconds / sourceVideoTbSeconds)),
                               attemptsUsed: gateBackoffAttempts,
                               maxAttempts: Self.gateBackoffStepsSeconds.count),
                           reanchorGateBelowBoundary(reason: "its first sync sample presents "
                               + "\(String(format: "%.2f", Double((packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts) &- restartTargetVideoPts) * sourceVideoTbSeconds))s later") {
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
                            stampLiveSegmentFinalize()
                        }
                        // AE#408: a re-aimed gate opens BELOW the segment's advertised start. Pinning
                        // that frame to the advertised start would relabel the whole item axis by the
                        // backoff, trading a late landing for an early one; keeping its own timestamp
                        // costs an overlap with the previous segment instead, which is the direction
                        // AVPlayer absorbs (a HOLE at the advertised start is what stalls it, and that
                        // is what the pin exists for when the gate opens late).
                        let pinnedTfdtPts = Self.pinnedFirstTfdtPts(
                            actualFirstDts: firstActualVideoDts,
                            desiredTfdtPts: desiredFirstVideoTfdtPts,
                            planAnchorPts: planAnchorVideoPts)
                        videoShiftPts = firstActualVideoDts - pinnedTfdtPts
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
                            + (effectiveGateTargetPts != restartTargetVideoPts
                                ? "reaimedTo=\(effectiveGateTargetPts) " : "")
                            + "desired=\(desiredFirstVideoTfdtPts) "
                            + (pinnedTfdtPts != desiredFirstVideoTfdtPts
                                ? "pinnedTo=\(pinnedTfdtPts) " : "")
                            + "shift=\(videoShiftPts) "
                            + (Self.presentedShiftPts(actualFirstPts: firstActualVideoPts,
                                                      desiredTfdtPts: desiredFirstVideoTfdtPts) != videoShiftPts
                                ? "presentedShift=\(Self.presentedShiftPts(actualFirstPts: firstActualVideoPts, desiredTfdtPts: desiredFirstVideoTfdtPts)) " : "")
                            // AE#418 round 5: the composition needs this, so the line that publishes
                            // the shift names it too. Zero on a source without frame reordering.
                            + (Self.presentationLeadPts(actualFirstPts: firstActualVideoPts,
                                                        actualFirstDts: firstActualVideoDts) != 0
                                ? "lead=\(Self.presentationLeadPts(actualFirstPts: firstActualVideoPts, actualFirstDts: firstActualVideoDts)) " : "")
                            // #133 follow-up diag: PID + reconstruct state per epoch, so retest logs separate a
                            // same-PID mid-stream parameter-set change from a reopen storm (each reopen is a fresh
                            // gate-open here; a same-PID change is NOT, it stays in one epoch and rotates in place).
                            + "videoPID=\(videoStreamIndex) reconstructed=\(pendingJoinVideoConfig != nil)",
                            category: .session
                        )
                        // AE#418: what the HOST folds is not the muxer's shift. Measured with
                        // `play --picture-probe` against a picture that states its own source time:
                        // AVPlayer presents a segment at the position the PLAYLIST gives it, not at
                        // the tfdt the segment carries, so a gate that opened below its boundary has
                        // its content presented that far late whatever it wrote. The muxer's shift
                        // stays what it is (it is the source-to-item offset for the bytes), and the
                        // axis the clock folds with is measured against the ADVERTISED start, which
                        // is where AVPlayer will put the frame. The two coincide on a pinned (late)
                        // gate, which is why publishing the mux shift held until the early-opening
                        // gate landed in 6.40.0. Same reason the seam activates at the advertised
                        // start: the stretch below it still belongs to the previous epoch on screen.
                        onVideoShiftKnown?(
                            Self.presentedShiftPts(
                                actualFirstPts: firstActualVideoPts,
                                desiredTfdtPts: desiredFirstVideoTfdtPts),
                            desiredFirstVideoTfdtPts,
                            videoShiftPts)
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
                           let elType = DoviRpuConverter.enhancementLayerType(
                               packet, framing: a53NALFraming) {
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
                        if !DoviRpuConverter.convertPacketToProfile81(
                            packet, framing: a53NALFraming) {
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
                    // #358: the VOD plan's boundaries are the mov/mp4 index's sync-sample timestamps,
                    // which are DECODE times, so the gate compares decode times too. Comparing the
                    // presentation time against them let a keyframe reach boundaries beyond its own
                    // by its composition offset (3 s on the field report's remux), consuming plan
                    // indices that then never opened a segment. Keyframe gating is unchanged, so
                    // #92 holds: the IRAP is still the segment's first sample and its RASL pictures
                    // still follow it in decode order.
                    let thisVideoSeg = isLive
                        ? liveVideoSegmentIndex(pts: packet.pointee.pts, isKeyframe: isVideoKeyframe)
                        : vodCutter.index(pts: packet.pointee.dts != Int64.min
                                               ? packet.pointee.dts : packet.pointee.pts,
                                          isKeyframe: isVideoKeyframe)
                    if thisVideoSeg != pumpQoSLastSeg {
                        pumpQoSLastSeg = thisVideoSeg
                        retunePumpQoS()
                    }
                    if let prev = pendingVideoPkt {
                        let prevSeg = pendingVideoSegIndex
                        // Newest muxed frame time, recorded per PACKET. Recording it at the ledger
                        // site below (which only fires when a segment opens) left it equal to the
                        // last segment's start, so the EOF tail EXTINF's "real span" branch could
                        // never be true and every archive's final segment was advertised at the
                        // full cut target no matter how little media it held.
                        if onSequentialSegmentFinalized != nil, prev.pointee.dts != Int64.min,
                           sourceVideoTbSeconds > 0 {
                            lastMuxedItemAxisSeconds = Double(prev.pointee.dts) * sourceVideoTbSeconds
                        }
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
                            if onSequentialSegmentFinalized != nil {
                                let startSec = Double(outDts) * sourceVideoTbSeconds
                                vodSegmentStartByIndex[prevSeg] = startSec
                                // The previous segment's REAL duration is final the moment this
                                // one's start is known; the report pairs with its capture. Plan
                                // indices a long GOP skipped report as zero-duration holes.
                                if lastSeqLedgerSeg != Int.min, lastSeqLedgerSeg < prevSeg,
                                   let priorStart = vodSegmentStartByIndex[lastSeqLedgerSeg],
                                   startSec > priorStart {
                                    vodSegmentStartByIndex.removeValue(forKey: lastSeqLedgerSeg)
                                    noteSequentialDurationKnown(index: lastSeqLedgerSeg,
                                                                duration: startSec - priorStart)
                                    for hole in (lastSeqLedgerSeg + 1)..<prevSeg {
                                        emitSequentialReport(index: hole, duration: 0)
                                    }
                                }
                                lastSeqLedgerSeg = prevSeg
                            }
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
                            // AE#412: a cold arrival can only start a decode run on a random-access
                            // point, so what a segment is worth to one is where its first sync sample
                            // sits. Recorded here, against the muxer's own index, because that is the
                            // segment these bytes are actually in.
                            if !isLive, (prev.pointee.flags & AV_PKT_FLAG_KEY) != 0 {
                                let openIdx = muxer.currentSegmentIndex
                                if firstSyncItemPtsBySegment[openIdx] == nil {
                                    firstSyncItemPtsBySegment[openIdx] =
                                        prev.pointee.dts != Int64.min ? prev.pointee.dts : prev.pointee.pts
                                }
                            }
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
                            let prime = copyAudioPrimeCandidate(fp)
                            if muxer.writePacket(fp).rc >= 0, let prime {
                                audioMoovPrimeFrame = prime
                            }
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

        // AE#406: the watchdog decides off this thread, so its verdict lands while the loop is
        // parked in a read that has no upper bound of its own. The abort that lets the loop observe
        // the verdict surfaces here as a read error, and `.readError` sends a reopenable source into
        // a URL reopen of the very origin that starved. The verdict is what the exit means.
        if noCutWatchdog?.hasLatchedExit == true {
            if case .stopRequested = exitReason {} else { exitReason = .segmentStall }
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

        // AE#222: a cut that deferred for want of a packet-derived audio sample entry is recoverable, but only
        // with one real audio frame in hand. Scan for it here, on the way out: the bytes this reads are the
        // same ones the rebuilt producer will re-read for its own first segments, and every alternative
        // (bridging to FLAC, stretching the first segment past its plan boundary) either downgrades the audio
        // or breaks the playlist. If no frame turns up, the reason stays .muxerFailed and the host's existing
        // fallbacks own the session.
        if case .muxerFailed = exitReason, cutDeferredAwaitingAudioSampleEntry {
            if let prime = scanForAudioMoovPrimeFrame() {
                stateLock.lock()
                _capturedAudioMoovPrimeFrame = prime
                stateLock.unlock()
                exitReason = .needsAudioSampleEntryPrime
            }
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
    /// #369: `capTicks` bounds the inferred delta (a sample longer than a discontinuity is
    /// definitionally invalid). Across a 33-bit PTS wrap the look-behind delta IS the wrap
    /// (device: 8226410192 ticks, ~91404 s; movenc rejects it as "Application provided duration
    /// ... is invalid" and the packet is lost), so an over-cap delta falls back like a
    /// non-forward one. The cap holds for the source's DECLARED duration too: movenc rejects the
    /// sample whatever produced its number, and a container that carries a wrap-scale duration
    /// (a corrupt DefaultDuration, a duration derived from the same wrapped clock) reaches the
    /// muxer through exactly this branch whenever there is no usable forward delta, which is the
    /// EOF tail of the very stream the cap exists for.
    static func resolveVideoSampleDuration(
        existingDuration: Int64,
        dts: Int64,
        nextDts: Int64?,
        fallback: Int64,
        capTicks: Int64
    ) -> Int64 {
        if let next = nextDts, dts != Int64.min, next != Int64.min {
            let inferred = next - dts
            if inferred > 0, inferred <= capTicks { return inferred }
        }
        return existingDuration > 0 && existingDuration <= capTicks ? existingDuration : fallback
    }

    /// #369: the sample-duration cap in source-video ticks (`discontinuityThresholdSeconds`, so
    /// live rebases and the duration cap share one definition of "discontinuity").
    private var videoSampleDurationCapTicks: Int64 {
        sourceVideoTbSeconds > 0
            ? Int64(Self.discontinuityThresholdSeconds / sourceVideoTbSeconds)
            : Int64.max
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
            fallback: videoFallbackDurationPts,
            capTicks: videoSampleDurationCapTicks
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
        // #259: the source time BASE, but no longer the source AXIS. The pump rebased this packet
        // onto the output axis long before it got here, so the shift is folded back: the tap's cues
        // are rendered against the source-PTS clock (as the c608 tap's and the SW path's are), and
        // the shift is recomputed per producer session, so leaving it in would displace every
        // caption by a different amount after each seek.
        if let kind = a53CodecKind, let observe = a53CaptionObserver,
           let data = packet.pointee.data, packet.pointee.pts != Int64.min {
            let size = Int(packet.pointee.size)
            if A53SEIParser.mayContainA53(data, size) {
                let extracted = A53SEIParser.triplets(in: data, size: size, codec: kind, framing: a53NALFraming)
                if !extracted.isEmpty {
                    observe(extracted,
                            Self.foldingShiftBack(packet.pointee.pts, shift: videoShiftPts),
                            Self.foldingShiftBack(packet.pointee.dts, shift: videoShiftPts),
                            sourceVideoTimeBase)
                }
            }
        }

        // #260: capture the source axis BEFORE the rescale (after it the packet carries muxer TB) and the
        // keyframe flag while the packet is still ours. The item axis comes back out of writePacket: the write
        // blanks the packet, so it cannot be read off it afterwards, and the sanitizer can move it.
        let frameObserver = nativeVideoFrameTimeObserverProvider?()
        let frameSourcePts = frameObserver == nil
            ? Int64.min
            : Self.foldingShiftBack(packet.pointee.pts, shift: videoShiftPts)
        let frameIsKeyframe = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
        let frameSegmentIndex = currentMuxerSegmentIndex

        av_packet_rescale_ts(packet, sourceVideoTimeBase, muxer.muxerVideoTimeBase)
        let write = muxer.writePacket(packet)
        if write.rc < 0, !loggedVideoWriteFailure {
            // #369: this rc used to be dropped on the floor; the field failure (movenc rejecting a
            // wrap-scale sample duration) was only findable through libav's own stderr line.
            loggedVideoWriteFailure = true
            EngineLog.emit(
                "[HLSSegmentProducer] #369 video packet write failed rc=\(write.rc) "
                + "dts=\(packet.pointee.dts) duration=\(packet.pointee.duration) (muxer TB; "
                + "first occurrence only)",
                category: .session
            )
        }
        let written = write.written

        if let frameObserver,
           let source = Self.cmTime(ticks: frameSourcePts, timeBase: sourceVideoTimeBase),
           let item = Self.cmTime(ticks: written.pts, timeBase: muxer.muxerVideoTimeBase) {
            frameObserver(
                NativeVideoFrameTime(
                    source: source,
                    item: item,
                    segmentIndex: frameSegmentIndex,
                    isKeyframe: frameIsKeyframe,
                    epoch: epoch
                )
            )
        }

        var pkt: UnsafeMutablePointer<AVPacket>? = packet
        trackedPacketFree(&pkt)
    }

    /// Ticks in `timeBase` as a `CMTime`. nil for NOPTS or a degenerate time base, so a consumer never
    /// receives a timestamp the engine could not actually resolve (#260).
    static func cmTime(ticks: Int64, timeBase: AVRational) -> CMTime? {
        guard ticks != Int64.min, timeBase.num > 0, timeBase.den > 0 else { return nil }
        return CMTime(value: CMTimeValue(ticks &* Int64(timeBase.num)), timescale: CMTimeScale(timeBase.den))
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

    /// Copies the payload of an audio packet about to be muxed, BEFORE the write: movenc consumes the
    /// packet's data reference, so afterwards there is nothing left to copy. The caller commits the copy
    /// into `audioMoovPrimeFrame` only when the write succeeded.
    private func copyAudioPrimeCandidate(_ packet: UnsafeMutablePointer<AVPacket>) -> [UInt8]? {
        guard capturesAudioPrimeFrames, let data = packet.pointee.data, packet.pointee.size > 0 else {
            return nil
        }
        return [UInt8](UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)))
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
        let prime = copyAudioPrimeCandidate(packet)
        if muxer.writePacket(packet).rc >= 0, let prime {
            audioMoovPrimeFrame = prime
        }

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

// MARK: - Live recording (AE#560)

extension HLSSegmentProducer: LiveRecordingHost {

    func recordingStreamDescriptors() -> [RecordingStreamDescriptor] {
        var out: [RecordingStreamDescriptor] = []

        let videoIndex = demuxer.videoStreamIndex
        if videoIndex >= 0, let stream = demuxer.stream(at: videoIndex) {
            out.append(RecordingStreamDescriptor(
                sourceStreamIndex: videoIndex,
                timeBaseNum: stream.pointee.time_base.num,
                timeBaseDen: stream.pointee.time_base.den,
                codecParameters: stream.pointee.codecpar,
                isVideo: true))
        }

        // The audio source is the SIDE demuxer when one is open (a packed audio rendition), and the
        // main demuxer otherwise. Reading the wrong one is how this feature would ship silent.
        let audioSource = sideAudioDemuxer ?? demuxer
        let audioIndex = audioSource.audioStreamIndex
        if audioIndex >= 0, let stream = audioSource.stream(at: audioIndex) {
            // A side demuxer numbers its streams independently, so it can hand back the same index
            // the main demuxer already used for video. The writer maps packets by source index, so
            // a collision would route audio into the video stream. Refuse instead.
            if audioIndex == videoIndex, sideAudioDemuxer != nil {
                EngineLog.emit(
                    "[HLSSegmentProducer] recording refused: the side audio demuxer reuses source "
                    + "stream index \(audioIndex), which the video stream already holds",
                    category: .session
                )
                return []
            }
            out.append(RecordingStreamDescriptor(
                sourceStreamIndex: audioIndex,
                timeBaseNum: stream.pointee.time_base.num,
                timeBaseDen: stream.pointee.time_base.den,
                codecParameters: stream.pointee.codecpar,
                isVideo: false))
        }
        return out
    }

    func setRecordingSink(_ sink: LiveRecordingSink?) {
        recordingSinkLock.lock()
        recordingSink = sink
        recordingSinkLock.unlock()
    }

    /// Pump thread. Non-blocking by the sink's contract.
    func tapForRecording(_ packet: UnsafeMutablePointer<AVPacket>) {
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
