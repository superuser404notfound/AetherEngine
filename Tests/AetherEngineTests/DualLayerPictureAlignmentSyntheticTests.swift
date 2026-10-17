// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
@testable import AetherEngine

/// `DualLayerPictureAlignment` on hand-built access units, so the leading-picture rules run without
/// the real clips `DualLayerPictureAlignmentTests` needs. Each access unit holds one base-layer
/// slice and one enhancement-layer slice (wrapped in NAL type 63, as in a profile 7 packet); the
/// enhancement layer's picture order is chosen to differ from the base layer's, so a restamp shows
/// as a changed time.
struct DualLayerPictureAlignmentSyntheticTests {

    typealias B = HEVCSyntheticBitstream
    typealias T = HEVCSyntheticBitstream.T

    /// One access unit: base slice, then the enhancement layer's slice (and, when `parameterSets`,
    /// its SPS/PPS, which have no other way in).
    private static func unit(bl: [UInt8], el: [UInt8], parameterSets: Bool = false) -> [UInt8] {
        var nals = [bl]
        if parameterSets {
            nals.append(B.wrappedEL(B.sps(pocLsbBits: 8)))
            nals.append(B.wrappedEL(B.pps()))
        }
        nals.append(B.wrappedEL(el))
        return B.accessUnit(nals)
    }

    private static func slice(_ type: Int, poc: Int) -> [UInt8] {
        B.slice(type: type, pocLsb: poc & 0xFF, pocLsbBits: 8)
    }

    private struct Result: Equatable { let pts: Int64; let placed: Bool }

    private static func run(_ a: inout DualLayerPictureAlignment, _ data: [UInt8], pts: Int64) -> Result {
        let out = data.withUnsafeBufferPointer {
            a.enhancementPTS($0.baseAddress!, $0.count, framing: .lengthPrefixed(size: 4), pts: pts)
        }
        return Result(pts: out, placed: a.lastEnhancementPlaced)
    }

    private static func seeded() -> DualLayerPictureAlignment {
        var a = DualLayerPictureAlignment()
        a.seedBaseParameterSets([B.sps(pocLsbBits: 8), B.pps()])
        return a
    }

    // MARK: - After a seek onto a CRA

    /// x265's default open GOP: a seek lands on a CRA followed by RASL pictures that reference what
    /// came before it. A decoder starting there does not output them. They used to knock the layer's
    /// offset out ("a picture below the opener's POC"), and with it the alignment, for the rest of the
    /// session.
    @Test("a seek onto a CRA with RASL pictures keeps the alignment: the RASL pictures are skipped, the rest still restamp")
    func craWithRaslAfterSeek() {
        var a = Self.seeded()
        a.reset()
        // Display order: RASL 6, RASL 7, CRA 8, 9, 10. PTS follows display order, one frame = 1000.
        let u0 = Self.run(&a, Self.unit(bl: Self.slice(T.cra, poc: 8), el: Self.slice(T.cra, poc: 8), parameterSets: true), pts: 2000)
        #expect(u0 == Result(pts: 2000, placed: true))

        // The RASL pictures are not output: no slot for either layer, and the unit keeps its own time
        let u1 = Self.run(&a, Self.unit(bl: Self.slice(T.raslN, poc: 6), el: Self.slice(T.raslN, poc: 6)), pts: 0)
        let u2 = Self.run(&a, Self.unit(bl: Self.slice(T.raslR, poc: 7), el: Self.slice(T.raslR, poc: 7)), pts: 1000)
        #expect(u1 == Result(pts: 0, placed: false))
        #expect(u2 == Result(pts: 1000, placed: false))

        // The enhancement layer codes picture 10 before 9 (B-frames); the base layer does not.
        // Slot of POC p is p - 8 for both layers. EL picture 10 pairs with the base picture of POC 10,
        // which has not arrived yet: its time is extrapolated from the time per slot (1000).
        let u3 = Self.run(&a, Self.unit(bl: Self.slice(T.trailR, poc: 9), el: Self.slice(T.trailR, poc: 10)), pts: 3000)
        #expect(u3 == Result(pts: 4000, placed: true), "alignment must survive the RASL pictures")
        // EL picture 9 pairs with the base picture of POC 9, which came out one unit earlier
        let u4 = Self.run(&a, Self.unit(bl: Self.slice(T.trailR, poc: 10), el: Self.slice(T.trailR, poc: 9)), pts: 4000)
        #expect(u4 == Result(pts: 3000, placed: true))
        #expect(a.reorderedUnits == 2)
    }

    @Test("a CRA in the middle of a stream keeps its RASL pictures in the numbering")
    func craWithRaslMidStream() {
        var a = Self.seeded()
        _ = Self.run(&a, Self.unit(bl: Self.slice(T.idrNLP, poc: 0), el: Self.slice(T.idrNLP, poc: 0), parameterSets: true), pts: 0)
        for i in 1...4 {
            _ = Self.run(&a, Self.unit(bl: Self.slice(T.trailR, poc: i), el: Self.slice(T.trailR, poc: i)), pts: Int64(i) * 1000)
        }
        // CRA at POC 7 with RASL 5 and 6 (decoded after it, shown before it): all output pictures.
        // Slots are POC (offset 0). The EL shows 6 where the BL has 5 and vice versa.
        _ = Self.run(&a, Self.unit(bl: Self.slice(T.cra, poc: 7), el: Self.slice(T.cra, poc: 7)), pts: 7000)
        let r5 = Self.run(&a, Self.unit(bl: Self.slice(T.raslR, poc: 5), el: Self.slice(T.raslR, poc: 6)), pts: 5000)
        #expect(r5.placed)
        // slot 6 is on the unit's own display side of the CRA: the base layer's POC 6 comes next
        let r6 = Self.run(&a, Self.unit(bl: Self.slice(T.raslR, poc: 6), el: Self.slice(T.raslR, poc: 5)), pts: 6000)
        #expect(r6 == Result(pts: 5000, placed: true))
    }

