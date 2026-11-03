#if DualLayerDolbyVision
import Testing
import Foundation
import Dovi
@testable import AetherEngine

/// The per-frame tables the composer fills for the kernels (inverse NLQ per EL code, MMR coefficients as
/// floats) against a reference written out here from the definition, not from the table code. The kernels
/// index these tables instead of recomputing per sample, so a wrong entry is a wrong picture;
/// `DoviCpuModelTests` and `DoviGpuEdgeCaseTests` compare the composed pixels with the CPU model.
@Suite(.offCooperativePoolOneLane)
struct DoviFrameTablesTests {

    private static func fixtureParams() throws -> DoviMetalParams {
        try DoviComposedFrameRpuTests.felNAL.withUnsafeBufferPointer { buf in
            let rpu = try #require(DoviRpuGuard.parse(buf.baseAddress!, buf.count))
            defer { dovi_rpu_free(rpu) }
            return try #require(DoviFelComposer.parseRpuParameters(rpu: rpu))
        }
    }

    /// Inverse linear-deadzone quantiser in Int64, reconstructing at the middle of the quantisation step.
    private static func referenceInverseNlq(_ n: DoviNlqParams, _ el: Int) -> Int32 {
        guard n.nlqMethod == .linear, n.nlqScale != 0 else { return 0 }
        let r = Int64(el) - Int64(n.nlqOffset)
        if r == 0 { return 0 }
        let magFp = (2 * abs(r) - 1) * Int64(n.nlqScale)
        var mag = (magFp + 2 * Int64(n.nlqThreshold)) >> Int64(n.nlqShift + 1)
        if n.vdrInMax > 0 && mag > Int64(n.vdrInMax) { mag = Int64(n.vdrInMax) }
        return Int32(r < 0 ? -mag : mag)
    }

    private static func nlqTable(_ p: DoviMetalParams) -> [Int32] {
        var table = [Int32](repeating: .min, count: 3 * 1024)
        table.withUnsafeMutableBufferPointer { DoviFelComposer.populateNlqLut(into: $0.baseAddress!, params: p) }
        return table
    }

    @Test("the inverse-NLQ table holds the reference value for every EL code of every component")
    func nlqTableMatchesTheReference() throws {
        let p = try Self.fixtureParams()
        let table = Self.nlqTable(p)
        for (component, nlq) in [p.nlqY, p.nlqCb, p.nlqCr].enumerated() {
            #expect(nlq.nlqScale != 0, "the fixture must carry a residual or the check proves nothing")
            for code in 0..<1024 {
                let expected = Self.referenceInverseNlq(nlq, code)
                #expect(table[component * 1024 + code] == expected, "component \(component) code \(code)")
            }
        }
    }

    @Test("the inverse-NLQ table follows an offset, a threshold and a ceiling")
    func nlqTableFollowsTheParameters() throws {
        var p = try Self.fixtureParams()
        p.nlqY.nlqOffset = 509
        p.nlqY.nlqThreshold = 40_000
        p.nlqCb.vdrInMax = 17
        let table = Self.nlqTable(p)
        for (component, nlq) in [p.nlqY, p.nlqCb, p.nlqCr].enumerated() {
            for code in 0..<1024 {
                #expect(table[component * 1024 + code] == Self.referenceInverseNlq(nlq, code), "component \(component) code \(code)")
            }
        }
        #expect(table[1024 + 1023] <= 17 && table[1024] >= -17, "the ceiling clamps")
    }

    @Test("with the residual off the table is left alone")
    func nlqTableUntouchedWithoutResidual() throws {
        var p = try Self.fixtureParams()
        p.flags.insert(.disableResidual)
        #expect(Self.nlqTable(p).allSatisfy { $0 == .min })
    }

    @Test("the MMR table holds every coefficient scaled by 2^-coef_shift, exactly")
    func mmrTableMatchesTheDefinition() throws {
        let p = try Self.fixtureParams()
        var table = [Float](repeating: .nan, count: DoviFelComposer.mmrTableCount)
        table.withUnsafeMutableBufferPointer { DoviFelComposer.populateMmrTable(into: $0.baseAddress!, params: p) }
        let piece = 1 + DoviMmrParams.coefficientsPerPiece
        var nonZero = 0
        for (component, mmr) in [p.mmrY, p.mmrCb, p.mmrCr].enumerated() {
            let scale = pow(2.0, -Double(mmr.coefShift))
            for pieceIndex in 0..<DoviMmrParams.maxPieces {
                let base = (component * DoviMmrParams.maxPieces + pieceIndex) * piece
                #expect(Double(table[base]) == Double(mmr.constant[pieceIndex]) * scale)
                for t in 0..<DoviMmrParams.coefficientsPerPiece {
                    let expected = Double(mmr.coef[pieceIndex][t]) * scale
                    #expect(Double(table[base + 1 + t]) == expected, "component \(component) piece \(pieceIndex) term \(t)")
                    if mmr.coef[pieceIndex][t] != 0 { nonZero += 1 }
                }
            }
        }
        #expect(nonZero > 0, "the fixture must carry MMR coefficients or the check proves nothing")
    }
}
#endif
