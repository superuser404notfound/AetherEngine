import Foundation
import AetherLibavfilter
import AetherLibavutil

/// Tone-maps a decoded HDR (PQ/HLG, BT.2020) AVFrame to SDR BT.709 RGBA via a
/// zscale + tonemap libavfilter graph (one graph per call; extractor is low-frequency).
/// Caller owns the returned frame and must av_frame_free it.
struct HDRToneMapper {
    static func toneMap(
        frame: UnsafeMutablePointer<AVFrame>,
        targetWidth: Int,
        timeBase: AVRational,
        sar: AVRational,
        highQuality: Bool = false
    ) -> UnsafeMutablePointer<AVFrame>? {
        let srcW = Int(frame.pointee.width)
        let srcH = Int(frame.pointee.height)
        guard srcW > 0, srcH > 0, targetWidth > 0 else { return nil }
        let (width, height) = FrameDecodeContext.displayDimensions(
            srcW: srcW, srcH: srcH, sar: sar, targetWidth: targetWidth)
        guard let graph = avfilter_graph_alloc() else { return nil }
        var graphOpt: UnsafeMutablePointer<AVFilterGraph>? = graph
        defer { avfilter_graph_free(&graphOpt) }

        guard let bufferFilter = avfilter_get_by_name("buffer"),
              let sinkFilter = avfilter_get_by_name("buffersink") else { return nil }

        let sarNum = sar.num > 0 ? sar.num : 1
        let sarDen = sar.den > 0 ? sar.den : 1
        // AE#499: colorspace and range belong in the args. Without them the link is configured as
        // unspecified, the first frame arrives as BT.2020 and buffersrc warns that changing frame
        // properties on the fly is not supported by all filters. zscale reads the frame rather than the
        // link, so this was never the cause of a failure, but a graph that describes its own input
        // wrongly is a bad place to debug the next one from.
        let args = "video_size=\(frame.pointee.width)x\(frame.pointee.height)" +
                   ":pix_fmt=\(frame.pointee.format)" +
                   ":time_base=\(timeBase.num)/\(timeBase.den)" +
                   ":pixel_aspect=\(sarNum)/\(sarDen)" +
                   ":colorspace=\(frame.pointee.colorspace.rawValue)" +
                   ":range=\(frame.pointee.color_range.rawValue)"

        var srcCtx: UnsafeMutablePointer<AVFilterContext>?
        var sinkCtx: UnsafeMutablePointer<AVFilterContext>?
        let srcRet = avfilter_graph_create_filter(&srcCtx, bufferFilter, "in", args, nil, graph)
        let sinkRet = avfilter_graph_create_filter(&sinkCtx, sinkFilter, "out", nil, nil, graph)
        guard srcRet >= 0, sinkRet >= 0 else {
            EngineLog.emit("[HDRToneMap] create_filter failed src=\(srcRet) sink=\(sinkRet) args=\(args)", category: .swPlayback)
            return nil
        }

        // BT.2020 PQ/HLG to linear, Hable tone-map to SDR, BT.709 (tv range), RGBA.
        // CGImage does not carry SAR. Bake the same display dimensions as SDR/DV into the pixels.
        let chain = "zscale=w=\(width):h=\(height):t=linear:npl=100:f=\(highQuality ? "bicubic" : "bilinear")," +
                    "tonemap=tonemap=hable:desat=0," +
                    "zscale=p=bt709:t=bt709:m=bt709:r=tv," +
                    "format=pix_fmts=rgba"

        var inputs = avfilter_inout_alloc()
        var outputs = avfilter_inout_alloc()
        defer { avfilter_inout_free(&inputs); avfilter_inout_free(&outputs) }
        guard inputs != nil, outputs != nil else { return nil }
        outputs!.pointee.name = strdup("in")
        outputs!.pointee.filter_ctx = srcCtx
        outputs!.pointee.pad_idx = 0
        outputs!.pointee.next = nil
        inputs!.pointee.name = strdup("out")
        inputs!.pointee.filter_ctx = sinkCtx
        inputs!.pointee.pad_idx = 0
        inputs!.pointee.next = nil

        let parseRet = avfilter_graph_parse_ptr(graph, chain, &inputs, &outputs, nil)
        guard parseRet >= 0 else {
            EngineLog.emit("[HDRToneMap] parse_ptr failed ret=\(parseRet) chain=\(chain)", category: .swPlayback)
            return nil
        }
        let configRet = avfilter_graph_config(graph, nil)
        guard configRet >= 0 else {
            EngineLog.emit("[HDRToneMap] graph_config failed ret=\(configRet)", category: .swPlayback)
            return nil
        }

        // KEEP_REF: without it buffersrc takes the frame's refs and resets it (w/h=0),
        // so the caller's sws fallback after a failed tone-map gets an emptied frame and returns nil.
        let addRet = av_buffersrc_add_frame_flags(
            srcCtx, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF)
        )
        guard addRet >= 0 else {
            EngineLog.emit("[HDRToneMap] add_frame failed ret=\(addRet)", category: .swPlayback)
            return nil
        }

        guard let out = av_frame_alloc() else { return nil }
        var outOpt: UnsafeMutablePointer<AVFrame>? = out
        let getRet = av_buffersink_get_frame(sinkCtx, out)
        if getRet < 0 {
            EngineLog.emit("[HDRToneMap] get_frame failed ret=\(getRet)", category: .swPlayback)
            av_frame_free(&outOpt)
            return nil
        }
        return out
    }
}
