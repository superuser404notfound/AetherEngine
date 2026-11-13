import Testing
import Foundation
@testable import AetherEngine

/// Audit PERF-108: the detour cache was only emptied at close, so the blocks a backward scrub filled
/// (up to 32 MB per reader) stayed resident for the rest of the session. The read path now sweeps
/// blocks nothing has read for a while.
@Suite("Detour block idle release")
struct DetourBlockIdleReleaseTests {

    @Test("a detour block nothing reads any more is released by the read path", .timeLimit(.minutes(3)))
    func idleBlockIsReleased() async throws {
        let maybe = ThrottledOriginServer(totalSize: 64 * 1024 * 1024, throttleUs: 1000)
        let server = try #require(maybe)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!
        let reader = AVIOReader(url: url, detourIdleSeconds: 0.2, detourFetchBudget: 30)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let chunk = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var read = 0
        while read < 13 * 1024 * 1024 {
            let n = Int(reader.read(into: buf, size: Int32(chunk)))
            #expect(n > 0, "forward read failed at \(read)")
            if n <= 0 { return }
            read += n
        }
        let frontier = Int64(read)

        // Backward past the retained head and the window: this fills the 4 to 8 MB block.
        #expect(reader.seek(offset: 5 * 1024 * 1024, whence: Int32(SEEK_SET)) == 5 * 1024 * 1024)
        #expect(reader.read(into: buf, size: Int32(chunk)) > 0)
        #expect(reader.detourResidentBlocksForTesting == 1, "no detour block was filled, so this measured nothing")

        // Back to the window. Nothing reads the block from here on, and each read is a chance for
        // the sweep, which runs at most once a second.
        #expect(reader.seek(offset: frontier, whence: Int32(SEEK_SET)) == frontier)
        try await waitFor {
            _ = reader.read(into: buf, size: Int32(chunk))
            return reader.detourResidentBlocksForTesting == 0
        }
    }
}
