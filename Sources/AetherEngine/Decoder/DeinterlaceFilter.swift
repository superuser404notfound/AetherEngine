import Foundation
import AetherLibavfilter
import AetherLibavformat
import AetherLibavutil

/// Deinterlacer selection + cadence for the software-decode path, resolved from `LoadOptions`
/// at load time and handed to `SoftwareVideoDecoder` before `open`.
struct DeinterlaceConfig: Sendable, Equatable {
    var mode: DeinterlaceMode = .auto
    var fieldRate: DeinterlaceFieldRate = .field
    /// #853: match fields back into film frames and drop the repeated frame of each five around the
    /// deinterlacer (`fieldmatch` + `decimate`), for hard-telecined film. Decided at load.
    var inverseTelecine = false
    /// The video stream's frame rate, which the buffer source declares under inverse telecine:
    /// `decimate` refuses an input link without one. Unknown (0/1) keeps inverse telecine off.
    var sourceFrameRate = SourceFrameRate()

    struct SourceFrameRate: Sendable, Equatable {
        var num: Int32 = 0
        var den: Int32 = 1
        var isKnown: Bool { num > 0 && den > 0 }
        var framesPerSecond: Double? { isKnown ? Double(num) / Double(den) : nil }

        init(num: Int32 = 0, den: Int32 = 1) {
            self.num = num
            self.den = den
        }

        /// The stream's declared rate (`avg_frame_rate`, else `r_frame_rate`, as
        /// `AetherEngine.detectFrameRate` reads it), with the NTSC rates snapped to their exact
        /// rationals: a container that rounds 30000/1001 to 2997/100 would otherwise put
        /// `decimate`'s output a hair off 24000/1001.
        init(stream: UnsafeMutablePointer<AVStream>) {
            let avg = stream.pointee.avg_frame_rate
            let rate = avg.num > 0 && avg.den > 0 ? avg : stream.pointee.r_frame_rate
            guard rate.num > 0, rate.den > 0 else { self.init(); return }
            let fps = Double(rate.num) / Double(rate.den)
            if abs(fps - 30000.0 / 1001.0) < 0.01 {
                self.init(num: 30000, den: 1001)
            } else if abs(fps - 30) < 0.01 {
                self.init(num: 30, den: 1)
            } else {
                self.init(num: rate.num, den: rate.den)
            }
        }
    }
}

