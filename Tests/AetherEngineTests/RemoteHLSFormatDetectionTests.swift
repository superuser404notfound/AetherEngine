import Testing
import CoreMedia
import CoreVideo
@testable import AetherEngine

/// AetherEngine#168: the nativeRemoteHLS bypass runs no libav probe, so the item's dynamic range must be
/// read back from AVPlayer's parsed video-track CMFormatDescription. Pins the pure transfer/subtype ->
/// VideoFormat classifier that feeds the badge (`fmt=sdr` was a hard-coded default on this path).
@Suite("RemoteHLSFormatDetection")
struct RemoteHLSFormatDetectionTests {

    private let dvh1: FourCharCode = 0x64766831 // 'dvh1'
    private let dvhe: FourCharCode = 0x64766865 // 'dvhe'
    private let hvc1: FourCharCode = 0x68766331 // 'hvc1'

    @Test("PQ transfer classifies as HDR10")
    func pqIsHDR10() {
        let fmt = RemoteHLSFormatDetection.videoFormat(
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
            videoSubType: hvc1)
        #expect(fmt == .hdr10)
    }

    @Test("HLG transfer classifies as HLG")
    func hlgIsHLG() {
        let fmt = RemoteHLSFormatDetection.videoFormat(
            transferFunction: kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
            videoSubType: hvc1)
        #expect(fmt == .hlg)
    }

    @Test("BT.709 transfer classifies as SDR")
    func bt709IsSDR() {
        let fmt = RemoteHLSFormatDetection.videoFormat(
            transferFunction: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            videoSubType: hvc1)
        #expect(fmt == .sdr)
    }

    @Test("Missing transfer function classifies as SDR")
    func nilTransferIsSDR() {
        let fmt = RemoteHLSFormatDetection.videoFormat(transferFunction: nil, videoSubType: hvc1)
        #expect(fmt == .sdr)
    }

    @Test("Unrecognized transfer string classifies as SDR")
    func unknownTransferIsSDR() {
        let fmt = RemoteHLSFormatDetection.videoFormat(transferFunction: "Some_Future_Transfer",
                                                       videoSubType: hvc1)
        #expect(fmt == .sdr)
    }

    @Test("dvh1 subtype classifies as Dolby Vision regardless of transfer")
    func dvh1IsDolbyVision() {
        // DV tracks carry a PQ base transfer; the subtype must win so the badge reads DV, not HDR10.
        let fmt = RemoteHLSFormatDetection.videoFormat(
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
            videoSubType: dvh1)
        #expect(fmt == .dolbyVision)
    }

    @Test("dvhe subtype classifies as Dolby Vision")
    func dvheIsDolbyVision() {
        let fmt = RemoteHLSFormatDetection.videoFormat(transferFunction: nil, videoSubType: dvhe)
        #expect(fmt == .dolbyVision)
    }

    @Test("hvc1 subtype does not override a PQ transfer")
    func hvc1KeepsHDR10() {
        let fmt = RemoteHLSFormatDetection.videoFormat(
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
            videoSubType: hvc1)
        #expect(fmt == .hdr10)
    }

    @Test("Nil subtype with PQ still classifies as HDR10")
    func nilSubtypePQIsHDR10() {
        let fmt = RemoteHLSFormatDetection.videoFormat(
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
            videoSubType: nil)
        #expect(fmt == .hdr10)
    }

    // MARK: - shouldApplyDisplayCriteria

    @Test("HDR formats warrant a panel switch when not suppressed", arguments: [
        VideoFormat.hdr10, .hdr10Plus, .dolbyVision, .hlg
    ])
    func hdrAppliesCriteria(_ format: VideoFormat) {
        #expect(RemoteHLSFormatDetection.shouldApplyDisplayCriteria(
            format: format, suppressDisplayCriteria: false))
    }

    @Test("SDR never warrants a panel switch")
    func sdrSkipsCriteria() {
        #expect(!RemoteHLSFormatDetection.shouldApplyDisplayCriteria(
            format: .sdr, suppressDisplayCriteria: false))
    }

    @Test("A sole-writer host suppresses the switch even for HDR")
    func suppressedSkipsCriteria() {
        #expect(!RemoteHLSFormatDetection.shouldApplyDisplayCriteria(
            format: .hdr10, suppressDisplayCriteria: true))
    }
}
