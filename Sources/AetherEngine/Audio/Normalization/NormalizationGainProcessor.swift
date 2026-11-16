import Foundation
import os

/// Sodalite#242: a fixed gain with a lookahead peak limiter behind it, run on Float32 PCM.
///
/// The gain is a track's loudness correction (ReplayGain, Jellyfin's `NormalizationGain`), so it is
/// constant for a whole track and only changes when the host asks. A lift can push peaks past full
/// scale, so a limiter holds them at `ceilingDBFS`. It runs for a cut too, where it only acts on a
/// source that already peaks above the ceiling after the cut: switching it on mid-track when a cut
/// turns into a lift would play the empty delay line as a 5 ms hole.
///
/// The limiter looks `lookaheadFrames` ahead, so the output trails the input by that many frames
/// (about 5 ms). The gain curve is a sliding minimum of the required gain over the lookahead plus
/// one frame, box-averaged over the same length, so every value the average takes in while a peak
/// sits in the delay line is at or below that peak's required gain: it never overshoots. A slower release on top keeps bass notes from
/// pumping. Same attack and release as `AudioShapingGraph`'s `alimiter`.
///
/// Not thread safe for `process`: one render thread at a time. `setGainDB` and `statistics` may be
/// called from any thread.
final class NormalizationGainProcessor: @unchecked Sendable {

    static let gainRange: ClosedRange<Double> = -30 ... 18
    static let ceilingDBFS: Double = -1
    static let lookaheadMilliseconds: Double = 5
    static let releaseMilliseconds: Double = 50
    /// A gain reduction smaller than this does not count as limiting in the statistics (0.01 dB).
    static let limitingThreshold: Float = 0.99885

    struct Statistics: Sendable, Equatable {
        /// Largest gain reduction the limiter applied, in dB (positive), 0 when it never acted.
        var maxReductionDB: Double = 0
        /// Frames during which the limiter was reducing gain.
        var limitedFrames: Int = 0
        /// Frames processed.
        var frames: Int = 0

        var limitingShare: Double { frames > 0 ? Double(limitedFrames) / Double(frames) : 0 }

        func merged(with other: Statistics) -> Statistics {
            Statistics(maxReductionDB: max(maxReductionDB, other.maxReductionDB),
                       limitedFrames: limitedFrames + other.limitedFrames, frames: frames + other.frames)
        }
    }

    static func clampedGainDB(_ db: Double) -> Double {
        guard db.isFinite else { return 0 }
        return min(max(db, gainRange.lowerBound), gainRange.upperBound)
    }

    let sampleRate: Double
    let channels: Int
    let lookaheadFrames: Int
    /// Length of the minimum and box windows: the delay plus the frame being written.
    private let window: Int

    private let ceiling: Float
    private let releaseCoefficient: Float

    /// Requested gain, written from any thread; the render thread picks it up per buffer.
    private let pendingGain: OSAllocatedUnfairLock<Float>
    private let stats = OSAllocatedUnfairLock(initialState: Statistics())

    // Render-thread state.
    private var linearGain: Float
    /// Interleaved delay line, `lookaheadFrames` frames.
    private var delay: [Float]
    private var delayIndex = 0
    /// Sliding minimum of the required gain (monotonic deque over a ring of values and frame stamps).
    private var minValues: [Float]
    private var minStamps: [Int]
    private var minHead = 0
    private var minCount = 0
    /// Box average of the held minimum.
    private var boxValues: [Float]
    private var boxIndex = 0
    private var boxSum: Double
    private var envelope: Float = 1
    private var frameStamp = 0

    init(gainDB: Double, sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.channels = max(1, channels)
        lookaheadFrames = max(1, Int((self.sampleRate * Self.lookaheadMilliseconds / 1000).rounded()))
        window = lookaheadFrames + 1
        ceiling = Float(pow(10, Self.ceilingDBFS / 20))
        releaseCoefficient = Float(1 - exp(-1 / (self.sampleRate * Self.releaseMilliseconds / 1000)))
        let gain = Float(pow(10, Self.clampedGainDB(gainDB) / 20))
        linearGain = gain
        pendingGain = OSAllocatedUnfairLock(initialState: gain)
        delay = [Float](repeating: 0, count: lookaheadFrames * self.channels)
        minValues = [Float](repeating: 1, count: lookaheadFrames + 1)
        minStamps = [Int](repeating: 0, count: lookaheadFrames + 1)
        boxValues = [Float](repeating: 1, count: lookaheadFrames + 1)
        boxSum = Double(lookaheadFrames + 1)
    }

