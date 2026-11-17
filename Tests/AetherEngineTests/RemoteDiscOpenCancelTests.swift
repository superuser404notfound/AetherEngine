import Testing
import Foundation
@testable import AetherEngine

/// Audit DMX-201: `Demuxer.markClosed()` has to reach a remote disc image's size probe, which runs
/// before any reader exists. Without it a stopped `.iso` open kept up to four range requests alive.
@Suite("Remote disc open is cancellable", .serialized, .offCooperativePool)
struct RemoteDiscOpenCancelTests {

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var failed = false
        var isFinished: Bool { lock.withLock { finished } }
        var didFail: Bool { lock.withLock { failed } }
        func done(failed: Bool) { lock.withLock { self.failed = failed; finished = true } }
    }

    @Test("markClosed ends a size probe that the origin never answers", .timeLimit(.minutes(3)))
    func markClosedEndsTheProbe() async throws {
        let origin = try #require(HeldHTTPOrigin())
        defer { origin.stop() }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        let outcome = Outcome()
        let url = origin.url("/movie.iso")
        Thread.detachNewThread {
            do { try demuxer.open(url: url); outcome.done(failed: false) } catch { outcome.done(failed: true) }
        }
        try await waitFor { origin.connectionCount >= 1 }
        demuxer.markClosed()
        try await waitFor { outcome.isFinished }
        #expect(outcome.didFail)
        #expect(origin.connectionCount == 1, "a cancelled probe must not start another attempt")
    }

    @Test("an open that was already closed never contacts the origin", .timeLimit(.minutes(3)))
    func closedBeforeOpenSendsNothing() throws {
        let origin = try #require(HeldHTTPOrigin())
        defer { origin.stop() }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        demuxer.markClosed()
        #expect(throws: (any Error).self) { try demuxer.open(url: origin.url("/movie.iso")) }
        #expect(origin.connectionCount == 0)
    }
}
