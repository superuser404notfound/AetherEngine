import Testing
import Foundation
@testable import AetherEngine

/// #309: a transport that dies silently while the window can still serve reads.
///
/// Two separate defects, and only the first one is in the report:
/// - Detection. `connStallTimeout` was evaluated in exactly one place, inside the read loop's
///   forward wait, so nothing noticed a dead flow while reads were satisfied from the window.
///   The persistent request also sets `timeoutInterval = 0`, so the transport is not expected to
///   notice either: the reader is the only detector there is, and it only ticked when a consumer
///   happened to block.
/// - Recovery. The frontier refill fired only for PLANNED ends (a delivered range, a high-water
///   end). An error-ended generation was replaced only once the window had drained to EMPTY, so
///   the reader spent 16 MB of read-ahead before asking for a replacement, and playback rejoined
///   the clock with a burst (the field report's +17 MB interval and 389 dropped frames). Detecting
///   the death instantly would not have changed that by itself.
///
/// The origin serves a range, stops writing mid-body, and keeps the socket open with no FIN, which
/// is the reader-observable shape of the field case (URLSession surfaced nothing until the task was
/// later cancelled).
///
/// `.serialized`: one case mutates the process-wide backoff-scale hook, and keeping the four off each
/// other's timing is worth more than running them concurrently. The stall threshold and the consumer
/// pace are deliberately NOT process-wide hooks: swift-testing runs suites in parallel, and a hook
/// that every reader reads at init would reach into whatever suite happens to run alongside this one.
@Suite("Silent transport death (#309)", .serialized, .offCooperativePool)
struct Issue309SilentTransportDeathTests {

    private static let totalSize: Int64 = 256 * 1024 * 1024
    /// The first data range. Its completion is what puts the refill at `silenceOffset`, and it
    /// keeps the silent generation off offset 0, where the speculative tail fetch and the open's
    /// own from-zero request live.
    private static let firstRange: Int64 = 2 * 1024 * 1024
    private static var silenceOffset: Int64 { firstRange }

    /// Snapshot taken from the ORIGIN's thread at the moment it receives a given request, which is
    /// the only way to observe how much read-ahead the reader still held when it asked for the
    /// replacement. A loopback origin answers in microseconds, so timing cannot express this.
    private final class RunwayProbe: @unchecked Sendable {
        private let lock = NSLock()
        private weak var reader: AVIOReader?
        private var recorded: Int?
        func attach(_ reader: AVIOReader) {
            lock.lock(); self.reader = reader; lock.unlock()
        }
        func recordRunway() {
            lock.lock()
            let reader = self.reader
            let alreadyRecorded = recorded != nil
            lock.unlock()
            guard !alreadyRecorded, let reader else { return }
            let ahead = reader.windowDiagnostics.aheadBytes
            lock.lock()
            if recorded == nil { recorded = ahead }
            lock.unlock()
        }
        var runwayAtRequest: Int? {
            lock.lock(); defer { lock.unlock() }
            return recorded
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

    /// `bytesPerSecond` paces the CONSUMER inside this loop rather than through
    /// `AetherEngine.sourceThrottleKbpsForTesting`. That hook is read at every reader's init, so
    /// setting it would throttle the readers of every suite swift-testing happens to run in parallel
    /// with this one. Pacing here is local by construction.
    private static func read(_ reader: AVIOReader, bytes target: Int, sliceCap: Int = 256 * 1024,
                            deadline: TimeInterval = 120, bytesPerSecond: Int = 0) -> Int {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        let stopAt = Date().addingTimeInterval(deadline)
        while got < target && Date() < stopAt {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
            if bytesPerSecond > 0 {
                Thread.sleep(forTimeInterval: Double(n) / Double(bytesPerSecond))
            }
        }
        return got
    }

    // MARK: - The open keeps its own budget

    /// The watchdog's threshold is a verdict on a transfer that stopped, and the first byte of the
    /// open is not that: `SourceOpenPolicy.firstByteTimeout` is the budget for it, and a host sets it
    /// for an origin that is known to be slow to answer (a NAS spinning up). Ended at the stall
    /// threshold instead, both open attempts were cut at it and the open failed with `noResponse`:
    /// measured with this origin, 0.4 s opened and 0.8 s failed in 1.3 s, every time. That is also
    /// the shape #309's own detection test failed in on a loaded CI runner, where a first byte took
    /// longer than its 0.6 s threshold.
    @Test("an open whose first byte is slower than the stall threshold still opens",
          .timeLimit(.minutes(3)))
    func slowFirstByteOpens() throws {
        let serverMaybe = ThrottledOriginServer(totalSize: Self.totalSize, firstByteDelayUs: { _ in 1_500_000 })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: Self.firstRange,
                                connStallTimeout: 0.3)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        #expect(Self.read(reader, bytes: 64 * 1024) == 64 * 1024)
    }

