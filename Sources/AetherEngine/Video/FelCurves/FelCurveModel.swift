// Only with the DolbyVisionFelCurves trait (off by default).
#if DolbyVisionFelCurves
import Foundation
import Dovi

/// One component's reshaping curve as the Profile 8.1 RPU carries it: absolute base-layer pivots and, per
/// piece, `c0, c1, c2` of `out = c0 + c1 * x + c2 * x^2` with input and output normalised to [0, 1].
struct FelCurve: Equatable, Sendable {
    var pivots: [UInt16]
    var coefs: [Double]

    var pieces: Int { pivots.count - 1 }

    /// Evaluates the curve at a normalised input, for tests and diagnostics.
    func value(at x: Double) -> Double {
        let code = x * 1023
        var piece = pieces - 1
        for i in 1..<pivots.count where code < Double(pivots[i]) {
            piece = i - 1
            break
        }
        let c = coefs[(3 * piece)..<(3 * piece + 3)].map { $0 }
        return c[0] + c[1] * x + c[2] * x * x
    }

    /// Pivots every `1024 / pieces` codes, the last one at 1023: the split Profile 7 streams use for luma.
    static func uniform(pieces: Int) -> [UInt16] {
        (0...pieces).map { UInt16(min(1023, $0 * 1024 / pieces)) }
    }

    static func identity(pivots: [UInt16]) -> FelCurve {
        FelCurve(pivots: pivots, coefs: Array(repeating: [0.0, 1.0, 0.0], count: pivots.count - 1).flatMap { $0 })
    }
}

extension FelCurve {
    /// This curve plus `delta`, coefficient by coefficient; nil unless both have the same pivots.
    func adding(_ delta: FelCurve) -> FelCurve? {
        guard pivots == delta.pivots, coefs.count == delta.coefs.count else { return nil }
        return FelCurve(pivots: pivots, coefs: zip(coefs, delta.coefs).map { $0 + $1 })
    }

    /// Writes the curve as one component's mapping of a Profile 8.1 RPU. False when libdovi refuses it.
    func apply(to rpu: OpaquePointer, component: UInt8) -> Bool {
        pivots.withUnsafeBufferPointer { p in
            coefs.withUnsafeBufferPointer { c in
                dovi_rpu_set_polynomial_mapping(rpu, component, p.baseAddress, p.count, c.baseAddress) == 0
            }
        }
    }
}

/// The linear dead-zone inverse quantiser of one component, in the composer's fixed point
/// (`DoviFelComposer.parseNlqParams` and `dovi_eval_inv_nlq` do the same arithmetic). The residual
/// comes out in VDR codes (12-bit for every stream surveyed).
struct FelNlq: Equatable, Sendable {
    var offset: Int32
    var scale: Int64
    var threshold: Int64
    var vdrInMax: Int64
    var shift: Int64

    func residual(elCode: Int) -> Int32 {
        let r = Int64(elCode) - Int64(offset)
        if r == 0 { return 0 }
        var mag = ((2 * r.magnitude.asInt64 - 1) * scale + 2 * threshold) >> (shift + 1)
        if vdrInMax > 0, mag > vdrInMax { mag = vdrInMax }
        if mag < 0 { mag = 0 }
        return Int32(r < 0 ? -mag : mag)
    }

    /// One lookup per possible enhancement-layer code.
    func table(elBits: Int) -> [Int32] {
        (0..<(1 << elBits)).map { residual(elCode: $0) }
    }
}

private extension UInt64 {
    var asInt64: Int64 { Int64(clamping: self) }
}

/// What the curve fold reads from one Profile 7 RPU before it is converted.
struct FelRpuInfo: Sendable {
    /// The stream's luma curve when it is a polynomial; the fold adds the residual to it.
    var luma: FelCurve?
    /// Per-component inverse quantisers; nil when the RPU carries no usable residual.
    var nlq: [FelNlq]?
    var sceneRefresh: Bool
    var vdrBits: Int
    var elBits: Int

    var carriesResidual: Bool { nlq != nil }

