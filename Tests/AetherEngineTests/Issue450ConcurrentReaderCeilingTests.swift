import Testing
import Foundation
@testable import AetherEngine

/// #450: what the reader's transport pools cost a process that runs more than one reader.
///
/// Reported shape: four live tiles against one Jellyfin origin, each its own engine. Tiles 1 and 2
/// tune, tiles 3 and 4 receive zero bytes and give up 15 s later, on sim and on device. Three
/// concurrent `curl` pulls of the same endpoints flow at full rate, so the origin is not the wall.
///
/// The wall was `httpMaximumConnectionsPerHost = 2` on `persistentSession`, a `static let`, so those
/// two connections were the whole process's allowance to one origin. On the bounded pool that number
/// throttles, because every request on it ends. On the open-ended pool nothing ahead of the third
/// request is going to end, so it is not slowed, it is parked, and URLSession parks it with no
/// callback, no error and no metrics: `awaitFirstPersistentData` then spends its full 15 s and the
/// load reports a source that would not open.
@Suite("Concurrent readers against one origin (#450)", .serialized)
struct Issue450ConcurrentReaderCeilingTests {

    /// ~400 KB/s. Slow on purpose: a loopback origin at full rate fills a held window to its
    /// high-water end within milliseconds, which ENDS that connection and hands the next reader the
    /// slot this case is about denying it. The fast origin is the one shape that cannot express it.
    private static let originChunkBytes = 8 * 1024
    private static let originThrottleUs: useconds_t = 20_000
    private static let originSize: Int64 = 8 * 1024 * 1024 * 1024

    private static func makeOrigin() -> ThrottledOriginServer? {
        ThrottledOriginServer(totalSize: originSize,
                              chunkBytes: originChunkBytes,
                              throttleUs: originThrottleUs)
    }

    /// Paths the origin was actually ASKED for, which is the only place the parked case shows: the
    /// third request does not fail, it never arrives.
    private static func pathsSeen(_ server: ThrottledOriginServer) -> [String] {
        server.requestLog.map(\.path)
    }

    private static func fireOpenEnded(_ session: URLSession, port: UInt16, count: Int) {
        for n in 1...count {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/probe\(n).ts")!)
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            request.timeoutInterval = 0
            session.dataTask(with: request) { _, _, _ in }.resume()
        }
    }

