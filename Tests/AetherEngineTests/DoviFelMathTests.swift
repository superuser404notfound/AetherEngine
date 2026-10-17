// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
import Metal
import Dovi
@testable import AetherEngine

/// Numerical checks of the Dolby Vision Profile 7 FEL reconstruction, all driven through the production
/// `DoviFelComposer.compose` with `.debugRawVDR` (12-bit VDR codes, no quantisation) and the real RPU parser.
/// Nothing here re-implements the kernel's arithmetic: expectations are worked out from the DoViBaker
/// formulas (erazortt/DoViBaker, `DoViProcessor.cpp`) and written down as numbers.
@Suite(.offCooperativePoolOneLane)
struct DoviFelMathTests {

    // Raw 376-byte unspec62 RPU NAL extracted from fel-clip-a.mkv
    static let clipARpuHex = "7c011908090840613650ae20002008020080200802007f801ffc00ffc001fffa0000030100000300d0000008000006800000400000340000030200000301a000001000000d0000030080000068000004000003034000002000000a800000800000e18618800000800000800000800000800000800000b0c30c800000800000800000800000800000800000986186800000800000800000800000800000540000040000040000070c30c4000004000004000004000004000004000005861864000004000004000004000004000004000004c30c34000004000004000004000004012000010010010000030100480000400400400000401200001001001000001c95980000d7a8959be7f3ac7095991328000004000003002000000300200000030070d8890c06182978c238145000000698f96bfffc00000300000300000300018081f73805463008015faa4900c0282183180081872b94210002020000030008050000030002261140120c1f4000641f2e1276ffb6cfda80"

