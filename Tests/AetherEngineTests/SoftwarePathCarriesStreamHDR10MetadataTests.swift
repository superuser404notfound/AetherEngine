import Foundation
import CoreVideo
import AetherLibavcodec
import AetherLibavutil
import Testing
@testable import AetherEngine

/// AE#957: VideoToolbox attaches no HDR10 static metadata to the frames it decodes, so the software path
/// sent HDR10 with none. The hardware decoder now finds the stream's values (container, `hvcC` or SEI)
/// and the output normalizer attaches them to every frame.
@Suite("Software path carries the stream's HDR10 metadata (AE#957)")
struct SoftwarePathCarriesStreamHDR10MetadataTests {

    /// A typical x265 HDR10 encode: BT.2020 at 1000 nit, minimum 0.005, MaxCLL 1000 / 400.
    private static let clip = HDR10StaticMetadata(maxCLL: 1000, maxFALL: 400, masteringPeakNits: 1000,
                                                  masteringMinNits: 0.005)

    /// A prefix SEI NAL (no start code or length) with both messages, emulation prevention applied: the
    /// minimum luminance (50 = 00 00 00 32) needs it, as in every real HDR10 stream.
    private static func seiNAL(_ m: HDR10StaticMetadata = clip) -> [UInt8] {
        var rbsp: [UInt8] = [137, 24] + [UInt8](m.masteringDisplayColorVolume)
        rbsp += [144, 4] + [UInt8](m.contentLightLevel)
        rbsp.append(0x80)
        var escaped: [UInt8] = [39 << 1, 1]
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 { escaped.append(3); zeros = 0 }
            escaped.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return escaped
    }

    private static func lengthPrefixed(_ nal: [UInt8], size: Int) -> [UInt8] {
        (0 ..< size).reversed().map { UInt8((nal.count >> (8 * $0)) & 0xFF) } + nal
    }

    private func scan(_ bytes: [UInt8], framing: A53SEIParser.NALFraming) -> HDR10StaticMetadataSEI.Values {
        bytes.withUnsafeBufferPointer {
            HDR10StaticMetadataSEI.scan($0.baseAddress!, size: $0.count, codec: .hevc, framing: framing)
        }
    }

    @Test func issue957TheSEIInAKeyFrameGivesCoreVideosBytes() {
        let expected = HDR10StaticMetadataSEI.Values(
            masteringDisplay: Self.clip.masteringDisplayColorVolume, contentLightLevel: Self.clip.contentLightLevel)
        // An access unit: an AUD, the SEI, a slice.
        let aud: [UInt8] = [35 << 1, 1, 0x50]
        let slice: [UInt8] = [19 << 1, 1, 0xAF, 0x00, 0x11]
        let annexB: [UInt8] = [0, 0, 0, 1] + aud + [0, 0, 1] + Self.seiNAL() + [0, 0, 1] + slice
        let fromAnnexB = scan(annexB, framing: .annexB)
        #expect(fromAnnexB == expected)
        let mp4 = [aud, Self.seiNAL(), slice].flatMap { Self.lengthPrefixed($0, size: 4) }
        let fromMP4 = scan(mp4, framing: .lengthPrefixed(size: 4))
        #expect(fromMP4 == expected)
    }

    @Test func issue957TheScanStopsAfterThreeKeyFrames() {
        // docs/architecture-software.md says 3.
        #expect(HDR10StaticMetadataSEI.keyFramesToScan == 3)
    }

    @Test func issue957APacketWithoutTheSEIGivesNothing() {
        let slice: [UInt8] = [19 << 1, 1, 0xAF, 0x00, 0x11]
        let fromSlice = scan(Self.lengthPrefixed(slice, size: 4), framing: .lengthPrefixed(size: 4))
        #expect(fromSlice.isEmpty)
        // A truncated message is skipped, not read past its end.
        let cut = Array(Self.seiNAL().prefix(12))
        let fromCut = scan(Self.lengthPrefixed(cut, size: 4), framing: .lengthPrefixed(size: 4))
        #expect(fromCut.isEmpty)
    }

    @Test func issue957TheHvcCSEIArrayIsRead() {
        let sei = Self.seiNAL()
        var record = [UInt8](repeating: 0, count: 23)
        record[0] = 1
        record[22] = 2
        let vps: [UInt8] = [32 << 1, 1, 0x0C]
        let vpsArray: [UInt8] = [0x80 | 32, 0, 1, 0, UInt8(vps.count)]
        let seiArray: [UInt8] = [39, 0, 1, UInt8(sei.count >> 8), UInt8(sei.count & 0xFF)]
        record += vpsArray + vps
        record += seiArray + sei
        let found = record.withUnsafeBufferPointer {
            HDR10StaticMetadataSEI.scanHEVCConfigRecord($0.baseAddress!, size: $0.count)
        }
        #expect(found.masteringDisplay == Self.clip.masteringDisplayColorVolume)
        #expect(found.contentLightLevel == Self.clip.contentLightLevel)
        // A record cut inside its arrays gives nothing rather than a guess.
        let cut = Array(record.dropLast(10))
        let fromCut = cut.withUnsafeBufferPointer {
            HDR10StaticMetadataSEI.scanHEVCConfigRecord($0.baseAddress!, size: $0.count)
        }
        #expect(fromCut.isEmpty)
    }

