import Foundation

/// AE#374: what the software path's master clock does once the producer is done.
///
/// `AVSampleBufferRenderSynchronizer` is the master clock for the whole software session, and nothing
/// used to stop it at end of media: the demux loop drained, published `.ended` and parked its own
/// threads, but left the synchronizer at rate 1. So `currentTime` kept walking past `duration` for as
/// long as the host held the session, and the 1 Hz `[SWDiag]` line kept reporting an `aLead` falling at
/// exactly 1.00 per second, which is the shape of a session drifting rather than of one that finished.
/// A downstream host read those lines as evidence of a clock defect, and so did this repo. The native
/// path parks on its final sample; this is what makes the two agree.
enum SoftwareEndOfMediaClock {

    /// Longest the clock may keep running after the last packet, so a queued audio tail plays out
    /// instead of being cut off. Bounded because the anchor is a stream value: a broken PTS must not
    /// buy an unbounded runway on a session that is already over.
    static let maxTailPlayoutSeconds: TimeInterval = 5.0

    /// Seconds to let the clock run before parking it: the decoded audio still ahead of the playhead,
    /// clamped. Zero (park now) when the source carries no audio, when its PTS is unusable, or when the
    /// clock has already passed it, which is the normal VOD case because the drain that precedes end of
    /// media has already walked the clock to the last video frame.
    static func tailPlayoutSeconds(clockSeconds: Double, lastAudioPts: Double) -> TimeInterval {
        guard clockSeconds.isFinite, lastAudioPts.isFinite else { return 0 }
        let remaining = lastAudioPts - clockSeconds
        guard remaining > 0 else { return 0 }
        return min(remaining, maxTailPlayoutSeconds)
    }

    /// Where a late park puts the clock: back on `latest` when the clock has run past it, nil (park
    /// where it stands) otherwise or when either value is unusable.
    static func parkSeconds(clockSeconds: Double, notAfter latest: Double) -> Double? {
        guard clockSeconds.isFinite, latest.isFinite, clockSeconds > latest else { return nil }
        return latest
    }

    /// Whether the end-of-media drain may stop waiting for the parked video: every packet still
    /// parked is timed before the clock, so none of it can be shown on time. A stopped timebase never
    /// takes a late frame, and on a CI runner the synchronizer stayed stopped at rate 2.0 after the
    /// rebuffer hold was lifted at the end (36.8 s, 255 packets parked up to 33 s), so waiting for the
    /// renderer to take them never ended. False while any of it is still ahead of the clock, or when
    /// either side has no usable time.
    static func parkedTailIsBehindClock(newestParkedSeconds: Double, clockSeconds: Double) -> Bool {
        guard newestParkedSeconds.isFinite, clockSeconds.isFinite else { return false }
        return newestParkedSeconds < clockSeconds
    }
}
