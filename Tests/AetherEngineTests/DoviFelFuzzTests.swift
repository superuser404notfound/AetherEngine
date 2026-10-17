import Testing
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import Dovi
@testable import AetherEngine

/// Corrupt and hostile input must degrade (nil parameters, dropped EL, base layer
/// only), never crash or hang. Seeds are real packets/RPUs from the FEL fixtures;
/// mutations are deterministic so a failure reproduces.
@Suite(.offCooperativePoolOneLane)
struct DoviFelFuzzTests {

    /// SplitMix64: deterministic, no dependence on the system RNG.
    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    }

    /// First video packet that contains an RPU, as raw bytes, plus one RPU NAL.
    static func seed(index: Int = 2) throws -> (packet: [UInt8], rpu: [UInt8])? {
        let name = DoviFelRealFileTests.fixtures[index]
        guard DoviFelRealFileTests.available(name) else { return nil }
        let demuxer = Demuxer()
        try demuxer.open(url: DoviFelRealFileTests.url(name))
        defer { demuxer.close() }
        let idx = Int32(demuxer.videoStreamIndex)
        while let pkt = try demuxer.readPacket() {
            defer {
                av_packet_unref(pkt)
                var o: UnsafeMutablePointer<AVPacket>? = pkt
                trackedPacketFree(&o)
            }
            guard pkt.pointee.stream_index == idx, let data = pkt.pointee.data else { continue }
            let bytes = [UInt8](UnsafeBufferPointer(start: data, count: Int(pkt.pointee.size)))
            let copy = makePacket(bytes)
            defer { var o: UnsafeMutablePointer<AVPacket>? = copy; trackedPacketFree(&o) }
            let r = DoviRpuConverter.separateDualLayers(copy, extractEL: false, useCustomBlockSource: true, extractParams: true)
            if let raw = r.rpuData { return (bytes, raw) }
        }
        return nil
    }

    /// Owns its buffer, padded the way FFmpeg packets are.
    static func makePacket(_ bytes: [UInt8]) -> UnsafeMutablePointer<AVPacket> {
        let pkt = trackedPacketAlloc()!
        let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
        let ref = av_buffer_alloc(bytes.count + pad)!
        memset(ref.pointee.data, 0, bytes.count + pad)
        _ = bytes.withUnsafeBufferPointer { memcpy(ref.pointee.data, $0.baseAddress!, bytes.count) }
        pkt.pointee.buf = ref
        pkt.pointee.data = ref.pointee.data
        pkt.pointee.size = Int32(bytes.count)
        pkt.pointee.pts = 0
        pkt.pointee.dts = 0
        return pkt
    }

    /// Mutations only probe the parser if they start from an RPU libdovi really accepts. libdovi
    /// hands back a handle even when parsing fails, so the error, not the handle, is the verdict.
    static func expectLibdoviAccepts(_ nal: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let rpu = try #require(nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) },
                               sourceLocation: sourceLocation)
        defer { dovi_rpu_free(rpu) }
        #expect(dovi_rpu_get_error(rpu) == nil, "\(dovi_rpu_get_error(rpu).map { String(cString: $0) } ?? "")",
                sourceLocation: sourceLocation)
        #if DualLayerDolbyVision
        #expect(DoviFelComposer.parseRpuParameters(rpu: rpu) != nil, sourceLocation: sourceLocation)
        #endif
    }

    static func mutate(_ input: [UInt8], _ rng: inout RNG) -> [UInt8] {
        var b = input
        switch rng.below(6) {
        case 0: // flip a few bits
            for _ in 0..<(1 + rng.below(8)) where !b.isEmpty { b[rng.below(b.count)] ^= UInt8(1 << rng.below(8)) }
        case 1: // truncate
            b = Array(b.prefix(rng.below(b.count + 1)))
        case 2: // overwrite a run with 0xFF / 0x00
            if !b.isEmpty {
                let start = rng.below(b.count), len = 1 + rng.below(16)
                let v: UInt8 = rng.below(2) == 0 ? 0xFF : 0x00
                for i in start..<min(b.count, start + len) { b[i] = v }
            }
        case 3: // random garbage of the same length
            for i in 0..<b.count { b[i] = UInt8(truncatingIfNeeded: rng.next()) }
        case 4: // duplicate a slice
            if b.count > 4 {
                let start = rng.below(b.count - 1), len = 1 + rng.below(min(32, b.count - start))
                b.insert(contentsOf: b[start..<(start + len)], at: start)
            }
        default: // extend with junk
            for _ in 0..<rng.below(64) { b.append(UInt8(truncatingIfNeeded: rng.next())) }
        }
        return b
    }

    /// A length-prefixed access unit built from a synthetic RPU: a base-layer slice, an enhancement-layer
    /// NAL (`unspec63`) and the RPU (`unspec62`), so the splitter fuzz runs without a clip.
    static func syntheticPacket(rpu: [UInt8]) -> [UInt8] {
        func framed(_ nal: [UInt8]) -> [UInt8] {
            let n = UInt32(nal.count)
            return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + nal
        }
        let base: [UInt8] = [0x02, 0x01] + (0..<48).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }
        let el: [UInt8] = [0x7E, 0x01, 0x02, 0x01] + (0..<24).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 3) }
        return framed(base) + framed(el) + framed(rpu)
    }

    #if DualLayerDolbyVision
    static func checkMutatedRpuParsing(seedRPU: [UInt8], label: String, rngState: UInt64, iterations: Int) throws {
        #expect(seedRPU.withUnsafeBufferPointer { DoviRpuGuard.crcIsValid($0.baseAddress!, $0.count) }, "a seed RPU must pass the CRC guard")
        try expectLibdoviAccepts(seedRPU)
        var rng = RNG(state: rngState)
        var parsed = 0, rejected = 0
        for _ in 0..<iterations {
            let rpuBytes = mutate(seedRPU, &rng)
            guard !rpuBytes.isEmpty else { continue }
            guard let rpu = rpuBytes.withUnsafeBufferPointer({ DoviRpuGuard.parse($0.baseAddress!, $0.count) }) else {
                rejected += 1
                continue
            }
            defer { dovi_rpu_free(rpu) }
            if let p = DoviFelComposer.parseRpuParameters(rpu: rpu) {
                parsed += 1
                // Whatever survives must be safe for the kernels to index.
                for poly in [p.polyY, p.polyCb, p.polyCr] {
                    #expect(poly.numPivots <= UInt32(DoviPolynomialParams.maxPivots))
                    if poly.numPivots >= 2 {
                        let pieces = Int(poly.numPivots) - 1
                        for i in 0..<pieces {
                            #expect(poly.pivots[i] <= poly.pivots[i + 1], "pivots must ascend")
                            #expect(poly.order[i] <= 3)
                            #expect(poly.coefShift[i] <= 23 || poly.method[i] == DoviMapping.mmr.rawValue)
                        }
                        #expect(poly.pivots[Int(poly.numPivots) - 1] <= p.blMax)
                    }
                }
                #expect(p.blMax == 1023)
                #expect(p.vdrScale >= 1)
                for n in [p.nlqY, p.nlqCb, p.nlqCr] {
                    #expect(n.nlqShift <= 23)
                    #expect(n.vdrInMax >= 0)
                }
            } else {
                rejected += 1
            }
        }
        print("[fuzz] RPU \(label): \(parsed) parsed, \(rejected) rejected of \(iterations)")
        #expect(parsed + rejected > iterations * 3 / 4)
    }

    @Test("a mutated synthetic RPU never crashes libdovi or the parameter parser; the result is nil or self-consistent",
          .timeLimit(.minutes(2)), arguments: DoviCrcValidFuzzTests.syntheticSeeds.indices)
    func mutatedSyntheticRpuParsing(index: Int) throws {
        let seed = DoviCrcValidFuzzTests.syntheticSeeds[index]
        try Self.checkMutatedRpuParsing(seedRPU: seed.nal, label: seed.name, rngState: 0xFE1 + UInt64(index), iterations: 4000)
    }

    @Test("a mutated RPU from a real clip never crashes libdovi or the parameter parser; the result is nil or self-consistent",
          .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[2]), DoviFelRealFileTests.needsClips),
          .timeLimit(.minutes(2)))
    func mutatedRpuParsing() throws {
        let seed = try #require(try Self.seed())
        try Self.checkMutatedRpuParsing(seedRPU: seed.rpu, label: "clip", rngState: 0xFE1, iterations: 4000)
    }
    #endif

    static func checkMutatedPacketSplitting(seedPacket: [UInt8], useCustomBlockSource: Bool, iterations: Int) {
        var rng = RNG(state: useCustomBlockSource ? 0xA11 : 0xB22)
        for i in 0..<iterations {
            let bytes = mutate(seedPacket, &rng)
            let pkt = makePacket(bytes.isEmpty ? [0] : bytes)
            let r = DoviRpuConverter.separateDualLayers(
                pkt, extractEL: true, useCustomBlockSource: useCustomBlockSource, extractParams: true
            )
            if let el = r.elPacket {
                // An extracted EL must be a well-formed length-prefixed stream inside its buffer.
                var off = 0
                let size = Int(el.pointee.size)
                while off + 4 <= size {
                    let n = (Int(el.pointee.data[off]) << 24) | (Int(el.pointee.data[off + 1]) << 16)
                        | (Int(el.pointee.data[off + 2]) << 8) | Int(el.pointee.data[off + 3])
                    #expect(n >= 0 && off + 4 + n <= size, "iteration \(i): EL NAL overruns its packet")
                    if off + 4 + n > size { break }
                    off += 4 + n
                }
                #expect(off == size || size - off < 4, "iteration \(i): trailing bytes in EL packet")
                var o: UnsafeMutablePointer<AVPacket>? = el
                trackedPacketFree(&o)
            }
            var o: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&o)
        }
    }

    @Test("a mutated or truncated synthetic access unit is split without crashing, and never reads past its buffer",
          .timeLimit(.minutes(3)),
          arguments: DoviCrcValidFuzzTests.syntheticSeeds.indices, [true, false])
    func mutatedSyntheticPacketSplitting(index: Int, useCustomBlockSource: Bool) {
        let packet = Self.syntheticPacket(rpu: DoviCrcValidFuzzTests.syntheticSeeds[index].nal)
        Self.checkMutatedPacketSplitting(seedPacket: packet, useCustomBlockSource: useCustomBlockSource, iterations: 1500)
    }

    @Test("a mutated or truncated access unit from a real clip is split without crashing, and never reads past its buffer",
          .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[2]), DoviFelRealFileTests.needsClips),
          .timeLimit(.minutes(3)),
          arguments: [true, false])
    func mutatedPacketSplitting(useCustomBlockSource: Bool) throws {
        let seed = try #require(try Self.seed())
        Self.checkMutatedPacketSplitting(seedPacket: seed.packet, useCustomBlockSource: useCustomBlockSource, iterations: 1500)
    }

    @Test("length prefixes that lie about their size are contained by the NAL walker",
          arguments: [0xFFFF_FFFF, 0x7FFF_FFFF, 0x8000_0000, 0x0000_1000, 0x0000_0004, 0])
    func lyingLengthPrefix(length: UInt32) throws {
        // [len][2-byte NAL header + 6 bytes] — the prefix claims `length`.
        var bytes: [UInt8] = [
            UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF),
            0x7E, 0x01, 1, 2, 3, 4, 5, 6,
        ]
        for variant in 0..<3 {
            if variant == 1 { bytes += bytes }                 // a second, equally wrong, NAL
            if variant == 2 { bytes = Array(bytes.prefix(6)) } // cut inside the header
            let pkt = Self.makePacket(bytes)
            let r = DoviRpuConverter.separateDualLayers(pkt, extractEL: true, useCustomBlockSource: false, extractParams: true)
            if let el = r.elPacket { var o: UnsafeMutablePointer<AVPacket>? = el; trackedPacketFree(&o) }
            var o: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&o)
        }
    }

    @Test("empty, tiny and null-data packets are handled")
    func degeneratePackets() {
        for size in [0, 1, 2, 3, 4, 5] {
            let pkt = Self.makePacket([UInt8](repeating: 0x7E, count: size))
            pkt.pointee.size = Int32(size)
            let r = DoviRpuConverter.separateDualLayers(pkt, extractEL: true, useCustomBlockSource: false, extractParams: true)
            #expect(r.elPacket == nil)
            var o: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&o)
        }
        let empty = trackedPacketAlloc()!   // data == nil
        let r = DoviRpuConverter.separateDualLayers(empty, extractEL: true, useCustomBlockSource: true, extractParams: true)
        #expect(r.elPacket == nil && r.rpuData == nil)
        var o: UnsafeMutablePointer<AVPacket>? = empty
        trackedPacketFree(&o)
    }
}
