import AVFoundation
import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Session that turns a remote video source (typically a Jellyfin
/// MKV) into a local HLS-fMP4 stream AVPlayer can play.
///
/// Architecture: a single libavformat `hls` muxer instance runs for
/// the duration of the session, fed by the engine's `Demuxer`. Custom
/// `s->io_open` / `s->io_close2` callbacks (see `HLSSegmentProducer`)
/// redirect every fragment write into a `SegmentCache`. The local HTTP
/// server hands AVPlayer fragments from that cache, blocking on a
/// condition variable when AVPlayer requests an index that hasn't been
/// muxed yet. This replaces the previous self-built per-fragment
/// muxer + lazy generator + manual PTS-shift compensation. The
/// libavformat HLS-fmp4 output is byte-identical to `ffmpeg -f hls
/// -hls_segment_type fmp4`, which is the reference Apple's HLS spec
/// is defined against; we no longer carry the burden of reproducing
/// it ourselves.
///
/// Phase A: video-only, strict-forward producer (no backward-scrub
/// teardown, no audio bridge). Audio + scrub-restart follow.
public final class HLSVideoEngine: @unchecked Sendable {

    // MARK: - Errors

    public enum HLSVideoEngineError: Error, CustomStringConvertible, LocalizedError {
        case openFailed(reason: String)
        case noVideoStream
        case unsupportedCodec(rawCodecID: UInt32)
        case zeroDuration
        case unsupportedDVProfile(profile: Int, compatID: Int)
        case muxerInit(underlying: Error)
        case alreadyStarted
        case notStarted

        public var description: String {
            switch self {
            case .openFailed(let r):     return "HLSVideoEngine: open failed (\(r))"
            case .noVideoStream:         return "HLSVideoEngine: source has no video stream"
            case .unsupportedCodec(let id): return "HLSVideoEngine: unsupported codec id \(id) (only HEVC and H.264 supported)"
            case .zeroDuration:          return "HLSVideoEngine: source has zero duration (cannot build segment plan)"
            case .unsupportedDVProfile(let p, let c): return "HLSVideoEngine: unsupported Dolby Vision profile \(p).\(c)"
            case .muxerInit(let e):      return "HLSVideoEngine: muxer init failed (\(e))"
            case .alreadyStarted:        return "HLSVideoEngine: session already started"
            case .notStarted:            return "HLSVideoEngine: session not started"
            }
        }

        public var errorDescription: String? { description }
    }

    /// DV profile + base-layer compatibility classification per the
    /// table in DrHurt's KSPlayer notes (AetherEngine#1), Apple's HLS
    /// Authoring Spec, and Dolby's ETSI TS 103 572. HEVC profiles
    /// 5 / 8 carry HEVC streams; profile 10 carries AV1 streams.
    fileprivate enum DVVariant {
        case none              // not DV
        case profile5          // HEVC P5  (IPT-PQ-c2, no base)     → dvh1 + PQ
        case profile81         // HEVC P8.1 with HDR10-compat base  → dvh1 + PQ  (on DV display)
        case profile84         // HEVC P8.4 with HLG-compat base    → hvc1 + HLG + SUPPLEMENTAL dvh1/db4h
        case profile7          // HEVC P7 dual-layer (BL = HDR10)   → hvc1 + PQ (BL only)
        case profile82         // HEVC P8.2 with SDR-compat base    → reject
        case av1Profile10      // AV1 P10.0 (no base)               → dav1 + PQ
        case av1Profile101     // AV1 P10.1 with HDR10-compat base  → dav1 + PQ
        case av1Profile104     // AV1 P10.4 with HLG-compat base    → av01 + HLG + SUPPLEMENTAL dav1
        case av1Profile102     // AV1 P10.2 with SDR-compat base    → reject
        case unknown           // anything else                     → reject
    }

    /// Source audio codec routed to either fMP4 stream-copy or the
    /// FLAC bridge. Stream-copy preserves Atmos / DTS-HD metadata
    /// (EAC3-JOC stays Atmos); the bridge decodes to S16 PCM and
    /// re-encodes losslessly as FLAC so AVPlayer plays codecs that
    /// aren't legal in fMP4. See `project_audio_rework` memory for
    /// the full trade-off matrix (TrueHD-MAT Atmos loses its object
    /// metadata on the FLAC re-encode; lossless 7.1 PCM survives).
    fileprivate enum AudioCodecCompat {
        // fMP4-legal: stream-copy, no decode.
        case aac, ac3, eac3, flac, alac, mp3, opus
        // Not legal in fMP4: bridge through `AudioBridge` (decode →
        // S16 PCM → FLAC encode).
        case truehd, dts
        case vorbis, pcm, mp2
        case unsupported

        static func from(_ codecID: AVCodecID) -> AudioCodecCompat {
            switch codecID {
            case AV_CODEC_ID_AAC:    return .aac
            case AV_CODEC_ID_AC3:    return .ac3
            case AV_CODEC_ID_EAC3:   return .eac3
            case AV_CODEC_ID_FLAC:   return .flac
            case AV_CODEC_ID_ALAC:   return .alac
            case AV_CODEC_ID_MP3:    return .mp3
            case AV_CODEC_ID_OPUS:   return .opus
            case AV_CODEC_ID_TRUEHD: return .truehd
            case AV_CODEC_ID_DTS:    return .dts
            case AV_CODEC_ID_VORBIS: return .vorbis
            case AV_CODEC_ID_MP2:    return .mp2
            case AV_CODEC_ID_PCM_S16LE,
                 AV_CODEC_ID_PCM_S24LE,
                 AV_CODEC_ID_PCM_F32LE,
                 AV_CODEC_ID_PCM_S16BE,
                 AV_CODEC_ID_PCM_S32LE,
                 AV_CODEC_ID_PCM_U8:
                return .pcm
            default: return .unsupported
            }
        }

        /// CODECS attribute string for the master playlist when this
        /// codec is stream-copied. Empty for codecs that always bridge
        /// (they show up as `fLaC` after the encode, computed by the
        /// engine rather than the enum).
        var hlsCodecsString: String {
            switch self {
            case .aac:    return "mp4a.40.2"
            case .ac3:    return "ac-3"
            case .eac3:   return "ec-3"
            case .flac:   return "fLaC"
            case .alac:   return "alac"
            case .mp3, .opus, .truehd, .dts, .vorbis, .pcm, .mp2, .unsupported:
                // mp3 is theoretically `mp4a.40.34`, but AVPlayer reads
                // any mp4a sample entry as AAC, so we bridge it to FLAC
                // instead, the engine then computes `fLaC` from the
                // bridged stream rather than reading this enum.
                return ""
            }
        }

        /// Codecs that aren't legal in fMP4 and always have to go
        /// through `AudioBridge` for FLAC transcoding.
        ///
        /// Opus is in this set despite being fMP4-spec-legal: AVPlayer
        /// rejects `opus` inside HLS-fMP4 in practice (only the CAF
        /// container path or WebM-with-VP9-video gets Opus direct-play
        /// on Apple platforms; HLS-fMP4 segments with Opus audio fail
        /// header validation downstream). Routing Opus pre-emptively
        /// through the FLAC bridge avoids a "stream-copy header write
        /// failed, retrying with FLAC bridge" round-trip on every
        /// Opus source.
        ///
        /// MP3 is in the same bucket for the same reason: the muxer
        /// happily writes `mp4a.40.34` (MP3-in-MP4 sample entry), but
        /// AVPlayer reads any `mp4a` entry as AAC and fails to decode
        /// the MP3 frames with -11829 / CoreMedia -12848. Bridge cost
        /// on a lossy mono/stereo source is negligible.
        var requiresBridge: Bool {
            switch self {
            case .opus, .mp3, .truehd, .dts, .vorbis, .pcm, .mp2: return true
            default: return false
            }
        }
    }

    // MARK: - State

    private let sourceURL: URL
    private let sourceHTTPHeaders: [String: String]
    private let dvModeAvailable: Bool

    /// Opt-in override from `LoadOptions.keepDvh1TagWithoutDV`.
    /// See LoadOptions for the full rationale — default OFF, set
    /// only for misreporting DV panels.
    private let keepDvh1TagWithoutDV: Bool

    /// Mirror of the user's tvOS Match Content master toggle at load
    /// time. One of two inputs to the master-vs-media-playlist routing
    /// decision (the other is `panelIsInHDRMode`). When `false`, the
    /// panel is user-locked to its current mode regardless of what the
    /// playlist advertises, so the engine treats it as "panel won't
    /// switch into HDR" when the panel is in SDR.
    private let matchContentEnabled: Bool

    /// Whether the connected display can present any HDR (HDR10, HLG,
    /// HDR10+, or DV). Sourced from `AVPlayer.eligibleForHDRPlayback`
    /// upstream. Used together with `matchContentEnabled` and
    /// `panelIsInHDRMode` to decide whether master-playlist routing is
    /// safe.
    private let displaySupportsHDR: Bool

    /// Whether the connected panel was already presenting in HDR at
    /// load time (EDR active, `UIScreen.main.currentEDRHeadroom > 1`).
    /// When `true`, master-playlist routing is safe regardless of
    /// `matchContentEnabled`: the panel already accepts HDR signaling
    /// and the master's `SUPPLEMENTAL-CODECS=dvh1` can upgrade an
    /// HDR10-locked panel to DV mode per DrHurt's empirical test in
    /// AetherEngine#4. When `false`, master is only safe if
    /// `displaySupportsHDR && matchContentEnabled` so AVKit can drive
    /// the panel-mode switch from SDR into HDR.
    private let panelIsInHDRMode: Bool

    /// `dvModeAvailable || keepDvh1TagWithoutDV`. The DV
    /// classification + codec-tag + master-playlist routing branches
    /// key off this single boolean.
    private var effectiveDvMode: Bool { dvModeAvailable || keepDvh1TagWithoutDV }

    /// Optional caller-chosen audio source stream index. When `nil` the
    /// engine falls back to `av_find_best_stream(AVMEDIA_TYPE_AUDIO)`,
    /// which picks whichever stream libavformat ranks highest (typically
    /// the container's default flag, then bitrate). When set, the start
    /// path uses this stream for the muxed audio output, enabling host
    /// driven mid-playback audio track switching via the
    /// `AetherEngine.selectAudioTrack(index:)` reload.
    private let audioSourceStreamIndexOverride: Int32?

    private var demuxer: Demuxer?
    private var cache: SegmentCache?
    private var producer: HLSSegmentProducer?
    private var server: HLSLocalServer?
    private var provider: VideoSegmentProvider?

    /// Captured at `start()` so the restart path can spin up a fresh
    /// producer at any segment index without re-running the full
    /// DV-classification / codec-pick logic.
    private var videoStreamIndex: Int32 = -1
    private var savedVideoConfig: HLSSegmentProducer.StreamConfig?
    private var savedAudioConfig: HLSSegmentProducer.AudioConfig?

    /// Per-frame fallback durations (in the respective source
    /// time_base) so the producer can backfill `pkt->duration` when
    /// the matroska demuxer doesn't supply per-block durations.
    /// Computed once at `start()` from `videoStream.avg_frame_rate`
    /// and `audioStream.codecpar` and carried across producer
    /// restarts so the scrub path doesn't have to recompute them.
    private var videoFallbackDurationPts: Int64 = 40
    private var audioFallbackDurationPts: Int64 = 0

    /// First video keyframe PTS (in source video TB), latched after
    /// the segment plan is built. Source `videoStream.start_time`
    /// is non-zero on MKV remuxes where the first usable IDR lives
    /// past PTS=0 (e.g. 5 ms on Lila Giraffe, 88 ms on Bombige
    /// Magenverstimmung). The producer subtracts this from every
    /// video packet's pts/dts so seg-0's fragment tfdt aligns with
    /// the playlist's cumulative-EXTINF origin of 0, AVPlayer's
    /// HLS-fMP4 engine stalls at `waitingToPlay` otherwise.
    private var firstKeyframePts: Int64 = 0

    /// `firstKeyframePts` converted to seconds using the source video
    /// time base. Retained for diagnostics; the actual AVPlayer-clock
    /// to source-PTS translation lives in `playlistShiftSeconds` below,
    /// which the producer updates dynamically on each gate open (the
    /// shift can differ from `firstKeyframeSeconds` on restart sessions
    /// when matroska seek imprecision lands past the planned target).
    public private(set) var firstKeyframeSeconds: Double = 0

    /// Human-readable description of the audio path that won the
    /// stream-copy → FLAC-bridge → video-only cascade for this session.
    /// Set inside `buildProducerWithAudioCascade` and read by the host
    /// for diagnostic surfaces. `nil` while no audio pipeline is live
    /// (source had no audio, or video-only fallback engaged).
    ///
    /// Possible values:
    /// - `"Stream-copy (EAC3+JOC Atmos)"`
    /// - `"Stream-copy (<CODEC>)"` for non-Atmos passthrough
    /// - `"FLAC bridge ← <CODEC>"` for codecs re-encoded into the fMP4
    public private(set) var audioPipelineDescription: String?

    /// `videoShiftPts` of the currently active producer, converted to
    /// seconds via the source video time base. Updated by the producer's
    /// `onVideoShiftKnown` callback on every gate open. AVPlayer's HLS
    /// clock sits at `source_pts - playlistShiftSeconds`; the subtitle
    /// path and side-demuxer seek read this to translate back to
    /// source time.
    public private(set) var playlistShiftSeconds: Double = 0

    /// Source video time base, latched in `start()` so the
    /// `onVideoShiftKnown` callback can convert producer PTS shift to
    /// seconds without having to thread the TB through the callback
    /// signature on every fire.
    private var sourceVideoTbSeconds: Double = 1.0 / 1000.0

    /// Fires when the active producer's `playlistShiftSeconds` changes
    /// (initial gate open or restart). AetherEngine wires this to keep
    /// its own published shift in step so the subtitle overlay's cue
    /// lookup uses the right source-time conversion.
    var onPlaylistShiftChanged: (@Sendable (Double) -> Void)?
    /// Session-long FLAC bridge for codecs that aren't legal in fMP4.
    /// Owned by the engine (not the producer) so that producer
    /// restarts on scrub don't lose the bridge's encoder state. The
    /// bridge's `startSegment()` is called before each restart so the
    /// FLAC encoder PTS rebases off the new demuxer cursor.
    private var audioBridge: AudioBridge?
    private var segmentPlan: [Segment] = []

    /// Serializes restart requests so multiple AVPlayer GETs racing
    /// the same scrub can't tear down and rebuild the producer in
    /// parallel.
    private let restartLock = NSLock()

    /// Fires once per session, the first time the producer sees an
    /// HDR10+ T.35 signature in a packet. Hooked by `AetherEngine` to
    /// upgrade the published `videoFormat` from `.hdr10` → `.hdr10Plus`.
    /// Debounced here so producer restarts on scrub don't re-fire.
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    private var hasReportedHDR10Plus = false
    private let hdr10PlusLock = NSLock()

    /// Approximate target segment duration in seconds. The hls muxer
    /// snaps cut points to keyframes at-or-after this threshold, so
    /// actual durations are this + GOP length variance. Apple's HLS
    /// Authoring Spec recommends 6 s as the target; we drop to 4 s
    /// here because initial playback latency is dominated by the
    /// time the producer takes to demux + mux the first segment
    /// before AVPlayer can begin playback (~370 ms at 6 s on a 24 fps
    /// 1440p source over LAN). 4 s halves that, stays comfortably
    /// inside the spec's 2-6 s acceptable range, and the slightly
    /// larger playlist footprint is negligible.
    private static let targetSegmentDuration: Double = 4.0

    public init(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        dvModeAvailable: Bool = true,
        displaySupportsHDR: Bool = true,
        keepDvh1TagWithoutDV: Bool = false,
        matchContentEnabled: Bool = true,
        panelIsInHDRMode: Bool = false,
        audioSourceStreamIndexOverride: Int32? = nil,
        initialPositionSeconds: Double? = nil,
        audioBridgeMode: AudioBridgeMode = .surroundCompat,
        preopenedDemuxer: Demuxer? = nil
    ) {
        self.sourceURL = url
        self.sourceHTTPHeaders = sourceHTTPHeaders
        self.dvModeAvailable = dvModeAvailable
        self.displaySupportsHDR = displaySupportsHDR
        self.keepDvh1TagWithoutDV = keepDvh1TagWithoutDV
        self.matchContentEnabled = matchContentEnabled
        self.panelIsInHDRMode = panelIsInHDRMode
        self.audioSourceStreamIndexOverride = audioSourceStreamIndexOverride
        self.initialPositionSeconds = initialPositionSeconds
        self.audioBridgeMode = audioBridgeMode
        self.preopenedDemuxer = preopenedDemuxer
    }

    /// Encoder choice for the audio bridge (used for source codecs that
    /// can't stream-copy into fMP4: TrueHD, DTS, DTS-HD MA, MP3, Opus,
    /// and EAC3-from-MKV-without-dec3-extradata).
    private let audioBridgeMode: AudioBridgeMode

    /// Optional Demuxer that the host already opened + ran
    /// `find_stream_info` on (typically `AetherEngine.load`'s probe
    /// Demuxer for the same URL). When non-nil, `start()` reuses this
    /// instance instead of opening a fresh one, halving the
    /// per-`load()` HTTP probe + `avformat_find_stream_info` work
    /// (~1-3 s on slow CDN). Consumed in `start()`: cleared from
    /// this property and assigned to `self.demuxer`. Unconsumed
    /// preopened demuxers (e.g. if `start()` is never called before
    /// `stop()`) are closed by `stop()` so the resource doesn't
    /// linger after the engine is torn down.
    private var preopenedDemuxer: Demuxer?

    /// Resume position used to seed the sliding-window playlist so its
    /// initial visible range covers the segment AVPlayer will seek to.
    /// Without this seed, a resume at e.g. 4368 s lands AVPlayer on a
    /// playlist that only lists segs 0-29, and the seek either fails
    /// outright or stalls waiting for the playlist to grow past 4368 s.
    private let initialPositionSeconds: Double?

    // MARK: - Public API

    public func start() throws -> URL {
        guard demuxer == nil else { throw HLSVideoEngineError.alreadyStarted }

        // 1. Open the source. If the caller pre-opened a Demuxer for
        //    this URL (typically `AetherEngine.load`'s probe Demuxer)
        //    reuse it — avformat_find_stream_info is already done,
        //    AVIO buffer is warm, the seek that follows for cue
        //    prewarm invalidates any stale read position. Saves
        //    ~1-3 s per load on slow CDN sources by not running
        //    open_input + find_stream_info twice.
        let dem: Demuxer
        if let preopened = preopenedDemuxer {
            dem = preopened
            preopenedDemuxer = nil
        } else {
            dem = Demuxer()
            do {
                try dem.open(url: sourceURL, extraHeaders: sourceHTTPHeaders)
            } catch {
                throw HLSVideoEngineError.openFailed(reason: "\(error)")
            }
        }
        demuxer = dem

        let videoIndex = dem.videoStreamIndex
        guard videoIndex >= 0, let videoStream = dem.stream(at: videoIndex) else {
            throw HLSVideoEngineError.noVideoStream
        }
        let codecpar = videoStream.pointee.codecpar!
        let isHEVC = codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
        let isH264 = codecpar.pointee.codec_id == AV_CODEC_ID_H264
        let isAV1 = codecpar.pointee.codec_id == AV_CODEC_ID_AV1

        // Accepted codecs: HEVC, H.264, AV1 (when AVPlayer can decode
        // it on the active platform).
        //
        // AV1 is gated on `VTCapabilityProbe.av1Available`, which
        // returns true on iOS 17+ / macOS 14+ (Apple ships dav1d via
        // VideoToolbox) and false on tvOS (no SW dav1d on tvOS, no HW
        // AV1 on any current Apple TV chip). When the gate says false
        // for AV1, `AetherEngine.load`'s dispatch routes the source
        // through `SoftwarePlaybackHost` instead of reaching this
        // engine, so the guard below never sees an AV1 source on
        // unsupported platforms.
        //
        // VP9 is explicitly NOT here: AVPlayer's HLS manifest parser
        // rejects the `vp09` CODECS attribute even though VideoToolbox
        // can HW-decode VP9 (empirically verified). `AetherEngine.load`
        // dispatches all VP9 sources to `SoftwarePlaybackHost`.
        let av1OK = isAV1 && VTCapabilityProbe.av1Available
        guard isHEVC || isH264 || av1OK else {
            throw HLSVideoEngineError.unsupportedCodec(rawCodecID: codecpar.pointee.codec_id.rawValue)
        }

        let videoTimeBase = videoStream.pointee.time_base
        if videoTimeBase.num > 0, videoTimeBase.den > 0 {
            sourceVideoTbSeconds = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        }
        let durationSeconds = dem.duration
        guard durationSeconds > 0 else {
            throw HLSVideoEngineError.zeroDuration
        }

        // 2. Prewarm the MKV cue table so libavformat's keyframe index
        //    is populated. avformat_seek_file's first invocation on an
        //    MKV source lazily parses the Cues element from the file
        //    tail, which fans out into one or two HTTP byte-range
        //    reads. Mid-duration target so the prewarm doesn't strand
        //    the demuxer cursor far from where playback starts.
        let prewarmStart = DispatchTime.now()
        dem.seek(to: durationSeconds * 0.5)
        let prewarmMs = Double(DispatchTime.now().uptimeNanoseconds - prewarmStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit("[HLSVideoEngine] cue prewarm: seek to \(String(format: "%.1f", durationSeconds * 0.5))s took \(String(format: "%.1f", prewarmMs))ms")

        // 3. Build the segment plan from real keyframes in the index,
        //    using the SAME cut algorithm libavformat's hls muxer uses
        //    internally (first keyframe at-or-after `(segIdx+1) * hls_time`
        //    absolute from start_pts). When the index doesn't have
        //    enough entries we fall back to a uniform stride; the
        //    muxer may then end up making a slightly different number
        //    of segments than we planned, but Phase A doesn't test
        //    that path and Phase B's restart machinery handles any
        //    drift at scrub time.
        let keyframes = dem.indexedKeyframes(streamIndex: videoIndex)
        let plan: [Segment]
        if keyframes.count >= 2 {
            plan = buildKeyframeSegmentPlan(
                keyframes: keyframes,
                videoTimeBase: videoTimeBase,
                sourceDurationSeconds: durationSeconds
            )
            let detectedFirstKeyframePts = keyframes.sorted().first ?? 0
            self.firstKeyframePts = detectedFirstKeyframePts
            let firstKeyframePts = detectedFirstKeyframePts
            let firstKeyframeSeconds = Double(firstKeyframePts) * Double(videoTimeBase.num) / Double(videoTimeBase.den)
            self.firstKeyframeSeconds = firstKeyframeSeconds
            let videoStreamStart = videoStream.pointee.start_time
            let formatStart = dem.formatStartTime
            EngineLog.emit(
                "[HLSVideoEngine] segment plan: keyframe-aligned, \(keyframes.count) IRAPs → \(plan.count) segments " +
                "[firstKeyframePts=\(firstKeyframePts) (\(String(format: "%.3f", firstKeyframeSeconds))s) " +
                "videoStream.start_time=\(videoStreamStart) format.start_time=\(formatStart)us " +
                "plan[0].startSeconds=\(String(format: "%.3f", plan.first?.startSeconds ?? -1))]",
                category: .session
            )
        } else {
            plan = buildUniformSegmentPlan(
                videoTimeBase: videoTimeBase,
                sourceDurationSeconds: durationSeconds
            )
            EngineLog.emit(
                "[HLSVideoEngine] segment plan: uniform stride fallback (\(keyframes.count) IRAPs in index, need >=2)",
                category: .session
            )
        }

        // 4. Classify the DV variant and pick the sample-entry codec
        //    tag + CODECS string. Per-profile policy:
        //
        //    - P5  → always `dvh1.05.<level>` + `dvcC` box, regardless
        //            of panel capability. AVPlayer's system DV decoder
        //            converts IPT-PQ-c2 to YCbCr and auto-tonemaps to
        //            the panel's actual mode. On non-DV panels the
        //            playlist routing below forces media (master with
        //            bare `dvh1.05` is rejected by tvOS 26's strict
        //            codec filter).
        //    - P8.1 → `dvh1.08.<level>` on DV-capable display, `hvc1.2
        //            .4.L<level>` downgrade on non-DV display (HDR10
        //            base layer plays as plain HEVC HDR10).
        //    - P8.4 → `hvc1.2.4.L<level>` + SUPPLEMENTAL `dvh1.08.<level>
        //            /db4h` on every panel; the cross-player-compat
        //            form because P8.4's base is HLG-HEVC.
        let codecTagOverride: String?
        let videoRange: HLSVideoRange
        let primaryCodecs: String
        let supplementalCodecs: String?
        let dvVariant: DVVariant
        // Default false; set true in the P7 branch below so the mp4
        // muxer drops the source's `dvcC` configuration record before
        // `avformat_write_header` writes the sample entry. Necessary
        // because P7's BL is routed as plain HEVC HDR10 (`hvc1`) and
        // VT's HEVC selection rejects `hvc1` + a P7 `dvcC` with
        // `kVTVideoDecoderUnsupportedDataFormatErr` (-12906).
        var stripDolbyVisionMetadata = false

        if isH264 {
            codecTagOverride = "avc1"
            videoRange = isHDRTransfer(codecpar) ? .pq : .sdr
            let profileIDC = Int(codecpar.pointee.profile)
            let levelIDC = Int(codecpar.pointee.level)
            let safeProfile = profileIDC > 0 ? profileIDC : 100  // High
            let safeLevel = levelIDC > 0 ? levelIDC : 40         // 4.0
            primaryCodecs = String(format: "avc1.%02X%02X%02X", safeProfile, 0, safeLevel)
            supplementalCodecs = nil
            dvVariant = .none
        } else if isAV1 {
            // AV1 path. When dvModeAvailable is false (device can't do
            // DV at all), we deliberately skip the DV side-data probe
            // so classify returns .none → plain AV1 codec string.
            // When dvModeAvailable is true and the source carries
            // Dolby Vision RPU, classify resolves to one of the
            // av1Profile10x variants and we emit the matching `dav1`
            // codec tag + Apple HLS Authoring Spec CODECS string.
            let dvRecord = effectiveDvMode ? doviConfigRecord(from: codecpar) : nil
            let resolvedVariant = classifyDVVariant(dvRecord, codecID: AV_CODEC_ID_AV1)
            dvVariant = resolvedVariant

            // AV1 codec-string fields (per Apple HLS Authoring Spec +
            // AV1 codec-string IETF draft):
            //
            //   av01.<profile>.<level><tier>.<bitDepth>.
            //        <monochrome>.<chromaSubX><chromaSubY><chromaPos>.
            //        <colorPrim>.<transfer>.<matrix>.<videoFullRange>
            //
            // Profile 0 (Main) is the dominant case in the wild —
            // higher profiles cover 4:2:2 / 4:4:4 / 12-bit which Apple
            // doesn't accept in HLS-fMP4 today, but dav1d decodes them
            // so we let the muxer try; FFmpeg writes the `av1C` box
            // automatically from the codecpar.
            let av1ProfileRaw = Int(codecpar.pointee.profile)
            let av1Profile = (av1ProfileRaw >= 0 && av1ProfileRaw <= 2) ? av1ProfileRaw : 0
            let av1LevelRaw = Int(codecpar.pointee.level)
            // FFmpeg's seq_level_idx encoding: 0..23 → AV1 levels 2.0..7.3.
            // Default to 8 (= level 4.0) when the source doesn't expose
            // a value, matching ~4K @ 30fps.
            let av1Level = (av1LevelRaw >= 0 && av1LevelRaw <= 23) ? av1LevelRaw : 8
            let bitDepthRaw = Int(codecpar.pointee.bits_per_raw_sample)
            let dvLevelRaw = Int(dvRecord?.dv_level ?? 0)
            let dvLevel = dvLevelRaw > 0 ? dvLevelRaw : 6
            let dvLevelStr = String(format: "%02d", dvLevel)

            switch resolvedVariant {
            case .av1Profile10:
                // P10.0: DV-only, no HDR10 / HLG base layer. AVPlayer
                // refuses the asset on non-DV displays per Apple's
                // spec for `dav1` track type. Same shape as HEVC P5.
                codecTagOverride = "dav1"
                videoRange = .pq
                primaryCodecs = "dav1.10.\(dvLevelStr)"
                supplementalCodecs = nil
            case .av1Profile101:
                // P10.1: HDR10-compat base layer. Same `dav1` codec
                // tag — the HDR10 fallback is implicit in the
                // bitstream and the decoder picks it up when DV isn't
                // available. Analogous to HEVC P8.1.
                codecTagOverride = "dav1"
                videoRange = .pq
                primaryCodecs = "dav1.10.\(dvLevelStr)"
                supplementalCodecs = nil
            case .av1Profile104:
                // P10.4: HLG-compat base. Plain `av01` codec tag so
                // non-DV hosts present the HLG base layer; DV signaled
                // via the supplemental codecs string. Analogous to
                // HEVC P8.4 ↔ hvc1.2.4.LXX.b0 + dvh1.08.LL/db4h.
                codecTagOverride = "av01"
                videoRange = .hlg
                let bd = bitDepthRaw > 0 ? bitDepthRaw : 10
                primaryCodecs = String(
                    format: "av01.%d.%02dM.%02d.0.111.09.18.09.0",
                    av1Profile, av1Level, bd
                )
                supplementalCodecs = "dav1.10.\(dvLevelStr)/db4h"
            case .av1Profile102:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: 10, compatID: 2)
            case .unknown:
                let p = Int(dvRecord?.dv_profile ?? 0)
                let c = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 0)
                throw HLSVideoEngineError.unsupportedDVProfile(profile: p, compatID: c)
            case .none:
                // Plain AV1, no DV. Pick color signaling per the
                // source's transfer characteristic so AVPlayer hands
                // the right colorspace to the display.
                codecTagOverride = "av01"
                let trc = codecpar.pointee.color_trc
                let cp: Int, tc: Int, mc: Int, bd: Int
                if trc == AVCOL_TRC_ARIB_STD_B67 {
                    videoRange = .hlg; cp = 9; tc = 18; mc = 9
                    bd = bitDepthRaw > 0 ? bitDepthRaw : 10
                } else if trc == AVCOL_TRC_SMPTE2084 {
                    videoRange = .pq; cp = 9; tc = 16; mc = 9
                    bd = bitDepthRaw > 0 ? bitDepthRaw : 10
                } else {
                    videoRange = .sdr; cp = 1; tc = 1; mc = 1
                    bd = bitDepthRaw > 0 ? bitDepthRaw : 8
                }
                primaryCodecs = String(
                    format: "av01.%d.%02dM.%02d.0.111.%02d.%02d.%02d.0",
                    av1Profile, av1Level, bd, cp, tc, mc
                )
                supplementalCodecs = nil
            // HEVC DV variants can't reach this switch (classifyDVVariant
            // is called with AV_CODEC_ID_AV1) but Swift's exhaustivity
            // check needs explicit handling.
            case .profile5, .profile81, .profile84, .profile7, .profile82:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: -1, compatID: -1)
            }
        } else {
            // HEVC path (DV or plain). Always classify the DV variant
            // so DV5 can emit a `dvh1` sample entry + `dvcC` box even
            // on a panel that won't engage DV mode at the HDMI
            // handshake. AVPlayer has a system-level DV decoder on
            // every tvOS 14+ device; it engages on the `dvh1` sample
            // entry regardless of panel state, converts the IPT-PQ-c2
            // elementary stream to a standard YCbCr colorspace, and
            // auto-tonemaps to whatever the panel can accept (HDR10 on
            // an HDR10-only TV, SDR on an SDR-locked panel). Without
            // the `dvh1` sample entry, the HEVC bitstream's IPT chroma
            // gets interpreted as YCbCr+BT.2020+PQ, producing the
            // green/purple cast DrHurt reported on AetherEngine#4
            // Build 160 + 163. Per DrHurt's #19 manual remux test,
            // `dvh1` sample entry + media playlist routing plays DV5
            // correctly on every panel mode. The routing branch below
            // forces media playlist for the DV5-on-non-DV-panel case.
            let dvRecord = doviConfigRecord(from: codecpar)
            dvVariant = classifyDVVariant(dvRecord, codecID: AV_CODEC_ID_HEVC)

            // Dump the raw DV side data fields so a remote tester can
            // photograph the diagnostic overlay and confirm what the
            // demuxer surfaced for this source. Three fields drive
            // every downstream routing decision: dv_profile (5/7/8),
            // dv_bl_signal_compatibility_id (0/1/4 for no-base / HDR10
            // / HLG), and dv_level (1-13, content frame-rate × HDR
            // overhead). Pair with the source codecpar color fields
            // so the AVPlayer-side color interpretation can be cross-
            // checked against what FFmpeg parsed from the HEVC VUI.
            if let r = dvRecord {
                let cp = Int(codecpar.pointee.color_primaries.rawValue)
                let trc = Int(codecpar.pointee.color_trc.rawValue)
                let csp = Int(codecpar.pointee.color_space.rawValue)
                EngineLog.emit(
                    "[HLSVideoEngine] DV source: profile=\(r.dv_profile) "
                    + "compat=\(r.dv_bl_signal_compatibility_id) "
                    + "level=\(r.dv_level) rpu=\(r.rpu_present_flag) "
                    + "el=\(r.el_present_flag) bl=\(r.bl_present_flag) "
                    + "color_primaries=\(cp) color_trc=\(trc) color_space=\(csp)",
                    category: .session
                )
            }

            let dvLevelRaw = Int(dvRecord?.dv_level ?? 0)
            let dvLevel = dvLevelRaw > 0 ? dvLevelRaw : 6
            let hevcLevelRaw = Int(codecpar.pointee.level)
            let hevcLevel = hevcLevelRaw > 0 ? hevcLevelRaw : 150
            let dvLevelStr = String(format: "%02d", dvLevel)

            switch dvVariant {
            case .profile5:
                // P5 has no HDR10 base layer (IPT-PQ-c2 elementary
                // stream only). `dvh1` sample entry + `dvcC` box is
                // the only legal packaging. Emitted regardless of
                // `effectiveDvMode` because AVPlayer's DV decoder
                // engages on the sample entry independent of panel
                // state and tonemaps internally; without `dvh1` the
                // IPT chroma is misinterpreted as YCbCr (green/purple
                // cast). Master playlist with bare `dvh1.05` CODECS
                // is rejected by tvOS 26's master-level codec filter
                // on non-DV panels (-11868), so the routing logic
                // forces media playlist when the panel can't engage
                // DV/HDR mode.
                codecTagOverride = "dvh1"
                videoRange = .pq
                primaryCodecs = "dvh1.05.\(dvLevelStr)"
                supplementalCodecs = nil
            case .profile81:
                // P8.1 (HDR10-compat base layer). `dvh1` on a DV-
                // capable display so AVKit reads the sample-entry
                // FourCC and asks the panel for DV; `hvc1` on a
                // non-DV display so AVPlayer plays the HDR10 base
                // layer as plain HEVC HDR10 (DrHurt #4 #7).
                if effectiveDvMode {
                    codecTagOverride = "dvh1"
                    primaryCodecs = "dvh1.08.\(dvLevelStr)"
                } else {
                    codecTagOverride = "hvc1"
                    primaryCodecs = "hvc1.2.4.L\(hevcLevel)"
                }
                videoRange = .pq
                supplementalCodecs = nil
            case .profile84:
                // P8.4 (HLG-compat base layer). Bare `dvh1` empirically
                // does NOT play on either an HDR-mode or SDR-locked
                // panel: HDR-mode fails AVPlayer asset open (DrHurt
                // #4 Build 160: "does NOT play at all"), SDR-locked
                // plays wrong colors. AVPlayer appears to reject the
                // dvh1 sample entry when the underlying transfer
                // characteristic is HLG.
                //
                // Workaround: emit `hvc1` sample-entry + `hvc1.2.4
                // .LXX` primary CODECS so AVPlayer treats the asset
                // as plain HEVC HLG (which it plays fine), then ride
                // the `SUPPLEMENTAL-CODECS=dvh1.08.LL/db4h` hint to
                // let DV-capable panels still upgrade to DV mode.
                // The "/db4h" brand identifier marks the supplemental
                // as DV with HLG base for the AVPlayer's profile
                // matching logic, per the Dolby Vision HLS spec.
                //
                // Cost: AVKit's auto-criteria reads the `hvc1` sample
                // entry and programs HLG criteria; the supplemental
                // hint is what triggers the DV upgrade once the
                // panel is in HDR. On a non-DV panel the supplemental
                // is ignored and HLG base plays as expected.
                codecTagOverride = "hvc1"
                videoRange = .hlg
                primaryCodecs = "hvc1.2.4.L\(hevcLevel)"
                supplementalCodecs = "dvh1.08.\(dvLevelStr)/db4h"
            case .profile7:
                // P7 dual-layer (UHD-BD remux territory). The bitstream
                // carries an HEVC Main10 base layer + an enhancement
                // layer + RPU; Apple has no system-level P7 decoder, so
                // the only legal path on tvOS is to play the base layer
                // as plain HEVC HDR10. AVPlayer's Main10 decoder ignores
                // NAL units with `nuh_layer_id != 0` per the HEVC spec
                // (Annex F multi-layer extension), which leaves just
                // the BL frames going through the video pipeline. The
                // EL NALs ride along in the fMP4 samples (modest
                // bandwidth cost on a local segment cache), the panel
                // sees HDR10 PQ, no DV mode is requested.
                //
                // `dv_bl_signal_compatibility_id` is typically 6 for P7
                // sources. The spec uses 6 as a P7-specific marker
                // rather than a formal HDR10 backwards-compat flag, but
                // the BL is always PQ HEVC Main10 by construction since
                // UHD-BD requires HDR10 backwards-compat. We don't read
                // compat here because all P7 routes the same way.
                codecTagOverride = "hvc1"
                videoRange = .pq
                primaryCodecs = "hvc1.2.4.L\(hevcLevel)"
                supplementalCodecs = nil
                stripDolbyVisionMetadata = true
            case .profile82:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: 8, compatID: 2)
            case .unknown:
                let p = Int(dvRecord?.dv_profile ?? 0)
                let c = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 0)
                throw HLSVideoEngineError.unsupportedDVProfile(profile: p, compatID: c)
            case .none:
                codecTagOverride = "hvc1"
                videoRange = isHDRTransfer(codecpar) ? .pq : .sdr
                primaryCodecs = "hvc1.2.4.L\(hevcLevel)"
                supplementalCodecs = nil
            // AV1 DV variants unreachable here (classify was called with
            // AV_CODEC_ID_HEVC) but exhaustivity needs them.
            case .av1Profile10, .av1Profile101, .av1Profile104, .av1Profile102:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: -1, compatID: -1)
            }
        }

        let resolution = (Int(codecpar.pointee.width), Int(codecpar.pointee.height))

        let avgFR = videoStream.pointee.avg_frame_rate
        let frameRate: Double? = (avgFR.den > 0 && avgFR.num > 0)
            ? Double(avgFR.num) / Double(avgFR.den)
            : nil
        let hdcpLevel: String? = (dvVariant != .none) ? "TYPE-1" : nil

        // 5. Position the demuxer at the file's first packet so the
        //    producer's pump starts from byte zero. The cue prewarm
        //    above moved the cursor mid-file; libavformat's index is
        //    populated now, this seek-to-0 is cheap.
        dem.seek(to: 0)

        // 6. Build the segment cache + producer. The producer's
        //    constructor calls avformat_write_header which opens the
        //    init.mp4 sink (no bytes yet) and primes the muxer for
        //    av_write_frame. Pump runs on a worker queue.
        let segmentCache = SegmentCache()
        self.cache = segmentCache

        let videoConfig = HLSSegmentProducer.StreamConfig(
            codecpar: codecpar,
            timeBase: videoTimeBase,
            codecTagOverride: codecTagOverride,
            stripDolbyVisionMetadata: stripDolbyVisionMetadata
        )
        self.videoStreamIndex = videoIndex
        self.savedVideoConfig = videoConfig
        self.segmentPlan = plan

        // Per-frame fallback duration in the source video time_base,
        // computed from `avg_frame_rate`. Handed to the producer so
        // it can backfill `pkt->duration` when the source MKV
        // doesn't supply per-block durations (HandBrake / web-rip
        // pipelines drop the TrackEntry `DefaultDuration`, so every
        // packet emerges with `duration == 0`). Without this the
        // mp4 sub-muxer writes `trun.last.duration = 0` and the
        // fragment ends one frame short of where the next fragment
        // starts → AVPlayer's HLS-fMP4 engine sees an unfillable
        // gap, parks on `WaitingToMinimizeStallsReason`, and never
        // queues seg-N+1.
        //
        // 25 fps in a 1/1000 source TB → fallback = 40 ticks (40 ms).
        // 23.976 fps (24000/1001) in 1/1000 → 41 ticks.
        let videoFallbackDuration: Int64 = {
            guard avgFR.num > 0 && avgFR.den > 0,
                  videoTimeBase.num > 0, videoTimeBase.den > 0 else {
                // Defensive default for the 25 fps / 1 ms case.
                return 40
            }
            let num = Int64(avgFR.den) * Int64(videoTimeBase.den)
            let den = Int64(avgFR.num) * Int64(videoTimeBase.num)
            return max(1, num / den)
        }()
        self.videoFallbackDurationPts = videoFallbackDuration

        // 6a. Pick the audio routing: stream-copy for codecs legal in
        //     fMP4, FLAC bridge for those that aren't, drop for the
        //     unsupported tail. The fallback cascade tries stream-copy
        //     first (the common case is `ec-3` for streaming UHD with
        //     Atmos JOC); if the muxer rejects the header (EAC3 from
        //     MKV without a parsed `dec3` extradata is the typical
        //     EINVAL), we retry with the FLAC bridge; if that also
        //     fails we ship video-only.
        //
        // Source selection: caller can override the auto-picked stream
        // (host-driven audio track switching). Override is validated
        // against the container; an invalid index logs and falls back
        // to libavformat's pick so a stale picker selection from a
        // previous title can't strand playback without audio.
        let autoAudioStreamIndex = dem.audioStreamIndex
        let audioStreamIndex: Int32
        if let override = audioSourceStreamIndexOverride {
            if Self.isAudioStream(demuxer: dem, index: override) {
                audioStreamIndex = override
                EngineLog.emit(
                    "[HLSVideoEngine] audio: override accepted, sourceStreamIndex=\(override) (auto would have picked \(autoAudioStreamIndex))",
                    category: .session
                )
            } else {
                EngineLog.emit(
                    "[HLSVideoEngine] audio: override sourceStreamIndex=\(override) invalid (not an audio stream), falling back to auto=\(autoAudioStreamIndex)",
                    category: .session
                )
                audioStreamIndex = autoAudioStreamIndex
            }
        } else {
            audioStreamIndex = autoAudioStreamIndex
        }
        var streamCopyAudio: HLSSegmentProducer.AudioConfig?
        var bridgePreferred = false
        var audioHLSCodecs: String?

        if audioStreamIndex >= 0, let audioStream = dem.stream(at: audioStreamIndex) {
            let codecID = audioStream.pointee.codecpar.pointee.codec_id
            let compat = AudioCodecCompat.from(codecID)
            if compat.requiresBridge {
                bridgePreferred = true
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec=\(compat) (bridge required) — decoding + FLAC re-encode",
                    category: .session
                )
            } else if compat != .unsupported {
                streamCopyAudio = HLSSegmentProducer.AudioConfig(
                    codecpar: audioStream.pointee.codecpar,
                    timeBase: audioStream.pointee.time_base,
                    sourceStreamIndex: audioStreamIndex,
                    inputTimeBase: audioStream.pointee.time_base,
                    sourceTimeBase: audioStream.pointee.time_base,
                    bridge: nil
                )
                // Compute the audio per-frame fallback duration in
                // the source audio time_base. Same need as
                // `videoFallbackDurationPts`: matroska demuxers that
                // drop block durations make every audio packet
                // arrive with `pkt->duration = 0`, and the mp4 sub-
                // muxer's last-sample-in-fragment lookup then writes
                // a zero-duration trailing entry. AC3 / EAC3 are
                // exactly 1536 samples per frame; AAC is 1024.
                let acp = audioStream.pointee.codecpar.pointee
                let sampleRate = Int64(acp.sample_rate)
                let frameSamples: Int64 = {
                    if acp.frame_size > 0 { return Int64(acp.frame_size) }
                    switch acp.codec_id {
                    case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3: return 1536
                    case AV_CODEC_ID_AAC: return 1024
                    case AV_CODEC_ID_MP3: return 1152
                    case AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC: return 4096
                    default: return 1024
                    }
                }()
                let audioTb = audioStream.pointee.time_base
                self.audioFallbackDurationPts = {
                    guard sampleRate > 0, audioTb.num > 0, audioTb.den > 0 else { return 1 }
                    let num = frameSamples * Int64(audioTb.den)
                    let den = sampleRate * Int64(audioTb.num)
                    return max(1, num / den)
                }()
                // Apple HLS Authoring Spec: EAC3 with JOC (Atmos via
                // DD+) should be advertised as `ec+3`, plain EAC3 5.1
                // / 7.1 as `ec-3`. Profile 30 is libavformat's JOC
                // marker on the source codecpar. Advertising plain
                // `ec-3` for a JOC track means the dec3 box says
                // Atmos but the playlist says plain DD+, which makes
                // AVPlayer's downstream routing logic inconsistent
                // (the field experiment was JOC playing fine on Sonos
                // even with `ec-3`, but matching the spec is the
                // correct posture for the cases where it matters).
                //
                // iOS exception: iOS AVPlayer strictly enforces
                // RFC 6381 codec strings and silently drops the
                // variant when the audio codec is anything other
                // than `ec-3` — `ec+3` makes `asset.load(tracks)`
                // return 0 and the item fails with `Cannot Open`
                // (`AVFoundationErrorDomain -11848` / underlying
                // `CoreMediaErrorDomain -15517`). JOC stays intact
                // because the dec3 box still carries the marker;
                // only the playlist string changes.
                let isJOC = compat == .eac3 && acp.profile == 30
                #if os(iOS)
                audioHLSCodecs = compat.hlsCodecsString
                #else
                audioHLSCodecs = isJOC ? "ec+3" : compat.hlsCodecsString
                #endif
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec=\(compat) → stream-copy as `\(audioHLSCodecs ?? "?")` "
                    + "\(isJOC ? "[JOC=Atmos] " : "")"
                    + "(fallback duration=\(audioFallbackDurationPts) in audioTb \(audioTb.num)/\(audioTb.den))",
                    category: .session
                )
            } else {
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec id=\(codecID.rawValue) unsupported, video-only",
                    category: .session
                )
            }
        }

        // 6b. Attempt the cascade. The bridge instance, if needed, is
        //     constructed up-front so it survives across restarts.
        let prod: HLSSegmentProducer
        prod = try buildProducerWithAudioCascade(
            preferBridge: bridgePreferred,
            streamCopyAudio: streamCopyAudio,
            sourceAudioStreamIndex: audioStreamIndex,
            sourceAudioStream: audioStreamIndex >= 0 ? dem.stream(at: audioStreamIndex) : nil,
            audioHLSCodecs: &audioHLSCodecs
        )
        self.producer = prod

        // 7. Wire the provider, the server, and serve the URL.
        let manifestCodecs = audioHLSCodecs.map { "\(primaryCodecs),\($0)" } ?? primaryCodecs
        // Convert resume position (if any) to a segment index so the
        // provider's sliding-window playlist starts with the resume
        // segment already visible.
        let initialIndex = Self.segmentIndex(forSeconds: initialPositionSeconds, plan: plan)
        let prov = VideoSegmentProvider(
            cache: segmentCache,
            segments: plan,
            codecsString: manifestCodecs,
            supplementalCodecs: supplementalCodecs,
            resolution: resolution,
            videoRange: videoRange,
            frameRate: frameRate,
            hdcpLevel: hdcpLevel,
            initialIndex: initialIndex,
            restartHandler: { [weak self] idx in
                self?.restartProducer(at: idx)
            }
        )
        self.provider = prov

        EngineLog.emit(
            "[HLSVideoEngine] prepared: codec=\(manifestCodecs)"
            + (supplementalCodecs.map { " supplemental=\($0)" } ?? "")
            + " resolution=\(resolution.0)x\(resolution.1) "
            + "fps=\(frameRate.map { String(format: "%.3f", $0) } ?? "nil") "
            + "range=\(videoRange.rawValue) DV=\(dvVariant) segments=\(plan.count) "
            + "duration=\(String(format: "%.1f", durationSeconds))s"
        )

        let srv = HLSLocalServer(provider: prov)
        try srv.start()
        self.server = srv

        // 8. Kick the pump. Producer is now writing init + segments
        //    into the cache as fast as the demuxer can feed packets;
        //    AVPlayer's HTTP fetches block on cache.fetch until the
        //    requested index lands.
        prod.start()

        // Pick the URL handed to AVPlayer.
        //
        // The decision is driven by the active panel's dynamic-range
        // state, not by the source's claim. Master-playlist routing
        // advertises `VIDEO-RANGE=PQ` (or HLG) and optionally
        // `SUPPLEMENTAL-CODECS=dvh1` upfront, which AVPlayer translates
        // into a panel-mode request the moment AVKit sees the manifest.
        // That request can succeed in three ways:
        //
        //   1. Panel is already in HDR (`panelIsInHDRMode == true`).
        //      No transition needed; HDR10 / HLG signaling lands on a
        //      panel that already accepts it. SUPPLEMENTAL-CODECS upgrades
        //      an HDR10 panel into DV mode per DrHurt's manual remux
        //      test in AetherEngine#4.
        //   2. Panel is in SDR, can do HDR (`displaySupportsHDR`), and
        //      `matchContentEnabled` is on. AVKit drives the panel
        //      transition out of SDR using its own criteria pipeline.
        //   3. Otherwise (SDR-only TV, or HDR-capable TV with Match
        //      Dynamic Range off): the panel won't transition, and a
        //      master playlist claiming HDR while the panel sits in SDR
        //      fails asset open with `Cannot Open` (-11848). Route via
        //      media playlist instead so AVPlayer sees no upfront HDR
        //      hint, opens as generic HEVC, and the display tone-maps
        //      the HDR bitstream to its locked mode.
        //
        // Source-side gate: only HDR or DV sources benefit from master
        // routing in the first place. SDR HEVC has nothing to advertise
        // and stays on the media playlist regardless of panel state.
        //
        // DV5 routing is panel-state sensitive:
        //   - DV panel in DV mode:       master (DV native)
        //   - DV panel SDR-locked:       media  (master rejected when panel
        //                                won't engage DV; AVPlayer tonemaps
        //                                via the segment's dvh1 sample entry)
        //   - Non-DV but HDR-ready panel: master (DrHurt #4 #63: AVPlayer
        //                                 tonemaps DV→HDR10 via the master
        //                                 CODECS hint, which is closer to
        //                                 source intent than tonemaping all
        //                                 the way down to SDR via media)
        //   - SDR-locked panel (no HDR
        //     mode reachable):           media (master with bare `dvh1.05`
        //                                CODECS is rejected by tvOS 26's
        //                                strict master-level codec filter
        //                                with -11868 on these panels)
        //
        // DV8.1 and DV8.4 on non-DV panels already downgrade their
        // CODECS string to `hvc1.*` in the HEVC dispatch above, so the
        // master-side codec filter accepts them and they fall through
        // to the standard sourceIsHDR && panelReadyForHDR check below.
        // Only DV5 keeps `dvh1.05` even on non-DV panels (its IPT-PQ-c2
        // elementary stream needs the DV decoder regardless), so only
        // DV5 needs the SDR-locked guard.
        let sourceIsHDR = videoRange != .sdr || effectiveDvMode
        let panelReadyForHDR = panelIsInHDRMode
            || (displaySupportsHDR && matchContentEnabled)
        let dv5OnSdrLockedNonDVPanel = dvVariant == .profile5
            && !effectiveDvMode
            && !panelReadyForHDR
        let useMasterPlaylist: Bool
        if dv5OnSdrLockedNonDVPanel {
            useMasterPlaylist = false
        } else {
            useMasterPlaylist = sourceIsHDR && panelReadyForHDR
        }
        let resolvedURL: URL? = useMasterPlaylist
            ? srv.playlistURL
            : srv.mediaPlaylistURL
        guard let url = resolvedURL else {
            stop()
            throw HLSVideoEngineError.openFailed(reason: "server URL not ready")
        }
        self.servingMasterPlaylist = useMasterPlaylist
        EngineLog.emit("[HLSVideoEngine] serving on \(url.absoluteString) (dvModeAvailable=\(dvModeAvailable) effectiveDvMode=\(effectiveDvMode) panelIsHDR=\(panelIsInHDRMode) displaySupportsHDR=\(displaySupportsHDR) matchContent=\(matchContentEnabled) sourceIsHDR=\(sourceIsHDR) useMaster=\(useMasterPlaylist) videoRange=\(videoRange) dvVariant=\(dvVariant))")
        return url
    }

    /// Resolved routing decision exposed for the host's AVPlayerItem
    /// configuration. `true` when `start()` chose the master playlist
    /// (HDR / DV signaling reaches AVPlayer); `false` for the media
    /// playlist auto-tonemap path. Read after `start()` returns;
    /// undefined before. Host wires this into AVPlayerItem flags that
    /// only make sense when AVPlayer can engage an HDR pipeline.
    public private(set) var servingMasterPlaylist: Bool = false

    // MARK: - Diagnostics

    /// Snapshot of internal pipeline counters for the engine memory
    /// probe. All fields are point-in-time reads; no locking across
    /// fields, so individual values may be from slightly different
    /// instants (acceptable for a 30 s probe).
    public struct DiagnosticStats {
        public let segmentCacheCount: Int
        public let segmentCacheBytes: Int
        public let producerPacketsWritten: Int
        public let avioBytesFetched: Int64
        public let audioFifoSamples: Int
        /// Bytes held in AudioBridge's growable PCM buffers (FIFO +
        /// swr delay). Zero if the bridge isn't active (stream-copy
        /// audio path or video-only). Linear growth across probe
        /// samples implicates the bridge as a leak source.
        public let audioBridgeFifoBytes: Int
        public let audioBridgeSwrBytes: Int
        public var audioBridgeTotalBytes: Int { audioBridgeFifoBytes + audioBridgeSwrBytes }
        /// Cumulative bytes the current MP4SegmentMuxer has emitted
        /// through its FragmentSplitter over its lifetime. Resets on
        /// muxer rebuild (currently never — the muxer is session-long).
        /// Used as the muxer-leak attribution baseline.
        public let muxerLifetimeFragmentBytes: Int
        public let muxerFragmentCuts: Int
        /// Accepted-not-yet-closed connections on the local HLS server.
        /// Steady (1-3) is normal AVPlayer keep-alive; rising count
        /// would point to a CFNetwork client leak.
        public let serverConnectionCount: Int
        /// Lifetime bytes the HLS server has sent over all responses
        /// (Data writeAll + sendfile combined). Should track
        /// `muxerLifetimeFragmentBytes` for the segment-serve path
        /// (modulo init.mp4 + playlist responses). Divergence flags a
        /// drop or duplicate.
        public let serverLifetimeBytesSent: Int
        /// Of `serverLifetimeBytesSent`, how many went via the
        /// `sendfile(2)` fast path (file → socket kernel-side, no
        /// Foundation `Data`). Used to verify the fast path is
        /// actually taken vs. silently falling back to the
        /// Data-allocation path on every fetch.
        public let serverSendfileBytesSent: Int
        /// `av_packet_alloc` count minus `av_packet_free` count from
        /// the `PacketBalanceTracker` covering all engine packet-
        /// handling paths (demuxer / bridge / producer / subtitle /
        /// SW host). Steady low single digits = balanced. Linear
        /// growth = a packet leak in one of our paths.
        public let packetsAlive: Int
        public let packetsTotalAllocs: Int
        /// Number of times the producer's `runPumpLoop` was entered for
        /// a restart session (restartTargetVideoDts != Int64.min). Each
        /// scrub or seek that triggers a producer restart increments this
        /// by one. Zero for non-restart (phase-A) sessions.
        public let producerRestartCount: Int
        /// Most recently measured open-audio-gate vs. open-video-gate
        /// gap in source-clock milliseconds. Matches the value logged
        /// at the gap-detection site. Zero until the first audio gate
        /// opens in a session.
        public let lastAVGapMs: Double
        /// Lifetime count of HTTP requests served by the loopback HLS
        /// server (one per `processRequest` call). Includes playlist,
        /// init-segment, and media-segment fetches.
        public let serverRequestCount: Int
    }

    /// Read the current pipeline counters. Returns zeros for any
    /// sub-system that hasn't been constructed yet (pre-start or
    /// post-stop).
    public func diagnosticStats() -> DiagnosticStats {
        let abLive = audioBridge?.liveBytes
        return DiagnosticStats(
            segmentCacheCount: cache?.count ?? 0,
            segmentCacheBytes: cache?.totalBytes ?? 0,
            producerPacketsWritten: producer?.packetsWrittenCount ?? 0,
            avioBytesFetched: demuxer?.avioBytesFetched ?? 0,
            audioFifoSamples: audioBridge?.fifoSampleCount ?? 0,
            audioBridgeFifoBytes: abLive?.fifoBytes ?? 0,
            audioBridgeSwrBytes: abLive?.swrDelayBytes ?? 0,
            muxerLifetimeFragmentBytes: producer?.muxerLifetimeFragmentBytes ?? 0,
            muxerFragmentCuts: producer?.muxerFragmentCuts ?? 0,
            serverConnectionCount: server?.activeConnectionCount ?? 0,
            serverLifetimeBytesSent: server?.lifetimeBytesSent ?? 0,
            serverSendfileBytesSent: server?.lifetimeSendfileBytes ?? 0,
            packetsAlive: PacketBalanceTracker.alive,
            packetsTotalAllocs: PacketBalanceTracker.totalAllocs,
            producerRestartCount: producer?.restartCount ?? 0,
            lastAVGapMs: producer?.lastAVGapMs ?? 0,
            serverRequestCount: server?.requestCount ?? 0
        )
    }

    /// Bump the sliding-window playlist so segments covering `seconds`
    /// are listed before AVPlayer issues the seek-driven segment fetch.
    /// Called by `AetherEngine.seek(to:)`. No-op if the position
    /// already falls inside the visible window or if the playlist has
    /// already transitioned to VOD-with-ENDLIST.
    public func extendVisibleWindow(toCoverSeconds seconds: Double) {
        guard let prov = provider else { return }
        let idx = Self.segmentIndex(forSeconds: seconds, plan: segmentPlan)
        prov.extendVisibleWindow(toCover: idx)
    }

    /// Locate the segment that contains a given source-time offset.
    /// Linear scan, fine for our 2k-segment scale on the engine's
    /// rare-event paths (load + seek). Returns 0 if `seconds` is nil
    /// or negative, last index if past the end.
    fileprivate static func segmentIndex(forSeconds seconds: Double?, plan: [Segment]) -> Int {
        guard let s = seconds, s > 0, !plan.isEmpty else { return 0 }
        for (i, seg) in plan.enumerated() {
            if s < seg.startSeconds + seg.durationSeconds {
                return i
            }
        }
        return plan.count - 1
    }

    public func stop() {
        // Snapshot every resource into locals under the lock so we can
        // (a) clear the instance state immediately and (b) hand the
        // resources to a detached cleanup task that doesn't capture
        // self. Per Delarkz's AetherEngine#10, SwiftUI releases its
        // @State engine reference on the main thread; without the
        // detach the dismiss path would freeze the host UI for up to
        // 3 seconds while the producer's pump (potentially parked
        // inside demuxer.readPacket waiting on an HTTP byte-range
        // read) finishes exiting.
        restartLock.lock()
        let p = producer
        producer = nil
        let s = server
        server = nil
        let c = cache
        cache = nil
        let ab = audioBridge
        audioBridge = nil
        let d = demuxer
        demuxer = nil
        // Pick up the preopened Demuxer if start() never consumed it
        // (e.g. an exception path before start()). Closing both d and
        // preopened is safe: when start() ran, preopened was set to
        // nil and only d holds the ref; when start() never ran, d is
        // nil and preopened holds it. Calling close on a nil is a
        // no-op; calling close twice is idempotent on Demuxer either
        // way.
        let preopened = preopenedDemuxer
        preopenedDemuxer = nil
        provider = nil
        savedVideoConfig = nil
        savedAudioConfig = nil
        segmentPlan = []
        restartLock.unlock()

        // Send the cancel signal synchronously so the pump starts
        // unwinding immediately. waitForFinish + the rest of the
        // resource teardown move to a detached task.
        p?.stop()

        // Detached cleanup. The closure captures the local resource
        // strong refs (not self), so they live as long as the cleanup
        // needs them. The producer waitForFinish has to come before
        // closing the demuxer / cache / server because the pump
        // accesses them by reference during the unwind; the closure
        // serialises that ordering off-thread.
        Task.detached {
            _ = p?.waitForFinish(timeout: 3.0)
            s?.stop()
            c?.close()
            ab?.close()
            d?.close()
            preopened?.close()
        }
    }

    deinit {
        stop()
    }

    // MARK: - Producer construction + restart

    /// Allocate and configure a new `HLSSegmentProducer` rooted at
    /// the given absolute segment index. Used both for the initial
    /// session bring-up (baseIndex=0) and for the backward / forward
    /// scrub restart path.
    private func makeProducer(baseIndex: Int) throws -> HLSSegmentProducer {
        guard let dem = demuxer, let cache = cache, let cfg = savedVideoConfig else {
            throw HLSVideoEngineError.notStarted
        }

        // Scan-forward + dynamic-shift wiring.
        //
        // Video scan target (for restart sessions): plan[N].startPts
        // in source video TB. The producer scans forward to the
        // first real `AV_PKT_FLAG_KEY` packet with dts ≥ this value,
        // which may land at a later IDR than the target when the
        // planned position is a non-IDR keyframe in libavformat's
        // wider index. Audio scan target is set DYNAMICALLY by the
        // producer once video lands (so audio and video first
        // samples come from the same source-time).
        //
        // Desired first tfdt (the value the muxer's fragment tfdt
        // ends up at after the dynamic shift applies): for
        // baseIndex == 0 this is 0 (playlist origin); for restart
        // sessions it's plan[N].startSeconds in source TB =
        // plan[N].startPts - firstKeyframePts. The producer computes
        // shift = actualFirstDts - desiredFirstTfdt on the first
        // kept packet per stream and applies it to all subsequent
        // packets, giving aligned tfdts on both streams without
        // relying on the demuxer hitting the plan exactly.
        let videoTarget: Int64
        let desiredVideoTfdt: Int64
        let desiredAudioTfdt: Int64
        if baseIndex > 0, baseIndex < segmentPlan.count {
            videoTarget = segmentPlan[baseIndex].startPts
            desiredVideoTfdt = segmentPlan[baseIndex].startPts - firstKeyframePts
            // Rescale into the source audio TB (not the bridge encoder
            // input TB). The producer subtracts this value from the
            // first kept audio packet's dts to compute audioShiftPts,
            // and that dts is ALWAYS in source audio TB. Pre-fix the
            // rescale targeted bridge.inputTimeBase (1/48000), so for
            // FLAC-bridged DTS sources the resulting shift was off by
            // a factor of 48 and the log line showed
            // `shift=-152485195` garbage. Stream-copy was unaffected
            // since sourceTimeBase == inputTimeBase there; the bug was
            // bridge-only and silent (bridge.feed re-stamps PTS
            // independently via nextEncoderPTS so the shift's effect
            // on output PTS is null, but the gate-target side of the
            // calculation was inconsistent).
            desiredAudioTfdt = savedAudioConfig.map {
                av_rescale_q(desiredVideoTfdt, cfg.timeBase, $0.sourceTimeBase)
            } ?? 0
        } else {
            videoTarget = Int64.min
            desiredVideoTfdt = 0
            desiredAudioTfdt = 0
        }

        // Build the producer's segment-boundary slice. Each entry is
        // the startPts of one segment in source video TB; the last
        // entry is the endPts of the final segment so the producer
        // has a known upper bound for its segmentIndex() lookup. The
        // producer indexes this slice with `i = absoluteSegIdx - baseIndex`.
        let plannedSegs = segmentPlan[baseIndex..<segmentPlan.count]
        var segmentBoundaries: [Int64] = plannedSegs.map { $0.startPts }
        if let last = plannedSegs.last {
            segmentBoundaries.append(last.endPts)
        }

        let prod = try HLSSegmentProducer(
            demuxer: dem,
            videoStreamIndex: videoStreamIndex,
            video: cfg,
            audio: savedAudioConfig,
            cache: cache,
            baseIndex: baseIndex,
            targetSegmentDurationSeconds: Self.targetSegmentDuration,
            videoFallbackDurationPts: videoFallbackDurationPts,
            audioFallbackDurationPts: audioFallbackDurationPts,
            restartTargetVideoDts: videoTarget,
            desiredFirstVideoTfdtPts: desiredVideoTfdt,
            desiredFirstAudioTfdtPts: desiredAudioTfdt,
            segmentBoundaries: segmentBoundaries
        )
        prod.onFirstHDR10PlusDetected = { [weak self] in
            self?.notifyHDR10PlusOnce()
        }
        prod.onVideoShiftKnown = { [weak self] shiftPts in
            self?.handleVideoShiftKnown(shiftPts)
        }
        return prod
    }

    /// Converts the producer's `videoShiftPts` (in source video TB)
    /// to seconds and notifies the engine + AetherEngine that the
    /// AVPlayer-clock-to-source-PTS translation may have changed.
    /// Fires on initial start (shift ≈ firstKeyframeSeconds) and on
    /// every restart (shift can be larger when matroska seek
    /// imprecision lands past the planned target).
    private func handleVideoShiftKnown(_ shiftPts: Int64) {
        let seconds = shiftPts == Int64.min ? 0 : Double(shiftPts) * sourceVideoTbSeconds
        playlistShiftSeconds = seconds
        onPlaylistShiftChanged?(seconds)
    }

    /// Debounced relay. Producers each have their own once-per-instance
    /// scan latch; this guards against re-firing after a scrub restart
    /// (which builds a fresh producer that re-scans from packet zero).
    private func notifyHDR10PlusOnce() {
        hdr10PlusLock.lock()
        let alreadyFired = hasReportedHDR10Plus
        hasReportedHDR10Plus = true
        hdr10PlusLock.unlock()
        if !alreadyFired {
            onFirstHDR10PlusDetected?()
        }
    }

    /// Try the stream-copy → FLAC-bridge → video-only cascade for the
    /// initial producer construction. Inspired by the equivalent
    /// cascade the old per-fragment FMP4VideoMuxer ran during init
    /// capture; the failure mode it covers is the EAC3-from-MKV case
    /// where the source codecpar lacks the `dec3` extradata the mp4
    /// muxer needs to write the audio track's sample-entry. The same
    /// bytes that fed AVPlayer through stream-copy under the old
    /// architecture now fail header write here too — the fix on both
    /// sides is the same FLAC bridge fallback.
    private func buildProducerWithAudioCascade(
        preferBridge: Bool,
        streamCopyAudio: HLSSegmentProducer.AudioConfig?,
        sourceAudioStreamIndex: Int32,
        sourceAudioStream: UnsafeMutablePointer<AVStream>?,
        audioHLSCodecs: inout String?
    ) throws -> HLSSegmentProducer {
        // Detect if the source is EAC3+JOC Atmos so we can flag any
        // stream-copy → FLAC-bridge fallback as an Atmos downgrade.
        // EAC3 profile=30 is the JOC marker libavformat's demuxer sets
        // on Atmos streams. If this fallback ever fires the user is
        // silently getting lossless bed-channel FLAC instead of Atmos
        // (object metadata is lost in the PCM intermediate), so we
        // want this loud in the log so it surfaces before someone
        // notices their AVR's Atmos indicator stayed off.
        let sourceIsAtmos: Bool = {
            guard let stream = sourceAudioStream else { return false }
            return stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_EAC3
                && stream.pointee.codecpar.pointee.profile == 30
        }()

        // If the source already needs the bridge (TrueHD / DTS / Vorbis
        // / PCM / MP2), skip the stream-copy attempt — we know the
        // muxer won't accept those codecs in fMP4 anyway.
        // Source-codec label used for diagnostic strings if the cascade
        // makes a decision worth surfacing. Falls back to "audio" so
        // that a missing codec entry in libavcodec (extremely rare,
        // mostly out-of-band-extension exotica) doesn't produce
        // "Stream-copy (nil)" in the UI.
        let sourceCodecLabel: String = {
            if let stream = sourceAudioStream,
               let cstr = avcodec_get_name(stream.pointee.codecpar.pointee.codec_id) {
                return String(cString: cstr).uppercased()
            }
            return "audio"
        }()

        if !preferBridge, let cfg = streamCopyAudio, let vcfg = savedVideoConfig {
            // Pre-flight the mp4 muxer's write_header to detect cases
            // the cascade would otherwise miss. makeProducer no longer
            // exercises avformat_write_header itself — the first muxer
            // alloc happens lazily inside the producer's pump on the
            // first keep-packet, well after this scope has returned.
            // Without the probe a failure there (typical case:
            // EAC3-from-MKV whose CodecPrivate lacks the dec3 extradata
            // the mov muxer needs to write the audio track's
            // sample-entry, returns -22 / "Cannot write moov atom
            // before EAC3 packets parsed") leaves the producer stuck
            // and the bridge fallback below never fires.
            let probeVideo = MP4SegmentMuxer.VideoConfig(
                codecpar: vcfg.codecpar,
                timeBase: vcfg.timeBase,
                codecTagOverride: vcfg.codecTagOverride,
                stripDolbyVisionMetadata: vcfg.stripDolbyVisionMetadata
            )
            let probeAudio = MP4SegmentMuxer.AudioConfig(
                codecpar: cfg.codecpar,
                timeBase: cfg.timeBase
            )
            let probeRet = MP4SegmentMuxer.probeWriteHeader(
                video: probeVideo,
                audio: probeAudio
            )
            if probeRet < 0 {
                if sourceIsAtmos {
                    EngineLog.emit(
                        "[HLSVideoEngine] WARNING: Atmos downgrade — EAC3+JOC stream-copy probe rejected by mp4 muxer (ret=\(probeRet)). "
                        + "Falling back to FLAC bridge: bed channels stay lossless, but object metadata is lost. "
                        + "Source: \(sourceAudioStream?.pointee.codecpar.pointee.profile.description ?? "?") profile, "
                        + "channels=\(sourceAudioStream?.pointee.codecpar.pointee.ch_layout.nb_channels ?? -1). "
                        + "If you see this in production, capture the source MKV — dec3 extradata reconstruction can recover Atmos.",
                        category: .session
                    )
                } else {
                    EngineLog.emit(
                        "[HLSVideoEngine] audio stream-copy probe failed (ret=\(probeRet)), retrying with FLAC bridge",
                        category: .session
                    )
                }
                // Fall through to bridge attempt.
            } else {
                self.savedAudioConfig = cfg
                do {
                    let prod = try makeProducer(baseIndex: 0)
                    if sourceIsAtmos {
                        EngineLog.emit(
                            "[HLSVideoEngine] EAC3+JOC Atmos: stream-copy engaged, MAT 2.0 passthrough intact",
                            category: .session
                        )
                    }
                    self.audioPipelineDescription = sourceIsAtmos
                        ? "Stream-copy (EAC3+JOC Atmos)"
                        : "Stream-copy (\(sourceCodecLabel))"
                    return prod
                } catch {
                    EngineLog.emit(
                        "[HLSVideoEngine] makeProducer failed after stream-copy probe succeeded (\(error)), retrying with FLAC bridge",
                        category: .session
                    )
                    // Fall through to bridge attempt.
                }
            }
        } else if preferBridge && sourceIsAtmos {
            // Caller pre-decided bridge before reaching here. For Atmos
            // that's wrong — only legacy / non-fMP4-legal codecs should
            // pre-bridge. Diagnose this explicitly so a future codec-
            // table mistake doesn't silently degrade Atmos.
            EngineLog.emit(
                "[HLSVideoEngine] WARNING: Atmos source pre-routed to FLAC bridge without stream-copy attempt — Atmos lost. Investigate the codec compatibility table.",
                category: .session
            )
        }

        // FLAC bridge attempt. Requires a source audio stream.
        if let audioStream = sourceAudioStream, sourceAudioStreamIndex >= 0 {
            do {
                let bridge = try AudioBridge(
                    srcCodecpar: audioStream.pointee.codecpar,
                    srcTimeBase: audioStream.pointee.time_base,
                    mode: audioBridgeMode
                )
                if let cp = bridge.encoderCodecpar {
                    let cfg = HLSSegmentProducer.AudioConfig(
                        codecpar: cp,
                        timeBase: bridge.encoderTimeBase,
                        sourceStreamIndex: sourceAudioStreamIndex,
                        inputTimeBase: bridge.encoderTimeBase,
                        sourceTimeBase: audioStream.pointee.time_base,
                        bridge: bridge
                    )
                    self.savedAudioConfig = cfg
                    self.audioBridge = bridge
                    do {
                        let prod = try makeProducer(baseIndex: 0)
                        let (hlsCodec, pipelineLabel): (String, String)
                        switch audioBridgeMode {
                        case .surroundCompat:
                            hlsCodec = "ec-3"
                            pipelineLabel = "EAC3 5.1 bridge ← \(sourceCodecLabel)"
                        case .lossless:
                            hlsCodec = "fLaC"
                            pipelineLabel = "FLAC bridge ← \(sourceCodecLabel)"
                        }
                        audioHLSCodecs = hlsCodec
                        self.audioPipelineDescription = pipelineLabel
                        return prod
                    } catch {
                        EngineLog.emit(
                            "[HLSVideoEngine] \(audioBridgeMode.rawValue) bridge header write failed (\(error)), falling back to video-only",
                            category: .session
                        )
                        self.savedAudioConfig = nil
                        self.audioBridge = nil
                        bridge.close()
                    }
                }
            } catch {
                EngineLog.emit(
                    "[HLSVideoEngine] AudioBridge init failed (\(error)), falling back to video-only",
                    category: .session
                )
            }
        }

        // Video-only fallback.
        self.savedAudioConfig = nil
        self.audioBridge = nil
        audioHLSCodecs = nil
        self.audioPipelineDescription = nil
        return try makeProducer(baseIndex: 0)
    }

    /// Tear down the current producer, seek the demuxer to the start
    /// of segment `idx`, and spin up a fresh producer with
    /// `baseIndex = idx`. Triggered by `VideoSegmentProvider` when
    /// AVPlayer requests a segment that's outside the current LRU's
    /// reach in either direction.
    ///
    /// The same `init.mp4` bytes are reproduced across restarts
    /// because the muxer's stream configuration is byte-deterministic
    /// for a fixed `StreamConfig`. AVPlayer cached the init segment
    /// from the original session bring-up and never re-fetches it, so
    /// the cache.setInit overwrite during restart is a no-op from
    /// AVPlayer's perspective.
    private func restartProducer(at idx: Int) {
        restartLock.lock()
        defer { restartLock.unlock() }

        guard idx >= 0, idx < segmentPlan.count, demuxer != nil else { return }

        let restartStart = DispatchTime.now()

        if let old = producer {
            old.stop()
            let ok = old.waitForFinish(timeout: 5.0)
            if !ok {
                EngineLog.emit(
                    "[HLSVideoEngine] restart at idx=\(idx): old producer didn't exit within 5s, abandoning it",
                    category: .session
                )
            }
        }
        producer = nil

        // Seek the demuxer to the ABSOLUTE source-PTS of the target
        // segment's first keyframe, not to the relative playlist time.
        // segmentPlan[N].startSeconds is relative to startPts0 (the
        // first video keyframe's PTS). If startPts0 != 0 (common when
        // a source has B-frames buffered at the head or has been
        // re-muxed with a non-zero start), seeking with the relative
        // value lands a-keyframe-or-more behind the intended one
        // (av_seek_frame's AVSEEK_FLAG_BACKWARD rolls back from the
        // target, and sorted[N] > target-in-relative-source-time when
        // startPts0 > 0). The muxer then emits seg-N with content
        // starting at sorted[N-1]'s source time, AVPlayer's playlist
        // clock advances per EXTINFs (which are correct as keyframe
        // diffs), and embedded subtitle cue.startTime stays in
        // absolute source-PTS. Net effect: subtitles appear up to one
        // segment duration AHEAD of the corresponding audio.
        let absoluteTargetPts = segmentPlan[idx].startPts
        let videoTb = savedVideoConfig?.timeBase ?? AVRational(num: 1, den: 1000)
        let absoluteTargetSeconds = Double(absoluteTargetPts) * Double(videoTb.num) / Double(videoTb.den)
        demuxer?.seek(to: absoluteTargetSeconds)
        // Re-arm the FLAC bridge's PTS rebase off the new demuxer
        // cursor. Without this, the bridge's encoder timeline keeps
        // climbing from where the old producer left off, drifting
        // out of alignment with the freshly-seeked video PTS.
        audioBridge?.startSegment()

        do {
            let newProd = try makeProducer(baseIndex: idx)
            producer = newProd
            newProd.start()
        } catch {
            EngineLog.emit(
                "[HLSVideoEngine] restart at idx=\(idx) failed: \(error)",
                category: .session
            )
            return
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - restartStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit(
            "[HLSVideoEngine] producer restarted at idx=\(idx) (seek=\(String(format: "%.2f", absoluteTargetSeconds))s [absolute source-PTS], restart took \(String(format: "%.0f", elapsedMs))ms)",
            category: .session
        )
    }

    // MARK: - Segment planning

    /// Build a uniform-duration segment plan from the source's
    /// reported duration. Used only as a fallback when libavformat's
    /// keyframe index is too sparse for the keyframe-aligned plan.
    /// The hls muxer will still snap actual cut points to real
    /// keyframes, so EXTINF / actual-duration drift accumulates with
    /// each segment in this fallback path. Phase B's restart machinery
    /// renegotiates timeline alignment after scrubs, so the drift
    /// stays bounded within one playback span.
    private func buildUniformSegmentPlan(
        videoTimeBase: AVRational,
        sourceDurationSeconds: Double
    ) -> [Segment] {
        guard sourceDurationSeconds > 0 else { return [] }
        let stride = Self.targetSegmentDuration
        let count = max(1, Int(ceil(sourceDurationSeconds / stride)))
        let tb = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        guard tb > 0 else { return [] }

        var plan: [Segment] = []
        plan.reserveCapacity(count)
        for i in 0..<count {
            let startSeconds = Double(i) * stride
            let endSeconds = min(sourceDurationSeconds, Double(i + 1) * stride)
            let startPts = Int64(startSeconds / tb)
            let endPts = Int64(endSeconds / tb)
            plan.append(Segment(
                startPts: startPts,
                endPts: endPts,
                startSeconds: startSeconds,
                durationSeconds: max(0.001, endSeconds - startSeconds)
            ))
        }
        return plan
    }

    /// Build a segment plan from real keyframes using libavformat's
    /// hls muxer cut algorithm: segment N ends at the first keyframe
    /// whose absolute distance from `start_pts` reaches `(N+1) *
    /// targetSegmentDuration`. `start_pts` is taken as the first
    /// keyframe in the index (sorted ascending), which matches the
    /// muxer's behaviour of latching `vs->start_pts` to the first
    /// packet's pts.
    ///
    /// This algorithm replaces the previous one which walked the
    /// keyframe list with a relative threshold per segment. The
    /// relative walk diverged from libavformat's cut algorithm on
    /// sources with irregular GOPs (e.g. keyframes at 0, 5.8, 11.5,
    /// 17.4, 23.3 produce 3 segments under absolute thresholds but
    /// only 2 under the relative walk), which would translate into
    /// playlist drift the moment the muxer actually cut differently
    /// from what we'd advertised.
    private func buildKeyframeSegmentPlan(
        keyframes: [Int64],
        videoTimeBase: AVRational,
        sourceDurationSeconds: Double
    ) -> [Segment] {
        guard keyframes.count >= 2 else { return [] }
        let tb = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        guard tb > 0 else { return [] }
        let target = Self.targetSegmentDuration

        let sorted = keyframes.sorted()
        let startPts0 = sorted[0]

        var plan: [Segment] = []
        plan.reserveCapacity(sorted.count)
        var i = 0
        var segIdx = 0
        while i < sorted.count {
            let segStartPts = sorted[i]
            let segStartSeconds = Double(segStartPts - startPts0) * tb
            let thresholdSeconds = Double(segIdx + 1) * target

            var j = i + 1
            while j < sorted.count {
                let candidateSeconds = Double(sorted[j] - startPts0) * tb
                if candidateSeconds >= thresholdSeconds { break }
                j += 1
            }

            let segEndPts: Int64
            let segEndSeconds: Double
            if j < sorted.count {
                segEndPts = sorted[j]
                segEndSeconds = Double(segEndPts - startPts0) * tb
            } else {
                segEndSeconds = sourceDurationSeconds
                segEndPts = Int64(sourceDurationSeconds / tb)
            }

            plan.append(Segment(
                startPts: segStartPts,
                endPts: segEndPts,
                startSeconds: segStartSeconds,
                durationSeconds: max(0.001, segEndSeconds - segStartSeconds)
            ))

            i = j
            segIdx += 1
        }

        return plan
    }

    // MARK: - DV / HDR detection

    private func doviConfigRecord(
        from codecpar: UnsafePointer<AVCodecParameters>
    ) -> AVDOVIDecoderConfigurationRecord? {
        let count = Int(codecpar.pointee.nb_coded_side_data)
        guard count > 0, let sideData = codecpar.pointee.coded_side_data else {
            return nil
        }
        for i in 0..<count {
            let item = sideData.advanced(by: i).pointee
            guard item.type == AV_PKT_DATA_DOVI_CONF else { continue }
            guard let raw = item.data, item.size >= 8 else { continue }
            return raw.withMemoryRebound(
                to: AVDOVIDecoderConfigurationRecord.self,
                capacity: 1
            ) { $0.pointee }
        }
        return nil
    }

    private func isHDRTransfer(_ codecpar: UnsafePointer<AVCodecParameters>) -> Bool {
        let trc = codecpar.pointee.color_trc
        return trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67
    }

    /// Validate that `index` points at an audio stream in the demuxer's
    /// container. Used to gate `audioSourceStreamIndexOverride` so a
    /// stale picker selection (e.g. a stream index from a previous
    /// title) can't make `start()` filter packets nobody is producing.
    private static func isAudioStream(demuxer: Demuxer, index: Int32) -> Bool {
        guard index >= 0, let stream = demuxer.stream(at: index) else {
            return false
        }
        return stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
    }

    private func classifyDVVariant(
        _ record: AVDOVIDecoderConfigurationRecord?,
        codecID: AVCodecID
    ) -> DVVariant {
        guard let r = record else { return .none }
        let profile = Int(r.dv_profile)
        let compat = Int(r.dv_bl_signal_compatibility_id)

        // HEVC + DV: profiles 5, 7, 8 per Dolby's ETSI TS 103 572.
        // Profile 9 is AVC+DV which AetherEngine doesn't support
        // (AVPlayer accepts AVC but not AVC+DV per DrHurt's matrix).
        if codecID == AV_CODEC_ID_HEVC {
            if profile == 5 { return .profile5 }
            if profile == 7 { return .profile7 }
            if profile == 8 {
                switch compat {
                case 1: return .profile81
                case 2: return .profile82
                case 4: return .profile84
                default: return .profile81  // P8.6 etc → treat as P8.1
                }
            }
            return .unknown
        }

        // AV1 + DV: profile 10 per Dolby's spec. compat == 0 means
        // P10.0 (no base layer); compat == 1 / 2 / 4 mirror P8's HDR10
        // / SDR / HLG base-layer compatibility flags.
        if codecID == AV_CODEC_ID_AV1 {
            if profile == 10 {
                switch compat {
                case 0: return .av1Profile10
                case 1: return .av1Profile101
                case 2: return .av1Profile102
                case 4: return .av1Profile104
                default: return .av1Profile10
                }
            }
            return .unknown
        }

        return .unknown
    }

    // MARK: - Segment plan model

    fileprivate struct Segment {
        let startPts: Int64
        let endPts: Int64
        let startSeconds: Double
        let durationSeconds: Double
    }

}

