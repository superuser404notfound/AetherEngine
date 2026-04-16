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
    ///   - onFrame: Called on a background thread with each decoded frame.
    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        self.onFrame = onFrame

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

        #if DEBUG
        print("[VideoDecoder] Opened: \(codecpar.pointee.width)x\(codecpar.pointee.height), codec=\(codecpar.pointee.codec_id.rawValue), \(use10Bit ? "10-bit P010 (HDR/DV)" : "8-bit NV12")")
        #endif
    }

    /// Send a compressed packet to the decoder. Decoded frames arrive
    /// asynchronously via the `onFrame` callback.
    func decode(packet: UnsafeMutablePointer<AVPacket>) {
        guard let session = decompressionSession,
              let formatDesc = formatDescription else { return }

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
                guard status == noErr,
                      let pixelBuffer = imageBuffer,
                      let self = self else { return }
                // When DV metadata propagation is OFF, VT outputs pixel data
                // in BT.2020/PQ but may strip color attachments from the buffer.
                // Without attachments, the display layer defaults to BT.709
                // interpretation → completely wrong colors. Fix: manually tag
                // HDR pixel buffers with the correct color space.
                if self.use10Bit {
                    self.attachHDRColorSpace(to: pixelBuffer)
                }
                self.onFrame?(pixelBuffer, pts)
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
        decompressionSession = nil
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
        // 10-bit (P010) for HEVC/AV1: preserves HDR10 and Dolby Vision metadata.
        // 8-bit (NV12) for H.264: no HDR support, saves memory.
        // PropagatePerFrameHDRDisplayMetadata is true by default in VT,
        // so DV/HDR10 metadata flows automatically on 10-bit pixel buffers.
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
