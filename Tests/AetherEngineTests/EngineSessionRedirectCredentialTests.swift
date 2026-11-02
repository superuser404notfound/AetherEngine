import Foundation
import Testing
@testable import AetherEngine

/// Audit NET-108: URLSession's own redirect carries every custom header except `Authorization` to the
/// new host (measured: `X-Emby-Token`, `Cookie`, `Range` and `Referer` all arrived at a cross-host
/// target). The engine's owned sessions had no redirect handler, so a 302 on a playlist, segment, key
/// or disc range took the host's token wherever it pointed. The session-level delegate now applies the
/// same rule a per-task redirect handler does.
@Suite("Engine sessions keep credentials off a redirect target", .serialized, .timeLimit(.minutes(2)))
struct EngineSessionRedirectCredentialTests {

    private let credentialFields = ["X-Emby-Token": "SOURCE-ONLY", "Cookie": "sid=SOURCE-ONLY",
                                    "Authorization": "Bearer SOURCE-ONLY"]

    private func request(to url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in credentialFields { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.setValue("https://portal.example/", forHTTPHeaderField: "Referer")
        return request
    }

    private func redirectingPair() throws -> (source: ThrottledOriginServer, target: ThrottledOriginServer) {
        let target = try #require(ThrottledOriginServer(totalSize: 1024))
        let targetPort = target.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: 1024,
            respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(targetPort)/cdn/seg.ts") })
        let source = try #require(sourceMaybe)
        return (source, target)
    }

    private func expectScrubbed(_ seen: [String: String], sourceLocation: SourceLocation = #_sourceLocation) {
        for field in credentialFields.keys {
            #expect(seen[field.lowercased()] == nil, "\(field) reached the redirect target",
                    sourceLocation: sourceLocation)
        }
        #expect(seen["range"] == "bytes=0-1023", sourceLocation: sourceLocation)
        #expect(seen["referer"] == "https://portal.example/", sourceLocation: sourceLocation)
    }

    @Test("a data(for:) fetch on an engine session arrives at a cross-origin target without credentials")
    func sessionLevelFetch() async throws {
        let (source, target) = try redirectingPair()
        defer { source.stop(); target.stop() }
        let session = URLSession(
            configuration: .ephemeral, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let url = try #require(URL(string: "http://127.0.0.1:\(source.port)/Videos/seg.ts"))
        _ = try await session.data(for: request(to: url))

        let seen = try #require(target.requestHeaders.last)
        expectScrubbed(seen)
    }

    /// The relay's `UpstreamPump` shape: a per-task delegate that answers the body callbacks and has
    /// no redirect method of its own, so the session-level one has to answer for it.
    @Test("a task delegate without a redirect method falls back to the session's rule")
    func taskDelegateWithoutRedirect() async throws {
        let (source, target) = try redirectingPair()
        defer { source.stop(); target.stop() }
        let session = URLSession(
            configuration: .ephemeral, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let url = try #require(URL(string: "http://127.0.0.1:\(source.port)/Videos/seg.ts"))
        _ = try await session.data(for: request(to: url), delegate: BodyOnlyTaskDelegate())

        let seen = try #require(target.requestHeaders.last)
        expectScrubbed(seen)
    }

    @Test("a same-origin hop and an http to https upgrade keep the credentials, a local downgrade loses them, a public one is upgraded",
          arguments: [
              ("https://media.example/a.m3u8", "https://media.example/b.m3u8", true),
              ("http://media.example:8096/a.m3u8", "https://media.example:8920/a.m3u8", true),
              // A local name keeps the downgrade as sent; a public one is asked for over https
              // (`RedirectHeaderPolicy.upgradedDowngrade`), which makes it the same origin again.
              ("https://media.local/a.m3u8", "http://media.local/a.m3u8", false),
              ("https://media.example/a.m3u8", "http://media.example/a.m3u8", true),
              ("https://media.example/a.m3u8", "https://cdn.other/a.m3u8", false),
              ("https://media.example/a.m3u8", "https://media.example:8443/a.m3u8", false),
          ])
    func redirectDecision(from: String, to: String, keeps: Bool) async throws {
        let fromURL = try #require(URL(string: from))
        let toURL = try #require(URL(string: to))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request(to: fromURL))
        // What URLSession hands the delegate: the new URL with the old request's headers copied over.
        var carried = request(to: toURL)
        carried.setValue(nil, forHTTPHeaderField: "Authorization")
        let response = try #require(HTTPURLResponse(
            url: fromURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": to]))

        let box = RequestBox()
        EngineTLS.sessionDelegate.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: carried,
            completionHandler: { box.set($0) })
        let next = try #require(box.get())

        for field in ["X-Emby-Token", "Cookie"] {
            #expect((next.value(forHTTPHeaderField: field) != nil) == keeps, "\(field) \(from) -> \(to)")
        }
        #expect(next.value(forHTTPHeaderField: "Range") == "bytes=0-1023")
        #expect(next.value(forHTTPHeaderField: "Referer") == "https://portal.example/")
    }

    /// The system-trust probe must keep running without the host's evaluator, which is what it
    /// measures, while still scrubbing a redirect like every other engine session.
    @Test("the redirect-only delegate answers no trust challenge")
    func redirectOnlyDelegateHasNoChallengeMethod() {
        let delegate: NSObject = EngineTLS.redirectDelegate
        let challenge = #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:))
        #expect(!delegate.responds(to: challenge))
        #expect(EngineTLS.sessionDelegate.responds(to: challenge))
    }
}

private final class BodyOnlyTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {}
}

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?
    func set(_ request: URLRequest?) { lock.withLock { value = request } }
    func get() -> URLRequest? { lock.withLock { value } }
}
