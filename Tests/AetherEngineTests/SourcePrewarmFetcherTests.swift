import Testing
import Foundation
@testable import AetherEngine

extension PrewarmStoreSuites {
    /// #551: the fetch that fills the store, against an origin whose first byte costs something.
    ///
    /// `.serialized`: these share the process-wide prewarm store. They never reset the origin
    /// budget, which is process-wide too: a global reset from here tore the budget out from under
    /// suites running in parallel (measured, two unrelated failures), so a test that needs a ceiling
    /// sets it for its own origin and clears that one again.
    @Suite("Source prewarm fetch (#551)", .serialized, .timeLimit(.minutes(3)))
    struct SourcePrewarmFetcherTests {

        private let fileSize: Int64 = 64 * 1024 * 1024

        private func url(_ server: ThrottledOriginServer) -> URL {
            URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!
        }

        @Test("a warm retains the budget it was given and the size the origin stated")
        func warmRetainsBudget() async throws {
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }
            let store = SourcePrewarmStore(totalByteCap: 8 << 20)

            let report = await SourcePrewarmFetcher.warm(
                url: url(server), extraHeaders: [:], byteBudget: 256 * 1024, into: store)

            #expect(report.isWarm)
            #expect(report.retainedBytes == 256 * 1024)
            #expect(report.contentLength == fileSize)
            #expect(report.declined == nil)
            let warmed = try #require(store.take(for: url(server)))
            #expect(warmed.head.start == 0)
            #expect(warmed.head.data.count == 256 * 1024)
            #expect(warmed.contentLength == fileSize)
        }

        /// The body this origin serves is not an MP4, so the plan asks for no trailing object and the
        /// warm costs exactly one request. A second one against a metered origin is the expensive
        /// mistake this feature is not allowed to make by default.
        @Test("a warm that needs no trailing object costs exactly one request")
        func oneRequestWhenNoTailIsNeeded() async throws {
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }
            let store = SourcePrewarmStore(totalByteCap: 8 << 20)

            _ = await SourcePrewarmFetcher.warm(
                url: url(server), extraHeaders: [:], byteBudget: 128 * 1024, into: store)

            #expect(server.rangeRequestCount == 1, "requests: \(server.requestedRanges)")
            let asked = try #require(server.requestedRanges.first)
            #expect(asked.start == 0)
            #expect(asked.end == Int64(128 * 1024 - 1))
        }

        /// An origin that ignores `Range` is about to send the whole source. The decision has to be
        /// taken at the response header, not at the completion handler, or a prewarm of a 4 GB film
        /// downloads the film (the shape #255 paid for once already).
        @Test("an origin that ignores Range is declined at the header, and nothing is stored")
        func rangeIgnoringOriginIsDeclined() async throws {
            let refusing = ThrottledOriginServer(totalSize: fileSize,
                                                 respond: { _, _, _ in .status(200) })
            let server = try #require(refusing)
            defer { server.stop() }
            let store = SourcePrewarmStore(totalByteCap: 8 << 20)

            let report = await SourcePrewarmFetcher.warm(
                url: url(server), extraHeaders: [:], byteBudget: 128 * 1024, into: store)

            #expect(!report.isWarm)
            #expect(report.declined?.contains("200") == true)
            #expect(store.retainedBytes == 0)
        }

        /// The arbitration rule: on an origin metered down to one request at a time, the prewarm is
        /// not the request that gets to go. It declines without touching the network at all.
        @Test("a serial origin gets no speculative request")
        func serialOriginIsNotAsked() async throws {
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }
            let store = SourcePrewarmStore(totalByteCap: 8 << 20)
            OriginRequestBudget.shared.setHostLimit(1, for: url(server))
            defer { OriginRequestBudget.shared.setHostLimit(nil, for: url(server)) }

            let report = await SourcePrewarmFetcher.warm(
                url: url(server), extraHeaders: [:], byteBudget: 128 * 1024, into: store)

            #expect(!report.isWarm)
            #expect(server.rangeRequestCount == 0, "a serial origin was asked anyway: \(server.requestedRanges)")
            #expect(report.declined?.contains("#377") == true)
        }

        /// A cancelled warm makes no promises: a host that starts playing something else must not find
        /// half a source warm for a URL it has moved on from.
        @Test("a cancelled warm stores nothing")
        func cancelledWarmStoresNothing() async throws {
            let stalling = ThrottledOriginServer(totalSize: fileSize,
                                                 firstByteDelayUs: { _ in 30_000_000 })
            let server = try #require(stalling)
            defer { server.stop() }
            let store = SourcePrewarmStore(totalByteCap: 8 << 20)
            let target = url(server)

            let task = Task {
                await SourcePrewarmFetcher.warm(
                    url: target, extraHeaders: [:], byteBudget: 128 * 1024, into: store)
            }
            // Cancel once the fetch is on the wire, inside the stalled first byte. A fixed sleep here
            // could outlast the stall on a loaded runner and let the warm complete.
            try await waitFor { server.rangeRequestCount > 0 }
            task.cancel()
            let report = await task.value

            #expect(!report.isWarm)
            #expect(store.retainedBytes == 0)
        }

        /// The budget is not a promise either: a source smaller than the budget warms whole, and the
        /// span still has to describe what it actually holds.
        @Test("a source smaller than the budget warms whole")
        func smallSourceWarmsWhole() async throws {
            let small: Int64 = 40 * 1024
            let server = try #require(ThrottledOriginServer(totalSize: small))
            defer { server.stop() }
            let store = SourcePrewarmStore(totalByteCap: 8 << 20)

            let report = await SourcePrewarmFetcher.warm(
                url: url(server), extraHeaders: [:], byteBudget: 1 << 20, into: store)

            #expect(report.retainedBytes == Int(small))
            #expect(report.contentLength == small)
        }

        /// The other half of the runaway-download door. The 200 check stops an origin that ignores
        /// `Range` outright; this stops the one that answers 206 with MORE than was asked for, which is
        /// what an edge that rounds a range up to its own chunk boundary does. Without the check the
        /// body is buffered to whatever the header claimed, which on a film is the film.
        @Test("a 206 wider than the request is refused at the header")
        func overServingOriginIsRefused() async throws {
            let wide = ThrottledOriginServer(totalSize: fileSize, ignoreRangeEnd: true)
            let server = try #require(wide)
            defer { server.stop() }
            let store = SourcePrewarmStore(totalByteCap: 8 << 20)

            let report = await SourcePrewarmFetcher.warm(
                url: url(server), extraHeaders: [:], byteBudget: 128 * 1024, into: store)

            #expect(!report.isWarm)
            #expect(report.declined?.contains("asked for") == true, "declined: \(report.declined ?? "nil")")
            #expect(store.retainedBytes == 0)
        }

        /// A warm whose task was cancelled before it ever ran must return, not hang. The cancellation
        /// handler fires on the spot in that case, so the fetch can end before the caller has installed
        /// the handler that resumes it, and an outcome dropped there would strand the caller forever
        /// and hold the origin slot with it.
        @Test("a warm that starts already cancelled returns instead of hanging")
        func alreadyCancelledWarmReturns() async throws {
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }
            let store = SourcePrewarmStore(totalByteCap: 8 << 20)
            let target = url(server)

            let task = Task {
                while !Task.isCancelled { await Task.yield() }
                return await SourcePrewarmFetcher.warm(
                    url: target, extraHeaders: [:], byteBudget: 128 * 1024, into: store)
            }
            task.cancel()
            let report = await task.value

            #expect(!report.isWarm)
            #expect(store.retainedBytes == 0)
        }
    }
}
