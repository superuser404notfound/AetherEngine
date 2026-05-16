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
        case profile84         // HEVC P8.4 with HLG-compat base    → dvh1 + HLG (on DV display)
        case profile7          // HEVC P7 dual-layer                → reject
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
            case .mp3:    return "mp4a.40.34"
            case .opus, .truehd, .dts, .vorbis, .pcm, .mp2, .unsupported:
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
        var requiresBridge: Bool {
            switch self {
            case .opus, .truehd, .dts, .vorbis, .pcm, .mp2: return true
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
    /// the playlist's cumulative-EXTINF origin of 0 — AVPlayer's
    /// HLS-fMP4 engine stalls at `waitingToPlay` otherwise.
    private var firstKeyframePts: Int64 = 0
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
        keepDvh1TagWithoutDV: Bool = false,
        audioSourceStreamIndexOverride: Int32? = nil
    ) {
        self.sourceURL = url
        self.sourceHTTPHeaders = sourceHTTPHeaders
        self.dvModeAvailable = dvModeAvailable
        self.keepDvh1TagWithoutDV = keepDvh1TagWithoutDV
        self.audioSourceStreamIndexOverride = audioSourceStreamIndexOverride
    }

    // MARK: - Public API

    public func start() throws -> URL {
        guard demuxer == nil else { throw HLSVideoEngineError.alreadyStarted }

        // 1. Open the source.
        let dem = Demuxer()
        do {
            try dem.open(url: sourceURL, extraHeaders: sourceHTTPHeaders)
        } catch {
            throw HLSVideoEngineError.openFailed(reason: "\(error)")
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

        // 4. Classify the DV variant and pick the master-playlist
        //    CODECS string + codec_tag override. Same routing rules as
        //    before: P5 / P8.1 use bare `dvh1.<profile>.<dvLevel>`
        //    direct form; P8.4 keeps the cross-player-compat `hvc1.2.4
        //    .LXX` + SUPPLEMENTAL `dvh1.08.LL/db4h` because its base
        //    layer is HLG-HEVC. With dvModeAvailable=false the engine
        //    downgrades any DV source to plain HEVC (hvc1) so AVPlayer
        //    doesn't reject the asset on a non-DV-capable display.
        let codecTagOverride: String?
        let videoRange: HLSVideoRange
        let primaryCodecs: String
        let supplementalCodecs: String?
        let dvVariant: DVVariant

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
        } else if !effectiveDvMode {
            codecTagOverride = "hvc1"
            let hevcLevelRaw = Int(codecpar.pointee.level)
            let hevcLevel = hevcLevelRaw > 0 ? hevcLevelRaw : 150
            let trc = codecpar.pointee.color_trc
            if trc == AVCOL_TRC_ARIB_STD_B67 {
                videoRange = .hlg
            } else if trc == AVCOL_TRC_SMPTE2084 {
                videoRange = .pq
            } else {
                videoRange = .sdr
            }
            primaryCodecs = "hvc1.2.4.L\(hevcLevel)"
            supplementalCodecs = nil
            dvVariant = .none
        } else {
            let dvRecord = doviConfigRecord(from: codecpar)
            dvVariant = classifyDVVariant(dvRecord, codecID: AV_CODEC_ID_HEVC)

            let dvLevelRaw = Int(dvRecord?.dv_level ?? 0)
            let dvLevel = dvLevelRaw > 0 ? dvLevelRaw : 6
            let hevcLevelRaw = Int(codecpar.pointee.level)
            let hevcLevel = hevcLevelRaw > 0 ? hevcLevelRaw : 150
            let dvLevelStr = String(format: "%02d", dvLevel)

            switch dvVariant {
            case .profile5:
                codecTagOverride = "dvh1"
                videoRange = .pq
                primaryCodecs = "dvh1.05.\(dvLevelStr)"
                supplementalCodecs = nil
            case .profile81, .profile84:
                // P8.1 (HDR10-compat base) and P8.4 (HLG-compat base).
                // This branch only fires when `effectiveDvMode == true`,
                // which under the current `keepDvh1TagWithoutDV=false`
                // default means `dvModeAvailable == true` — i.e. the
                // active display is DV-capable. Non-DV displays take
                // the `!effectiveDvMode` branch above and never reach
                // here.
                //
                // For a DV-capable display we emit bare `dvh1` rather
                // than the spec's cross-compat `hvc1 + SUPPLEMENTAL=
                // dvh1/db*` form. Rationale:
                //
                // - `AVPlayerViewController.appliesPreferredDisplayCriteria
                //   Automatically = true` makes AVKit read the
                //   init.mp4 sample-entry codec FourCC and program
                //   `preferredDisplayCriteria` to match. With `hvc1`
                //   in the sample entry, AVKit asks the panel for
                //   HDR10 / HLG mode — overriding the engine's own
                //   DV criteria assignment from
                //   `DisplayCriteriaController.apply()`. DrHurt's
                //   AetherEngine#4 report: "DV 8.4: TV switches to
                //   HDR mode and Sodalite shows 'HLG'" is exactly
                //   this override.
                //
                // - Cross-compat tags exist so that NON-DV-capable
                //   AVPlayer instances can fall back to the HEVC
                //   base layer. That's unreachable on this branch
                //   (we already know the display is DV-capable), so
                //   the cross-compat is pure overhead.
                //
                // - Bare `dvh1` puts the dvh1 FourCC directly in
                //   both the master CODECS attribute and the
                //   sample-entry, so AVKit's auto-criteria and the
                //   engine's manual criteria converge on DV mode.
                //
                // P8.1 and P8.4 differ only in the base layer's
                // transfer (PQ vs HLG); both negotiate DV mode on a
                // DV-capable panel that does that profile.
                codecTagOverride = "dvh1"
                videoRange = (dvVariant == .profile84) ? .hlg : .pq
                primaryCodecs = "dvh1.08.\(dvLevelStr)"
                supplementalCodecs = nil
            case .profile7:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: 7, compatID: -1)
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
            codecTagOverride: codecTagOverride
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
                audioHLSCodecs = compat.hlsCodecsString
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec=\(compat) → stream-copy as `\(compat.hlsCodecsString)` "
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
        let prov = VideoSegmentProvider(
            cache: segmentCache,
            segments: plan,
            codecsString: manifestCodecs,
            supplementalCodecs: supplementalCodecs,
            resolution: resolution,
            videoRange: videoRange,
            frameRate: frameRate,
            hdcpLevel: hdcpLevel,
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
        //   - DV-capable display + DV source: master playlist with
        //     full DV codec strings so AVKit's auto-criteria reads
        //     `dvh1` from the sample entries and engages DV mode.
        //   - non-DV display + HDR HEVC (HDR10 / HLG): master so
        //     AVKit gets the `VIDEO-RANGE=PQ` (or HLG) + `hvc1` codec
        //     hint upfront and programs HDR criteria immediately.
        //     Routing through media here defaults AVKit's auto-
        //     criteria to SDR until init.mp4 is fetched and parsed —
        //     long enough for AVKit to override the engine's pre-load
        //     HDR criteria and stick the panel back in SDR mode for
        //     the rest of the session ("Match Dynamic Range ON, TV
        //     blinks to HDR then drops back to SDR" symptom).
        //   - non-DV display + DV source: still media-playlist for
        //     AVPlayer's auto-tonemap path. The master with bare
        //     `dvh1` would be rejected by tvOS 26's strict master-
        //     level codec filter (-11868).
        //   - SDR HEVC: media is fine, no auto-criteria override
        //     to worry about.
        let useMasterPlaylist: Bool
        if effectiveDvMode {
            useMasterPlaylist = true
        } else if videoRange != .sdr && dvVariant == .none {
            useMasterPlaylist = true
        } else {
            useMasterPlaylist = false
        }
        let resolvedURL: URL? = useMasterPlaylist
            ? srv.playlistURL
            : srv.mediaPlaylistURL
        guard let url = resolvedURL else {
            stop()
            throw HLSVideoEngineError.openFailed(reason: "server URL not ready")
        }
        EngineLog.emit("[HLSVideoEngine] serving on \(url.absoluteString) (dvModeAvailable=\(dvModeAvailable) effectiveDvMode=\(effectiveDvMode) useMaster=\(useMasterPlaylist) videoRange=\(videoRange) dvVariant=\(dvVariant))")
        return url
    }

    public func stop() {
        restartLock.lock()
        producer?.stop()
        let p = producer
        producer = nil
        restartLock.unlock()
        // Wait outside the lock so deinit on the producer (which may
        // touch the engine via weakly-captured closures) doesn't
        // re-enter restartLock.
        _ = p?.waitForFinish(timeout: 3.0)

        server?.stop()
        cache?.close()
        audioBridge?.close()
        provider = nil
        server = nil
        cache = nil
        savedVideoConfig = nil
        savedAudioConfig = nil
        audioBridge = nil
        segmentPlan = []
        demuxer?.close()
        demuxer = nil
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
            desiredAudioTfdt = savedAudioConfig.map {
                av_rescale_q(desiredVideoTfdt, cfg.timeBase, $0.inputTimeBase)
            } ?? 0
        } else {
            videoTarget = Int64.min
            desiredVideoTfdt = 0
            desiredAudioTfdt = 0
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
            desiredFirstAudioTfdtPts: desiredAudioTfdt
        )
        prod.onFirstHDR10PlusDetected = { [weak self] in
            self?.notifyHDR10PlusOnce()
        }
        return prod
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
        if !preferBridge, let cfg = streamCopyAudio {
            self.savedAudioConfig = cfg
            do {
                let prod = try makeProducer(baseIndex: 0)
                if sourceIsAtmos {
                    EngineLog.emit(
                        "[HLSVideoEngine] EAC3+JOC Atmos: stream-copy engaged, MAT 2.0 passthrough intact",
                        category: .session
                    )
                }
                return prod
            } catch {
                if sourceIsAtmos {
                    EngineLog.emit(
                        "[HLSVideoEngine] WARNING: Atmos downgrade — EAC3+JOC stream-copy rejected by mp4 muxer (\(error)). "
                        + "Falling back to FLAC bridge: bed channels stay lossless, but object metadata is lost. "
                        + "Source: \(sourceAudioStream?.pointee.codecpar.pointee.profile.description ?? "?") profile, "
                        + "channels=\(sourceAudioStream?.pointee.codecpar.pointee.ch_layout.nb_channels ?? -1). "
                        + "If you see this in production, capture the source MKV — dec3 extradata reconstruction can recover Atmos.",
                        category: .session
                    )
                } else {
                    EngineLog.emit(
                        "[HLSVideoEngine] audio stream-copy header write failed (\(error)), retrying with FLAC bridge",
                        category: .session
                    )
                }
                // Fall through to bridge attempt.
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
                    srcTimeBase: audioStream.pointee.time_base
                )
                if let cp = bridge.encoderCodecpar {
                    let cfg = HLSSegmentProducer.AudioConfig(
                        codecpar: cp,
                        timeBase: bridge.encoderTimeBase,
                        sourceStreamIndex: sourceAudioStreamIndex,
                        inputTimeBase: bridge.encoderTimeBase,
                        bridge: bridge
                    )
                    self.savedAudioConfig = cfg
                    self.audioBridge = bridge
                    do {
                        let prod = try makeProducer(baseIndex: 0)
                        audioHLSCodecs = "fLaC"
                        return prod
                    } catch {
                        EngineLog.emit(
                            "[HLSVideoEngine] FLAC bridge header write failed (\(error)), falling back to video-only",
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

    /// Forward-distance threshold beyond which a fetch triggers a
    /// restart instead of waiting for the producer to catch up. At
    /// 6 s segments, 8 segments ≈ 48 s of source content; further
    /// than that and waiting is slower than tearing down and
    /// resuming at the target.
    private static let forwardWaitWindow = 8

    init(
        cache: SegmentCache,
        segments: [HLSVideoEngine.Segment],
        codecsString: String,
        supplementalCodecs: String?,
        resolution: (Int, Int),
        videoRange: HLSVideoRange,
        frameRate: Double?,
        hdcpLevel: String?,
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
    }

    // MARK: - HLSSegmentProvider

    func initSegment() -> Data? {
        return cache.fetchInit(timeout: 30.0)
    }

    func mediaSegment(at index: Int) -> Data? {
        guard index >= 0, index < segments.count else { return nil }
        let totalStart = DispatchTime.now()

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

        // Decide whether to restart the producer or wait. Three cases:
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
        let range = cache.indexRange()
        let needsRestart: Bool
        if let r = range {
            needsRestart = (index < r.0) || (index > r.1 + Self.forwardWaitWindow)
        } else {
            // Empty cache. Producer's plausible cold-start reach is
            // ~3 segments; anything past that and we know we want a
            // restart at the requested index rather than wait.
            needsRestart = index > 2
        }

        if needsRestart, let restart = restartHandler {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): out-of-range fetch (cache.range=\(range.map { "\($0.0)..\($0.1)" } ?? "empty")), restarting producer",
                category: .session
            )
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
