// #377 (Rasmusmart57): the origin refuses new requests for about four minutes at a stretch, and a
// reader that asks for a new range every 8 to 16 MB of drain will ask inside one of those windows on
// any long file. `LoadOptions.heldSourceConnection` answers once and pulls, over a transport whose
// reads are demand driven, so the framing that `URLSession` would normally do is ours.
//
// These tests measure the framing, because that is the part that can be wrong quietly: a chunk size
// line delivered as media bytes corrupts a container without an error anywhere, and a Range header
// sent twice is a different request than the one intended. The backpressure itself is NOT testable
// on a loopback (TCP closes the window before any buffer of interest fills, which is why the
// suspend defect in #220 survived every local test it ever had); what is measurable here is that the
// pull budget is the only thing that decides how much comes off the wire, and that a zero budget
// ends the connection after exactly one request.
import Foundation
import Testing
@testable import AetherEngine

/// Records what the connection reports and answers pull budgets from a script.
private final class RecordingHeldDelegate: HeldSourceConnectionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _body = Data()
    private var _statuses: [Int] = []
    private var _ended = false
    private var _endError: Error?
    private var budgets: [Int]
    private let defaultBudget: Int
    private let finished = DispatchSemaphore(value: 0)
    /// Refuse the response, the way the reader does for a 429 or a Range-ignoring 200.
    private let acceptResponse: @Sendable (Int) -> Bool

    init(budgets: [Int] = [], defaultBudget: Int = 64 * 1024,
         acceptResponse: @escaping @Sendable (Int) -> Bool = { $0 == 200 || $0 == 206 }) {
        self.budgets = budgets
        self.defaultBudget = defaultBudget
        self.acceptResponse = acceptResponse
    }

    var body: Data { lock.lock(); defer { lock.unlock() }; return _body }
    var statuses: [Int] { lock.lock(); defer { lock.unlock() }; return _statuses }
    var endError: Error? { lock.lock(); defer { lock.unlock() }; return _endError }

    @discardableResult
    func waitForEnd(seconds: Double = 120) -> Bool {
        finished.wait(timeout: .now() + seconds) == .success
    }

    func heldConnection(_ connection: HeldSourceConnection,
                        didReceive response: HTTPURLResponse,
                        from url: URL) -> Bool {
        lock.lock()
        _statuses.append(response.statusCode)
        lock.unlock()
        return acceptResponse(response.statusCode)
    }

    func heldConnection(_ connection: HeldSourceConnection, didReceive data: Data) {
        lock.lock()
        _body.append(data)
        lock.unlock()
    }

    func heldConnectionPullBudget(_ connection: HeldSourceConnection) -> Int {
        lock.lock(); defer { lock.unlock() }
        if budgets.isEmpty { return defaultBudget }
        return budgets.removeFirst()
    }

    func heldConnection(_ connection: HeldSourceConnection, didEndWith error: Error?) {
        lock.lock()
        _ended = true
        _endError = error
        lock.unlock()
        finished.signal()
    }
}

@Suite("#377 held source connection")
struct Issue377HeldConnectionTests {

    // MARK: - Request framing

