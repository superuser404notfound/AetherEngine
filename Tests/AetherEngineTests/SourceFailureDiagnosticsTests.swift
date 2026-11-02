import Foundation
import Testing
@testable import AetherEngine

@Suite("Source failure diagnostics", .serialized)
struct SourceFailureDiagnosticsTests {
    private final class CorrelationEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [SourceNetworkDiagnostics.Event] = []
        func add(_ value: SourceNetworkDiagnostics.Event) { lock.withLock { values.append(value) } }
        func snapshot() -> [SourceNetworkDiagnostics.Event] { lock.withLock { values } }
    }

    /// Feed the real task delegate a response before failing the transport. URLProtocol buffers
    /// its response until completion, so its ordinary client API cannot model a mid-body failure.
    private final class FailedPartialResponse: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let task = task as? URLSessionDataTask,
                  let delegate = task.delegate as? URLSessionDataDelegate else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 0-4095/*", "Content-Length": "4096"])!
            delegate.urlSession?(.shared, dataTask: task, didReceive: response) { _ in
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        }
        override func stopLoading() {}
    }

    @Test("An abandoned ranged failure does not override a streaming replacement",
          .timeLimit(.minutes(3)), arguments: [200, 403])
    func retiredConnectionDoesNotFailStreamingReplacement(status: Int) async throws {
        let body = Data(repeating: 0x47, count: 8192)
        let server = try #require(ScriptedOriginServer { request in
            if request.range != nil || request.method == "HEAD" {
                return .init(status: 200, declaredLength: nil, close: true)
            }
            return .init(status: status, declaredLength: nil, close: true,
                         body: status == 200 ? body : nil)
        })
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/\(UUID().uuidString).bin")!
        let events = CorrelationEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { event in
            guard event.originalURL == url else { return }
            events.add(event)
        }
        defer { SourceNetworkDiagnostics.handler = previous }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailedPartialResponse.self]
        let session = URLSession(configuration: configuration, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let reader = AVIOReader(url: url, boundedInitialFetch: 4096, persistentRequestSession: session)
        let result = try await withTaskCancellationHandler {
            try await ProbeTestJob {
                defer { reader.markClosed(); reader.close() }
                try reader.open()
                var prefix = Data(count: 16)
                let count = prefix.withUnsafeMutableBytes {
                    reader.read(into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), size: 16)
                }
                return (reader.isSeekable, count > 0 ? Data(prefix.prefix(Int(count))) : Data())
            }.outcome()
        } onCancel: {
            reader.markClosed()
            server.stop()
        }
        if status == 200 {
            let (seekable, prefix) = try result.get()
            #expect(!seekable)
            #expect(prefix == body.prefix(16))
        } else {
            #expect(throws: AVIOReaderError.httpStatus(status)) { try result.get() }
        }
        #expect(events.snapshot().contains {
            $0.role == .persistentRead && $0.phase == .completed && $0.urlErrorCode == NSURLErrorNetworkConnectionLost
        })
        #expect(events.snapshot().contains {
            $0.role == .persistentRead && $0.phase == .response && $0.status == 206
        })
        #expect(server.requests.contains { $0.method == "GET" && $0.range == nil })
    }

    @Test("A delayed old HLS request keeps its attempt after a retry and a different playback", .timeLimit(.minutes(3)))
    func delayedHLSRequestKeepsOriginalAttempt() async throws {
        let events = CorrelationEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { events.add($0) }
        defer { SourceNetworkDiagnostics.handler = previous }
        let releaseOld = DispatchSemaphore(value: 0)
        let server = try #require(ScriptedOriginServer { request in
            // ScriptedOriginServer runs each reply on its own detached serving thread.
            if request.range == "bytes=0-0" { releaseOld.wait() }
            return .init(status: 200, declaredLength: 0)
        })
        defer { releaseOld.signal(); server.stop() }
        let session = URLSession(configuration: .ephemeral, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let playbackID = UUID()
        let old = SourceNetworkDiagnostics.Context(playbackID: playbackID, attemptID: UUID())
        let retry = SourceNetworkDiagnostics.Context(playbackID: playbackID, attemptID: UUID())
        let replacement = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let baseURL = URL(string: "http://127.0.0.1:\(server.port)/\(UUID().uuidString)/")!
        let oldURL = baseURL.appendingPathComponent("old.m3u8")
        let retryURL = baseURL.appendingPathComponent("retry.m3u8")
        let replacementURL = baseURL.appendingPathComponent("replacement.m3u8")
        let fixtureURLs = [oldURL, retryURL, replacementURL]
        var originalRequest = URLRequest(url: oldURL)
        originalRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let oldRequest = SourceNetworkDiagnostics.request(originalRequest, context: old)
        let oldFetch = Task {
            // The request was already created for the outgoing attempt. Even
            // a newer ambient context at fetch time must not replace its owner.
            try await SourceNetworkDiagnostics.$context.withValue(retry) {
                try await BoundedPlaylistFetch.data(for: oldRequest, session: session, limit: 1_024)
            }
        }
        defer { oldFetch.cancel() }
        try await waitFor { server.requests.contains { $0.range == "bytes=0-0" } }
        let retryRequest = SourceNetworkDiagnostics.request(URLRequest(url: retryURL), context: retry)
        _ = try await SourceNetworkDiagnostics.$context.withValue(replacement) {
            try await BoundedPlaylistFetch.data(for: retryRequest, session: session, limit: 1_024)
        }
        let replacementRequest = SourceNetworkDiagnostics.request(URLRequest(url: replacementURL), context: replacement)
        _ = try await BoundedPlaylistFetch.data(for: replacementRequest, session: session, limit: 1_024)
        #expect(!events.snapshot().contains { $0.originalURL == oldURL && $0.phase == .completed })
        releaseOld.signal()
        let (_, oldResponse) = try await oldFetch.value
        #expect((oldResponse as? HTTPURLResponse)?.statusCode == 200)

        // Other suites can emit the same phase and role through the process-wide handler.
        let unrelatedURL = baseURL.appendingPathComponent("unrelated.m3u8")
        SourceNetworkDiagnostics.Trace(role: .hlsPlaylist, context: replacement)
            .record(.completed, originalURL: unrelatedURL, url: unrelatedURL, status: 200)
        let completed = events.snapshot().filter {
            $0.phase == .completed && $0.role == .hlsPlaylist
                && $0.originalURL.map { fixtureURLs.contains($0) } == true
        }
        #expect(completed.map(\.originalURL) == [retryURL, replacementURL, oldURL])
        #expect(Set(completed.map(\.requestID)).count == 3)
        for (url, expected) in [(oldURL, old), (retryURL, retry), (replacementURL, replacement)] {
            let requestEvents = events.snapshot().filter { $0.originalURL == url }
            #expect(requestEvents.contains { $0.phase == .response })
            #expect(requestEvents.contains { $0.phase == .completed })
            #expect(requestEvents.allSatisfy { $0.context == expected })
            #expect(Set(requestEvents.map(\.requestID)).count == 1)
        }
    }

    @Test("Playlist segment and key requests preserve the reader's original context and headers")
    func hlsRequestsKeepCapturedContextAndHeaders() throws {
        let original = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let replacement = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let baseURL = URL(string: "https://origin.example/live/main.m3u8")!
        let headers = ["Authorization": "Bearer private-fixture-token", "User-Agent": "fixture-agent"]
        let reader = SourceNetworkDiagnostics.$context.withValue(original) {
            HLSLiveIngestReader(playlistURL: baseURL, httpHeaders: headers)
        }
        defer { reader.close() }
        try SourceNetworkDiagnostics.$context.withValue(replacement) {
            let fresh = try #require(reader.makeFreshMainReader())
            defer { fresh.close() }
            for path in ["main.m3u8", "segment.ts", "encryption.key"] {
                let url = baseURL.deletingLastPathComponent().appendingPathComponent(path)
                for owner in [reader, fresh] {
                    let request = owner.makeRequest(url)
                    #expect(SourceNetworkDiagnostics.context(for: request) == original)
                    #expect(request.url == url)
                    #expect(request.httpMethod == "GET")
                    #expect(request.allHTTPHeaderFields?.count == headers.count)
                    for (name, value) in headers { #expect(request.value(forHTTPHeaderField: name) == value) }
                    #expect(request.value(forHTTPHeaderField: "playback_id") == nil)
                    #expect(request.value(forHTTPHeaderField: "attempt_id") == nil)
                }
            }
            let crossOrigin = reader.makeRequest(URL(string: "https://cdn.example/segment.ts")!)
            #expect(SourceNetworkDiagnostics.context(for: crossOrigin) == original)
            #expect(crossOrigin.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    @Test("Trace captures once and an unbound request cannot borrow an ambient playback")
    func tracesFreezeContextAndKeepUnboundRequestsUnattributed() throws {
        let events = CorrelationEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { events.add($0) }
        defer { SourceNetworkDiagnostics.handler = previous }
        let original = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let replacement = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let url = URL(string: "https://origin.example/\(UUID().uuidString)/segment.ts")!
        let trace = SourceNetworkDiagnostics.$context.withValue(original) {
            SourceNetworkDiagnostics.Trace(role: .hlsSegment)
        }
        let tagged = SourceNetworkDiagnostics.request(URLRequest(url: url), context: original)
        let unbound = SourceNetworkDiagnostics.request(tagged, context: nil)
        #expect(SourceNetworkDiagnostics.context(for: tagged) == original)
        #expect(SourceNetworkDiagnostics.context(for: unbound) == nil)
        SourceNetworkDiagnostics.$context.withValue(replacement) {
            trace.record(.response, originalURL: url, url: url, status: 200)
            trace.record(.completed, originalURL: url, url: url, status: 200)
            let unboundTrace = SourceNetworkDiagnostics.Trace(role: .hlsKey,
                context: SourceNetworkDiagnostics.context(for: unbound))
            unboundTrace.record(.completed, originalURL: url, url: url, status: 200)
        }
        let unrelatedURL = url.deletingLastPathComponent().appendingPathComponent("unrelated.ts")
        SourceNetworkDiagnostics.Trace(role: .hlsSegment, context: original)
            .record(.completed, originalURL: unrelatedURL, url: unrelatedURL, status: 200)
        let captured = events.snapshot().filter { $0.originalURL == url }
        #expect(captured.count == 3)
        #expect(captured[0].context == original && captured[1].context == original)
        #expect(captured[0].requestID == captured[1].requestID)
        #expect(captured[2].context == nil)
        #expect(captured[2].requestID != captured[0].requestID)
    }

    @Test("A segment carriage probe completes once with its captured context", .timeLimit(.minutes(3)), arguments: [200, 403])
    func carriageProbeCompletesWithCapturedContext(status: Int) async throws {
        let events = CorrelationEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { events.add($0) }
        defer { SourceNetworkDiagnostics.handler = previous }
        let body = Data([0, 1, 2, 3])
        let server = try #require(ScriptedOriginServer { _ in
            .init(status: status, declaredLength: Int64(body.count), close: true, body: body)
        })
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let original = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let replacement = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let url = URL(string: "http://127.0.0.1:\(server.port)/head.ts")!
        do {
            _ = try await SourceNetworkDiagnostics.$context.withValue(replacement) {
                try await HLSCarriageProbe.classifySegmentHead(
                    url: url, httpHeaders: [:], session: session, diagnosticContext: original)
            }
            #expect(status == 200)
        } catch {
            #expect(error as? HLSIngestError == .playlistUnreachable(status: status))
            #expect(status == 403)
        }
        let captured = events.snapshot().filter { $0.originalURL == url }
        #expect(captured.filter { $0.phase == .response }.count == 1)
        #expect(captured.filter { $0.phase == .completed }.count == 1)
        #expect(captured.allSatisfy { $0.context == original && $0.role == .hlsSegment && $0.status == status })
        #expect(Set(captured.map(\.requestID)).count == 1)
    }

    @Test("Held HTTP bodies complete once after consumption and keep their captured owner",
          .timeLimit(.minutes(3)), arguments: [200, 403])
    func heldBodyCompletion(status: Int) async throws {
        let payload = Data(repeating: 0x47, count: 4096)
        let server = try #require(ScriptedOriginServer { _ in
            .init(status: status, declaredLength: Int64(payload.count), close: true, body: payload)
        })
        defer { server.stop() }
        let transport = PersistentHTTP1Transport(label: "diagnostics-test")
        defer { transport.close() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/\(UUID().uuidString).ts")!
        let events = CorrelationEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { if $0.originalURL == url { events.add($0) } }
        defer { SourceNetworkDiagnostics.handler = previous }
        let owner = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let replacement = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let body = try await SourceNetworkDiagnostics.$context.withValue(replacement) {
            try await transport.open(url, headers: [:], limit: payload.count,
                                     diagnosticContext: owner, role: .hlsSegment)
        }
        if status == 200 {
            #expect(!events.snapshot().contains { $0.phase == .completed })
        }
        var received = Data()
        while let chunk = try await body.next() { received.append(chunk) }
        #expect(received == (status == 200 ? payload : Data()))
        #expect(try await body.next() == nil)
        body.abandon()
        let captured = events.snapshot()
        #expect(captured.map(\.phase) == [.response, .completed])
        #expect(captured.allSatisfy { $0.context == owner && $0.status == status && $0.role == .hlsSegment })
        #expect(Set(captured.map(\.requestID)).count == 1)
        #expect(captured.last?.bytes == Int64(received.count))
    }

    @Test("Held HTTP body limits report one terminal event before or during streaming",
          .timeLimit(.minutes(3)), arguments: [true, false])
    func heldBodyLimit(declaredLength: Bool) async throws {
        let payload = Data(repeating: 0x47, count: 4096)
        let server = try #require(ScriptedOriginServer { _ in
            .init(status: 200, declaredLength: declaredLength ? Int64(payload.count) : nil,
                  close: true, body: payload)
        })
        defer { server.stop() }
        let transport = PersistentHTTP1Transport(label: "diagnostics-limit-test")
        defer { transport.close() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/\(UUID().uuidString).ts")!
        let events = CorrelationEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { if $0.originalURL == url { events.add($0) } }
        defer { SourceNetworkDiagnostics.handler = previous }
        do {
            _ = try await transport.get(url, headers: [:], limit: 16, role: .hlsSegment)
            Issue.record("An oversized body must fail")
        } catch let error as BoundedFetch.Exceeded {
            #expect(error.limit == 16)
        }
        let captured = events.snapshot()
        #expect(captured.map(\.phase) == [.response, .bodyLimitExceeded])
        #expect(captured.allSatisfy { $0.status == 200 }, "the terminal event keeps the status the head carried")
        #expect(captured.allSatisfy { $0.context == nil && $0.role == .hlsSegment })
        #expect(Set(captured.map(\.requestID)).count == 1)
    }

    // A held open that fails after a redirect names the hop that answered, not the URL it started at.
    @Test("A held open that fails after a redirect reports the failing hop and its status",
          .timeLimit(.minutes(3)))
    func heldOpenFailureAfterRedirect() async throws {
        let payload = Data(repeating: 0x47, count: 4096)
        let server = try #require(ScriptedOriginServer { request in
            request.path.hasSuffix("/moved.ts")
                ? .init(status: 200, declaredLength: Int64(payload.count), close: true, body: payload)
                : .init(status: 302, declaredLength: 0, location: "/moved.ts")
        })
        defer { server.stop() }
        let transport = PersistentHTTP1Transport(label: "diagnostics-redirect-test")
        defer { transport.close() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/\(UUID().uuidString).ts")!
        let events = CorrelationEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { if $0.originalURL == url { events.add($0) } }
        defer { SourceNetworkDiagnostics.handler = previous }
        await #expect(throws: BoundedFetch.Exceeded.self) {
            _ = try await transport.get(url, headers: [:], limit: 16, role: .hlsSegment)
        }
        let captured = events.snapshot()
        #expect(captured.map(\.phase) == [.response, .redirect, .response, .bodyLimitExceeded])
        let terminal = try #require(captured.last)
        #expect(terminal.url?.path == "/moved.ts")
        #expect(terminal.status == 200)
        #expect(Set(captured.map(\.requestID)).count == 1)
    }

    @Test("Abandoning or dropping a held HTTP body reports once without claiming success",
          .timeLimit(.minutes(3)), arguments: [true, false])
    func heldBodyAbandoned(explicit: Bool) async throws {
        let server = try #require(ScriptedOriginServer { _ in
            .init(status: 200, declaredLength: nil, close: true, body: Data(repeating: 0x47, count: 4096))
        })
        defer { server.stop() }
        let transport = PersistentHTTP1Transport(label: "diagnostics-abandon-test")
        defer { transport.close() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/\(UUID().uuidString).ts")!
        let events = CorrelationEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { if $0.originalURL == url { events.add($0) } }
        defer { SourceNetworkDiagnostics.handler = previous }
        var body: PersistentHTTP1Transport.Body? = try await transport.open(url, headers: [:], limit: 8192)
        if explicit {
            body?.abandon()
            body?.abandon()
        }
        body = nil
        try await waitFor { events.snapshot().contains { $0.phase == .abandoned } }
        #expect(events.snapshot().map(\.phase) == [.response, .abandoned])
        #expect(Set(events.snapshot().map(\.requestID)).count == 1)
    }

    @Test("Bounded HLS requests report real HTTP refusals without synthetic cancellation")
    func boundedResponseEvidence() async throws {
        final class Events: @unchecked Sendable {
            let lock = NSLock()
            var values: [SourceNetworkDiagnostics.Event] = []
            func add(_ value: SourceNetworkDiagnostics.Event) { lock.withLock { values.append(value) } }
            func snapshot() -> [SourceNetworkDiagnostics.Event] { lock.withLock { values } }
        }
        let events = Events()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { events.add($0) }
        defer { SourceNetworkDiagnostics.handler = previous }
        let server = try #require(ScriptedOriginServer { _ in .init(status: 403, declaredLength: 0) })
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/private.m3u8")!
        let (_, response) = try await BoundedPlaylistFetch.data(for: URLRequest(url: url), session: session, limit: 1024)
        #expect((response as? HTTPURLResponse)?.statusCode == 403)
        let terminal = try #require(events.snapshot().first {
            $0.originalURL == url && $0.phase == .completed && $0.role == .hlsPlaylist
        })
        #expect(terminal.status == 403)
        #expect(terminal.urlErrorCode == nil)
    }

    @Test("Real source response events retain status and origin", .timeLimit(.minutes(3)))
    func responseEvidence() async throws {
        let events = CorrelationEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { events.add($0) }
        defer { SourceNetworkDiagnostics.handler = previous }
        let server = try #require(ScriptedOriginServer { _ in .init(status: 403, declaredLength: 0) })
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/\(UUID().uuidString)/test.ts")!
        let reader = AVIOReader(url: url, isLive: true)
        try await withTaskCancellationHandler {
            let result = try await ProbeTestJob {
                defer { reader.markClosed(); reader.close() }
                try reader.open()
            }.outcome()
            #expect(throws: AVIOReaderError.httpStatus(403)) { try result.get() }
        } onCancel: {
            reader.markClosed()
        }
        let response = try #require(events.snapshot().first {
            $0.phase == .response && $0.status == 403 && $0.originalURL == url && $0.role == .persistentRead
        })
        #expect(response.originalURL?.port == Int(server.port))
        #expect(response.url?.host == "127.0.0.1")
        #expect(response.urlErrorCode == nil)
        #expect(response.role == .persistentRead)
    }

    @MainActor
    @Test("Live initial probe preserves HTTP refusal, including uppercase HTTP", arguments: [401, 403, 404, 429, 503])
    func liveProbePreservesRefusal(status: Int) async throws {
        let server = try #require(ScriptedOriginServer { _ in
            .init(status: status, declaredLength: 0)
        })
        defer { server.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.isLive = true
        let url = URL(string: "HTTP://127.0.0.1:\(server.port)/live/test.ts")!
        do {
            _ = try await engine.load(url: url, options: options)
            Issue.record("A refused source must fail")
        } catch {
            #expect(engine.errorInfo?.underlyingCode == status)
            #expect(engine.errorInfo?.kind == (AVIOReader.isRateLimitStatus(status) ? .sourceRateLimited : .sourceRefused))
            #expect(!server.requests.isEmpty, "Uppercase HTTP must use the HTTP reader")
        }
    }

    @Test("URL errors survive wrappers without reading localized messages")
    func nestedTransportCode() {
        for code in [-1001, -1003, -1004, -1006, -1009, -1202, -999] {
            let error = NSError(domain: "Wrapper", code: 7, userInfo: [NSUnderlyingErrorKey: URLError(URLError.Code(rawValue: code))])
            #expect(SourceNetworkDiagnostics.urlErrorCode(error) == code)
        }
        #expect(SourceNetworkDiagnostics.urlErrorCode(NSError(domain: "private.example", code: -1003)) == nil)
    }

    @Test("NSError keeps historical case codes and carries the original FFmpeg failure separately")
    func demuxCodeSurvivesBridge() {
        for code: Int32 in [-1094995529, -1128613112, -1296385272, -5] {
            let cases: [(DemuxerError, Int)] = [
                (.openFailed(code: code), 0), (.streamInfoFailed(code: code), 1), (.readFailed(code: code), 2)
            ]
            for (failure, historicalCode) in cases {
                let error = failure as NSError
                #expect(error.domain == "AetherEngine.DemuxerError")
                #expect(error.code == historicalCode)
                #expect(error.userInfo[DemuxerError.ffmpegErrorCodeKey] as? Int == Int(code))
                #expect(error.localizedDescription == failure.description)
            }
        }
    }

    // AE#818 review: a first connection that ends without a body or a refusal (an IPTV or Jellyfin
    // tuner still spinning up resets it) is the reconnect ladder's to ride, not the open's to fail. Its
    // URL error is recorded for a later give-up and forgotten once the reconnect delivers. The reset
    // comes after the header, because URLSession silently retries a GET that dies before one.
    @Test("A live open whose first connection drops before any data reconnects instead of failing",
          .timeLimit(.minutes(3)))
    func liveOpenRidesFirstConnectionLoss() async throws {
        let maybeServer = ThrottledOriginServer(totalSize: 8 * 1024 * 1024, throttleUs: 0,
                                                respond: { index, _, _ in index == 0 ? .serveThenDrop(afterBytes: 0) : .serve206 })
        let server = try #require(maybeServer)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/live/channel.ts")!, isLive: true)
        let (count, recorded) = try await withTaskCancellationHandler {
            try await ProbeTestJob {
                defer { reader.markClosed(); reader.close() }
                try reader.open()
                var prefix = Data(count: 16)
                let count = prefix.withUnsafeMutableBytes {
                    reader.read(into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), size: 16)
                }
                return (count, reader.lastTransportFailureCode)
            }.outcome().get()
        } onCancel: {
            reader.markClosed()
            server.stop()
        }
        #expect(count > 0)
        #expect(server.requestLog.count >= 2)
        #expect(recorded == nil, "a delivered reconnect leaves no recorded cause behind")
    }

    @MainActor
    @Test("Live initial connection failure keeps liveSourceUnavailable and the original URL error",
          .timeLimit(.minutes(2)))
    func liveConnectionFailure() async throws {
        let server = try #require(ScriptedOriginServer { _ in .init(status: 200, declaredLength: 0) })
        let url = URL(string: "http://127.0.0.1:\(server.port)/live/test.ts")!
        server.stop()
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.isLive = true
        do {
            _ = try await engine.load(url: url, options: options)
            Issue.record("Closed source must fail")
        } catch {
            #expect(engine.errorInfo?.kind == .liveSourceUnavailable)
            #expect(engine.errorInfo?.underlyingDomain == NSURLErrorDomain)
            #expect(engine.errorInfo?.underlyingCode == NSURLErrorCannotConnectToHost)
        }
    }
    /// In-process ranged source: exercise the reader and real URLSession delegates without a server.
    private final class RangedSource: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let range = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-")
                .dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(range.first ?? "0") ?? 0
            let end = min(16_383, range.count > 1 ? (Int(range[1]) ?? 16_383) : 16_383)
            guard start <= end else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes \(start)-\(end)/16384", "Content-Length": "\(end - start + 1)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data((start...end).map { UInt8($0 % 251) }))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @Test("AVIO reconnects keep the reader owner across real thread boundaries, including nil",
          .timeLimit(.minutes(3)), arguments: [true, false])
    func avioReconnectRetainsCapturedContext(attributed: Bool) async throws {
        let owner = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let replacement = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        let url = URL(string: "https://\(UUID().uuidString).invalid/video.bin")!
        let events = CorrelationEvents()
        let previous = SourceNetworkDiagnostics.handler
        SourceNetworkDiagnostics.handler = { if $0.originalURL == url { events.add($0) } }
        defer { SourceNetworkDiagnostics.handler = previous }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RangedSource.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        // One request suppresses speculative tail prefetch; only the playback connection is exercised.
        OriginRequestBudget.shared.setHostLimit(1, for: url)
        defer { OriginRequestBudget.shared.setHostLimit(nil, for: url) }
        let reader = SourceNetworkDiagnostics.$context.withValue(attributed ? owner : nil) {
            AVIOReader(url: url, boundedInitialFetch: 4096, persistentRequestSession: session)
        }
        let result = try await withTaskCancellationHandler {
            try await SourceNetworkDiagnostics.$context.withValue(replacement) {
                try await ProbeTestJob {
                    defer { reader.markClosed(); reader.close() }
                    #expect(SourceNetworkDiagnostics.context == nil)
                    try reader.open()
                    var bytes = [UInt8](repeating: 0, count: 16)
                    #expect(reader.read(into: &bytes, size: 16) == 16)
                    #expect(bytes == (0..<16).map { UInt8($0 % 251) })
                    #expect(reader.seek(offset: 8192, whence: SEEK_SET) == 8192)
                    #expect(reader.read(into: &bytes, size: 16) == 16)
                    #expect(bytes == (8192..<8208).map { UInt8($0 % 251) })
                }.outcome()
            }
        } onCancel: { reader.markClosed(); session.invalidateAndCancel() }
        try result.get()
        try await waitFor { events.snapshot().filter { $0.phase == .completed }.count >= 2 }
        let captured = events.snapshot()
        let responses = captured.filter { $0.phase == .response }
        #expect(responses.count == 2)
        #expect(Set(responses.map(\.requestID)).count == 2)
        #expect(captured.allSatisfy { $0.role == .persistentRead && $0.context == (attributed ? owner : nil) })
    }

    @MainActor
    @Test("Session opens and fresh reopens retain their explicitly captured owner, including nil", arguments: [true, false])
    func sessionReopensRetainContext(attributed: Bool) {
        let owner = attributed ? SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID()) : nil
        let ambient = SourceNetworkDiagnostics.Context(playbackID: UUID(), attemptID: UUID())
        SourceNetworkDiagnostics.$context.withValue(ambient) {
            let session = HLSVideoEngine(url: URL(string: "https://example.invalid/video.mkv")!, diagnosticContext: owner)
            #expect(session.openProfile.diagnosticContext == owner)
            #expect(session.restartReopenProfile.diagnosticContext == owner)
            let headers = RequestHeaderStore(["User-Agent": "test"])
            let liveReopen = session.openProfile.withRequestHeaders(headers)
            #expect(liveReopen.diagnosticContext == owner)
            #expect(liveReopen.requestHeaders === headers)
        }
    }

    @MainActor
    @Test("Live startup keeps its public kind and original cause; VOD retains its own classification")
    func liveStartupFailureContract() throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        for code in [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost] {
            let error = NSError(domain: "Wrapper", code: 1,
                                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: code)])
            engine.publishLoadFailure(error, isLiveStart: true)
            #expect(engine.errorInfo?.kind == .liveSourceUnavailable)
            #expect(engine.errorInfo?.underlyingDomain == NSURLErrorDomain)
            #expect(engine.errorInfo?.underlyingCode == code)
            engine.publishLoadFailure(error)
            #expect(engine.errorInfo?.kind == .sourceOpenFailed)
        }
        for status in [401, 403, 404, 429, 503, 509] {
            for error: any Error in [AVIOReaderError.httpStatus(status), HLSIngestError.playlistUnreachable(status: status)] {
                engine.publishLoadFailure(error, isLiveStart: true)
                #expect(engine.errorInfo?.kind == (AVIOReader.isRateLimitStatus(status) ? .sourceRateLimited : .sourceRefused))
                #expect(engine.errorInfo?.underlyingCode == status)
            }
        }
        for error: any Error in [URLError(.serverCertificateUntrusted), AVIOReaderError.transportSecurityFailed(code: NSURLErrorServerCertificateUntrusted)] {
            engine.publishLoadFailure(error, isLiveStart: true)
            #expect(engine.errorInfo?.kind == .sourceCertificateRejected)
            #expect(engine.errorInfo?.underlyingDomain == NSURLErrorDomain)
            #expect(engine.errorInfo?.underlyingCode == NSURLErrorServerCertificateUntrusted)
        }
        engine.publishLoadFailure(DemuxerError.openFailed(code: -5), isLiveStart: true)
        #expect(engine.errorInfo?.kind == .liveSourceUnavailable)
        #expect(engine.errorInfo?.underlyingCode == 0)
        #expect(engine.errorInfo?.ffmpegErrorCode == -5)
        engine.publishLoadFailure(HLSIngestError.playlistInvalid(reason: "no segments"), isLiveStart: true)
        #expect(engine.errorInfo?.kind == .liveSourceUnavailable)
        #expect(engine.errorInfo?.hlsDiagnosticReason == .noSegments)
    }

    @Test("Diagnostic roles and phases preserve raw tokens and accept future values")
    func extensibleDiagnosticTokens() throws {
        let role = SourceNetworkDiagnostics.Role(rawValue: "FutureReader")
        let phase = SourceNetworkDiagnostics.Phase(rawValue: "future_phase")
        #expect(try JSONDecoder().decode(SourceNetworkDiagnostics.Role.self, from: JSONEncoder().encode(role)) == role)
        #expect(try JSONDecoder().decode(SourceNetworkDiagnostics.Phase.self, from: JSONEncoder().encode(phase)) == phase)
        #expect(SourceNetworkDiagnostics.Role.persistentRead.rawValue == "PersistentRead")
        #expect(SourceNetworkDiagnostics.Phase.bodyLimitExceeded.rawValue == "body_limit_exceeded")
        #expect(SourceNetworkDiagnostics.Phase.abandoned.rawValue == "abandoned")
    }

}
