import Testing
import Foundation
@testable import AetherEngine

/// A ranged answer is only trusted as far as it matches what was asked: it has to start at the
/// requested offset (audit DMX-5), and nothing past the requested end is kept (audit DMX-1).
@Suite("Ranged response integrity", .offCooperativePool)
struct RangedResponseIntegrityTests {

    private final class FirstRequestAt: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if seen { return false }
            seen = true
            return true
        }
    }

    private func readExact(_ reader: AVIOReader, _ size: Int) -> [UInt8]? {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate() }
        var got = 0
        while got < size {
            let n = reader.read(into: buf.advanced(by: got), size: Int32(size - got))
            guard n > 0 else { return nil }
            got += Int(n)
        }
        return Array(UnsafeBufferPointer(start: buf, count: size))
    }

    private func expected(at offset: Int64, count: Int) -> [UInt8] {
        (0..<count).map { ThrottledOriginServer.patternByte(at: offset + Int64($0)) }
    }

    @Test("an origin that answers wider than the range asked for is ended at the range end",
          .timeLimit(.minutes(3)))
    func overDeliveryIsEndedAtTheRangeEnd() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024,
                                                        ignoreRangeEnd: true))
        defer { server.stop() }
        let firstRange: Int64 = 512 * 1024
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        #expect(readExact(reader, 64 * 1024) != nil)

        try await waitFor { !reader.hasLiveConnectionForTesting }
        // The read above may itself have drawn the window below low water after the range ended,
        // which is the ordinary way a bounded read moves on, and the refill can have landed before
        // this looks. What over-delivery would break is where that refill starts: excess kept in the
        // window moves the frontier past the range end. So any refill starts exactly at it, and
        // without one the window still holds no more than the range.
        let tail = Int64(512 * 1024 * 1024) - Int64(AVIOReader.tailPrefetchBytes)
        let refills = server.requestLog.map(\.start).filter { $0 > 1 && $0 != tail }
        #expect(refills.allSatisfy { $0 == firstRange }, "refills at \(refills), the range ended at \(firstRange)")
        if refills.isEmpty {
            #expect(reader.windowBytesForTesting <= Int(firstRange),
                    "the window held \(reader.windowBytesForTesting)B of a \(firstRange)B range")
        }
    }

    @Test("a persistent 206 that starts elsewhere is refused, not placed at the requested offset",
          .timeLimit(.minutes(3)))
    func persistentMisplacedRangeIsRefused() async throws {
        let target: Int64 = 64 * 1024 * 1024
        let once = FirstRequestAt()
        let respond: @Sendable (Int, Int64, String) -> ThrottledOriginServer.Directive = { _, offset, _ in
            offset == target && once.claim() ? .serve206From(start: target - 4096) : .serve206
        }
        let origin = ThrottledOriginServer(totalSize: 512 * 1024 * 1024, patternedBody: true, respond: respond)
        let server = try #require(origin)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        #expect(readExact(reader, 4096) == expected(at: 0, count: 4096))

        #expect(reader.seek(offset: target, whence: SEEK_SET) == target)
        #expect(readExact(reader, 4096) == expected(at: target, count: 4096))
    }

    @Test("a chunk fetch 206 that starts elsewhere is refused", .timeLimit(.minutes(3)))
    func chunkMisplacedRangeIsRefused() async throws {
        let target: Int64 = 16 * 1024 * 1024
        let once = FirstRequestAt()
        let respond: @Sendable (Int, Int64, String) -> ThrottledOriginServer.Directive = { _, offset, _ in
            offset == target && once.claim() ? .serve206From(start: target - 4096) : .serve206
        }
        let origin = ThrottledOriginServer(totalSize: 64 * 1024 * 1024, patternedBody: true, respond: respond)
        let server = try #require(origin)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                chunkSize: 256 * 1024, prefetchEnabled: false)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        #expect(reader.seek(offset: target, whence: SEEK_SET) == target)
        let got = readExact(reader, 4096)
        // Refused and retried is fine, failed is fine; the misplaced bytes are not.
        if let got { #expect(got == expected(at: target, count: 4096)) }
    }

    @Test("Content-Range start is compared against the requested offset")
    func misplacedStartIsNamed() {
        let url = URL(string: "http://example.invalid/movie.bin")!
        func response(_ status: Int, _ contentRange: String?) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                            headerFields: contentRange.map { ["Content-Range": $0] } ?? [:])!
        }
        #expect(AVIOReader.misplacedRangeStart(response(206, "bytes 100-199/1000"), requestedOffset: 100) == nil)
        #expect(AVIOReader.misplacedRangeStart(response(206, "bytes 64-199/1000"), requestedOffset: 100) == 64)
        #expect(AVIOReader.misplacedRangeStart(response(206, "bytes 100-199/*"), requestedOffset: 100) == nil)
        #expect(AVIOReader.misplacedRangeStart(response(206, nil), requestedOffset: 100) == nil)
        #expect(AVIOReader.misplacedRangeStart(response(200, "bytes 64-199/1000"), requestedOffset: 100) == nil)
    }
}
