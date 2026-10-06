import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import AetherLibswscale

/// libavcodec software video decoder for codecs without VideoToolbox support (e.g. AV1/dav1d on Apple TV).
/// Uses sws_scale (SIMD/NEON-optimized) for YUV→NV12/P010 conversion; required to hit 24fps at 1080p for AV1.
final class SoftwareVideoDecoder: VideoDecodingPipeline, @unchecked Sendable {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    // FFmpeg 8.x exposes SwsContext as a real struct (7.x was OpaquePointer); pointer type must match or call sites miscompile.
    private var swsContext: UnsafeMutablePointer<SwsContext>?
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)
    var onFrame: DecodedFrameHandler?

    /// Fires once (demux thread) on first HDR10+ side data; engine flips videoFormat to .hdr10Plus.
    private var seenHDR10Plus = false
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?

    /// AE#658: fires (decode thread) on the first displayed frame and whenever the decoded format or the
    /// display buffer's format changes. Guarded by `lock`, like everything `emit` reads.
    var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
    private var decodedFormatKey: DecodedFormatKey?
    private var reportedFormatKey: DecodedFormatKey?

    /// The decoder's own output, taken before a deinterlace graph can rewrite the frame (the hardware
    /// graph hands `emit` a VideoToolbox surface whose pixel format says nothing about the decode).
    struct DecodedFormatKey: Equatable {
        var pixelFormat: Int32
        var color: ColorDescription
        var pixelBufferType: OSType = 0
    }

    /// True when the source is >8-bit (HDR10, AV1 HDR).
    private var use10Bit = false

    /// Container-declared SAR fallback for anamorphic DVD/SD content (NTSC 720x480, PAL 720x576, widescreen DVDs).
    /// Native VideoToolbox gets this from the container automatically; the software path must attach it explicitly.
    private var streamSAR = AVRational(num: 1, den: 1)

    /// #177: first sane non-square SAR of the stream. Once latched, every frame attaches this value;
    /// interlaced sources can oscillate SAR per-field and a garbage AVCodecContext value (1088:1 seen
    /// in the field) must never flicker the display geometry. Guarded by `lock` (set inside emit).
    private var latchedSAR: AVRational?
    private var loggedSARLatch = false
    /// #290: one line per stream when a declared SAR is dropped for the aspect it produces, so a
    /// smeared picture names its own cause instead of looking like a renderer bug.
    private var loggedSARReject = false

    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolFormat = OutputFormat(tenBit: false, fullRange: false)
    /// The format the last converted frame asked for, so a change is logged once (release-visible) rather
    /// than per frame. Guarded by `lock`, like the pool.
    private var loggedOutputFormat: OutputFormat?

    /// Skip pre-seek frames; decoded for reference but not converted.
    /// Guarded by `skipLock` not `lock`: emit() runs with `lock` held, so a same-lock accessor would deadlock.
    /// CMTime is multi-word: old unsynchronized access was a torn-read candidate.
    var skipUntilPTS: CMTime? {
        get { skipLock.lock(); defer { skipLock.unlock() }; return _skipUntilPTS }
        set { skipLock.lock(); _skipUntilPTS = newValue; skipLock.unlock() }
    }
    private var _skipUntilPTS: CMTime?

    /// AE#492: guarded by `lock`, the same one `flush()` and `decode(packet:epoch:)` take.
    private var _feedEpoch: UInt64 = 0
    var feedEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }; return _feedEpoch
    }
    private let skipLock = NSLock()

    /// Clear the skip threshold only if it is still the one we acted on.
    private func clearSkip(ifStillAt threshold: CMTime) {
        skipLock.lock()
        if let current = _skipUntilPTS, CMTimeCompare(current, threshold) == 0 {
            _skipUntilPTS = nil
        }
        skipLock.unlock()
    }

    // MARK: [MovieClaw P31] 跳转后追落点时少干活
    //
    // 跳转按关键帧 / 时间表落在目标之前，目标之前的帧只是为了把解码状态带到落点，一帧都不显示。原来它们照样
    // 全解、照样去隔行：真机 DVD《哪吒闹海》时间表 43 秒一格，跳转后追 23 秒内容用了 3 秒（约 8 倍速），期间画面冻住。
    // 离落点超过 1 秒的包让解码器跳过不被参考的帧（MPEG-2 / H.264 / HEVC 的 B 帧，丢了不影响后面任何帧）；
    // 离落点超过 0.25 秒解出来的帧直接丢，不进去隔行
    nonisolated static let catchUpDiscardMarginSeconds = 1.0
    nonisolated static let catchUpFilterMarginSeconds = 0.25
    private var catchUpDiscarding = false
    private var catchUpFramesSkipped = 0

    /// `pts`（本流时间基）落在跳帧门槛之前超过 `margin` 秒。调用方持有 lock
    private func isFarBeforeSkipThreshold(pts: Int64, margin: Double) -> Bool {
        guard pts != Int64.min, timeBase.den > 0, let threshold = skipUntilPTS, threshold.isNumeric else { return false }
        let seconds = Double(pts) * Double(timeBase.num) / Double(timeBase.den)
        return seconds < threshold.seconds - margin
    }

    /// 按这个包离落点多远，切换解码器是否跳过不被参考的帧。没有时间戳的包沿用上一个包的决定。调用方持有 lock
    private func applyCatchUpDiscard(_ ctx: UnsafeMutablePointer<AVCodecContext>, packet: UnsafeMutablePointer<AVPacket>) {
        let stamp = packet.pointee.dts != Int64.min ? packet.pointee.dts : packet.pointee.pts
        let far: Bool
        if skipUntilPTS == nil {
            far = false
        } else if stamp == Int64.min {
            return
        } else {
            far = isFarBeforeSkipThreshold(pts: stamp, margin: Self.catchUpDiscardMarginSeconds)
        }
        guard far != catchUpDiscarding else { return }
        catchUpDiscarding = far
        ctx.pointee.skip_frame = far ? AVDISCARD_NONREF : AVDISCARD_DEFAULT
        if !far, catchUpFramesSkipped > 0 {
            EngineLog.emit("[SWDecoder] [MovieClaw P31] 追落点：跳过 \(catchUpFramesSkipped) 帧的去隔行与显示准备",
                           category: .swPlayback)
            catchUpFramesSkipped = 0
        }
    }

    /// Protects codecContext across the demux thread (decode) and main thread (close/flush).
    private let lock = NSLock()

    /// Deinterlacer for interlaced MPEG-2/VC-1/MPEG-4 (DVD rips, SD broadcast); see DeinterlaceFilter class doc.
    /// Engaged lazily on first interlaced frame; every subsequent frame routes through it. Guarded by `lock`.
    private let deinterlacer = DeinterlaceFilter()

    /// Deinterlacer selection + cadence from LoadOptions. Set by the host BEFORE `open`;
    /// applied to the filter there (mutating it mid-stream would need a graph rebuild).
    var deinterlaceConfig = DeinterlaceConfig()

    /// #544: decode on the calling thread with no frame-level threading. Set before `open`; the
    /// still extractor is the only caller, everything on a playback path wants the parallel default.
    var decodesSingleThreaded = false

    /// The pixel buffer format this decoder hands the display layer, read off the decoded frame (audit
    /// DEC-107). The container's declaration alone missed two cases: `color_range` was never read, so a
    /// full-range AV1 / VP9 / HEVC picture was labelled video range and shown crushed, and
    /// `bits_per_raw_sample` is 0 for libdav1d and the AV1 / VP9 parsers, so a 10-bit SDR stream was
    /// dithered down to 8 bit.
    struct OutputFormat: Equatable {
        var tenBit: Bool
        var fullRange: Bool

        var pixelFormatType: OSType {
            switch (tenBit, fullRange) {
            case (false, false): return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            case (false, true): return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            case (true, false): return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            case (true, true): return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            }
        }

        var swscaleFormat: AVPixelFormat { tenBit ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12 }
    }

    /// `streamIs10Bit` is the open-time verdict (declared depth or an HDR transfer) and only ever widens
    /// the answer. The range is a LABEL: the legacy `sws_scale` reads a source's range from the pixel
    /// format alone (the yuvj family), so a full-range frame in a plain 4:2:0 format is copied across
    /// untouched and only has to be tagged as what it is. Asking swscale to convert would take 4K off its
    /// unscaled NV12 / P010 path, and a yuvj source IS converted to video range by swscale itself, so it
    /// stays video range here.
    nonisolated static func outputFormat(pixelFormat: Int32, colorRange: AVColorRange,
                                         streamIs10Bit: Bool) -> OutputFormat {
        let format = AVPixelFormat(rawValue: pixelFormat)
        let depth = av_pix_fmt_desc_get(format)?.pointee.comp.0.depth ?? 8
        let convertedBySwscale: Bool
        switch format {
        case AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUVJ444P, AV_PIX_FMT_YUVJ440P:
            convertedBySwscale = true
        default:
            convertedBySwscale = false
        }
        return OutputFormat(tenBit: streamIs10Bit || depth > 8,
                            fullRange: colorRange == AVCOL_RANGE_JPEG && !convertedBySwscale)
    }

    /// AE#499: what the container declared about colour, captured at `open` before a single frame
    /// exists. A decoded frame carries the VUI alone, and a remux whose VUI is empty would otherwise
    /// reach `attachColorSpace` as an untagged picture, so an HDR10 file decoded in software lost its
    /// PQ / BT.2020 attachments while the same file through the hardware decoder (which reads
    /// `codecpar`) kept them. Written once in `open`, before the host can feed a packet, and read on
    /// the decode thread afterwards, the same discipline `use10Bit` and the other open-time fields keep.
    private var containerColor = ColorDescription.unspecified

    /// Deinterlaced frames dropped for carrying no PTS (see the drop site in decode()). Guarded by `lock`.
    private var droppedUntimestampedFields = 0

    /// #407: frames whose PTS was reconstructed from `best_effort_timestamp` (see the repair site
    /// in drainDecodedFrames()). Guarded by `lock`.
    private var repairedTimestamps = 0

    /// GPU-side copy from the hw-deinterlace filter's pool buffers into `pixelBufferPool` (see
    /// the VT branch in emit()). Created lazily on the first hw frame; guarded by `lock`.
    private var transferSession: VTPixelTransferSession?
    private var loggedTransferFailure = false

    /// #220: a send failure that survives the drain-and-retry is release-visible once per
    /// decoder, so a wedge that is a genuine decode error is distinguishable in a field log
    /// from one that is not.
    private var loggedSendFailure = false

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        self.onFrame = onFrame
        deinterlacer.config = deinterlaceConfig

        guard let codecpar = stream.pointee.codecpar else {
            throw VideoDecoderError.noCodecParameters
        }

        timeBase = stream.pointee.time_base

        // Container SAR fallback; see streamSAR. Frames usually carry their own (MPEG-2 seq header, from frame 1).
        //
        // Both fields, because they carry different sources and only one of them is the container's.
        // `codecpar` holds what the bitstream declared (mpegts/mpeg-ps fill it from the parser), while
        // a container-declared ratio reaches AVStream alone: Matroska writes its DisplayWidth quotient
        // to `st->sample_aspect_ratio` (matroskadec.c) and MP4 does the same with `pasp` (mov.c),
        // leaving codecpar at 0:1. Reading codecpar alone left this fallback dead in exactly the case
        // it exists for, an anamorphic source whose ratio lives in the container rather than in the
        // stream, which is every DVD remuxed to MKV in a codec whose bitstream cannot carry SAR.
        streamSAR = Self.declaredStreamSAR(
            bitstream: codecpar.pointee.sample_aspect_ratio,
            container: stream.pointee.sample_aspect_ratio
        )

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw VideoDecoderError.unsupportedCodec(id: codecpar.pointee.codec_id.rawValue)
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            throw VideoDecoderError.sessionCreationFailed(status: -1)
        }
        codecContext = ctx

        guard avcodec_parameters_to_context(ctx, codecpar) >= 0 else {
            throw VideoDecoderError.noCodecParameters
        }

        // Reject VideoToolbox pixel format to force pure software decode (some decoders ignore this).
        ctx.pointee.get_format = { _, fmts in
            guard let fmts = fmts else { return AV_PIX_FMT_NONE }
            var i = 0
            while fmts[i] != AV_PIX_FMT_NONE {
                if fmts[i] != AV_PIX_FMT_VIDEOTOOLBOX {
                    return fmts[i]
                }
                i += 1
            }
            return AV_PIX_FMT_YUV420P
        }

        if decodesSingleThreaded {
            // #544: a still run is one short GOP decoded once. Frame-level threading buys throughput
            // nobody is waiting for and costs output delay plus a second worker pool.
            ctx.pointee.thread_count = 1
            ctx.pointee.thread_type = 0
        } else {
            ctx.pointee.thread_count = Int32(ProcessInfo.processInfo.activeProcessorCount)
            ctx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
        }

        // Belt-and-suspenders hwaccel=none: some decoders ignore get_format.
        var opts: OpaquePointer?
        av_dict_set(&opts, "hwaccel", "none", 0)

        guard avcodec_open2(ctx, codec, &opts) >= 0 else {
            av_dict_free(&opts)
            throw VideoDecoderError.sessionCreationFailed(status: -2)
        }
        av_dict_free(&opts)

        containerColor = ColorDescription(codecpar: codecpar)
        let bitsPerSample = codecpar.pointee.bits_per_raw_sample
        let isHDRTransfer = ColorAttachments.isHDRTransfer(codecpar.pointee.color_trc)
        use10Bit = bitsPerSample > 8 || isHDRTransfer

        // Release-visible log (no #if DEBUG): needed for TestFlight users and DrHurt #4 black-screen reports.
        EngineLog.emit("[SWDecoder] Opened: \(codecpar.pointee.width)x\(codecpar.pointee.height), codec=\(String(cString: codec.pointee.name)), threads=\(ctx.pointee.thread_count), \(use10Bit ? "10-bit" : "8-bit")", category: .swPlayback)
    }

    /// #407: the timestamp to put on a decoded frame that carries none, or nil when the frame is
    /// already timed (the common case, and the one that must stay untouched: a decoder-set PTS is
    /// always at least as good as the reconstruction, and `best_effort_timestamp` can trail it).
    ///
    /// `AV_NOPTS_VALUE` is `Int64.min`. `best_effort_timestamp` is libavcodec's own
    /// `guess_correct_pts(pts, pkt_dts)`, so a frame with neither cannot be timed by any means the
    /// decoder has and stays unschedulable; the layer below drops it rather than wedging the queue.
    static func repairedPTS(pts: Int64, bestEffort: Int64) -> Int64? {
        guard pts == Int64.min, bestEffort != Int64.min else { return nil }
        return bestEffort
    }

    /// What to do with a packet after `avcodec_send_packet` returned `ret` (#220).
    enum PacketSendDisposition: Equatable {
        /// The decoder took the packet.
        case accepted
        /// `AVERROR(EAGAIN)`: the packet was NOT consumed. The decoder's output queue is full
        /// and has to be read before it accepts more input, which is legal at any time under
        /// frame threading (a packet that yields no frame, reorder delay, thread_count packets
        /// in flight). Drain, then send the same packet again.
        case drainAndRetry
        /// A real decode error. Drop the packet; the decoder stays usable for the next one.
        case dropped
    }

    nonisolated static func disposition(forSendResult ret: Int32) -> PacketSendDisposition {
        if ret >= 0 { return .accepted }
        return ret == FFmpegErr.eagain ? .drainAndRetry : .dropped
    }

    /// Feed one packet and deliver whatever the decoder produces.
    ///
    /// #220: this used to `return` on any negative send result without draining. EAGAIN is not
    /// an error, and returning on it both dropped the packet and left the output queue full, so
    /// every subsequent send hit the same wall: video wedged permanently until a seek flushed
    /// the decoder, while audio kept playing.
    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64? = nil) {
        lock.lock()
        // AE#492: a packet decided on before a flush must not be sent after it. Checked here rather
        // than at the caller because only this lock orders the two: `flush()` takes it to retire the
        // epoch, so either the send happens first and the flush drops what it produced, or the flush
        // happens first and the send never runs.
        if let epoch, epoch != _feedEpoch { lock.unlock(); return }
        guard let ctx = codecContext else { lock.unlock(); return }
        applyCatchUpDiscard(ctx, packet: packet)
        var sendRet = avcodec_send_packet(ctx, packet)
        lock.unlock()

        if Self.disposition(forSendResult: sendRet) == .drainAndRetry {
            drainDecodedFrames()
            lock.lock()
            // Audit DEC-1: the drain drops the lock between frames, so a flush can land in it.
            if let epoch, epoch != _feedEpoch { lock.unlock(); return }
            sendRet = codecContext == nil ? FFmpegErr.einval : avcodec_send_packet(ctx, packet)
            lock.unlock()
        }
        if Self.disposition(forSendResult: sendRet) == .dropped, !loggedSendFailure {
            loggedSendFailure = true
            EngineLog.emit("[SWDecoder] send_packet returned \(sendRet); packet dropped (logged once)",
                           category: .swPlayback)
        }
        // Drain regardless: a dropped packet does not invalidate frames the decoder already holds.
        drainDecodedFrames()
    }

    /// Pull every frame the decoder can currently produce, through the deinterlacer when one is
    /// active. Exits on EAGAIN (needs more input) or EOF, the same condition the receive loop
    /// has always used.
    private func drainDecodedFrames() {
        lock.lock()
        guard let ctx = codecContext else { lock.unlock(); return }
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let f = frame else { lock.unlock(); return }
        lock.unlock()

        var filtered: UnsafeMutablePointer<AVFrame>? = nil

        while true {
            lock.lock()
            guard codecContext != nil else { lock.unlock(); break }
            let ret = avcodec_receive_frame(ctx, f)
            guard ret >= 0 else { lock.unlock(); break }

            // AE#499: fill the fields the VUI left open from the container's declaration BEFORE any
            // consumer reads the frame, for the same reason the timestamp repair below runs here.
            ColorDescription.backfill(frame: f, container: containerColor)
            decodedFormatKey = DecodedFormatKey(pixelFormat: f.pointee.format, color: ColorDescription(frame: f))

            // #407: repair the frame's own timestamp BEFORE anything reads it. A frame that reaches
            // the renderer with no PTS is unschedulable and gets dropped there, so every consumer
            // below (captions, the deinterlace graph, emit) has to see the repaired value, not just
            // the one that happens to be looked at last. `best_effort_timestamp` is libavcodec's
            // guess_correct_pts(pts, pkt_dts), the same reconstruction every other FFmpeg-based
            // player consumes, and it is the only timestamp left when the container carried decode
            // timestamps alone: Matroska V_MS/VFW/FOURCC tracks (VC-1, the legacy MS codecs) put the
            // block time in DTS, and live MPEG-TS delivers untimed pictures outright. The demuxer's
            // `+genpts` normally fills those in a packet earlier; this is the layer that has to hold
            // when it cannot (an open that never got the flag, a frame the reconstruction skipped).
            if let repaired = Self.repairedPTS(
                pts: f.pointee.pts, bestEffort: f.pointee.best_effort_timestamp
            ) {
                f.pointee.pts = repaired
                repairedTimestamps += 1
                if repairedTimestamps == 1 || repairedTimestamps % 250 == 0 {
                    EngineLog.emit(
                        "[SWDecoder] repaired \(repairedTimestamps) frame timestamp(s) from best_effort_timestamp",
                        category: .swPlayback
                    )
                }
            }

            // #131: A53 captions surface as decoded-frame side data on the FFmpeg path (MPEG-2
            // picture user data and friends). Presentation order by construction of decoder output.
            if let onA53 = onA53Captions,
               let sd = av_frame_get_side_data(f, AV_FRAME_DATA_A53_CC),
               let sdData = sd.pointee.data, sd.pointee.size >= 3,
               f.pointee.pts != Int64.min, timeBase.den > 0 {
                let extracted = CCDataParser.parseCCDataTriplets(bytes: sdData, count: Int(sd.pointee.size))
                if !extracted.isEmpty {
                    let pts = Double(f.pointee.pts) * Double(timeBase.num) / Double(timeBase.den)
                    onA53(extracted, pts)
                }
            }

            // [MovieClaw P31] 离落点还远的帧不显示，也就不必去隔行（上传 GPU、按场出两帧）；留 0.25 秒给去隔行攒前后帧
            if isFarBeforeSkipThreshold(pts: f.pointee.pts, margin: Self.catchUpFilterMarginSeconds) {
                catchUpFramesSkipped += 1
                av_frame_unref(f)
                lock.unlock()
                continue
            }

            let isInterlaced = (f.pointee.flags & (1 << 3)) != 0  // AV_FRAME_FLAG_INTERLACED
            if isInterlaced || deinterlacer.isActive {
                if deinterlacer.ensureGraph(frame: f, timeBase: timeBase),
                   deinterlacer.push(f) >= 0 {
                    if filtered == nil { filtered = av_frame_alloc() }
                    if let out = filtered {
                        while deinterlacer.pull(into: out) >= 0 {  // filter holds 1-2 frames lookahead; push can yield EAGAIN
                            // Untimestamped output is unschedulable: yadif's SECOND field is
                            // cur.pts + next.pts, which is NOPTS whenever either source frame
                            // lacked a PTS (live TS delivers those); an invalid-PTS sample
                            // can't be paced by the render synchronizer and can wedge the
                            // display queue. Drop it; at field rate the neighbor field covers.
                            if out.pointee.pts == Int64.min {
                                droppedUntimestampedFields += 1
                                if droppedUntimestampedFields == 1 || droppedUntimestampedFields % 250 == 0 {
                                    EngineLog.emit(
                                        "[SWDecoder] dropped \(droppedUntimestampedFields) untimestamped deinterlaced frame(s)",
                                        category: .swPlayback
                                    )
                                }
                                av_frame_unref(out)
                                continue
                            }
                            // Filtered PTS rides the sink's time_base, NOT the stream's: yadif/bwdif
                            // halve the link time_base, and send_field puts the two fields of a frame
                            // on odd/even ticks of that halved base (see DeinterlaceFilter class doc).
                            emit(out, timeBase: deinterlacer.outputTimeBase)
                            av_frame_unref(out)
                        }
                    }
                    lock.unlock()
                    continue
                }
                // No deinterlacer in linked build or graph failure: fall through and render as-is (combing, but playing).
            }
            // emit() must stay under `lock`: close() frees swsContext/pixelBufferPool under the same lock;
            // emitting unlocked raced a stop() into a use-after-free of the sws context.
            emit(f, timeBase: timeBase)
            lock.unlock()
        }

        av_frame_free(&frame)
        if filtered != nil { av_frame_free(&filtered) }
    }

    /// Convert + deliver one decoded (or deinterlaced) frame: skip threshold, pixel buffer
    /// extraction, HDR10+ side data, onFrame. Shared by the direct and deinterlaced paths.
    /// `tb` is the time_base the frame's PTS rides on: the stream time_base for direct frames,
    /// `DeinterlaceFilter.outputTimeBase` for filtered ones (halved by yadif/bwdif; with
    /// send_field the fields sit on odd/even ticks, so rescaling into the stream base would
    /// collapse each pair to duplicate timestamps).
    private func emit(_ f: UnsafeMutablePointer<AVFrame>, timeBase tb: AVRational) {
        // Per-frame autorelease pool: the decode/feed loops are single long-running dispatch
        // blocks, so without this, ObjC transients (VTPixelTransferSession internals, CV
        // bridging) accumulate in the block's last-resort pool and only pop at session end,
        // AFTER close() tore the session down, crashing the pop with an over-release
        // (EXC_BAD_ACCESS in AutoreleasePoolPage::releaseUntil on engine.sw.feed), and
        // bloating memory for the whole channel visit meanwhile.
        autoreleasepool { emitInner(f, timeBase: tb) }
    }

    private func emitInner(_ f: UnsafeMutablePointer<AVFrame>, timeBase tb: AVRational) {
        let cmPTS = SourceTimestampBounds.cmTime(ticks: f.pointee.pts, timeBase: tb)
        if let threshold = skipUntilPTS, cmPTS.isValid {
            if CMTimeCompare(cmPTS, threshold) < 0 {
                return
            }
            // Compare-and-clear: a concurrent seek can install a new threshold; blindly nil-ing would discard it.
            clearSkip(ifStillAt: threshold)
        }

        let pixelBuffer: CVPixelBuffer
        if f.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            // Hardware deinterlace path: the frame wraps a CVPixelBuffer from FFmpeg's
            // VideoToolbox hwframes pool (data[3]). Do NOT hand that buffer to the display
            // layer: its IOSurfaces carry different properties than our pool's, and on tvOS
            // the display's direct video plane wedges on the first such frame, while GPU
            // compositing keeps rendering them (visible through translucent overlays). A
            // VTPixelTransferSession copies GPU-side into a buffer from our own pool (the
            // same attributes the sw path has always displayed); still no sws, no CPU copy.
            guard let raw = f.pointee.data.3 else { return }
            let src = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()
            if let copied = transferToOwnPool(src) {
                pixelBuffer = copied
            } else {
                // Transfer unavailable: pass the pool buffer through (frozen-plane risk, but
                // better than dropping video entirely).
                if !loggedTransferFailure {
                    loggedTransferFailure = true
                    EngineLog.emit("[SWDecoder] VT pixel transfer failed; passing filter pool buffer through", category: .swPlayback)
                }
                pixelBuffer = src
            }
            attachColorSpace(from: f, to: pixelBuffer)
            attachPixelAspectRatio(from: f, to: pixelBuffer)
        } else {
            guard let converted = convertFrameToPixelBuffer(f) else { return }
            pixelBuffer = converted
        }

        reportDecodedFormat(pixelBuffer: pixelBuffer)

        // HDR10+: read dynamic metadata from post-decode AVFrame side data (T.35 SEI bytes).
        // Can't reuse the VT path's packet-side stash; this decoder owns its own packet flow.
        let hdr10PlusData = extractHDR10PlusBytes(from: f)
        if hdr10PlusData != nil, !seenHDR10Plus {
            seenHDR10Plus = true
            onFirstHDR10PlusDetected?()
        }

        onFrame?(pixelBuffer, cmPTS, hdr10PlusData)
    }

    /// #544: `resetFilterGraph: false` keeps the deinterlace graph across the flush. The still
    /// extractor flushes before every run, and rebuilding the graph means a fresh Metal pipeline, a
    /// fresh full-resolution hwframes pool AND an unconditional `[Deinterlace] engaged` line, about
    /// sixteen times a second while a viewer holds the scrub. That line alone overwrites a host's
    /// whole diagnostic ring in half a minute. A still run decodes a full GOP and returns the frame
    /// at its target, so the filter has context from this position by the time that frame is made.
    func flush() {
        flush(resetFilterGraph: true)
    }

    func flush(resetFilterGraph: Bool) {
        lock.lock()
        defer { lock.unlock() }
        // AE#492: retires every packet a caller had already decided to send. Bumped under the lock,
        // so a feed that has not reached `avcodec_send_packet` yet is refused from here on.
        _feedEpoch &+= 1
        // Deinterlacer temporal references are stale across seeks; drop the graph (lazily rebuilt on next interlaced frame).
        if resetFilterGraph { deinterlacer.teardown() }
        guard let ctx = codecContext else { return }
        avcodec_flush_buffers(ctx)
    }

    /// Serialise HDR10+ dynamic metadata from AVFrame side data to T.35 SEI bytes (kCMSampleAttachmentKey_HDR10PlusPerFrameData).
    /// Returns nil when the frame carries no AV_FRAME_DATA_DYNAMIC_HDR_PLUS side data.
    private func extractHDR10PlusBytes(
        from frame: UnsafeMutablePointer<AVFrame>
    ) -> Data? {
        let count = Int(frame.pointee.nb_side_data)
        guard count > 0, let sideData = frame.pointee.side_data else {
            return nil
        }
        for i in 0..<count {
            guard let entry = sideData[i] else { continue }
            guard entry.pointee.type == AV_FRAME_DATA_DYNAMIC_HDR_PLUS else { continue }
            guard let raw = entry.pointee.data, entry.pointee.size > 0 else { continue }
            return raw.withMemoryRebound(
                to: AVDynamicHDRPlus.self,
                capacity: 1
            ) { recordPtr -> Data? in
                var dataPtr: UnsafeMutablePointer<UInt8>? = nil
                var size: Int = 0
                let result = av_dynamic_hdr_plus_to_t35(recordPtr, &dataPtr, &size)
                guard result >= 0, let buf = dataPtr, size > 0 else { return nil }
                let data = Data(bytes: buf, count: size)
                av_free(buf)  // use av_free, not plain free(): libavutil allocator contract
                return data
            }
        }
        return nil
    }

    func close() {
        lock.lock()
        deinterlacer.teardown()
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        codecContext = nil
        if swsContext != nil {
            sws_freeContext(swsContext)
            swsContext = nil
        }
        pixelBufferPool = nil
        poolWidth = 0
        poolHeight = 0
        loggedOutputFormat = nil
        if let session = transferSession {
            VTPixelTransferSessionInvalidate(session)
            transferSession = nil
        }
        // Nil onFrame inside the lock: emit() reads it under the same lock; unsynchronized write is a data race.
        onFrame = nil
        lock.unlock()
    }

    deinit {
        close()
    }

    // MARK: - Decoder-owned pixel buffer pool

    /// Create (or reuse) the decoder-owned CVPixelBufferPool for the given geometry. These
    /// attributes (IOSurface + Metal compatible, NV12/P010) are the ones the display path has
    /// always accepted; both the sws path and the hw-deinterlace transfer draw from here.
    private func ensurePixelBufferPool(width: Int, height: Int, format: OutputFormat) -> CVPixelBufferPool? {
        if pixelBufferPool == nil || poolWidth != width || poolHeight != height || poolFormat != format {
            pixelBufferPool = nil
            let poolAttrs: NSDictionary = [kCVPixelBufferPoolMinimumBufferCountKey: 6]
            let pbAttrs: NSDictionary = [
                kCVPixelBufferPixelFormatTypeKey: format.pixelFormatType,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs, pbAttrs, &pixelBufferPool)
            poolWidth = width
            poolHeight = height
            poolFormat = format
        }
        return pixelBufferPool
    }

    /// GPU-side copy of a hw-deinterlace filter frame into a buffer from our own pool.
    /// Returns nil when the session or pool cannot be created or the transfer fails; the
    /// caller then passes the filter's buffer through as a last resort.
    private func transferToOwnPool(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        if transferSession == nil {
            var session: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            guard status == noErr, let s = session else { return nil }
            transferSession = s
        }
        // The transfer converts range and depth itself, so it asks for the stream's own default.
        guard let session = transferSession,
              let pool = ensurePixelBufferPool(
                  width: CVPixelBufferGetWidth(src),
                  height: CVPixelBufferGetHeight(src),
                  format: OutputFormat(tenBit: use10Bit, fullRange: false)
              ) else { return nil }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) == kCVReturnSuccess,
              let out = dst else { return nil }
        guard VTPixelTransferSessionTransferImage(session, from: src, to: out) == noErr else { return nil }
        return out
    }

    private func reportDecodedFormat(pixelBuffer: CVPixelBuffer) {
        guard let onDecodedFormat, var key = decodedFormatKey else { return }
        key.pixelBufferType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard key != reportedFormatKey else { return }
        reportedFormatKey = key
        onDecodedFormat(DecodedVideoFormat(
            frame: VideoStreamFormat(
                pixelFormat: AVPixelFormat(rawValue: key.pixelFormat),
                declaredBitDepth: 0,
                color: key.color,
                codecID: codecContext?.pointee.codec_id ?? AV_CODEC_ID_NONE,
                profile: codecContext?.pointee.profile ?? AV_PROFILE_UNKNOWN),
            pixelBufferFormat: DecodedVideoFormat.fourCC(key.pixelBufferType)))
    }

    // MARK: - AVFrame → CVPixelBuffer (sws_scale)

    private func convertFrameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }

        let srcFmt = AVPixelFormat(rawValue: frame.pointee.format)

        let outputFormat = Self.outputFormat(
            pixelFormat: frame.pointee.format, colorRange: frame.pointee.color_range, streamIs10Bit: use10Bit)
        let dstFmt = outputFormat.swscaleFormat
        if outputFormat != loggedOutputFormat {
            loggedOutputFormat = outputFormat
            EngineLog.emit(
                "[SWDecoder] output \(outputFormat.tenBit ? "10-bit P010" : "8-bit NV12"), "
                + "\(outputFormat.fullRange ? "full" : "video") range "
                + "(frame \(av_get_pix_fmt_name(srcFmt).map { String(cString: $0) } ?? "?"), "
                + "color_range=\(frame.pointee.color_range.rawValue))",
                category: .swPlayback
            )
        }

        swsContext = sws_getCachedContext(
            swsContext,
            Int32(width), Int32(height), srcFmt,
            Int32(width), Int32(height), dstFmt,
            // FFmpeg 8 turned the SWS_* constants into a typed `SwsFlags`
            // enum; the C signature still wants a plain int, so unwrap.
            Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        )
        guard swsContext != nil else { return nil }

        var pixelBuffer: CVPixelBuffer?
        guard let pool = ensurePixelBufferPool(width: width, height: height, format: outputFormat) else { return nil }
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        attachColorSpace(from: frame, to: pb)
        attachPixelAspectRatio(from: frame, to: pb)

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let yPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
            .assumingMemoryBound(to: UInt8.self)

        var dstData: (UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?,
                      UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?)
        dstData.0 = yPlane
        dstData.1 = cbcrPlane
        dstData.2 = nil
        dstData.3 = nil

        var dstLinesize: (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32) = (0, 0, 0, 0, 0, 0, 0, 0)
        dstLinesize.0 = Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
        dstLinesize.1 = Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 1))

        withUnsafePointer(to: &frame.pointee.data) { srcDataPtr in
            withUnsafePointer(to: &frame.pointee.linesize) { srcLinesizePtr in
                withUnsafeMutablePointer(to: &dstData) { dstPtr in
                    withUnsafeMutablePointer(to: &dstLinesize) { dstLsPtr in
                        let srcSlice = UnsafeRawPointer(srcDataPtr)
                            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                        let srcLs = UnsafeRawPointer(srcLinesizePtr)
                            .assumingMemoryBound(to: Int32.self)
                        let dstSlice = UnsafeMutableRawPointer(dstPtr)
                            .assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)
                        let dstLs = UnsafeMutableRawPointer(dstLsPtr)
                            .assumingMemoryBound(to: Int32.self)

                        sws_scale(
                            swsContext,
                            srcSlice, srcLs,
                            0, Int32(height),
                            dstSlice, dstLs
                        )
                    }
                }
            }
        }

        return pb
    }

    // MARK: - Color Space Metadata

    /// Map FFmpeg color metadata to CVPixelBuffer attachments for correct HDR10 rendering (BT.2020 + PQ).
    /// Every field is written, a gap included (AE#654): VideoToolbox never hands the display layer an
    /// untagged buffer, and neither may this decoder.
    private func attachColorSpace(from frame: UnsafeMutablePointer<AVFrame>, to pb: CVPixelBuffer) {
        let tags = ColorAttachments.presented(ColorDescription(frame: frame))
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, tags.primaries, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, tags.transfer, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, tags.matrix, .shouldPropagate)
    }

    // MARK: - Pixel Aspect Ratio (anamorphic SD)

    /// The stream's declared SAR. Neither field alone is the whole answer: codecpar carries what the
    /// bitstream said (the mpegts / mpeg-ps parsers fill it), while a container-declared ratio
    /// reaches AVStream alone (Matroska's DisplayWidth quotient, MP4's `pasp`).
    ///
    /// A container that declares a real correction wins, because it is the later authoring layer:
    /// `mkvmerge --aspect-ratio` writes DisplayWidth and leaves the bitstream alone, so the two
    /// disagree by design and the newer one is the intent. This is also what every ffmpeg-based
    /// player resolves to (`av_guess_sample_aspect_ratio` returns the stream ratio wherever it is
    /// set), and what an MP4 `pasp` means to AVFoundation. A SQUARE declaration is not a
    /// correction and therefore not a claim to prefer, on either side: reading `1:1` out of the
    /// bitstream as "declared" is what hid a container-declared ratio entirely.
    ///
    /// Sanity is not judged here; the caller runs both gates against the frame.
    static func declaredStreamSAR(bitstream: AVRational, container: AVRational) -> AVRational {
        if container.num > 0, container.den > 0, container.num != container.den { return container }
        if bitstream.num > 0, bitstream.den > 0 { return bitstream }
        return container
    }

    /// #177 resolution order: frame -> codec context -> stream, first sane wins. The frame usually
    /// carries its own (MPEG-2 seq header from frame 1); the codec context covers codecs that only
    /// populate it there; the container-declared stream SAR is the last resort.
    ///
    /// #290: sanity is judged against the coded dimensions, so a SAR whose numbers are plausible
    /// but whose display aspect is not (a live 1080p channel declaring 3:1) drops through to the
    /// next source, and to square pixels when no source survives. See `PixelAspectPolicy`.
    ///
    /// A square candidate does not end the search either. It corrects nothing, so treating it as an
    /// answer only means the axes behind it are never read: an anamorphic MKV whose H.264 VUI says
    /// square (the shape `mkvmerge --aspect-ratio` leaves behind) was drawn at its coded size while
    /// the ratio sat in the container, one axis further down. nil and 1:1 attach the same nothing.
    static func resolveSAR(
        frame: AVRational, codecCtx: AVRational, stream: AVRational, width: Int32, height: Int32
    ) -> AVRational? {
        for candidate in [frame, codecCtx, stream] {
            if let sane = PixelAspectPolicy.saneSAR(candidate, width: width, height: height),
               sane.num != sane.den {
                return sane
            }
        }
        return nil
    }

    /// #177 per-stream latch: the first sane non-square SAR wins for the rest of the stream, so
    /// per-field oscillation on interlaced content cannot flicker the display geometry. Square or
    /// unknown SAR before any latch attaches nothing (coded dimensions are correct then).
    static func sarForAttachment(
        resolved: AVRational?, latched: AVRational?
    ) -> (attach: AVRational?, latch: AVRational?) {
        if let latched { return (latched, latched) }
        guard let resolved, resolved.num != resolved.den else { return (nil, nil) }
        return (resolved, resolved)
    }

    /// Attach SAR as kCVImageBufferPixelAspectRatioKey for anamorphic content. The renderer keys
    /// its CMVideoFormatDescription cache on this attachment (#177), so it must be stable per stream.
    private func attachPixelAspectRatio(from frame: UnsafeMutablePointer<AVFrame>, to pb: CVPixelBuffer) {
        let ctxSAR = codecContext?.pointee.sample_aspect_ratio ?? AVRational(num: 0, den: 1)
        let width = frame.pointee.width
        let height = frame.pointee.height
        let resolved = Self.resolveSAR(
            frame: frame.pointee.sample_aspect_ratio,
            codecCtx: ctxSAR,
            stream: streamSAR,
            width: width,
            height: height
        )
        if resolved == nil, !loggedSARReject, latchedSAR == nil {
            logRejectedSAR(frame: frame.pointee.sample_aspect_ratio, ctx: ctxSAR, width: width, height: height)
        }
        let (attach, latch) = Self.sarForAttachment(resolved: resolved, latched: latchedSAR)
        latchedSAR = latch
        guard let sar = attach else {
            // Recycled pool buffers can carry a stale attachment from an earlier frame.
            CVBufferRemoveAttachment(pb, kCVImageBufferPixelAspectRatioKey)
            return
        }
        if !loggedSARLatch {
            loggedSARLatch = true
            let frameSAR = frame.pointee.sample_aspect_ratio
            EngineLog.emit(
                "[SWDecoder] SAR latched \(sar.num):\(sar.den) "
                + "(frame=\(frameSAR.num):\(frameSAR.den) ctx=\(ctxSAR.num):\(ctxSAR.den) "
                + "stream=\(streamSAR.num):\(streamSAR.den))",
                category: .swPlayback
            )
        }

        let aspect: NSDictionary = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(sar.num),
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(sar.den),
        ]
        CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
    }

    /// #290: name the dropped ratio and the aspect it would have produced, once per stream. Only a
    /// SAR that cleared the component gate and failed on the display aspect reaches this; an unset
    /// or square SAR is the ordinary case and stays silent.
    private func logRejectedSAR(frame: AVRational, ctx: AVRational, width: Int32, height: Int32) {
        guard let message = Self.rejectedSARMessage(
            frame: frame, ctx: ctx, stream: streamSAR, width: width, height: height
        ) else { return }
        loggedSARReject = true
        EngineLog.emit(message, category: .swPlayback)
    }

    /// The rejection line, including the three axes the ratio could have arrived on.
    ///
    /// #290 (axes): a rejected SAR never latches, so the latch line that names frame / ctx / stream
    /// cannot fire for it, and this line was the only one a bad ratio produced. That made the axis
    /// unreadable in exactly the case where it is asked for. The axes separate the two hypotheses a
    /// smeared live channel leaves open: on MPEG-TS, where no container ratio exists, `stream=` is
    /// the parser's reading of the SPS VUI at open time and `frame=` is the SPS in force for this
    /// frame, so agreement means the VUI genuinely declares the ratio and disagreement is the
    /// fingerprint of a declaration that changed between the join and the frame.
    ///
    /// Nil unless some axis actually lost on the display aspect: an unset or square SAR everywhere
    /// is the ordinary case and has nothing to report.
    static func rejectedSARMessage(
        frame: AVRational, ctx: AVRational, stream: AVRational, width: Int32, height: Int32
    ) -> String? {
        let candidates = [frame, ctx, stream]
        let rejectedByAspect = { (sar: AVRational) in
            PixelAspectPolicy.saneSAR(sar) != nil
                && PixelAspectPolicy.saneSAR(sar, width: width, height: height) == nil
        }
        guard let rejected = candidates.first(where: rejectedByAspect) else { return nil }
        let aspect = PixelAspectPolicy.displayAspect(sar: rejected, width: width, height: height)
        return "[SWDecoder] SAR \(rejected.num):\(rejected.den) rejected on \(width)x\(height): "
            + String(format: "display aspect %.2f outside %.2f...%.2f",
                     aspect, PixelAspectPolicy.minDisplayAspect, PixelAspectPolicy.maxDisplayAspect)
            + ", using square pixels "
            + "(frame=\(frame.num):\(frame.den) ctx=\(ctx.num):\(ctx.den) "
            + "stream=\(stream.num):\(stream.den))"
    }
}
