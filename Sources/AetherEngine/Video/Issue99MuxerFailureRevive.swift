import Foundation

/// Bounded revive for a VOD pump that died with `muxerFailed` (issue #99, failure mode B).
///
/// `handlePumpFinished` only reopened LIVE sessions; a VOD muxer death (e.g. the first cut firing
/// before any bridged audio packet reached the muxer, so mov_write_moov cannot build the dec3 box)
/// left the session permanently starved: no producer, no restarts, black screen with no error.
/// The gate admits a small number of producer rebuilds per session. A rebuild goes through
/// `performRestart`, which recreates the muxer AND re-arms the audio bridge, so a transient cause
/// (post-EOF encoder state, a mid-cut I/O hiccup) heals; a persistent one (truly unmuxable source)
/// exhausts the cap instead of restart-storming.
struct MuxerFailureReviveGate {
    let maxAttempts: Int
    private(set) var attempts = 0

    /// Records one muxer failure. True while the failure count is within the cap (caller should
    /// rebuild the producer), false once exhausted (caller should give up and log).
    mutating func admit() -> Bool {
        attempts += 1
        return attempts <= maxAttempts
    }
}
