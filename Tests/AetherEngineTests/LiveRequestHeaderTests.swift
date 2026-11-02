import Testing
import Foundation
@testable import AetherEngine

/// AE#792: a session's request headers can be replaced while it plays, and the reader that is
/// already open sends the new set on its next request.
///
/// The shape this exists for is a media server whose bearer tokens live an hour. Mid-title the
/// origin starts refusing the token the reader was opened with; the host mints a new one and hands
/// it over; the reader's reconnect, already backing off, must carry it rather than the header it
/// froze at its open. Before the store, the only way to get it there was a rebuild of the session.
@Suite("Live request headers", .serialized, .offCooperativePool)
struct LiveRequestHeaderTests {

    /// An origin whose first token lapses after the opening range: "first" is served below
    /// `lapsesAt` and refused from there on, "second" is served everywhere. Tying the lapse to the
    /// offset rather than to a moment keeps the read from racing the rotation.
    ///
    /// The host's renewal happens here too, on the refusal numbered `renewsAtRefusal`, before that
    /// 401 goes out. A test task that watched for the refusal and then renewed raced the reader's
    /// credential ladder (`AVIOReader.credentialRefusalMaxStreak`, about 3 s), which a loaded
    /// runner overran: the reader gave up before the renewal landed.
    final class TokenGate: @unchecked Sendable {
        private let lock = NSLock()
        private var refused = 0
        let lapsesAt: Int64
        let renewsAtRefusal: Int
        weak var origin: ThrottledOriginServer?
        var renew: (@Sendable () -> Void)?

        init(lapsesAt: Int64, renewsAtRefusal: Int) {
            self.lapsesAt = lapsesAt
            self.renewsAtRefusal = renewsAtRefusal
        }
        var refusals: Int { lock.withLock { refused } }

        func answer(_ index: Int, offset: Int64) -> ThrottledOriginServer.Directive {
            let sent = origin?.requestHeaders[index]["authorization"]
            if sent == "Bearer second" || (sent == "Bearer first" && offset < lapsesAt) { return .serve206 }
            let count = lock.withLock { refused += 1; return refused }
            if count == renewsAtRefusal { renew?() }
            return .status(401)
        }
    }

    @Test("a reader stalled on a refused token heals on the next attempt once the store holds a new one",
          .timeLimit(.minutes(2)))
    func refusedTokenHealsWithoutReopen() async throws {
        let firstRange: Int64 = 256 * 1024
        // The last refusal the ladder still retries after: the reader is mid-ladder, on the stale
        // token, when the renewal lands.
        // AE#958: the refill asks `rangeCheckBytes` early, which is where the lapse has to bite.
        let gate = TokenGate(lapsesAt: firstRange - Int64(AVIOReader.rangeCheckBytes),
                             renewsAtRefusal: AVIOReader.credentialRefusalMaxStreak)
        let originMaybe = ThrottledOriginServer(totalSize: 64 * 1024 * 1024,
                                                respond: { index, offset, _ in gate.answer(index, offset: offset) })
        let origin = try #require(originMaybe)
        gate.origin = origin
        defer { origin.stop() }

        let store = RequestHeaderStore(["Authorization": "Bearer first"])
        gate.renew = { store.replace(["Authorization": "Bearer second"]) }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(origin.port)/movie.bin")!,
                                extraHeaders: store.current,
                                boundedInitialFetch: firstRange,
                                requestHeaderStore: store)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let target = Int(firstRange) + 1024 * 1024
        let delivered = Delivered()
        Thread.detachNewThread {
            let sliceCap = 128 * 1024
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
            defer { buf.deallocate() }
            var got = 0
            while got < target {
                let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
                if n <= 0 { break }
                got += Int(n)
            }
            delivered.finish(got)
        }

