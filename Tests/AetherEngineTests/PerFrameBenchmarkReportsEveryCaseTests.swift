import Foundation
import Testing
@testable import AetherEngine

/// AE#957: the per-frame benchmark behind `aetherctl bench`. Small frames and few runs, so it only checks
/// that every case reports and that a report survives the JSON a baseline is kept in. The frame chain cases
/// are skipped: they compile the chain's kernels and wait on the GPU, on the main actor, and `FrameChainTests`
/// covers the chain with the guards that needs.
@Suite("Per-frame benchmark reports every case (AE#957)", .timeLimit(.minutes(1)))
struct PerFrameBenchmarkReportsEveryCaseTests {

    @MainActor
    @Test func issue957EveryCaseReportsAndTheReportRoundTrips() throws {
        let report = PerFrameBenchmark(iterations: 10, width: 64, height: 64, includesChain: false).run()
        let names = report.results.map { $0.name }
        #expect(names == [
            "normalizer: frame already tagged",
            "normalizer: tag in place",
            "normalizer: owned copy",
            "renderer: sample buffer",
            "chain: pass-through, wall time",
            "chain: two passes through RGB, wall time",
            "sei: HDR10 scan of a 250 KB key frame",
        ])
        // A case either ran with ordered numbers or was skipped with a reason.
        let consistent = report.results.allSatisfy { result in
            result.iterations == 0
                ? result.note != nil
                : result.minMicroseconds <= result.medianMicroseconds
                    && result.medianMicroseconds <= result.p99Microseconds
                    && result.p99Microseconds <= result.maxMicroseconds
        }
        #expect(consistent)
        let chainSkipped = report.results.filter { $0.name.hasPrefix("chain:") }.allSatisfy { $0.iterations == 0 }
        #expect(chainSkipped)
        #expect(report.width == 64)

        let decoded = try JSONDecoder().decode(PerFrameBenchmarkReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
    }
}
