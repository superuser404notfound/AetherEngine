#if DualLayerDolbyVision
import Foundation
@_spi(Diagnostics) import AetherEngine

/// Reads `label<TAB>url` lines from stdin and measures each title's enhancement layer at sampled keyframes
/// (`AetherEngine.doviResidualSurvey`). Prints a header, then one TSV row per title as soon as it finishes
/// (so rows arrive in completion order, not input order):
/// label, measured frames, residual-off frames, failures, mean |residual| (12-bit codes), mean signed
/// residual, p99 |residual| (median over frames, then the max), share of pixels moved >= one 10-bit step,
/// mean nits change at the average level, p99 nits change at the peak (median, max), the timestamp of the
/// frame with the largest highlight change, and the seconds the title took.
func runElSurvey(parallel: Int, points: Int) -> Int32 {
    var input: [(label: String, url: URL)] = []
    while let line = readLine() {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let url = parts[1].contains("://") ? URL(string: parts[1]) : URL(fileURLWithPath: parts[1])
        if let url { input.append((parts[0], url)) }
    }
    let rows = input
    let out = NSLock()
    @Sendable func emit(_ line: String) { out.withLock { print(line); fflush(stdout) } }

    emit(["label", "frames", "off", "fail", "mean_abs", "mean_signed", "p99_med", "p99_max", "visible",
          "avg_nits", "hi_nits_med", "hi_nits_max", "peak_s", "secs"].joined(separator: "\t"))
    let gate = DispatchSemaphore(value: max(1, parallel))
    DispatchQueue.concurrentPerform(iterations: rows.count) { i in
        gate.wait()
        defer { gate.signal() }
        let start = Date()
        do {
            let r = try AetherEngine.doviResidualSurvey(url: rows[i].url, points: points)
            let f = r.frames
            func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
            func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
            let peak = f.max { $0.highlightNits < $1.highlightNits }
            emit([
                rows[i].label, "\(f.count)", "\(r.residualOffFrames)", "\(r.failures)",
                String(format: "%.2f", mean(f.map(\.meanAbs))), String(format: "%+.2f", mean(f.map(\.meanSigned))),
                String(format: "%.0f", median(f.map { Double($0.p99Abs) })), "\(f.map(\.p99Abs).max() ?? 0)",
                String(format: "%.3f", mean(f.map(\.visibleFraction))),
                String(format: "%.2f", mean(f.map(\.averageLevelNits))),
                String(format: "%.1f", median(f.map(\.highlightNits))), String(format: "%.1f", peak?.highlightNits ?? 0),
                peak.map { String(format: "%.0f", $0.seconds) } ?? "-",
                String(format: "%.1f", Date().timeIntervalSince(start)),
            ].joined(separator: "\t"))
        } catch {
            emit("\(rows[i].label)\terror: \(error)")
        }
    }
    return 0
}
#endif
