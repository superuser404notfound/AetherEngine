import Foundation
import Testing

/// AE#998 (hourami): stopping after a long watch held main 0.4 to 0.6 s inside `replaceCurrentItem`.
/// The time was not AVFoundation but the Swift overlay decoding the typed KVO change: with `.new` (or
/// `.old`) requested, `NSKeyValueObservedChange` casts the raw value through `_castForKVO` before the
/// closure runs, whether or not the closure reads it, and that cast hit a conformance-cache miss that
/// scans every conformance record in the process.
///
/// Every observer reads the observed object instead, so no engine observer asks for a decoded value.
/// The invariant is about how the observers are written, so the test is structural.
struct Issue998KVOReadsTheObjectTests {

    private func sources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return try walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test("no KVO observer requests a decoded old or new value")
    func noObserverDecodesTheChange() throws {
        let files = try sources()
        #expect(!files.isEmpty)
        for (name, text) in files {
            for line in text.split(separator: "\n") where line.contains(".observe(\\.") || line.contains("options: [") {
                let options = line.range(of: "options: [").map { String(line[$0.upperBound...].prefix(while: { $0 != "]" })) }
                guard let options else { continue }
                #expect(!options.contains(".new"), "\(name): \(line.trimmingCharacters(in: .whitespaces))")
                #expect(!options.contains(".old"), "\(name): \(line.trimmingCharacters(in: .whitespaces))")
            }
            #expect(!text.contains("change.newValue"), "\(name) reads a decoded KVO value")
            #expect(!text.contains("change.oldValue"), "\(name) reads a decoded KVO value")
        }
    }
}
