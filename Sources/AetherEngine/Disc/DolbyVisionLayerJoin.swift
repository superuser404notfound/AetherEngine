import Foundation

/// Joins the two layers of a Dolby Vision Profile 7 source whose enhancement layer is carried apart from the base
/// layer (the UHD Blu-ray layout: its own transport PID, or a Matroska / MP4 track of its own) into the one-unit-per-
/// picture shape the dual-layer route reads from a single-track remux.
///
/// Each layer is a complete HEVC bitstream in its own decode order, so a unit is the n-th base access unit and the
/// n-th enhancement access unit, never the enhancement unit with the same presentation time: the enhancement decoder
/// must see its pictures in its own decode order, and `DualLayerPictureAlignment` already places each picture by its
/// own display slot. The ordinal is anchored at a common IRAP, because after a seek (or when the read starts) the
/// two layers do not begin at the same place: libavformat lands on a base-layer keyframe, and the enhancement
/// layer's packets before the first picture of that point are leading units that no decoder could start from. An
/// anchor is a base IRAP and an enhancement IRAP with the same presentation time. Everything before it is retired.
///
/// Two repairs keep the ordinal honest once locked, both only when the layers carry the same time per unit (every
/// disc does): a unit whose enhancement partner is missing goes out base-only and an extra enhancement unit is
/// dropped, judged by presentation time after sixteen consecutive units agreed; and at every base IRAP the
/// enhancement head is checked to be the IRAP with the same time, resynchronised within the queue when it is not.
///
/// A third check covers a unit lost soon after a lock, before sixteen units could agree (the time repair above
/// trusts the layers' times only after that run, and a loss ends the run). It works at base IRAPs, where the enhancement
/// head must be the IRAP with the same time: when it is not, and that IRAP is not queued (the resynchronisation above
/// handles that case), either the enhancement IRAP was paired already (the enhancement layer is ahead) or it has not
/// been read yet (the base layer lost a unit, or the enhancement IRAP itself was lost). In the first case the time
/// repair is switched on at once; in the second the base IRAP waits, within `repairLookahead` enhancement units and
/// the queue time limit, for the enhancement IRAP, which the resynchronisation then lands on; with none in sight the
/// time repair is switched on as well. The IRAP check switches the time repair on as a mature run would (the run of
/// agreeing units is counted as reached), so the repair itself decides by time which side is stale. So a single
/// lost unit leaves the pairs between the loss and the next base IRAP wrong (the layers' times are not trusted yet,
/// so those units pair by order), at most one GOP, and nothing after it. The check applies only while the layers
/// shared the previous base IRAP's time (or the anchor), and not when the enhancement head is an IRAP of its own
/// time ahead of the base IRAP, so a layer with its own IRAP structure is still paired by order. Where the layers
/// disagree after a run of sixteen and no partner is in sight the base unit goes out alone.
///
/// Queues are bounded by time (with unit counts behind them as a memory backstop), so a file that interleaves its
/// tracks in chunks of a second or two joins without losing a pairing.
///
/// Pure and generic over the unit it holds (the demuxer holds packets, the tests hold plain values). Times are in
/// microseconds, `Int64.min` when unknown.
struct DolbyVisionLayerJoin<Unit> {

    struct Entry {
        var unit: Unit
        var pts: Int64
        var isIRAP: Bool
    }

    enum Step {
        /// One output unit: the base access unit and its enhancement partner, nil when it has none.
        case pair(base: Unit, enhancement: Unit?)
        /// A unit that will never be paired (leading, stale, or beyond a bound), for the caller to free.
        case discard(Unit)
    }

    /// How long, in presentation time, base units may wait for an enhancement unit once locked before the oldest goes
    /// out alone. A time bound, not a count: libavformat's mov reader reads each track in chunks of about a second,
    /// so the base layer legitimately runs a chunk ahead (twenty-four units at 23.976 fps, a hundred and twenty at
    /// 120 fps) before the other track's chunk arrives.
    static var queueTimeLimitMicros: Int64 { 2_000_000 }
    /// The same while searching for the first anchor: the enhancement layer's first IRAP may sit a chunk later.
    static var searchTimeLimitMicros: Int64 { 4_000_000 }
    /// Unit-count backstops behind the time bounds, for memory (units can have no time, or an absurd frame rate):
    /// at most this many base units wait once locked, or while searching.
    static var queueLimit: Int { 240 }
    static var searchLimit: Int { 480 }
    /// Two presentation times are the same when they differ by no more than this (Matroska counts milliseconds,
    /// transport streams 90 kHz ticks).
    static var timeToleranceMicros: Int64 { 2_000 }
    /// Consecutive agreeing units before a disagreement is read as a lost unit rather than as a layer with its own GOP.
    static var agreeingRunForRepair: Int { 16 }
    /// How many units either queue may hold while a disagreement waits for its partner to show up.
    static var repairLookahead: Int { 6 }

