import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Session that turns a remote video source (typically a Jellyfin
/// MKV) into a local HLS-fMP4 stream AVPlayer can play. Built so the
/// existing AetherEngine demuxer + new `FMP4VideoMuxer` + new
/// `HLSLocalServer` cooperate around a lazy `HLSSegmentProvider`
/// implementation that generates one fragment per AVPlayer GET.
///
/// Only used for streams the host has classified as Dolby Vision
/// direct-play (the `.native` route in Sodalite's player). HDR10,
/// HDR10+, HLG and SDR continue to flow through AetherEngine's
/// FFmpeg + VideoToolbox + AVSampleBufferDisplayLayer pipeline,
/// because those don't need the AVPlayer-only HDMI handshake that
/// engages tvOS's true Dolby Vision mode on a capable TV.
///
/// Phase 4 of the rollout: video-only fragments. Audio routing into
/// the same fMP4 stream lands in phase 6. AVPlayer will play silent
/// video for now, which is enough to verify the DV signalling path.
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
    /// table in DrHurt's KSPlayer notes (AetherEngine#1) and Apple's
    /// HLS Authoring Spec. The codec FourCC the muxer writes and the
    /// `VIDEO-RANGE` we put on the master playlist depend on which
    /// variant we hit.
    fileprivate enum DVVariant {
        case none           // not DV (would be a routing bug phase 1 only sends DV here)
        case profile5       // P5 (IPT-PQ-c2, no HDR10 base)         → dvh1 + PQ
        case profile81      // P8 with HDR10-compat base              → dvh1 + PQ
        case profile84      // P8 with HLG-compat base                → hvc1 + HLG
        case profile7       // P7 dual-layer (Apple TV cannot decode) → reject
        case profile82      // P8 with SDR-compat base (rare)         → reject
        case unknown        // anything else (P9, P10/AV1, malformed) → reject
    }

    /// Audio codec compatibility with AVPlayer's native fMP4 decode
    /// pipeline. AAC / AC3 / EAC3 (incl. Atmos JOC) / FLAC / ALAC /
    /// MP3 / Opus stream-copy directly into fMP4 segments and AVPlayer
    /// renders them. TrueHD / DTS / DTS-HD MA aren't legal in fMP4 at
    /// all but FFmpeg has decoders for them; the `AudioBridge` decodes
    /// to PCM and re-encodes losslessly as FLAC (DrHurt's `-c:a flac`
    /// trick), which AVPlayer plays natively.
    fileprivate enum AudioCodecCompat {
        case aac, ac3, eac3, flac, alac, mp3, opus
        case truehd, dts
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
            default:                 return .unsupported
            }
        }

        /// CODECS string AVPlayer reads on the master playlist when
        /// this codec is stream-copied directly. Empty for codecs
        /// that always have to be bridged (TrueHD / DTS) since their
        /// hlsCodecsString is `fLaC` after transcode anyway.
        var hlsCodecsString: String {
            switch self {
            case .aac:    return "mp4a.40.2"
            case .ac3:    return "ac-3"
            case .eac3:   return "ec-3"
            case .flac:   return "fLaC"
            case .alac:   return "alac"
            case .mp3:    return "mp4a.40.34"
            case .opus:   return "opus"
            case .truehd: return ""
            case .dts:    return ""
            case .unsupported: return ""
            }
        }

        /// Codecs that aren't legal in fMP4 and always have to go
        /// through `AudioBridge` for FLAC transcoding. Stream-copy
        /// codecs may also fall through to the bridge if the muxer
        /// rejects them at header-write time (typical for EAC3 from
        /// MKV without pre-parsed `dec3` extradata).
        var requiresBridge: Bool {
            switch self {
            case .truehd, .dts: return true
            default:            return false
            }
        }
    }

    // MARK: - State

    private let sourceURL: URL
    /// Whether the host's display pipeline can actually engage Dolby
    /// Vision mode on the HDMI handshake. When false (e.g. the user
    /// disabled "Match Dynamic Range" in tvOS Settings, or the TV
    /// just isn't DV-capable), DV-tagged fragments are rejected by
    /// AVPlayer at asset-load time. We respond by downgrading the
    /// muxed sample-entry tag to `hvc1` and emitting a plain HEVC
    /// CODECS string — DV P8.1 then plays as its HDR10 base layer,
    /// and AVPlayer's automatic tone-mapping (preferredDynamicRange
    /// defaults to standard) handles the HDR10→SDR conversion. DV
    /// P5 sources also play in this mode but lose colour fidelity,
    /// since their bitstream is IPT-PQ-c2 rather than BT.2020 PQ.
    private let dvModeAvailable: Bool
    private var demuxer: Demuxer?
    private var server: HLSLocalServer?
    private var provider: VideoSegmentProvider?

    /// Approximate target segment duration in seconds. Actual
    /// fragments may be slightly shorter or longer because we snap
    /// boundaries to source keyframes. 6 s matches Apple's HLS
    /// authoring recommendation.
    private static let targetSegmentDuration: Double = 6.0

    public init(url: URL, dvModeAvailable: Bool = true) {
        self.sourceURL = url
        self.dvModeAvailable = dvModeAvailable
    }

    // MARK: - Public API

    /// Open the source, build the segment plan, start the server,
    /// return the URL the host hands to AVPlayer.
    public func start() throws -> URL {
        guard demuxer == nil else { throw HLSVideoEngineError.alreadyStarted }

        // 1. Open the source. Reuses AetherEngine's existing AVIO +
        //    HTTP byte-range fetch + Matroska demuxer; nothing new
        //    here on the input side.
        let dem = Demuxer()
        do {
            try dem.open(url: sourceURL)
        } catch {
            throw HLSVideoEngineError.openFailed(reason: "\(error)")
        }
        demuxer = dem

        let videoIndex = dem.videoStreamIndex
        guard videoIndex >= 0, let videoStream = dem.stream(at: videoIndex) else {
            throw HLSVideoEngineError.noVideoStream
        }
        let codecpar = videoStream.pointee.codecpar!
        // H.264 acceptance was added so the diagnostic
        // `devForceHLSWrapper` toggle can exercise the HLS-fMP4
        // remux path on H.264 sources too, not just HEVC. The mp4
        // muxer auto-detects avcC vs hvcC from codec_id and writes
        // the right config box; we just have to remember to override
        // the sample-entry tag to "avc1" (it would default to "h264"
        // which AVPlayer would reject).
        let isHEVC = codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
        let isH264 = codecpar.pointee.codec_id == AV_CODEC_ID_H264
        guard isHEVC || isH264 else {
            throw HLSVideoEngineError.unsupportedCodec(rawCodecID: codecpar.pointee.codec_id.rawValue)
        }

        // 2. Build the segment plan. The previous uniform-stride
        //    plan generated 6-second segments at fixed times, then
        //    mediaSegment(at:) ran a runtime IRAP search to snap
        //    each cut to a real keyframe. That worked for the muxer
        //    (each fragment was self-contained), but the playlist's
        //    EXTINF times never matched the fragment's actual
        //    content range — for a source with irregular GOPs the
        //    drift between "playlist says seg N is at 294–300" and
        //    "fragment's tfdt says decode at 300.6" could reach
        //    several seconds per fragment. AVPlayer used the tfdt
        //    correctly but mapped scrubs through the playlist, so
        //    after a handful of scrubs the player's idea of where
        //    each fragment lives diverged from where its bytes
        //    actually played, surfacing as the "video freezes,
        //    audio continues" symptom Vincent kept seeing.
        //
        //    Fix: build the segment plan from real IRAP positions
        //    in the source's libavformat index after the cue prewarm
        //    seek has populated it. Each segment boundary is now a
        //    known keyframe in the source — the playlist EXTINF and
        //    the fragment tfdt agree exactly. The historical "index
        //    always empty" problem (DrHurt's build-115) was solved
        //    by adding the cue prewarm step below, but the segment
        //    plan never started reading from the index until this
        //    change.
        //
        //    Sources where the index is still empty after prewarm
        //    (some non-MKV containers, malformed cue tables) fall
        //    back to the uniform plan. Same runtime IRAP search
        //    handles boundaries in that path.
        let videoTimeBase = videoStream.pointee.time_base
        let durationSeconds = dem.duration
        guard durationSeconds > 0 else {
            throw HLSVideoEngineError.zeroDuration
        }

        // Prewarm the MKV cue table. avformat_seek_file's first
        // invocation on an MKV source lazily parses the Cues element
        // from the file tail, which fans out into one or two HTTP
        // byte-range reads through the AVIO callback. Mid-duration
        // seek target so any cached AVIO bytes left over after the
        // prewarm are still usable by mid-movie resume positions.
        let prewarmStart = DispatchTime.now()
        dem.seek(to: durationSeconds * 0.5)
        let prewarmMs = Double(DispatchTime.now().uptimeNanoseconds - prewarmStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit("[HLSVideoEngine] cue prewarm: seek to \(String(format: "%.1f", durationSeconds * 0.5))s took \(String(format: "%.1f", prewarmMs))ms")

        let keyframes = dem.indexedKeyframes(streamIndex: videoIndex)
        let plan: [Segment]
        if keyframes.count >= 2 {
            plan = buildKeyframeSegmentPlan(
                keyframes: keyframes,
                videoTimeBase: videoTimeBase,
                sourceDurationSeconds: durationSeconds
            )
            EngineLog.emit(
                "[HLSVideoEngine] segment plan: keyframe-aligned, \(keyframes.count) IRAPs → \(plan.count) segments",
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

        // 4. Classify the DV variant and compute the master-playlist
        //    CODECS string. For AVPlayer-only consumption (which is
        //    our case: tvOS / iOS / macOS only, no other HLS clients
        //    ever see this stream), the simpler `dvh1.<profile>.<dv
        //    Level>` direct form is preferable to Apple's cross-
        //    player-compatibility form (`hvc1.2.4.LXXX` + `SUPPLE
        //    MENTAL-CODECS=dvh1.08.LL/db1p`). Both forms work for
        //    AVPlayer when the master also carries the recommended
        //    extras (AVERAGE-BANDWIDTH, FRAME-RATE, HDCP-LEVEL=
        //    TYPE-1 for 4K HDR, CLOSED-CAPTIONS=NONE), but DrHurt's
        //    empirical work across many DV files (issue #2) shows
        //    that the `dvh1` direct form is more robust against
        //    poorly-mastered sources where the HEVC base-layer
        //    advertised in `hvc1.2.4.LXXX` doesn't quite match the
        //    actual bitstream profile / level. SUPPLEMENTAL-CODECS
        //    matters for non-DV-aware players that need a base-layer
        //    fallback; AVPlayer is DV-aware and parses the dvvC /
        //    dvcC config box from init.mp4 directly.
        //
        //       Profile         | codec_tag | CODECS               | VIDEO-RANGE
        //       ----------------+-----------+----------------------+------------
        //       P5  (compat 0)  | dvh1      | dvh1.05.<dvLevel>    | PQ
        //       P8.1 (compat 1) | dvh1      | dvh1.08.<dvLevel>    | PQ
        //       P8.4 (compat 4) | hvc1      | hvc1.2.4.L<hev>.b0,  | HLG
        //                       |           |  SUPPLEMENTAL=       |
        //                       |           |  dvh1.08.LL/db4h     |
        //
        //    P8.4 keeps the supplemental form because its base layer
        //    is HLG-HEVC (codec_tag=hvc1) and we don't have a P8.4
        //    test source to validate dvh1-direct against. Conservative
        //    until we do.
        //
        //    The bare `dvh1` we shipped through builds 121-124 was
        //    rejected because it lacked the master-level extras
        //    (AVERAGE-BANDWIDTH / FRAME-RATE / HDCP-LEVEL / CLOSED-
        //    CAPTIONS); AVPlayer's master-codec-filter for HDR / DV
        //    variants needs them. Verified empirically with the
        //    standalone `aetherctl` CLI: dvh1 alone rejected, dvh1
        //    plus extras accepted.
        let codecTagOverride: String?
        let videoRange: HLSVideoRange
        let primaryCodecs: String
        let supplementalCodecs: String?
        // Hoisted out of the codec branch below so downstream
        // diagnostics (HDCP-LEVEL tagging, the engine.start summary
        // line) can reference it for both codec paths. H.264 always
        // reports `.none` — no Dolby Vision on H.264 by spec.
        let dvVariant: DVVariant

        if isH264 {
            // H.264 path. Sample-entry tag is `avc1` (FFmpeg defaults
            // to "h264" which AVPlayer rejects). CODECS string per
            // RFC 6381: `avc1.<profile_idc><constraint_flags><level
            // _idc>` as six hex digits. We don't have the constraint
            // flags from codecpar (they live in the SPS bitstream),
            // so emit them as `00` — AVPlayer is forgiving here as
            // long as profile_idc and level_idc are sane. Falls back
            // to High @ L4.0 if codecpar didn't populate them.
            codecTagOverride = "avc1"
            videoRange = isHDRTransfer(codecpar) ? .pq : .sdr
            let profileIDC = Int(codecpar.pointee.profile)
            let levelIDC = Int(codecpar.pointee.level)
            let safeProfile = profileIDC > 0 ? profileIDC : 100  // High
            let safeLevel = levelIDC > 0 ? levelIDC : 40         // 4.0
            primaryCodecs = String(format: "avc1.%02X%02X%02X", safeProfile, 0, safeLevel)
            supplementalCodecs = nil
            dvVariant = .none
        } else if !dvModeAvailable {
            // HEVC source on a non-DV display path. Skip DV variant
            // detection entirely and emit plain HEVC with the source
            // transfer characteristic (PQ for DV / HDR10 / HDR10+
            // bases, HLG for HLG sources, SDR otherwise). AVPlayer's
            // automatic preferredDynamicRange=standard tone-mapping
            // handles the HDR→SDR conversion on the SDR panel that
            // Match Content's "off" state effectively locks us into.
            // This is the workaround for AVPlayer rejecting dvh1-
            // tagged assets with `-11868 'Cannot Open'` whenever the
            // user has Match Dynamic Range disabled in tvOS Settings.
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
            // HEVC path — walks through DV variant detection.
            let dvRecord = doviConfigRecord(from: codecpar)
            dvVariant = classifyDVVariant(dvRecord)

            // dv_level is the DV-internal level (1-13) from the dvcC /
            // dvvC config box; defaults to 6 (UHD HDR) when the source
            // didn't populate it. codecpar.level is HEVC's general_level
            // _idc, which Apple's CODECS string takes verbatim as
            // "L<value>" (e.g. 150 for L5.0). Falls back to 150 (UHD)
            // for the same reason.
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
            case .profile81:
                codecTagOverride = "dvh1"
                videoRange = .pq
                primaryCodecs = "dvh1.08.\(dvLevelStr)"
                supplementalCodecs = nil
            case .profile84:
                // P8.4 keeps the cross-player-compat form because the
                // base layer is HLG-HEVC and we don't have a P8.4 test
                // source. Sample-entry tag stays `hvc1`.
                codecTagOverride = "hvc1"
                videoRange = .hlg
                primaryCodecs = "hvc1.2.4.L\(hevcLevel).b0"
                supplementalCodecs = "dvh1.08.\(dvLevelStr)/db4h"
            case .profile7:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: 7, compatID: -1)
            case .profile82:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: 8, compatID: 2)
            case .unknown:
                let p = Int(dvRecord?.dv_profile ?? 0)
                let c = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 0)
                throw HLSVideoEngineError.unsupportedDVProfile(profile: p, compatID: c)
            case .none:
                // Phase-1 routing should keep non-DV out of this engine,
                // but be defensive: play as plain HEVC HDR10/HLG/SDR
                // with an explicit hvc1 tag so AVPlayer doesn't reject
                // the segment because the muxer picked hev1 by default.
                codecTagOverride = "hvc1"
                videoRange = isHDRTransfer(codecpar) ? .pq : .sdr
                primaryCodecs = "hvc1.2.4.L\(hevcLevel)"
                supplementalCodecs = nil
            }
        }
        let codecsString = primaryCodecs

        let resolution = (Int(codecpar.pointee.width), Int(codecpar.pointee.height))

        // 5. Pick the best audio stream and choose stream-copy vs the
        //    FLAC bridge (decode → S16 PCM → FLAC encode). TrueHD /
        //    DTS / DTS-HD MA always go through the bridge because
        //    they aren't legal in fMP4 to begin with. AAC / AC3 /
        //    EAC3 / FLAC / ALAC / MP3 / Opus first try a stream-copy
        //    path; if the mp4 muxer rejects them at header-write
        //    time (the common case is EAC3 from MKV without pre-
        //    parsed `dec3` extradata, which fails with -22 EINVAL),
        //    we rebuild the muxer with the FLAC bridge in the catch
        //    branch below.
        let audioStreamIndex = dem.audioStreamIndex
        var audioConfig: FMP4VideoMuxer.StreamConfig? = nil
        var audioHLSCodec: String? = nil
        var resolvedAudioStreamIndex: Int32 = -1
        var audioBridge: AudioBridge? = nil
        var audioStreamPtr: UnsafeMutablePointer<AVStream>? = nil
        if audioStreamIndex >= 0, let audioStream = dem.stream(at: audioStreamIndex) {
            audioStreamPtr = audioStream
            let audioCodecID = audioStream.pointee.codecpar.pointee.codec_id
            let compat = AudioCodecCompat.from(audioCodecID)
            if compat.requiresBridge {
                // TrueHD / DTS: decode + FLAC re-encode is the only
                // legal way into fMP4 for these.
                do {
                    let bridge = try AudioBridge(
                        srcCodecpar: audioStream.pointee.codecpar,
                        srcTimeBase: audioStream.pointee.time_base
                    )
                    if let cp = bridge.encoderCodecpar {
                        audioConfig = FMP4VideoMuxer.StreamConfig(
                            codecpar: cp,
                            timeBase: bridge.encoderTimeBase,
                            codecTagOverride: nil
                        )
                        audioHLSCodec = "fLaC"
                        resolvedAudioStreamIndex = audioStreamIndex
                        audioBridge = bridge
                        EngineLog.emit("[HLSVideoEngine] audio: codec=\(compat) (bridge required) → transcoding to FLAC")
                    }
                } catch {
                    EngineLog.emit("[HLSVideoEngine] audio bridge init failed (\(error)); video-only fragment")
                }
            } else if compat != .unsupported {
                audioConfig = FMP4VideoMuxer.StreamConfig(
                    codecpar: audioStream.pointee.codecpar,
                    timeBase: audioStream.pointee.time_base,
                    codecTagOverride: nil
                )
                audioHLSCodec = compat.hlsCodecsString
                resolvedAudioStreamIndex = audioStreamIndex
                EngineLog.emit("[HLSVideoEngine] audio: codec=\(compat) → muxing as `\(compat.hlsCodecsString)` (stream-copy)")
            } else {
                EngineLog.emit("[HLSVideoEngine] audio codec id=\(audioCodecID.rawValue) unsupported (no FFmpeg decoder?); video-only fragment")
            }
        }

        // Build the master-playlist CODECS string. AVPlayer reads
        // this at variant-info parse time and filters streams it
        // can't decode. Per RFC 6381: comma-separated, video first,
        // audio after when present.
        // `manifestCodecs` is recomputed after the muxer init below,
        // because that step might fall back to video-only and we'd
        // need to drop the audio half from CODECS to keep AVPlayer
        // from waiting on a track we won't actually emit.
        var manifestCodecs = audioHLSCodec.map { "\(codecsString),\($0)" } ?? codecsString

        // 6. Capture the init segment. A throwaway muxer is built per
        //    the resolved stream configs, its `avformat_write_header`
        //    produces the `ftyp`+`moov` bytes we'll serve as
        //    /init.mp4 throughout the session, and we then dispose
        //    the muxer. Each subsequent fragment is muxed by an
        //    independent fresh `FMP4VideoMuxer` instance — that's the
        //    stateless-fragment model that eliminates the cross-
        //    fragment DTS-monotonicity coupling. The captured init
        //    bytes bind the track IDs and codec configs every later
        //    fragment must reference; since the same `StreamConfig`
        //    drives every per-fragment muxer, libavformat picks the
        //    same track IDs and box layout deterministically.
        let videoConfig = FMP4VideoMuxer.StreamConfig(
            codecpar: codecpar,
            timeBase: videoTimeBase,
            codecTagOverride: codecTagOverride
        )
        // FFmpeg's mov muxer requires pre-parsed extradata for some
        // audio codecs (notably EAC3, where the dec3 box bytes have
        // to be derived from the bitstream). MKV sources sometimes
        // don't carry that extradata in CodecPrivate, so
        // avformat_write_header returns -22 (EINVAL) before any
        // packet has been read. The fallback chain is: stream-copy
        // first, FLAC bridge second (decode → S16 PCM → FLAC, which
        // always works because the encoder synthesises its own
        // codec-private from PCM input — loses Atmos JOC, but better
        // than silent video), video-only last.
        func captureInit(audio: FMP4VideoMuxer.StreamConfig?) throws -> Data {
            let m = try FMP4VideoMuxer(video: videoConfig, audio: audio)
            defer { m.close() }
            return try m.writeInitSegment()
        }
        let initSegmentData: Data
        var audioWasIncluded = audioConfig != nil
        do {
            initSegmentData = try captureInit(audio: audioConfig)
        } catch {
            if audioBridge == nil,
               audioConfig != nil,
               let audioStream = audioStreamPtr {
                EngineLog.emit("[HLSVideoEngine] muxer/header init failed with audio (\(error.localizedDescription)), retrying with FLAC bridge")
                do {
                    let bridge = try AudioBridge(
                        srcCodecpar: audioStream.pointee.codecpar,
                        srcTimeBase: audioStream.pointee.time_base
                    )
                    if let cp = bridge.encoderCodecpar {
                        let bridgedConfig = FMP4VideoMuxer.StreamConfig(
                            codecpar: cp,
                            timeBase: bridge.encoderTimeBase,
                            codecTagOverride: nil
                        )
                        initSegmentData = try captureInit(audio: bridgedConfig)
                        audioConfig = bridgedConfig
                        audioHLSCodec = "fLaC"
                        audioBridge = bridge
                        audioWasIncluded = true
                    } else {
                        throw error
                    }
                } catch {
                    EngineLog.emit("[HLSVideoEngine] FLAC bridge attempt also failed (\(error)), retrying video-only")
                    do {
                        initSegmentData = try captureInit(audio: nil)
                    } catch {
                        throw HLSVideoEngineError.muxerInit(underlying: error)
                    }
                    audioConfig = nil
                    audioHLSCodec = nil
                    resolvedAudioStreamIndex = -1
                    audioBridge = nil
                    audioWasIncluded = false
                }
            } else if audioConfig != nil {
                EngineLog.emit("[HLSVideoEngine] muxer/header init failed (\(error.localizedDescription)), retrying video-only")
                do {
                    initSegmentData = try captureInit(audio: nil)
                } catch {
                    throw HLSVideoEngineError.muxerInit(underlying: error)
                }
                audioConfig = nil
                audioHLSCodec = nil
                resolvedAudioStreamIndex = -1
                audioBridge = nil
                audioWasIncluded = false
            } else {
                throw HLSVideoEngineError.muxerInit(underlying: error)
            }
        }
        if !audioWasIncluded {
            manifestCodecs = codecsString
        } else if audioHLSCodec != nil {
            // Recompute in case the bridge fallback changed audioHLSCodec.
            manifestCodecs = "\(codecsString),\(audioHLSCodec!)"
        }

        // Frame rate for the FRAME-RATE attribute. AVRational from
        // `avg_frame_rate`; convert to Double, fall back nil when
        // the source didn't fill it (the master playlist will then
        // omit the attribute, which Apple's spec allows).
        let avgFR = videoStream.pointee.avg_frame_rate
        let frameRate: Double? = (avgFR.den > 0 && avgFR.num > 0)
            ? Double(avgFR.num) / Double(avgFR.den)
            : nil

        // HDCP level: Apple Tech Talk 501 ("Authoring 4K and HDR HLS
        // Streams") requires TYPE-1 (HDCP 2.2) for >1920x1080 HDR /
        // DV content. Sub-1080p SDR streams can omit it. For our
        // .native-route DV streams we always set it.
        let hdcpLevel: String? = (dvVariant != .none) ? "TYPE-1" : nil

        EngineLog.emit(
            "[HLSVideoEngine] prepared: codec=\(manifestCodecs)"
            + (supplementalCodecs.map { " supplemental=\($0)" } ?? "")
            + " resolution=\(resolution.0)x\(resolution.1) "
            + "fps=\(frameRate.map { String(format: "%.3f", $0) } ?? "nil") "
            + "range=\(videoRange.rawValue) DV=\(dvVariant) segments=\(plan.count) "
            + "duration=\(String(format: "%.1f", durationSeconds))s init=\(initSegmentData.count)B"
        )

        // The earlier full-buffer hex dump used to live here but ate
        // ~40 ring-buffer lines per session and pushed the much more
        // actionable `[FMP4VideoMuxer] init.mp4 …` box summary out of
        // the overlay's visible window before AVPlayer's eventual
        // failure landed. The summary answers the same structural
        // questions (sample-entry FourCC, hvcC / dvcC / dvvC presence)
        // in one line. If a future failure needs byte-level detail
        // again, the loopback port is still reachable from `aetherctl
        // <source>` + `curl /init.mp4 | xxd` on macOS, without
        // dominating the TestFlight overlay.

        // 7. Wire the provider, the server, and serve the URL.
        let prov = VideoSegmentProvider(
            demuxer: dem,
            videoStreamIndex: videoIndex,
            audioStreamIndex: resolvedAudioStreamIndex >= 0 ? resolvedAudioStreamIndex : nil,
            videoTimeBase: videoTimeBase,
            videoCodecID: codecpar.pointee.codec_id,
            videoConfig: videoConfig,
            audioConfig: audioConfig,
            audioBridge: audioBridge,
            initSegmentData: initSegmentData,
            segments: plan,
            codecsString: manifestCodecs,
            supplementalCodecs: supplementalCodecs,
            resolution: resolution,
            videoRange: videoRange,
            frameRate: frameRate,
            hdcpLevel: hdcpLevel
        )
        provider = prov

        let srv = HLSLocalServer(provider: prov)
        try srv.start()
        server = srv

        // Pick which playlist to hand AVPlayer. With Match Dynamic
        // Range enabled and a capable panel (dvModeAvailable=true),
        // the master playlist is the right entry point — AVPlayer
        // negotiates the HDMI HDR / DV handshake from the master's
        // CODECS / VIDEO-RANGE / HDCP-LEVEL attributes. With the
        // user-set "match" preference off, master-playlist routing
        // refuses to load the `dvh1`-tagged variant because tvOS
        // won't switch the panel. DrHurt's note on AetherEngine#2:
        // pointing AVPlayer at the media playlist directly skips
        // the variant selection and engages AVPlayer's automatic
        // tone-map to SDR, so DV / HDR sources play without the
        // -11868 'Cannot Open' rejection.
        let resolvedURL: URL?
        if dvModeAvailable {
            resolvedURL = srv.playlistURL
        } else {
            resolvedURL = srv.mediaPlaylistURL
        }
        guard let url = resolvedURL else {
            stop()
            throw HLSVideoEngineError.openFailed(reason: "server URL not ready")
        }
        EngineLog.emit("[HLSVideoEngine] serving on \(url.absoluteString) (dvModeAvailable=\(dvModeAvailable))")
        return url
    }

    public func stop() {
        server?.stop()
        server = nil
        provider?.close()
        provider = nil
        demuxer?.close()
        demuxer = nil
    }

    deinit {
        stop()
    }

    // MARK: - Segment planning

    /// Build a uniform-duration segment plan from the source's
    /// reported duration. Each segment is `targetSegmentDuration`
    /// seconds long except the last (which absorbs any remainder).
    /// The actual keyframe alignment happens at fragment-generation
    /// time in `VideoSegmentProvider.mediaSegment(at:)`: the demux
    /// loop seeks to the segment start, reads packets, and stops at
    /// the next IDR at-or-after the segment end. The fragment's
    /// `trun` durations in the moof reflect what was actually
    /// muxed, so the EXTINF / actual-duration mismatch is at most
    /// one GOP and AVPlayer adapts.
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

    /// Build a segment plan anchored at real keyframes from
    /// libavformat's index. Each segment boundary is a known IRAP
    /// position in the source, so the playlist's `EXTINF` time
    /// matches the fragment's `tfdt` exactly — no drift between
    /// "where AVPlayer maps a scrub" and "where the bytes actually
    /// play".
    ///
    /// Segments coalesce consecutive short GOPs to approximate the
    /// `targetSegmentDuration` (6 s). At 24 fps with 1 s GOPs that
    /// merges 6 GOPs into one segment; at 1 GOP every 5 s, one GOP
    /// per segment; at one IRAP every 12 s, the segment is 12 s
    /// long (still spec-legal — HLS `EXT-X-TARGETDURATION` will
    /// reflect the longest actual segment).
    ///
    /// The last keyframe in the list anchors the final segment,
    /// which extends to `sourceDurationSeconds`. Sources whose
    /// declared duration is slightly less than the last keyframe
    /// (off-by-one in MKV duration math) still produce a non-empty
    /// final segment.
    private func buildKeyframeSegmentPlan(
        keyframes: [Int64],
        videoTimeBase: AVRational,
        sourceDurationSeconds: Double
    ) -> [Segment] {
        guard keyframes.count >= 2 else { return [] }
        let tb = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        guard tb > 0 else { return [] }
        let target = Self.targetSegmentDuration

        // FFmpeg's index entries should arrive in DTS order from the
        // MKV Cues element, but defensively sort by timestamp so a
        // misordered cue table doesn't produce backward segment
        // boundaries.
        let sorted = keyframes.sorted()

        var plan: [Segment] = []
        plan.reserveCapacity(sorted.count)
        var i = 0
        while i < sorted.count {
            let segStartPts = sorted[i]
            let segStartSeconds = Double(segStartPts) * tb

            // Walk forward until either we cross the target duration
            // or we run out of keyframes. The first IRAP whose
            // distance from segStartPts exceeds `target` becomes the
            // segment end (and the next segment's start).
            var j = i + 1
            while j < sorted.count {
                let candidateSeconds = Double(sorted[j] - segStartPts) * tb
                if candidateSeconds >= target { break }
                j += 1
            }

            let segEndPts: Int64
            let segEndSeconds: Double
            if j < sorted.count {
                segEndPts = sorted[j]
                segEndSeconds = Double(segEndPts) * tb
            } else {
                // Last segment runs to end-of-file. Compute endPts
                // from declared duration even if the demuxer's
                // duration is slightly past the last keyframe; the
                // muxer will simply read until EOF or until packets
                // run dry.
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
        }

        return plan
    }

    // MARK: - DV / HDR detection

    /// Look up FFmpeg's `AV_PKT_DATA_DOVI_CONF` side data on the
    /// codec parameters. Mirrors `VideoDecoder.swift`, intentionally
    /// duplicated rather than refactored shared so the two paths
    /// stay independently maintainable.
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

    /// Classify the source's Dolby Vision variant from the parsed
    /// configuration record. P8.6 is normalised to P8.1 per
    /// DrHurt's note: "P8.6 is not a valid profile (but should still
    /// play if treated as 8.1)".
    private func classifyDVVariant(_ record: AVDOVIDecoderConfigurationRecord?) -> DVVariant {
        guard let r = record else { return .none }
        let profile = Int(r.dv_profile)
        let compat = Int(r.dv_bl_signal_compatibility_id)

        if profile == 5 { return .profile5 }
        if profile == 7 { return .profile7 }
        if profile == 8 || profile == 9 || profile == 10 {
            switch compat {
            case 1: return .profile81
            case 2: return .profile82
            case 4: return .profile84
            default: return .profile81  // P8.6 etc → treat as P8.1
            }
        }
        return .unknown
    }

    // No `formatLevel` / `buildHEVCCodecsString` helpers: the
    // master-playlist CODECS attribute uses the bare 4cc (`dvh1` or
    // `hvc1`) per DrHurt's empirical KSPlayer testing
    // (AetherEngine#2). The dotted RFC 6381 form (`dvh1.05.06`) is
    // spec-compliant but Apple TV's AVPlayer treats them as
    // equivalent at variant-info parse time, and the bare form
    // sidesteps any pickiness about exact level encoding.

    // MARK: - Segment plan model

    fileprivate struct Segment {
        let startPts: Int64
        let endPts: Int64
        let startSeconds: Double
        let durationSeconds: Double
    }
}