    private static func read(_ reader: AVIOReader, bytes target: Int) -> Int {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: target)
        defer { buf.deallocate() }
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(target - got))
            if n <= 0 { break }
            got += Int(n)
        }
        return got
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

    // MARK: - The transport contract the reader pools are built on

    /// The negative control. Without it the test below could pass for a reason that has nothing to
    /// do with the cap, and this suite would be measuring itself.
    @Test("a cap of two parks the third open-ended request", .timeLimit(.minutes(2)))
    func aCapOfTwoParksTheThirdOpenEndedRequest() async throws {
        let server = try #require(Self.makeOrigin())
        defer { server.stop() }

        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        Self.fireOpenEnded(session, port: server.port, count: 3)
        try await waitFor { Self.pathsSeen(server).count >= 2 }
        // The window the third request is given to show up and must not use.
        try await Task.sleep(for: .seconds(5))

        #expect(Self.pathsSeen(server).count == 2,
                "expected the cap to park one of three: \(Self.pathsSeen(server))")
    }

    @Test("the long-lived pool lets a third open-ended request through", .timeLimit(.minutes(2)))
    func longLivedPoolLetsTheThirdRequestThrough() async throws {
        let server = try #require(Self.makeOrigin())
        defer { server.stop() }

        // The shipped configuration, not a copy of it: a test that rebuilds the config it means to
        // check can keep passing after the shipped one changes underneath it.
        let session = URLSession(configuration: AVIOReader.makeSessionConfig(longLived: true))
        defer { session.invalidateAndCancel() }

        Self.fireOpenEnded(session, port: server.port, count: 3)
        try await waitFor { Self.pathsSeen(server).count >= 3 }

        #expect(Self.pathsSeen(server).count == 3,
                "an open-ended request was parked by the long-lived pool: \(Self.pathsSeen(server))")
    }

    // MARK: - The reader on top of it

    @Test("a third concurrent live reader reaches the origin", .timeLimit(.minutes(3)))
    func thirdConcurrentLiveReaderReachesTheOrigin() async throws {
        let server = try #require(Self.makeOrigin())
        defer { server.stop() }

        // The holders must still be holding when the third reader asks, so their windows are given
        // a high-water end this run cannot reach. Backpressure releasing a slot mid-test would be
        // indistinguishable from the fix.
        func openTile(_ n: Int) throws -> AVIOReader {
            let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/tile\(n).ts")!,
                                    label: "tile\(n)",
                                    isLive: true,
                                    windowHighWater: 512 * 1024 * 1024)
            try reader.open()
            return reader
        }

        // A live reader issues exactly one request, the open-ended `bytes=0-` pump: the tail
        // prefetch guards on `!isLive` and the size probes are skipped on this path, so every entry
        // in the origin's log below is a pump and is attributable by path.
        let held = try (1...2).map { try openTile($0) }
        defer { for reader in held { reader.markClosed(); reader.close() } }
        for (index, reader) in held.enumerated() {
            #expect(reader.windowDiagnostics.windowBytes > 0,
                    "holder \(index + 1) never delivered, so this run says nothing about the third")
        }

        let third = try openTile(3)
        defer { third.markClosed(); third.close() }

        #expect(Self.pathsSeen(server).contains("/tile3.ts"),
                "the third reader's request never reached the origin: \(Self.pathsSeen(server))")
        #expect(third.windowDiagnostics.windowBytes > 0,
                "the third reader opened with nothing delivered while two connections were held")
    }

    // MARK: - The witness

    /// #450: the reported case spent 15 s in silence because the only line that describes a
    /// connection delivering nothing is armed at `connStallTimeout` (20 s shipped), which is longer
    /// than the arcs that give up on a source first. The witness that speaks has to be inside them.
    @Test("a connection with no first byte is reported before the threshold ends it",
          .timeLimit(.minutes(2)))
    func aConnectionWithNoFirstByteIsReported() async throws {
        let stallTimeout: TimeInterval = 2.0
        let firstRange: Int64 = 2 * 1024 * 1024
        // AE#958: the frontier refill starts the overlap check's worth of held bytes early.
        let silenceOffset = firstRange - Int64(AVIOReader.rangeCheckBytes)
        let attempts = AttemptCounter()
        let serverMaybe = ThrottledOriginServer(
            totalSize: 256 * 1024 * 1024,
            respond: { _, offset, _ in
                offset == silenceOffset && attempts.next(for: offset) == 1
                    ? .serveThenGoSilent(afterBytes: 0) : .serve206
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }

        let sink = EngineLogCapture()
        defer { sink.end() }

        let label = "silent-\(UUID().uuidString)"
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                label: label,
                                boundedInitialFetch: firstRange,
                                connStallTimeout: stallTimeout)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Let the first range complete, then consume enough to put the refill on the wire. That
        // refill is the generation that receives headers and no body.
        try await waitFor { !reader.hasLiveConnectionForTesting }
        #expect(Self.read(reader, bytes: 512 * 1024) == 512 * 1024)
        // The capture sees every reader in the process, so the reader's own label picks its line.
        func reported() -> [String] { sink.matching(label).filter { $0.contains("no first byte after") } }
        try await waitFor { !reported().isEmpty }

        let lines = reported()
        #expect(!lines.isEmpty, "a generation that received headers and no body was never reported")
        // The two facts that separate a parked request from an origin sitting on one. Without them
        // the line names the silence but not the side it is on.
        #expect(lines.first?.contains("request(s) open to this origin") == true, "\(lines)")
        #expect(lines.first?.contains("connections per host") == true, "\(lines)")
    }
}
