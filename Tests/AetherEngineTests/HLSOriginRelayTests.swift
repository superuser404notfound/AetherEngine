// Addressing and rewriting, none of which asks the trust evaluator. The live
// proof that a client which never sees the certificate still gets the stream
// lives with the other tests that set an evaluator, in EngineTLSHandshakeTests.
import Foundation
import Testing

@testable import AetherEngine

@Suite("HLS origin relay addressing and rewriting", .timeLimit(.minutes(3)))
struct HLSOriginRelayAddressingTests {

    private let token = String(repeating: "ab", count: 16)

    @Test("An origin survives the round trip through a relay URL")
    func roundTrip() throws {
        let origin = URL(
            string: "https://media.example.com:8920/videos/1/master.m3u8"
                + "?ApiKey=abc123&PlaySessionId=x%20y&tag=a+b")!
        let local = try #require(HLSOriginRelay.localURL(for: origin, port: 51234, token: token))

        #expect(local.host == "127.0.0.1")
        #expect(local.port == 51234)
        #expect(local.path == "/\(token)\(HLSOriginRelay.route)")
        let recovered = try #require(HLSOriginRelay.originURL(fromQuery: local.query ?? ""))
        #expect(recovered == origin, "recovered \(recovered) from \(origin)")
    }

    @Test("A query that names no origin yields none")
    func rejectsForeignQuery() {
        #expect(HLSOriginRelay.originURL(fromQuery: "") == nil)
        #expect(HLSOriginRelay.originURL(fromQuery: "other=https%3A%2F%2Fa.b") == nil)
    }

    @Test("The origin key keeps scheme, host and port apart")
    func originKeys() {
        #expect(HLSOriginRelay.originKey(for: URL(string: "https://A.example.com/x")!) == "https://a.example.com")
        #expect(HLSOriginRelay.originKey(for: URL(string: "https://a.example.com:8920/x")!) == "https://a.example.com:8920")
        #expect(HLSOriginRelay.originKey(for: URL(string: "http://a.example.com/x")!) == "http://a.example.com")
        #expect(HLSOriginRelay.originKey(for: URL(string: "file:///tmp/x")!) == nil)
    }

    @Test("Sub-resources follow the address the request arrived on")
    func rewriteFollowsTheRequestAuthority() {
        // The AirPlay shape (#86): a receiver reaches the LAN address, and every
        // URI it is handed next has to stay there rather than sending it to a
        // loopback it resolves to itself.
        #expect(HLSOriginRelay.rewriteAuthority(host: "192.168.1.40:51234") == "192.168.1.40")
        #expect(HLSOriginRelay.rewriteAuthority(host: "127.0.0.1:51234") == "127.0.0.1")
        #expect(HLSOriginRelay.rewriteAuthority(host: "[fe80::1]:51234") == "[fe80::1]")
        #expect(HLSOriginRelay.rewriteAuthority(host: nil) == "127.0.0.1")
        #expect(HLSOriginRelay.rewriteAuthority(host: "") == "127.0.0.1")
    }

    @Test("Every URI in a media playlist comes back pointing at the relay")
    func rewritesMediaPlaylist() throws {
        let relay = HLSOriginRelay()
        let origin = URL(string: "https://media.example.com/hls/media.m3u8?ApiKey=k")!
        relay.admit(origin)

        let playlist = """
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-MAP:URI="init.mp4"
            #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k1",IV=0x00
            #EXTINF:6.0,
            seg0.ts
            #EXTINF:6.0,
            https://cdn.example.com/seg1.ts
            #EXT-X-ENDLIST
            """

        let rewritten = relay.rewritePlaylist(
            playlist, relativeTo: origin, authority: "192.168.1.40", port: 51234, token: token)
        let lines = rewritten.components(separatedBy: "\n")

        #expect(lines.first == "#EXTM3U")
        #expect(rewritten.contains("#EXT-X-TARGETDURATION:6"))
        #expect(rewritten.contains("#EXT-X-ENDLIST"))
        // Nothing that names a resource may still point outside.
        #expect(!rewritten.contains("\"init.mp4\""))
        #expect(!rewritten.contains("URI=\"https://keys.example.com/k1\""))
        for line in lines where !line.hasPrefix("#") && !line.isEmpty {
            #expect(line.hasPrefix("http://192.168.1.40:"), "segment line escaped the relay: \(line)")
        }
        for line in lines where line.contains("URI=\"") {
            #expect(line.contains("URI=\"http://192.168.1.40:"), "tag escaped the relay: \(line)")
        }

        // A relative segment resolves against the playlist it came from.
        let segLine = try #require(lines.first { !$0.hasPrefix("#") && !$0.isEmpty })
        let query = try #require(URL(string: segLine)?.query)
        let recovered = try #require(HLSOriginRelay.originURL(fromQuery: query))
        #expect(recovered.absoluteString == "https://media.example.com/hls/seg0.ts")
    }