// MARK: - Cache-backed provider

/// Thin `HLSSegmentProvider` over a `SegmentCache`. The cache is
/// populated by the session's `HLSSegmentProducer`. AVPlayer GETs are
/// served from cache hits when the producer is ahead of the playhead;
/// misses block on the cache's per-index condvar with a generous
/// timeout (the producer is on a worker thread, so blocking the HTTP
/// server's connection thread is the natural backpressure model).
///
/// Scrub policy:
///  - In-cache: fast path, no waiting.
///  - Forward seek within `forwardWaitWindow` of cache.max: wait for
///    the producer to catch up. AVPlayer's normal sequential playback
///    falls in this bucket.
///  - Forward seek beyond that, or any backward seek beyond cache.min:
///    fire `restartHandler` so the engine can teardown + reseek
///    + spin up a fresh producer rooted at the new segment index,
///    then re-block on cache.fetch.
private final class VideoSegmentProvider: HLSSegmentProvider {

    private let cache: SegmentCache
    private let segments: [HLSVideoEngine.Segment]

    private let codecsString: String
    private let supplementalCodecsString: String?
    private let resolution: (Int, Int)
    private let videoRange: HLSVideoRange
    private let frameRate: Double?
    private let hdcpLevel: String?

    /// Closure into the engine that tears down the current producer
    /// and brings up a fresh one rooted at the given absolute segment
    /// index. Synchronous: returns after the new producer's pump has
    /// started writing, which is typically within 50-200 ms on Apple
    /// TV against a local Jellyfin source.
    private let restartHandler: ((Int) -> Void)?

