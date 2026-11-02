import Testing
import Foundation
@testable import AetherEngine

/// `LoadOptions.progressiveSegmentDelivery`: a VOD segment is served while its producer writes it,
/// so AVPlayer can use each fragment as it lands instead of waiting for the segment's cut. On a slow
/// link that wait is a whole segment at the link's rate, which is the time to first frame.
@Suite("Progressive segment delivery", .serialized)
struct ProgressiveSegmentDeliveryTests {

    private func makeCache() -> SegmentCache {
        SegmentCache(baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("progressive-\(UUID().uuidString)", isDirectory: true))
    }

    /// A staging file inside the cache's session directory, as the muxer opens one.
    private func makeStaging(_ cache: SegmentCache, index: Int) throws -> (URL, FileHandle) {
        let url = cache.sessionDir.appendingPathComponent("staging-seg-\(index)-\(UUID().uuidString.prefix(8)).tmp")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return (url, try FileHandle(forWritingTo: url))
    }

    private func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: Int(seed) &+ $0) })
    }

    // MARK: - Cache and reader

    @Test("a reader follows the staging file as it grows and finishes at the seal")
    func readerFollowsGrowthToTheSeal() throws {
        let cache = makeCache()
        defer { cache.close() }
        let (staging, handle) = try makeStaging(cache, index: 3)
        let first = bytes(1000, seed: 1), second = bytes(700, seed: 9)
        handle.write(first)
        cache.beginInProgress(index: 3, stagingPath: staging)

        guard case .progressive(let reader) = cache.fetchSource(index: 3, timeout: 1, progressive: true) else {
            Issue.record("a segment being written is served by a reader"); return
        }
        #expect(reader.next() == .bytes(first))
        handle.write(second)
        #expect(reader.next() == .bytes(second))
        try handle.close()
        cache.adopt(index: 3, stagingPath: staging, byteCount: first.count + second.count)
        #expect(reader.next() == .finished)
        // The sealed segment is plain bytes from here on.
        guard case .data(let sealed) = cache.fetchSource(index: 3, timeout: 1, progressive: true) else {
            Issue.record("an adopted segment is served whole"); return
        }
        #expect(sealed == first + second)
    }

    @Test("an abandoned segment reads as abandoned once its written bytes are drained")
    func abandonedSegment() throws {
        let cache = makeCache()
        defer { cache.close() }
        let (staging, handle) = try makeStaging(cache, index: 5)
        defer { try? handle.close() }
        let partial = bytes(512, seed: 4)
        handle.write(partial)
        cache.beginInProgress(index: 5, stagingPath: staging)
        let reader = try #require(ProgressiveSegmentReader(cache: cache, index: 5, stagingPath: staging))
        #expect(reader.next() == .bytes(partial))
        cache.abandonInProgress(index: 5)
        #expect(reader.next() == .abandoned)
    }

    @Test("a low index sealed after many higher adoptions still finishes (backward seek)")
    func lowIndexSealedAfterManyHigherAdoptions() throws {
        let cache = makeCache()
        defer { cache.close() }
        let payload = bytes(100, seed: 3)
        for index in 100..<(100 + SegmentCache.sealedStagingMemory) {
            let (staging, handle) = try makeStaging(cache, index: index)
            handle.write(payload)
            try handle.close()
            cache.beginInProgress(index: index, stagingPath: staging)
            cache.adopt(index: index, stagingPath: staging, byteCount: payload.count)
        }
        let (staging, handle) = try makeStaging(cache, index: 10)
        handle.write(payload)
        try handle.close()
        cache.beginInProgress(index: 10, stagingPath: staging)
        let reader = try #require(ProgressiveSegmentReader(cache: cache, index: 10, stagingPath: staging))
        #expect(reader.next() == .bytes(payload))
        cache.adopt(index: 10, stagingPath: staging, byteCount: payload.count)
        #expect(reader.next(pollInterval: 0.01, idleTimeout: 0.5) == .finished)
    }

    @Test("a producer that stops writing does not hold a reader forever")
    func idleReaderGivesUp() throws {
        let cache = makeCache()
        defer { cache.close() }
        let (staging, handle) = try makeStaging(cache, index: 1)
        defer { try? handle.close() }
        cache.beginInProgress(index: 1, stagingPath: staging)
        let reader = try #require(ProgressiveSegmentReader(cache: cache, index: 1, stagingPath: staging))
        #expect(reader.next(pollInterval: 0.01, idleTimeout: 0.2) == .abandoned)
    }

    @Test("with the option off, a segment being written is not served until its cut")
    func offWaitsForTheCut() throws {
        let cache = makeCache()
        defer { cache.close() }
        let (staging, handle) = try makeStaging(cache, index: 2)
        defer { try? handle.close() }
        handle.write(bytes(100, seed: 2))
        cache.beginInProgress(index: 2, stagingPath: staging)
        #expect(cache.fetchSource(index: 2, timeout: 0.2, progressive: false) == nil)
    }

    @Test("a seal that renames the file under a reader does not cut it short")
    func readerSurvivesTheRename() throws {
        let cache = makeCache()
        defer { cache.close() }
        let (staging, handle) = try makeStaging(cache, index: 7)
        let body = bytes(300_000, seed: 7)
        handle.write(body)
        try handle.close()
        cache.beginInProgress(index: 7, stagingPath: staging)
        let reader = try #require(ProgressiveSegmentReader(cache: cache, index: 7, stagingPath: staging))
        cache.adopt(index: 7, stagingPath: staging, byteCount: body.count)
        #expect(!FileManager.default.fileExists(atPath: staging.path), "precondition: the staging file was renamed")
        #expect(reader.readToEnd() == body)
    }

    // MARK: - Loopback server

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Serves segment 1 from a cache entry the test writes into.
    private final class CacheProvider: HLSSegmentProvider, @unchecked Sendable {
        let cache: SegmentCache
        let chunks = Counter()
        init(cache: SegmentCache) { self.cache = cache }
        func initSegment() -> Data? { Data("ftypinit".utf8) }
        var segmentCount: Int { 4 }
        func segmentDuration(at index: Int) -> Double { 4.0 }
        var playlistType: HLSPlaylistType { .vod }
        func mediaSegment(at index: Int) -> Data? {
            VideoSegmentProvider.drain(mediaSegmentSource(at: index, onSlow: nil))
        }
        func mediaSegmentSource(at index: Int, onSlow: (@Sendable () -> Void)?) -> SegmentSource? {
            cache.fetchSource(index: index, timeout: 2, progressive: true)
        }
        func didDeliverProgressiveChunk(index: Int) { chunks.bump() }
    }

    @Test("the server sends a segment while it is written and ends it at the seal", .timeLimit(.minutes(3)))
    func serverStreamsWhileWritten() async throws {
        let cache = makeCache()
        defer { cache.close() }
        let (staging, handle) = try makeStaging(cache, index: 1)
        let head = bytes(4096, seed: 3), tail = bytes(8192, seed: 5)
        handle.write(head)
        cache.beginInProgress(index: 1, stagingPath: staging)
        let provider = CacheProvider(cache: cache)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        // The rest of the segment lands 0.8 s after the request; the head must not wait for it.
        let writer = Thread {
            Thread.sleep(forTimeInterval: 0.8)
            handle.write(tail)
            try? handle.close()
            cache.adopt(index: 1, stagingPath: staging, byteCount: head.count + tail.count)
        }
        writer.start()
        let (raw, firstByteAfter) = await Self.get(port: server.port, path: "/\(server.pathToken)/seg1.mp4")
        let (header, body) = Self.splitResponse(raw)
        #expect(firstByteAfter >= 0 && firstByteAfter < 0.6, "the head waited for the cut: \(firstByteAfter)s")
        #expect(header.contains("Transfer-Encoding: chunked"))
        #expect(Self.decodeChunked(body) == .complete(head + tail))
        #expect(provider.chunks.value >= 2, "each chunk is evidence for the wedge watchdog")
    }

    @Test("an abandoned segment ends the connection without the final chunk", .timeLimit(.minutes(3)))
    func serverAbortsAnAbandonedSegment() async throws {
        let cache = makeCache()
        defer { cache.close() }
        let (staging, handle) = try makeStaging(cache, index: 1)
        defer { try? handle.close() }
        let partial = bytes(2048, seed: 6)
        handle.write(partial)
        cache.beginInProgress(index: 1, stagingPath: staging)
        let provider = CacheProvider(cache: cache)   // the server holds its provider weakly
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        let abandon = Thread {
            Thread.sleep(forTimeInterval: 0.4)
            cache.abandonInProgress(index: 1)
        }
        abandon.start()
        let (raw, _) = await Self.get(port: server.port, path: "/\(server.pathToken)/seg1.mp4")
        let (_, body) = Self.splitResponse(raw)
        // A partial body AVPlayer would otherwise take for a whole segment.
        #expect(Self.decodeChunked(body) == .truncated(partial))
        withExtendedLifetime(provider) {}
    }

    // MARK: - Option

    @Test("the option is off by default and a tuning field, not an identity one")
    func optionDefaults() {
        #expect(!LoadOptions().progressiveSegmentDelivery)
        var proposed = LoadOptions()
        proposed.progressiveSegmentDelivery = true
        #expect(SessionOptionCorrection.refusedFields(from: LoadOptions(), to: proposed).isEmpty)
    }

    // MARK: - Helpers

    enum Chunked: Equatable {
        case complete(Data)
        case truncated(Data)
    }

    private static func decodeChunked(_ body: Data) -> Chunked {
        var out = Data()
        var rest = body
        while let lineEnd = rest.range(of: Data("\r\n".utf8)) {
            let sizeLine = String(data: rest[..<lineEnd.lowerBound], encoding: .utf8) ?? ""
            guard let size = Int(sizeLine.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
            if size == 0 { return .complete(out) }
            let start = lineEnd.upperBound
            guard let end = rest.index(start, offsetBy: size, limitedBy: rest.endIndex) else { break }
            out.append(rest[start..<end])
            rest = rest[(rest.index(end, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex)...]
        }
        return .truncated(out)
    }

    private static func splitResponse(_ raw: Data) -> (header: String, body: Data) {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return ("", Data()) }
        return (String(data: raw[..<sep.lowerBound], encoding: .utf8) ?? "", Data(raw[sep.upperBound...]))
    }

    /// Raw-socket GET on its own thread (a blocking `recv` may not sit on the test's thread), read
    /// until the server closes or goes quiet for 30 s. Returns the bytes and the time to first byte.
    /// The quiet bound is only a hang guard (this thread is out of `.timeLimit`'s reach): both tests
    /// end on a terminator or a close, and a loaded runner can leave a live response silent for
    /// well over a second.
    private static func get(port: UInt16, path: String) async -> (Data, TimeInterval) {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: blockingGET(port: port, path: path))
            }
        }
    }

    private static func blockingGET(port: UInt16, path: String) -> (Data, TimeInterval) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0)
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
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
                if collected.range(of: Data("\r\n0\r\n\r\n".utf8)) != nil { break }
            } else if n == 0 {
                break
            } else if Double(DispatchTime.now().uptimeNanoseconds - lastByteAt.uptimeNanoseconds) / 1e9 > 30 {
                break
            }
        }
        return (collected, firstByteAfter)
    }
}
