// Only with the DolbyVisionStillReshaping trait: the still converter is not built without it.
#if DolbyVisionStillReshaping
import Testing
import AetherLibavutil
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

    // MARK: - RPU reshaping (mapping) curves (#103 follow-up)

    private typealias Curve = DolbyVisionStillConverter.ReshapeCurve

    private func poly(_ pivots: [Double], _ coefs: [[Double]]) -> Curve {
        Curve(pivots: pivots, isMMR: coefs.map { _ in false }, poly: coefs,
              mmrOrder: [], mmrConst: [], mmrCoef: [])
    }

    @Test("Linear reshaping curve matches the clip's Cp/Ct gain+offset fit")
    func reshapeLinear() {
        // Cp curve from the real Profile 5 clip: out = 0.06739 + 1.05242*x.
        let cp = poly([0, 1], [[0.06739, 1.05242, 0]])
        #expect(abs(cp.map(0, (0, 0, 0)) - 0.06739) < 1e-9)
        #expect(abs(cp.map(0.5, (0, 0.5, 0.5)) - (0.06739 + 1.05242 * 0.5)) < 1e-9)
        #expect(!cp.isIdentity)
    }

    @Test("Identity curve is detected and is a no-op")
    func reshapeIdentity() {
        let id = poly([0, 1], [[0, 1, 0]])
        #expect(id.isIdentity)
        for i in 0...10 {
            let x = Double(i) / 10.0
            #expect(abs(id.map(x, (x, x, x)) - x) < 1e-12)
        }
    }

    @Test("Quadratic term is applied (Horner)")
    func reshapeQuadratic() {
        let q = poly([0, 1], [[0, 0, 1]])   // y = x^2
        #expect(abs(q.map(0.5, (0, 0, 0)) - 0.25) < 1e-12)
        #expect(abs(q.map(0.7, (0, 0, 0)) - 0.49) < 1e-12)
    }

    @Test("Piecewise segment selection is continuous across the pivot")
    func reshapePiecewise() {
        // seg0 on [0,0.5]: y = x ; seg1 on [0.5,1]: y = -0.5 + 2x. Meet at (0.5, 0.5).
        let c = poly([0, 0.5, 1], [[0, 1, 0], [-0.5, 2, 0]])
        #expect(abs(c.map(0.25, (0, 0, 0)) - 0.25) < 1e-12)  // seg0
        #expect(abs(c.map(0.5, (0, 0, 0)) - 0.5) < 1e-12)    // pivot: both segments agree
        #expect(abs(c.map(0.75, (0, 0, 0)) - 1.0) < 1e-12)   // seg1
    }

    @Test("Input is clamped to the pivot range")
    func reshapeClamp() {
        let c = poly([0.2, 0.8], [[0, 1, 0]])   // y = x on [0.2,0.8]
        #expect(abs(c.map(-1, (0, 0, 0)) - 0.2) < 1e-12)  // clamps to low pivot
        #expect(abs(c.map(5, (0, 0, 0)) - 0.8) < 1e-12)   // clamps to high pivot
    }

    @Test("MMR reshaping evaluates cross terms and higher orders")
    func reshapeMMR() {
        // term layout per segment: [I, Ct, Cp, I*Ct, I*Cp, Ct*Cp, I*Ct*Cp]
        func mmr(order: Int, const: Double, coef: [[Double]]) -> Curve {
            Curve(pivots: [0, 1], isMMR: [true], poly: [[0, 0, 0]],
                  mmrOrder: [order], mmrConst: [const], mmrCoef: [coef])
        }
        let zero = [Double](repeating: 0, count: 7)
        // constant + linear I: 0.1 + 1*I
        let linI = mmr(order: 1, const: 0.1, coef: [[1, 0, 0, 0, 0, 0, 0], zero, zero])
        #expect(abs(linI.map(0.9, (0.3, 0.2, 0.1)) - 0.4) < 1e-12)
        // cross term I*Ct (index 3)
        let cross = mmr(order: 1, const: 0, coef: [[0, 0, 0, 1, 0, 0, 0], zero, zero])
        #expect(abs(cross.map(0, (0.3, 0.2, 0.1)) - 0.06) < 1e-12)
        // order 2: 1*I + 1*I^2 with I=0.3 -> 0.3 + 0.09 = 0.39
        let ord2 = mmr(order: 2, const: 0,
                       coef: [[1, 0, 0, 0, 0, 0, 0], [1, 0, 0, 0, 0, 0, 0], zero])
        #expect(abs(ord2.map(0, (0.3, 0.2, 0.1)) - 0.39) < 1e-12)
    }
}
#endif
