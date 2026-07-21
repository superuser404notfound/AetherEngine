import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Libavformat
import Libavcodec
import Libavutil
import Libswscale

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

    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    /// Skip pre-seek frames; decoded for reference but not converted.
    /// Guarded by `skipLock` not `lock`: emit() runs with `lock` held, so a same-lock accessor would deadlock.
    /// CMTime is multi-word: old unsynchronized access was a torn-read candidate.
    var skipUntilPTS: CMTime? {
        get { skipLock.lock(); defer { skipLock.unlock() }; return _skipUntilPTS }
        set { skipLock.lock(); _skipUntilPTS = newValue; skipLock.unlock() }
    }
    private var _skipUntilPTS: CMTime?
    private let skipLock = NSLock()

    /// Clear the skip threshold only if it is still the one we acted on.
    private func clearSkip(ifStillAt threshold: CMTime) {
        skipLock.lock()
        if let current = _skipUntilPTS, CMTimeCompare(current, threshold) == 0 {
            _skipUntilPTS = nil
        }
        skipLock.unlock()
    }

    /// Protects codecContext across the demux thread (decode) and main thread (close/flush).
    private let lock = NSLock()

    /// Deinterlacer for interlaced MPEG-2/VC-1/MPEG-4 (DVD rips, SD broadcast); see DeinterlaceFilter class doc.
    /// Engaged lazily on first interlaced frame; every subsequent frame routes through it. Guarded by `lock`.
    private let deinterlacer = DeinterlaceFilter()

    /// Deinterlacer selection + cadence from LoadOptions. Set by the host BEFORE `open`;
    /// applied to the filter there (mutating it mid-stream would need a graph rebuild).
    var deinterlaceConfig = DeinterlaceConfig()

    /// Deinterlaced frames dropped for carrying no PTS (see the drop site in decode()). Guarded by `lock`.
    private var droppedUntimestampedFields = 0

    /// GPU-side copy from the hw-deinterlace filter's pool buffers into `pixelBufferPool` (see
    /// the VT branch in emit()). Created lazily on the first hw frame; guarded by `lock`.
    private var transferSession: VTPixelTransferSession?
    private var loggedTransferFailure = false

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        self.onFrame = onFrame
        deinterlacer.config = deinterlaceConfig

        guard let codecpar = stream.pointee.codecpar else {
            throw VideoDecoderError.noCodecParameters
        }

        timeBase = stream.pointee.time_base

        // Container SAR fallback; see streamSAR. Frames usually carry their own (MPEG-2 seq header, from frame 1).
        streamSAR = codecpar.pointee.sample_aspect_ratio

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

        ctx.pointee.thread_count = Int32(ProcessInfo.processInfo.activeProcessorCount)
        ctx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE

        // Belt-and-suspenders hwaccel=none: some decoders ignore get_format.
        var opts: OpaquePointer?
        av_dict_set(&opts, "hwaccel", "none", 0)

        guard avcodec_open2(ctx, codec, &opts) >= 0 else {
            av_dict_free(&opts)
            throw VideoDecoderError.sessionCreationFailed(status: -2)
        }
        av_dict_free(&opts)

        let bitsPerSample = codecpar.pointee.bits_per_raw_sample
        let isHDRTransfer = ColorAttachments.isHDRTransfer(codecpar.pointee.color_trc)
        use10Bit = bitsPerSample > 8 || isHDRTransfer

        // Release-visible log (no #if DEBUG): needed for TestFlight users and DrHurt #4 black-screen reports.
        EngineLog.emit("[SWDecoder] Opened: \(codecpar.pointee.width)x\(codecpar.pointee.height), codec=\(String(cString: codec.pointee.name)), threads=\(ctx.pointee.thread_count), \(use10Bit ? "10-bit" : "8-bit")", category: .swPlayback)
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) {
        lock.lock()
        guard let ctx = codecContext else { lock.unlock(); return }

        let sendRet = avcodec_send_packet(ctx, packet)
        guard sendRet >= 0 else { lock.unlock(); return }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let f = frame else { lock.unlock(); return }
        lock.unlock()

        var filtered: UnsafeMutablePointer<AVFrame>? = nil

        while true {
            lock.lock()
            guard codecContext != nil else { lock.unlock(); break }
            let ret = avcodec_receive_frame(ctx, f)
            guard ret >= 0 else { lock.unlock(); break }

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
        if let threshold = skipUntilPTS, f.pointee.pts != Int64.min {
            let framePTS = CMTimeMake(
                value: f.pointee.pts * Int64(tb.num),
                timescale: Int32(tb.den)
            )
            if CMTimeCompare(framePTS, threshold) < 0 {
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

        let pts = f.pointee.pts
        let cmPTS: CMTime
        if pts != Int64.min {
            cmPTS = CMTimeMake(
                value: pts * Int64(tb.num),
                timescale: Int32(tb.den)
            )
        } else {
            cmPTS = .invalid
        }

        // HDR10+: read dynamic metadata from post-decode AVFrame side data (T.35 SEI bytes).
        // Can't reuse the VT path's packet-side stash; this decoder owns its own packet flow.
        let hdr10PlusData = extractHDR10PlusBytes(from: f)
        if hdr10PlusData != nil, !seenHDR10Plus {
            seenHDR10Plus = true
            onFirstHDR10PlusDetected?()
        }

        onFrame?(pixelBuffer, cmPTS, hdr10PlusData)
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        // Deinterlacer temporal references are stale across seeks; drop the graph (lazily rebuilt on next interlaced frame).
        deinterlacer.teardown()
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
    private func ensurePixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        let cvPixelFormat: OSType = use10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        if pixelBufferPool == nil || poolWidth != width || poolHeight != height {
            pixelBufferPool = nil
            let poolAttrs: NSDictionary = [kCVPixelBufferPoolMinimumBufferCountKey: 6]
            let pbAttrs: NSDictionary = [
                kCVPixelBufferPixelFormatTypeKey: cvPixelFormat,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs, pbAttrs, &pixelBufferPool)
            poolWidth = width
            poolHeight = height
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
        guard let session = transferSession,
              let pool = ensurePixelBufferPool(
                  width: CVPixelBufferGetWidth(src),
                  height: CVPixelBufferGetHeight(src)
              ) else { return nil }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) == kCVReturnSuccess,
              let out = dst else { return nil }
        guard VTPixelTransferSessionTransferImage(session, from: src, to: out) == noErr else { return nil }
        return out
    }

    // MARK: - AVFrame → CVPixelBuffer (sws_scale)

    private func convertFrameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }

        let srcFmt = AVPixelFormat(rawValue: frame.pointee.format)

        let dstFmt = use10Bit ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12

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
        guard let pool = ensurePixelBufferPool(width: width, height: height) else { return nil }
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
    private func attachColorSpace(from frame: UnsafeMutablePointer<AVFrame>, to pb: CVPixelBuffer) {
        let primaries = ColorAttachments.primaries(frame.pointee.color_primaries)
        let transfer = ColorAttachments.transfer(frame.pointee.color_trc)
        let matrix = ColorAttachments.matrix(frame.pointee.colorspace)

        if let primaries {
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        }
        if let transfer {
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        }
        if let matrix {
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }
    }

    // MARK: - Pixel Aspect Ratio (anamorphic SD)

    /// #177 sanity gate: reject unset (0:x), negative, and garbage SARs. AVCodecContext has been
    /// seen carrying 1088:1 on live TS; no legitimate pixel aspect ratio needs values above 256.
    static func saneSAR(_ sar: AVRational) -> AVRational? {
        guard sar.num > 0, sar.den > 0, sar.num <= 256, sar.den <= 256 else { return nil }
        return sar
    }

    /// #177 resolution order: frame -> codec context -> stream, first sane wins. The frame usually
    /// carries its own (MPEG-2 seq header from frame 1); the codec context covers codecs that only
    /// populate it there; the container-declared stream SAR is the last resort.
    static func resolveSAR(frame: AVRational, codecCtx: AVRational, stream: AVRational) -> AVRational? {
        saneSAR(frame) ?? saneSAR(codecCtx) ?? saneSAR(stream)
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
        let resolved = Self.resolveSAR(
            frame: frame.pointee.sample_aspect_ratio,
            codecCtx: ctxSAR,
            stream: streamSAR
        )
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
}
