// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
import Metal
@testable import AetherEngine

/// Edge cases for the composition kernels, executed on the GPU with expected
/// values worked out by hand rather than by re-running the shader's arithmetic.
///
/// Conventions used throughout: identity curves, denominator 23, 10-bit BL into
/// 12-bit VDR (vdr_scale 4), and an NLQ with `scale = 2048`, `shift = 11`, which is
/// what the real P7 streams carry, so that one EL code of residual is exactly one
/// VDR code. Dither is off so every expectation is exact.
@Suite(.offCooperativePoolOneLane)
struct DoviGpuEdgeCaseTests {

    typealias H = DoviGpuCurveSweepTests

    // MARK: - Fixtures

    static func nlq(
        offset: Int32 = 512,
        scale: Int32 = 2048,
        threshold: Int32 = 0,
        vdrInMax: Int32 = 512,
        method: DoviNlqMethod = .linear
    ) -> DoviNlqParams {
        var n = DoviNlqParams()
        n.nlqMethod = method
        n.nlqOffset = offset
        n.nlqScale = scale
        n.nlqThreshold = threshold
        n.vdrInMax = vdrInMax
        n.nlqShift = 11
        return n
    }

    static func params(
        flags: DoviComposerFlags = [],
        nlqY: DoviNlqParams = nlq(),
        nlqCb: DoviNlqParams = nlq(),
        nlqCr: DoviNlqParams = nlq()
    ) -> DoviMetalParams {
        var p = DoviMetalParams()
        p.ditherMode = .none
        p.flags = flags
        p.polyY = H.identityCurve()
        p.polyCb = H.identityCurve()
        p.polyCr = H.identityCurve()
        p.nlqY = nlqY
        p.nlqCb = nlqCb
        p.nlqCr = nlqCr
        return p
    }

    /// Constant-field compose: BL (y, cb, cr) at `blWidth x blHeight`, EL
    /// (y, cb, cr) at half that, returning the output buffer.
    static func composeConstant(
        _ composer: DoviFelComposer,
        blWidth: Int = 64, blHeight: Int = 16,
        bl: (y: Int, cb: Int, cr: Int),
        el: (y: Int, cb: Int, cr: Int),
        params: DoviMetalParams
    ) throws -> CVPixelBuffer {
        let blBuf = try #require(H.makeBuffer(width: blWidth, height: blHeight))
        let elBuf = try #require(H.makeBuffer(width: blWidth / 2, height: blHeight / 2))
        H.fillPlane(blBuf, plane: 0, components: 1) { _, _, _ in bl.y }
        H.fillPlane(blBuf, plane: 1, components: 2) { _, _, c in c == 0 ? bl.cb : bl.cr }
        H.fillPlane(elBuf, plane: 0, components: 1) { _, _, _ in el.y }
        H.fillPlane(elBuf, plane: 1, components: 2) { _, _, c in c == 0 ? el.cb : el.cr }
        return try #require(composer.compose(baseBuffer: blBuf, enhancementBuffer: elBuf, params: params, frameIndex: 0))
    }

    /// Every sample of a plane.
    static func allSamples(_ buffer: CVPixelBuffer, plane: Int, components: Int) -> [[Int]] {
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        return (0..<height).flatMap { H.readPlane(buffer, plane: plane, components: components, row: $0) }
    }

    static func lumaValues(_ buffer: CVPixelBuffer) -> Set<Int> {
        Set(allSamples(buffer, plane: 0, components: 1).map { $0[0] })
    }

    // MARK: - Residual (inverse NLQ) on the GPU

