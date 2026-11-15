import Foundation

/// The BT.2390 EETF (ITU-R BT.2390, section 5.4.1) from a source peak to a lower target peak, on PQ values
/// (AE#957). Below the knee the picture is left as it is; from the knee a Hermite spline rolls the rest of
/// the source range off into the target's top. Applied to each PQ-coded R'G'B' component, as BT.2390 does:
/// highlights above the target move toward white rather than clipping a channel.
///
/// Black is not mapped (source and target black are 0, as on an OLED), so everything below the knee is
/// unchanged to the code value. A black level lift for a panel with raised black can come later.
///
/// This is the CPU reference: `FrameChainToneMapParams` carries the same numbers to the shader.
struct BT2390ToneCurve: Equatable, Sendable {
    let sourcePeakNits: Double
    let targetPeakNits: Double
    /// PQ of the source peak: the top of the range the curve works on.
    let sourcePeakPQ: Double
    /// The target peak on the curve's 0...1 scale (PQ of the target over PQ of the source peak).
    let maxLum: Double
    /// Where the roll-off starts on the same scale (BT.2390's KS).
    let kneeStart: Double

    /// Nil when there is nothing to map (the target is at or above the source peak), when a value is not a
    /// usable luminance (0 to 10000 nit), or when the target is below a third of the source peak on the
    /// curve's scale (about 5 nit for a 1000 nit source): BT.2390's knee would then fall below 0, and a
    /// spline from 0 turns back down before it reaches the target.
    init?(sourcePeakNits: Double, targetPeakNits: Double) {
        guard sourcePeakNits.isFinite, targetPeakNits.isFinite, targetPeakNits > 0, sourcePeakNits <= 10_000,
              targetPeakNits < sourcePeakNits else { return nil }
        let peakPQ = Self.pq(nits: sourcePeakNits)
        let maxLum = Self.pq(nits: targetPeakNits) / peakPQ
        guard maxLum >= 1.0 / 3 else { return nil }
        self.sourcePeakNits = sourcePeakNits
        self.targetPeakNits = targetPeakNits
        sourcePeakPQ = peakPQ
        self.maxLum = maxLum
        kneeStart = 1.5 * maxLum - 0.5
    }

    /// One PQ value (0...1) through the curve. Values above the source peak land on the target peak.
    func map(pq e: Double) -> Double {
        let e1 = min(max(e / sourcePeakPQ, 0), 1)
        guard e1 >= kneeStart else { return e }
        let t = (e1 - kneeStart) / (1 - kneeStart)
        let t2 = t * t, t3 = t2 * t
        let p = (2 * t3 - 3 * t2 + 1) * kneeStart + (t3 - 2 * t2 + t) * (1 - kneeStart) + (-2 * t3 + 3 * t2) * maxLum
        return p * sourcePeakPQ
    }

    /// Where the roll-off starts, in nit (464 for a 1000 nit source and a 600 nit target).
    var kneeNits: Double { Self.nits(pq: kneeStart * sourcePeakPQ) }

    /// The light level in nit after the curve, for one light level in nit before it.
    func map(nits: Double) -> Double { Self.nits(pq: map(pq: Self.pq(nits: nits))) }

    /// The HDR10 metadata of the mapped picture: the target is the new mastering peak, and MaxCLL / MaxFALL
    /// are mapped by the same curve (0, which means unknown, stays 0).
    func outputMetadata(from source: HDR10StaticMetadata) -> HDR10StaticMetadata {
        func mapped(_ level: Int) -> Int {
            level > 0 ? max(1, Int(map(nits: Double(level)).rounded())) : 0
        }
        let maxCLL = mapped(source.maxCLL)
        let maxFALL = mapped(source.maxFALL)
        return HDR10StaticMetadata(maxCLL: maxCLL, maxFALL: maxCLL > 0 ? min(maxFALL, maxCLL) : maxFALL,
                                   masteringPeakNits: targetPeakNits, masteringMinNits: source.masteringMinNits)
    }

    // MARK: - PQ (SMPTE ST 2084)

    private static let m1 = 2610.0 / 16384
    private static let m2 = 2523.0 / 4096 * 128
    private static let c1 = 3424.0 / 4096
    private static let c2 = 2413.0 / 4096 * 32
    private static let c3 = 2392.0 / 4096 * 32

    /// The PQ value (0...1) of a luminance in nit.
    static func pq(nits: Double) -> Double {
        let y = pow(min(max(nits, 0), 10_000) / 10_000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    /// The luminance in nit of a PQ value (0...1).
    static func nits(pq e: Double) -> Double {
        let p = pow(min(max(e, 0), 1), 1 / m2)
        return 10_000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }
}

/// Which of the source's values set the peak the curve maps from.
public enum ToneMapSourcePeak: String, Equatable, Sendable {
    /// The mastering display's peak luminance.
    case mastering
    /// MaxCLL, the brightest pixel in the title, when it is below the mastering peak.
    case maxCLL

    /// MaxCLL when it is known (above 0) and below the mastering peak, else the mastering peak. Nil when
    /// the source gives neither.
    static func choose(masteringPeakNits: Double?, maxCLL: Int?) -> (nits: Double, from: ToneMapSourcePeak)? {
        let mastering = masteringPeakNits.flatMap { $0 > 0 ? $0 : nil }
        let brightest = maxCLL.flatMap { $0 > 0 ? Double($0) : nil }
        switch (mastering, brightest) {
        case let (m?, b?): return b < m ? (b, .maxCLL) : (m, .mastering)
        case let (m?, nil): return (m, .mastering)
        case let (nil, b?): return (b, .maxCLL)
        case (nil, nil): return nil
        }
    }
}

/// Layout matches `FrameChainToneMapParams` in `FrameChainShaderSource`. The roll-off is BT.2390's Hermite
/// spline expanded into one cubic in the spline's own coordinate and scaled to PQ, so the shader spends one
/// fused multiply-add on the coordinate and three on the cubic per component. On the A12 the chain is
/// limited by arithmetic: written out term by term, the curve took 4.5 ms of GPU time per 4K frame.
struct FrameChainToneMapParams: Equatable {
    /// The knee in PQ: values below it pass unchanged.
    var kneePQ: Float
    /// The spline's coordinate is `saturate(e * xScale - xOffset)`.
    var xScale: Float
    var xOffset: Float
    /// The roll-off in PQ: `((c3 * x + c2) * x + c1) * x + c0`.
    var c0: Float
    var c1: Float
    var c2: Float
    var c3: Float

    init(_ curve: BT2390ToneCurve) {
        let ks = curve.kneeStart, peak = curve.sourcePeakPQ, m = curve.maxLum
        let rollOff = 1 - ks
        kneePQ = Float(ks * peak)
        xScale = Float(1 / (peak * rollOff))
        xOffset = Float(ks / rollOff)
        // (2t^3 - 3t^2 + 1) ks + (t^3 - 2t^2 + t)(1 - ks) + (3t^2 - 2t^3) m, collected by power of t.
        c0 = Float(ks * peak)
        c1 = Float(rollOff * peak)
        c2 = Float((-3 * ks - 2 * rollOff + 3 * m) * peak)
        c3 = Float((2 * ks + rollOff - 2 * m) * peak)
    }
}
