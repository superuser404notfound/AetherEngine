import Foundation

/// AetherEngine#334: the terminal state the `nativeRemoteHLS` bypass never had.
///
/// The lean bypass deliberately runs without a readiness watchdog and leaves a dead upstream to
/// AVPlayer's own "gave up" signal (`surfaceEndFailures`). That covers an origin that stops answering.
/// It does not cover an origin that answers everything while AVFoundation can build no track from what
/// it serves: no failure is ever raised, `readyToPlay` never arrives, and the session sits in `.loading`
/// for as long as the host leaves it there. Field shape: a video-only channel carrying HEVC in MPEG-TS,
/// where the carriage reroute is the fix but there is no audio track to reach readiness with either.
///
/// This is a ceiling on silence, not on how long a slow origin may take. Anything that resolves the
/// session, readiness at any point, a carriage reroute, an AVPlayer failure that already published a
/// terminal state, disarms it, so a Jellyfin transcode spin-up or a slow IPTV token handshake never
/// meets it. Only a session where nothing at all happened for the whole budget fails.
///
/// Pure decision logic; the timing loop lives in NativeAVPlayerHost, like the carriage watchdog's.
struct RemoteHLSReadinessDeadline {

    enum Verdict: Equatable {
        /// Still inside the budget with nothing resolved; poll again after the tick cadence.
        case keepWaiting
        /// The session resolved itself. Stop watching; nothing to publish.
        case disarm
        /// The budget passed with no readiness, no reroute and no failure: publish a terminal state.
        case fail
    }

    /// 45 s. It has to outlast the deferred carriage probe's own readiness ceiling (20 s) plus the
    /// segment-head read it then performs, or the deadline would fail sessions the probe was about to
    /// reroute. Everything healthy disarms in the first second, so the budget only ever costs the
    /// sessions that were going to hang anyway.
    static let defaultBudgetSeconds: Double = 45

    let budgetTicks: Int
    private(set) var ticksObserved = 0

    init(budgetSeconds: Double = RemoteHLSReadinessDeadline.defaultBudgetSeconds, tickSeconds: Double) {
        self.budgetTicks = max(1, Int((budgetSeconds / tickSeconds).rounded()))
    }

    mutating func tick(isReady: Bool, carriageRerouted: Bool, hasFailed: Bool) -> Verdict {
        if isReady || carriageRerouted || hasFailed { return .disarm }
        ticksObserved += 1
        return ticksObserved >= budgetTicks ? .fail : .keepWaiting
    }

    /// Published as the session's error text, so it has to name what happened rather than the symptom:
    /// a host that reads "no track" knows to retune or to pick another source, one that reads
    /// "failed to load" does not.
    static func failureMessage(budgetSeconds: Double) -> String {
        "The stream never became playable: AVFoundation built no track for it within "
        + "\(Int(budgetSeconds.rounded()))s and the source's carriage could not be identified."
    }
}
