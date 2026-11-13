import Testing
import Foundation
@testable import AetherEngine

/// Live sources are open-ended by design, so the high-water end is the ONLY thing that
/// ever terminates a healthy live connection — and "re-request at the frontier" is a lie
/// to a live origin: the bytes broadcast during the drain are gone, and the demuxer
/// rejoins on a corrupt TS packet. IPTV panels also serve their ring buffer as a join
/// burst at line rate on every (re)connect, so the 16 MB VOD cap turned each reconnect
/// into the cause of the next one, forever. The live threshold absorbs the burst ONCE;
/// the end-and-refill stays as the memory backstop for a "live" source that sustainedly
/// outruns realtime (a misdeclared VOD). These tests pin both halves.
@Suite("AVIOReader live window backpressure", .offCooperativePool)
struct LiveWindowBackpressureTests {

    @Test("a live join burst past the VOD high water keeps its one connection",
          .timeLimit(.minutes(3)))
    func liveJoinBurstKeepsConnection() async throws {
        // The join-burst shape: 24 MB delivered at line rate into a stalled consumer,
        // then silence with the connection held open — no FIN, no error, exactly a live
        // origin that has caught up to realtime.
        let burst: Int64 = 24 * 1024 * 1024
        let serverMaybe = ThrottledOriginServer(
            totalSize: 512 * 1024 * 1024,
            respond: { _, _, _ in .serveThenGoSilent(afterBytes: burst) }
        )
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/live.ts")!,
                                isLive: true,
                                connStallTimeout: 600)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // The origin must be able to FINISH its burst: on the 16 MB threshold the reader
        // cancelled the task mid-burst and the remaining bytes were never accepted.
        try await waitFor { server.bytesWritten >= burst }
        #expect(server.bytesWritten >= burst,
                "origin only placed \(server.bytesWritten / (1024 * 1024)) MB of its \(burst / (1024 * 1024)) MB burst; the reader ended the connection")

        // Let the in-flight tail land in the window, then pin the live contract: the
        // burst is absorbed, the connection is NOT voluntarily ended, and no re-request
        // was ever issued.
        try await waitFor { reader.windowDiagnostics.aheadBytes >= Int(burst) }
        let diag = reader.windowDiagnostics
        #expect(diag.aheadBytes >= Int(burst),
                "window holds \(diag.aheadBytes / (1024 * 1024)) MB of the burst")
        #expect(!diag.parked, "a live burst inside the live threshold must not trip the end")
        #expect(reader.hasLiveConnectionForTesting,
                "the live connection must survive the burst")
        #expect(server.rangeRequestCount == 1,
                "a live reader re-requested mid-stream: \(server.requestedRanges)")
        #expect(server.requestedRanges.first?.end == nil,
                "the live request must be open-ended")
    }

    @Test("a live source past the live backstop is ended, stays bounded, and refills at the frontier",
          .timeLimit(.minutes(3)))
    func liveBackstopEndsAndRefills() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024))
        defer { server.stop() }
        // A shrunken backstop keeps the test inside seconds; the shipped live value only
        // changes WHERE the end fires, not what it does. (4 MB sits under winLowWater,
        // which just means the refill gate is already open on the first read.)
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/live.ts")!,
                                isLive: true,
                                connStallTimeout: 600,
                                windowHighWater: 4 * 1024 * 1024)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // A "live" origin outrunning realtime into a stalled consumer: the backstop must
        // end the connection (bounded memory, the #310 contract, unchanged for live).
        try await waitFor { !reader.hasLiveConnectionForTesting }
        #expect(!reader.hasLiveConnectionForTesting,
                "the live backstop must still end a connection that outruns the consumer")
        #expect(reader.windowDiagnostics.parked,
                "the backstop end must be recorded as backpressure so the refill owns it")
        #expect(server.rangeRequestCount == 1,
                "the refill must not fire while nothing drains: \(server.requestedRanges)")
        #expect(server.bytesWritten < 24 * 1024 * 1024,
                "origin served \(server.bytesWritten / (1024 * 1024)) MB past a 4 MB backstop")

        // Draining must trigger the frontier refill and keep delivering fresh bytes.
        let sliceCap = 256 * 1024
        let target = 12 * 1024 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got >= target, "only \(got / (1024 * 1024)) MB delivered after the backstop")
        #expect(server.rangeRequestCount >= 2, "the frontier refill never fired")
        // #331 follow-up: this origin answers every offset it is given, which is the shape of a
        // live source that is a growing file. The refill must RESUME at the frontier there, because
        // asking a byte-addressable live origin for zero re-delivers its whole buffer on top of
        // the window. The join shape is reserved for an origin that has rejected an offset.
        #expect(server.requestedRanges.dropFirst().allSatisfy { $0.start > 0 },
                "a refill against a range-honouring live origin restarted at byte zero: \(server.requestedRanges)")
        #expect(server.requestedRanges.allSatisfy { $0.end == nil },
                "every live request must be open-ended: \(server.requestedRanges)")
    }

    /// The field shape behind the fix's third half: a panel that CLEANLY ends every
    /// connection after serving its ring-buffer burst, and answers 416 to any request
    /// with a nonzero byte offset (a live stream has no byte addresses). Reconnecting
    /// "at the frontier" against such an origin is an unrecoverable rejection loop:
    /// every retry asks the same unsatisfiable offset until the runway drains and the
    /// session starves. The rejection is the signal: one 416 latches the join shape for
    /// the rest of the session, so the loop costs a single request and never repeats.
    @Test("a rejected live frontier latches the join shape for the rest of the session",
          .timeLimit(.minutes(3)))
    func liveReconnectAsksLikeAJoin() async throws {
        // 4 MB per connection: the origin serves its "ring buffer" and completes the
        // response; anything with offset > 0 is rejected the way the field panel does.
        let serverMaybe = ThrottledOriginServer(
            totalSize: 4 * 1024 * 1024,
            respond: { _, offset, _ in offset > 0 ? .status(416) : .serve206 }
        )
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/live.ts")!,
                                isLive: true,
                                connStallTimeout: 600)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Read through several burst-reconnect cycles: 10 MB needs at least three
        // connections against a 4 MB-per-connection origin.
        let sliceCap = 256 * 1024
        let target = 10 * 1024 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got >= target,
                "only \(got / (1024 * 1024)) MB delivered; the reconnect starved on a rejected frontier")
        #expect(server.rangeRequestCount >= 3, "expected one connection per burst cycle")
        // The latch costs exactly one rejected request per reader: the first reconnect asks at
        // the frontier (right for a byte-addressable live source), is told 416, and every
        // request after it is the join shape. Two or more rejections means the latch never took.
        let rejected = server.requestedRanges.filter { $0.start > 0 }
        #expect(rejected.count == 1,
                "the join shape must be latched by the first rejection: \(server.requestedRanges)")
        #expect(server.requestedRanges.last?.start == 0,
                "a live reconnect went on carrying a frontier offset: \(server.requestedRanges)")
    }
}
