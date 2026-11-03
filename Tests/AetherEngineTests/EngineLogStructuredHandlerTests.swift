import Foundation
import Testing
@testable import AetherEngine

/// AE#897: a host that files lines by subsystem gets the category the engine wrote the line under,
/// the same redacted text `handler` gets, and no `.verbose` lines.
///
/// No other test touches `structuredHandler`, so this suite owns it; lines from tests logging in
/// parallel still arrive, hence the marker filter.
@Suite("EngineLog structured handler")
struct EngineLogStructuredHandlerTests {

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(String, EngineLog.Category, EngineLog.Level)] = []
        func append(_ entry: (String, EngineLog.Category, EngineLog.Level)) {
            lock.lock(); storage.append(entry); lock.unlock()
        }
        func matching(_ marker: String) -> [(String, EngineLog.Category, EngineLog.Level)] {
            lock.lock(); defer { lock.unlock() }
            return storage.filter { $0.0.contains(marker) }
        }
    }

    @Test("receives the category, the info level and the redacted line, and no verbose lines")
    func deliversCategoryAndLevel() {
        let marker = "structured-\(UUID().uuidString)"
        let collector = Collector()
        let plain = EngineLogCapture()
        defer { plain.end() }
        EngineLog.structuredHandler = { collector.append(($0, $1, $2)) }
        defer { EngineLog.structuredHandler = nil }

        EngineLog.emit("\(marker) engine")
        EngineLog.emit("\(marker) demux http://h/v?api_key=secret123", category: .demux)
        EngineLog.emit("\(marker) verbose", category: .session, level: .verbose)

        let got = collector.matching(marker)
        #expect(got.map(\.1) == [.engine, .demux])
        #expect(got.allSatisfy { $0.2 == .info })
        #expect(got.map(\.0) == plain.matching(marker))
        #expect(!got.contains { $0.0.contains("secret123") })
    }
}
