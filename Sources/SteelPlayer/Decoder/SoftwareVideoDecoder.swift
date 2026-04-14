import Foundation
import CoreMedia
import CoreVideo
import Accelerate
import Libavformat
import Libavcodec
import Libavutil

/// FFmpeg software video decoder fallback for codecs without
/// VideoToolbox hardware support (e.g. AV1 on A15, VP8/VP9).
///
/// Decodes to AVFrame (YUV420P) and converts to CVPixelBuffer (NV12)
/// for the Metal renderer. Slower than hardware decode but works for
/// any codec FFmpeg supports.
final class SoftwareVideoDecoder {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)
    var onFrame: DecodedFrameHandler?

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
        // FFmpeg's AV1 decoder tries VideoToolbox internally and fails on A15.
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
        // 0 = auto-detect (uses ProcessInfo.processInfo.activeProcessorCount).
        // A15 in Apple TV 4K has 6 cores — all should be used for AV1.
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

        #if DEBUG
        print("[SWDecoder] Opened: \(codecpar.pointee.width)x\(codecpar.pointee.height), codec=\(String(cString: codec.pointee.name)), threads=\(ctx.pointee.thread_count)")
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
        lock.unlock()
        onFrame = nil
    }

    deinit {
        close()
    }

    // MARK: - AVFrame → CVPixelBuffer

    /// Convert a decoded AVFrame to a CVPixelBuffer.
    /// Supports both 8-bit (YUV420P → NV12) and 10-bit (YUV420P10 → P010).
    private func convertFrameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }

        let pixFmt = frame.pointee.format
        let is10Bit = (pixFmt == AV_PIX_FMT_YUV420P10LE.rawValue ||
                       pixFmt == AV_PIX_FMT_YUV420P10BE.rawValue)

        if is10Bit {
            return convert10BitFrame(frame, width: width, height: height)
        } else {
            return convert8BitFrame(frame, width: width, height: height)
        }
    }

    // MARK: - 8-bit YUV420P → NV12

    private func convert8BitFrame(_ frame: UnsafeMutablePointer<AVFrame>, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: NSDictionary = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attrs, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        // Y plane
        let yDst = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
        let yDstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ySrc = frame.pointee.data.0!
        let ySrcStride = Int(frame.pointee.linesize.0)

        for row in 0..<height {
            memcpy(yDst.advanced(by: row * yDstStride),
                   ySrc.advanced(by: row * ySrcStride), width)
        }

        // Interleave U + V → CbCr — optimized row-by-row memcpy
        // (vImage doesn't have a 2-channel planar→chunky, so we use
        // a tight loop that the compiler auto-vectorizes with NEON)
        let cbcrDst = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let uSrc = frame.pointee.data.1!
        let vSrc = frame.pointee.data.2!
        let uStride = Int(frame.pointee.linesize.1)
        let vStride = Int(frame.pointee.linesize.2)
        let halfW = width / 2

        for row in 0..<(height / 2) {
            let dst = cbcrDst.advanced(by: row * cbcrStride).assumingMemoryBound(to: UInt8.self)
            let u = uSrc.advanced(by: row * uStride)
            let v = vSrc.advanced(by: row * vStride)
            // Process 2 pixels at a time for better auto-vectorization
            var col = 0
            while col < halfW {
                dst[col &* 2]       = u[col]
                dst[col &* 2 &+ 1]  = v[col]
                col &+= 1
            }
        }

        return pb
    }

    // MARK: - 10-bit YUV420P10 → P010

    private func convert10BitFrame(_ frame: UnsafeMutablePointer<AVFrame>, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: NSDictionary = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ]
        // P010: 10-bit bi-planar, 16-bit per component (upper 10 bits used)
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            attrs, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        // Y plane: 16-bit per sample.
        // libdav1d outputs 10-bit values (0-1023). P010 uses upper 10 bits
        // of a 16-bit word, so we shift left by 6.
        let yDstRaw = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
        let yDstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ySrcRaw = UnsafeRawPointer(frame.pointee.data.0!)
        let ySrcStride = Int(frame.pointee.linesize.0)

        for row in 0..<height {
            let dst = yDstRaw.advanced(by: row * yDstStride).bindMemory(to: UInt16.self, capacity: width)
            let src = ySrcRaw.advanced(by: row * ySrcStride).assumingMemoryBound(to: UInt16.self)
            for col in 0..<width {
                dst[col] = src[col] << 6
            }
        }

        // CbCr plane: interleave U + V, each 16-bit
        let cbcrDstRaw = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let uRaw = UnsafeRawPointer(frame.pointee.data.1!)
        let vRaw = UnsafeRawPointer(frame.pointee.data.2!)
        let uStride = Int(frame.pointee.linesize.1)
        let vStride = Int(frame.pointee.linesize.2)
        let halfW = width / 2
        let halfH = height / 2

        for row in 0..<halfH {
            let dst = cbcrDstRaw.advanced(by: row * cbcrStride).bindMemory(to: UInt16.self, capacity: halfW * 2)
            let u = uRaw.advanced(by: row * uStride).assumingMemoryBound(to: UInt16.self)
            let v = vRaw.advanced(by: row * vStride).assumingMemoryBound(to: UInt16.self)
            for col in 0..<halfW {
                dst[col * 2]     = u[col] << 6
                dst[col * 2 + 1] = v[col] << 6
            }
        }

        return pb
    }
}
