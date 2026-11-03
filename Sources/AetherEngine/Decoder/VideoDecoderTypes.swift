import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
import AetherLibavformat
import AetherLibavcodec

/// Decoded frame callback. `hdr10PlusT35` carries HDR10+ dynamic metadata serialised to ITU-T T.35 bytes
/// (kCMSampleAttachmentKey_HDR10PlusPerFrameData format); nil for non-HDR10+ streams.
typealias DecodedFrameHandler = @Sendable (CVPixelBuffer, CMTime, Data?) -> Void

/// Common video decoder protocol. SoftwareVideoDecoder (libavcodec) and
/// HardwareVideoDecoder (VTDecompressionSession, HEVC/VP9) both conform; the host swaps per codec without rewiring the demux loop.
// Sendable: both conformers (SoftwareVideoDecoder, HardwareVideoDecoder) are @unchecked Sendable
// (internally lock-guarded), so `any VideoDecodingPipeline` is safe to capture in @Sendable closures.
protocol VideoDecodingPipeline: AnyObject, Sendable {
    var onFrame: DecodedFrameHandler? { get set }
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)? { get set }
    /// #131: fires per decoded frame carrying `AV_FRAME_DATA_A53_CC` side data, with the raw
    /// cc_data triplets and the frame PTS in seconds. Decoder output is presentation order.
    /// Only the software decoder produces it; VideoToolbox surfaces no A53 side data (H.264/HEVC
    /// never route through the SW host, so nothing is missed there).
    var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)? { get set }
    /// AE#658: the decoded format and its display buffer, reported on the first frame and on change.
    var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)? { get set }
    var skipUntilPTS: CMTime? { get set }
    /// Every frame the decoder has produced since it opened, the ones `skipUntilPTS` discards
    /// included. The preroll reads it as the decoder's progress toward a seek target (#800): a slow
    /// decoder still working up to the target is told apart from one that delivers nothing.
    var framesDecoded: UInt64 { get }

    /// AE#492: the decoder's current feed epoch. A caller that decides a batch of packets is
    /// current captures this, hands it back with each one, and the decoder refuses any packet whose
    /// epoch `flush()` has since retired. Read and compared under the same lock `flush()` takes, so
    /// a flush and a feed cannot interleave: the alternative is a caller re-reading a generation it
    /// cannot hold across the call it is about to make.
    var feedEpoch: UInt64 { get }

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws
    /// `epoch` is the value read from `feedEpoch` when this packet was decided to be current;
    /// `nil` from a caller with no seek of its own to be invalidated by.
    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64?)
    func flush()
    /// End of source or a live seam: delivers what the decoder still owes before the `flush()` the host
    /// makes next. `flush()` of a decoder that delivers what it drains is enough, so the default does
    /// nothing; a decoder whose `flush()` discards (the dual-layer one) overrides it. Seeks never call it.
    func drainForEndOfStream()
    func close()
}

extension VideoDecodingPipeline {
    func drainForEndOfStream() {}
    /// A decoder that does not count reports no progress, so its preroll times out as before.
    var framesDecoded: UInt64 { 0 }
}

enum VideoDecoderError: Error, LocalizedError {
    case noCodecParameters
    case unsupportedCodec(id: UInt32)
    case noExtradata
    case unsupportedConfiguration(codec: String, detail: String)
    case hardwareDecoderUnavailable(codec: String)
    case formatDescriptionFailed(status: OSStatus)
    case sessionCreationFailed(status: OSStatus)
    /// `DualLayerVideoDecoder` is single use (dolby-vision-fel.md §5.8): `open` after `close` refuses
    /// with this instead of inheriting the previous stream's state. Thrown rather than a
    /// trapping precondition so host misuse surfaces as an error and tests can assert it.
    case decoderClosed
    /// No Metal device or shader compilation failed; FEL composition cannot run.
    /// Thrown from `open()` for a decoder built without a composer. The software host does not get
    /// there in production: it builds the composer first and decodes the base layer alone when that
    /// fails.
    case composerUnavailable
    /// The GPU stopped completing Dolby Vision FEL compositions and did not recover: the stall bound
    /// (`DualLayerVideoDecoder.maxComposeStallBypassFrames` / `maxComposeStallEpisodes`) was reached.
    case composerStalled

    var errorDescription: String? {
        switch self {
        case .noCodecParameters: "No codec parameters"
        case .unsupportedCodec(let id): "Unsupported video codec (id: \(id))"
        case .noExtradata: "Missing codec extradata"
        case .unsupportedConfiguration(let codec, let detail):
            "Unsupported \(codec) configuration: \(detail)"
        case .hardwareDecoderUnavailable(let codec):
            "Hardware \(codec) decoder unavailable"
        case .formatDescriptionFailed(let s): "Format description failed (\(s))"
        case .sessionCreationFailed(let s): "Decoder session failed (\(s))"
        case .decoderClosed: "Decoder is closed (single use)"
        case .composerUnavailable: "Dolby Vision FEL composer unavailable (no Metal device or shader compilation failed)"
        case .composerStalled: "Dolby Vision FEL composition stalled: the GPU stopped completing frames and did not recover"
        }
    }
}

