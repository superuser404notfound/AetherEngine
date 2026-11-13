import Testing
import Foundation
@testable import AetherEngine

/// Backpressure history (#174 → #220 → #310) — each design fixed the previous one's failure
/// mode, and these tests pin the current one:
/// - #174: delegate-blocking had no flow-control contract (TLS/H2 transports keep reading at
///   line rate into unbounded URLSession-internal allocations until jetsam) and was replaced
///   with task suspend/resume.
/// - #220: suspend() measured advisory — 911 MB arrived after a suspend — so requests became
///   bounded ranges and a hard cap ended a connection the suspend failed to park.
/// - #310: a task that DID park held a dormant established flow whose closed receive window
///   starves every Network.framework flow in the process on user-space-networking OSes
///   (tvOS/iOS). The suspend is gone: at winHighWater the connection is ENDED and the read
///   loop re-requests at the frontier once the consumer drains below winLowWater. A stalled
///   or paused consumer therefore holds NO connection at all — which is what these tests pin.
///
/// They run a loopback HTTP/1.1 origin that counts every body byte it manages to write and
/// records every Range it is asked for.
@Suite("AVIOReader persistent backpressure (#174/#220/#310)", .offCooperativePool, .timeLimit(.minutes(3)))
struct Issue174PersistentReadBackpressureTests {


    // MARK: - Tests

    @Test("a stalled consumer is left with no live connection, not a parked one")
    func stalledConsumerEndsOriginConnection() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Nobody consumes: the demux side is deliberately parked, the exact #174 shape
        // (muxer backpressured on SegmentCache high water, no read ever advances position).
        // Wait for the high-water end itself, then leave a window in which a refill with
        // nothing draining would have to show up.
        try await waitFor { reader.windowDiagnostics.parked && !reader.hasLiveConnectionForTesting }
        try await Task.sleep(for: .seconds(1))

        // The #310 contract, in order of importance: the flow is GONE (a suspended task is a
        // dormant flow), the end is recorded as backpressure so the refill path owns it, the
        // window parked near winHighWater, the refill has not fired with nothing draining,
        // and the origin was never asked to serve past the one bounded range.
        #expect(!reader.hasLiveConnectionForTesting,
                "a stalled consumer must hold no connection")
        let diag = reader.windowDiagnostics
        #expect(diag.parked,
                "the end must be recorded as backpressure so the refill path owns it")
        #expect(diag.aheadBytes < 32 * 1024 * 1024,
                "window held \(diag.aheadBytes / (1024 * 1024)) MB against a 16 MB high water")
        #expect(server.requestedRanges.filter { $0.start == 0 }.count == 1,
                "the refill must not fire while nothing drains: \(server.requestedRanges)")
        #expect(server.bytesWritten < 48 * 1024 * 1024,
                "origin served \(server.bytesWritten / (1024 * 1024)) MB into a stalled consumer")
    }

    @Test("resuming consumption after a stall delivers fresh bytes at the frontier (refill liveness)")
    func drainAfterStallResumesDelivery() async throws {
        let totalSize: Int64 = 256 * 1024 * 1024
        let server = try #require(ThrottledOriginServer(totalSize: totalSize))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Stall long enough for the high-water end to engage, then consume far more than the
        // window: delivery must keep flowing, which proves the frontier refill runs.
        try await waitFor { reader.windowDiagnostics.parked }

        let sliceCap = 256 * 1024
        let target = 48 * 1024 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got >= target, "only \(got / (1024 * 1024)) MB delivered after the stall")

        // Every data-connection range must start at or past the previous one: a reconnect
        // that reset below the frontier would be re-fetching resident bytes. The open-time
        // speculative tail fetch is the one legitimate out-of-order range; it lives at the
        // far end of the file and is excluded by position.
        let dataStarts = server.requestedRanges.map(\.start)
            .filter { $0 < totalSize - Int64(1024 * 1024) }
        #expect(dataStarts == dataStarts.sorted(),
                "a refill went backwards past the frontier: \(server.requestedRanges)")
    }

    @Test("teardown during the backpressure-ended state does not hang")
    func teardownWhileParked() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        try reader.open()

        try await waitFor { reader.windowDiagnostics.parked }

        // Completing without a hang is the assertion: nothing may be left waiting on a
        // connection that was deliberately ended and will never refill after close.
        reader.markClosed()
        reader.close()
        #expect(!reader.hasLiveConnectionForTesting)
    }

    /// #220: bounded ranges cannot be exercised against an origin that ignores the range end.
    /// It would stream to EOF whatever was asked for, and every later assertion about window
    /// size or request count would be measuring the server's behaviour instead of the reader's.
    @Test("the test origin serves exactly the requested range and no more")
    func originHonoursFiniteRange() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        request.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(data.count == 1024 * 1024)
        #expect(server.requestedRanges.first?.end == 1_048_575)
    }
}
