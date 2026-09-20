// Live-handshake proof for `EngineTLS.serverTrustEvaluator`. The resolver
// unit tests cannot show the load-bearing part: that URLSession actually
// delivers the server-trust challenge to the reader's per-task delegates.
// NWListener rejects an imported in-memory identity with EINVAL, so the
// self-signed origin runs as a Python subprocess, which limits this suite to
// macOS, the platform `swift test` runs on anyway.
#if os(macOS)

    import Foundation
    import Testing

    @testable import AetherEngine

    /// Everything that sets `EngineTLS.serverTrustEvaluator` lives in this one
    /// suite. The evaluator is process global and suites otherwise run in
    /// parallel, so a second suite setting it would decide what this one is
    /// testing.
    /// Every request below goes through `HLSLocalServer`, which is why these clients carry no deadline
/// of their own worth reading: the hang catcher is the `.timeLimit` trait, and 150 s is only there
/// because a URL request must name something. The 15 s they used to carry reported the server as
/// dead twice on CI (`NSURLErrorTimedOut`) while it was merely waiting for a thread.
@Suite("EngineTLS live handshake against a self-signed origin", .serialized, .timeLimit(.minutes(3)))
    struct EngineTLSHandshakeTests {

        /// Lives here rather than beside the resolver tests because reading the
        /// evaluator is as much a claim on the process global as writing it,
        /// and a suite that only reads still races the ones that write.
        @Test("No evaluator is set by default")
        func defaultsToNoEvaluator() {
            #expect(EngineTLS.serverTrustEvaluator == nil)
        }

        @Test("No evaluator: the handshake is refused and no request reaches the origin")
        func refusedByDefault() async throws {
            let server = try #require(await SelfSignedTLSOrigin())
            defer { server.stop() }

            let previous = EngineTLS.serverTrustEvaluator
            defer { EngineTLS.serverTrustEvaluator = previous }
            EngineTLS.serverTrustEvaluator = nil

            let reader = AVIOReader(
                url: URL(string: "https://127.0.0.1:\(server.port)/movie.bin")!,
                chunkRequestTimeout: 5, chunkMaxRetries: 1)
            defer { reader.markClosed(); reader.close() }
            let refusal = Self.openFailure(of: reader)

            try await Task.sleep(for: .seconds(1))
            #expect(server.requestsServed == 0,
                    "a request crossed a handshake that system trust should have refused")
            #expect(Self.isTrustRefusal(refusal),
                    "open failed as \(String(describing: refusal)), not a trust refusal")
        }

        @Test("Accepted for this origin: the same server serves the reader")
        func acceptedWhenOptedIn() async throws {
            let server = try #require(await SelfSignedTLSOrigin())
            defer { server.stop() }

            let previous = EngineTLS.serverTrustEvaluator
            defer { EngineTLS.serverTrustEvaluator = previous }
            EngineTLS.serverTrustEvaluator = { _ in true }

            let reader = AVIOReader(
                url: URL(string: "https://127.0.0.1:\(server.port)/movie.bin")!,
                chunkRequestTimeout: 10, chunkMaxRetries: 2)
            defer { reader.markClosed(); reader.close() }
            try reader.open()

            let sliceCap = 64 * 1024
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
            defer { buf.deallocate() }
            var got = 0
            let deadline = Date().addingTimeInterval(20)
            while got < sliceCap && Date() < deadline {
                let n = reader.read(into: buf, size: Int32(sliceCap - got))
                if n <= 0 { break }
                got += Int(n)
            }
            #expect(got == sliceCap, "delivered \(got) of \(sliceCap) bytes")
            #expect(buf[0] == 0xA7)
            #expect(server.requestsServed > 0)
        }


        @Test("An evaluator that answers for another host leaves this one refused")
        func refusedForAnOriginTheHostDidNotAccept() async throws {
            let server = try #require(await SelfSignedTLSOrigin())
            defer { server.stop() }

            // The case a process-wide flag cannot express: a host holding a LAN
            // address behind a private certificate and a WAN address with a real
            // one, accepting the first without quietly relaxing the second.
            let previous = EngineTLS.serverTrustEvaluator
            defer { EngineTLS.serverTrustEvaluator = previous }
            EngineTLS.serverTrustEvaluator = { $0.host == "media.example" }

            let reader = AVIOReader(
                url: URL(string: "https://127.0.0.1:\(server.port)/movie.bin")!,
                chunkRequestTimeout: 5, chunkMaxRetries: 1)
            defer { reader.markClosed(); reader.close() }
            let refusal = Self.openFailure(of: reader)

            try await Task.sleep(for: .seconds(1))
            #expect(server.requestsServed == 0,
                    "a request crossed a handshake the evaluator did not accept")
            #expect(Self.isTrustRefusal(refusal),
                    "open failed as \(String(describing: refusal)), not a trust refusal")
        }

        @Test("Through the relay: a client that never sees the certificate gets the stream")
        func relayServesThroughUntrustedOrigin() async throws {
            let origin = try #require(await SelfSignedHLSOrigin())
            defer { origin.stop() }

            let previous = EngineTLS.serverTrustEvaluator
            defer { EngineTLS.serverTrustEvaluator = previous }
            EngineTLS.serverTrustEvaluator = { _ in true }

            let server = try Self.relayServer()
            defer { server.stop(); server.relay?.stop() }

            let master = URL(string: "https://127.0.0.1:\(origin.port)/master.m3u8")!
            let entry = try #require(server.relayURL(for: master))

            let playlist = try await Self.text(of: entry)
            #expect(playlist.contains("#EXT-X-STREAM-INF"))
            let variant = try #require(
                playlist.components(separatedBy: "\n").first { $0.hasPrefix("http://127.0.0.1:") })

            let media = try await Self.text(of: try #require(URL(string: variant)))
            #expect(media.contains("#EXTINF"))
            let segmentLine = try #require(
                media.components(separatedBy: "\n").first {
                    $0.hasPrefix("http://127.0.0.1:") && !$0.contains("m3u8")
                })

            var segmentRequest = URLRequest(url: try #require(URL(string: segmentLine)))
            segmentRequest.timeoutInterval = 150
            let (bytes, response) = try await URLSession.shared.data(for: segmentRequest)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(bytes.count == 4096, "served \(bytes.count) segment bytes")
            #expect(bytes.first == 0x47, "not an MPEG-TS sync byte")
        }

        @Test("Through the relay: no evaluator refuses to launder an untrusted origin")
        func relayRefusesWhenNotOptedIn() async throws {
            let origin = try #require(await SelfSignedHLSOrigin())
            defer { origin.stop() }

            let previous = EngineTLS.serverTrustEvaluator
            defer { EngineTLS.serverTrustEvaluator = previous }
            EngineTLS.serverTrustEvaluator = nil

            let server = try Self.relayServer()
            defer { server.stop(); server.relay?.stop() }

            let master = URL(string: "https://127.0.0.1:\(origin.port)/master.m3u8")!
            let entry = try #require(server.relayURL(for: master))

            var request = URLRequest(url: entry)
            request.timeoutInterval = 150
            let (_, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 502,
                    "the upstream handshake should have failed system trust")
        }

        @Test("Through the relay: an origin the evaluator declines is not laundered either")
        func relayRefusesAnOriginTheEvaluatorDeclines() async throws {
            let origin = try #require(await SelfSignedHLSOrigin())
            defer { origin.stop() }

            // The relay is mounted for every https origin once an evaluator
            // exists, so the per-origin answer has to hold at the handshake it
            // makes on the player's behalf.
            let previous = EngineTLS.serverTrustEvaluator
            defer { EngineTLS.serverTrustEvaluator = previous }
            EngineTLS.serverTrustEvaluator = { $0.host == "media.example" }

            let server = try Self.relayServer()
            defer { server.stop(); server.relay?.stop() }

            let master = URL(string: "https://127.0.0.1:\(origin.port)/master.m3u8")!
            let entry = try #require(server.relayURL(for: master))

            var request = URLRequest(url: entry)
            request.timeoutInterval = 150
            let (_, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 502,
                    "an origin the evaluator declined was served anyway")
        }

        @Test("A self-signed origin is what the relay is mounted for")
        func trustProbeNamesTheSelfSignedOrigin() async throws {
            let origin = try #require(await SelfSignedHLSOrigin())
            defer { origin.stop() }

            // The probe asks the system, not the evaluator, so an answer already given here must not
            // change what it reads: what is being measured is whether AVPlayer could reach the origin
            // unaided, and AVPlayer never sees the evaluator.
            let previous = EngineTLS.serverTrustEvaluator
            defer { EngineTLS.serverTrustEvaluator = previous }
            EngineTLS.serverTrustEvaluator = { _ in true }

            let refused = await HLSOriginRelay.systemTrustRefuses(
                URL(string: "https://127.0.0.1:\(origin.port)/master.m3u8")!)
            #expect(refused, "the origin the relay exists for was read as one AVPlayer could reach")
        }

        private static func relayServer() throws -> HLSLocalServer {
            let server = HLSLocalServer(relay: HLSOriginRelay())
            try server.start()
            return server
        }

        private static func text(of url: URL) async throws -> String {
            var request = URLRequest(url: url)
            request.timeoutInterval = 150
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            return String(decoding: data, as: UTF8.self)
        }

        /// A refused handshake reaches the host as a typed failure rather than as unreadable media,
        /// so the refusal arms assert the classification and not only that no byte was served.
        private static func openFailure(of reader: AVIOReader) -> Error? {
            do {
                try reader.open()
                return nil
            } catch {
                return error
            }
        }

        private static func isTrustRefusal(_ error: Error?) -> Bool {
            guard case .transportSecurityFailed = error as? AVIOReaderError else { return false }
            return true
        }
    }

    /// Loopback HTTPS origin with a self-signed certificate for 127.0.0.1,
    /// serving Range requests from a constant 0xA7 body. Every request that
    /// makes it past the TLS handshake is appended to a log file, which is
    /// the refusal observable: a client that distrusts the certificate never
    /// gets a request line onto the wire.
    final class SelfSignedTLSOrigin {
        let port: UInt16
        private let process: Process
        private let workDir: URL

        var requestsServed: Int {
            let log = workDir.appendingPathComponent("requests.log")
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { return 0 }
            return text.split(separator: "\n").count
        }

        init?() async {
            guard let launched = await PythonOrigin.launch(
                prefix: "aether-tls-origin", script: Self.serverPy,
                files: ["cert.pem": Self.certPEM, "key.pem": Self.keyPEM])
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
            import http.server, os, re, ssl, sys

            TOTAL = 4 * 1024 * 1024
            BODY_BYTE = b"\\xa7"

            class Handler(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *args):
                    pass

                def do_GET(self):
                    with open("requests.log", "a") as f:
                        f.write(self.path + "\\n")
                    start, end = 0, TOTAL - 1
                    m = re.match(r"bytes=(\\d*)-(\\d*)", self.headers.get("Range", ""))
                    ranged = bool(m)
                    if m:
                        if m.group(1):
                            start = min(int(m.group(1)), TOTAL - 1)
                        if m.group(2):
                            end = min(int(m.group(2)), TOTAL - 1)
                    length = max(0, end - start + 1)
                    self.send_response(206 if ranged else 200)
                    if ranged:
                        self.send_header("Content-Range", f"bytes {start}-{end}/{TOTAL}")
                    self.send_header("Content-Length", str(length))
                    self.send_header("Accept-Ranges", "bytes")
                    self.end_headers()
                    remaining = length
                    while remaining > 0:
                        chunk = min(remaining, 65536)
                        try:
                            self.wfile.write(BODY_BYTE * chunk)
                        except OSError:
                            return
                        remaining -= chunk

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain("cert.pem", "key.pem")
            server.socket = ctx.wrap_socket(server.socket, server_side=True)
            print("READY", server.server_address[1], flush=True)
            server.serve_forever()
            """

        static let certPEM = """
            -----BEGIN CERTIFICATE-----
            MIIDGjCCAgKgAwIBAgIUPCvl3+omqHtbGt28tTO8nBwZNtwwDQYJKoZIhvcNAQEL
            BQAwFDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MDgwMjA1MjIyOFoXDTM2MDcz
            MDA1MjIyOFowFDESMBAGA1UEAwwJMTI3LjAuMC4xMIIBIjANBgkqhkiG9w0BAQEF
            AAOCAQ8AMIIBCgKCAQEA1dnlqErHwZiOfKnONSyxp+WGfORM8RzCp5dFgm8xJpGi
            R6I/Ly2Tezt2scNP9lBq8AEETtocm9dYObrSp6zHfZi4dUb6ixRc5DkYE8k37WEi
            1/AVAQI7VPpasuuUOrmfeMd3dZOozu+6JprgpJyPzdGuw84dSREsbb1gGaOU/wWt
            R4X0U2IHttV0uVLoj7MzZt1PsMqsimOuuau46TtH/9nwd7NjHykW0+dj8uJKe5Pw
            y20WhT2jf0Ls3leE2fuJfGb1gKaJYY/7vT46F7iJMq7VlstNeKK40OU5MtKKBRbZ
            96A1AZRXwHwhSysJeAo8UZW61wN20MWhrupEx0eAqwIDAQABo2QwYjAdBgNVHQ4E
            FgQUhzShz4pSJL1oBklsC6pzezgk4HUwHwYDVR0jBBgwFoAUhzShz4pSJL1oBkls
            C6pzezgk4HUwDwYDVR0TAQH/BAUwAwEB/zAPBgNVHREECDAGhwR/AAABMA0GCSqG
            SIb3DQEBCwUAA4IBAQCzSx/tNHjYcwWlK0LMBFSVvn6ss3as8rX1U/CUve/AdDCG
            vhC+uew++YqDX2zeibDqN17kqtyY35lvIsWeNMw8QnF+QBofWWLd6YxyE+hnEti5
            Rx3cVpUnJ0MKSprRLRpzSYnSOo6Q42AMl4/ki1VDddIxQixAQzzcHQLZimJsw/kZ
            Efhd1lTbD+ZghMuXpq+JLiylEd3LSW5UvTox1FOe03AVEQAMeWPcZwoEBtm3Qsbn
            ahzZULJX/KFQHDfLD337xzfgNYR2w77rx6yaCUzrHZXha8qpevV3tMc1s/pi2KJ5
            wAWlaPiab3bnQj5zmw4VdYBFptCfRRcLTZuCKTwu
            -----END CERTIFICATE-----
            """

        static let keyPEM = """
            -----BEGIN PRIVATE KEY-----
            MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDV2eWoSsfBmI58
            qc41LLGn5YZ85EzxHMKnl0WCbzEmkaJHoj8vLZN7O3axw0/2UGrwAQRO2hyb11g5
            utKnrMd9mLh1RvqLFFzkORgTyTftYSLX8BUBAjtU+lqy65Q6uZ94x3d1k6jO77om
            muCknI/N0a7Dzh1JESxtvWAZo5T/Ba1HhfRTYge21XS5UuiPszNm3U+wyqyKY665
            q7jpO0f/2fB3s2MfKRbT52Py4kp7k/DLbRaFPaN/QuzeV4TZ+4l8ZvWApolhj/u9
            PjoXuIkyrtWWy014orjQ5Tky0ooFFtn3oDUBlFfAfCFLKwl4CjxRlbrXA3bQxaGu
            6kTHR4CrAgMBAAECggEAFrD6R3M34vj3FY9HDClj6HbYYGQxLdxpYzMP8xktU/Rc
            DdHPdogVgBv9KjuZPn+l+TWCaYOHSZn+CJIkTBpvSIpt+DPB3gQZHzZXsbHGN2/5
            LISTFfpQpWGzQgzxO5H6s+wmZtl2Lg8N547Di3P5ZlN7gddbECe8WSChE9dhtfWI
            kjf+zh4dlTeU8RB+NT9puqASWuvePx+D2N1ySUFM+eVKV4T4M2UtYBG/fT33cbaP
            qY6J2kGnQvETzqMHfE+9vb0jWJpVs+Zkii4p0OB3iS66ZDPdbW+pdVmWHVvvq+IH
            ZQL2yWBvE7y9m5qRuC8kX8tabcbPjEi8NEVC6xuhgQKBgQDxCOilXiPRtl7S4+d8
            iYwLVyctr/2sVtTXLvTwXJj3Xr2dUJWggrhxBqI2PvAFHhWAnils3xuAf0+Orly1
            oGfr35fQb3IH6FKnSj/uoYiXMsjsDgOypNmg5KyWM4kqDW27HJq/PioC6MJzAeO/
            WjOE0cWVjKW1qyIkgz+T6jsBiwKBgQDjIOwNIa38vqwBc3F8c8wLWHZDLBXGS1kh
            5AyW+QcZ9EyKozPbxyqZrmEZa0v/IxuUniBq0O27dXJF09eJrAVd8dDMW0kJTmKk
            ddbB44MzsADgE2jJiEcu22VZCoy0kjbODHw6L9KR8k+utx97fgl/p+BC/nwv6jYi
            pXcI6EshYQKBgAeM9OTBRzP5l4zZsNW45VcxmruWqMauTaqUAP5KmEwffqcf8CAA
            GFEKGSjD3fb7E0ddLQUJFC55Tn+0vJi/9qFv9qyD4TmYMIanD8uk6cd6wsqKQdll
            yp98ql9mK+TSWN6krcBR7TT8H6NEquLCq5x8icj+h+5h9wbXybUTgFezAoGBAOKQ
            TqdytzntgWsZG1WHtTyEC8RJz5a0Rr812xEmbF0Jguiwj+RmMiqG9jkC/RYOkU6Y
            xcGHk/1w1IKvJMwiGmBx/VQ8owhzdpaTLZzPNGt04Aqlkdum40rsc5Z0nZLqX1z+
            u1TXq3cGfVHNPcxUF2mNrnllnb+2JDY/VBRAk+FBAoGAI+Nb/JgYjihUqiqKcK0t
            76scm4eNsR6wl1WWsZUMZlVVfQr8BqjIxz5yB8qTqdEMgMe0M/RdDgsqm8UIc9q6
            GCRPZZR6CB0MobtvS9eczqo4Ov6pEnIk2I6T2oNuXbqscNJgWSHFGoK3Bl1aPJsa
            TqL2wDYvLDkN1MEol+GDgSM=
            -----END PRIVATE KEY-----
            """
    }

#endif
