#if DolbyVisionFelCurves
import Testing
import Foundation
import Dovi
@testable import AetherEngine

@Suite("FEL curve fold")
struct FelCurveTests {

    /// A Profile 7 FEL RPU (clip A of the composer's fixtures), with its 2-byte NAL header.
    static let felRpuHex = "7c011908090840613650ae20002008020080200802007f801ffc00ffc001fffa0000030100000300d0000008000006800000400000340000030200000301a000001000000d0000030080000068000004000003034000002000000a800000800000e18618800000800000800000800000800000800000b0c30c800000800000800000800000800000800000986186800000800000800000800000800000540000040000040000070c30c4000004000004000004000004000004000005861864000004000004000004000004000004000004c30c34000004000004000004000004012000010010010000030100480000400400400000401200001001001000001c95980000d7a8959be7f3ac7095991328000004000003002000000300200000030070d8890c06182978c238145000000698f96bfffc00000300000300000300018081f73805463008015faa4900c0282183180081872b94210002020000030008050000030002261140120c1f4000641f2e1276ffb6cfda80"

    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    static func parse(_ nal: [UInt8]) -> OpaquePointer? {
        nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) }
    }

    @Test("uniform pivots match the split Profile 7 streams use for luma")
    func uniformPivots() {
        #expect(FelCurve.uniform(pieces: 8) == [0, 128, 256, 384, 512, 640, 768, 896, 1023])
        #expect(FelCurve.uniform(pieces: 4) == [0, 256, 512, 768, 1023])
    }

    @Test("the inverse quantiser matches the composer's arithmetic")
    func inverseNlq() {
        // offset 512, slope 2048 / 2^23, 12-bit VDR: shift 11, ceiling 2^20 >> 11.
        let nlq = FelNlq(offset: 512, scale: 2048, threshold: 0, vdrInMax: 512, shift: 11)
        #expect(nlq.residual(elCode: 512) == 0)
        #expect(nlq.residual(elCode: 513) == 0)
        #expect(nlq.residual(elCode: 514) == 1)
        #expect(nlq.residual(elCode: 600) == 87)
        #expect(nlq.residual(elCode: 424) == -87)
        #expect(nlq.residual(elCode: 1023) == 510)
        let ceiling = FelNlq(offset: 512, scale: 4096, threshold: 0, vdrInMax: 100, shift: 11)
        #expect(ceiling.residual(elCode: 1000) == 100)
        #expect(ceiling.residual(elCode: 20) == -100)
    }

    @Test("a constant residual lifts the stream's luma curve and identity chroma by that amount")
    func constantResidual() {
        var samples = FelCurveSamples()
        var state: UInt64 = 1
        for _ in 0..<20_000 {
            state = state &* 6364136223846793005 &+ 1
            let code = Float(64 + Int(state >> 33) % 880)
            for c in 0..<3 {
                samples.base[c].append(code)
                samples.residual[c].append(c == 0 ? 40 : -20)
            }
        }
        let stream = FelCurve.identity(pivots: FelCurve.uniform(pieces: 8))
        let set = FelCurveFit.fit(samples, streamLuma: stream)
        #expect(set.components[0].pivots == stream.pivots)
        #expect(set.components[1].pivots == FelCurve.uniform(pieces: 4))
        for x in stride(from: 0.1, through: 0.9, by: 0.05) {
            #expect(abs(set.components[0].value(at: x) - (x + 40.0 / 4095)) < 1e-6)
            #expect(abs(set.components[1].value(at: x) - (x - 20.0 / 4095)) < 1e-6)
        }
    }

    @Test("without samples the curves are the stream's luma and identity chroma")
    func noResidual() {
        let stream = FelCurve(pivots: [0, 512, 1023], coefs: [0.01, 0.9, 0.05, -0.02, 1.0, 0.0])
        let set = FelCurveFit.fit(FelCurveSamples(), streamLuma: stream)
        #expect(set.components[0] == stream)
        #expect(set.components[1] == FelCurve.identity(pivots: FelCurve.uniform(pieces: 4)))
        #expect(set.components[2] == FelCurve.identity(pivots: FelCurve.uniform(pieces: 4)))
    }

    @Test("samples bunched in part of a piece get a lower order instead of an unconstrained parabola")
    func narrowSpread() {
        var samples = FelCurveSamples()
        for i in 0..<3_000 {
            let code = Float(300 + i % 3)
            for c in 0..<3 {
                samples.base[c].append(code)
                samples.residual[c].append(Float(i % 7) - 3 + 12)
            }
        }
        let set = FelCurveFit.fit(samples, streamLuma: nil)
        // Piece 2 of luma (256..384) holds every sample within 3 codes: a constant, no slope or curvature.
        let piece = Array(set.components[0].coefs[6..<9])
        let identity = [0.0, 1.0, 0.0]
        #expect(abs(piece[0] - identity[0] - 12.0 / 4095) < 1e-6)
        #expect(piece[1] == identity[1])
        #expect(piece[2] == identity[2])
    }

    @Test("the RPU reader takes the stream's luma polynomial, the inverse quantiser and the residual flag")
    func readsFelRpu() throws {
        let rpu = try #require(Self.parse(Self.bytes(Self.felRpuHex)))
        defer { dovi_rpu_free(rpu) }
        let info = try #require(FelRpuInfo.read(rpu))
        #expect(info.carriesResidual)
        #expect(info.nlq?.count == 3)
        #expect(info.vdrBits == 12)
        let luma = try #require(info.luma)
        #expect(luma.pivots.first == 0)
        #expect(luma.pivots.count >= 2)
        #expect(luma.coefs.count == 3 * luma.pieces)
    }

    @Test("curves written into the converted RPU read back as written and survive a write and parse")
    func curvesRoundTrip() throws {
        let rpu = try #require(Self.parse(Self.bytes(Self.felRpuHex)))
        defer { dovi_rpu_free(rpu) }
        let set = FelCurveSet(components: [
            FelCurve(pivots: FelCurve.uniform(pieces: 8), coefs: (0..<8).flatMap { [0.001 * Double($0), 1.02, -0.01] }),
            FelCurve(pivots: FelCurve.uniform(pieces: 4), coefs: (0..<4).flatMap { _ in [-0.004, 1.0, 0.0] }),
            FelCurve(pivots: FelCurve.uniform(pieces: 4), coefs: (0..<4).flatMap { _ in [0.003, 0.99, 0.0] }),
        ])
        let out = try #require(DoviRpuConverter.convertedUnspec62(rpu, rewrite: { set.apply(to: $0) }))
        defer { dovi_data_free(out) }
        let written = [UInt8](UnsafeBufferPointer(start: out.pointee.data, count: out.pointee.len))
        let back = try #require(Self.parse(written))
        defer { dovi_rpu_free(back) }
        let header = try #require(dovi_rpu_get_header(back))
        #expect(header.pointee.guessed_profile == 8)
        dovi_rpu_free_header(header)
        let mapping = try #require(dovi_rpu_get_data_mapping(back))
        defer { dovi_rpu_free_data_mapping(mapping) }
        let curves = [mapping.pointee.curves.0, mapping.pointee.curves.1, mapping.pointee.curves.2]
        for (curve, expected) in zip(curves, set.components) {
            #expect(curve.mapping_idc == 0)
            #expect(Int(curve.num_pivots_minus2) + 2 == expected.pivots.count)
        }
        let info = try #require(FelRpuInfo.read(back))
        let luma = try #require(info.luma)
        #expect(luma.pivots == set.components[0].pivots)
        for (a, b) in zip(luma.coefs, set.components[0].coefs) {
            #expect(abs(a - b) < 1e-6)
        }
        #expect(!info.carriesResidual)
    }

    @Test("a rewrite that libdovi refuses falls back to the mode 2 mapping")
    func refusedRewriteFallsBack() throws {
        let rpu = try #require(Self.parse(Self.bytes(Self.felRpuHex)))
        defer { dovi_rpu_free(rpu) }
        let bad = FelCurveSet(components: [FelCurve(pivots: [0, 512, 256], coefs: [0, 1, 0, 0, 1, 0])])
        let out = try #require(DoviRpuConverter.convertedUnspec62(rpu, rewrite: { bad.apply(to: $0) }))
        defer { dovi_data_free(out) }
        let back = try #require(Self.parse([UInt8](UnsafeBufferPointer(start: out.pointee.data, count: out.pointee.len))))
        defer { dovi_rpu_free(back) }
        let luma = try #require(FelRpuInfo.read(back)?.luma)
        #expect(luma.pivots == [0, 1023])
        #expect(luma.coefs == [0, 1, 0])
    }
}
#endif
