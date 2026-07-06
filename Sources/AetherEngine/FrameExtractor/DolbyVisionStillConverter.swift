import Foundation
import CoreGraphics
import Libavutil

/// Converts a decoded Dolby Vision Profile 5 / Profile 10.0 base-layer frame (which is
/// IPT-PQ-C2, NOT standard YCbCr) into an SDR sRGB image by applying the Dolby Vision
/// colour transform carried in the RPU. Without this the base-layer planes are read as
/// BT.2020 YCbCr and produce the characteristic green + magenta cast (AetherEngine #103).
///
/// The per-component reshaping curves are intentionally skipped (validated against a libplacebo
/// render: reshaping does not drive the visible corruption, and skipping it keeps this a small
/// CPU pass rather than a full Dolby Vision compositor). Highlights and shadows are brought to
/// SDR with a hue-preserving BT.2390 EETF (`ToneCurve`) anchored on the RPU source PQ range, so
/// the curve adapts to each clip's mastering envelope. This replaced a fixed-exposure per-channel
/// Hable tone-map that mapped 100-nit diffuse white to mid-gray and crushed normally-lit content
/// (validated too dark, 24-79% of a libplacebo reference luminance; #103 follow-up). If a frame
/// carries no DV metadata the converter returns nil so the caller falls back to the standard path.
enum DolbyVisionStillConverter {

    /// BT.2020 LMS -> RGB (Hunt-Pointer-Estevez, no crosstalk), applied after the RPU
    /// rgb_to_lms matrix. Constant from libplacebo's Dolby Vision path.
    private static let lms2rgb: [Double] = [
         3.06441879, -2.16597676,  0.10155818,
        -0.65612108,  1.78554118, -0.12943749,
         0.01736321, -0.04725154,  1.03004253,
    ]

    /// Linear BT.2020 -> BT.709 gamut conversion.
    private static let bt2020to709: [Double] = [
         1.660491, -0.587641, -0.072850,
        -0.124550,  1.132900, -0.008349,
        -0.018151, -0.100579,  1.118730,
    ]

    /// Returns an SDR sRGB CGImage for a DV P5/P10.0 frame, or nil when the frame lacks
    /// AV_FRAME_DATA_DOVI_METADATA, is not 10-bit 4:2:0, or has zero dimensions.
    static func makeImage(
        frame: UnsafeMutablePointer<AVFrame>,
        targetWidth: Int,
        sar: AVRational
    ) -> CGImage? {
        // Only the 10-bit planar 4:2:0 base layer is handled; anything else falls back.
        let fmt = AVPixelFormat(rawValue: frame.pointee.format)
        guard fmt == AV_PIX_FMT_YUV420P10LE else { return nil }

        guard let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA),
              let metaRaw = sd.pointee.data else { return nil }
        let base = UnsafeRawPointer(metaRaw)
        let meta = base.assumingMemoryBound(to: AVDOVIMetadata.self)

        // av_dovi_get_header / _color are static-inline (not importable); resolve via offsets.
        let header = base.advanced(by: Int(meta.pointee.header_offset))
            .assumingMemoryBound(to: AVDOVIRpuDataHeader.self)
        let color = base.advanced(by: Int(meta.pointee.color_offset))
            .assumingMemoryBound(to: AVDOVIColorMetadata.self)

        let bitDepth = Int(header.pointee.bl_bit_depth)
        let maxVal = Double((1 << bitDepth) - 1)
        guard maxVal > 0 else { return nil }

        var colorMeta = color.pointee
        var nonlinear = [Double](repeating: 0, count: 9)  // ycc_to_rgb (before PQ)
        var rgb2lms = [Double](repeating: 0, count: 9)     // rgb_to_lms (after PQ)
        var offset = [Double](repeating: 0, count: 3)      // input offset of neutral value
        withUnsafeBytes(of: &colorMeta.ycc_to_rgb_matrix) { raw in
            let a = raw.bindMemory(to: AVRational.self)
            for i in 0..<9 { nonlinear[i] = q2d(a[i]) }
        }
        withUnsafeBytes(of: &colorMeta.rgb_to_lms_matrix) { raw in
            let a = raw.bindMemory(to: AVRational.self)
            for i in 0..<9 { rgb2lms[i] = q2d(a[i]) }
        }
        withUnsafeBytes(of: &colorMeta.ycc_to_rgb_offset) { raw in
            let a = raw.bindMemory(to: AVRational.self)
            for i in 0..<3 { offset[i] = q2d(a[i]) }
        }
        // PQ-linearised LMS -> linear BT.2020 RGB in one matrix.
        let combined = matMul(lms2rgb, rgb2lms)

