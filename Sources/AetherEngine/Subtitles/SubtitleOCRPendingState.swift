import Foundation

/// Phase D: pending-composition end resolution for the OCR worker, mirroring the 5.14.1
/// sidecar semantics (SubtitleDecoder.decodeFileSync): a bitmap composition still open at the
/// NEXT composition or clear event ends at that event's PTS; a real earlier end (DVD/DVB
/// end_display_time) survives; the decoder's flat fallback end survives only for a composition
/// with no successor at all (end of stream), emitted once the playhead has passed it.
struct SubtitleOCRPendingState: Sendable {
    /// Playhead margin past a pending cue's own end before it is emitted successor-less. Ahead
    /// of the playhead a successor may still arrive with the next produced/prefetched packets.
    static let expiryMarginSeconds: Double = 2.0

    private var pending: [SubtitleCue] = []

    /// Feed one decoded event (entry PTS + its cues; a PGS clear composition carries only
    /// trimAt). Returns the compositions this event closed, ready for OCR.
    mutating func consume(eventPts: Double, cues: [SubtitleCue], trimAt: Double?) -> [SubtitleCue] {
        let closeAt = trimAt ?? eventPts
        var closed: [SubtitleCue] = []
        var kept: [SubtitleCue] = []
        for cue in pending {
            guard cue.startTime < closeAt else { kept.append(cue); continue }
            let end = cue.endTime > closeAt ? closeAt : cue.endTime
            closed.append(SubtitleCue(id: cue.id, startTime: cue.startTime, endTime: end, body: cue.body))
        }
        pending = kept
        pending.append(contentsOf: cues.filter { if case .image = $0.body { return true } else { return false } })
        return closed
    }

    /// End-of-stream path: emit pending compositions whose own end lies more than the margin
    /// behind the playhead with no successor event having closed them.
    mutating func expired(asOf playhead: Double) -> [SubtitleCue] {
        var closed: [SubtitleCue] = []
        pending.removeAll { cue in
            guard playhead > cue.endTime + Self.expiryMarginSeconds else { return false }
            closed.append(cue)
            return true
        }
        return closed
    }
}