    /// (EL luma code, expected output luma code) for a BL of 512.
    /// vdr = 512 * 4 + residual; out = floor(vdr / 4 + 0.5). The residual is reconstructed at the
    /// middle of the quantisation step, (|r| - 1/2) * scale, truncated: |r| = 1 -> 0, 2 -> 1, 3 -> 2.
    @Test("GPU residual: positive, negative and zero residual land on the hand-computed code",
          arguments: [
            (612, 537),   // +100 -> 99 -> 2147 / 4 = 536.75 -> 537
            (412, 487),   // -100 -> -99 -> 1949 / 4 = 487.25 -> 487
            (512, 512),   // el == offset: no residual, and not zeroed out
            (513, 512),   // +1 -> 0 -> 2048 / 4 = 512
            (514, 512),   // +2 -> 1 -> 2049 / 4 = 512.25 -> 512
            (515, 513),   // +3 -> 2 -> 2050 / 4 = 512.5  -> rounds up to 513
            (511, 512),   // -1 -> 0 -> 512
          ])
    func residualSigns(elY: Int, expected: Int) throws {
        let composer = try #require(DoviFelComposer())
        let out = try Self.composeConstant(composer, bl: (512, 512, 512), el: (elY, 512, 512), params: Self.params())
        #expect(Self.lumaValues(out) == [expected], "el=\(elY)")
    }

    @Test("GPU residual: vdr_in_max clamps the magnitude symmetrically")
    func residualClampedByVdrInMax() throws {
        let composer = try #require(DoviFelComposer())
        let p = Self.params(nlqY: Self.nlq(vdrInMax: 256))
        // +511 -> clamped to +256 -> (2048 + 256) / 4 = 576 ; -512 -> -256 -> 448
        let hi = try Self.composeConstant(composer, bl: (512, 512, 512), el: (1023, 512, 512), params: p)
        let lo = try Self.composeConstant(composer, bl: (512, 512, 512), el: (0, 512, 512), params: p)
        #expect(Self.lumaValues(hi) == [576])
        #expect(Self.lumaValues(lo) == [448])
    }

    @Test("GPU residual: a non-zero deadzone threshold is added to the magnitude, as in the reference pseudo-code")
    func residualThresholdAdded() throws {
        // DoViBaker: dq = (2|r| - 1) * S + 2 * T, all >> (shift + 1). With S = 2048 (one code per EL code), shift 11 and
        // T = 50 codes: |r| = 100 -> (99.5 + 50) = 149.5 -> 149; |r| = 30 -> 29.5 + 50 = 79.5 -> 79; negative mirrors.
        let composer = try #require(DoviFelComposer())
        let p = Self.params(nlqY: Self.nlq(threshold: 50 * 2048))
        let big = try Self.composeConstant(composer, bl: (512, 512, 512), el: (612, 512, 512), params: p)
        let small = try Self.composeConstant(composer, bl: (512, 512, 512), el: (542, 512, 512), params: p)
        let neg = try Self.composeConstant(composer, bl: (512, 512, 512), el: (412, 512, 512), params: p)
        #expect(Self.lumaValues(big) == [(2048 + 149) / 4])     // 549.25 -> 549
        #expect(Self.lumaValues(small) == [532])                // (2048 + 79) / 4 = 531.75, rounded
        #expect(Self.lumaValues(neg) == [475])                  // (2048 - 149) / 4 = 474.75, rounded
    }

    @Test("GPU residual: zero scale, method none and disable_residual each yield the bare base layer")
    func residualOff() throws {
        let composer = try #require(DoviFelComposer())
        let cases: [(String, DoviMetalParams)] = [
            ("zero scale", Self.params(nlqY: Self.nlq(scale: 0))),
            ("method none", Self.params(nlqY: Self.nlq(method: .none))),
            ("disable flag", Self.params(flags: [.disableResidual])),
            ("disabled helper", Self.params(nlqY: .disabled)),
        ]
        for (name, p) in cases {
            let out = try Self.composeConstant(composer, bl: (512, 512, 512), el: (900, 100, 900), params: p)
            #expect(Self.lumaValues(out) == [512], "\(name)")
        }
    }

