import Foundation
import Testing
@testable import AetherEngine

/// Fires `action` from a thread of its own the moment `condition` holds. The engine work runs on
/// `ProbeTestJob`'s thread, so a step that must land inside one of its short windows (a slot wait,
/// a stalled body) cannot be left to an async test task: on a loaded runner the cooperative pool
/// resumed those 20 ms polls tens of seconds late, missed the window, and the test hung or saw a
/// timeout it was not about.
private final class ProbeTestTrigger: @unchecked Sendable {
    private let fired = ProbeTestBox(false)
    var didFire: Bool { fired.value }

    init(deadline seconds: TimeInterval = 300, when condition: @escaping @Sendable () -> Bool,
         _ action: @escaping @Sendable () -> Void) {
        let fired = self.fired
        Thread.detachNewThread {
            let end = Date(timeIntervalSinceNow: seconds)
            while !condition() {
                guard Date() < end else { return }
                usleep(1_000)
            }
            action()
            fired.update { $0 = true }
        }
    }
}

@Suite(.timeLimit(.minutes(3)))
struct SourceOpenRecoveryTests {
    private let bytes = Data(repeating: 0x47, count: 8192)

    private func url(_ origin: ProbeHTTPTestOrigin) -> URL {
        URL(string: "http://127.0.0.1:\(origin.port)/media.bin")!
    }

