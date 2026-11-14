import Foundation
import CoreMedia
import CoreVideo
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Builds the codec-specific Core Media description consumed by `HardwareVideoDecoder`.
///
/// HEVC and AV1 take their record from the extradata. VP9 in WebM has no codec initialization
/// payload. VideoToolbox nevertheless requires an ISO `vpcC` configuration record, so it is
/// synthesized from FFmpeg's probed stream parameters rather than treating the expected lack of
/// `AVCodecParameters.extradata` as an error.
enum VideoToolboxVideoFormat {
    struct Configuration {
        let codecName: String
        let codecType: CMVideoCodecType
        let extensions: NSDictionary
        let bitDepth: Int
    }

    struct VP9Configuration: Equatable {
        let profile: UInt8
        let level: UInt8
        let bitDepth: UInt8
        let chromaSubsampling: UInt8
        let fullRange: Bool
        let colorPrimaries: UInt8
        let transferCharacteristics: UInt8
        let matrixCoefficients: UInt8

        /// VP Codec ISO Media File Format Binding `vpcC` atom payload: FullBox version/flags followed by the
        /// eight-byte VPCodecConfigurationRecord. Core Media's sample-description atom dictionary
        /// consumes this complete box payload, as emitted by FFmpeg's `ff_isom_write_vpcc`.
        var configurationBoxPayload: Data {
            Data([
                1, 0, 0, 0, // FullBox version 1 + flags
                profile,
                level,
                (bitDepth << 4) | (chromaSubsampling << 1) | (fullRange ? 1 : 0),
                colorPrimaries,
                transferCharacteristics,
                matrixCoefficients,
                0, 0 // codecInitializationDataSize; VP9 has no initialization data
            ])
        }
    }

    static func make(stream: UnsafeMutablePointer<AVStream>) throws -> Configuration {
        guard let codecpar = stream.pointee.codecpar else {
            throw VideoDecoderError.noCodecParameters
        }
        let pixelAspectRatio = pixelAspectRatio(codecpar: codecpar, stream: stream)

        switch codecpar.pointee.codec_id {
        case AV_CODEC_ID_HEVC:
            guard let extradata = codecpar.pointee.extradata,
                  codecpar.pointee.extradata_size > 0 else {
                throw VideoDecoderError.noExtradata
            }
            let data = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            let atoms: NSDictionary = ["hvcC": data]
            let extensions = NSMutableDictionary(dictionary: [
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms
            ])
            addColor(codecpar: codecpar, to: extensions)
            let bitDepth = codecpar.pointee.bits_per_raw_sample > 8
                || ColorAttachments.isHDRTransfer(codecpar.pointee.color_trc) ? 10 : 8
            return Configuration(
                codecName: "HEVC",
                codecType: kCMVideoCodecType_HEVC,
                extensions: extensions,
                bitDepth: bitDepth
            )

        case AV_CODEC_ID_AV1:
            // Matroska's AV1 CodecPrivate is the av1C record, and its blocks are the low-overhead OBU
            // temporal units VideoToolbox takes as samples.
            guard let extradata = codecpar.pointee.extradata,
                  codecpar.pointee.extradata_size > 0 else {
                throw VideoDecoderError.noExtradata
            }
            let data = Data(bytes: extradata, count: Int(codecpar.pointee.extradata_size))
            let atoms: NSDictionary = ["av1C": data]
            let extensions = NSMutableDictionary(dictionary: [
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms
            ])
            addColor(codecpar: codecpar, to: extensions)
            let bitDepth = codecpar.pointee.bits_per_raw_sample > 8
                || ColorAttachments.isHDRTransfer(codecpar.pointee.color_trc) ? 10 : 8
            return Configuration(
                codecName: "AV1",
                codecType: kCMVideoCodecType_AV1,
                extensions: extensions,
                bitDepth: bitDepth
            )

        case AV_CODEC_ID_VP9:
            let vp9 = try vp9Configuration(
                codecpar: UnsafePointer(codecpar),
                frameRate: stream.pointee.avg_frame_rate
            )
            let atoms: NSDictionary = ["vpcC": vp9.configurationBoxPayload]
            let extensions = extensions(atoms: atoms, pixelAspectRatio: pixelAspectRatio)
            addColor(codecpar: codecpar, to: extensions)
            return Configuration(
                codecName: "VP9",
                codecType: kCMVideoCodecType_VP9,
                extensions: extensions,
                bitDepth: Int(vp9.bitDepth)
            )

        default:
            throw VideoDecoderError.unsupportedCodec(id: codecpar.pointee.codec_id.rawValue)
        }
    }

    private static func pixelAspectRatio(
        codecpar: UnsafeMutablePointer<AVCodecParameters>,
        stream: UnsafeMutablePointer<AVStream>
    ) -> AVRational? {
        PixelAspectPolicy.declaredPixelAspect(
            bitstream: codecpar.pointee.sample_aspect_ratio,
            container: stream.pointee.sample_aspect_ratio,
            width: codecpar.pointee.width,
            height: codecpar.pointee.height
        )
    }

