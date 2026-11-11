import Foundation
import AetherLibavutil

/// AE#1036: lifts a quiet source toward `AudioShaping.loudnessTargetLUFS`.
///
/// The programme loudness is measured as ITU-R BS.1770 / EBU R128 integrated loudness (K-weighting,
/// 400 ms blocks every 100 ms, absolute gate at -70 LUFS, relative gate 10 LU under the ungated
/// mean) over everything this source has played so far. The gain that would bring it to the
/// target moves toward that value at a bounded rate and never goes below 0 dB, so a source already
/// at or above the target plays as it was. The gain is applied at the graph's input, in front of
/// the compressor and the limiter that keeps it from clipping.
///
/// It is causal and adds no latency: a chunk is played at the gain the history before it asked
/// for, and measured afterwards. Silence is gated out of the measurement, so a pause or a quiet
/// stretch holds the gain where it is instead of pulling it up.
///
/// Why not libavfilter's `loudnorm`: its dynamic mode only accepts 192 kHz input and holds back
/// three seconds of audio before its first output, which every start, seek and live tune would pay.
///
/// Not thread safe: `AudioShapingGraph` calls it under its owner's lock.
final class LoudnessNormalizer {

    /// The fastest the gain rises, in dB per second. A quiet film's first seconds come up as a
    /// fade over a few seconds rather than as a step.
    static let riseDBPerSecond: Double = 2
    /// The fastest the gain falls, in dB per second, when the measured loudness rises.
    static let fallDBPerSecond: Double = 6

    let targetLUFS: Double
    let maxGainDB: Double
    private let sampleRate: Double
    private let channels: Int
    /// BS.1770 channel weights: 1 for the fronts, 1.41 for the surrounds, 0 for the LFE.
    private let weights: [Double]
    private let filter: KWeighting
    private var state: [KWeighting.State]

    /// Samples per 100 ms step.
    private let stepLength: Int
    private var stepFill = 0
    private var stepEnergy = 0.0
    /// The last four steps' energies; a 400 ms block is their mean.
    private var recentSteps: [Double] = []
    /// Gating histogram over block loudness, 0.1 LU wide bins from -70 to +5 LUFS: integrated
    /// loudness over a whole film in constant memory and constant time per step.
    private var histogramEnergy = [Double](repeating: 0, count: LoudnessNormalizer.bins)
    private var histogramCount = [Int](repeating: 0, count: LoudnessNormalizer.bins)
    private static let bins = 750
    private static let floorLUFS = -70.0
    private static let binWidth = 0.1

    /// The gain in force, in dB, and the one the measurement currently asks for.
    private(set) var gainDB = 0.0
    private var desiredGainDB = 0.0

    init(targetLUFS: Double, maxGainDB: Double, sampleRate: Int32, layout: UnsafePointer<AVChannelLayout>) {
        self.targetLUFS = targetLUFS
        self.maxGainDB = maxGainDB
        self.sampleRate = Double(sampleRate)
        channels = Int(layout.pointee.nb_channels)
        weights = (0..<Int32(channels)).map { Self.weight(av_channel_layout_channel_from_index(layout, UInt32($0))) }
        filter = KWeighting(sampleRate: Double(sampleRate))
        state = Array(repeating: KWeighting.State(), count: channels)
        stepLength = max(1, Int(sampleRate) / 10)
    }

    static func weight(_ channel: AVChannel) -> Double {
        switch channel {
        case AV_CHAN_LOW_FREQUENCY, AV_CHAN_LOW_FREQUENCY_2: return 0
        case AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT, AV_CHAN_BACK_LEFT, AV_CHAN_BACK_RIGHT,
             AV_CHAN_BACK_CENTER, AV_CHAN_SURROUND_DIRECT_LEFT, AV_CHAN_SURROUND_DIRECT_RIGHT: return 1.41
        default: return 1
        }
    }

    /// Integrated loudness of everything measured so far, in LUFS; nil before the first block
    /// that clears the absolute gate.
    var integratedLUFS: Double? {
        var energy = 0.0, count = 0
        for b in 0..<Self.bins where histogramCount[b] > 0 {
            energy += histogramEnergy[b]; count += histogramCount[b]
        }
        guard count > 0 else { return nil }
        let relativeGate = Self.lufs(energy / Double(count)) - 10
        let first = max(0, Int(((relativeGate - Self.floorLUFS) / Self.binWidth).rounded(.up)))
        energy = 0; count = 0
        for b in first..<Self.bins where histogramCount[b] > 0 {
            energy += histogramEnergy[b]; count += histogramCount[b]
        }
        return count > 0 ? Self.lufs(energy / Double(count)) : nil
    }

