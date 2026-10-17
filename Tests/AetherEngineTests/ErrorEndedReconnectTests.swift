import Testing
import Foundation
@testable import AetherEngine

/// A connection that ended in ERROR without delivering a single byte of its generation used
/// to be routed through the no-connection reposition branch: `seekReconnect` cleared the
/// unproductive streak and applied no backoff, so an origin refusing every refill (e.g. a
/// connection-capped Xtream panel answering 500 at a range boundary) turned into an
/// unbounded reconnect spiral (~15 connections/s, observed 925 reconnects in 60 s) that
/// only ended when the segment provider tore the demuxer down from outside.
///
/// `.serialized`: these tests mutate the process-wide backoff-scale test hook.
@Suite("Error-ended zero-byte reconnects", .serialized, .offCooperativePool)
struct ErrorEndedReconnectTests {

    private final class PhaseLog: @unchecked Sendable {
        private let lock = NSLock()
        private var phases: [ReaderNetworkPhase] = []
        func append(_ phase: ReaderNetworkPhase) {
            lock.lock(); phases.append(phase); lock.unlock()
        }
        func contains(_ phase: ReaderNetworkPhase) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return phases.contains(phase)
        }
    }

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int64: Int] = [:]
        func next(for offset: Int64) -> Int {
            lock.lock(); defer { lock.unlock() }
            let n = (counts[offset] ?? 0) + 1
            counts[offset] = n
            return n
        }
    }

    /// The spiral itself: every refill refused with a hard 500. The reader must charge the
    /// failure ladder (status accounting, backoff, `.reconnecting`, bounded give-up) instead
    /// of reconnecting forever off the books.
    @Test("an origin refusing every refill is retried with backoff and given up on",
          .timeLimit(.minutes(2)))
    func refusedRefillIsBoundedAndGivenUp() async throws {
        let firstRange: Int64 = 512 * 1024
        let serverMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in offset < firstRange ? .serve206 : .status(500) }
        )
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: firstRange,
                                backoffScale: 0.02)
        defer { reader.markClosed(); reader.close() }
        let phases = PhaseLog()
        reader.onNetworkPhaseChanged = { phases.append($0) }
        try reader.open()

        let sliceCap = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        var result: Int32 = 0
        while true {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { result = n; break }
            got += Int(n)
        }

        #expect(got == Int(firstRange), "the delivered first range must still be served")
        #expect(result == -1, "a refused source must fail the read, not hang")
        // Streak 0..12 then give-up: ~14 attempts. The bug produced hundreds; leave slack
        // for the odd URLSession-level retry without letting a spiral pass.
        let attemptsAtBoundary = server.requestedRanges.filter { $0.start == firstRange }.count
        #expect(attemptsAtBoundary >= 2, "the failure must have been retried at all")
        #expect(attemptsAtBoundary <= 20,
                "reconnect spiral: \(attemptsAtBoundary) attempts at offset \(firstRange)")
        #expect(phases.contains(.reconnecting),
                "the failed refill never surfaced as `.reconnecting` to the host")
    }

    /// The counterpart the guard must not break: a SINGLE dropped refill connection is a
    /// transient. The first ladder pass sees real progress since the last accounting, keeps
    /// the streak at zero, applies no backoff, and the retry completes the read.
    @Test("a single dropped refill connection recovers and completes the read",
          .timeLimit(.minutes(2)))
    func transientRefillFailureRecovers() async throws {
        let firstRange: Int64 = 512 * 1024
        let attempts = AttemptCounter()
        let serverMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in
                offset == firstRange && attempts.next(for: offset) == 1
                    ? .dropConnection : .serve206
            }
        )
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        let target = Int(firstRange) + 512 * 1024
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }

        #expect(got == target, "read stopped at \(got) of \(target) after a transient failure")
        #expect(reader.unproductiveReconnectsForTesting == 0,
                "a healed transient must not leave a failure streak behind")
    }

    /// Regression guard for the healthy path: a range boundary on a well-behaved origin
    /// stays off the failure ladder entirely — no streak, no `.reconnecting`.
    @Test("healthy range boundaries stay off the failure ladder", .timeLimit(.minutes(2)))
    func healthyBoundariesKeepFastPath() async throws {
        let firstRange: Int64 = 256 * 1024
        let server = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: firstRange)
        defer { reader.markClosed(); reader.close() }
        let phases = PhaseLog()
        reader.onNetworkPhaseChanged = { phases.append($0) }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        let target = Int(firstRange) * 2
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            got += Int(n)
        }

        #expect(got == target, "sequential read stopped early at \(got) of \(target)")
        #expect(reader.unproductiveReconnectsForTesting == 0)
        #expect(!phases.contains(.reconnecting),
                "a planned range boundary must not read as a reconnect to the host")
    }
}