    @Test("GPU residual: Cb and Cr are inverted independently and with their own parameters")
    func chromaResidualIndependent() throws {
        let composer = try #require(DoviFelComposer())
        // Cr gets half the slope of Cb, so the same +100 EL swing gives +100 and +50.
        let p = Self.params(nlqCb: Self.nlq(scale: 2048), nlqCr: Self.nlq(scale: 1024))
        let out = try Self.composeConstant(composer, bl: (512, 400, 600), el: (512, 612, 612), params: p)
        let uv = Self.allSamples(out, plane: 1, components: 2)
        // Cb: (1600 + 99) / 4 = 424.75 -> 425 ; Cr: (2400 + 49) / 4 = 612.25 -> 612
        #expect(Set(uv.map { $0[0] }) == [425])
        #expect(Set(uv.map { $0[1] }) == [612])
    }

    @Test("GPU residual: only Cb active leaves Cr at its base value")
    func chromaOneComponentActive() throws {
        let composer = try #require(DoviFelComposer())
        let p = Self.params(nlqCr: Self.nlq(scale: 0))
        let out = try Self.composeConstant(composer, bl: (512, 400, 600), el: (512, 612, 612), params: p)
        let uv = Self.allSamples(out, plane: 1, components: 2)
        #expect(Set(uv.map { $0[0] }) == [425])
        #expect(Set(uv.map { $0[1] }) == [600])
    }

    // MARK: - Output range

    @Test("GPU clamps to video range: luma 64...940, chroma 64...960")
    func outputClamps() throws {
        let composer = try #require(DoviFelComposer())
        let p = Self.params(flags: [.disableResidual])
        let low = try Self.composeConstant(composer, bl: (0, 0, 0), el: (512, 512, 512), params: p)
        let high = try Self.composeConstant(composer, bl: (1023, 1023, 1023), el: (512, 512, 512), params: p)
        #expect(Self.lumaValues(low) == [64])
        #expect(Set(Self.allSamples(low, plane: 1, components: 2).flatMap { $0 }) == [64])
        #expect(Self.lumaValues(high) == [940])
        #expect(Set(Self.allSamples(high, plane: 1, components: 2).flatMap { $0 }) == [960])
    }

    @Test("GPU residual pushing past the VDR range saturates instead of wrapping")
    func residualSaturates() throws {
        let composer = try #require(DoviFelComposer())
        let p = Self.params()
        // BL 1023 + 511 residual -> 4092 + 511 > 4095 -> clamp -> out 1024 -> luma cap 940.
        let hi = try Self.composeConstant(composer, bl: (1023, 512, 512), el: (1023, 512, 512), params: p)
        // BL 0 - 512 residual -> negative -> clamp 0 -> luma floor 64.
        let lo = try Self.composeConstant(composer, bl: (0, 512, 512), el: (0, 512, 512), params: p)
        #expect(Self.lumaValues(hi) == [940])
        #expect(Self.lumaValues(lo) == [64])
    }

    // MARK: - Geometry

    @Test("GPU writes every pixel for sizes that are not a multiple of the threadgroup or of 8",
          arguments: [(4, 4), (6, 4), (34, 10), (130, 18), (514, 6), (1030, 10), (65, 17), (65, 16), (64, 17)])
    func oddGeometryCoversEveryPixel(width: Int, height: Int) throws {
        let composer = try #require(DoviFelComposer())
        // Residual of +100 over the whole frame: an unwritten pixel would read 0,
        // and a border pixel that mis-sampled the EL would miss 537.
        let out = try Self.composeConstant(
            composer, blWidth: width, blHeight: height,
            bl: (512, 512, 512), el: (612, 612, 412), params: Self.params()
        )
        #expect(Self.lumaValues(out) == [537], "luma \(width)x\(height)")
        let uv = Self.allSamples(out, plane: 1, components: 2)
        #expect(uv.count == ((width + 1) / 2) * ((height + 1) / 2))
        #expect(Set(uv.map { $0[0] }) == [537], "Cb \(width)x\(height)")
        #expect(Set(uv.map { $0[1] }) == [487], "Cr \(width)x\(height)")
    }

