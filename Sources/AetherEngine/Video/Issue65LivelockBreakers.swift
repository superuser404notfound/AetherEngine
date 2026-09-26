import Foundation

// Decision helpers for the loopback-HLS VOD scrub-burst livelock (issue #65). Both are pure so the
// false-positive guards (the only thing standing between a real wedge and a healthy slow seek) are
// unit-testable without spinning up an AVPlayer or a producer.

/// Stuck-detection for the VOD backpressure park (issue #65, Piece A).
///
/// The producer parks in `awaitBackpressureRelease` until the consumer's fetch high-water
/// (`SegmentCache.targetIndex`) reaches a release target. A genuine wedge is the consumer target
/// frozen for `breakThresholdSeconds` while AVPlayer is stuck and issuing no forward segment request;
/// a slow-but-advancing consumer (cold cache, throttled CDN) keeps nudging the target up and must
/// NEVER trip the breaker, and neither must a quiet consumer that is still rendering (AE#649).
/// Feed `observe(currentTarget:)` once per ~1 s poll (`ParkClock` makes the caller's wakeups into
/// seconds): it resets the stuck timer whenever the target MOVES, so only a target that is frozen for
/// the whole window trips.
struct BackpressureWedgeDetector {
    let breakThresholdSeconds: Int
    /// #93 retest fast path: trip after this many consecutive polls where the fetch target AND the
    /// rendered clock are both frozen while the consumer wants to play. nil = fast path disabled.
    /// The dual freeze is what makes the short window safe: healthy steady-state playback freezes the
    /// target between segment fetches but advances the clock every poll; a post-seek decode ramp holds
    /// the clock but keeps prefetching (target advances). Only a consumer that neither renders nor
    /// fetches for the whole window is wedged.
    let fastBreakThresholdSeconds: Int?
    private var maxTargetSeen: Int
    /// AE#528: the target as of the previous poll, which is what says whether the consumer fetched
    /// at all. `maxTargetSeen` cannot: it only ever climbs.
    private var lastTarget: Int
    private var stuckSeconds: Int = 0
    /// AE#649: what the slow path trips on. Polls since the target last moved in which the rendered
    /// clock did not advance either; a poll whose clock advanced is held, not counted. Without a
    /// rendered position every poll counts, so it equals `stuckSeconds` exactly as before.
    private var idleSeconds: Int = 0
    private var lastRenderedPosition: Double?
    private var flatSeconds: Int = 0
    /// Diagnostic: whether the last `true` from `observe` came from the fast path.
    private(set) var lastTripFast = false
    /// AE#649 diagnostic: whether the last poll saw the rendered clock move. The PARK line names a
    /// quiet consumer that is playing out what it already holds, so it cannot be read as a stuck one.
    private(set) var lastPollRendered = false

    /// AE#528 diagnostic: polls since the consumer's fetch target last moved. The PARK line carries
    /// it, so a park that is plain backpressure behind a consumer that keeps fetching (stuck=0s, a
    /// viewer scrubbing) is distinguishable at a glance from one whose consumer has gone quiet,
    /// instead of being inferred from `cacheTarget` deltas across log lines after the fact.
    var secondsSinceTargetMoved: Int { stuckSeconds }

    /// AE#649 diagnostic: the count the slow path trips on (see `idleSeconds`). The PARK line carries
    /// it beside `stuck=`, so a park behind a consumer that is quiet but playing (stuck climbing, idle
    /// at 0) reads differently from one behind a consumer that stopped both fetching and rendering.
    var secondsWithoutProgress: Int { idleSeconds }

    /// Rendered-clock deltas below this are aliasing/representation jitter, not playback progress
    /// (one poll second of real playback advances the clock by ~1 s).
    static let renderedClockFlatEpsilon: Double = 0.1

    init(breakThresholdSeconds: Int, fastBreakThresholdSeconds: Int? = nil,
         initialTarget: Int, initialRenderedPosition: Double? = nil) {
        self.breakThresholdSeconds = breakThresholdSeconds
        self.fastBreakThresholdSeconds = fastBreakThresholdSeconds
        self.maxTargetSeen = initialTarget
        self.lastTarget = initialTarget
        self.lastRenderedPosition = initialRenderedPosition
    }

