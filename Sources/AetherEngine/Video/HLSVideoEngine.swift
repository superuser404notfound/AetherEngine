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
    private var demuxer: Demuxer?
    private var server: HLSLocalServer?
    private var provider: VideoSegmentProvider?

    /// Approximate target segment duration in seconds. Actual
    /// fragments may be slightly shorter or longer because we snap
    /// boundaries to source keyframes. 6 s matches Apple's HLS
    /// authoring recommendation.
    private static let targetSegmentDuration: Double = 6.0

    public init(url: URL) {
        self.sourceURL = url
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

        // 2. Build the segment plan. The original implementation read
        //    `avformat_index_get_entry` to enumerate every keyframe
        //    and snap segment boundaries to real keyframes but for
        //    MKV files served over HTTP byte-range, the cues are
        //    parsed lazily on first seek, not at
        //    `avformat_find_stream_info` time, so the index is
        //    always empty here and `noKeyframeIndex` (== Error 3)
        //    fired on every native session. DrHurt's build-115
        //    report.
        //
        //    Switch to uniform `targetSegmentDuration` segments
        //    keyed off the source's reported duration. The actual
        //    fragment cuts happen during `mediaSegment(at:)` where
        //    we read packets and stop on the next IDR keyframe at
        //    or after the segment's end-PTS, so the resulting
        //    fragments are still keyframe-aligned even though the
        //    plan doesn't know which keyframe in advance. The
        //    EXTINF in the manifest is the nominal duration, the
        //    `trun` durations in the moof reflect reality, and
        //    AVPlayer reads the moof's `trun` and adjusts its
        //    buffer math accordingly.
        let videoTimeBase = videoStream.pointee.time_base
        let durationSeconds = dem.duration
        guard durationSeconds > 0 else {
            throw HLSVideoEngineError.zeroDuration
        }
        let plan = buildUniformSegmentPlan(
            videoTimeBase: videoTimeBase,
            sourceDurationSeconds: durationSeconds
        )

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

        // 6. Build the per-session muxer, generate the init segment.
        //    The muxer is reused across every fragment in this
        //    session; segments may be requested out of order (seeks)
        //    but per ISO BMFF the `mfhd.sequence_number` is only a
        //    "recommended monotonic" hint, not load-bearing for
        //    AVPlayer playback.
        let videoConfig = FMP4VideoMuxer.StreamConfig(
            codecpar: codecpar,
            timeBase: videoTimeBase,
            codecTagOverride: codecTagOverride
        )
        // The muxer is built and the init segment is written in one
        // attempt with audio, then retried video-only if that throws.
        // Reason: FFmpeg's mov muxer requires pre-parsed extradata
        // for some audio codecs (notably EAC3, where the dec3 box
        // bytes have to be derived from the bitstream). MKV sources
        // sometimes don't carry that extradata in CodecPrivate, so
        // `avformat_write_header` returns -22 (EINVAL) before any
        // packet has been read. DrHurt's build with the latest
        // changes hit this for a P5 + EAC3 source. Falling back to a
        // video-only mux at least gets DV mode engaged on the TV
        // (with silent video) instead of dropping the whole .native
        // route and reverting to AetherEngine's HDR10 base output.
        // Helper that builds a muxer + writes its init segment.
        // Used twice in the fallback path: first with audio, then
        // (if that fails) without.
        func buildMuxerAndInit(audio: FMP4VideoMuxer.StreamConfig?) throws -> (FMP4VideoMuxer, Data) {
            let m = try FMP4VideoMuxer(video: videoConfig, audio: audio)
            do {
                let init_ = try m.writeInitSegment()
                return (m, init_)
            } catch {
                m.close()
                throw error
            }
        }
        let muxer: FMP4VideoMuxer
        let initSegmentData: Data
        var audioWasIncluded = audioConfig != nil
        do {
            (muxer, initSegmentData) = try buildMuxerAndInit(audio: audioConfig)
        } catch {
            // Stream-copy attempt failed. Try the FLAC bridge as a
            // second pass before giving up on audio entirely.
            // Typical trigger: EAC3 from MKV where the muxer can't
            // derive `dec3` box bytes without pre-parsed extradata.
            // DrHurt's build-118 P5+EAC3 hit this with `avformat_
            // write_header failed (-22)`. The FLAC bridge always
            // works because the encoder synthesises its own codec-
            // private from PCM input. Loses Atmos JOC metadata
            // because the spatial mix is decoded to multichannel
            // PCM before re-encoding, but better than silent video.
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
                        (muxer, initSegmentData) = try buildMuxerAndInit(audio: bridgedConfig)
                        audioConfig = bridgedConfig
                        audioHLSCodec = "fLaC"
                        audioBridge = bridge
                        audioWasIncluded = true
                    } else {
                        throw error
                    }
                } catch {
                    // Bridge attempt also failed. Fall back to video-only.
                    EngineLog.emit("[HLSVideoEngine] FLAC bridge attempt also failed (\(error)), retrying video-only")
                    do {
                        (muxer, initSegmentData) = try buildMuxerAndInit(audio: nil)
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
                // Bridge was already in use and failed at header
                // write, or audioStreamPtr is nil. Either way, fall
                // back to video-only.
                EngineLog.emit("[HLSVideoEngine] muxer/header init failed (\(error.localizedDescription)), retrying video-only")
                do {
                    (muxer, initSegmentData) = try buildMuxerAndInit(audio: nil)
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
            muxer: muxer,
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

        guard let url = srv.playlistURL else {
            stop()
            throw HLSVideoEngineError.openFailed(reason: "server URL not ready")
        }
        EngineLog.emit("[HLSVideoEngine] serving on \(url.absoluteString)")
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
/// session's demuxer + muxer behind a serial lock; concurrent
/// fetches block each other instead of racing the demuxer.
private final class VideoSegmentProvider: HLSSegmentProvider {

    private let demuxer: Demuxer
    private let videoStreamIndex: Int32
    private let audioStreamIndex: Int32?
    private let videoTimeBase: AVRational
    private let muxer: FMP4VideoMuxer
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

    init(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32?,
        videoTimeBase: AVRational,
        muxer: FMP4VideoMuxer,
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
        self.muxer = muxer
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
        muxer.close()
        audioBridge?.close()
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

        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return nil }

        // Seek to the start of this segment. Demuxer.seek expects
        // seconds (it converts to AV_TIME_BASE internally and uses
        // avformat_seek_file for MKV-safe seek behaviour).
        demuxer.seek(to: seg.startSeconds)

        // Reset the audio bridge's per-fragment state: drains its
        // FIFO leftover and arms the encoder-PTS rebase so the next
        // decoded source frame's pts becomes the FLAC stream base
        // for this fragment. Without this, FLAC packet timestamps
        // accumulate from the encoder's first-ever sample and drift
        // out of alignment with video as fragments march on.
        audioBridge?.startSegment()

        var videoCount = 0
        var audioCount = 0
        var didEnqueueAnyVideo = false
        // After a seek, libavformat returns packets starting from the
        // last keyframe at-or-before the requested time (standard
        // backward-seek behaviour, required so the decoder can rebuild
        // reference frames before the seek target). Re-feeding those
        // pre-target packets into the per-session mp4 muxer breaks
        // the per-stream monotonic-PTS invariant the muxer enforces:
        // the second `av_interleaved_write_frame` call returns -22
        // EINVAL because the new packet's PTS is lower than the
        // previous fragment's last-written PTS. Skip everything until
        // the first IDR at-or-after `seg.startPts`, so each fragment
        // is self-contained and timestamps stay monotonic across
        // fragments.
        var foundSegmentStart = false
        do {
            while let packet = try demuxer.readPacket() {
                var pktPtr: UnsafeMutablePointer<AVPacket>? = packet
                defer { av_packet_free(&pktPtr) }

                let streamIdx = packet.pointee.stream_index

                if streamIdx == videoStreamIndex {
                    let isKey = (packet.pointee.flags & AV_PKT_FLAG_KEY_VALUE) != 0
                    if !foundSegmentStart {
                        // Wait for the first IDR at-or-after the segment
                        // start. Skip pre-roll non-key packets and any
                        // keyframe that's still before the boundary
                        // (the seek can land us mid-GOP).
                        if isKey,
                           packet.pointee.pts != Int64.min,
                           packet.pointee.pts >= seg.startPts {
                            foundSegmentStart = true
                            // Fall through and emit this IDR as the
                            // segment's first sample.
                        } else {
                            continue
                        }
                    }
                    // Stop reading once we've passed this segment's
                    // end boundary, but only on a keyframe (otherwise
                    // we'd cut in the middle of a GOP and break the
                    // next segment's IDR alignment).
                    if didEnqueueAnyVideo,
                       packet.pointee.pts != Int64.min,
                       packet.pointee.pts >= seg.endPts,
                       isKey {
                        break
                    }
                    try muxer.writePacket(packet, toStreamIndex: muxer.videoOutputIndex)
                    didEnqueueAnyVideo = true
                    videoCount += 1
                } else if let aIdx = audioStreamIndex,
                          let aOutIdx = muxer.audioOutputIndex,
                          streamIdx == aIdx,
                          foundSegmentStart {
                    // Audio packets before the segment's first video
                    // IDR are dropped; without a video frame to anchor
                    // them they'd play earlier than the segment claims
                    // to start.
                    if let bridge = audioBridge {
                        // Decode source codec → S16 PCM → FLAC.
                        // bridge.feed returns [AVPacket*] with
                        // ownership transferred to us.
                        let flacPackets = try bridge.feed(packet: packet)
                        for fp in flacPackets {
                            do {
                                try muxer.writePacket(fp, toStreamIndex: aOutIdx)
                            } catch {
                                var pPtr: UnsafeMutablePointer<AVPacket>? = fp
                                av_packet_free(&pPtr)
                                throw error
                            }
                            var pPtr: UnsafeMutablePointer<AVPacket>? = fp
                            av_packet_free(&pPtr)
                            audioCount += 1
                        }
                    } else {
                        try muxer.writePacket(packet, toStreamIndex: aOutIdx)
                        audioCount += 1
                    }
                }
                // Other streams (additional audio tracks, subtitles,
                // attachments) are silently dropped. Audio-track
                // switching mid-session would require re-priming the
                // muxer and is a phase-7 concern.

                // Safety bound: never read more than ~30 s worth of
                // packets for one segment, regardless of where the
                // next keyframe is. Pathological sources without
                // mid-stream keyframes can otherwise gobble the
                // whole file.
                if videoCount + audioCount > 3600 { break }
            }
            let bytes = try muxer.flushFragment()
            EngineLog.emit("[HLSVideoEngine] seg\(index): v=\(videoCount) a=\(audioCount) → \(bytes.count) B (start=\(String(format: "%.2f", seg.startSeconds))s dur=\(String(format: "%.2f", seg.durationSeconds))s)")
            return bytes
        } catch {
            EngineLog.emit("[HLSVideoEngine] seg\(index) generation failed: \(error)")
            return nil
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
