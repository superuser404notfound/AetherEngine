import Foundation
import AetherEngine

/// Reads `label<TAB>url` lines from stdin and prints `label<TAB>FEL|MEL|none|error: ...` for each, in
/// input order, probing `parallel` sources at a time. Each probe walks only to the first RPU
/// (`AetherEngine.probeDolbyVisionEnhancementLayer`), so a library's Profile 7 copies classify in seconds.
func runElType(parallel: Int) -> Int32 {
    var input: [(label: String, url: URL)] = []
    while let line = readLine() {
        let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        let url = parts[1].contains("://") ? URL(string: parts[1]) : URL(fileURLWithPath: parts[1])
        if let url { input.append((parts[0], url)) }
    }
    let rows = input

    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String]
        init(count: Int) { values = Array(repeating: "", count: count) }
        func set(_ i: Int, _ value: String) { lock.withLock { values[i] = value } }
        var all: [String] { lock.withLock { values } }
    }
    let answers = Answers(count: rows.count)
    let gate = DispatchSemaphore(value: max(1, parallel))
    DispatchQueue.concurrentPerform(iterations: rows.count) { i in
        gate.wait()
        defer { gate.signal() }
        do {
            answers.set(i, try AetherEngine.probeDolbyVisionEnhancementLayer(url: rows[i].url)?.rawValue ?? "none")
        } catch {
            answers.set(i, "error: \(error)")
        }
    }
    for (row, answer) in zip(rows, answers.all) { print("\(row.label)\t\(answer)") }
    return 0
}
