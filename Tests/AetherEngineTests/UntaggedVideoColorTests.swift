import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

/// AE#1103: `LoadOptions.untaggedVideoColor` names what a stream with no colour description is.
/// Measured end to end with `aetherctl probe --untagged-color` and `serve` on a 10-bit HEVC encode
/// with no VUI colour and no `colr`: the served `init.mp4` carries `colr nclx` 9 / 16 / 9, and
/// AVAssetReader decodes it as BT.2020 / PQ where the untouched file comes out as a VideoToolbox
/// BT.709 guess.
struct UntaggedVideoColorTests {

    private let untagged = ColorDescription.unspecified

    @Test("AE#1103: an untagged 10-bit stream becomes HDR10, limited range")
    func untaggedTenBitBecomesHDR10() {
        #expect(ColorDescription.assumed(.hdr10, for: untagged, bitDepth: 10, isDolbyVision: false)
            == ColorDescription(primaries: AVCOL_PRI_BT2020, transfer: AVCOL_TRC_SMPTE2084,
                                matrix: AVCOL_SPC_BT2020_NCL, range: AVCOL_RANGE_MPEG))
    }

    @Test("AE#1103: HLG takes the HLG transfer over the same BT.2020 primaries and matrix")
    func untaggedBecomesHLG() {
        let hlg = ColorDescription.assumed(.hlg, for: untagged, bitDepth: 12, isDolbyVision: false)
        #expect(hlg?.transfer == AVCOL_TRC_ARIB_STD_B67)
        #expect(hlg?.primaries == AVCOL_PRI_BT2020)
        #expect(hlg?.matrix == AVCOL_SPC_BT2020_NCL)
    }

    @Test("AE#1103: a declared range survives")
    func declaredRangeIsKept() {
        var fullRange = untagged
        fullRange.range = AVCOL_RANGE_JPEG
        #expect(ColorDescription.assumed(.hdr10, for: fullRange, bitDepth: 10, isDolbyVision: false)?.range
            == AVCOL_RANGE_JPEG)
    }

    @Test("AE#1103: one declared field is enough to keep the stream's own word",
          arguments: [
            ColorDescription(primaries: AVCOL_PRI_BT709, transfer: AVCOL_TRC_UNSPECIFIED,
                             matrix: AVCOL_SPC_UNSPECIFIED, range: AVCOL_RANGE_UNSPECIFIED),
            ColorDescription(primaries: AVCOL_PRI_UNSPECIFIED, transfer: AVCOL_TRC_BT709,
                             matrix: AVCOL_SPC_UNSPECIFIED, range: AVCOL_RANGE_UNSPECIFIED),
            ColorDescription(primaries: AVCOL_PRI_UNSPECIFIED, transfer: AVCOL_TRC_UNSPECIFIED,
                             matrix: AVCOL_SPC_BT2020_NCL, range: AVCOL_RANGE_UNSPECIFIED),
          ])
    func declaredFieldWins(_ declared: ColorDescription) {
        #expect(ColorDescription.assumed(.hdr10, for: declared, bitDepth: 10, isDolbyVision: false) == nil)
    }

    @Test("AE#1103: 8 bit, an unknown depth and Dolby Vision are left alone, and .standard changes nothing")
    func outsideTheGateNothingChanges() {
        #expect(ColorDescription.assumed(.hdr10, for: untagged, bitDepth: 8, isDolbyVision: false) == nil)
        #expect(ColorDescription.assumed(.hdr10, for: untagged, bitDepth: 0, isDolbyVision: false) == nil)
        #expect(ColorDescription.assumed(.hdr10, for: untagged, bitDepth: 10, isDolbyVision: true) == nil)
        #expect(ColorDescription.assumed(.standard, for: untagged, bitDepth: 10, isDolbyVision: false) == nil)
    }

    @Test("AE#1103: the depth comes from the pixel format, the container's figure only without one")
    func bitDepthSources() {
        #expect(ColorDescription.bitDepth(
            pixelFormat: AV_PIX_FMT_YUV420P10LE.rawValue, bitsPerRawSample: 8) == 10)
        #expect(ColorDescription.bitDepth(pixelFormat: AV_PIX_FMT_YUV420P.rawValue, bitsPerRawSample: 0) == 8)
        #expect(ColorDescription.bitDepth(pixelFormat: AV_PIX_FMT_NONE.rawValue, bitsPerRawSample: 10) == 10)
        #expect(ColorDescription.bitDepth(pixelFormat: AV_PIX_FMT_NONE.rawValue, bitsPerRawSample: 0) == 0)
    }

    @Test("AE#1103: the session's reopens carry the option, so a restart cannot drop back to SDR")
    func reopensInheritTheOption() {
        let session = HLSVideoEngine(
            url: URL(fileURLWithPath: "/nonexistent/untagged.mkv"), dvModeAvailable: false,
            untaggedVideoColor: .hdr10)
        #expect(session.openProfile.untaggedVideoColor == .hdr10)
        #expect(session.restartReopenProfile.untaggedVideoColor == .hdr10)
    }

    @Test("AE#1103: a custom source refuses any change, a URL source takes it")
    func customSourceRefusesTheCorrection() {
        let off = LoadOptions()
        var on = off
        on.untaggedVideoColor = .hdr10
        #expect(SessionOptionCorrection.untaggedVideoColorRefusal(isCustomSource: true, current: off, proposed: on)
            == .untaggedVideoColorNeedsFreshLoad)
        #expect(SessionOptionCorrection.untaggedVideoColorRefusal(isCustomSource: true, current: on, proposed: off)
            == .untaggedVideoColorNeedsFreshLoad)
        #expect(SessionOptionCorrection.untaggedVideoColorRefusal(isCustomSource: true, current: on, proposed: on) == nil)
        #expect(SessionOptionCorrection.untaggedVideoColorRefusal(isCustomSource: false, current: off, proposed: on) == nil)
        #expect(!SessionReloadRefusal.untaggedVideoColorNeedsFreshLoad.description.isEmpty)
    }
}
