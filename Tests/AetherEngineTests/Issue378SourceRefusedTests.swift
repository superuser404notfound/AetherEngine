// #378: a refused source. The reported origin (an Xtream panel behind a portal's 302) answered every GET —
// the suffix tail prefetch, the ranged data connection at byte 0, the size probes and the unranged
// streaming GET — with 403 for about twenty seconds, while a HEAD came back 200 with no length.
//
// What the host got out of that was `sourceOpenFailed` with FFmpeg's "Invalid data found when
// processing input": the streaming delegate allowed any status, so the 403 error page went into the
// stream buffer and FFmpeg probed it as container bytes. The 403 the data connection had already
// been refused with was recorded as an Int and then read as "no size resolved". Nothing in the
// classification could tell a refused origin from a corrupt file. And because the tail prefetch's
// delegate took any non-206 as "no suffix range support", one 403 also switched the prefetch off
// for that origin for the rest of the process.
//
// Three fixes, each measured against a scripted origin: the streaming GET hangs up on anything but
// a 200/206 and the open fails typed with the status; after a 401/403/404/410 at byte 0 the HEAD and
// `bytes=0-1` probes are not issued (the one request still made is the unranged GET, so an origin
// that refuses `Range` but serves a plain GET plays forward-only); and only the origin's answer to
// the range FORM (a 200, a 416) latches the suffix-range denial.
import Foundation
import Testing
@testable import AetherEngine

@Suite("#378 a refused source fails with its status, not as invalid data", .serialized)
struct Issue378SourceRefusedTests {

    // Every origin here has its own loopback port, and `SuffixRangeSupport` keys by origin, so the
    // process-wide latch is naturally isolated per test; resetting it would race the #281 suite.

