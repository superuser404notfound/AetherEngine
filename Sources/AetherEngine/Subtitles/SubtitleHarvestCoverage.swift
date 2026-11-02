import Foundation

/// #416: which spans of the source a harvest has actually READ, as distinct from the packets it
/// stored.
///
/// A PGS display set has no end of its own, so "no packet between this set and the playhead" is how
/// the drain decides that a set decoded behind a seek landing is the line still on screen there.
/// That inference is worth exactly as much as the reading behind it. Where a run was abandoned
/// mid-flight and its successor re-anchored somewhere else, the span between them was never read,
/// and a set stranded on the near side of that hole keeps looking active for as long as the store
/// stays empty in front of it: the reporter's case is a set whose authored clear lies inside the
/// hole, published over a scene ten seconds later and closed at the far side of the silence.
///
/// #362 round 2 established that no arrangement of the packets that DID arrive can show this. A
/// reader restarted BEHIND leaves a descending harvest sequence at the boundary, but one re-anchored
/// FORWARD hangs its packets in ascending order behind the stretch it skipped, so the pair looks
/// exactly like an authored silence. The ledger was named there as the precise signal and left
/// unbuilt for want of a reproducible defect; #416 is that defect.
///
/// Every note is a whole span, stated by the reader that read it: an anchor says where a run began,
/// progress says how far that run has got, and a run is contiguous by construction because a
/// demuxer reads forwards. Closed runs merge into a sorted, disjoint list. `covers` answers the one
/// question the drain asks, which is not "is there a packet here" but "did anyone look".
struct SubtitleHarvestCoverage: Sendable, Equatable {

    struct Span: Sendable, Equatable {
        var from: Double
        var through: Double
    }

    /// Two runs that meet within this are treated as one. It exists for the seam between a run that
    /// stopped and the one that took over from it, which never line up to the sample: the pump
    /// re-opens on a keyframe boundary, the side reader on a subtitle packet. It is deliberately
    /// far smaller than any authored dwell, so a real hole can never hide inside it.
    static let seamSeconds: Double = 0.25

    /// A run may not be extended by more than this in one note. Every reader announces its anchor,
    /// so a legitimate step is either sub-second (steady reading) or the distance from a fresh
    /// anchor to the playhead it landed at. A larger step means a reposition nobody announced, and
    /// extending across it would claim a stretch nobody read, which is the one failure mode this
    /// type must not have. Such a step starts a new run instead.
    static let maxUnannouncedAdvanceSeconds: Double = 30

    /// Bound on the retained spans. Dropping the lowest-positioned ones (a session's earliest
    /// ground) under-claims coverage, which costs a landing line at worst; growing without bound
    /// would cost a session.
    static let maxSpans: Int = 128

    private var closed: [Span] = []
    private var open: [SubtitlePacketStore.Writer: Span] = [:]

    /// No note has ever been made. Callers read this as "nothing is known", never as "nothing was
    /// read": a path whose readers do not report has to keep behaving exactly as it did before.
    var isEmpty: Bool { closed.isEmpty && open.isEmpty }

    /// A run starts here: this reader has positioned at `seconds` and will read forwards from it.
    mutating func noteAnchor(_ writer: SubtitlePacketStore.Writer, at seconds: Double) {
        guard seconds.isFinite else { return }
        closeRun(writer)
        open[writer] = Span(from: seconds, through: seconds)
    }

    /// One step of a reader working its way forwards: its loop has read through `seconds`.
    ///
    /// A step larger than `maxUnannouncedAdvanceSeconds` is not treated as reading but as a
    /// reposition its reader did not announce, and starts a new run. That costs the coverage of a
    /// reader whose notes are genuinely that far apart, and it is the safety net for the one failure
    /// mode this type must not have: extending a run across ground nobody read would put the defect
    /// back silently. Callers whose claim rests on an invariant rather than on observed steps use
    /// `noteReach` instead.
    mutating func noteProgress(_ writer: SubtitlePacketStore.Writer, through seconds: Double) {
        guard seconds.isFinite else { return }
        guard var run = open[writer] else {
            // No anchor yet: the position itself is all that is known, and a point covers nothing.
            open[writer] = Span(from: seconds, through: seconds)
            return
        }
        guard seconds > run.through else { return }
        guard seconds - run.through <= Self.maxUnannouncedAdvanceSeconds else {
            closeRun(writer)
            open[writer] = Span(from: seconds, through: seconds)
            return
        }
        run.through = seconds
        open[writer] = run
    }

    /// The caller states that this reader's current run has reached `seconds` from its anchor,
    /// however far that is in one note.
    ///
    /// The pump's coverage is stated this way, because it does not come from watching its loop: it
    /// comes from playback rendering at the playhead, which cannot happen unless the pump read
    /// everything from where it opened up to there. A step-size rule has nothing to say about that
    /// claim, and would break it exactly where it matters: a track selected an hour into a film
    /// makes the drain's first note an hour-long step over ground the pump certainly read, and
    /// refusing it would dark the very landing the selection is asking for.
    ///
    /// This trusts every reposition to be announced with `noteAnchor`. For the pump that is the
    /// producer's open and restart on the native path (`makeProducer` has exactly those two
    /// callers) and the host reposition on the software path.
    mutating func noteReach(_ writer: SubtitlePacketStore.Writer, through seconds: Double) {
        guard seconds.isFinite else { return }
        guard var run = open[writer] else {
            open[writer] = Span(from: seconds, through: seconds)
            return
        }
        guard seconds > run.through else { return }
        run.through = seconds
        open[writer] = run
    }

    /// Was every second between `from` and `through` read by some run? An empty or inverted span is
    /// trivially covered: there is nothing in it to have missed.
    func covers(from: Double, through: Double) -> Bool {
        Self.covers(sortedSpans(), from: from, through: through)
    }

    /// `covers` over spans already sorted by start, for a caller asking many questions of one
    /// snapshot (#941: one drain tick asks once per stored pair).
    static func covers(_ spans: [Span], from: Double, through: Double) -> Bool {
        guard from.isFinite, through.isFinite, through > from else { return true }
        var cursor = from
        for span in spans {
            guard span.from <= cursor + Self.seamSeconds else { return false }
            cursor = max(cursor, span.through)
            if cursor >= through { return true }
        }
        return cursor >= through
    }

    /// Every span this ledger holds, open runs included, sorted by start. Small by construction
    /// (`maxSpans` plus one run per writer), so the sort is cheaper than keeping a second index.
    func sortedSpans() -> [Span] {
        (closed + open.values).sorted { $0.from < $1.from }
    }

    private mutating func closeRun(_ writer: SubtitlePacketStore.Writer) {
        guard let run = open.removeValue(forKey: writer) else { return }
        insert(run)
    }

    /// Merge a finished run into the sorted, disjoint list.
    private mutating func insert(_ span: Span) {
        guard span.through > span.from else { return }   // a point run read nothing
        var merged = span
        var out: [Span] = []
        out.reserveCapacity(closed.count + 1)
        var inserted = false
        for existing in closed {
            if existing.through + Self.seamSeconds < merged.from {
                out.append(existing)
            } else if existing.from > merged.through + Self.seamSeconds {
                if !inserted { out.append(merged); inserted = true }
                out.append(existing)
            } else {
                merged.from = min(merged.from, existing.from)
                merged.through = max(merged.through, existing.through)
            }
        }
        if !inserted { out.append(merged) }
        closed = out.sorted { $0.from < $1.from }
        if closed.count > Self.maxSpans { closed.removeFirst(closed.count - Self.maxSpans) }
    }
}