// MARK: - Lazy segment provider

/// `HLSSegmentProvider` impl that generates each fMP4 fragment on
/// demand the first time AVPlayer GETs `seg{N}.mp4`. Holds the
/// session's demuxer behind a serial lock; concurrent fetches block
/// each other instead of racing the demuxer.
///
/// Each fragment is muxed by a fresh `FMP4VideoMuxer` instance via
/// `writeFragmentStateless`. The provider never holds a long-lived
/// muxer — the session's init.mp4 was captured once at session start
/// and is served byte-identical to every AVPlayer request, while each
/// media-segment fragment carries the absolute `tfdt` that lets
/// AVPlayer position it on the timeline independent of fragment
/// order. This removes the cross-fragment DTS-monotonicity coupling
/// that the long-lived-muxer model imposed and that didn't survive
/// imperfect IRAP boundary detection.
private final class VideoSegmentProvider: HLSSegmentProvider {

    private let demuxer: Demuxer
    private let videoStreamIndex: Int32
    private let audioStreamIndex: Int32?
    private let videoTimeBase: AVRational
    /// Codec ID for the video stream — used by the random-access-point
    /// detection in `mediaSegment` to pick the right NAL-type table
    /// (HEVC vs H.264). Stored at session start so the per-packet
    /// parse doesn't have to re-walk the demuxer's stream list.
    private let videoCodecID: AVCodecID
    /// Stream configs reused for every per-fragment fresh muxer.
    /// Same configs → identical track IDs + codec configs → moof +
    /// mdat fragments stay binary-compatible with the session-wide
    /// init.mp4 served to AVPlayer.
    private let videoConfig: FMP4VideoMuxer.StreamConfig
    private let audioConfig: FMP4VideoMuxer.StreamConfig?
    /// Per-session decode → S16 PCM → FLAC encoder. Stays long-lived
    /// so its FLAC stream timestamps stay continuous across fragments;
    /// `startSegment()` drains the FIFO and rearms PTS rebase at the
    /// start of each `mediaSegment(at:)` call.
    private let audioBridge: AudioBridge?

