import Foundation
import CoreVideo
import AetherLibavutil
import AetherLibavcodec

/// AE#658: a video picture's format in FFmpeg's vocabulary, for a host's stats panel.
///
/// The raw fields are libav names (`yuv420p10le`, `bt2020`, `smpte2084`, `bt2020nc`, `tv`), nil where
/// the stream leaves a value unspecified. A gap stays a gap: an untagged source is not reported as
/// BT.709 here, even though that is what the display layer is handed for it (AE#654). The `…Label`
/// properties turn them into the names a viewer reads.
public struct VideoStreamFormat: Sendable, Equatable {
    public let pixelFormat: String?
    /// Bits per luma sample, from the pixel format's descriptor (or the stream's declared sample depth
    /// when the pixel format is unknown).
    public let bitDepth: Int?
    public let colorPrimaries: String?
    public let transfer: String?
    public let matrix: String?
    public let range: String?
    /// Codec profile as libavcodec names it ("Main 10", "High", "Main"), nil when undeclared.
    public let profile: String?

    public init(pixelFormat: String?, bitDepth: Int?, colorPrimaries: String?, transfer: String?,
                matrix: String?, range: String?, profile: String?) {
        self.pixelFormat = pixelFormat
        self.bitDepth = bitDepth
        self.colorPrimaries = colorPrimaries
        self.transfer = transfer
        self.matrix = matrix
        self.range = range
        self.profile = profile
    }

    init(pixelFormat: AVPixelFormat,
         declaredBitDepth: Int32,
         color: ColorDescription,
         codecID: AVCodecID,
         profile: Int32) {
        let pixName = pixelFormat == AV_PIX_FMT_NONE ? nil : av_get_pix_fmt_name(pixelFormat).map { String(cString: $0) }
        var depth: Int? = nil
        if pixelFormat != AV_PIX_FMT_NONE, let desc = av_pix_fmt_desc_get(pixelFormat), desc.pointee.nb_components > 0 {
            depth = Int(desc.pointee.comp.0.depth)
        } else if declaredBitDepth > 0 {
            depth = Int(declaredBitDepth)
        }
        self.init(
            pixelFormat: pixName,
            bitDepth: depth,
            colorPrimaries: color.primaries == AVCOL_PRI_UNSPECIFIED
                ? nil : av_color_primaries_name(color.primaries).map { String(cString: $0) },
            transfer: color.transfer == AVCOL_TRC_UNSPECIFIED
                ? nil : av_color_transfer_name(color.transfer).map { String(cString: $0) },
            matrix: color.matrix == AVCOL_SPC_UNSPECIFIED
                ? nil : av_color_space_name(color.matrix).map { String(cString: $0) },
            range: color.range == AVCOL_RANGE_UNSPECIFIED
                ? nil : av_color_range_name(color.range).map { String(cString: $0) },
            profile: Self.profileName(codecID: codecID, profile: profile))
    }

    /// What the container and the probe's decoder declared for the stream.
    init(codecpar: UnsafePointer<AVCodecParameters>) {
        self.init(
            pixelFormat: AVPixelFormat(rawValue: codecpar.pointee.format),
            declaredBitDepth: codecpar.pointee.bits_per_raw_sample,
            color: ColorDescription(codecpar: codecpar),
            codecID: codecpar.pointee.codec_id,
            profile: codecpar.pointee.profile)
    }

    static func profileName(codecID: AVCodecID, profile: Int32) -> String? {
        guard profile != AV_PROFILE_UNKNOWN else { return nil }
        return avcodec_profile_name(codecID, profile).map { String(cString: $0) }
    }

    public var colorPrimariesLabel: String? { colorPrimaries.map(Self.primariesLabel) }
    public var transferLabel: String? { transfer.map(Self.transferLabel) }
    public var matrixLabel: String? { matrix.map(Self.matrixLabel) }
    public var rangeLabel: String? { range.map(Self.rangeLabel) }

    static func primariesLabel(_ name: String) -> String {
        switch name {
        case "bt709": return "BT.709"
        case "bt2020": return "BT.2020"
        case "smpte432": return "Display P3"
        case "smpte431": return "DCI-P3"
        case "bt470bg": return "BT.601 PAL"
        case "smpte170m": return "BT.601 NTSC"
        case "bt470m": return "BT.470 M"
        case "smpte240m": return "SMPTE 240M"
        default: return name
        }
    }

    static func transferLabel(_ name: String) -> String {
        switch name {
        case "bt709": return "BT.709 (SDR)"
        case "smpte2084": return "PQ (SMPTE ST 2084)"
        case "arib-std-b67": return "HLG"
        case "smpte170m", "bt601": return "BT.601 (SDR)"
        case "bt2020-10", "bt2020-12": return "BT.2020 (SDR)"
        case "iec61966-2-1": return "sRGB"
        case "linear": return "Linear"
        default: return name
        }
    }

    static func matrixLabel(_ name: String) -> String {
        switch name {
        case "bt709": return "BT.709"
        case "bt2020nc": return "BT.2020 NCL"
        case "bt2020c": return "BT.2020 CL"
        case "bt470bg", "smpte170m": return "BT.601"
        case "ictcp": return "ICtCp"
        case "gbr": return "RGB"
        default: return name
        }
    }

    static func rangeLabel(_ name: String) -> String {
        switch name {
        case "tv": return "Limited"
        case "pc": return "Full"
        default: return name
        }
    }
}

/// AE#658: what the engine's own software decoder produced, as it produced it. Published only on the
/// software path, because on the native path AVPlayer decodes and the frames never pass through the engine.
public struct DecodedVideoFormat: Sendable, Equatable {
    /// The decoded frame: libavcodec's output pixel format and the colour description after the
    /// container filled the fields the bitstream left open.
    public let frame: VideoStreamFormat
    /// The CoreVideo buffer the frame was converted into for display, as its four-character code
    /// (`420v` = NV12, `x420` = P010).
    public let pixelBufferFormat: String
    /// AE#983: the deinterlace graph the frame passed through, nil when frames go out as decoded.
    /// The graph engages on the first frame flagged interlaced and stays in the path until a seek
    /// (`deint=interlaced` passes progressive frames through it untouched).
    public let deinterlace: VideoDeinterlace?

    public init(frame: VideoStreamFormat, pixelBufferFormat: String, deinterlace: VideoDeinterlace? = nil) {
        self.frame = frame
        self.pixelBufferFormat = pixelBufferFormat
        self.deinterlace = deinterlace
    }

    /// The display buffer in the names a viewer reads, "P010 (x420)".
    public var pixelBufferLabel: String {
        switch pixelBufferFormat {
        case "420v": return "NV12 (420v)"
        case "420f": return "NV12 full range (420f)"
        case "x420": return "P010 (x420)"
        case "xf20": return "P010 full range (xf20)"
        default: return pixelBufferFormat
        }
    }

    static func libavPixelFormat(forPixelBufferType type: OSType) -> AVPixelFormat {
        switch type {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return AV_PIX_FMT_NV12
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: return AV_PIX_FMT_P010LE
        default: return AV_PIX_FMT_NONE
        }
    }

    static func fourCC(_ type: OSType) -> String {
        let bytes = [UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF),
                     UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return "0x" + String(type, radix: 16)
    }
}
