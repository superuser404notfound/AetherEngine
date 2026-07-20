import Foundation
import Libavformat
import Libavcodec
import Libavutil

extension HLSVideoEngine {

    /// Audio codec routing: stream-copy (fMP4-legal, preserves Atmos/DTS-HD) vs AudioBridge (decode->S16 PCM->FLAC for non-fMP4-legal codecs; TrueHD-MAT Atmos object metadata lost in PCM intermediate).
    enum AudioCodecCompat {
        case aac, ac3, eac3, flac, alac, mp3, opus
        case truehd, dts
        case vorbis, pcm, mp2
        /// LATM/LOAS-framed AAC (DVB-T2/IPTV, typically HE-AAC); no ADTS headers, no ASC in extradata, always bridges via aac_latm decoder.
        case aacLatm
        case unsupported

        static func from(_ codecID: AVCodecID) -> AudioCodecCompat {
            switch codecID {
            case AV_CODEC_ID_AAC:    return .aac
            case AV_CODEC_ID_AAC_LATM: return .aacLatm
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

        /// CODECS attribute for the master playlist. Empty for bridged codecs (engine computes `fLaC` from the encoded stream).
        var hlsCodecsString: String {
            switch self {
            case .aac:    return "mp4a.40.2"
            case .ac3:    return "ac-3"
            case .eac3:   return "ec-3"
            case .flac:   return "fLaC"
            case .alac:   return "alac"
            case .mp3, .opus, .truehd, .dts, .vorbis, .pcm, .mp2, .aacLatm, .unsupported:
                // mp3: theoretically mp4a.40.34, but AVPlayer treats any mp4a as AAC and fails; bridge to FLAC.
                return ""
            }
        }

        /// Codecs that must go through AudioBridge. Opus is fMP4-spec-legal but AVPlayer rejects it in HLS-fMP4 in practice (only CAF/WebM paths work). MP3 writes `mp4a.40.34` but AVPlayer treats any mp4a as AAC, failing with -11829/-12848.
        var requiresBridge: Bool {
            switch self {
            case .opus, .mp3, .truehd, .dts, .vorbis, .pcm, .mp2, .aacLatm: return true
            default: return false
            }
        }
    }

    /// #165: ordered bridge-encoder cascade. The configured mode is attempted first; if its encoder is
    /// absent from the FFmpeg build (`AudioBridgeError.encoderNotFound`), fall through to the other mode's
    /// encoder rather than dropping to silent video-only. Both modes decode everywhere on Apple devices
    /// (EAC3 -> HDMI bitstream, FLAC -> LPCM), so either is a valid rescue; the only loss is the configured
    /// mode's channel/quality trade-off. Deterministic and a full permutation (each mode appears once).
    static func bridgeModeCascade(configured: AudioBridgeMode) -> [AudioBridgeMode] {
        switch configured {
        case .surroundCompat: return [.surroundCompat, .lossless]
        case .lossless:       return [.lossless, .surroundCompat]
        }
    }

    /// Guards `audioSourceStreamIndexOverride` against stale picker selections from a previous title.
    static func isAudioStream(demuxer: Demuxer, index: Int32) -> Bool {
        guard index >= 0, let stream = demuxer.stream(at: index) else {
            return false
        }
        return stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
    }

    /// Audio routing cascade: stream-copy -> configured bridge mode -> alternate bridge mode (when the
    /// configured encoder is absent from the build, #165) -> video-only. Covers EAC3-from-MKV where codecpar
    /// lacks the `dec3` extradata the mp4 muxer needs to write the audio sample-entry.
    func buildProducerWithAudioCascade(
        preferBridge: Bool,
        streamCopyAudio: HLSSegmentProducer.AudioConfig?,
        sourceAudioStreamIndex: Int32,
        sourceAudioStream: UnsafeMutablePointer<AVStream>?,
        audioHLSCodecs: inout String?
    ) throws -> HLSSegmentProducer {
        // EAC3 profile=30 is the JOC marker; any stream-copy->FLAC fallback silently loses Atmos object metadata.
        let sourceIsAtmos: Bool = {
            guard let stream = sourceAudioStream else { return false }
            return stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_EAC3
                && stream.pointee.codecpar.pointee.profile == 30
        }()

        let sourceCodecLabel: String = {  // falls back to "audio" for codecs with no libavcodec name entry
            if let stream = sourceAudioStream,
               let cstr = avcodec_get_name(stream.pointee.codecpar.pointee.codec_id) {
                return String(cString: cstr).uppercased()
            }
            return "audio"
        }()

        if !preferBridge, let cfg = streamCopyAudio, let vcfg = savedVideoConfig {
            // Pre-flight avformat_write_header: makeProducer is lazy (muxer alloc on first keep-packet), so a
            // failure there (EAC3-from-MKV, missing dec3 extradata, -22 "Cannot write moov atom before EAC3
            // packets parsed") would leave the producer stuck with the bridge fallback unreachable.
            let probeVideo = MP4SegmentMuxer.VideoConfig(
                codecpar: vcfg.codecpar,
                timeBase: vcfg.timeBase,
                codecTagOverride: vcfg.codecTagOverride,
                stripDolbyVisionMetadata: vcfg.stripDolbyVisionMetadata,
                colorOverride: vcfg.colorOverride,
                extradataOverride: vcfg.extradataOverride
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
                        "[HLSVideoEngine] WARNING: Atmos downgrade, EAC3+JOC stream-copy probe rejected by mp4 muxer (ret=\(probeRet)). "
                        + "Falling back to FLAC bridge: bed channels stay lossless, but object metadata is lost. "
                        + "Source: \(sourceAudioStream?.pointee.codecpar.pointee.profile.description ?? "?") profile, "
                        + "channels=\(sourceAudioStream?.pointee.codecpar.pointee.ch_layout.nb_channels ?? -1). "
                        + "If you see this in production, capture the source MKV, dec3 extradata reconstruction can recover Atmos.",
                        category: .session
                    )
                } else {
                    EngineLog.emit(
                        "[HLSVideoEngine] audio stream-copy probe failed (ret=\(probeRet)), retrying with FLAC bridge",
                        category: .session
                    )
                }
            } else {
                self.savedAudioConfig = cfg
                do {
                    let prod = try makeProducer(baseIndex: initialProducerBaseIndex)
                    if sourceIsAtmos {
                        EngineLog.emit(
                            "[HLSVideoEngine] EAC3+JOC Atmos: stream-copy engaged; DD+/JOC bitstream "
                            + "preserved for the downstream renderer (HDMI passthrough / AirPods spatial; "
                            + "plain Bluetooth A2DP / LE downmixes natively)",
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
                }
            }
        } else if preferBridge && sourceIsAtmos {
            // EAC3+JOC always stream-copies; a pre-bridge decision is a codec-table bug.
            EngineLog.emit(
                "[HLSVideoEngine] WARNING: Atmos source pre-routed to FLAC bridge without stream-copy attempt, Atmos lost. Investigate the codec compatibility table.",
                category: .session
            )
        }

        if let audioStream = sourceAudioStream, sourceAudioStreamIndex >= 0 {
            // #165: cascade across bridge modes. The configured mode's encoder can be absent from the
            // FFmpeg build (custom builds without --enable-encoder=eac3); AudioBridge.init then throws
            // .encoderNotFound. Rather than dropping to silent video-only after one attempt, try the other
            // mode's encoder. Only encoder-absence cascades (retrying a different encoder can help); every
            // other init failure is source-specific and re-attempting is pointless, so it stops immediately.
            let cascade = Self.bridgeModeCascade(configured: audioBridgeMode)
            attempts: for (attemptIndex, bridgeModeAttempt) in cascade.enumerated() {
                let isLastAttempt = attemptIndex == cascade.count - 1
                let bridge: AudioBridge
                do {
                    bridge = try AudioBridge(
                        srcCodecpar: audioStream.pointee.codecpar,
                        srcTimeBase: audioStream.pointee.time_base,
                        mode: bridgeModeAttempt
                    )
                } catch AudioBridge.AudioBridgeError.encoderNotFound where !isLastAttempt {
                    EngineLog.emit(
                        "[HLSVideoEngine] \(bridgeModeAttempt.rawValue) bridge encoder absent from this FFmpeg build, "
                        + "cascading to \(cascade[attemptIndex + 1].rawValue)",
                        category: .session
                    )
                    continue attempts
                } catch {
                    EngineLog.emit(
                        "[HLSVideoEngine] ERROR: AudioBridge init failed (\(error)), no working bridge encoder, "
                        + "falling back to SILENT video-only",
                        category: .session
                    )
                    break attempts
                }

                guard let cp = bridge.encoderCodecpar else {
                    bridge.close()
                    break attempts
                }
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
                    let prod = try makeProducer(baseIndex: initialProducerBaseIndex)
                    let (hlsCodec, pipelineLabel): (String, String)
                    switch bridgeModeAttempt {
                    case .surroundCompat:
                        hlsCodec = "ec-3"
                        pipelineLabel = "\(sourceCodecLabel) → EAC3 5.1 bridge"
                    case .lossless:
                        hlsCodec = "fLaC"
                        pipelineLabel = "\(sourceCodecLabel) → FLAC bridge"
                    }
                    audioHLSCodecs = hlsCodec
                    self.audioPipelineDescription = pipelineLabel
                    if bridgeModeAttempt != audioBridgeMode {
                        EngineLog.emit(
                            "[HLSVideoEngine] audio bridge cascaded \(audioBridgeMode.rawValue) → "
                            + "\(bridgeModeAttempt.rawValue) (configured encoder absent); \(pipelineLabel)",
                            category: .session
                        )
                    }
                    return prod
                } catch {
                    EngineLog.emit(
                        "[HLSVideoEngine] \(bridgeModeAttempt.rawValue) bridge header write failed (\(error)), falling back to video-only",
                        category: .session
                    )
                    self.savedAudioConfig = nil
                    self.audioBridge = nil
                    bridge.close()
                    break attempts
                }
            }
        }

        // Video-only fallback: illegal for demuxed-audio sessions (silent playback); fail and let the host fall back to server-muxed.
        if sideAudioDemuxer != nil {
            throw HLSVideoEngineError.openFailed(
                reason: "demuxed-audio companion present but no audio pipeline could be built")
        }
        self.savedAudioConfig = nil
        self.audioBridge = nil
        audioHLSCodecs = nil
        self.audioPipelineDescription = nil
        return try makeProducer(baseIndex: initialProducerBaseIndex)
    }
}
