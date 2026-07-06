import Foundation

/// Outcome of one startup-readiness attempt: did the freshly (re)loaded item reach a playable state,
/// die, or run out the settle window without doing either?
enum StartupReadiness: Sendable, Equatable {
    /// The item produced a non-zero presentation size or actually started playing (hasEverPlayed).
    case ready
    /// `item.status == .failed` (e.g. -11819 "Cannot Complete Action" / -11868 cold DV handshake).
    case dead
    /// The settle window elapsed with the item neither ready nor failed: the silent 0-track park
    /// (`AVPlayerWaitingWithNoItemToPlayReason`, `asset.tracks` empty).
    case timedOut
}

/// Terminal failure thrown when the readiness gate exhausts the master budget and has no media
/// fallback. Routes through `load()`'s catch so the host surfaces a real error instead of the item
/// sitting failed-but-silent (its startup failure was consumed while the gate held it).
struct StartupGateFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The gate's next move after one attempt.
enum StartupGateAction: Sendable, Equatable {
    /// Item is playable; stop the gate and keep playing.
    case proceed
    /// Reload the master with a fresh asset and try again (the failed cold attempt warmed the link).
    case reloadMaster
    /// Master is not recovering; reload the media playlist once (HDR10 base, no DV upgrade).
    case fallBackToMedia
    /// Nothing left to try (no media URL, or already fell back); surface a terminal failure.
    case giveUp
}

/// Pure decision for the DV/HDR cold-start readiness gate (Sodalite #35). A DV master (P7 signalled as
/// P8.1, or any HDR master) instantiated while the HDMI DV/HDCP decode path is still warming right after
/// an SDR->HDR panel switch resolves to zero playable tracks (silent park) or fails
/// `AVFoundationErrorDomain -11819` "Cannot Complete Action". Neither is a -11868/-11848 display
/// rejection, so the reactive `MasterFallbackDecision` path never fires and the startup surfaces
/// "Playback stopped"; a second launch "just works" because the failed attempt warmed the link.
///
/// This gate reloads the master a bounded number of times (each fresh asset re-probes the now-warmer
/// link), then falls back to the media playlist, so a cold DV resume can never hang forever on 0 tracks.
/// Kept pure and separate (matching `MasterFallbackDecision` / `ItemDeathReviveGate`) so the state
/// machine is testable offline; the AVFoundation-facing polling and reloads live in `AetherEngine`.
enum StartupReadinessGate {

    /// Master attempts before falling back to media. Attempt 1 is the item the load path already
    /// created; the remainder are fresh reloads that re-probe the warming link. Two total.
    static let masterAttempts = 2

    /// Decide the next action after `attempt` master attempts (1-based) produced `outcome`.
    static func nextAction(
        outcome: StartupReadiness,
        attempt: Int,
        masterAttempts: Int = masterAttempts,
        masterAlreadyFellBack: Bool,
        hasMediaFallbackURL: Bool
    ) -> StartupGateAction {
        if outcome == .ready { return .proceed }
        if attempt < masterAttempts { return .reloadMaster }
        if !masterAlreadyFellBack && hasMediaFallbackURL { return .fallBackToMedia }
        return .giveUp
    }
}