    @Test("a frame whose enhancement layer is one or three luma samples wide still has a chroma plane and composes it",
          arguments: [(2, 2), (6, 2)])
    func tinyEnhancementLayerStillComposes(width: Int, height: Int) throws {
        let composer = try #require(DoviFelComposer())
        // Chroma rounds up, so a narrow EL has a chroma plane of at least one sample rather than an empty one.
        // The kernel divides by that size: a floored size would be 0 for a 1-sample-wide EL and sample at infinity.
        let out = try Self.composeConstant(
            composer, blWidth: width, blHeight: height,
            bl: (512, 512, 512), el: (612, 612, 412), params: Self.params()
        )
        #expect(Self.lumaValues(out) == [537], "luma \(width)x\(height)")
        let uv = Self.allSamples(out, plane: 1, components: 2)
        #expect(uv.count == ((width + 1) / 2) * ((height + 1) / 2))
        #expect(Set(uv.map { $0[0] }) == [537], "Cb \(width)x\(height)")
        #expect(Set(uv.map { $0[1] }) == [487], "Cr \(width)x\(height)")
        // and the composer still works afterwards (no leaked parameter slot)
        let ok = try Self.composeConstant(composer, bl: (512, 512, 512), el: (612, 512, 512), params: Self.params())
        #expect(Self.lumaValues(ok) == [537])
    }

    @Test("GPU enhancement-layer upsampling preserves a constant field to the last row and column")
    func upsamplingPartitionOfUnity() throws {
        let composer = try #require(DoviFelComposer())
        // EL is 1/4 the BL area. A weight set that does not sum to one, or one that
        // reads past the edge, shows up as a border that differs from the interior.
        for (w, h) in [(64, 16), (66, 18), (130, 34)] {
            let out = try Self.composeConstant(
                composer, blWidth: w, blHeight: h,
                bl: (512, 512, 512), el: (700, 512, 512), params: Self.params()
            )
            // +188 is clamped to vdr_in_max 512 so is not clipped: (2048 + 188)/4 = 559.
            #expect(Self.lumaValues(out) == [559], "\(w)x\(h)")
        }
    }

    // MARK: - Curve shape

