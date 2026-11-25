import Foundation

/// AE#464: where a host's audio-delay nudge lands, per video route.
///
/// Lip-sync error is a property of the viewer's chain (a soundbar or AVR adding video-processing
/// latency, or the reverse), not of the file, so the correction is a per-setup nudge the host sets
/// once and the engine honours for the life of the session. AVFoundation offers no audio-delay
/// control on either surface a host can reach (`AVPlayerItem` has none, and an HLS-streamed asset
/// vends no `AVAssetTrack` to bind an `AVAudioMix` to), so the offset has to be applied where the
/// engine still holds the timestamps. That is a different place on each route, and on both of them
/// it is the LAST place rather than the obvious one:
///
/// - `.software`: the decoded sample's stamped PTS, downstream of `AudioClockAnchor`. Applying it to
///   the container PTS upstream instead would feed the gapless predictor an offset it treats as
///   ordinary rounding jitter, so any nudge below its 100 ms discontinuity threshold would vanish
///   without a trace, and the clock-arming decision (`SWClockAnchorPolicy`) would move with it.
/// - `.loopback`: the audio timestamps written into the fMP4 segments. Segments already cut carry
///   the old offset, and the two are not splicable: at the seam the audio track gains a gap or an
///   overlap of exactly the change, and a change that moves audio EARLIER walks into
///   `OutputTimestampSanitizer`'s strictly-increasing-DTS rule, which clamps it away entirely. A new
///   value is therefore a new muxer, which is a re-cut at the playhead.
///
/// In both cases the offset moves AUDIO and never the stream the session reports its position on, so
/// `currentTime`, seeking and the subtitle axis are untouched by a nudge.
enum AudioDelayPolicy {

    /// Largest offset the engine carries, either direction, in seconds.
    ///
    /// The correction this exists for is tens to a couple hundred milliseconds; the bound is a
    /// generous ceiling rather than a target. A constant A/V offset holds `|delay|` of one track in
    /// the muxer's interleaver, so the bound keeps an out-of-range value from turning into a stalled
    /// interleaver or a live session that has spent its edge on a typo. Live muxes with an 8 s
    /// interleave window (`MP4SegmentMuxer.maxBufferedFragmentSeconds`), well above it. VOD flushes a
    /// fragment every 0.5 s since AE#1129, and each flush drains the interleaver, so the delayed
    /// track's samples land in a later fragment of the same segment instead of piling up.
    static let maxAbsSeconds: Double = 2.0

    /// Bring a host value into range. A non-finite value (NaN from an unset stepper, an infinity out
    /// of a division) becomes 0 rather than propagating into a timestamp.
    static func clamp(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(max(seconds, -maxAbsSeconds), maxAbsSeconds)
    }

    /// True when `seconds` had to be brought in, i.e. the host asked for something the engine will
    /// not carry. Worth a log line: the delivered offset is not the one that was set.
    static func isOutOfRange(_ seconds: Double) -> Bool {
        !seconds.isFinite || abs(seconds) > maxAbsSeconds
    }

    /// Where the offset is applied on a given route.
    enum Application: Equatable {
        /// Stamped onto decoded audio samples as they are handed to the renderer. Takes effect as
        /// soon as the renderer's queue is flushed, with no re-cut and no rebuild.
        case sampleTimestamps
        /// Written into the fMP4 segments the local server feeds AVPlayer. A change is only clean
        /// across a re-cut at the playhead, so applying one costs a producer restart.
        case segmentTimestamps
        /// The engine does not hold this session's audio timestamps, so it cannot move them.
        case unavailable
    }

    static func application(for route: VideoRoute) -> Application {
        switch route {
        case .software: return .sampleTimestamps
        case .loopback: return .segmentTimestamps
        // AVPlayer owns the whole media selection; the engine never sees the timestamps (`.remoteBypass`),
        // or there is no video for audio to be early or late against (`.audio`, `.none`).
        case .remoteBypass, .audio, .none: return .unavailable
        }
    }

    /// Whether applying `new` in place of `current` needs anything done at all. Setting the value
    /// already in force is not a re-cut, which matters on `.loopback` where it would otherwise cost
    /// a visible rebuffer per redundant call.
    static func isChange(from current: Double, to new: Double) -> Bool {
        current != new
    }
}