        let srcW = Int(frame.pointee.width)
        let srcH = Int(frame.pointee.height)
        guard srcW > 0, srcH > 0,
              let yPlane = frame.pointee.data.0,
              let uPlane = frame.pointee.data.1,
              let vPlane = frame.pointee.data.2 else { return nil }
        let yls = Int(frame.pointee.linesize.0) / 2
        let uls = Int(frame.pointee.linesize.1) / 2
        let vls = Int(frame.pointee.linesize.2) / 2
        let yp = UnsafeRawPointer(yPlane).assumingMemoryBound(to: UInt16.self)
        let up = UnsafeRawPointer(uPlane).assumingMemoryBound(to: UInt16.self)
        let vp = UnsafeRawPointer(vPlane).assumingMemoryBound(to: UInt16.self)

        let (dstW, dstH) = FrameDecodeContext.displayDimensions(
            srcW: srcW, srcH: srcH, sar: sar,
            targetWidth: targetWidth > 0 ? targetWidth : srcW)
        guard dstW > 0, dstH > 0 else { return nil }

        // Static per-clip tone curve, anchored on the RPU source PQ range (the mastering
        // envelope). Matches libplacebo's canonical BT.2390 static mapping (within <1/255).
        let tone = ToneCurve(srcMinPQ: Double(colorMeta.source_min_pq) / 4095.0,
                             srcMaxPQ: Double(colorMeta.source_max_pq) / 4095.0)