    @Test("GPU zero-width piece is never selected; the later piece owns the shared pivot")
    func zeroWidthPiece() throws {
        let composer = try #require(DoviFelComposer())
        var poly = DoviPolynomialParams()
        poly.numPivots = 4
        poly.pivots[0] = 0; poly.pivots[1] = 500; poly.pivots[2] = 500; poly.pivots[3] = 1023
        for piece in 0..<3 {
            poly.method[piece] = DoviMapping.polynomial.rawValue
            poly.order[piece] = 1
            poly.coefShift[piece] = 23
        }
        poly.coef[0] = [0, 1 << 23, 0]          // identity
        poly.coef[1] = [Int32(0.9 * 8388608.0), 0, 0]   // would output ~0.9 if ever chosen
        poly.coef[2] = [0, 1 << 23, 0]          // identity
        var p = Self.params(flags: [.disableResidual])
        p.polyY = poly

        let bl = try #require(H.makeBuffer(width: 1024, height: 4))
        let el = try #require(H.makeBuffer(width: 512, height: 2))
        H.fillPlane(bl, plane: 0, components: 1) { c, _, _ in min(c, 1023) }
        H.fillPlane(bl, plane: 1, components: 2) { _, _, _ in 512 }
        H.fillPlane(el, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(el, plane: 1, components: 2) { _, _, _ in 512 }
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p))
        let row = H.readPlane(out, plane: 0, components: 1, row: 0).map { $0[0] }
        for code in [100, 499, 500, 501, 900] {
            #expect(row[code] == min(max(code, 64), 940), "code \(code)")
        }
    }

    @Test("GPU luma MMR path reads the base-layer chroma, not just luma")
    func lumaMmrUsesChroma() throws {
        let composer = try #require(DoviFelComposer())
        var poly = DoviPolynomialParams()
        poly.numPivots = 2
        poly.pivots[0] = 0; poly.pivots[1] = 1023
        poly.method[0] = DoviMapping.mmr.rawValue
        poly.order[0] = 1
        poly.coefShift[0] = 23
        var mmr = DoviMmrParams()
        mmr.coefShift = 23
        // Terms are [y, u, v, yu, yv, uv, yuv]; select u only, so luma out = BL Cb.
        mmr.coef[0][1] = 1 << 23

        var p = Self.params(flags: [.disableResidual, .lumaMmr])
        p.polyY = poly
        p.mmrY = mmr
        let out = try Self.composeConstant(composer, bl: (800, 300, 700), el: (512, 512, 512), params: p)
        #expect(Self.lumaValues(out) == [300])
    }

    @Test("GPU luma MMR with a constant term and order 2 matches the hand-computed value")
    func lumaMmrOrderTwo() throws {
        let composer = try #require(DoviFelComposer())
        var poly = DoviPolynomialParams()
        poly.numPivots = 2
        poly.pivots[0] = 0; poly.pivots[1] = 1023
        poly.method[0] = DoviMapping.mmr.rawValue
        poly.order[0] = 2
        poly.coefShift[0] = 23
        var mmr = DoviMmrParams()
        mmr.coefShift = 23
        mmr.constant[0] = Int32(0.1 * 8388608.0)
        mmr.coef[0][0] = Int32(0.5 * 8388608.0)    // order 1, y
        mmr.coef[0][7] = Int32(0.2 * 8388608.0)    // order 2, y^2
        var p = Self.params(flags: [.disableResidual, .lumaMmr])
        p.polyY = poly
        p.mmrY = mmr
        // y = 600/1023: 0.1 + 0.5 y + 0.2 y^2
        let y = 600.0 / 1023.0
        let pred = 0.1 + 0.5 * y + 0.2 * y * y
        let expected = Int(floor(Double(Int((pred * 1023.0 * 4.0).rounded(.toNearestOrEven))) / 4.0 + 0.5))
        let out = try Self.composeConstant(composer, bl: (600, 512, 512), el: (512, 512, 512), params: p)
        #expect(Self.lumaValues(out) == [expected])
    }

    // MARK: - Dither

    @Test("GPU dither keeps the mean level and only moves values by one code")
    func ditherStaysWithinOneCode() throws {
        let composer = try #require(DoviFelComposer())
        var p = Self.params()
        p.ditherMode = .bayer8x8
        // Residual +3 (reconstructed as +2) on a 512 base: exactly 512.5, so dither splits 512/513.
        let blBuf = try #require(H.makeBuffer(width: 64, height: 64))
        let elBuf = try #require(H.makeBuffer(width: 32, height: 32))
        H.fillPlane(blBuf, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(blBuf, plane: 1, components: 2) { _, _, _ in 512 }
        H.fillPlane(elBuf, plane: 0, components: 1) { _, _, _ in 515 }
        H.fillPlane(elBuf, plane: 1, components: 2) { _, _, _ in 512 }
        for frame: UInt32 in [0, 1] {
            let out = try #require(composer.compose(baseBuffer: blBuf, enhancementBuffer: elBuf, params: p, frameIndex: frame))
            let samples = Self.allSamples(out, plane: 0, components: 1).map { $0[0] }
            #expect(samples.allSatisfy { $0 == 512 || $0 == 513 })
            let mean = Double(samples.reduce(0, +)) / Double(samples.count)
            #expect(abs(mean - 512.5) < 0.01, "frame \(frame) mean \(mean)")
        }
    }

    // MARK: - Robustness of the composer itself

    @Test("compose refuses degenerate buffers instead of crashing")
    func degenerateBuffers() throws {
        let composer = try #require(DoviFelComposer())
        // A non-planar buffer cannot give the six textures the kernels need.
        var bgra: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 16, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &bgra)
        let good = try #require(H.makeBuffer(width: 64, height: 16))
        let half = try #require(H.makeBuffer(width: 32, height: 8))
        if let bgra {
            #expect(composer.compose(baseBuffer: bgra, enhancementBuffer: half, params: Self.params()) == nil)
            #expect(composer.compose(baseBuffer: good, enhancementBuffer: bgra, params: Self.params()) == nil)
        }
    }

    @Test("repeated composes at a changing resolution recycle the pool without leaking slots")
    func resolutionChangeMidStream() throws {
        let composer = try #require(DoviFelComposer())
        for (w, h) in [(64, 16), (128, 32), (64, 16), (256, 64), (64, 16)] {
            for _ in 0..<8 {
                let out = try Self.composeConstant(
                    composer, blWidth: w, blHeight: h,
                    bl: (512, 512, 512), el: (612, 512, 512), params: Self.params()
                )
                #expect(CVPixelBufferGetWidth(out) == w)
                #expect(CVPixelBufferGetHeight(out) == h)
            }
        }
        // All in-flight slots must have been returned: a leak would deadlock here.
        composer.acquireSlot()
        composer.releaseSlot()
        #expect(composer.takePeakSlotsInUse() >= 1)
    }
}

