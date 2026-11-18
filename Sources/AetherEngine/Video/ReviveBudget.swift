import Foundation

/// How many times a VOD session may rebuild its producer for one kind of death, with the reset
/// policy stated instead of implied (audit HLS-R201).
///
/// `.never` is a session-lifetime cap, right for a cause that does not heal (an unmuxable source,
/// the audio prime, a gate that starves to EOF). `.onProgress` counts CONSECUTIVE barren revives:
/// the count restarts once the session has stored segments since the previous admit, so a long
/// film that heals every outage is not failed on the Nth one for arithmetic reasons (HLS-201).
///
/// `.onProgress` alone has no bound for a source that is cut every few seconds and delivers a
/// segment in between: every death follows progress, so every death reads as the first. A
/// `ceiling` caps revives in a sliding wall-clock window on top of the count, and no progress lifts
/// it. That tells "heals every outage" apart from "is cut every few seconds", and on a one-slot
/// panel it is the open churn the host has to see, not the engine to absorb (AE#1085).
///
/// The #377 refusing-source clock (`RefusingSourceReviveBudget`) and the live arm
/// (`liveRecoveryBudgetDecision`) keep their own shapes: one is wall-clock per refusal window, the
/// other is per recovery cycle.
///
/// History: #99 introduced this as `MuxerFailureReviveGate` for a VOD pump that died with
/// `muxerFailed`. A rebuild goes through `performRestart`, which recreates the muxer and re-arms
/// the audio bridge, so a transient cause heals and a persistent one exhausts the cap.
struct ReviveBudget {
    enum Reset: Equatable {
        case never
        case onProgress
    }

    /// At most `maxRevives` admitted revives inside any `windowSeconds` of wall clock.
    struct Ceiling: Equatable {
        let maxRevives: Int
        let windowSeconds: TimeInterval
    }

    let maxAttempts: Int
    let reset: Reset
    let ceiling: Ceiling?
    private(set) var attempts = 0
    private var progressAtLastAdmit: Int?
    private var admittedAt: [DispatchTime] = []
    /// The last refusal came from the ceiling rather than the count, for the give-up line.
    private(set) var refusedByCeiling = false

    init(maxAttempts: Int, reset: Reset = .never, ceiling: Ceiling? = nil) {
        self.maxAttempts = maxAttempts
        self.reset = reset
        self.ceiling = ceiling
    }

    /// Records one death. True while the count is within the cap (rebuild the producer), false once
    /// exhausted (give up and say so). `progress` is a monotonic count of what the session has
    /// produced, read by the caller; it only matters under `.onProgress`. `now` is injectable so the
    /// ceiling can be pinned without a test that sleeps through the window.
    mutating func admit(progress: Int = 0, now: DispatchTime = .now()) -> Bool {
        if reset == .onProgress, let last = progressAtLastAdmit, progress > last {
            attempts = 0
        }
        progressAtLastAdmit = progress
        attempts += 1
        refusedByCeiling = false
        guard attempts <= maxAttempts else { return false }
        guard let ceiling else { return true }
        admittedAt.removeAll { Self.seconds(from: $0, to: now) >= ceiling.windowSeconds }
        guard admittedAt.count < ceiling.maxRevives else {
            refusedByCeiling = true
            return false
        }
        admittedAt.append(now)
        return true
    }

    /// Revives admitted inside the ceiling's window as of the last admit.
    var revivesInWindow: Int { admittedAt.count }

    private static func seconds(from: DispatchTime, to: DispatchTime) -> TimeInterval {
        guard to.uptimeNanoseconds > from.uptimeNanoseconds else { return 0 }
        return TimeInterval(to.uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000_000
    }
}
