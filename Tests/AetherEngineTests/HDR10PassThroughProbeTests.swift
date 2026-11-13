import Foundation
import Testing
import CoreMedia
import CoreVideo
#if !targetEnvironment(simulator)
import Metal
#endif
@testable import AetherEngine

/// AE#957 step 2: the HDR10 pass-through probe. Its settings come from the environment, its metadata must
/// be the SEI byte layout CoreVideo expects, and a format description made from a tagged buffer must carry
/// that metadata, because that description is what the renderer hands the display layer.
@Suite("HDR10 pass-through probe")
struct HDR10PassThroughProbeTests {

    // MARK: Settings

    @Test
    func issue957ProbeIsOffWithoutTheVariable() {
        #expect(HDR10ProbeSettings.fromEnvironment { _ in nil } == nil)
        #expect(HDR10ProbeSettings.fromEnvironment { _ in "" } == nil)
    }

    @Test(arguments: HDR10ProbeSettings.Mode.allCases)
    func issue957EveryModeParsesWithTheDefaultMetadata(mode: HDR10ProbeSettings.Mode) throws {
        let env = [HDR10ProbeSettings.modeVariable: mode.rawValue.uppercased()]
        let settings = try #require(HDR10ProbeSettings.fromEnvironment { env[$0] })
        #expect(settings.mode == mode)
        #expect(settings.metadata == .probeDefault)
    }

    @Test
    func issue957AnUnknownModeLeavesTheProbeOff() {
        let env = [HDR10ProbeSettings.modeVariable: "tonemap"]
        #expect(HDR10ProbeSettings.fromEnvironment { env[$0] } == nil)
        guard case .failure = HDR10ProbeSettings.parse(mode: "tonemap", metadata: nil) else {
            Issue.record("an unknown mode parsed")
            return
        }
    }

    @Test
    func issue957ModesSayWhatTheyDo() {
        #expect(!HDR10ProbeSettings.Mode.log.runsChain && !HDR10ProbeSettings.Mode.log.setsMetadata)
        #expect(!HDR10ProbeSettings.Mode.meta.runsChain && HDR10ProbeSettings.Mode.meta.setsMetadata)
        #expect(HDR10ProbeSettings.Mode.chain.runsChain && !HDR10ProbeSettings.Mode.chain.setsMetadata)
        #expect(HDR10ProbeSettings.Mode.chainMeta.runsChain && HDR10ProbeSettings.Mode.chainMeta.setsMetadata)
    }

    @Test
    func issue957MetadataKeysOverrideTheDefaults() throws {
        let m = try HDR10StaticMetadata.parse("maxcll=600, peak=1000").get()
        #expect(m == HDR10StaticMetadata(maxCLL: 600, maxFALL: 123, masteringPeakNits: 1000, masteringMinNits: 0.005))
    }

    @Test(arguments: ["maxcll=0", "maxcll=70000", "maxcll=100,maxfall=200", "peak=20000", "peak=0.5",
                      "min=800", "min=-1", "colour=1", "maxcll", "maxcll=abc"])
    func issue957BadMetadataIsRefused(text: String) {
        guard case .failure = HDR10StaticMetadata.parse(text) else {
            Issue.record("'\(text)' parsed")
            return
        }
    }

    // MARK: Byte layout

    /// The mastering display SEI: G, B, R primaries and the white point as 16-bit values in 0.00002 units,
    /// then peak and minimum luminance as 32-bit values in 0.0001 nit, all big endian.
    @Test
    func issue957MasteringDisplayBytesAreTheSEILayout() {
        let bytes = [UInt8](HDR10StaticMetadata.probeDefault.masteringDisplayColorVolume)
        #expect(bytes.count == 24)
        #expect(Array(bytes[0..<4]) == [0x21, 0x34, 0x9B, 0xAA])        // G 8500, 39850
        #expect(Array(bytes[12..<16]) == [0x3D, 0x13, 0x40, 0x42])      // white point 15635, 16450
        #expect(Array(bytes[16..<20]) == [0x00, 0x76, 0x8F, 0x90])      // 777 nit = 7_770_000
        #expect(Array(bytes[20..<24]) == [0x00, 0x00, 0x00, 0x32])      // 0.005 nit = 50
        #expect(HDR10StaticMetadata.describe(masteringDisplayColorVolume: Data(bytes)) == "peak 777 min 0.0050")
    }

