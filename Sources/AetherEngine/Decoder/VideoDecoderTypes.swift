import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
import AetherLibavformat
import AetherLibavcodec

/// Decoded frame callback. `hdr10PlusT35` carries HDR10+ dynamic metadata serialised to ITU-T T.35 bytes
/// (kCMSampleAttachmentKey_HDR10PlusPerFrameData format); nil for non-HDR10+ streams.
typealias DecodedFrameHandler = @Sendable (CVPixelBuffer, CMTime, Data?) -> Void

/// Common video decoder protocol. SoftwareVideoDecoder (libavcodec, AV1/VP9) and
/// HardwareVideoDecoder (VTDecompressionSession, HEVC) both conform; the host swaps per codec without rewiring the demux loop.
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
    func close()
}

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
        let filled = filled(d)
        return Tags(
            primaries: primaries(filled.primaries) ?? kCVImageBufferColorPrimaries_ITU_R_709_2,
            transfer: shownTransfer(transfer(d.transfer)),
            matrix: matrix(filled.matrix) ?? kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    }

    /// `presented`'s gap filling in FFmpeg's values, for the fMP4 `colr` box the loopback path writes.
    /// A value CoreVideo has no name for counts as a gap, the same as unspecified.
    static func filled(_ d: ColorDescription) -> ColorDescription {
        let declaredPrimaries = primaries(d.primaries) != nil ? d.primaries : nil
        let declaredMatrix = matrix(d.matrix) != nil ? d.matrix : nil
        let resolvedPrimaries: AVColorPrimaries = declaredPrimaries ?? {
            switch declaredMatrix {
            case AVCOL_SPC_SMPTE170M?, AVCOL_SPC_BT470BG?:    AVCOL_PRI_SMPTE170M
            case AVCOL_SPC_BT2020_NCL?, AVCOL_SPC_BT2020_CL?: AVCOL_PRI_BT2020
            default:                                          AVCOL_PRI_BT709
            }
        }()
        let resolvedMatrix: AVColorSpace = declaredMatrix ?? {
            switch declaredPrimaries {
            case AVCOL_PRI_SMPTE170M?, AVCOL_PRI_SMPTE240M?, AVCOL_PRI_BT470BG?: AVCOL_SPC_SMPTE170M
            case AVCOL_PRI_BT2020?:                                              AVCOL_SPC_BT2020_NCL
            default:                                                             AVCOL_SPC_BT709
            }
        }()
        return ColorDescription(primaries: resolvedPrimaries, transfer: d.transfer,
                                matrix: resolvedMatrix, range: d.range)
    }

    /// [MovieClaw P60] SDR goes to the screen as sRGB on Mac and iPhone: code values shown as they are,
    /// the way Infuse, VLC and mpv without ICC show them. Tagged BT.709 (or untagged, which CoreVideo reads
    /// as BT.709) the system applies its scene-referred Rec.709 conversion, ~1.961 gamma: measured on
    /// 我不是大师 S01E17 against the decoded frame, midtones +8~10 code values brighter than Infuse.
    /// Not tvOS: there the picture goes out as a Rec.709 signal and the TV owns the curve, so a BT.709
    /// tag is already pass-through and an sRGB one would be converted into it.
    #if os(macOS) || os(iOS)
    static let presentsSDRAsSRGB = true
    #else
    static let presentsSDRAsSRGB = false
    #endif

    /// The transfer tag a buffer goes to the display layer with (P60): whatever would be shown with the
    /// BT.709 curve, a missing tag included (CoreVideo reads that as BT.709), goes as sRGB instead.
    static func shownTransfer(_ tag: CFString?) -> CFString {
        let bt709 = kCVImageBufferTransferFunction_ITU_R_709_2
        guard presentsSDRAsSRGB else { return tag ?? bt709 }
        if let tag, tag != bt709 { return tag }
        return kCVImageBufferTransferFunction_sRGB
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