extension DoviGpuEdgeCaseTests {
    private static func rawWord(_ b: CVPixelBuffer, plane: Int) -> Int {
        CVPixelBufferLockBaseAddress(b, .readOnly); defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(b, plane) / 2
        return Int(CVPixelBufferGetBaseAddressOfPlane(b, plane)!.assumingMemoryBound(to: UInt16.self)[3 * stride + 3])
    }

    @Test("full-precision output keeps the two VDR bits the 10-bit code drops")
    func fullPrecisionKeepsLowBits() throws {
        let composer = try #require(DoviFelComposer())
        // BL 500 -> VDR 2000; +2 residual (reconstructed as +1) -> 2001 = 500.25 in 10-bit codes.
        var p = Self.params(); p.ditherMode = .fullPrecision
        let out = try Self.composeConstant(composer, bl: (500, 512, 512), el: (514, 512, 512), params: p)
        #expect(Self.rawWord(out, plane: 0) == 2001 * 16)
        #expect(Self.rawWord(out, plane: 0) >> 6 == 500, "the top 10 bits stay a valid P010 code")
        var r = Self.params(); r.ditherMode = .none
        let rounded = try Self.composeConstant(composer, bl: (500, 512, 512), el: (514, 512, 512), params: r)
        #expect(Self.rawWord(rounded, plane: 0) == 500 << 6)
    }
}

// MARK: - DoViBaker input and prediction clamps

extension DoviGpuEdgeCaseTests {
    /// A one-piece MMR curve over `[lo, hi]` whose only non-zero term is `term` of `[y, u, v, yu, yv, uv, yuv]`.
    private static func mmrPassThrough(term: Int, lo: UInt32 = 0, hi: UInt32 = 1023) -> (DoviPolynomialParams, DoviMmrParams) {
        var poly = DoviPolynomialParams()
        poly.numPivots = 2
        poly.pivots[0] = lo; poly.pivots[1] = hi
        poly.method[0] = DoviMapping.mmr.rawValue
        poly.order[0] = 1
        poly.coefShift[0] = 23
        var mmr = DoviMmrParams()
        mmr.coefShift = 23
        mmr.coef[0][term] = 1 << 23
        return (poly, mmr)
    }

    private static func rawParams() -> DoviMetalParams {
        var p = params(flags: [.disableResidual])
        p.ditherMode = .debugRawVDR
        return p
    }