    private let initSegmentData: Data
    private let segments: [HLSVideoEngine.Segment]

    private let codecsString: String
    private let supplementalCodecsString: String?
    private let resolution: (Int, Int)
    private let videoRange: HLSVideoRange
    private let frameRate: Double?
    private let hdcpLevel: String?

    private let lock = NSLock()
    private var isClosed = false

    /// LRU cache of generated segment bytes, keyed by segment
    /// index. Cache hits serve immediately without touching the
    /// demuxer / muxer / audio bridge — the dominant cost in our
    /// pipeline. Sized to ~30 entries which at typical Cars 4K DV
    /// bitrate (~14 MB / 6 s) caps at ~420 MB resident — fine on
    /// Apple TV's RAM budget — and covers the common scrub
    /// patterns: AVPlayer's same-segment double-fetch, the user
    /// scrubbing back into a span they just played, and the
    /// forward buffer's overlap with the next playback range.
    private static let segmentCacheCapacity = 30
    /// Cached fragment payloads. Eviction uses `cacheOrder` to
    /// pop the least-recently-used entry. NSCache would be
    /// tempting but it's GC-aware and may evict aggressively
    /// under memory pressure; a hand-rolled LRU keeps the cap
    /// strict and the residency predictable.
    private var segmentCache: [Int: Data] = [:]
    /// Most-recent-last access order. Mutated on every hit and
    /// every store; eviction pops the front when the cache
    /// exceeds capacity.
    private var cacheOrder: [Int] = []

