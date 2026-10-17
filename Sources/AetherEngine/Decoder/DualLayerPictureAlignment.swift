// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation

/// Gives each enhancement-layer packet the presentation time of the base-layer picture it belongs to.
///
/// A profile 7 access unit carries one picture of each layer, and the container stamps the unit with
/// the base layer's presentation time. The two pictures of one unit need not be the same frame: the
/// enhancement layer may have its own GOP (B-frames where the base layer has none, IDRs at other cuts),
/// so its picture in a given unit can be a frame or two earlier or later. A spec decoder composes each
/// layer's pictures in that layer's display order; pairing by access unit instead puts a neighbouring
/// frame's residual onto moving detail.
///
/// Each layer's display order is followed causally as a display slot counted in access units from the
/// start (or the last seek): a picture that opens a sequence (IDR, BLA, a CRA after a seek) is shown
/// after every picture decoded before it, so its slot is the number of units before it; later pictures
/// of that sequence sit at slot + (POC - its POC). Streams whose layers share a GOP (every UHD Blu-ray
/// title seen so far) get identical slots in both layers, and their packets keep their unit's time.
///
/// Two limits, both of which end in the access-unit pairing a stream without this type would get:
/// - A sequence opener takes the slot "units before it", which assumes the previous sequence's slots
///   all lie below that count. If the previous sequence's POC numbering ran ahead of its unit count
///   (gaps in its POCs), the opener and its first followers share slots with its last pictures, and
///   the time kept for a slot is the newer one, so a restamp into that range can land on the wrong
///   picture. It needs a mid-stream sequence change with such gaps; a seek resets all slots.
/// - A layer whose slots drift further than `maxSlotDistance` from the unit position stops being
///   placed until its next IDR or BLA (the only mid-stream pictures that open a sequence; a CRA
///   opens one only at the start or after a seek). A stream that cuts GOPs with CRAs (open GOP)
///   therefore stays on access-unit pairing from that point until the next seek.
struct DualLayerPictureAlignment {

    /// A slot further than this from the unit's own position is further than any DPB allows, so the
    /// layer's sequence is not trusted (dolby-vision-fel.md §5.3).
    static let maxSlotDistance = 16

    /// How many slots earlier than its own unit an enhancement picture may be restamped. A base-layer
    /// frame waits for its partner only until K newer base frames have arrived (`DualLayerVideoDecoder.
    /// maxLayerSkewFrames`), so an enhancement picture restamped to a frame further back than that
    /// finds its partner already bypassed and is dropped: the pair is lost without anyone noticing.
    /// Beyond this distance the unit is treated like one whose slot is unknown (access-unit pairing,
    /// counted in `unabsorbableRestamps`). The owner sets it from its own skew bound; the default is
    /// the DPB bound, which absorbs anything the slots can say.
    var maxBackwardRestamp = DualLayerPictureAlignment.maxSlotDistance
    /// Units whose enhancement picture sat further back than `maxBackwardRestamp`.
    private(set) var unabsorbableRestamps = 0

    /// One layer's display slots.
    private struct Layer {
        var counter = HEVCPictureOrderCount()
        /// slot = POC + offset in the current sequence; nil until a sequence opens, and for the rest of
        /// a sequence whose slots cannot be trusted.
        var offset: Int?

        mutating func slot(_ p: HEVCPictureOrderCount.Picture, unit: Int) -> Int? {
            if p.startsSequence {
                offset = unit - p.poc
                return unit
            }
            guard let offset else { return nil }
            // A leading picture of the opener (RADL, POC below the IRAP's) is shown before the IRAP
            // but decoded after it. That does not break the numbering: POC still steps one per
            // picture, so it keeps the sequence's offset and lands before the opener's slot.
            // (RASL pictures of a sequence-opening CRA never get here: `HEVCPictureOrderCount` does
            // not report them, since a decoder starting at the CRA does not output them.)
            let s = p.poc + offset
            // Further from decode order than any DPB allows: POC is not stepping one per frame.
            if abs(s - unit) > DualLayerPictureAlignment.maxSlotDistance { self.offset = nil; return nil }
            return s
        }
    }

    private var base = Layer()
    private var enhancement = Layer()
    /// Access units since the start or the last seek.
    private var units = 0
    /// Presentation time of recent base-layer pictures, by slot.
    private var baseTime: [Int: Int64] = [:]
    /// First base-layer slot seen since the reset: with the latest it gives the time per slot.
    private var origin: (slot: Int, pts: Int64)?
    private var latest: (slot: Int, pts: Int64)?

