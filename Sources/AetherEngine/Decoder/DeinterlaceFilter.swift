import Foundation
import Libavfilter
import Libavutil

/// Deinterlacer selection + cadence for the software-decode path, resolved from `LoadOptions`
/// at load time and handed to `SoftwareVideoDecoder` before `open`.
struct DeinterlaceConfig: Sendable, Equatable {
    var mode: DeinterlaceMode = .auto
    var fieldRate: DeinterlaceFieldRate = .field
}

/// Persistent deinterlacing graph for the software-decode path (MPEG-2/VC-1/MPEG-4 and, per the
/// #107 routing rule, interlaced H.264, tvOS AVPlayer does not deinterlace, so 1080i/576i
/// broadcast routes here; see VideoRoutingPolicy).
///
/// Two engines:
/// - HARDWARE (`config.mode == .auto`, default): `format=nv12,hwupload,yadif_videotoolbox`, the
///   yadif kernel as a Metal compute shader over VideoToolbox frames. The sink emits
///   `AV_PIX_FMT_VIDEOTOOLBOX` frames wrapping IOSurface-backed CVPixelBuffers (`frame.data[3]`)
///   that go straight to the renderer, skipping the sws_scale copy. Runs at field rate by default
///   (`config.fieldRate`). Requires yadif_videotoolbox in the linked FFmpeg build (FFmpegBuild
///   >= 2.1) and a Metal device; any build failure disables hw for the session and falls back.
/// - SOFTWARE (fallback, or `config.mode == .software`): CPU bwdif (yadif for older linked
///   frameworks), always `mode=send_frame`, field rate without the GPU is the wrong cost trade.
///
/// MUST be persistent: yadif/bwdif are temporal filters that need a continuous frame stream.
/// `deint=interlaced` passes progressive frames through untouched.
/// Torn down on seek so stale temporal references never cross a discontinuity; lazily rebuilt on
/// the next interlaced frame. Not thread-safe; the owning decoder serializes access with its lock.
///
/// PTS contract: output frames carry PTS on `outputTimeBase` (the buffersink's time_base), NOT the
/// input stream time_base. yadif/bwdif halve their output link time_base and scale PTS by 2, and
/// with `mode=send_field` the two fields of a frame land on ODD/EVEN ticks of that halved base,
/// rescaling back to the stream base would collapse each pair onto one integer PTS (duplicate
/// timestamps, every other field dropped). Callers must timestamp with `outputTimeBase`.
final class DeinterlaceFilter {

    enum Engine: String { case hardware, software }

    /// Set by the owning decoder (under its lock) before the first `ensureGraph`.
    var config = DeinterlaceConfig()

    /// Which engine the current graph uses; nil when no graph is built.
    private(set) var engine: Engine?

    /// Time base of the filter output. Valid while `isActive`; see the PTS contract above.
    private(set) var outputTimeBase = AVRational(num: 0, den: 1)

    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var srcCtx: UnsafeMutablePointer<AVFilterContext>?
    private var sinkCtx: UnsafeMutablePointer<AVFilterContext>?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var pixFmt: Int32 = -1
    private var loggedUnavailable = false

    /// Latched on the first hardware graph failure: a missing filter or Metal device will not
    /// appear mid-session, so don't re-attempt (and re-log) on every geometry change.
    private var hwDisabled = false

    /// VideoToolbox hw device, created lazily for the hardware graph and kept across seek
    /// teardowns (device creation is not per-stream state).
    private var hwDeviceRef: UnsafeMutablePointer<AVBufferRef>?

    var isActive: Bool { graph != nil }