    /// The reported origin: HEAD is served (200, no length), every GET is refused with a 403 that
    /// carries a small error page.
    private static func refusingOrigin() throws -> ScriptedOriginServer {
        try #require(ScriptedOriginServer { request in
            if request.method == "HEAD" {
                return .init(status: 200, declaredLength: 0)
            }
            return .init(status: 403, declaredLength: 22, bodyBytes: 22)
        })
    }

    // MARK: - The predicate

    @Test("only a 200 or a 416 is the origin's verdict on the suffix-range form")
    func suffixRangeVerdictStatuses() {
        #expect(AVIOReader.suffixRangeStatusDeclinesTheForm(200))
        #expect(AVIOReader.suffixRangeStatusDeclinesTheForm(416))
        for status in [401, 403, 404, 410, 429, 500, 502, 503, 509] {
            #expect(!AVIOReader.suffixRangeStatusDeclinesTheForm(status), "\(status) latched")
        }
    }

    // MARK: - The reader, against the reported origin

    @Test("the open fails typed with the status, sends no probes and accepts no error page")
    func refusedOpenFailsTypedWithTheStatus() throws {
        let server = try Self.refusingOrigin()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/1325105.mkv")!

        let reader = AVIOReader(url: url)
        defer { reader.markClosed(); reader.close() }
        #expect(throws: AVIOReaderError.httpStatus(403)) { try reader.open() }
        #expect(reader.cumulativeBytesFetched == 0, "the 403 body was accepted as media")

        let requests = server.requests
        #expect(!requests.contains { $0.method == "HEAD" }, "the HEAD probe ran after a 403 at byte 0")
        #expect(!requests.contains { $0.range == "bytes=0-1" }, "the bytes=0-1 probe ran after a 403 at byte 0")
        #expect(requests.filter { $0.range == nil && $0.method == "GET" }.count == 1,
                "expected exactly one unranged GET: \(requests)")
        #expect(requests.filter { $0.range?.hasPrefix("bytes=-") == true }.count == 1,
                "expected exactly one suffix tail prefetch: \(requests)")
    }

    @Test("a refusal does not latch the suffix-range denial for the origin", .timeLimit(.minutes(2)))
    func refusalDoesNotLatchSuffixRanges() async throws {
        let server = try Self.refusingOrigin()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/1325105.mkv")!

        let first = AVIOReader(url: url)
        #expect(throws: AVIOReaderError.httpStatus(403)) { try first.open() }
        first.markClosed(); first.close()
        // Let the tail prefetch's own outcome land: the 403 arrives at once from a loopback origin,
        // but the outcome closure runs on the delegate queue after open() has already thrown.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(SuffixRangeSupport.shared.denialReason(for: url) == nil,
                "a 403 during the refusal latched the origin: \(SuffixRangeSupport.shared.denialReason(for: url) ?? "")")

        let second = AVIOReader(url: url)
        defer { second.markClosed(); second.close() }
        #expect(throws: AVIOReaderError.httpStatus(403)) { try second.open() }
        try await waitFor { server.requests.filter { $0.range?.hasPrefix("bytes=-") == true }.count >= 2 }
        // A third ask, if one is coming, gets the same chance the original fixed wait gave it.
        try await Task.sleep(nanoseconds: 300_000_000)

        let suffixRequests = server.requests.filter { $0.range?.hasPrefix("bytes=-") == true }
        #expect(suffixRequests.count == 2,
                "the second open did not ask again after a refusal that said nothing about ranges: \(suffixRequests.count)")
    }

    /// The regression guard for #281: an origin that answers the suffix form itself — here with a
    /// 416 — is still remembered after one occurrence.
    @Test("a 416 to the suffix form still latches", .timeLimit(.minutes(3)))
    func rangeNotSatisfiableStillLatches() async throws {
        let declared: Int64 = 4 * 1024 * 1024 * 1024
        let server = try #require(ScriptedOriginServer { recorded in
            if recorded.range?.hasPrefix("bytes=-") == true {
                return .init(status: 416, declaredLength: 0)
            }
            return .init(status: 206,
                         declaredLength: Int64(1024 * 1024),
                         contentRange: "bytes 0-1048575/\(declared)",
                         bodyBytes: 1024 * 1024)
        })
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/big.mp4")!

        let reader = AVIOReader(url: url)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        try await waitFor { SuffixRangeSupport.shared.denialReason(for: url) != nil }
        let reason = try #require(SuffixRangeSupport.shared.denialReason(for: url))
        #expect(reason.contains("416"))
    }

    /// The other origin the probe skip has to keep working: `Range` is refused, a plain GET is served.
    @Test("an origin that refuses Range but serves a plain GET plays forward-only without probes")
    func rangeRefusingOriginPlaysForwardOnly() throws {
        let bodySize = 2 * 1024 * 1024
        let server = try #require(ScriptedOriginServer { request in
            if request.range != nil {
                return .init(status: 403, declaredLength: 0)
            }
            return .init(status: 200, declaredLength: Int64(bodySize), bodyBytes: bodySize)
        })
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/plain.mkv")!

        let reader = AVIOReader(url: url)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        #expect(!reader.isSeekable)

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let read = buffer.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, size: Int32($0.count)) }
        #expect(read > 0, "the unranged GET delivered nothing: \(read)")

        let requests = server.requests
        #expect(!requests.contains { $0.method == "HEAD" })
        #expect(!requests.contains { $0.range == "bytes=0-1" })
    }

    @Test("a sequential-origin session is refused typed too")
    func sequentialOriginRefusalIsTyped() throws {
        let server = try Self.refusingOrigin()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/archive.ts")!

        let reader = AVIOReader(url: url, sequentialOnly: true)
        defer { reader.markClosed(); reader.close() }
        #expect(throws: AVIOReaderError.httpStatus(403)) { try reader.open() }
        #expect(reader.cumulativeBytesFetched == 0)
    }

    // MARK: - Up the chain

    @Test("the demuxer open throws the reader's typed refusal, not an FFmpeg open failure")
    func demuxerNeverSeesTheErrorPage() throws {
        let server = try Self.refusingOrigin()
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/1325105.mkv")!

        let demuxer = Demuxer()
        defer { demuxer.close() }
        #expect(throws: AVIOReaderError.httpStatus(403)) { try demuxer.open(url: url) }
    }

    @Test("the session's open failure keeps the status typed, like the HLS classifications")
    func openFailurePassesTheStatusThrough() {
        let mapped = HLSVideoEngine.openFailure(from: AVIOReaderError.httpStatus(403))
        #expect(mapped as? AVIOReaderError == .httpStatus(403))
    }

    @MainActor
    @Test("a refused open publishes sourceRefused with the status; any other open failure stays sourceOpenFailed")
    func loadFailurePublishesTheStatus() throws {
        let engine = try AetherEngine()

        engine.publishLoadFailure(AVIOReaderError.httpStatus(403))
        let refused = try #require(engine.errorInfo)
        #expect(refused.kind == .sourceRefused)
        #expect(refused.underlyingCode == 403)
        #expect(refused.underlyingDomain == nil)
        #expect(refused.message.contains("403"))
        guard case .error = engine.state else {
            Issue.record("expected .error, got \(engine.state)")
            return
        }

        engine.publishLoadFailure(DemuxerError.openFailed(code: -5))
        let opened = try #require(engine.errorInfo)
        #expect(opened.kind == .sourceOpenFailed)
        #expect(opened.underlyingCode != 403)
    }

    // MARK: - Where the refusal meets #377

    /// A rate limit is a refusal too, and the reader now types it like any other. But the recovery a
    /// host owes it is the opposite one (wait, do not hand off to a second player), and #377 built
    /// `sourceRateLimited` to say exactly that, so the open must not flatten it into `sourceRefused`.
    @MainActor
    @Test("a metered open publishes sourceRateLimited, not sourceRefused, and keeps the status")
    func rateLimitedOpenPublishesTheMeteredKind() throws {
        let engine = try AetherEngine()

        for status in [429, 503, 509] {
            engine.publishLoadFailure(AVIOReaderError.httpStatus(status))
            let metered = try #require(engine.errorInfo)
            #expect(metered.kind == .sourceRateLimited, "\(status) published \(metered.kind.rawValue)")
            #expect(metered.underlyingCode == status)
        }

        for status in [401, 403, 404, 410, 500, 502] {
            engine.publishLoadFailure(AVIOReaderError.httpStatus(status))
            let refused = try #require(engine.errorInfo)
            #expect(refused.kind == .sourceRefused, "\(status) published \(refused.kind.rawValue)")
            #expect(refused.underlyingCode == status)
        }
    }

    /// The streaming pump reads a status like the persistent connection and the probe do, and those
    /// two charge a metering origin against the shared budget. On a sequential origin the pump's GET
    /// is the session's only request, so this is the only place that 429 is ever seen.
    @Test("a rate limit read by the streaming pump is charged against the origin budget")
    func meteredStreamingPumpChargesTheBudget() throws {
        let server = try #require(ScriptedOriginServer { _ in
            .init(status: 429, declaredLength: 0)
        })
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/archive.ts")!

        let reader = AVIOReader(url: url, sequentialOnly: true)
        defer { reader.markClosed(); reader.close() }
        #expect(throws: AVIOReaderError.httpStatus(429)) { try reader.open() }

        let snapshot = try #require(OriginRequestBudget.shared.snapshot(for: url),
                                    "the metered origin was never charged")
        #expect(snapshot.refusals >= 1)
    }
}
