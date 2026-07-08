import Foundation

/// Holdback for PGS cues that arrive already behind the playhead (issue #100).
///
/// PGS compositions have no intrinsic end: FFmpeg reports `end_display_time = UINT32_MAX`, the
/// decoder stamps the cue with an open-ended placeholder window, and the SUCCESSOR composition's
/// trim closes it (`pgsTrimAt`). In steady state insert and trim land within a frame of each
/// other and nothing untoward shows. When the side reader catches up after starvation (the #96
/// class), the backlog arrives with multi-second decode gaps and every historical cue's open
/// window covers the playhead the moment it inserts, so ~seconds of stale subtitles flash
/// through the overlay one by one.
///
/// The gate holds a PGS event whose cues start more than `staleEpsilonSeconds` behind the
/// playhead (a catch-up signature; a live cue at a seek landing anchors at most ~2 s back and
/// passes straight through). The next PGS event or clear event resolves the hold: trimmed to the
/// successor's start, the cue publishes only if its true window covers the playhead (it is the
/// genuinely active subtitle), otherwise it is dropped silently. Trade-off, accepted: the LAST
/// backlog cue has no successor yet and stays held until the next composition arrives; missing
/// one line briefly beats replaying 80 s of history through the live overlay.
struct PGSStaleArrivalGate {
    let staleEpsilonSeconds: Double
    private(set) var heldCues: [SubtitleCue] = []

    /// #112 full umbau: set while the reader decodes the region behind a fresh seek target to reconstruct the
    /// active line. In this window a self-contained composition (Acquisition Point / Epoch Start) covering the
    /// playhead is the current line and publishes immediately, instead of being held for successor resolution
    /// (the "several tens of seconds" gap). Auto-cleared once the reader decodes a cue at/after the playhead, so a
    /// #100 catch-up backlog outside a reconstruction (normal replays, or historical acquisition points long
    /// behind the playhead) still cannot flash.
    var reconstructing: Bool = false

    init(staleEpsilonSeconds: Double = 5.0) {
        self.staleEpsilonSeconds = staleEpsilonSeconds
    }

    var hasHeld: Bool { !heldCues.isEmpty }

    /// Resolve the held event against its successor's trim point. Returns the cues to publish
    /// NOW: the held cues trimmed to `trimAt`, filtered to those whose true window covers the
    /// playhead. History that ended before the playhead is dropped.
    mutating func resolveHeld(trimAt: Double, playhead: Double) -> [SubtitleCue] {
        guard !heldCues.isEmpty else { return [] }
        let resolved = heldCues.map { cue in
            SubtitleCue(id: cue.id, startTime: cue.startTime,
                        endTime: min(cue.endTime, trimAt), body: cue.body)
        }
        heldCues = []
        return resolved.filter { $0.startTime <= playhead && playhead < $0.endTime }
    }

    /// Admit an incoming event's cues. Stale PGS arrivals (every cue starting more than the
    /// epsilon behind the playhead) are held for successor resolution and publish nothing yet;
    /// everything else passes through unchanged.
    ///
    /// #112 full umbau: `isSelfContained` marks an Acquisition Point / Epoch Start - a composition that rebuilds
    /// the visible line on its own. While `reconstructing` (decoding just behind a fresh seek target), such a
    /// composition covering the playhead publishes immediately: it is the current line, not stale replay. Seeing a
    /// cue at/after the playhead means the reader caught up, so reconstruction mode ends and the #100 stale hold
    /// governs again - a catch-up backlog of Normal replays (or acquisition points long behind the playhead, once
    /// out of reconstruction) stays held and cannot flash.
    mutating func admit(cues: [SubtitleCue], isPGS: Bool, isSelfContained: Bool = false, playhead: Double) -> [SubtitleCue] {
        guard isPGS, !cues.isEmpty else { return cues }
        if cues.contains(where: { $0.startTime >= playhead - staleEpsilonSeconds }) {
            reconstructing = false
        }
        if reconstructing, isSelfContained, cues.contains(where: { $0.startTime <= playhead }) {
            return cues
        }
        let stale = cues.allSatisfy { $0.startTime < playhead - staleEpsilonSeconds }
        guard stale else { return cues }
        heldCues = cues
        return []
    }

    /// Drop the hold without publishing (seek re-anchor, track switch, clear, stop).
    mutating func reset() {
        heldCues = []
    }
}