    init(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32?,
        videoTimeBase: AVRational,
        videoCodecID: AVCodecID,
        videoConfig: FMP4VideoMuxer.StreamConfig,
        audioConfig: FMP4VideoMuxer.StreamConfig?,
        audioBridge: AudioBridge?,
        initSegmentData: Data,
        segments: [HLSVideoEngine.Segment],
        codecsString: String,
        supplementalCodecs: String?,
        resolution: (Int, Int),
        videoRange: HLSVideoRange,
        frameRate: Double?,
        hdcpLevel: String?
    ) {
        self.demuxer = demuxer
        self.videoStreamIndex = videoStreamIndex
        self.audioStreamIndex = audioStreamIndex
        self.videoTimeBase = videoTimeBase
        self.videoCodecID = videoCodecID
        self.videoConfig = videoConfig
        self.audioConfig = audioConfig
        self.audioBridge = audioBridge
        self.initSegmentData = initSegmentData
        self.segments = segments
        self.codecsString = codecsString
        self.supplementalCodecsString = supplementalCodecs
        self.resolution = resolution
        self.videoRange = videoRange
        self.frameRate = frameRate
        self.hdcpLevel = hdcpLevel
    }

    func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        audioBridge?.close()
        segmentCache.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    // MARK: - HLSSegmentProvider

