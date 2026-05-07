import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import AVFoundation
import Libavformat
import Libavcodec
import Libavutil

/// Callback type for decoded video frames.
///
/// `hdr10PlusT35` carries the source-frame's HDR10+ dynamic metadata,
/// already serialised to the ITU-T T.35 byte format Apple's
/// `kCMSampleAttachmentKey_HDR10PlusPerFrameData` expects. Nil for
/// non-HDR10+ streams or when the metadata was dropped (tonemap-to-SDR).
typealias DecodedFrameHandler = (CVPixelBuffer, CMTime, Data?) -> Void

/// VideoToolbox hardware decoder wrapper. Takes compressed AVPackets
/// from the Demuxer and produces decoded CVPixelBuffers via Apple's
/// hardware-accelerated VideoToolbox.
///
/// Supports H.264 and HEVC (including Main10 for HDR/DV). Falls back
/// to "unsupported" error for codecs VideoToolbox can't handle,
/// software fallback is a future addition.
final class VideoDecoder: @unchecked Sendable {

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var use10Bit = false
    /// True only for actual HDR content (PQ or HLG transfer). 10-bit
    /// SDR (Main 10 with BT.709 transfer, common in anime / cartoon
    /// encodes for banding control) is *not* HDR and must keep its
    /// BT.709 color attachments, otherwise the display interprets
    /// the BT.709 yuv values as BT.2020/PQ and the picture comes out
    /// massively oversaturated.
    private var isHDR = false
    /// When true, HDR10/DV content is tone-mapped to BT.709 SDR via a
    /// separate VTPixelTransferSession in the output handler. We do
    /// NOT use kVTDecompressionPropertyKey_PixelTransferProperties
    /// because that conflicts with controlTimebase-driven display
    /// (used in Atmos mode), frames stop rendering. An explicit
    /// transfer session is independent of the decoder's timing path.
    private var tonemapToSDR = false
    /// True when the input stream carries Dolby Vision RPU metadata
    /// and the format description has been tagged as `dvh1` with a
    /// `dvcC` extension. The TV-side DV mode switch only fires when
    /// the layer sees a DV-tagged format description, so this flag
    /// gates whether we even attempted that signalling.
    private var isDolbyVision = false

    /// Per-frame HDR10+ metadata, keyed by the packet PTS so the
    /// async VT output handler can pair the right T.35 SEI bytes
    /// to each decoded frame (B-frame reorder makes the simple "use
    /// the most recent value" approach unsafe). FFmpeg gives us the
    /// data on the input AVPacket; the matching CVPixelBuffer comes
    /// out of VT some frames later, so we stash on the way in and
    /// look up + remove on the way out.
    private let hdr10PlusLock = NSLock()
    nonisolated(unsafe) private var pendingHDR10Plus: [Int64: Data] = [:]
    /// One-shot flag set the first time HDR10+ side data lands on an
    /// input packet. Drives the public `onFirstHDR10PlusDetected`
    /// callback so the engine can flip its published videoFormat from
    /// `.hdr10` to `.hdr10Plus` reactively (mirroring how DV is
    /// detected at stream-open time, just with a per-frame source).
    private var seenHDR10Plus = false

    /// Fires once per session, on the demux thread, the first time
    /// HDR10+ dynamic metadata appears on an input packet. The host
    /// side uses this to update the published videoFormat for the
    /// HDR badge label.
    var onFirstHDR10PlusDetected: (() -> Void)?

    /// Post-decode pixel transfer for HDR→SDR tonemapping. Allocated
    /// only when `tonemapToSDR` is true.
    private var pixelTransferSession: VTPixelTransferSession?
    /// Pool of 8-bit NV12 buffers used as the tonemap target.
    private var tonemapPool: CVPixelBufferPool?

