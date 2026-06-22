import Foundation
import CoreVideo
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil

extension AetherEngine {

    // MARK: - Probe

    /// One-shot container + stream metadata read; no HLS server or decoders. Network sources pull a HEAD probe + small initial range (typically a few MB). File sources read directly via FFmpeg's file protocol.
    ///
    /// - Parameters:
    ///   - url: Media source (`file://`, `http://`, or `https://`).
    ///   - options: Forwarded for `httpHeaders` only; other flags ignored (no playback session).
    /// - Throws: Any error the demuxer raises during open / probe.
    public nonisolated static func probe(
        url: URL,
        options: LoadOptions = .init()
    ) throws -> SourceProbe {
        try probe(source: .url(url), options: options)
    }

    /// `probe(url:)` for a custom byte source (AetherEngine#27). Caller retains reader ownership; cursor is left at an unspecified position and `close()` is NOT called. Pass a fresh (or rewound) reader to `load(source:)` afterwards. `SourceProbe.url` is `aether-custom://source` for custom readers.
    public nonisolated static func probe(
        source: MediaSource,
        options: LoadOptions = .init()
    ) throws -> SourceProbe {
        let demuxer = Demuxer()
        let displayURL: URL
        switch source {
        case .url(let u):
            try demuxer.open(url: u, extraHeaders: options.httpHeaders)
            displayURL = u
        case .custom(let reader, let formatHint):
            try demuxer.open(reader: reader, formatHint: formatHint)
            displayURL = URL(string: "aether-custom://source")!
        }
        defer { demuxer.close() }
        return makeSourceProbe(demuxer: demuxer, displayURL: displayURL)
    }

    /// Assemble a `SourceProbe` from an open demuxer. Shared by static probe entry points and `load(source:)`'s internal probe stage so all report identical metadata.
    nonisolated static func makeSourceProbe(
        demuxer: Demuxer,
        displayURL: URL
    ) -> SourceProbe {
        var detectedFormat: VideoFormat = .sdr
        var detectedRate: Double? = nil
        var detectedCodecID: AVCodecID = AV_CODEC_ID_NONE
        var width: Int32 = 0
        var height: Int32 = 0
        let videoIdx = demuxer.videoStreamIndex
        if videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) {
            detectedFormat = Self.detectVideoFormat(stream: stream)
            detectedRate = Self.detectFrameRate(stream: stream)
            detectedCodecID = stream.pointee.codecpar.pointee.codec_id
            width = stream.pointee.codecpar.pointee.width
            height = stream.pointee.codecpar.pointee.height
        }
        let codecName: String? = {
            guard detectedCodecID != AV_CODEC_ID_NONE,
                  let cstr = avcodec_get_name(detectedCodecID) else { return nil }
            return String(cString: cstr)
        }()
        let snappedRate = detectedRate.flatMap { FrameRateSnap.snap($0) }
        let duration = demuxer.duration
        // Heuristic only: duration absent + network scheme. aether-custom:// never matches. Hosts decide the final LoadOptions.isLive.
        let liveSchemes: Set<String> = ["http", "https", "udp", "rtp", "rtsp"]
        let isLive = duration <= 0
            && liveSchemes.contains(displayURL.scheme?.lowercased() ?? "")

