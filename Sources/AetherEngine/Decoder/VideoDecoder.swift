import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil

/// Callback type for decoded video frames.
typealias DecodedFrameHandler = (CVPixelBuffer, CMTime) -> Void

/// VideoToolbox hardware decoder wrapper. Takes compressed AVPackets
/// from the Demuxer and produces decoded CVPixelBuffers via Apple's
/// hardware-accelerated VideoToolbox.
///
/// Supports H.264 and HEVC (including Main10 for HDR/DV). Falls back
/// to "unsupported" error for codecs VideoToolbox can't handle —
/// software fallback is a future addition.
final class VideoDecoder: @unchecked Sendable {

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var use10Bit = false
    /// When true, HDR10/DV content is tone-mapped to BT.709 SDR via a
    /// separate VTPixelTransferSession in the output handler. We do
    /// NOT use kVTDecompressionPropertyKey_PixelTransferProperties
    /// because that conflicts with controlTimebase-driven display
    /// (used in Atmos mode) — frames stop rendering. An explicit
    /// transfer session is independent of the decoder's timing path.
    private var tonemapToSDR = false

    /// Post-decode pixel transfer for HDR→SDR tonemapping. Allocated
    /// only when `tonemapToSDR` is true.
    private var pixelTransferSession: VTPixelTransferSession?
    /// Pool of 8-bit NV12 buffers used as the tonemap target.
    private var tonemapPool: CVPixelBufferPool?

    /// Thread-safe access to the frame callback. Written on the main thread
    /// (open/close), read on VideoToolbox's internal callback thread.
    private let onFrameLock = NSLock()
    private var _onFrame: DecodedFrameHandler?
    fileprivate var onFrame: DecodedFrameHandler? {
        get { onFrameLock.lock(); defer { onFrameLock.unlock() }; return _onFrame }
        set { onFrameLock.lock(); defer { onFrameLock.unlock() }; _onFrame = newValue }
    }

    /// The stream's time base as a rational number, used to convert
    /// PTS from FFmpeg's int64 to CMTime.
    private var timeBase: CMTime = CMTime(value: 1, timescale: 90000)

    /// Create a decoder for the given video stream.
    /// - Parameters:
    ///   - stream: The FFmpeg AVStream for the video track.
    ///   - tonemapToSDR: If true, convert HDR10/DV content to BT.709 SDR
    ///     during decode. Use when the display cannot switch to HDR
    ///     (Match Content disabled or SDR panel).
    ///   - onFrame: Called on a background thread with each decoded frame.
    func open(
        stream: UnsafeMutablePointer<AVStream>,
        tonemapToSDR: Bool = false,
        onFrame: @escaping DecodedFrameHandler
    ) throws {
        self.onFrame = onFrame
        self.tonemapToSDR = tonemapToSDR

        guard let codecpar = stream.pointee.codecpar else {
            throw VideoDecoderError.noCodecParameters
        }

        // Store time base for PTS conversion
        let tb = stream.pointee.time_base
        timeBase = CMTime(value: CMTimeValue(tb.num), timescale: CMTimeScale(tb.den))

        // Use 10-bit output for HDR/DV content so VideoToolbox preserves
        // HDR metadata and the display can switch to HDR mode via
        // AVDisplayCriteria. The host app must link AVKit and set
        // AVDisplayCriteria to trigger the TV's HDR mode switch.
        let bps = codecpar.pointee.bits_per_raw_sample
        let isMain10Profile = codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
            && codecpar.pointee.profile == 2  // FF_PROFILE_HEVC_MAIN_10
        let isHDRTransfer = codecpar.pointee.color_trc == AVCOL_TRC_SMPTE2084
            || codecpar.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67
        use10Bit = bps > 8 || isMain10Profile || isHDRTransfer

        #if DEBUG
        print("[VideoDecoder] Bit depth: bps=\(bps), profile=\(codecpar.pointee.profile), trc=\(codecpar.pointee.color_trc.rawValue) → \(use10Bit ? "10-bit P010" : "8-bit NV12")")
        #endif

        // Build CMVideoFormatDescription from FFmpeg's codec parameters
        let formatDesc = try createFormatDescription(from: codecpar)
        self.formatDescription = formatDesc

        // Create the VideoToolbox decompression session
        let session = try createDecompressionSession(formatDescription: formatDesc)
        self.decompressionSession = session

        // Tonemap infrastructure — only when going HDR→SDR.
        if use10Bit && tonemapToSDR {
            try setupTonemapPipeline(
                width: Int(codecpar.pointee.width),
                height: Int(codecpar.pointee.height)
            )
        }

        #if DEBUG
        let outputMode: String = {
            if use10Bit && tonemapToSDR { return "10-bit P010 → tonemap → 8-bit NV12 BT.709" }
            if use10Bit { return "10-bit P010 (HDR/DV)" }
            return "8-bit NV12"
        }()
        print("[VideoDecoder] Opened: \(codecpar.pointee.width)x\(codecpar.pointee.height), codec=\(codecpar.pointee.codec_id.rawValue), \(outputMode)")
        #endif
    }

