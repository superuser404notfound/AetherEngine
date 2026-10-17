// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
import Metal
@testable import AetherEngine

/// Runs the real composition kernels over every base-layer code and compares the
/// result against ``DolbyVisionStillConverter/ReshapeCurve`` in Swift.
///
/// The rest of the suite re-implements the shader's arithmetic in Swift and tests
/// the re-implementation, so it would pass unchanged if the Metal source diverged
/// from it. These tests execute `dovi_compose_luma` and `dovi_compose_chroma` and
/// read the output planes back, which is the only way the two can disagree and be
/// caught. They are built around the cases a single-piece test cannot see:
/// per-piece order, per-piece coefficient denominators, and per-piece MMR
/// coefficients.
@Suite(.offCooperativePoolOneLane)
struct DoviGpuCurveSweepTests {

    static let blWidth = 1024
    static let blHeight = 4

    // MARK: - Buffer helpers

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

    /// Writes one 10-bit code per (plane, column, row) through `value`, honouring
    /// the plane's own stride. P010 is MSB-aligned, hence the shift by 6.
    static func fillPlane(
        _ buffer: CVPixelBuffer,
        plane: Int,
        components: Int,
        _ value: (_ column: Int, _ row: Int, _ component: Int) -> Int
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        for row in 0..<height {
            let rowPtr = (base + row * bytesPerRow).assumingMemoryBound(to: UInt16.self)
            for column in 0..<width {
                for c in 0..<components {
                    rowPtr[column * components + c] = UInt16(value(column, row, c) << 6)
                }
            }
        }
    }