    @Test func issue957TheContainersDeclarationMatchesTheSEIBytes() throws {
        let codecpar = try #require(avcodec_parameters_alloc())
        defer { var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar; avcodec_parameters_free(&p) }
        let mdcv = try #require(av_packet_side_data_new(
            &codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
            AV_PKT_DATA_MASTERING_DISPLAY_METADATA, MemoryLayout<AVMasteringDisplayMetadata>.size, 0))
        try #require(mdcv.pointee.data).withMemoryRebound(to: AVMasteringDisplayMetadata.self, capacity: 1) {
            func q(_ v: Int32) -> AVRational { AVRational(num: v, den: 50_000) }
            // FFmpeg's order: red, green, blue.
            $0.pointee.display_primaries = ((q(35400), q(14600)), (q(8500), q(39850)), (q(6550), q(2300)))
            $0.pointee.white_point = (q(15635), q(16450))
            $0.pointee.max_luminance = AVRational(num: 1000, den: 1)
            $0.pointee.min_luminance = AVRational(num: 50, den: 10_000)
            $0.pointee.has_primaries = 1
            $0.pointee.has_luminance = 1
        }
        let cll = try #require(av_packet_side_data_new(
            &codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
            AV_PKT_DATA_CONTENT_LIGHT_LEVEL, MemoryLayout<AVContentLightMetadata>.size, 0))
        try #require(cll.pointee.data).withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) {
            $0.pointee.MaxCLL = 1000
            $0.pointee.MaxFALL = 400
        }
        let found = HDR10StaticMetadataSEI.fromCodedSideData(codecpar)
        #expect(found.masteringDisplay == Self.clip.masteringDisplayColorVolume)
        #expect(found.contentLightLevel == Self.clip.contentLightLevel)
    }

    @Test func issue957AHalfFilledContainerVolumeIsNotUsed() {
        var m = AVMasteringDisplayMetadata()
        m.max_luminance = AVRational(num: 1000, den: 1)
        m.has_luminance = 1
        #expect(HDR10StaticMetadataSEI.masteringDisplay(m) == nil)
    }

    @Test func issue957TheNormalizerAttachesTheValuesToEveryFrame() throws {
        let values = HDR10StaticMetadataSEI.Values(
            masteringDisplay: Self.clip.masteringDisplayColorVolume, contentLightLevel: Self.clip.contentLightLevel)
        let normalizer = VideoToolboxOutputMetadataNormalizer()
        func frame() throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()] as NSDictionary, &buffer)
            return try #require(buffer)
        }
        func attached(_ b: CVPixelBuffer) -> [Data?] {
            [CVBufferCopyAttachment(b, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data,
             CVBufferCopyAttachment(b, kCVImageBufferContentLightLevelInfoKey, nil) as? Data]
        }
        let both: [Data?] = [values.masteringDisplay, values.contentLightLevel]
        let neither: [Data?] = [nil, nil]
        func normalize(_ b: CVPixelBuffer, modifiable: Bool) -> CVPixelBuffer {
            normalizer.applyingOutputMetadata(to: b, isModifiable: modifiable, colorPrimaries: nil,
                transferFunction: nil, yCbCrMatrix: nil, pixelAspectRatio: nil, hdr10: values)
        }

        // Decoder-owned (immutable) output: the values go on an owned copy, the original is untouched.
        let owned = try frame()
        let copy = normalize(owned, modifiable: false)
        #expect(copy !== owned)
        #expect(attached(owned) == neither)
        #expect(attached(copy) == both)

        // Modifiable output gets them in place; a frame that already carries them passes unchanged.
        let modifiable = try frame()
        #expect(normalize(modifiable, modifiable: true) === modifiable)
        #expect(attached(modifiable) == both)
        #expect(normalize(modifiable, modifiable: false) === modifiable)

        // No values known: the frame is left as it is.
        let plain = try frame()
        let untouched = normalizer.applyingOutputMetadata(to: plain, isModifiable: false, colorPrimaries: nil,
            transferFunction: nil, yCbCrMatrix: nil, pixelAspectRatio: nil)
        #expect(untouched === plain)
    }

    /// A value the frame already carries is the decoder's own and stays: only a missing key is filled, and a
    /// frame with both keys is not copied, whatever values they hold.
    @Test func issue957AFrameThatCarriesItsOwnValuesKeepsThem() throws {
        let values = HDR10StaticMetadataSEI.Values(
            masteringDisplay: Self.clip.masteringDisplayColorVolume, contentLightLevel: Self.clip.contentLightLevel)
        let own = HDR10StaticMetadata(maxCLL: 4000, maxFALL: 1000, masteringPeakNits: 4000,
                                      masteringMinNits: 0.005).masteringDisplayColorVolume
        var created: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()] as NSDictionary, &created)
        let frame = try #require(created)
        CVBufferSetAttachment(frame, kCVImageBufferMasteringDisplayColorVolumeKey, own as CFData, .shouldPropagate)
        let normalizer = VideoToolboxOutputMetadataNormalizer()
        func normalize(modifiable: Bool) -> CVPixelBuffer {
            normalizer.applyingOutputMetadata(to: frame, isModifiable: modifiable, colorPrimaries: nil,
                transferFunction: nil, yCbCrMatrix: nil, pixelAspectRatio: nil, hdr10: values)
        }

        let inPlace = normalize(modifiable: true)
        let mastering = CVBufferCopyAttachment(frame, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data
        let lightLevel = CVBufferCopyAttachment(frame, kCVImageBufferContentLightLevelInfoKey, nil) as? Data
        #expect(inPlace === frame)
        #expect(mastering == own)
        #expect(lightLevel == Self.clip.contentLightLevel)

        // Both keys present now: a decoder-owned frame passes as it is, no copy.
        let owned = normalize(modifiable: false)
        #expect(owned === frame)
    }
}
