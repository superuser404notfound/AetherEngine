import Testing
import Foundation
@testable import AetherEngine

/// #93 round 3, prevention half: AVPlayer's segment-request timeout (~3.5 s,
/// -12889 "No response for media file") fires on time-to-first-byte. The server
/// held slow requests open without sending anything, so every wedge-window
/// request accumulated -12889 strikes toward failedToPlayToEndTime. A serve
/// that cannot deliver promptly must now emit response headers early
/// (Transfer-Encoding: chunked) and stream the body when the segment lands.
struct Issue93SlowSegmentServeTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    // MARK: - SlowServeSignal

    @Test("signal fires once after the threshold while the serve is still running")
    func signalFiresAfterThreshold() {
        let fired = Counter()
        // Gate on the callback actually firing instead of asserting after a fixed sleep: on a
        // loaded CI runner the 0.05 s timer thread can be scheduled well past a fixed 0.3 s window
        // (it flaked there). Same semaphore-gate discipline as completeIsABarrier below; the
        // generous backstop only elapses on a genuine no-fire, otherwise it returns on the fire.
        let didFire = DispatchSemaphore(value: 0)
        let signal = SlowServeSignal(thresholdSeconds: 0.05) {
            fired.bump()
            didFire.signal()
        }
        let armed = didFire.wait(timeout: .now() + 15) == .success
        signal.complete()
        #expect(armed)
        #expect(fired.value == 1)
    }

    @Test("a serve completing before the threshold never signals")
    func signalCancelledByCompletion() {
        let fired = Counter()
        let signal = SlowServeSignal(thresholdSeconds: 0.2) { fired.bump() }
        signal.complete()
        Thread.sleep(forTimeInterval: 0.4)
        #expect(fired.value == 0)
    }

    @Test("after complete() returns, the callback can no longer be in flight")
    func completeIsABarrier() {
        // The server reads its header-sent flag right after the provider
        // returns; a callback still executing past complete() would race it.
        let fired = Counter()
        // Block until the callback has actually begun, so the barrier assertion never depends on
        // wall-clock scheduling (a fixed sleep flaked in CI when the timer thread was starved and
        // the callback had not started when complete() was called).
        let started = DispatchSemaphore(value: 0)
        let signal = SlowServeSignal(thresholdSeconds: 0.05) {
            started.signal()                     // callback is now in flight
            Thread.sleep(forTimeInterval: 0.2)   // slow callback body
            fired.bump()
        }
        started.wait()                            // wait for the timer to fire the callback
        signal.complete()
        // complete() must have waited for the in-flight callback.
        #expect(fired.value == 1)
    }

    // MARK: - Chunked framing

    @Test("chunked response header advertises chunked and omits Content-Length")
    func chunkedHeaderShape() {
        let header = String(data: HLSLocalServer.chunkedResponseHeader(contentType: "video/mp4"),
                            encoding: .utf8) ?? ""
        #expect(header.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(header.contains("Transfer-Encoding: chunked\r\n"))
        #expect(header.contains("Content-Type: video/mp4\r\n"))
        #expect(!header.contains("Content-Length"))
        #expect(header.hasSuffix("\r\n\r\n"))
    }

    @Test("chunk framing round-trips a payload")
    func chunkFramingRoundTrip() {
        let payload = Data((0..<300).map { UInt8($0 % 251) })
        var wire = HLSLocalServer.chunkFrameHeader(size: payload.count)
        wire.append(payload)
        wire.append(HLSLocalServer.chunkFrameTrailer)
        wire.append(HLSLocalServer.chunkedFinal)
        let decoded = Self.decodeChunkedBody(wire)
        #expect(decoded == payload)
    }

    @Test("chunk size is hex-encoded")
    func chunkHeaderIsHex() {
        #expect(String(data: HLSLocalServer.chunkFrameHeader(size: 26), encoding: .utf8) == "1a\r\n")
    }

    // MARK: - VideoSegmentProvider slow-serve signalling

    private func segments(_ n: Int) -> [HLSVideoEngine.Segment] {
        (0..<n).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
    }

    private func makeProvider(cache: SegmentCache, isLive: Bool = false,
                              slowThreshold: TimeInterval,
                              restartHandler: ((Int) -> Void)? = { _ in },
                              restartActivity: (() -> Bool)? = { false }) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: cache, segments: segments(60), codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 8_000_000, isLive: isLive,
            restartHandler: restartHandler,
            restartActivity: restartActivity,
            repositionWaitSlice: 0.05,
            repositionRideCapSeconds: 5.0,
            slowServeThresholdSeconds: slowThreshold
        )
    }

    @Test("a cache hit never signals slow")
    func cacheHitDoesNotSignal() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        cache.store(index: 5, data: Data(repeating: 0xAB, count: 16))
        let fired = Counter()
        let provider = makeProvider(cache: cache, slowThreshold: 0.02)
        let data = provider.mediaSegment(at: 5, onSlow: { fired.bump() })
        Thread.sleep(forTimeInterval: 0.15)
        #expect(data != nil)
        #expect(fired.value == 0)
    }

    @Test("a serve that outlives the threshold signals slow exactly once")
    func slowServeSignals() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let fired = Counter()
        // Out-of-range fetch, no restart activity, nothing ever delivered:
        // the serve burns its wait slices (~0.6 s) and returns nil.
        let provider = makeProvider(cache: cache, slowThreshold: 0.05)
        let data = provider.mediaSegment(at: 40, onSlow: { fired.bump() })
        #expect(data == nil)
        #expect(fired.value == 1)
    }

    @Test("a slow serve that ultimately delivers signals AND returns the bytes")
    func slowServeStillDelivers() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let fired = Counter()
        let polls = Counter()
        let provider = VideoSegmentProvider(
            cache: cache, segments: segments(60), codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            restartHandler: { _ in },
            restartActivity: { [weak cache] in
                polls.bump()
                if polls.value == 4 { cache?.store(index: 40, data: Data(repeating: 0xCD, count: 8)) }
                return true
            },
            repositionWaitSlice: 0.1,
            repositionRideCapSeconds: 5.0,
            slowServeThresholdSeconds: 0.05
        )
        let data = provider.mediaSegment(at: 40, onSlow: { fired.bump() })
        #expect(data != nil)
        #expect(fired.value == 1)
    }

    @Test("live serves never signal slow (live keeps its own contracts)")
    func liveNeverSignals() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let fired = Counter()
        let provider = makeProvider(cache: cache, isLive: true, slowThreshold: 0.02)
        _ = provider.mediaSegment(at: 40, onSlow: { fired.bump() })
        Thread.sleep(forTimeInterval: 0.1)
        #expect(fired.value == 0)
    }

    // MARK: - Server integration (real sockets)

    /// Minimal HLSSegmentProvider stub whose segment serve can be made slow.
    private final class StubProvider: HLSSegmentProvider, @unchecked Sendable {
        let payload: Data
        /// (delayUntilOnSlow, delayUntilReturn); nil = immediate return.
        let slow: (signalAt: TimeInterval, returnAt: TimeInterval)?
        let returnsNil: Bool

        init(payload: Data, slow: (TimeInterval, TimeInterval)? = nil, returnsNil: Bool = false) {
            self.payload = payload
            self.slow = slow
            self.returnsNil = returnsNil
        }

        func initSegment() -> Data? { Data("ftypinit".utf8) }
        var segmentCount: Int { 4 }
        func segmentDuration(at index: Int) -> Double { 4.0 }
        var playlistType: HLSPlaylistType { .vod }

        func mediaSegment(at index: Int) -> Data? {
            mediaSegment(at: index, onSlow: nil)
        }

        func mediaSegment(at index: Int, onSlow: (@Sendable () -> Void)?) -> Data? {
            guard let slow else { return returnsNil ? nil : payload }
            Thread.sleep(forTimeInterval: slow.signalAt)
            onSlow?()
            Thread.sleep(forTimeInterval: slow.returnAt - slow.signalAt)
            return returnsNil ? nil : payload
        }
    }

    /// Raw-socket GET: returns the response bytes plus the time to first byte,
    /// reading until EOF or `deadline` elapses with no new bytes.
    private static func rawGET(port: UInt16, path: String,
                               deadline: TimeInterval) -> (bytes: Data, firstByteAfter: TimeInterval) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(connected == 0)
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }

        let start = DispatchTime.now()
        var firstByteAfter: TimeInterval = -1
        var collected = Data()
        var lastByteAt = DispatchTime.now()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 {
                if firstByteAfter < 0 {
                    firstByteAfter = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
                }
                collected.append(contentsOf: buf[0..<n])
                lastByteAt = DispatchTime.now()
            } else if n == 0 {
                break   // orderly close
            } else {
                let idle = Double(DispatchTime.now().uptimeNanoseconds - lastByteAt.uptimeNanoseconds) / 1e9
                if idle > deadline { break }
            }
        }
        return (collected, firstByteAfter)
    }

    /// Splits an HTTP/1.1 response blob into (headerString, bodyData).
    private static func splitResponse(_ raw: Data) -> (header: String, body: Data) {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return ("", Data()) }
        let header = String(data: raw[..<sep.lowerBound], encoding: .utf8) ?? ""
        return (header, Data(raw[sep.upperBound...]))
    }

    /// Tiny chunked-transfer decoder for test assertions.
    private static func decodeChunkedBody(_ body: Data) -> Data {
        var out = Data()
        var rest = body
        while let lineEnd = rest.range(of: Data("\r\n".utf8)) {
            let sizeStr = String(data: rest[..<lineEnd.lowerBound], encoding: .utf8) ?? ""
            guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
            if size == 0 { break }
            let chunkStart = lineEnd.upperBound
            let chunkEnd = rest.index(chunkStart, offsetBy: size, limitedBy: rest.endIndex) ?? rest.endIndex
            out.append(rest[chunkStart..<chunkEnd])
            let afterChunk = rest.index(chunkEnd, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex
            rest = rest[afterChunk...]
        }
        return out
    }

    @Test("fast segments keep the exact Content-Length response")
    func fastSegmentUnchanged() throws {
        let payload = Data(repeating: 0x42, count: 4096)
        let provider = StubProvider(payload: payload)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        let (raw, _) = Self.rawGET(port: server.port, path: "/seg1.mp4", deadline: 1.0)
        let (header, body) = Self.splitResponse(raw)
        #expect(header.contains("200 OK"))
        #expect(header.contains("Content-Length: \(payload.count)"))
        #expect(!header.contains("Transfer-Encoding"))
        #expect(body.prefix(payload.count) == payload)
    }

    @Test("slow segments answer with an early chunked header, body follows on landing")
    func slowSegmentEarlyHeader() throws {
        let payload = Data(repeating: 0x37, count: 8192)
        // onSlow at 0.15 s, bytes land at 1.0 s: far beyond the old
        // no-response window, well under AVPlayer's 3.5 s TTFB timeout.
        let provider = StubProvider(payload: payload, slow: (0.15, 1.0))
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        let (raw, firstByteAfter) = Self.rawGET(port: server.port, path: "/seg1.mp4", deadline: 1.0)
        let (header, body) = Self.splitResponse(raw)
        #expect(firstByteAfter >= 0)
        #expect(firstByteAfter < 0.7, "header must arrive near the slow signal, got \(firstByteAfter)s")
        #expect(header.contains("Transfer-Encoding: chunked"))
        #expect(!header.contains("Content-Length"))
        #expect(Self.decodeChunkedBody(body) == payload)
    }

    @Test("a slow serve that ultimately misses aborts the connection instead of framing an empty 200")
    func slowMissAbortsConnection() throws {
        let provider = StubProvider(payload: Data(), slow: (0.1, 0.4), returnsNil: true)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        let (raw, firstByteAfter) = Self.rawGET(port: server.port, path: "/seg1.mp4", deadline: 1.5)
        let (header, body) = Self.splitResponse(raw)
        #expect(firstByteAfter >= 0)
        #expect(header.contains("Transfer-Encoding: chunked"))
        // No terminating zero-chunk: AVPlayer sees a truncated transfer and retries,
        // exactly like a dropped connection (and unlike a cacheable empty 200).
        #expect(!body.suffix(16).elementsEqual(Data("0\r\n\r\n".utf8).suffix(16)) || body.isEmpty)
        #expect(Self.decodeChunkedBody(body).isEmpty)
    }
}
