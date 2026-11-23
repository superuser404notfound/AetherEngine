import Foundation

/// The Lanczos-3 taps of one axis of a resample, one entry per output sample: the first of its six source
/// samples and their weights, normalised to sum to 1. Pure, so the arithmetic is testable where the Metal
/// stage is not built (the simulator). `LanczosPlaneScaler` uploads them once per plan.
///
/// Sample centres are aligned (output sample `o` sits at source position `(o + 0.5) * in / out - 0.5`), as
/// the rest of the upscale stage and the frame chain treat 4:2:0 chroma. For an upscale every tap the
/// kernel's support reaches is one of the six; a downscale would need a wider kernel and is not built.
struct LanczosTaps: Equatable {
    /// Six taps per output sample: Lanczos-3 is zero from three source samples out.
    static let count = 6
    /// The layout `LanczosShaderSource` reads: first index as a float, six weights, one pad float.
    static let stride = 8

    let inputCount: Int
    let outputCount: Int
    /// `outputCount * stride` floats.
    let table: [Float]

    init?(inputCount: Int, outputCount: Int) {
        guard inputCount > 0, outputCount >= inputCount else { return nil }
        self.inputCount = inputCount
        self.outputCount = outputCount
        let ratio = Double(inputCount) / Double(outputCount)
        var table = [Float](repeating: 0, count: outputCount * Self.stride)
        for o in 0..<outputCount {
            let centre = (Double(o) + 0.5) * ratio - 0.5
            let first = Int(centre.rounded(.down)) - 2
            var weights = (0..<Self.count).map { Self.kernel(centre - Double(first + $0)) }
            let sum = weights.reduce(0, +)
            weights = weights.map { $0 / sum }
            table[o * Self.stride] = Float(first)
            for k in 0..<Self.count { table[o * Self.stride + 1 + k] = Float(weights[k]) }
        }
        self.table = table
    }

    /// The first source index and the six weights of output sample `o`.
    func taps(at o: Int) -> (first: Int, weights: [Float]) {
        let base = o * Self.stride
        return (Int(table[base]), Array(table[(base + 1)...(base + Self.count)]))
    }

    /// sinc(x) * sinc(x / 3) for |x| < 3, else 0.
    static func kernel(_ x: Double) -> Double {
        let a = abs(x)
        guard a < 3 else { return 0 }
        guard a > 1e-9 else { return 1 }
        let px = Double.pi * a
        return 3 * sin(px) * sin(px / 3) / (px * px)
    }

    /// Runs the taps over one row of samples with edge replication, as the shader does. For the tests.
    func apply(_ samples: [Double]) -> [Double] {
        (0..<outputCount).map { o in
            let (first, weights) = taps(at: o)
            return (0..<Self.count).reduce(0.0) { acc, k in
                acc + Double(weights[k]) * samples[min(max(first + k, 0), samples.count - 1)]
            }
        }
    }
}