    // MARK: - IDR with RADL

    @Test("RADL pictures, whose POC is below their IDR's, keep the layer's offset instead of discarding it")
    func idrWithRadl() {
        var a = Self.seeded()
        a.reset()
        // Display order: RADL -2, RADL -1, IDR 0, 1, 2. PTS follows display order.
        let u0 = Self.run(&a, Self.unit(bl: Self.slice(T.idrWRADL, poc: 0), el: Self.slice(T.idrWRADL, poc: 0), parameterSets: true), pts: 2000)
        #expect(u0 == Result(pts: 2000, placed: true))
        let u1 = Self.run(&a, Self.unit(bl: Self.slice(T.radlR, poc: -2), el: Self.slice(T.radlR, poc: -2)), pts: 0)
        let u2 = Self.run(&a, Self.unit(bl: Self.slice(T.radlR, poc: -1), el: Self.slice(T.radlR, poc: -1)), pts: 1000)
        #expect(u1 == Result(pts: 0, placed: true), "same frame in both layers: unchanged, but placed by its slot")
        #expect(u2 == Result(pts: 1000, placed: true))

        let u3 = Self.run(&a, Self.unit(bl: Self.slice(T.trailR, poc: 1), el: Self.slice(T.trailR, poc: 2)), pts: 3000)
        #expect(u3 == Result(pts: 4000, placed: true), "alignment must survive the RADL pictures")
        let u4 = Self.run(&a, Self.unit(bl: Self.slice(T.trailR, poc: 2), el: Self.slice(T.trailR, poc: 1)), pts: 4000)
        #expect(u4 == Result(pts: 3000, placed: true))
    }

    // MARK: - Baselines the fix must not change

    @Test("layers with the same GOP keep every unit's own time")
    func sameGopUnchanged() {
        var a = Self.seeded()
        a.reset()
        _ = Self.run(&a, Self.unit(bl: Self.slice(T.idrNLP, poc: 0), el: Self.slice(T.idrNLP, poc: 0), parameterSets: true), pts: 0)
        for i in 1...20 {
            let r = Self.run(&a, Self.unit(bl: Self.slice(T.trailR, poc: i), el: Self.slice(T.trailR, poc: i)), pts: Int64(i) * 1000)
            #expect(r == Result(pts: Int64(i) * 1000, placed: true))
        }
        #expect(a.reorderedUnits == 0)
    }

    @Test("POC that does not step one per frame is not trusted: the layer falls back to access-unit pairing")
    func slotFurtherThanDpbIsNotTrusted() {
        var a = Self.seeded()
        a.reset()
        _ = Self.run(&a, Self.unit(bl: Self.slice(T.idrNLP, poc: 0), el: Self.slice(T.idrNLP, poc: 0), parameterSets: true), pts: 0)
        // The EL jumps 40 pictures ahead in one unit: further than any DPB
        let r = Self.run(&a, Self.unit(bl: Self.slice(T.trailR, poc: 1), el: Self.slice(T.trailR, poc: 41)), pts: 1000)
        #expect(r == Result(pts: 1000, placed: false))
    }

    // MARK: - Restamp distance the pairing can absorb

    @Test("an enhancement picture restamped further back than the owner's skew bound is not placed; one within it is")
    func restampBeyondSkewBoundIsNotPlaced() {
        var a = Self.seeded()
        a.maxBackwardRestamp = 2   // DualLayerVideoDecoder.maxLayerSkewFrames (3) - 1
        a.reset()
        _ = Self.run(&a, Self.unit(bl: Self.slice(T.idrNLP, poc: 0), el: Self.slice(T.idrNLP, poc: 0), parameterSets: true), pts: 0)
        for i in 1...4 {
            _ = Self.run(&a, Self.unit(bl: Self.slice(T.trailR, poc: i), el: Self.slice(T.trailR, poc: i)), pts: Int64(i) * 1000)
        }
        // Unit 5, EL shows picture 3: two back, the partner (base picture 3) is still waiting
        let within = Self.run(&a, Self.unit(bl: Self.slice(T.trailR, poc: 5), el: Self.slice(T.trailR, poc: 3)), pts: 5000)
        #expect(within == Result(pts: 3000, placed: true))
        #expect(a.unabsorbableRestamps == 0)
        // Unit 6, EL shows picture 3 again: three back, its partner has been bypassed by then
        let beyond = Self.run(&a, Self.unit(bl: Self.slice(T.trailR, poc: 6), el: Self.slice(T.trailR, poc: 3)), pts: 6000)
        #expect(beyond == Result(pts: 6000, placed: false))
        #expect(a.unabsorbableRestamps == 1)
    }

    @Test("the default bound is the DPB bound: restamps up to 16 back are placed")
    func defaultBoundAbsorbsDpbDepth() {
        var a = Self.seeded()
        a.reset()
        _ = Self.run(&a, Self.unit(bl: Self.slice(T.idrNLP, poc: 0), el: Self.slice(T.idrNLP, poc: 0), parameterSets: true), pts: 0)
        for i in 1...20 {
            _ = Self.run(&a, Self.unit(bl: Self.slice(T.trailR, poc: i), el: Self.slice(T.trailR, poc: i)), pts: Int64(i) * 1000)
        }
        let r = Self.run(&a, Self.unit(bl: Self.slice(T.trailR, poc: 21), el: Self.slice(T.trailR, poc: 6)), pts: 21000)
        #expect(r == Result(pts: 6000, placed: true))
    }
}
#endif
