import Foundation
import Libavfilter
import Libavutil

/// Tone-maps a single decoded HDR (PQ/HLG, BT.2020) AVFrame to an SDR
/// BT.709 RGBA AVFrame via a zscale + tonemap libavfilter graph. One
/// graph per call (decode dominates; the extractor is low-frequency).
/// Caller owns the returned frame and must av_frame_free it.
struct HDRToneMapper {
    static func toneMap(
        frame: UnsafeMutablePointer<AVFrame>,
        targetWidth: Int,
        timeBase: AVRational
    ) -> UnsafeMutablePointer<AVFrame>? {
        guard let graph = avfilter_graph_alloc() else { return nil }
        var graphOpt: UnsafeMutablePointer<AVFilterGraph>? = graph
        defer { avfilter_graph_free(&graphOpt) }

        guard let bufferFilter = avfilter_get_by_name("buffer"),
              let sinkFilter = avfilter_get_by_name("buffersink") else { return nil }

        let sar = frame.pointee.sample_aspect_ratio
        let sarNum = sar.num > 0 ? sar.num : 1
        let sarDen = sar.den > 0 ? sar.den : 1
        let args = "video_size=\(frame.pointee.width)x\(frame.pointee.height)" +
                   ":pix_fmt=\(frame.pointee.format)" +
                   ":time_base=\(timeBase.num)/\(timeBase.den)" +
                   ":pixel_aspect=\(sarNum)/\(sarDen)"

        var srcCtx: UnsafeMutablePointer<AVFilterContext>?
        var sinkCtx: UnsafeMutablePointer<AVFilterContext>?
        let srcRet = avfilter_graph_create_filter(&srcCtx, bufferFilter, "in", args, nil, graph)
        let sinkRet = avfilter_graph_create_filter(&sinkCtx, sinkFilter, "out", nil, nil, graph)
        guard srcRet >= 0, sinkRet >= 0 else {
            EngineLog.emit("[HDRToneMap] create_filter failed src=\(srcRet) sink=\(sinkRet) args=\(args)", category: .swPlayback)
            return nil
        }

        // BT.2020 PQ/HLG -> linear light, Hable tone-map to SDR range,
        // then encode to BT.709 (limited range) and pack to RGBA.
        let chain = "zscale=w=\(targetWidth):h=-2:t=linear:npl=100," +
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

        // KEEP_REF: without it, buffersrc TAKES the frame's references and
        // resets the input frame (w/h = 0). The caller's documented sws
        // fallback after a failed tone-map then operated on an emptied
        // frame and silently produced nil, exactly when it was needed.
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
