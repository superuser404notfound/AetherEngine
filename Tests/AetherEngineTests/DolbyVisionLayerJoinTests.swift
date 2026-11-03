import Foundation
import Testing
@testable import AetherEngine

// The joiner pairs the n-th base access unit with the n-th enhancement access unit of the same decode order,
// anchored at a common IRAP; these pin its decisions with plain values standing in for packets.
@Suite("Dolby Vision layer join")
struct DolbyVisionLayerJoinTests {

    typealias Join = DolbyVisionLayerJoin<String>
    private static let frame: Int64 = 41_708   // 23.976 fps in microseconds

    /// A layer's access units in decode order: `gop` pictures with the B-pyramid reorder 0 3 1 2 6 4 5 ..., an IRAP
    /// at the first picture of every GOP. `first` is the display index of the first unit.
    private static func layer(_ tag: String, gops: Int, gop: Int = 6, first: Int = 0, skipIRAP: Set<Int> = []) -> [Join.Entry] {
        var out: [Join.Entry] = []
        for g in 0..<gops {
            let start = first + g * gop
            var order = [0]
            var i = 1
            while i + 2 < gop + 1 {
                order += [i + 2, i, i + 1]
                i += 3
            }
            for (k, d) in order.enumerated() where d < gop {
                let display = start + d
                out.append(Join.Entry(unit: "\(tag)\(display)", pts: Int64(display) * frame,
                                      isIRAP: k == 0 && !skipIRAP.contains(start)))
            }
        }
        return out
    }

    /// Feeds both layers (interleaved the way a transport stream does, enhancement a step behind) and drains.
    private static func run(base: [Join.Entry], enhancement: [Join.Entry], join: inout Join)
        -> (pairs: [(String, String?)], discarded: [String]) {
        var pairs: [(String, String?)] = []
        var discarded: [String] = []
        func drain(atEnd: Bool) {
            while let step = join.next(atEnd: atEnd) {
                switch step {
                case let .pair(b, e): pairs.append((b, e))
                case .discard(let u): discarded.append(u)
                }
            }
            discarded += join.takeRetired()
        }
        for i in 0...max(base.count, enhancement.count) {
            if i < base.count { join.addBase(base[i]) }
            if i >= 1, i - 1 < enhancement.count { join.addEnhancement(enhancement[i - 1]) }
            drain(atEnd: false)
        }
        drain(atEnd: true)
        return (pairs, discarded)
    }

    @Test("units pair in each layer's own decode order, reordered pictures included")
    func decodeOrder() {
        var join = Join()
        let base = Self.layer("b", gops: 4)
        let enh = Self.layer("e", gops: 4)
        let result = Self.run(base: base, enhancement: enh, join: &join)
        #expect(result.pairs.count == base.count)
        #expect(result.pairs.map(\.0) == base.map(\.unit))
        #expect(result.pairs.compactMap(\.1) == enh.map(\.unit))
        #expect(result.discarded.isEmpty)
        #expect(join.locks == 1 && join.unpairedBase == 0 && join.droppedEnhancement == 0)
    }

    @Test("a layer whose picture is missing in the enhancement layer sends that base unit out alone and realigns")
    func missingEnhancementUnit() {
        var join = Join()
        let base = Self.layer("b", gops: 12)
        var enh = Self.layer("e", gops: 12)
        let lost = 37   // the unit after it is displayed before it: head times alone would misjudge this
        enh.remove(at: lost)
        let result = Self.run(base: base, enhancement: enh, join: &join)
        #expect(result.pairs.count == base.count)
        let alone = result.pairs.filter { $0.1 == nil }.map(\.0)
        #expect(alone == [base[lost].unit])
        // Everything after the hole is paired with the unit of its own picture again.
        for (b, e) in result.pairs.dropFirst(lost + 1) {
            #expect(e?.dropFirst() == b.dropFirst(), "\(b) paired with \(e ?? "none")")
        }
        #expect(join.unpairedBase == 1)
    }

