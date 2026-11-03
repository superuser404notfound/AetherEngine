import Testing
import Foundation
@testable import AetherEngine

/// A live HLS source refused for a while, as a connection-limited IPTV panel refuses an account's
/// sessions with 509 while another device holds its last slot, keeps its session: the ingest asks
/// again every second and carries on the moment it is served, and the refusals arm no pacer, which
/// would hold the requests after them. A session URL the panel keeps refusing, or revoked, is asked
/// for afresh through the URL the host loaded.
@Suite("Live HLS ingest rides out refusals", .offCooperativePool, .timeLimit(.minutes(2)))
struct HLSLiveIngestRefusalTests {

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
        private let respond: @Sendable (_ path: String, _ index: Int) -> Response
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        /// `respond` gets each request's path and how many requests for that path came before it.
        init?(respond: @escaping @Sendable (_ path: String, _ index: Int) -> Response) {
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

        func requestCount(_ path: String) -> Int {
            lock.withLock { counts[path] ?? 0 }
        }

        func url(_ path: String) -> URL {
            URL(string: "http://127.0.0.1:\(port)\(path)")!
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
            guard let head = String(data: request, encoding: .utf8),
                  let requestLine = head.components(separatedBy: "\r\n").first else { return }
            let parts = requestLine.components(separatedBy: " ")
            guard parts.count >= 2 else { return }
            let path = parts[1]

            let index: Int = lock.withLock {
                let index = counts[path] ?? 0
                counts[path] = index + 1
                return index
            }
            let response = respond(path, index)
            var header = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Status")\r\n"
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

    // MARK: - Media

    /// Valid sync bytes at 188-byte cadence, the payload stamped with the segment's index, so the
    /// order the bytes leave the FIFO in is checkable.
    private static func segment(_ index: Int) -> Data {
        var data = Data(capacity: 4 * 188)
        for packet in 0..<4 {
            var ts = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: 188)
            ts[0] = 0x47
            ts[1] = UInt8(truncatingIfNeeded: packet)
            data.append(contentsOf: ts)
        }
        return data
    }

    /// 1 s segments `0..<count`, segment URIs relative to the playlist.
    private static func playlist(count: Int, endList: Bool) -> Data {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:1", "#EXT-X-MEDIA-SEQUENCE:0"]
        for index in 0..<count {
            lines.append("#EXTINF:1.0,")
            lines.append("seg\(index).ts")
        }
        if endList { lines.append("#EXT-X-ENDLIST") }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func segmentIndex(_ path: String) -> Int? {
        guard let name = path.components(separatedBy: "/").last,
              name.hasPrefix("seg"), name.hasSuffix(".ts") else { return nil }
        return Int(name.dropFirst(3).dropLast(3))
    }

    /// Everything the reader hands out until EOF or `expectedBytes`. No deadline of its own; the
    /// suite's `.timeLimit` catches a hang (see `TestWaiting`).
    private func drain(_ reader: HLSLiveIngestReader, expectedBytes: Int) async throws -> Data {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            var done = false
        }
        let box = Box()
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 32 * 1024)
            while true {
                let n = buf.withUnsafeMutableBufferPointer {
                    reader.read($0.baseAddress, size: Int32($0.count))
                }
                if n <= 0 { break }
                box.lock.lock()
                box.data.append(contentsOf: buf[0..<Int(n)])
                let enough = box.data.count >= expectedBytes
                box.lock.unlock()
                if enough { break }
            }
            box.lock.withLock { box.done = true }
        }
        try await waitFor { box.lock.withLock { box.done } }
        return box.lock.withLock { box.data }
    }

    // MARK: - Tests

    @Test("a refused refresh is asked again until it is served, and arms no pacer")
    func refusedRefreshRetriesSteadily() async throws {
        // The join reads seg0..7 and takes seg1..7; the next four refreshes are refused with 509, as
        // a panel refuses while another device holds the account's last slot; the fifth lists
        // seg0..15 with ENDLIST. The 7.36.0 ladder waited 1, 2 and 4 s between them, and its 12 s
        // budget had no room for the fifth.
        let refusals = 4
        let origin = try #require(ScriptedOrigin { path, index in
            if path == "/media.m3u8" {
                switch index {
                case 0: return .init(status: 200, body: Self.playlist(count: 8, endList: false))
                case 1...refusals: return .init(status: 509)
                default: return .init(status: 200, body: Self.playlist(count: 16, endList: true))
                }
            }
            if let segment = Self.segmentIndex(path) { return .init(status: 200, body: Self.segment(segment)) }
            return .init(status: 404)
        })
        defer { origin.stop() }

        let url = origin.url("/media.m3u8")
        let reader = HLSLiveIngestReader(playlistURL: url)
        defer { reader.close() }
        #expect(reader.resolveSegmentFormatHint() == "mpegts")

        let expected = (1..<16).map(Self.segment).reduce(Data(), +)
        let got = try await drain(reader, expectedBytes: expected.count)

        #expect(reader.terminalError == nil)
        #expect(got == expected)
        #expect(origin.requestCount("/media.m3u8") == refusals + 2)
        // The refusals were not charged to the origin, so nothing after them waits on a pacer.
        #expect(!OriginRequestBudget.shared.isPaced(url))
    }

    @Test("a refused segment is fetched again at the same pace")
    func refusedSegmentRetriesSteadily() async throws {
        // seg9 is refused four times before it is served. The 7.36.0 fetch made three attempts and
        // went terminal.
        let refusals = 4
        let origin = try #require(ScriptedOrigin { path, index in
            if path == "/media.m3u8" {
                return .init(status: 200, body: Self.playlist(count: index == 0 ? 8 : 16, endList: index > 0))
            }
            if let segment = Self.segmentIndex(path) {
                if segment == 9, index < refusals { return .init(status: 509) }
                return .init(status: 200, body: Self.segment(segment))
            }
            return .init(status: 404)
        })
        defer { origin.stop() }

        let url = origin.url("/media.m3u8")
        let reader = HLSLiveIngestReader(playlistURL: url)
        defer { reader.close() }

        let expected = (1..<16).map(Self.segment).reduce(Data(), +)
        let got = try await drain(reader, expectedBytes: expected.count)

        #expect(reader.terminalError == nil)
        #expect(got == expected)
        #expect(origin.requestCount("/seg9.ts") == refusals + 1)
        #expect(!OriginRequestBudget.shared.isPaced(url))
    }

    @Test("a session URL that stays refused is asked for again through the loaded URL")
    func refusedSessionURLIsResolvedAfresh() async throws {
        // The loaded URL redirects to a session URL, as an IPTV panel's does. Once another device
        // has taken the account's last slot, the panel goes on refusing the session it evicted with
        // 509, while a fresh session from the loaded URL is admitted at once.
        let origin = try #require(ScriptedOrigin { path, index in
            switch path {
            case "/live/1.m3u8":
                return .init(status: 302, headers: ["Location": "/hls/session\(index + 1)/media.m3u8"])
            case "/hls/session1/media.m3u8":
                return index == 0
                    ? .init(status: 200, body: Self.playlist(count: 8, endList: false))
                    : .init(status: 509)
            case "/hls/session2/media.m3u8":
                return .init(status: 200, body: Self.playlist(count: 16, endList: true))
            default:
                if let segment = Self.segmentIndex(path) { return .init(status: 200, body: Self.segment(segment)) }
                return .init(status: 404)
            }
        })
        defer { origin.stop() }

        let url = origin.url("/live/1.m3u8")
        let reader = HLSLiveIngestReader(playlistURL: url)
        defer { reader.close() }

        let expected = (1..<16).map(Self.segment).reduce(Data(), +)
        let got = try await drain(reader, expectedBytes: expected.count)

        #expect(reader.terminalError == nil)
        #expect(got == expected)
        #expect(origin.requestCount("/hls/session1/media.m3u8")
                == 1 + HLSLiveIngestReader.sessionURLRefusalsBeforeReresolve)
        #expect(origin.requestCount("/live/1.m3u8") == 2)
        #expect(origin.requestCount("/hls/session2/seg15.ts") == 1)
        #expect(!OriginRequestBudget.shared.isPaced(url))
    }

    @Test("a revoked session URL is asked for again through the loaded URL")
    func revokedSessionURLIsResolvedAfresh() async throws {
        // The loaded URL redirects to a session URL, as an IPTV panel's does. The first session's
        // playlist then answers 403, revoked; the loaded URL hands out a second session, whose
        // playlist lists on with ENDLIST, and whose segments resolve against it.
        let origin = try #require(ScriptedOrigin { path, index in
            switch path {
            case "/live/1.m3u8":
                return .init(status: 302, headers: ["Location": "/hls/session\(index + 1)/media.m3u8"])
            case "/hls/session1/media.m3u8":
                return index == 0
                    ? .init(status: 200, body: Self.playlist(count: 8, endList: false))
                    : .init(status: 403)
            case "/hls/session2/media.m3u8":
                return .init(status: 200, body: Self.playlist(count: 16, endList: true))
            default:
                if let segment = Self.segmentIndex(path) { return .init(status: 200, body: Self.segment(segment)) }
                return .init(status: 404)
            }
        })
        defer { origin.stop() }

        let reader = HLSLiveIngestReader(playlistURL: origin.url("/live/1.m3u8"))
        defer { reader.close() }

        let expected = (1..<16).map(Self.segment).reduce(Data(), +)
        let got = try await drain(reader, expectedBytes: expected.count)

        #expect(reader.terminalError == nil)
        #expect(got == expected)
        #expect(origin.requestCount("/live/1.m3u8") == 2)
        #expect(origin.requestCount("/hls/session1/media.m3u8") == 2)
        #expect(origin.requestCount("/hls/session2/media.m3u8") == 1)
        // The second session's segments were fetched from it.
        #expect(origin.requestCount("/hls/session2/seg15.ts") == 1)
    }

    @Test("a source without a separate session URL still ends on a gone playlist")
    func goneDirectPlaylistIsTerminal() async throws {
        let origin = try #require(ScriptedOrigin { path, index in
            if path == "/media.m3u8" {
                return index == 0
                    ? .init(status: 200, body: Self.playlist(count: 8, endList: false))
                    : .init(status: 404)
            }
            if let segment = Self.segmentIndex(path) { return .init(status: 200, body: Self.segment(segment)) }
            return .init(status: 404)
        })
        defer { origin.stop() }

        let reader = HLSLiveIngestReader(playlistURL: origin.url("/media.m3u8"))
        defer { reader.close() }

        let joined = (1..<8).map(Self.segment).reduce(Data(), +)
        _ = try await drain(reader, expectedBytes: joined.count + 1)
        #expect(reader.terminalError == .playlistUnreachable(status: 404))
        #expect(origin.requestCount("/media.m3u8") == 2)
    }

    @Test("a broken refresh that is not a refusal ends on the short budget")
    func brokenRefreshEndsOnShortBudget() async throws {
        // 502 is a broken gateway, not an origin saying "not now": a dead channel must reach the
        // host's reopen or fallback after the short budget, not after the minute a refusal gets.
        let origin = try #require(ScriptedOrigin { path, index in
            if path == "/media.m3u8" {
                return index == 0
                    ? .init(status: 200, body: Self.playlist(count: 8, endList: false))
                    : .init(status: 502)
            }
            if let segment = Self.segmentIndex(path) { return .init(status: 200, body: Self.segment(segment)) }
            return .init(status: 404)
        })
        defer { origin.stop() }

        let reader = HLSLiveIngestReader(playlistURL: origin.url("/media.m3u8"))
        defer { reader.close() }

        let startedAt = Date()
        let joined = (1..<8).map(Self.segment).reduce(Data(), +)
        _ = try await drain(reader, expectedBytes: joined.count + 1)
        #expect(reader.terminalError == .playlistUnreachable(status: 502))
        // Refreshes are paced at a fixed interval and the deadline is wall time, so a starved runner
        // can only lower this count; the minute a refusal gets would roughly quintuple it.
        let failedRefreshes = origin.requestCount("/media.m3u8") - 1
        let shortBudgetAttempts = Int(HLSLiveIngestReader.unreachableRetryBudget
            / HLSLiveIngestReader.refusedRefreshRetryInterval) + 1
        #expect(failedRefreshes <= shortBudgetAttempts)
        #expect(Date().timeIntervalSince(startedAt) < HLSLiveIngestReader.refreshRetryBudget)
    }

    @Test("only a refusal gets the long retry budget")
    func retryBudgets() {
        for status in [429, 503, 509] {
            #expect(HLSLiveIngestReader.retryBudget(forStatus: status) == HLSLiveIngestReader.refreshRetryBudget)
        }
        for status: Int? in [500, 502, 504, nil] {
            #expect(HLSLiveIngestReader.retryBudget(forStatus: status) == HLSLiveIngestReader.unreachableRetryBudget)
        }
        #expect(HLSLiveIngestReader.unreachableRetryBudget < HLSLiveIngestReader.refreshRetryBudget)
    }

    @Test("the wait between retries is a second, or what the origin asks for up to five")
    func retryWaits() {
        #expect(HLSLiveIngestReader.retryWait(retryAfter: nil) == 1)
        #expect(HLSLiveIngestReader.retryWait(retryAfter: 0) == 1)
        #expect(HLSLiveIngestReader.retryWait(retryAfter: 3) == 3)
        #expect(HLSLiveIngestReader.retryWait(retryAfter: 120) == 5)
        #expect(HLSLiveIngestReader.isGoneStatus(403))
        #expect(HLSLiveIngestReader.isGoneStatus(404))
        #expect(!HLSLiveIngestReader.isGoneStatus(429))
        #expect(!HLSLiveIngestReader.isGoneStatus(408))
        #expect(!HLSLiveIngestReader.isGoneStatus(509))
        #expect(!HLSLiveIngestReader.isGoneStatus(503))
    }

    @Test("a refused session URL gives way to the loaded URL after two refusals, and only a session URL does")
    func refreshURLChoice() {
        let session = URL(string: "http://127.0.0.1:1/hls/s1/media.m3u8")!
        let loaded = URL(string: "http://127.0.0.1:1/live/1.m3u8")!
        func next(_ failures: Int, from current: URL, canReresolve: Bool = true) -> URL {
            HLSLiveIngestReader.nextRefreshURL(after: failures, current: current, sessionURL: session,
                                               loadedURL: loaded, canReresolve: canReresolve)
        }
        #expect(next(1, from: session) == session)
        #expect(next(2, from: session) == loaded)
        #expect(next(5, from: loaded) == loaded)
        #expect(next(9, from: session, canReresolve: false) == session)
    }
}
