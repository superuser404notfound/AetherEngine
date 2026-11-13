import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// Audit DMX-102 / DMX-109 / DMX-112: `Demuxer.markClosed()` is the one lock-free abort a teardown
/// has, and it only reached the stages that already had a provider to mark. The provider was
/// published after `provider.open()` returned, so a close during the connect (up to 15 s on a live
/// source) found nothing; a local-path source had no provider at all, so the interrupt callback
/// installed on it never saw the close; and a pump parked for an origin slot ignored it.
///
/// The bounds below are the assertions: every abort is measured against a wait the defect would
/// have sat out in full (10 s of withheld first byte, 10 s of slot wait).
@Suite("markClosed reaches every blocking stage of a demuxer", .serialized)
struct DemuxerMarkClosedReachTests {

    /// Cross-thread carrier for the result of an open running on a thread of its own.
    private final class OpenOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var _finished = false
        private var _threw = false
        var finished: Bool { lock.withLock { _finished } }
        var threw: Bool { lock.withLock { _threw } }
        func finish(threw: Bool) { lock.withLock { _finished = true; _threw = threw } }
    }

    private func openOnAThread(_ demuxer: Demuxer, url: URL, isLive: Bool) -> OpenOutcome {
        let outcome = OpenOutcome()
        Thread.detachNewThread {
            do {
                try demuxer.open(url: url, isLive: isLive)
                outcome.finish(threw: false)
            } catch {
                outcome.finish(threw: true)
            }
        }
        return outcome
    }

    @Test("a close that lands while the source is connecting aborts the open",
          .timeLimit(.minutes(3)), arguments: [true, false])
    func closeDuringConnectAbortsTheOpen(isLive: Bool) async throws {
        let origin = ThrottledOriginServer(
            totalSize: 64 << 20, patternedBody: true, firstByteDelayUs: { _ in 10_000_000 })
        let server = try #require(origin)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.ts")!

        let demuxer = Demuxer()
        let outcome = openOnAThread(demuxer, url: url, isLive: isLive)
        try await waitFor { server.requestedRanges.count >= 1 }
        demuxer.markClosed()

        let returned = try await waitFor(upTo: .seconds(4)) { outcome.finished }
        #expect(returned, "the open sat out the origin's withheld first byte after markClosed()")
        #expect(outcome.threw, "an aborted open must throw, not hand back a demuxer")
        demuxer.close()
    }

    @Test("a pump parked for an origin slot leaves when the demuxer is closed",
          .timeLimit(.minutes(3)))
    func closeReachesAParkedPump() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 64 << 20, patternedBody: true))
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.ts")!
        OriginRequestBudget.shared.setHostLimit(1, for: url)
        let holder = OriginRequestBudget.shared.acquire(for: url, label: "holder", timeout: 1)
        defer { OriginRequestBudget.shared.release(holder) }

        let demuxer = Demuxer()
        let outcome = openOnAThread(demuxer, url: url, isLive: false)
        try await waitFor { (OriginRequestBudget.shared.snapshot(for: url)?.waiting ?? 0) >= 1 }
        demuxer.markClosed()

        let returned = try await waitFor(upTo: .seconds(4)) { outcome.finished }
        #expect(returned, "the open stayed parked in the origin's slot queue after markClosed()")
        #expect(outcome.threw)
        try await waitFor { (OriginRequestBudget.shared.snapshot(for: url)?.waiting ?? 0) == 0 }
        #expect(OriginRequestBudget.shared.snapshot(for: url)?.inflight == 1,
                "the closed pump took a slot that belongs to the next session")
        demuxer.close()
    }

    @Test("a close on a local-path source stops the reads libavformat makes itself")
    func closeReachesALocalSource() throws {
        let tiny = TinyTransportStreamFixture.data
        var repeated = Data()
        for _ in 0..<400 { repeated.append(tiny) }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("markclosed-\(UUID().uuidString).ts")
        try repeated.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(url: file)
        demuxer.markClosed()

        // What libavformat already buffered during the probe is still delivered; the next read that
        // needs the file has to fail instead of finding it.
        var delivered = 0
        var failure: Error?
        while failure == nil, delivered < 100_000 {
            do {
                guard let read = try demuxer.readPacket() else { break }
                var packet: UnsafeMutablePointer<AVPacket>? = read
                trackedPacketFree(&packet)
                delivered += 1
            } catch {
                failure = error
            }
        }
        #expect(failure != nil, "a closed local source read all \(delivered) packets to its end")
    }
}