    /// Last index passed to `restartHandler`, also used as the assumed
    /// base index of the engine's currently-active producer. Used by
    /// the empty-cache branch in `mediaSegment(at:)` to distinguish
    /// between "producer just launched here, wait for it" (`abs(index
    /// − lastRestartIndex) ≤ 2`) and "producer is far away from this
    /// index, restart needed" (large diff). Initialised to 0 since
    /// every session starts with an initial producer at baseIndex 0
    /// or the host's resume target, with the engine updating this
    /// after the first explicit restart it triggers via the public
    /// `restartProducer(at:)` path.
    private var lastRestartIndex: Int = 0

    /// Forward-distance threshold beyond which a fetch triggers a
    /// restart instead of waiting for the producer to catch up.
    /// 8 is the value that survives both failure modes:
    ///
    ///   - Tightened to 3 briefly to fix a Vincent repro where a
    ///     seg-13 request waited 26 s for the existing producer to
    ///     sequentially write 11 segments. The smaller window did
    ///     trigger restart at the target index for that case, but
    ///     also restarted on every AVPlayer prefetch above the cache
    ///     edge. AVPlayer's HLS engine speculatively prefetches 5-7
    ///     segments ahead of the playhead during normal playback, so
    ///     with window 3 every prefetch above cache.max+3 triggered
    ///     a restart that killed the in-flight producer mid-write,
    ///     leaving cache holes that AVPlayer hit on its next sequential
    ///     request, restarting again, and so on. Vincent's "video
    ///     hängt nach Scrub nach vorn" was the cascade outcome.
    ///   - 8 is wide enough to absorb AVPlayer's prefetch (any request
    ///     within ~32 s of source content above cache.max waits) and
    ///     narrow enough that user-initiated scrubs of 30+ seconds
    ///     still trigger a restart at the target. The 26 s wait
    ///     in the original repro is the worst-case for "wait within
    ///     window"; it's annoying but not a hang, and stays bounded
    ///     by segment-write-rate × window. Tightening below 8
    ///     requires distinguishing user scrubs from AVPlayer's
    ///     speculative prefetch, which we currently cannot do from
    ///     the segment-server side.
    private static let forwardWaitWindow = 8