    func initSegment() -> Data? {
        // Re-emit the box summary at fetch time too: the one written
        // at writeInitSegment lands at session start, ~50 ring-buffer
        // lines before AVPlayer's eventual parse failure, where it
        // rolls out of the overlay's visible window. Re-emitting here
        // places the same line right before the bytes go on the wire,
        // so the overlay screenshot at failure time still shows it.
        FMP4VideoMuxer.logInitSegmentBoxSummary(initSegmentData)
        return initSegmentData
    }

    func mediaSegment(at index: Int) -> Data? {
        guard index >= 0, index < segments.count else { return nil }
        let seg = segments[index]

        // Short request ID for log correlation. Console.app filter on
        // `req=` lines up seek / IDR-search / mux / cache events from
        // one AVPlayer GET into one timeline.
        let req = String(UUID().uuidString.prefix(8))

        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return nil }

        let totalStart = DispatchTime.now()

        // Cache fast path. AVPlayer re-fetches segments on scrub-back
        // patterns and during prefetch; cached fragments skip the
        // whole demux + mux pipeline.
        if let cached = segmentCache[index] {
            cacheOrder.removeAll(where: { $0 == index })
            cacheOrder.append(index)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - totalStart.uptimeNanoseconds) / 1_000_000
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index) req=\(req): CACHE HIT \(cached.count) B (lookup=\(String(format: "%.1f", elapsed))ms)",
                category: .session
            )
            return cached
        }

        // Seek the demuxer to this segment's start. Demuxer.seek
        // expects seconds; it converts to AV_TIME_BASE internally
        // and lands on the MKV cue ≤ target.
        let seekStart = DispatchTime.now()
        demuxer.seek(to: seg.startSeconds)
        let seekMs = Double(DispatchTime.now().uptimeNanoseconds - seekStart.uptimeNanoseconds) / 1_000_000

        // Reset the audio bridge's per-fragment state: drains its
        // FIFO leftover and arms the encoder PTS rebase so the next
        // decoded source frame's pts becomes the FLAC stream base
        // for this fragment. Without this, FLAC packet timestamps
        // accumulate from the encoder's first-ever sample and drift
        // out of alignment with video as fragments march on.
        audioBridge?.startSegment()

        // Collected packets owned by us — each is `av_packet_clone`d
        // so its data buffer is refcounted independently of the
        // demuxer's internal lifetime. Freed in the defer below,
        // including the failure path.
        var collectedVideo: [UnsafeMutablePointer<AVPacket>] = []
        var collectedAudio: [UnsafeMutablePointer<AVPacket>] = []
        defer {
            for p in collectedVideo {
                var ptr: UnsafeMutablePointer<AVPacket>? = p
                av_packet_free(&ptr)
            }
            for p in collectedAudio {
                var ptr: UnsafeMutablePointer<AVPacket>? = p
                av_packet_free(&ptr)
            }
        }

        let readStart = DispatchTime.now()
        // Wall-clock deadline for the read loop. A 6 s target segment
        // generally finishes in 200-600 ms on Apple TV against a
        // local Jellyfin server; 15 s gives ~25x headroom for slow
        // links and long GOPs while capping the worst case where a
        // pathological source pins the provider lock.
        let segmentReadDeadlineNs = DispatchTime.now().uptimeNanoseconds + UInt64(15_000_000_000)

        var foundSegmentStart = false
        // PTS of the IRAP we accepted as this segment's first sample.
        // Used to filter out RADL leading pictures (HEVC NAL types 6/7,
        // "Random Access Decodable Leading") that the source emits
        // AFTER the IRAP in decode order but whose display PTS lies
        // BEFORE the IRAP. They reference the IRAP and decode fine,
        // but in a random-access segment they would produce frames
        // displayed in the previous segment's timeline range — and the
        // mp4 muxer rejects them because their PTS steps backward
        // from the IRAP's. Skipping them is semantically correct: at
        // a random-access boundary, the first displayable frame is
        // the IRAP itself.
        var segmentStartPTS: Int64 = Int64.min
        // After a seek, libavformat returns packets starting from
        // the last keyframe at-or-before the requested time (the
        // decoder needs reference frames before the seek target).
        // Skip everything until the first IRAP at-or-after
        // `seg.startPts`, so the fragment's first sample is a sync
        // sample and AVPlayer can decode from it cold.
        do {
            while let packet = try demuxer.readPacket() {
                var pktPtr: UnsafeMutablePointer<AVPacket>? = packet
                defer { av_packet_free(&pktPtr) }

                let streamIdx = packet.pointee.stream_index

                if streamIdx == videoStreamIndex {
                    // RAP detection combines two signals:
                    //
                    // 1. NAL-payload parse (primary, authoritative):
                    //    walks the length-prefixed NAL units looking
                    //    for HEVC type 16-21 (IRAP) or H.264 type 5
                    //    (IDR). Pure function of the bitstream.
                    // 2. `AV_PKT_FLAG_KEY` (secondary, sequential-
                    //    only): the MKV demuxer marks RAPs with KEY,
                    //    reliable in sequential reads but artificially
                    //    set on the first post-seek packet. We exclude
                    //    that one by gating on `!collectedVideo.isEmpty`
                    //    — index 0 is post-seek (unreliable), 1+ are
                    //    sequential (reliable).
                    //
                    // Combination catches IRAPs whose NAL layout
                    // confuses the length-prefix walker (some HEVC
                    // streams pack SEI / AUD orderings the parser
                    // doesn't unwind), while the post-seek artifact
                    // is still excluded.
                    let isRAP_nal = Self.packetContainsRandomAccessPoint(
                        packet, codecID: videoCodecID
                    )
                    let isRAP_flag = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                    let isSequentialRead = !collectedVideo.isEmpty
                    let isRAP = isRAP_nal || (isSequentialRead && isRAP_flag)

                    if !foundSegmentStart {
                        if isRAP,
                           packet.pointee.pts != Int64.min,
                           packet.pointee.pts >= seg.startPts {
                            foundSegmentStart = true
                            segmentStartPTS = packet.pointee.pts
                            // Fall through and collect this IRAP as
                            // the fragment's first sample.
                        } else {
                            continue
                        }
                    } else if packet.pointee.pts != Int64.min,
                              packet.pointee.pts < segmentStartPTS {
                        // RADL leading picture filter — see segmentStartPTS
                        // comment above. These frames display before the
                        // IRAP we accepted, so they have no place in this
                        // segment's timeline.
                        continue
                    }
                    // Stop reading at the next IRAP at-or-after the
                    // segment's nominal end so each fragment cuts at
                    // a GOP boundary. Without this, fragments would
                    // share GOPs and decoders would struggle to
                    // start cold on the second one.
                    if !collectedVideo.isEmpty,
                       packet.pointee.pts != Int64.min,
                       packet.pointee.pts >= seg.endPts,
                       isRAP {
                        break
                    }
                    // Normalise AV_PKT_FLAG_KEY to match our RAP
                    // verdict. The mp4 muxer reads `packet.flags`
                    // to populate the fragment's sample-dependency
                    // table; a fragment whose first sample doesn't
                    // claim KEY is structurally unplayable for
                    // AVPlayer ("audio plays, video frozen").
                    if isRAP {
                        packet.pointee.flags |= AV_PKT_FLAG_KEY
                    } else {
                        packet.pointee.flags &= ~AV_PKT_FLAG_KEY
                    }
                    if let cloned = av_packet_clone(packet) {
                        collectedVideo.append(cloned)
                    }
                } else if let aIdx = audioStreamIndex,
                          streamIdx == aIdx,
                          foundSegmentStart {
                    // Audio packets before the segment's first video
                    // IRAP are dropped; without a video frame to
                    // anchor them they'd play earlier than the
                    // fragment claims to start.
                    if let bridge = audioBridge {
                        // Decode source codec → S16 PCM → FLAC.
                        // `bridge.feed` transfers ownership of the
                        // returned AVPacket pointers to us; they
                        // flow into the collected-audio buffer and
                        // are freed by the defer above.
                        let flacPackets = try bridge.feed(packet: packet)
                        collectedAudio.append(contentsOf: flacPackets)
                    } else if let cloned = av_packet_clone(packet) {
                        collectedAudio.append(cloned)
                    }
                }
                // Other streams (additional audio tracks, subtitles,
                // attachments) are silently dropped.

                // Safety bound #1: packet count (~30 s of source at
                // typical 24-60 fps mixes). Pathological sources
                // without mid-stream keyframes would otherwise gobble
                // the whole file.
                if collectedVideo.count + collectedAudio.count > 3600 {
                    EngineLog.emit(
                        "[HLSVideoEngine] seg\(index) req=\(req) BOUND packet-count v=\(collectedVideo.count) a=\(collectedAudio.count), giving up on next-IDR boundary",
                        category: .session
                    )
                    break
                }
                // Safety bound #2: wall-clock deadline. Caps
                // pathological slow-HTTP cases that stay well under
                // the packet-count limit.
                if DispatchTime.now().uptimeNanoseconds > segmentReadDeadlineNs {
                    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - readStart.uptimeNanoseconds) / 1_000_000
                    EngineLog.emit(
                        "[HLSVideoEngine] seg\(index) req=\(req) BOUND wall-clock \(String(format: "%.0f", elapsedMs))ms v=\(collectedVideo.count) a=\(collectedAudio.count), emitting partial fragment",
                        category: .session
                    )
                    break
                }
            }
            let readMs = Double(DispatchTime.now().uptimeNanoseconds - readStart.uptimeNanoseconds) / 1_000_000

            // Stateless mux: fresh FMP4VideoMuxer per fragment, no
            // cross-fragment DTS-monotonicity state. The session's
            // init.mp4 was captured once at session start; this
            // call only returns moof+mdat bytes. See
            // `FMP4VideoMuxer.writeFragmentStateless` for the
            // architectural rationale.
            let muxStart = DispatchTime.now()
            let bytes = try FMP4VideoMuxer.writeFragmentStateless(
                video: videoConfig,
                audio: audioConfig,
                videoPackets: collectedVideo,
                audioPackets: collectedAudio
            )
            let muxMs = Double(DispatchTime.now().uptimeNanoseconds - muxStart.uptimeNanoseconds) / 1_000_000
            let totalMs = Double(DispatchTime.now().uptimeNanoseconds - totalStart.uptimeNanoseconds) / 1_000_000

            EngineLog.emit(
                "[HLSVideoEngine] seg\(index) req=\(req): v=\(collectedVideo.count) a=\(collectedAudio.count) → \(bytes.count) B " +
                "(start=\(String(format: "%.2f", seg.startSeconds))s dur=\(String(format: "%.2f", seg.durationSeconds))s) " +
                "timing: seek=\(String(format: "%.1f", seekMs))ms read=\(String(format: "%.1f", readMs))ms mux=\(String(format: "%.1f", muxMs))ms total=\(String(format: "%.1f", totalMs))ms",
                category: .session
            )
            storeInCache(index: index, bytes: bytes)
            return bytes
        } catch {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index) req=\(req) generation failed: \(error)",
                category: .session
            )
            return nil
        }
    }

    /// Stash the freshly-generated segment in the LRU cache.
    /// Evicts the least-recently-used entry when the cache exceeds
    /// `segmentCacheCapacity`. Caller must hold `lock`.
    private func storeInCache(index: Int, bytes: Data) {
        if segmentCache[index] != nil {
            cacheOrder.removeAll(where: { $0 == index })
        }
        segmentCache[index] = bytes
        cacheOrder.append(index)
        while cacheOrder.count > Self.segmentCacheCapacity {
            let oldest = cacheOrder.removeFirst()
            segmentCache.removeValue(forKey: oldest)
        }
    }

    var segmentCount: Int { segments.count }

    func segmentDuration(at index: Int) -> Double {
        guard index >= 0, index < segments.count else { return 0 }
        return segments[index].durationSeconds
    }

    var playlistType: HLSPlaylistType { .vod }
    // Master playlist accessors. P5 / P8.1 use bare `dvh1.05.<dvLevel>`
    // / `dvh1.08.<dvLevel>` in CODECS with no SUPPLEMENTAL-CODECS;
    // P8.4 keeps the cross-player-compat `hvc1.2.4.L<hev>.b0` +
    // SUPPLEMENTAL=`dvh1.08.<dvLevel>/db4h` form because its base
    // layer is HLG-HEVC. The master also carries AVERAGE-BANDWIDTH,
    // FRAME-RATE, RESOLUTION, VIDEO-RANGE, HDCP-LEVEL=TYPE-1 (for
    // 4K HDR per Apple Tech Talk 501) and CLOSED-CAPTIONS=NONE.
    // Confirmed by ZeroQ-bit's empirical A/B against the Dolby Browser
    // Test Kit source MP4s on tvOS AVPlayer (issue #2): bare `dvh1`
    // is what AVPlayer wants for P8.1, the spec-canonical
    // `hvc1.2.4.LXXX` + SUPPLEMENTAL form is parse-rejected before
    // init.mp4 fetch.
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

    /// Detect a random-access point by walking the packet's NAL
    /// payload, used in place of `AV_PKT_FLAG_KEY` because the MKV
    /// demuxer sets that flag inconsistently between sequential
    /// reads and post-seek reads (the first packet returned after
    /// `av_seek_frame` is artificially marked as a keyframe even
    /// when sequential reads of the same packet didn't see the
    /// flag). NAL payload bytes are identical in either context,
    /// so the parse returns a stable answer for the same source
    /// packet regardless of where the demuxer's cursor was.
    ///
    /// Random-access NAL unit types:
    ///   - HEVC (per ITU-T H.265 Annex 7.4.2.2 table 7-1):
    ///       16 = BLA_W_LP
    ///       17 = BLA_W_RADL
    ///       18 = BLA_N_LP
    ///       19 = IDR_W_RADL
    ///       20 = IDR_N_LP
    ///       21 = CRA_NUT
    ///     NAL header is 2 bytes; type lives in bits 1-6 of byte 0
    ///     (`(byte0 >> 1) & 0x3F`).
    ///   - H.264 (per ITU-T H.264 7.4.1 table 7-1):
    ///       5 = IDR slice
    ///     NAL header is 1 byte; type lives in bits 0-4 of byte 0
    ///     (`byte0 & 0x1F`).
    ///
    /// MKV and mp4 both frame NALs with a 4-byte big-endian length
    /// prefix in front of each unit, not Annex-B start codes. This
    /// matches the existing length-prefix walker in
    /// `VideoDecoder.extractHDR10PlusBytesFromHEVCBitstream`.
    ///
    /// A keyframe packet typically contains the parameter sets
    /// before the IDR (HEVC: VPS+SPS+PPS+IDR; H.264: SPS+PPS+IDR),
    /// so the scan walks every NAL and returns on the first RAP.
    fileprivate static func packetContainsRandomAccessPoint(
        _ packet: UnsafeMutablePointer<AVPacket>,
        codecID: AVCodecID
    ) -> Bool {
        guard let data = packet.pointee.data else { return false }
        let size = Int(packet.pointee.size)
        let isHEVC = codecID == AV_CODEC_ID_HEVC
        let isH264 = codecID == AV_CODEC_ID_H264
        guard isHEVC || isH264, size >= 5 else { return false }

        var offset = 0
        while offset + 4 <= size {
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1])
            let b2 = UInt32(data[offset + 2])
            let b3 = UInt32(data[offset + 3])
            let nalLen = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            offset += 4
            // Defensive bounds: an invalid length prefix (e.g. a
            // pathological / corrupt packet) shouldn't crash the
            // engine. Treat as "no RAP detected" and let the
            // surrounding loop continue on `AV_PKT_FLAG_KEY` or
            // the packet's natural failure path.
            guard nalLen > 0, offset + nalLen <= size, offset < size else {
                return false
            }
            let header0 = data[offset]
            if isHEVC {
                let nalType = (header0 >> 1) & 0x3F
                if nalType >= 16 && nalType <= 21 { return true }
            } else { // H.264
                let nalType = header0 & 0x1F
                if nalType == 5 { return true }
            }
            offset += nalLen
        }
        return false
    }
}

