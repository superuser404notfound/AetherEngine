// Only with the DolbyVisionFelCurves trait: the fold is not built without it.
#if DolbyVisionFelCurves
import Testing
@testable import AetherEngine

@Suite("Hostile RPU values in the FEL curve fold")
struct HostileInputFelCurveTests {

    @Test("GPU-202: the residual saturates for any parameters instead of trapping")
    func residualSaturates() {
        let extremes: [Int64] = [Int64.min, -(1 << 40), -1, 0, 1, 2048 << 23, 1 << 40, Int64.max]
        for scale in extremes {
            for threshold in extremes {
                for vdrInMax in [Int64.min, 0, 1, 4095, Int64.max] {
                    for shift in [Int64(0), 11, 24] {
                        let nlq = FelNlq(offset: 0, scale: scale, threshold: threshold, vdrInMax: vdrInMax, shift: shift)
                        let table = nlq.table(elBits: 10)
                        #expect(table.count == 1024)
                    }
                }
            }
        }
    }

    @Test("GPU-202: the crafted RPU of the audit (slope 2048, ceiling 0) reads as in range, not as a trap")
    func craftedParameters() {
        let nlq = FelNlq(offset: 0, scale: Int64(2048) << 23, threshold: 0, vdrInMax: 0, shift: 11)
        #expect(nlq.residual(elCode: 1023) == Int32.max)
        #expect(nlq.residual(elCode: 0) == 0)
    }
}
#endif
