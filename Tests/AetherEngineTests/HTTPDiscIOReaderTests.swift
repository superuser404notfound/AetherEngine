// Remote disc-image IOReader over HTTP byte-range requests (#64 follow-up: network .iso playback).
// Pure helpers are unit-tested directly; read/seek correctness and disc detection over HTTP are
// tested against an in-process mock URLProtocol that serves byte ranges from fixture bytes, so no
// real network or server is involved.
import Foundation
import Testing
@testable import AetherEngine

// Serialized: the tests share MockRangeURLProtocol's static byte store keyed by URL; running them
// in parallel would let one test's fixture bytes answer another's request.
@Suite("HTTPDiscIOReader (#64 remote disc images)", .serialized, .offCooperativePool)
struct HTTPDiscIOReaderTests {

    // MARK: - Pure helpers

    @Test("Range header spans the requested half-open window inclusively")
    func rangeHeader() {
        #expect(HTTPDiscIOReader.rangeHeader(offset: 0, length: 1) == "bytes=0-0")
        #expect(HTTPDiscIOReader.rangeHeader(offset: 2048, length: 4096) == "bytes=2048-6143")
    }

    @Test("Content-Range total is parsed; unknown size (*) is nil")
    func contentRange() {
        #expect(HTTPDiscIOReader.parseContentRangeTotal("bytes 0-0/12345") == 12345)
        #expect(HTTPDiscIOReader.parseContentRangeTotal("bytes 2048-6143/34960244736") == 34_960_244_736)
        #expect(HTTPDiscIOReader.parseContentRangeTotal("bytes 0-0/*") == nil)
        #expect(HTTPDiscIOReader.parseContentRangeTotal("garbage") == nil)
    }

    @Test("Disc-image URL detection gates the HTTP disc path")
    func discImageURL() {
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/movie.iso")!) == true)
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/MOVIE.ISO")!) == true)
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/disc.img")!) == true)
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/video.mp4")!) == false)
        #expect(Demuxer.isDiscImageURL(URL(string: "https://h/stream.m3u8")!) == false)
    }

