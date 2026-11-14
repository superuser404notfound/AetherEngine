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

    private static func report(_ cases: [(String, Int, Double)]) -> PerFrameBenchmarkReport {
        PerFrameBenchmarkReport(device: "test", os: "test", width: 64, height: 64, results: cases.map { name, runs, median in
            PerFrameBenchmarkResult(name: name, iterations: runs, minMicroseconds: median, medianMicroseconds: median,
                                    p95Microseconds: median, p99Microseconds: median, maxMicroseconds: median,
                                    note: runs == 0 ? "the frame chain needs OS 26" : nil)
        })
    }

    /// A case that ran in the baseline and is skipped or missing now regresses: a broken chain reports
    /// its cases as skipped, and the gate must not pass then.
    @Test func issue957ACaseThatStoppedRunningIsARegression() {
        let base = Self.report([("chain", 300, 4000), ("sei", 300, 12), ("copy", 300, 7000)])
        let now = Self.report([("chain", 0, 0), ("sei", 300, 12)])
        let found = now.regressions(against: base, tolerance: 0.2)
        #expect(found.map(\.name) == ["chain", "copy"])
        #expect(found.first?.reason.hasPrefix("ran in the baseline, skipped now") == true)
        #expect(found.last?.reason == "ran in the baseline, missing now")
    }

    @Test func issue957ASlowerMedianRegressesOnlyPastBothBounds() {
        let base = Self.report([("small", 300, 18), ("big", 300, 4000)])
        // +167% but only +30 us: under the floor. +25% and +1000 us: a regression.
        let now = Self.report([("small", 300, 48), ("big", 300, 5000)])
        #expect(now.regressions(against: base, tolerance: 0.2).map(\.name) == ["big"])
        #expect(now.regressions(against: base, tolerance: 0.3).isEmpty)
        // A case new in this run, with no baseline, is not a regression.
        #expect(Self.report([("new", 300, 1)]).regressions(against: Self.report([]), tolerance: 0.2).isEmpty)
    }
}
