import Foundation
import AetherEngine

// MARK: - bench

/// Per-frame cost of the software path's work around each frame (`AetherEngine.runPerFrameBenchmarks`):
/// prints the table, writes the report as JSON, and against a baseline report fails on a regression.
/// `--compare base.json new.json` compares two reports without running anything, which is how numbers
/// from the Apple TV harness are checked.
func runBench(iterations: Int, jsonPath: String?, baselinePath: String?, tolerance: Double,
              compare: (String, String)?) -> Int32 {
    if let compare {
        guard let base = loadBenchReport(compare.0), let new = loadBenchReport(compare.1) else { return 1 }
        printBenchReport(new)
        return compareBenchReports(base: base, new: new, tolerance: tolerance)
    }
    let report = MainActor.assumeIsolated {
        AetherEngine.runPerFrameBenchmarks(iterations: iterations)
    }
    printBenchReport(report)
    if let jsonPath {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(report).write(to: URL(fileURLWithPath: jsonPath))
            print("report: \(jsonPath)")
        } catch {
            print("ERROR: could not write \(jsonPath): \(error)")
            return 1
        }
    }
    guard let baselinePath else { return 0 }
    guard let base = loadBenchReport(baselinePath) else { return 1 }
    return compareBenchReports(base: base, new: report, tolerance: tolerance)
}

/// A case regresses when its median grows by more than `tolerance` (a fraction) and by more than this
/// many microseconds. On the A12 Apple TV the same build's in-place tagging measured 18 us in one run and
/// 48 us in the next (the thread on another core), and 50 us is 0.3% of a 59.94 fps frame.
let benchAbsoluteFloorMicroseconds = 50.0

func compareBenchReports(base: PerFrameBenchmarkReport, new: PerFrameBenchmarkReport, tolerance: Double) -> Int32 {
    if base.device != new.device || base.width != new.width || base.height != new.height {
        print("NOTE: baseline is \(base.device) \(base.width)x\(base.height), this run \(new.device) "
              + "\(new.width)x\(new.height); compare like with like")
    }
    var regressions = 0
    print(benchColumn("case") + " " + benchNumber("base us") + " " + benchNumber("now us") + "  change")
    for result in new.results where result.iterations > 0 {
        guard let old = base.results.first(where: { $0.name == result.name }), old.iterations > 0 else {
            print("\(result.name): no baseline")
            continue
        }
        let change = (result.medianMicroseconds - old.medianMicroseconds) / max(old.medianMicroseconds, 0.001)
        let regressed = change > tolerance
            && result.medianMicroseconds - old.medianMicroseconds > benchAbsoluteFloorMicroseconds
        if regressed { regressions += 1 }
        print(benchColumn(result.name) + " " + benchNumber(old.medianMicroseconds) + " "
              + benchNumber(result.medianMicroseconds) + String(format: "  %+.0f%%", change * 100)
              + (regressed ? "  REGRESSION" : ""))
    }
    print(regressions == 0 ? "verdict: no regression beyond \(Int(tolerance * 100))%"
                           : "verdict: \(regressions) regression(s) beyond \(Int(tolerance * 100))%")
    return regressions == 0 ? 0 : 1
}

func printBenchReport(_ report: PerFrameBenchmarkReport) {
    print("per-frame benchmark: \(report.device), \(report.os), \(report.width)x\(report.height)")
    print(benchColumn("case") + ["min", "median", "p95", "p99", "max"].map { " " + benchNumber($0) }.joined())
    for r in report.results {
        if r.iterations == 0 {
            print("\(r.name): skipped, \(r.note ?? "")")
            continue
        }
        let numbers = [r.minMicroseconds, r.medianMicroseconds, r.p95Microseconds, r.p99Microseconds,
                       r.maxMicroseconds]
        print(benchColumn(r.name) + numbers.map { " " + benchNumber($0) }.joined()
              + (r.note.map { "  (\($0))" } ?? ""))
    }
    print("(microseconds per frame; a frame lasts 41708 us at 23.976 fps, 16683 us at 59.94)")
}

private func benchColumn(_ text: String) -> String {
    text.count >= 40 ? text : text.padding(toLength: 40, withPad: " ", startingAt: 0)
}

private func benchNumber(_ value: Double) -> String { benchNumber(String(format: "%.1f", value)) }

private func benchNumber(_ text: String) -> String {
    String(repeating: " ", count: max(0, 9 - text.count)) + text
}

private func loadBenchReport(_ path: String) -> PerFrameBenchmarkReport? {
    do {
        return try JSONDecoder().decode(PerFrameBenchmarkReport.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        print("ERROR: cannot read the benchmark report \(path): \(error)")
        return nil
    }
}
