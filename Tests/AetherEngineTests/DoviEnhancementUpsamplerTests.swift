// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Foundation
import Testing
import Metal
@testable import AetherEngine

/// The enhancement layer is upsampled to the base-layer grid bilinearly, from explicit texel reads with exact
/// weights, and the interpolated code is rounded half up (`dovi_upsample_el`, `dovi_el_code`). These tests run
/// the production composer and read the residual back out of the un-quantised VDR plane, so a different filter
/// (a Catmull-Rom, or nearest), inexact weights or another rounding fail them.
@Suite(.offCooperativePoolOneLane, .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
struct DoviEnhancementUpsamplerTests {

    typealias H = DoviGpuCurveSweepTests

    /// BL luma constant 512 (VDR 2048), EL luma `elColumn(x)` at half resolution, residual scale 2048: the
    /// output is 2048 + floor((2|r| - 1) * 2048 / 4096) with r = el - 512, i.e. |r| - 1 for the codes used here
    /// (|r| of 88 or more is far from the half-step rounding), and the first row is returned.
    private func composeLuma(elColumn: (Int) -> Int) throws -> [Int] {
        let composer = try #require(DoviFelComposer())
        var p = DoviGpuEdgeCaseTests.params(nlqY: DoviGpuEdgeCaseTests.nlq(vdrInMax: 4095))
        p.ditherMode = .debugRawVDR
        let bl = try #require(H.makeBuffer(width: 64, height: 8))
        let el = try #require(H.makeBuffer(width: 32, height: 4))
        H.fillPlane(bl, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(bl, plane: 1, components: 2) { _, _, _ in 512 }
        H.fillPlane(el, plane: 0, components: 1) { x, _, _ in elColumn(x) }
        H.fillPlane(el, plane: 1, components: 2) { _, _, _ in 512 }
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p))
        return Array(DoviTestSupport.rawVDR(out)[0][0..<64])
    }

    /// Residual in VDR codes for an EL code, from the DoViBaker formula (positive side): ((2r - 1) * 2048) >> 12.
    private func residual(_ el: Int) -> Double {
        Double(((2 * (el - 512) - 1) * 2048) >> 12)
    }

    @Test("a linear EL ramp is reproduced between EL texel centres, one bilinear step per base-layer pixel")
    func rampIsLinearlyInterpolated() throws {
        // EL column x is 600 + 4x. BL pixel gx samples EL coordinate gx / 2 - 0.25 (centres at x + 0.5).
        let row = try composeLuma { 600 + 4 * $0 }
        for gx in 2..<62 {
            let elValue = 600.0 + 4.0 * (Double(gx) / 2.0 - 0.25)
            let expected = 2048.0 + (elValue - 512.0) - 0.5     // linear in el: |r| - 1/2
            #expect(abs(Double(row[gx]) - expected) <= 1.5, "gx \(gx): \(row[gx]) vs \(expected)")
        }
    }

    @Test("EL chroma is co-sited with the base chroma: even samples land on EL texels, odd ones half way")
    func chromaIsCosited() throws {
        // Quarter-resolution EL: EL chroma 16 x 4 under base chroma 32 x 8. Cb ramps across columns, Cr down
        // rows, 16 codes per EL texel. Base chroma sample n sits at EL texel n / 2 (DoViBaker's
        // upsampleChromaEven / Odd), so even samples read one texel exactly; a centre-aligned fetch would
        // read n / 2 - 0.25 and land 4 codes low on every even sample past the edge.
        let composer = try #require(DoviFelComposer())
        var p = DoviGpuEdgeCaseTests.params()
        p.ditherMode = .debugRawVDR
        let bl = try #require(H.makeBuffer(width: 64, height: 16))
        let el = try #require(H.makeBuffer(width: 32, height: 8))
        H.fillPlane(bl, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(bl, plane: 1, components: 2) { _, _, _ in 512 }
        H.fillPlane(el, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(el, plane: 1, components: 2) { x, y, c in 600 + 16 * (c == 0 ? x : y) }
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p))
        let planes = DoviTestSupport.rawVDR(out, chromaOnly: true)
        let cb = planes[1], cr = planes[2]

        /// EL code at base chroma index n along an axis of `elCount` texels, clamped at the far edge.
        func elAt(_ n: Int, _ elCount: Int) -> Double { 600.0 + 16.0 * min(Double(n) / 2.0, Double(elCount - 1)) }
        /// 2048 + ((2r - 1) * 2048) >> 12 = 2048 + r - 1 for the positive r used here.
        func vdr(_ e: Double) -> Int { 2048 + Int(e.rounded()) - 512 - 1 }

        for y in 0..<8 {
            for x in 0..<32 {
                // Exact on odd samples too: the half-way weight is exact, not the sampler's fixed point.
                let gotCb = cb[y * 32 + x], wantCb = vdr(elAt(x, 16))
                #expect(gotCb == wantCb, "Cb (\(x), \(y)): \(gotCb) vs \(wantCb)")
                let gotCr = cr[y * 32 + x], wantCr = vdr(elAt(y, 4))
                #expect(gotCr == wantCr, "Cr (\(x), \(y)): \(gotCr) vs \(wantCr)")
            }
        }
    }

    /// Exact bilinear EL code at base-layer column `gx` of a 64-wide row over a 32-wide EL (centre-aligned),
    /// rounded half up.
    private func exactLumaCode(_ gx: Int, _ elColumn: (Int) -> Int) -> Int {
        let u = (Double(gx) + 0.5) / 2.0 - 0.5
        let x0 = Int(floor(u)), fx = u - Double(x0)
        let a = Double(elColumn(min(max(x0, 0), 31))), b = Double(elColumn(min(max(x0 + 1, 0), 31)))
        return Int(floor(a * (1 - fx) + b * fx + 0.5))
    }

    @Test("luma: interpolated EL codes are exact and an exact half rounds up, not to even")
    func lumaHalfRoundsUp() throws {
        // Columns alternate 602 / 600: at the 2:1 quarter weights every base pixel lands on x.5
        // (0.25 * 602 + 0.75 * 600 = 600.5, 0.75 * 602 + 0.25 * 600 = 601.5). Ties-to-even would give 600 and
        // 602, half up gives 601 and 602. Above 512 the residual here is code - 513.
        let column: (Int) -> Int = { $0 % 2 == 0 ? 602 : 600 }
        let row = try composeLuma(elColumn: column)
        for gx in 0..<64 {
            let want = 2048 + exactLumaCode(gx, column) - 513
            #expect(row[gx] == want, "gx \(gx): \(row[gx]) vs \(want)")
        }
        #expect(row.contains(2048 + 601 - 513), "the 600.5 sites round up to 601")
    }

    @Test("chroma: a half-way EL code rounds up")
    func chromaHalfRoundsUp() throws {
        // Quarter-resolution EL chroma alternating 601 / 600 by column: odd base samples sit half way, at 600.5,
        // which rounds up to 601 (ties-to-even would give 600). Even samples read one texel exactly.
        let composer = try #require(DoviFelComposer())
        var p = DoviGpuEdgeCaseTests.params()
        p.ditherMode = .debugRawVDR
        let bl = try #require(H.makeBuffer(width: 64, height: 16))
        let el = try #require(H.makeBuffer(width: 32, height: 8))
        H.fillPlane(bl, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(bl, plane: 1, components: 2) { _, _, _ in 512 }
        H.fillPlane(el, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(el, plane: 1, components: 2) { x, _, _ in x % 2 == 0 ? 601 : 600 }
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p))
        let cb = DoviTestSupport.rawVDR(out, chromaOnly: true)[1]
        for x in 0..<32 {
            let n = x / 2
            let code: Int
            if x % 2 == 0 { code = n % 2 == 0 ? 601 : 600 } else { code = n + 1 > 15 ? (n % 2 == 0 ? 601 : 600) : 601 }
            #expect(cb[x] == 2048 + code - 513, "Cb \(x): \(cb[x]) vs \(2048 + code - 513)")
        }
    }

    @Test("a step edge in the EL is blended, never overshot, and the plateaus are exact")
    func stepHasNoRinging() throws {
        let low = 600, high = 700
        let row = try composeLuma { $0 < 16 ? low : high }
        let lo = 2048 + Int(residual(low)), hi = 2048 + Int(residual(high))
        for gx in 0..<64 {
            #expect(row[gx] >= lo && row[gx] <= hi, "gx \(gx) = \(row[gx]) leaves [\(lo), \(hi)]: the filter rings")
        }
        #expect(row[10] == lo)
        #expect(row[53] == hi)
        // The edge sits between EL columns 15 and 16, i.e. BL pixels 31 and 32: one pixel each side is strictly inside.
        let inside = (28..<36).filter { row[$0] > lo && row[$0] < hi }
        #expect(inside.count >= 2 && inside.count <= 4, "edge transition spans \(inside.count) pixels")
        for gx in 1..<64 { #expect(row[gx] >= row[gx - 1], "monotone at \(gx)") }
    }
}
#endif
