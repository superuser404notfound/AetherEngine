import Foundation
import Testing
@testable import AetherEngine

/// The grain templates and block offsets are built with their arithmetic written out over raw pointers,
/// because unoptimised (a host's Debug build) the plain version took the whole frame interval of a
/// 1080p 23.976 fps episode on an Apple TV 4K (A15). These tests hold the written-out loops to the plain
/// version, built on `AV1FilmGrainTables.random` and `round2` the way dav1d's C reads, for every lag,
/// several shifts and both chroma modes. The GPU digest tests then tie both to dav1d's own output.
@Suite("AV1 film grain tables match the reference arithmetic")
struct AV1FilmGrainTablesMatchTheReferenceArithmeticTests {

    typealias Tables = AV1FilmGrainTables

    static let coeffsY: [Int8] = (0..<24).map { Int8(($0 * 29) % 41 - 20) }
    static let coeffsC: [Int8] = (0..<25).map { Int8(($0 * 17) % 37 - 18) }

    /// `generate_grain_y_c` / `generate_grain_uv_c` as plainly as they read, for comparison.
    static func reference(width w: Int, height h: Int, seed: UInt32, shift: Int, lag: Int, coeffs: [Int8],
                          arShift: Int, luma: [Int]? = nil) -> [Int] {
        let gaussian = AV1GaussianSequence.values
        let lo = -(128 << (Tables.bitDepth - 8)), hi = (128 << (Tables.bitDepth - 8)) - 1
        var b = [Int](repeating: 0, count: w * h)
        var state = seed
        for i in 0..<(w * h) { b[i] = Tables.round2(Int(gaussian[Tables.random(11, &state)]), shift) }
        for y in 3..<h {
            for x in 3..<(w - 3) {
                var sum = 0
                var k = 0
                rows: for dy in -lag...0 {
                    for dx in -lag...lag {
                        if dx == 0 && dy == 0 {
                            if let luma {
                                let lw = Tables.lumaWidth
                                let lx = ((x - 3) << 1) + 3, ly = ((y - 3) << 1) + 3
                                let l = luma[ly * lw + lx] + luma[ly * lw + lx + 1]
                                    + luma[(ly + 1) * lw + lx] + luma[(ly + 1) * lw + lx + 1]
                                sum += Tables.round2(l, 2) * Int(coeffs[k])
                            }
                            break rows
                        }
                        sum += Int(coeffs[k]) * b[(y + dy) * w + x + dx]
                        k += 1
                    }
                }
                b[y * w + x] = min(max(b[y * w + x] + Tables.round2(sum, arShift), lo), hi)
            }
        }
        return b
    }

    @Test("luma and chroma templates", arguments: 0...3)
    func templates(lag: Int) {
        for shift in [2, 3, 5] {
            for arShift in [6, 9] {
                let seed: UInt32 = 0x1234 &+ UInt32(lag * 97 + shift * 13 + arShift)
                let luma = Tables.lumaTemplate(seed: seed, shift: shift, lag: lag, coeffs: Self.coeffsY, arShift: arShift)
                let lumaReference = Self.reference(width: Tables.lumaWidth, height: Tables.lumaHeight, seed: seed,
                                                   shift: shift, lag: lag, coeffs: Self.coeffsY, arShift: arShift)
                #expect(luma == lumaReference, "luma, lag \(lag) shift \(shift) ar \(arShift)")
                for addsLuma in [true, false] {
                    let chroma = Tables.chromaTemplate(seed: seed ^ 0xB524, shift: shift, lag: lag, coeffs: Self.coeffsC,
                                                       arShift: arShift, luma: luma, addsLuma: addsLuma)
                    let chromaReference = Self.reference(width: Tables.chromaWidth, height: Tables.chromaHeight,
                                                         seed: seed ^ 0xB524, shift: shift, lag: lag, coeffs: Self.coeffsC,
                                                         arShift: arShift, luma: addsLuma ? lumaReference : nil)
                    #expect(chroma == chromaReference, "chroma, lag \(lag) shift \(shift) ar \(arShift) luma \(addsLuma)")
                }
            }
        }
    }

    /// One 8-bit draw per 32x32 block, each block row from its own seed.
    @Test func blockOffsets() {
        let width = 1920, height = 1080
        let blockCols = (width + Tables.blockSize - 1) / Tables.blockSize
        let blockRows = (height + Tables.blockSize - 1) / Tables.blockSize
        for seed: UInt32 in [0, 0x7, 0xBEEF, 0xFFFF] {
            var expected: [UInt8] = []
            for row in 0..<blockRows {
                var state = seed
                state ^= UInt32(((row * 37 + 178) & 0xFF) << 8)
                state ^= UInt32((row * 173 + 105) & 0xFF)
                for _ in 0..<blockCols { expected.append(UInt8(Tables.random(8, &state))) }
            }
            #expect(Tables.blockOffsets(seed: seed, blockCols: blockCols, blockRows: blockRows) == expected, "seed \(seed)")
        }
    }
}
