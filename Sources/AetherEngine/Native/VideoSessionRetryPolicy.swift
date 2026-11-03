import Foundation

/// When to retry a video-session rebuild that VideoToolbox refused while the picture is on screen (in the
/// foreground, or in the background with picture-in-picture).
///
/// A refused rebuild leaves the decoder dropping every packet, with audio still playing. The retry is keyed
/// on the stream, not on a timer: each keyframe fed while the session is still lost is one chance, because
/// from a keyframe on a new session could show a picture again. The first attempts come quickly. After them
/// the retries slow down rather than stop, so a session the system gives back later recovers without a load.
struct VideoSessionRetryPolicy: Equatable {
    /// Keyframes tried at the quick spacing before the retries slow down.
    static let maxAttempts = 4
    /// Wall-clock seconds between the quick attempts. A lost decoder enqueues nothing, so the demux loop is not
    /// paced and keyframes can arrive in a burst: without a gap the whole quick budget would go in milliseconds,
    /// leaving a short-lived refusal no time to clear.
    static let minSpacing: TimeInterval = 2.0
    /// Wall-clock seconds between attempts once the quick ones are spent. A refused rebuild costs little, and
    /// a session the system gives back later is picked up at the first keyframe after the wait.
    static let slowSpacing: TimeInterval = 30.0

    enum Decision: Equatable {
        /// Try the rebuild now.
        case retry(attempt: Int)
        /// Nothing to do: recovery is not owed, or the last attempt is too recent.
        case none
    }

    private(set) var attempts = 0
    private var lastAttempt: TimeInterval?

    /// A keyframe was fed while the session is lost. `owed` is whether the host still owes a recovery.
    mutating func onKeyframe(owed: Bool, now: TimeInterval) -> Decision {
        guard owed else { return .none }
        let spacing = attempts < Self.maxAttempts ? Self.minSpacing : Self.slowSpacing
        if let lastAttempt, now - lastAttempt < spacing { return .none }
        attempts += 1
        lastAttempt = now
        return .retry(attempt: attempts)
    }

    /// A rebuild succeeded, or the picture came back on screen: the next loss starts a fresh quick budget.
    mutating func reset() {
        attempts = 0
        lastAttempt = nil
    }
}
