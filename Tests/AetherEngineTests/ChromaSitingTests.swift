import Foundation
import Testing
import CoreVideo
import Metal
@testable import AetherEngine

/// The scalers read 4:2:0 chroma where the buffer's tag puts it and write it back there. They used to
/// treat every frame as centre-sited, so left-sited chroma (the H.264 and HEVC default) landed half a target
/// sample off at 2x: a colour edge beside its luma edge.
@Suite("Chroma siting", .timeLimit(.minutes(3)))
struct ChromaSitingTests {

    @Test func sitingFollowsTheBufferTag() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        let buffer = try #require(pb)
        #expect(ChromaSiting.of(buffer) == .left, "untagged")
        let cases: [(CFString, ChromaSiting)] = [
            (kCVImageBufferChromaLocation_Left, .left), (kCVImageBufferChromaLocation_Center, .center),
            (kCVImageBufferChromaLocation_TopLeft, .topLeft), (kCVImageBufferChromaLocation_Top, .top),
            (kCVImageBufferChromaLocation_BottomLeft, .bottomLeft), (kCVImageBufferChromaLocation_Bottom, .bottom),
            (kCVImageBufferChromaLocation_DV420, .left),
        ]
        for (tag, siting) in cases {
            CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, tag, .shouldPropagate)
            #expect(ChromaSiting.of(buffer) == siting, "\(tag)")
        }
    }

    /// A ramp over the chroma samples, scaled 2x on its own with the siting's offset: each output sample
    /// reads the ramp at its own position in the picture. Left-sited chroma sample i sits on luma 2i, and
    /// output chroma o on target luma 2o, which is source luma o - 0.25, so chroma index o / 2 - 0.125.
    @Test func sitedLanczosTapsReadTheirOwnPosition() throws {
        let ramp = (0..<64).map(Double.init)
        let left = try #require(LanczosTaps(inputCount: 64, outputCount: 128, offset: ChromaSiting.left.chromaOffset.x))
        let centred = try #require(LanczosTaps(inputCount: 64, outputCount: 128))
        let l = left.apply(ramp), c = centred.apply(ramp)
        // Lanczos-3 follows a ramp to within about 0.02 samples; the two sitings are 0.125 apart.
        for o in 20..<100 {
            #expect(abs(l[o] - (Double(o) / 2 - 0.125)) < 0.03, "left \(o): \(l[o])")
            #expect(abs(c[o] - (Double(o) / 2 - 0.25)) < 0.03, "centre \(o): \(c[o])")
        }
    }
}

#if !targetEnvironment(simulator)
private enum SitingGate {
    static var gpuAvailable: Bool {
        guard #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *) else { return false }
        return MTLCreateSystemDefaultDevice() != nil
    }
}

/// A Cb ramp that crosses its midpoint at source luma position 31 (on the axis under test), through each
/// scaler at 2x: the crossing must come out at target luma 62.5 for every siting, which is where the
/// picture put it. 10-bit, so a code is a sixteenth of a source sample on the ramp.
@Suite("Chroma siting on the GPU", .serialized, .offCooperativePoolOneLane, .timeLimit(.minutes(3)),
       .enabled(if: SitingGate.gpuAvailable))
struct ChromaSitingGPUTests {

    enum Scaler: String, CaseIterable { case lanczos, chain }