    // MARK: - Sliding-window EVENT playlist state

    /// Segments visible in /media.m3u8 are `[0, visibleHighWater]`.
    /// EVENT playlists are append-only per RFC 8216 §6.2.1, so this
    /// counter is monotonic over a session. Grows by `growthPerRefresh`
    /// on each playlist build, plus explicit jumps from
    /// `extendVisibleWindow(toCover:)` on seek.
    ///
    /// Initial value covers the resume position so AVPlayer's first
    /// playlist read already contains the seg AVPlayer is about to
    /// seek to; otherwise AVPlayer either refuses the seek or stalls
    /// waiting for the playlist to grow past the requested time.
    ///
    /// AVPlayer fires CoreMediaErrorDomain -12888 ("Playlist File
    /// unchanged") after 2 consecutive polls of an unchanged playlist
    /// (target-duration / 2 cadence, ≈ 2 s for our 4 s segments).
    /// Adding ≥ 1 segment per build keeps that check happy.
    private let stateLock = NSLock()
    private var visibleHighWater: Int
    private var refreshCounter: Int = 0
    private var endlistAdded: Bool = false

    /// How many segments past the resume position the initial playlist
    /// exposes. 30 × 4 s = 120 s of forward runway: enough to absorb
    /// AVPlayer's preferredForwardBufferDuration plus the producer's
    /// startup latency without AVPlayer hitting the end of the visible
    /// playlist and stalling.
    private static let initialFillSegments = 30

