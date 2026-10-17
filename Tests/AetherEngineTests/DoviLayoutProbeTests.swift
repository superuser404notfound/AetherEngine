// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import Metal
@testable import AetherEngine

/// Checks the parameter ABI on the GPU rather than by hand.
///
/// Metal has no `static_assert`, and `xcrun metal` is not installed on every
/// machine that runs this suite, so the shader's view of `DoviMetalParams` cannot
/// be asserted at compile time. Instead `dovi_layout_probe` reads the last field
/// of each sub-block back out of the buffer the host actually uploaded: any offset
/// drift between ``DoviMetalParams/serialize()`` and the shader's struct
/// definitions moves a sentinel and fails a comparison below.
@Suite(.offCooperativePoolOneLane)
struct DoviLayoutProbeTests {

    /// Distinct value per probed field, so a shifted read lands on a value that
    /// belongs to a different field rather than on a plausible one.
    static func sentinelParams() -> DoviMetalParams {
        var p = DoviMetalParams()

        p.blWidth = 101
        p.blHeight = 102
        p.elWidth = 103
        p.elHeight = 104
        p.targetMode = 105
        p.ditherMode = .bayer8x8
        p.frameIndex = 107
        p.flags = [.disableResidual, .lumaMmr]

        p.polyY.numPivots = 9
        p.polyY.pivots[8] = 1023
        p.polyY.method[7] = DoviMapping.mmr.rawValue
        p.polyY.order[7] = 2
        p.polyY.coef[7][2] = -12345        // negative, to prove the sign survives
        p.polyY.coefShift[7] = 23
        p.mmrY.constant[7] = 777
        p.mmrY.coef[7][20] = 888
        p.mmrY.coefShift = 23

        p.polyCb.numPivots = 5
        p.polyCb.coefShift[7] = 17
        p.mmrCb.coef[7][20] = 1234
        p.mmrCb.coefShift = 19

        p.polyCr.numPivots = 3
        p.polyCr.coefShift[7] = 13
        p.mmrCr.coef[7][20] = -4321
        p.mmrCr.coefShift = 11

        Self.applyComponentSentinels(&p)

        p.minPq = 1
        p.maxPq = 2
        p.avgPq = 3
        p.blMax = 1023
        p.vdrMax = 4095
        p.vdrScale = 4

        return p
    }


    // MARK: - Per-component sentinels

    /// Fields probed per component, in slot order from `firstComponentSlot`; mirrors the shader's probe kernel.
    static let componentFieldNames = [
        "poly.pivots[0]", "poly.pivots[1]", "poly.method[0]", "poly.order[0]",
        "poly.coef[0][0]", "poly.coef[0][1]", "poly.coef[1][0]", "poly.coef_shift[0]",
        "mmr.constant[0]", "mmr.coef[0][0]", "mmr.coef[0][1]", "mmr.coef[1][0]",
        "nlq.method", "nlq.offset", "nlq.scale", "nlq.threshold", "nlq.shift", "nlq.vdr_in_max",
        "nlq.pivots[0]", "nlq.pivots[1]",
    ]
    static let firstComponentSlot = 36

    /// Distinct non-zero sentinel for component `c`, field `k`; fields that are signed alternate sign so a
    /// sign-lost read is caught too. `nlq.method` is an enum with two legal values, so it uses those.
    static func sentinel(_ c: Int, _ k: Int) -> UInt32 {
        let magnitude = UInt32(1000 * (c + 1) + 10 * k + 1)
        let signed = [4, 5, 8, 10, 15]   // coef[0][0], coef[0][1], mmr.constant[0], mmr.coef[0][1], nlq.threshold
        if signed.contains(k) { return UInt32(bitPattern: -Int32(magnitude)) }
        if k == 12 { return [DoviNlqMethod.none, .linear, .none][c].rawValue }
        return magnitude
    }

    static func slot(_ c: Int, _ k: Int) -> Int { firstComponentSlot + c * componentFieldNames.count + k }

