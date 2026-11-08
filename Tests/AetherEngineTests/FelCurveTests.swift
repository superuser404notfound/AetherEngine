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

    @Test("a constant residual lifts the stream's luma curve by that amount")
    func constantResidual() throws {
        var samples = FelCurveSamples()
        var state: UInt64 = 1
        for _ in 0..<20_000 {
            state = state &* 6364136223846793005 &+ 1
            samples.base.append(Float(64 + Int(state >> 33) % 880))
            samples.residual.append(40)
        }
        let stream = FelCurve.identity(pivots: FelCurve.uniform(pieces: 8))
        let residual = FelCurveFit.lumaResidual(samples, pivots: stream.pivots)
        let luma = try #require(stream.adding(residual))
        #expect(luma.pivots == stream.pivots)
        for x in stride(from: 0.1, through: 0.9, by: 0.05) {
            #expect(abs(luma.value(at: x) - (x + 40.0 / 4095)) < 1e-6)
        }
    }

    @Test("without samples the residual is zero and the stream's luma is unchanged")
    func noResidual() {
        let stream = FelCurve(pivots: [0, 512, 1023], coefs: [0.01, 0.9, 0.05, -0.02, 1.0, 0.0])
        let residual = FelCurveFit.lumaResidual(FelCurveSamples(), pivots: stream.pivots)
        #expect(residual.coefs == [0, 0, 0, 0, 0, 0])
        #expect(stream.adding(residual) == stream)
    }

    @Test("curves with other pivots are not added")
    func addingNeedsSamePivots() {
        let a = FelCurve.identity(pivots: [0, 512, 1023])
        let b = FelCurve.identity(pivots: [0, 256, 1023])
        #expect(a.adding(b) == nil)
    }

    @Test("samples bunched in part of a piece get a lower order instead of an unconstrained parabola")
    func narrowSpread() {
        var samples = FelCurveSamples()
        for i in 0..<3_000 {
            samples.base.append(Float(300 + i % 3))
            samples.residual.append(Float(i % 7) - 3 + 12)
        }
        let residual = FelCurveFit.lumaResidual(samples, pivots: FelCurve.uniform(pieces: 8))
        // Piece 2 (256..384) holds every sample within 3 codes: a constant, no slope or curvature.
        let piece = Array(residual.coefs[6..<9])
        #expect(abs(piece[0] - 12.0 / 4095) < 1e-6)
        #expect(piece[1] == 0)
        #expect(piece[2] == 0)
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

    static func chromaMethods(_ rpu: OpaquePointer) -> [UInt8] {
        guard let mapping = dovi_rpu_get_data_mapping(rpu) else { return [] }
        defer { dovi_rpu_free_data_mapping(mapping) }
        return [mapping.pointee.curves.1.mapping_idc, mapping.pointee.curves.2.mapping_idc]
    }

    @Test("the fold keeps the stream's chroma mapping and writes the luma curve it was given")
    func keepsChromaWritesLuma() throws {
        let source = try #require(Self.parse(Self.bytes(Self.felRpuHex)))
        let sourceChroma = Self.chromaMethods(source)
        let streamLuma = try #require(FelRpuInfo.read(source)?.luma)
        dovi_rpu_free(source)

        let rpu = try #require(Self.parse(Self.bytes(Self.felRpuHex)))
        defer { dovi_rpu_free(rpu) }
        let delta = FelCurve(pivots: streamLuma.pivots,
                             coefs: (0..<streamLuma.pieces).flatMap { [0.001 * Double($0), 0.02, -0.01] })
        let luma = try #require(streamLuma.adding(delta))
        let out = try #require(DoviRpuConverter.convertedUnspec62(rpu, keepMapping: true,
                                                                   rewrite: { luma.apply(to: $0, component: 0) }))
        defer { dovi_data_free(out) }
        let back = try #require(Self.parse([UInt8](UnsafeBufferPointer(start: out.pointee.data, count: out.pointee.len))))
        defer { dovi_rpu_free(back) }
        let header = try #require(dovi_rpu_get_header(back))
        #expect(header.pointee.guessed_profile == 8)
        dovi_rpu_free_header(header)
        #expect(Self.chromaMethods(back) == sourceChroma)
        let info = try #require(FelRpuInfo.read(back))
        #expect(!info.carriesResidual)
        let written = try #require(info.luma)
        #expect(written.pivots == luma.pivots)
        for (a, b) in zip(written.coefs, luma.coefs) {
            #expect(abs(a - b) < 1e-6)
        }
    }

    @Test("a rewrite that libdovi refuses leaves the stream's own mapping")
    func refusedRewriteKeepsMapping() throws {
        let source = try #require(Self.parse(Self.bytes(Self.felRpuHex)))
        let streamLuma = try #require(FelRpuInfo.read(source)?.luma)
        dovi_rpu_free(source)

        let rpu = try #require(Self.parse(Self.bytes(Self.felRpuHex)))
        defer { dovi_rpu_free(rpu) }
        let bad = FelCurve(pivots: [0, 512, 256], coefs: [0, 1, 0, 0, 1, 0])
        let out = try #require(DoviRpuConverter.convertedUnspec62(rpu, keepMapping: true,
                                                                   rewrite: { bad.apply(to: $0, component: 0) }))
        defer { dovi_data_free(out) }
        let back = try #require(Self.parse([UInt8](UnsafeBufferPointer(start: out.pointee.data, count: out.pointee.len))))
        defer { dovi_rpu_free(back) }
        let luma = try #require(FelRpuInfo.read(back)?.luma)
        #expect(luma.pivots == streamLuma.pivots)
        for (a, b) in zip(luma.coefs, streamLuma.coefs) {
            #expect(abs(a - b) < 1e-6)
        }
    }
}
#endif
