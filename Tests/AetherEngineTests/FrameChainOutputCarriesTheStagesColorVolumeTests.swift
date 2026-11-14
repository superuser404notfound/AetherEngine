#if !targetEnvironment(simulator)
import Foundation
import CoreVideo
import Testing
@testable import AetherEngine

/// AE#957: a frame chain stage declares the colour volume of its output, and the chain writes the frames'
/// HDR10 metadata from it, so the display does not tone map a picture that a stage already fitted to it.
/// Without a declaration the source's own metadata carries over. The geometry keys never do: the output is
/// the picture region alone.
@Suite("Frame chain output carries the stages' colour volume (AE#957)")
struct FrameChainOutputCarriesTheStagesColorVolumeTests {

    private static let source = HDR10StaticMetadata(maxCLL: 1000, maxFALL: 400, masteringPeakNits: 1000,
                                                    masteringMinNits: 0.005)
    private static let fitted = HDR10StaticMetadata(maxCLL: 800, maxFALL: 300, masteringPeakNits: 800,
                                                    masteringMinNits: 0.0005)

    private struct Failure: Error {}

    /// A 10-bit BT.2020 PQ frame, with the source's HDR10 keys and a clean aperture when asked.
    private static func frame(hdr10: HDR10StaticMetadata? = nil, aperture: Bool = false) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                  nil, &buffer) == kCVReturnSuccess, let pb = buffer else { throw Failure() }
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                              .shouldPropagate)
        if let hdr10 {
            CVBufferSetAttachment(pb, kCVImageBufferMasteringDisplayColorVolumeKey,
                                  hdr10.masteringDisplayColorVolume as CFData, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferContentLightLevelInfoKey, hdr10.contentLightLevel as CFData,
                                  .shouldPropagate)
        }
        if aperture {
            let clean: [String: Any] = [kCVImageBufferCleanApertureWidthKey as String: 14,
                                        kCVImageBufferCleanApertureHeightKey as String: 14]
            CVBufferSetAttachment(pb, kCVImageBufferCleanApertureKey, clean as CFDictionary, .shouldPropagate)
        }
        return pb
    }

    private static func hdr10Keys(_ buffer: CVPixelBuffer) -> (Data?, Data?) {
        (CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data,
         CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) as? Data)
    }

    @Test func issue957TheLastStageThatDeclaresAVolumeSetsTheChains() {
        #expect(FrameChainColorVolume.ofChain([]) == .unchanged)
        #expect(FrameChainColorVolume.ofChain([.unchanged, .unchanged]) == .unchanged)
        // A dither or LUT stage after the tone mapper keeps the tone mapper's volume.
        #expect(FrameChainColorVolume.ofChain([.hdr10(Self.source), .hdr10(Self.fitted), .unchanged])
                == .hdr10(Self.fitted))
    }

    @Test func issue957AnUnchangedChainCarriesTheSourcesKeysWithoutItsGeometry() throws {
        let input = try Self.frame(hdr10: Self.source, aperture: true)
        let output = try Self.frame()
        FrameChainOutputAttachments.carry(from: input, to: output, volume: .unchanged)
        let (mastering, lightLevel) = Self.hdr10Keys(output)
        #expect(mastering == Self.source.masteringDisplayColorVolume)
        #expect(lightLevel == Self.source.contentLightLevel)
        #expect(CVBufferCopyAttachment(output, kCVImageBufferCleanApertureKey, nil) == nil)
        #expect(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String
                == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
    }

    @Test func issue957ADeclaredVolumeReplacesTheSourcesHDR10Keys() throws {
        let input = try Self.frame(hdr10: Self.source)
        let output = try Self.frame()
        FrameChainOutputAttachments.carry(from: input, to: output, volume: .hdr10(Self.fitted))
        let (mastering, lightLevel) = Self.hdr10Keys(output)
        #expect(HDR10StaticMetadata.describe(masteringDisplayColorVolume: mastering) == "peak 800 min 0.0005")
        #expect(HDR10StaticMetadata.describe(contentLightLevel: lightLevel) == "800/300")
        #expect(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String
                == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
    }

    @Test func issue957AReusedOutputBufferKeepsNoneOfTheLastFramesKeys() throws {
        // A pool buffer that last carried a declared volume, now for a source without HDR10 metadata.
        let output = try Self.frame(hdr10: Self.fitted, aperture: true)
        FrameChainOutputAttachments.carry(from: try Self.frame(), to: output, volume: .unchanged)
        let (mastering, lightLevel) = Self.hdr10Keys(output)
        #expect(mastering == nil && lightLevel == nil)
        #expect(CVBufferCopyAttachment(output, kCVImageBufferCleanApertureKey, nil) == nil)
    }
}
#endif
