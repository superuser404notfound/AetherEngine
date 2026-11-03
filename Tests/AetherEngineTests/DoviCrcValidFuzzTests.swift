import Testing
import Foundation
import Dovi
@testable import AetherEngine

extension HeavyDualLayerSuites {
    /// The existing RPU fuzz mostly dies at the CRC check. This one repairs the CRC after mutating the
    /// payload (and re-applies emulation prevention), so the mutated RPU actually reaches libdovi's
    /// parser, which is built panic=abort: any upstream panic here would kill the process.
    @Suite(.offCooperativePool)
    struct DoviCrcValidFuzzTests {

        private static let crcTable: [UInt32] = (0..<256).map { i in
            var c = UInt32(i) << 24
            for _ in 0..<8 { c = c & 0x8000_0000 != 0 ? (c << 1) ^ 0x04C1_1DB7 : c << 1 }
            return c
        }

        static func escape(_ u: [UInt8]) -> [UInt8] {
            var out = [UInt8](), zeros = 0
            for (i, b) in u.enumerated() {
                if zeros >= 2 && b <= 3 && i >= 2 { out.append(3); zeros = 0 }
                out.append(b)
                zeros = b == 0 ? zeros + 1 : 0
            }
            return out
        }

        /// Mutates payload bytes of an unescaped RPU and fixes up the CRC.
        static func mutateValid(_ u: [UInt8], _ rng: inout DoviFelFuzzTests.RNG) -> [UInt8] {
            var b = u
            let tailAt = b.count - 5
            guard tailAt > 4 else { return b }
            switch rng.below(4) {
            case 0: for _ in 0..<(1 + rng.below(4)) { b[3 + rng.below(tailAt - 3)] ^= UInt8(1 << rng.below(8)) }
            case 1: b[3 + rng.below(tailAt - 3)] = UInt8(truncatingIfNeeded: rng.next())
            case 2:  // concentrate on the header/mapping region, where the syntax branches
                for _ in 0..<(1 + rng.below(3)) { b[3 + rng.below(min(40, tailAt - 3))] ^= UInt8(1 << rng.below(8)) }
            default:
                let start = 3 + rng.below(tailAt - 3), len = 1 + rng.below(8)
                for i in start..<min(tailAt, start + len) { b[i] = rng.below(2) == 0 ? 0xFF : 0x00 }
            }
            var crc: UInt32 = 0xFFFF_FFFF
            for i in 3..<tailAt { crc = (crc << 8) ^ crcTable[Int((crc >> 24) ^ UInt32(b[i]))] }
            b[tailAt] = UInt8(crc >> 24); b[tailAt + 1] = UInt8((crc >> 16) & 0xFF)
            b[tailAt + 2] = UInt8((crc >> 8) & 0xFF); b[tailAt + 3] = UInt8(crc & 0xFF)
            return b
        }

        /// Found by `crcValidMutations` (fixture 1): a CRC-valid RPU whose partition count is a 41-zero exp-Golomb
        /// code. libdovi parses it and then reads a linear-interp flag (abort); the guard must follow the code past 32 zeros.
        static let crcBytesReachLinearFlag = "7c011908090840613650ae20002008020080200802007f801ffc00ffc000ff00ff00000300000300d012811f6bf799ff6bf740000033fed7ee80000067fdafdd00000300cffb5fba000003019ff6bf74000003033fed7ee8000003029cdbf713e290d652833715954c126341284d15cc741520f02a42e5370f5ae1a762d5a57ca0430473c965dc73e4d29f0f297d65394bee5e94a7d40d35adc59e1a36d3f34ee2eb989b55a704d10a2f93177b914f4592097648f189d4419cd595ec49e0ecb7c041984ff7b4f97998e4d1ef509fe7b00ee182b2675ba33e73521f46cfaf3860d29087e92b30b43b2437b1006000004010004000004018000010040010000010060000040100040000072566000035ea2566f9fceb1c256644ca0000030100000300080000030008000003001c36224301860a5e308e051400000301a63e5affff000003000003000003000060207dce0151c030080002300e80c028217c58006d48008351000180580f0010010011a73442000404044129100a000003000460230024183e8000c828340ab0b02e561a80"

        @Test("the guard reads exp-Golomb codes as long as libdovi does")
        func guardCoversCrcBytes() throws {
            let bytes = stride(from: 0, to: Self.crcBytesReachLinearFlag.count, by: 2).map {
                UInt8(Self.crcBytesReachLinearFlag.dropFirst($0).prefix(2), radix: 16)!
            }
            #expect(bytes.withUnsafeBufferPointer { DoviRpuGuard.crcIsValid($0.baseAddress!, $0.count) })
            #expect(bytes.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) } == nil)
        }

        /// RPUs built in the test source (`DoviRpuGuardTests.craft`), so the fuzz runs wherever the suite does:
        /// a Profile 7 FEL RPU with a two-piece luma curve and MMR chroma, a MEL one whose curves are all
        /// polynomial, and a MEL one with MMR chroma. A MEL RPU keeps its mapping through the mode 2
        /// conversion, so these reach the writer's curve code; an FEL RPU's mapping is dropped there.
        static let syntheticSeeds: [(name: String, nal: [UInt8])] = [
            ("synthetic FEL", DoviRpuGuardTests.craft(pieces: [[.polynomial, .polynomial], [.mmr], [.mmr]], residual: .fel)),
            ("synthetic MEL, polynomial", DoviRpuGuardTests.craft(pieces: [[.polynomial], [.polynomial], [.polynomial]], residual: .mel)),
            ("synthetic MEL, MMR chroma", DoviRpuGuardTests.craft(pieces: [[.polynomial], [.mmr], [.mmr]], residual: .mel)),
        ]

