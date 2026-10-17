import Testing
import Foundation
@testable import AetherEngine

/// A live stream read straight off its URL (an IPTV panel's continuous MPEG-TS form of a channel)
/// and refused for a while, as a connection-limited panel refuses an account's requests with 509
/// while another device holds its last slot, keeps its session: the reader asks again on a short,
/// steady wait until it is served, the refusals arm no pacer, and a refused open is the origin's
/// answer, typed, rather than a minute of the same request.
///
/// The loopback cases run with the reconnect backoff scaled down, the way the other reader suites
/// do, and are judged by what came through and how many requests it took; the give-up case's only
/// wall-clock check is a lower bound (time spent >= budget) that a slow runner can only satisfy.
/// The wait itself is a pure rule, tested as one.
@Suite("Live stream reader rides out refusals", .offCooperativePool, .timeLimit(.minutes(2)))
struct LiveStreamRefusalRetryTests {

    // MARK: - Loopback origin

    /// One HTTP/1.1 response per connection (Connection: close), scripted per request.
    private final class ScriptedOrigin: @unchecked Sendable {
        struct Response {
            var status: Int
            var headers: [String: String] = [:]
            var body = Data()
        }

        let port: UInt16
        private let listener: LoopbackListener
        private let respond: @Sendable (_ index: Int) -> Response
        private let lock = NSLock()
        private var count = 0

        /// `respond` gets how many requests came before this one.
        init?(respond: @escaping @Sendable (_ index: Int) -> Response) {
            self.respond = respond
            guard let listener = LoopbackListener(backlog: 16) else { return nil }
            self.listener = listener
            port = listener.port
            listener.start { [weak self] conn in
                guard let self else { close(conn); return false }
                Thread.detachNewThread { [weak self] in
                    self?.serve(conn)
                }
                return true
            }
        }

        func stop() {
            listener.stop()
        }

        var requestCount: Int {
            lock.withLock { count }
        }

        var url: URL {
            URL(string: "http://127.0.0.1:\(port)/live/user/pass/1.ts")!
        }

