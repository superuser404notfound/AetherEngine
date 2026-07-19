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
    /// active line. In this window compositions behind the playhead are held (not published) and only the single
    /// line active at the playhead is emitted, so the lead-in's earlier compositions cannot scroll through the
    /// overlay. Auto-cleared once the reader decodes a cue at/after the playhead.
    var reconstructing: Bool = false

    /// #112: during a reconstruction pass, the newest composition at/behind the playhead seen so far - the
    /// candidate active line. Held, not published. Publishing every self-contained composition in the lead-in as
    /// it decoded scrolled ~24 s of history through the frozen overlay (ijuniorfu: "the subtitles keep changing
    /// while paused"). Emitted as the single active line when the decode reaches the playhead (a composition at or
    /// after it arrives), or dropped/superseded by a newer one first. #143: seeded from ANY decoded composition,
    /// not only self-contained ones; see `admitDuringReconstruction`.
    private(set) var reconstructionCandidate: SubtitleCue?

    init(staleEpsilonSeconds: Double = 5.0) {
        self.staleEpsilonSeconds = staleEpsilonSeconds
    }

    var hasHeld: Bool { !heldCues.isEmpty || reconstructionCandidate != nil }

    /// Resolve the held event against its successor's trim point. Returns the cues to publish
    /// NOW: the held cues trimmed to `trimAt`, filtered to those whose true window covers the
    /// playhead. History that ended before the playhead is dropped.
    ///
    /// #143: the trim also closes the reconstruction candidate's open window. Every PGS composition
    /// AND clear broadcasts its start as `pgsTrimAt`, but a clear carries no cues and never reaches
    /// `admit`; without this trim a line the author cleared before the playhead keeps its open
    /// placeholder window and resurrects as the "active" line at pass end.
    mutating func resolveHeld(trimAt: Double, playhead: Double) -> [SubtitleCue] {
        if let candidate = reconstructionCandidate,
           candidate.startTime < trimAt, candidate.endTime > trimAt {
            reconstructionCandidate = SubtitleCue(id: candidate.id, startTime: candidate.startTime,
                                                  endTime: trimAt, body: candidate.body)
        }
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
    /// the visible line on its own. While `reconstructing` (decoding just behind a fresh seek target), admit is
    /// delegated to `admitDuringReconstruction`, which holds the lead-in's compositions and emits only the single
    /// line active at the playhead. Outside reconstruction the #100 stale hold governs: a catch-up backlog of
    /// arrivals behind the playhead is held for successor resolution and cannot flash through the overlay.
    mutating func admit(cues: [SubtitleCue], isPGS: Bool, isSelfContained: Bool = false, playhead: Double) -> [SubtitleCue] {
        guard isPGS, !cues.isEmpty else { return cues }
        if reconstructing {
            return admitDuringReconstruction(cues: cues, isSelfContained: isSelfContained, playhead: playhead)
        }
        let stale = cues.allSatisfy { $0.startTime < playhead - staleEpsilonSeconds }
        guard stale else { return cues }
        heldCues = cues
        return []
    }

    /// #112: admit during a reconstruction pass. Compositions at/behind the playhead update the single candidate
    /// active line and publish nothing, so the lead-in's earlier lines never scroll through the frozen overlay.
    /// The first composition at or after the playhead ends the pass: the active line (the candidate, or a
    /// just-decoded composition at the playhead) is emitted once, together with any cues ahead of the playhead
    /// (future, stored but not yet shown).
    ///
    /// #143: the candidate is seeded from ANY decoded composition behind the playhead. Requiring a self-contained
    /// composition (Acquisition Point / Epoch Start) for the FIRST seed dropped the seek-landing line on AP-less/
    /// sparse-authored streams: every lead-in composition is Normal there, so no candidate was ever seeded and the
    /// landing-span line, forced cues included, stayed dark until the next authored composition. A composition
    /// that decoded at all is renderable (the drain decoder is rebuilt fresh at the backscan start, so a set whose
    /// references are missing fails decode and never gets here), and the steady-state path outside reconstruction
    /// already publishes Normal compositions unconditionally. `isSelfContained` stays on the signature: callers
    /// keep reporting the PCS classification, which the epoch-start-aware backscan direction would need.
    private mutating func admitDuringReconstruction(cues: [SubtitleCue], isSelfContained: Bool, playhead: Double) -> [SubtitleCue] {
        let newestBehind = cues.filter { $0.startTime <= playhead }.max(by: { $0.startTime < $1.startTime })
        if let newestBehind,
           reconstructionCandidate.map({ newestBehind.startTime >= $0.startTime }) ?? true {
            reconstructionCandidate = newestBehind
        }
        guard cues.contains(where: { $0.startTime >= playhead }) else {
            return []
        }
        reconstructing = false
        var out = cues.filter { $0.startTime > playhead }
        let active = [reconstructionCandidate, newestBehind]
            .compactMap { $0 }.max(by: { $0.startTime < $1.startTime })
        reconstructionCandidate = nil
        if let active, active.startTime <= playhead, playhead < active.endTime {
            // Round 8: close the emitted line at its successor's start. The successor's pgsTrimAt ran against the
            // store while this line was held here, so its open-ended placeholder survives; unclosed, both lines
            // cover the playhead from the successor's start until the NEXT composition trims, and two PGS bitmaps
            // stack on screen (ijuniorfu: "subtitles occasionally overlap"). With no published ahead cue the open
            // window stays and the store trim owns it, as before.
            let successorStart = out.map(\.startTime).min() ?? active.endTime
            out.append(SubtitleCue(id: active.id, startTime: active.startTime,
                                   endTime: min(active.endTime, successorStart), body: active.body))
        }
        return out
    }

    /// Drop the hold without publishing (seek re-anchor, track switch, clear, stop).
    mutating func reset() {
        heldCues = []
        reconstructionCandidate = nil
        reconstructing = false
    }
}
