import Testing
import Foundation
@testable import AetherEngine

/// Audit PERF-102: the forward-only reader trimmed its consumed head with `Data.subdata`, which
/// copied the whole 32-64 MB still ahead of the cut on every read. The buffer now holds the chunks
/// as they were delivered (AE#619), so a trim advances an offset and moves nothing.
@Suite("Forward-only streaming buffer")
struct StreamingBufferTrimTests {

    private let total = 6 * 1024 * 1024

    private func makeReader(_ server: ThrottledOriginServer) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/archive.ts")!, sequentialOnly: true)
    }

    @Test("unaligned reads return exactly the bytes the origin sent", .timeLimit(.minutes(3)))
    func byteExactAcrossUnalignedReads() async throws {
        let maybe = ThrottledOriginServer(totalSize: Int64(total), throttleUs: 0, patternedBody: true)
        let server = try #require(maybe)
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        // Everything is resident before the first read, so each trim below runs against the whole body.
        try await waitFor { reader.streamPeakBufferBytesForTesting >= total }

        let expected = (0..<total).map { ThrottledOriginServer.patternByte(at: Int64($0)) }
        let sizes = [1, 7, 4093, 65_537, 262_000, 300_001, 12, 1_048_576 + 5]
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sizes.max()!)
        defer { buf.deallocate() }
        var offset = 0
        var turn = 0
        while offset < total {
            let want = sizes[turn % sizes.count]
            turn += 1
            let n = Int(reader.read(into: buf, size: Int32(want)))
            #expect(n > 0, "read failed at \(offset)")
            if n <= 0 { return }
            let matches = expected.withUnsafeBufferPointer { memcmp($0.baseAddress! + offset, buf, n) == 0 }
            #expect(matches, "\(n) bytes at \(offset) differ from the origin's")
            if !matches { return }
            offset += n
        }
        #expect(offset == total)
        #expect(reader.read(into: buf, size: 4096) == FFmpegErr.eof)
    }

    #if DEBUG
    @Test("a trim releases what it passed and moves nothing it keeps", .timeLimit(.minutes(3)))
    func trimMovesNothing() async throws {
        let maybe = ThrottledOriginServer(totalSize: Int64(total), throttleUs: 0)
        let server = try #require(maybe)
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        try await waitFor { reader.streamPeakBufferBytesForTesting >= total }

        // Everything is resident and nothing consumed yet, so this is every chunk the body arrived in.
        let before = reader.streamChunkAddressesForTesting
        #expect(before.count > 1, "the body arrived as one chunk, so this could not tell a copy from a slice")

        let chunk = 262_000
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        // A chunk is released once the read position is a lookback past its end, and how large
        // URLSession makes the chunks is not this test's to know (larger on a CI runner), so read
        // until one goes. The body is the bound: if it ends first, nothing was released and that fails.
        var read = 0
        var after = before
        while after.count >= before.count, read < total {
            let n = Int(reader.read(into: buf, size: Int32(chunk)))
            #expect(n > 0)
            if n <= 0 { return }
            read += n
            after = reader.streamChunkAddressesForTesting
        }
        #expect(after.count < before.count, "the trim released nothing before the body ended")
        // One kept chunk is enough for the address check below. Asking for two made the result
        // depend on how URLSession cut the body, which a loaded machine coalesces into fewer chunks:
        // a release at the first boundary then leaves exactly one (measured, `after.count -> 1`).
        #expect(!after.isEmpty, "the trim released the chunk the read position is in")
        #expect(Array(before.suffix(after.count)) == after,
                "a trim reallocated the chunks it kept: the buffer was copied, not sliced")
    }
    #endif
}
