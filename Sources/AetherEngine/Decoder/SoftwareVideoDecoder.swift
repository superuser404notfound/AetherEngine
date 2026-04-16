import Foundation
import CoreMedia
import CoreVideo
import Libavformat
import Libavcodec
import Libavutil
import Libswscale

/// FFmpeg software video decoder fallback for codecs without
/// VideoToolbox hardware support (e.g. AV1 on Apple TV).
///
/// Uses sws_scale (SIMD-optimized) for YUV→NV12/P010 conversion
/// instead of manual per-pixel loops. This is critical for AV1
/// where decode + conversion must hit 24fps at 1080p.
final class SoftwareVideoDecoder {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swsContext: OpaquePointer?
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)
    var onFrame: DecodedFrameHandler?

    /// True when the source stream is >8-bit (HDR10, AV1 HDR).
    private var use10Bit = false

    /// Pixel buffer pool — reuses allocations instead of creating per frame.
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    /// After a seek, skip frames before this PTS to avoid the
    /// "fast forward" effect. Decoded for reference but not converted.
    var skipUntilPTS: CMTime?

    /// Protects codecContext from concurrent access between the demux
    /// thread (decode) and the main thread (close/flush).
    private let lock = NSLock()

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        self.onFrame = onFrame

        guard let codecpar = stream.pointee.codecpar else {
            throw VideoDecoderError.noCodecParameters
        }

        timeBase = stream.pointee.time_base

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

        // Force pure software decode — disable all hardware acceleration.
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

        // Use all available CPU cores for software decode.
        ctx.pointee.thread_count = Int32(ProcessInfo.processInfo.activeProcessorCount)
        ctx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE

        // Disable hwaccel via codec options — some decoders ignore get_format
        var opts: OpaquePointer?
        av_dict_set(&opts, "hwaccel", "none", 0)

        guard avcodec_open2(ctx, codec, &opts) >= 0 else {
            av_dict_free(&opts)
            throw VideoDecoderError.sessionCreationFailed(status: -2)
        }
        av_dict_free(&opts)

        // Use 10-bit output for HDR content to preserve dynamic range.
        let bitsPerSample = codecpar.pointee.bits_per_raw_sample
        let isHDRTransfer = codecpar.pointee.color_trc == AVCOL_TRC_SMPTE2084
            || codecpar.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67
        use10Bit = bitsPerSample > 8 || isHDRTransfer

        #if DEBUG
        print("[SWDecoder] Opened: \(codecpar.pointee.width)x\(codecpar.pointee.height), codec=\(String(cString: codec.pointee.name)), threads=\(ctx.pointee.thread_count), \(use10Bit ? "10-bit" : "8-bit")")
        #endif
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) {
        lock.lock()
        guard let ctx = codecContext else { lock.unlock(); return }

        let sendRet = avcodec_send_packet(ctx, packet)
        guard sendRet >= 0 else { lock.unlock(); return }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let f = frame else { lock.unlock(); return }
        lock.unlock()

        while true {
            lock.lock()
            guard codecContext != nil else { lock.unlock(); break }
            let ret = avcodec_receive_frame(ctx, f)
            lock.unlock()
            guard ret >= 0 else { break }

            // Skip pre-seek frames — decoded for reference but not converted.
            // This avoids the expensive sws_scale + display for frames the
            // renderer would drop anyway via skipUntilPTS.
            if let threshold = skipUntilPTS, f.pointee.pts != Int64.min {
                let framePTS = CMTimeMake(
                    value: f.pointee.pts * Int64(timeBase.num),
                    timescale: Int32(timeBase.den)
                )
                if CMTimeCompare(framePTS, threshold) < 0 {
                    continue
                }
                skipUntilPTS = nil
            }

            guard let pixelBuffer = convertFrameToPixelBuffer(f) else { continue }

            let pts = f.pointee.pts
            let cmPTS: CMTime
            if pts != Int64.min {
                cmPTS = CMTimeMake(
                    value: pts * Int64(timeBase.num),
                    timescale: Int32(timeBase.den)
                )
            } else {
                cmPTS = .invalid
            }

            onFrame?(pixelBuffer, cmPTS)
        }

        av_frame_free(&frame)
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard let ctx = codecContext else { return }
        avcodec_flush_buffers(ctx)
    }

    func close() {
        lock.lock()
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
        lock.unlock()
        onFrame = nil
    }

    deinit {
        close()
    }

    // MARK: - AVFrame → CVPixelBuffer (sws_scale)

    /// Convert a decoded AVFrame to an NV12 CVPixelBuffer using sws_scale.
    /// sws_scale is SIMD-optimized (NEON on ARM) — much faster than
    /// manual per-pixel loops, critical for AV1 at 1080p.
    private func convertFrameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }

        let srcFmt = AVPixelFormat(rawValue: frame.pointee.format)

        // Use P010LE (10-bit) for HDR sources, NV12 (8-bit) for SDR.
        // P010 preserves HDR10 dynamic range; NV12 saves memory for SDR.
        let dstFmt = use10Bit ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12

        // Get or create sws context (cached for same dimensions/format)
        swsContext = sws_getCachedContext(
            swsContext,
            Int32(width), Int32(height), srcFmt,
            Int32(width), Int32(height), dstFmt,
            SWS_BILINEAR, nil, nil, nil
        )
        guard swsContext != nil else { return nil }

        // Get pixel buffer from pool (or create pool on first call / resolution change)
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

        var pixelBuffer: CVPixelBuffer?
        guard let pool = pixelBufferPool else { return nil }
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        // Attach color space metadata from FFmpeg so AVSampleBufferDisplayLayer
        // renders with correct primaries/transfer/matrix (critical for HDR).
        attachColorSpace(from: frame, to: pb)

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        // Set up destination pointers for NV12 (2 planes: Y + CbCr)
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

        // sws_scale: SIMD-optimized conversion (handles 8-bit, 10-bit, any format → NV12)
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

    /// Map FFmpeg color metadata to CVPixelBuffer attachments.
    /// This tells AVSampleBufferDisplayLayer the correct color space
    /// for rendering — critical for HDR10 (BT.2020 + PQ).
    private func attachColorSpace(from frame: UnsafeMutablePointer<AVFrame>, to pb: CVPixelBuffer) {
        // Color primaries (e.g. BT.709, BT.2020)
        let primaries: CFString? = switch frame.pointee.color_primaries {
        case AVCOL_PRI_BT709:       kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020:      kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE432:    kCVImageBufferColorPrimaries_P3_D65
        default:                    nil
        }

        // Transfer function (e.g. SDR gamma, PQ for HDR10, HLG)
        let transfer: CFString? = switch frame.pointee.color_trc {
        case AVCOL_TRC_BT709:       kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE2084:   kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default:                    nil
        }

        // YCbCr matrix (e.g. BT.709, BT.2020)
        let matrix: CFString? = switch frame.pointee.colorspace {
        case AVCOL_SPC_BT709:       kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL:
                                    kCVImageBufferYCbCrMatrix_ITU_R_2020
        default:                    nil
        }

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
}
