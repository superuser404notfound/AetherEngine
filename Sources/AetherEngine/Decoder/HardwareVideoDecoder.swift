import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// VTDecompressionSession-backed HEVC decoder for the SoftwarePlaybackHost pipeline.
/// Owns the decoded-frame pool, IOSurface lifetime, and session teardown explicitly
/// (AVPlayer's opaque state grows unbounded on long 4K HDR sessions).
/// Same surface as SoftwareVideoDecoder so the host can swap without rewiring the demux loop.
final class HardwareVideoDecoder: VideoDecodingPipeline, @unchecked Sendable {

    // MARK: - Public surface (mirrors SoftwareVideoDecoder)

    /// Guarded by `skipLock` (not `lock`): close() holds `lock` across the VT drain that calls back into onFrame,
    /// so using `lock` here would deadlock. Multi-word closure swap is a data race without the guard.
    var onFrame: DecodedFrameHandler? {
        get { skipLock.lock(); defer { skipLock.unlock() }; return _onFrame }
        set { skipLock.lock(); _onFrame = newValue; skipLock.unlock() }
    }
    private var _onFrame: DecodedFrameHandler?
    /// Not yet wired on the VT side (follow-up: read AV_PKT_DATA_DYNAMIC_HDR10_PLUS before decode,
    /// mirror SoftwareVideoDecoder.extractHDR10PlusBytes). Flag kept so host wiring stays identical to SW path.
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?
    var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
    private var streamColor = ColorDescription.unspecified
    private var streamCodecID = AV_CODEC_ID_NONE
    private var streamProfile = AV_PROFILE_UNKNOWN
    private var reportedPixelBufferType: OSType = 0

    /// Skip pre-seek RASL frames to avoid the "fast forward" effect; decoded for reference but not delivered.
    /// Guarded by `skipLock` not `lock`: close() holds `lock` across VTDecompressionSessionWaitForAsynchronousFrames,
    /// which waits for the very callback that would need it (deadlock). CMTime is multi-word: old unsynchronized access was torn-read + ARC race.
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

