import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
import Dovi
@testable import AetherEngine

/// Pins the RPU that rides on every composed frame of the dual-layer (FEL) route to libdovi mode 2.
///
/// The Metal composer has already applied the RPU's luma/chroma reshaping and added the residual, so the
/// frame that reaches the display layer is the finished picture. The attached RPU therefore has to carry
/// no mapping (mode 2 sets both curves to no-op, drops the EL/NLQ part) and keep the display metadata
/// (L1/L2 and, on CM v4.0 sources, L3/L8/L9/L11/L254). Were it to keep the mapping (mode 5), the display
/// side would reshape a second time on top of an already reshaped picture.
///
/// The path under test is `DoviRpuConverter.separateDualLayers` with a custom block source, whose
/// `convertedRpu` is the RPU a composed frame carries (what `DoviDisplayMetadata.attach` takes).
@Suite(.serialized, .offCooperativePoolOneLane)
struct DoviComposedFrameRpuTests {

    // MARK: - Fixture

    /// dovi_tool's `fel_orig.bin` (MIT licence, Copyright quietvoid), a 384-byte Profile 7 FEL RPU: the
    /// bytes after its 4-byte Annex-B start code, i.e. the unspec62 payload (0x19 prefix) in escaped form.
    /// Embedded as hex; the 2-byte unspec62 NAL header (0x7C 0x01) is put back in `felNAL`.
    /// Its luma curve is a 9-piece polynomial, chroma is MMR, and it carries NLQ parameters, so unlike a
    /// Profile 8.1 RPU its mapping is not a no-op and mode 2 has something to neutralise.
    static let felHex: String =
        "1908090840613650ae20002008020080200802007f801ffc00ffc001fffa0000030100000300d0000008000006800000" +
        "400000340000030200000301a000001000000d0000030080000068000004000003034000002000000a86d9e67b2f863e" +
        "fc189e6029e98c06b8c566a7cd5f8dffcb6d8c39e38a9981b86ca6790f405f434cb7d80e9e04c349fd3bb77ec2cd5de3" +
        "a147d44c0a2e8062164a029b5d59500ed38f58c46c4ec13a14582cff3023536d57bbb6e411483b92966413698fce6bc3" +
        "1bd620fadd405bbef4643160b1f01bf2eefbf2a5e2f3ccb4abf3cc3983779e7568311b00480000400400400000401200" +
        "0010010010000010048000040040040000072566000035ea2566f9fceb1c256644ca0000030100000300080000030008" +
        "000003001c36224301860a5e308e051400000301a63e5affff000003000003000003000060200f80e1518030080059ca" +
        "1200c028218df82580080061400002022a512088050000030002281150120c07d000020d60015eb8f29d8280"