    /// Segments appended per playlist refresh. Must be ≥ 1 so two
    /// consecutive polls never see the same playlist (the
    /// -12888 trigger). Picked > 1 so the visible window grows faster
    /// than playback consumes it (1 seg per 4 s playback vs 2 segs per
    /// ~2.5 s poll = ~3.2x ahead).
    private static let growthPerRefresh = 2

    init(
        cache: SegmentCache,
        segments: [HLSVideoEngine.Segment],
        codecsString: String,
        supplementalCodecs: String?,
        resolution: (Int, Int),
        videoRange: HLSVideoRange,
        frameRate: Double?,
        hdcpLevel: String?,
        initialIndex: Int = 0,
        restartHandler: ((Int) -> Void)? = nil
    ) {
        self.cache = cache
        self.segments = segments
        self.codecsString = codecsString
        self.supplementalCodecsString = supplementalCodecs
        self.resolution = resolution
        self.videoRange = videoRange
        self.frameRate = frameRate
        self.hdcpLevel = hdcpLevel
        self.restartHandler = restartHandler

        let safeInitial = max(0, min(initialIndex, segments.count - 1))
        let target = safeInitial + Self.initialFillSegments
        self.visibleHighWater = min(segments.count - 1, max(Self.initialFillSegments, target))
    }

