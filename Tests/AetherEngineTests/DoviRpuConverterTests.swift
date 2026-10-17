import Testing
import AetherLibavcodec
import Dovi
@testable import AetherEngine

/// Deterministic NAL-walk checks for the DV P7 -> P8.1 converter (#132/#135).
/// Successful real-RPU conversion and the FEL/MEL string value are validated against
/// dovi_tool ground truth via `aetherctl dovitest` and on device; these guard the
/// pure byte-walk branches (degrade-on-failure, EL drop, no-op) from regressing.
@Suite(.serialized)
struct DoviRpuConverterTests {

    /// 2-byte HEVC NAL header (type in bits 1..6 of byte 0, layer 0, temporal_id_plus1 = 1) + payload.
    private func hevcNAL(type: UInt8, payload: [UInt8]) -> [UInt8] {
        [UInt8(type << 1), 0x01] + payload
    }

    /// Pack NALs into an AVCC (4-byte BE length prefix) AVPacket, the framing the MKV/MP4 demuxer guarantees.
    private func avccPacket(_ nals: [[UInt8]]) -> UnsafeMutablePointer<AVPacket> {
        var bytes: [UInt8] = []
        for nal in nals {
            let n = nal.count
            bytes.append(UInt8((n >> 24) & 0xFF))
            bytes.append(UInt8((n >> 16) & 0xFF))
            bytes.append(UInt8((n >> 8) & 0xFF))
            bytes.append(UInt8(n & 0xFF))
            bytes.append(contentsOf: nal)
        }
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(bytes.count))
        bytes.withUnsafeBytes { src in
            _ = memcpy(pkt.pointee.data, src.baseAddress, bytes.count)
        }
        return pkt
    }

    /// The HEVC NAL types present in a packet, in order.
    private func nalTypes(_ pkt: UnsafeMutablePointer<AVPacket>) -> [UInt8] {
        guard let data = pkt.pointee.data else { return [] }
        let size = Int(pkt.pointee.size)
        var out: [UInt8] = []
        var off = 0
        while off + 4 <= size {
            var len = 0
            for i in 0..<4 { len = (len << 8) | Int(data[off + i]) }
            let start = off + 4
            if len == 0 || start + len > size { break }
            out.append((data[start] >> 1) & 0x3F)
            off = start + len
        }
        return out
    }

    private func free(_ pkt: UnsafeMutablePointer<AVPacket>) {
        var p: UnsafeMutablePointer<AVPacket>? = pkt
        av_packet_free(&p)
    }

    // MARK: - #135 point 3: conversion-failure posture

    @Test("Unconvertible RPU degrades to clean HDR10: RPU and EL dropped, base layer kept")
    func degradesOnUnconvertibleRPU() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])   // TRAIL_R base-layer VCL
        let rpu = hevcNAL(type: 62, payload: [0x00])       // malformed unspec62, libdovi rejects
        let el = hevcNAL(type: 63, payload: [0xCC])        // unspec63 enhancement layer
        let pkt = avccPacket([bl, rpu, el])
        defer { free(pkt) }

        // A libdovi failure reports false...
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt) == false)
        // ...and drops the RPU (62) and EL (63): no stale P7 metadata rides inside an 8.1 container.
        #expect(nalTypes(pkt) == [1])
    }

    @Test("A packet of only a refused RPU and an EL is left untouched and reports the failure")
    func refusedRPUWithoutBaseLayerReportsFailure() {
        let nals = [hevcNAL(type: 62, payload: [0x00]), hevcNAL(type: 63, payload: [0xCC])]
        let bytes = framed(nals, .lengthPrefixed(size: 4))
        let pkt = packet(from: bytes)
        defer { free(pkt) }

        // Nothing is left to rebuild a packet from, so it stays as it was, but the dropped RPU still counts.
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt) == false)
        #expect(packetBytes(pkt) == bytes)
    }

    /// CRC-valid RPUs that reach a panic or an unbounded allocation in libdovi, and one with a wrong CRC.
    /// Handing any of them to libdovi aborts the test process, so passing is the point.
    typealias Hostile = (name: String, rpu: [UInt8])
    static let hostileRPUs: [Hostile] = {
        typealias G = DoviRpuGuardTests
        let poly: [[G.Piece]] = [[.polynomial], [.polynomial], [.polynomial]]
        return [
            ("linear interpolation", G.craft(linearOnComponent: 1)),
            ("polynomial and MMR mix, no residual", G.craft(pieces: [[.polynomial, .mmr], [.polynomial], [.polynomial]])),
            ("polynomial and MMR mix, MEL", G.craft(pieces: [[.mmr, .polynomial], [.polynomial], [.polynomial]], residual: .mel)),
            ("polynomial and MMR mix, FEL", G.craft(pieces: [[.polynomial], [.polynomial], [.polynomial, .mmr]], residual: .fel)),
            ("pivot count beyond the payload", G.craft(pieces: poly, pivotCount: (UInt64(1) << 32) - 2)),
            ("mapping_idc with 64 leading zeros", G.craft(pieces: [[.linear], [.polynomial], [.polynomial]],
                                                          firstMappingIdc: { $0.ueRaw(zeros: 64, rest: 0) })),
            ("vdr_rpu_id with 40 leading zeros", G.craft(pieces: poly, vdrRpuId: { $0.ueRaw(zeros: 40, rest: G.maxRest(40)) })),
            ("undefined level 8 block length", G.craftUsePrev(cmv40Block: (11, 8))),
            ("bad CRC", G.withBadCRC(G.craft(linearOnComponent: nil), crcByte: 1)),
        ]
    }()

    @Test("A hostile or corrupt RPU is refused on the real conversion paths: HDR10 fallback, no abort",
          arguments: Array(DoviRpuConverterTests.hostileRPUs.indices), [VideoNALFraming.lengthPrefixed(size: 4), .annexB])
    func hostileRPUDegradesOnEveryEntryPoint(index: Int, framing: VideoNALFraming) {
        let (name, rpu) = Self.hostileRPUs[index]
        let nals = [hevcNAL(type: 1, payload: [0xAA, 0xBB]), rpu, hevcNAL(type: 63, payload: [0xCC])]
        let bytes = framed(nals, framing)

        // The probes read the packet and must come back empty-handed.
        let probe = packet(from: bytes)
        defer { free(probe) }
        #expect(DoviRpuConverter.enhancementLayerType(probe, framing: framing) == nil, Comment(rawValue: name))
        #expect(DolbyVisionRecordAudit.rpuProfile(probe, framing: framing) == nil, Comment(rawValue: name))

        // The conversion reports the failure and drops the RPU and the EL, keeping the base layer.
        let pkt = packet(from: bytes)
        defer { free(pkt) }
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt, framing: framing) == false, Comment(rawValue: name))
        let expected = framed([nals[0]], framing)
        #expect(packetBytes(pkt) == expected, Comment(rawValue: name))
    }

    @Test("A well-formed crafted RPU takes the same paths and converts, so the refusals above are the guard's")
    func craftedRPUConvertsOnTheSamePaths() {
        let rpu = DoviRpuGuardTests.craft(pieces: [[.polynomial], [.mmr], [.mmr]], residual: .fel)
        let bytes = framed([hevcNAL(type: 1, payload: [0xAA, 0xBB]), rpu, hevcNAL(type: 63, payload: [0xCC])],
                           .lengthPrefixed(size: 4))
        let probe = packet(from: bytes)
        defer { free(probe) }
        #expect(DoviRpuConverter.enhancementLayerType(probe) == "FEL")
        let pkt = packet(from: bytes)
        defer { free(pkt) }
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt) == true)
        #expect(nalTypes(pkt) == [1, 62])
    }

    @Test("A non-DV packet is left untouched")
    func leavesNonDVUntouched() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let pkt = avccPacket([bl])
        defer { free(pkt) }

        // A non-DV packet is not a conversion failure...
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt) == true)
        #expect(nalTypes(pkt) == [1])
    }

    @Test("Enhancement layer is dropped even when there is no RPU to convert")
    func dropsEnhancementLayer() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let el = hevcNAL(type: 63, payload: [0xCC])
        let pkt = avccPacket([bl, el])
        defer { free(pkt) }

        #expect(DoviRpuConverter.convertPacketToProfile81(pkt) == true)
        #expect(nalTypes(pkt) == [1])   // EL (63) stripped, base layer kept
    }

    // MARK: - #135 point 2: FEL vs MEL diagnostics

    @Test("enhancementLayerType returns nil when no RPU NAL is present")
    func elTypeNilWithoutRPU() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let pkt = avccPacket([bl])
        defer { free(pkt) }
        #expect(DoviRpuConverter.enhancementLayerType(pkt) == nil)
    }

    @Test("enhancementLayerType returns nil for an unparseable RPU")
    func elTypeNilForMalformedRPU() {
        let pkt = avccPacket([hevcNAL(type: 1, payload: [0xAA]), hevcNAL(type: 62, payload: [0x00])])
        defer { free(pkt) }
        #expect(DoviRpuConverter.enhancementLayerType(pkt) == nil)
    }

    @Test("enhancementLayerType does not hand libdovi an RPU the guard rejects (it would abort the process)")
    func elTypeSkipsAnRPUThatWouldAbortLibdovi() {
        // CRC-valid, but a linear-interpolation polynomial piece, which libdovi panics on.
        let rpu = DoviRpuGuardTests.craft(linearOnComponent: 0)
        let pkt = avccPacket([hevcNAL(type: 1, payload: [0xAA]), rpu])
        defer { free(pkt) }
        #expect(DoviRpuConverter.enhancementLayerType(pkt) == nil)
    }

    // MARK: - #365: framing is given, not assumed

    /// Pack NALs Annex B, the framing a Matroska remux with Annex-B CodecPrivate delivers.
    private func annexBPacket(_ nals: [[UInt8]]) -> UnsafeMutablePointer<AVPacket> {
        var bytes: [UInt8] = []
        for nal in nals {
            bytes += [0x00, 0x00, 0x00, 0x01]
            bytes += nal
        }
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(bytes.count))
        bytes.withUnsafeBytes { src in
            _ = memcpy(pkt.pointee.data, src.baseAddress, bytes.count)
        }
        return pkt
    }

    private func annexBNALTypes(_ pkt: UnsafeMutablePointer<AVPacket>) -> [UInt8] {
        guard let data = pkt.pointee.data else { return [] }
        var out: [UInt8] = []
        A53SEIParser.forEachNAL(data, Int(pkt.pointee.size), .annexB) { nal, _ in
            out.append((nal[0] >> 1) & 0x3F)
        }
        return out
    }

    /// Walked as length-prefixed, an Annex-B packet reads `00 00 00 01` as a 1-byte NAL and finds
    /// nothing to convert, so the RPU and EL of a P7 source rode untouched into a container the
    /// muxer had already rewritten to 8.1. The converter has to be told the framing.
    @Test("An Annex-B packet walked with the wrong framing keeps its EL, walked with the right one loses it")
    func annexBPacketNeedsItsFraming() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let el = hevcNAL(type: 63, payload: [0xCC])

        let wrong = annexBPacket([bl, el])
        defer { free(wrong) }
        #expect(DoviRpuConverter.convertPacketToProfile81(wrong) == true)
        #expect(annexBNALTypes(wrong) == [1, 63])   // untouched: the EL survived

        let right = annexBPacket([bl, el])
        defer { free(right) }
        #expect(DoviRpuConverter.convertPacketToProfile81(right, framing: .annexB) == true)
        #expect(annexBNALTypes(right) == [1])
    }

    @Test("A rewritten Annex-B packet stays Annex B")
    func annexBPacketKeepsItsFraming() {
        let pkt = annexBPacket([hevcNAL(type: 1, payload: [0xAA, 0xBB]),
                                hevcNAL(type: 62, payload: [0x00]),
                                hevcNAL(type: 63, payload: [0xCC])])
        defer { free(pkt) }
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt, framing: .annexB) == false)
        #expect(annexBNALTypes(pkt) == [1])
        // Emitting length prefixes here would break the muxer's own Annex-B assumption downstream.
        let head = [UInt8](UnsafeBufferPointer(start: pkt.pointee.data, count: 4))
        #expect(head == [0x00, 0x00, 0x00, 0x01])
    }

    @Test("A length prefix size the sample entry cannot declare leaves the packet alone")
    func refusesUnsupportedLengthSize() {
        let pkt = avccPacket([hevcNAL(type: 1, payload: [0xAA]), hevcNAL(type: 63, payload: [0xCC])])
        defer { free(pkt) }
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt, framing: .lengthPrefixed(size: 2)) == true)
        #expect(nalTypes(pkt) == [1, 63])   // untouched rather than rewritten into a framing nobody declared
    }

    @Test("enhancementLayerType walks Annex-B packets when given the framing")
    func elTypeWalksAnnexB() {
        let pkt = annexBPacket([hevcNAL(type: 1, payload: [0xAA]), hevcNAL(type: 62, payload: [0x00])])
        defer { free(pkt) }
        // A malformed RPU still returns nil, but it now REACHES the RPU: with the wrong framing the
        // walk never sees NAL 62 at all, which is the failure this guards.
        #expect(DoviRpuConverter.enhancementLayerType(pkt, framing: .annexB) == nil)
        #expect(annexBNALTypes(pkt) == [1, 62])
    }

    // MARK: - aetherctl dovitest output (audit BIT-106)

    /// The probe's writer used to walk every packet as 4-byte-length NALs whatever the source was,
    /// so an Annex-B packet holding four NALs came out as one 1-byte NAL.
    @Test("The probe writes every NAL of a packet behind a start code, in either framing")
    func probeEmitsEveryNALInEitherFraming() {
        let nals = [hevcNAL(type: 35, payload: [0x50]),
                    hevcNAL(type: 19, payload: [UInt8](repeating: 0xAA, count: 40)),
                    hevcNAL(type: 62, payload: [UInt8](repeating: 0x11, count: 9)),
                    hevcNAL(type: 63, payload: [UInt8](repeating: 0x22, count: 30))]
        for (framing, build) in [(VideoNALFraming.annexB, annexBPacket),
                                 (VideoNALFraming.lengthPrefixed(size: 4), avccPacket)] {
            let pkt = build(nals)
            defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
            let out = AetherEngine.doviProbeAnnexB(UnsafePointer(pkt), framing: framing)
            var emitted: [[UInt8]] = []
            out.withUnsafeBytes { raw in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                A53SEIParser.forEachNAL(base, out.count, .annexB) { nal, len in
                    emitted.append([UInt8](UnsafeBufferPointer(start: nal, count: len)))
                }
            }
            #expect(emitted == nals, "framing \(framing)")
            #expect(Array(out.prefix(4)) == [0, 0, 0, 1])
        }
    }

    @Test("Annex-B extradata is written as it is, hvcC parameter sets are start-coded")
    func probeParameterSetsFollowTheExtradataFraming() {
        let annexB: [UInt8] = [0, 0, 0, 1, 0x40, 0x01, 0xAA, 0, 0, 0, 1, 0x42, 0x01, 0xBB]
        let annexBOut = annexB.withUnsafeBufferPointer {
            AetherEngine.doviProbeParameterSets(extradata: $0.baseAddress, size: $0.count, framing: .annexB)
        }
        #expect([UInt8](annexBOut) == annexB)

        var hvcC = [UInt8](repeating: 0, count: 22)
        hvcC[0] = 1
        hvcC[21] = 0x03
        hvcC.append(1)                                   // numOfArrays
        hvcC += [0x20, 0x00, 0x01, 0x00, 0x03, 0x40, 0x01, 0xAA]   // VPS array, one NAL of 3 bytes
        let hvcCOut = hvcC.withUnsafeBufferPointer {
            AetherEngine.doviProbeParameterSets(extradata: $0.baseAddress, size: $0.count, framing: .lengthPrefixed(size: 4))
        }
        #expect([UInt8](hvcCOut) == [0, 0, 0, 1, 0x40, 0x01, 0xAA])
        #expect(AetherEngine.doviProbeParameterSets(extradata: nil, size: 0, framing: .annexB).isEmpty)
    }

    // MARK: - Audit PERF-111: one rebuild, byte-identical to the two-copy rebuild it replaced

    /// A real unspec62 RPU NAL (139 bytes, from Dolby's Profile 8.1 test signal), so the rewrite-and-
    /// keep branch is exercised and not only the degrade branch.
    private static let realRPU: [UInt8] = {
        let hex = "7c0119080908406136506f003ff801ffc00fffd0000008000006800000400000340000030200000301a2566000035ea2566f9fceb1c256644ca00000100000030080000003008000000301c36224301860a5e308e0514000001a63e5affff000000300000300000300060200f80e1530100a0000030000030000030024180fa000040fa00640a3c503f380"
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }()

    /// The rebuild as it was before: every surviving NAL copied into its own array, then copied again
    /// into the output. Kept here as the reference the single-copy rebuild has to match byte for byte.
    private func legacyRebuild(_ input: [UInt8], framing: VideoNALFraming) -> (bytes: [UInt8], ok: Bool)? {
        var outputNALs: [[UInt8]] = []
        var converted = false, droppedEL = false, degraded = false
        input.withUnsafeBufferPointer { buf in
            A53SEIParser.forEachNAL(buf.baseAddress!, buf.count, framing) { nal, len in
                switch (nal[0] >> 1) & 0x3F {
                case 62:
                    guard let rpu = DoviRpuGuard.parse(nal, len) else { degraded = true; return }   // as production: the guard first, libdovi is panic=abort
                    if dovi_convert_rpu_with_mode(rpu, 2) != 0 { dovi_rpu_free(rpu); degraded = true; return }
                    guard let out = dovi_write_unspec62_nalu(rpu) else { dovi_rpu_free(rpu); degraded = true; return }
                    guard let data = out.pointee.data, out.pointee.len > 0 else {
                        dovi_data_free(out); dovi_rpu_free(rpu); degraded = true; return
                    }
                    outputNALs.append([UInt8](UnsafeBufferPointer(start: data, count: out.pointee.len)))
                    dovi_data_free(out)
                    dovi_rpu_free(rpu)
                    converted = true
                case 63:
                    droppedEL = true
                default:
                    outputNALs.append([UInt8](UnsafeBufferPointer(start: nal, count: len)))
                }
            }
        }
        if !converted && !droppedEL && !degraded { return nil }
        var bytes: [UInt8] = []
        for nal in outputNALs {
            if framing == .annexB {
                bytes += [0, 0, 0, 1]
            } else {
                let n = nal.count
                bytes += [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            }
            bytes += nal
        }
        return bytes.isEmpty ? nil : (bytes, !degraded)
    }

    private func packetBytes(_ pkt: UnsafeMutablePointer<AVPacket>) -> [UInt8] {
        [UInt8](UnsafeBufferPointer(start: pkt.pointee.data, count: Int(pkt.pointee.size)))
    }

    private func framed(_ nals: [[UInt8]], _ framing: VideoNALFraming) -> [UInt8] {
        var bytes: [UInt8] = []
        for nal in nals {
            if framing == .annexB {
                bytes += [0, 0, 0, 1]
            } else {
                let n = nal.count
                bytes += [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            }
            bytes += nal
        }
        return bytes
    }

    private func packet(from bytes: [UInt8]) -> UnsafeMutablePointer<AVPacket> {
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(bytes.count))
        bytes.withUnsafeBytes { _ = memcpy(pkt.pointee.data, $0.baseAddress, bytes.count) }
        return pkt
    }

    private func slice(_ count: Int, seed: UInt8) -> [UInt8] {
        let header = hevcNAL(type: 1, payload: [])
        var state = UInt32(seed) &+ 1
        return header + (0..<count).map { _ in
            state = state &* 1664525 &+ 1013904223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
    }

    private func expectMatchesLegacy(_ nals: [[UInt8]], framing: VideoNALFraming,
                                     expectSuccess: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        let input = framed(nals, framing)
        let reference = legacyRebuild(input, framing: framing)
        let pkt = packet(from: input)
        defer { free(pkt) }

        let ok = DoviRpuConverter.convertPacketToProfile81(pkt, framing: framing)
        #expect(ok == expectSuccess, sourceLocation: sourceLocation)
        if let reference {
            #expect(reference.ok == ok, sourceLocation: sourceLocation)
            #expect(packetBytes(pkt) == reference.bytes, "the rebuilt packet differs from the two-copy rebuild",
                    sourceLocation: sourceLocation)
            let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
            let tail = [UInt8](UnsafeBufferPointer(start: pkt.pointee.data + Int(pkt.pointee.size), count: pad))
            #expect(tail == [UInt8](repeating: 0, count: pad), "decoders read past size", sourceLocation: sourceLocation)
        } else {
            #expect(packetBytes(pkt) == input, "a packet with nothing to rewrite is left alone",
                    sourceLocation: sourceLocation)
        }
    }

    @Test("A real RPU is rewritten and every other NAL survives byte for byte, in order (length-prefixed)")
    func realRPUMatchesTheTwoCopyRebuild() {
        let sei = hevcNAL(type: 39, payload: [0x01, 0x02, 0x03, 0x00, 0x00, 0x03, 0x01])
        expectMatchesLegacy([hevcNAL(type: 32, payload: [0x0C]), sei, slice(40_000, seed: 1),
                             Self.realRPU, hevcNAL(type: 63, payload: [0xCC, 0xDD])],
                            framing: .lengthPrefixed(size: 4), expectSuccess: true)
    }

    @Test("A real RPU is rewritten and every other NAL survives byte for byte, in order (Annex B)")
    func realRPUMatchesTheTwoCopyRebuildAnnexB() {
        expectMatchesLegacy([slice(3_000, seed: 2), Self.realRPU, slice(9_000, seed: 3)],
                            framing: .annexB, expectSuccess: true)
    }

    @Test("A malformed RPU degrades exactly as before: dropped, the rest untouched, failure reported")
    func degradedPacketMatchesTheTwoCopyRebuild() {
        expectMatchesLegacy([slice(5_000, seed: 4), hevcNAL(type: 62, payload: [0x00]), slice(700, seed: 5),
                             hevcNAL(type: 63, payload: [0x01])],
                            framing: .lengthPrefixed(size: 4), expectSuccess: false)
    }

    @Test("Several RPUs in one packet are each rewritten in place of their own position")
    func severalRPUsKeepTheirPositions() {
        expectMatchesLegacy([slice(100, seed: 6), Self.realRPU, slice(200, seed: 7), Self.realRPU, slice(300, seed: 8)],
                            framing: .lengthPrefixed(size: 4), expectSuccess: true)
    }

    @Test("A packet that is nothing but RPU and EL is left untouched")
    func onlyRPUAndELIsLeftAlone() {
        let input = framed([hevcNAL(type: 63, payload: [0x01]), hevcNAL(type: 63, payload: [0x02])], .lengthPrefixed(size: 4))
        let pkt = packet(from: input)
        defer { free(pkt) }
        // The EL is dropped, which would leave nothing: the degenerate guard keeps the packet.
        #expect(DoviRpuConverter.convertPacketToProfile81(pkt) == true)
        #expect(packetBytes(pkt) == input)
    }

    #if DualLayerDolbyVision
    // MARK: - Single parse per RPU

    /// Each RPU must be parsed exactly once. Before the fix, `separateDualLayers`
    /// parsed via `DoviFelComposer.parseRpuParameters` (internally calling
    /// `dovi_parse_unspec62_nalu`) and then again via a direct call, and
    /// `DualLayerVideoDecoder` added a third. After the fix: one parse per RPU.
    @Test("separateDualLayers parses each RPU exactly once")
    func singleParsePerRPUPerformance() {
        // Build a P7 packet from the real RPU fixture: BL + RPU + EL.
        // clipARpuHex already includes the 2-byte HEVC NAL header (0x7C, 0x01 = type 62).
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let rpu = hexToBytes(DoviFelMathTests.clipARpuHex)
        let el = hevcNAL(type: 63, payload: [0xCC])
        let pkt = avccPacket([bl, rpu, el])
        defer { free(pkt) }

        // Baseline: no prior parses.
        DoviFelComposer.resetParseRpuCountForTesting()
        #expect(DoviFelComposer.parseRpuCountForTesting == 0)

        let result = DoviRpuConverter.separateDualLayers(pkt)

        // Exactly one parse happened (via parseRpuParameters).
        #expect(DoviFelComposer.parseRpuCountForTesting == 1,
                "expected exactly 1 parse per RPU, got \(DoviFelComposer.parseRpuCountForTesting)")
        #expect(result.rpuParams != nil)
        #expect(result.convertedRpu != nil)
        #expect(result.isFEL == true)
        #expect(result.isMEL == false)
        #expect(result.success == true)
    }

    // MARK: - Several RPUs in one packet

    /// The raw bytes, the parameters and the converted RPU of a result must all come from one RPU.
    /// Clip A and clip C differ in pivots and in size, so each output names its source.
    @Test("with two valid RPUs in a packet, raw bytes, parameters and converted RPU all come from the last one")
    func twoValidRpusComeFromOneRpu() throws {
        let first = hexToBytes(DoviFelMathTests.clipARpuHex)
        let second = hexToBytes(DoviFelMathTests.clipCRpuHex)
        let pkt = avccPacket([hevcNAL(type: 1, payload: [0xAA]), first, second, hevcNAL(type: 63, payload: [0xCC])])
        defer { free(pkt) }
        let result = DoviRpuConverter.separateDualLayers(pkt)

        #expect(result.success)
        #expect(result.rpuData == second)
        // Parameters of the second RPU: its luma curve is not the first's 9-pivot one.
        let expected = try #require(Self.parameters(of: second))
        let got = try #require(result.rpuParams)
        #expect(got.polyY.numPivots == expected.polyY.numPivots)
        #expect(got.polyY.pivots == expected.polyY.pivots)
        #expect(got.polyCb.coef == expected.polyCb.coef)
        #expect(got.mmrCb.coef == expected.mmrCb.coef)
        let other = try #require(Self.parameters(of: first))
        #expect(got.polyY.pivots != other.polyY.pivots || got.mmrCb.coef != other.mmrCb.coef, "fixture RPUs must differ")
        #expect(result.convertedRpu == Self.converted(second))
    }

    @Test("a second RPU that fails the guard leaves the first RPU's bytes, parameters and conversion intact")
    func failingSecondRpuKeepsFirstConsistent() throws {
        let first = hexToBytes(DoviFelMathTests.clipARpuHex)
        var bad = hexToBytes(DoviFelMathTests.clipCRpuHex)
        bad[bad.count - 6] ^= 0xFF   // inside the CRC-covered payload: the guard refuses it
        let pkt = avccPacket([hevcNAL(type: 1, payload: [0xAA]), first, bad, hevcNAL(type: 63, payload: [0xCC])])
        defer { free(pkt) }
        let result = DoviRpuConverter.separateDualLayers(pkt)

        #expect(!result.success, "the dropped RPU is still reported")
        #expect(result.rpuData == first)
        let expected = try #require(Self.parameters(of: first))
        let got = try #require(result.rpuParams)
        #expect(got.polyY.pivots == expected.polyY.pivots)
        #expect(got.mmrCb.coef == expected.mmrCb.coef)
        #expect(result.convertedRpu == Self.converted(first))
        #expect(result.isFEL)
    }

    private static func parameters(of nal: [UInt8]) -> DoviMetalParams? {
        guard let rpu = dovi_parse_unspec62_nalu(nal, nal.count) else { return nil }
        defer { dovi_rpu_free(rpu) }
        return DoviFelComposer.parseRpuParameters(rpu: rpu)
    }

    private static func converted(_ nal: [UInt8]) -> [UInt8]? {
        guard let rpu = dovi_parse_unspec62_nalu(nal, nal.count) else { return nil }
        defer { dovi_rpu_free(rpu) }
        guard let out = DoviRpuConverter.convertedUnspec62(rpu) else { return nil }
        defer { dovi_data_free(out) }
        return [UInt8](UnsafeBufferPointer(start: out.pointee.data, count: out.pointee.len))
    }

    @Test("separateDualLayers skips parameter extraction when extractParams is false")
    func separateDualLayersSkipsParameterExtractionWhenRequested() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let rpu = hexToBytes(DoviFelMathTests.clipARpuHex)
        let el = hevcNAL(type: 63, payload: [0xCC])
        let pkt = avccPacket([bl, rpu, el])
        defer { free(pkt) }

        DoviFelComposer.resetParseRpuCountForTesting()
        #expect(DoviFelComposer.parseRpuCountForTesting == 0)

        let result = DoviRpuConverter.separateDualLayers(pkt, extractParams: false)

        #expect(DoviFelComposer.parseRpuCountForTesting == 0,
                "expected 0 parses when extractParams is false, got \(DoviFelComposer.parseRpuCountForTesting)")
        #expect(result.rpuParams == nil)
        #expect(result.convertedRpu != nil)
        #expect(result.isFEL == true)
        #expect(result.isMEL == false)
        #expect(result.success == true)
    }

    @Test("convertPacketToProfile81 skips parameter extraction")
    func convertPacketToProfile81SkipsParameterExtraction() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB])
        let rpu = hexToBytes(DoviFelMathTests.clipARpuHex)
        let el = hevcNAL(type: 63, payload: [0xCC])
        let pkt = avccPacket([bl, rpu, el])
        defer { free(pkt) }

        DoviFelComposer.resetParseRpuCountForTesting()
        #expect(DoviFelComposer.parseRpuCountForTesting == 0)

        let success = DoviRpuConverter.convertPacketToProfile81(pkt)

        #expect(DoviFelComposer.parseRpuCountForTesting == 0,
                "expected 0 parses in convertPacketToProfile81, got \(DoviFelComposer.parseRpuCountForTesting)")
        #expect(success == true)
    }

    // MARK: - Untouched Base Layer with CustomBlockSource

    @Test("separateDualLayers with useCustomBlockSource leaves packet untouched while extracting EL and RPU")
    func separateDualLayersWithCustomBlockSourceLeavesPacketUntouched() {
        let bl = hevcNAL(type: 1, payload: [0xAA, 0xBB, 0xCC, 0xDD])
        let rpu = hexToBytes(DoviFelMathTests.clipARpuHex)
        let el = hevcNAL(type: 63, payload: [0xEE, 0xFF])
        let pkt = avccPacket([bl, rpu, el])
        defer { free(pkt) }

        let originalData = pkt.pointee.data
        let originalSize = pkt.pointee.size
        let originalBuf = pkt.pointee.buf

        let result = DoviRpuConverter.separateDualLayers(
            pkt,
            extractEL: true,
            useCustomBlockSource: true,
            extractParams: true
        )
        defer {
            var elOpt: UnsafeMutablePointer<AVPacket>? = result.elPacket
            trackedPacketFree(&elOpt)
        }

        // Base-layer packet pointer, size, and AVBufferRef must be COMPLETELY UNTOUCHED
        #expect(pkt.pointee.data == originalData)
        #expect(pkt.pointee.size == originalSize)
        #expect(pkt.pointee.buf == originalBuf)

        // EL packet, RPU params, and converted RPU must still be correctly extracted
        #expect(result.elPacket != nil)
        #expect(result.rpuParams != nil)
        #expect(result.convertedRpu != nil)
        #expect(result.isFEL == true)
        #expect(result.isMEL == false)
        #expect(result.success == true)
    }
    #endif

    /// Hex-string decoder for RPU fixtures.
    private func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            if let byte = UInt8(hex[i..<next], radix: 16) {
                bytes.append(byte)
            }
            i = next
        }
        return bytes
    }
}