    static let felNAL: [UInt8] = {
        var out: [UInt8] = [0x7C, 0x01]
        var i = felHex.startIndex
        while i < felHex.endIndex {
            let j = felHex.index(i, offsetBy: 2)
            out.append(UInt8(felHex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }()

    // MARK: - Production path

    private static func hevcNAL(type: UInt8, payload: [UInt8]) -> [UInt8] { [UInt8(type << 1), 0x01] + payload }

    private static func avcc(_ nals: [[UInt8]]) -> UnsafeMutablePointer<AVPacket> {
        var bytes: [UInt8] = []
        for n in nals {
            let c = n.count
            bytes += [UInt8((c >> 24) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
            bytes += n
        }
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(bytes.count))
        bytes.withUnsafeBytes { _ = memcpy(pkt.pointee.data, $0.baseAddress, bytes.count) }
        return pkt
    }

    /// What `separateDualLayers` does with one packet, flags included, and what it returns: the raw RPU
    /// NAL and the converted one that a composed frame carries.
    static func composedFrameRpu(source nal: [UInt8]) -> (raw: [UInt8], attached: [UInt8])? {
        let pkt = avcc([hevcNAL(type: 1, payload: [0xAA, 0xBB]), nal, hevcNAL(type: 63, payload: [0xCC, 0xDD])])
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
        return composedFrameRpu(packet: pkt)
    }

    static func composedFrameRpu(packet: UnsafeMutablePointer<AVPacket>) -> (raw: [UInt8], attached: [UInt8])? {
        let r = DoviRpuConverter.separateDualLayers(packet, extractEL: true, useCustomBlockSource: true, extractParams: true)
        var el = r.elPacket
        trackedPacketFree(&el)
        guard let raw = r.rpuData, let attached = r.convertedRpu else { return nil }
        return (raw, attached)
    }

    /// The same conversion with another libdovi mode, for the guard test.
    static func converted(_ nal: [UInt8], mode: UInt8) -> [UInt8]? {
        nal.withUnsafeBufferPointer { buf -> [UInt8]? in
            guard let rpu = DoviRpuGuard.parse(buf.baseAddress!, buf.count) else { return nil }
            defer { dovi_rpu_free(rpu) }
            guard dovi_convert_rpu_with_mode(rpu, mode) == 0, let out = dovi_write_unspec62_nalu(rpu) else { return nil }
            defer { dovi_data_free(out) }
            return [UInt8](UnsafeBufferPointer(start: out.pointee.data, count: out.pointee.len))
        }
    }

    // MARK: - Snapshot of what libdovi reads back

    struct Curve: Equatable {
        var mappingIdc: UInt8
        var pivots: [UInt16]
        var hasPolynomial: Bool
        var hasMMR: Bool
        var polyOrderMinus1: [UInt64]
        var polyCoefInt: [[Int64]]
        var polyCoef: [[UInt64]]
    }

    struct Snapshot: Equatable {
        var profile: UInt8
        var elType: String?
        var rpuFormat: UInt16
        var disableResidual: Bool
        var curves: [Curve]
        var nlqMethodIdc: Int32
        var hasNLQ: Bool
        /// Scalar fields of the VDR DM data (everything but the extension blocks).
        var dmScalars: [String]
        /// Extension blocks by level, every field of every block.
        var blocks: [String: [String]]

        /// Both reshaping curves of every component are the identity polynomial: order 1, y = x.
        var isIdentityMapping: Bool {
            curves.count == 3 && curves.allSatisfy { c in
                c.mappingIdc == 0 && c.hasPolynomial && !c.hasMMR
                    && c.polyOrderMinus1.allSatisfy { $0 == 0 }
                    && c.polyCoefInt.allSatisfy { $0 == [0, 1] }
                    && c.polyCoef.allSatisfy { $0 == [0, 0] }
            }
        }

        /// No residual: not a dual-layer RPU any more.
        var carriesNoEnhancementLayer: Bool { !hasNLQ && elType == nil }
    }

    private static func dump<T>(_ v: T, skip: Set<String> = []) -> [String] {
        Mirror(reflecting: v).children.compactMap { c in
            guard let l = c.label, !skip.contains(l) else { return nil }
            return "\(l)=\(c.value)"
        }
    }

    private static func list<T>(_ list: UnsafePointer<UnsafePointer<T>?>?, _ n: Int) -> [[String]] {
        guard let list else { return [] }
        return (0..<n).compactMap { list[$0].map { dump($0.pointee) } }
    }

    static func snapshot(ofNAL nal: [UInt8]) -> Snapshot? {
        nal.withUnsafeBufferPointer { buf -> Snapshot? in
            guard let rpu = DoviRpuGuard.parse(buf.baseAddress!, buf.count) else { return nil }
            defer { dovi_rpu_free(rpu) }
            guard let hdr = dovi_rpu_get_header(rpu), let map = dovi_rpu_get_data_mapping(rpu),
                  let dm = dovi_rpu_get_vdr_dm_data(rpu) else { return nil }
            defer { dovi_rpu_free_header(hdr); dovi_rpu_free_data_mapping(map); dovi_rpu_free_vdr_dm_data(dm) }

            var curves: [Curve] = []
            for c in [map.pointee.curves.0, map.pointee.curves.1, map.pointee.curves.2] {
                var poly = Curve(mappingIdc: c.mapping_idc,
                                 pivots: c.pivots.data.map { Array(UnsafeBufferPointer(start: $0, count: c.pivots.len)) } ?? [],
                                 hasPolynomial: c.polynomial != nil, hasMMR: c.mmr != nil,
                                 polyOrderMinus1: [], polyCoefInt: [], polyCoef: [])
                if let p = c.polynomial?.pointee {
                    poly.polyOrderMinus1 = p.poly_order_minus1.data.map { Array(UnsafeBufferPointer(start: $0, count: p.poly_order_minus1.len)) } ?? []
                    if let l = p.poly_coef_int.list {
                        poly.polyCoefInt = (0..<p.poly_coef_int.len).map { i in
                            l[i].flatMap { d in d.pointee.data.map { Array(UnsafeBufferPointer(start: $0, count: d.pointee.len)) } } ?? []
                        }
                    }
                    if let l = p.poly_coef.list {
                        poly.polyCoef = (0..<p.poly_coef.len).map { i in
                            l[i].flatMap { d in d.pointee.data.map { Array(UnsafeBufferPointer(start: $0, count: d.pointee.len)) } } ?? []
                        }
                    }
                }
                curves.append(poly)
            }

            let d = dm.pointee.dm_data
            var blocks: [String: [String]] = [:]
            if let b = d.level1 { blocks["L1"] = dump(b.pointee) }
            if d.level2.len > 0 { blocks["L2"] = list(d.level2.list, d.level2.len).flatMap { $0 } }
            if let b = d.level3 { blocks["L3"] = dump(b.pointee) }
            if let b = d.level4 { blocks["L4"] = dump(b.pointee) }
            if let b = d.level5 { blocks["L5"] = dump(b.pointee) }
            if let b = d.level6 { blocks["L6"] = dump(b.pointee) }
            if d.level8.len > 0 { blocks["L8"] = list(d.level8.list, d.level8.len).flatMap { $0 } }
            if let b = d.level9 { blocks["L9"] = dump(b.pointee) }
            if d.level10.len > 0 { blocks["L10"] = list(d.level10.list, d.level10.len).flatMap { $0 } }
            if let b = d.level11 { blocks["L11"] = dump(b.pointee) }
            if let b = d.level254 { blocks["L254"] = dump(b.pointee) }
            if let b = d.level255 { blocks["L255"] = dump(b.pointee) }

            return Snapshot(profile: hdr.pointee.guessed_profile,
                            elType: hdr.pointee.el_type.map { String(cString: $0) },
                            rpuFormat: hdr.pointee.rpu_format,
                            disableResidual: hdr.pointee.disable_residual_flag,
                            curves: curves, nlqMethodIdc: map.pointee.nlq_method_idc,
                            hasNLQ: map.pointee.nlq != nil,
                            dmScalars: dump(dm.pointee, skip: ["dm_data"]), blocks: blocks)
        }
    }

    /// The assertions every composed-frame RPU has to satisfy against the source it came from.
    static func expectPinned(source: Snapshot, attached: Snapshot, label: String,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(attached.profile == 8, "\(label): attached RPU is not Profile 8", sourceLocation: sourceLocation)
        #expect(attached.carriesNoEnhancementLayer, "\(label): attached RPU still carries an EL/NLQ part", sourceLocation: sourceLocation)
        #expect(attached.isIdentityMapping, "\(label): attached RPU keeps a non-identity mapping (a second reshape on the display side)", sourceLocation: sourceLocation)
        #expect(Set(attached.blocks.keys) == Set(source.blocks.keys),
                "\(label): extension levels changed, source \(source.blocks.keys.sorted()) attached \(attached.blocks.keys.sorted())", sourceLocation: sourceLocation)
        for (level, fields) in source.blocks {
            #expect(attached.blocks[level] == fields, "\(label): \(level) differs after conversion", sourceLocation: sourceLocation)
        }
        #expect(attached.dmScalars == source.dmScalars, "\(label): VDR DM scalars differ after conversion", sourceLocation: sourceLocation)
    }

    // MARK: - Synthetic

    @Test("The fixture is a Profile 7 FEL RPU with L1/L2 display metadata")
    func fixtureIsFel() throws {
        let s = try #require(Self.snapshot(ofNAL: Self.felNAL))
        #expect(s.profile == 7)
        #expect(s.elType == "FEL")
        #expect(s.hasNLQ)
        #expect(!s.isIdentityMapping)
        #expect(s.blocks["L1"] != nil)
        #expect(s.blocks["L2"] != nil)
    }

    @Test("The RPU attached to a composed frame has no-op curves, no EL, and the source's display metadata")
    func attachedRpuIsMode2() throws {
        let source = try #require(Self.snapshot(ofNAL: Self.felNAL))
        let (raw, attached) = try #require(Self.composedFrameRpu(source: Self.felNAL))
        #expect(raw == Self.felNAL)
        #expect(attached.prefix(2).elementsEqual([0x7C, 0x01]), "complete unspec62 NAL, as DoviDisplayMetadata.attach expects")
        let out = try #require(Self.snapshot(ofNAL: attached))
        Self.expectPinned(source: source, attached: out, label: "fel_orig")
    }

    // MARK: - Real file (CM v4.0)

    static let cmv40Clip = DoviFelRealFileTests.fixtures[2]
    static let packetsToCheck = 240

    /// The mapping of this clip's RPUs is already the identity polynomial, so it proves the display metadata
    /// survives (CM v4.0 L3/L8/L9/L254 included) but not the mode-2-vs-5 difference; the fixture above does.
    /// The RPUs of the first `packetsToCheck` video packets of the clip, through the production path.
    @Test("Real CM v4.0 clip: every composed-frame RPU is no-op mapped and keeps L1/L2/L3/L8/L9/L254 (and every level the source has)",
          .enabled(if: DoviFelRealFileTests.available(DoviComposedFrameRpuTests.cmv40Clip), DoviFelRealFileTests.needsClips))
    func realClipKeepsCmv40() throws {
        let demuxer = Demuxer()
        try demuxer.open(url: DoviFelRealFileTests.url(Self.cmv40Clip))
        defer { demuxer.close() }
        let idx = Int32(demuxer.videoStreamIndex)

        var checked = 0, nonIdentitySources = 0
        var levelsBefore = Set<String>(), levelsAfter = Set<String>()
        var packets = 0
        while packets < Self.packetsToCheck, let pkt = try demuxer.readPacket() {
            defer {
                av_packet_unref(pkt)
                var o: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&o)
            }
            guard pkt.pointee.stream_index == idx else { continue }
            packets += 1
            guard let (raw, attached) = Self.composedFrameRpu(packet: pkt) else { continue }
            let source = try #require(Self.snapshot(ofNAL: raw))
            let out = try #require(Self.snapshot(ofNAL: attached))
            Self.expectPinned(source: source, attached: out, label: "packet \(packets)")
            levelsBefore.formUnion(source.blocks.keys)
            levelsAfter.formUnion(out.blocks.keys)
            if !source.isIdentityMapping { nonIdentitySources += 1 }
            checked += 1
        }
        print("DOVI-REAL packets=\(packets) rpus=\(checked) sourceNonIdentity=\(nonIdentitySources) levelsBefore=\(levelsBefore.sorted()) levelsAfter=\(levelsAfter.sorted())")
        #expect(checked > 0)
        // `expectPinned` already compares every level the source has. This pins that the clip really is
        // CM v4.0 (so the check is not vacuous) and that those levels came out the other side. The clip
        // has no L10/L11 (nothing to drop); `levelsAfter == levelsBefore` is asserted for whatever it has.
        for level in ["L1", "L2", "L3", "L8", "L9", "L254"] {
            #expect(levelsBefore.contains(level), "clip no longer carries \(level); the check would be vacuous")
            #expect(levelsAfter.contains(level), "\(level) did not survive")
        }
        #expect(levelsAfter == levelsBefore)
    }

    // MARK: - Guard: the assertions can tell mode 2 from modes that keep the mapping

    @Test("Mode 5 keeps the mapping and the EL, so the pinned assertions would catch a regression to it")
    func mode5FailsThePin() throws {
        let source = try #require(Self.snapshot(ofNAL: Self.felNAL))
        let m5 = try #require(Self.converted(Self.felNAL, mode: 5))
        let kept = try #require(Self.snapshot(ofNAL: m5))
        #expect(kept.profile == 7)
        #expect(!kept.carriesNoEnhancementLayer)
        #expect(!kept.isIdentityMapping, "mode 5 must not satisfy the identity-mapping assertion, or the pin proves nothing")
        // The DM survives mode 5 as well, so the mapping assertions are what separate the two modes.
        #expect(kept.blocks == source.blocks)
    }

    @Test("Mode 0 (no conversion) fails the pin too")
    func mode0FailsThePin() throws {
        let m0 = try #require(Self.converted(Self.felNAL, mode: 0))
        let kept = try #require(Self.snapshot(ofNAL: m0))
        #expect(!kept.isIdentityMapping)
        #expect(!kept.carriesNoEnhancementLayer)
    }


    #if DualLayerDolbyVision
    // MARK: - Raw base layer: the mapping stays

    /// `fel_orig` with `disable_residual_flag` set, made by libdovi itself (mode 1, then mode 2: the NLQ is
    /// dropped and the flag set, the curves and the display metadata are kept), so it is the RPU class libdovi
    /// parses, not a hand-made bit pattern. A real FEL stream carries these on frames without a residual.
    static let felNoResidualNAL: [UInt8]? = {
        felNAL.withUnsafeBufferPointer { buf -> [UInt8]? in
            guard let rpu = DoviRpuGuard.parse(buf.baseAddress!, buf.count) else { return nil }
            defer { dovi_rpu_free(rpu) }
            guard dovi_convert_rpu_with_mode(rpu, 1) == 0, dovi_convert_rpu_with_mode(rpu, 2) == 0,
                  let out = dovi_write_unspec62_nalu(rpu) else { return nil }
            defer { dovi_data_free(out) }
            return [UInt8](UnsafeBufferPointer(start: out.pointee.data, count: out.pointee.len))
        }
    }()

    @Test("The residual-off fixture has the flag set, no el_type, a non-identity mapping, and L1/L2")
    func noResidualFixtureShape() throws {
        let nal = try #require(Self.felNoResidualNAL)
        let s = try #require(Self.snapshot(ofNAL: nal))
        #expect(s.disableResidual)
        #expect(s.elType == nil)
        #expect(!s.hasNLQ)
        #expect(!s.isIdentityMapping)
        #expect(s.blocks["L1"] != nil)
        #expect(s.blocks["L2"] != nil)
    }

    @Test("A composed frame whose RPU has disable_residual_flag set still carries no mapping, and the same display metadata")
    func noResidualRpuIsUnmappedOnComposedFrames() throws {
        let nal = try #require(Self.felNoResidualNAL)
        let source = try #require(Self.snapshot(ofNAL: nal))
        let (raw, attached) = try #require(Self.composedFrameRpu(source: nal))
        #expect(raw == nal)
        let out = try #require(Self.snapshot(ofNAL: attached))
        Self.expectPinned(source: source, attached: out, label: "fel_orig, residual off")
    }

    /// An access unit with no enhancement layer NAL (the case the decoder releases a base frame for) still
    /// yields both forms of its RPU: the composed one with the mapping removed, and the one a raw base
    /// layer carries, which keeps it.
    @Test("An access unit without an enhancement layer yields a mapping-preserving RPU for the raw base layer and the no-op one for a composed frame",
          arguments: ["fel_orig", "fel_orig, residual off"])
    func baseLayerRpuKeepsTheMapping(label: String) throws {
        let nal = try #require(label == "fel_orig" ? Self.felNAL : Self.felNoResidualNAL)
        let pkt = Self.avcc([Self.hevcNAL(type: 1, payload: [0xAA, 0xBB]), nal])
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
        let r = DoviRpuConverter.separateDualLayers(pkt, extractEL: true, useCustomBlockSource: true, extractParams: true)
        #expect(r.elPacket == nil, "the access unit has no enhancement layer")
        let source = try #require(Self.snapshot(ofNAL: nal))
        let composed = try #require(r.convertedRpu)
        let baseLayer = try #require(r.baseLayerRpu)
        #expect(baseLayer.prefix(2).elementsEqual([0x7C, 0x01]), "complete unspec62 NAL")

        let c = try #require(Self.snapshot(ofNAL: composed))
        Self.expectPinned(source: source, attached: c, label: "\(label): composed form")

        let b = try #require(Self.snapshot(ofNAL: baseLayer))
        #expect(b.profile == 8, "not Profile 8")
        #expect(b.carriesNoEnhancementLayer, "still carries an EL/NLQ part")
        #expect(!b.isIdentityMapping, "the mapping was dropped: the display would show the base layer unreshaped")
        #expect(b.curves == source.curves, "the curves changed")
        #expect(b.blocks == source.blocks, "display metadata changed")
        #expect(baseLayer != composed)
    }
    #endif
}
