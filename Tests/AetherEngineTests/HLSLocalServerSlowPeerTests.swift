import Foundation
import Testing
@testable import AetherEngine

/// The listener answers the whole LAN while AirPlay needs it (#86), and the session token is read only
/// after a complete request head. These pin what keeps a peer that never presents one from holding the
/// slots the local player needs (audit NET-6), plus the two accept-loop diagnostics (NET-12, NET-13).
@Suite("HLS local server against slow and silent peers", .serialized, .timeLimit(.minutes(2)))
struct HLSLocalServerSlowPeerTests {

    @Test("A connection that never sends a request head is dropped at the head deadline")
    func idleStrangerIsDropped() async throws {
        let server = HLSLocalServer(provider: StubProvider(), unauthenticatedHeadSeconds: 0.5)
        try server.start()
        defer { server.stop() }

        let fd = try #require(Self.connect(port: server.port, host: "127.0.0.1"))
        defer { close(fd) }

        // Observed from the client side: the server may drop the connection before a poll of its
        // count ever sees it, which on a loaded run left a wait for "count == 1" parked forever.
        // The old per-recv timeout was 60 s, so closing well inside that is the fix.
        #expect(await Self.onOwnThread { Self.peerCloses(fd: fd, within: 20) },
                "an idle unauthenticated connection kept its slot")
        try await waitFor { server.activeConnectionCount == 0 }
    }

    @Test("A peer trickling its head one byte at a time is dropped at the head deadline")
    func tricklingStrangerIsDropped() async throws {
        let server = HLSLocalServer(provider: StubProvider(), unauthenticatedHeadSeconds: 1)
        try server.start()
        defer { server.stop() }

        let fd = try #require(Self.connect(port: server.port, host: "127.0.0.1"))
        let trickle = Trickle(fd: fd)
        defer { trickle.stop(); close(fd) }

        #expect(await Self.onOwnThread { Self.peerCloses(fd: fd, within: 20) },
                "a byte every 200 ms kept an unauthenticated connection open")
        try await waitFor { server.activeConnectionCount == 0 }
    }

    @Test("A connection that presented the token keeps its keep-alive idle past the stranger deadline")
    func authenticatedKeepAliveSurvives() async throws {
        // The stranger deadline runs from accept, so it must leave room for a worker thread that a
        // loaded runner schedules late, or the first request is dropped before it is read.
        let server = HLSLocalServer(provider: StubProvider(), unauthenticatedHeadSeconds: 2)
        try server.start()
        defer { server.stop() }

        let fd = try #require(Self.connect(port: server.port, host: "127.0.0.1"))
        defer { close(fd) }
        let path = "/\(server.pathToken)/media.m3u8"
        #expect(await Self.onOwnThread { Self.requestStatus(fd: fd, path: path) } == 200)
        try await Task.sleep(for: .milliseconds(3000))
        #expect(await Self.onOwnThread { Self.requestStatus(fd: fd, path: path) } == 200,
                "the second request on an authenticated keep-alive connection was not answered")
    }

    @Test("LAN peers cannot take the slots kept for loopback",
          .enabled(if: HLSLocalServer.localActiveIPAddress() != nil))
    func lanPeersLeaveLoopbackSlots() async throws {
        let lanIP = try #require(HLSLocalServer.localActiveIPAddress())
        let server = HLSLocalServer(provider: StubProvider(), unauthenticatedHeadSeconds: 60)
        try server.start()
        defer { server.stop() }

        var held: [Int32] = []
        defer { held.forEach { close($0) } }
        for _ in 0 ..< HLSLocalServer.maxConcurrentConnections + 2 {
            if let fd = Self.connect(port: server.port, host: lanIP) { held.append(fd) }
        }
        // Both waits are bounded under the suite's limit only to say which one stalled: CI ran this
        // test into the limit once (2026-11-08) with nothing to read, and it does not reproduce locally.
        let lanShareTaken = try await waitFor(upTo: .seconds(50)) {
            server.activeConnectionCount >= HLSLocalServer.maxNonLoopbackConnections
        }
        try #require(lanShareTaken, "\(held.count) LAN connects succeeded, server counts \(server.activeConnectionCount)")
        #expect(server.activeConnectionCount == HLSLocalServer.maxNonLoopbackConnections)

        let fd = try #require(Self.connect(port: server.port, host: "127.0.0.1"))
        defer { close(fd) }
        let path = "/\(server.pathToken)/media.m3u8"
        #expect(await Self.onOwnThread { Self.requestStatus(fd: fd, path: path, timeoutSeconds: 50) } == 200,
                "a loopback player was refused while LAN peers held their share (0 = no answer within 50 s); server counts \(server.activeConnectionCount)")
    }

    @Test("The stop line names the port that was released")
    func stopLineNamesThePort() throws {
        let tap = EngineLogCapture()
        defer { tap.end() }
        let server = HLSLocalServer(provider: StubProvider())
        try server.start()
        let port = server.port
        server.stop()
        #expect(!tap.matching("[HLSLocalServer] stop: port \(port) released").isEmpty)
        #expect(tap.matching("[HLSLocalServer] stop: port 0 released").isEmpty)
    }

    /// Audit NET-111: every tokenless request cost the host's log two unthrottled lines, so a LAN
    /// peer looping short connections could scroll a 300-line ring in a fraction of a second.
    @Test("A flood of tokenless requests costs the log a handful of lines")
    func tokenlessFloodIsThrottled() async throws {
        let tap = EngineLogCapture()
        defer { tap.end() }
        let server = HLSLocalServer(provider: StubProvider())
        try server.start()
        defer { server.stop() }
        let marker = "flood-\(UUID().uuidString)"
        let port = server.port

        let answered = await Self.onOwnThread { () -> Int in
            var answered = 0
            for _ in 0 ..< 1000 {
                guard let fd = Self.connect(port: port, host: "127.0.0.1") else { continue }
                if Self.requestStatus(fd: fd, path: "/\(marker)/media.m3u8") == 404 { answered += 1 }
                close(fd)
            }
            return answered
        }
        #expect(answered == 1000)
        #expect(tap.matching(marker).count <= 3, "\(tap.matching(marker).count) lines for 1000 requests")
    }

    @Test("Attacker text is logged with its control characters escaped")
    func controlCharactersAreEscaped() {
        #expect(HLSLocalServer.escapedForLog("GET /x\n[HLSLocalServer] GET /forged HTTP/1.1")
                == "GET /x\\x0A[HLSLocalServer] GET /forged HTTP/1.1")
        #expect(HLSLocalServer.escapedForLog("a\u{7F}b\tc\u{0}") == "a\\x7Fb\\x09c\\x00")
        #expect(HLSLocalServer.escapedForLog("GET /seg_1.m4s HTTP/1.1") == "GET /seg_1.m4s HTTP/1.1")
        #expect(HLSLocalServer.escapedForLog(String(repeating: "a", count: 300), limit: 256)
                == String(repeating: "a", count: 256) + "...")
    }

    @Test("A repeating failure line goes out once per interval with a tally of the rest")
    func throttleCountsWhatItHeldBack() {
        var throttle = LogThrottle(interval: 5)
        #expect(throttle.admit(now: 100) == 0)
        #expect(throttle.admit(now: 100.1) == nil)
        #expect(throttle.admit(now: 104.9) == nil)
        #expect(throttle.admit(now: 105) == 2)
        #expect(throttle.admit(now: 106) == nil)
        #expect(throttle.admit(now: 200) == 1)
    }

    // MARK: - Helpers

    private static func connect(port: UInt16, host: String) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// One keep-alive GET on an open connection; the status, or 0. Reads until the declared body
    /// has arrived so the next request on the same socket starts clean.
    private static func requestStatus(fd: Int32, path: String, timeoutSeconds: Int = 120) -> Int {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let sent = Array(request.utf8).withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent > 0 else { return 0 }
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { return 0 }
            received.append(chunk, count: n)
            guard let text = String(data: received, encoding: .utf8),
                  let headEnd = text.range(of: "\r\n\r\n") else { continue }
            let head = text[..<headEnd.lowerBound]
            let length = head.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let bodySoFar = received.count - text[..<headEnd.upperBound].utf8.count
            guard bodySoFar >= length else { continue }
            let parts = (head.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
            return parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
        }
    }

    /// True once the server has closed or reset `fd`, false if it is still open after `seconds`.
    private static func peerCloses(fd: Int32, within seconds: Int) -> Bool {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var chunk = [UInt8](repeating: 0, count: 512)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n == 0 { return true }
            if n < 0 { return errno == ECONNRESET }
        }
    }

    private static func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: body()) }
        }
    }
}

/// Sends one byte of a request head every 200 ms from its own thread until stopped or refused.
private final class Trickle: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    init(fd: Int32) {
        Thread.detachNewThread { [self] in
            let head = Array("GET / HTTP/1.1\r\nHost: x\r\nX-Pad: \(String(repeating: "a", count: 400))\r\n\r\n".utf8)
            for byte in head {
                if isStopped { return }
                var one = byte
                if send(fd, &one, 1, 0) != 1 { return }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }
}

private final class StubProvider: HLSSegmentProvider, @unchecked Sendable {
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { 1 }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .vod }
}
