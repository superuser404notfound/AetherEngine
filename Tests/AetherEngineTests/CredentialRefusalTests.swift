import Testing
import Foundation
@testable import AetherEngine

/// AE#792 part 2: a credential the origin refuses mid-session is told apart from a lost source. The
/// reader gives it a short ladder and stamps it on the session's header store, the store announces
/// it once per header set, and the engine revives only after the host replaced the headers.
@Suite("Credential refusal", .serialized, .offCooperativePool)
struct CredentialRefusalTests {

    // MARK: - Store

    @Test("replace bumps the revision")
    func revisionMoves() {
        let store = RequestHeaderStore(["Authorization": "Bearer a"])
        #expect(store.revision == 0)
        store.replace(["Authorization": "Bearer b"])
        #expect(store.revision == 1)
    }

    @Test("a refusal is announced once per revision, and a stale one does not replace a newer")
    func refusalAnnouncedOncePerRevision() {
        let store = RequestHeaderStore(["Authorization": "Bearer a"])
        let seen = Seen()
        store.onCredentialRefusal = { seen.add($0) }
        store.noteCredentialRefusal(status: 401, revision: 0)
        store.noteCredentialRefusal(status: 401, revision: 0)
        #expect(seen.values == [401])
        store.replace(["Authorization": "Bearer b"])
        store.noteCredentialRefusal(status: 403, revision: 1)
        #expect(seen.values == [401, 403])
        // A late answer to the replaced credential says nothing about the current one.
        store.noteCredentialRefusal(status: 401, revision: 0)
        #expect(store.recentCredentialRefusal(within: 60)?.revision == 1)
        #expect(store.recentCredentialRefusal(within: 60)?.status == 403)
        #expect(seen.values == [401, 403])
    }

    @Test("a refusal older than the window is not recent")
    func refusalWindow() {
        let store = RequestHeaderStore([:])
        store.noteCredentialRefusal(status: 401, revision: 0, at: Date().addingTimeInterval(-120))
        #expect(store.recentCredentialRefusal(within: 60) == nil)
        #expect(store.recentCredentialRefusal(within: 600)?.status == 401)
    }

    // MARK: - Engine decisions

    @Test("revive only once the headers moved past the refused revision")
    func revivePlan() {
        #expect(HLSVideoEngine.credentialRefusalPlan(refusedRevision: 3, currentRevision: 3) == .awaitRenewal)
        #expect(HLSVideoEngine.credentialRefusalPlan(refusedRevision: 3, currentRevision: 4) == .revive)
    }

    @Test("a software pipeline failure over a refused credential reaches the host as sourceRefused")
    func softwareFailureReclassified() {
        let failed = PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "read failed")
        let refusal = RequestHeaderStore.CredentialRefusal(status: 401, revision: 0, at: Date())
        let typed = AetherEngine.reclassifiedForCredentialRefusal(failed, refusal: refusal)
        #expect(typed.kind == .sourceRefused)
        #expect(typed.underlyingCode == 401)
        #expect(AetherEngine.reclassifiedForCredentialRefusal(failed, refusal: nil).kind == .softwarePipelineFailed)
        let other = PlaybackErrorInfo(kind: .nativeItemFailed, message: "x")
        #expect(AetherEngine.reclassifiedForCredentialRefusal(other, refusal: refusal).kind == .nativeItemFailed)
    }

    // MARK: - Reader

    /// The origin serves the opening range and refuses every request past it with 401, whatever
    /// the token. The unproductive ladder spent about 80 s on this; the credential ladder gives up
    /// after its third refusal, a few seconds in, with the refusal on the store.
    @Test("a reader refused 401 mid-stream gives up in seconds and stamps the store",
          .timeLimit(.minutes(3)))
    func refusedReaderGivesUpQuickly() async throws {
        let firstRange: Int64 = 256 * 1024
        let originMaybe = ThrottledOriginServer(totalSize: 64 * 1024 * 1024, respond: { _, offset, _ in
            offset < firstRange ? .serve206 : .status(401)
        })
        let origin = try #require(originMaybe)
        defer { origin.stop() }

        let store = RequestHeaderStore(["Authorization": "Bearer lapsed"])
        let seen = Seen()
        store.onCredentialRefusal = { seen.add($0) }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(origin.port)/movie.bin")!,
                                extraHeaders: store.current, boundedInitialFetch: firstRange,
                                requestHeaderStore: store)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let started = Date()
        let result = Result()
        Thread.detachNewThread {
            let cap = 128 * 1024
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
            defer { buf.deallocate() }
            var got = 0
            var last: Int32 = 0
            while got < Int(firstRange) + 1024 * 1024 {
                last = reader.read(into: buf, size: Int32(cap))
                if last <= 0 { break }
                got += Int(last)
            }
            result.finish(last)
        }
        try await waitFor { result.code != nil }
        let elapsed = Date().timeIntervalSince(started)
        #expect((result.code ?? 0) < 0, "the read failed instead of delivering")
        #expect(elapsed < 15, "gave up after \(elapsed)s; the unproductive ladder takes about 80 s")
        #expect(store.recentCredentialRefusal(within: 60)?.status == 401)
        #expect(store.recentCredentialRefusal(within: 60)?.revision == 0)
        #expect(seen.values == [401], "announced once for the one header set")
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Int] = []
        func add(_ v: Int) { lock.withLock { list.append(v) } }
        var values: [Int] { lock.withLock { list } }
    }

    final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32?
        func finish(_ v: Int32) { lock.withLock { value = v } }
        var code: Int32? { lock.withLock { value } }
    }
}