    /// Writes the per-component sentinels over `p`.
    static func applyComponentSentinels(_ p: inout DoviMetalParams) {
        let polys: [WritableKeyPath<DoviMetalParams, DoviPolynomialParams>] = [\.polyY, \.polyCb, \.polyCr]
        let mmrs: [WritableKeyPath<DoviMetalParams, DoviMmrParams>] = [\.mmrY, \.mmrCb, \.mmrCr]
        let nlqs: [WritableKeyPath<DoviMetalParams, DoviNlqParams>] = [\.nlqY, \.nlqCb, \.nlqCr]
        for c in 0..<3 {
            func u(_ k: Int) -> UInt32 { sentinel(c, k) }
            func i(_ k: Int) -> Int32 { Int32(bitPattern: sentinel(c, k)) }
            p[keyPath: polys[c]].pivots[0] = u(0)
            p[keyPath: polys[c]].pivots[1] = u(1)
            p[keyPath: polys[c]].method[0] = u(2)
            p[keyPath: polys[c]].order[0] = u(3)
            p[keyPath: polys[c]].coef[0][0] = i(4)
            p[keyPath: polys[c]].coef[0][1] = i(5)
            p[keyPath: polys[c]].coef[1][0] = i(6)
            p[keyPath: polys[c]].coefShift[0] = u(7)
            p[keyPath: mmrs[c]].constant[0] = i(8)
            p[keyPath: mmrs[c]].coef[0][0] = i(9)
            p[keyPath: mmrs[c]].coef[0][1] = i(10)
            p[keyPath: mmrs[c]].coef[1][0] = i(11)
            p[keyPath: nlqs[c]].nlqMethod = DoviNlqMethod(rawValue: u(12))!
            p[keyPath: nlqs[c]].nlqOffset = i(13)
            p[keyPath: nlqs[c]].nlqScale = i(14)
            p[keyPath: nlqs[c]].nlqThreshold = i(15)
            p[keyPath: nlqs[c]].nlqShift = u(16)
            p[keyPath: nlqs[c]].vdrInMax = i(17)
            p[keyPath: nlqs[c]].nlqPivots = [u(18), u(19)]
        }
    }

    @Test("The shader reads every parameter sub-block at the offset the Swift serializer wrote it to")
    func layoutProbeRoundTrip() throws {
        let composer = try #require(DoviFelComposer())
        let params = Self.sentinelParams()
        let slots = try #require(composer.probeLayout(params: params),
                                 "dovi_layout_probe is unavailable, so the parameter ABI is unverified")
        #expect(slots.count == DoviFelComposer.layoutProbeSlots)