    /// Returns `true` once the consumer fetch target has been frozen for `breakThresholdSeconds`, or
    /// (fast path) once target and rendered clock have both been frozen for `fastBreakThresholdSeconds`.
    ///
    /// AE#649: with a rendered position wired, frozen for the slow path means frozen with NO
    /// playback progress. A consumer can go quiet for longer than the threshold while playing
    /// perfectly: AVPlayer on a cellular iPhone fetches in bursts, several segments at once and
    /// then nothing for 24 to 58 s while it plays out a forward buffer of up to 109 s (the same
    /// title on Wi-Fi fetched one segment every 3 to 7 s). Counting that silence tripped the
    /// breaker every few minutes, and the #421 nudge seek it led to flushed the buffer on screen: a
    /// half-second freeze of picture and sound, each time. Seconds in which the rendered clock
    /// advanced are therefore held rather than counted. A consumer that really stopped fetching
    /// still plays its buffer dry and then renders nothing, and that is the fast path's shape, so
    /// it breaks within `fastBreakThresholdSeconds` of the clock going flat.
    ///
    /// AE#528: frozen means UNCHANGED, not "no higher than before". A viewer scrubbing backwards
    /// declares a LOWER fetch target on every GET, and against a monotone high-water that was
    /// indistinguishable from a consumer that had stopped asking for anything: the busiest consumer
    /// of the session read as the silent one, and the breaker tore down a healthy pump in the middle
    /// of the scrub (field capture: a new GET every ~100 ms right up to the trip). The slow path
    /// therefore takes any movement as the fetch it is. The FAST path deliberately does not: a scrub
    /// burst that keeps declaring targets while nothing renders is the #35/#79 wedge, and its whole
    /// point is to break that in single digits, so there a moving target plus a flat clock still trips.
    ///
    /// `wantsToPlay` is the play-intent guard (issue #65 pause false-positive). A paused or backgrounded
    /// consumer issues no forward segment request by design, so its frozen fetch target is NOT a wedge: when
    /// `wantsToPlay` is false the detector re-baselines to the current target and holds the stuck timer at
    /// zero, so a pause of any length never trips and the window after resume starts fresh. The legit wedge
    /// (AVPlayer wants to play but is starved, `timeControlStatus == .waitingToPlay`) keeps `wantsToPlay`
    /// true and still trips. Defaults to true so existing callers and live keep their prior behaviour.
    ///
    /// `renderedPosition` feeds the fast path and holds the slow count while the clock moves; nil (not
    /// wired: tests, live) keeps both inert. Any move beyond the flat epsilon, forward or backward (a new
    /// seek landing), restarts the flat window.
    ///
    /// `hasStartedRendering` is the cold-startup guard: before AVPlayer has ever presented a frame
    /// (`timeControlStatus` never reached `.playing`), a flat rendered clock is normal pre-roll, NOT a
    /// wedge, and the producer parks the instant it fills its forward window ahead of a consumer still
    /// evaluating buffering rate. A high-bitrate DV master over a slow link pre-rolls past the fast
    /// window, so tripping here re-anchors and nudge-flushes AVPlayer's forward buffer, restarting the
    /// pre-roll from zero forever ("loads forever"). Cold startup belongs to the #35 StartupReadinessGate;
    /// this detector is a mid-stream recovery tool (#93 backward-seek), so it suspends (re-baselines,
    /// like the paused case) until the first frame lands. Defaults true for existing callers, live, tests.
    mutating func observe(currentTarget: Int, wantsToPlay: Bool = true,
                          renderedPosition: Double? = nil, hasStartedRendering: Bool = true) -> Bool {
        guard wantsToPlay, hasStartedRendering else {
            if currentTarget > maxTargetSeen { maxTargetSeen = currentTarget }
            lastTarget = currentTarget
            stuckSeconds = 0
            idleSeconds = 0
            flatSeconds = 0
            lastPollRendered = false
            if let rendered = renderedPosition { lastRenderedPosition = rendered }
            return false
        }
        let targetAdvanced = currentTarget > maxTargetSeen
        let targetMoved = currentTarget != lastTarget
        lastTarget = currentTarget
        if targetAdvanced { maxTargetSeen = currentTarget }
        stuckSeconds = targetMoved ? 0 : stuckSeconds + 1
        var clockFlat = false
        var clockMoved = false
        if let rendered = renderedPosition {
            if let last = lastRenderedPosition {
                clockFlat = abs(rendered - last) < Self.renderedClockFlatEpsilon
                clockMoved = !clockFlat
            }
            lastRenderedPosition = rendered
        }
        lastPollRendered = clockMoved
        if targetMoved {
            idleSeconds = 0
        } else if !clockMoved {
            idleSeconds += 1
        }
        if targetAdvanced || !clockFlat {
            flatSeconds = 0
        } else {
            flatSeconds += 1
        }
        if let fast = fastBreakThresholdSeconds, flatSeconds >= fast {
            lastTripFast = true
            return true
        }
        if idleSeconds >= breakThresholdSeconds {
            lastTripFast = false
            return true
        }
        return false
    }
}

