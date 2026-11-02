import Testing
import Foundation
@testable import AetherEngine

/// Audit NET-102: the remote disc reader checked a range answer only after URLSession had buffered
/// the whole body, so an origin that ignored Range (or answered `bytes N-EOF`) put a 40 GB image
/// into memory before the check could refuse it. The check now runs at the response head, and what
/// is kept is capped at the range that was asked for.
@Suite("Disc reader range answers", .offCooperativePool)
struct DiscReaderRangeAnswerTests {

    private let total = Int64(512 * 1024 * 1024)

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

    private func url(_ server: ThrottledOriginServer, _ name: String = "movie.iso") -> URL {
        URL(string: "http://127.0.0.1:\(server.port)/\(name)")!
    }

    private func read(_ reader: HTTPDiscIOReader, at offset: Int64, count: Int) -> [UInt8]? {
        guard reader.seek(offset: offset, whence: SEEK_SET) == offset else { return nil }
        var out = [UInt8](repeating: 0, count: count)
        let n = out.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: Int32(count)) }
        return n == Int32(count) ? out : nil
    }

    @Test("an origin that answers the range probe with a 200 is hung up on at the head",
          .timeLimit(.minutes(3)))
    func plain200IsHungUpOn() throws {
        let maybe = ThrottledOriginServer(totalSize: total, respond: { _, _, _ in .serve200 })
        let server = try #require(maybe)
        defer { server.stop() }

        #expect(HTTPDiscIOReader(url: url(server)) == nil)
        #expect(server.bytesWritten < 16 * 1024 * 1024,
                "the origin wrote \(server.bytesWritten / 1024 / 1024) MB of a \(total / 1024 / 1024) MB body")
    }

    @Test("open names the origin that cannot address bytes", .timeLimit(.minutes(3)))
    func openThrowsForAnOriginWithoutRanges() throws {
        let maybe = ThrottledOriginServer(totalSize: total, respond: { _, _, _ in .serve200 })
        let server = try #require(maybe)
        defer { server.stop() }

        #expect(throws: AVIOReaderError.originIgnoresRange) {
            try HTTPDiscIOReader.open(url: url(server))
        }
    }

    @Test("a remote disc image on such an origin fails the demuxer open with that cause",
          .timeLimit(.minutes(3)))
    func demuxerOpenFailsTyped() throws {
        let maybe = ThrottledOriginServer(totalSize: total, respond: { _, _, _ in .serve200 })
        let server = try #require(maybe)
        defer { server.stop() }

        let demuxer = Demuxer()
        defer { demuxer.close() }
        #expect(throws: AVIOReaderError.originIgnoresRange) {
            try demuxer.open(url: url(server))
        }
        #expect(server.bytesWritten < 16 * 1024 * 1024)
    }

    @Test("a 206 that runs past the range is cut where the range ends", .timeLimit(.minutes(3)))
    func overWide206IsCutAtTheRange() throws {
        let maybe = ThrottledOriginServer(totalSize: total, ignoreRangeEnd: true)
        let server = try #require(maybe)
        defer { server.stop() }

        let reader = try #require(HTTPDiscIOReader(url: url(server), baseChunkSize: 64 * 1024,
                                                   maxChunkSize: 64 * 1024))
        defer { reader.close() }
        #expect(read(reader, at: 100_000, count: 4096) == [UInt8](repeating: 0x55, count: 4096))
        #expect(read(reader, at: 9_000_000, count: 4096) == [UInt8](repeating: 0x55, count: 4096))
        #expect(server.bytesWritten < 32 * 1024 * 1024,
                "the origin wrote \(server.bytesWritten / 1024 / 1024) MB for two 64 KB ranges")
    }

    @Test("a 206 that starts elsewhere is hung up on at the head and the range asked again",
          .timeLimit(.minutes(3)))
    func misplaced206IsHungUpOn() throws {
        let target: Int64 = 64 * 1024 * 1024
        let once = FirstClaim()
        let respond: @Sendable (Int, Int64, String) -> ThrottledOriginServer.Directive = { _, offset, _ in
            offset == target && once.take() ? .serve206From(start: target - 4096) : .serve206
        }
        let maybe = ThrottledOriginServer(totalSize: total, ignoreRangeEnd: true, patternedBody: true,
                                          respond: respond)
        let server = try #require(maybe)
        defer { server.stop() }

        let reader = try #require(HTTPDiscIOReader(url: url(server), baseChunkSize: 64 * 1024,
                                                   maxChunkSize: 64 * 1024))
        defer { reader.close() }
        let expected = (0..<4096).map { ThrottledOriginServer.patternByte(at: target + Int64($0)) }
        #expect(read(reader, at: target, count: 4096) == expected)
        #expect(server.bytesWritten < 32 * 1024 * 1024,
                "the origin wrote \(server.bytesWritten / 1024 / 1024) MB, so the misplaced body was taken")
    }
}
