import Foundation
import Testing
import CoreMedia
import CoreVideo
@testable import AetherEngine

/// AE#957: the renderer reuses its format description while the frames look the same, and the
/// description snapshots the frame's HDR10 static metadata. So a change of that metadata at the same
/// size and colour (a stream whose first frames carry none, or values that change) must make a new
/// description, or the display layer keeps seeing the first frame's values.
@Suite("Format description follows HDR10 static metadata")
struct FormatDescriptionFollowsHDR10MetadataTests {

    private func frame(cll: [UInt8]?) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()] as NSDictionary, &pb)
        let buffer = try #require(pb)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020,
                              .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020,
                              .shouldPropagate)
        if let cll {
            CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, Data(cll) as CFData,
                                  .shouldPropagate)
        }
        return buffer
    }

    private func cll(_ sample: CMSampleBuffer) -> Data? {
        guard let desc = CMSampleBufferGetFormatDescription(sample) else { return nil }
        return CMFormatDescriptionGetExtension(
            desc, extensionKey: kCMFormatDescriptionExtension_ContentLightLevelInfo) as? Data
    }

    @Test
    @MainActor
    func issue957AChangedContentLightLevelMakesANewDescription() throws {
        let renderer = SampleBufferRenderer()
        let none = try #require(renderer.createSampleBuffer(from: frame(cll: nil), pts: CMTime(value: 0, timescale: 24)))
        #expect(cll(none) == nil)

        let a = try #require(renderer.createSampleBuffer(from: frame(cll: [0x01, 0x59, 0x00, 0x7B]),
                                                         pts: CMTime(value: 1, timescale: 24)))
        #expect(cll(a) == Data([0x01, 0x59, 0x00, 0x7B]))

        let b = try #require(renderer.createSampleBuffer(from: frame(cll: [0x0F, 0xA0, 0x03, 0xE8]),
                                                         pts: CMTime(value: 2, timescale: 24)))
        #expect(cll(b) == Data([0x0F, 0xA0, 0x03, 0xE8]))

        // The same values again reuse the description: the cache still works.
        let again = try #require(renderer.createSampleBuffer(from: frame(cll: [0x0F, 0xA0, 0x03, 0xE8]),
                                                             pts: CMTime(value: 3, timescale: 24)))
        #expect(CMSampleBufferGetFormatDescription(again) === CMSampleBufferGetFormatDescription(b))
    }
}
