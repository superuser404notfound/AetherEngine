// Only with the DolbyVisionFelCurves trait (off by default).
#if DolbyVisionFelCurves
import CoreVideo
import Foundation

/// Draws the fit's luma samples from one decoded picture pair: the base layer (full resolution) and the
/// enhancement layer (its own grid, a quarter of the pixels for every UHD Blu-ray surveyed).
///
/// Positions are drawn on the enhancement layer's luma grid, which is where its residual is coded, and the
/// base layer's luma is averaged over the block of pixels one enhancement-layer pixel covers. Every position
/// counts, the darkest included: a dark title's enhancement layer does most of its work there, and letterbox
/// bars, which carry no residual, only hold the curve's foot where it already is.
enum FelCurveSampler {
    static let defaultCount = 100_000

    static func samples(base: CVPixelBuffer, enhancement: CVPixelBuffer, nlq: FelNlq, elBits: Int,
                        count: Int = defaultCount, seed: UInt64 = 0x5EED) -> FelCurveSamples? {
        guard let bl = Planes(base), let el = Planes(enhancement) else { return nil }
        defer { bl.unlock(); el.unlock() }
        guard el.width > 1, el.height > 1, bl.width >= el.width, bl.height >= el.height,
              bl.width % el.width == 0, bl.height % el.height == 0 else { return nil }
        let rx = bl.width / el.width, ry = bl.height / el.height
        let table = nlq.table(elBits: elBits)
        let elMask = (1 << elBits) - 1

        var out = FelCurveSamples()
        out.base.reserveCapacity(count)
        out.residual.reserveCapacity(count)
        var state = seed
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
        for _ in 0..<count {
            let x = next() % el.width
            let y = next() % el.height
            var sum = 0
            for dy in 0..<ry {
                for dx in 0..<rx { sum += bl.luma(x * rx + dx, y * ry + dy) }
            }
            out.base.append(Float(sum) / Float(rx * ry))
            out.residual.append(Float(table[el.luma(x, y) & elMask]))
        }
        return out
    }

    /// A locked bi-planar 4:2:0 buffer with 16-bit samples holding 10 significant bits at the top (P010).
    private struct Planes {
        let buffer: CVPixelBuffer
        let width: Int, height: Int
        let y: UnsafeRawPointer
        let yStride: Int

        init?(_ buffer: CVPixelBuffer) {
            let format = CVPixelBufferGetPixelFormatType(buffer)
            guard format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange else { return nil }
            guard CVPixelBufferGetPlaneCount(buffer) == 2,
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
            guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                return nil
            }
            self.buffer = buffer
            self.y = UnsafeRawPointer(y)
            width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        }

        func unlock() { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        func luma(_ x: Int, _ yy: Int) -> Int {
            Int(y.load(fromByteOffset: yy * yStride + x * 2, as: UInt16.self) >> 6)
        }
    }
}
#endif
