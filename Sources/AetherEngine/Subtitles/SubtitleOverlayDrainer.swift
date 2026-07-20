import Foundation

/// #112 rework: playhead-paced decode planning for the subtitle overlay. The drainer
/// replaces the embedded side reader's positioning/pacing half: it reads packets from
/// the SubtitlePacketStore near the playhead and decodes them into the existing
/// applySubtitleEvent path, so the PGS stale-arrival gate, trim state machine, and
/// retention semantics stay playhead-relative and untouched.
struct SubtitleDrainCursor: Sendable {
    /// Source PTS (seconds) of the last packet handed to the decoder.
    var lastDecodedPts: Double
    /// Playhead at the previous tick; a jump beyond the threshold means the user
    /// seeked (or the producer re-anchored) and the decoder must be rebuilt.
    var lastPlayhead: Double
}

enum SubtitleDrainPlan: Equatable, Sendable {
    /// Continue decoding forward from the cursor (exclusive) through the lead edge.
    case decode(from: Double, through: Double)
    /// Discontinuity: rebuild the decoder, then decode the window around the playhead.
    case resetAndDecode(from: Double, through: Double)
    /// Caught up; nothing worth scanning this tick.
    case idle
}

enum SubtitleOverlayDrainer {
    /// Sub-second forward windows are not worth a store scan; the next tick accumulates.
    /// The cursor only ever advances to an actually-decoded packet's PTS, so deferring
    /// the scan never skips late-arriving packets.
    static let minimumScanWindowSeconds: Double = 1.0

    static func drainPlan(cursor: SubtitleDrainCursor?, playhead: Double,
                          lead: Double, backscan: Double,
                          jumpThreshold: Double) -> SubtitleDrainPlan {
        let through = playhead + lead
        guard let cursor else {
            return .resetAndDecode(from: playhead - backscan, through: through)
        }
        if abs(playhead - cursor.lastPlayhead) > jumpThreshold {
            return .resetAndDecode(from: playhead - backscan, through: through)
        }
        guard through - cursor.lastDecodedPts >= minimumScanWindowSeconds else {
            return .idle
        }
        return .decode(from: cursor.lastDecodedPts.nextUp, through: through)
    }

    /// #143 follow-up: whether a reconstruction pass should be finalized this tick because no
    /// successor composition can end it. `admitDuringReconstruction` flushes the seeded active-line
    /// candidate only when a composition at/after the playhead decodes; a landing set that is the
    /// newest composition in the file (or whose next line is beyond the forward lead window) has no
    /// such trigger, so the candidate hangs and the overlay stays dark. Finalize only inside a
    /// reconstruction pass, only with a seeded candidate (a true gap with nothing decoded behind the
    /// playhead is left alone), and only when nothing is stored ahead in the lead window (a stored
    /// successor ends the pass the normal way).
    static func shouldFinalizeReconstruction(reconstructing: Bool,
                                             hasCandidate: Bool,
                                             hasSuccessorAhead: Bool) -> Bool {
        reconstructing && hasCandidate && !hasSuccessorAhead
    }
}