    private var base: [Entry] = []
    private var enhancement: [Entry] = []
    private(set) var isLocked = false
    private var agreeingRun = 0
    /// Set when a base unit went out alone because its partner had not arrived within the bound: the enhancement
    /// unit still to come for it is stale, so the ordinal is off by one, and the time-based repair is trusted at once
    /// (without waiting for a run of agreeing units) until the layers agree again.
    private var ordinalSkewed = false
    /// Whether the last base IRAP paired with the enhancement IRAP of its time (true at the anchor): the layers
    /// then share IRAP times, so a base IRAP without its partner at the enhancement head is a lost unit.
    private var irapShared = false
    /// Time of the newest enhancement IRAP taken out of the queue (paired, dropped or retired), `Int64.min` when none.
    private var lastEnhancementIRAP = Int64.min

    /// Units that went out base-only, enhancement units dropped as stale, and resynchronisations at an IRAP.
    private(set) var unpairedBase = 0
    private(set) var droppedEnhancement = 0
    private(set) var resyncs = 0
    /// Locks achieved since the last `reset`: 1 after the first anchor, more after a mid-stream relock.
    private(set) var locks = 0

    var heldBase: Int { base.count }
    var heldEnhancement: Int { enhancement.count }

    mutating func addBase(_ entry: Entry) { base.append(entry) }

    mutating func addEnhancement(_ entry: Entry) {
        enhancement.append(entry)
        // A layer that outruns its partner (a stream with no enhancement units for a long stretch) is bounded; the
        // oldest goes first, which can only lose an anchor that the search would not have used any more.
        if enhancement.count > Self.searchLimit + Self.queueLimit
            || Self.span(of: enhancement) > Self.searchTimeLimitMicros + Self.queueTimeLimitMicros {
            let dropped = takeEnhancement()
            droppedEnhancement += 1
            dropQueue.append(dropped)
        }
    }

    private mutating func takeEnhancement() -> Unit {
        let entry = enhancement.removeFirst()
        if entry.isIRAP { lastEnhancementIRAP = entry.pts }
        return entry.unit
    }

    /// Units retired by a bound outside `next` (see `addEnhancement`); the caller takes and frees them.
    private var dropQueue: [Unit] = []
    mutating func takeRetired() -> [Unit] {
        defer { dropQueue = [] }
        return dropQueue
    }

    /// The next thing to do with what is held, or nil while a decision needs more input. `atEnd` is the end of the
    /// source: nothing more will arrive, so a waiting unit goes out with what it has.
    mutating func next(atEnd: Bool = false) -> Step? {
        if !isLocked, let step = searching(atEnd: atEnd) { return step }
        guard isLocked else { return nil }
        return locked(atEnd: atEnd)
    }

    /// Everything still held, for the caller to free (a seek, a reopen, close). The join starts over.
    mutating func reset() -> [Unit] {
        defer {
            base = []; enhancement = []; dropQueue = []
            isLocked = false; agreeingRun = 0; ordinalSkewed = false; irapShared = false
            lastEnhancementIRAP = Int64.min
        }
        return base.map(\.unit) + enhancement.map(\.unit) + dropQueue
    }

    // MARK: - Search for the anchor

    /// How much presentation time the queue spans (its newest known time past its oldest); 0 when either is unknown.
    private static func span(of queue: [Entry]) -> Int64 {
        guard let first = queue.first?.pts, let last = queue.last?.pts,
              first != Int64.min, last != Int64.min else { return 0 }
        let (d, overflow) = last.subtractingReportingOverflow(first)
        return overflow ? 0 : max(0, d)
    }

    private func baseWaitedTooLong(limitMicros: Int64, limitCount: Int) -> Bool {
        base.count > limitCount || Self.span(of: base) > limitMicros
    }

    private static func sameTime(_ a: Int64, _ b: Int64) -> Bool {
        guard a != Int64.min, b != Int64.min else { return false }
        let (d, overflow) = a.subtractingReportingOverflow(b)
        return !overflow && abs(d) <= timeToleranceMicros
    }

    /// Indices of the first base IRAP that has an enhancement IRAP with its time.
    private func firstCommonIRAP() -> (base: Int, enhancement: Int)? {
        for (bi, b) in base.enumerated() where b.isIRAP {
            if let ei = enhancement.firstIndex(where: { $0.isIRAP && Self.sameTime($0.pts, b.pts) }) {
                return (bi, ei)
            }
        }
        return nil
    }

    private mutating func searching(atEnd: Bool) -> Step? {
        if let (bi, ei) = firstCommonIRAP() {
            // Retire what precedes the anchor, one unit per call so the caller frees each.
            if bi > 0 { return .discard(base.removeFirst().unit) }
            if ei > 0 {
                droppedEnhancement += 1
                return .discard(takeEnhancement())
            }
            isLocked = true
            agreeingRun = 0
            irapShared = true
            locks += 1
            return nil
        }
        // No shared IRAP yet. A base unit that has waited longer than a search may last goes out base-only, and the
        // search goes on with whatever follows (the next IRAP may be shared). At the end of the source everything goes.
        if baseWaitedTooLong(limitMicros: Self.searchTimeLimitMicros, limitCount: Self.searchLimit) || (atEnd && !base.isEmpty) {
            unpairedBase += 1
            return .pair(base: base.removeFirst().unit, enhancement: nil)
        }
        if atEnd, !enhancement.isEmpty {
            droppedEnhancement += 1
            return .discard(takeEnhancement())
        }
        return nil
    }