    /// Units whose enhancement-layer picture was moved to another frame's time.
    private(set) var reorderedUnits = 0
    /// Whether the last unit's enhancement-layer picture was placed by its display slot (as opposed
    /// to keeping its unit's time for want of one).
    private(set) var lastEnhancementPlaced = false

    mutating func seedBaseParameterSets(_ nals: [[UInt8]]) {
        base.counter.feedParameterSets(nals)
    }

    /// After a seek both layers restart at their next IRAP.
    mutating func reset() {
        base.counter.reset(); base.offset = nil
        enhancement.counter.reset(); enhancement.offset = nil
        units = 0
        baseTime.removeAll()
        origin = nil
        latest = nil
    }

    /// Reads both layers' pictures from one access unit (base-layer NALs, and enhancement-layer NALs
    /// wrapped in unspec63) and returns the time to stamp on its enhancement-layer packet. `pts` is the
    /// unit's presentation time, in the stream's time base. It comes back unchanged when both pictures
    /// are the same frame, and whenever the enhancement picture's slot is not known.
    mutating func enhancementPTS(_ data: UnsafePointer<UInt8>, _ size: Int, framing: VideoNALFraming, pts: Int64) -> Int64 {
        var bl: HEVCPictureOrderCount.Picture?
        var el: HEVCPictureOrderCount.Picture?
        A53SEIParser.forEachNAL(data, size, framing) { nal, len in
            let type = (nal[0] >> 1) & 0x3F
            if type == 63 {
                if len > 4, let p = enhancement.counter.feed(nal + 2, len - 2), el == nil { el = p }
            } else if type < 48 {
                if let p = base.counter.feed(nal, len), bl == nil { bl = p }
            }
        }
        let unit = units
        units += 1
        lastEnhancementPlaced = false

        let blSlot = bl.flatMap { base.slot($0, unit: unit) }
        var elSlot = el.flatMap { enhancement.slot($0, unit: unit) }
        if let slot = elSlot, (blSlot ?? unit) - slot > maxBackwardRestamp {
            unabsorbableRestamps += 1
            elSlot = nil
        }
        guard pts != Int64.min else { return pts }
        if let blSlot {
            baseTime[blSlot] = pts
            if baseTime.count > 64 {
                for s in baseTime.keys where s < unit - 32 { baseTime.removeValue(forKey: s) }
            }
            if origin == nil { origin = (blSlot, pts) }
            latest = (blSlot, pts)
        }

        guard let elSlot else { return pts }
        lastEnhancementPlaced = true
        if elSlot == blSlot { return pts }
        if let known = baseTime[elSlot] {
            reorderedUnits += 1
            return known
        }
        // That base-layer picture is still to come: extrapolate from the time per slot.
        guard let origin, let latest, latest.slot != origin.slot,
              let result = Self.extrapolate(origin: origin, latest: latest, slot: elSlot) else {
            lastEnhancementPlaced = false; return pts
        }
        reorderedUnits += 1
        return result
    }

    /// Time of a slot beyond the latest one, from the time per slot between two known ones. Timestamps
    /// come from the stream, so every step is overflow-checked: a crafted value makes this decline
    /// (nil), never trap.
    static func extrapolate(origin: (slot: Int, pts: Int64), latest: (slot: Int, pts: Int64), slot: Int) -> Int64? {
        guard let span = checkedSub(latest.pts, origin.pts),
              let slotSpan = checkedSub(latest.slot, origin.slot), slotSpan != 0,
              let ahead = checkedSub(slot, latest.slot) else { return nil }
        let perSlot = Double(span) / Double(slotSpan)
        guard perSlot > 0, perSlot.isFinite else { return nil }
        let offset = (Double(ahead) * perSlot).rounded()
        // 2^63 is exactly representable; anything at or beyond it, or NaN, cannot convert.
        guard offset.isFinite, offset > -9.223372036854775807e18, offset < 9.223372036854775807e18 else { return nil }
        return checkedAdd(latest.pts, Int64(offset))
    }

    private static func checkedSub<T: FixedWidthInteger>(_ a: T, _ b: T) -> T? {
        let (v, o) = a.subtractingReportingOverflow(b); return o ? nil : v
    }

    private static func checkedAdd<T: FixedWidthInteger>(_ a: T, _ b: T) -> T? {
        let (v, o) = a.addingReportingOverflow(b); return o ? nil : v
    }
}
#endif
