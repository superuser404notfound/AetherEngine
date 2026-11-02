import Foundation

/// #496: why the overlay drainer, and with it the #151 forward prefetcher, was torn down.
///
/// The teardown used to leave no trace at all. `#151 forward prefetch exited (reason=cancelled
/// cancelled=true)` says only that somebody called `cancel()`, and the cancel itself printed
/// nothing, so a field capture showing a prefetcher that stops seven seconds into a session and
/// never comes back is indistinguishable from a teardown, a track switch and a rebuild. Two
/// investigations reconstructed it from the adjacency of unrelated lines instead (the whole-file
/// reader that opened 67 microseconds later), which is a reading, not a reading of the log.
///
/// Every teardown route carries one of these, so the line names the caller's intent rather than
/// the mechanism they share.
enum SubtitleDrainStopReason: String, Sendable {
    /// The primary selection moved to an external / sidecar track, which is read whole and needs
    /// no prefetcher. A bitmap one brings the drainer back for its own packets (#921). The common
    /// one in the field.
    case sidecarSelected
    /// Same for the secondary companion channel.
    case secondarySidecarSelected
    /// An external track backfilled straight out of a finished native store: no decode, but the
    /// embedded drain target goes away all the same.
    case externalStoreBackfill
    /// In-band CEA-608/708 is fed by the producer's caption tap, not by the drainer.
    case closedCaptionsSelected
    /// A rendition the proxy injected into the served master: AVPlayer draws it, the overlay does not.
    case injectedRenditionSelected
    /// A live rendition playlist feeds the overlay directly.
    case liveRenditionSelected
    /// #921: a bitmap sidecar's packets were dropped, whatever the selection moves to next.
    case sidecarReleased
    /// Subtitles off.
    case subtitlesCleared
    /// The session itself is going away (`stopInternal`), so nothing is expected to survive.
    case sessionStopped
    /// `startSubtitleForwardPrefetcher` is replacing a running session with a new one (a changed
    /// lead, or a jump the in-place re-anchor cannot serve). The one reason that is not a loss.
    case prefetchRebuild
}
