import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Libavformat
import Libavcodec
import Libavutil

/// Hardware-accelerated video decoder via VideoToolbox. Built as a
/// drop-in counterpart to `SoftwareVideoDecoder` so the
/// `SoftwarePlaybackHost` (which is misnamed — it really hosts any
/// non-AVPlayer decode + render pipeline) can pick the right backend
/// per codec.
///
/// Currently supports HEVC. H.264 / AV1 could be added with small
/// codec-type changes; we leave them on libavcodec or dav1d
/// respectively for now because the immediate motivation is the
/// 4K HDR HEVC memory-pressure work where AVPlayer's opaque internal
/// state grows unbounded over long sessions, and routing HEVC
/// through our own VT decoder lets us own the decoded-frame pool,
/// the IOSurface lifetime, and the session teardown explicitly.
///
/// Same public surface as `SoftwareVideoDecoder` (open / decode /
/// flush / close + onFrame + onFirstHDR10PlusDetected) so the host
/// can swap implementations without rewiring the demux loop.
final class HardwareVideoDecoder: VideoDecodingPipeline, @unchecked Sendable {

    // MARK: - Public surface (mirrors SoftwareVideoDecoder)

    var onFrame: DecodedFrameHandler?
    /// HDR10+ side data isn't extracted in the POC; the flag is here
    /// so the host's wiring stays identical to the software path.
    /// A follow-up pass will mirror `SoftwareVideoDecoder.extractHDR10PlusBytes`
    /// for the VT side, reading dynamic metadata off the packet's
    /// `AV_PKT_DATA_DYNAMIC_HDR10_PLUS` side data before decode.
    var onFirstHDR10PlusDetected: (() -> Void)?

    /// After a seek, skip frames before this PTS to avoid the
    /// "fast forward" effect of dumping pre-seek RASL frames to the
    /// renderer. Decoded for reference but not delivered upstream.
    var skipUntilPTS: CMTime?

    // MARK: - Internals

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)
    private var width: Int32 = 0
    private var height: Int32 = 0

    /// Protects `session` from concurrent access between the demux
    /// thread (decode), the main thread (close/flush), and the
    /// VT callback (frame delivery).
    private let lock = NSLock()

    /// Pointer back to self for the C decompression callback. Set in
    /// `open`, cleared in `close`. The session holds this in its
    /// `decompressionOutputRefCon` so the callback can resolve `self`
    /// without capturing it in a Swift closure (the VT API is C-only).
    private var refConBox: Unmanaged<RefConBox>?

    /// Small heap-allocated box for the unsafe pointer-to-self the
    /// C callback dereferences. Separate object so we can pass a
    /// `UnsafeMutablePointer<RefConBox>` to VT and still get the
    /// Swift instance back without unsafe bit-casts. `fileprivate`
    /// so the file-level C callback below can reference the type.
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

        // 1. Build CMVideoFormatDescription from the source's hvcC
        //    extradata. CMVideoFormatDescriptionCreate with
        //    kCMVideoCodecType_HEVC accepts the hvcC bytes via the
        //    `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms`
        //    extension dictionary, the same shape AVFoundation builds
        //    internally when consuming an .mp4/.mkv HEVC track.
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

        // 2. Decoder specification: REQUIRE hardware. Refuse the
        //    session creation outright if VT would otherwise fall
        //    back to software decode on this platform/codec, because
        //    the whole point of routing HEVC through this path is
        //    HW decode under our explicit lifecycle. Software-decode
        //    HEVC is rejected by the user and would tank CPU at 4K
        //    anyway. Key is iOS 17 / tvOS 17 (`require`); pre-iOS 17
        //    falls back to the `prefer` key which gives the same
        //    behaviour on devices with HW decode but allows SW
        //    fallback if unavailable.
        let decoderSpec: NSDictionary
        if #available(tvOS 17.0, iOS 17.0, *) {
            decoderSpec = [
                kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
            ]
        } else {
            decoderSpec = [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
            ]
        }

        // 3. Destination pixel buffer attributes. We let VT pick a
        //    bit-depth-appropriate biplanar YCbCr format
        //    (10BiPlanar for HDR, 8BiPlanar for SDR) by setting
        //    BiPlanarType8/10 hints. IOSurface-backed + Metal-compat
        //    so the layer can render via the GPU path.
        let bitsPerSample = codecpar.pointee.bits_per_raw_sample
        let isHDRTransfer = codecpar.pointee.color_trc == AVCOL_TRC_SMPTE2084
            || codecpar.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67
        let use10Bit = bitsPerSample > 8 || isHDRTransfer
        let pixelFormat: OSType = use10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let pixelBufferAttrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        // 4. Output callback record. The C callback dispatches back
        //    into our `handleDecodedFrame` via the refCon pointer.
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

        // 5. Ask VT to pass through per-frame HDR metadata so the
        //    display layer can drive correct tone mapping. Pre-iOS 18
        //    / tvOS 18 this property is set unconditionally; on older
        //    OSes the unknown-key set returns -12911 which we swallow.
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
            category: .engine
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

        // Build a CMSampleBuffer from the AVPacket. The packet's data
        // is HEVC bitstream in length-prefix (MP4-style) framing as
        // delivered by FFmpeg's matroska demuxer. VT expects exactly
        // that, so we wrap the bytes in a CMBlockBuffer + CMSampleBuffer
        // without rewriting.
        //
        // We copy the bytes once: VT may retain the buffer past the
        // decode call (asynchronous decoders), and AVPacket's storage
        // gets reused for the next packet, so a shallow reference
        // would race.
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
            // CMBlockBuffer takes ownership only on success; on failure
            // we still own the allocation.
            copied.deallocate()
            return
        }

        // Build the sample buffer with a single sample timing entry
        // derived from the packet's PTS / DTS. CMTime needs a positive
        // timescale and a nominal duration; we fill these from the
        // stream's time_base and packet's duration when available.
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

        // Mark the keyframe attachment so VT can drop pre-key frames
        // after a flush (seek path).
        if (packet.pointee.flags & AV_PKT_FLAG_KEY) == 0 {
            // Non-key: tag as DependsOnOthers so the decoder knows
            // it can't be used as a sync sample.
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

        // Submit to VT. Flags request asynchronous decode (with
        // temporal queueing) so VT can pipeline across multiple
        // packets. The callback fires on VT's internal queue.
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
                category: .engine
            )
        }
    }

    func flush() {
        lock.lock()
        let session = self.session
        lock.unlock()
        guard let session else { return }
        // Wait for any in-flight async frames to drain, then signal
        // a discontinuity so VT drops its reference picture state.
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

    /// Invoked by `hwDecoderOutputCallback` once a frame has decoded.
    /// Delivers the CVPixelBuffer + PTS to the configured handler,
    /// honouring `skipUntilPTS` for seek-pre-roll trimming.
    fileprivate func handleDecodedFrame(
        imageBuffer: CVImageBuffer,
        pts: CMTime
    ) {
        // Seek-pre-roll trim: while skipUntilPTS is set, drop frames
        // whose PTS is earlier than the target. The renderer would
        // skip them anyway but dropping here saves an enqueue.
        if let threshold = skipUntilPTS, CMTimeCompare(pts, threshold) < 0 {
            return
        }
        if skipUntilPTS != nil, CMTimeCompare(pts, skipUntilPTS!) >= 0 {
            skipUntilPTS = nil
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