    /// AV1 (seen on the built-in XDR panel): without colour in the description VideoToolbox guesses
    /// (`ColorInfoGuessedBy`) and tags its output BT.709 SDR in the buffer's CGColorSpace and the
    /// IOSurface's colour space ID, under the PQ transfer the frame handler attaches afterwards, and a
    /// PQ source came out blown out. VP9 gets the same keys so its output cannot be tagged that way
    /// either. HEVC too (AE#957): on an A12 Apple TV, tvOS 27.2, a PQ BT.2020 clip came out tagged
    /// BT.709 the same way despite its VUI, so the output normalizer copied every 4K frame to retag
    /// it (about 7 ms each).
    private static func addColor(
        codecpar: UnsafeMutablePointer<AVCodecParameters>,
        to extensions: NSMutableDictionary
    ) {
        if let primaries = ColorAttachments.primaries(codecpar.pointee.color_primaries) {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = primaries
        }
        if let transfer = ColorAttachments.transfer(codecpar.pointee.color_trc) {
            extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer
        }
        if let matrix = ColorAttachments.matrix(codecpar.pointee.color_space) {
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix
        }
        extensions[kCMFormatDescriptionExtension_FullRangeVideo] =
            codecpar.pointee.color_range == AVCOL_RANGE_JPEG
    }

    private static func extensions(
        atoms: NSDictionary,
        pixelAspectRatio: AVRational?
    ) -> NSMutableDictionary {
        let extensions = NSMutableDictionary(dictionary: [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms
        ])
        if let pixelAspectRatio {
            extensions[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing:
                    Int(pixelAspectRatio.num),
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing:
                    Int(pixelAspectRatio.den)
            ] as NSDictionary
        }
        return extensions
    }

    static func vp9Configuration(
        codecpar: UnsafePointer<AVCodecParameters>,
        frameRate: AVRational
    ) throws -> VP9Configuration {
        let parameters = codecpar.pointee
        let pixelDescription = av_pix_fmt_desc_get(AVPixelFormat(rawValue: parameters.format))
        let describedBitDepth = pixelDescription.map { Int($0.pointee.comp.0.depth) }
        let bitDepth = describedBitDepth ?? {
            let raw = Int(parameters.bits_per_raw_sample)
            if raw > 0 { return raw }
            switch parameters.profile {
            case 0, 1: return 8
            // Profiles 2/3 permit both 10 and 12 bits; do not guess without a probed depth.
            case 2, 3: return 0
            default: return 0
            }
        }()

        let profile: Int
        if parameters.profile >= 0 {
            profile = Int(parameters.profile)
        } else if bitDepth == 8 {
            profile = 0
        } else if bitDepth == 10 {
            profile = 2
        } else {
            throw VideoDecoderError.unsupportedConfiguration(
                codec: "VP9", detail: "profile and bit depth are unknown"
            )
        }

        guard profile == 0 || profile == 2 else {
            throw VideoDecoderError.unsupportedConfiguration(
                codec: "VP9", detail: "profile \(profile) is not a hardware 4:2:0 profile"
            )
        }
        guard (profile == 0 && bitDepth == 8) || (profile == 2 && bitDepth == 10) else {
            throw VideoDecoderError.unsupportedConfiguration(
                codec: "VP9", detail: "profile \(profile) with \(bitDepth)-bit samples"
            )
        }
        if let pixelDescription {
            guard pixelDescription.pointee.log2_chroma_w == 1,
                  pixelDescription.pointee.log2_chroma_h == 1 else {
                throw VideoDecoderError.unsupportedConfiguration(
                    codec: "VP9", detail: "only 4:2:0 chroma is hardware-decodable"
                )
            }
        }

        let level = parameters.level >= 0
            ? UInt8(clamping: parameters.level)
            : estimatedVP9Level(
                width: parameters.width,
                height: parameters.height,
                frameRate: frameRate
            )
        // vpcC represents left (vertical) and top-left (colocated) 4:2:0 only. Do not
        // relabel an explicitly centered source; let libavcodec handle that declaration.
        let chromaSubsampling: UInt8
        switch parameters.chroma_location {
        case AVCHROMA_LOC_LEFT: chromaSubsampling = 0
        case AVCHROMA_LOC_UNSPECIFIED, AVCHROMA_LOC_TOPLEFT: chromaSubsampling = 1
        default:
            throw VideoDecoderError.unsupportedConfiguration(
                codec: "VP9", detail: "chroma location is not representable in vpcC")
        }
        guard parameters.color_space != AVCOL_SPC_RGB else {
            throw VideoDecoderError.unsupportedConfiguration(
                codec: "VP9", detail: "RGB signaling requires a 4:4:4 profile")
        }

        return VP9Configuration(
            profile: UInt8(profile),
            level: level,
            bitDepth: UInt8(bitDepth),
            chromaSubsampling: chromaSubsampling,
            fullRange: parameters.color_range == AVCOL_RANGE_JPEG,
            colorPrimaries: UInt8(clamping: parameters.color_primaries.rawValue),
            transferCharacteristics: UInt8(clamping: parameters.color_trc.rawValue),
            matrixCoefficients: UInt8(clamping: parameters.color_space.rawValue)
        )
    }