    // Raw 225-byte unspec62 RPU NAL extracted from fel-clip-c.mp4
    static let clipCRpuHex = "7c011908090840613650af003ff801ffc00ffc001fffa000001000000d0000030080000068000004000003020090000080080080000080240000200200200000200900000800800800000d12b300001af512b37cfe758e12b3226500000300800000040000030004000003000e1b112180c3052f1847028a00000300d31f2d7fff800000030000030000030030103ee700a8c0300800410a6680c02821800800800800800400020200000300080500000300000300000300120c07d0000201c000f650301c0040038680b080180080080080080080041204ff80008041ac0ad580"

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            if let byte = UInt8(hex[i..<next], radix: 16) {
                bytes.append(byte)
            }
            i = next
        }
        return bytes
    }

    // MARK: - Fixtures

    private typealias H = DoviGpuCurveSweepTests

    /// A one-piece curve over [0, 1023] with Q23 coefficients given as doubles.
    private static func polynomial(_ c0: Double, _ c1: Double = 0, _ c2: Double = 0, order: UInt32) -> DoviPolynomialParams {
        var poly = DoviPolynomialParams()
        poly.numPivots = 2
        poly.pivots[0] = 0; poly.pivots[1] = 1023
        poly.method[0] = DoviMapping.polynomial.rawValue
        poly.order[0] = order
        poly.coefShift[0] = 23
        poly.coef[0] = [Int32(c0 * 8388608.0), Int32(c1 * 8388608.0), Int32(c2 * 8388608.0)]
        return poly
    }

    private static func rawParams(residual: Bool) -> DoviMetalParams {
        var p = DoviGpuEdgeCaseTests.params(flags: residual ? [] : [.disableResidual])
        p.ditherMode = .debugRawVDR
        return p
    }

    // MARK: - D1 & S2: inverse NLQ

    /// DoViBaker `nonLinearInverseQuantization`: rr = e - offset; rr = 2 rr - sign; dq = rr * S, then a shift
    /// that lands in VDR codes; for S = 2048 at denom 23 that is (2|r| - 1) * 2048 >> 12. The kernel reconstructs
    /// the magnitude and applies the sign afterwards, so a negative residual truncates toward zero where
    /// DoViBaker's arithmetic shift floors: the two differ by at most one code on negative half-steps.
    @Test("inverse NLQ through the composer: el = 1023 gives +510 (not 511), el = 0 gives -511, centre gives 0",
          arguments: [
            (1023, 2558),   // r = +511: (1021 * 2048) >> 12 = 510
            (0, 1537),      // r = -512: (1023 * 2048) >> 12 = 511 -> -511 (DoViBaker floors to -512)
            (512, 2048),          // r = 0
            (768, 2303),    // r = +256: (511 * 2048) >> 12 = 255
            (256, 1793),    // r = -256: -255 (DoViBaker -256)
            (513, 2048),          // r = +1: (1 * 2048) >> 12 = 0
            (514, 2049),      // r = +2: (3 * 2048) >> 12 = 1
          ])
    func inverseNlqThroughComposer(el: Int, expectedVdr: Int) throws {
        let composer = try #require(DoviFelComposer())
        var p = Self.rawParams(residual: true)
        p.nlqY = DoviGpuEdgeCaseTests.nlq(vdrInMax: 4095)   // not binding: isolate the quantiser
        let out = try DoviGpuEdgeCaseTests.composeConstant(composer, bl: (512, 512, 512), el: (el, 512, 512), params: p)
        #expect(Set(DoviTestSupport.rawVDR(out)[0]) == [expectedVdr], "el=\(el)")
    }

    // MARK: - D3: delta-coded pivots

    @Test("D3: the parser prefix-sums delta-coded pivots into absolute breakpoints")
    func pivotPrefixSumAccumulation() {
        let clipABytes = Self.hexToBytes(Self.clipARpuHex)
        guard let rpu = dovi_parse_unspec62_nalu(clipABytes, clipABytes.count) else {
            Issue.record("Failed to parse clip A RPU")
            return
        }
        defer { dovi_rpu_free(rpu) }
        // libdovi returns a handle even when parsing fails; only the error says it was accepted.
        #expect(dovi_rpu_get_error(rpu) == nil, "\(dovi_rpu_get_error(rpu).map { String(cString: $0) } ?? "")")
        guard let params = DoviFelComposer.parseRpuParameters(rpu: rpu) else {
            Issue.record("Failed to parse clip A RPU")
            return
        }

        // Luma pivots from clip A are delta-coded: 0 128 128 128 128 128 128 128 127
        let expectedLumaPivots: [UInt32] = [0, 128, 256, 384, 512, 640, 768, 896, 1023]
        #expect(params.polyY.numPivots == 9)
        for i in 0..<9 {
            #expect(params.polyY.pivots[i] == expectedLumaPivots[i], Comment("Pivot \(i) expected \(expectedLumaPivots[i]), got \(params.polyY.pivots[i])"))
        }
    }

    /// DoViBaker `getPivotIndex`: the first piece whose upper pivot the sample is below, and the last piece for
    /// anything at or above the top pivot. Pieces here are [0,128), [128,256), [256,1023] and each one's constant
    /// is distinct, so the output names the piece that was selected.
    @Test("piece selection on the GPU: boundaries belong to the upper piece and the top code selects the last piece")
    func pieceSelectionOnGpu() throws {
        let composer = try #require(DoviFelComposer())
        var poly = DoviPolynomialParams()
        poly.numPivots = 4
        poly.pivots[0] = 0; poly.pivots[1] = 128; poly.pivots[2] = 256; poly.pivots[3] = 1023
        let levels = [0.25, 0.5, 0.75]
        for piece in 0..<3 {
            poly.method[piece] = DoviMapping.polynomial.rawValue
            poly.order[piece] = 0
            poly.coefShift[piece] = 23
            poly.coef[piece] = [Int32(levels[piece] * 8388608.0), 0, 0]
        }
        var p = Self.rawParams(residual: false)
        p.polyY = poly

        let bl = try #require(H.makeBuffer(width: 1024, height: 4))
        let el = try #require(H.makeBuffer(width: 512, height: 2))
        H.fillPlane(bl, plane: 0, components: 1) { c, _, _ in min(c, 1023) }
        H.fillPlane(bl, plane: 1, components: 2) { _, _, _ in 512 }
        H.fillPlane(el, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(el, plane: 1, components: 2) { _, _, _ in 512 }
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p))
        let row = Array(DoviTestSupport.rawVDR(out)[0][0..<1024])
        let expected = [(0, 1024), (127, 1024), (128, 2048), (255, 2048), (256, 3072), (1000, 3072), (1023, 3072)]
        for (code, vdr) in expected {
            #expect(row[code] == vdr, "BL code \(code)")
        }
    }

    // MARK: - D4 & N1: polynomial coefficients and denominator

    /// DoViBaker `polynompialMapping`: the input is the BL code over 2^bl_bit_depth (1024, not 1023) and the
    /// result is in 12-bit VDR codes after 2^vdr_bit_depth (4096).
    @Test("polynomial reshaping on the GPU matches the closed form over all 1024 base-layer codes")
    func polynomialOverAllCodes() throws {
        let composer = try #require(DoviFelComposer())
        let c0 = 0.02, c1 = 0.95, c2 = 0.10
        var p = Self.rawParams(residual: false)
        p.polyY = Self.polynomial(c0, c1, c2, order: 2)
        // The coefficients the kernel actually receives, so the comparison is not about Int32 truncation.
        let q = p.polyY.coef[0].map { Double($0) / 8388608.0 }

        let bl = try #require(H.makeBuffer(width: 1024, height: 4))
        let el = try #require(H.makeBuffer(width: 512, height: 2))
        H.fillPlane(bl, plane: 0, components: 1) { c, _, _ in c }
        H.fillPlane(bl, plane: 1, components: 2) { _, _, _ in 512 }
        H.fillPlane(el, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(el, plane: 1, components: 2) { _, _, _ in 512 }
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: p))
        let row = DoviTestSupport.rawVDR(out)[0]
        var worst = 0.0
        for code in 0..<1024 {
            let x = Double(code) / 1024.0
            let exact = min(max((q[0] + q[1] * x + q[2] * x * x) * 4096.0, 0), 4095)
            worst = max(worst, abs(Double(row[code]) - exact))
        }
        #expect(worst <= 1.0, "worst deviation \(worst) VDR codes")
    }

    // MARK: - N3: prediction overshoot is capped before the residual is added

    @Test("N3: a prediction above the VDR range is capped at vdr_max before the residual is added")
    func predictionOvershootCappedBeforeResidual() throws {
        let composer = try #require(DoviFelComposer())
        // Prediction 1.02 -> 4178 12-bit codes (above vdr_max 4095); EL 312 -> r = -200 -> (399 * 2048) >> 12 = 199 -> -199.
        // DoViBaker caps the mapping result at 0xffff before the residual (`polynompialMapping` returns uint16_t):
        // (65535 - 3192 + 8) >> 4 = 3896, which is 4095 - 199. Adding first would give 4178 - 199 = 3979.
        var p = Self.rawParams(residual: true)
        p.polyY = Self.polynomial(1.02, order: 0)
        p.nlqY = DoviGpuEdgeCaseTests.nlq(vdrInMax: 4095)
        let out = try DoviGpuEdgeCaseTests.composeConstant(composer, bl: (512, 512, 512), el: (312, 512, 512), params: p)
        #expect(Set(DoviTestSupport.rawVDR(out)[0]) == [3896])
    }

    // MARK: - D2: chroma MMR on a real RPU

    @Test("D2: clip A order-3 chroma MMR parses, and maps mid-grey to mid-grey and a Cb sweep to the pinned curve")
    func chromaMmrOnRealRpu() throws {
        let clipABytes = Self.hexToBytes(Self.clipARpuHex)
        let rpu = try #require(dovi_parse_unspec62_nalu(clipABytes, clipABytes.count))
        defer { dovi_rpu_free(rpu) }
        #expect(dovi_rpu_get_error(rpu) == nil, "\(dovi_rpu_get_error(rpu).map { String(cString: $0) } ?? "")")
        var params = try #require(DoviFelComposer.parseRpuParameters(rpu: rpu))

        #expect(params.polyCb.usesMmr, "Cb curve must be MMR on clip A")
        #expect(params.polyCr.usesMmr, "Cr curve must be MMR on clip A")
        #expect(params.polyCb.order[0] == 3, Comment("Cb MMR order must be 3, got \(params.polyCb.order[0])"))
        #expect(params.polyCr.order[0] == 3, Comment("Cr MMR order must be 3, got \(params.polyCr.order[0])"))
        #expect(params.mmrCb.coefShift == 23, "MMR coef shift must be 23")

        params.ditherMode = .debugRawVDR
        params.flags.insert(.disableResidual)
        let composer = try #require(DoviFelComposer())

        // Chroma plane is 1024 wide for a 2048-wide base layer: column c carries Cb = c, with Y and Cr at mid-grey.
        let bl = try #require(H.makeBuffer(width: 2048, height: 4))
        let el = try #require(H.makeBuffer(width: 1024, height: 2))
        H.fillPlane(bl, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(bl, plane: 1, components: 2) { c, _, comp in comp == 0 ? c : 512 }
        H.fillPlane(el, plane: 0, components: 1) { _, _, _ in 512 }
        H.fillPlane(el, plane: 1, components: 2) { _, _, _ in 512 }
        let out = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params))
        let planes = DoviTestSupport.rawVDR(out, chromaOnly: true)
        let cb = Array(planes[1][0..<1024]).map { Double($0) / 4.0 }   // 10-bit equivalent codes
        let cr = Array(planes[2][0..<1024]).map { Double($0) / 4.0 }

        // Mid-grey in, mid-grey out: the property the flat-64 green collapse violated.
        #expect(abs(cb[512] - 512.0) < 2.0, "Cb(512) must be ~512, got \(cb[512])")
        #expect(abs(cr[512] - 512.0) < 2.0, "Cr at mid-grey input must be ~512, got \(cr[512])")

        let span = (cb.max() ?? 0) - (cb.min() ?? 0)
        #expect(span > 500.0, "Cb curve is nearly flat over the full input range (span \(span) codes)")
        var violations = 0
        for code in 1..<1024 where cb[code] < cb[code - 1] - 1.0 { violations += 1 }
        #expect(violations == 0, "Cb curve must be non-decreasing in its own component, \(violations) violations")

        // Regression anchors measured off this RPU through the composer (not independently derived; mid-grey above
        // is the derived check). They catch a piece, an order or a coefficient index shifting.
        for (code, anchor) in Self.chromaAnchors {
            #expect(abs(cb[code] - anchor) < 1.0, "Cb(\(code)) drifted: \(cb[code]), pinned \(anchor)")
        }
    }

    private static let chromaAnchors: [(Int, Double)] = [(0, 0.0), (256, 222.5), (768, 886.75), (1023, 1023.75)]

    // MARK: - Metal GPU Composition & Pixel Sanity Assertions

    @Test("Metal GPU Composition: Real RPU reconstructs 10-bit P010 without flat-64 green chroma")
    func metalGpuCompositionSanity() throws {
        guard let composer = DoviFelComposer() else {
            Issue.record("Failed to initialize DoviFelComposer")
            return
        }

        let clipABytes = Self.hexToBytes(Self.clipARpuHex)
        guard let rpu = dovi_parse_unspec62_nalu(clipABytes, clipABytes.count) else {
            Issue.record("Failed to parse clip A RPU")
            return
        }
        defer { dovi_rpu_free(rpu) }
        // libdovi returns a handle even when parsing fails; only the error says it was accepted.
        #expect(dovi_rpu_get_error(rpu) == nil, "\(dovi_rpu_get_error(rpu).map { String(cString: $0) } ?? "")")
        guard let params = DoviFelComposer.parseRpuParameters(rpu: rpu) else {
            Issue.record("Failed to parse clip A RPU")
            return
        }

        let w = 256, h = 256
        let pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

        var blBufferOpt: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, pixelFormat, [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary, &blBufferOpt)

        var elBufferOpt: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w / 2, h / 2, pixelFormat, [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary, &elBufferOpt)

        guard let blBuffer = blBufferOpt, let elBuffer = elBufferOpt else {
            Issue.record("Failed to allocate CVPixelBuffers")
            return
        }

        // Mid-grey base layer (luma 512, Cb/Cr 512) and a neutral enhancement
        // layer (512, the NLQ offset, so the residual is zero).
        //
        // Both go through the stride-aware helper. The previous version walked each
        // plane as `width * height` contiguous samples, which ignores row padding
        // and, for the enhancement layer's chroma plane, computed twice the
        // sample count the plane holds: it wrote 16 KiB past the end and faulted
        // whenever the pages behind the IOSurface happened not to be mapped.
        DoviGpuCurveSweepTests.fillPlane(blBuffer, plane: 0, components: 1) { _, _, _ in 512 }
        DoviGpuCurveSweepTests.fillPlane(blBuffer, plane: 1, components: 2) { _, _, _ in 512 }
        DoviGpuCurveSweepTests.fillPlane(elBuffer, plane: 0, components: 1) { _, _, _ in 512 }
        DoviGpuCurveSweepTests.fillPlane(elBuffer, plane: 1, components: 2) { _, _, _ in 512 }

        // Execute Metal GPU composition
        guard let dst = composer.compose(
            baseBuffer: blBuffer,
            enhancementBuffer: elBuffer,
            params: params,
            frameIndex: 1
        ) else {
            Issue.record("Composer returned nil")
            return
        }

        // Read back output pixels and assert that chroma is NOT flat 64
        CVPixelBufferLockBaseAddress(dst, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dst, .readOnly) }

        guard let outUvPtr = CVPixelBufferGetBaseAddressOfPlane(dst, 1) else {
            Issue.record("No output chroma plane")
            return
        }

        let outUv = outUvPtr.assumingMemoryBound(to: UInt16.self)
        let sampleCb = Int(outUv[0] >> 6)
        let sampleCr = Int(outUv[1] >> 6)

        // Mid-gray in -> mid-gray out (~512). A flat 64 would be the green-frame failure.
        #expect(sampleCb > 400 && sampleCb < 600, "Output Cb sample must be near mid-gray (~512), was \(sampleCb) (D2 flat 64 regression)")
        #expect(sampleCr > 400 && sampleCr < 600, "Output Cr sample must be near mid-gray (~512), was \(sampleCr) (D2 flat 64 regression)")

        guard let outYPtr = CVPixelBufferGetBaseAddressOfPlane(dst, 0) else {
            Issue.record("No output luma plane")
            return
        }
        let outY = outYPtr.assumingMemoryBound(to: UInt16.self)
        let sampleY = Int(outY[0] >> 6)
        #expect(sampleY > 400 && sampleY < 600, "Output Y sample must be near mid-gray (~512), was \(sampleY)")
    }
}
#endif