/// FFmpeg-to-CoreVideo color metadata mapping shared by SW and HW decoders (single source of truth for primaries/transfer/matrix).
enum ColorAttachments {
    static func primaries(_ v: AVColorPrimaries) -> CFString? {
        switch v {
        case AVCOL_PRI_BT709:    kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020:   kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE432: kCVImageBufferColorPrimaries_P3_D65
        case AVCOL_PRI_SMPTE431: kCVImageBufferColorPrimaries_DCI_P3
        case AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE240M: kCVImageBufferColorPrimaries_SMPTE_C
        case AVCOL_PRI_BT470BG:  kCVImageBufferColorPrimaries_EBU_3213
        default:                 nil
        }
    }

    static func transfer(_ v: AVColorTransferCharacteristic) -> CFString? {
        switch v {
        // BT.601 and the SDR BT.2020 codepoints name the BT.709 curve, CoreVideo has one constant for all.
        case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M, AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12:
            kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE2084:    kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case AVCOL_TRC_IEC61966_2_1: kCVImageBufferTransferFunction_sRGB
        case AVCOL_TRC_LINEAR:       kCVImageBufferTransferFunction_Linear
        case AVCOL_TRC_SMPTE240M:    kCVImageBufferTransferFunction_SMPTE_240M_1995
        default:                     nil
        }
    }

    static func matrix(_ v: AVColorSpace) -> CFString? {
        switch v {
        case AVCOL_SPC_BT709:                       kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: kCVImageBufferYCbCrMatrix_ITU_R_2020
        case AVCOL_SPC_SMPTE170M, AVCOL_SPC_BT470BG: kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_SMPTE240M:                   kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
        default:                                    nil
        }
    }

    struct Tags: Equatable {
        var primaries: CFString
        var transfer: CFString
        var matrix: CFString
    }

    /// AE#654: the tags a software-decoded buffer is presented with, gaps filled the way VideoToolbox
    /// fills them on the hardware path. A buffer without tags is not read as BT.709 by the display
    /// layer, the report has it going out in the panel's own gamut, so one untagged file looked two
    /// ways depending on which decoder the route picked. Measured
    /// on VideoToolbox's output (`ColorInfoGuessedBy`): nothing declared reads as BT.709 in all three,
    /// at 720x480 and 720x576 as much as at 1080p and for MPEG-2 as much as H.264, and a lone BT.601
    /// matrix gets SMPTE-C primaries and the BT.709 curve.
    static func presented(_ d: ColorDescription) -> Tags {
        let declaredPrimaries = primaries(d.primaries)
        let declaredMatrix = matrix(d.matrix)
        let bt709 = kCVImageBufferColorPrimaries_ITU_R_709_2
        let bt601Matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
        let bt2020Matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        let bt2020Primaries = kCVImageBufferColorPrimaries_ITU_R_2020
        let smpteC = kCVImageBufferColorPrimaries_SMPTE_C
        let ebu = kCVImageBufferColorPrimaries_EBU_3213

        let resolvedPrimaries: CFString = declaredPrimaries ?? {
            switch declaredMatrix {
            case bt601Matrix?:  smpteC
            case bt2020Matrix?: bt2020Primaries
            default:            bt709
            }
        }()
        let resolvedMatrix: CFString = declaredMatrix ?? {
            switch declaredPrimaries {
            case smpteC?, ebu?:     bt601Matrix
            case bt2020Primaries?:  bt2020Matrix
            default:                kCVImageBufferYCbCrMatrix_ITU_R_709_2
            }
        }()
        return Tags(
            primaries: resolvedPrimaries,
            transfer: transfer(d.transfer) ?? kCVImageBufferTransferFunction_ITU_R_709_2,
            matrix: resolvedMatrix)
    }

    /// The colour space CoreVideo manages a buffer with these tags in, i.e. the one playback shows the
    /// picture in. An RGB still converted from the same picture has to carry it: tagged sRGB instead,
    /// a BT.709 still drew 8 levels darker than VideoToolbox's own conversion of the frame, and an SDR
    /// BT.2020 one up to 57 levels off in red.
    static func colorSpace(for tags: Tags) -> CGColorSpace? {
        let attachments: NSDictionary = [
            kCVImageBufferColorPrimariesKey: tags.primaries,
            kCVImageBufferTransferFunctionKey: tags.transfer,
            kCVImageBufferYCbCrMatrixKey: tags.matrix,
        ]
        return CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue()
    }

    /// PQ (ST 2084) or HLG transfer means the stream is HDR.
    static func isHDRTransfer(_ trc: AVColorTransferCharacteristic) -> Bool {
        trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67
    }
}