    @Test("Read-ahead window grows on sequential continuation and resets otherwise")
    func adaptiveWindow() {
        // Sequential continuation (position == lastFetchEnd) doubles, capped at maxChunk.
        #expect(HTTPDiscIOReader.nextChunkSize(position: 4096, lastFetchEnd: 4096, current: 4096,
                                               base: 4096, maxChunk: 32768) == 8192)
        #expect(HTTPDiscIOReader.nextChunkSize(position: 8192, lastFetchEnd: 8192, current: 8192,
                                               base: 4096, maxChunk: 32768) == 16384)
        #expect(HTTPDiscIOReader.nextChunkSize(position: 99999, lastFetchEnd: 99999, current: 32768,
                                               base: 4096, maxChunk: 32768) == 32768)  // capped
        // A non-contiguous read (seek) resets to base.
        #expect(HTTPDiscIOReader.nextChunkSize(position: 200000, lastFetchEnd: 8192, current: 16384,
                                               base: 4096, maxChunk: 32768) == 4096)
        // No prior refill yet -> base.
        #expect(HTTPDiscIOReader.nextChunkSize(position: 0, lastFetchEnd: -1, current: 4096,
                                               base: 4096, maxChunk: 32768) == 4096)
    }

    // MARK: - Read / seek over a mock range server

    private func makeReader(_ bytes: [UInt8], base: Int = 4096, maxChunk: Int = 4096,
                            streamRange: Int = 64 * 1024 * 1024,
                            failFirst: Int = 0) -> HTTPDiscIOReader? {
        let url = URL(string: "http://disc.test/test.iso")!
        MockRangeURLProtocol.reset()
        MockRangeURLProtocol.bytesByURL[url.absoluteString] = Data(bytes)
        if failFirst > 0 { MockRangeURLProtocol.failFirstForURL[url.absoluteString] = failFirst }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRangeURLProtocol.self]
        return HTTPDiscIOReader(url: url, baseChunkSize: base, maxChunkSize: maxChunk,
                                streamRangeSize: streamRange,
                                requestTimeout: 5, sessionConfiguration: config)
    }

    // MARK: - #1007 progressive sequential ranges

    /// Runs `read` on its own thread, so a read that blocks on the network fails the test instead
    /// of hanging it (a Swift Testing time limit cannot stop a blocked thread).
    private func readOffThread(_ r: HTTPDiscIOReader, size: Int,
                               within seconds: Double) -> (n: Int32, bytes: [UInt8])? {
        let done = DispatchSemaphore(value: 0)
        let box = ReadBox()
        Thread.detachNewThread {
            var out = [UInt8](repeating: 0, count: size)
            let n = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: Int32(size)) }
            box.set(n, out)
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return box.get()
    }

    private func readAll(_ r: HTTPDiscIOReader, count: Int) -> [UInt8] {
        var got: [UInt8] = []
        var out = [UInt8](repeating: 0, count: 50_000)
        while got.count < count {
            let n = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 50_000) }
            guard n > 0 else { break }
            got += out[0..<Int(n)]
        }
        return got
    }

    private static let streamStart = 64 * 1024

    @Test("#1007: a sequential read is served from the bytes that arrived, not the response tail")
    func progressiveReadDoesNotWaitForTheTail() throws {
        let src = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let r = try #require(makeReader(src, streamRange: 256 * 1024))
        defer { r.cancel() }
        MockRangeURLProtocol.stallFromOffset = Self.streamStart
        MockRangeURLProtocol.stallAfterBytes = 32 * 1024
        #expect(readOffThread(r, size: Self.streamStart, within: 5)?.n == Int32(Self.streamStart))
        let second = try #require(readOffThread(r, size: 4096, within: 3),
                                  "the read waited on a response tail that never came")
        #expect(second.n == 4096)
        #expect(second.bytes == Array(src[Self.streamStart..<(Self.streamStart + 4096)]))
    }

    @Test("#1007: a short body resumes at the next unread byte")
    func shortBodyResumesAtTheFrontier() throws {
        let src = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        let r = try #require(makeReader(src, streamRange: 256 * 1024))
        MockRangeURLProtocol.shortBodyOnceFromOffset = Self.streamStart
        MockRangeURLProtocol.shortBodyBytes = 32 * 1024
        #expect(readAll(r, count: src.count) == src)
        let resumed = "bytes=\(Self.streamStart + 32 * 1024)-"
        #expect(MockRangeURLProtocol.requestedRanges.contains { $0.hasPrefix(resumed) })
    }

    @Test("#1007: sequential playback chains bounded ranges and still seeks")
    func streamChainsRangesAndSeeks() throws {
        let src = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let r = try #require(makeReader(src, streamRange: 192 * 1024))
        #expect(readAll(r, count: src.count) == src)
        let streamRequests = MockRangeURLProtocol.requestedRanges.filter {
            !$0.hasPrefix("bytes=0-")
        }
        #expect(streamRequests.count >= 5)
        #expect(r.seek(offset: 100, whence: SEEK_SET) == 100)
        let back = try #require(readOffThread(r, size: 100, within: 3))
        #expect(back.bytes == Array(src[100..<200]))
    }

    @Test("#1007: once playback streamed, any sequential continuation streams; discovery still ramps")
    func playbackStreamsEveryContinuation() {
        // Discovery: a continuation below the top of the window keeps ramping.
        #expect(!HTTPDiscIOReader.streams(position: 8192, lastFetchEnd: 8192, nextChunk: 8192,
                                          maxChunk: 65536, streamRange: 262_144))
        #expect(HTTPDiscIOReader.streams(position: 8192, lastFetchEnd: 8192, nextChunk: 8192,
                                         maxChunk: 65536, streamRange: 262_144, playback: true))
        // A jump is never a continuation, playback or not: the first read after a seek stays small.
        #expect(!HTTPDiscIOReader.streams(position: 900_000, lastFetchEnd: 8192, nextChunk: 4096,
                                          maxChunk: 65536, streamRange: 262_144, playback: true))
    }

    @Test("#1007: after a seek in playback, the continuation streams instead of re-ramping")
    func seekInPlaybackRestreams() throws {
        // The reader floors its base window at 64 KiB, so the ramp is 64, 128, 256, 512 KiB.
        let base = 64 * 1024, range = 1024 * 1024
        let src = (0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 11) }
        let r = try #require(makeReader(src, base: base, maxChunk: 512 * 1024, streamRange: range))
        defer { r.cancel() }
        let played = readAll(r, count: 2 * 1024 * 1024)
        #expect(played == Array(src[0..<played.count]))
        // Backwards, so the target is outside what the stream holds (the mock ignores suspend and
        // buffers ahead to EOF).
        let target = 128 * 1024
        #expect(r.seek(offset: Int64(target), whence: SEEK_SET) == Int64(target))
        let first = try #require(readOffThread(r, size: base, within: 3))
        #expect(first.bytes == Array(src[target..<(target + base)]))
        let next = try #require(readOffThread(r, size: 4096, within: 3))
        #expect(next.bytes == Array(src[(target + base)..<(target + base + 4096)]))
        let ranges = MockRangeURLProtocol.requestedRanges
        #expect(ranges.contains("bytes=\(target)-\(target + base - 1)"), "\(ranges)")
        let streamed = ranges.last { $0.hasPrefix("bytes=\(target + base)-") }
        #expect(streamed == "bytes=\(target + base)-\(target + base + range - 1)",
                "the continuation re-ramped instead of streaming: \(ranges)")
    }

    @Test("#1007: a streamed range that starts elsewhere is refused")
    func misplacedStreamRangeIsRefused() throws {
        let src = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0) }
        let r = try #require(makeReader(src, streamRange: 256 * 1024))
        #expect(readOffThread(r, size: Self.streamStart, within: 5)?.n == Int32(Self.streamStart))
        MockRangeURLProtocol.misrangedFor.insert("http://disc.test/test.iso")
        let next = try #require(readOffThread(r, size: 4096, within: 10))
        #expect(next.n == -1)
    }

    @Test("#1007: cancel wakes a read parked on a stalled stream")
    func cancelWakesAStalledStream() throws {
        let src = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0) }
        let r = try #require(makeReader(src, streamRange: 256 * 1024))
        MockRangeURLProtocol.stallFromOffset = Self.streamStart
        MockRangeURLProtocol.stallAfterBytes = 0
        #expect(readOffThread(r, size: Self.streamStart, within: 5)?.n == Int32(Self.streamStart))
        Thread.detachNewThread { Thread.sleep(forTimeInterval: 0.3); r.cancel() }
        let parked = try #require(readOffThread(r, size: 4096, within: 3), "cancel did not wake the read")
        #expect(parked.n == -1)
    }

    @Test("AVSEEK_SIZE returns the total size from the range probe")
    func sizeProbe() {
        let r = makeReader([UInt8](0..<200))
        #expect(r != nil)
        #expect(r?.seek(offset: 0, whence: 65536) == 200)  // AVSEEK_SIZE
    }

    @Test("Sequential and random reads return the exact source bytes")
    func reads() throws {
        let src = (0..<10_000).map { UInt8($0 & 0xff) }
        let r = try #require(makeReader(src))
        var out = [UInt8](repeating: 0, count: 6000)
        // sequential read across chunk boundaries (chunkSize 4096)
        let n1 = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 6000) }
        #expect(n1 > 0)
        #expect(Array(out[0..<Int(n1)]) == Array(src[0..<Int(n1)]))
        // random seek then read
        #expect(r.seek(offset: 8192, whence: SEEK_SET) == 8192)
        var out2 = [UInt8](repeating: 0, count: 100)
        let n2 = out2.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 100) }
        #expect(n2 == 100)
        #expect(Array(out2[0..<100]) == Array(src[8192..<8292]))
    }

    @Test("Reading at EOF returns 0; seek past end then read is empty")
    func eof() throws {
        let r = try #require(makeReader([UInt8](repeating: 7, count: 50)))
        #expect(r.seek(offset: 50, whence: SEEK_SET) == 50)
        var out = [UInt8](repeating: 0, count: 16)
        let n = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 16) }
        #expect(n == 0)
    }

    @Test("A transient request failure is retried")
    func retry() throws {
        let src = (0..<2000).map { UInt8($0 & 0xff) }
        let r = try #require(makeReader(src))  // probe succeeds cleanly
        // Inject one network failure for the first read's range request; the retry must recover it.
        MockRangeURLProtocol.failFirstForURL["http://disc.test/test.iso"] = 1
        var out = [UInt8](repeating: 0, count: 100)
        let n = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 100) }
        #expect(n == 100)
        #expect(Array(out[0..<100]) == Array(src[0..<100]))
    }

    // audit NET-9: a 206 that claims a different start than what was requested must never be
    // accepted; the reader would otherwise place those bytes at `position` and corrupt whatever
    // structure or stream is read through it.
    @Test("A 206 whose Content-Range start does not match the request is refused, not served")
    func misrangedResponseIsRefused() throws {
        let src = (0..<2000).map { UInt8($0 & 0xff) }
        let r = try #require(makeReader(src))  // the offset-0 probe is unaffected and succeeds
        MockRangeURLProtocol.misrangedFor.insert("http://disc.test/test.iso")
        #expect(r.seek(offset: 1000, whence: SEEK_SET) == 1000)
        var out = [UInt8](repeating: 0, count: 100)
        let n = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 100) }
        #expect(n == -1)
    }

    // audit NET-9: a proxy that falls back to a full 200 mid-session (cache miss, range
    // coalescing, a Range-stripping origin) must be treated as fatal for this reader, not read as
    // if byte 0 of the body were the requested offset.
    @Test("A 200 answer mid-session is refused, not served as if it started at the requested offset")
    func plain200MidSessionIsRefused() throws {
        let src = (0..<2000).map { UInt8($0 & 0xff) }
        let r = try #require(makeReader(src))  // the offset-0 probe is unaffected and succeeds
        MockRangeURLProtocol.plain200AfterProbeFor.insert("http://disc.test/test.iso")
        #expect(r.seek(offset: 1000, whence: SEEK_SET) == 1000)
        var out = [UInt8](repeating: 0, count: 100)
        let n = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 100) }
        #expect(n == -1)
    }

    @Test("A server without range support fails init (caller falls back to streaming)")
    func noRangeSupport() {
        let url = URL(string: "http://disc.test/noRange.iso")!
        MockRangeURLProtocol.bytesByURL[url.absoluteString] = Data([1, 2, 3])
        MockRangeURLProtocol.disableRangeFor.insert(url.absoluteString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRangeURLProtocol.self]
        #expect(HTTPDiscIOReader(url: url, sessionConfiguration: config) == nil)
        MockRangeURLProtocol.disableRangeFor.remove(url.absoluteString)
    }

    // MARK: - Disc detection over HTTP

    @Test("DiscReader.wrap recognizes an ISO9660 disc read over HTTP")
    func discDetectionOverHTTP() throws {
        let disc = ISO9660Fixture.make(files: [
            .init(name: "VTS_01_1.VOB", length: 2048),
        ])
        let r = try #require(makeReader([UInt8](disc)))
        let wrapped = try DiscReader.wrap(r)
        #expect(wrapped != nil)
    }

    // MARK: - Source byte accounting

    @Test("The reader counts the bytes it pulled from the origin")
    func countsPulledBytes() throws {
        let src = (0..<200_000).map { UInt8($0 & 0xff) }
        let r = try #require(makeReader(src))
        #expect(r.sourceBytesFetched == 0)
        var out = [UInt8](repeating: 0, count: 6000)
        let n = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 6000) }
        #expect(n == 6000)
        // One refill at the 64 KiB floor covers the 6000 bytes read: the count is the transfer.
        #expect(r.sourceBytesFetched == 65_536)
        // A re-read inside the buffer pulls nothing new.
        #expect(r.seek(offset: 4500, whence: SEEK_SET) == 4500)
        _ = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 100) }
        #expect(r.sourceBytesFetched == 65_536)
        // A seek out of the buffer refills, and that refill counts.
        #expect(r.seek(offset: 150_000, whence: SEEK_SET) == 150_000)
        _ = out.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 100) }
        #expect(r.sourceBytesFetched == 65_536 + 50_000)
    }

    // A disc session reports `LiveTelemetry.demuxerBytesFetched` and the software-path throughput
    // from this counter. It read 0 for every custom source, so a remote disc image showed no source
    // bytes at all while the reader pulled the whole title.
    @Test("A remote disc reports the reader's bytes through its extent map and the demuxer bridge")
    func discBridgeReportsPulledBytes() throws {
        let disc = ISO9660Fixture.make(files: [
            .init(name: "VTS_01_1.VOB", length: 2048),
        ])
        let r = try #require(makeReader([UInt8](disc)))
        let wrapped = try #require(try DiscReader.wrap(r))
        let bridge = CustomIOReaderBridge(reader: wrapped.reader)
        #expect(r.sourceBytesFetched > 0)
        #expect(bridge.cumulativeBytesFetched == r.sourceBytesFetched)
    }

    @Test("A host's own reader still reports no source bytes")
    func hostReaderReportsNothing() {
        let bridge = CustomIOReaderBridge(reader: DataIOReader(data: Data(repeating: 1, count: 4096)))
        #expect(bridge.cumulativeBytesFetched == 0)
    }
}