    /// The coded size a VP9 key frame declares in its uncompressed header (VP9 bitstream spec 6.2),
    /// or nil for any other frame or a header too short to read. A superframe starts with its first
    /// frame, which is the key frame when the packet is one.
    static func vp9KeyFrameSize(_ bytes: UnsafeBufferPointer<UInt8>) -> (width: Int32, height: Int32)? {
        var reader = BitReader(bytes)
        guard reader.read(2) == 2 else { return nil }   // frame_marker
        let profileLow = reader.read(1), profileHigh = reader.read(1)
        guard let profileLow, let profileHigh else { return nil }
        let profile = profileHigh << 1 | profileLow
        if profile == 3, reader.read(1) == nil { return nil }
        // show_existing_frame, then frame_type (0 = key frame)
        guard reader.read(1) == 0, reader.read(1) == 0 else { return nil }
        guard reader.read(2) != nil,                     // show_frame, error_resilient_mode
              reader.read(24) == 0x49_83_42 else { return nil }
        if profile >= 2, reader.read(1) == nil { return nil }  // ten_or_twelve_bit
        guard let colorSpace = reader.read(3) else { return nil }
        if colorSpace != 7 {                             // CS_RGB
            guard reader.read(1) != nil else { return nil }    // color_range
            if profile == 1 || profile == 3, reader.read(3) == nil { return nil }
        } else if profile == 1 || profile == 3, reader.read(1) == nil {
            return nil
        }
        guard let widthMinusOne = reader.read(16),
              let heightMinusOne = reader.read(16) else { return nil }
        return (Int32(widthMinusOne) + 1, Int32(heightMinusOne) + 1)
    }

    private struct BitReader {
        let bytes: UnsafeBufferPointer<UInt8>
        var position = 0

        init(_ bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

        mutating func read(_ count: Int) -> UInt32? {
            guard position + count <= bytes.count * 8 else { return nil }
            var value: UInt32 = 0
            for _ in 0..<count {
                let bit = bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1
                value = value << 1 | UInt32(bit)
                position += 1
            }
            return value
        }
    }

    /// Mirrors FFmpeg's `get_vp9_level`: first matching luma sample-rate and picture-size ceiling.
    private static func estimatedVP9Level(
        width: Int32,
        height: Int32,
        frameRate: AVRational
    ) -> UInt8 {
        let pictureSize = Int64(max(width, 0)) * Int64(max(height, 0))
        guard pictureSize > 0 else { return 0 }
        let sampleRate: Int64
        if frameRate.num > 0, frameRate.den > 0 {
            let (product, overflow) = pictureSize.multipliedReportingOverflow(
                by: Int64(frameRate.num)
            )
            sampleRate = overflow ? Int64.max : product / Int64(frameRate.den)
        } else {
            sampleRate = 0
        }

        struct LevelLimit {
            let level: UInt8
            let sampleRate: Int64
            let pictureSize: Int64
        }
        let limits = [
            LevelLimit(level: 10, sampleRate: 829_440, pictureSize: 36_864),
            LevelLimit(level: 11, sampleRate: 2_764_800, pictureSize: 73_728),
            LevelLimit(level: 20, sampleRate: 4_608_000, pictureSize: 122_880),
            LevelLimit(level: 21, sampleRate: 9_216_000, pictureSize: 245_760),
            LevelLimit(level: 30, sampleRate: 20_736_000, pictureSize: 552_960),
            LevelLimit(level: 31, sampleRate: 36_864_000, pictureSize: 983_040),
            LevelLimit(level: 40, sampleRate: 83_558_400, pictureSize: 2_228_224),
            LevelLimit(level: 41, sampleRate: 160_432_128, pictureSize: 2_228_224),
            LevelLimit(level: 50, sampleRate: 311_951_360, pictureSize: 8_912_896),
            LevelLimit(level: 51, sampleRate: 588_251_136, pictureSize: 8_912_896),
            LevelLimit(level: 52, sampleRate: 1_176_502_272, pictureSize: 8_912_896),
            LevelLimit(level: 60, sampleRate: 1_176_502_272, pictureSize: 35_651_584),
            LevelLimit(level: 61, sampleRate: 2_353_004_544, pictureSize: 35_651_584),
            LevelLimit(level: 62, sampleRate: 4_706_009_088, pictureSize: 35_651_584)
        ]
        return limits.first {
            sampleRate <= $0.sampleRate && pictureSize <= $0.pictureSize
        }?.level ?? 0
    }
}
