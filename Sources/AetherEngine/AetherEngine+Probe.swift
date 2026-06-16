import Foundation
import CoreVideo
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil

extension AetherEngine {

    // MARK: - Probe

    /// One-shot read of a source's container + stream metadata,
    /// without spinning up the HLS server or any decoders. Returns
    /// the same kind of info `load(url:)` collects internally before
    /// dispatching, packaged as a `SourceProbe` for hosts and CLI
    /// tools that just want to know "what's in this file?".
    ///
    /// Network sources fetch a HEAD probe + a small initial range
    /// for libavformat's stream info pass; total bytes pulled depend
    /// on the container but typically a few MB. File sources read
    /// from disk directly via FFmpeg's file protocol.
    ///
    /// - Parameters:
    ///   - url: Media source (`file://`, `http://`, or `https://`).
    ///   - options: Forwarded for `httpHeaders` only; other flags are
    ///     ignored since no playback session starts.
    /// - Throws: Any error the demuxer raises during open / probe.
    public nonisolated static func probe(
        url: URL,
        options: LoadOptions = .init()
    ) throws -> SourceProbe {
        try probe(source: .url(url), options: options)
    }

    /// `probe(url:)` for a custom byte source (AetherEngine#27). Same
    /// one-shot metadata read, but against a caller-supplied
    /// `IOReader` instead of a URL.
    ///
    /// Reader contract: the caller retains ownership. The probe seeks
    /// and reads through the reader for libavformat's stream-info
    /// pass and leaves the cursor at an unspecified position; it does
    /// NOT call `close()`. Hand the engine a fresh reader (or one you
    /// rewind yourself) when you `load(source:)` afterwards. For the
    /// `.url` case this is exactly `probe(url:)`.
    ///
    /// `SourceProbe.url` echoes the probed URL for `.url` sources and
    /// the synthetic `aether-custom://source` for custom readers
    /// (mirroring what `load(source:)` publishes as `loadedURL`).
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

    /// Build the decoy subtitle rendition list (native-picker path) from
    /// the probed subtitle tracks. Each rendition's `renditionID` embeds
    /// the engine subtitle AVStream index (`TrackInfo.id`) so the host can
    /// correlate AVKit's selected legible option back to the track; the
    /// `name` is a human label (the track's localized language name, then
    /// its declared name, then "Subtitle N"); `language` is the ISO code
    /// (fallback "und").
    nonisolated static func makeSubtitleRenditions(
        from tracks: [TrackInfo]
    ) -> [SubtitleRendition] {
        // The native picker lists each rendition by its NAME, and AVKit
        // collapses entries sharing NAME + LANGUAGE. Build a consistent,
        // self-describing label from the reliable signals (localized language +
        // format derived from the codec), then append the container title only
        // when it carries a real distinguisher (SDH / Forced / Commentary /
        // Simplified), dropping bare echoes and remux auto-titles like
        // "ENG (srt)". Number any labels that still collide so every track stays
        // selectable. Result e.g. "English (SRT)", "English SDH (SRT)",
        // "Chinese Simplified (SRT)", "English (VOBSUB)".
        var renditions: [SubtitleRendition] = []
        var usedNameCounts: [String: Int] = [:]
        for (offset, track) in tracks.enumerated() {
            let language = track.language?.trimmingCharacters(in: .whitespaces)
            let langCode = (language?.isEmpty == false) ? language! : "und"
            let localizedLang = (langCode != "und")
                ? Locale.current.localizedString(forLanguageCode: langCode)
                : nil
            let format = subtitleFormatLabel(track.codec)
            let title = track.name.trimmingCharacters(in: .whitespaces)

            // Keep the container title only when it adds information beyond the
            // language / format. Drop bare echoes ("English", "eng", "SRT") and
            // remux auto-titles of the form "<langcode> (<codec>)" (e.g.
            // "ENG (srt)", "FRE (dvdsub)") -- the auto-pattern is matched against
            // THIS track's language code so real labels like "SDH" survive.
            let lowerTitle = title.lowercased()
            let lowerLang = langCode.lowercased()
            let echoesLanguageName = localizedLang.map { lowerTitle == $0.lowercased() } ?? false
            let isEcho = title.isEmpty
                || lowerTitle == lowerLang
                || echoesLanguageName
                || lowerTitle == format.lowercased()
                || (lowerTitle.hasPrefix(lowerLang + " (") && lowerTitle.hasSuffix(")"))
            let distinguisher = isEcho ? nil : title

            // Compose "Language Distinguisher (FORMAT)".
            let languageLabel: String? = localizedLang ?? (langCode != "und" ? langCode : nil)
            let base: String
            switch (languageLabel, distinguisher) {
            case let (lang?, dist?):
                base = "\(lang) \(dist) (\(format))"
            case let (lang?, nil):
                base = "\(lang) (\(format))"
            case let (nil, dist?):
                base = "\(dist) (\(format))"
            case (nil, nil):
                base = "Subtitle \(offset + 1) (\(format))"
            }

            let priorCount = usedNameCounts[base, default: 0]
            usedNameCounts[base] = priorCount + 1
            let displayName = (priorCount == 0) ? base : "\(base) \(priorCount + 1)"

            renditions.append(SubtitleRendition(
                renditionID: "sub\(track.id)",
                name: displayName,
                language: langCode,
                trackIndex: track.id
            ))
        }
        return renditions
    }

