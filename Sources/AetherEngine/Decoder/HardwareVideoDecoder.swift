import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Libavformat
import Libavcodec
import Libavutil

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
    var onFirstHDR10PlusDetected: (() -> Void)?

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

    /// Protects `session` across the demux thread (decode), main thread (close/flush), and VT callback (delivery).
    private let lock = NSLock()

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

        guard codecpar.pointee.codec_id == AV_CODEC_ID_HEVC else {
            throw VideoDecoderError.unsupportedCodec(id: codecpar.pointee.codec_id.rawValue)
        }

        // 1. Build CMVideoFormatDescription from the hvcC extradata via
        //    kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms (same shape AVFoundation uses for .mp4/.mkv).
        guard let extradata = codecpar.pointee.extradata, codecpar.pointee.extradata_size > 0 else {
            throw VideoDecoderError.noExtradata
        }
        let hvcCData = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
        var fd: CMVideoFormatDescription?
        let atomsDict: NSDictionary = ["hvcC": hvcCData]
        let extensions: NSDictionary = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atomsDict,
        ]
        let fdStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: width,
            height: height,
            extensions: extensions,
            formatDescriptionOut: &fd
        )
        guard fdStatus == noErr, let formatDesc = fd else {
            throw VideoDecoderError.formatDescriptionFailed(status: fdStatus)
        }
        formatDescription = formatDesc

        // 2. Require hardware on tvOS 17+ so VT fails outright rather than silently falling back to SW
        //    (which would show only as pathological CPU + frame drops at 4K). Deployment target is tvOS 26
        //    so the if-available branch is always taken in production.
        var decoderSpec: NSDictionary?
        if #available(tvOS 17.0, iOS 17.0, *) {
            decoderSpec = [
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
            ]
        }

        // 3. Pixel buffer attributes: 10-bit biplanar for HDR, 8-bit for SDR; IOSurface-backed for Metal rendering.
        let bitsPerSample = codecpar.pointee.bits_per_raw_sample
        let isHDRTransfer = ColorAttachments.isHDRTransfer(codecpar.pointee.color_trc)
        let use10Bit = bitsPerSample > 8 || isHDRTransfer

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
        if #available(tvOS 17.0, iOS 17.0, *) {
            VTSessionSetProperty(
                createdSession,
                key: kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
                value: kCFBooleanTrue
            )
        }

        EngineLog.emit(
            "[HardwareVideoDecoder] opened HEVC \(width)x\(height) "
            + "\(use10Bit ? "10-bit" : "8-bit") "
            + "transfer=\(codecpar.pointee.color_trc.rawValue)",
            category: .swPlayback
        )
    }

    // MARK: - Decode

    func decode(packet: UnsafeMutablePointer<AVPacket>) {
        lock.lock()
        guard let session = session, let formatDesc = formatDescription else {
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
        let ptsRaw = packet.pointee.pts
        let dtsRaw = packet.pointee.dts
        let durRaw = packet.pointee.duration
        let timescale = max(timeBase.den, 1)

        let pts = (ptsRaw != Int64.min)
            ? CMTimeMake(value: ptsRaw * Int64(timeBase.num), timescale: timescale)
            : CMTime.invalid
        let dts = (dtsRaw != Int64.min)
            ? CMTimeMake(value: dtsRaw * Int64(timeBase.num), timescale: timescale)
            : CMTime.invalid
        let dur = (durRaw > 0)
            ? CMTimeMake(value: durRaw * Int64(timeBase.num), timescale: timescale)
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

        // Async decode with temporal queueing; callback fires on VT's internal queue.
        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sb,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if decodeStatus != noErr {
            EngineLog.emit(
                "[HardwareVideoDecoder] decode error \(decodeStatus) at pts=\(ptsRaw)",
                category: .swPlayback
            )
        }
    }

    func flush() {
        lock.lock()
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
        if let transfer = colorTransfer {
            CVBufferSetAttachment(imageBuffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        }
        if let matrix = colorMatrix {
            CVBufferSetAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }

        onFrame?(imageBuffer, pts, nil)
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