    static func prewarmHardwarePipeline() -> Bool {
        guard avfilter_get_by_name("yadif_videotoolbox") != nil,
              let frame = av_frame_alloc() else {
            return false
        }
        var ownedFrame: UnsafeMutablePointer<AVFrame>? = frame
        defer {
            av_frame_free(&ownedFrame)
        }

        frame.pointee.width = 64
        frame.pointee.height = 64
        frame.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        frame.pointee.pts = 0
        frame.pointee.flags |= (1 << 3)
        frame.pointee.sample_aspect_ratio = AVRational(num: 1, den: 1)
        guard av_frame_get_buffer(frame, 0) >= 0 else {
            return false
        }

        let filter = DeinterlaceFilter()
        filter.config = DeinterlaceConfig(mode: .auto, fieldRate: .field)
        defer {
            filter.teardown()
        }

        guard filter.ensureGraph(
            frame: frame,
            timeBase: AVRational(num: 1, den: 30)
        ) else {
            return false
        }
        return filter.engine == .hardware
    }

    /// Build (or rebuild after a parameter change) the graph for the given frame's geometry.
    /// Returns false when no deinterlacer is compiled into the linked FFmpeg build or graph setup
    /// fails; the caller then renders the frame directly (combing, but playing).
    func ensureGraph(frame: UnsafeMutablePointer<AVFrame>, timeBase: AVRational) -> Bool {
        if graph != nil,
           width == frame.pointee.width,
           height == frame.pointee.height,
           pixFmt == frame.pointee.format {
            return true
        }
        teardown()

        if config.mode == .auto, !hwDisabled {
            if buildGraph(frame: frame, timeBase: timeBase, engine: .hardware) {
                return true
            }
            // One-shot fallback: whatever failed (filter not in the linked build, no Metal
            // device, hwframes alloc) will keep failing; don't retry per geometry change.
            hwDisabled = true
            EngineLog.emit(
                "[Deinterlace] hardware graph unavailable; falling back to software",
                category: .swPlayback
            )
        }
        return buildGraph(frame: frame, timeBase: timeBase, engine: .software)
    }

