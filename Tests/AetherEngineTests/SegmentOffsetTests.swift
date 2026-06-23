import Foundation
import Testing
@testable import AetherEngine

@Suite("HLSSegmentProducer.segmentOffset binary search")
struct SegmentOffsetTests {

    /// Reference implementation: the original linear "first i where absolute < boundaries[i+1]" scan.
    private func reference(_ absolute: Int64, _ b: [Int64]) -> Int {
        guard !b.isEmpty else { return 0 }
        for i in 0..<(b.count - 1) where absolute < b[i + 1] { return i }
        return max(0, b.count - 2)
    }

    @Test("Empty boundaries returns 0")
    func empty() {
        #expect(HLSSegmentProducer.segmentOffset(forAbsolutePts: 1234, boundaries: []) == 0)
    }

    @Test("Single boundary always maps to offset 0")
    func single() {
        #expect(HLSSegmentProducer.segmentOffset(forAbsolutePts: -10, boundaries: [100]) == 0)
        #expect(HLSSegmentProducer.segmentOffset(forAbsolutePts: 100, boundaries: [100]) == 0)
        #expect(HLSSegmentProducer.segmentOffset(forAbsolutePts: 9999, boundaries: [100]) == 0)
    }

    @Test("Exact boundary, below-first, and past-last edges match the reference")
    func edges() {
        let b: [Int64] = [0, 1000, 2000, 3000, 4000]
        #expect(HLSSegmentProducer.segmentOffset(forAbsolutePts: -1, boundaries: b) == reference(-1, b))
        #expect(HLSSegmentProducer.segmentOffset(forAbsolutePts: 0, boundaries: b) == reference(0, b))
        #expect(HLSSegmentProducer.segmentOffset(forAbsolutePts: 1000, boundaries: b) == reference(1000, b))   // exact boundary
        #expect(HLSSegmentProducer.segmentOffset(forAbsolutePts: 1500, boundaries: b) == reference(1500, b))
        #expect(HLSSegmentProducer.segmentOffset(forAbsolutePts: 3999, boundaries: b) == reference(3999, b))
        #expect(HLSSegmentProducer.segmentOffset(forAbsolutePts: 4000, boundaries: b) == reference(4000, b))   // last boundary
        #expect(HLSSegmentProducer.segmentOffset(forAbsolutePts: 999999, boundaries: b) == reference(999999, b)) // past last
    }

    @Test("Binary search matches the linear reference across a deterministic sweep")
    func sweepEquivalence() {
        // Several boundary layouts (uniform, irregular, large) crossed with a dense set of probe points.
        let layouts: [[Int64]] = [
            [0, 1000, 2000, 3000, 4000, 5000],
            [0, 480, 960, 1440, 1920, 2400, 2880],            // ~480-tick segments
            [500, 1500, 4500, 4501, 9000],                    // irregular incl. adjacent boundaries
            Array(stride(from: Int64(0), through: 200_000, by: 4096)),  // long VOD-like
        ]
        for b in layouts {
            // Probe every boundary and the midpoints / +-1 around them, plus far out-of-range values.
            var probes: [Int64] = [Int64.min / 2, -5, -1, 999_999_999]
            for x in b { probes.append(x - 1); probes.append(x); probes.append(x + 1) }
            for i in 0..<(b.count - 1) { probes.append((b[i] + b[i + 1]) / 2) }
            for p in probes {
                let got = HLSSegmentProducer.segmentOffset(forAbsolutePts: p, boundaries: b)
                #expect(got == reference(p, b), "mismatch at pts=\(p) for boundaries=\(b)")
            }
        }
    }
}
