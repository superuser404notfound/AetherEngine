import Testing
@testable import AetherEngine
import Libavcodec

struct TeletextDecoderOptionsTests {
    @Test("teletext gets txt_format=ass and auto page when no override")
    func teletextAutoPage() {
        let opts = EmbeddedSubtitleDecoder.decoderOptions(for: AV_CODEC_ID_DVB_TELETEXT, teletextPage: nil)
        #expect(opts["txt_format"] == "ass")
        #expect(opts["txt_page"] == "subtitle")
    }

    @Test("teletext page override is passed through as a string")
    func teletextPageOverride() {
        let opts = EmbeddedSubtitleDecoder.decoderOptions(for: AV_CODEC_ID_DVB_TELETEXT, teletextPage: 801)
        #expect(opts["txt_page"] == "801")
        #expect(opts["txt_format"] == "ass")
    }

    @Test("non-teletext codecs get no options")
    func nonTeletext() {
        #expect(EmbeddedSubtitleDecoder.decoderOptions(for: AV_CODEC_ID_HDMV_PGS_SUBTITLE, teletextPage: 801).isEmpty)
        #expect(EmbeddedSubtitleDecoder.decoderOptions(for: AV_CODEC_ID_SUBRIP, teletextPage: nil).isEmpty)
        #expect(EmbeddedSubtitleDecoder.decoderOptions(for: AV_CODEC_ID_DVB_SUBTITLE, teletextPage: nil).isEmpty)
    }
}