    @Test("An injected rendition stays with the server that owns it")
    func absoluteOnlyLeavesTheServersOwnRenditions() {
        // The #316 master carries the origin's variants as absolute URIs and the
        // engine's own subtitle renditions as relative ones. Rewriting the second
        // kind would send the player to the origin for a rendition only the
        // engine has.
        let relay = HLSOriginRelay()
        let origin = URL(string: "https://media.example.com/hls/master.m3u8")!
        relay.admit(origin)

        let master = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="subs_0.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=5000000,SUBTITLES="subs"
            https://media.example.com/hls/v0/index.m3u8
            """

        let rewritten = relay.rewritePlaylist(
            master, relativeTo: origin, port: 51234, token: token, absoluteOnly: true)

        #expect(rewritten.contains("URI=\"subs_0.m3u8\""), "the engine's own rendition moved")
        #expect(!rewritten.contains("https://media.example.com/hls/v0/index.m3u8"),
                "the origin's variant stayed at the origin")
        #expect(rewritten.contains("http://127.0.0.1:51234/\(token)\(HLSOriginRelay.route)"))
    }

    @Test("A host discovered in a playlist becomes fetchable, one that was never named does not")
    func allowListFollowsThePlaylist() async throws {
        let relay = HLSOriginRelay()
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }
        // Closed ports on 127.0.0.1, which refuse at once rather than leaving the
        // fetch to time out. Nothing here waits on a name resolving, and the three
        // differ only by port, which the allow list treats as part of the origin.
        let origin = URL(string: "https://127.0.0.1:9/hls/media.m3u8")!
        relay.admit(origin)

        _ = relay.rewritePlaylist(
            "#EXTM3U\n#EXTINF:6.0,\nhttps://127.0.0.1:10/seg1.ts\n", relativeTo: origin,
            port: server.port, token: server.pathToken)

        let named = try #require(server.relayURL(for: URL(string: "https://127.0.0.1:10/seg1.ts")!))
        let stranger = try #require(HLSOriginRelay.localURL(
            for: URL(string: "https://127.0.0.1:11/x.ts")!, port: server.port,
            token: server.pathToken))

        #expect(try await status(of: named) == 502, "the playlist named this host")
        #expect(try await status(of: stranger) == 403, "nothing ever named this host")
    }

    @Test("A request without this session's token never reaches the relay")
    func rejectsForeignToken() async throws {
        let relay = HLSOriginRelay()
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }
        let origin = URL(string: "https://127.0.0.1:9/hls/media.m3u8")!
        relay.admit(origin)

        let stranger = try #require(HLSOriginRelay.localURL(
            for: origin, port: server.port, token: String(repeating: "cd", count: 16)))
        #expect(try await status(of: stranger) == 404, "a stale or scanned token was answered")
    }

    @Test("A blocking-reload request keeps the parameters that make it block")
    func blockingReloadParametersReachTheOrigin() throws {
        // AVPlayer appends _HLS_msn / _HLS_part to a playlist URL that advertises CAN-BLOCK-RELOAD
        // (#441). The relay URL already carries a query, so they arrive alongside `origin`; dropped,
        // the reload answers at once and the player asks again immediately.
        let origin = URL(string: "https://media.example.com/hls/media.m3u8?ApiKey=k")!
        let local = try #require(HLSOriginRelay.localURL(for: origin, port: 51234, token: token))
        let asAVPlayerAsks = "\(local.query ?? "")&_HLS_msn=42&_HLS_part=3"

        let upstream = try #require(HLSOriginRelay.originURL(fromQuery: asAVPlayerAsks))
        #expect(upstream.path == "/hls/media.m3u8")
        let query = try #require(upstream.query)
        #expect(query.contains("ApiKey=k"), "the origin's own query was dropped: \(query)")
        #expect(query.contains("_HLS_msn=42"), "the blocking-reload sequence was dropped: \(query)")
        #expect(query.contains("_HLS_part=3"), "the blocking-reload part was dropped: \(query)")
    }

    // Everything from here to the end of this suite drives a REAL origin, and the origins below
    // are subprocesses: `Process` exists only on macOS, so elsewhere these tests name servers that
    // cannot be built. Without the gate the whole test target fails to COMPILE for iOS and tvOS,
    // which a macOS `swift build` never shows.
    #if os(macOS)

    @Test("A range is forwarded verbatim and its framing comes back")
    func rangesPassThroughUntouched() async throws {
        let upstream = try #require(await RangeEchoOrigin())
        defer { upstream.stop() }
        let relay = HLSOriginRelay()
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }

        let origin = URL(string: "http://127.0.0.1:\(upstream.port)/movie.ts")!
        let entry = try #require(server.relayURL(for: origin))

        var request = URLRequest(url: entry)
        request.timeoutInterval = 15
        request.setValue("bytes=100-199", forHTTPHeaderField: "Range")
        let (body, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 206, "a partial answer was not relayed as one")
        #expect(body.count == 100, "relayed \(body.count) bytes for a 100 byte range")
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 100-199/4096")
        #expect(upstream.lastRange == "bytes=100-199", "the origin saw \(upstream.lastRange ?? "no range")")
    }

    @Test("A metered origin is charged to the budget the reader already reads")
    func refusalReachesTheSharedBudget() async throws {
        let upstream = try #require(await RangeEchoOrigin(status: 429))
        defer { upstream.stop() }
        let relay = HLSOriginRelay()
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }

        let origin = URL(string: "http://127.0.0.1:\(upstream.port)/movie.ts")!
        let entry = try #require(server.relayURL(for: origin))
        _ = try await URLSession.shared.data(for: URLRequest(url: entry))

        // The budget is process-wide and per origin, so a refusal seen here has to be the same
        // refusal the reader and the subtitle prefetcher would have been metered by.
        //
        // Read off the counter and the learned limit rather than `isPaced`. The quiet ladder
        // `isPaced` reports is switched off process-wide by `quietPeriodCapForTesting`, which two
        // other suites set in their init and never restore, so in a full run this suite's answer
        // would be decided by whether one of them happened to have started. The origin's port is
        // this test's own, which is what keeps the counter this test's own.
        let snapshot = try #require(OriginRequestBudget.shared.snapshot(for: origin))
        #expect(snapshot.refusals == 1, "a 429 through the relay was charged \(snapshot.refusals) times")
        #expect(snapshot.limit == 1, "the refusal did not bring the origin's concurrency down")
    }

    @Test("An origin that says the resource is gone is not rewritten into a playlist")
    func errorStatusIsNotLaunderedIntoAPlaylist() async throws {
        // The path looks like a playlist and the body is whatever the origin serves with its 404.
        // Rewritten and framed as 200, that reaches AVPlayer as a parse error instead of as the
        // one word it can act on.
        let upstream = try #require(await RangeEchoOrigin(status: 404))
        defer { upstream.stop() }
        let relay = HLSOriginRelay()
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }

        let origin = URL(string: "http://127.0.0.1:\(upstream.port)/hls/media.m3u8")!
        let entry = try #require(server.relayURL(for: origin))
        #expect(try await status(of: entry) == 404, "a refused playlist came back as a served one")
    }

    @Test("A segment reaches the player while the origin is still sending it")
    func mediaIsRelayedAsItArrives() async throws {
        // Held to the last byte, a segment puts its whole download in front of the player's first
        // byte: AVPlayer abandons a segment whose first byte has not arrived in about 3.5 s (-12889),
        // and it sizes the next rendition off what it measured, which behind a buffer is a loopback
        // burst rather than the link.
        //
        // The origin sends its head and one slice and then holds the rest for far longer than this
        // reader will wait, so the discriminator is whether an answer begins at all rather than a
        // ratio of two durations on a loaded machine.
        //
        // Read off a socket rather than through URLSession: what is being timed is when the relay
        // put an answer on the wire, and a client stack that batches its own delivery would be timed
        // instead. Measured that way this failed on CI while passing here, which is exactly the
        // reading a client in the middle can produce.
        let upstream = try #require(await TricklingOrigin(slices: 2, pauseSeconds: 20))
        defer { upstream.stop() }
        let relay = HLSOriginRelay()
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }

        let origin = URL(string: "http://127.0.0.1:\(upstream.port)/movie.ts")!
        let entry = try #require(server.relayURL(for: origin))

        let answer = try #require(Self.firstBytesOffTheWire(from: entry, waitingUpTo: 10))
        #expect(answer.elapsed < 8,
                "the answer only began after the origin had finished (\(answer.elapsed)s)")
        #expect(answer.text.hasPrefix("HTTP/1.1 200"), "answered: \(answer.text.prefix(64))")
        #expect(answer.text.contains("Content-Length: \(TricklingOrigin.totalBytes(slices: 2))"),
                "the length the origin stated did not survive")
    }

    /// One request on a raw socket, and the moment the first byte of the answer lands.
    private static func firstBytesOffTheWire(from url: URL, waitingUpTo seconds: Int)
        -> (elapsed: TimeInterval, text: String)?
    {
        guard let host = url.host, let port = url.port else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let target = url.path + (url.query.map { "?\($0)" } ?? "")
        let request = "GET \(target) HTTP/1.1\r\nHost: \(host):\(port)\r\n\r\n"
        let wire = Array(request.utf8)
        let sent = wire.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == wire.count else { return nil }

        let started = Date()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let read = buffer.withUnsafeMutableBufferPointer { recv(fd, $0.baseAddress, $0.count, 0) }
        guard read > 0 else { return nil }
        return (Date().timeIntervalSince(started), String(decoding: buffer[0..<read], as: UTF8.self))
    }

    @Test("A body of unstated length is held, and held is not the same as rewritten")
    func heldMediaIsStillMedia() async throws {
        // A body with no Content-Length cannot be framed for the player without measuring it, so it
        // is read whole. What must not follow is that a held body is treated as a playlist: the
        // rewriter would walk MPEG-TS as lines of text.
        let upstream = try #require(await TricklingOrigin(declaresLength: false))
        defer { upstream.stop() }
        let relay = HLSOriginRelay()
        let server = HLSLocalServer(relay: relay)
        try server.start()
        defer { server.stop(); relay.stop() }

        let origin = URL(string: "http://127.0.0.1:\(upstream.port)/movie.ts")!
        let entry = try #require(server.relayURL(for: origin))

        var request = URLRequest(url: entry)
        request.timeoutInterval = 30
        let (body, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(body.count == TricklingOrigin.totalBytes(slices: 8), "relayed \(body.count) bytes")
        #expect(body.allSatisfy { $0 == 0x47 }, "the body came back changed")
    }

    @Test("The relay is wanted only where the system refuses the origin")
    func trustProbeAnswersForTheOriginInHand() async throws {
        // An origin the system reaches is one AVPlayer reaches, so relaying it would move a whole
        // session's bytes through the process for nothing.
        let reachable = try #require(await RangeEchoOrigin())
        defer { reachable.stop() }
        let reached = await HLSOriginRelay.systemTrustRefuses(
            URL(string: "http://127.0.0.1:\(reachable.port)/movie.ts")!)
        #expect(reached == false, "a reachable origin was read as a trust refusal")

        // An origin that is simply down is not a trust refusal either. It fails the direct route as
        // well, and a relay saves nothing.
        let down = await HLSOriginRelay.systemTrustRefuses(URL(string: "https://127.0.0.1:9/x.m3u8")!)
        #expect(down == false, "an unreachable origin was read as a trust refusal")
    }

    #endif

    @Test("A header value from the origin cannot write a second response")
    func headerValuesAreSanitised() {
        let injected = "text/plain\r\nX-Injected: yes\r\n\r\nHTTP/1.1 200 OK"
        let written = HLSLocalServer.headerValue(injected)
        #expect(!written.contains("\r"))
        #expect(!written.contains("\n"))
        #expect(written.hasPrefix("text/plain"))
        #expect(HLSLocalServer.headerValue("bytes 0-99/4096") == "bytes 0-99/4096")
    }

    private func status(of url: URL) async throws -> Int {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

#if os(macOS)

    /// Serves a fixed-length body in slices with a pause between them, so a client can tell a body
    /// that is being relayed as it arrives from one that was read whole first. Nothing else here can
    /// distinguish the two: over loopback a held body is delivered fast enough to look immediate.
    final class TricklingOrigin {
        static let sliceBytes = 64 * 1024
        static func totalBytes(slices: Int) -> Int { sliceBytes * slices }

        let port: UInt16
        private let process: Process
        private let workDir: URL

        init?(slices: Int = 8, pauseSeconds: Double = 0.05, declaresLength: Bool = true) async {
            guard let launched = await PythonOrigin.launch(
                prefix: "aether-trickle-origin",
                script: Self.serverPy(slices: slices, pauseSeconds: pauseSeconds,
                                      declaresLength: declaresLength))
            else { return nil }
            process = launched.process
            port = launched.port
            workDir = launched.workDir
        }

        func stop() {
            process.terminate()
            try? FileManager.default.removeItem(at: workDir)
        }

        private static func serverPy(slices: Int, pauseSeconds: Double, declaresLength: Bool)
            -> String
        {
            """
            import http.server, time

            SLICE = \(sliceBytes)
            SLICES = \(slices)
            PAUSE = \(pauseSeconds)
            DECLARE = \(declaresLength ? "True" : "False")

            class Handler(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *args):
                    pass

                def do_GET(self):
                    self.send_response(200)
                    if DECLARE:
                        self.send_header("Content-Length", str(SLICE * SLICES))
                    else:
                        # No length to state, so the body ends with the connection. URLSession
                        # reports -1 for it, which is the arm that has to be held rather than framed.
                        self.send_header("Connection", "close")
                        self.close_connection = True
                    self.send_header("Content-Type", "video/mp2t")
                    self.end_headers()
                    for _ in range(SLICES):
                        try:
                            self.wfile.write(b"\\x47" * SLICE)
                            self.wfile.flush()
                        except OSError:
                            return
                        time.sleep(PAUSE)

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            print("READY", server.server_address[1], flush=True)
            server.serve_forever()
            """
        }
    }


    /// Loopback HTTP origin that answers Range requests exactly as asked and records the last
    /// one it saw, which is what makes "forwarded verbatim" observable rather than asserted.
    final class RangeEchoOrigin {
        let port: UInt16
        private let process: Process
        private let workDir: URL

        var lastRange: String? {
            let log = workDir.appendingPathComponent("range.log")
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
            return text.split(separator: "\n").last.map(String.init)
        }

        init?(status: Int = 206) async {
            guard let launched = await PythonOrigin.launch(
                prefix: "aether-range-origin", script: Self.serverPy(status: status))
            else { return nil }
            process = launched.process
            port = launched.port
            workDir = launched.workDir
        }

        func stop() {
            process.terminate()
            try? FileManager.default.removeItem(at: workDir)
        }

        private static func serverPy(status: Int) -> String {
            """
            import http.server, re

            TOTAL = 4096
            REFUSE = \(status) if \(status) >= 400 else 0

            class Handler(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *args):
                    pass

                def do_GET(self):
                    raw = self.headers.get("Range", "")
                    with open("range.log", "a") as f:
                        f.write(raw + "\\n")
                    if REFUSE:
                        self.send_response(REFUSE)
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    m = re.match(r"bytes=(\\d+)-(\\d+)", raw)
                    if m:
                        start, end = int(m.group(1)), min(int(m.group(2)), TOTAL - 1)
                        length = end - start + 1
                        self.send_response(206)
                        self.send_header("Content-Range", f"bytes {start}-{end}/{TOTAL}")
                    else:
                        start, length = 0, TOTAL
                        self.send_response(200)
                    self.send_header("Content-Length", str(length))
                    self.send_header("Accept-Ranges", "bytes")
                    self.end_headers()
                    self.wfile.write(b"\\x47" * length)

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            print("READY", server.server_address[1], flush=True)
            server.serve_forever()
            """
        }
    }


    final class SelfSignedHLSOrigin {
        let port: UInt16
        private let process: Process
        private let workDir: URL

        init?() async {
            guard let launched = await PythonOrigin.launch(
                prefix: "aether-hls-origin", script: Self.serverPy,
                files: ["cert.pem": SelfSignedTLSOrigin.certPEM, "key.pem": SelfSignedTLSOrigin.keyPEM])
            else { return nil }
            process = launched.process
            port = launched.port
            workDir = launched.workDir
        }

        func stop() {
            process.terminate()
            try? FileManager.default.removeItem(at: workDir)
        }

        private static let serverPy = """
            import http.server, ssl

            MASTER = (
                "#EXTM3U\\n"
                "#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS=\\"avc1.640028,mp4a.40.2\\"\\n"
                "media.m3u8?token=abc\\n"
            )
            MEDIA = (
                "#EXTM3U\\n"
                "#EXT-X-TARGETDURATION:6\\n"
                "#EXT-X-VERSION:3\\n"
                "#EXTINF:6.0,\\n"
                "seg0.ts\\n"
                "#EXT-X-ENDLIST\\n"
            )
            SEGMENT = b"\\x47" * 4096

            class Handler(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *args):
                    pass

                def do_GET(self):
                    path = self.path.split("?")[0]
                    if path.endswith("master.m3u8"):
                        body, ctype = MASTER.encode(), "application/vnd.apple.mpegurl"
                    elif path.endswith("media.m3u8"):
                        body, ctype = MEDIA.encode(), "application/vnd.apple.mpegurl"
                    elif path.endswith("seg0.ts"):
                        body, ctype = SEGMENT, "video/mp2t"
                    else:
                        self.send_response(404)
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    self.send_response(200)
                    self.send_header("Content-Type", ctype)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain("cert.pem", "key.pem")
            server.socket = ctx.wrap_socket(server.socket, server_side=True)
            print("READY", server.server_address[1], flush=True)
            server.serve_forever()
            """
    }

#endif
