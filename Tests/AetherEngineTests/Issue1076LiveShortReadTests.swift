import Foundation
import Testing
@testable import AetherEngine

/// AE#1076: a live read returns what has arrived instead of waiting until FFmpeg's whole 256 KB
/// buffer is full. Before, every read on a 0.5 Mbit/s HDHomeRun sub-channel took about 4 s, which
/// showed up as a 1.7 to 2.9 s `open_input` and as a live edge that moved in multi-second steps.
@Suite(.serialized)
struct Issue1076LiveShortReadTests {

    private static func origin() throws -> TrickleWatchdogTests.PacedOrigin {
        // 4 KB every 50 ms is about 650 kbit/s, a low-bitrate sub-channel. 256 KB takes 3.2 s.
        let origin = TrickleWatchdogTests.PacedOrigin(totalSize: 256 * 1024 * 1024, pace: { _, _ in
            .drip(bytes: 4 * 1024, everyUs: 50_000)
        })
        return try #require(origin)
    }

    private static func timedRead(_ reader: AVIOReader, size: Int) -> (bytes: Int32, seconds: Double) {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate() }
        let start = Date()
        let n = reader.read(into: buf, size: Int32(size))
        return (n, Date().timeIntervalSince(start))
    }

    @Test("a live read hands back what has arrived instead of filling the request",
          .timeLimit(.minutes(3)))
    func liveReadReturnsShort() throws {
        let origin = try Self.origin()
        defer { origin.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(origin.port)/live.ts")!,
                                isLive: true)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        for _ in 0..<5 {
            let read = Self.timedRead(reader, size: 256 * 1024)
            #expect(read.bytes > 0)
            #expect(read.bytes < 256 * 1024, "a live read waited for the whole request")
            #expect(read.seconds < 1.5, "a live read took \(read.seconds) s")
        }
    }

    @Test("a VOD read still fills the request", .timeLimit(.minutes(3)))
    func vodReadStillFills() throws {
        let origin = try Self.origin()
        defer { origin.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(origin.port)/movie.bin")!,
                                boundedInitialFetch: 2 * 1024 * 1024)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let read = Self.timedRead(reader, size: 64 * 1024)
        #expect(read.bytes == 64 * 1024)
    }
}
