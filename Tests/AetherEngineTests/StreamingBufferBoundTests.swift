import Testing
import Foundation
@testable import AetherEngine

/// Audit DMX-107: the forward-only reader pauses its transfer at a high water and ends it at twice
/// that, because the pause is advisory. The end was a bare EIO, indistinguishable from a dropped
/// connection. It now carries a typed cause, and memory stays bounded either way.
@Suite("Forward-only streaming buffer bound")
struct StreamingBufferBoundTests {

    private func drain(_ reader: AVIOReader) -> (read: Int, last: Int32) {
        let chunk = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var read = 0
        while true {
            let n = reader.read(into: buf, size: Int32(chunk))
            if n <= 0 { return (read, n) }
            read += Int(n)
        }
    }

    @Test("a transport that delivers past the hard cap ends the read with a typed cause",
          .timeLimit(.minutes(3)))
    func hardCapIsTyped() throws {
        let body = 64 * 1024 * 1024
        let maybe = ThrottledOriginServer(totalSize: Int64(body), throttleUs: 0)
        let server = try #require(maybe)
        defer { server.stop() }
        // One delivery is larger than twice this, so the cap is passed without depending on
        // whether the transport honours the pause that comes first. The peak is then about one
        // URLSession delivery, which measured 2.4 MB on a CI runner, so the bound is a quarter of
        // the body rather than a guess at the delivery size.
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/archive.ts")!,
                                sequentialOnly: true, streamHighWater: 1024)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let result = drain(reader)
        #expect(result.last == FFmpegErr.eio, "a source ended at the cap is lost, not finished")
        #expect(reader.lastReadFailure == .originIgnoresFlowControl)
        #expect(result.read < body, "the cap let the whole body through")
        #expect(reader.streamPeakBufferBytesForTesting < body / 4,
                "the buffer held \(reader.streamPeakBufferBytesForTesting / 1024) KB")
    }

    @Test("a body that finishes inside the bound is EOF with no failure", .timeLimit(.minutes(3)))
    func completeBodyHasNoFailure() throws {
        let maybe = ThrottledOriginServer(totalSize: 2 * 1024 * 1024, throttleUs: 0)
        let server = try #require(maybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/archive.ts")!,
                                sequentialOnly: true)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let result = drain(reader)
        #expect(result.read == 2 * 1024 * 1024)
        #expect(result.last == FFmpegErr.eof)
        #expect(reader.lastReadFailure == nil)
    }

    @Test("a dropped connection is EIO without a cause of ours", .timeLimit(.minutes(3)))
    func droppedConnectionHasNoCause() throws {
        let total: Int64 = 8 * 1024 * 1024
        let maybe = ThrottledOriginServer(totalSize: total, throttleUs: 0,
                                          respond: { _, _, _ in .serveThenDrop(afterBytes: 1024 * 1024) })
        let server = try #require(maybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/archive.ts")!,
                                sequentialOnly: true)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let result = drain(reader)
        #expect(result.last == FFmpegErr.eio)
        #expect(reader.lastReadFailure == nil, "a lost connection is the network's, not the origin's flow control")
    }
}