/// Turns a park loop's wakeups into elapsed seconds (issue #528).
///
/// Both VOD park loops wait on `SegmentCache`'s condition (`awaitFetchHighWater`,
/// `awaitPrefetchDiskHeadroom`), and that condition is broadcast by every consumer GET that moves the
/// fetch target and by every stored segment, so the wait returns long before its one second timeout
/// whenever the consumer is busy. Counting iterations counted WAKEUPS, and everything hanging off that
/// counter (the 12 s log threshold, the 24 s wedge break, the 5 s fast path) ran at the consumer's
/// request rate instead of the clock's: in the #528 capture the park counter climbed from 12 to 22
/// "seconds" inside 2.400 s of wall clock, and the 24 s breaker fired inside a pump whose exit line
/// read `elapsed=10145ms`. The busier the consumer, the faster the timer meant to measure its silence.
///
/// Feed `advance(nowNanos:)` once per wakeup. It returns the park's age in whole seconds the first
/// time each second is reached and nil for every wakeup inside a second already counted, so a caller
/// keeps its per-second cadence whatever the wakeup rate is. A gap longer than a second (a wakeup that
/// did not come) reports the age and skips the seconds in between rather than replaying them, which
/// makes a starved loop count slower than the clock, never faster.
struct ParkClock {
    private let startNanos: UInt64
    private var countedSeconds = 0

    init(nowNanos: UInt64) {
        self.startNanos = nowNanos
    }

    mutating func advance(nowNanos: UInt64) -> Int? {
        let elapsedNanos = nowNanos > startNanos ? nowNanos - startNanos : 0
        let seconds = Int(elapsedNanos / 1_000_000_000)
        guard seconds > countedSeconds else { return nil }
        countedSeconds = seconds
        return seconds
    }
}

/// Starvation predicate for a seek that did not land within its deadline (issue #65, Piece B).
///
/// During a pending zero-tolerance loopback seek AVPlayer holds the old frame, so `renderedTime` is
/// flat whether the seek is healthy-but-slow or wedged; it cannot distinguish them. What does: a
/// healthy seek refills AVPlayer's forward buffer (`bufferedEnd` climbs past `renderedTime`), while a
/// wedged seek is starved (the producer is parked, so `bufferedEnd` stays at the rendered position,
/// matching the reporter's `loaded=[]`). Returns `true` only when there is effectively no forward
/// buffer, i.e. AVPlayer is starved rather than slow.
func seekIsWedged(renderedTime: Double, bufferedEnd: Double, forwardBufferFloor: Double = 1.0) -> Bool {
    return (bufferedEnd - renderedTime) < forwardBufferFloor
}

/// Single-resume latch for the deadline-bounded seek (issue #65). The AVPlayer landing and the deadline
/// race to resume one continuation; whichever calls `claim()` first wins, the loser is a no-op. MainActor
/// isolated (so it is Sendable and capturable in the @Sendable seek completion) and only touched there.
@MainActor
final class SeekResumeGuard {
    private var claimed = false
    /// Returns `true` exactly once, to the first caller.
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Thread-safe Double mirror so an off-main consumer (the producer pump re-anchoring on a wedge) can read
/// AVPlayer's last rendered position, which the engine updates on the main actor (issue #65).
final class AtomicDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ initial: Double) { value = initial }
    func get() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Double) { lock.lock(); value = newValue; lock.unlock() }
}

/// Thread-safe Double? mirror so the off-main wedge re-anchor can read the engine's pending recovery
/// seek target (#93 retest), which the engine sets/retires on the main actor. nil = no unlanded user
/// seek pending; the wedge re-anchor then falls back to AVPlayer's frozen position.
final class AtomicOptionalDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    init(_ initial: Double? = nil) { value = initial }
    func get() -> Double? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Double?) { lock.lock(); value = newValue; lock.unlock() }
}

/// Thread-safe Bool mirror so the off-main producer pump can read whether AVPlayer currently wants to play
/// (`timeControlStatus != .paused`), which the engine updates on the main actor. Lets the VOD backpressure
/// wedge detector suspend while the consumer is paused (issue #65 pause false-positive).
final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ initial: Bool) { value = initial }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}
