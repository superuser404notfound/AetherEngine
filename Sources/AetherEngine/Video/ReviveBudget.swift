import Foundation

/// How many times a VOD session may rebuild its producer for one kind of death, with the reset
/// policy stated instead of implied (audit HLS-R201).
///
/// `.never` is a session-lifetime cap, right for a cause that does not heal (an unmuxable source,
/// the audio prime, a gate that starves to EOF). `.onProgress` counts CONSECUTIVE barren revives:
/// the count restarts once the session has stored segments since the previous admit, so a long
/// film that heals every outage is not failed on the Nth one for arithmetic reasons (HLS-201).
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

    let maxAttempts: Int
    let reset: Reset
    private(set) var attempts = 0
    private var progressAtLastAdmit: Int?

    init(maxAttempts: Int, reset: Reset = .never) {
        self.maxAttempts = maxAttempts
        self.reset = reset
    }

    /// Records one death. True while the count is within the cap (rebuild the producer), false once
    /// exhausted (give up and say so). `progress` is a monotonic count of what the session has
    /// produced, read by the caller; it only matters under `.onProgress`.
    mutating func admit(progress: Int = 0) -> Bool {
        if reset == .onProgress, let last = progressAtLastAdmit, progress > last {
            attempts = 0
        }
        progressAtLastAdmit = progress
        attempts += 1
        return attempts <= maxAttempts
    }
}