    @Test("the request carries the range, the host and the path with its query")
    func requestFraming() throws {
        let url = try #require(URL(string: "https://cdn.example.com/media/file.mkv?token=abc&x=1"))
        let bytes = try HeldSourceConnection.requestBytes(
            target: url, host: "cdn.example.com", port: 443, secure: true,
            offset: 14_652_209_616, extraHeaders: [:], userAgent: "AetherEngine/test")
        let text = String(decoding: bytes, as: UTF8.self)

        #expect(text.hasPrefix("GET /media/file.mkv?token=abc&x=1 HTTP/1.1\r\n"))
        #expect(text.contains("\r\nHost: cdn.example.com\r\n"))
        #expect(text.contains("\r\nRange: bytes=14652209616-\r\n"))
        #expect(text.contains("\r\nUser-Agent: AetherEngine/test\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test("a non-default port rides in Host, because an origin may route on it")
    func hostCarriesNonDefaultPort() throws {
        let url = try #require(URL(string: "http://192.168.1.10:8096/Videos/1/stream"))
        let text = String(decoding: try HeldSourceConnection.requestBytes(
            target: url, host: "192.168.1.10", port: 8096, secure: false,
            offset: 0, extraHeaders: [:], userAgent: nil), as: UTF8.self)
        #expect(text.contains("\r\nHost: 192.168.1.10:8096\r\n"))
        #expect(!text.contains("User-Agent:"))
    }

    @Test("a source header set wins without duplicating a header the request already sends")
    func extraHeadersDoNotDuplicate() throws {
        let url = try #require(URL(string: "https://jellyfin.example.com/Items/1/Download"))
        let text = String(decoding: try HeldSourceConnection.requestBytes(
            target: url, host: "jellyfin.example.com", port: 443, secure: true, offset: 0,
            extraHeaders: ["X-Emby-Token": "secret", "User-Agent": "Sodalite/1.0", "Range": "bytes=99-"],
            userAgent: "AetherEngine/test"), as: UTF8.self)

        #expect(text.contains("\r\nX-Emby-Token: secret\r\n"))
        // The caller's User-Agent replaces the default rather than joining it.
        #expect(text.contains("\r\nUser-Agent: Sodalite/1.0\r\n"))
        #expect(!text.contains("AetherEngine/test"))
        // A caller cannot smuggle a second Range in: the offset is the reader's to decide.
        #expect(text.components(separatedBy: "Range: ").count == 2)
        #expect(text.contains("\r\nRange: bytes=0-\r\n"))
    }

    @Test("the path and query go on the wire percent-encoded, as the URL spells them")
    func requestKeepsThePercentEncoding() throws {
        let url = try #require(URL(string: "http://h.example/My%20Movie%3F.mkv/?a=%20b&c=%0D%0A"))
        let text = String(decoding: try HeldSourceConnection.requestBytes(
            target: url, host: "h.example", port: 80, secure: false,
            offset: 0, extraHeaders: [:], userAgent: nil), as: UTF8.self)
        #expect(text.hasPrefix("GET /My%20Movie%3F.mkv/?a=%20b&c=%0D%0A HTTP/1.1\r\n"))
        #expect(text.components(separatedBy: "\r\n").allSatisfy { !$0.contains("\r") && !$0.contains("\n") })
    }

    @Test("an IPv6 literal is bracketed in Host")
    func ipv6HostIsBracketed() throws {
        let url = try #require(URL(string: "http://[::1]:8096/Videos/1/stream"))
        let host = try #require(url.host)
        let text = String(decoding: try HeldSourceConnection.requestBytes(
            target: url, host: host, port: 8096, secure: false,
            offset: 0, extraHeaders: [:], userAgent: nil), as: UTF8.self)
        #expect(text.contains("\r\nHost: [::1]:8096\r\n"))
    }

    @Test("a header value carrying a line break is refused rather than written")
    func lineBreakInAHeaderIsRefused() throws {
        let url = try #require(URL(string: "http://h.example/a.mkv"))
        for value in ["a\r\nX-Injected: 1", "a\nX-Injected: 1", "a\rb"] {
            #expect(throws: (any Error).self) {
                try HeldSourceConnection.requestBytes(
                    target: url, host: "h.example", port: 80, secure: false, offset: 0,
                    extraHeaders: ["X-Custom": value], userAgent: nil)
            }
        }
    }

    // MARK: - Chunked framing

    @Test("a chunked body decodes across arbitrary feed boundaries")
    func chunkedAcrossFeeds() throws {
        let wire = Data("4\r\nWiki\r\n7\r\npedia i\r\nB\r\nn \r\nchunks.\r\n0\r\n\r\n".utf8)
        // One byte at a time is the worst split a socket can hand over, and the state machine has
        // to survive a size line arriving in pieces.
        for feedSize in [1, 3, 7, wire.count] {
            let decoder = ChunkedBodyDecoder()
            var out = Data()
            var offset = 0
            while !decoder.isComplete {
                if let piece = try decoder.take(upTo: 4096) {
                    out.append(piece)
                    continue
                }
                guard offset < wire.count else { break }
                let end = min(offset + feedSize, wire.count)
                decoder.feed(wire.subdata(in: offset..<end))
                offset = end
            }
            #expect(decoder.isComplete, "feed size \(feedSize) never reached the terminating chunk")
            #expect(String(decoding: out, as: UTF8.self) == "Wikipedia in \r\nchunks.")
        }
    }

