import Foundation
import CoreGraphics
import CoreMedia
import Libavformat
import Libavcodec
import Libavutil
import Libswscale

/// avcodec_receive_frame "needs more input" sentinel. AVERROR(EAGAIN);
/// the EAGAIN errno is 35 on Darwin and FFmpeg negates it.
private let AVERROR_EAGAIN_VALUE: Int32 = -35
/// FFmpeg AVERROR_EOF: FFERRTAG(0xF8,'E','O','F') = -541478725.
private let AVERROR_FRAMEDECODE_EOF_VALUE: Int32 = -541478725

/// Isolated, single-threaded FFmpeg decode context for still-image
/// extraction. Owns its own `Demuxer`, `AVCodecContext` (forced
/// software), and `SwsContext`, strictly separate from playback. Lazy:
/// `ensureOpen()` opens on first use; `close()` releases everything and
/// is safe to call repeatedly. NOT thread-safe; `FrameExtractor`
/// serializes all access on its decode queue.
final class FrameDecodeContext: @unchecked Sendable {
    private let url: URL
    private let httpHeaders: [String: String]
    /// When non-nil, the context opens from this independent reader (a custom
    /// source clone) instead of the URL. The context owns it and closes it at
    /// deinit (NOT in close(), which only tears down the demuxer/decoder so the
    /// idle-reopen path can rebuild over the still-alive reader).
    private let reader: IOReader?
    private let formatHint: String?

