import Foundation

/// #112 rework: playhead-paced decode planning for the subtitle overlay. The drainer
/// replaces the embedded side reader's positioning/pacing half: it reads packets from
/// the SubtitlePacketStore near the playhead and decodes them into the existing
/// applySubtitleEvent path, so the PGS stale-arrival gate, trim state machine, and
/// retention semantics stay playhead-relative and untouched.
struct SubtitleDrainCursor: Sendable {
    /// Source PTS (seconds) of the last packet handed to the decoder.
    var lastDecodedPts: Double
    /// #362: harvest sequence of that packet, 0 when the cursor sits on a window boundary rather
    /// than on a packet. What the next tick compares its first entry against, to see whether the
    /// two were read by the same run or whether a hole opened right at the cursor.
    var lastDecodedSequence: UInt64 = 0
    /// Playhead at the previous tick; a jump beyond the threshold means the user
    /// seeked (or the producer re-anchored) and the decoder must be rebuilt.
    var lastPlayhead: Double
    /// #250: where the current contiguous decoded run started, i.e. the window start of the last
    /// `.resetAndDecode`. Steady ticks decode forward from the cursor, so the tick's own window
    /// start says nothing about how far back determination reaches. nil until the first reset.
    var coverageStart: Double? = nil
    /// #276: the retained run, i.e. the same span folded ACROSS seeks for as long as the runs keep
    /// touching. Lives on the cursor because the cursor's lifetime is exactly the claim's: both are
    /// cleared by `stopSubtitleDrainer` and by every track switch, and those are the same points
    /// that empty the channel's cue array.
    var retained: SubtitleResolutionStatement.Retention? = nil
    /// #362: the near side of a hole in the stored window this tick stopped at, the harvest
    /// sequence there, and the ticks it may still stop there. Anchored on a position rather than a
    /// flag, so a hole that fills in stages starts a fresh budget at each new boundary instead of
    /// inheriting a spent one.
    var harvestGapAt: Double? = nil
    var harvestGapSequence: UInt64 = 0
    var harvestGapTicksLeft: Int = 0
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

    /// #271: `elapsedSinceLastPlan` is the wall time between this plan and the previous one. Steady
    /// playback advances the playhead by roughly that much, so a tick that itself took longer than
    /// `jumpThreshold` would otherwise read its own duration as a seek and reset onto a fresh,
    /// disjoint window: a positive feedback loop where one slow tick guarantees the next one is
    /// slower. Only FORWARD drift is forgiven; playback never moves the playhead backwards, so a
    /// backward delta is a seek at any tick duration. Rate is not modelled: above 1x a pathologically
    /// slow tick can still trip the threshold, which costs a redundant window decode, not correctness.
    static func drainPlan(cursor: SubtitleDrainCursor?, playhead: Double,
                          lead: Double, backscan: Double,
                          jumpThreshold: Double,
                          elapsedSinceLastPlan: Double = 0) -> SubtitleDrainPlan {
        let through = playhead + lead
        guard let cursor else {
            return .resetAndDecode(from: playhead - backscan, through: through)
        }
        let delta = playhead - cursor.lastPlayhead
        let allowance = delta > 0 ? jumpThreshold + max(0, elapsedSinceLastPlan) : jumpThreshold
        if abs(delta) > allowance {
            return .resetAndDecode(from: playhead - backscan, through: through)
        }
        guard through - cursor.lastDecodedPts >= minimumScanWindowSeconds else {
            return .idle
        }
        return .decode(from: cursor.lastDecodedPts.nextUp, through: through)
    }

    /// #271: how far into a PTS-ordered store window one tick may decode. The window is bounded in
    /// seconds of content (backscan + lead) and never in packets, so its size is set by the file's
    /// subtitle density; a typeset ASS track puts thousands of packets in one window and the decode
    /// loop has no suspension point. `cap` bounds the batch, and the boundary is then extended
    /// forward to the end of the run sharing the last packet's PTS.
    ///
    /// That extension is required, not a nicety: the drain cursor is a bare PTS advanced by
    /// `lastDecodedPts.nextUp`, so a cut INSIDE a same-PTS run would skip its remainder rather than
    /// resume it on the next tick. Bitmap tracks put one composition on a PTS and never notice;
    /// dense ASS deliberately keeps hundreds of distinct payloads on one timestamp and would lose
    /// every one of them past the cut. A single run longer than the cap is therefore decoded whole.
    static func batchEnd(count: Int, cap: Int, ptsAt: (Int) -> Double) -> Int {
        guard cap > 0 else { return count }
        guard count > cap else { return count }
        let boundary = ptsAt(cap - 1)
        var end = cap
        while end < count, ptsAt(end) == boundary { end += 1 }
        return end
    }

