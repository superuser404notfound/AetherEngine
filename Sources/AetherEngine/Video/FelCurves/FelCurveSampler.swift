// Only with the DolbyVisionFelCurves trait (off by default).
#if DolbyVisionFelCurves
import CoreVideo
import Foundation

/// Draws the fit's samples from one decoded picture pair: the base layer (full resolution) and the
/// enhancement layer (its own grid, a quarter of the pixels for every UHD Blu-ray surveyed).
///
/// Positions are drawn on the enhancement layer's luma grid, which is where its residual is coded.
/// The base layer's luma is averaged over the block of pixels one enhancement-layer pixel covers, and
/// chroma is read from both layers' chroma planes at the matching place. Letterbox bars (base-layer luma
/// at or below `blackLevel`) are skipped, since the bars stay black whatever a curve does.
enum FelCurveSampler {
    static let defaultCount = 100_000
    static let blackLevel: Float = 70

    static func samples(base: CVPixelBuffer, enhancement: CVPixelBuffer, nlq: [FelNlq], elBits: Int,
                        count: Int = defaultCount, seed: UInt64 = 0x5EED) -> FelCurveSamples? {
        guard let bl = Planes(base), let el = Planes(enhancement) else { return nil }
        defer { bl.unlock(); el.unlock() }
        guard el.width > 1, el.height > 1, bl.width >= el.width, bl.height >= el.height,
              bl.width % el.width == 0, bl.height % el.height == 0, nlq.count == 3 else { return nil }
        let rx = bl.width / el.width, ry = bl.height / el.height
        let tables = nlq.map { $0.table(elBits: elBits) }
        let elMask = (1 << elBits) - 1

        var out = FelCurveSamples()
        for c in 0..<3 {
            out.base[c].reserveCapacity(count)
            out.residual[c].reserveCapacity(count)
        }
        var state = seed
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
        var attempts = 0
        while out.count < count, attempts < count * 4 {
            attempts += 1
            let x = next() % el.width
            let y = next() % el.height

            var sum = 0
            for dy in 0..<ry {
                for dx in 0..<rx { sum += bl.luma(x * rx + dx, y * ry + dy) }
            }
            let baseY = Float(sum) / Float(rx * ry)
            if baseY <= blackLevel { continue }

            // Chroma: the base layer's chroma grid is half its luma grid, the enhancement layer's likewise.
            let bcx = min((x * rx) / 2, bl.width / 2 - 1), bcy = min((y * ry) / 2, bl.height / 2 - 1)
            let ecx = min(x / 2, el.width / 2 - 1), ecy = min(y / 2, el.height / 2 - 1)
            let baseCb = bl.chroma(bcx, bcy, 0), baseCr = bl.chroma(bcx, bcy, 1)
            let elY = el.luma(x, y) & elMask, elCb = el.chroma(ecx, ecy, 0) & elMask, elCr = el.chroma(ecx, ecy, 1) & elMask

            out.base[0].append(baseY)
            out.base[1].append(Float(baseCb))
            out.base[2].append(Float(baseCr))
            out.residual[0].append(Float(tables[0][elY]))
            out.residual[1].append(Float(tables[1][elCb]))
            out.residual[2].append(Float(tables[2][elCr]))
        }
        return out.count >= 1000 ? out : nil
    }

    /// A locked bi-planar 4:2:0 buffer with 16-bit samples holding 10 significant bits at the top (P010)
    /// or 8-bit samples.
    private struct Planes {
        let buffer: CVPixelBuffer
        let width: Int, height: Int
        let y: UnsafeRawPointer, uv: UnsafeRawPointer
        let yStride: Int, uvStride: Int
        let wide: Bool

        init?(_ buffer: CVPixelBuffer) {
            let format = CVPixelBufferGetPixelFormatType(buffer)
            switch format {
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
                wide = true
            default:
                return nil
            }
            guard CVPixelBufferGetPlaneCount(buffer) == 2,
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
            guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                return nil
            }
            self.buffer = buffer
            self.y = UnsafeRawPointer(y)
            self.uv = UnsafeRawPointer(uv)
            width = CVPixelBufferGetWidthOfPlane(buffer, 0)
            height = CVPixelBufferGetHeightOfPlane(buffer, 0)
            yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        }

        func unlock() { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        func luma(_ x: Int, _ yy: Int) -> Int {
            Int(y.load(fromByteOffset: yy * yStride + x * 2, as: UInt16.self) >> 6)
        }

        func chroma(_ x: Int, _ yy: Int, _ c: Int) -> Int {
            Int(uv.load(fromByteOffset: yy * uvStride + x * 4 + c * 2, as: UInt16.self) >> 6)
        }
    }
}
#endif