    @Test
    func issue957ContentLightLevelBytesAreMaxCLLThenMaxFALL() {
        let data = HDR10StaticMetadata.probeDefault.contentLightLevel
        #expect([UInt8](data) == [0x01, 0x59, 0x00, 0x7B])
        #expect(HDR10StaticMetadata.describe(contentLightLevel: data) == "345/123")
        #expect(HDR10StaticMetadata.describe(contentLightLevel: Data([1, 2])) == nil)
    }

    // MARK: Buffers

    /// What the renderer hands the display layer is a format description made from the buffer, so the
    /// metadata has to survive `CMVideoFormatDescriptionCreateForImageBuffer`.
    @Test
    func issue957FormatDescriptionCarriesTheAttachedMetadata() throws {
        let buffer = try ProbeFrames.pq(64, 36)
        let meta = HDR10StaticMetadata.probeDefault
        CVBufferSetAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey,
                              meta.masteringDisplayColorVolume as CFData, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, meta.contentLightLevel as CFData,
                              .shouldPropagate)
        #expect(HDR10ProbeStage.describeFormatDescription(of: buffer) == "mdcv=peak 777 min 0.0050 cll=345/123")
    }

    @Test
    func issue957LogModeChangesNothing() throws {
        let buffer = try ProbeFrames.pq(64, 36)
        let stage = HDR10ProbeStage(settings: HDR10ProbeSettings(mode: .log, metadata: .probeDefault))
        #expect(stage.process(buffer, pts: .zero) == nil)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) == nil)
    }

    @Test
    func issue957MetaModeTagsTheDecodersBuffer() throws {
        let buffer = try ProbeFrames.pq(64, 36, sourceCLL: Data([0x03, 0xE8, 0x01, 0x90]))
        let stage = HDR10ProbeStage(settings: HDR10ProbeSettings(mode: .meta, metadata: .probeDefault))
        // nil delivers the input, which now carries the probe's values in place of the source's.
        #expect(stage.process(buffer, pts: .zero) == nil)
        let cll = CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) as? Data
        #expect(HDR10StaticMetadata.describe(contentLightLevel: cll) == "345/123")
        let pq = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        #expect(HDR10ProbeStage.describe(buffer).contains("tf=\(pq)"))
    }

    @Test
    func issue957CopiedAttachmentsLeaveTheGeometryKeysBehind() throws {
        let input = try ProbeFrames.pq(64, 36, sourceCLL: Data([0x03, 0xE8, 0x01, 0x90]))
        let aperture: [String: Any] = [kCVImageBufferCleanApertureWidthKey as String: 60,
                                       kCVImageBufferCleanApertureHeightKey as String: 34]
        CVBufferSetAttachment(input, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldPropagate)
        let output = try ProbeFrames.pq(60, 34)
        HDR10ProbeStage.copyAttachments(from: input, to: output)
        #expect(CVBufferCopyAttachment(output, kCVImageBufferCleanApertureKey, nil) == nil)
        #expect(CVBufferCopyAttachment(output, kCVImageBufferContentLightLevelInfoKey, nil) as? Data
                == Data([0x03, 0xE8, 0x01, 0x90]))
        #expect(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String
                == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
    }
}

#if !targetEnvironment(simulator)
private enum ProbeChainGate {
    static var gpuAvailable: Bool {
        guard #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *) else { return false }
        return MTLCreateSystemDefaultDevice() != nil
    }
}