        /// `AETHER_FUZZ_N` overrides the iteration count; the default is what a CI run can afford per seed
        /// for the synthetic seeds and what an unattended soak is worth for a clip.
        static func iterations(default fallback: Int) -> Int {
            Int(ProcessInfo.processInfo.environment["AETHER_FUZZ_N"] ?? "") ?? fallback
        }

        /// Mutates `nal` with the CRC repaired every time, and pushes whatever the guard lets through the
        /// way production does: parse, the composer's parameter walk, then the mode 2 conversion and the
        /// write (`DoviRpuConverter.convertedUnspec62`). libdovi aborts the process on a panic, so
        /// getting to the end is the assertion.
        static func fuzz(seed nal: [UInt8], label: String, rngSeed: UInt64, iterations: Int) throws {
            try DoviFelFuzzTests.expectLibdoviAccepts(nal)
            let u = try #require(nal.withUnsafeBufferPointer { DoviRpuGuard.verifiedUnescaped($0.baseAddress!, $0.count) })
            let env = ProcessInfo.processInfo.environment
            var rng = DoviFelFuzzTests.RNG(state: rngSeed + (UInt64(env["AETHER_FUZZ_SEED"] ?? "") ?? 0) << 16)
            var reached = 0, guarded = 0, parsed = 0, written = 0
            for _ in 0..<iterations {
                let m = Self.escape(Self.mutateValid(u, &rng))
                guard m.withUnsafeBufferPointer({ DoviRpuGuard.crcIsValid($0.baseAddress!, $0.count) }) else { continue }
                reached += 1
                if let dump = env["AETHER_FUZZ_DUMP"] { try? Data(m).write(to: URL(fileURLWithPath: dump + label)) }
                guard let rpu = m.withUnsafeBufferPointer({ DoviRpuGuard.parse($0.baseAddress!, $0.count) }) else { guarded += 1; continue }
                defer { dovi_rpu_free(rpu) }
                #if DualLayerDolbyVision
                if let p = DoviFelComposer.parseRpuParameters(rpu: rpu) {
                    parsed += 1
                    for poly in [p.polyY, p.polyCb, p.polyCr] {
                        var q = poly; q.clampToCapacity()
                        #expect(q.numPivots <= UInt32(DoviPolynomialParams.maxPivots))
                    }
                }
                #endif
                if let out = DoviRpuConverter.convertedUnspec62(rpu) {
                    written += 1
                    dovi_data_free(out)
                }
            }
            print("[fuzz-crc] \(label): \(reached) CRC-valid mutants, \(guarded) rejected by guard/libdovi, \(parsed) parsed, \(written) converted and written")
            #expect(reached > iterations * 3 / 4)
            #expect(written > 0, "no mutant survived to the writer: the seed is not exercising it")
        }

        @Test("a CRC-valid mutated synthetic RPU never aborts libdovi in parse, convert or write",
              .timeLimit(.minutes(5)), arguments: DoviCrcValidFuzzTests.syntheticSeeds.indices)
        func crcValidMutationsOfSyntheticSeeds(index: Int) throws {
            let seed = Self.syntheticSeeds[index]
            try Self.fuzz(seed: seed.nal, label: seed.name, rngSeed: 0x5E0 + UInt64(index),
                          iterations: Self.iterations(default: 20000))
        }

        static func fuzzClip(_ fixture: Int) throws {
            let seed = try #require(try DoviFelFuzzTests.seed(index: fixture))
            try fuzz(seed: seed.rpu, label: "fixture \(fixture)", rngSeed: 0xC4C + UInt64(fixture),
                     iterations: iterations(default: 20000))
        }

        @Test("a CRC-valid mutated RPU from the first clip never aborts libdovi in parse, convert or write",
              .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[0]), DoviFelRealFileTests.needsClips),
              .timeLimit(.minutes(30)))
        func crcValidMutationsClip0() throws { try Self.fuzzClip(0) }

        @Test("a CRC-valid mutated RPU from the second clip never aborts libdovi in parse, convert or write",
              .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[1]), DoviFelRealFileTests.needsClips),
              .timeLimit(.minutes(30)))
        func crcValidMutationsClip1() throws { try Self.fuzzClip(1) }

        @Test("a CRC-valid mutated RPU from the third clip never aborts libdovi in parse, convert or write",
              .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[2]), DoviFelRealFileTests.needsClips),
              .timeLimit(.minutes(30)))
        func crcValidMutationsClip2() throws { try Self.fuzzClip(2) }
    }
}

extension HeavyDualLayerSuites.DoviCrcValidFuzzTests {
    @Test("replay a dumped RPU", .enabled(if: ProcessInfo.processInfo.environment["AETHER_FUZZ_REPLAY"] != nil))
    func replay() throws {
        let d = [UInt8](try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["AETHER_FUZZ_REPLAY"]!)))
        let u = d.withUnsafeBufferPointer { DoviRpuGuard.verifiedUnescaped($0.baseAddress!, $0.count) }
        print("[replay] crc ok \(u != nil), guard says unimplemented: \(u.map { DoviRpuGuard.reachesUnimplementedPath($0) } ?? false)")
        let r = d.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) }
        print("[replay] parsed \(r != nil)")
    }
}
