import Testing
import Libavutil
@testable import AetherEngine

/// Deterministic checks for the Dolby Vision Profile 5 still-colour primitives (#103).
/// End-to-end colour correctness is validated on device / against a libplacebo reference;
/// these guard the pure math (PQ EOTF, sRGB OETF, matrix multiply, tone-map) from regressing.
struct DolbyVisionColorTests {

    @Test("PQ EOTF anchors: 0 -> 0, 1 -> 1, monotonic")
    func pqEOTFAnchors() {
        #expect(DolbyVisionStillConverter.pqEOTF(0) == 0)
        #expect(abs(DolbyVisionStillConverter.pqEOTF(1.0) - 1.0) < 1e-6)
        // Monotonically increasing across the code range.
        var prev = -1.0
        for i in 0...20 {
            let v = DolbyVisionStillConverter.pqEOTF(Double(i) / 20.0)
            #expect(v >= prev, "PQ EOTF not monotonic at \(i)")
            prev = v
        }
        // Negative codes clamp to 0.
        #expect(DolbyVisionStillConverter.pqEOTF(-0.5) == 0)
    }

    @Test("sRGB OETF anchors")
    func srgbAnchors() {
        #expect(DolbyVisionStillConverter.srgbOETF(0) == 0)
        #expect(abs(DolbyVisionStillConverter.srgbOETF(1.0) - 1.0) < 1e-9)
        #expect(abs(DolbyVisionStillConverter.srgbOETF(0.5) - 0.7353569) < 1e-4)
        // Out-of-range clamps.
        #expect(DolbyVisionStillConverter.srgbOETF(-1) == 0)
        #expect(abs(DolbyVisionStillConverter.srgbOETF(2) - 1.0) < 1e-9)
    }

    @Test("3x3 matrix multiply: identity and known product")
    func matrixMultiply() {
        let ident: [Double] = [1,0,0, 0,1,0, 0,0,1]
        let m: [Double] = [1,2,3, 4,5,6, 7,8,9]
        let im = DolbyVisionStillConverter.matMul(ident, m)
        for i in 0..<9 { #expect(im[i] == m[i]) }
        // [[1,2],[3,4]] style: A*B with A=diag(2), B=m -> 2*m
        let two: [Double] = [2,0,0, 0,2,0, 0,0,2]
        let tm = DolbyVisionStillConverter.matMul(two, m)
        for i in 0..<9 { #expect(tm[i] == 2 * m[i]) }
    }

    @Test("PQ OETF inverts PQ EOTF; anchors + round-trip")
    func pqOETFRoundTrip() {
        #expect(abs(DolbyVisionStillConverter.pqOETF(0)) < 1e-6)
        #expect(abs(DolbyVisionStillConverter.pqOETF(1.0) - 1.0) < 1e-6)
        for i in 0...20 {
            let e = Double(i) / 20.0
            let back = DolbyVisionStillConverter.pqOETF(DolbyVisionStillConverter.pqEOTF(e))
            #expect(abs(back - e) < 1e-4, "PQ round-trip off at code \(e)")
        }
    }

    /// The #103 regression: the shipped fixed-exposure Hable curve mapped 100-nit diffuse
    /// white to ~50% output (mid-gray), crushing normally-lit content (validated vs a
    /// libplacebo ground truth: AE mean luma was 24-79% of reference). The BT.2390 EETF,
    /// anchored on the RPU source PQ range, must lift diffuse white near display white while
    /// keeping blacks dark and the curve monotonic.
    @Test("BT.2390 tone curve: dark black, monotonic, source peak -> white, diffuse white lifted")
    func toneCurve() {
        let srcMinPQ = 62.0 / 4095.0, srcMaxPQ = 3696.0 / 4095.0   // real values from the Dolby P5 clip
        let curve = DolbyVisionStillConverter.ToneCurve(srcMinPQ: srcMinPQ, srcMaxPQ: srcMaxPQ)
        let peak = DolbyVisionStillConverter.pqEOTF(srcMaxPQ)       // scene-linear source peak

        // Black must not turn milky.
        #expect(curve.map(0) >= 0)
        #expect(DolbyVisionStillConverter.srgbOETF(curve.map(0)) < 0.15, "black lifted too much")

        // Monotonic non-negative across the scene-linear range.
        var prev = -1.0
        for i in 0...64 {
            let v = curve.map(peak * Double(i) / 64.0)
            #expect(v >= prev - 1e-9, "tone curve not monotonic")
            #expect(v >= 0)
            prev = v
        }

        // Source mastering peak reaches SDR display white.
        #expect(curve.map(peak) >= 0.98, "source peak should reach SDR white")

        // Diffuse white (100 nits == 0.01 scene-linear) maps to libplacebo's static BT.2390 value
        // (~0.65), well clear of the old fixed-exposure ~0.50 mid-gray crush.
        let dwOut = DolbyVisionStillConverter.srgbOETF(curve.map(0.01))
        #expect(dwOut >= 0.58 && dwOut <= 0.72, "diffuse white off libplacebo target (\(dwOut))")

        // Final sRGB always clamps to [0,1].
        for i in 0...50 {
            let c = DolbyVisionStillConverter.srgbOETF(curve.map(peak * Double(i) / 50.0 * 1.2))
            #expect(c >= 0 && c <= 1.0, "final sRGB out of range")
        }
    }

    @Test("AVRational to double, with zero-denominator guard")
    func rationalConversion() {
        #expect(DolbyVisionStillConverter.q2d(AVRational(num: 3, den: 2)) == 1.5)
        #expect(DolbyVisionStillConverter.q2d(AVRational(num: 5, den: 0)) == 0)
    }
}
