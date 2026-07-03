import Foundation

/// Bounded revive for an AVPlayerItem that died via `failedToPlayToEndTime` (issue #93, round 3).
///
/// Accumulated -12889 media timeouts (a requested segment outliving AVPlayer's ~3.5 s
/// time-to-first-byte window during a wedge-window producer restart) fail the item: rate 0,
/// `timeControlStatus` parked at `.paused`, `item.status` often still `readyToPlay`. Every
/// recovery layer read that pause as user intent and disarmed, so the session was terminal.
/// The gate bounds the stage-2 item reloads the death escalation may attempt: a frozen position
/// across consecutive deaths means the reloads are not taking (persistently missing segment),
/// so the budget exhausts instead of reload-storming; any real position change (playback
/// progressed, or the user scrubbed away) is a fresh episode and restores the full budget.
struct ItemDeathReviveGate {
    let maxAttempts: Int
    private(set) var attempts = 0
    private var lastPosition: Double?

    init(maxAttempts: Int) {
        self.maxAttempts = maxAttempts
    }

    /// Position deltas at or below this are the same dead spot (rendered-clock jitter),
    /// not progress.
    private let progressEpsilon: Double = 0.5

    /// Records one item death at `position`. True while the episode's failure count is within
    /// the cap (caller should reload the item), false once exhausted (caller gives up and logs).
    mutating func admit(position: Double) -> Bool {
        if let last = lastPosition, abs(position - last) > progressEpsilon {
            attempts = 0
        }
        lastPosition = position
        attempts += 1
        return attempts <= maxAttempts
    }
}

extension AetherEngine {
    /// Pure decision: may a stalled-consumer recovery (nudge / stage-2 reload) act on a consumer
    /// whose `timeControlStatus` is `.paused`? A genuine user pause must never be fought; the
    /// item-death escalation bypasses the guard because `failedToPlayToEndTime` parks the dead
    /// item at `.paused`, and that pause IS the failure, not user intent.
    nonisolated static func stalledConsumerRecoveryAllowed(
        consumerIsPaused: Bool, allowPausedConsumer: Bool
    ) -> Bool {
        !consumerIsPaused || allowPausedConsumer
    }
}