        private func serve(_ conn: Int32) {
            defer { close(conn) }
            var request = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = read(conn, &buf, buf.count)
                guard n > 0 else { return }
                request.append(contentsOf: buf[0..<n])
                if request.count > 64 * 1024 { return }
            }
            let index: Int = lock.withLock {
                count += 1
                return count - 1
            }
            let response = respond(index)
            var header = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Status")\r\n"
            header += "Content-Type: video/mp2t\r\n"
            for (field, value) in response.headers {
                header += "\(field): \(value)\r\n"
            }
            header += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
            _ = header.withCString { write(conn, $0, strlen($0)) }
            response.body.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(conn, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard n > 0 else { return }
                    offset += n
                }
            }
        }
    }

    /// Valid sync bytes at 188-byte cadence, enough to be read in several reader calls.
    private static func streamBytes(count packets: Int) -> Data {
        var data = Data(capacity: packets * 188)
        for packet in 0..<packets {
            var ts = [UInt8](repeating: UInt8(truncatingIfNeeded: packet), count: 188)
            ts[0] = 0x47
            data.append(contentsOf: ts)
        }
        return data
    }

    /// The backoff scale and the refusal budget are handed to this reader alone, so no other test's
    /// reader sees them.
    private static func makeLiveReader(_ url: URL, refusalBudget: TimeInterval? = nil) -> AVIOReader {
        AVIOReader(url: url, label: "live", prefetchEnabled: true, isLive: true,
                   backoffScale: 0.02, liveRefusalRetryBudget: refusalBudget)
    }

    /// Reads until `expectedBytes` have come through or the reader fails; the bytes, and the code
    /// the read ended with when it did not deliver them.
    private static func drain(_ reader: AVIOReader, expectedBytes: Int) -> (bytes: Int, failure: Int32?) {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buf.deallocate() }
        var total = 0
        while total < expectedBytes {
            let n = reader.read(into: buf, size: 64 * 1024)
            if n <= 0 { return (total, n) }
            total += Int(n)
        }
        return (total, nil)
    }

    // MARK: - The wait

    @Test("the wait is a second, or the origin's Retry-After up to five seconds")
    func waitIsASecondOrTheRetryAfterUpToFive() {
        #expect(AVIOReader.liveRefusalWait(retryAfter: 0) == 1)
        #expect(AVIOReader.liveRefusalWait(retryAfter: 0.3) == 1)
        #expect(AVIOReader.liveRefusalWait(retryAfter: 2) == 2)
        #expect(AVIOReader.liveRefusalWait(retryAfter: 5) == 5)
        #expect(AVIOReader.liveRefusalWait(retryAfter: 30) == 5)
    }

    // MARK: - The stream

    @Test("a stream refused mid-session is asked for again until it is served, and arms no pacer")
    func refusedMidStreamIsRetriedUntilServed() throws {
        let first = Self.streamBytes(count: 400)
        let second = Self.streamBytes(count: 400)
        let refusals = 3
        let origin = try #require(ScriptedOrigin { index in
            switch index {
            case 0: return .init(status: 200, body: first)
            case 1...refusals: return .init(status: 509)
            default: return .init(status: 200, body: second)
            }
        })
        defer { origin.stop() }
        let reader = Self.makeLiveReader(origin.url)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let drained = Self.drain(reader, expectedBytes: first.count + second.count)

        #expect(drained.failure == nil)
        #expect(drained.bytes >= first.count + second.count)
        // The first body, the refusals, and the body that followed them: nothing was given up on
        // and nothing asked twice over.
        #expect(origin.requestCount >= refusals + 2)
        // The refusals armed no pacer and lowered no budget: the books hold no refusal for this
        // origin (a witness stamp carries no count).
        let books = OriginRequestBudget.shared.snapshot(for: origin.url)
        #expect((books?.refusals ?? 0) == 0)
        #expect(books?.limit == nil)
        #expect(!OriginRequestBudget.shared.isPaced(origin.url))
    }

    @Test("a stream refused for longer than the budget ends as a read error")
    func refusedPastTheBudgetGivesUp() throws {
        let budget: TimeInterval = 1
        let first = Self.streamBytes(count: 400)
        let origin = try #require(ScriptedOrigin { index in
            index == 0 ? .init(status: 200, body: first) : .init(status: 509)
        })
        defer { origin.stop() }
        let reader = Self.makeLiveReader(origin.url, refusalBudget: budget)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let started = DispatchTime.now()
        let drained = Self.drain(reader, expectedBytes: first.count + 1)
        let spent = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9

        #expect(drained.bytes == first.count)
        #expect(drained.failure == FFmpegErr.eio)
        // Given up only once the budget ran out: the old count-based ladder's six attempts at this
        // pace end in a fraction of it. A slow runner only lengthens this, so it bounds nothing
        // from above; how many requests fit in the second is the runner's business, not the rule's.
        #expect(spent >= budget, "gave up after \(spent) s")
        #expect(origin.requestCount - 1 >= 2, "\(origin.requestCount - 1) refused attempts")
    }

    // MARK: - The open

    @Test("a live open the origin refuses fails typed with its status at once")
    func refusedOpenFailsTyped() throws {
        let origin = try #require(ScriptedOrigin { _ in .init(status: 509) })
        defer { origin.stop() }
        let reader = Self.makeLiveReader(origin.url)
        defer { reader.markClosed(); reader.close() }

        let failure = #expect(throws: AVIOReaderError.self) { try reader.open() }
        #expect(failure == .httpStatus(509))
        // The one request, not the read loop's ladder on the same one.
        #expect(origin.requestCount == 1)
    }

    @Test("a live open answered with a server error is asked once more and plays when served")
    func serverErrorAtOpenIsAskedOnceMore() throws {
        let body = Self.streamBytes(count: 400)
        let origin = try #require(ScriptedOrigin { index in
            index == 0 ? .init(status: 502) : .init(status: 200, body: body)
        })
        defer { origin.stop() }
        let reader = Self.makeLiveReader(origin.url)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let drained = Self.drain(reader, expectedBytes: body.count)
        #expect(drained.failure == nil)
        #expect(drained.bytes >= body.count)
    }

    @Test("a live open answered with a server error twice fails typed with its status")
    func serverErrorTwiceAtOpenFailsTyped() throws {
        let origin = try #require(ScriptedOrigin { _ in .init(status: 500) })
        defer { origin.stop() }
        let reader = Self.makeLiveReader(origin.url)
        defer { reader.markClosed(); reader.close() }

        let failure = #expect(throws: AVIOReaderError.self) { try reader.open() }
        #expect(failure == .httpStatus(500))
        #expect(origin.requestCount == 2)
    }

    @Test("a live open answered 403 fails typed too")
    func forbiddenOpenFailsTyped() throws {
        let origin = try #require(ScriptedOrigin { _ in .init(status: 403) })
        defer { origin.stop() }
        let reader = Self.makeLiveReader(origin.url)
        defer { reader.markClosed(); reader.close() }

        let failure = #expect(throws: AVIOReaderError.self) { try reader.open() }
        #expect(failure == .httpStatus(403))
        #expect(origin.requestCount == 1)
    }
}
