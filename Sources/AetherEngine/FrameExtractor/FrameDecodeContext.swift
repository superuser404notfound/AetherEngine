import Foundation
import CoreGraphics
import CoreMedia
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import AetherLibswscale

/// Isolated, single-threaded FFmpeg decode context for still-image extraction.
/// Owns its own Demuxer, AVCodecContext, and SwsContext, separate
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
    /// Cache-backed stills run beside native AVPlayer playback, so they may use VideoToolbox.
    /// Every existing standalone/network extractor keeps the software default from issue #27.
    private let allowsHardwareDecode: Bool
    /// For a disc image (Blu-ray / DVD ISO) URL, the title to extract stills from. nil = the default
    /// (main) title. Threaded into `Demuxer.open` so a still follows the currently-selected disc title
    /// instead of always decoding the default one (AE#105).
    private let selectTitleID: Int?

    private var demuxer: Demuxer?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var hardwareDeviceContext: UnsafeMutablePointer<AVBufferRef>?
    private var hardwareDecodeDisabled = false
    private var loggedHardwareFallback = false
    private var swsContext: UnsafeMutablePointer<SwsContext>?
    private var videoStreamIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 90000)
    /// Source SAR (sample aspect ratio) read from the stream at open. Anamorphic
    /// sources (NTSC/PAL DVD, anamorphic Blu-ray) store non-square pixels; without
    /// this the thumbnail draws square-pixel and looks stretched. Defaults 1:1.
    private var streamSAR = AVRational(num: 1, den: 1)
    private(set) var isOpen = false
    private(set) var isHDR = false
    /// True for Dolby Vision Profile 5 / Profile 10.0 (no base layer): the decoded planes are
    /// IPT-PQ-C2, not standard YCbCr, so they route through DolbyVisionStillConverter (#103).
    private(set) var isDolbyVisionNoBaseLayer = false
    /// Diagnostic/test seam for the decoder selected after the first frame.
    private(set) var hardwareDecoderName: String?

    /// Cumulative bytes this context's demuxer pulled from the source (decode-queue only).
    /// Diagnostic: quantifies the extractor's share of link bandwidth per extraction.
    var bytesFetched: Int64 { demuxer?.avioBytesFetched ?? 0 }

    /// PQ (ST 2084) / HLG transfers mean the frame is HDR and needs tone-mapping to SDR.
    static func isHDRTransfer(_ trc: AVColorTransferCharacteristic) -> Bool {
        ColorAttachments.isHDRTransfer(trc)
    }

    /// True when the stream is Dolby Vision Profile 5 (HEVC) or Profile 10.0 (AV1) - the
    /// no-base-layer profiles whose decoded planes are IPT-PQ-C2, not standard YCbCr. Read
    /// from the dvcC/dvvC configuration record (`AVDOVIDecoderConfigurationRecord`). Profiles
    /// 7 / 8.x carry HDR10/HLG base layers FFmpeg decodes correctly, so they are excluded.
    static func isDVNoBaseLayer(codecpar: UnsafePointer<AVCodecParameters>) -> Bool {
        let count = Int(codecpar.pointee.nb_coded_side_data)
        guard count > 0, let sideData = codecpar.pointee.coded_side_data else { return false }
        for i in 0..<count {
            let item = sideData[i]
            guard item.type == AV_PKT_DATA_DOVI_CONF, let raw = item.data, item.size >= 8 else { continue }
            let record = raw.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
            let profile = Int(record.dv_profile)
            let compat = Int(record.dv_bl_signal_compatibility_id)
            if profile == 5 { return true }             // HEVC P5: IPT-PQ-c2, no base
            if profile == 10 && compat == 0 { return true } // AV1 P10.0: no base
            return false
        }
        return false
    }

    /// Thread budget for the disposable still/thumbnail decoder. Capped well below the
    /// core count so it cannot grab every core at playback's QoS and starve the
    /// real-time software decode (and, with subs on, the subtitle side-demuxer) on a
    /// weak A12 box (issue #27). The thumbnail has no clock deadline, so 2 is plenty.
    static func stillExtractionThreadCount(activeProcessorCount: Int) -> Int {
        return max(1, min(2, activeProcessorCount))
    }

    /// Wall-clock ceiling for a single still/thumbnail decode's HTTP reads. A healthy
    /// chunk returns far sooner; this only bounds a genuinely stalled remote source so
    /// a frozen read cannot pin the FrameExtractor's serial decode queue (issue #27).
    static let stillReadDeadlineSeconds: TimeInterval = 8

    /// A still requested more than this many seconds past the demuxer's known duration is treated as
    /// out of range and clamped (see `clampSeekSeconds`). The grace absorbs rounding on a last-frame scrub.
    static let pastDurationTolerance: Double = 1.0
    /// How far inside the end a clamped past-EOF request lands, to reach a safely-decodable frame.
    static let clampBackoffSeconds: Double = 1.0

    /// Clamp a still-extraction seek target to the demuxer's known duration. Seeking far past EOF
    /// lands on a garbage/empty frame that decodes "successfully" but is blank (AE#105: a mis-selected
    /// decoy Blu-ray title whose demuxer knew only 76s while the scrub asked for 611s). Returns the
    /// request unchanged when the duration is unknown (<= 0) or the request is within tolerance of the
    /// end; otherwise the last safely-decodable position.
    static func clampSeekSeconds(requested: Double, duration: Double) -> Double {
        guard duration > 0, requested > duration + pastDurationTolerance else { return requested }
        return max(0, duration - clampBackoffSeconds)
    }

    init(url: URL, httpHeaders: [String: String], selectTitleID: Int? = nil,
         allowsHardwareDecode: Bool = false) {
        self.url = url
        self.httpHeaders = httpHeaders
        self.reader = nil
        self.formatHint = nil
        self.selectTitleID = selectTitleID
        self.allowsHardwareDecode = allowsHardwareDecode
    }

    init(reader: IOReader, formatHint: String?, allowsHardwareDecode: Bool = false) {
        // Placeholder; unused when reader != nil (openInternal opens the reader).
        self.url = URL(string: "aether-custom://frame-extractor")!
        self.httpHeaders = [:]
        self.reader = reader
        self.formatHint = formatHint
        self.selectTitleID = nil
        // DataIOReader is internal and exists for the native segment-cache still path. Recognizing
        // it here keeps both VOD and live FrameExtractor call sites byte-identical and leaves every
        // public custom-reader/network caller on the issue #27 software default. The 2026-09-02
        // device trace measured 30 software context opens in 20 seconds over resident H.264 bytes.
        self.allowsHardwareDecode = allowsHardwareDecode || reader is DataIOReader
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
        if hardwareDeviceContext != nil {
            av_buffer_unref(&hardwareDeviceContext)
        }
        hardwareDeviceContext = nil
        if swsContext != nil {
            sws_freeContext(swsContext)
            swsContext = nil
        }
        demuxer?.close()
        demuxer = nil
        videoStreamIndex = -1
        isHDR = false
        isDolbyVisionNoBaseLayer = false
        hardwareDecoderName = nil
        isOpen = false
    }

    private func openInternal() throws {
        let demuxer = Demuxer()
        if let reader = reader {
            try demuxer.open(reader: reader, formatHint: formatHint, profile: .stillExtraction)
        } else {
            try demuxer.open(url: url, extraHeaders: httpHeaders, profile: .stillExtraction, selectTitleID: selectTitleID)
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
        // Both fields: codecpar holds the bitstream-declared ratio, while a container-declared one
        // (Matroska DisplayWidth, MP4 pasp) reaches AVStream alone. Resolved by the shared rule, so
        // a thumbnail cannot be shaped by a different ratio than the playing picture.
        let declared = SoftwareVideoDecoder.declaredStreamSAR(
            bitstream: codecpar.pointee.sample_aspect_ratio,
            container: stream.pointee.sample_aspect_ratio
        )
        if declared.num > 0, declared.den > 0 {
            streamSAR = declared
        }
        isHDR = Self.isHDRTransfer(codecpar.pointee.color_trc)
        isDolbyVisionNoBaseLayer = Self.isDVNoBaseLayer(codecpar: codecpar)
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw FrameDecodeError.unsupportedCodec
        }
        var openedWithHardware = false
        if allowsHardwareDecode, !hardwareDecodeDisabled {
            let deviceResult = av_hwdevice_ctx_create(
                &hardwareDeviceContext, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0)
            if deviceResult >= 0, hardwareDeviceContext != nil {
                do {
                    codecContext = try makeCodecContext(
                        codecpar: codecpar, codec: codec, useHardware: true)
                    openedWithHardware = true
                } catch {
                    disableHardwareDecode("decoder open failed")
                }
            } else {
                disableHardwareDecode("device creation failed ret=\(deviceResult)")
            }
        }

        if !openedWithHardware {
            if hardwareDeviceContext != nil {
                av_buffer_unref(&hardwareDeviceContext)
            }
            hardwareDeviceContext = nil
            codecContext = try makeCodecContext(
                codecpar: codecpar, codec: codec, useHardware: false)
            logOpened(codecpar: codecpar, codec: codec, hardware: "none")
        }
    }

    private func makeCodecContext(
        codecpar: UnsafeMutablePointer<AVCodecParameters>,
        codec: UnsafePointer<AVCodec>,
        useHardware: Bool
    ) throws -> UnsafeMutablePointer<AVCodecContext> {
        guard let ctx = avcodec_alloc_context3(codec) else {
            throw FrameDecodeError.allocationFailed
        }
        guard avcodec_parameters_to_context(ctx, codecpar) >= 0 else {
            var doomed: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&doomed)
            throw FrameDecodeError.noCodecParameters
        }

        if useHardware, let hardwareDeviceContext {
            ctx.pointee.hw_device_ctx = av_buffer_ref(hardwareDeviceContext)
            ctx.pointee.get_format = { _, fmts in
                guard let fmts else { return AV_PIX_FMT_NONE }
                var fallback = AV_PIX_FMT_NONE
                var i = 0
                while fmts[i] != AV_PIX_FMT_NONE {
                    if fmts[i] == AV_PIX_FMT_VIDEOTOOLBOX { return fmts[i] }
                    if fallback == AV_PIX_FMT_NONE { fallback = fmts[i] }
                    i += 1
                }
                return fallback
            }
        } else {
            ctx.pointee.get_format = { _, fmts in
                guard let fmts = fmts else { return AV_PIX_FMT_NONE }
                var i = 0
                while fmts[i] != AV_PIX_FMT_NONE {
                    if fmts[i] != AV_PIX_FMT_VIDEOTOOLBOX { return fmts[i] }
                    i += 1
                }
                return AV_PIX_FMT_YUV420P
            }
        }
        ctx.pointee.thread_count = Int32(Self.stillExtractionThreadCount(
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount))
        ctx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE

        // Still extraction needs no deblock or full-rate quality: skip loop filter
        // and enable the fast/inaccurate path to cut per-frame CPU on big HEVC/AV1 keyframes.
        // AV_CODEC_FLAG2_FAST is a C #define (1 << 0) that does not bridge to Swift.
        let AV_CODEC_FLAG2_FAST_VALUE: Int32 = 1 << 0
        ctx.pointee.skip_loop_filter = AVDISCARD_ALL
        ctx.pointee.flags2 |= AV_CODEC_FLAG2_FAST_VALUE

        var opts: OpaquePointer?
        if !useHardware {
            // Belt-and-suspenders with the software get_format callback above.
            av_dict_set(&opts, "hwaccel", "none", 0)
        }
        let openResult = avcodec_open2(ctx, codec, &opts)
        av_dict_free(&opts)
        guard openResult >= 0 else {
            var doomed: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&doomed)
            throw FrameDecodeError.decoderOpenFailed
        }
        return ctx
    }

    private func disableHardwareDecode(_ reason: String) {
        hardwareDecodeDisabled = true
        if !loggedHardwareFallback {
            loggedHardwareFallback = true
            EngineLog.emit(
                "[FrameDecode] VideoToolbox unavailable; using software (\(reason))",
                category: .swPlayback)
        }
    }

    private func logOpened(
        codecpar: UnsafeMutablePointer<AVCodecParameters>,
        codec: UnsafePointer<AVCodec>,
        hardware: String
    ) {
        hardwareDecoderName = hardware
        guard let ctx = codecContext else { return }
        EngineLog.emit(
            "[FrameDecode] Opened \(codecpar.pointee.width)x\(codecpar.pointee.height) "
            + "codec=\(String(cString: codec.pointee.name)) threads=\(ctx.pointee.thread_count) "
            + "hw=\(hardware)",
            category: .swPlayback)
    }

    private func replaceHardwareDecoderWithSoftware(reason: String) -> Bool {
        disableHardwareDecode(reason)
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        codecContext = nil
        if hardwareDeviceContext != nil {
            av_buffer_unref(&hardwareDeviceContext)
        }
        hardwareDeviceContext = nil
        hardwareDecoderName = nil

        guard let stream = demuxer?.stream(at: videoStreamIndex),
              let codecpar = stream.pointee.codecpar,
              let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            isOpen = false
            return false
        }
        do {
            codecContext = try makeCodecContext(
                codecpar: codecpar, codec: codec, useHardware: false)
            logOpened(codecpar: codecpar, codec: codec, hardware: "none")
            return true
        } catch {
            isOpen = false
            return false
        }
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

        // Bound this decode's HTTP reads so a stalled remote source can't park the
        // serial decode queue and freeze the scrub preview (issue #27). No-op for
        // file:// / custom sources. Disarmed on every exit path.
        demuxer.beginReadDeadline(secondsFromNow: Self.stillReadDeadlineSeconds)
        defer { demuxer.endReadDeadline() }

        avcodec_flush_buffers(ctx)

        // AVDISCARD_DEFAULT for both modes. AVDISCARD_NONKEY breaks streams whose seek
        // lands mid-GOP past a sparse keyframe (every packet discarded -> EAGAIN, nil frame);
        // thumbnail gains nothing from it, and snapshot must keep all frames to reach exact PTS.
        ctx.pointee.skip_frame = AVDISCARD_DEFAULT

        // Clamp a request past the demuxer's known duration to the last decodable frame: seeking far
        // past EOF returns a blank garbage frame that still reports success (AE#105). Both the seek and
        // the forward-decode target below must use the clamped value or snapshot would chase an
        // unreachable PTS forever.
        let seekSeconds = Self.clampSeekSeconds(requested: seconds, duration: demuxer.duration)
        if seekSeconds != seconds {
            EngineLog.emit(
                "[FrameExtractor] still past duration: t=\(String(format: "%.2f", seconds))s "
                + "> duration=\(String(format: "%.2f", demuxer.duration))s; clamped to "
                + "\(String(format: "%.2f", seekSeconds))s",
                category: .swPlayback)
        }

        demuxer.seek(to: seekSeconds)

        guard timeBase.num > 0 else { return nil }
        let targetPTS = Int64((seekSeconds * Double(timeBase.den)) / Double(timeBase.num))

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard frame != nil else { return nil }
        defer { av_frame_free(&frame) }

        var hardwareTransferFailure: Int32?
        func makeImage(_ decodedFrame: UnsafeMutablePointer<AVFrame>) -> CGImage? {
            var transferredFrame: UnsafeMutablePointer<AVFrame>?
            let f: UnsafeMutablePointer<AVFrame>
            if decodedFrame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
                transferredFrame = av_frame_alloc()
                guard let transferTarget = transferredFrame else { return nil }
                let transferResult = av_hwframe_transfer_data(transferTarget, decodedFrame, 0)
                guard transferResult >= 0 else {
                    hardwareTransferFailure = transferResult
                    av_frame_free(&transferredFrame)
                    return nil
                }
                let propertyResult = av_frame_copy_props(transferTarget, decodedFrame)
                guard propertyResult >= 0 else {
                    hardwareTransferFailure = propertyResult
                    av_frame_free(&transferredFrame)
                    return nil
                }
                f = transferTarget
                if hardwareDecoderName == nil,
                   let stream = demuxer.stream(at: videoStreamIndex),
                   let codecpar = stream.pointee.codecpar,
                   let codec = avcodec_find_decoder(codecpar.pointee.codec_id) {
                    logOpened(codecpar: codecpar, codec: codec, hardware: "videotoolbox")
                }
            } else {
                f = decodedFrame
                if hardwareDecoderName == nil,
                   let stream = demuxer.stream(at: videoStreamIndex),
                   let codecpar = stream.pointee.codecpar,
                   let codec = avcodec_find_decoder(codecpar.pointee.codec_id) {
                    logOpened(codecpar: codecpar, codec: codec, hardware: "none")
                }
            }
            defer {
                if transferredFrame != nil {
                    av_frame_free(&transferredFrame)
                }
            }
            let width = mode == .thumbnail
                ? targetWidth
                : Self.clampedWidth(frame: f, maxSize: maxSize)
            if isDolbyVisionNoBaseLayer {
                let sar = resolvedSAR(frame: f)
                if let img = DolbyVisionStillConverter.makeImage(frame: f, targetWidth: width, sar: sar) {
                    return img
                }
                // No DV metadata on this frame / unsupported layout: fall through to the standard path.
            }
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
                let image = makeImage(f)
                if let hardwareTransferFailure {
                    guard replaceHardwareDecoderWithSoftware(
                        reason: "frame transfer failed ret=\(hardwareTransferFailure)") else {
                        return nil
                    }
                    return decodeFrame(
                        at: seconds,
                        mode: mode,
                        targetWidth: targetWidth,
                        maxSize: maxSize,
                        isCancelled: isCancelled)
                }
                return image
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

    /// Stream SAR (read at open) is authoritative, per-frame is fallback, square pixels are the
    /// floor. #290: each candidate is judged against the frame it applies to, so a declared ratio
    /// that would smear the picture into a band (a live channel claiming 3:1 on 1920x1080) drops
    /// through instead of scaling a thumbnail to it. See `PixelAspectPolicy`.
    private func resolvedSAR(frame: UnsafeMutablePointer<AVFrame>) -> AVRational {
        let width = frame.pointee.width
        let height = frame.pointee.height
        if streamSAR.num > 1 || streamSAR.den > 1,
           let sane = PixelAspectPolicy.saneSAR(streamSAR, width: width, height: height) {
            return sane
        }
        if let sane = PixelAspectPolicy.saneSAR(
            frame.pointee.sample_aspect_ratio, width: width, height: height) {
            return sane
        }
        return AVRational(num: 1, den: 1)
    }

    /// sws_scale the frame to RGBA at `targetWidth` (height from source aspect) into an
    /// owned-buffer CGImage. Mirrors the sws tuple-pointer dance in SoftwareVideoDecoder.
    private func convertToCGImage(frame: UnsafeMutablePointer<AVFrame>, targetWidth: Int) -> CGImage? {
        let srcW = Int(frame.pointee.width)
        let srcH = Int(frame.pointee.height)
        guard srcW > 0, srcH > 0, targetWidth > 0 else { return nil }

        let sar = resolvedSAR(frame: frame)

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

enum FrameDecodeError: Error, CustomStringConvertible, LocalizedError {
    case noVideoStream
    case noCodecParameters
    case unsupportedCodec
    case allocationFailed
    case decoderOpenFailed

    var description: String {
        switch self {
        case .noVideoStream: "FrameDecode: source has no video stream"
        case .noCodecParameters: "FrameDecode: video stream has no codec parameters"
        case .unsupportedCodec: "FrameDecode: no decoder for the video codec"
        case .allocationFailed: "FrameDecode: avcodec_alloc_context3 failed"
        case .decoderOpenFailed: "FrameDecode: decoder open failed"
        }
    }

    var errorDescription: String? { description }
}
