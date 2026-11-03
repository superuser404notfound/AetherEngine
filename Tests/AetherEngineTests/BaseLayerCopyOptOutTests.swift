import Foundation
import CoreVideo
import VideoToolbox
import Testing
@testable import AetherEngine

/// The output-metadata normalizer copies every base-layer frame whose `imageBufferModifiable`
/// flag is absent into a 4K pool of its own (about 315 MB of IOSurface in the app). The dual-layer
/// route composes into that same buffer, so the copy buys nothing there; only that route opts out.
@Suite("Base-layer metadata copy opt-out")
struct BaseLayerCopyOptOutTests {

    private func makeInput() throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attrs, &out) == kCVReturnSuccess)
        return try #require(out)
    }

    private func decoder(_ allowsInPlace: Bool) -> HardwareVideoDecoder {
        let d = HardwareVideoDecoder()
        d.allowsInPlaceOutputMetadata = allowsInPlace
        return d
    }

    private func normalized(_ input: CVPixelBuffer, flags: VTDecodeInfoFlags, allowsInPlace: Bool) -> CVPixelBuffer {
        VideoToolboxOutputMetadataNormalizer().applyingOutputMetadata(
            to: input,
            isModifiable: decoder(allowsInPlace).outputIsModifiable(flags),
            colorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            yCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
            pixelAspectRatio: nil)
    }

    private func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil) as? String
    }

    @Test("the single-layer path still copies when the flag is absent")
    func singleLayerKeepsTheCopy() throws {
        let input = try makeInput()
        let output = normalized(input, flags: [], allowsInPlace: false)
        #expect(output !== input)
        #expect(attachment(input, kCVImageBufferColorPrimariesKey) == nil)
    }

    @Test("the single-layer path still uses the buffer when VideoToolbox grants the flag")
    func singleLayerHonoursTheFlag() throws {
        let input = try makeInput()
        #expect(normalized(input, flags: .imageBufferModifiable, allowsInPlace: false) === input)
    }

    @Test("the opted-out decoder applies the attachments to its own buffer, no copy")
    func optOutMakesNoCopyAndKeepsTheAttachments() throws {
        let input = try makeInput()
        let output = normalized(input, flags: [], allowsInPlace: true)
        #expect(output === input)
        #expect(attachment(output, kCVImageBufferColorPrimariesKey) == (kCVImageBufferColorPrimaries_ITU_R_2020 as String))
        #expect(attachment(output, kCVImageBufferTransferFunctionKey) == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String))
        #expect(attachment(output, kCVImageBufferYCbCrMatrixKey) == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String))
    }

    @Test("a plain HardwareVideoDecoder does not opt out")
    func defaultIsOff() {
        #expect(HardwareVideoDecoder().allowsInPlaceOutputMetadata == false)
        #expect(HardwareVideoDecoder().outputIsModifiable([]) == false)
    }

    #if DualLayerDolbyVision
    @Test("the dual-layer base-layer decoder opts out, on both construction paths")
    func dualLayerOptsOut() throws {
        let production = DualLayerVideoDecoder(composer: nil)
        #expect(production.primaryOutputIsModifiableForTesting)
        let injected = DualLayerVideoDecoder(composer: nil, primaryDecoder: HardwareVideoDecoder(), enhancementDecoder: nil)
        #expect(injected.primaryOutputIsModifiableForTesting)
        let enhancement = try #require(production.makeEnhancementDecoder() as? HardwareVideoDecoder)
        #expect(enhancement.outputIsModifiable([]) == false)
    }
    #endif
}
