import Testing
import Foundation

// The upstream fixtures exercise a 32 MB initial range; MovieClaw defaults to a short index-first request.
@testable import AetherEngine

/// Audit DMX-101: an origin that cannot address bytes (a plain file server, a proxy that strips
/// `Range`) answered every 32 MB refill with a 200, which the reader rejects, so playback ended at
/// the first range boundary. Such an origin is now caught at the open and played forward-only with
/// the streaming path's bounded buffer, and an origin that does honour ranges is left alone.
@Suite("Range-ignoring origins")
struct RangeIgnoringOriginTests {

    private static let avseekSize: Int32 = 65536
    private let mb = 1024 * 1024

    private final class FirstClaim: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    private func expected(at offset: Int64, count: Int) -> [UInt8] {
        (0..<count).map { ThrottledOriginServer.patternByte(at: offset + Int64($0)) }
    }

    /// Reads `total` bytes in 256 KB reads, checking the first 1 KB of the read that crosses each
    /// 4 MB mark against the origin's pattern. Checking every byte of a 72 MB body would measure the
    /// test, not the reader.
    private func drain(_ reader: AVIOReader, total: Int64) -> (read: Int64, last: Int32, firstBadOffset: Int64?) {
        let chunk = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var read: Int64 = 0
        var last: Int32 = 0
        var nextCheck: Int64 = 0
        var bad: Int64?
        while read < total {
            last = reader.read(into: buf, size: Int32(chunk))
            if last <= 0 { break }
            if read + Int64(last) > nextCheck {
                let start = max(0, nextCheck - read)
                let n = Int(min(1024, Int64(last) - start))
                let got = Array(UnsafeBufferPointer(start: buf.advanced(by: Int(start)), count: n))
                if got != expected(at: read + start, count: n), bad == nil { bad = read + start }
                nextCheck = (read + Int64(last) + 4 * Int64(mb) - 1) / (4 * Int64(mb)) * 4 * Int64(mb)
            }
            read += Int64(last)
        }
        return (read, last, bad)
    }

    private func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://example.invalid/movie.bin")!, statusCode: status,
                        httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    // MARK: - The classification every reader shares