        return SourceProbe(
            url: displayURL,
            durationSeconds: duration,
            videoFormat: detectedFormat,
            videoCodecID: Int32(bitPattern: detectedCodecID.rawValue),
            videoCodecName: codecName,
            videoWidth: width,
            videoHeight: height,
            videoFrameRate: snappedRate,
            isDolbyVision: detectedFormat == .dolbyVision,
            audioTracks: demuxer.audioTrackInfos(),
            subtitleTracks: demuxer.subtitleTrackInfos(),
            metadata: demuxer.mediaMetadata(),
            isLive: isLive
        )
    }

    // MARK: - SW-decoder repro probe

    /// SW-decode repro for `aetherctl swdecode` (MPEG-4 Part 2, MPEG-2, VC-1, AV1 without HW). No render target. Discriminates: `openSucceeded == false` (missing libavcodec decoder / bad extradata), `framesDecoded == 0` (pixel-format conversion failure / all non-IDR), `framesDecoded > 0` (SW path healthy; downstream issue if real playback still hangs).
    public nonisolated static func swDecodeProbe(
        url: URL,
        maxPackets: Int = 100,
        options: LoadOptions = .init()
    ) throws -> SoftwareDecodeProbeResult {
        let demuxer = Demuxer()
        try demuxer.open(url: url, extraHeaders: options.httpHeaders)
        defer { demuxer.close() }

        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else {
            throw AetherEngineError.noVideoStream
        }

        let codecID = stream.pointee.codecpar.pointee.codec_id
        let codecName: String = {
            guard let cstr = avcodec_get_name(codecID) else { return "unknown" }
            return String(cString: cstr)
        }()
        let width = stream.pointee.codecpar.pointee.width
        let height = stream.pointee.codecpar.pointee.height

        let decoder = SoftwareVideoDecoder()
        // Class for captured-by-reference mutable accumulators; closure fires synchronously inside avcodec_send_packet / receive_frame.
        final class Accum {
            var framesDecoded = 0
            var firstFramePixelFormat: String?
            var firstFrameWidth: Int = 0
            var firstFrameHeight: Int = 0
        }
        let accum = Accum()

        do {
            try decoder.open(stream: stream) { pixelBuffer, _, _ in
                accum.framesDecoded += 1
                if accum.firstFramePixelFormat == nil {
                    let pfType = CVPixelBufferGetPixelFormatType(pixelBuffer)
                    let bytes: [UInt8] = [
                        UInt8((pfType >> 24) & 0xff),
                        UInt8((pfType >> 16) & 0xff),
                        UInt8((pfType >> 8) & 0xff),
                        UInt8(pfType & 0xff),
                    ]
                    let printable = bytes.map { ($0 >= 0x20 && $0 < 0x7f) ? $0 : 0x2e }
                    let fourCC = String(bytes: printable, encoding: .ascii) ?? "????"
                    accum.firstFramePixelFormat = "\(fourCC) (0x\(String(pfType, radix: 16)))"
                    accum.firstFrameWidth = CVPixelBufferGetWidth(pixelBuffer)
                    accum.firstFrameHeight = CVPixelBufferGetHeight(pixelBuffer)
                }
            }
        } catch {
            return SoftwareDecodeProbeResult(
                codecName: codecName,
                codecID: Int32(bitPattern: codecID.rawValue),
                width: width,
                height: height,
                openSucceeded: false,
                openError: "\(error)",
                packetsRead: 0,
                packetsFedToDecoder: 0,
                framesDecoded: 0,
                firstFramePixelFormat: nil,
                firstFrameWidth: 0,
                firstFrameHeight: 0,
                firstError: "decoder open failed: \(error)"
            )
        }
        defer { decoder.close() }

        var packetsRead = 0
        var packetsFedToDecoder = 0
        var firstError: String?

        while packetsRead < maxPackets, accum.framesDecoded < maxPackets {
            do {
                guard let packet = try demuxer.readPacket() else {
                    break  // EOF
                }
                packetsRead += 1
                if packet.pointee.stream_index == videoIdx {
                    packetsFedToDecoder += 1
                    decoder.decode(packet: packet)
                }
                av_packet_unref(packet)
                av_packet_free_safe(packet)
            } catch {
                if firstError == nil {
                    firstError = "\(error)"
                }
                break
            }
        }
        decoder.flush()

        return SoftwareDecodeProbeResult(
            codecName: codecName,
            codecID: Int32(bitPattern: codecID.rawValue),
            width: width,
            height: height,
            openSucceeded: true,
            openError: nil,
            packetsRead: packetsRead,
            packetsFedToDecoder: packetsFedToDecoder,
            framesDecoded: accum.framesDecoded,
            firstFramePixelFormat: accum.firstFramePixelFormat,
            firstFrameWidth: accum.firstFrameWidth,
            firstFrameHeight: accum.firstFrameHeight,
            firstError: firstError
        )
    }

    /// Pure, nonisolated, and unit-testable: audio-only path when the host requested it OR the probe found no video stream.
    nonisolated static func shouldUseAudioOnlyPath(audioOnlyRequested: Bool, hasVideoStream: Bool) -> Bool {
        audioOnlyRequested || !hasVideoStream
    }

    /// Whitelist (not blacklist) of AVPlayer-native audio codecs: AAC, MP3, MP2, ALAC, AC-3/E-AC-3, LPCM, FLAC (native since iOS/tvOS 11). Anything else falls back to `AudioPlaybackHost` (FFmpeg).
    nonisolated static func avPlayerCanDecodeAudio(_ codecID: AVCodecID) -> Bool {
        switch codecID {
        case AV_CODEC_ID_AAC,
             AV_CODEC_ID_MP3,
             AV_CODEC_ID_MP2,
             AV_CODEC_ID_MP1,
             AV_CODEC_ID_ALAC,
             AV_CODEC_ID_FLAC,
             AV_CODEC_ID_AC3,
             AV_CODEC_ID_EAC3,
             AV_CODEC_ID_PCM_S16LE,
             AV_CODEC_ID_PCM_S16BE,
             AV_CODEC_ID_PCM_S24LE,
             AV_CODEC_ID_PCM_S24BE,
             AV_CODEC_ID_PCM_F32LE:
            return true
        default:
            return false
        }
    }

    // MARK: - Decoder identity helpers

    /// User-facing label for the active video decoder. nil when no video track (AV_CODEC_ID_NONE). Native = VideoToolbox HW; SW = dav1d (AV1) or libavcodec (VP9, MPEG-2, VC-1).
    static func videoDecoderLabel(codecID: AVCodecID, isSoftware: Bool) -> String? {
        guard codecID != AV_CODEC_ID_NONE else { return nil }
        let name: String = {
            guard let cstr = avcodec_get_name(codecID) else { return "video" }
            return String(cString: cstr).uppercased()
        }()
        if isSoftware {
            switch codecID {
            case AV_CODEC_ID_AV1: return "dav1d \(name) (SW)"
            default:              return "libavcodec \(name) (SW)"
            }
        }
        return "VideoToolbox \(name) (HW)"
    }

    /// User-facing label for the active audio decoder on the SW path (libavcodec -> CoreAudio). nil when no audio track.
    static func softwareAudioDecoderLabel(
        audioTracks: [TrackInfo],
        activeIndex: Int32
    ) -> String? {
        guard activeIndex >= 0,
              let track = audioTracks.first(where: { $0.id == Int(activeIndex) }) else {
            return nil
        }
        return "libavcodec \(track.codec.uppercased()) → CoreAudio"
    }

    // MARK: - Format / frame-rate probing

    nonisolated static func detectVideoFormat(stream: UnsafeMutablePointer<AVStream>) -> VideoFormat {
        let codecpar = stream.pointee.codecpar.pointee
        // dvcC/dvvC side-data is the authoritative DV marker, independent of color_trc. Branching on color_trc first mis-classifies HLG-base P8.4 (reported as HLG) and unspecified-trc P5 (reported as SDR) -- both emit hvc1 instead of dvh1, so the panel never enters DV (DrHurt#4 2026-05-26: only P8.1 produced dolbyvision pre-fix).
        if Self.streamHasDV(stream: stream) {
            return .dolbyVision
        }
        let transfer = codecpar.color_trc
        if transfer == AVCOL_TRC_SMPTE2084 { return .hdr10 }
        if transfer == AVCOL_TRC_ARIB_STD_B67 { return .hlg }
        return .sdr
    }

    /// Clamp source format to what the panel can present. On non-DV panels, publishes the HDR10/HLG base layer format (hvc1 path); SDR-base DV (P8.2) collapses to .sdr (HLSVideoEngine refuses to serve it).
    static func effectiveVideoFormat(
        detected: VideoFormat,
        stream: UnsafeMutablePointer<AVStream>
    ) -> VideoFormat {
        guard detected == .dolbyVision else { return detected }
        let caps = displayCapabilities
        if caps.supportsDolbyVision { return .dolbyVision }
        let trc = stream.pointee.codecpar.pointee.color_trc
        if trc == AVCOL_TRC_ARIB_STD_B67 {
            return caps.supportsHLG ? .hlg : .sdr
        }
        // SMPTE2084 base (P5/P7/P8.1) or unspecified trc (P5 with empty VUI): AVPlayer tonemaps via dvh1 on non-DV panel.
        return caps.supportsHDR10 ? .hdr10 : .sdr
    }

    private nonisolated static func streamHasDV(stream: UnsafeMutablePointer<AVStream>) -> Bool {
        let nb = Int(stream.pointee.codecpar.pointee.nb_coded_side_data)
        guard nb > 0, let sideData = stream.pointee.codecpar.pointee.coded_side_data else {
            return false
        }
        for i in 0..<nb {
            if sideData[i].type == AV_PKT_DATA_DOVI_CONF {
                return true
            }
        }
        return false
    }

    nonisolated static func detectFrameRate(stream: UnsafeMutablePointer<AVStream>) -> Double? {
        let avg = stream.pointee.avg_frame_rate
        if avg.den > 0 && avg.num > 0 {
            return Double(avg.num) / Double(avg.den)
        }
        let r = stream.pointee.r_frame_rate
        if r.den > 0 && r.num > 0 {
            return Double(r.num) / Double(r.den)
        }
        return nil
    }
}
