// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
import Metal
@testable import AetherEngine

/// S4 from ``DoviFelMathTests``' list:
/// the ordered dither is unbiased at the output, and Cb and Cr do not share a
/// dither pattern.
///
/// These run the real `dovi_compose_luma` / `dovi_compose_chroma` kernels and
/// read the planes back, so they fail if the shader stops matching the claim.
///
/// What they deliberately do *not* lock is the half-step centring in
/// `dovi_dither`. At `vdr_scale <= 64` the raw table `k/64` and the centred table
/// `(k + 0.5)/64` select exactly the same cells, so at the 10-bit-into-12-bit
/// scale of 4 that every Dolby Vision stream uses, the two are bit-identical and
/// no end-to-end test can tell them apart. The centring matters only above that,
/// and the reason it is there is written out in the shader.
@Suite(.offCooperativePoolOneLane)
struct DoviDitherTests {

    static let width = 64
    static let height = 64

    static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary,
            &buffer
        )
        return buffer
    }

    static func fillPlane(_ buffer: CVPixelBuffer, plane: Int, components: Int, value: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let h = CVPixelBufferGetHeightOfPlane(buffer, plane)
        for row in 0..<h {
            let rowPtr = (base + row * bytesPerRow).assumingMemoryBound(to: UInt16.self)
            for column in 0..<(w * components) {
                rowPtr[column] = UInt16(value << 6)
            }
        }
    }

    /// The 8x8 Bayer cell at the plane's origin, one component of it.
    static func readCell(_ buffer: CVPixelBuffer, plane: Int, components: Int, component: Int) -> [Int] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return [] }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        var out: [Int] = []
        out.reserveCapacity(64)
        for row in 0..<8 {
            let rowPtr = (base + row * bytesPerRow).assumingMemoryBound(to: UInt16.self)
            for column in 0..<8 {
                out.append(Int(rowPtr[column * components + component] >> 6))
            }
        }
        return out
    }

    /// A flat curve: `pred_norm` is the constant `c0`, whatever the input code.
    /// Used to drive one exact VDR value onto the whole plane, so the only thing
    /// varying across the cell is the dither.
    static func constantCurve(c0: Int32) -> DoviPolynomialParams {
        var poly = DoviPolynomialParams()
        poly.numPivots = 2
        poly.pivots[0] = 0
        poly.pivots[1] = 1023
        poly.method[0] = DoviMapping.polynomial.rawValue
        poly.order[0] = 1
        poly.coef[0] = [c0, 0, 0]
        poly.coefShift[0] = 23
        return poly
    }

    /// Smallest `c0` whose denormalised VDR value is exactly `vdr`, and the value
    /// the kernel will actually compute from it.
    static func curveHitting(vdr: Int, blMax: Int, vdrScale: Int) -> (curve: DoviPolynomialParams, vdr: Int) {
        // Curves are normalised by 2^bits (blMax + 1) both ways.
        let blNorm = blMax + 1
        let norm = Double(vdr) / (Double(blNorm) * Double(vdrScale))
        let fixed = Int32((norm * Double(1 << 23)).rounded())
        let exact = Double(fixed) / Double(1 << 23)
        let produced = Int((exact * Double(blNorm) * Double(vdrScale)).rounded(.toNearestOrEven))
        return (constantCurve(c0: fixed), produced)
    }

    static func compose(
        lumaCurve: DoviPolynomialParams,
        cbCurve: DoviPolynomialParams,
        crCurve: DoviPolynomialParams,
        dither: DoviDither,
        frameIndex: UInt32
    ) -> CVPixelBuffer? {
        guard let composer = DoviFelComposer(),
              let bl = makeBuffer(width: width, height: height),
              let el = makeBuffer(width: width / 2, height: height / 2) else { return nil }
        fillPlane(bl, plane: 0, components: 1, value: 512)
        fillPlane(bl, plane: 1, components: 2, value: 512)
        fillPlane(el, plane: 0, components: 1, value: 512)
        fillPlane(el, plane: 1, components: 2, value: 512)

        var params = DoviMetalParams()
        params.ditherMode = dither
        params.flags = [.disableResidual]
        params.polyY = lumaCurve
        params.polyCb = cbCurve
        params.polyCr = crCurve
        return composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: frameIndex)
    }

    // MARK: - Unbiased

    @Test("dither is unbiased: the 8x8 cell mean is the exact pre-rounding value, at every quarter-code residue")
    func ditherMeanMatchesExactValue() throws {
        // vdr_scale is 4, so the value reaching the rounding step is k + r/4.
        // r = 0 is the case where rounding is exact and dither must not move it;
        // r = 2 is the case a flat 0.5 bias resolves entirely the wrong way for
        // half the levels, which is what dither exists to fix.
        for r in 0..<4 {
            let target = 500 * 4 + r
            let (curve, vdr) = Self.curveHitting(vdr: target, blMax: 1023, vdrScale: 4)
            #expect(vdr == target, "curve construction missed the target VDR value: \(vdr) != \(target)")

            guard let dst = Self.compose(
                lumaCurve: curve,
                cbCurve: Self.constantCurve(c0: 0),
                crCurve: Self.constantCurve(c0: 0),
                dither: .bayer8x8,
                frameIndex: 0
            ) else {
                Issue.record("Composer returned nil")
                return
            }

            let cell = Self.readCell(dst, plane: 0, components: 1, component: 0)
            #expect(cell.count == 64)
            let mean = Double(cell.reduce(0, +)) / 64.0
            let exact = Double(vdr) / 4.0
            #expect(abs(mean - exact) < 1e-9,
                    "residue \(r): dithered cell mean \(mean) is not the exact value \(exact)")

            // Only two output levels may appear, and they must bracket the value.
            let levels = Set(cell).sorted()
            #expect(levels.count <= 2, "residue \(r): dither produced \(levels.count) levels: \(levels)")
            for level in levels {
                #expect(abs(Double(level) - exact) < 1.0,
                        "residue \(r): level \(level) is more than a code from \(exact)")
            }
        }
    }

    @Test("the per-frame inversion does not bias either frame of the pair")
    func frameInversionIsUnbiased() throws {
        // Residue 1: three quarters of the cell stays low, so an inversion that
        // drew from a shifted set of offsets would show up as a mean shift here.
        let (curve, vdr) = Self.curveHitting(vdr: 500 * 4 + 1, blMax: 1023, vdrScale: 4)
        var means: [Double] = []
        for frame in [UInt32(0), UInt32(1)] {
            guard let dst = Self.compose(
                lumaCurve: curve,
                cbCurve: Self.constantCurve(c0: 0),
                crCurve: Self.constantCurve(c0: 0),
                dither: .bayer8x8,
                frameIndex: frame
            ) else {
                Issue.record("Composer returned nil")
                return
            }
            let cell = Self.readCell(dst, plane: 0, components: 1, component: 0)
            means.append(Double(cell.reduce(0, +)) / 64.0)
        }
        let exact = Double(vdr) / 4.0
        #expect(abs(means[0] - exact) < 1e-9, "frame 0 mean \(means[0]) != \(exact)")
        #expect(abs(means[1] - exact) < 1e-9, "frame 1 mean \(means[1]) != \(exact)")
    }

    // MARK: - Decorrelated

    @Test("Cb and Cr use different dither phases, so a flat field does not get a shared pattern")
    func chromaPhasesAreDecorrelated() throws {
        // Residue 2 splits the cell evenly, which is the residue with the most
        // pattern to compare.
        let (curve, vdr) = Self.curveHitting(vdr: 500 * 4 + 2, blMax: 1023, vdrScale: 4)

        guard let dst = Self.compose(
            lumaCurve: Self.constantCurve(c0: 0),
            cbCurve: curve,
            crCurve: curve,
            dither: .bayer8x8,
            frameIndex: 0
        ) else {
            Issue.record("Composer returned nil")
            return
        }

        let cb = Self.readCell(dst, plane: 1, components: 2, component: 0)
        let cr = Self.readCell(dst, plane: 1, components: 2, component: 1)
        #expect(cb.count == 64 && cr.count == 64)

        let exact = Double(vdr) / 4.0
        #expect(abs(Double(cb.reduce(0, +)) / 64.0 - exact) < 1e-9, "Cb cell mean is biased")
        #expect(abs(Double(cr.reduce(0, +)) / 64.0 - exact) < 1e-9, "Cr cell mean is biased")

        // Same curve, same input, same frame, so any difference is the phase.
        // At the 50% level the selected set is a checkerboard in (x + y) parity,
        // and the Cb/Cr offsets differ by (0, 1), which inverts that parity: the
        // two patterns come out exact complements, 64 of 64. A weak offset is the
        // failure worth catching here rather than a missing one -- the (4, 4)
        // diagonal this replaced is a near-symmetry of the matrix and scored 0 of
        // 64 at this level, so `cb != cr` alone would not have been enough.
        let differing = zip(cb, cr).filter { $0 != $1 }.count
        #expect(differing >= 48,
                "Cb and Cr dither patterns differ on only \(differing) of 64 pixels; the phase offset is gone or is a symmetry of the Bayer matrix")
    }

    // MARK: - Dither actually changes something

    @Test("with dither off the same field collapses to one level, so the cell spread above is the dither's")
    func unditheredIsFlat() throws {
        let (curve, _) = Self.curveHitting(vdr: 500 * 4 + 2, blMax: 1023, vdrScale: 4)
        guard let dst = Self.compose(
            lumaCurve: curve,
            cbCurve: Self.constantCurve(c0: 0),
            crCurve: Self.constantCurve(c0: 0),
            dither: .none,
            frameIndex: 0
        ) else {
            Issue.record("Composer returned nil")
            return
        }
        let cell = Self.readCell(dst, plane: 0, components: 1, component: 0)
        #expect(Set(cell).count == 1, "undithered output is not flat: \(Set(cell).sorted())")
    }

    /// The 8x8 ordered-dither matrix as a literal table (`k` in `k/64`).
    static let bayerGolden: [Int] = [
        0, 32, 8, 40, 2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]

    /// Recovers every cell of the dither matrix from the GPU and compares it with the golden table.
    /// A 16-bit VDR into a 10-bit plane gives `vdr_scale = 64`, so a constant luma of `500*64 + j`
    /// rounds up in a cell exactly when `j + k >= 64`; the first `j` at which a cell rises gives `k = 64 - j`.
    @Test("the dither matrix the kernel applies is the golden Bayer 8x8, cell for cell")
    func ditherMatrixIsGolden() throws {
        let composer = try #require(DoviFelComposer())
        var recovered = [Int](repeating: 0, count: 64)
        var rose = [Bool](repeating: false, count: 64)
        for j in 0..<64 {
            var p = DoviMetalParams()
            let depthsOK = p.setBitDepths(bl: 10, vdr: 16)
            #expect(depthsOK)
            p.ditherMode = .bayer8x8
            p.flags = [.disableResidual]
            p.frameIndex = 0
            p.polyY = DoviGpuCurveSweepTests.identityCurve()
            p.polyCb = DoviGpuCurveSweepTests.identityCurve()
            p.polyCr = DoviGpuCurveSweepTests.identityCurve()
            p.polyY.numPivots = 2
            p.polyY.pivots[0] = 0; p.polyY.pivots[1] = 1023
            p.polyY.method[0] = DoviMapping.polynomial.rawValue
            p.polyY.order[0] = 0
            p.polyY.coefShift[0] = 23
            p.polyY.coef[0] = [Int32((Double(500 * 64 + j) / (1024.0 * 64.0) * 8388608.0).rounded()), 0, 0]
            let out = try DoviGpuEdgeCaseTests.composeConstant(composer, blWidth: 16, blHeight: 16,
                                                               bl: (500, 512, 512), el: (512, 512, 512), params: p)
            let rows = (0..<8).map { DoviGpuCurveSweepTests.readPlane(out, plane: 0, components: 1, row: $0) }
            for y in 0..<8 { for x in 0..<8 where !rose[y * 8 + x] && rows[y][x][0] == 501 {
                rose[y * 8 + x] = true; recovered[y * 8 + x] = 64 - j
            } }
        }
        #expect(recovered == Self.bayerGolden, "recovered \(recovered)")
    }
}
#endif