    /// Map an FFmpeg subtitle codec name to a short, user-facing format label.
    nonisolated private static func subtitleFormatLabel(_ codec: String) -> String {
        switch codec.lowercased() {
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "mov_text", "text", "tx3g": return "Text"
        case "webvtt", "vtt": return "VTT"
        case "dvd_subtitle", "dvdsub", "vobsub": return "VOBSUB"
        case "hdmv_pgs_subtitle", "pgssub", "pgs": return "PGS"
        case "dvb_subtitle", "dvbsub": return "DVB"
        case "dvb_teletext": return "Teletext"
        default: return codec.uppercased()
        }
    }

    /// Assemble a `SourceProbe` from an open demuxer. Shared by the
    /// static probe entry points and `load(source:)`'s internal probe
    /// stage, so all of them report identical metadata for the same
    /// source.
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
        // Live-stream hint: duration absent + network-feed URL scheme.
        // Heuristic only; hosts decide whether to flip
        // LoadOptions.isLive based on this plus their own context
        // (e.g. an IPTV catalog entry vs a movie file). Custom readers
        // (synthetic aether-custom:// scheme) never match.
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

    /// One-shot SW-decoder repro for `aetherctl swdecode` and any
    /// future host-side diagnostic that wants to localise SW-pipeline
    /// failures (MPEG-4 Part 2, MPEG-2, VC-1, AV1 on platforms without
    /// HW AV1) without spinning up a render target.
    ///
    /// Opens the demuxer, opens `SoftwareVideoDecoder` for the video
    /// stream, reads up to `maxPackets` packets and feeds the video
    /// ones to the decoder, returns counters + first-frame metadata.
    /// Useful failure modes the result discriminates:
    ///
    /// - `openSucceeded == false`: decoder couldn't open (FFmpegBuild
    ///   missing the libavcodec decoder, codec-private extradata
    ///   malformed). `openError` carries the reason.
    /// - `openSucceeded == true && framesDecoded == 0`: decoder
    ///   opened but never produced a frame from the packets fed.
    ///   Suggests pixel-format conversion failure or all-skipped
    ///   non-IDR packets.
    /// - `framesDecoded > 0` with a populated `firstFramePixelFormat`:
    ///   SW decode path is functionally healthy end-to-end; if real
    ///   playback still hangs, the failure is downstream
    ///   (`SoftwarePlaybackHost` frame-enqueue, `AVSampleBufferDisplayLayer`
    ///   attach, audio-clock sync).
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
        // Captured-by-reference accumulators via a class so the onFrame
        // closure can mutate them safely without inout / @escaping
        // capture gymnastics. Closure fires synchronously from inside
        // avcodec_send_packet / receive_frame, all on this thread.
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

    /// Decide whether a load should use the audio-only path. Pure and
    /// `nonisolated` so it is unit-testable without a `@MainActor`
    /// engine instance. The audio path is taken when the host explicitly
    /// requested it OR the probe found no video stream.
    nonisolated static func shouldUseAudioOnlyPath(audioOnlyRequested: Bool, hasVideoStream: Bool) -> Bool {
        audioOnlyRequested || !hasVideoStream
    }

