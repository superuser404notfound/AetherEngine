// Audio tail padding (AetherEngine#847).
//
// AVPlayer ends a muxed HLS item when its audio runs out, however much picture is left: a 60 s
// HEVC track over 35 s of AC-3 ended at 35.0 s from the engine's loopback and from a plain ffmpeg
// fMP4 playlist alike, and a start inside that tail ended the item at load. A gap in the audio is
// harmless (audio at 0-35 s and 59-60 s plays to 59.99 s), so the final segment gets silence from
// where its audio stops to where its video does, in the delivered codec.
//
// The span decision is pure; the encode cases run against this build's FFmpeg and decode their own
// output back, so a codec whose encoder is missing is skipped rather than failed.
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

@Suite("Audio tail padding (#847)", .offCooperativePoolOneLane)
struct AudioTailPaddingTests {

    // MARK: - Span

    @Test("Audio ending inside the final segment is filled from its end to the picture's")
    func fillsFromAudioEnd() {
        let span = AudioTailPadding.span(videoEnd: 60.0, audioEnd: 57.5, segmentStart: 55.96)
        #expect(span?.start == 57.5)
        #expect(span?.end == 60.0)
    }

    @Test("Audio ending before the final segment is filled from the segment's start, never earlier")
    func clampsToSegmentStart() {
        let span = AudioTailPadding.span(videoEnd: 60.0, audioEnd: 35.0, segmentStart: 55.96)
        #expect(span?.start == 55.96)
    }

    @Test("A run that wrote no audio (a start inside the tail) is filled from the segment's start")
    func fillsRunWithoutAudio() {
        let span = AudioTailPadding.span(videoEnd: 60.0, audioEnd: nil, segmentStart: 55.96)
        #expect(span?.start == 55.96)
    }

    @Test("Tracks ending within the end-of-media epsilon are left exactly as they are")
    func ordinaryFileUntouched() {
        #expect(AudioTailPadding.span(videoEnd: 60.0, audioEnd: 59.97, segmentStart: 55.96) == nil)
        #expect(AudioTailPadding.span(videoEnd: 60.0, audioEnd: 59.5, segmentStart: 55.96) == nil)
        #expect(AudioTailPadding.span(videoEnd: 60.0, audioEnd: 61.0, segmentStart: 55.96) == nil)
    }

    @Test("Frame count rounds down so the fill never outlasts the picture, with at least one frame")
    func frameCountRoundsDown() {
        let tb = AVRational(num: 1, den: 48_000)
        // 4.04 s at 48 kHz is 193920 samples, 126.25 AC-3 frames.
        #expect(AudioTailPadding.frameCount(spanTicks: 193_920, timeBase: tb, sampleRate: 48_000, frameSize: 1536) == 126)
        #expect(AudioTailPadding.frameCount(spanTicks: 100, timeBase: tb, sampleRate: 48_000, frameSize: 1536) == 1)
        #expect(AudioTailPadding.frameCount(spanTicks: 0, timeBase: tb, sampleRate: 48_000, frameSize: 1536) == 0)
    }

    @Test("Only Low Complexity AAC is padded, read from the profile or the ASC's object type")
    func aacProfileGate() {
        #expect(AudioTailPadding.aacIsLowComplexity(profile: AV_PROFILE_AAC_LOW, extradata: []))
        #expect(!AudioTailPadding.aacIsLowComplexity(profile: AV_PROFILE_AAC_HE, extradata: [0x11, 0x90]))
        // ASC 0x11 0x90: object type 2 (LC), 48 kHz, stereo.
        #expect(AudioTailPadding.aacIsLowComplexity(profile: AV_PROFILE_UNKNOWN, extradata: [0x11, 0x90]))
        // Object type 5 (SBR).
        #expect(!AudioTailPadding.aacIsLowComplexity(profile: AV_PROFILE_UNKNOWN, extradata: [0x29, 0x90]))
        #expect(!AudioTailPadding.aacIsLowComplexity(profile: AV_PROFILE_UNKNOWN, extradata: []))
    }

    // MARK: - Encode round trip

    static let encodableCodecs: [(AVCodecID, Int32, Int32)] = [
        (AV_CODEC_ID_AC3, 6, 0),
        (AV_CODEC_ID_EAC3, 6, 0),
        (AV_CODEC_ID_FLAC, 2, 16),
        (AV_CODEC_ID_FLAC, 8, 24),
        (AV_CODEC_ID_AAC, 2, 0),
        (AV_CODEC_ID_ALAC, 2, 16),
    ]

