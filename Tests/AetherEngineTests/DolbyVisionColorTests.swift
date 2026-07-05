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

    @Test("Tone-map: 0 -> 0, monotonic, non-negative; final sRGB clamps to [0,1]")
    func toneMap() {
        #expect(DolbyVisionStillConverter.tonemap(0) == 0)
        // Bright highlights may map above 1.0 (fixed white point); the sRGB OETF clips them.
        var prev = -1.0
        for i in 0...50 {
            let x = Double(i) / 50.0 * 2.0
            let v = DolbyVisionStillConverter.tonemap(x)
            #expect(v >= prev - 1e-9, "tone-map not monotonic")
            #expect(v >= 0, "tone-map negative")
            let clamped = DolbyVisionStillConverter.srgbOETF(v)
            #expect(clamped >= 0 && clamped <= 1.0, "final sRGB not in [0,1]")
            prev = v
        }
    }

    @Test("AVRational to double, with zero-denominator guard")
    func rationalConversion() {
        #expect(DolbyVisionStillConverter.q2d(AVRational(num: 3, den: 2)) == 1.5)
        #expect(DolbyVisionStillConverter.q2d(AVRational(num: 5, den: 0)) == 0)
    }
}