    /// Whether AVPlayer/AVFoundation can natively decode this audio codec
    /// on Apple platforms, so the engine can hand the source straight to a
    /// lean AVPlayer (hardware-accelerated, energy-efficient, native system
    /// integration) instead of the FFmpeg software path. Whitelist, not
    /// blacklist: anything not known-native (Opus, Vorbis, APE, WavPack,
    /// Musepack, ...) falls back to `AudioPlaybackHost`, which decodes
    /// everything via FFmpeg. AAC, MP3, MP2, ALAC, AC-3/E-AC-3, LPCM, and
    /// FLAC (AVFoundation has decoded FLAC since iOS/tvOS 11) are native.
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

    /// Build a user-facing label for the active video decoder. Native
    /// dispatch goes through VideoToolbox on every Apple platform we
    /// ship to, so the "HW" tag holds even on HW-AV1 capable devices;
    /// the SW branch covers the dav1d-on-tvOS AV1 case and the libavcodec
    /// VP9 path. Returns `nil` when the source had no video track
    /// (AV_CODEC_ID_NONE) so the caller can hide the row instead of
    /// printing a placeholder.
    static func videoDecoderLabel(codecID: AVCodecID, isSoftware: Bool) -> String? {
        guard codecID != AV_CODEC_ID_NONE else { return nil }
        let name: String = {
            guard let cstr = avcodec_get_name(codecID) else { return "video" }
            return String(cString: cstr).uppercased()
        }()
        if isSoftware {
            // SW host paths: AV1 via dav1d, VP9 via libavcodec's vp9
            // decoder, plus legacy codecs AVPlayer's HLS-fMP4 pipeline
            // does not accept (MPEG-4 Part 2 / MPEG-2 / VC-1) via the
            // matching libavcodec native decoder. SoftwareVideoDecoder
            // resolves the actual decoder via `avcodec_find_decoder`.
            switch codecID {
            case AV_CODEC_ID_AV1: return "dav1d \(name) (SW)"
            default:              return "libavcodec \(name) (SW)"
            }
        }
        return "VideoToolbox \(name) (HW)"
    }

    /// Build a user-facing label for the active audio decoder on the
    /// software path. The SW host always uses libavcodec for audio
    /// decode then hands PCM to CoreAudio, so the label is uniform.
    /// Returns `nil` when the source has no audio.
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
        // Dolby Vision side-data (the `dvcC` / `dvvC` box parsed out of
        // the container) is the authoritative DV marker, independent of
        // base-layer transfer characteristic. Profile 5 is non-backward-
        // compatible (no HDR10/HLG base; ships with SMPTE2084 OR an
        // unspecified trc depending on muxer); Profile 7 and 8.1 use
        // SMPTE2084 base; Profile 8.4 uses HLG base. Branching on
        // `color_trc` first mis-classifies the HLG-base case (P8.4
        // reported as plain HLG) and any unspecified-trc case (P5 with
        // an empty base-layer VUI reported as SDR) — both surface as
        // criteria writes with `codec=hvc1` instead of `dvh1`, so the
        // panel never enters DV mode even when it could. DrHurt#4
        // (2026-05-26): on a DV-capable panel, only P8.1 was producing
        // `format=dolbyvision codec=dvh1` pre-fix.
        if Self.streamHasDV(stream: stream) {
            return .dolbyVision
        }
        let transfer = codecpar.color_trc
        if transfer == AVCOL_TRC_SMPTE2084 { return .hdr10 }
        if transfer == AVCOL_TRC_ARIB_STD_B67 { return .hlg }
        return .sdr
    }

    /// Clamp the source-detected format to what the active display can
    /// actually present. AVPlayer renders DV's HDR10 (PQ) or HLG base
    /// layer on a non-DV panel — HLSVideoEngine forces this by emitting
    /// plain `hvc1` when `dvModeAvailable=false` — so the engine publishes
    /// the base format the panel ends up showing, not the source's DV
    /// claim. Picks the base from the source `color_trc`: PQ → hdr10,
    /// HLG → hlg. SDR-base DV (P8.2) collapses to .sdr; HLSVideoEngine
    /// refuses to serve it anyway so the badge never reaches the UI.
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
        // SMPTE2084 base (P5 / P7 / P8.1) or an unspecified trc (P5
        // sometimes ships with an empty base-layer VUI). Both are
        // HDR-derived; AVPlayer tonemaps via the dvh1 sample entry on
        // a non-DV panel. Map to HDR10 if the panel can present it.
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