    private var demuxer: Demuxer?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swsContext: UnsafeMutablePointer<SwsContext>?
    private var videoStreamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 90000)
    private(set) var isOpen = false
    private(set) var isHDR = false

    /// PQ (ST 2084) and HLG transfers mean the decoded frame is HDR and
    /// needs tone-mapping to SDR before display as a thumbnail.
    static func isHDRTransfer(_ trc: AVColorTransferCharacteristic) -> Bool {
        return trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67
    }

    init(url: URL, httpHeaders: [String: String]) {
        self.url = url
        self.httpHeaders = httpHeaders
        self.reader = nil
        self.formatHint = nil
    }

    init(reader: IOReader, formatHint: String?) {
        // Placeholder; unused when reader != nil (openInternal opens the reader).
        self.url = URL(string: "aether-custom://frame-extractor")!
        self.httpHeaders = [:]
        self.reader = reader
        self.formatHint = formatHint
    }

    deinit {
        close()
        reader?.close()
    }

    /// Open demuxer + decoder if not already open. Throws on failure
    /// and leaves the context fully closed (no partial state to leak).
    func ensureOpen() throws {
        guard !isOpen else { return }
        do {
            try openInternal()
            isOpen = true
        } catch {
            close()
            throw error
        }
    }

    func close() {
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        codecContext = nil
        if swsContext != nil {
            sws_freeContext(swsContext)
            swsContext = nil
        }
        demuxer?.close()
        demuxer = nil
        videoStreamIndex = -1
        isHDR = false
        isOpen = false
    }

    private func openInternal() throws {
        let demuxer = Demuxer()
        if let reader = reader {
            try demuxer.open(reader: reader, formatHint: formatHint, profile: .stillExtraction)
        } else {
            try demuxer.open(url: url, extraHeaders: httpHeaders, profile: .stillExtraction)
        }
        self.demuxer = demuxer

        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else {
            throw FrameDecodeError.noVideoStream
        }
        videoStreamIndex = videoIdx
        timeBase = stream.pointee.time_base

        demuxer.discardAllStreamsExcept([videoIdx])

        guard let codecpar = stream.pointee.codecpar else {
            throw FrameDecodeError.noCodecParameters
        }
        isHDR = Self.isHDRTransfer(codecpar.pointee.color_trc)
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw FrameDecodeError.unsupportedCodec
        }
        guard let ctx = avcodec_alloc_context3(codec) else {
            throw FrameDecodeError.allocationFailed
        }
        codecContext = ctx
        guard avcodec_parameters_to_context(ctx, codecpar) >= 0 else {
            throw FrameDecodeError.noCodecParameters
        }
        ctx.pointee.get_format = { _, fmts in
            guard let fmts = fmts else { return AV_PIX_FMT_NONE }
            var i = 0
            while fmts[i] != AV_PIX_FMT_NONE {
                if fmts[i] != AV_PIX_FMT_VIDEOTOOLBOX { return fmts[i] }
                i += 1
            }
            return AV_PIX_FMT_YUV420P
        }
        ctx.pointee.thread_count = Int32(ProcessInfo.processInfo.activeProcessorCount)
        ctx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE

        // Still extraction never needs deblocked output or full-rate decode
        // quality; skip the loop filter and enable the fast/inaccurate decode
        // path to cut per-frame CPU on big HEVC/AV1 keyframes.
        // AV_CODEC_FLAG2_FAST is a C #define (1 << 0) and does not bridge
        // directly to Swift, so we define it locally.
        let AV_CODEC_FLAG2_FAST_VALUE: Int32 = 1 << 0
        ctx.pointee.skip_loop_filter = AVDISCARD_ALL
        ctx.pointee.flags2 |= AV_CODEC_FLAG2_FAST_VALUE

        var opts: OpaquePointer?
        // Software decode is actually forced by the get_format callback
        // above (it rejects AV_PIX_FMT_VIDEOTOOLBOX). The "hwaccel" dict
        // entry is a no-op at avcodec_open2 level but is kept for parity
        // with SoftwareVideoDecoder.
        av_dict_set(&opts, "hwaccel", "none", 0)
        guard avcodec_open2(ctx, codec, &opts) >= 0 else {
            av_dict_free(&opts)
            throw FrameDecodeError.decoderOpenFailed
        }
        av_dict_free(&opts)

        EngineLog.emit("[FrameDecode] Opened \(codecpar.pointee.width)x\(codecpar.pointee.height) codec=\(String(cString: codec.pointee.name)) threads=\(ctx.pointee.thread_count)", category: .swPlayback)
    }

    // MARK: - Decode

    /// Decode one frame at/after `seconds`.
    ///
    /// - thumbnail mode: returns the first decoded frame after the seek
    ///   (the keyframe), downscaled so its width is `targetWidth`.
    /// - snapshot mode: decodes forward, skipping frames until
    ///   `frame.pts >= seconds`, then returns that frame at `maxSize`
    ///   (aspect-preserved) or native size when `maxSize` is nil.
    ///
    /// `isCancelled` is polled between packets and before conversion so
    /// a superseded scrub request bails promptly. Returns nil on EOF,
    /// decode failure, or cancellation. Frees every FFmpeg allocation
    /// on every path.
    func decodeFrame(
        at seconds: Double,
        mode: FrameMode,
        targetWidth: Int,
        maxSize: CGSize?,
        isCancelled: () -> Bool
    ) -> CGImage? {
        guard isOpen, let ctx = codecContext, let demuxer else { return nil }

        avcodec_flush_buffers(ctx)

        // AVDISCARD_DEFAULT for both modes. Thumbnail returns the first frame
        // after the seek and stops, so discarding non-key frames buys nothing,
        // and AVDISCARD_NONKEY actively breaks streams whose seek lands mid-GOP
        // past a sparse keyframe (decoder discards every packet -> EAGAIN, nil
        // frame). Snapshot must keep all frames to decode forward to the exact PTS.
        ctx.pointee.skip_frame = AVDISCARD_DEFAULT

        demuxer.seek(to: seconds)

        guard timeBase.num > 0 else { return nil }
        let targetPTS = Int64((seconds * Double(timeBase.den)) / Double(timeBase.num))

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard frame != nil else { return nil }
        defer { av_frame_free(&frame) }

        while true {
            if isCancelled() { return nil }

            let packetOrNil: UnsafeMutablePointer<AVPacket>?
            do {
                packetOrNil = try demuxer.readPacket()
            } catch {
                return nil
            }
            guard let packet = packetOrNil else {
                return nil
            }

            if packet.pointee.stream_index != videoStreamIndex {
                av_packet_unref(packet)
                av_packet_free_safe(packet)
                continue
            }

            // The receive loop below drains the decoder before each send,
            // so the decoder's input queue is always empty here; send-side EAGAIN cannot occur.
            let sendRet = avcodec_send_packet(ctx, packet)
            av_packet_unref(packet)
            av_packet_free_safe(packet)
            guard sendRet >= 0 else { continue }

            while true {
                if isCancelled() { return nil }
                let recvRet = avcodec_receive_frame(ctx, frame)
                if recvRet == AVERROR_EAGAIN_VALUE { break }           // need another packet
                if recvRet == AVERROR_FRAMEDECODE_EOF_VALUE { return nil } // decoder drained
                guard recvRet >= 0, let f = frame else { break }       // real error: try next packet

                // Skip frames before the requested PTS for frame-accuracy.
                // A frame with no PTS (AV_NOPTS_VALUE == Int64.min) is
                // accepted as-is, so on PTS-less streams snapshot degrades
                // gracefully to the first frame after the seek.
                if mode == .snapshot,
                   f.pointee.pts != Int64.min,
                   f.pointee.pts < targetPTS {
                    continue
                }

                if isCancelled() { return nil }
                let width = mode == .thumbnail
                    ? targetWidth
                    : Self.clampedWidth(frame: f, maxSize: maxSize)
                if isHDR {
                    var toned = HDRToneMapper.toneMap(frame: f, targetWidth: width, timeBase: timeBase)
                    if toned != nil {
                        defer { av_frame_free(&toned) }
                        if let img = Self.cgImageFromRGBAFrame(toned!) { return img }
                    }
                    // tone-map failed: fall through to the sws path (degraded but non-nil)
                }
                return convertToCGImage(frame: f, targetWidth: width)
            }
        }
    }

    /// Output width for snapshot mode: native width, optionally capped
    /// to `maxSize` while preserving aspect ratio.
    private static func clampedWidth(frame: UnsafeMutablePointer<AVFrame>, maxSize: CGSize?) -> Int {
        let nativeW = Int(frame.pointee.width)
        let nativeH = Int(frame.pointee.height)
        guard let maxSize, maxSize.width > 0, maxSize.height > 0, nativeW > 0, nativeH > 0 else {
            return nativeW
        }
        let scale = min(maxSize.width / CGFloat(nativeW), maxSize.height / CGFloat(nativeH), 1.0)
        return max(1, Int((CGFloat(nativeW) * scale).rounded()))
    }

    /// Wrap an RGBA AVFrame (e.g. the tone-mapper output) into a CGImage by
    /// copying its pixels into an owned buffer. Honors linesize (row stride
    /// may exceed width*4).
    private static func cgImageFromRGBAFrame(_ frame: UnsafeMutablePointer<AVFrame>) -> CGImage? {
        let w = Int(frame.pointee.width)
        let h = Int(frame.pointee.height)
        guard w > 0, h > 0, let src = frame.pointee.data.0 else { return nil }
        let srcStride = Int(frame.pointee.linesize.0)
        let dstStride = w * 4
        var rgba = [UInt8](repeating: 0, count: dstStride * h)
        rgba.withUnsafeMutableBytes { dst in
            for row in 0..<h {
                memcpy(dst.baseAddress!.advanced(by: row * dstStride),
                       src.advanced(by: row * srcStride),
                       dstStride)
            }
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: dstStride, space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// sws_scale the frame to RGBA at `targetWidth` (height derived from
    /// source aspect) and wrap it in a CGImage with an owned byte
    /// buffer. Mirrors the sws tuple-pointer dance in
    /// SoftwareVideoDecoder and the CGImage idiom in
    /// EmbeddedSubtitleDecoder.
    private func convertToCGImage(frame: UnsafeMutablePointer<AVFrame>, targetWidth: Int) -> CGImage? {
        let srcW = Int(frame.pointee.width)
        let srcH = Int(frame.pointee.height)
        guard srcW > 0, srcH > 0, targetWidth > 0 else { return nil }

        let dstW = min(targetWidth, srcW)
        let dstH = max(1, Int((Double(dstW) * Double(srcH) / Double(srcW)).rounded()))
        let srcFmt = AVPixelFormat(rawValue: frame.pointee.format)

        swsContext = sws_getCachedContext(
            swsContext,
            Int32(srcW), Int32(srcH), srcFmt,
            Int32(dstW), Int32(dstH), AV_PIX_FMT_RGBA,
            Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        )
        guard swsContext != nil else { return nil }

        let bytesPerRow = dstW * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * dstH)

        let ok: Bool = rgba.withUnsafeMutableBufferPointer { dstBuf -> Bool in
            var dstData: (UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?,
                          UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?)
                = (dstBuf.baseAddress, nil, nil, nil, nil, nil, nil, nil)
            var dstLinesize: (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)
                = (Int32(bytesPerRow), 0, 0, 0, 0, 0, 0, 0)

            return withUnsafePointer(to: &frame.pointee.data) { srcDataPtr in
                withUnsafePointer(to: &frame.pointee.linesize) { srcLsPtr in
                    withUnsafeMutablePointer(to: &dstData) { dstPtr in
                        withUnsafeMutablePointer(to: &dstLinesize) { dstLsPtr in
                            let srcSlice = UnsafeRawPointer(srcDataPtr)
                                .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                            let srcLs = UnsafeRawPointer(srcLsPtr)
                                .assumingMemoryBound(to: Int32.self)
                            let dstSlice = UnsafeMutableRawPointer(dstPtr)
                                .assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)
                            let dstLs = UnsafeMutableRawPointer(dstLsPtr)
                                .assumingMemoryBound(to: Int32.self)
                            let scaled = sws_scale(
                                swsContext, srcSlice, srcLs,
                                0, Int32(srcH), dstSlice, dstLs
                            )
                            return scaled > 0
                        }
                    }
                }
            }
        }
        guard ok else { return nil }

        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        // sws_scale into RGBA yields straight, fully-opaque pixels (alpha
        // = 0xFF), so the alpha byte is ignorable rather than premultiplied.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        return CGImage(
            width: dstW, height: dstH,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

enum FrameDecodeError: Error {
    case noVideoStream
    case noCodecParameters
    case unsupportedCodec
    case allocationFailed
    case decoderOpenFailed
}
