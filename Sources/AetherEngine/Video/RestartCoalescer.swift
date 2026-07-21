import Foundation

/// Collapses burst seek restarts to in-flight + one pending (AetherEngine#35). Rapid scrubs on loopback-HLS fired one `performRestart` per position (up to 5s `waitForFinish` + demuxer seek each); timeout left the abandoned producer reading the shared demuxer, stealing the first post-seek packet. Not thread-safe; HLSVideoEngine mutates under `restartLock`.
struct RestartCoalescer {
    private var inFlight = false
    private var pending: Int?
    /// Set when `pending` came from an authoritative re-anchor (issue #79). An authoritative target is a
    /// recovery re-base computed from AVPlayer's REAL rendered position (the seek-deadline reconcile or the
    /// backpressure wedge breaker), not a best-effort scrub target. It must win the pending slot so a stale
    /// burst-tail scrub can't override it and leave the producer anchored away from the position the engine
    /// clock was reconciled to (the #79 permanent wedge). A later authoritative target still replaces it
    /// (AVPlayer moved). Cleared once the target is consumed by `next`.
    private var pendingAuthoritative = false

    /// Returns `true` if the caller should become the in-flight worker; `false` if coalesced (in-flight worker will pick it up via `next(justRan:)`).
    ///
    /// `authoritative` marks a recovery re-anchor (#79): it overwrites `pending` and locks the slot, so a
    /// subsequent ordinary scrub `begin` is dropped rather than clobbering it. A non-authoritative scrub never
    /// overwrites an authoritative pending. Whichever runs as the in-flight worker still drains via `next`.
    mutating func begin(_ idx: Int, authoritative: Bool = false) -> Bool {
        if inFlight {
            if authoritative {
                pending = idx
                pendingAuthoritative = true
            } else if !pendingAuthoritative {
                pending = idx
            }
            // else: an authoritative pending owns the slot; drop this scrub. Since #178 a NEW user
            // seek releases the slot (clearSupersededAuthoritativePending) before its segment GETs
            // can fire a restart, so what lands here is a stale burst-tail fetch from an abandoned
            // position, exactly what the #79 lock exists to block.
            return false
        }
        inFlight = true
        return true
    }

    /// True while a coalesced restart run is executing (#93 residual: segment fetches ride this
    /// instead of burning fixed retry budgets against a progressing restart).
    var isInFlight: Bool { inFlight }

    /// #178: a NEW user seek makes a pending authoritative recovery re-anchor obsolete; it was
    /// computed for the seek being superseded. Dropping it releases the slot lock so the new seek's
    /// segment-driven restart is not discarded (the #79 lock exists to block STALE burst-tail
    /// scrubs, not fresher user intent), and removes a target that would otherwise re-anchor the
    /// producer away from where AVPlayer plays next. Ordinary pendings keep their newest-wins flow.
    mutating func clearSupersededAuthoritativePending() {
        guard pendingAuthoritative else { return }
        pending = nil
        pendingAuthoritative = false
    }

    /// Returns next pending target, or `nil` when the burst has settled (clears in-flight flag).
    mutating func next(justRan idx: Int) -> Int? {
        if let p = pending, p != idx {
            pending = nil
            pendingAuthoritative = false
            return p
        }
        pending = nil
        pendingAuthoritative = false
        inFlight = false
        return nil
    }
}