    // MARK: - Sliding-window operations

    /// Extend the visible window so segment `index` is in the playlist.
    /// Called from the engine's seek path before AVPlayer issues its
    /// new segment fetch so the playlist already lists the target by
    /// the time AVPlayer re-reads it. Idempotent and monotonic.
    func extendVisibleWindow(toCover index: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !endlistAdded else { return }
        let target = min(segments.count - 1, index + Self.initialFillSegments)
        if target > visibleHighWater {
            visibleHighWater = target
            if visibleHighWater >= segments.count - 1 {
                endlistAdded = true
            }
        }
    }

    /// Atomic snapshot the playlist build reads from. Now that we're
    /// back on .vod playlistType the sliding-window state is dormant
    /// (visibleHighWater is still tracked for future EVENT revival,
    /// but the snapshot reports the full segment count so AVPlayer
    /// sees the complete playlist with a correct asset.duration).
    /// Without this fix the snapshot was returning visibleHighWater+1
    /// (=31 at session start), causing AVPlayer to think the asset
    /// was 2:13 long and stop playback at that point.
    func notePlaylistBuild() -> (visibleCount: Int, refreshCounter: Int, endlistAdded: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        refreshCounter += 1
        return (segments.count, refreshCounter, false)
    }

    // MARK: - HLSSegmentProvider