    @Test(arguments: Scaler.allCases, [ChromaSiting.left, .center, .topLeft, .bottom])
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func chromaLandsWhereThePictureHasIt(scaler: Scaler, siting: ChromaSiting) throws {
        for vertical in [false, true] {
            let input = try Self.ramp(64, 64, siting: siting, vertical: vertical)
            let device = try #require(MTLCreateSystemDefaultDevice())
            let queue = try #require(device.makeCommandQueue())
            let picture = FrameUpscaler.PictureRegion(x: 0, y: 0, width: 64, height: 64)
            let out: CVPixelBuffer
            switch scaler {
            case .lanczos:
                let s = try LanczosPlaneScaler(device: device, queue: queue, sourceWidth: 64, sourceHeight: 64,
                                               targetWidth: 128, targetHeight: 128)
                let (o, work) = try s.encode(input, picture: picture)
                work.commandBuffer.commit()
                work.commandBuffer.waitUntilCompleted()
                _ = try work.finish()
                out = o
            case .chain:
                let chain = try FrameChain(device: device, queue: queue, sourceWidth: 64, sourceHeight: 64,
                                           targetWidth: 128, targetHeight: 128, stages: [PassThroughStage()])
                out = try chain.process(input, picture: picture).0
            }
            let crossing = try #require(Self.cbCrossing(out, siting: siting, vertical: vertical))
            #expect(abs(crossing - 62.5) < 0.15,
                    "\(scaler) \(siting) \(vertical ? "vertical" : "horizontal"): Cb crosses at \(crossing)")
        }
    }

    /// The same-size round trip reads a sited sample exactly and writes it back from the same spot, so hard
    /// chroma comes back. Read as centred, every sample came back blurred with its neighbours.
    @Test(arguments: [ChromaSiting.left, .topLeft])
    @available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
    func roundTripGivesHardChromaBack(siting: ChromaSiting) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        for fuses in [true, false] {
            let input = try Self.buffer(64, 32, siting: siting)
            let alongY = siting.y != 0.5
            Self.fill(input, y: { _, _ in 126 * 4 }, c: { i, j in
                let odd = (i % 2 == 1) != (alongY && j % 2 == 1)
                return odd ? (104 * 4, 150 * 4) : (152 * 4, 106 * 4)
            })
            let chain = try FrameChain(device: device, queue: queue, sourceWidth: 64, sourceHeight: 32,
                                       targetWidth: 64, targetHeight: 32, stages: [PassThroughStage()],
                                       fusesRoundTrip: fuses)
            let out = try chain.process(input, picture: FrameUpscaler.PictureRegion(x: 0, y: 0, width: 64, height: 32)).0
            let a = Self.chroma(input), b = Self.chroma(out)
            let diff = zip(a, b).map { abs($0 - $1) }.max() ?? .max
            #expect(diff <= 2, "\(siting) fused \(fuses): chroma off by \(diff) codes (10-bit)")
        }
    }

    private static func buffer(_ w: Int, _ h: Int, siting: ChromaSiting) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { throw CocoaError(.fileNoSuchFile) }
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let tags: [(ChromaSiting, CFString)] = [
            (.left, kCVImageBufferChromaLocation_Left), (.center, kCVImageBufferChromaLocation_Center),
            (.topLeft, kCVImageBufferChromaLocation_TopLeft), (.bottom, kCVImageBufferChromaLocation_Bottom),
        ]
        if let tag = tags.first(where: { $0.0 == siting })?.1 {
            CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, tag, .shouldPropagate)
        }
        return pb
    }

    /// Flat luma; Cb a ramp of 16 codes per source luma sample through 512 at position 31, read at each
    /// chroma sample's own position; Cr neutral.
    private static func ramp(_ w: Int, _ h: Int, siting: ChromaSiting, vertical: Bool) throws -> CVPixelBuffer {
        let pb = try buffer(w, h, siting: siting)
        fill(pb, y: { _, _ in 126 * 4 }, c: { i, j in
            let pos = vertical ? 2 * Double(j) + Double(siting.y) : 2 * Double(i) + Double(siting.x)
            return (Int(min(max(512 + (pos - 31) * 16, 400), 624)), 512)
        })
        return pb
    }

    /// 10-bit codes: `y(x, row)` per luma sample, `c(i, j)` per chroma sample.
    private static func fill(_ pb: CVPixelBuffer, y: (Int, Int) -> Int, c: (Int, Int) -> (Int, Int)) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(pb, plane) {
                let p = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<CVPixelBufferGetWidthOfPlane(pb, plane) {
                    if plane == 0 {
                        p[x] = UInt16(y(x, row)) << 6
                    } else {
                        let v = c(x, row)
                        p[2 * x] = UInt16(v.0) << 6
                        p[2 * x + 1] = UInt16(v.1) << 6
                    }
                }
            }
        }
    }

    /// Every Cb and Cr code of the chroma plane, row by row.
    private static func chroma(_ pb: CVPixelBuffer) -> [Int] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        var out: [Int] = []
        for row in 0..<CVPixelBufferGetHeightOfPlane(pb, 1) {
            let p = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
            for i in 0..<(CVPixelBufferGetWidthOfPlane(pb, 1) * 2) { out.append(Int(p[i] >> 6)) }
        }
        return out
    }

    /// Where Cb crosses 512 along the middle row (or column) of the output, in target luma samples: output
    /// chroma sample o sits on target luma 2o plus the siting.
    private static func cbCrossing(_ pb: CVPixelBuffer, siting: ChromaSiting, vertical: Bool) -> Double? {
        let cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1)
        let all = chroma(pb)
        let n = vertical ? ch : cw
        let line = (0..<n).map { k in Double(vertical ? all[(k * cw + cw / 2) * 2] : all[((ch / 2) * cw + k) * 2]) }
        for o in 0..<(n - 1) where line[o] < 512 && line[o + 1] >= 512 {
            let frac = (512 - line[o]) / (line[o + 1] - line[o])
            return 2 * (Double(o) + frac) + Double(vertical ? siting.y : siting.x)
        }
        return nil
    }
}
#endif
