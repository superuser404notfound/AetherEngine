import Foundation
import CoreMedia

/// Gapless presentation-clock for the software AudioDecoder output. Container per-packet PTS are
/// quantized to the container timebase (1 ms for MKV). When the decoded frame duration is not an
/// integer number of those ticks -- e.g. a 1536-sample AC-3 frame at 44.1 kHz is 34.83 ms, not an
/// integer ms -- stamping every CMSampleBuffer with its own quantized PTS leaves a +/-0.5 ms
/// gap/overlap between consecutive buffers, and AVSampleBufferAudioRenderer reconciles a
/// discontinuity at each boundary (~29 audible clicks/sec, a continuous crackle). 48 kHz AC-3
/// (1536 samples = exactly 32 ms) is integer-ms so it never showed.
///
/// Fix: anchor to the first frame's PTS, then advance by emitted sample count so consecutive buffers
/// abut to the sample. `reset()` on flush; a real source PTS discontinuity (seek/edit, > 100 ms off
/// the predicted clock) re-anchors so genuine gaps aren't papered over. Mirrors
/// `OutputTimestampSanitizer`'s focused, unit-testable mutating-struct shape (issue #89).
struct AudioClockAnchor {
    /// A real seek/edit moves the source clock by far more than container rounding jitter.
    static let discontinuityThresholdSeconds = 0.10

    private var anchorPTS: CMTime = .invalid
    private var emittedSamplesSinceAnchor: Int64 = 0

    /// Clear the anchor (flush/seek). The next `resolve` re-anchors to its `startPTS`.
    mutating func reset() {
        anchorPTS = .invalid
        emittedSamplesSinceAnchor = 0
    }

    /// Decide the PTS to stamp on a buffer whose container PTS is `startPTS`, without mutating state.
    /// `reanchor` distinguishes a fresh anchor (first buffer or post-discontinuity) from a continued
    /// gapless run; pass it back to `commit` once the buffer is actually emitted.
    func resolve(startPTS: CMTime, sampleRate: Int32) -> (pts: CMTime, reanchor: Bool) {
        guard anchorPTS.isValid else {
            return (startPTS, true)  // first buffer after open/flush
        }
        let predicted = CMTimeAdd(
            anchorPTS,
            CMTime(value: emittedSamplesSinceAnchor, timescale: sampleRate)
        )
        // No source PTS mid-run (a frame without one, the normalization tail at EOF): the running
        // count says exactly where this buffer goes (AUD-206).
        guard startPTS.isValid else { return (predicted, false) }
        if abs(CMTimeGetSeconds(CMTimeSubtract(startPTS, predicted))) > Self.discontinuityThresholdSeconds {
            return (startPTS, true)   // real discontinuity (seek/edit): honour the source clock
        }
        return (predicted, false)     // gapless continuation: abut to the sample, ignore container rounding
    }

    /// Advance the clock after a buffer was successfully emitted at `pts`. Only called on success so a
    /// dropped buffer does not inject phantom samples into the running count.
    mutating func commit(pts: CMTime, reanchor: Bool, sampleCount: Int) {
        if reanchor {
            anchorPTS = pts
            emittedSamplesSinceAnchor = Int64(sampleCount)
        } else {
            emittedSamplesSinceAnchor += Int64(sampleCount)
        }
    }
}
