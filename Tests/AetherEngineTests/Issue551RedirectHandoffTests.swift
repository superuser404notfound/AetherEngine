import Testing
import Foundation
@testable import AetherEngine

extension PrewarmStoreSuites {
    /// AE#551 round 2: what a warm knows about WHERE the bytes live, and what a request may carry
    /// once it goes there.
    ///
    /// The report: a stable resolver URL that 302s to a temporary CDN target was resolved by the warm
    /// and then resolved again by the load, for ~3.2 s of redirect TTFB the warm had already paid.
    /// Measured here as request counts against the source origin, which is the observable a loopback
    /// origin can answer honestly.
    ///
    /// The second half was found while fixing the first: pinning a cross-origin target and then
    /// building requests against it replays the media server's credential to that target, which is
    /// exactly what `RedirectHeaderPolicy` (#126) exists to prevent on the hop. One policy now runs
    /// where the request is built, so a pin cannot outflank it.
    ///
    /// `.serialized`: the prewarm store and the origin budget are process-wide.
    @Suite("#551 the warm's resolved target, and what travels to it", .serialized)
    struct Issue551RedirectHandoffTests {

        private let fileSize: Int64 = 64 * 1024 * 1024
        private let credentials = ["Authorization": "Bearer SOURCE-ONLY",
                                   "X-Emby-Token": "SOURCE-ONLY"]

        private func read(_ reader: AVIOReader, upTo target: Int) -> Int {
            let sliceCap = 128 * 1024
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
            defer { buf.deallocate() }
            var got = 0
            while got < target {
                let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
                if n <= 0 { break }
                got += Int(n)
            }
            return got
        }

        // MARK: - The handoff

        @Test("the load starts at the target the warm resolved instead of resolving it again",
              .timeLimit(.minutes(2)))
        func loadAdoptsTheWarmsResolvedTarget() async throws {
            SourcePrewarmStore.shared.clear()
            let cdn = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { cdn.stop() }
            let cdnPort = cdn.port
            let sourceMaybe = ThrottledOriginServer(
                totalSize: fileSize,
                respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin") })
            let source = try #require(sourceMaybe)
            defer { source.stop() }
            let url = URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!

            _ = await SourcePrewarmFetcher.warm(url: url, extraHeaders: [:],
                                                byteBudget: 256 * 1024, into: .shared)
            let resolvesForTheWarm = source.rangeRequestCount
            #expect(resolvesForTheWarm >= 1, "the warm has to have resolved the chain itself")

            let reader = AVIOReader(url: url)
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            #expect(read(reader, upTo: 384 * 1024) == 384 * 1024)

            #expect(source.rangeRequestCount == resolvesForTheWarm,
                    "the session resolved the chain a second time: \(source.requestLog)")
            // AE#958: the connection re-reads the warm's last `rangeCheckBytes` to check the origin.
            #expect(cdn.requestLog.contains(where: { $0.start >= 256 * 1024 - Int64(AVIOReader.rangeCheckBytes) }),
                    "the data connection never reached the resolved target: \(cdn.requestLog)")
        }

        @Test("a warm that never saw a redirect pins nothing", .timeLimit(.minutes(2)))
        func aDirectWarmPinsNothing() async throws {
            SourcePrewarmStore.shared.clear()
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }
            let url = URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!

            _ = await SourcePrewarmFetcher.warm(url: url, extraHeaders: [:],
                                                byteBudget: 256 * 1024, into: .shared)
            let warmed = try #require(SourcePrewarmStore.shared.take(for: url))
            #expect(warmed.resolvedURL?.absoluteString == url.absoluteString || warmed.resolvedURL == nil,
                    "a direct origin must not hand back a different target: \(String(describing: warmed.resolvedURL))")
        }

        // MARK: - What travels to the pinned target

        @Test("a credential header does not reach a cross-origin target the session pinned",
              .timeLimit(.minutes(2)))
        func credentialsStayOffThePinnedTarget() async throws {
            let firstRange: Int64 = 256 * 1024
            let cdn = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { cdn.stop() }
            let cdnPort = cdn.port
            let sourceMaybe = ThrottledOriginServer(
                totalSize: fileSize,
                respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin") })
            let source = try #require(sourceMaybe)
            defer { source.stop() }

            var headers = credentials
            // A non-credential header a header-dependent proxy needs (#8): it must still travel, or
            // the fix would have broken the thing the policy deliberately keeps.
            headers["Referer"] = "https://app.example"
            let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                    extraHeaders: headers,
                                    boundedInitialFetch: firstRange)
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            // Past the bounded first range, so at least one request is built against the PINNED target
            // rather than followed onto it through a 302.
            #expect(read(reader, upTo: Int(firstRange) + 128 * 1024) == Int(firstRange) + 128 * 1024)

            let atTarget = cdn.requestHeaders
            #expect(!atTarget.isEmpty, "the target served nothing, so the test proves nothing")
            #expect(!atTarget.contains(where: { $0["authorization"] != nil }),
                    "the media server's credential reached the CDN: \(atTarget)")
            #expect(!atTarget.contains(where: { $0["x-emby-token"] != nil }),
                    "the media server's token reached the CDN: \(atTarget)")
            #expect(atTarget.allSatisfy { $0["referer"] == "https://app.example" },
                    "a non-credential header stopped travelling: \(atTarget)")
            #expect(source.requestHeaders.allSatisfy { $0["authorization"] == "Bearer SOURCE-ONLY" },
                    "the source itself must still be authenticated: \(source.requestHeaders)")
        }

        @Test("the same-origin case keeps every header it always had", .timeLimit(.minutes(2)))
        func sameOriginKeepsCredentials() async throws {
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }
            let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                    extraHeaders: credentials)
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            #expect(read(reader, upTo: 128 * 1024) == 128 * 1024)

            #expect(!server.requestHeaders.isEmpty)
            #expect(server.requestHeaders.allSatisfy { $0["authorization"] == "Bearer SOURCE-ONLY" },
                    "an unredirected source lost its credential: \(server.requestHeaders)")
        }
    }
}