/// The chain modes on a 10-bit PQ frame: the pixels come back as they were (the pass-through stage does
/// no transfer handling, so PQ codes survive as codes) in a buffer of our own, with the decoder's tags.
/// Five minutes like "Frame chain": on a CI runner both suites compile their kernels on one shared GPU, and
/// the first case of each took about 5 minutes there with every trait on.
@Suite("HDR10 pass-through probe, chain", .serialized, .offCooperativePoolOneLane, .timeLimit(.minutes(5)),
       .enabled(if: ProbeChainGate.gpuAvailable))
struct HDR10PassThroughProbeChainTests {

    @Test(arguments: [HDR10ProbeSettings.Mode.chain, .chainMeta])
    func issue957ChainKeepsThePQFrameAndItsTags(mode: HDR10ProbeSettings.Mode) throws {
        let input = try ProbeFrames.pq(320, 180, sourceCLL: Data([0x03, 0xE8, 0x01, 0x90]))
        let stage = HDR10ProbeStage(settings: HDR10ProbeSettings(mode: mode, metadata: .probeDefault))
        let output = try #require(stage.process(input, pts: .zero))
        #expect(output !== input)
        #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        let diff = ProbeFrames.maxDifference(input, output)
        #expect(diff.y <= 1 && diff.c <= 1, "max difference Y \(diff.y), C \(diff.c)")
        #expect(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String
                == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        let cll = HDR10StaticMetadata.describe(
            contentLightLevel: CVBufferCopyAttachment(output, kCVImageBufferContentLightLevelInfoKey, nil) as? Data)
        #expect(cll == (mode == .chainMeta ? "345/123" : "1000/400"))
    }
}
#endif

/// 10-bit (x420) BT.2020 PQ video-range frames with a luma ramp from about 0.15 to 1600 nit.
private enum ProbeFrames {
    struct Failure: Error {}

    static func pq(_ w: Int, _ h: Int, sourceCLL: Data? = nil) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { throw Failure() }
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                              .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        if let sourceCLL {
            CVBufferSetAttachment(pb, kCVImageBufferContentLightLevelInfoKey, sourceCLL as CFData, .shouldPropagate)
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            let pw = CVPixelBufferGetWidthOfPlane(pb, plane), ph = CVPixelBufferGetHeightOfPlane(pb, plane)
            for row in 0..<ph {
                let line = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<pw {
                    if plane == 0 {
                        // 128...768 is about 0.15 to 1600 nit in PQ. It starts above black because the chain
                        // clamps RGB to 0...1, and the chroma below on black luma would be a negative green.
                        line[x] = UInt16(128 + x * 640 / max(w - 1, 1)) << 6
                    } else {
                        line[2 * x] = UInt16(500 + row * 24 / max(ph - 1, 1)) << 6
                        line[2 * x + 1] = UInt16(524 - x * 24 / max(pw - 1, 1)) << 6
                    }
                }
            }
        }
        return pb
    }

    /// Largest difference in 10-bit code values between two same-size x420 buffers, luma and chroma.
    static func maxDifference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (y: Int, c: Int) {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        var result = [0, 0]
        for plane in 0..<2 {
            let pa = CVPixelBufferGetBaseAddressOfPlane(a, plane)!, pb = CVPixelBufferGetBaseAddressOfPlane(b, plane)!
            let sa = CVPixelBufferGetBytesPerRowOfPlane(a, plane), sb = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
            let samples = CVPixelBufferGetWidthOfPlane(a, plane) * (plane == 0 ? 1 : 2)
            for row in 0..<CVPixelBufferGetHeightOfPlane(a, plane) {
                let la = pa.advanced(by: row * sa).assumingMemoryBound(to: UInt16.self)
                let lb = pb.advanced(by: row * sb).assumingMemoryBound(to: UInt16.self)
                for i in 0..<samples {
                    result[plane] = max(result[plane], abs(Int(la[i] >> 6) - Int(lb[i] >> 6)))
                }
            }
        }
        return (result[0], result[1])
    }
}
