import Foundation

/// AE#850: whether the pump keeps up with real time at the relaxed QoS.
///
/// The AE#286 relaxation only asks how far ahead the pump is, which assumes `.utility` still produces
/// faster than the consumer plays. A heavy enough session breaks that: a 4K Dolby Vision remux with
/// TrueHD Atmos rendered to APAC ran at 1.15-1.25x real time on `.userInitiated` and 0.10-0.51x on
/// `.utility` on an A15 Apple TV, so every relaxed stretch drained the 16 s lead and ended in a stall,
/// 22 class changes in 15 minutes with the forward window never filling.
///
/// The probe measures content produced against wall time while relaxed. The verdict is a rate, not a
/// lead, because a consumer that fetches in bursts drains the lead on a pump that keeps up perfectly
/// well. A relaxed stretch usually ends in a promotion long before one window is complete (at 0.12x
/// the lead loses a 4 s segment in under 5 s), so the window adds up the relaxed stretches instead of
/// starting over with each one.
struct PumpRelaxationRateProbe {

    /// Long enough that one slow read or one expensive GOP cannot decide it, short enough that a pump
    /// at 0.5x has spent only a quarter of the relaxed lead by the time it is decided.
    static let minimumWallSeconds = 8.0
    /// Below this the forward window cannot fill at the relaxed class, and the lead drains.
    static let requiredRate = 1.0

    /// The running stretch: where it started and the newest sample in it.
    private var stretchStart: (wall: Double, content: Double)?
    private var stretchLast: (wall: Double, content: Double) = (0, 0)
    /// Closed stretches of the current window.
    private var closedWall = 0.0
    private var closedContent = 0.0

    /// Feed the wall clock and the newest produced content position, both in seconds, while relaxed.
    /// Opens a stretch when none is running. Returns the measured rate once the window holds at least
    /// `minimumWallSeconds` and is below `requiredRate`, else nil. A window that keeps up starts the
    /// next one, so a pump that slows down later in the session (thermal throttling) is still caught,
    /// not averaged away against its first minutes.
    mutating func observe(wallSeconds: Double, contentSeconds: Double) -> Double? {
        guard let start = stretchStart else {
            stretchStart = (wallSeconds, contentSeconds)
            stretchLast = (wallSeconds, contentSeconds)
            return nil
        }
        stretchLast = (wallSeconds, contentSeconds)
        let wall = closedWall + (wallSeconds - start.wall)
        guard wall >= Self.minimumWallSeconds else { return nil }
        let rate = (closedContent + max(0, contentSeconds - start.content)) / wall
        if rate < Self.requiredRate { return rate }
        reset()
        stretchStart = (wallSeconds, contentSeconds)
        stretchLast = (wallSeconds, contentSeconds)
        return nil
    }

    /// The relaxed stretch ended (a promotion, a pump restart): keep what it measured up to its last
    /// sample, the next stretch adds to it.
    mutating func suspend() {
        guard let start = stretchStart else { return }
        closedWall += stretchLast.wall - start.wall
        closedContent += max(0, stretchLast.content - start.content)
        stretchStart = nil
    }

    /// The relaxed pump parked: it got far enough ahead of the consumer to wait, which is the answer
    /// the window was collecting evidence for. Parked time is not production time either.
    mutating func reset() {
        stretchStart = nil
        closedWall = 0
        closedContent = 0
    }
}
