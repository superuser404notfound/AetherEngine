import Darwin
import Foundation
import Testing
@testable import AetherEngine

/// Audit NET-112 / FEA-107 / DEC-103 / NET-113: segment, key and rendition bodies were read with
/// `session.data(for:)`, which holds the whole body before anyone can look at its size, and the
/// playlist fetch appended one byte at a time. One bounded fetch now serves all of them.
@Suite(.timeLimit(.minutes(3)))
struct BoundedFetchTests {

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: EngineTLS.sessionDelegate, delegateQueue: nil)
    }

    private func request(_ origin: LoopbackBodyOrigin, _ path: String = "/body") -> URLRequest {
        URLRequest(url: URL(string: "http://127.0.0.1:\(origin.port)\(path)")!)
    }

    @Test("an endless body with no declared length is cut off at the cap and the connection is dropped")
    func endlessBodyIsCutOff() async throws {
        let origin = try #require(LoopbackBodyOrigin(body: .endless(chunkBytes: 16 * 1024)))
        defer { origin.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let limit = 512 * 1024
        await #expect(throws: BoundedFetch.Exceeded(limit: limit)) {
            _ = try await BoundedFetch.data(for: request(origin), session: session, limit: limit)
        }
        try await waitFor { origin.clientHungUp }
        #expect(origin.bytesWritten < 200 * 1024 * 1024)
    }

    @Test("a key body is cut off at 64 bytes and a 16 byte key arrives whole")
    func keyBodiesAreBounded() async throws {
        let endless = try #require(LoopbackBodyOrigin(body: .endless(chunkBytes: 1024)))
        let key = try #require(LoopbackBodyOrigin(body: .fixed(16)))
        defer { endless.stop(); key.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        await #expect(throws: BoundedFetch.Exceeded(limit: BoundedFetch.keyLimit)) {
            _ = try await BoundedFetch.data(for: request(endless), session: session, limit: BoundedFetch.keyLimit)
        }
        let (data, response) = try await BoundedFetch.data(
            for: request(key), session: session, limit: BoundedFetch.keyLimit)
        #expect(data.count == 16)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test("a declared length over the cap is refused at the response head")
    func declaredLengthIsRefusedAtTheHead() async throws {
        let origin = try #require(LoopbackBodyOrigin(
            body: .endless(chunkBytes: 16 * 1024), declaredLength: 8 * 1024 * 1024 * 1024))
        defer { origin.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        await #expect(throws: BoundedFetch.Exceeded(limit: 1024 * 1024)) {
            _ = try await BoundedFetch.data(for: request(origin), session: session, limit: 1024 * 1024)
        }
        try await waitFor { origin.clientHungUp }
        #expect(origin.bytesWritten < 16 * 1024 * 1024)
    }

    @Test("a refusal comes back with its status and no body")
    func refusalKeepsItsStatus() async throws {
        let origin = try #require(LoopbackBodyOrigin(body: .endless(chunkBytes: 4096), status: 404))
        defer { origin.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await BoundedFetch.data(for: request(origin), session: session, limit: 1024)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        #expect(data.isEmpty)
    }

    @Test("a body within the cap arrives whole and in order")
    func bodyWithinTheCapArrivesWhole() async throws {
        let size = 3 * 1024 * 1024 + 17
        let origin = try #require(LoopbackBodyOrigin(body: .fixed(size), declaredLength: Int64(size)))
        defer { origin.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let (data, _) = try await BoundedFetch.data(for: request(origin), session: session, limit: 4 * 1024 * 1024)
        #expect(data.count == size)
        #expect(data.prefix(4) == Data([0, 1, 2, 3]))
    }

    @Test("a cancelled fetch ends instead of waiting for its body")
    func cancellationEndsTheFetch() async throws {
        let origin = try #require(LoopbackBodyOrigin(body: .endless(chunkBytes: 4096)))
        defer { origin.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let task = Task { [request = request(origin)] in
            try await BoundedFetch.data(for: request, session: session, limit: 1 << 30)
        }
        try await waitFor { origin.bytesWritten > 0 }
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        try await waitFor { origin.clientHungUp }
    }

    @Test("the playlist wrapper keeps its error text")
    func playlistWrapperKeepsItsError() async throws {
        let origin = try #require(LoopbackBodyOrigin(body: .endless(chunkBytes: 1024)))
        defer { origin.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        await #expect(throws: HLSIngestError.playlistInvalid(reason: "playlist exceeds 4096 bytes")) {
            _ = try await BoundedPlaylistFetch.data(for: request(origin), session: session, limit: 4096)
        }
    }

    @Test("32 MiB of body accumulates in chunks, not byte by byte")
    func largeBodyAccumulatesQuickly() async throws {
        let size = 32 * 1024 * 1024
        let origin = try #require(LoopbackBodyOrigin(body: .fixed(size), declaredLength: Int64(size)))
        defer { origin.stop() }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        // Measured against `session.data(for:)` on the same origin in the same run, not against a wall
        // clock: a loaded suite stretched an absolute sample to 8 s, while the per-byte accumulation this
        // replaced ran about 27x slower than the plain fetch under any load (audit NET-113).
        //
        // Sampled until the bound holds rather than a fixed three times. A loaded suite stalls either
        // fetch for up to 2.7 s against 16 ms unloaded, and all three bounded samples once landed in a
        // stall. A stall only ever adds time, so the best sample converges on the real cost, and the
        // per-byte path is slower in every sample and can never pass.
        let bound = { (plain: Duration) in plain * 4 + .milliseconds(250) }
        var bestPlain = Duration.seconds(3600)
        var bestBounded = Duration.seconds(3600)
        for _ in 0..<12 {
            let plainStart = ContinuousClock.now
            let (plain, _) = try await session.data(for: request(origin))
            bestPlain = min(bestPlain, ContinuousClock.now - plainStart)
            #expect(plain.count == size)
            let boundedStart = ContinuousClock.now
            let (data, _) = try await BoundedPlaylistFetch.data(for: request(origin), session: session, limit: 64 * 1024 * 1024)
            bestBounded = min(bestBounded, ContinuousClock.now - boundedStart)
            #expect(data.count == size)
            if bestBounded < bound(bestPlain) { break }
        }
        #expect(bestBounded < bound(bestPlain), "bounded \(bestBounded) vs plain \(bestPlain)")
    }

    @Test("a segment may weigh 20 MB/s of its own duration between 32 MiB and 256 MiB")
    func segmentLimitFollowsTheDuration() {
        let floor = 32 * 1024 * 1024
        let ceiling = 256 * 1024 * 1024
        #expect(BoundedFetch.segmentLimit(forDuration: 0) == floor)
        #expect(BoundedFetch.segmentLimit(forDuration: -4) == floor)
        #expect(BoundedFetch.segmentLimit(forDuration: .nan) == floor)
        #expect(BoundedFetch.segmentLimit(forDuration: .infinity) == floor)
        #expect(BoundedFetch.segmentLimit(forDuration: 1) == floor)
        #expect(BoundedFetch.segmentLimit(forDuration: 2) == 40_000_000)
        #expect(BoundedFetch.segmentLimit(forDuration: 6) == 120_000_000)
        // A 10 s UHD remux segment at 125 MB is inside its cap.
        #expect(BoundedFetch.segmentLimit(forDuration: 10) >= 125_000_000)
        #expect(BoundedFetch.segmentLimit(forDuration: 600) == ceiling)
    }
}

/// A one-request-per-connection loopback origin whose body can be endless, to see a fetch end where
/// its cap says and to count what the origin managed to write before the client hung up.
private final class LoopbackBodyOrigin: @unchecked Sendable {
    enum Body {
        case endless(chunkBytes: Int)
        case fixed(Int)
    }

    let port: UInt16
    private let listener: LoopbackListener
    private let body: Body
    private let status: Int
    private let declaredLength: Int64?
    private let lock = NSLock()
    private var _bytesWritten = 0
    private var _clientHungUp = false
    private var _connections: Set<Int32> = []

    var bytesWritten: Int { lock.withLock { _bytesWritten } }
    var clientHungUp: Bool { lock.withLock { _clientHungUp } }

    init?(body: Body, status: Int = 200, declaredLength: Int64? = nil) {
        self.body = body
        self.status = status
        self.declaredLength = declaredLength
        guard let listener = LoopbackListener(backlog: 8) else { return nil }
        self.listener = listener
        port = listener.port
        listener.start { [self] fd in
            lock.withLock { _ = _connections.insert(fd) }
            Thread.detachNewThread { [self] in serve(fd) }
            return true
        }
    }

    func stop() {
        lock.lock()
        for fd in _connections { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
        listener.stop()
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.withLock { _ = _connections.remove(fd) }
            close(fd)
        }
        var received = Data()
        var byte: UInt8 = 0
        while !received.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard recv(fd, &byte, 1, 0) == 1 else { return }
            received.append(byte)
        }
        var head = "HTTP/1.1 \(status) X\r\nConnection: close\r\nContent-Type: video/mp2t\r\n"
        if let declaredLength { head += "Content-Length: \(declaredLength)\r\n" }
        head += "\r\n"
        guard write(fd, Array(head.utf8)) else { return hangUp() }
        switch body {
        case .endless(let chunkBytes):
            let chunk = [UInt8](repeating: 0x55, count: chunkBytes)
            while write(fd, chunk) { lock.withLock { _bytesWritten += chunkBytes } }
            hangUp()
        case .fixed(let count):
            // 64 KiB is a multiple of 256, so a repeated ramp stays one continuous ramp.
            let ramp = (0..<64 * 1024).map { UInt8(truncatingIfNeeded: $0) }
            var remaining = count
            while remaining > 0 {
                let size = min(remaining, ramp.count)
                guard write(fd, size == ramp.count ? ramp : Array(ramp.prefix(size))) else { return hangUp() }
                lock.withLock { _bytesWritten += size }
                remaining -= size
            }
        }
    }

    private func hangUp() {
        lock.withLock { _clientHungUp = true }
    }

    private func write(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}