    // MARK: - Detection

    @Test("a flow that dies mid-window is ended without any read blocking on it",
          .timeLimit(.minutes(2)))
    func deadFlowIsEndedWithoutAWaitingRead() async throws {
        let stallTimeout: TimeInterval = 0.6
        let silenceOffset = Self.silenceOffset
        // Built into a local first: `#require` wraps its expression in a @Sendable closure, which a
        // capturing origin closure cannot cross.
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize,
            respond: { _, offset, _ in
                offset == silenceOffset ? .serveThenGoSilent(afterBytes: 4 * 1024 * 1024) : .serve206
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: Self.firstRange,
                                connStallTimeout: stallTimeout)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // The refill is issued BY a read, and only once the first range is no longer installed, so
        // wait for that range to complete before consuming. Then consume enough to put the refill on
        // the wire and far less than the 4 MB it delivers: from here on every read is satisfied from
        // the window, which is precisely the state that used to defer detection indefinitely.
        try await waitFor { !reader.hasLiveConnectionForTesting }
        #expect(Self.read(reader, bytes: 1024 * 1024) == 1024 * 1024)
        try await waitFor { server.requestedRanges.contains { $0.start == silenceOffset } }
        #expect(server.requestedRanges.contains { $0.start == silenceOffset },
                "the frontier refill never went out: \(server.requestedRanges)")

        // No reads at all from here: the consumer is parked, exactly as a paused player is.
        try await waitFor { !reader.hasLiveConnectionForTesting }