    @Test("The fill is contiguous, starts where asked, stays inside the span and decodes to silence",
          arguments: encodableCodecs.indices)
    func encodesDecodableSilence(index: Int) throws {
        let (codecID, channels, bits) = Self.encodableCodecs[index]
        guard avcodec_find_encoder(codecID) != nil else { return }
        var parOpt = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&parOpt) }
        let par = try #require(parOpt)
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = codecID
        par.pointee.sample_rate = 48_000
        par.pointee.bits_per_raw_sample = bits
        par.pointee.profile = codecID == AV_CODEC_ID_AAC ? AV_PROFILE_AAC_LOW : AV_PROFILE_UNKNOWN
        av_channel_layout_default(&par.pointee.ch_layout, channels)
        if codecID == AV_CODEC_ID_ALAC {
            // A real ALAC track carries its magic cookie; take the one FFmpeg's encoder writes.
            try Self.installEncoderExtradata(on: par)
        }

        let tb = AVRational(num: 1, den: 48_000)
        let start: Int64 = 2_686_080   // 55.96 s
        let end: Int64 = 2_880_000     // 60.0 s
        guard case .packets(let packets, _) = AudioTailPadding.silencePackets(
            codecpar: par, startTicks: start, endTicks: end, timeBase: tb) else {
            Issue.record("encoder present but no packets for \(String(cString: avcodec_get_name(codecID)))")
            return
        }
        defer { for p in packets { var q: UnsafeMutablePointer<AVPacket>? = p; trackedPacketFree(&q) } }
        #expect(!packets.isEmpty)
        #expect(packets.first?.pointee.pts == start)
        for (a, b) in zip(packets, packets.dropFirst()) {
            #expect(b.pointee.pts == a.pointee.pts + a.pointee.duration)
        }
        if let last = packets.last {
            #expect(last.pointee.pts + last.pointee.duration <= end)
        }

        let decoder = try #require(avcodec_find_decoder(codecID))
        var decOpt = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&decOpt) }
        let dec = try #require(decOpt)
        #expect(avcodec_parameters_to_context(dec, par) >= 0)
        #expect(avcodec_open2(dec, decoder, nil) >= 0)
        var frameOpt = av_frame_alloc()
        defer { av_frame_free(&frameOpt) }
        let frame = try #require(frameOpt)
        var decodedSamples = 0
        var peak: Float = 0
        func receive() {
            while avcodec_receive_frame(dec, frame) >= 0 {
                decodedSamples += Int(frame.pointee.nb_samples)
                peak = max(peak, Self.peak(of: frame))
            }
        }
        for p in packets {
            _ = avcodec_send_packet(dec, p)
            receive()
        }
        _ = avcodec_send_packet(dec, nil)
        receive()
        #expect(decodedSamples > 0)
        // Lossless fills decode to exact zero; AC-3 and E-AC-3 to about -102 dBFS of decoder
        // rounding, far below anything audible, so the bound is -80 dBFS of full scale.
        let lossless = codecID == AV_CODEC_ID_FLAC || codecID == AV_CODEC_ID_ALAC
        #expect(lossless ? peak == 0 : peak < 1e-4,
                "\(String(cString: avcodec_get_name(codecID))) fill is not silent: peak \(peak)")
    }

    @Test("A codec this build cannot encode is reported, not guessed at")
    func missingEncoderIsReported() throws {
        var parOpt = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&parOpt) }
        let par = try #require(parOpt)
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_MP3
        par.pointee.sample_rate = 48_000
        av_channel_layout_default(&par.pointee.ch_layout, 2)
        guard avcodec_find_encoder(AV_CODEC_ID_MP3) == nil else { return }
        let outcome = AudioTailPadding.silencePackets(
            codecpar: par, startTicks: 0, endTicks: 48_000, timeBase: AVRational(num: 1, den: 48_000))
        guard case .unavailable(let reason) = outcome else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(reason.contains("mp3"))
    }

    @Test("frameLength is read from an ALAC cookie with or without its atom header")
    func alacCookieFrameLength() throws {
        var parOpt = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&parOpt) }
        let par = try #require(parOpt)
        let config: [UInt8] = [0x00, 0x00, 0x10, 0x00] + Array(repeating: 0, count: 20)
        for bytes in [config, [0x00, 0x00, 0x00, 0x24, 0x61, 0x6C, 0x61, 0x63, 0, 0, 0, 0] + config] {
            let buffer = try #require(av_mallocz(bytes.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
            bytes.withUnsafeBytes { _ = memcpy(buffer, $0.baseAddress, bytes.count) }
            av_freep(&par.pointee.extradata)
            par.pointee.extradata = buffer.assumingMemoryBound(to: UInt8.self)
            par.pointee.extradata_size = Int32(bytes.count)
            #expect(AudioTailPadding.alacFrameLength(par.pointee) == 4096)
        }
    }

    private static func installEncoderExtradata(on par: UnsafeMutablePointer<AVCodecParameters>) throws {
        let codec = try #require(avcodec_find_encoder(par.pointee.codec_id))
        var encOpt = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&encOpt) }
        let enc = try #require(encOpt)
        enc.pointee.sample_rate = par.pointee.sample_rate
        enc.pointee.sample_fmt = AV_SAMPLE_FMT_S16P
        _ = av_channel_layout_copy(&enc.pointee.ch_layout, &par.pointee.ch_layout)
        try #require(avcodec_open2(enc, codec, nil) >= 0)
        try #require(avcodec_parameters_from_context(par, enc) >= 0)
        par.pointee.bits_per_raw_sample = 16
    }

    /// Peak absolute sample, as a fraction of full scale.
    private static func peak(of frame: UnsafeMutablePointer<AVFrame>) -> Float {
        let format = AVSampleFormat(rawValue: frame.pointee.format)
        let planar = av_sample_fmt_is_planar(format) != 0
        let channels = Int(frame.pointee.ch_layout.nb_channels)
        let samples = Int(frame.pointee.nb_samples) * (planar ? 1 : channels)
        var peak: Float = 0
        for plane in 0..<(planar ? channels : 1) {
            guard let base = frame.pointee.extended_data[plane] else { continue }
            for i in 0..<samples {
                let v: Float
                switch format {
                case AV_SAMPLE_FMT_FLTP, AV_SAMPLE_FMT_FLT:
                    v = base.withMemoryRebound(to: Float.self, capacity: samples) { abs($0[i]) }
                case AV_SAMPLE_FMT_S16P, AV_SAMPLE_FMT_S16:
                    v = Float(base.withMemoryRebound(to: Int16.self, capacity: samples) { abs(Int32($0[i])) }) / 32_768
                case AV_SAMPLE_FMT_S32P, AV_SAMPLE_FMT_S32:
                    v = Float(base.withMemoryRebound(to: Int32.self, capacity: samples) { abs(Int64($0[i])) }) / 2_147_483_648
                default:
                    v = 0
                }
                peak = max(peak, v)
            }
        }
        return peak
    }
}