    @Test("a response is classified by what it did with the range that was asked for")
    func classification() {
        func answer(_ http: HTTPURLResponse, start: Int64 = 0, end: Int64? = 99) -> AVIOReader.RangeAnswer {
            AVIOReader.rangeAnswer(http, requestedStart: start, requestedEnd: end)
        }
        #expect(answer(response(206, ["Content-Range": "bytes 0-99/1000", "Content-Length": "100"])) == .honoured)
        #expect(answer(response(206, ["Content-Range": "bytes 64-99/1000"])) == .misplaced(start: 64))
        #expect(answer(response(206, ["Content-Range": "bytes 0-999/1000", "Content-Length": "1000"])) == .overWide)
        #expect(answer(response(206, ["Content-Range": "bytes 0-99/*"])) == .honoured)
        #expect(answer(response(200, ["Content-Length": "1000"])) == .ignored)
        #expect(answer(response(200, [:])) == .ignored, "a 200 that states no length cannot be the asked range")
        #expect(answer(response(200, ["Content-Length": "100"])) == .wholeFile)
        #expect(answer(response(200, ["Content-Length": "50"])) == .wholeFile)
        #expect(answer(response(200, ["Content-Length": "100"]), start: 5, end: 99) == .ignored,
                "a 200 cannot be a range that starts past byte 0")
        #expect(answer(response(200, ["Content-Length": "5000"]), end: nil) == .wholeFile,
                "an open-ended ask has no span a 200 could exceed")
        #expect(answer(response(404, [:])) == .unjudged)
        #expect(answer(response(416, [:])) == .unjudged)
    }

    // MARK: - On the wire

    /// What a forward-only source owes: a non-seekable pb that still states its length, every byte of
    /// the body once and in order, a clean EOF, a bounded buffer, and no ranged request past the open.
    private func expectForwardOnlyPlayback(_ reader: AVIOReader, _ server: ThrottledOriginServer,
                                           total: Int64, unrangedRequests: ClosedRange<Int> = 1...1) {
        #expect(reader.originIgnoresRange)
        #expect(!reader.isSeekable, "the pb must be non-seekable so FFmpeg never seeks a source that cannot")
        #expect(reader.seek(offset: 0, whence: Self.avseekSize) == total,
                "the Content-Length still answers AVSEEK_SIZE, which an MPEG-TS duration estimate needs")

        let result = drain(reader, total: total)
        #expect(result.read == total, "read \(result.read / Int64(mb)) MB of \(total / Int64(mb)) MB")
        #expect(result.firstBadOffset == nil, "bytes differ from the origin's at \(result.firstBadOffset ?? -1)")
        let tailBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { tailBuf.deallocate() }
        #expect(reader.read(into: tailBuf, size: 4096) == FFmpegErr.eof, "a body read to its end is EOF")

        #expect(reader.streamPeakBufferBytesForTesting <= 64 * mb + 8 * mb,
                "the streaming buffer held \(reader.streamPeakBufferBytesForTesting / mb) MB of a \(total / Int64(mb)) MB body")

        // One unranged GET carried the whole body. Everything else is the open's own: the bounded
        // range that was answered with a 200, the one byte confirmation, the suffix tail prefetch.
        #expect(unrangedRequests.contains(server.rangeHeaderPresence.filter { !$0 }.count),
                "\(server.rangeHeaderPresence.filter { !$0 }.count) requests without a Range header")
        let tail = total - Int64(AVIOReader.tailPrefetchBytes)
        let strays = server.requestLog.enumerated().filter { index, request in
            server.rangeHeaderPresence[index] && request.start > 1 && request.start != tail
        }
        #expect(strays.isEmpty, "ranged requests past the open: \(strays.map(\.element))")
    }

    @Test("an origin that ignores Range is read forward-only past the 32 MB range boundary",
          .timeLimit(.minutes(2)))
    func forwardOnlyPastTheRangeBoundary() throws {
        let total = Int64(72 * mb)
        let maybe = ThrottledOriginServer(totalSize: total, throttleUs: 500, patternedBody: true,
                                          respond: { _, _, _ in .serve200 })
        let server = try #require(maybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.ts")!, boundedInitialFetch: 32 * 1024 * 1024)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        expectForwardOnlyPlayback(reader, server, total: total)
    }

    @Test("a cold open that was refused once does not hide an origin that ignores Range",
          .timeLimit(.minutes(2)))
    func refusedColdOpenStillFindsTheIgnoredRange() throws {
        let total = Int64(72 * mb)
        let once = FirstClaim()
        let respond: @Sendable (Int, Int64, String) -> ThrottledOriginServer.Directive = { _, offset, _ in
            offset == 0 && once.take() ? .status(503) : .serve200
        }
        let maybe = ThrottledOriginServer(totalSize: total, throttleUs: 500, patternedBody: true,
                                          respond: respond)
        let server = try #require(maybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.ts")!, boundedInitialFetch: 32 * 1024 * 1024)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // The size probe's HEAD fallback has no Range header either, and it fires when the probe
        // behind a refusal is slow, which is the case here.
        expectForwardOnlyPlayback(reader, server, total: total, unrangedRequests: 1...2)
    }

    @Test("an origin that honours Range keeps the seekable path and its range refills",
          .timeLimit(.minutes(2)))
    func honouringOriginIsUnaffected() throws {
        let total = Int64(40 * mb)
        let server = try #require(ThrottledOriginServer(totalSize: total, throttleUs: 500))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!, boundedInitialFetch: 32 * 1024 * 1024)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        #expect(!reader.originIgnoresRange)
        #expect(reader.isSeekable)
        #expect(reader.seek(offset: 0, whence: Self.avseekSize) == total)

        let chunk = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var read: Int64 = 0
        while read < 36 * Int64(mb) {
            let n = reader.read(into: buf, size: Int32(chunk))
            #expect(n > 0, "read failed at \(read)")
            if n <= 0 { break }
            read += Int64(n)
        }
        #expect(read >= 36 * Int64(mb))
        #expect(server.rangeHeaderPresence.allSatisfy { $0 }, "a ranged source asked for an unranged GET")
        #expect(server.requestedRanges.contains { $0.start == 32 * Int64(mb) },
                "the refill at the 32 MB boundary never asked for its range")
        #expect(!server.requestLog.contains { $0.start == 1 && $0.end == 1 },
                "an honoured range needs no confirmation")
    }

    @Test("an origin that honours Range and refused the cold open once keeps the seekable path",
          .timeLimit(.minutes(2)))
    func refusedColdOpenOnHonouringOriginStaysSeekable() throws {
        let total = Int64(40 * mb)
        let once = FirstClaim()
        let respond: @Sendable (Int, Int64, String) -> ThrottledOriginServer.Directive = { _, offset, _ in
            offset == 0 && once.take() ? .status(503) : .serve206
        }
        let server = try #require(ThrottledOriginServer(totalSize: total, throttleUs: 500, respond: respond))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!, boundedInitialFetch: 32 * 1024 * 1024)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        #expect(!reader.originIgnoresRange)
        #expect(reader.isSeekable)
        #expect(reader.resolvedByteSize == total)

        let chunk = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var read: Int64 = 0
        while read < 36 * Int64(mb) {
            let n = reader.read(into: buf, size: Int32(chunk))
            #expect(n > 0, "read failed at \(read)")
            if n <= 0 { break }
            read += Int64(n)
        }
        #expect(read >= 36 * Int64(mb))
        #expect(server.requestedRanges.contains { $0.start == 32 * Int64(mb) },
                "the refill at the 32 MB boundary never asked for its range")
        #expect(!server.requestLog.contains { $0.start == 1 && $0.end == 1 },
                "an honoured range needs no confirmation")
    }

    @Test("a 200 on a cache miss at the open does not take the seekable path away",
          .timeLimit(.minutes(2)))
    func cacheMissAtTheOpenIsConfirmedAway() throws {
        let total = Int64(40 * mb)
        let once = FirstClaim()
        let respond: @Sendable (Int, Int64, String) -> ThrottledOriginServer.Directive = { _, offset, _ in
            offset == 0 && once.take() ? .serve200 : .serve206
        }
        let maybe = ThrottledOriginServer(totalSize: total, throttleUs: 500, respond: respond)
        let server = try #require(maybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!, boundedInitialFetch: 32 * 1024 * 1024)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        #expect(!reader.originIgnoresRange)
        #expect(reader.isSeekable)
        #expect(reader.resolvedByteSize == total)
        #expect(server.requestLog.contains { $0.start == 1 && $0.end == 1 },
                "the 200 was never confirmed with a one byte range")
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buf.deallocate() }
        #expect(reader.read(into: buf, size: 64 * 1024) > 0)
    }

    @Test("a small file answered with a 200 that covers it stays sized and seekable",
          .timeLimit(.minutes(1)))
    func smallWholeFileStaysSeekable() throws {
        let total = Int64(4 * mb)
        let maybe = ThrottledOriginServer(totalSize: total, throttleUs: 0, patternedBody: true,
                                          respond: { _, _, _ in .serve200 })
        let server = try #require(maybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/small.mp4")!, boundedInitialFetch: 32 * 1024 * 1024)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        #expect(!reader.originIgnoresRange)
        #expect(reader.isSeekable)
        #expect(reader.resolvedByteSize == total)
        #expect(!server.requestLog.contains { $0.start == 1 && $0.end == 1 },
                "a whole small file needs no confirmation")
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        #expect(reader.read(into: buf, size: 4096) == 4096)
        #expect(Array(UnsafeBufferPointer(start: buf, count: 4096)) == expected(at: 0, count: 4096))
    }
}
