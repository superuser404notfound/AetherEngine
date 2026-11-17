import Foundation
import AetherLibavcodec

/// `av_parser_init` for either libavcodec signature. Up to major 62 (FFmpeg 8) it takes an `int`,
/// from major 63 (FFmpeg 9, `FF_API_PARSER_CODECID` gone) an `enum AVCodecID`. Swift imports the two
/// as different parameter types, so a call written for one does not compile against the other. The
/// bundled FFmpegBuild is FFmpeg 8; a host that links its own FFmpeg 9 builds the same sources.
/// Overload resolution on the function reference picks whichever one the headers declare.
func parserInit(_ codecID: AVCodecID) -> UnsafeMutablePointer<AVCodecParserContext>? {
    callParserInit(av_parser_init, codecID)
}

private func callParserInit(
    _ initialise: (Int32) -> UnsafeMutablePointer<AVCodecParserContext>?, _ codecID: AVCodecID
) -> UnsafeMutablePointer<AVCodecParserContext>? {
    initialise(Int32(codecID.rawValue))
}

private func callParserInit(
    _ initialise: (AVCodecID) -> UnsafeMutablePointer<AVCodecParserContext>?, _ codecID: AVCodecID
) -> UnsafeMutablePointer<AVCodecParserContext>? {
    initialise(codecID)
}