/// Persistent deinterlacing graph for the software-decode path (MPEG-2/VC-1/MPEG-4 and, per the
/// #107 routing rule, interlaced H.264, tvOS AVPlayer does not deinterlace, so 1080i/576i
/// broadcast routes here; see VideoRoutingPolicy).
///
/// Two engines:
/// - HARDWARE (`config.mode == .auto`, default): `format=nv12,hwupload,bwdif_videotoolbox`, bwdif
///   as a Metal compute shader over VideoToolbox frames, the same algorithm as the software engine
///   (AE#1102). `yadif_videotoolbox` takes over when the linked FFmpeg build has no
///   bwdif_videotoolbox or its graph fails to build. The sink emits `AV_PIX_FMT_VIDEOTOOLBOX` frames
///   wrapping IOSurface-backed CVPixelBuffers (`frame.data[3]`) that go straight to the renderer,
///   skipping the sws_scale copy. Runs at field rate by default (`config.fieldRate`). Needs a
///   Metal device; when every GPU filter has failed to build, or a GPU graph errors while
///   running, hw stays off for the session.
/// - SOFTWARE (fallback, or `config.mode == .software`): CPU bwdif (yadif for older linked
///   frameworks), always `mode=send_frame`, field rate without the GPU is the wrong cost trade.
///
/// Inverse telecine (#853, `config.inverseTelecine`) wraps either engine for hard-telecined film:
/// `fieldmatch` rebuilds the film frames from the fields, the deinterlacer then touches only the
/// frames `fieldmatch` could not match (it flags them interlaced, so `deint=interlaced` skips the
/// rest), and `decimate` drops the repeated frame of each five, 29.97 to 23.976 fps. Software:
/// `fieldmatch,bwdif,decimate`, the order the FFmpeg docs give. Hardware: the whole chain runs on
/// the GPU, `format=nv12,hwupload,fieldmatch_videotoolbox,decimate_videotoolbox,<gpu filter>`
/// (AE#1108). Those are Metal ports whose output equals the CPU filters; on an M1 they cost 30 to
/// 85% of the CPU time, least where `fieldmatch` is expensive (grain, HD). Where the linked build
/// lacks them, the stream is not 8-bit 4:2:0 with a height that is a multiple of 4, or they fail to
/// build or error while running, the cadence work stays on the CPU before the upload:
/// `fieldmatch,decimate,format,hwupload,<gpu filter>`. Always `send_frame`: at field rate the frame
/// count doubles before `decimate` and its 1-in-5 cycle no longer lines up with the pulldown.
/// `fieldmatch` runs `combmatch=full`, because only a match judged by comb scores flags the frames
/// it could not match (`interlaced_frame = combs[match] >= combpel`; the scores are never computed
/// otherwise). `decimate` stamps its output from the graph's first frame plus one 1001/24000 tick
/// per frame, so a rebuild (every seek) re-anchors it, and so does a gap in the input timestamps
/// (`breaksInverseTelecineCadence`).
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

    /// Latched once every GPU filter has failed: a missing filter or Metal device will not
    /// appear mid-session, so don't re-attempt (and re-log) on every geometry change.
    private var hwDisabled = false

    /// GPU deinterlacers, preferred first. bwdif_videotoolbox matches the software engine's bwdif;
    /// yadif_videotoolbox covers FFmpegBuild releases without it.
    static let hardwareFilterNames = ["bwdif_videotoolbox", "yadif_videotoolbox"]

    /// The GPU filters the linked FFmpeg build carries, in preference order.
    static let linkedHardwareFilters: [String] =
        hardwareFilterNames.filter { avfilter_get_by_name($0) != nil }

    /// GPU filters whose graph failed to build in this session; the next one takes over.
    private(set) var failedHardwareFilters: Set<String> = []

    /// VideoToolbox hw device, created lazily for the hardware graph and kept across seek
    /// teardowns (device creation is not per-stream state).
    private var hwDeviceRef: UnsafeMutablePointer<AVBufferRef>?

    var isActive: Bool { graph != nil }

    private var builtFilterName: String?

    /// True while the built graph runs inverse telecine (#853).
    private(set) var builtInverseTelecine = false
    /// Graphs built so far, so a caller can tell a build from the check of a graph already standing (AE#1112).
    private(set) var graphBuilds = 0

    /// True while that inverse telecine runs on the GPU (AE#1108).
    private(set) var builtInverseTelecineHardware = false

    /// Latched once the GPU cadence filters failed to build or errored. The next builds then keep the
    /// cadence work on the CPU instead of paying the failed attempt on every seek. Tests set it to
    /// pin the CPU cadence chain.
    var hwInverseTelecineDisabled = false

    /// The PTS (input time base) of the last frame pushed into an inverse telecine graph, for the
    /// cadence-gap check. nil while no such graph is built.
    private var lastInverseTelecinePTS: Int64?

    /// Logged once per filter instance when inverse telecine was asked for and cannot be built.
    private var loggedInverseTelecineUnavailable = false

    /// `fieldmatch` and `decimate` are both in the linked FFmpeg build (FFmpegBuild 3.11+).
    static let inverseTelecineFiltersLinked: Bool =
        avfilter_get_by_name("fieldmatch") != nil && avfilter_get_by_name("decimate") != nil

    /// The `fieldmatch` options of the playback chain. `combmatch=full`: see the class doc.
    static let inverseTelecineFieldMatchOptions = "order=auto:combmatch=full"
    static let inverseTelecineFieldMatch = "fieldmatch=\(inverseTelecineFieldMatchOptions)"

    /// AE#1108: `fieldmatch_videotoolbox` and `decimate_videotoolbox` are in the linked FFmpeg build.
    static let hardwareInverseTelecineFiltersLinked: Bool =
        avfilter_get_by_name("fieldmatch_videotoolbox") != nil
        && avfilter_get_by_name("decimate_videotoolbox") != nil

    /// Whether the GPU inverse telecine chain gives the CPU chain's pictures for this frame.
    /// - 8-bit 4:2:0 only. The ports read NV12, and the `format=nv12` ahead of them is then a repack.
    ///   For 4:2:2 or 4:4:4 it would subsample chroma across the two fields of a combed frame before
    ///   `fieldmatch` separates them, which the CPU chain never does.
    /// - A height that is a multiple of 4. On a plane with an odd row count the CPU filter reads a row
    ///   it never wrote, so the GPU port refuses such a frame.
    /// - At least 32x16, the port's minimum.
    static func hardwareInverseTelecineAccepts(width: Int32, height: Int32, pixelFormat: Int32) -> Bool {
        guard let desc = av_pix_fmt_desc_get(AVPixelFormat(rawValue: pixelFormat)) else { return false }
        let d = desc.pointee
        let isHardwareFormat = d.flags & UInt64(AV_PIX_FMT_FLAG_HWACCEL) != 0
        return !isHardwareFormat && d.nb_components >= 3 && d.comp.0.depth == 8
            && d.log2_chroma_w == 1 && d.log2_chroma_h == 1
            && height % 4 == 0 && width >= 32 && height >= 16
    }

    /// The built graph as the public report describes it (AE#983); nil while no graph is built.
    var activeDeinterlace: VideoDeinterlace? {
        guard let engine, let builtFilterName else { return nil }
        return VideoDeinterlace(filter: builtFilterName, isHardware: engine == .hardware,
                                fieldRate: engine == .hardware && !builtInverseTelecine ? config.fieldRate : .frame,
                                inverseTelecine: builtInverseTelecine,
                                inverseTelecineIsHardware: builtInverseTelecineHardware)
    }

    /// Inverse telecine for the next build: asked for, with a known source rate (the buffer source
    /// must declare it for `decimate`), and both filters linked. Logs once why not.
    private func inverseTelecineBuildable() -> Bool {
        guard config.inverseTelecine else { return false }
        let missing: String? = !Self.inverseTelecineFiltersLinked
            ? "no fieldmatch / decimate in the linked FFmpeg build"
            : (!config.sourceFrameRate.isKnown ? "the stream states no frame rate" : nil)
        guard let missing else { return true }
        if !loggedInverseTelecineUnavailable {
            loggedInverseTelecineUnavailable = true
            EngineLog.emit("[Deinterlace] inverse telecine unavailable (\(missing)); deinterlacing instead (#853)",
                           category: .swPlayback)
        }
        return false
    }

    static func prewarmHardwarePipeline() -> Bool {
        guard !linkedHardwareFilters.isEmpty,
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
        // AE#1108: the GPU cadence filters load their Metal library and pipelines at init too, so a
        // film session's first build does not compile them on the decode thread.
        if filter.engine == .hardware, hardwareInverseTelecineFiltersLinked {
            let cadence = DeinterlaceFilter()
            cadence.config = DeinterlaceConfig(mode: .auto, fieldRate: .frame, inverseTelecine: true,
                                               sourceFrameRate: .init(num: 30000, den: 1001))
            _ = cadence.ensureGraph(frame: frame, timeBase: AVRational(num: 1001, den: 30000))
            cadence.teardown()
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
        if passthroughLatched { return false }

        if config.mode == .auto, !hwDisabled {
            let candidates = Self.linkedHardwareFilters.filter { !failedHardwareFilters.contains($0) }
            if candidates.isEmpty, !loggedUnavailable, failedHardwareFilters.isEmpty {
                loggedUnavailable = true
                EngineLog.emit(
                    "[Deinterlace] no GPU deinterlacer (\(Self.hardwareFilterNames.joined(separator: " / "))) in the linked FFmpeg build",
                    category: .swPlayback
                )
            }
            for name in candidates {
                let triedGPUCadence = wantsHardwareInverseTelecine(frame: frame)
                if triedGPUCadence, buildGraph(frame: frame, timeBase: timeBase, engine: .hardware,
                                               hardwareFilter: name, inverseTelecineOnGPU: true) {
                    return true
                }
                if buildGraph(frame: frame, timeBase: timeBase, engine: .hardware, hardwareFilter: name) {
                    // The same deinterlacer builds with the CPU cadence, so the GPU cadence filters were
                    // what failed. When it does not, the deinterlacer or the device is at fault, and the
                    // next candidate tries the GPU cadence again.
                    if triedGPUCadence {
                        hwInverseTelecineDisabled = true
                        EngineLog.emit("[Deinterlace] GPU inverse telecine filters failed to build; "
                                       + "fieldmatch / decimate stay on the CPU (AE#1108)", category: .swPlayback)
                    }
                    return true
                }
                failedHardwareFilters.insert(name)
            }
            // One-shot fallback: whatever failed (no Metal device, hwframes alloc) will keep
            // failing; don't retry per geometry change. The prewarm ran this same order, so the
            // filter that builds here had its Metal pipeline compiled already.
            hwDisabled = true
            EngineLog.emit(
                "[Deinterlace] hardware graph unavailable; falling back to software",
                category: .swPlayback
            )
        }
        return buildGraph(frame: frame, timeBase: timeBase, engine: .software)
    }

    /// AE#1108: the next hardware build should try the GPU cadence filters.
    private func wantsHardwareInverseTelecine(frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        guard config.inverseTelecine, !hwInverseTelecineDisabled, Self.hardwareInverseTelecineFiltersLinked,
              Self.hardwareInverseTelecineAccepts(width: frame.pointee.width, height: frame.pointee.height,
                                                  pixelFormat: frame.pointee.format) else {
            return false
        }
        return inverseTelecineBuildable()
    }

    private func buildGraph(
        frame: UnsafeMutablePointer<AVFrame>,
        timeBase: AVRational,
        engine wanted: Engine,
        hardwareFilter: String? = nil,
        inverseTelecineOnGPU: Bool = false
    ) -> Bool {
        // AE#492: the build cost belongs on the line that reports the build. A seek tears the graph
        // down, so this is paid per seek on interlaced sources and never on progressive ones, and
        // without the number the two are not comparable.
        let buildStart = DispatchTime.now()
        // Engine-specific preconditions.
        switch wanted {
        case .hardware:
            guard hardwareFilter != nil, ensureHWDevice() else { return false }
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
        // #853: decimate's output rate is the input link's rate times 4/5, and a link with no rate
        // (0/1) fails the graph, so an inverse telecine graph declares the stream's.
        let inverseTelecine = inverseTelecineBuildable()
        if inverseTelecine {
            args += ":frame_rate=\(config.sourceFrameRate.num)/\(config.sourceFrameRate.den)"
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
            // #853: never field rate under inverse telecine, see the class doc.
            let mode = config.fieldRate == .field && !inverseTelecine ? "send_field" : "send_frame"
            let deintOpts = "mode=\(mode):parity=auto:deint=interlaced"
            let hardwareFilter = hardwareFilter ?? ""
            let gpuCadence = inverseTelecine && inverseTelecineOnGPU
            if gpuCadence {
                chain = "format=\(swFmt),hwupload,fieldmatch_videotoolbox=\(Self.inverseTelecineFieldMatchOptions),"
                    + "decimate_videotoolbox,\(hardwareFilter)=\(deintOpts)"
            } else {
                chain = (inverseTelecine ? "\(Self.inverseTelecineFieldMatch),decimate," : "")
                    + "format=\(swFmt),hwupload,\(hardwareFilter)=\(deintOpts)"
            }

            guard let formatFilter = avfilter_get_by_name("format"),
                  let uploadFilter = avfilter_get_by_name("hwupload"),
                  let deintFilter = avfilter_get_by_name(hardwareFilter),
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
            // The filter's init creates the Metal pipeline; failure here (no Metal device, e.g.
            // some CI VMs) is the fallback trigger.
            let upInit = avfilter_init_str(upC, nil)
            let deintInit = avfilter_init_str(deintC, deintOpts)
            guard upInit >= 0, deintInit >= 0 else {
                EngineLog.emit(
                    "[Deinterlace] hw filter init failed hwupload=\(upInit) \(hardwareFilter)=\(deintInit)",
                    category: .swPlayback
                )
                return false
            }
            // #853: CPU fieldmatch and decimate take CPU frames only, so they sit between the source
            // and the format conversion. AE#1108: their GPU ports sit between the upload and the
            // deinterlacer and take their frames context from the upload's link.
            var head = srcC
            var gpuTail = upC
            if gpuCadence {
                guard let decimateC = linkCadenceFilters(after: upC, in: g, onGPU: true) else { return false }
                gpuTail = decimateC
            } else if inverseTelecine {
                guard let decimateC = linkCadenceFilters(after: srcC, in: g, onGPU: false) else { return false }
                head = decimateC
            }
            guard avfilter_link(head, 0, fmtC, 0) >= 0,
                  avfilter_link(fmtC, 0, upC, 0) >= 0,
                  avfilter_link(gpuTail, 0, deintC, 0) >= 0,
                  avfilter_link(deintC, 0, sinkC, 0) >= 0 else {
                EngineLog.emit("[Deinterlace] hw graph link failed", category: .swPlayback)
                return false
            }

        case .software:
            // bwdif is the primary (better edge reconstruction); yadif the fallback for older
            // linked frameworks. Always send_frame: see class doc. No hw device involved, so
            // the string-parse path is fine here.
            let filterName = avfilter_get_by_name("bwdif") != nil ? "bwdif" : "yadif"
            let deinterlace = "\(filterName)=mode=send_frame:parity=auto:deint=interlaced"
            chain = inverseTelecine ? "\(Self.inverseTelecineFieldMatch),\(deinterlace),decimate" : deinterlace

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
        graphBuilds &+= 1
        graph = g
        srcCtx = src
        sinkCtx = sink
        engine = wanted
        builtFilterName = wanted == .hardware ? hardwareFilter
            : (avfilter_get_by_name("bwdif") != nil ? "bwdif" : "yadif")
        builtInverseTelecine = inverseTelecine
        builtInverseTelecineHardware = inverseTelecine && inverseTelecineOnGPU && wanted == .hardware
        lastInverseTelecinePTS = nil
        outputTimeBase = av_buffersink_get_time_base(sink)
        width = frame.pointee.width
        height = frame.pointee.height
        pixFmt = frame.pointee.format
        let buildMs = Double(DispatchTime.now().uptimeNanoseconds - buildStart.uptimeNanoseconds) / 1e6
        EngineLog.emit(
            "[Deinterlace] engaged [\(wanted.rawValue)]: \(width)x\(height) pixFmt=\(pixFmt) (\(chain)) outTB=\(outputTimeBase.num)/\(outputTimeBase.den) built in \(String(format: "%.1f", buildMs))ms",
            category: .swPlayback
        )
        return true
    }

    /// Creates `fieldmatch` and `decimate` (or their `_videotoolbox` ports) and links
    /// `upstream -> fieldmatch -> decimate`. Returns `decimate`, or nil when either fails.
    private func linkCadenceFilters(after upstream: UnsafeMutablePointer<AVFilterContext>,
                                    in g: UnsafeMutablePointer<AVFilterGraph>,
                                    onGPU: Bool) -> UnsafeMutablePointer<AVFilterContext>? {
        let suffix = onGPU ? "_videotoolbox" : ""
        guard let matchFilter = avfilter_get_by_name("fieldmatch" + suffix),
              let decimateFilter = avfilter_get_by_name("decimate" + suffix) else { return nil }
        var matchCtx: UnsafeMutablePointer<AVFilterContext>?
        var decimateCtx: UnsafeMutablePointer<AVFilterContext>?
        let matchRet = avfilter_graph_create_filter(&matchCtx, matchFilter, "match",
                                                    Self.inverseTelecineFieldMatchOptions, nil, g)
        let decimateRet = avfilter_graph_create_filter(&decimateCtx, decimateFilter, "decimate", nil, nil, g)
        guard matchRet >= 0, decimateRet >= 0, let matchC = matchCtx, let decimateC = decimateCtx,
              avfilter_link(upstream, 0, matchC, 0) >= 0,
              avfilter_link(matchC, 0, decimateC, 0) >= 0 else {
            EngineLog.emit("[Deinterlace] inverse telecine filters failed fieldmatch\(suffix)=\(matchRet) "
                           + "decimate\(suffix)=\(decimateRet)", category: .swPlayback)
            return nil
        }
        return decimateC
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

    /// Feed a decoded frame. KEEP_REF (DEC-202): buffersrc takes its own reference and leaves `frame`
    /// intact, so a failed push really can fall through to "render as-is" instead of emitting a frame the
    /// call had emptied. The caller unrefs the frame after a successful push.
    func push(_ frame: UnsafeMutablePointer<AVFrame>) -> Int32 {
        guard let src = srcCtx else { return -1 }
        let ret = av_buffersrc_add_frame_flags(src, frame, Int32(AV_BUFFERSRC_FLAG_KEEP_REF))
        if ret >= 0, builtInverseTelecine, frame.pointee.pts != Int64.min {
            lastInverseTelecinePTS = frame.pointee.pts
        }
        return ret
    }

    /// #853: `decimate` stamps its output from the graph's first frame plus one tick per frame it
    /// keeps, never from the frames' own timestamps. A source frame that never arrives (a damaged or
    /// cut stream) would then move every later picture against the audio for as long as the graph
    /// lives. True when `frame` lands more than 1.75 source frame durations after the previous push
    /// into an inverse telecine graph (one missing frame is 2; a soft-telecine frame that repeats a
    /// field is 1.5 and rounds either side of it at 90 kHz, so a threshold of 1.5 rebuilt the graph on
    /// every other such frame): the caller flushes the graph and lets this frame build a fresh
    /// one, which anchors on it. A timestamp going backwards (a seam the decoder did not flush) is
    /// the same discontinuity. A repeated timestamp is not: `decimate` ignores input timestamps.
    func breaksInverseTelecineCadence(_ frame: UnsafeMutablePointer<AVFrame>, timeBase: AVRational) -> Bool {
        guard builtInverseTelecine, let last = lastInverseTelecinePTS, frame.pointee.pts != Int64.min,
              let rate = config.sourceFrameRate.framesPerSecond, rate > 0, timeBase.num > 0, timeBase.den > 0 else {
            return false
        }
        let delta = Double(frame.pointee.pts - last) * Double(timeBase.num) / Double(timeBase.den)
        return delta > 1.75 / rate || delta < 0
    }

    /// DEC-203: tells the graph no more input is coming, so yadif/bwdif release the frame they hold as
    /// `cur` while they wait for `next` (they synthesise the missing one on EOF). Pull until the sink
    /// reports EOF after this. The graph is spent afterwards; the caller tears it down.
    func sendEndOfStream() -> Int32 {
        guard let src = srcCtx else { return -1 }
        return av_buffersrc_add_frame_flags(src, nil, 0)
    }

    /// Graph errors survived in this session. A hardware graph that errors falls back to software for
    /// the rebuild, and a software graph that keeps erroring stops being rebuilt (frames render as-is).
    private(set) var graphErrorCount = 0
    static let maxGraphErrors = 3
    private var passthroughLatched = false

    /// DEC-202: libavfilter latches a filter error on the link, so every later `pull` returns it at once
    /// and every pushed frame piles up in the buffersrc FIFO. A pull result that is neither a frame, EAGAIN
    /// nor EOF is therefore terminal for this graph: drop it, and let the next interlaced frame build a
    /// fresh one. Returns true when `code` was such an error.
    @discardableResult
    func noteGraphError(afterPull code: Int32) -> Bool {
        guard code < 0, code != FFmpegErr.eagain, code != FFmpegErr.eof else { return false }
        graphErrorCount += 1
        let wasHardware = engine == .hardware
        let wasGPUCadence = builtInverseTelecineHardware
        teardown()
        // A running GPU graph that errors goes straight to software, not to the next GPU filter:
        // the cause is usually the device (hwupload ENOMEM, IOSurface pressure) and would hit the
        // next filter too, and only the first filter's pipeline was warmed.
        // AE#1108: a graph with the GPU cadence filters first gives up only those and keeps the GPU
        // deinterlacer, which is far cheaper than the software chain. If the device was at fault,
        // the next hardware graph errors too and goes to software as above.
        if wasGPUCadence {
            hwInverseTelecineDisabled = true
        } else if wasHardware {
            hwDisabled = true
        }
        if graphErrorCount >= Self.maxGraphErrors { passthroughLatched = true }
        EngineLog.emit(
            "[Deinterlace] graph error \(FFmpegErr.text(for: code)), graph dropped "
            + "(\(graphErrorCount)/\(Self.maxGraphErrors))"
            + (passthroughLatched ? "; rendering interlaced frames as-is from here" : ""),
            category: .swPlayback
        )
        return true
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
        builtFilterName = nil
        builtInverseTelecine = false
        builtInverseTelecineHardware = false
        lastInverseTelecinePTS = nil
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