/// `AV_PKT_FLAG_KEY` is `1 << 0` per FFmpeg's `packet.h` (and a C
/// macro Swift can't import directly). Aliased here so callers don't
/// have to re-derive the bit.
private let AV_PKT_FLAG_KEY_VALUE: Int32 = 0x0001

private extension Data {
    /// Render bytes as an `xxd`-style hex dump: 16 bytes per row,
    /// offset on the left, hex pairs in the middle, ASCII column
    /// on the right. Designed for diagnostic-overlay log output;
    /// non-printable bytes show as `.` in the ASCII column. Caller
    /// is responsible for capping size before calling, this dumps
    /// every byte of `self`.
    func hexDump() -> String {
        var result = ""
        var offset = 0
        for chunk in self.chunked(by: 16) {
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 16 * 3 - 1, withPad: " ", startingAt: 0)
            let ascii = chunk.map { (b: UInt8) -> Character in
                (b >= 0x20 && b < 0x7f) ? Character(UnicodeScalar(b)) : "."
            }
            result += String(format: "%04x  %@  %@\n", offset, padded, String(ascii))
            offset += chunk.count
        }
        return result
    }

    func chunked(by size: Int) -> [Data] {
        stride(from: 0, to: count, by: size).map { i in
            self.subdata(in: i..<Swift.min(i + size, count))
        }
    }
}