        let bytesPerRow = dstW * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * dstH)
        rgba.withUnsafeMutableBufferPointer { out in
            for oy in 0..<dstH {
                let sy = min(srcH - 1, oy * srcH / dstH)
                let cy = sy / 2
                for ox in 0..<dstW {
                    let sx = min(srcW - 1, ox * srcW / dstW)
                    let cx = sx / 2
                    // Base-layer signal (I, Ct, Cp) normalised to [0,1]. Reshaping skipped.
                    let sig0 = Double(yp[sy * yls + sx]) / maxVal - offset[0]
                    let sig1 = Double(up[cy * uls + cx]) / maxVal - offset[1]
                    let sig2 = Double(vp[cy * vls + cx]) / maxVal - offset[2]
                    // ycc_to_rgb in the nonlinear (PQ) domain.
                    let r0 = nonlinear[0] * sig0 + nonlinear[1] * sig1 + nonlinear[2] * sig2
                    let g0 = nonlinear[3] * sig0 + nonlinear[4] * sig1 + nonlinear[5] * sig2
                    let b0 = nonlinear[6] * sig0 + nonlinear[7] * sig1 + nonlinear[8] * sig2
                    // PQ EOTF -> linear (1.0 == 10000 nits).
                    let lr = pqEOTF(r0), lg = pqEOTF(g0), lb = pqEOTF(b0)
                    // (lms2rgb * rgb_to_lms) -> linear BT.2020 RGB (1.0 == 10000 nits).
                    let rr0 = combined[0] * lr + combined[1] * lg + combined[2] * lb
                    let gg0 = combined[3] * lr + combined[4] * lg + combined[5] * lb
                    let bb0 = combined[6] * lr + combined[7] * lg + combined[8] * lb
                    // Hue-preserving BT.2390 tone-map: tone-map scene luminance and scale RGB by the
                    // same factor, so chroma ratios (hue + saturation) survive. Per-channel tone-mapping
                    // (the old path) shifted hue and distorted saturated highlights.
                    let y = 0.2627 * rr0 + 0.6780 * gg0 + 0.0593 * bb0   // BT.2020 luma
                    let yd = tone.map(y)
                    let scale = y > 1e-6 ? yd / y : 0
                    var rr = rr0 * scale
                    var gg = gg0 * scale
                    var bb = bb0 * scale
                    // Highlight desaturation: if a channel overshoots the display range, blend toward
                    // the target luminance so the peak channel lands exactly at 1.0. Trades saturation
                    // to stay in gamut instead of clipping (matches libplacebo's tone-map desaturation;
                    // without it saturated highlights blow out, e.g. ~50% clipped on bright scenes).
                    let m = max(rr, max(gg, bb))
                    if m > 1.0 && m > yd {
                        let t = (m - 1.0) / (m - yd)
                        rr += (yd - rr) * t
                        gg += (yd - gg) * t
                        bb += (yd - bb) * t
                    }
                    // BT.2020 -> BT.709.
                    let r7 = bt2020to709[0] * rr + bt2020to709[1] * gg + bt2020to709[2] * bb
                    let g7 = bt2020to709[3] * rr + bt2020to709[4] * gg + bt2020to709[5] * bb
                    let b7 = bt2020to709[6] * rr + bt2020to709[7] * gg + bt2020to709[8] * bb
                    let o = oy * bytesPerRow + ox * 4
                    out[o + 0] = u8(srgbOETF(r7))
                    out[o + 1] = u8(srgbOETF(g7))
                    out[o + 2] = u8(srgbOETF(b7))
                    out[o + 3] = 0xFF
                }
            }
        }

        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        return CGImage(
            width: dstW, height: dstH,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - Math

    static func q2d(_ r: AVRational) -> Double {
        r.den != 0 ? Double(r.num) / Double(r.den) : 0
    }

    /// O = A * B for row-major 3x3 matrices.
    static func matMul(_ a: [Double], _ b: [Double]) -> [Double] {
        var o = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                o[r * 3 + c] = a[r * 3 + 0] * b[0 * 3 + c]
                    + a[r * 3 + 1] * b[1 * 3 + c]
                    + a[r * 3 + 2] * b[2 * 3 + c]
            }
        }
        return o
    }

    /// SMPTE ST 2084 (PQ) EOTF. Input is a normalised PQ code [0,1]; output is linear
    /// where 1.0 corresponds to 10000 nits.
    static func pqEOTF(_ e: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375
        let c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let ec = max(e, 0)
        let ep = pow(ec, 1.0 / m2)
        let num = max(ep - c1, 0)
        let den = max(c2 - c3 * ep, 1e-6)
        return pow(num / den, 1.0 / m1)
    }

    /// Inverse of `pqEOTF`: scene-linear (1.0 == 10000 nits) -> normalised PQ code [0,1].
    static func pqOETF(_ l: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375
        let c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let lm = pow(max(l, 0), m1)
        return pow((c1 + c2 * lm) / (1 + c3 * lm), m2)
    }

    /// BT.2390 EETF tone-mapping to an SDR display, anchored on the Dolby Vision RPU source PQ
    /// range so the curve adapts to each clip's mastering envelope. `map` takes scene-linear
    /// luminance (1.0 == 10000 nits) and returns SDR-linear luminance [0,1] (1.0 == 100-nit
    /// diffuse white). Applied to luminance and used as a uniform RGB scale (hue-preserving).
    struct ToneCurve {
        private let srcMin: Double
        private let rng: Double
        private let maxLum: Double
        private let minLum: Double
        private let ks: Double

        /// Target SDR display: 100-nit diffuse white; a near-zero black keeps shadow detail.
        private static let dstWhiteLinear = 100.0 / 10000.0

        init(srcMinPQ: Double, srcMaxPQ: Double) {
            let lo = min(max(srcMinPQ, 0), 1)
            // Guard degenerate / unpopulated ranges (e.g. source_max_pq == 0): assume a 1000-nit master.
            var hi = min(max(srcMaxPQ, 0), 1)
            if hi <= lo + 1e-4 { hi = DolbyVisionStillConverter.pqOETF(1000.0 / 10000.0) }
            srcMin = lo
            rng = hi - lo
            let dstMax = DolbyVisionStillConverter.pqOETF(Self.dstWhiteLinear)
            let dstMin = DolbyVisionStillConverter.pqOETF(0.05 / 10000.0)
            maxLum = min(max((dstMax - lo) / (hi - lo), 0), 1)
            minLum = max((dstMin - lo) / (hi - lo), 0)
            // Knee point. The ITU BT.2390 spec value (1.5*maxLum - 0.5) maps mid-tones ~35/255
            // too bright vs the de-facto reference (libplacebo). This slope/offset was fit to
            // libplacebo's static BT.2390 curve and matches it within <1/255 across all realistic
            // mastering peaks (600-10000 nits).
            ks = min(max(1.982 * (maxLum - 0.5), 0), maxLum)
        }

        /// scene-linear luminance -> SDR-linear luminance [0,1].
        func map(_ sceneLuma: Double) -> Double {
            let x = DolbyVisionStillConverter.pqOETF(sceneLuma)
            var e = min(max((x - srcMin) / rng, 0), 1)
            // BT.2390 Hermite knee above KS; identity below (and when source peak <= display peak).
            if e > ks && ks < 1.0 {
                let t = (e - ks) / (1 - ks)
                let t2 = t * t, t3 = t2 * t
                e = (2 * t3 - 3 * t2 + 1) * ks
                  + (t3 - 2 * t2 + t) * (1 - ks)
                  + (-2 * t3 + 3 * t2) * maxLum
            }
            // BT.2390 black-point lift: raise the floor toward display min without milking mids.
            e += minLum * pow(1 - e, 4)
            let outPQ = e * rng + srcMin
            return DolbyVisionStillConverter.pqEOTF(outPQ) / Self.dstWhiteLinear
        }
    }

    static func srgbOETF(_ x: Double) -> Double {
        let v = min(max(x, 0), 1)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    private static func u8(_ x: Double) -> UInt8 {
        UInt8(min(max(x, 0), 1) * 255.0 + 0.5)
    }
}
