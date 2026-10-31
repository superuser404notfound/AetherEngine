import Testing
import AetherLibavcodec
@testable import AetherEngine

@Suite("AVPlayer audio codec routing")
struct AudioCodecRoutingTests {

    @Test("AVPlayer-decodable music codecs route native")
    func nativeCodecs() {
        for id in [AV_CODEC_ID_AAC, AV_CODEC_ID_MP3, AV_CODEC_ID_MP2, AV_CODEC_ID_ALAC, AV_CODEC_ID_FLAC, AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3, AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_PCM_S16BE] {
            #expect(AetherEngine.avPlayerCanDecodeAudio(id) == true)
        }
    }

    @Test("Codecs AVPlayer cannot decode route to the FFmpeg fallback")
    func fallbackCodecs() {
        for id in [AV_CODEC_ID_OPUS, AV_CODEC_ID_VORBIS, AV_CODEC_ID_APE, AV_CODEC_ID_WAVPACK, AV_CODEC_ID_NONE] {
            #expect(AetherEngine.avPlayerCanDecodeAudio(id) == false)
        }
    }

    @Test("an automatic audio-only load of a whitelisted URL source goes to AVPlayer")
    func automaticKeepsAVPlayer() {
        for id in [AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC, AV_CODEC_ID_AAC, AV_CODEC_ID_MP3] {
            #expect(AetherEngine.audioOnlyUsesAVPlayer(
                codecID: id, isCustomSource: false, flacBlocksTooSmall: false, preferred: .automatic))
        }
    }

    /// The preference used to reach only the video routing: an audio-only FLAC asked onto
    /// `.software` still opened on `AudioAVPlayerHost`, the host whose clock ran past the end of
    /// 24-bit FLAC streamed over HTTP.
    @Test("software sends a codec AVPlayer could play to the FFmpeg host")
    func softwareOverridesAVPlayer() {
        for id in [AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC, AV_CODEC_ID_AAC, AV_CODEC_ID_MP3] {
            #expect(AetherEngine.audioOnlyUsesAVPlayer(
                codecID: id, isCustomSource: false, flacBlocksTooSmall: false, preferred: .software) == false)
        }
    }

    @Test("what already ruled AVPlayer out still does, whatever the preference")
    func existingRulesHold() {
        for preferred in DecodePath.allCases {
            #expect(AetherEngine.audioOnlyUsesAVPlayer(
                codecID: AV_CODEC_ID_OPUS, isCustomSource: false, flacBlocksTooSmall: false, preferred: preferred) == false)
            #expect(AetherEngine.audioOnlyUsesAVPlayer(
                codecID: AV_CODEC_ID_FLAC, isCustomSource: true, flacBlocksTooSmall: false, preferred: preferred) == false)
            #expect(AetherEngine.audioOnlyUsesAVPlayer(
                codecID: AV_CODEC_ID_FLAC, isCustomSource: false, flacBlocksTooSmall: true, preferred: preferred) == false)
        }
    }
}
