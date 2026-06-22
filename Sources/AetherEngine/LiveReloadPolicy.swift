import Foundation

/// Positioning policy for pipeline reloads (audio-track switch, background-return reopen). Pure decisions, testable and centralized so the rule cannot drift across `reloadWithAudioOverride`'s two backend branches and `reloadAtCurrentPosition`.
///
/// Live rules exist because of a device-verified stall (tvOS 26, Jellyfin live `stream.ts`, 2026-06): reloading a live session against the same URL caused Jellyfin to re-serve its transcode backlog (~60 s, segments 0..19) at I/O speed before AVPlayer's first playlist fetch. The pre-readiness seek-to-0 then pointed 60 s behind the live edge while AVPlayer targeted edge-minus-holdback; the item fetched init.mp4 + all segments but never reached `readyToPlay`, parking in `waitingToPlay` forever (frozen frame). Fix: treat any live reload as a fresh join -- no stale-clock resume, no explicit start seek.
enum LiveReloadPolicy {

    /// Start position handed to `loadNative` / `loadSoftware` / `load(url:)`.
    ///
    /// - VOD: pre-reload playhead; positions <= 1 s collapse to nil to skip the seek at head.
    /// - Live: always nil. The DVR window restarts at rejoin; a position would be stale and could wedge AVPlayer against the backlog.
    static func resumePosition(isLive: Bool, currentTime: Double) -> Double? {
        if isLive { return nil }
        return currentTime > 1 ? currentTime : nil
    }

    /// Whether the native host should skip its explicit initial seek and let AVPlayer choose the join position.
    ///
    /// - Live REJOIN: true. Skipping gives AVPlayer edge-minus-holdback (3x TARGETDURATION), same as `loadRemoteHLS`. The zero-tolerance seek-to-0 is the prime suspect for the never-ready AVPlayerItem against Jellyfin's backlog.
    /// - Initial live JOIN: false. The first manifest is held until the 2-segment startup cushion exists; seg0 is already the cushioned edge; the explicit seek-to-0 reinforces it (device-verified; do not change).
    /// - VOD: false. Explicit seek makes replay-from-beginning land at 0:00.
    static func skipInitialSeek(isLive: Bool, isRejoin: Bool) -> Bool {
        isLive && isRejoin
    }
}