    /// Change the gain. The next buffer ramps to it over its own length, so there is no click.
    func setGainDB(_ db: Double) {
        let gain = Float(pow(10, Self.clampedGainDB(db) / 20))
        pendingGain.withLock { $0 = gain }
    }

    var gainDB: Double {
        Double(20 * log10(pendingGain.withLock { $0 }))
    }

    var statistics: Statistics { stats.withLock { $0 } }

    /// Process `frames` interleaved frames in place.
    func process(interleaved samples: UnsafeMutablePointer<Float>, frames: Int) {
        process(frames: frames) { frame, channel in
            samples + (frame * channels + channel)
        }
    }

    /// Process `frames` frames held in one buffer per channel, in place. `planes.count` must equal
    /// `channels`.
    func process(planes: [UnsafeMutablePointer<Float>], frames: Int) {
        guard planes.count == channels else { return }
        process(frames: frames) { frame, channel in
            planes[channel] + frame
        }
    }

    private func process(frames: Int, sample: (Int, Int) -> UnsafeMutablePointer<Float>) {
        guard frames > 0 else { return }
        let target = pendingGain.withLockIfAvailable { $0 } ?? linearGain
        let start = linearGain
        let step = (target - start) / Float(frames)
        var maxReduction: Float = 1
        var limited = 0

        for frame in 0 ..< frames {
            let gain = start + step * Float(frame + 1)

            var peak: Float = 0
            for channel in 0 ..< channels {
                let value = abs(sample(frame, channel).pointee * gain)
                if value > peak { peak = value }
            }
            let required: Float = peak > ceiling ? ceiling / peak : 1
            let held = pushMinimum(required)

            boxSum += Double(held) - Double(boxValues[boxIndex])
            boxValues[boxIndex] = held
            boxIndex = (boxIndex + 1) % window
            let smoothed = min(1, Float(boxSum / Double(window)))

            if smoothed < envelope {
                envelope = smoothed
            } else {
                envelope += (smoothed - envelope) * releaseCoefficient
            }
            if envelope < maxReduction { maxReduction = envelope }
            if envelope < Self.limitingThreshold { limited += 1 }

            let base = delayIndex * channels
            for channel in 0 ..< channels {
                let pointer = sample(frame, channel)
                let incoming = pointer.pointee * gain
                pointer.pointee = delay[base + channel] * envelope
                delay[base + channel] = incoming
            }
            delayIndex = (delayIndex + 1) % lookaheadFrames
            frameStamp += 1
        }

        linearGain = target
        let reductionDB = maxReduction < 1 ? Double(-20 * log10(maxReduction)) : 0
        let limitedFrames = limited
        stats.withLockIfAvailable { s in
            s.frames += frames
            s.limitedFrames += limitedFrames
            if reductionDB > s.maxReductionDB { s.maxReductionDB = reductionDB }
        }
    }

    /// Push one required gain into the sliding minimum over the last `window` frames and return
    /// that minimum.
    private func pushMinimum(_ value: Float) -> Float {
        let n = window
        // Drop values that left the window from the front.
        while minCount > 0, minStamps[minHead] <= frameStamp - n {
            minHead = (minHead + 1) % n
            minCount -= 1
        }
        // Drop values at least as large as the new one from the back; they can never be the minimum again.
        while minCount > 0 {
            let back = (minHead + minCount - 1) % n
            guard minValues[back] >= value else { break }
            minCount -= 1
        }
        let slot = (minHead + minCount) % n
        minValues[slot] = value
        minStamps[slot] = frameStamp
        minCount += 1
        return minValues[minHead]
    }
}