        try await waitFor { delivered.total != nil }
        #expect(delivered.total == target, "the read healed past the refusal instead of failing")
        #expect(gate.refusals == AVIOReader.credentialRefusalMaxStreak, "the renewal landed mid-ladder")
        let sent = origin.requestHeaders.map { $0["authorization"] }
        #expect(sent.last == "Bearer second", "the healing request carried the renewed token")
        // One reader all the way through: the same AVIOReader was never reopened, it only reconnected.
        #expect(sent.first == "Bearer first")
    }

    @Test("a reader opened without a store keeps the headers it was opened with")
    func readerWithoutStoreKeepsItsHeaders() async throws {
        let originMaybe = ThrottledOriginServer(totalSize: 4 * 1024 * 1024)
        let origin = try #require(originMaybe)
        defer { origin.stop() }
        let unrelated = RequestHeaderStore(["Authorization": "Bearer session"])
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(origin.port)/side.bin")!,
                                extraHeaders: ["Authorization": "Bearer opened"],
                                boundedInitialFetch: 64 * 1024)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        unrelated.replace(["Authorization": "Bearer rotated"])
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buf.deallocate() }
        _ = reader.read(into: buf, size: 64 * 1024)
        #expect(origin.requestHeaders.allSatisfy { $0["authorization"] == "Bearer opened" })
    }

    /// The session's still extractor (`makeFrameExtractor()`) opens its demuxer lazily, on the first
    /// scrub after the extractor was built, and again after an idle close, so it must read the store
    /// at that moment, not the token current when the host asked for the extractor.
    @Test("a still extractor over the session's source opens with the rotated headers")
    func stillExtractorFollowsTheStore() throws {
        let originMaybe = ThrottledOriginServer(totalSize: 4 * 1024 * 1024)
        let origin = try #require(originMaybe)
        defer { origin.stop() }
        let store = RequestHeaderStore(["Authorization": "Bearer first"])
        let context = FrameDecodeContext(url: URL(string: "http://127.0.0.1:\(origin.port)/movie.bin")!,
                                         httpHeaders: store.current, requestHeaderStore: store)
        defer { context.close() }
        store.replace(["Authorization": "Bearer second"])
        // The bytes are not a container, so the open fails after its requests; only their headers matter.
        try? context.ensureOpen()
        let sent = origin.requestHeaders.map { $0["authorization"] }
        #expect(!sent.isEmpty, "the open reached the origin")
        #expect(sent.allSatisfy { $0 == "Bearer second" })
    }

    @Test("the outcome says live only where every source request is built by the session's readers")
    func outcomeFollowsWhoOwnsTheRequests() {
        func outcome(custom: Bool = false, disc: Bool = false, route: VideoRoute,
                     avAudio: Bool = false) -> RequestHeaderUpdateOutcome {
            .forSession(isCustomSource: custom, isDiscImage: disc, route: route,
                        audioRequestsOwnedByAVFoundation: avAudio)
        }
        #expect(outcome(route: .loopback) == .appliedToLiveRequests)
        #expect(outcome(route: .software) == .appliedToLiveRequests)
        #expect(outcome(route: .audio) == .appliedToLiveRequests)
        #expect(outcome(route: .none) == .appliedToLiveRequests)
        #expect(outcome(route: .remoteBypass) == .installedForNextRebuild)
        #expect(outcome(route: .audio, avAudio: true) == .installedForNextRebuild)
        #expect(outcome(custom: true, route: .loopback) == .installedForNextRebuild)
        #expect(outcome(disc: true, route: .loopback) == .installedForNextRebuild)
    }

    @Test("without a session the call installs nothing")
    @MainActor
    func noSessionInstallsNothing() throws {
        let engine = try AetherEngine()
        #expect(engine.updateRequestHeaders(["Authorization": "Bearer x"]) == .noActiveSession)
        #expect(engine.loadedOptions.httpHeaders.isEmpty)
    }

    final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int?
        func finish(_ n: Int) { lock.withLock { value = n } }
        var total: Int? { lock.withLock { value } }
    }
}