    // MARK: - Internals

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)
    private var width: Int32 = 0
    private var height: Int32 = 0

    /// Color metadata from codecpar, re-applied to every CVPixelBuffer.
    /// VTDecompressionSession should propagate these from SPS+hvcC but has been observed not to;
    /// without them an HDR buffer renders as desaturated SDR on AVSampleBufferDisplayLayer.
    private var colorPrimaries: CFString?
    private var colorTransfer: CFString?
    private var colorMatrix: CFString?

    /// #354: the stream's pixel aspect ratio, re-applied to every CVPixelBuffer for the same reason
    /// the colorimetry is: nothing else puts it there. The renderer builds its format description
    /// from the delivered buffer, so a ratio that is not an attachment on that buffer never reaches
    /// the layer, and anamorphic content is displayed at its coded dimensions. nil for square pixels
    /// and for a ratio the policy rejects, which is the case where coded dimensions ARE correct.
    ///
    /// Resolved once at `open()`, not per frame: VT delivers pixel buffers rather than `AVFrame`s, so
    /// the per-frame source `SoftwareVideoDecoder` prefers does not exist here. That also makes the
    /// #177 latch unnecessary, since one resolution cannot oscillate.
    private var pixelAspectRatio: AVRational?

    /// Protects `session` across the demux thread (decode), main thread (close/flush), and VT callback (delivery).
    private let lock = NSLock()

    /// AE#492: guarded by `lock`, the same one `flush()` and `decode(packet:epoch:)` take.
    private var _feedEpoch: UInt64 = 0
    var feedEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }; return _feedEpoch
    }

    /// Heap-allocated box carrying a weak self reference for the C decompression callback's refCon.
    /// Separate object so we can pass UnsafeMutablePointer<RefConBox> to VT without unsafe bit-casts.
    /// `fileprivate` so the file-level C callback can access the type.
    private var refConBox: Unmanaged<RefConBox>?

    fileprivate final class RefConBox {
        weak var decoder: HardwareVideoDecoder?
        init(_ decoder: HardwareVideoDecoder) { self.decoder = decoder }
    }

    // MARK: - Lifecycle

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        self.onFrame = onFrame

        guard let codecpar = stream.pointee.codecpar else {
            throw VideoDecoderError.noCodecParameters
        }

        timeBase = stream.pointee.time_base
        width = codecpar.pointee.width
        height = codecpar.pointee.height

        // #354: both declared sources, because only one of them is the container's. The bitstream
        // ratio reaches codecpar, while a container-declared one reaches AVStream alone (Matroska's
        // DisplayWidth quotient, MP4's `pasp`), which is where every DVD remuxed to MKV carries it.
        pixelAspectRatio = Self.resolvePixelAspectRatio(
            bitstream: codecpar.pointee.sample_aspect_ratio,
            container: stream.pointee.sample_aspect_ratio,
            width: width,
            height: height
        )
        if let sar = pixelAspectRatio {
            EngineLog.emit(
                "[HWDecoder] SAR \(sar.num):\(sar.den) on \(width)x\(height) "
                + "(bitstream=\(codecpar.pointee.sample_aspect_ratio.num):"
                + "\(codecpar.pointee.sample_aspect_ratio.den) "
                + "container=\(stream.pointee.sample_aspect_ratio.num):"
                + "\(stream.pointee.sample_aspect_ratio.den))",
                category: .swPlayback
            )
        }

        let isVP9 = codecpar.pointee.codec_id == AV_CODEC_ID_VP9  // [MovieClaw P14]
        guard codecpar.pointee.codec_id == AV_CODEC_ID_HEVC || (isVP9 && Self.decodesVP9InHardware(codecpar)) else {
            throw VideoDecoderError.unsupportedCodec(id: codecpar.pointee.codec_id.rawValue)
        }

        // 1. Build CMVideoFormatDescription from the hvcC extradata via
        //    kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms (same shape AVFoundation uses for .mp4/.mkv).
        //    [MovieClaw P14] VP9 没有 extradata：vpcC 由流参数拼出来
        let atomsDict: NSDictionary
        if isVP9 {
            atomsDict = ["vpcC": Self.vpcC(codecpar)]
        } else {
            guard let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 else {
                throw VideoDecoderError.noExtradata
            }
            atomsDict = ["hvcC": Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))]
        }
        var fd: CMVideoFormatDescription?
        let extensions: NSDictionary = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atomsDict,
        ]
        let fdStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: isVP9 ? kCMVideoCodecType_VP9 : kCMVideoCodecType_HEVC,
            width: width,
            height: height,
            extensions: extensions,
            formatDescriptionOut: &fd
        )
        guard fdStatus == noErr, let formatDesc = fd else {
            throw VideoDecoderError.formatDescriptionFailed(status: fdStatus)
        }
        formatDescription = formatDesc

        // 2. Require hardware so VT fails outright rather than silently falling back to SW
        //    (which would show only as pathological CPU + frame drops at 4K).
        let decoderSpec: NSDictionary = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
        ]

        // 3. Pixel buffer attributes: 10-bit biplanar for HDR, 8-bit for SDR; IOSurface-backed for Metal rendering.
        let bitsPerSample = codecpar.pointee.bits_per_raw_sample
        let isHDRTransfer = ColorAttachments.isHDRTransfer(codecpar.pointee.color_trc)
        let use10Bit = bitsPerSample > 8 || isHDRTransfer

        streamColor = ColorDescription(codecpar: codecpar)
        streamCodecID = codecpar.pointee.codec_id
        streamProfile = codecpar.pointee.profile
        self.colorPrimaries = ColorAttachments.primaries(codecpar.pointee.color_primaries)
        self.colorTransfer = ColorAttachments.transfer(codecpar.pointee.color_trc)
        self.colorMatrix = ColorAttachments.matrix(codecpar.pointee.color_space)
        let pixelFormat: OSType = use10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let pixelBufferAttrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        // 4. Output callback: C function dispatches into handleDecodedFrame via refCon.
        let box = RefConBox(self)
        let unmanaged = Unmanaged.passRetained(box)
        refConBox = unmanaged

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: hwDecoderOutputCallback,
            decompressionOutputRefCon: unmanaged.toOpaque()
        )

        var sessionOut: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: decoderSpec,
            imageBufferAttributes: pixelBufferAttrs,
            outputCallback: &callback,
            decompressionSessionOut: &sessionOut
        )
        guard status == noErr, let createdSession = sessionOut else {
            unmanaged.release()
            refConBox = nil
            throw VideoDecoderError.sessionCreationFailed(status: status)
        }
        session = createdSession

        // 5. Pass through per-frame HDR metadata for correct tone mapping; unknown-key set returns -12911 on older OSes (swallowed).
        VTSessionSetProperty(
            createdSession,
            key: kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
            value: kCFBooleanTrue
        )

        EngineLog.emit(
            "[HardwareVideoDecoder] opened \(isVP9 ? "VP9" : "HEVC") \(width)x\(height) "
            + "\(use10Bit ? "10-bit" : "8-bit") "
            + "transfer=\(codecpar.pointee.color_trc.rawValue)",
            category: .swPlayback
        )
    }

    // MARK: - Decode

    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64? = nil) {
        lock.lock()
        // AE#492: see `SoftwareVideoDecoder.decode`. Same rule, same lock as `flush()`.
        if let epoch, epoch != _feedEpoch { lock.unlock(); return }
        guard session != nil, let formatDesc = formatDescription else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Wrap the packet (HEVC length-prefix framing from FFmpeg's matroska demuxer, already the VT-expected format)
        // in a CMBlockBuffer+CMSampleBuffer. Copy once: VT may retain the buffer past the call (async decode),
        // and AVPacket storage is reused for the next packet.
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        let size = Int(packet.pointee.size)
        let copied = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        copied.copyMemory(from: data, byteCount: size)

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: copied,
            blockLength: size,
            blockAllocator: kCFAllocatorDefault,  // ← matching dealloc allocator
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: size,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let bb = blockBuffer else {
            // CMBlockBuffer takes ownership only on success; we own the allocation on failure.
            copied.deallocate()
            return
        }
        let pts = SourceTimestampBounds.cmTime(ticks: packet.pointee.pts, timeBase: timeBase)
        let dts = SourceTimestampBounds.cmTime(ticks: packet.pointee.dts, timeBase: timeBase)
        let dur = packet.pointee.duration > 0
            ? SourceTimestampBounds.cmTime(ticks: packet.pointee.duration, timeBase: timeBase)
            : CMTime.invalid

        var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var sampleSize = size

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else { return }

        // Tag non-keyframes as DependsOnOthers so VT can drop pre-seek RASL frames after a flush.
        if (packet.pointee.flags & AV_PKT_FLAG_KEY) == 0 {
            if let attachArray = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
               CFArrayGetCount(attachArray) > 0 {
                let dict = unsafeBitCast(
                    CFArrayGetValueAtIndex(attachArray, 0),
                    to: CFMutableDictionary.self
                )
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        // Audit DEC-4: the epoch check and the send sit under one hold of `lock`, or a flush landing
        // while the sample buffer is built lets a pre-seek packet into VT after it. Safe to hold:
        // the output callback never takes `lock`, and `close()` already holds it across the VT wait.
        lock.lock()
        if let epoch, epoch != _feedEpoch { lock.unlock(); return }
        guard let session = self.session else { lock.unlock(); return }
        // Async decode with temporal queueing; callback fires on VT's internal queue.
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sb,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        lock.unlock()
        if decodeStatus != noErr {
            EngineLog.emit(
                "[HardwareVideoDecoder] decode error \(decodeStatus) at pts=\(packet.pointee.pts)",
                category: .swPlayback
            )
        }
    }

    func flush() {
        lock.lock()
        _feedEpoch &+= 1   // AE#492
        let session = self.session
        lock.unlock()
        guard let session else { return }
        // Drain in-flight frames then signal a discontinuity so VT drops its reference picture state.
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionFinishDelayedFrames(session)
    }

    func close() {
        lock.lock()
        if let session = session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        formatDescription = nil
        lock.unlock()

        if let box = refConBox {
            box.release()
            refConBox = nil
        }
        onFrame = nil
    }

    deinit {
        close()
    }

    // MARK: - Pixel aspect ratio (#354)

    /// The ratio to attach, or nil when there is nothing to correct. Bitstream first, container
    /// second (`declaredStreamSAR`), then the same two gates the libavcodec path runs: the #177
    /// component bound and the #290 display aspect the ratio produces on this frame. Square pixels
    /// return nil rather than 1:1, because attaching a correction of one is a correction a consumer
    /// cannot tell from a real one.
    static func resolvePixelAspectRatio(
        bitstream: AVRational, container: AVRational, width: Int32, height: Int32
    ) -> AVRational? {
        PixelAspectPolicy.declaredPixelAspect(
            bitstream: bitstream, container: container, width: width, height: height)
    }

    // MARK: - Callback handling (called from VT's queue)

    /// Invoked by `hwDecoderOutputCallback`; delivers CVPixelBuffer+PTS, honouring `skipUntilPTS` for seek-pre-roll.
    fileprivate func handleDecodedFrame(
        imageBuffer: CVImageBuffer,
        pts: CMTime
    ) {
        if let threshold = skipUntilPTS {
            if CMTimeCompare(pts, threshold) < 0 {
                return
            }
            // Compare-and-clear: a concurrent seek can install a new threshold; blindly nil-ing would discard it.
            clearSkip(ifStillAt: threshold)
        }

        // Attach color metadata; without it HDR PQ content shows as desaturated SDR on AVSampleBufferDisplayLayer.
        if let primaries = colorPrimaries {
            CVBufferSetAttachment(imageBuffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        }
        // [MovieClaw P60] SDR goes out as sRGB on Mac / iPhone. An undeclared transfer is judged on the tag
        // VideoToolbox read off the SPS VUI, so an HDR stream the container never labelled stays HDR.
        let decodedTransfer = colorTransfer
            ?? (CVBufferCopyAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, nil) as? String).map { $0 as CFString }
        CVBufferSetAttachment(imageBuffer, kCVImageBufferTransferFunctionKey,
                              ColorAttachments.shownTransfer(decodedTransfer), .shouldPropagate)
        if let matrix = colorMatrix {
            CVBufferSetAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }

        // #354: without this the renderer's format description carries no pixel aspect ratio and
        // anamorphic content is displayed at its coded dimensions.
        if let sar = pixelAspectRatio {
            let aspect: NSDictionary = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(sar.num),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(sar.den),
            ]
            CVBufferSetAttachment(imageBuffer, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
        } else {
            // A recycled pool buffer can carry a stale attachment from an earlier stream.
            CVBufferRemoveAttachment(imageBuffer, kCVImageBufferPixelAspectRatioKey)
        }

        reportDecodedFormat(imageBuffer)
        onFrame?(imageBuffer, pts, nil)
    }

    /// VideoToolbox decodes straight into the display buffer, so the buffer IS the decoded picture; its
    /// colour is what this decoder attached, which is the stream's declaration.
    private func reportDecodedFormat(_ buffer: CVImageBuffer) {
        guard let onDecodedFormat else { return }
        let type = CVPixelBufferGetPixelFormatType(buffer)
        guard type != reportedPixelBufferType else { return }
        reportedPixelBufferType = type
        onDecodedFormat(DecodedVideoFormat(
            frame: VideoStreamFormat(
                pixelFormat: DecodedVideoFormat.libavPixelFormat(forPixelBufferType: type),
                declaredBitDepth: 0,
                color: streamColor,
                codecID: streamCodecID,
                profile: streamProfile),
            pixelBufferFormat: DecodedVideoFormat.fourCC(type)))
    }
}

// MARK: - C callback

private func hwDecoderOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard status == noErr, let imageBuffer = imageBuffer else { return }
    guard let refCon = decompressionOutputRefCon else { return }
    let box = Unmanaged<HardwareVideoDecoder.RefConBox>
        .fromOpaque(refCon).takeUnretainedValue()
    box.decoder?.handleDecodedFrame(
        imageBuffer: imageBuffer,
        pts: presentationTimeStamp
    )
}

// MARK: - [MovieClaw P14] VP9 硬解（VideoToolbox）
//
// VP9 原来一律走 libavcodec 软解：真机 4K VP9（《The Age of A.I.》）本进程 CPU 约 48%，连播 7 分钟温度就到「偏热」。
// iOS 26.2 起 VideoToolbox 的 VP9 解码器是「补充解码器」，登记后才可用（`VTRegisterSupplementalVideoDecoderIfAvailable`）；
// 登记后照常建 VTDecompressionSession，格式描述用 vpcC（没有 extradata，由流参数拼），包原样送进去。
extension HardwareVideoDecoder {
    /// 登记 VP9 补充解码器并确认有硬解（只做一次）
    static let vp9HardwareAvailable: Bool = {
        if #available(iOS 26.2, tvOS 26.2, macOS 11.0, visionOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            return VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
        }
        return false
    }()

    /// 这条 VP9 流交给硬件：有硬解，且是 4:2:0 的 8 / 10 bit（profile 0 / 2）；4:4:4 等少见格式仍软解
    static func decodesVP9InHardware(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> Bool {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_VP9, vp9HardwareAvailable else { return false }
        let format = vp9Format(codecpar)
        return format.chroma <= 1 && (format.depth == 8 || format.depth == 10)
    }

    /// 位深与色度抽样（vpcC 的编码：0/1 = 4:2:0，2 = 4:2:2，3 = 4:4:4）
    private static func vp9Format(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> (depth: Int, chroma: UInt8) {
        guard let desc = av_pix_fmt_desc_get(AVPixelFormat(rawValue: codecpar.pointee.format)) else {
            return (codecpar.pointee.bits_per_raw_sample > 8 ? Int(codecpar.pointee.bits_per_raw_sample) : 8, 1)
        }
        let depth = Int(desc.pointee.comp.0.depth)
        let chroma: UInt8 = desc.pointee.log2_chroma_w == 1 ? (desc.pointee.log2_chroma_h == 1 ? 1 : 2) : 3
        return (depth, chroma)
    }

    /// vpcC 盒的内容（version 1、flags 0，后接 VPCodecConfigurationRecord）
    static func vpcC(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> Data {
        let par = codecpar.pointee
        let format = vp9Format(codecpar)
        let profile: UInt8 = (0 ... 3).contains(par.profile) ? UInt8(par.profile) : (format.depth > 8 ? 2 : 0)
        // 容器多半不写级别：按画面大小给一个够用的（4K 用 5.1）
        let level: UInt8 = par.level > 0 && par.level < 100 ? UInt8(par.level)
            : (Int(par.width) * Int(par.height) > 2_228_224 ? (Int(par.width) * Int(par.height) > 8_912_896 ? 61 : 51) : 41)
        let fullRange: UInt8 = par.color_range == AVCOL_RANGE_JPEG ? 1 : 0
        return Data([1, 0, 0, 0, profile, level,
                     UInt8(format.depth << 4) | (format.chroma << 1) | fullRange,
                     UInt8(truncatingIfNeeded: par.color_primaries.rawValue),
                     UInt8(truncatingIfNeeded: par.color_trc.rawValue),
                     UInt8(truncatingIfNeeded: par.color_space.rawValue),
                     0, 0])
    }
}
