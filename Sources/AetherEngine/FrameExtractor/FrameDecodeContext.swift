import Foundation
import CoreGraphics
import CoreMedia
import Libavformat
import Libavcodec
import Libavutil
import Libswscale

/// Isolated, single-threaded FFmpeg decode context for still-image extraction.
/// Owns its own Demuxer, AVCodecContext (forced software), and SwsContext, separate
/// from playback. Lazy: ensureOpen() opens on first use, close() is idempotent.
/// NOT thread-safe; FrameExtractor serializes all access on its decode queue.
final class FrameDecodeContext: @unchecked Sendable {
    private let url: URL
    private let httpHeaders: [String: String]
    /// When non-nil, opens from this independent reader (custom source clone) not the URL.
    /// Closed at deinit, NOT in close() (which tears down only demuxer/decoder so the
    /// idle-reopen path can rebuild over the still-alive reader).
    private let reader: IOReader?
    private let formatHint: String?

    private var demuxer: Demuxer?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swsContext: UnsafeMutablePointer<SwsContext>?
    private var videoStreamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 90000)
    /// Source SAR (sample aspect ratio) read from the stream at open. Anamorphic
    /// sources (NTSC/PAL DVD, anamorphic Blu-ray) store non-square pixels; without
    /// this the thumbnail draws square-pixel and looks stretched. Defaults 1:1.
    private var streamSAR = AVRational(num: 1, den: 1)
    private(set) var isOpen = false
    private(set) var isHDR = false

    /// PQ (ST 2084) / HLG transfers mean the frame is HDR and needs tone-mapping to SDR.
    static func isHDRTransfer(_ trc: AVColorTransferCharacteristic) -> Bool {
        ColorAttachments.isHDRTransfer(trc)
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

    /// Open demuxer + decoder if not already open. Throws on failure, leaving the
    /// context fully closed (no partial state to leak).
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
        // Prefer container/stream SAR; the SW decoder does not reliably attach SAR
        // to output frames (see SoftwareVideoDecoder), so per-frame is fallback-only.
        let parSAR = codecpar.pointee.sample_aspect_ratio
        if parSAR.num > 0, parSAR.den > 0 {
            streamSAR = parSAR
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

        // Still extraction needs no deblock or full-rate quality: skip loop filter
        // and enable the fast/inaccurate path to cut per-frame CPU on big HEVC/AV1 keyframes.
        // AV_CODEC_FLAG2_FAST is a C #define (1 << 0) that does not bridge to Swift.
        let AV_CODEC_FLAG2_FAST_VALUE: Int32 = 1 << 0
        ctx.pointee.skip_loop_filter = AVDISCARD_ALL
        ctx.pointee.flags2 |= AV_CODEC_FLAG2_FAST_VALUE

        var opts: OpaquePointer?
        // SW decode is forced by the get_format callback above (rejects VIDEOTOOLBOX).
        // The "hwaccel" entry is a no-op at avcodec_open2, kept for parity with SoftwareVideoDecoder.
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
    /// - thumbnail: first frame after the seek (keyframe), downscaled to `targetWidth`.
    /// - snapshot: decode forward until pts >= seconds, return at `maxSize` (aspect-preserved) or native.
    ///
    /// `isCancelled` is polled between packets and before conversion so a superseded scrub
    /// bails promptly. Returns nil on EOF / decode failure / cancellation. Frees all FFmpeg allocs.
    func decodeFrame(
        at seconds: Double,
        mode: FrameMode,
        targetWidth: Int,
        maxSize: CGSize?,
        isCancelled: () -> Bool
    ) -> CGImage? {
        guard isOpen, let ctx = codecContext, let demuxer else { return nil }

        avcodec_flush_buffers(ctx)

        // AVDISCARD_DEFAULT for both modes. AVDISCARD_NONKEY breaks streams whose seek
        // lands mid-GOP past a sparse keyframe (every packet discarded -> EAGAIN, nil frame);
        // thumbnail gains nothing from it, and snapshot must keep all frames to reach exact PTS.
        ctx.pointee.skip_frame = AVDISCARD_DEFAULT

        demuxer.seek(to: seconds)

        guard timeBase.num > 0 else { return nil }
        let targetPTS = Int64((seconds * Double(timeBase.den)) / Double(timeBase.num))

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard frame != nil else { return nil }
        defer { av_frame_free(&frame) }

        func makeImage(_ f: UnsafeMutablePointer<AVFrame>) -> CGImage? {
            let width = mode == .thumbnail
                ? targetWidth
                : Self.clampedWidth(frame: f, maxSize: maxSize)
            if isHDR {
                var toned = HDRToneMapper.toneMap(frame: f, targetWidth: width, timeBase: timeBase)
                if toned != nil {
                    defer { av_frame_free(&toned) }
                    if let img = Self.cgImageFromRGBAFrame(toned!) { return img }
                }
                // tone-map failed: fall through to sws path (degraded but non-nil)
            }
            return convertToCGImage(frame: f, targetWidth: width)
        }

        // Once the demuxer hits EOF, flush the decoder (NULL packet) and keep draining: the
        // context is frame-threaded, so the last GOP's frames only emit after the flush. Without
        // this, a snapshot/thumbnail targeting the final frames returned nil (blank preview).
        var draining = false
        while true {
            if isCancelled() { return nil }

            if !draining {
                let packetOrNil: UnsafeMutablePointer<AVPacket>?
                do {
                    packetOrNil = try demuxer.readPacket()
                } catch {
                    return nil
                }
                guard let packet = packetOrNil else {
                    avcodec_send_packet(ctx, nil)
                    draining = true
                    continue
                }
                if packet.pointee.stream_index != videoStreamIndex {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    continue
                }
                // Receive loop below drains before each send, so send-side EAGAIN cannot occur here.
                let sendRet = avcodec_send_packet(ctx, packet)
                av_packet_unref(packet)
                av_packet_free_safe(packet)
                guard sendRet >= 0 else { continue }
            }

            while true {
                if isCancelled() { return nil }
                let recvRet = avcodec_receive_frame(ctx, frame)
                if recvRet == FFmpegErr.eagain {
                    if draining { return nil }      // flushed dry without reaching the target
                    break                           // need another packet
                }
                if recvRet == FFmpegErr.eof { return nil } // decoder drained
                guard recvRet >= 0, let f = frame else {
                    if draining { return nil }      // avoid re-flushing the same error forever
                    break                           // real error: try next packet
                }

                // Skip frames before targetPTS for frame-accuracy. No-PTS frames
                // (AV_NOPTS_VALUE == Int64.min) are accepted, so PTS-less streams
                // degrade to the first frame after the seek.
                if mode == .snapshot,
                   f.pointee.pts != Int64.min,
                   f.pointee.pts < targetPTS {
                    continue
                }

                if isCancelled() { return nil }
                return makeImage(f)
            }
        }
    }

    /// Output pixel displayDimensions for a target display width, applying source SAR
    /// so anamorphic frames draw at true shape. `targetWidth` is the display width capped
    /// to coded width; height derives from coded aspect scaled by SAR (1:1 = coded aspect).
    /// Exposed for regression testing.
    static func displayDimensions(srcW: Int, srcH: Int, sar: AVRational, targetWidth: Int) -> (Int, Int) {
        let dstW = min(targetWidth, srcW)
        let sarNum = sar.num > 0 ? Double(sar.num) : 1
        let sarDen = sar.den > 0 ? Double(sar.den) : 1
        let displayHeight = Double(dstW) * Double(srcH) * sarDen / (Double(srcW) * sarNum)
        let dstH = max(1, Int(displayHeight.rounded()))
        return (dstW, dstH)
    }

    /// Snapshot output width: native width, optionally capped to `maxSize` (aspect-preserved).
    private static func clampedWidth(frame: UnsafeMutablePointer<AVFrame>, maxSize: CGSize?) -> Int {
        let nativeW = Int(frame.pointee.width)
        let nativeH = Int(frame.pointee.height)
        guard let maxSize, maxSize.width > 0, maxSize.height > 0, nativeW > 0, nativeH > 0 else {
            return nativeW
        }
        let scale = min(maxSize.width / CGFloat(nativeW), maxSize.height / CGFloat(nativeH), 1.0)
        return max(1, Int((CGFloat(nativeW) * scale).rounded()))
    }

    /// Copy an RGBA AVFrame (e.g. tone-mapper output) into an owned-buffer CGImage.
    /// Honors linesize (row stride may exceed width*4).
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

    /// sws_scale the frame to RGBA at `targetWidth` (height from source aspect) into an
    /// owned-buffer CGImage. Mirrors the sws tuple-pointer dance in SoftwareVideoDecoder.
    private func convertToCGImage(frame: UnsafeMutablePointer<AVFrame>, targetWidth: Int) -> CGImage? {
        let srcW = Int(frame.pointee.width)
        let srcH = Int(frame.pointee.height)
        guard srcW > 0, srcH > 0, targetWidth > 0 else { return nil }

        // Resolve SAR: stream value (read at open) is authoritative, per-frame is fallback.
        let frameSAR = frame.pointee.sample_aspect_ratio
        let sar = (streamSAR.num > 1 || streamSAR.den > 1)
            ? streamSAR
            : (frameSAR.num > 0 && frameSAR.den > 0 ? frameSAR : AVRational(num: 1, den: 1))

        // Display height from coded aspect scaled by SAR so anamorphic draws true,
        // e.g. NTSC DVD 720x480 SAR 8:9 -> 4:3 not stretched 3:2.
        let (dstW, dstH) = Self.displayDimensions(
            srcW: srcW, srcH: srcH, sar: sar, targetWidth: targetWidth)
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
        // sws_scale RGBA yields opaque pixels (alpha 0xFF), so alpha is ignorable not premultiplied.
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