    static func readPlane(
        _ buffer: CVPixelBuffer,
        plane: Int,
        components: Int,
        row: Int
    ) -> [[Int]] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return [] }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let rowPtr = (base + row * bytesPerRow).assumingMemoryBound(to: UInt16.self)
        var out: [[Int]] = []
        out.reserveCapacity(width)
        for column in 0..<width {
            var sample: [Int] = []
            for c in 0..<components {
                sample.append(Int(rowPtr[column * components + c] >> 6))
            }
            out.append(sample)
        }
        return out
    }

    // MARK: - Reference output stage

    /// The quantisation the kernels apply after the curve: denormalise by
    /// `bl_max * vdr_scale`, clamp to the VDR range, then round down to the output
    /// plane and clamp to video range. Dither is off for these tests, so the
    /// kernel's bias is a flat 0.5 and the result is exactly reproducible.
    static func quantize(predNorm: Double, blMax: Int, vdrScale: Int, vdrMax: Int, lo: Int, hi: Int) -> Int {
        let vdr = min(max(Int((predNorm * Double(blMax) * Double(vdrScale)).rounded(.toNearestOrEven)), 0), vdrMax)
        let scaled = Double(vdr) / Double(vdrScale)
        return min(max(Int(floor(scaled + 0.5)), lo), hi)
    }

    /// Exact value of an RPU-style Q(shift) coefficient, so the reference and the
    /// shader are compared on the same number rather than on the intended one.
    static func fp(_ value: Double, shift: UInt32) -> (fixed: Int32, exact: Double) {
        let scale = Double(1 << shift)
        let fixed = Int32(value * scale)
        return (fixed, Double(fixed) / scale)
    }

    static func identityCurve() -> DoviPolynomialParams {
        var poly = DoviPolynomialParams()
        poly.numPivots = 2
        poly.pivots[0] = 0
        poly.pivots[1] = 1023
        poly.method[0] = DoviMapping.polynomial.rawValue
        poly.order[0] = 1
        poly.coef[0] = [0, 1 << 23, 0]
        poly.coefShift[0] = 23
        return poly
    }

    // MARK: - Luma: multi-piece polynomial

    // The reference curve is the still converter's, compiled only with DolbyVisionStillReshaping.
    #if DolbyVisionStillReshaping
    @Test("GPU luma sweep: a 3-piece polynomial with per-piece order and denominator matches the reference curve")
    func lumaMultiPiecePolynomialSweep() throws {
        guard let composer = DoviFelComposer() else {
            Issue.record("Failed to initialize DoviFelComposer")
            return
        }

        let blMax = 1023
        let pivotCodes: [UInt32] = [0, 256, 700, 1023]

        // Piece 1 deliberately uses a different coefficient denominator and a
        // quadratic term: a kernel that read piece 0's order or shift for every
        // piece would pass a single-piece test and fail here.
        let shifts: [UInt32] = [23, 20, 23]
        let intended: [[Double]] = [
            [0.08, 0.90, 0.00],
            [0.05, 0.70, 0.20],
            [0.30, 0.55, 0.00]
        ]
        let orders: [UInt32] = [1, 2, 1]

        var poly = DoviPolynomialParams()
        poly.numPivots = UInt32(pivotCodes.count)
        for (i, pivot) in pivotCodes.enumerated() { poly.pivots[i] = pivot }

        var exact: [[Double]] = []
        for piece in 0..<3 {
            poly.method[piece] = DoviMapping.polynomial.rawValue
            poly.order[piece] = orders[piece]
            poly.coefShift[piece] = shifts[piece]
            var row: [Double] = []
            for j in 0..<3 {
                let c = Self.fp(intended[piece][j], shift: shifts[piece])
                // Coefficients above the piece's order are not read by the kernel,
                // so the reference must zero them rather than trust the table.
                let live = UInt32(j) <= orders[piece]
                poly.coef[piece][j] = live ? c.fixed : 0
                row.append(live ? c.exact : 0)
            }
            exact.append(row)
        }

        var params = DoviMetalParams()
        params.ditherMode = .none
        params.flags = [.disableResidual]   // this test is about the curve, not the residual
        params.polyY = poly
        params.polyCb = Self.identityCurve()
        params.polyCr = Self.identityCurve()

        guard let bl = Self.makeBuffer(width: Self.blWidth, height: Self.blHeight),
              let el = Self.makeBuffer(width: Self.blWidth / 2, height: Self.blHeight / 2) else {
            Issue.record("Failed to allocate CVPixelBuffers")
            return
        }
        // One base-layer code per column, so a single row of output covers the
        // whole 10-bit input domain.
        Self.fillPlane(bl, plane: 0, components: 1) { column, _, _ in column }
        Self.fillPlane(bl, plane: 1, components: 2) { _, _, _ in 512 }
        Self.fillPlane(el, plane: 0, components: 1) { _, _, _ in 512 }
        Self.fillPlane(el, plane: 1, components: 2) { _, _, _ in 512 }

        guard let dst = composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 0) else {
            Issue.record("Composer returned nil")
            return
        }

        let reference = DolbyVisionStillConverter.ReshapeCurve(
            pivots: pivotCodes.map { Double($0) / Double(blMax) },
            isMMR: [false, false, false],
            poly: exact,
            mmrOrder: [0, 0, 0],
            mmrConst: [0, 0, 0],
            mmrCoef: [[[]], [[]], [[]]]
        )

        let output = Self.readPlane(dst, plane: 0, components: 1, row: 0)
        #expect(output.count == Self.blWidth)

        var worst = 0
        var worstCode = -1
        for code in 0..<min(output.count, 1024) {
            let x = Double(code) / Double(blMax)
            let expected = Self.quantize(
                predNorm: reference.map(x, (x, 0.5, 0.5)),
                blMax: blMax, vdrScale: 4, vdrMax: 4095, lo: 64, hi: 940
            )
            let diff = abs(output[code][0] - expected)
            if diff > worst {
                worst = diff
                worstCode = code
            }
        }
        #expect(worst <= 1,
                "GPU luma output diverges from the reference curve by \(worst) codes at BL \(worstCode)")

        // A curve that landed on a single piece everywhere, or collapsed to
        // identity, would still satisfy a tolerance check, so pin two interior
        // points that only the correct piece can produce.
        // BL 100 sits in piece 0: 0.08 + 0.9 * 100/1023 = 0.1680 -> 172.
        // BL 900 sits in piece 2: 0.30 + 0.55 * 900/1023 = 0.7839 -> 802.
        #expect(abs(output[100][0] - 172) <= 1, "piece 0 not applied at BL 100: got \(output[100][0])")
        #expect(abs(output[900][0] - 802) <= 1, "piece 2 not applied at BL 900: got \(output[900][0])")
    }

    // MARK: - Chroma: per-piece MMR

    @Test("GPU chroma sweep: MMR coefficients are read per reshaping piece, not only from piece 0")
    func chromaPerPieceMmrSweep() throws {
        guard let composer = DoviFelComposer() else {
            Issue.record("Failed to initialize DoviFelComposer")
            return
        }

        let blMax = 1023
        let shift: UInt32 = 23
        let pivotCodes: [UInt32] = [0, 512, 1023]

        // Two MMR pieces whose coefficients differ enough that reading piece 0 for
        // the whole range is off by ~160 codes at the top of the sweep, well past
        // any float tolerance. Piece 1 is order 2, so it also catches an
        // implementation that reuses piece 0's order.
        let constants = [Self.fp(0.02, shift: shift), Self.fp(-0.05, shift: shift)]
        let piece0Order0 = [0.10, 0.80, 0.05, 0, 0, 0, 0]
        let piece1Order0 = [0.05, 1.10, 0.02, 0, 0, 0, 0]
        let piece1Order1 = [0.00, -0.35, 0.00, 0, 0, 0, 0]

        var poly = DoviPolynomialParams()
        poly.numPivots = UInt32(pivotCodes.count)
        for (i, pivot) in pivotCodes.enumerated() { poly.pivots[i] = pivot }
        poly.method[0] = DoviMapping.mmr.rawValue
        poly.method[1] = DoviMapping.mmr.rawValue
        poly.order[0] = 1
        poly.order[1] = 2

        var mmr = DoviMmrParams()
        mmr.coefShift = shift
        mmr.constant[0] = constants[0].fixed
        mmr.constant[1] = constants[1].fixed

        var exactCoef: [[[Double]]] = [
            [Array(repeating: 0.0, count: 7), Array(repeating: 0.0, count: 7), Array(repeating: 0.0, count: 7)],
            [Array(repeating: 0.0, count: 7), Array(repeating: 0.0, count: 7), Array(repeating: 0.0, count: 7)]
        ]
        for (k, value) in piece0Order0.enumerated() {
            let c = Self.fp(value, shift: shift)
            mmr.coef[0][k] = c.fixed
            exactCoef[0][0][k] = c.exact
        }
        for (k, value) in piece1Order0.enumerated() {
            let c = Self.fp(value, shift: shift)
            mmr.coef[1][k] = c.fixed
            exactCoef[1][0][k] = c.exact
        }
        for (k, value) in piece1Order1.enumerated() {
            let c = Self.fp(value, shift: shift)
            mmr.coef[1][7 + k] = c.fixed
            exactCoef[1][1][k] = c.exact
        }

        var params = DoviMetalParams()
        params.ditherMode = .none
        params.flags = [.disableResidual]
        params.polyY = Self.identityCurve()
        params.polyCb = poly
        params.mmrCb = mmr
        params.polyCr = Self.identityCurve()

        guard let bl = Self.makeBuffer(width: Self.blWidth, height: Self.blHeight),
              let el = Self.makeBuffer(width: Self.blWidth / 2, height: Self.blHeight / 2) else {
            Issue.record("Failed to allocate CVPixelBuffers")
            return
        }
        // Constant luma so the cross terms are a known y, and two codes of Cb per
        // chroma column so the 512-wide plane still sweeps the full input range.
        let lumaCode = 512
        Self.fillPlane(bl, plane: 0, components: 1) { _, _, _ in lumaCode }
        Self.fillPlane(bl, plane: 1, components: 2) { column, _, component in
            component == 0 ? min(column * 2, 1023) : 512
        }
        Self.fillPlane(el, plane: 0, components: 1) { _, _, _ in 512 }
        Self.fillPlane(el, plane: 1, components: 2) { _, _, _ in 512 }

        guard let dst = composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 0) else {
            Issue.record("Composer returned nil")
            return
        }

        let reference = DolbyVisionStillConverter.ReshapeCurve(
            pivots: pivotCodes.map { Double($0) / Double(blMax) },
            isMMR: [true, true],
            poly: [[0, 0, 0], [0, 0, 0]],
            mmrOrder: [1, 2],
            mmrConst: [constants[0].exact, constants[1].exact],
            mmrCoef: exactCoef
        )

        let output = Self.readPlane(dst, plane: 1, components: 2, row: 0)
        #expect(output.count == Self.blWidth / 2)

        let y = Double(lumaCode) / Double(blMax)
        let v = Double(512) / Double(blMax)

        var worst = 0
        var worstColumn = -1
        for column in 0..<output.count {
            let cbCode = min(column * 2, 1023)
            let u = Double(cbCode) / Double(blMax)
            let expected = Self.quantize(
                predNorm: reference.map(u, (y, u, v)),
                blMax: blMax, vdrScale: 4, vdrMax: 4095, lo: 64, hi: 960
            )
            let diff = abs(output[column][0] - expected)
            if diff > worst {
                worst = diff
                worstColumn = column
            }
            // Cr is identity, so it also shows whether the two curves were mixed up.
            #expect(abs(output[column][1] - 512) <= 1,
                    "Cr must pass through at 512, got \(output[column][1]) at column \(column)")
        }
        #expect(worst <= 2,
                "GPU chroma output diverges from the reference MMR curve by \(worst) codes at column \(worstColumn)")

        // Explicit N4 guard: at the top of the range piece 1 must be in force.
        // Piece 1 at u = 1022/1023 gives ~0.7372 -> ~754 codes; evaluating piece 0
        // there would give ~0.9207 -> ~942, so the two readings cannot be confused.
        let top = output.count - 1
        #expect(output[top][0] < 800,
                "the top of the sweep used piece 0's MMR coefficients: got \(output[top][0])")
    }

    // MARK: - Identity is bit-exact
    #endif

    @Test("GPU identity curve is bit-exact: every base-layer code survives the round trip")
    func identityCurveIsBitExact() throws {
        guard let composer = DoviFelComposer() else {
            Issue.record("Failed to initialize DoviFelComposer")
            return
        }

        var params = DoviMetalParams()
        params.ditherMode = .none
        params.flags = [.disableResidual]
        params.polyY = Self.identityCurve()
        params.polyCb = Self.identityCurve()
        params.polyCr = Self.identityCurve()

        guard let bl = Self.makeBuffer(width: Self.blWidth, height: Self.blHeight),
              let el = Self.makeBuffer(width: Self.blWidth / 2, height: Self.blHeight / 2) else {
            Issue.record("Failed to allocate CVPixelBuffers")
            return
        }
        Self.fillPlane(bl, plane: 0, components: 1) { column, _, _ in column }
        Self.fillPlane(bl, plane: 1, components: 2) { column, _, _ in min(column * 2, 1023) }
        Self.fillPlane(el, plane: 0, components: 1) { _, _, _ in 512 }
        Self.fillPlane(el, plane: 1, components: 2) { _, _, _ in 512 }

        guard let dst = composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 0) else {
            Issue.record("Composer returned nil")
            return
        }

        // Denormalising by bl_max * vdr_scale (1023 * 4) rather than vdr_max is
        // what makes this exact; * 4095 would drift by up to 3 codes at the top.
        let output = Self.readPlane(dst, plane: 0, components: 1, row: 0)
        for code in 64...940 {
            #expect(output[code][0] == code,
                    "identity curve changed BL code \(code) into \(output[code][0])")
        }
        // Below and above the video range the output saturates instead.
        #expect(output[0][0] == 64)
        #expect(output[1023][0] == 940)
    }
}
#endif