    @Test("a chunk size line with an extension is still a size, and trailers end the body")
    func chunkedExtensionsAndTrailers() throws {
        let decoder = ChunkedBodyDecoder()
        decoder.feed(Data("5;name=value\r\nhello\r\n0\r\nX-Checksum: 1\r\n\r\n".utf8))
        let out = try decoder.take(upTo: 4096)
        #expect(String(decoding: out ?? Data(), as: UTF8.self) == "hello")
        #expect(try decoder.take(upTo: 4096) == nil)
        #expect(decoder.isComplete)
    }

    @Test("a size line that is not hex is a framing error rather than media bytes")
    func chunkedRejectsBadSize() {
        let decoder = ChunkedBodyDecoder()
        decoder.feed(Data("not-a-size\r\nhello\r\n".utf8))
        #expect(throws: ChunkedBodyDecoder.ChunkedError.self) {
            _ = try decoder.take(upTo: 4096)
        }
    }

    @Test("the decoder hands back no more than the budget asks for")
    func chunkedRespectsBudget() throws {
        let decoder = ChunkedBodyDecoder()
        decoder.feed(Data("10\r\n0123456789abcdef\r\n0\r\n\r\n".utf8))
        let first = try decoder.take(upTo: 4)
        #expect(String(decoding: first ?? Data(), as: UTF8.self) == "0123")
        let rest = try decoder.take(upTo: 1024)
        #expect(String(decoding: rest ?? Data(), as: UTF8.self) == "456789abcdef")
    }

    // MARK: - Against a real socket

    @Test("one request serves the whole body, and the pull budget is what comes off the wire")
    func onePullRequestServesTheBody() async throws {
        let total: Int64 = 3 * 1024 * 1024
        let origin = try #require(ThrottledOriginServer(totalSize: total, throttleUs: 0))
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/media.mkv"))

        let delegate = RecordingHeldDelegate(defaultBudget: 128 * 1024)
        let connection = HeldSourceConnection(url: url, offset: 0, extraHeaders: [:],
                                              userAgent: "AetherEngine/test", label: "test",
                                              delegate: delegate)
        connection.start()
        #expect(delegate.waitForEnd(), "the connection never reported an end")

        #expect(delegate.statuses == [206])
        #expect(delegate.endError == nil)
        #expect(Int64(delegate.body.count) == total)
        // The whole point: one range for the whole file, not one per drain cycle.
        #expect(origin.rangeRequestCount == 1)
        #expect(origin.requestedRanges.first?.start == 0)
        #expect(origin.requestedRanges.first?.end == nil, "the held connection asks open-ended")
    }

    @Test("a zero budget ends the connection, and the origin was asked exactly once")
    func zeroBudgetEndsTheConnection() async throws {
        let origin = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024, throttleUs: 0))
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/media.mkv"))

        // Two pulls, then the answer a paused viewer produces.
        let delegate = RecordingHeldDelegate(budgets: [32 * 1024, 32 * 1024, 0])
        let connection = HeldSourceConnection(url: url, offset: 0, extraHeaders: [:],
                                              userAgent: nil, label: "test", delegate: delegate)
        connection.start()
        #expect(delegate.waitForEnd())

        // A budget is a CEILING on one read, not a promise: a socket hands over what has arrived,
        // so two 32 KB pulls deliver at most 64 KB and usually a little less.
        #expect(delegate.body.count <= 64 * 1024)
        #expect(delegate.body.count > 32 * 1024, "both pulls should have delivered")
        #expect(delegate.endError == nil, "a budget of zero is a deliberate end, not a fault")
        #expect(origin.rangeRequestCount == 1)
    }

    @Test("a refused response ends the connection without reading a body")
    func refusedResponseReadsNoBody() async throws {
        // Built outside `#require`: the macro decomposes the call and the scripted response is
        // not a `@Sendable` closure once it has been split into an argument.
        let refusing = ThrottledOriginServer(
            totalSize: 8 * 1024 * 1024, throttleUs: 0,
            respond: { _, _, _ in .status(429, retryAfter: 3) })
        let origin = try #require(refusing)
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/media.mkv"))

        let delegate = RecordingHeldDelegate()
        let connection = HeldSourceConnection(url: url, offset: 0, extraHeaders: [:],
                                              userAgent: nil, label: "test", delegate: delegate)
        connection.start()
        #expect(delegate.waitForEnd())

        #expect(delegate.statuses == [429], "the refusal has to reach the reader's classification")
        #expect(delegate.body.isEmpty)
    }

    @Test("a redirect is followed and the responding target is the one that served the body")
    func followsRedirect() async throws {
        let total: Int64 = 512 * 1024
        let redirecting = ThrottledOriginServer(totalSize: total, throttleUs: 0, respond: { _, _, path in
            path == "/pinned.mkv" ? .serve206 : .redirect(to: "/pinned.mkv")
        })
        let origin = try #require(redirecting)
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/source.mkv"))

        let delegate = RecordingHeldDelegate(defaultBudget: 64 * 1024)
        let connection = HeldSourceConnection(url: url, offset: 0, extraHeaders: [:],
                                              userAgent: nil, label: "test", delegate: delegate)
        connection.start()
        #expect(delegate.waitForEnd())

        #expect(delegate.statuses == [206], "only the served response reaches the reader")
        #expect(Int64(delegate.body.count) == total)
        #expect(connection.respondedBy.path == "/pinned.mkv")
        #expect(origin.requestLog.map(\.path) == ["/source.mkv", "/pinned.mkv"])
    }

    @Test("a cross-origin redirect drops the credential headers and keeps the rest")
    func crossOriginRedirectDropsCredentials() async throws {
        let total: Int64 = 64 * 1024
        final class PortBox: @unchecked Sendable { var port: UInt16 = 0 }
        let box = PortBox()
        let respond: @Sendable (Int, Int64, String) -> ThrottledOriginServer.Directive = { _, _, path in
            path == "/pinned.mkv" ? .serve206 : .redirect(to: "http://localhost:\(box.port)/pinned.mkv")
        }
        let redirecting = ThrottledOriginServer(totalSize: total, throttleUs: 0, respond: respond)
        let origin = try #require(redirecting)
        defer { origin.stop() }
        box.port = origin.port
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/source.mkv"))

        let delegate = RecordingHeldDelegate(defaultBudget: 64 * 1024)
        let connection = HeldSourceConnection(
            url: url, offset: 0,
            extraHeaders: ["X-Emby-Token": "secret", "Authorization": "MediaBrowser Token=\"secret\"",
                           "X-Custom": "kept"],
            userAgent: nil, label: "test", delegate: delegate)
        connection.start()
        #expect(delegate.waitForEnd())

        let headers = origin.requestHeaders
        try #require(headers.count == 2)
        #expect(headers[0]["x-emby-token"] == "secret")
        #expect(headers[1]["x-emby-token"] == nil)
        #expect(headers[1]["authorization"] == nil)
        #expect(headers[1]["x-custom"] == "kept")
    }

    @Test("a mid-body offset asks for exactly that offset")
    func offsetIsHonoured() async throws {
        let total: Int64 = 4 * 1024 * 1024
        let origin = try #require(ThrottledOriginServer(totalSize: total, throttleUs: 0))
        defer { origin.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/media.mkv"))

        let offset: Int64 = 1_048_576
        let delegate = RecordingHeldDelegate(defaultBudget: 256 * 1024)
        let connection = HeldSourceConnection(url: url, offset: offset, extraHeaders: [:],
                                              userAgent: nil, label: "test", delegate: delegate)
        connection.start()
        #expect(delegate.waitForEnd())

        #expect(origin.requestedRanges.first?.start == offset)
        #expect(Int64(delegate.body.count) == total - offset)
    }
}

