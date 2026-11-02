import Testing
import Foundation
@testable import AetherEngine

/// Audit DMX-105: a detour block took an origin ticket in `detourFetchBlock` and a second one inside
/// `syncRequest`. On an origin capped at two requests, with the pump holding one, the outer ticket
/// took the last slot and the inner acquire waited its whole four second budget for it: +4 s per
/// block, and a third request on the books against a limit of two. A reader that already holds a
/// ticket must never block on another, so the detour holds one.
@Suite("Detour origin ticket", .serialized, .offCooperativePool)
struct DetourOriginTicketTests {

    @Test("a detour block behind a pump holding one of two slots takes one slot and no wait",
          .timeLimit(.minutes(2)))
    func detourTakesOneTicket() async throws {
        let total: Int64 = 64 * 1024 * 1024
        // About 6 MB/s: the pump still has seconds of its 32 MB range to go when the detour is asked for.
        let maybe = ThrottledOriginServer(totalSize: total, throttleUs: 40_000)
        let server = try #require(maybe)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!
        OriginRequestBudget.shared.setHostLimit(2, for: url)
        defer { OriginRequestBudget.shared.setHostLimit(nil, for: url) }

        let reader = AVIOReader(url: url)
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
        #expect(reader.hasLiveConnectionForTesting, "the pump was not on the link, so the detour had no rival")

        // Backward past the retained head and the window (which trimmed to about 8 MB): the read
        // that opens the detour block holding 4 to 8 MB.
        let target = Int64(5 * 1024 * 1024)
        #expect(reader.seek(offset: target, whence: Int32(SEEK_SET)) == target)
        let served = reader.read(into: buf, size: Int32(chunk))

        #expect(served > 0)
        // The witness is the pump still on the link, not a clock: with the old double acquire the
        // second ticket waited out its 4 s budget, by which time the pump's range had ended (checked
        // by reverting 0fd16c57). A wall-clock bound on this read measured 2.0 to 2.3 s on a loaded
        // CI runner for a correct detour.
        #expect(reader.hasLiveConnectionForTesting,
                "the detour only got its slot once the pump's range had finished")
        let books = try #require(OriginRequestBudget.shared.snapshot(for: url))
        #expect(books.limit == 2)
        #expect(books.peakInflight == 2, "peak \(books.peakInflight) on the books against a limit of 2")
        // The detour block is the 4 MB aligned block holding the target, and nothing else asks for
        // exactly that range: the pump's refills are 32 MB and the tail prefetch is a suffix.
        #expect(server.requestedRanges.contains { $0.start == 4 * 1024 * 1024 && $0.end == 8 * 1024 * 1024 - 1 },
                "no detour block went out, so this measured nothing: \(server.requestedRanges)")

        // Arming a seek deadline must still reuse that resident block without network I/O.
        let requestsBeforeHit = server.rangeRequestCount
        reader.beginReadDeadline(secondsFromNow: 8)
        #expect(reader.seek(offset: target, whence: Int32(SEEK_SET)) == target)
        #expect(reader.read(into: buf, size: Int32(chunk)) == chunk)
        #expect(server.rangeRequestCount == requestsBeforeHit)
        reader.endReadDeadline()
    }

    @Test("bounded cold probing reanchors without a speculative block, then restores normal detours",
          .timeLimit(.minutes(2)))
    func boundedProbeSkipsColdDetour() throws {
        let server = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024,
                                                       throttleUs: 40_000, patternedBody: true))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/bounded.bin")!)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        let chunk = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        func readToThirteenMB(from start: Int) throws {
            var position = start
            while position < 13 * 1024 * 1024 {
                let n = Int(reader.read(into: buf, size: Int32(chunk)))
                try #require(n > 0)
                position += n
            }
        }
        try readToThirteenMB(from: 0)
        #expect(reader.hasLiveConnectionForTesting)
        let target: Int64 = 5 * 1024 * 1024
        reader.beginReadDeadline(secondsFromNow: 8)
        #expect(reader.seek(offset: target, whence: Int32(SEEK_SET)) == target)
        let n = Int(reader.read(into: buf, size: Int32(chunk)))
        #expect(n == chunk)
        #expect(!reader.readDeadlineFired)
        #expect((0..<max(0, n)).allSatisfy {
            buf[$0] == ThrottledOriginServer.patternByte(at: target + Int64($0))
        })
        #expect(server.requestedRanges.contains { $0.start == target })
        #expect(!server.requestedRanges.contains { $0.start == 4 * 1024 * 1024 && $0.end == 8 * 1024 * 1024 - 1 })
        reader.endReadDeadline()

        // The policy is scoped to the bounded operation, not a sticky source-wide downgrade.
        try readToThirteenMB(from: Int(target) + max(0, n))
        #expect(reader.seek(offset: target, whence: Int32(SEEK_SET)) == target)
        #expect(reader.read(into: buf, size: Int32(chunk)) == chunk)
        #expect(server.requestedRanges.contains { $0.start == 4 * 1024 * 1024 && $0.end == 8 * 1024 * 1024 - 1 })
    }

    #if os(macOS)
    /// #746 moved the 429 accounting into `syncRequest`'s completion callback, so the slot is not
    /// handed on before the refusal is on the books. The detour still charged the same answer again
    /// afterwards, and each charge halves the origin's concurrency and doubles its quiet period.
    @Test("a rate limited detour block is charged to the origin once", .timeLimit(.minutes(3)))
    func rateLimitedDetourChargedOnce() async throws {
        let origin = try #require(await RangeEchoOrigin(status: 429))
        defer { origin.stop() }
        let url = URL(string: "http://127.0.0.1:\(origin.port)/movie.bin")!
        let reader = AVIOReader(url: url)
        defer { reader.markClosed(); reader.close() }

        #expect(reader.detourFetchIsRateLimitedForTesting(from: 0, size: 1024))
        let books = try #require(OriginRequestBudget.shared.snapshot(for: url))
        #expect(books.refusals == 1, "one 429 was charged \(books.refusals) times")
    }
    #endif
}
