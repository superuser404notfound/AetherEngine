import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// FFmpeg's AC-3 / E-AC-3 decoders compress dynamics by default; the engine's audible decoders open
/// them with `drc_scale` 0, so the software host plays as loud as Apple's decoder on the native path.
@Suite("Audio decoder options", .timeLimit(.minutes(3)))
struct AudioDecoderOptionsTests {

    static func drcScale(opening id: AVCodecID) -> Double? {
        guard let codec = avcodec_find_decoder(id), let context = avcodec_alloc_context3(codec) else { return nil }
        var owned: UnsafeMutablePointer<AVCodecContext>? = context
        defer { avcodec_free_context(&owned) }
        context.pointee.sample_rate = 48_000
        av_channel_layout_default(&context.pointee.ch_layout, 6)
        guard AudioDecoderOptions.open(context, codec) >= 0 else { return nil }
        var value = -1.0
        guard av_opt_get_double(context.pointee.priv_data, "drc_scale", 0, &value) >= 0 else { return nil }
        return value
    }

    @Test("AC-3 and E-AC-3 open without the stream's dynamic range compression",
          arguments: [AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3])
    func dolbyDecodersOpenWithoutDRC(id: AVCodecID) {
        #expect(Self.drcScale(opening: id) == 0)
    }

    @Test("other codecs open with no options")
    func otherCodecsOpenPlain() {
        #expect(AudioDecoderOptions.dictionary(for: AV_CODEC_ID_AAC).isEmpty)
        #expect(AudioDecoderOptions.dictionary(for: AV_CODEC_ID_TRUEHD).isEmpty)
        #expect(AudioDecoderOptions.dictionary(for: AV_CODEC_ID_DTS).isEmpty)
    }
}