    /// DoViBaker `mmrMapping` clamps s0 to pivot_value[0], s1 to pivot_value[1], s2 to pivot_value[2] (each
    /// component's own range) before forming the cross terms. With a pass-through MMR the output is the
    /// clamped input, in 12-bit VDR codes (x4).
    @Test("MMR inputs are clamped to their own component's pivot range: Cb to poly_cb, Cr to poly_cr, luma to poly_y")
    func mmrInputsClampedToOwnComponentRange() throws {
        let composer = try #require(DoviFelComposer())

        // Cb term (u) with poly_cb range [64, 940]: BL Cb 1000 -> 940, BL Cb 30 -> 64.
        var p = Self.rawParams()
        (p.polyCb, p.mmrCb) = Self.mmrPassThrough(term: 1, lo: 64, hi: 940)
        var out = try Self.composeConstant(composer, bl: (512, 1000, 512), el: (512, 512, 512), params: p)
        #expect(Set(DoviTestSupport.rawVDR(out)[1]) == [940 * 4])
        out = try Self.composeConstant(composer, bl: (512, 30, 512), el: (512, 512, 512), params: p)
        #expect(Set(DoviTestSupport.rawVDR(out)[1]) == [64 * 4])

        // Cb output reading the v term: clamped by poly_cr's range [100, 900], not poly_cb's.
        p = Self.rawParams()
        (p.polyCb, p.mmrCb) = Self.mmrPassThrough(term: 2)
        p.polyCr = {
            var c = H.identityCurve(); c.pivots[0] = 100; c.pivots[1] = 900; return c
        }()
        out = try Self.composeConstant(composer, bl: (512, 512, 1000), el: (512, 512, 512), params: p)
        #expect(Set(DoviTestSupport.rawVDR(out)[1]) == [900 * 4])
        out = try Self.composeConstant(composer, bl: (512, 512, 20), el: (512, 512, 512), params: p)
        #expect(Set(DoviTestSupport.rawVDR(out)[1]) == [100 * 4])

        // Cr output reading the y term: clamped by poly_y's range [64, 940].
        p = Self.rawParams()
        (p.polyCr, p.mmrCr) = Self.mmrPassThrough(term: 0)
        p.polyY = {
            var c = H.identityCurve(); c.pivots[0] = 64; c.pivots[1] = 940; return c
        }()
        out = try Self.composeConstant(composer, bl: (1000, 512, 512), el: (512, 512, 512), params: p)
        #expect(Set(DoviTestSupport.rawVDR(out)[2]) == [940 * 4])

        // Luma MMR reading Cb: clamped by poly_cb's range.
        p = Self.rawParams()
        p.flags.insert(.lumaMmr)
        (p.polyY, p.mmrY) = Self.mmrPassThrough(term: 1)
        p.polyCb = {
            var c = H.identityCurve(); c.pivots[0] = 200; c.pivots[1] = 800; return c
        }()
        out = try Self.composeConstant(composer, bl: (512, 1000, 512), el: (512, 512, 512), params: p)
        #expect(Set(DoviTestSupport.rawVDR(out)[0]) == [800 * 4])
    }

    /// DoViBaker floors the polynomial and the MMR result at 0 (`vv = (vv < 0) ? 0 : vv`) before the residual
    /// is added, so a negative prediction is not pulled back up by it: 0 + 99, not -410 + 99 -> clamp 0.
    @Test("a negative prediction is floored at 0 before the residual is added")
    func negativePredictionFlooredBeforeResidual() throws {
        let composer = try #require(DoviFelComposer())
        var neg = DoviPolynomialParams()
        neg.numPivots = 2; neg.pivots[0] = 0; neg.pivots[1] = 1023
        neg.method[0] = DoviMapping.polynomial.rawValue
        neg.order[0] = 0; neg.coefShift[0] = 23
        neg.coef[0] = [Int32(-0.1 * 8388608.0), 0, 0]   // -0.1 * 4096 = -410 VDR codes

        var p = Self.params()
        p.ditherMode = .debugRawVDR
        p.polyY = neg
        let out = try Self.composeConstant(composer, bl: (512, 512, 512), el: (612, 512, 512), params: p)
        #expect(Set(DoviTestSupport.rawVDR(out)[0]) == [99])   // +100 EL codes -> +99 residual

        // The same through MMR (chroma): constant -0.1, residual +99.
        var m = DoviMmrParams(); m.coefShift = 23; m.constant[0] = Int32(-0.1 * 8388608.0)
        var mp = DoviPolynomialParams()
        mp.numPivots = 2; mp.pivots[1] = 1023
        mp.method[0] = DoviMapping.mmr.rawValue; mp.order[0] = 1; mp.coefShift[0] = 23
        p.polyCb = mp; p.mmrCb = m
        let c = try Self.composeConstant(composer, bl: (512, 512, 512), el: (512, 612, 512), params: p)
        #expect(Set(DoviTestSupport.rawVDR(c)[1]) == [99])
    }

