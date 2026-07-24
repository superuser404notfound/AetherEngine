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

    /// Whether a reconstruction pass should be finalized after its drain window has decoded.
    /// A renderable composition at/after the playhead ends the pass inside
    /// `admitDuringReconstruction`. If the pass is still active with a seeded candidate, only
    /// non-rendering packets such as a PGS clear were decoded ahead, or no successor was present.
    static func shouldFinalizeReconstruction(reconstructing: Bool,
                                             hasCandidate: Bool) -> Bool {
        reconstructing && hasCandidate
    }
}