        /// Compares one slot, naming the field so a failure says which offset moved.
        func expect(_ slot: Int, _ value: UInt32, _ field: String) {
            #expect(slots[slot] == value,
                    "slot \(slot) (\(field)) read \(slots[slot]), expected \(value)")
        }
        func expect(_ slot: Int, signed value: Int32, _ field: String) {
            expect(slot, UInt32(bitPattern: value), field)
        }

        // sizeof on the GPU side, against the size the serializer produced.
        expect(0, UInt32(DoviMetalParams.serializedSize), "sizeof(DoviMetalParams)")
        #expect(params.serialize().count == DoviMetalParams.serializedSize)

        expect(1, 101, "bl_width")
        expect(2, 102, "bl_height")
        expect(3, 103, "el_width")
        expect(4, 104, "el_height")
        expect(5, 105, "target_mode")
        expect(6, DoviDither.bayer8x8.rawValue, "dither_mode")
        expect(7, 107, "frame_index")
        expect(8, DoviComposerFlags([.disableResidual, .lumaMmr]).rawValue, "flags")

        expect(9, 9, "poly_y.num_pivots")
        expect(10, 1023, "poly_y.pivots[8]")
        expect(11, DoviMapping.mmr.rawValue, "poly_y.method[7]")
        expect(12, 2, "poly_y.order[7]")
        expect(13, signed: -12345, "poly_y.coef[7][2]")
        expect(14, 23, "poly_y.coef_shift[7]")
        expect(15, 777, "mmr_y.mmr_constant[7]")
        expect(16, 888, "mmr_y.coef[7][20]")
        expect(17, 23, "mmr_y.coef_shift")
        expect(18, Self.sentinel(0, 17), "nlq_y.vdr_in_max")
        expect(19, Self.sentinel(0, 19), "nlq_y.nlq_pivots[1]")

        expect(20, 5, "poly_cb.num_pivots")
        expect(21, 17, "poly_cb.coef_shift[7]")
        expect(22, 1234, "mmr_cb.coef[7][20]")
        expect(23, 19, "mmr_cb.coef_shift")
        expect(24, Self.sentinel(1, 19), "nlq_cb.nlq_pivots[1]")

        expect(25, 3, "poly_cr.num_pivots")
        expect(26, 13, "poly_cr.coef_shift[7]")
        expect(27, signed: -4321, "mmr_cr.coef[7][20]")
        expect(28, 11, "mmr_cr.coef_shift")
        expect(29, Self.sentinel(2, 19), "nlq_cr.nlq_pivots[1]")

        expect(30, 1, "min_pq")
        expect(31, 2, "max_pq")
        expect(32, 3, "avg_pq")
        expect(33, 1023, "bl_max")
        expect(34, 4095, "vdr_max")
        expect(35, 4, "vdr_scale")

        // First element of every array and every NLQ scalar, per component, each with its own sentinel.
        let names = ["y", "cb", "cr"]
        for c in 0..<3 {
            for (k, field) in Self.componentFieldNames.enumerated() {
                expect(Self.slot(c, k), Self.sentinel(c, k), "\(names[c]).\(field)")
            }
        }
    }

    @Test("Bit depths derive the normalisation constants, and reject pairs the kernels cannot express")
    func bitDepthDerivation() {
        var p = DoviMetalParams()

        let profile7 = p.setBitDepths(bl: 10, vdr: 12)
        #expect(profile7)
        #expect(p.blMax == 1023)
        #expect(p.vdrMax == 4095)
        #expect(p.vdrScale == 4)

        let eightBit = p.setBitDepths(bl: 8, vdr: 8)
        #expect(eightBit)
        #expect(p.blMax == 255)
        #expect(p.vdrMax == 255)
        #expect(p.vdrScale == 1, "equal depths must not scale the residual")

        // A VDR depth below the base-layer depth has no meaning in the
        // reconstruction, and would make vdr_scale a fraction.
        let vdrBelowBl = p.setBitDepths(bl: 12, vdr: 10)
        let vdrTooDeep = p.setBitDepths(bl: 10, vdr: 20)
        let blTooShallow = p.setBitDepths(bl: 4, vdr: 12)
        #expect(!vdrBelowBl)
        #expect(!vdrTooDeep)
        #expect(!blTooShallow)
        #expect(p.blMax == 255, "a rejected pair must leave the previous values alone")
    }

    @Test("A zeroed NLQ block is neutral, matching what a memset gives the C side")
    func zeroedNlqIsNeutral() {
        let zeroed = DoviNlqParams()
        // nlq_method 0 is LINEAR, so neutrality has to come from the zero slope:
        // the kernel returns no residual when nlq_scale is zero. That is what lets
        // a memset-zeroed C struct and a default-initialised Swift value agree.
        #expect(zeroed.nlqMethod == .linear)
        #expect(zeroed.nlqScale == 0)

        let disabled = DoviNlqParams.disabled
        #expect(disabled.nlqMethod == .none)
        #expect(disabled.nlqScale == 0)
    }

    @Test("serialize(into:) writes byte-for-byte identical output to serialize() -> Data")
    func serializeIntoRawBufferMatchesSerializeData() {
        let params = Self.sentinelParams()
        let expectedData = params.serialize()

        var rawBytes = [UInt8](repeating: 0, count: DoviMetalParams.serializedSize)
        rawBytes.withUnsafeMutableBytes { raw in
            params.serialize(into: raw)
        }

        #expect(Data(rawBytes) == expectedData)
    }
}
#endif