    /// Reads the header, the mapping and the scene flag of a parsed RPU.
    static func read(_ rpu: OpaquePointer) -> FelRpuInfo? {
        guard let header = dovi_rpu_get_header(rpu) else { return nil }
        defer { dovi_rpu_free_header(header) }
        let denom = Int(header.pointee.coefficient_log2_denom)
        let vdrBits = Int(header.pointee.vdr_bit_depth_minus8) + 8
        let elBits = Int(header.pointee.el_bit_depth_minus8) + 8
        guard header.pointee.coefficient_data_type == 0, denom > 0, denom <= 32 else { return nil }

        var info = FelRpuInfo(luma: nil, nlq: nil, sceneRefresh: false, vdrBits: vdrBits, elBits: elBits)
        if let dm = dovi_rpu_get_vdr_dm_data(rpu) {
            info.sceneRefresh = dm.pointee.scene_refresh_flag != 0
            dovi_rpu_free_vdr_dm_data(dm)
        }

        guard let mapping = dovi_rpu_get_data_mapping(rpu) else { return info }
        defer { dovi_rpu_free_data_mapping(mapping) }
        info.luma = polynomial(mapping.pointee.curves.0, denom: denom)

        let residualOn = !header.pointee.disable_residual_flag
        let isFEL = header.pointee.el_type.map { String(cString: $0) == "FEL" } ?? false
        if residualOn, isFEL, mapping.pointee.nlq_method_idc == 0, denom >= vdrBits, elBits <= 12,
           let nlq = mapping.pointee.nlq {
            let shift = Int64(denom - vdrBits)
            func fixed(_ int: UInt64, _ frac: UInt64) -> Int64 { (Int64(clamping: int) << Int64(denom)) + Int64(clamping: frac) }
            let n = nlq.pointee
            let offsets = [n.nlq_offset.0, n.nlq_offset.1, n.nlq_offset.2]
            let slopes = [fixed(n.linear_deadzone_slope_int.0, n.linear_deadzone_slope.0),
                          fixed(n.linear_deadzone_slope_int.1, n.linear_deadzone_slope.1),
                          fixed(n.linear_deadzone_slope_int.2, n.linear_deadzone_slope.2)]
            let thresholds = [fixed(n.linear_deadzone_threshold_int.0, n.linear_deadzone_threshold.0),
                              fixed(n.linear_deadzone_threshold_int.1, n.linear_deadzone_threshold.1),
                              fixed(n.linear_deadzone_threshold_int.2, n.linear_deadzone_threshold.2)]
            let maxima = [fixed(n.vdr_in_max_int.0, n.vdr_in_max.0),
                          fixed(n.vdr_in_max_int.1, n.vdr_in_max.1),
                          fixed(n.vdr_in_max_int.2, n.vdr_in_max.2)]
            let params = (0..<3).map {
                FelNlq(offset: Int32(offsets[$0]), scale: slopes[$0], threshold: thresholds[$0],
                       vdrInMax: maxima[$0] >> shift, shift: shift)
            }
            if params.allSatisfy({ $0.scale > 0 }) { info.nlq = params }
        }
        return info
    }

    /// A component's curve as absolute pivots and second-order coefficients, or nil for MMR or anything
    /// the RPU's own syntax would not allow.
    private static func polynomial(_ curve: DoviReshapingCurve, denom: Int) -> FelCurve? {
        guard curve.mapping_idc == 0, let poly = curve.polynomial else { return nil }
        let count = Int(curve.num_pivots_minus2) + 2
        guard let pivotData = curve.pivots.data, curve.pivots.len >= count else { return nil }
        var pivots: [UInt16] = []
        var running = 0
        for i in 0..<count {
            running += Int(pivotData[i])
            guard running <= 1023 else { return nil }
            pivots.append(UInt16(running))
        }
        guard zip(pivots, pivots.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        let pieces = count - 1
        guard let orders = poly.pointee.poly_order_minus1.data, poly.pointee.poly_order_minus1.len >= pieces,
              let ints = poly.pointee.poly_coef_int.list, poly.pointee.poly_coef_int.len >= pieces,
              let fracs = poly.pointee.poly_coef.list, poly.pointee.poly_coef.len >= pieces else { return nil }
        if let interp = poly.pointee.linear_interp_flag.data, poly.pointee.linear_interp_flag.len >= pieces,
           (0..<pieces).contains(where: { interp[$0] != 0 }) {
            return nil
        }
        let scale = Double(UInt64(1) << UInt64(denom))
        var coefs: [Double] = []
        for p in 0..<pieces {
            let order = Int(orders[p]) + 1
            guard order >= 1, order <= 2, let ip = ints[p], let fp = fracs[p],
                  let iv = ip.pointee.data, let fv = fp.pointee.data,
                  ip.pointee.len >= order + 1, fp.pointee.len >= order + 1 else { return nil }
            for j in 0..<3 {
                coefs.append(j <= order ? Double(iv[j]) + Double(fv[j]) / scale : 0)
            }
        }
        return FelCurve(pivots: pivots, coefs: coefs)
    }
}
#endif