    private func readPrefix(_ reader: AVIOReader) async throws -> Data {
        let job = ProbeTestJob {
            var data = Data(count: 16)
            let count = data.withUnsafeMutableBytes {
                reader.read(into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), size: 16)
            }
            return count > 0 ? Data(data.prefix(Int(count))) : Data()
        }
        return try await job.outcome().get()
    }

    @Test("A silent initial request reaches the alternate request shape within the host budget")
    func coldRequestRecovery() async throws {
        // Silence is keyed on the request shape, not on arrival order: on a loaded runner the first
        // request can be cancelled at its first-byte deadline before it ever reaches the wire, and
        // then the alternate request is the first one the origin sees.
        let silence = ProbeTestGate()
        let origin = try ProbeHTTPTestOrigin(data: bytes, response: { request, _ in
            if request.range != "bytes=0-" { silence.wait() }
            return nil
        })
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let reader = AVIOReader(url: source, boundedInitialFetch: 4096,
            sourceOpenPolicy: .init(firstByteTimeout: 0.2, sizeProbeTimeout: 2))
        defer { reader.markClosed(); reader.close(); silence.open(); origin.stop() }
        try await ProbeTestJob { try reader.open() }.outcome().get()
        #expect(reader.isSeekable)
        #expect(try await readPrefix(reader) == bytes.prefix(16))
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.peakInflight == 1)
        #expect(origin.requests.map(\.method).allSatisfy { $0 == "GET" })
        #expect(origin.requests.filter { $0.range == "bytes=0-" }.count == 1,
                "the recovered data connection must be retained, not reprobed")
        #expect(origin.requests.count <= 2)
        #expect(origin.failure == nil)
    }

    @Test("A single-request origin tries Range, HEAD and bounded Range without a speculative fan")
    func serialFallbacks() async throws {
        let origin = try ProbeHTTPTestOrigin(data: bytes, response: { request, index in
            guard index < 2 else { return nil }
            let status = request.method == "HEAD" ? 403 : 405
            return Data("HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        })
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let reader = AVIOReader(url: source, prefetchEnabled: false,
            sourceOpenPolicy: .init(firstByteTimeout: 1, sizeProbeTimeout: 3))
        defer { reader.markClosed(); reader.close(); origin.stop() }
        try await ProbeTestJob { try reader.open() }.outcome().get()
        #expect(reader.isSeekable)
        #expect(try await readPrefix(reader) == bytes.prefix(16))
        #expect(Array(origin.requests.prefix(3).map(\.method)) == ["GET", "HEAD", "GET"])
        #expect(Array(origin.requests.prefix(3).map(\.range)) == ["bytes=0-", nil, "bytes=0-1"])
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.peakInflight == 1)
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.inflight == 0)
        #expect(origin.failure == nil)
    }

    @Test("A held connection whose headers resolved the size survives a delayed body")
    func slowBodyKeepsConnection() async throws {
        let origin = try ProbeHTTPTestOrigin(data: bytes, stage: .body, stallOpenEndedBody: true)
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        // The held transport exposes the response head before any body byte. URLSession can
        // coalesce them, which would exercise the unknown-size fallback instead of this branch.
        let reader = AVIOReader(url: source, boundedInitialFetch: 4096, heldConnection: true,
            sourceOpenPolicy: .init(firstByteTimeout: 0.2, sizeProbeTimeout: 2))
        defer { reader.markClosed(); reader.close(); origin.stop() }
        let job = ProbeTestJob { try reader.open() }
        // Release the body the moment the open returns, before the stall machinery can give up on
        // it, and count the requests at that same moment.
        let requestsAtOpen = ProbeTestBox(-1)
        let release = ProbeTestTrigger(when: { job.isFinished }) {
            requestsAtOpen.update { $0 = origin.requests.count }
            origin.blocked.open()
        }
        try await job.outcome().get()
        try await waitFor { release.didFire }
        #expect(origin.blocked.entered)
        #expect(reader.isSeekable)
        #expect(requestsAtOpen.value == 1, "a slow body must not cause a redundant size probe")
        #expect(try await readPrefix(reader) == bytes.prefix(16))
        // Reading can legitimately trigger a new forward prefetch after the initial window.
        // It must not repeat discovery or restart from zero.
        #expect(origin.requests.dropFirst().allSatisfy {
            $0.method == "GET" && $0.range != nil && $0.range != "bytes=0-"
                && $0.range != "bytes=0-4095"
        })
    }

    @Test("Silent serial fallbacks share one deadline before forward-only playback")
    func sharedProbeDeadline() async throws {
        let gate = ProbeTestGate()
        let origin = try ProbeHTTPTestOrigin(data: bytes, response: { request, _ in
            if request.range == "bytes=0-" || request.range == "bytes=0-1" || request.method == "HEAD" {
                gate.wait()
            }
            return nil
        })
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let reader = AVIOReader(url: source, prefetchEnabled: false,
            sourceOpenPolicy: .init(firstByteTimeout: 1, sizeProbeTimeout: 0.45))
        defer { reader.markClosed(); reader.close(); gate.open(); origin.stop() }
        let job = ProbeTestJob { try reader.open() }
        try await job.outcome().get()
        #expect(!reader.isSeekable, "without a size, playback must not advertise byte seeking")
        #expect(try await readPrefix(reader) == bytes.prefix(16))
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.inflight == 0)
    }

    @Test("A winning size probe cancels and joins its slow siblings before data fetch")
    func winningProbeReleasesSiblings() async throws {
        let gate = ProbeTestGate()
        let origin = try ProbeHTTPTestOrigin(data: bytes, response: { request, _ in
            if request.range == "bytes=0-" || request.range == "bytes=0-1" { gate.wait() }
            return nil
        })
        let source = url(origin)
        let reader = AVIOReader(url: source, prefetchEnabled: false,
            sourceOpenPolicy: .init(firstByteTimeout: 1, sizeProbeTimeout: 10))
        defer { reader.markClosed(); reader.close(); gate.open(); origin.stop() }
        let job = ProbeTestJob { try reader.open() }
        try await waitFor { gate.entered }
        try await job.outcome().get()
        #expect(!gate.isOpen, "the winner must not wait for the losing origin to respond")
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.inflight == 0,
                "no losing probe may retain a ticket after open")
        #expect(reader.isSeekable)
        #expect(try await readPrefix(reader) == bytes.prefix(16))
    }

    @Test("Teardown cancels a metadata request waiting for the origin slot")
    func cancellationWhileWaitingForSlot() async throws {
        let origin = try ProbeHTTPTestOrigin(data: bytes)
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let ticket = OriginRequestBudget.shared.acquire(for: source, label: "test-holder", timeout: 1)
        let reader = AVIOReader(url: source, prefetchEnabled: false,
            sourceOpenPolicy: .init(firstByteTimeout: 1, sizeProbeTimeout: 30))
        defer { reader.close(); OriginRequestBudget.shared.release(ticket); origin.stop() }
        let job = ProbeTestJob { try reader.open() }
        let parked = ProbeTestBox(false)
        let teardown = ProbeTestTrigger(when: {
            OriginRequestBudget.shared.snapshot(for: source)?.waiting == 1 || job.isFinished
        }) {
            parked.update { $0 = !job.isFinished }
            reader.markClosed()
        }
        let result = try await job.outcome()
        try await waitFor { teardown.didFire }
        try #require(parked.value, "the size probe never parked for the held slot")
        if case .success = result { Issue.record("cancelled open must not succeed") }
        #expect(origin.requests.isEmpty)
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.inflight == 1)
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.waiting == 0)
    }
    @Test("Unanswered opens fail within their budgets without inventing a forward-only source")
    func unansweredOpenDoesNotBecomeSequential() async throws {
        let gate = ProbeTestGate()
        let origin = try ProbeHTTPTestOrigin(data: bytes, response: { _, _ in gate.wait(); return nil })
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let reader = AVIOReader(url: source,
            sourceOpenPolicy: .init(firstByteTimeout: 0.15, sizeProbeTimeout: 0.25))
        defer { reader.markClosed(); reader.close(); gate.open(); origin.stop() }
        let job = ProbeTestJob { try reader.open() }
        let result = try await job.outcome()
        if case .failure(let error) = result {
            #expect(error as? AVIOReaderError == .requestTimeout)
        } else { Issue.record("no response is not a successful sequential open") }
        // Either request can be cancelled at its deadline before it reaches the wire on a loaded
        // runner, so the count is a ceiling: two ranged GETs at most, never an unranged one.
        #expect(origin.requests.count <= 2)
        #expect(origin.requests.allSatisfy { $0.method == "GET" && $0.range != nil })
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.inflight == 0)
    }

    @Test("Cancelling the alternate data open releases the origin slot promptly")
    func cancelDataRetry() async throws {
        let gate = ProbeTestGate()
        let origin = try ProbeHTTPTestOrigin(data: bytes, response: { _, _ in gate.wait(); return nil })
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let reader = AVIOReader(url: source,
            sourceOpenPolicy: .init(firstByteTimeout: 0.15, sizeProbeTimeout: 30))
        defer { reader.close(); gate.open(); origin.stop() }
        let job = ProbeTestJob { try reader.open() }
        // Keyed on the alternate request's shape: the first request can be cancelled before it
        // reaches the wire on a loaded runner, so counting arrivals can wait for one that never comes.
        let teardown = ProbeTestTrigger(when: {
            origin.requests.contains { $0.range == "bytes=0-" } || job.isFinished
        }) {
            reader.markClosed()
        }
        let result = try await job.outcome()
        try await waitFor { teardown.didFire }
        if case .failure(let error) = result { #expect(error is CancellationError) }
        else { Issue.record("cancelled data retry must not open") }
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.inflight == 0)
    }

    @Test("A truncated 206 body recovers without losing or duplicating bytes")
    func truncatedBodyRecovers() async throws {
        let content = Data((0..<8192).map { UInt8($0 % 251) })
        let origin = try ProbeHTTPTestOrigin(data: content, response: { _, index in
            guard index == 0 else { return nil }
            return Data("HTTP/1.1 206 Partial Content\r\nContent-Length: 8192\r\nContent-Range: bytes 0-8191/8192\r\nConnection: close\r\n\r\n".utf8) + content.prefix(2048)
        })
        let source = url(origin)
        OriginRequestBudget.shared.setHostLimit(1, for: source)
        let reader = AVIOReader(url: source, sourceOpenPolicy: .init(firstByteTimeout: 1, sizeProbeTimeout: 1))
        defer { reader.markClosed(); reader.close(); origin.stop() }
        let received = ProbeTestBox(Data())
        let job = ProbeTestJob {
            try reader.open()
            var result = Data()
            var chunk = [UInt8](repeating: 0, count: 1024)
            while result.count < content.count {
                let count = chunk.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, size: 1024) }
                guard count > 0 else { break }
                result.append(contentsOf: chunk.prefix(Int(count)))
            }
            received.update { $0 = result }
        }
        try await job.outcome().get()
        #expect(received.value == content)
        #expect(reader.isSeekable)
        // URLSession may discard a short body before delivering any data callback. In that
        // case byte zero is the unread frontier; otherwise the delivered prefix is retained.
        #expect(origin.requests.count >= 2)
        let retries = origin.requests.dropFirst().compactMap { $0.range }
        #expect(!retries.isEmpty)
        #expect(retries.allSatisfy { $0.hasPrefix("bytes=0-") || $0.hasPrefix("bytes=2048-") })
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.peakInflight == 1)
    }
    @MainActor
    @Test("An exhausted opening budget stays a transport failure and is not repeated by routing")
    func exhaustedOpenDoesNotReprobe() async throws {
        let gate = ProbeTestGate()
        let origin = try ProbeHTTPTestOrigin(data: Data(repeating: 0, count: 8192),
            response: { _, _ in gate.wait(); return nil })
        let engine = try AetherEngine()
        defer { engine.stop(); gate.open(); origin.stop() }
        var options = LoadOptions(sourceOpenPolicy: .init(firstByteTimeout: 0.15, sizeProbeTimeout: 0.25))
        options.maxConcurrentSourceRequests = 1
        options.suppressDisplayCriteria = true
        do {
            try await engine.load(url: URL(string: "http://127.0.0.1:\(origin.port)/media.mkv")!, options: options)
            Issue.record("an unanswered source must not load successfully")
        } catch {
            #expect(error as? AVIOReaderError == .requestTimeout)
        }
        // The retry can still be on its way to the origin's parser when load() gives up, or never
        // reach it: the reader cancels it sizeProbeTimeout after resume, and a loaded machine may
        // not have put it on the wire by then. So its arrival gets a grace, not an unbounded wait,
        // and the verdict is the ceiling: routing must not add a third request.
        try await waitFor(upTo: .seconds(2)) { origin.requests.count >= 2 }
        #expect(origin.requests.count <= 2, "routing must not repeat the open")
        #expect(engine.errorInfo?.kind == .sourceOpenFailed)
        #expect(engine.errorInfo?.underlyingDomain == NSURLErrorDomain)
        #expect(!engine.canSeek)
        #expect(engine.errorInfo?.underlyingCode == URLError.timedOut.rawValue)
    }

}