    static func lufs(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }

    /// Applies the gain to `frames` frames of interleaved Float32 from `input` into `output`, then
    /// measures `input`.
    func process(_ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>, frames: Int) {
        let g0 = pow(10, gainDB / 20)
        let g1 = pow(10, advanceGain(frames: frames) / 20)
        // Linear ramp across the chunk, so a gain change never lands as a step.
        for f in 0..<frames {
            let g = Float(frames > 1 ? g0 + (g1 - g0) * Double(f) / Double(frames - 1) : g1)
            for c in 0..<channels { output[f * channels + c] = input[f * channels + c] * g }
        }
        measure(input, frames: frames)
    }

    /// Moves the gain toward the measurement's ask by at most the slew over `frames` samples.
    private func advanceGain(frames: Int) -> Double {
        let seconds = Double(frames) / sampleRate
        if desiredGainDB > gainDB {
            gainDB = min(desiredGainDB, gainDB + Self.riseDBPerSecond * seconds)
        } else {
            gainDB = max(desiredGainDB, gainDB - Self.fallDBPerSecond * seconds)
        }
        return gainDB
    }

    private func measure(_ samples: UnsafePointer<Float>, frames: Int) {
        for f in 0..<frames {
            var sum = 0.0
            for c in 0..<channels where weights[c] > 0 {
                let y = filter.run(Double(samples[f * channels + c]), &state[c])
                sum += weights[c] * y * y
            }
            stepEnergy += sum
            stepFill += 1
            if stepFill == stepLength { closeStep() }
        }
    }

    private func closeStep() {
        recentSteps.append(stepEnergy / Double(stepLength))
        stepEnergy = 0
        stepFill = 0
        if recentSteps.count > 4 { recentSteps.removeFirst() }
        guard recentSteps.count == 4 else { return }
        let block = recentSteps.reduce(0, +) / 4
        guard block > 0 else { return }
        let loudness = Self.lufs(block)
        guard loudness >= Self.floorLUFS else { return }
        let bin = min(Self.bins - 1, Int((loudness - Self.floorLUFS) / Self.binWidth))
        histogramEnergy[bin] += block
        histogramCount[bin] += 1
        if let measured = integratedLUFS {
            desiredGainDB = min(max(targetLUFS - measured, 0), maxGainDB)
        }
    }

    /// Forgets the filter history, not the loudness: after a seek the source is still the same
    /// programme, so its measurement and the gain carry on.
    func resetFilters() {
        state = Array(repeating: KWeighting.State(), count: channels)
        stepFill = 0
        stepEnergy = 0
        recentSteps.removeAll(keepingCapacity: true)
    }
}

/// BS.1770's K-weighting: a high shelf (+4 dB above about 1.5 kHz, the head's effect) followed by
/// a high-pass at about 38 Hz. Coefficients are derived for the rate from the analogue
/// prototypes, as libebur128 does, so 44.1, 48 and 96 kHz all read the same.
struct KWeighting {
    struct State { var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0, z1 = 0.0, z2 = 0.0 }

    private let b0, b1, b2, a1, a2: Double
    private let a1h, a2h: Double

    init(sampleRate: Double) {
        var f0 = 1681.974450955533, q = 0.7071752369554196
        let g = 3.999843853973347
        var k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        b0 = (vh + vb * k / q + k * k) / a0
        b1 = 2 * (k * k - vh) / a0
        b2 = (vh - vb * k / q + k * k) / a0
        a1 = 2 * (k * k - 1) / a0
        a2 = (1 - k / q + k * k) / a0
        f0 = 38.13547087602444; q = 0.5003270373238773
        k = tan(Double.pi * f0 / sampleRate)
        let a0h = 1 + k / q + k * k
        a1h = 2 * (k * k - 1) / a0h
        a2h = (1 - k / q + k * k) / a0h
    }

    func run(_ x: Double, _ s: inout State) -> Double {
        let y = b0 * x + b1 * s.x1 + b2 * s.x2 - a1 * s.y1 - a2 * s.y2
        // The high-pass numerator is 1, -2, 1 unnormalized, as in the spec's 48 kHz table.
        let z = y - 2 * s.y1 + s.y2 - a1h * s.z1 - a2h * s.z2
        s.x2 = s.x1; s.x1 = x
        s.y2 = s.y1; s.y1 = y
        s.z2 = s.z1; s.z1 = z
        return z
    }
}