    /// Send a compressed packet to the decoder. Decoded frames arrive
    /// asynchronously via the `onFrame` callback.
    func decode(packet: UnsafeMutablePointer<AVPacket>) {
        guard let session = decompressionSession,
              let formatDesc = formatDescription else { return }
        #if DEBUG
        decodeInputCount += 1
        if decodeInputCount == 1 {
            print("[VideoDecoder] first packet submitted")
        }
        #endif

        let packetData = packet.pointee.data
        let packetSize = Int(packet.pointee.size)
        guard let data = packetData, packetSize > 0 else { return }

        // Convert PTS from FFmpeg int64 to CMTime.
        // AV_NOPTS_VALUE is a C macro that Swift can't import, so we
        // define the sentinel value inline: 0x8000000000000000 (= Int64.min)
        let pts = packet.pointee.pts
        let avNoPTS: Int64 = -0x7FFFFFFFFFFFFFFF - 1  // == Int64.min == AV_NOPTS_VALUE
        let cmPTS: CMTime
        if pts != avNoPTS {
            cmPTS = CMTimeMake(
                value: pts * Int64(timeBase.value),
                timescale: timeBase.timescale
            )
        } else {
            cmPTS = .invalid
        }

        // Copy packet data into a CoreMedia-managed CMBlockBuffer.
        // We must copy because VTDecompressionSession decodes asynchronously
        // and the FFmpeg AVPacket may be freed before decoding completes.
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: packetSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: packetSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return }
        status = CMBlockBufferReplaceDataBytes(
            with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: packetSize
        )
        guard status == kCMBlockBufferNoErr else { return }

