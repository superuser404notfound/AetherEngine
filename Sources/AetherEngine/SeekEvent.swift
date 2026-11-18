import Foundation

/// One statement about a seek's lifecycle: its outcome and the target it belonged to, in a single value
/// (AetherEngine#38 follow-up).
///
/// `isSeeking` / `seekTarget` are a LEVEL signal, and a level cannot say why it fell. "Landed on the
/// target", "spent the recovery budget with the clock parked at the target while the source keeps
/// stalling", and "a newer seek took over" all read as the same falling edge. Worse, the two properties
/// clear in the same recompute with no ordering guarantee across a queue hop, so the target that the
/// edge belonged to can already be gone when a consumer reads it. The synchronized-playback host that
/// asked for the signal rebuilt all of that host-side out of a landing grace, a retained last target and
/// a 180 s unreached-target map; this stream is what those heuristics were approximating.
///
/// Contract:
///
/// - Every `.began` is terminated by exactly one `.landed`, `.stalled` or `.superseded` under the same
///   `id`, with one deliberate exception: a `.stalled` seek stays alive inside AVPlayer as recovery
///   intent, so a `.landed` for the same `id` can still arrive, minutes later on a stalled source. That
///   late landing is the edge a level signal structurally cannot carry, because the level fell at the
///   give-up.
/// - `.rejected` stands alone. The seek never reached a host, so it has no `.began` and no terminator.
/// - `target` is on the same axis as `clock.currentTime` (source PTS, display origin folded out).
/// - `.landed` carries the position actually rendered, which keyframe granularity and a playing item's
///   overshoot can put a few seconds off `target`.
///
/// Events are published on the main actor, in emission order.
public struct SeekEvent: Sendable, Equatable {

    /// Which path issued the seek. `.deferred` covers a seek the session could not take yet (#127/#178):
    /// it is stashed and replayed at readiness, and it is the case where the engine publishes an
    /// optimistic `currentTime` for a position nothing has reached yet, so a consumer needs to know.
    public enum Origin: String, Sendable, Equatable {
        case programmatic
        case nativeScrub
        case deferred
        /// A `.skip` or `.changePosition` from the system (Control Center, the lock screen, the iPhone
        /// Remote, AirPods) that the engine carried out itself, because it owns Now Playing and
        /// `nowPlayingCommandInterceptor` left the command to it (AE#1088).
        case remoteCommand
        /// A skip button in the Picture in Picture window of the software route (AE#1088).
        case pictureInPicture
    }

    /// Why a seek never reached a host.
    public enum Rejection: String, Sendable, Equatable {
        /// No session to seek in: the engine is idle, errored, or past end-of-media.
        case noActiveSession
        /// Live source without a DVR window; there is no seekable range to land in.
        case liveWithoutDVR
        /// The source can only be read forwards; a duration does not make it seekable.
        case sourceNotSeekable
    }

    public enum Outcome: Sendable, Equatable {
        /// A seek toward `target` is now in flight.
        case began
        /// The picture is at the target: AVPlayer reported the landing, or the rendered frame reached the
        /// scrub target. This is the only outcome that means "safe to read the clock".
        case landed(renderedTime: Double)
        /// Positioning did not complete within its budget. Native AVPlayer recovery may keep the
        /// target pending and later emit `.landed` under this `id`. A software positioning failure
        /// instead reports a terminal pipeline error without finalizing the requested clock.
        case stalled
        /// A newer seek took over before this one settled; the newer one's `.began` carries its target.
        case superseded
        /// The seek was not accepted. Terminal on its own.
        case rejected(Rejection)
    }

    /// Identifies one seek across its events. Monotonic per engine instance; not the internal seek fence.
    public let id: UInt64
    public let origin: Origin
    public let outcome: Outcome
    /// Seek destination on the `currentTime` axis.
    public let target: Double
    /// Where the playhead stood when the seek was asked for, on the same axis as `target` (AE#1088).
    /// A remote skip carries the position its target was computed from, and a seek replayed from the
    /// load stash keeps the position from before the stash, not the optimistic clock it published.
    /// Nil for `.nativeScrub`, whose starting point AVKit does not report, and for the engine's own
    /// live rejoin.
    public let departure: Double?

    public init(id: UInt64, origin: Origin, outcome: Outcome, target: Double, departure: Double? = nil) {
        self.id = id
        self.origin = origin
        self.outcome = outcome
        self.target = target
        self.departure = departure
    }

    /// True for the three outcomes that end a seek's in-flight window. A `.stalled` seek is finished as
    /// far as the level signal is concerned, which is exactly why a later `.landed` needs the id.
    public var isTerminal: Bool {
        switch outcome {
        case .began: return false
        case .landed, .stalled, .superseded, .rejected: return true
        }
    }
}

extension SeekEvent: CustomStringConvertible {
    public var description: String {
        let outcomeText: String
        switch outcome {
        case .began: outcomeText = "began"
        case .landed(let rendered): outcomeText = "landed rendered=\(String(format: "%.2f", rendered))"
        case .stalled: outcomeText = "stalled"
        case .superseded: outcomeText = "superseded"
        case .rejected(let reason): outcomeText = "rejected(\(reason.rawValue))"
        }
        let from = departure.map { " from=\(String(format: "%.2f", $0))" } ?? ""
        return "seek#\(id) \(origin.rawValue) \(outcomeText) target=\(String(format: "%.2f", target))\(from)"
    }
}

extension AetherEngine {

    /// Pure decision: has a native AVKit scrub physically landed, i.e. is the picture in the region the
    /// producer restarted for?
    ///
    /// `target` is the restarted segment's start, which is a LOWER BOUND on the landing, not a point: the
    /// restart aims at the segment containing the requested time, and a `seektest` probe measured a
    /// restart at 84.0 for a landing at 90.0. Reading it as a band is what makes an honest landing look
    /// like a miss.
    ///
    /// `frozen` is the rendered position when the watch was armed, which is the pre-scrub picture: AVPlayer
    /// has committed to the new time and cannot render the old region forward while the seek is pending.
    /// It supplies the direction and, on a backward scrub, the evidence that the picture actually jumped
    /// off the old playhead rather than the old buffer draining under a still-pending seek.
    nonisolated static func nativeScrubLanded(
        rendered: Double,
        target: Double,
        frozen: Double,
        tolerance: Double = 0.75
    ) -> Bool {
        guard rendered.isFinite, target.isFinite, frozen.isFinite else { return false }
        guard rendered >= target - tolerance else { return false }
        // Forward: reaching the restarted region is the landing (overshoot included, a playing item keeps
        // moving while the 100 ms tick that observes it settles).
        if target >= frozen { return true }
        // Backward: the picture must have left the frozen playhead, otherwise "above the target" is just
        // the old position, which sits above it by definition.
        return rendered < frozen - tolerance
    }
}
