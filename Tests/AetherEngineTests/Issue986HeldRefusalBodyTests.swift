import Testing
import Foundation
@testable import AetherEngine

/// AE#986: CFNetwork content-sniffs a `text/plain` or untyped response and withholds the response
/// until 512 body bytes or the end of the connection. A refusal with a short body on a held
/// connection then reached the open as "unanswered", and the open failed after 40 s with
/// `status=0`. Every engine request turns sniffing off, so the status lands at once.
@Suite("AE#986 held refusal body", .serialized, .offCooperativePool)
struct Issue986HeldRefusalBodyTests {

    @Test("an engine request keeps sniffing off through later mutation")
    func sniffingStaysOff() {
        var request = URLRequest(engineURL: URL(string: "http://127.0.0.1/a.mkv")!, timeoutInterval: 7)
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        request.allHTTPHeaderFields = ["Authorization": "x"]
        request.httpMethod = "HEAD"
        #expect(!request.sniffsContent)
        #expect(request.timeoutInterval == 7)
        #expect(URLRequest(url: URL(string: "http://127.0.0.1/a.mkv")!).sniffsContent)
    }

    @Test("no engine source builds an origin request that sniffs")
    func everyRequestIsAnEngineRequest() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in files
            where file.pathExtension == "swift" && file.lastPathComponent != "URLRequest+ContentSniffing.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("URLRequest(url:") { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "use URLRequest(engineURL:) in \(offenders)")
    }

    @Test("a refusal with a held short body fails the open with its status in seconds",
          .timeLimit(.minutes(2)),
          arguments: [("text/plain", 500), (nil, 500), ("text/plain", 403)] as [(String?, Int)])
    func heldRefusalFailsFast(contentType: String?, status: Int) throws {
        let originMaybe = ThrottledOriginServer(totalSize: 64 * 1024 * 1024, respond: { _, _, _ in
            .statusWithHeldBody(status, contentType: contentType, body: 25)
        })
        let origin = try #require(originMaybe)
        defer { origin.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(origin.port)/film.mkv")!)
        defer { reader.markClosed(); reader.close() }

        let started = Date()
        var thrown: Error?
        do { try reader.open() } catch { thrown = error }
        let elapsed = Date().timeIntervalSince(started)

        #expect(thrown != nil, "the open succeeded against a refusal")
        #expect(elapsed < 5, "failed after \(elapsed)s; before AE#986 this took 40 s")
        if case .httpStatus(let code)? = thrown as? AVIOReaderError {
            #expect(code == status)
        } else {
            Issue.record("expected httpStatus(\(status)), got \(String(describing: thrown))")
        }
    }
}