/// The reader with the flag on, against the same scripted origin the pushed path is measured on.
///
/// Request COUNT is the observable, and it is the one thing a loopback can honestly report about
/// this change: how many times the origin was asked is transport independent, while the
/// backpressure itself is invisible here (TCP closes the window long before any buffer of interest
/// fills, which is why #220's defect survived every local test it had). Each test that asserts a
/// held count carries the pushed count next to it, because a harness in which the known shape looks
/// the same as the new one decides nothing.
@Suite("#377 held connection in the reader", .offCooperativePool)
struct Issue377HeldReaderTests {

    /// Ranges the DATA path asked for, with the open-time speculative tail fetch excluded: it
    /// lives at the far end of the file and is not part of the streaming cadence.
    private func dataRanges(_ server: ThrottledOriginServer, totalSize: Int64) -> [Int64] {
        server.requestedRanges.map(\.start).filter { $0 < totalSize - 1024 * 1024 }
    }

    private func drain(_ reader: AVIOReader, bytes target: Int, timeout: TimeInterval = 120) -> Int {
        let sliceCap = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        let deadline = Date().addingTimeInterval(timeout)
        while got < target && Date() < deadline {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            got += Int(n)
        }
        return got
    }

    /// Thread-safe because `playIntentProvider` is read on the held connection's pump thread.
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    }

    @Test("a held reader serves a long read on one request where the pushed reader needs several")
    func oneRequestForALongRead() async throws {
        let totalSize: Int64 = 256 * 1024 * 1024
        let target = 64 * 1024 * 1024

        let heldOrigin = try #require(ThrottledOriginServer(totalSize: totalSize))
        defer { heldOrigin.stop() }
        let held = AVIOReader(url: URL(string: "http://127.0.0.1:\(heldOrigin.port)/movie.bin")!,
                              heldConnection: true)
        defer { held.markClosed(); held.close() }
        try held.open()
        #expect(drain(held, bytes: target) >= target, "the held reader did not deliver the read")

        let pushedOrigin = try #require(ThrottledOriginServer(totalSize: totalSize))
        defer { pushedOrigin.stop() }
        let pushed = AVIOReader(url: URL(string: "http://127.0.0.1:\(pushedOrigin.port)/movie.bin")!)
        defer { pushed.markClosed(); pushed.close() }
        try pushed.open()
        #expect(drain(pushed, bytes: target) >= target, "the pushed reader did not deliver the read")

        let heldAsks = dataRanges(heldOrigin, totalSize: totalSize)
        let pushedAsks = dataRanges(pushedOrigin, totalSize: totalSize)

        // The positive control: the default path pays a request per drain cycle, which is the
        // cadence that walks into a refusal window on a long file.
        #expect(pushedAsks.count > 1,
                "the pushed control asked \(pushedAsks.count) times; it pays a request per drain cycle, so this harness is not measuring the difference")
        #expect(heldAsks.count == 1,
                "a held connection asked \(heldAsks.count) times for one continuous read: \(heldAsks)")
    }

    @Test("a PAUSED consumer ends the held connection inside its budget and holds no flow",
          .timeLimit(.minutes(2)))
    func pausedConsumerEndsTheHeldConnection() async throws {
        let totalSize: Int64 = 256 * 1024 * 1024
        let server = try #require(ThrottledOriginServer(totalSize: totalSize))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                heldConnection: true)
        defer { reader.markClosed(); reader.close() }
        reader.playIntentProvider = { false }
        reader.heldPausedBudgetSeconds = 3
        try reader.open()

        // Nobody consumes AND the consumer says it is paused. #310's worst episode came out of
        // exactly this state, so the connection has to be gone rather than merely quiet. The budget
        // runs from the moment the window is full, which is the origin's pace, so wait for the end
        // itself and then leave a window in which a re-request with nothing draining would show.
        try await waitFor { !reader.hasLiveConnectionForTesting && reader.windowDiagnostics.parked }
        try await Task.sleep(for: .seconds(1))

        #expect(!reader.hasLiveConnectionForTesting,
                "a paused consumer must hold no flow, which is the #310 invariant 6.11.0 shipped")
        let diag = reader.windowDiagnostics
        #expect(diag.parked, "the end must be recorded as backpressure so the refill owns it")
        #expect(dataRanges(server, totalSize: totalSize).count == 1,
                "nothing drained, so nothing may have been re-requested")
    }

    @Test("a PLAYING consumer that has stopped drawing keeps the held connection")
    func playingStalledConsumerKeepsTheHeldConnection() async throws {
        let totalSize: Int64 = 256 * 1024 * 1024
        let server = try #require(ThrottledOriginServer(totalSize: totalSize))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                heldConnection: true)
        defer { reader.markClosed(); reader.close() }
        // The segment producer's shape: it fills its cache, parks while the muxer works, and draws
        // again. Reading that as a stopped consumer is what cost a field hour 213 re-requests.
        reader.playIntentProvider = { true }
        reader.heldPausedBudgetSeconds = 3
        try reader.open()

        // Well past the budget a paused consumer would have spent.
        try await Task.sleep(for: .seconds(8))
        #expect(dataRanges(server, totalSize: totalSize).count == 1,
                "the wait itself must not have re-requested: \(dataRanges(server, totalSize: totalSize))")

        // Draw again. A connection that survived the wait serves this from the same request; one
        // that was ended would refill at the frontier and the origin would see a second ask. That
        // is the contract, and unlike a liveness flag it does not depend on when the check lands.
        let more = 8 * 1024 * 1024
        #expect(drain(reader, bytes: more) >= more, "the reader did not deliver after the wait")
        let asks = dataRanges(server, totalSize: totalSize)
        #expect(asks.count == 1,
                "a parked producer is not a paused viewer; drawing again must not cost a request: \(asks)")
    }

    @Test("a parked stretch longer than the stall timeout is not a delivery gap")
    func parkedPastTheStallTimeoutKeepsTheHeldConnection() async throws {
        let totalSize: Int64 = 256 * 1024 * 1024
        let server = try #require(ThrottledOriginServer(totalSize: totalSize))
        defer { server.stop() }
        // The field shape inside a test's budget: a producer that parks for longer than the
        // delivery-gap watchdog's threshold. A 16 MB window is ~100 s of a 1.2 Mbps title, so the
        // real 20 s is crossed by the regime this flag was asked for, not by an exotic one.
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                connStallTimeout: 2, heldConnection: true)
        defer { reader.markClosed(); reader.close() }
        reader.playIntentProvider = { true }
        try reader.open()

        let parkStarted = DispatchTime.now()
        try await Task.sleep(for: .seconds(5))
        // What a red run needs to be read: CI failed this once (2026-11-02, 32.7 s for a 5 s park)
        // and no loaded local run reproduced it, so the messages say who ended the connection.
        let parked = Double(DispatchTime.now().uptimeNanoseconds - parkStarted.uptimeNanoseconds) / 1e9
        let ends = "park \(String(format: "%.1f", parked))s, gap ends \(reader.deliveryGapEndCountForTesting), "
            + "trickle ends \(reader.trickleEndCountForTesting), backpressure end \(reader.windowDiagnostics.parked), "
            + "window \(reader.windowDiagnostics.windowBytes / 1024)KB"
        #expect(dataRanges(server, totalSize: totalSize).count == 1,
                "the parked stretch itself asked for nothing: \(dataRanges(server, totalSize: totalSize)); \(ends)")
        #expect(reader.hasLiveConnectionForTesting, "the park must not have ended the connection; \(ends)")

        // The invariant, stated where a loopback can state it without a race: the watchdog judges an
        // OUTSTANDING read, the park had none, so the park does not accumulate. Left accumulating it
        // is handed to the read the drain below issues, and the next tick (20 ms away, because the
        // remaining-gap re-arm collapses to its floor once the gap outgrows the timeout) ends a
        // connection nothing is wrong with. Over a real link that race is the origin's round trip
        // wide; on loopback the delivery wins it, which is why the count alone cannot say this.
        let parkedGap = reader.deliveryGapSecondsForTesting
        #expect(parkedGap < 3,
                "a stretch with no read outstanding accumulated \(parkedGap)s of delivery gap, and the read that follows it is judged on that; \(ends)")

        let more = 8 * 1024 * 1024
        #expect(drain(reader, bytes: more) >= more, "the reader did not deliver after the parked stretch")
        let asks = dataRanges(server, totalSize: totalSize)
        #expect(asks.count == 1,
                "a stretch with no read outstanding is not a gap; drawing again must not cost a request: \(asks)")
    }

    @Test("consumption after an idle end refills at the frontier without going backwards",
          .timeLimit(.minutes(2)))
    func refillAfterIdleEnd() async throws {
        let totalSize: Int64 = 256 * 1024 * 1024
        let server = try #require(ThrottledOriginServer(totalSize: totalSize))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                heldConnection: true)
        defer { reader.markClosed(); reader.close() }
        // A pause is what ends a held connection, so that is what this drives before resuming.
        let playing = LockedFlag(false)
        reader.playIntentProvider = { playing.get() }
        reader.heldPausedBudgetSeconds = 3
        try reader.open()

        // The paused budget runs from the moment the window is full, and filling it is the origin's
        // pace: on a loaded runner that alone outlasted a fixed 8 s sleep, the connection was never
        // ended, and the drain below rode it (`[0]`). Wait for the end itself.
        try await waitFor { !reader.hasLiveConnectionForTesting }
        let afterIdle = dataRanges(server, totalSize: totalSize)
        #expect(afterIdle.count == 1)

        playing.set(true)
        let target = 48 * 1024 * 1024
        #expect(drain(reader, bytes: target) >= target,
                "the reader did not resume after the pause ended")

        let asks = dataRanges(server, totalSize: totalSize)
        // `#require`, not `#expect`: `asks[1]` below traps on a shorter list, and a trap takes the
        // whole test process down with every result still buffered in it.
        try #require(asks.count == 2,
                     "resuming should cost exactly one re-request at the frontier, got \(asks)")
        #expect(asks == asks.sorted(), "a refill went backwards past the frontier: \(asks)")
        #expect(asks[1] > 0, "the refill asked from byte 0 again instead of at the frontier")
    }
}