/// In-process URLProtocol that answers `Range` requests from `bytesByURL`, returning 206 + a
/// `Content-Range` header, so HTTPDiscIOReader can be exercised without a real server.
final class MockRangeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bytesByURL: [String: Data] = [:]
    nonisolated(unsafe) static var disableRangeFor: Set<String> = []
    /// Number of leading requests per URL that should fail with a network error (retry testing).
    nonisolated(unsafe) static var failFirstForURL: [String: Int] = [:]
    /// audit NET-9: any request at a non-zero offset gets a 206 that claims to start at 0 (a
    /// mis-ranged response) instead of the requested offset, with junk bytes so a caller that
    /// trusted it would read garbage rather than the source.
    nonisolated(unsafe) static var misrangedFor: Set<String> = []
    /// audit NET-9: any request at a non-zero offset gets a full 200 instead of a 206 (a
    /// Range-ignoring proxy or a cache-miss fallback), body starting at byte 0 of the source.
    nonisolated(unsafe) static var plain200AfterProbeFor: Set<String> = []

    /// #1007: a request starting at or past this offset sends its head and `stallAfterBytes` of
    /// body, then holds the connection open until it is cancelled.
    nonisolated(unsafe) static var stallFromOffset: Int?
    nonisolated(unsafe) static var stallAfterBytes = 0
    /// #1007: the first request starting at or past this offset ends cleanly after
    /// `shortBodyBytes`, short of the range it announced.
    nonisolated(unsafe) static var shortBodyOnceFromOffset: Int?
    nonisolated(unsafe) static var shortBodyBytes = 0
    /// Every `Range` header received, in order.
    nonisolated(unsafe) static var requestedRanges: [String] = []
    private static let recordLock = NSLock()

    static func reset() {
        bytesByURL = [:]; disableRangeFor = []; failFirstForURL = [:]
        misrangedFor = []; plain200AfterProbeFor = []
        stallFromOffset = nil; stallAfterBytes = 0
        shortBodyOnceFromOffset = nil; shortBodyBytes = 0
        recordLock.lock(); requestedRanges = []; recordLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if let rv = request.value(forHTTPHeaderField: "Range") {
            Self.recordLock.lock(); Self.requestedRanges.append(rv); Self.recordLock.unlock()
        }
        guard let url = request.url, let data = Self.bytesByURL[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        if let remaining = Self.failFirstForURL[url.absoluteString], remaining > 0 {
            Self.failFirstForURL[url.absoluteString] = remaining - 1
            // A clean 503 (rather than a transport error) completes the task and exercises the
            // reader's non-2xx -> retry path without URLProtocol failure-handling quirks.
            let resp = HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "0"])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let total = data.count
        let rangeOnly = !Self.disableRangeFor.contains(url.absoluteString)
        var lower = 0, upper = total - 1, status = 200
        var headers: [String: String] = ["Content-Type": "application/octet-stream"]
        if rangeOnly, let rv = request.value(forHTTPHeaderField: "Range"),
           rv.hasPrefix("bytes=") {
            let parts = rv.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            lower = Int(parts.first ?? "0") ?? 0
            upper = (parts.count > 1 ? Int(parts[1]) : nil) ?? (total - 1)
            upper = min(upper, total - 1)
            status = 206
            headers["Content-Range"] = "bytes \(lower)-\(upper)/\(total)"
        }
        var slice = (lower <= upper && lower < total) ? data.subdata(in: lower..<(upper + 1)) : Data()
        if lower > 0, status == 206, Self.misrangedFor.contains(url.absoluteString) {
            headers["Content-Range"] = "bytes 0-\(slice.count - 1)/\(total)"
            slice = Data(repeating: 0xEE, count: slice.count)
        }
        if lower > 0, status == 206, Self.plain200AfterProbeFor.contains(url.absoluteString) {
            status = 200
            headers["Content-Range"] = nil
            slice = data
        }
        headers["Content-Length"] = String(slice.count)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if status == 206, let stall = Self.stallFromOffset, lower >= stall {
            if Self.stallAfterBytes > 0 { client?.urlProtocol(self, didLoad: slice.prefix(Self.stallAfterBytes)) }
            return
        }
        if status == 206, let short = Self.shortBodyOnceFromOffset, lower >= short {
            Self.shortBodyOnceFromOffset = nil
            client?.urlProtocol(self, didLoad: slice.prefix(Self.shortBodyBytes))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didLoad: slice)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class ReadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Int32, [UInt8]) = (0, [])
    func set(_ n: Int32, _ bytes: [UInt8]) { lock.lock(); value = (n, bytes); lock.unlock() }
    func get() -> (n: Int32, bytes: [UInt8]) { lock.lock(); defer { lock.unlock() }; return value }
}
