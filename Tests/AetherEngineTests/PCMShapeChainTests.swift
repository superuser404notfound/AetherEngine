import Testing
import AetherLibavcodec
@testable import AetherEngine

/// The integer and float PCM shapes and MPEG-1 Layer I, which become whole with FFmpegBuild 3.15.0.
///
/// Same rule as the other format chains: a track whose decoder is missing plays SILENT (the bridge has
/// nothing to open and the session drops to video-only), so every shape a linked demuxer can hand over
/// is named here, not only the common ones. 24-bit big-endian is what camera MOVs record (`in24`),
/// 32-bit integer comes in WAV and MOV, float in MOV, WAV and Matroska, signed 8-bit in MOV (`twos`).
@Suite("PCM shapes and MP1")
struct PCMShapeChainTests {

    private static let audio: [(String, AVCodecID, HLSVideoEngine.AudioCodecCompat)] = [
        ("pcm_s8", AV_CODEC_ID_PCM_S8, .pcm),
        ("pcm_s24be", AV_CODEC_ID_PCM_S24BE, .pcm),
        ("pcm_s32le", AV_CODEC_ID_PCM_S32LE, .pcm),
        ("pcm_s32be", AV_CODEC_ID_PCM_S32BE, .pcm),
        ("pcm_f32be", AV_CODEC_ID_PCM_F32BE, .pcm),
        ("pcm_f64le", AV_CODEC_ID_PCM_F64LE, .pcm),
        ("pcm_f64be", AV_CODEC_ID_PCM_F64BE, .pcm),
        ("mp1", AV_CODEC_ID_MP1, .mp2),
    ]

    @Test("every shape bridges instead of trying to stream-copy into fMP4")
    func everyShapeBridges() {
        for (name, id, expected) in Self.audio {
            let compat = HLSVideoEngine.AudioCodecCompat.from(id)
            #expect(compat == expected, "\(name) routes as \(compat), not \(expected)")
            #expect(compat.requiresBridge, "\(name) would try to stream-copy into fMP4")
        }
    }

    @Test("the linked libavcodec carries every decoder the table routes")
    func everyDecoderIsLinked() {
        for (name, id, _) in Self.audio {
            #expect(avcodec_find_decoder(id) != nil,
                    "\(name) is routed but absent from the linked FFmpeg build: those tracks play silently")
        }
    }
}