    /// #362: where a tick has to stop because the stored window has a hole the harvest is still
    /// filling, rather than a stretch the author left empty. Returns how many entries may decode,
    /// the position the hold is anchored on and the harvest sequence there, or nil when the window
    /// reads as one run.
    ///
    /// After a seek the pump restarts behind the landing and fills forward while the store still
    /// holds an island the previous run harvested further ahead, so the window reads as "packets,
    /// hole, packets". Decoding straight across it advances the cursor to the far side, and the
    /// cursor only ever moves forward: the hole's packets land a second later and are never read,
    /// leaving a stretch of the film with no subtitles at all until some later seek resets the
    /// window behind it (report: eleven authored sets between 2966.6 s and 2988.5 s delivered as
    /// two).
    ///
    /// The size of the gap cannot tell the two apart, and a threshold on it is actively harmful: a
    /// PGS set is separated from its own clear by its display duration, so a 3 s rule stopped the
    /// tick at every authored line and delivery fell to a sixth of the sets in a fixture run.
    /// **Harvest ORDER tells them apart.** A run reads a stream forwards, so its entries carry
    /// ascending PTS and ascending sequence; where a PTS-ascending pair's sequence descends, the
    /// far side was written by an EARLIER run, which means the run that wrote the near side has not
    /// reached the far side yet and the span between them is unread. An authored silence looks
    /// contiguous in sequence and never stops anything, however long it is.
    ///
    /// Stopping at the near side costs nothing visible: the drain runs a 60 s lead ahead of the
    /// playhead, a hole is only honoured while its FAR side lies past `notBefore` (the playhead plus
    /// a short release lead), so everything at or behind the playhead decodes whole and the landing
    /// region with it, and the caller crosses the hole anyway once its tick budget is spent. #941
    /// moved this from the near side: a refill at about 1x keeps the playhead just behind the
    /// filling run, past the last packet before the hole while the hole itself is still ahead. What it does change is the cursor's claim: a tick that stopped at a hole no longer
    /// reports determination past it, which is the honest reading and the one #250 asks for.
    ///
    /// `resumeFrom` is the packet the cursor sits on, i.e. the last one a steady tick decoded, and
    /// it is not optional detail: a hole that opens right at the cursor leaves a window holding
    /// nothing but the island, so there is no pair inside it to compare and the tick would decode
    /// the island and carry the cursor past the hole. That is the reported shape exactly (a set at
    /// 280 s closed at 295 s, the four packets between them never read). Pass nil on a reset, whose
    /// window starts at a backscan boundary rather than at something that was read.
    ///
    /// #941: `isRead` is the #416 ledger, and it covers the half order cannot. A run re-anchored
    /// FORWARD hangs its island behind the stretch it skipped with ascending sequences, so after a
    /// seek past the front and straight back the window reads "old run, hole, newer island" and no
    /// pair descends. Any pair whose span no reader has read is a hole whatever its order says.
    static func harvestGapCut(count: Int, ptsAt: (Int) -> Double,
                              sequenceAt: (Int) -> UInt64,
                              resumeFrom: (pts: Double, sequence: UInt64)?,
                              notBefore: Double,
                              isRead: (Double, Double) -> Bool = { _, _ in true })
        -> (index: Int, at: Double, sequence: UInt64)? {
        guard count > 0 else { return nil }
        var previous = resumeFrom
        for index in 0..<count {
            if let previous, previous.sequence > 0, ptsAt(index) > notBefore,
               sequenceAt(index) < previous.sequence || !isRead(previous.pts, ptsAt(index)) {
                return (index, previous.pts, previous.sequence)
            }
            previous = (ptsAt(index), sequenceAt(index))
        }
        return nil
    }

    /// #362: whether a tick holding at a hole may resume. The window it now sees starts past the
    /// hold position, so the near side is no longer in it and the pair that revealed the hole
    /// cannot be re-formed; what answers instead is the first entry's provenance. A sequence newer
    /// than the one held at means the filling run has reached this position and everything from
    /// the hold to here is read; an older one is still the island on the far side of the hole.
    ///
    /// #941: a newer sequence is necessary and not sufficient. A later reader re-harvesting the
    /// island stamps it newer too, so the ledger has to agree that the ground from the hold up to
    /// that entry was read.
    static func harvestGapHoldResumes(firstSequence: UInt64?, heldSequence: UInt64,
                                      firstPts: Double? = nil, heldAt: Double = 0,
                                      isRead: (Double, Double) -> Bool = { _, _ in true }) -> Bool {
        guard let firstSequence, firstSequence > heldSequence else { return false }
        guard let firstPts else { return true }
        return isRead(heldAt, firstPts)
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