        #expect(!reader.hasLiveConnectionForTesting,
                "a connection that delivered nothing for \(stallTimeout)s is still installed")
        let diag = reader.windowDiagnostics
        #expect(!diag.parked,
                "window at \(diag.aheadBytes / (1024 * 1024)) MB: not a high-water end, so it must be recorded as a fault")
        // The watchdog ENDS, it never reconnects: a parked consumer must not turn a dead flow into
        // a reconnect loop, which is the failure mode #307 paid for.
        #expect(server.requestedRanges.filter { $0.start == silenceOffset }.count == 1,
                "the dead flow was re-requested while nothing drained: \(server.requestedRanges)")
    }

    @Test("a generation that never sees a first byte is ended too", .timeLimit(.minutes(2)))
    func headersWithoutABodyAreEnded() async throws {
        let stallTimeout: TimeInterval = 0.6

        let silenceOffset = Self.silenceOffset
        let attempts = AttemptCounter()
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize,
            respond: { _, offset, _ in
                offset == silenceOffset && attempts.next(for: offset) == 1
                    ? .serveThenGoSilent(afterBytes: 0) : .serve206
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: Self.firstRange,
                                connStallTimeout: stallTimeout, backoffScale: 0.02)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        try await waitFor { !reader.hasLiveConnectionForTesting }
        #expect(Self.read(reader, bytes: 512 * 1024) == 512 * 1024)
        try await waitFor { server.requestedRanges.contains { $0.start == silenceOffset } }
        try await waitFor { !reader.hasLiveConnectionForTesting }

        #expect(!reader.hasLiveConnectionForTesting,
                "a request answered with headers and no body stayed installed")
        #expect(server.requestedRanges.filter { $0.start == silenceOffset }.count == 1,
                "the ended generation was re-requested with nothing draining")

        // Liveness: the retry (served normally) must carry the read past the first range.
        let past = Self.read(reader, bytes: 4 * 1024 * 1024)
        #expect(past == 4 * 1024 * 1024, "only \(past) B delivered after the empty response")
    }

    // MARK: - Recovery

    @Test("the replacement is requested while read-ahead remains, not once it is spent",
          .timeLimit(.minutes(3)))
    func runwayIsRefilledBeforeItDrains() async throws {
        let stallTimeout: TimeInterval = 0.5
        // A consumer at ~2 MB/s, so the 6 MB resident at the moment of death is worth seconds of
        // playback rather than the microseconds a loopback memcpy would take. Without a paced
        // consumer this test would measure the harness, not the reader.
        let consumerBytesPerSecond = 2 * 1024 * 1024

        let silenceOffset = Self.silenceOffset
        let silentBytes: Int64 = 4 * 1024 * 1024
        let frontierAfterSilence = silenceOffset + silentBytes
        let probe = RunwayProbe()
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize,
            respond: { _, offset, _ in
                if offset == frontierAfterSilence { probe.recordRunway() }
                return offset == silenceOffset ? .serveThenGoSilent(afterBytes: silentBytes) : .serve206
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: Self.firstRange,
                                connStallTimeout: stallTimeout)
        defer { reader.markClosed(); reader.close() }
        probe.attach(reader)
        try reader.open()

        // Read straight through the death. 7 MB is past everything the silenced generation and the
        // first range delivered (6 MB), so completing it can only happen through a replacement.
        let target = 7 * 1024 * 1024
        let got = Self.read(reader, bytes: target, bytesPerSecond: consumerBytesPerSecond)
        #expect(got == target, "read stopped at \(got / 1024) KB of \(target / 1024) KB")

        let runway = try #require(probe.runwayAtRequest,
                                  "the frontier after the silence was never requested: \(server.requestedRanges)")
        #expect(runway >= 2 * 1024 * 1024,
                "the replacement was asked for with only \(runway / 1024) KB of read-ahead left: the runway was spent before recovering")
    }

    // MARK: - Regression

    @Test("a backpressure-parked reader is not treated as a dead flow", .timeLimit(.minutes(2)))
    func parkedIsNotStalled() async throws {
        let stallTimeout: TimeInterval = 0.5

        let server = try #require(ThrottledOriginServer(totalSize: Self.totalSize))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                connStallTimeout: stallTimeout)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Nobody consumes: the window fills to high water, the connection is ended on purpose, and
        // from then on there is no delivery at all. That is the state the watchdog must NOT read as
        // a fault, or every paused player would reconnect on a timer.
        try await waitFor { reader.windowDiagnostics.parked }
        try await Task.sleep(for: .seconds(stallTimeout * 4))

        #expect(reader.windowDiagnostics.parked, "the high-water end must still own this state")
        #expect(reader.unproductiveReconnectsForTesting == 0,
                "a parked reader was charged \(reader.unproductiveReconnectsForTesting) failures")
        #expect(server.requestedRanges.filter { $0.start == 0 }.count == 1,
                "the watchdog re-requested a deliberately ended connection: \(server.requestedRanges)")

        // And it still refills when the consumer comes back.
        let got = Self.read(reader, bytes: 24 * 1024 * 1024)
        #expect(got == 24 * 1024 * 1024, "only \(got / (1024 * 1024)) MB after the park")
        #expect(reader.unproductiveReconnectsForTesting == 0)
    }
}
