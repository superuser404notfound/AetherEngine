import Foundation
import CoreMedia
import CoreVideo
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

        // Use all available CPU cores for software decode
        ctx.pointee.thread_count = 0  // auto-detect
        ctx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE

        guard avcodec_open2(ctx, codec, nil) >= 0 else {
            throw VideoDecoderError.sessionCreationFailed(status: -2)
        }

        #if DEBUG
        print("[SWDecoder] Opened: \(codecpar.pointee.width)x\(codecpar.pointee.height), codec=\(String(cString: codec.pointee.name)), threads=\(ctx.pointee.thread_count)")
        #endif
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) {
        guard let ctx = codecContext else { return }

        let sendRet = avcodec_send_packet(ctx, packet)
        guard sendRet >= 0 else { return }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let f = frame else { return }

        while avcodec_receive_frame(ctx, f) >= 0 {
            guard let pixelBuffer = convertFrameToPixelBuffer(f) else { continue }

            let pts = f.pointee.pts
            let avNoPTS: Int64 = Int64.min
            let cmPTS: CMTime
            if pts != avNoPTS {
                cmPTS = CMTimeMake(
                    value: pts * Int64(timeBase.num),
                    timescale: Int32(timeBase.den)
                )
            } else {
                cmPTS = .invalid
            }

            onFrame?(pixelBuffer, cmPTS)
        }
    }

    func flush() {
        guard let ctx = codecContext else { return }
        avcodec_flush_buffers(ctx)
    }

    func close() {
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        codecContext = nil
        onFrame = nil
    }

    deinit {
        close()
    }

    // MARK: - AVFrame → CVPixelBuffer (NV12)

    /// Convert a decoded YUV420P AVFrame to an NV12 CVPixelBuffer.
    /// Y plane is copied directly. U and V planes are interleaved
    /// into the CbCr plane.
    private func convertFrameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }

        // Create CVPixelBuffer in NV12 format (matches our Metal shader)
        var pixelBuffer: CVPixelBuffer?
        let attrs: NSDictionary = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attrs,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        // Copy Y plane (plane 0)
        let yDst = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
        let yDstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ySrc = frame.pointee.data.0!
        let ySrcStride = Int(frame.pointee.linesize.0)

        for row in 0..<height {
            memcpy(
                yDst.advanced(by: row * yDstStride),
                ySrc.advanced(by: row * ySrcStride),
                width
            )
        }

        // Interleave U + V → CbCr plane (plane 1)
        let cbcrDst = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
        let cbcrDstStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let uSrc = frame.pointee.data.1!
        let vSrc = frame.pointee.data.2!
        let uStride = Int(frame.pointee.linesize.1)
        let vStride = Int(frame.pointee.linesize.2)
        let halfHeight = height / 2
        let halfWidth = width / 2

        for row in 0..<halfHeight {
            let dstRow = cbcrDst.advanced(by: row * cbcrDstStride)
                .assumingMemoryBound(to: UInt8.self)
            let uRow = uSrc.advanced(by: row * uStride)
            let vRow = vSrc.advanced(by: row * vStride)

            for col in 0..<halfWidth {
                dstRow[col * 2]     = uRow[col]  // Cb
                dstRow[col * 2 + 1] = vRow[col]  // Cr
            }
        }

        return pb
    }
}