    private func buildGraph(
        frame: UnsafeMutablePointer<AVFrame>,
        timeBase: AVRational,
        engine wanted: Engine
    ) -> Bool {
        // Engine-specific preconditions.
        switch wanted {
        case .hardware:
            guard avfilter_get_by_name("yadif_videotoolbox") != nil else {
                if !loggedUnavailable {
                    loggedUnavailable = true
                    EngineLog.emit(
                        "[Deinterlace] no yadif_videotoolbox in the linked FFmpeg build (needs FFmpegBuild >= 2.1)",
                        category: .swPlayback
                    )
                }
                return false
            }
            guard ensureHWDevice() else { return false }
        case .software:
            guard avfilter_get_by_name("bwdif") != nil || avfilter_get_by_name("yadif") != nil else {
                if !loggedUnavailable {
                    loggedUnavailable = true
                    EngineLog.emit(
                        "[Deinterlace] no bwdif/yadif in the linked FFmpeg build; rendering interlaced frames as-is",
                        category: .swPlayback
                    )
                }
                return false
            }
        }

        guard let g = avfilter_graph_alloc(),
              let bufferFilter = avfilter_get_by_name("buffer"),
              let sinkFilter = avfilter_get_by_name("buffersink") else {
            return false
        }
        var built = false
        var gOpt: UnsafeMutablePointer<AVFilterGraph>? = g
        defer { if !built { avfilter_graph_free(&gOpt) } }

        let sar = frame.pointee.sample_aspect_ratio
        let sarNum = sar.num > 0 ? sar.num : 1
        let sarDen = sar.den > 0 ? sar.den : 1
        var args = "video_size=\(frame.pointee.width)x\(frame.pointee.height)" +
                   ":pix_fmt=\(frame.pointee.format)" +
                   ":time_base=\(timeBase.num)/\(timeBase.den)" +
                   ":pixel_aspect=\(sarNum)/\(sarDen)"
        // Declare colorspace/range when the first frame carries them, so the buffer source's
        // link matches the incoming frames ("Changing video frame properties on the fly"
        // warning otherwise) and bt709/tv tagging survives onto the filtered output.
        if frame.pointee.colorspace != AVCOL_SPC_UNSPECIFIED {
            args += ":colorspace=\(frame.pointee.colorspace.rawValue)"
        }
        if frame.pointee.color_range != AVCOL_RANGE_UNSPECIFIED {
            args += ":range=\(frame.pointee.color_range.rawValue)"
        }

        var src: UnsafeMutablePointer<AVFilterContext>?
        var sink: UnsafeMutablePointer<AVFilterContext>?
        let srcRet = avfilter_graph_create_filter(&src, bufferFilter, "in", args, nil, g)
        let sinkRet = avfilter_graph_create_filter(&sink, sinkFilter, "out", nil, nil, g)
        guard srcRet >= 0, sinkRet >= 0, let srcC = src, let sinkC = sink else {
            EngineLog.emit(
                "[Deinterlace] create_filter failed src=\(srcRet) sink=\(sinkRet) args=\(args)",
                category: .swPlayback
            )
            return false
        }

        let chain: String
        switch wanted {
        case .hardware:
            // FFmpeg 8's hwupload validates its device ref at filter INIT, and
            // avfilter_graph_parse_ptr inits filters internally, before a device could be
            // attached post-parse ("A hardware device reference is required to upload frames
            // to", ret=-22). So the hw chain is built filter-by-filter: alloc, attach the
            // device, init, link.
            //
            // format=<sw>: sws converts the decoder's planar YUV to the bi-planar layout the
            // renderer wants BEFORE upload, so the sink's CVPixelBuffers are directly
            // displayable. hwupload: sw frame -> VideoToolbox hwframes ctx (IOSurface + Metal
            // compatible). deint=interlaced: progressive frames pass through (uploaded but
            // untouched).
            let swFmt = is10Bit(frame.pointee.format) ? "p010le" : "nv12"
            let mode = config.fieldRate == .field ? "send_field" : "send_frame"
            let deintOpts = "mode=\(mode):parity=auto:deint=interlaced"
            chain = "format=\(swFmt),hwupload,yadif_videotoolbox=\(deintOpts)"

            guard let formatFilter = avfilter_get_by_name("format"),
                  let uploadFilter = avfilter_get_by_name("hwupload"),
                  let deintFilter = avfilter_get_by_name("yadif_videotoolbox"),
                  let dev = hwDeviceRef else {
                return false
            }
            var fmtCtx: UnsafeMutablePointer<AVFilterContext>?
            let fmtRet = avfilter_graph_create_filter(&fmtCtx, formatFilter, "fmt", "pix_fmts=\(swFmt)", nil, g)
            guard fmtRet >= 0, let fmtC = fmtCtx,
                  let upC = avfilter_graph_alloc_filter(g, uploadFilter, "up"),
                  let deintC = avfilter_graph_alloc_filter(g, deintFilter, "deint") else {
                EngineLog.emit("[Deinterlace] hw filter alloc failed fmt=\(fmtRet)", category: .swPlayback)
                return false
            }
            upC.pointee.hw_device_ctx = av_buffer_ref(dev)
            deintC.pointee.hw_device_ctx = av_buffer_ref(dev)
            // yadif_videotoolbox init creates the Metal pipeline; failure here (no Metal
            // device, e.g. some CI VMs) is the fallback trigger.
            let upInit = avfilter_init_str(upC, nil)
            let deintInit = avfilter_init_str(deintC, deintOpts)
            guard upInit >= 0, deintInit >= 0 else {
                EngineLog.emit(
                    "[Deinterlace] hw filter init failed hwupload=\(upInit) yadif_vt=\(deintInit)",
                    category: .swPlayback
                )
                return false
            }
            guard avfilter_link(srcC, 0, fmtC, 0) >= 0,
                  avfilter_link(fmtC, 0, upC, 0) >= 0,
                  avfilter_link(upC, 0, deintC, 0) >= 0,
                  avfilter_link(deintC, 0, sinkC, 0) >= 0 else {
                EngineLog.emit("[Deinterlace] hw graph link failed", category: .swPlayback)
                return false
            }

        case .software:
            // bwdif is the primary (better edge reconstruction); yadif the fallback for older
            // linked frameworks. Always send_frame: see class doc. No hw device involved, so
            // the string-parse path is fine here.
            let filterName = avfilter_get_by_name("bwdif") != nil ? "bwdif" : "yadif"
            chain = "\(filterName)=mode=send_frame:parity=auto:deint=interlaced"

            var inputs = avfilter_inout_alloc()
            var outputs = avfilter_inout_alloc()
            defer { avfilter_inout_free(&inputs); avfilter_inout_free(&outputs) }
            guard inputs != nil, outputs != nil else { return false }
            outputs!.pointee.name = strdup("in")
            outputs!.pointee.filter_ctx = srcC
            outputs!.pointee.pad_idx = 0
            outputs!.pointee.next = nil
            inputs!.pointee.name = strdup("out")
            inputs!.pointee.filter_ctx = sinkC
            inputs!.pointee.pad_idx = 0
            inputs!.pointee.next = nil

            let parseRet = avfilter_graph_parse_ptr(g, chain, &inputs, &outputs, nil)
            guard parseRet >= 0 else {
                EngineLog.emit("[Deinterlace] parse_ptr failed ret=\(parseRet) chain=\(chain)", category: .swPlayback)
                return false
            }
        }

        let configRet = avfilter_graph_config(g, nil)
        guard configRet >= 0 else {
            EngineLog.emit(
                "[Deinterlace] graph_config failed ret=\(configRet) chain=\(chain)",
                category: .swPlayback
            )
            return false
        }

        built = true
        graph = g
        srcCtx = src
        sinkCtx = sink
        engine = wanted
        outputTimeBase = av_buffersink_get_time_base(sink)
        width = frame.pointee.width
        height = frame.pointee.height
        pixFmt = frame.pointee.format
        EngineLog.emit(
            "[Deinterlace] engaged [\(wanted.rawValue)]: \(width)x\(height) pixFmt=\(pixFmt) (\(chain)) outTB=\(outputTimeBase.num)/\(outputTimeBase.den)",
            category: .swPlayback
        )
        return true
    }

