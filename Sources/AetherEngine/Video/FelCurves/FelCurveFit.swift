// Only with the DolbyVisionFelCurves trait (off by default).
#if DolbyVisionFelCurves
import Foundation

/// Base-layer luma codes and the luma residual the enhancement layer adds at the same place, one entry per
/// sampled pixel. Codes are the base layer's own (10-bit); residuals are VDR codes as the inverse quantiser
/// produces them.
struct FelCurveSamples: Sendable {
    var base: [Float] = []
    var residual: [Float] = []

    var count: Int { base.count }
}

/// The residual a scene's enhancement layer adds to luma, as a curve over base-layer luma that is added to
/// the stream's own luma polynomial coefficient by coefficient (`FelCurve.adding(_:)`).
///
/// An ordinary least-squares fit over the samples with the pivots fixed in advance (the stream's luma
/// pivots). Chroma is not fitted: the stream's own chroma mapping stays in the RPU and is applied by the
/// platform decoder, and the chroma residual adds nothing measurable on top of it. Nothing here evaluates
/// the stream's mapping on a pixel.
enum FelCurveFit {
    static let lumaPieces = 8
    /// A piece with fewer samples gets no residual.
    static let minimumSamplesPerPiece = 30

    static func lumaResidual(_ samples: FelCurveSamples, pivots: [UInt16], baseBits: Int = 10, vdrBits: Int = 12) -> FelCurve {
        let coefs = residualCurve(base: samples.base, residual: samples.residual, pivots: pivots,
                                  baseMax: Double((1 << baseBits) - 1), vdrMax: Double((1 << vdrBits) - 1))
        return FelCurve(pivots: pivots, coefs: coefs)
    }

    /// Per piece, the second-order polynomial in normalised base-layer input that best fits the normalised
    /// residual, by least squares. Zero for a piece with too few samples or a singular system.
    static func residualCurve(base: [Float], residual: [Float], pivots: [UInt16], baseMax: Double, vdrMax: Double) -> [Double] {
        let pieces = pivots.count - 1
        // Normal equations per piece: sums of x^0..x^4 and of y * x^0..x^2.
        var sx = [[Double]](repeating: [Double](repeating: 0, count: 5), count: pieces)
        var sy = [[Double]](repeating: [Double](repeating: 0, count: 3), count: pieces)
        var n = [Int](repeating: 0, count: pieces)
        var lo = [Double](repeating: .infinity, count: pieces)
        var hi = [Double](repeating: -.infinity, count: pieces)
        let upper = pivots.dropFirst().map { Float($0) }
        for i in 0..<min(base.count, residual.count) {
            let code = base[i]
            var piece = pieces - 1
            for p in 0..<(pieces - 1) where code < upper[p] {
                piece = p
                break
            }
            let x = Double(code) / baseMax
            let y = Double(residual[i]) / vdrMax
            let x2 = x * x
            sx[piece][0] += 1
            sx[piece][1] += x
            sx[piece][2] += x2
            sx[piece][3] += x2 * x
            sx[piece][4] += x2 * x2
            sy[piece][0] += y
            sy[piece][1] += y * x
            sy[piece][2] += y * x2
            n[piece] += 1
            lo[piece] = min(lo[piece], x)
            hi[piece] = max(hi[piece], x)
        }
        var fitted: [[Double]?] = []
        for p in 0..<pieces {
            // A parabola fitted to samples bunched in part of a piece is unconstrained over the rest of it,
            // where another frame of the scene may well have pixels, so a narrow spread gets a lower order.
            let width = Double(pivots[p + 1] - pivots[p]) / baseMax
            let spread = n[p] > 0 ? (hi[p] - lo[p]) / width : 0
            let order = spread >= 0.5 ? 3 : (spread >= 0.1 ? 2 : 1)
            fitted.append(n[p] >= minimumSamplesPerPiece ? solve(sx[p], sy[p], maxTerms: order) : nil)
        }
        return bridgeEmptyPieces(fitted, pivots: pivots, baseMax: baseMax).flatMap { $0 }
    }

    /// The fit sees one frame per scene, so a scene that opens dark leaves its bright pieces without samples.
    /// A zero residual there dropped later highlights back to base-layer level with a step at the pivot
    /// (Minions, 45 to 65 VDR codes too dark above code 512). An empty piece therefore holds the edge value
    /// of its fitted neighbour, or runs straight between both neighbours' edges, so the curve stays continuous.
    /// Without any fitted piece the residual stays zero.
    static func bridgeEmptyPieces(_ fitted: [[Double]?], pivots: [UInt16], baseMax: Double) -> [[Double]] {
        func value(_ w: [Double], _ x: Double) -> Double { w[0] + w[1] * x + w[2] * x * x }
        func x(_ pivot: Int) -> Double { Double(pivots[pivot]) / baseMax }
        var out = fitted.map { $0 ?? [0, 0, 0] }
        var p = 0
        while p < fitted.count {
            guard fitted[p] == nil else { p += 1; continue }
            var end = p
            while end + 1 < fitted.count, fitted[end + 1] == nil { end += 1 }
            let left = p > 0 ? fitted[p - 1].map { value($0, x(p)) } : nil
            let right = end + 1 < fitted.count ? fitted[end + 1].map { value($0, x(end + 1)) } : nil
            let line: [Double]
            switch (left, right) {
            case let (l?, r?):
                let slope = (r - l) / (x(end + 1) - x(p))
                line = [l - slope * x(p), slope, 0]
            case let (l?, nil): line = [l, 0, 0]
            case let (nil, r?): line = [r, 0, 0]
            case (nil, nil): line = [0, 0, 0]
            }
            for q in p...end { out[q] = line }
            p = end + 1
        }
        return out
    }

    /// Solves the normal equations for up to `maxTerms` terms by Gaussian elimination with partial pivoting; falls back to a line
    /// and then to a constant when the samples of a piece span too few distinct codes for a parabola.
    static func solve(_ s: [Double], _ t: [Double], maxTerms: Int = 3) -> [Double]? {
        func eliminate(_ size: Int) -> [Double]? {
            var a = (0..<size).map { r in (0..<size).map { s[r + $0] } + [t[r]] }
            for col in 0..<size {
                guard let pivot = (col..<size).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }) else { return nil }
                guard abs(a[pivot][col]) > 1e-12 * max(1, abs(s[0])) else { return nil }
                a.swapAt(col, pivot)
                for r in 0..<size where r != col {
                    let f = a[r][col] / a[col][col]
                    for k in col...size { a[r][k] -= f * a[col][k] }
                }
            }
            let w = (0..<size).map { a[$0][size] / a[$0][$0] }
            return w.allSatisfy(\.isFinite) ? w : nil
        }
        if maxTerms >= 3, let w = eliminate(3) { return w }
        if maxTerms >= 2, let w = eliminate(2) { return w + [0] }
        if let w = eliminate(1) { return w + [0, 0] }
        return nil
    }
}
#endif