    /// Thread-safe access to the frame callback. Written on the main thread
    /// (open/close), read on VideoToolbox's internal callback thread.
    private let onFrameLock = NSLock()
    private var _onFrame: DecodedFrameHandler?
    private var onFrame: DecodedFrameHandler? {
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
        // HDR ≠ 10-bit. The bit-depth above only chooses the
        // VideoToolbox output pixel format (P010 vs NV12). The
        // color-attachment decision below uses *transfer function*,
        // which is the actual HDR signal.
        isHDR = isHDRTransfer

        #if DEBUG
        print("[VideoDecoder] Bit depth: bps=\(bps), profile=\(codecpar.pointee.profile), trc=\(codecpar.pointee.color_trc.rawValue) → \(use10Bit ? "10-bit P010" : "8-bit NV12") isHDR=\(isHDR)")
        #endif

        // Build CMVideoFormatDescription from FFmpeg's codec parameters
        let formatDesc = try createFormatDescription(from: codecpar)
        self.formatDescription = formatDesc

        // Create the VideoToolbox decompression session
        let session = try createDecompressionSession(formatDescription: formatDesc)
        self.decompressionSession = session

        // Tonemap infrastructure, only when going HDR→SDR. 10-bit
        // SDR doesn't need tonemapping; its values are already in
        // BT.709 space.
        if use10Bit && isHDR && tonemapToSDR {
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

        // HDR10+ extraction. FFmpeg's HEVC decoder is the only thing
        // that parses bitstream T.35 SEI into AVFrame side data, and
        // we bypass that decoder entirely on the VT hardware path.
        // So:
        //
        //   - First try `AV_PKT_DATA_DYNAMIC_HDR10_PLUS` on the
        //     packet (works for VP9 / AV1-in-container where the
        //     demuxer surfaces it pre-decode).
        //   - For HEVC fall through to a manual SEI walker that
        //     parses the packet bitstream, finds the T.35 SEI, and
        //     extracts the payload starting at country_code 0xB5
        //     (the format Apple's
        //     `kCMSampleAttachmentKey_HDR10PlusPerFrameData` expects).
        //
        // Stashed under packet PTS so the async VT output handler
        // can pair the bytes with the matching decoded frame on the
        // way back out (B-frame reorder makes "use the most recent"
        // unsafe).
        var hdrData = extractHDR10PlusBytes(from: packet)
        if hdrData == nil {
            hdrData = extractHDR10PlusBytesFromHEVCBitstream(
                data: data,
                size: packetSize
            )
        }
        if cmPTS.isValid, let hdrData {
            hdr10PlusLock.lock()
            pendingHDR10Plus[cmPTS.value] = hdrData
            let firstTime = !seenHDR10Plus
            if firstTime { seenHDR10Plus = true }
            hdr10PlusLock.unlock()
            if firstTime {
                EngineLog.emit("[VideoDecoder] HDR10+ dynamic metadata detected, \(hdrData.count) bytes T.35 SEI per frame")
                onFirstHDR10PlusDetected?()
            }
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
        // Async decode with temporal processing, VT outputs frames in
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
            outputHandler: { [weak self] status, infoFlags, imageBuffer, pts, _ in
                guard let self = self else { return }
                #if DEBUG
                if status != noErr, !self.loggedDecodeError {
                    self.loggedDecodeError = true
                    print("[VideoDecoder] decode output error: status=\(status) info=\(infoFlags)")
                }
                #endif
                guard status == noErr, let pixelBuffer = imageBuffer else { return }
                // VT strips color attachments when DV propagation is
                // off (the HDR10-fallback path) and on plain decode
                // paths sometimes leaves the buffer untagged. Re-tag
                // explicitly so the display layer knows how to
                // interpret the bytes:
                //
                //   - actually-HDR (PQ/HLG transfer)  → BT.2020 + PQ
                //   - 10-bit SDR (Main 10, BT.709)   → BT.709 SDR
                //
                // This is the difference that fixes oversaturated
                // 10-bit SDR encodes (e.g. anime/cartoon HEVC Main10
                // with BT.709), without the SDR tag the display
                // would assume BT.2020 because of the 10-bit format
                // and crush the colors.
                //
                // Dolby Vision streams are excluded because their
                // pixel-buffer colorspace is profile-specific:
                // Profile 8.1 base is BT.2020+PQ, Profile 5 base is
                // IPT-PQ-c2 (not BT.2020 at all), Profile 8.4 base is
                // BT.2020+HLG. VT picks the right output attachments
                // based on the dvcC atom in the format description;
                // overriding here with a hardcoded BT.2020+PQ tag
                // mislabels the bytes for P5 in particular and the
                // TV reads the lie and crushes colors into the
                // green/magenta cast DrHurt reported. For DV we
                // trust VT and leave the attachments alone.
                if self.use10Bit, !self.isDolbyVision {
                    if self.isHDR {
                        self.attachHDRColorSpace(to: pixelBuffer)
                    } else {
                        self.attachSDRColorSpace(to: pixelBuffer)
                    }
                }

                // Diagnostic dump on the first DV-decoded frame so we
                // can see what VT actually puts on the output buffer
                // for each profile. Build 113 (engine c1ef72e) showed
                // that skipping our BT.2020+PQ override didn't change
                // the TV's HDR-mode handshake, which means either VT
                // is setting the same tags itself or the downshift
                // signal is coming from somewhere else entirely. The
                // attachments and pixel format below should tell us
                // which.
                if self.isDolbyVision, !self.loggedFirstDVFrame {
                    self.loggedFirstDVFrame = true
                    let pf = CVPixelBufferGetPixelFormatType(pixelBuffer)
                    let pfStr = String(format: "%c%c%c%c",
                                       (pf >> 24) & 0xFF, (pf >> 16) & 0xFF,
                                       (pf >> 8) & 0xFF, pf & 0xFF)
                    let prim = CVBufferGetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil)?.takeUnretainedValue() as? String ?? "<nil>"
                    let trc = CVBufferGetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil)?.takeUnretainedValue() as? String ?? "<nil>"
                    let mat = CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue() as? String ?? "<nil>"
                    EngineLog.emit("[VideoDecoder] First DV frame: pixelFormat='\(pfStr)' (0x\(String(pf, radix: 16))) primaries=\(prim) trc=\(trc) matrix=\(mat)")
                }

                // Reclaim any HDR10+ payload the demux side stashed
                // for this frame's PTS. Tonemap-to-SDR drops the
                // metadata (it's irrelevant for an SDR output) so we
                // pull it off the map either way to avoid leaking.
                let hdr10PlusData: Data? = {
                    guard pts.isValid else { return nil }
                    self.hdr10PlusLock.lock()
                    defer { self.hdr10PlusLock.unlock() }
                    return self.pendingHDR10Plus.removeValue(forKey: pts.value)
                }()

                if self.tonemapToSDR, self.use10Bit, self.isHDR {
                    // VTPixelTransferSession needs correct source color
                    // attachments to know it must tone-map PQ→SDR. The
                    // call above made that explicit. Now do the transfer.
                    if let sdrBuffer = self.tonemapPixelBuffer(pixelBuffer) {
                        self.attachSDRColorSpace(to: sdrBuffer)
                        self.onFrame?(sdrBuffer, pts, nil)
                    }
                } else {
                    self.onFrame?(pixelBuffer, pts, hdr10PlusData)
                }
            }
        )
    }

    /// Pull HDR10+ dynamic metadata from `AV_PKT_DATA_DYNAMIC_HDR10_PLUS`
    /// packet side data and serialise it to the T.35 SEI byte format
    /// `kCMSampleAttachmentKey_HDR10PlusPerFrameData` expects (starts
    /// with `itu_t_t35_country_code = 0xb5`, little endian payload).
    /// Returns nil when the packet has no HDR10+ side data.
    private func extractHDR10PlusBytes(
        from packet: UnsafeMutablePointer<AVPacket>
    ) -> Data? {
        let count = Int(packet.pointee.side_data_elems)
        guard count > 0, let sideData = packet.pointee.side_data else {
            return nil
        }
        for i in 0..<count {
            let item = sideData.advanced(by: i).pointee
            guard item.type == AV_PKT_DATA_DYNAMIC_HDR10_PLUS else { continue }
            guard let raw = item.data, item.size > 0 else { continue }
            return raw.withMemoryRebound(
                to: AVDynamicHDRPlus.self,
                capacity: 1
            ) { recordPtr -> Data? in
                var dataPtr: UnsafeMutablePointer<UInt8>? = nil
                var size: Int = 0
                let result = av_dynamic_hdr_plus_to_t35(recordPtr, &dataPtr, &size)
                guard result >= 0, let buf = dataPtr, size > 0 else { return nil }
                let data = Data(bytes: buf, count: size)
                // FFmpeg owns the allocation, free via av_free() so the
                // matching allocator is used (plain free() happens to
                // work on Apple platforms today but the contract isn't
                // guaranteed across libavutil's allocator backends).
                av_free(buf)
                return data
            }
        }
        return nil
    }

    /// Flush the decoder, wait for all pending frames to be delivered.
    func flush() {
        guard let session = decompressionSession else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        // Drop any HDR10+ payloads whose frames were dropped instead
        // of delivered (e.g. seek-target skip). Seek/stop pre-flush
        // followed by a fresh demux walks new PTSes, so old entries
        // would leak forever. The seenHDR10Plus latch stays as-is
        // across seeks within the same session, the format hasn't
        // changed, so re-firing the callback would be noise.
        hdr10PlusLock.lock()
        pendingHDR10Plus.removeAll(keepingCapacity: true)
        hdr10PlusLock.unlock()
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
    /// color attachments, the display layer then defaults to BT.709
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
    ///, the display layer then interprets the bytes as Rec.709 SDR.
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
    /// hvcC for HEVC, av1C for AV1) and passes it as a sample-description
    /// extension. For HEVC streams that carry a Dolby Vision config in
    /// codec side data, the format description is tagged as `dvh1` and
    /// extended with a `dvcC` atom alongside `hvcC` so the display layer
    /// (and ultimately the TV) recognises the DV signalling.
    private func createFormatDescription(
        from codecpar: UnsafePointer<AVCodecParameters>
    ) throws -> CMVideoFormatDescription {
        let width = codecpar.pointee.width
        let height = codecpar.pointee.height

        // Determine the CMVideoCodecType + the matching base atom key.
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

        // FFmpeg stores extradata in the codec's native config-record
        // format (avcC / hvcC / av1C from mp4 / mkv), which is exactly
        // what CMVideoFormatDescription expects.
        guard let extradata = codecpar.pointee.extradata,
              codecpar.pointee.extradata_size > 0 else {
            throw VideoDecoderError.noExtradata
        }
        let extradataBytes = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))

        // Detect Dolby Vision via FFmpeg's `AV_PKT_DATA_DOVI_CONF` side
        // data on the codec parameters. When present and we're not
        // tone-mapping to SDR, we promote the codec type to
        // `kCMVideoCodecType_DolbyVisionHEVC` and pack a `dvcC` atom
        // alongside the existing `hvcC` so the layer sees a proper DV
        // format description.
        //
        // The previous `displaySupportsDolbyVision` gate (querying
        // `AVPlayer.availableHDRModes.contains(.dolbyVision)`) is
        // removed: the API is soft-deprecated on tvOS 26 and was
        // observed to lag the HDMI HDR-mode handshake, so it could
        // return false on a DV-capable TV that just hadn't switched
        // yet. DrHurt's first verification round confirmed P8 / P5 /
        // HDR10+ all fell back even though his display is genuinely
        // DV-capable. We now always emit `dvh1` + `dvcC` for DV
        // streams. On non-DV TVs Profile 8.1 / 8.4 still play via
        // their backward-compatible HDR10 / HLG base layer (the layer
        // is responsible for delivering the base; the dvcC atom is
        // additive metadata the TV only acts on when it can). Profile
        // 5 has no backward-compatible base, so on a non-DV TV it'll
        // still produce wrong colours, but that's the same as before
        // and we'll add a play-time refusal later if needed.
        let atoms: NSMutableDictionary = [atomKey: extradataBytes]
        let effectiveCodecType: CMVideoCodecType

        let detectedDVRecord: AVDOVIDecoderConfigurationRecord? = {
            guard codecpar.pointee.codec_id == AV_CODEC_ID_HEVC else { return nil }
            return doviConfigRecord(from: codecpar)
        }()

        // Diagnostic logging (always emitted via EngineLog so the
        // host can mirror it into an in-app overlay regardless of
        // build config).
        let gateRaw = Self.availableHDRModesRawValue
        let gateContainsDV = Self.displaySupportsDolbyVision
        EngineLog.emit("[VideoDecoder] AVPlayer.availableHDRModes raw=\(gateRaw) contains.dolbyVision=\(gateContainsDV)")

        if let r = detectedDVRecord {
            let action: String
            if tonemapToSDR {
                action = "skipped (tonemap-to-SDR active, falling back to plain HEVC)"
            } else {
                action = "tagging as 'dvh1' with dvcC (unconditional)"
            }
            EngineLog.emit(
                "[VideoDecoder] Dolby Vision detected: profile=\(r.dv_profile) level=\(r.dv_level) "
                + "rpu=\(r.rpu_present_flag) el=\(r.el_present_flag) bl=\(r.bl_present_flag) "
                + "compat=\(r.dv_bl_signal_compatibility_id) → \(action)"
            )
        } else if codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
            EngineLog.emit("[VideoDecoder] No Dolby Vision side data on HEVC stream")
        }

        if let dvRecord = detectedDVRecord, !tonemapToSDR {
            let dvcCData = buildDvcCAtom(from: dvRecord)
            let atomKey = dvConfigAtomKey(for: dvRecord)
            atoms[atomKey] = dvcCData
            effectiveCodecType = kCMVideoCodecType_DolbyVisionHEVC
            isDolbyVision = true
            let hex = dvcCData.map { String(format: "%02x", $0) }.joined(separator: " ")
            EngineLog.emit("[VideoDecoder] \(atomKey) bytes (24): \(hex) (md_compression=\(dvRecord.dv_md_compression))")
        } else {
            effectiveCodecType = codecType
        }

        let extensions: NSDictionary = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms
        ]

        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: effectiveCodecType,
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

    /// Whether the active video output advertises Dolby Vision in
    /// `AVPlayer.availableHDRModes`. Kept around for diagnostic
    /// logging only; the DV-tagging path no longer gates on it
    /// because the API is soft-deprecated on tvOS 26 and was
    /// observed to lag the HDMI HDR-mode handshake on real DV TVs.
    private static var displaySupportsDolbyVision: Bool {
        #if os(tvOS) || os(iOS)
        return AVPlayer.availableHDRModes.contains(.dolbyVision)
        #else
        return false
        #endif
    }

    /// Raw OptionSet value of `AVPlayer.availableHDRModes`. Lets
    /// debug logs differentiate "API returned 0 (no HDR at all)"
    /// from "API returned HDR10|HLG but not DV" without requiring
    /// the reader to know the bit layout (HLG=1, HDR10=2, DV=4).
    private static var availableHDRModesRawValue: Int {
        #if os(tvOS) || os(iOS)
        return AVPlayer.availableHDRModes.rawValue
        #else
        return 0
        #endif
    }

    /// Look up FFmpeg's `AV_PKT_DATA_DOVI_CONF` side data on the codec
    /// parameters and return the parsed record. Returns nil when the
    /// stream carries no Dolby Vision configuration.
    ///
    /// The 24-byte ISO BMFF `dvcC` box body is built from the record by
    /// `buildDvcCAtom(from:)`, separated so the diagnostics in
    /// `createFormatDescription` can inspect profile / level / flags
    /// without serialising the atom unnecessarily.
    private func doviConfigRecord(
        from codecpar: UnsafePointer<AVCodecParameters>
    ) -> AVDOVIDecoderConfigurationRecord? {
        let count = Int(codecpar.pointee.nb_coded_side_data)
        guard count > 0, let sideData = codecpar.pointee.coded_side_data else {
            return nil
        }
        for i in 0..<count {
            let item = sideData.advanced(by: i).pointee
            guard item.type == AV_PKT_DATA_DOVI_CONF else { continue }
            // The first 8 fields of AVDOVIDecoderConfigurationRecord
            // are the public DV config bytes. Newer FFmpeg builds add
            // `dv_md_compression` (9th byte), we don't use it for the
            // box body, so 8 bytes is enough to proceed safely.
            guard let raw = item.data, item.size >= 8 else { continue }
            return raw.withMemoryRebound(
                to: AVDOVIDecoderConfigurationRecord.self,
                capacity: 1
            ) { $0.pointee }
        }
        return nil
    }

    /// Build the 24-byte DV configuration atom payload from FFmpeg's
    /// DV record. The atom box type (`dvcC` vs `dvvC` vs `dvwC`) is
    /// selected by `dvConfigAtomKey(for:)` strictly from `dv_profile`
    /// per the Dolby spec and every reference muxer (FFmpeg movenc,
    /// GPAC MP4Box, mkvtoolnix). The 24-byte payload is identical in
    /// all three boxes; only the FourCC differs.
    ///
    /// Layout (DOVIDecoderConfigurationRecord, ISO BMFF Dolby Vision
    /// Streams spec v2.x and the v4.0 extension that added the
    /// `dv_md_compression` 2-bit field at the same byte position):
    ///
    /// ```
    ///   Byte 0    : dv_version_major
    ///   Byte 1    : dv_version_minor
    ///   Byte 2    : dv_profile (7) << 1 | dv_level high bit (1)
    ///   Byte 3    : dv_level low 5 bits << 3 | rpu << 2 | el << 1 | bl
    ///   Byte 4    : dv_bl_signal_compatibility_id (4) << 4
    ///                | dv_md_compression (2) << 2
    ///                | reserved (2) at the bottom
    ///   Bytes 5..7  : reserved zero
    ///   Bytes 8..23 : reserved zero
    /// ```
    ///
    /// Note on byte 4: `dv_md_compression` is a 2-bit field at bits
    /// [3..2]. FFmpeg's parser reads it as `(byte >> 2) & 0x03` and
    /// the canonical encoder packs it the same way. The values are
    /// 0 (none), 1 (limited), 2 (reserved), 3 (extended). The
    /// previous version of this code packed it into bits [3..0],
    /// which silently misreported the compression mode whenever the
    /// stream actually used compressed RPU metadata.
    private func buildDvcCAtom(
        from record: AVDOVIDecoderConfigurationRecord
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[0] = record.dv_version_major
        bytes[1] = record.dv_version_minor
        let profile        = record.dv_profile & 0x7F
        let level          = record.dv_level   & 0x3F
        let rpu            = record.rpu_present_flag & 0x01
        let el             = record.el_present_flag  & 0x01
        let bl             = record.bl_present_flag  & 0x01
        let compat         = record.dv_bl_signal_compatibility_id & 0x0F
        let mdCompression  = record.dv_md_compression & 0x03
        // Byte 2: dv_profile (7) << 1 | high bit of dv_level (1)
        bytes[2] = (profile << 1) | ((level >> 5) & 0x01)
        // Byte 3: low 5 bits of dv_level | rpu | el | bl
        bytes[3] = ((level & 0x1F) << 3) | (rpu << 2) | (el << 1) | bl
        // Byte 4: compat_id (bits 7..4) | md_compression (bits 3..2)
        //                                | reserved (bits 1..0)
        bytes[4] = (compat << 4) | (mdCompression << 2)
        // Bytes 5–23 reserved zero (already initialised).
        return Data(bytes)
    }

    /// Pick the right ISO BMFF atom box type for a DV configuration
    /// record. Strictly profile-based per Dolby's "Dolby Vision
    /// Streams Within the ISO Base Media File Format" spec and every
    /// open-source reference muxer (FFmpeg `mov_write_dvcc_dvvc_tag`,
    /// GPAC `dvcC_box_write`, mkvtoolnix BlockAdditionMapping):
    ///
    ///   - `dv_profile` 0..7  (incl. P5, P7) → `dvcC` (original)
    ///   - `dv_profile` 8..10 (P8, P9, P10/AV1) → `dvvC`
    ///   - `dv_profile`  > 10 (P11+/VVC)  → `dvwC`
    ///
    /// The earlier `dv_md_compression != 0 → dvvC` heuristic was
    /// wrong: md_compression is orthogonal to the box type and varies
    /// independently within a profile. Apple's VT, every shipping
    /// player, and every Hollywood DV master follow the profile rule.
    private func dvConfigAtomKey(
        for record: AVDOVIDecoderConfigurationRecord
    ) -> String {
        let profile = Int(record.dv_profile)
        switch profile {
        case ...7:    return "dvcC"
        case 8...10:  return "dvvC"
        default:      return "dvwC"
        }
    }

    /// Create a VTDecompressionSession for hardware decoding.
    private func createDecompressionSession(
        formatDescription: CMVideoFormatDescription
    ) throws -> VTDecompressionSession {
        // Request YCbCr BiPlanar 4:2:0, VideoToolbox's native output.
        // 10-bit (P010) for HEVC/AV1 Main10: preserves HDR10 and DV metadata.
        // 8-bit (NV12) for SDR content: smaller buffers, no HDR needed.
        // Tonemap (PQ→BT.709) happens in a separate VTPixelTransferSession
        // after decode so the decompression session never needs to know
        // about it, this avoids a conflict with controlTimebase-driven
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

        // Using nil for outputCallback, we use the per-frame
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
            EngineLog.emit("[VideoDecoder] VTDecompressionSessionCreate FAILED status=\(status) (codecType=0x\(String(CMFormatDescriptionGetMediaSubType(formatDescription), radix: 16)) pixelFormat=0x\(String(pixelFormat, radix: 16)))")
            throw VideoDecoderError.sessionCreationFailed(status: status)
        }
        EngineLog.emit("[VideoDecoder] VTDecompressionSessionCreate ok (codecType=0x\(String(CMFormatDescriptionGetMediaSubType(formatDescription), radix: 16)) requested=0x\(String(pixelFormat, radix: 16)))")

        // Leave `kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata`
        // at its default (true). The previous code gated it on
        // `AVPlayer.availableHDRModes.contains(.dolbyVision)`, the
        // same soft-deprecated tvOS-26 API we just removed from the
        // format-description tagging path. When that gate returned
        // false on a DV-capable TV (the API is observed to lag the
        // HDMI HDR-mode handshake), VT was being told to STRIP the
        // DV RPU per-frame metadata even though our format
        // description was tagged as `dvh1`, so the TV got a
        // DV-shaped sample stream with no actual DV data and
        // refused to switch into DV mode. Apple's own HDR-with-
        // Dolby-Vision PDF says to leave this property at the
        // default. Ours is now the default.
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

        // 2. Pixel transfer session, the actual HDR→SDR worker.
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
    /// Returns nil if anything in the path fails, caller should drop the frame.
    private func tonemapPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let session = pixelTransferSession,
              let pool = tonemapPool else { return nil }

        var output: CVPixelBuffer?
        let allocStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard allocStatus == kCVReturnSuccess, let dst = output else { return nil }

        let transferStatus = VTPixelTransferSessionTransferImage(session, from: source, to: dst)
        guard transferStatus == noErr else { return nil }
        return dst
    }

    #if DEBUG
    fileprivate var loggedDecodeError = false
    #endif
    private var loggedHEVCSEIWalker = false
    private var loggedFirstDVFrame = false

    // MARK: - HEVC SEI Walker (HDR10+ extraction on the HW path)

    /// Walk an HEVC packet's NAL units, find any user-data-registered
    /// ITU-T T.35 SEI carrying HDR10+ dynamic metadata, and return
    /// the T.35 payload starting from the country_code byte (0xB5)
    /// in the format Apple's `kCMSampleAttachmentKey_HDR10PlusPerFrameData`
    /// expects.
    ///
    /// Required because FFmpeg only exposes HDR10+ as `AVFrame` side
    /// data after its own HEVC decoder runs, and we bypass that
    /// decoder entirely on the VT hardware path. So the SEI message
    /// lives in the packet bitstream and would otherwise be lost
    /// before VT swallows it.
    ///
    /// Assumes mp4 / mkv style length-prefixed NAL framing with a
    /// 4-byte big-endian length, which is the universal default for
    /// HEVC in those containers.
    private func extractHDR10PlusBytesFromHEVCBitstream(
        data: UnsafeMutablePointer<UInt8>,
        size: Int
    ) -> Data? {
        let lengthSize = 4
        var offset = 0
        while offset + lengthSize < size {
            // 4-byte big-endian NAL length
            var nalLength = 0
            for i in 0..<lengthSize {
                nalLength = (nalLength << 8) | Int(data[offset + i])
            }
            offset += lengthSize
            guard nalLength > 2, offset + nalLength <= size else { break }

            // HEVC NAL header byte 0: forbidden_zero (1) +
            // nal_unit_type (6) + nuh_layer_id high bit (1).
            // NUT 39 = PREFIX_SEI_NUT, 40 = SUFFIX_SEI_NUT.
            let nalUnitType = (data[offset] >> 1) & 0x3F
            if nalUnitType == 39 || nalUnitType == 40 {
                // Skip the 2-byte NAL header to the SEI payload.
                let seiStart = offset + 2
                let seiSize = nalLength - 2
                if let t35 = parseHEVCSEIPayloadForT35(
                    bytes: data + seiStart,
                    size: seiSize
                ) {
                    if !loggedHEVCSEIWalker {
                        loggedHEVCSEIWalker = true
                        EngineLog.emit("[VideoDecoder] HEVC bitstream SEI walker found HDR10+ T.35 payload (\(t35.count) bytes)")
                    }
                    return t35
                }
            }
            offset += nalLength
        }
        return nil
    }

    /// Parse one HEVC SEI NAL's payload, returning the T.35 bytes
    /// for the first SEI message that matches the HDR10+ signature
    /// (country_code 0xB5, terminal_provider 0x003C, oriented_code
    /// 0x0001, application_identifier 4 = SMPTE 2094-40).
    ///
    /// Handles emulation-prevention-byte unescape (HEVC's RBSP rule
    /// strips 0x03 from any 0x00 0x00 0x03 sequence) and the
    /// variable-length payload_type / payload_size encoding (sum of
    /// preceding 0xFF bytes plus the final non-FF byte).
    private func parseHEVCSEIPayloadForT35(
        bytes: UnsafePointer<UInt8>,
        size: Int
    ) -> Data? {
        // Unescape RBSP first so payload_size is byte-accurate.
        var rbsp: [UInt8] = []
        rbsp.reserveCapacity(size)
        var i = 0
        while i < size {
            if i + 2 < size, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0x03 {
                rbsp.append(0)
                rbsp.append(0)
                i += 3
            } else {
                rbsp.append(bytes[i])
                i += 1
            }
        }

        var off = 0
        while off < rbsp.count {
            // payload_type: sum of preceding 0xFF bytes + final byte
            var payloadType = 0
            while off < rbsp.count, rbsp[off] == 0xFF {
                payloadType += 255
                off += 1
            }
            guard off < rbsp.count else { break }
            payloadType += Int(rbsp[off])
            off += 1

            // payload_size: same encoding
            var payloadSize = 0
            while off < rbsp.count, rbsp[off] == 0xFF {
                payloadSize += 255
                off += 1
            }
            guard off < rbsp.count else { break }
            payloadSize += Int(rbsp[off])
            off += 1

            guard off + payloadSize <= rbsp.count else { break }

            // HEVC payload_type 4 = user_data_registered_itu_t_t35
            // (ISO/IEC 23008-2 Annex D, Table D.2.1). The earlier
            // version of this walker checked == 5, which is
            // user_data_unregistered, so it never matched on real
            // HDR10+ streams and the HW path always returned nil.
            if payloadType == 4, payloadSize >= 6,
               rbsp[off] == 0xB5,                                 // USA
               rbsp[off + 1] == 0x00, rbsp[off + 2] == 0x3C,      // Samsung
               rbsp[off + 3] == 0x00, rbsp[off + 4] == 0x01,      // SMPTE 2094-40
               rbsp[off + 5] == 0x04                              // application_identifier 4
            {
                return Data(rbsp[off..<(off + payloadSize)])
            }

            off += payloadSize
        }
        return nil
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