    /// Create (once) the VideoToolbox hw device the hardware graph uploads into.
    private func ensureHWDevice() -> Bool {
        if hwDeviceRef != nil { return true }
        let ret = av_hwdevice_ctx_create(&hwDeviceRef, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0)
        guard ret >= 0, hwDeviceRef != nil else {
            EngineLog.emit("[Deinterlace] videotoolbox hwdevice create failed ret=\(ret)", category: .swPlayback)
            return false
        }
        return true
    }

    /// True when the pixel format stores >8 bits per component (HDR10-class sources).
    private func is10Bit(_ format: Int32) -> Bool {
        guard let desc = av_pix_fmt_desc_get(AVPixelFormat(rawValue: format)) else { return false }
        return desc.pointee.comp.0.depth > 8
    }

    /// Feed a decoded frame (takes ownership; frame is reset after the call).
    func push(_ frame: UnsafeMutablePointer<AVFrame>) -> Int32 {
        guard let src = srcCtx else { return -1 }
        return av_buffersrc_add_frame_flags(src, frame, 0)
    }

    /// Pull the next filtered frame into `out`. Returns >= 0 on success, AVERROR(EAGAIN) when the
    /// filter needs more input. Output PTS is on `outputTimeBase` (see class doc), and for the
    /// hardware engine the frame is `AV_PIX_FMT_VIDEOTOOLBOX` (CVPixelBuffer in `data[3]`).
    func pull(into out: UnsafeMutablePointer<AVFrame>) -> Int32 {
        guard let sink = sinkCtx else { return -1 }
        return av_buffersink_get_frame(sink, out)
    }

    /// Free the graph. Called on seek (stale temporal references) and close; `ensureGraph` lazily
    /// rebuilds. The hw device ref survives teardown (not per-stream state); freed in deinit.
    func teardown() {
        if graph != nil {
            avfilter_graph_free(&graph)
        }
        graph = nil
        srcCtx = nil
        sinkCtx = nil
        engine = nil
        outputTimeBase = AVRational(num: 0, den: 1)
        width = 0
        height = 0
        pixFmt = -1
    }

    deinit {
        teardown()
        if hwDeviceRef != nil {
            av_buffer_unref(&hwDeviceRef)
        }
    }
}