    // MARK: - Ordinal pairing

    private mutating func locked(atEnd: Bool) -> Step? {
        guard let b = base.first else {
            if atEnd, !enhancement.isEmpty {
                droppedEnhancement += 1
                return .discard(takeEnhancement())
            }
            return nil
        }
        guard let e = enhancement.first else {
            if atEnd || baseWaitedTooLong(limitMicros: Self.queueTimeLimitMicros, limitCount: Self.queueLimit) {
                unpairedBase += 1
                if !atEnd { ordinalSkewed = true }
                return .pair(base: base.removeFirst().unit, enhancement: nil)
            }
            return nil
        }
        // At a base IRAP the enhancement head should be the IRAP with the same time. If it is not and that IRAP is
        // queued further on, the units between are stale (the layers drifted): drop them to land on it.
        if b.isIRAP, !(e.isIRAP && Self.sameTime(e.pts, b.pts)),
           let ei = enhancement.firstIndex(where: { $0.isIRAP && Self.sameTime($0.pts, b.pts) }), ei > 0 {
            resyncs += 1
            droppedEnhancement += 1
            return .discard(takeEnhancement())
        }
        // A base IRAP whose enhancement head is not the IRAP of its time, with none queued: a lost unit shifted the
        // ordinal. Before sixteen units agreed the time repair is off, so decide here (see the type's notes).
        if b.isIRAP, irapShared, !(e.isIRAP && Self.sameTime(e.pts, b.pts)), !ordinalSkewed {
            let paired = Self.sameTime(lastEnhancementIRAP, b.pts)
            let behind = !e.isIRAP || (Self.difference(e.pts, b.pts).map { $0 < -Self.timeToleranceMicros } ?? false)
            if paired {
                agreeingRun = max(agreeingRun, Self.agreeingRunForRepair)
            } else if behind {
                if !atEnd, enhancement.count <= Self.repairLookahead,
                   !baseWaitedTooLong(limitMicros: Self.queueTimeLimitMicros, limitCount: Self.queueLimit) {
                    return nil
                }
                agreeingRun = max(agreeingRun, Self.agreeingRunForRepair)
            }
        }
        if let delta = Self.difference(e.pts, b.pts), agreeingRun >= Self.agreeingRunForRepair || ordinalSkewed,
           abs(delta) > Self.timeToleranceMicros {
            // Both layers are in decode order, so the head times of the two queues say nothing about which side
            // lost a unit; where the head's partner sits does. The base head's time further along the enhancement
            // queue means the enhancement units in front are extra; the enhancement head's time further along the
            // base queue means the base units in front have no partner. Neither visible yet: wait for more input.
            if let k = enhancement.firstIndex(where: { Self.sameTime($0.pts, b.pts) }), k > 0 {
                droppedEnhancement += 1
                return .discard(takeEnhancement())
            }
            if let k = base.firstIndex(where: { Self.sameTime($0.pts, e.pts) }), k > 0 {
                unpairedBase += 1
                return .pair(base: base.removeFirst().unit, enhancement: nil)
            }
            if !atEnd, base.count <= Self.repairLookahead, enhancement.count <= Self.repairLookahead { return nil }
            // No partner anywhere in sight. Base units went out alone just before (the skew): the enhancement units
            // arriving now belong to them, so they are stale. An enhancement unit shown before everything the base
            // layer still holds is stale too. Otherwise the layers agreed on every unit for a stretch and disagree
            // now: an ordinal pair would put a residual on the wrong picture (a disc's units all carry the same
            // time), so the base unit goes out alone and plays as its base layer. The next base IRAP resynchronises
            // (above), and the run of agreeing units, which is kept, makes the next unit with a partner repair as usual.
            if ordinalSkewed || base.map(\.pts).filter({ $0 != Int64.min }).min().map({ e.pts < $0 - Self.timeToleranceMicros }) == true {
                droppedEnhancement += 1
                return .discard(takeEnhancement())
            }
            unpairedBase += 1
            return .pair(base: base.removeFirst().unit, enhancement: nil)
        }
        if b.isIRAP { irapShared = e.isIRAP && Self.sameTime(e.pts, b.pts) }
        if let delta = Self.difference(e.pts, b.pts), abs(delta) <= Self.timeToleranceMicros {
            agreeingRun += 1
            if ordinalSkewed, agreeingRun >= 4 { ordinalSkewed = false }
        } else {
            agreeingRun = 0
        }
        return .pair(base: base.removeFirst().unit, enhancement: takeEnhancement())
    }

    private static func difference(_ a: Int64, _ b: Int64) -> Int64? {
        guard a != Int64.min, b != Int64.min else { return nil }
        let (d, overflow) = a.subtractingReportingOverflow(b)
        return overflow ? nil : d
    }
}
