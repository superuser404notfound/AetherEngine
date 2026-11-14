import Foundation
import Testing
@testable import AetherEngine

/// AE#957: the per-frame benchmark behind `aetherctl bench`. Small frames and few runs, so it only checks
/// that every case reports and that a report survives the JSON a baseline is kept in.
@Suite("Per-frame benchmark reports every case (AE#957)")
struct PerFrameBenchmarkReportsEveryCaseTests {

    @MainActor
    @Test func issue957EveryCaseReportsAndTheReportRoundTrips() throws {
        let report = AetherEngine.runPerFrameBenchmarks(iterations: 10, width: 64, height: 64)
        let names = report.results.map { $0.name }
        #expect(names == [
            "normalizer: frame already tagged",
            "normalizer: tag in place",
            "normalizer: owned copy",
            "renderer: sample buffer",
            "chain: pass-through, wall time",
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
        #expect(report.width == 64)

        let decoded = try JSONDecoder().decode(PerFrameBenchmarkReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
    }
}