    @Test("an extra enhancement unit is dropped, not paired")
    func extraEnhancementUnit() {
        var join = Join()
        let base = Self.layer("b", gops: 12)
        var enh = Self.layer("e", gops: 12)
        enh.insert(Join.Entry(unit: "extra", pts: enh[36].pts + 7_000_000, isIRAP: false), at: 37)
        let result = Self.run(base: base, enhancement: enh, join: &join)
        #expect(result.pairs.count == base.count)
        #expect(!result.pairs.compactMap(\.1).contains("extra"))
        #expect(result.discarded.contains("extra"))
        for (b, e) in result.pairs {
            #expect(e?.dropFirst() == b.dropFirst(), "\(b) paired with \(e ?? "none")")
        }
        #expect(join.droppedEnhancement >= 1)
    }

    @Test("after a seek the enhancement layer's leading units before the shared IRAP are retired")
    func seekIntoMidGOP() {
        var join = Join()
        // The base layer lands on the keyframe of GOP 3 (display 18); the enhancement layer starts two units earlier,
        // in the tail of GOP 2, as a cluster-aligned seek leaves it.
        let base = Self.layer("b", gops: 4, first: 18)
        let tail = Self.layer("e", gops: 1, first: 12).suffix(2)
        let enh = Array(tail) + Self.layer("e", gops: 4, first: 18)
        let result = Self.run(base: base, enhancement: enh, join: &join)
        #expect(result.discarded == tail.map(\.unit))
        #expect(result.pairs.count == base.count)
        for (b, e) in result.pairs { #expect(e?.dropFirst() == b.dropFirst()) }
        #expect(join.locks == 1)
    }

    @Test("base units before the first shared IRAP are retired too (a seek that landed the base layer early)")
    func baseLeadingUnits() {
        var join = Join()
        let lead = Array(Self.layer("b", gops: 1, first: 12).suffix(2))
        let base = lead + Self.layer("b", gops: 3, first: 18)
        let enh = Self.layer("e", gops: 3, first: 18)
        let result = Self.run(base: base, enhancement: enh, join: &join)
        #expect(result.discarded == lead.map(\.unit))
        #expect(result.pairs.count == base.count - lead.count)
    }

    @Test("a base IRAP the enhancement layer does not share is skipped as an anchor: the layers lock at the next shared one")
    func enhancementOnlyIRAPMismatch() {
        var join = Join()
        let base = Self.layer("b", gops: 6)
        // The enhancement layer has no IRAP at GOPs 0 and 1 (display 0 and 6).
        let enh = Self.layer("e", gops: 6, skipIRAP: [0, 6])
        let result = Self.run(base: base, enhancement: enh, join: &join)
        // The first shared IRAP is display 12; the twelve units before it, in both layers, are retired.
        let firstShared = 12
        #expect(result.pairs.count == base.count - firstShared)
        #expect(result.pairs.first?.0 == "b\(firstShared)")
        #expect(result.pairs.first?.1 == "e\(firstShared)")
        #expect(result.discarded.count == 2 * firstShared)
    }

    @Test("layers that never share an IRAP leave the base layer playing, base-only, and drop the enhancement units")
    func noCommonIRAP() {
        var join = Join()
        let count = Int(Join.searchTimeLimitMicros / Self.frame) + 40
        var base: [Join.Entry] = [], enh: [Join.Entry] = []
        for i in 0..<count {
            base.append(Join.Entry(unit: "b\(i)", pts: Int64(i) * Self.frame, isIRAP: i == 0))
            enh.append(Join.Entry(unit: "e\(i)", pts: Int64(i) * Self.frame, isIRAP: i == 7))
        }
        let result = Self.run(base: base, enhancement: enh, join: &join)
        #expect(result.pairs.count == count)
        #expect(result.pairs.allSatisfy { $0.1 == nil })
        #expect(result.pairs.map(\.0) == base.map(\.unit))
        #expect(join.locks == 0 && join.unpairedBase == count)
    }

    @Test("times from a millisecond container and a 90 kHz one still count as the same time")
    func timeBaseTolerance() {
        var join = Join()
        var base = Self.layer("b", gops: 3)
        var enh = Self.layer("e", gops: 3)
        // Matroska rounds to whole milliseconds; the transport stream keeps 90 kHz ticks.
        for i in base.indices { base[i].pts = (base[i].pts / 1000) * 1000 }
        for i in enh.indices { enh[i].pts = (enh[i].pts * 9 / 100) * 100 / 9 }
        let result = Self.run(base: base, enhancement: enh, join: &join)
        #expect(result.pairs.count == base.count)
        #expect(result.pairs.allSatisfy { $0.1 != nil })
        #expect(join.locks == 1)
    }

    @Test("an unknown time never anchors but does not stop pairing once locked")
    func unknownTimes() {
        var join = Join()
        var base = Self.layer("b", gops: 3)
        var enh = Self.layer("e", gops: 3)
        base[4].pts = Int64.min
        enh[4].pts = Int64.min
        let result = Self.run(base: base, enhancement: enh, join: &join)
        #expect(result.pairs.count == base.count)
        #expect(result.pairs.allSatisfy { $0.1 != nil })
    }

    @Test("the end of the source flushes waiting base units alone and drops stray enhancement units")
    func endOfSource() {
        var join = Join()
        let base = Self.layer("b", gops: 2)
        let enh = Array(Self.layer("e", gops: 2).prefix(base.count - 3))
        let result = Self.run(base: base, enhancement: enh, join: &join)
        #expect(result.pairs.count == base.count)
        #expect(result.pairs.suffix(3).allSatisfy { $0.1 == nil })
        #expect(join.heldBase == 0 && join.heldEnhancement == 0)
    }

    @Test("a base layer that runs ahead is bounded in time: past the queue limit the oldest unit goes out alone")
    func queueIsBounded() {
        var join = Join()
        let base = Self.layer("b", gops: 24)
        let enh = Self.layer("e", gops: 24)
        // Lock on the first pair, then starve the enhancement layer.
        join.addBase(base[0]); join.addEnhancement(enh[0])
        var out: [(String, String?)] = []
        func drain() {
            while let step = join.next() { if case let .pair(b, e) = step { out.append((b, e)) } }
        }
        drain()
        for entry in base.dropFirst() { join.addBase(entry); drain() }
        #expect(out.first?.1 == "e0")
        #expect(join.heldBase <= Join.queueLimit)
        // Two seconds of 23.976 fps units wait, not one more.
        #expect(Int64(join.heldBase - 1) * Self.frame <= Join.queueTimeLimitMicros)
        #expect(join.heldBase > 40)
        #expect(out.dropFirst().allSatisfy { $0.1 == nil })
    }

    /// Feeds the layers the way an MP4 with one-second chunks per track is read: a chunk of one layer, then a chunk
    /// of the other, `lead` says which comes first.
    private static func runChunked(base: [Join.Entry], enhancement: [Join.Entry], chunk: Int, enhancementFirst: Bool,
                                   join: inout Join) -> (pairs: [(String, String?)], discarded: [String]) {
        var pairs: [(String, String?)] = []
        var discarded: [String] = []
        func drain(atEnd: Bool) {
            while let step = join.next(atEnd: atEnd) {
                switch step {
                case let .pair(b, e): pairs.append((b, e))
                case .discard(let u): discarded.append(u)
                }
            }
            discarded += join.takeRetired()
        }
        var bi = 0, ei = 0
        var turnIsEnhancement = enhancementFirst
        while bi < base.count || ei < enhancement.count {
            if turnIsEnhancement {
                for _ in 0..<chunk where ei < enhancement.count { join.addEnhancement(enhancement[ei]); ei += 1; drain(atEnd: false) }
            } else {
                for _ in 0..<chunk where bi < base.count { join.addBase(base[bi]); bi += 1; drain(atEnd: false) }
            }
            turnIsEnhancement.toggle()
        }
        drain(atEnd: true)
        return (pairs, discarded)
    }

    @Test("tracks interleaved in chunks of a second or more join without a lost pairing, whichever layer leads",
          arguments: [24, 36, 44], [false, true])
    func chunkedInterleave(chunk: Int, enhancementFirst: Bool) {
        var join = Join()
        let base = Self.layer("b", gops: 40), enh = Self.layer("e", gops: 40)
        let result = Self.runChunked(base: base, enhancement: enh, chunk: chunk, enhancementFirst: enhancementFirst, join: &join)
        #expect(result.pairs.count == base.count)
        #expect(result.pairs.allSatisfy { $0.1 != nil })
        for (b, e) in result.pairs { #expect(e?.dropFirst() == b.dropFirst(), "\(b) paired with \(e ?? "none")") }
        #expect(join.unpairedBase == 0 && join.droppedEnhancement == 0 && join.locks == 1)
    }

    @Test("a chunk longer than the time bound sends the oldest base units out alone, never a wrong pair")
    func chunkBeyondTheBound() {
        var join = Join()
        let base = Self.layer("b", gops: 40), enh = Self.layer("e", gops: 40)
        // Three seconds per chunk (72 units): past the two-second bound.
        let result = Self.runChunked(base: base, enhancement: enh, chunk: 72, enhancementFirst: false, join: &join)
        #expect(result.pairs.count == base.count)
        #expect(join.unpairedBase > 0)
        for (b, e) in result.pairs { if let e { #expect(e.dropFirst() == b.dropFirst(), "\(b) paired with \(e)") } }
    }

    @Test("a unit whose partner is nowhere in sight goes out alone once the layers had agreed, not paired by order")
    func noPartnerInSightSendsBaseAlone() {
        var join = Join()
        let base = Self.layer("b", gops: 12)
        let enh = Self.layer("e", gops: 12)
        // Sixteen agreeing pairs build the trust.
        var out: [(String, String?)] = []
        func drain() {
            while let step = join.next() { if case let .pair(b, e) = step { out.append((b, e)) } }
        }
        for i in 0..<20 { join.addBase(base[i]); join.addEnhancement(enh[i]); drain() }
        #expect(out.count == 20 && out.allSatisfy { $0.1 != nil } && join.locks == 1)
        // Then a stretch where the enhancement layer is far ahead in time of anything the base layer holds (a burst of
        // lost units, here more than the lookahead can see): base units 20 to 27, enhancement units 60 to 67.
        for i in 20..<28 { join.addBase(base[i]) }
        for i in 60..<68 { join.addEnhancement(enh[i]) }
        let before = out.count
        drain()
        let pairedWrongly = out.dropFirst(before).filter { $0.1 != nil }
        #expect(pairedWrongly.isEmpty, "paired \(pairedWrongly.map { "\($0.0)+\($0.1 ?? "")" })")
        #expect(out.count > before && out.dropFirst(before).allSatisfy { $0.0.hasPrefix("b") })
        #expect(join.unpairedBase >= 1)
    }

    @Test("before the layers have agreed for a stretch, the same disagreement still pairs by order")
    func earlyDisagreementPairsByOrder() {
        var join = Join()
        let base = Self.layer("b", gops: 12), enh = Self.layer("e", gops: 12)
        var out: [(String, String?)] = []
        func drain() {
            while let step = join.next() { if case let .pair(b, e) = step { out.append((b, e)) } }
        }
        for i in 0..<4 { join.addBase(base[i]); join.addEnhancement(enh[i]); drain() }
        for i in 4..<12 { join.addBase(base[i]) }
        for i in 40..<48 { join.addEnhancement(enh[i]) }
        drain()
        // Not enough evidence of shared times yet: the repair stays off, as documented.
        #expect(out.dropFirst(4).first?.1 != nil)
    }

    // MARK: - A single unit lost soon after a lock

    /// Feeds one unit per layer per step in transport-stream order (base then enhancement, or the other way round)
    /// and drains after every unit, the way the demuxer does.
    private static func runInterleaved(base: [Join.Entry], enhancement: [Join.Entry], enhancementFirst: Bool)
        -> [(base: String, enhancement: String?)] {
        var join = Join()
        var pairs: [(base: String, enhancement: String?)] = []
        func drain(atEnd: Bool) {
            while let step = join.next(atEnd: atEnd) { if case let .pair(b, e) = step { pairs.append((b, e)) } }
            _ = join.takeRetired()
        }
        for i in 0..<max(base.count, enhancement.count) {
            if enhancementFirst {
                if i < enhancement.count { join.addEnhancement(enhancement[i]); drain(atEnd: false) }
                if i < base.count { join.addBase(base[i]); drain(atEnd: false) }
            } else {
                if i < base.count { join.addBase(base[i]); drain(atEnd: false) }
                if i < enhancement.count { join.addEnhancement(enhancement[i]); drain(atEnd: false) }
            }
        }
        drain(atEnd: true)
        return pairs
    }

    /// Indices of the pairs whose enhancement unit is another picture's.
    private static func wrongPairs(_ pairs: [(base: String, enhancement: String?)]) -> [Int] {
        pairs.enumerated().compactMap { i, p in
            guard let e = p.enhancement else { return nil }
            return e.dropFirst() == p.base.dropFirst() ? nil : i
        }
    }

    private static let gopUnits = 24

    @Test("a unit lost in the first sixteen after a lock leaves at most one GOP of wrong pairs, none after the next IRAP",
          arguments: [(true, false), (false, false), (true, true), (false, true)])
    func lostEarlyIsBoundedByOneGOP(loseEnhancement: Bool, enhancementFirst: Bool) {
        for index in [1, 5, 11, 15] {
            var base = Self.layer("b", gops: 6, gop: Self.gopUnits), enh = Self.layer("e", gops: 6, gop: Self.gopUnits)
            if loseEnhancement { enh.remove(at: index) } else { base.remove(at: index) }
            let pairs = Self.runInterleaved(base: base, enhancement: enh, enhancementFirst: enhancementFirst)
            let wrong = Self.wrongPairs(pairs)
            #expect(wrong.count <= Self.gopUnits, "lost \(loseEnhancement ? "enhancement" : "base") unit \(index): \(wrong.count) wrong")
            // Nothing is wrong once the next base IRAP (pair index 24 or so) is past: the layers are realigned.
            #expect((wrong.last ?? 0) <= Self.gopUnits + 4, "still wrong at \(wrong.last ?? -1)")
            // The loss costs one base-only unit at most per layer, nothing else is thrown away.
            #expect(pairs.filter { $0.enhancement == nil }.count <= 3)
        }
    }

    @Test("a unit lost after the layers had agreed for a stretch is repaired by time with no wrong pair",
          arguments: [(true, false), (false, false), (true, true), (false, true)])
    func lostLateIsRepairedAtOnce(loseEnhancement: Bool, enhancementFirst: Bool) {
        var base = Self.layer("b", gops: 6, gop: Self.gopUnits), enh = Self.layer("e", gops: 6, gop: Self.gopUnits)
        if loseEnhancement { enh.remove(at: 40) } else { base.remove(at: 40) }
        let pairs = Self.runInterleaved(base: base, enhancement: enh, enhancementFirst: enhancementFirst)
        #expect(Self.wrongPairs(pairs).isEmpty)
    }

    @Test("wherever a single unit is lost, whichever layer and interleave, the wrong pairs stay within one GOP and end",
          arguments: [(true, false), (false, false), (true, true), (false, true)])
    func lostAnywhereIsBoundedByOneGOP(loseEnhancement: Bool, enhancementFirst: Bool) {
        let total = 6 * Self.gopUnits
        for index in 1..<(total - 1) {
            var base = Self.layer("b", gops: 6, gop: Self.gopUnits), enh = Self.layer("e", gops: 6, gop: Self.gopUnits)
            if loseEnhancement { enh.remove(at: index) } else { base.remove(at: index) }
            let wrong = Self.wrongPairs(Self.runInterleaved(base: base, enhancement: enh, enhancementFirst: enhancementFirst))
            #expect(wrong.count <= Self.gopUnits,
                    "lost \(loseEnhancement ? "enhancement" : "base") unit \(index): \(wrong.count) wrong")
            // The pairs after the loss's own GOP and the following one are right again.
            #expect((wrong.last ?? 0) < index + 2 * Self.gopUnits, "lost \(index): still wrong at \(wrong.last ?? -1)")
        }
    }

    // MARK: - A unit lost while the enhancement layer is read well ahead of the base layer

    /// Which layer the next unit comes from: `true` base, `false` enhancement.
    private typealias Schedule = [Bool]

    /// One unit per layer per step, the enhancement layer `lag` steps behind (negative: ahead).
    private static func lagSchedule(units: Int, lag: Int) -> Schedule {
        var s: Schedule = []
        for i in 0..<(units + abs(lag) + 2) {
            let b = lag >= 0 ? i : i + lag
            let e = lag >= 0 ? i - lag : i
            if b >= 0 { s.append(true) }
            if e >= 0 { s.append(false) }
        }
        return s
    }

    /// Chunks of `chunk` units of one layer, then of the other, the enhancement layer first.
    private static func enhancementFirstChunks(units: Int, chunk: Int) -> Schedule {
        var s: Schedule = []
        var turnIsEnhancement = true
        var b = 0, e = 0
        while b < units + 2 || e < units + 2 {
            for _ in 0..<chunk { s.append(!turnIsEnhancement); if turnIsEnhancement { e += 1 } else { b += 1 } }
            turnIsEnhancement.toggle()
        }
        return s
    }

    private static func runScheduled(base: [Join.Entry], enhancement: [Join.Entry], schedule: Schedule)
        -> (pairs: [(base: String, enhancement: String?)], heldAtEnd: Int) {
        var join = Join()
        var pairs: [(base: String, enhancement: String?)] = []
        func drain(atEnd: Bool) {
            while let step = join.next(atEnd: atEnd) { if case let .pair(b, e) = step { pairs.append((b, e)) } }
            _ = join.takeRetired()
        }
        var bi = 0, ei = 0
        for isBase in schedule {
            if isBase, bi < base.count { join.addBase(base[bi]); bi += 1; drain(atEnd: false) }
            if !isBase, ei < enhancement.count { join.addEnhancement(enhancement[ei]); ei += 1; drain(atEnd: false) }
        }
        while bi < base.count { join.addBase(base[bi]); bi += 1; drain(atEnd: false) }
        while ei < enhancement.count { join.addEnhancement(enhancement[ei]); ei += 1; drain(atEnd: false) }
        drain(atEnd: true)
        return (pairs, join.heldBase + join.heldEnhancement)
    }

    private static let gopsForAhead = 12

    private static let aheadSchedules: [(String, Schedule)] = {
        let units = gopsForAhead * gopUnits
        return [("EL chunks first", enhancementFirstChunks(units: units, chunk: gopUnits)),
                ("EL ten units ahead", lagSchedule(units: units, lag: -10))]
    }()

    @Test("an enhancement layer read more than six units ahead, a unit lost early: wrong pairs within one GOP, the layer is not given up")
    func lostEarlyWhileEnhancementIsAhead() {
        for (name, schedule) in Self.aheadSchedules {
            for loseEnhancement in [true, false] {
                for index in [1, 10] {
                    var base = Self.layer("b", gops: Self.gopsForAhead, gop: Self.gopUnits)
                    var enh = Self.layer("e", gops: Self.gopsForAhead, gop: Self.gopUnits)
                    if loseEnhancement { enh.remove(at: index) } else { base.remove(at: index) }
                    let r = Self.runScheduled(base: base, enhancement: enh, schedule: schedule)
                    let label = "\(name), lost \(loseEnhancement ? "enhancement" : "base") unit \(index)"
                    let wrong = Self.wrongPairs(r.pairs)
                    #expect(wrong.count <= Self.gopUnits, "\(label): \(wrong.count) wrong pairs")
                    #expect((wrong.last ?? 0) <= Self.gopUnits + 4, "\(label): still wrong at \(wrong.last ?? -1)")
                    #expect(r.pairs.filter { $0.enhancement == nil }.count <= 3,
                            "\(label): \(r.pairs.filter { $0.enhancement == nil }.count) base-only")
                    #expect(r.heldAtEnd == 0, "\(label): \(r.heldAtEnd) units held at the end")
                }
            }
        }
    }

    @Test("an enhancement IRAP lost after a mature run, the enhancement layer read well ahead: one base-only unit, no wrong pair")
    func lostEnhancementIRAPWhileEnhancementIsAhead() {
        for (name, schedule) in Self.aheadSchedules {
            var enh = Self.layer("e", gops: Self.gopsForAhead, gop: Self.gopUnits)
            enh.remove(at: Self.gopUnits)   // the IRAP of the second GOP
            let r = Self.runScheduled(base: Self.layer("b", gops: Self.gopsForAhead, gop: Self.gopUnits),
                                      enhancement: enh, schedule: schedule)
            #expect(Self.wrongPairs(r.pairs).isEmpty, "\(name)")
            #expect(r.pairs.filter { $0.enhancement == nil }.count == 1,
                    "\(name): \(r.pairs.filter { $0.enhancement == nil }.count) base-only")
            #expect(r.heldAtEnd == 0, "\(name): \(r.heldAtEnd) units held at the end")
        }
    }

    @Test("reset hands back everything held and the join starts over")
    func resetStartsOver() {
        var join = Join()
        let base = Self.layer("b", gops: 2)
        let enh = Self.layer("e", gops: 2)
        join.addBase(base[0]); join.addBase(base[1]); join.addEnhancement(enh[1])
        let held = join.reset()
        #expect(Set(held) == Set([base[0].unit, base[1].unit, enh[1].unit]))
        #expect(join.heldBase == 0 && join.heldEnhancement == 0 && !join.isLocked)
        let result = Self.run(base: base, enhancement: enh, join: &join)
        #expect(result.pairs.count == base.count)
    }
}