/// The transport is decided at OPEN time (`loadIdentityFields` refuses to change it on a reload), so
/// a session that opens again on its own has to carry it. It opens again more often than the flag's
/// design suggests: a preopen that failed, a live reopen, and the VOD scrub restart that replaces a
/// wedged demuxer. Each of those is a fresh AVIOReader, and one built without the flag is back on
/// ranged requests against the origin the flag was turned on for, silently and for the rest of the
/// session.
@Suite("#377 the held transport survives the session's own reopens")
struct Issue377SessionProfileTests {
    private func engine(held: Bool) -> HLSVideoEngine {
        HLSVideoEngine(url: URL(string: "file:///dev/null")!, dvModeAvailable: false,
                       sequentialOrigin: false, heldSourceConnection: held)
    }

    @Test("a session asked to hold a connection opens every reopen of its own that way")
    func reopensCarryTheHeldTransport() {
        let session = engine(held: true)
        #expect(session.openProfile.avioHeldConnection,
                "the fallback open and the live reopen both use this profile")
        #expect(session.restartReopenProfile.avioHeldConnection,
                "the VOD scrub restart opens a replacement demuxer of its own")
    }

    @Test("a session that never asked for it opens none of them that way")
    func reopensStayOnTheDefaultTransport() {
        let session = engine(held: false)
        #expect(!session.openProfile.avioHeldConnection)
        #expect(!session.restartReopenProfile.avioHeldConnection)
    }
}
