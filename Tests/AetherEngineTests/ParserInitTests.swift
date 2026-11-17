import Testing
import AetherLibavcodec
@testable import AetherEngine

@Suite("av_parser_init through the helper that compiles against FFmpeg 8 and 9")
struct ParserInitTests {

    @Test("a codec with a parser gets one, of that codec")
    func knownCodecs() throws {
        for codecID in [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_MPEG4, AV_CODEC_ID_DTS] {
            let parser = try #require(parserInit(codecID), "no parser for \(codecID.rawValue)")
            defer { av_parser_close(parser) }
            let ids = withUnsafeBytes(of: parser.pointee.parser.pointee.codec_ids) {
                Array($0.bindMemory(to: Int32.self))
            }
            #expect(ids.contains(Int32(codecID.rawValue)))
        }
    }

    @Test("a codec without a parser gets nil")
    func noParser() {
        #expect(parserInit(AV_CODEC_ID_NONE) == nil)
    }
}
