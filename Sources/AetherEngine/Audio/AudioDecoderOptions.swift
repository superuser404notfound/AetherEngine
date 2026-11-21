import AetherLibavcodec
import AetherLibavutil

/// How the engine opens an FFmpeg audio decoder whose PCM someone hears.
enum AudioDecoderOptions {
    /// FFmpeg's AC-3 and E-AC-3 decoders apply the stream's dynamic range compression by default
    /// (`drc_scale` 1). Apple's decoder, which plays the same track on the native path, does not, unless
    /// the viewer turns on Reduce Loud Sounds. So a session on the software host played about 2 dB
    /// quieter and with flattened peaks (an E-AC-3 5.1 film: -18.6 LUFS against Apple's -16.8, and
    /// -16.6 with `drc_scale` 0). A compressed sound is the host's call (`AudioShaping`), not the decoder's.
    static func dictionary(for codecID: AVCodecID) -> [String: String] {
        switch codecID {
        case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3: ["drc_scale": "0"]
        default: [:]
        }
    }

    /// `avcodec_open2` with `dictionary(for:)`.
    static func open(_ context: UnsafeMutablePointer<AVCodecContext>, _ codec: UnsafePointer<AVCodec>) -> Int32 {
        var options: OpaquePointer?
        for (key, value) in dictionary(for: codec.pointee.id) { av_dict_set(&options, key, value, 0) }
        let result = avcodec_open2(context, codec, &options)
        av_dict_free(&options)
        return result
    }
}
