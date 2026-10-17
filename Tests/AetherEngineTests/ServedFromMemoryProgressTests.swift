import Testing
import Foundation
@testable import AetherEngine

/// #380 follow-up. The report named ONE branch: the window serve, where draining read-ahead reset
/// the reconnect ladders and so held a refusing origin at streak=1 for as long as the runway
/// lasted. The read loop serves from memory in three places, and the other two were charging the
/// ladders the same way:
///
/// - the retained head/tail spans (#281), which run FIRST, before every network path, and whose
///   own log line says "no reconnect for it";
/// - the detour cache's resident-block hit (#69), the parse ping-pong's cheap path.
///
/// The span serve is the one that reaches a metered origin: a rate-limit status hands the origin
/// to the #377 budget, which caps it to one request and takes the detour out of service
/// (`originRequiresSerialRequests`), while the spans keep serving. That is the field shape #380
/// described as "one served byte reset the whole ladder and it started over".
@Suite(.offCooperativePool)
struct ServedFromMemoryProgressTests {

    /// The frontier refill is only requested once the initial range has COMPLETED (`activeTask`
    /// cleared by the completion callback), so the test waits on that state rather than on a
    /// sleep long enough to probably work.
    private static func awaitRangeDelivered(_ reader: AVIOReader) async throws {
        try await waitFor { !reader.hasLiveConnectionForTesting }
    }

    @discardableResult
    private static func readOnce(_ reader: AVIOReader, at offset: Int64, bytes: Int) -> Int32 {
        #expect(reader.seek(offset: offset, whence: SEEK_SET) == offset)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
        defer { buf.deallocate() }
        return reader.read(into: buf, size: Int32(bytes))
    }

    /// Sequential reads from the current position, which is what walks the window forward and
    /// trims it, so a later read at 0 is genuinely below `winStart`. Returns the bytes served.
    private static func readForward(_ reader: AVIOReader, bytes: Int) -> Int {
        let slice = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: slice)
        defer { buf.deallocate() }
        var got = 0
        while got < bytes {
            let n = reader.read(into: buf, size: Int32(min(slice, bytes - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        return got
    }

    /// Serves from inside the resident window until the refused frontier has charged the ladder.
    /// The charge is paced (`nextFaultedRefillAt`), so this re-reads rather than sleeping once and
    /// hoping the ladder ran; each iteration's read is itself the thing that can charge it.
    private static func chargeLadderFromWindow(_ reader: AVIOReader, near offset: Int64) async throws -> Int {
        var step = 0
        while true {
            readOnce(reader, at: offset + Int64(step % 8) * 64 * 1024, bytes: 32 * 1024)
            if reader.rateLimitStreakForTesting > 0 { return reader.rateLimitStreakForTesting }
            step += 1
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A metered origin refusing the frontier while the parser returns to the retained head: the
    /// serve costs no request, so it says nothing about the origin and must leave the ladder's
    /// charge standing. Before this held, the return to the head reset the streak on every read,
    /// and both the bounded give-up and #380's re-resolve rung stayed out of reach.
    @Test("a retained-span serve is not progress against a metered origin",
          .timeLimit(.minutes(2)))
    func retainedSpanServeDoesNotClearTheLadder() async throws {
        // The first range ends here and every refill at the frontier is refused: the shape of an
        // origin that answers the range boundary and meters everything past it.
        let frontier: Int64 = 8 * 1024 * 1024
        let serverMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in offset == frontier ? .status(509) : .serve206 }
        )
        let server = try #require(serverMaybe)
        defer { server.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: frontier,
                                backoffScale: 0.02)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        #expect(Self.readOnce(reader, at: 0, bytes: 64 * 1024) > 0)
        try await Self.awaitRangeDelivered(reader)

        // Past winLookback (2 MB) + winTrimBatch (4 MB), so the window has trimmed and a read at 0
        // can no longer be served from it.
        let walked = Self.readForward(reader, bytes: 6 * 1024 * 1024 + 512 * 1024)
        #expect(walked == 6 * 1024 * 1024 + 512 * 1024,
                "need a trimmed window for the read at 0 to reach the head span (read \(walked))")

        let charged = try await Self.chargeLadderFromWindow(reader, near: 6 * 1024 * 1024)
        #expect(charged > 0, "the refused frontier must have charged the rate-limit ladder")

        // The parse's return to the head, repeatedly. Every one of these is a memcpy out of bytes
        // fetched during open.
        let headSpanEnd = Int64(16 * 64 * 1024)
        let requestsBefore = server.requestLog.count
        for step in 0..<16 {
            #expect(Self.readOnce(reader, at: Int64(step) * 64 * 1024, bytes: 32 * 1024) > 0)
        }
        // Only requests for the bytes the loop READ say anything here. The ladder goes on retrying
        // the refused frontier for as long as this test wants it charged, and that retry is paced,
        // so a raw count of the log is a race: it landed inside the loop once on CI and read as a
        // head fetch it never was (log said 8388608..41943039, twice).
        let fetchedTheHead = server.requestLog.dropFirst(requestsBefore).filter {
            $0.start < headSpanEnd
        }
        #expect(fetchedTheHead.isEmpty,
                "the run must come out of the retained head: \(fetchedTheHead)")
        #expect(reader.rateLimitStreakForTesting >= charged,
                "a span serve costs no request and must not clear the ladder")
    }
}