        // Build CMSampleBuffer with timing info
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: cmPTS,
            decodeTimeStamp: .invalid
        )
        var sampleSize = packetSize
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sample = sampleBuffer else { return }

        // Send to VideoToolbox for hardware decoding.
        // Using the OutputHandler variant for cleaner Swift integration
        // (no C function pointer needed).
        // Async decode with temporal processing — VT outputs frames in
        // display order (sorted by PTS). Required for AVSampleBufferDisplayLayer
        // which expects frames in presentation order.
        let decodeFlags: VTDecodeFrameFlags = [
            ._EnableAsynchronousDecompression,
            ._EnableTemporalProcessing,
        ]
        var infoFlags: VTDecodeInfoFlags = []
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: decodeFlags,
            infoFlagsOut: &infoFlags,
            outputHandler: { [weak self] status, infoFlags, imageBuffer, pts, duration in
                guard let self = self else { return }
                #if DEBUG
                if status != noErr, !self.loggedDecodeError {
                    self.loggedDecodeError = true
                    print("[VideoDecoder] decode output error: status=\(status) info=\(infoFlags)")
                }
                #endif
                guard status == noErr, let pixelBuffer = imageBuffer else { return }
                #if DEBUG
                self.decodeOutputCount += 1
                if self.decodeOutputCount == 1 {
                    print("[VideoDecoder] first frame decoded (PTS=\(String(format: "%.3f", CMTimeGetSeconds(pts))))")
                }
                #endif
                // VT strips color attachments when DV propagation is off
                // (always the case in HDR10 fallback). Re-tag the buffer
                // as BT.2020/PQ so the next stage knows what it's holding.
                if self.use10Bit {
                    self.attachHDRColorSpace(to: pixelBuffer)
                }
                if self.tonemapToSDR, self.use10Bit {
                    // VTPixelTransferSession needs correct source color
                    // attachments to know it must tone-map PQ→SDR. The
                    // call above made that explicit. Now do the transfer.
                    if let sdrBuffer = self.tonemapPixelBuffer(pixelBuffer) {
                        self.attachSDRColorSpace(to: sdrBuffer)
                        self.onFrame?(sdrBuffer, pts)
                    }
                } else {
                    self.onFrame?(pixelBuffer, pts)
                }
            }
        )
    }

    /// Flush the decoder — wait for all pending frames to be delivered.
    func flush() {
        guard let session = decompressionSession else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    /// Close the decoder and release resources.
    func close() {
        if let session = decompressionSession {
            // Wait for all in-flight frames before invalidating, otherwise
            // pending output callbacks may fire after onFrame is cleared.
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        if let transfer = pixelTransferSession {
            VTPixelTransferSessionInvalidate(transfer)
        }
        decompressionSession = nil
        pixelTransferSession = nil
        tonemapPool = nil
        formatDescription = nil
        onFrame = nil
    }

    deinit {
        close()
    }

    // MARK: - HDR Color Space

    /// Attach BT.2020/PQ color metadata to HDR pixel buffers.
    /// When PropagatePerFrameHDRDisplayMetadata is OFF, VT may strip
    /// color attachments — the display layer then defaults to BT.709
    /// which produces completely wrong colors for BT.2020/PQ content.
    private func attachHDRColorSpace(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    }

    /// Attach BT.709 SDR color metadata. Used after VideoToolbox has
    /// tone-mapped HDR10/DV content down to SDR via PixelTransferProperties
    /// — the display layer then interprets the bytes as Rec.709 SDR.
    private func attachSDRColorSpace(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    // MARK: - VideoToolbox Setup

    /// Create a CMVideoFormatDescription from FFmpeg's AVCodecParameters.
    /// This extracts the codec-specific "extradata" (avcC for H.264,
    /// hvcC for HEVC) and passes it as a sample description extension.
    private func createFormatDescription(
        from codecpar: UnsafePointer<AVCodecParameters>
    ) throws -> CMVideoFormatDescription {
        let width = codecpar.pointee.width
        let height = codecpar.pointee.height

        // Determine the CMVideoCodecType
        let codecType: CMVideoCodecType
        let atomKey: String
        switch codecpar.pointee.codec_id {
        case AV_CODEC_ID_H264:
            codecType = kCMVideoCodecType_H264
            atomKey = "avcC"
        case AV_CODEC_ID_HEVC:
            codecType = kCMVideoCodecType_HEVC
            atomKey = "hvcC"
        case AV_CODEC_ID_AV1:
            codecType = kCMVideoCodecType_AV1
            atomKey = "av1C"
        default:
            throw VideoDecoderError.unsupportedCodec(
                id: codecpar.pointee.codec_id.rawValue
            )
        }

        // Build CMVideoFormatDescription. For H.264/HEVC, FFmpeg stores
        // extradata in avcC/hvcC format (from mp4/mkv), which is exactly
        // what CMVideoFormatDescription expects. AV1 uses av1C.
        guard let extradata = codecpar.pointee.extradata,
              codecpar.pointee.extradata_size > 0 else {
            throw VideoDecoderError.noExtradata
        }

        let extradataBytes = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
        let atoms: NSDictionary = [atomKey: extradataBytes]
        let extensions: NSDictionary = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms
        ]

        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: width,
            height: height,
            extensions: extensions,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let desc = formatDesc else {
            throw VideoDecoderError.formatDescriptionFailed(status: status)
        }
        return desc
    }

    /// Create a VTDecompressionSession for hardware decoding.
    private func createDecompressionSession(
        formatDescription: CMVideoFormatDescription
    ) throws -> VTDecompressionSession {
        // Request YCbCr BiPlanar 4:2:0 — VideoToolbox's native output.
        // 10-bit (P010) for HEVC/AV1 Main10: preserves HDR10 and DV metadata.
        // 8-bit (NV12) for SDR content: smaller buffers, no HDR needed.
        // Tonemap (PQ→BT.709) happens in a separate VTPixelTransferSession
        // after decode so the decompression session never needs to know
        // about it — this avoids a conflict with controlTimebase-driven
        // display layers (Atmos mode) where PixelTransferProperties on
        // the decoder stopped frame output.
        let pixelFormat: OSType = use10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let pixelBufferAttrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ]

        // Using nil for outputCallback — we use the per-frame
        // OutputHandler in decode() instead of a session-level C callback.
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttrs,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let sess = session else {
            throw VideoDecoderError.sessionCreationFailed(status: status)
        }

        // DV per-frame metadata: only enable on DV-capable displays.
        // On HDR10-only TVs, DV RPU causes wrong colors — DV Profile 8
        // is backwards-compatible with HDR10, so disabling propagation
        // gives correct HDR10 output on non-DV displays.
        #if os(tvOS) || os(iOS)
        let displaySupportsDV = AVPlayer.availableHDRModes.contains(.dolbyVision)
        VTSessionSetProperty(sess, key: kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
                             value: displaySupportsDV ? kCFBooleanTrue : kCFBooleanFalse)
        #if DEBUG
        print("[VideoDecoder] DV metadata: \(displaySupportsDV ? "ON" : "OFF (HDR10 fallback)")")
        #endif
        #else
        VTSessionSetProperty(sess, key: kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata, value: kCFBooleanFalse)
        #endif

        return sess
    }

    // MARK: - Tonemap Pipeline (HDR → SDR)

    /// Allocate the VTPixelTransferSession and output pool used to
    /// convert PQ BT.2020 buffers to Rec.709 SDR. Called from open()
    /// only when `tonemapToSDR && use10Bit`.
    private func setupTonemapPipeline(width: Int, height: Int) throws {
        // 1. Pool of 8-bit NV12 output buffers.
        let outputAttrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ]
        let poolAttrs: NSDictionary = [
            kCVPixelBufferPoolMinimumBufferCountKey: 4,
        ]
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs,
            outputAttrs,
            &pool
        )
        guard poolStatus == kCVReturnSuccess, let p = pool else {
            throw VideoDecoderError.sessionCreationFailed(status: poolStatus)
        }
        self.tonemapPool = p

        // 2. Pixel transfer session — the actual HDR→SDR worker.
        var session: VTPixelTransferSession?
        let sessionStatus = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &session
        )
        guard sessionStatus == noErr, let s = session else {
            throw VideoDecoderError.sessionCreationFailed(status: sessionStatus)
        }
        VTSessionSetProperty(s,
            key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
            value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(s,
            key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
            value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(s,
            key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
            value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        self.pixelTransferSession = s

        #if DEBUG
        print("[VideoDecoder] HDR→SDR tonemap pipeline ready (\(width)x\(height))")
        #endif
    }

    /// Convert an HDR pixel buffer to SDR using the transfer session.
    /// Returns nil if anything in the path fails — caller should drop the frame.
    private func tonemapPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let session = pixelTransferSession,
              let pool = tonemapPool else {
            #if DEBUG
            if !tonemapLoggedMissing { tonemapLoggedMissing = true
                print("[VideoDecoder] tonemapPixelBuffer: missing session or pool")
            }
            #endif
            return nil
        }

        var output: CVPixelBuffer?
        let allocStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard allocStatus == kCVReturnSuccess, let dst = output else {
            #if DEBUG
            if !tonemapLoggedAlloc { tonemapLoggedAlloc = true
                print("[VideoDecoder] tonemap pool alloc failed: \(allocStatus)")
            }
            #endif
            return nil
        }

        let transferStatus = VTPixelTransferSessionTransferImage(session, from: source, to: dst)
        guard transferStatus == noErr else {
            #if DEBUG
            if !tonemapLoggedTransfer { tonemapLoggedTransfer = true
                print("[VideoDecoder] tonemap transfer failed: \(transferStatus)")
            }
            #endif
            return nil
        }
        #if DEBUG
        if !tonemapLoggedSuccess { tonemapLoggedSuccess = true
            print("[VideoDecoder] tonemap first frame transferred OK")
        }
        #endif
        return dst
    }

    #if DEBUG
    private var tonemapLoggedMissing = false
    private var tonemapLoggedAlloc = false
    private var tonemapLoggedTransfer = false
    private var tonemapLoggedSuccess = false
    fileprivate var decodeInputCount = 0
    fileprivate var decodeOutputCount = 0
    fileprivate var loggedDecodeError = false
    #endif
}

// MARK: - Errors

enum VideoDecoderError: Error, LocalizedError {
    case noCodecParameters
    case unsupportedCodec(id: UInt32)
    case noExtradata
    case formatDescriptionFailed(status: OSStatus)
    case sessionCreationFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noCodecParameters: "No codec parameters"
        case .unsupportedCodec(let id): "Unsupported video codec (id: \(id))"
        case .noExtradata: "Missing codec extradata"
        case .formatDescriptionFailed(let s): "Format description failed (\(s))"
        case .sessionCreationFailed(let s): "Decoder session failed (\(s))"
        }
    }
}