    func initSegment() -> Data? {
        return cache.fetchInit(timeout: 30.0)
    }

    /// File URL for a cached segment without materializing any bytes.
    /// Used by `HLSLocalServer` to take the `sendfile(2)` fast path
    /// (file → socket entirely kernel-side, no Foundation `Data`
    /// involvement). Returns nil when the segment isn't yet cached,
    /// is out of range, or its cache entry has been pruned. This is
    /// intentionally a pure-lookup: no producer restart, no window
    /// extension, no `declareTarget`. The caller falls back to
    /// `mediaSegment(at:)` (which does drive those side effects) on
    /// nil.
    func mediaSegmentURL(at index: Int) -> URL? {
        guard index >= 0, index < segments.count else { return nil }
        // Drive cache-window + restart side effects same as the Data
        // path; only the byte materialization changes. Without this
        // the sendfile path would skip the producer restart on
        // out-of-range fetches and AVPlayer would 404 indefinitely.
        extendVisibleWindow(toCover: index)
        cache.declareTarget(index)
        return cache.peekURL(index: index)
    }

    func mediaSegment(at index: Int) -> Data? {
        guard index >= 0, index < segments.count else { return nil }
        let totalStart = DispatchTime.now()

        // Defensive: if AVPlayer fetches a segment beyond the current
        // visible window (e.g. via an internal seek path that bypassed
        // the engine.seek hook), extend the window so the next playlist
        // refresh includes it. Without this, AVPlayer could end up
        // working off a stale view where it requests a seg that isn't
        // "supposed to exist" yet.
        extendVisibleWindow(toCover: index)

        // Declare AVPlayer's target FIRST so the cache window slides
        // to centre on `index` before any subsequent producer store
        // runs `pruneOutsideWindow`. Without this, a resume-style
        // jump to seg-55 races with the producer's first store: the
        // producer (after restart at 55) writes seg-55, the cache
        // prunes with the still-default target=-1 / window=[-16,19],
        // seg-55 is evicted before `fetch(55)` ever sees it, and
        // AVPlayer times out on a segment that did exist for ~10 µs.
        cache.declareTarget(index)

        // Fast path: serve from cache.
        if let hit = cache.peek(index: index) {
            return logServed(index: index, bytes: hit, totalStart: totalStart, restarted: false)
        }

        // Decide whether to restart the producer or wait. Four cases:
        //   - range is empty → the producer hasn't produced (or hasn't
        //     produced anything in our current window after declareTarget
        //     pruned). If the requested index is beyond the producer's
        //     plausible cold-start reach (a few seg-0s), restart at
        //     `index`. Otherwise wait — the producer is about to write
        //     seg-0 / seg-1 / seg-2 and we don't want to thrash.
        //   - index below the cache's low edge → backward seek past
        //     the kept window, restart.
        //   - index too far above the cache's high edge → forward
        //     seek past where the producer can reach via backpressure,
        //     restart.
        //   - index nominally within the cache's [min..max] range but
        //     peek failed → could be a real hole OR producer-in-flight
        //     that hasn't yet written this segment. Wait briefly; only
        //     restart if the wait times out. Without this short wait
        //     every restart cascades: producer restarts at N, finishes
        //     writing N, returns to caller; AVPlayer then GETs N+1, but
        //     producer hasn't written N+1 yet so peek returns nil while
        //     cache.range is (N..M) from the previous producer's leftover.
        //     The "hole" branch triggers a fresh restart at N+1, which
        //     repeats the pattern for N+2, N+3, etc. A 2s wait absorbs
        //     the typical 100-500ms producer write cadence and breaks
        //     the cascade. True holes (rare; happen after CC's +10s skip
        //     when AVPlayer rebuffers behind the skip target and the
        //     declareTarget prune evicts a segment AVPlayer will need
        //     later) still trigger a restart after the wait times out.
        let range = cache.indexRange()
        let needsRestart: Bool
        if let r = range {
            if index < r.0 {
                needsRestart = true
            } else if index > r.1 + Self.forwardWaitWindow {
                needsRestart = true
            } else if index >= r.0 && index <= r.1 {
                // Producer might still be writing this index forward
                // from its current write head. Wait briefly first.
                if let waited = cache.fetch(index: index, timeout: 2.0) {
                    return logServed(index: index, bytes: waited, totalStart: totalStart, restarted: false)
                }
                needsRestart = true
            } else {
                // r.1 < index <= r.1 + forwardWaitWindow — producer is
                // about to write this; backpressure-wait.
                needsRestart = false
            }
        } else {
            // Empty cache. Two scenarios:
            //  1. Cold start: producer just launched at lastRestartIndex,
            //     hasn't written anything yet. AVPlayer's first GET for
            //     a nearby segment should wait briefly while the producer
            //     fills the cache (restarting would just churn the
            //     producer we already have).
            //  2. Big scrub after the cache window slid away: the
            //     producer is far from `index` (different baseIndex)
            //     and won't ever write into the requested region.
            //     Restart is mandatory; waiting just times out.
            //
            // Discriminate on lastRestartIndex (the absolute segment
            // index the engine's current producer was launched at):
            // close to `index` means cold-start case → wait; far from
            // it means scrub case → restart. The previous heuristic
            // (`index > 2`) only handled cold-start from index 0 and
            // missed Vincent's repro where the producer was at idx
            // 1314 and AVPlayer requested seg-0 after a back-scrub,
            // leaving AVPlayer to time out for 30 s and 404.
            needsRestart = abs(index - lastRestartIndex) > 2
        }

        if needsRestart, let restart = restartHandler {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): out-of-range fetch (cache.range=\(range.map { "\($0.0)..\($0.1)" } ?? "empty")), restarting producer",
                category: .session
            )
            lastRestartIndex = index
            restart(index)
        }

        let bytes = cache.fetch(index: index, timeout: 30.0)
        return logServed(index: index, bytes: bytes, totalStart: totalStart, restarted: needsRestart)
    }

    private func logServed(index: Int, bytes: Data?, totalStart: DispatchTime, restarted: Bool) -> Data? {
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - totalStart.uptimeNanoseconds) / 1_000_000
        if let bytes = bytes {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): served \(bytes.count) B (wait=\(String(format: "%.1f", elapsedMs))ms cache=\(cache.count) restarted=\(restarted))",
                category: .session
            )
        } else {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): cache miss after \(String(format: "%.0f", elapsedMs))ms (cache=\(cache.count) restarted=\(restarted))",
                category: .session
            )
        }
        return bytes
    }

    var segmentCount: Int { segments.count }

    func segmentDuration(at index: Int) -> Double {
        guard index >= 0, index < segments.count else { return 0 }
        return segments[index].durationSeconds
    }

    /// Reverted to .vod after the sliding-window EVENT experiment:
    /// EVENT halved RSS growth (3.0 → 1.3 MB/sec) but did not bound
    /// it (AVPlayer still retains ~93% of consumed source bytes
    /// regardless of playlist type), and the side effects were
    /// unacceptable — Control Center showed "LIVE" instead of a
    /// scrub bar (caused by EVENT making asset.duration NaN), and
    /// replay-from-beginning landed ~2 min in (AVPlayer's EVENT
    /// live-edge default overrode EXT-X-START even with the
    /// explicit seek-to-0). The leak is fundamental to the
    /// AVPlayer + HLS-loopback pipeline for 4K HDR HEVC content.
    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { codecsString }
    var masterSupplementalCodecs: String? { supplementalCodecsString }
    var masterResolution: (width: Int, height: Int)? {
        return (resolution.0, resolution.1)
    }
    var masterVideoRange: HLSVideoRange? { videoRange }
    var masterBandwidth: Int? { 5_000_000 }
    var masterAverageBandwidth: Int? { 5_000_000 }
    var masterFrameRate: Double? { frameRate }
    var masterHDCPLevel: String? { hdcpLevel }
    var masterClosedCaptions: String? { "NONE" }
}
