import Foundation
import AetherLibavcodec
import AetherLibavutil

/// The one place a libavcodec decoder context is allocated, filled from codecpar and opened. Each caller
/// keeps its own threading and options through `configure` and `options`.
enum FFmpegDecoderContext {

    /// Enough for 8K in either orientation. Beyond it a header is hostile, and dav1d takes its
    /// `frame_size_limit` from this value (audit DEC-201).
    static let maxVideoPixels: Int64 = 8192 * 8192

    /// Enough for a 4K graphics canvas in any aspect. Legitimate PGS stays at 1920x1080; without a cap a
    /// PCS of 16384x16000 passes FFmpeg's own `INT_MAX` check and allocates about 1 GB (audit DEC-201).
    static let maxSubtitlePixels: Int64 = 4096 * 4096

    enum Failure: Error, Equatable {
        case allocation
        case parameters(Int32)
        case open(Int32)
    }

    /// `get_format` for software-only decode: anything but VideoToolbox, YUV 4:2:0 when nothing else is offered.
    static let softwareOnlyGetFormat: @convention(c) (
        UnsafeMutablePointer<AVCodecContext>?, UnsafePointer<AVPixelFormat>?
    ) -> AVPixelFormat = { _, formats in
        guard let formats else { return AV_PIX_FMT_NONE }
        var index = 0
        while formats[index] != AV_PIX_FMT_NONE {
            if formats[index] != AV_PIX_FMT_VIDEOTOOLBOX { return formats[index] }
            index += 1
        }
        return AV_PIX_FMT_YUV420P
    }

    /// Allocates a context for `codec`, copies `codecpar` into it, runs `configure` (set fields the open reads),
    /// applies `maxPixels` and opens it. The context is freed on every failure path.
    static func open(
        codec: UnsafePointer<AVCodec>,
        codecpar: UnsafePointer<AVCodecParameters>,
        maxPixels: Int64,
        options: [String: String] = [:],
        configure: (UnsafeMutablePointer<AVCodecContext>) -> Void = { _ in }
    ) throws -> UnsafeMutablePointer<AVCodecContext> {
        guard let ctx = avcodec_alloc_context3(codec) else { throw Failure.allocation }
        var owned: UnsafeMutablePointer<AVCodecContext>? = ctx
        let parametersResult = avcodec_parameters_to_context(ctx, codecpar)
        guard parametersResult >= 0 else {
            avcodec_free_context(&owned)
            throw Failure.parameters(parametersResult)
        }
        configure(ctx)
        // A subtitle canvas seeded from an 8K video must still open (avcodec_open2 drops a size above
        // max_pixels), so the cap grows to the seeded size, never past the video cap.
        let seeded = Int64(max(0, ctx.pointee.width)) * Int64(max(0, ctx.pointee.height))
        ctx.pointee.max_pixels = min(max(maxPixels, seeded), maxVideoPixels)

        var dictionary: OpaquePointer?
        for (key, value) in options { av_dict_set(&dictionary, key, value, 0) }
        let openResult = avcodec_open2(ctx, codec, &dictionary)
        av_dict_free(&dictionary)
        guard openResult >= 0 else {
            avcodec_free_context(&owned)
            throw Failure.open(openResult)
        }
        return ctx
    }
}