    /// DoViBaker also caps the prediction at full scale (`v > 0xffff ? 0xffff : v`) before the residual, so a
    /// prediction above it is not pulled back down from there: 4095 - 99, not 4506 - 99 -> clamp 4095.
    @Test("a prediction above full scale is capped at vdr_max before the residual is added")
    func overRangePredictionCappedBeforeResidual() throws {
        let composer = try #require(DoviFelComposer())
        var high = DoviPolynomialParams()
        high.numPivots = 2; high.pivots[0] = 0; high.pivots[1] = 1023
        high.method[0] = DoviMapping.polynomial.rawValue
        high.order[0] = 0; high.coefShift[0] = 23
        high.coef[0] = [Int32(1.1 * 8388608.0), 0, 0]   // 1.1 * 4096 = 4506 VDR codes

        var p = Self.params()
        p.ditherMode = .debugRawVDR
        p.polyY = high
        let out = try Self.composeConstant(composer, bl: (512, 512, 512), el: (412, 512, 512), params: p)
        #expect(Set(DoviTestSupport.rawVDR(out)[0]) == [3996])   // -100 EL codes -> -99 residual

        // The same through MMR (chroma): constant 1.1, residual -99.
        var m = DoviMmrParams(); m.coefShift = 23; m.constant[0] = Int32(1.1 * 8388608.0)
        var mp = DoviPolynomialParams()
        mp.numPivots = 2; mp.pivots[1] = 1023
        mp.method[0] = DoviMapping.mmr.rawValue; mp.order[0] = 1; mp.coefShift[0] = 23
        p.polyCr = mp; p.mmrCr = m
        let c = try Self.composeConstant(composer, bl: (512, 512, 512), el: (512, 512, 412), params: p)
        #expect(Set(DoviTestSupport.rawVDR(c)[2]) == [3996])
    }

    @Test("GPU luma MMR on odd sizes reads the last base-layer chroma column and row",
          arguments: [(65, 17), (65, 16), (64, 17)])
    func oddSizesWithLumaMmr(width: Int, height: Int) throws {
        let composer = try #require(DoviFelComposer())
        var poly = DoviPolynomialParams()
        poly.numPivots = 2
        poly.pivots[0] = 0; poly.pivots[1] = 1023
        poly.method[0] = DoviMapping.mmr.rawValue
        poly.order[0] = 1
        poly.coefShift[0] = 23
        var mmr = DoviMmrParams()
        mmr.coefShift = 23
        mmr.coef[0][1] = 1 << 23       // luma out = BL Cb
        var p = Self.params(flags: [.disableResidual, .lumaMmr])
        p.polyY = poly
        p.mmrY = mmr
        let out = try Self.composeConstant(composer, blWidth: width, blHeight: height,
                                           bl: (800, 300, 700), el: (512, 512, 512), params: p)
        #expect(Self.lumaValues(out) == [300], "\(width)x\(height)")
    }

    /// The GPU's float-to-int conversion saturates, so this passes without the clamp too; it locks in the
    /// result the clamp-before-convert in `dovi_denormalize` is meant to give.
    @Test("GPU MMR result far outside the range ends at the VDR range limit",
          arguments: [Int32.max, Int32.min])
    func mmrOutOfRangeClamps(coef: Int32) throws {
        let composer = try #require(DoviFelComposer())
        var poly = DoviPolynomialParams()
        poly.numPivots = 2
        poly.pivots[0] = 0; poly.pivots[1] = 1023
        poly.method[0] = DoviMapping.mmr.rawValue
        poly.order[0] = 1
        poly.coefShift[0] = 0
        var mmr = DoviMmrParams()
        mmr.coefShift = 0
        mmr.coef[0][1] = coef       // u * 2^31, times 4092 in the denormalise: far past Int32
        var p = Self.params(flags: [.disableResidual, .lumaMmr])
        p.polyY = poly
        p.mmrY = mmr
        p.ditherMode = .debugRawVDR
        let out = try Self.composeConstant(composer, bl: (512, 300, 700), el: (512, 512, 512), params: p)
        #expect(Set(DoviTestSupport.rawVDR(out)[0]) == [coef > 0 ? 4095 : 0])
    }
}
#endif
