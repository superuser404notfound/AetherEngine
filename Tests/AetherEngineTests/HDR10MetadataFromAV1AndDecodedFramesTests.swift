import Foundation
import CoreVideo
import AetherLibavutil
import Testing
@testable import AetherEngine

/// AE#957: HDR10 static metadata on the software path's other routes. Hardware AV1 (VideoToolbox) reads it
/// from the stream's metadata OBUs; the libavcodec decoder (dav1d AV1, VP9, H.264 High 10, HEVC Rext) reads it
/// from each decoded frame's side data. Both give Core Video's byte layout, the one HEVC's SEI already has.
@Suite("HDR10 metadata from AV1 OBUs and decoded frames (AE#957)")
struct HDR10MetadataFromAV1AndDecodedFramesTests {

    private static let clip = HDR10StaticMetadata(maxCLL: 1000, maxFALL: 400, masteringPeakNits: 1000,
                                                  masteringMinNits: 0.005)
    private static let expected = HDR10StaticMetadataSEI.Values(
        masteringDisplay: clip.masteringDisplayColorVolume, contentLightLevel: clip.contentLightLevel)

    /// BT.2020 red, green, blue, then D65, as x, y pairs.
    private static let chromaticities: [Double] = [0.708, 0.292, 0.170, 0.797, 0.131, 0.046, 0.3127, 0.3290]

    private static func bigEndian(_ value: UInt32, bytes: Int) -> [UInt8] {
        (0 ..< bytes).reversed().map { UInt8((value >> (8 * UInt32($0))) & 0xFF) }
    }

    /// A metadata OBU with its size, then the trailing bits.
    private static func metadataOBU(type: UInt8, _ body: [UInt8]) -> [UInt8] {
        let payload = [type] + body + [0x80]
        return [5 << 3 | 2, UInt8(payload.count)] + payload
    }

    private static var cllOBU: [UInt8] { metadataOBU(type: 1, bigEndian(1000, bytes: 2) + bigEndian(400, bytes: 2)) }

    private static var mdcvOBU: [UInt8] {
        var body: [UInt8] = []
        for value in chromaticities { body += bigEndian(UInt32((value * 65_536).rounded()), bytes: 2) }
        body += bigEndian(UInt32(1000 * 256), bytes: 4) // 24.8 fixed point
        body += bigEndian(UInt32((0.005 * 16_384).rounded()), bytes: 4) // 18.14 fixed point
        return metadataOBU(type: 2, body)
    }

    private static let temporalDelimiter: [UInt8] = [2 << 3 | 2, 0]
    private static let frameOBU: [UInt8] = [6 << 3 | 2, 3, 0x10, 0x20, 0x30]

    private static func scan(_ bytes: [UInt8]) -> HDR10StaticMetadataSEI.Values {
        bytes.withUnsafeBufferPointer { HDR10StaticMetadataSEI.scanAV1($0.baseAddress!, size: $0.count) }
    }

    @Test func issue957AV1MetadataOBUsGiveCoreVideosLayout() {
        let found = Self.scan(Self.temporalDelimiter + Self.cllOBU + Self.mdcvOBU + Self.frameOBU)
        #expect(found == Self.expected)
    }

    @Test func issue957AV1ConfigRecordOBUsAreRead() {
        let record: [UInt8] = [0x81, 0x0C, 0x00, 0x00] + Self.mdcvOBU + Self.cllOBU
        let found = record.withUnsafeBufferPointer {
            HDR10StaticMetadataSEI.scanAV1ConfigRecord($0.baseAddress!, size: $0.count)
        }
        #expect(found == Self.expected)
        let notARecord = [UInt8](repeating: 0, count: 8)
        let none = notARecord.withUnsafeBufferPointer {
            HDR10StaticMetadataSEI.scanAV1ConfigRecord($0.baseAddress!, size: $0.count)
        }
        #expect(none == .none)
    }

    @Test func issue957AMalformedAV1TemporalUnitKeepsWhatWasRead() {
        // An OBU that declares more bytes than the packet holds ends the walk.
        let overrun = Self.scan(Self.cllOBU + [5 << 3 | 2, 0x7F, 0x02, 0x00])
        #expect(overrun == HDR10StaticMetadataSEI.Values(contentLightLevel: Self.expected.contentLightLevel))
        // A short MDCV and a set forbidden bit yield nothing.
        #expect(Self.scan(Self.metadataOBU(type: 2, [0x01, 0x02])) == .none)
        #expect(Self.scan([0x80] + Self.cllOBU) == .none)
    }

    @Test func issue957ADecodedFramesSideDataGivesCoreVideosLayout() throws {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let decoded = try #require(frame)
        #expect(HDR10StaticMetadataSEI.fromFrameSideData(decoded) == .none)

        // libdav1d's units: 0.16 fixed point chromaticity, 24.8 and 18.14 fixed point luminance.
        let mastering = try #require(av_mastering_display_metadata_create_side_data(decoded))
        func q(_ value: Double, _ den: Int32) -> AVRational {
            AVRational(num: Int32((value * Double(den)).rounded()), den: den)
        }
        let c = Self.chromaticities.map { q($0, 1 << 16) }
        mastering.pointee.display_primaries = ((c[0], c[1]), (c[2], c[3]), (c[4], c[5]))
        mastering.pointee.white_point = (c[6], c[7])
        mastering.pointee.max_luminance = q(1000, 1 << 8)
        mastering.pointee.min_luminance = q(0.005, 1 << 14)
        mastering.pointee.has_primaries = 1
        mastering.pointee.has_luminance = 1
        let lightLevel = try #require(av_content_light_metadata_create_side_data(decoded))
        lightLevel.pointee.MaxCLL = 1000
        lightLevel.pointee.MaxFALL = 400

        #expect(HDR10StaticMetadataSEI.fromFrameSideData(decoded) == Self.expected)
    }

    @Test func issue957TheSoftwareDecoderSetsAndClearsTheHDR10Keys() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &buffer)
        let pb = try #require(buffer)
        SoftwareVideoDecoder.setHDR10(Self.expected, on: pb)
        let mastering = CVBufferCopyAttachment(pb, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data
        let lightLevel = CVBufferCopyAttachment(pb, kCVImageBufferContentLightLevelInfoKey, nil) as? Data
        #expect(mastering == Self.expected.masteringDisplay)
        #expect(lightLevel == Self.expected.contentLightLevel)

        // A reused pool buffer for a frame with no values keeps none of the last frame's.
        SoftwareVideoDecoder.setHDR10(.none, on: pb)
        #expect(CVBufferCopyAttachment(pb, kCVImageBufferMasteringDisplayColorVolumeKey, nil) == nil)
        #expect(CVBufferCopyAttachment(pb, kCVImageBufferContentLightLevelInfoKey, nil) == nil)
    }
}
