import Foundation
import CoreMedia
import AetherLibavformat
import AetherLibavutil
import AetherLibavcodec
import Testing
@testable import AetherEngine

/// AE#957: VideoToolbox tagged a PQ BT.2020 HEVC clip's frames BT.709 and gave them no HDR10 metadata, so the
/// output normalizer copied every 4K frame (about 7 ms each on an A12 Apple TV). The format description it
/// decodes with now names the stream's colour and HDR10 values, and VideoToolbox attaches them itself.
@Suite("Decoder format description carries the stream's colour and HDR10 values (AE#957)")
struct DecoderFormatCarriesStreamColourAndHDR10Tests {

    private static let clip = HDR10StaticMetadata(maxCLL: 1000, maxFALL: 400, masteringPeakNits: 1000,
                                                  masteringMinNits: 0.005)

    @Test func issue957HEVCDescriptionNamesTheStreamsColour() throws {
        let context = try #require(avformat_alloc_context())
        defer { avformat_free_context(context) }
        let stream = try #require(avformat_new_stream(context, nil))
        let parameters = try #require(stream.pointee.codecpar)
        parameters.pointee.codec_id = AV_CODEC_ID_HEVC
        parameters.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        parameters.pointee.width = 3840
        parameters.pointee.height = 2160
        parameters.pointee.color_primaries = AVCOL_PRI_BT2020
        parameters.pointee.color_trc = AVCOL_TRC_SMPTE2084
        parameters.pointee.color_space = AVCOL_SPC_BT2020_NCL
        parameters.pointee.color_range = AVCOL_RANGE_MPEG
        // A minimal hvcC (version 1, no arrays); avformat_free_context frees it.
        let record = [UInt8](repeating: 0, count: 23)
        let extradata = try #require(av_mallocz(record.count + 64)?.assumingMemoryBound(to: UInt8.self))
        extradata.update(from: record, count: record.count)
        extradata[0] = 1
        parameters.pointee.extradata = extradata
        parameters.pointee.extradata_size = Int32(record.count)

        let configuration = try VideoToolboxVideoFormat.make(stream: stream)
        let extensions = configuration.extensions
        let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
        let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
        let fullRange = extensions[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool
        let hasRecord = (extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
            as? NSDictionary)?["hvcC"] != nil
        #expect(configuration.codecName == "HEVC")
        #expect(hasRecord)
        #expect(primaries == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
        #expect(transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(matrix == kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String)
        #expect(fullRange == false)
    }

    @Test func issue957TheHDR10ValuesKnownAtOpenGoIntoTheDescription() {
        let base: NSDictionary = [kCMFormatDescriptionExtension_TransferFunction:
                                    kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ]
        let values = HDR10StaticMetadataSEI.Values(
            masteringDisplay: Self.clip.masteringDisplayColorVolume, contentLightLevel: Self.clip.contentLightLevel)
        let extensions = HardwareVideoDecoder.extensions(base, carrying: values)
        let mastering = extensions?[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] as? Data
        let lightLevel = extensions?[kCMFormatDescriptionExtension_ContentLightLevelInfo] as? Data
        let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction] as? String
        #expect(mastering == Self.clip.masteringDisplayColorVolume)
        #expect(lightLevel == Self.clip.contentLightLevel)
        #expect(transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)

        // Nothing known: the description is left as it was.
        let unchanged = HardwareVideoDecoder.extensions(base, carrying: .none)
        #expect(unchanged === base)
    }
}
