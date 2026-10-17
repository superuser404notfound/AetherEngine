import Testing
import Foundation
@testable import AetherEngine

/// #410, the reader half. The phase axis a host reads for "is my source down" was cleared by two things
/// that are not deliveries: the ladder's own exit (`.flowing` on the way out, so the reopen window read as
/// a healthy source) and every serve out of memory (draining read-ahead while the origin refuses every
/// refill). The ladders themselves have drawn that line since #380; the axis now draws it in the same
/// place, which is what makes the exit's honest `.exhausted` survive long enough to be read.
///
/// `.serialized`: these tests mutate the process-wide backoff-scale test hook.
@Suite("Source-stall visibility (#410)", .serialized, .offCooperativePool)
struct Issue410SourceStallVisibilityTests {

    /// The refusal these tests stage arms the request-rate pacer's wall-clock quiet ladder, which
    /// added 54 s to `bytes handed back out of memory do not clear the stall` and blocked a reader
    /// thread throughout. The subject here is stall visibility, so the ladder is pinned away.
    init() { OriginRequestBudget.shared.quietPeriodCapForTesting = 0 }

    private final class PhaseLog: @unchecked Sendable {
        private let lock = NSLock()
        private var phases: [ReaderNetworkPhase] = []
        func append(_ phase: ReaderNetworkPhase) {
            lock.lock(); phases.append(phase); lock.unlock()
        }
        var snapshot: [ReaderNetworkPhase] {
            lock.lock(); defer { lock.unlock() }
            return phases
        }
    }

    /// An origin that delivered a runway and then refuses every refill: the reader drains the runway,
    /// charges the ladder, gives up, and hands the read back. From the moment it first reports
    /// `.reconnecting`, nothing it does is a delivery, so the axis must not read `.flowing` again, and the
    /// give-up must say `.exhausted` rather than claim the source came back.
    @Test("a refusing origin stays visible across the runway and the give-up",
          .timeLimit(.minutes(2)))
    func refusedRefillHoldsTheStallThroughGiveUp() async throws {
        // 8 MB of runway so the low-water refill is refused while the window still has plenty to serve:
        // the reads after the refusal are exactly the memory serves that used to report delivery.
        let firstRange: Int64 = 8 * 1024 * 1024
        let serverMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in offset < firstRange ? .serve206 : .status(500) }
        )
        let server = try #require(serverMaybe)
        defer { server.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: firstRange,
                                backoffScale: 0.02)
        defer { reader.markClosed(); reader.close() }
        let phases = PhaseLog()
        reader.onNetworkPhaseChanged = { phases.append($0) }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        var result: Int32 = 0
        while true {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { result = n; break }
            got += Int(n)
        }

        #expect(got == Int(firstRange), "the delivered runway must still be served in full")
        #expect(result == -1, "a refused source must fail the read, not hang")

        #expect(phases.snapshot == [.flowing, .reconnecting, .exhausted],
                "the spent ladder must hand over `.exhausted`, not claim the source came back: \(phases.snapshot)")
    }

    /// The counterpart, so the rule cannot be satisfied by never reporting recovery: an origin that refuses
    /// once and then delivers must clear the axis off its own delivery.
    @Test("a transient refusal clears once the origin delivers again",
          .timeLimit(.minutes(2)))
    func transientRefusalClearsOnDelivery() async throws {
        let firstRange: Int64 = 1024 * 1024
        let refusals = OSAllocatedUnfairLockCounter()
        let serverMaybe = ThrottledOriginServer(
            totalSize: 8 * 1024 * 1024,
            respond: { _, offset, _ in
                guard offset >= firstRange else { return .serve206 }
                return refusals.bumpAndGet() <= 1 ? .status(500) : .serve206
            }
        )
        let server = try #require(serverMaybe)
        defer { server.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: firstRange,
                                backoffScale: 0.02)
        defer { reader.markClosed(); reader.close() }
        let phases = PhaseLog()
        reader.onNetworkPhaseChanged = { phases.append($0) }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        while got < 4 * 1024 * 1024 {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            got += Int(n)
        }

        #expect(got >= 4 * 1024 * 1024, "the retry after a single refusal must complete the read")
        let observed = phases.snapshot
        #expect(observed.last == .flowing,
                "the origin delivered again and the axis never said so: \(observed)")
    }

    /// The retained-span serve after the origin has gone: the parse returns to the head while every fetch
    /// past the delivered runway is refused. Those reads cross no network, and #380 already stopped them
    /// from clearing the reconnect ladders. The axis has to draw the same line, otherwise the stall a host
    /// reads is erased by read-ahead paid for before the origin died, and the `.exhausted` the give-up just
    /// published does not survive the next read.
    @Test("bytes handed back out of memory do not clear the stall",
          .timeLimit(.minutes(2)))
    func memoryServeDoesNotClearTheStall() async throws {
        let runway: Int64 = 8 * 1024 * 1024
        let serverMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in offset < runway ? .serve206 : .status(509) }
        )
        let server = try #require(serverMaybe)
        defer { server.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: runway,
                                backoffScale: 0.02)
        defer { reader.markClosed(); reader.close() }
        let phases = PhaseLog()
        reader.onNetworkPhaseChanged = { phases.append($0) }
        try reader.open()

        #expect(Self.readOnce(reader, at: 0, bytes: 64 * 1024) > 0)
        try await Self.awaitRangeDelivered(reader)

        // Past winLookback + winTrimBatch, so a later read at 0 reaches the retained head span rather
        // than the window it walked out of.
        let walked = Self.readForward(reader, bytes: 6 * 1024 * 1024 + 512 * 1024)
        #expect(walked == 6 * 1024 * 1024 + 512 * 1024, "need a trimmed window (read \(walked))")

        // A read past the runway: nothing resident can serve it, so it goes to the origin, which meters
        // every attempt until the ladder is spent.
        #expect(Self.readOnce(reader, at: 20 * 1024 * 1024, bytes: 32 * 1024) <= 0,
                "a refused region must fail the read")
        let spent = phases.snapshot
        #expect(spent.contains(.reconnecting), "the metered origin never surfaced as `.reconnecting`: \(spent)")
        #expect(spent.last == .exhausted, "the spent ladder must hand over `.exhausted`: \(spent)")

        // And now the parse returns to the retained head, repeatedly. Every one of these is a memcpy out
        // of bytes fetched before the origin died.
        let requestsBefore = server.requestLog.count
        for step in 0..<16 {
            #expect(Self.readOnce(reader, at: Int64(step) * 64 * 1024, bytes: 32 * 1024) > 0)
        }
        #expect(server.requestLog.count == requestsBefore,
                "the run must come out of the retained head: \(server.requestLog.suffix(4))")
        #expect(phases.snapshot == spent,
                "serving out of memory moved the network axis: \(phases.snapshot)")
    }

    // MARK: - Reader drivers (same shape as ServedFromMemoryProgressTests)

    private static func awaitRangeDelivered(_ reader: AVIOReader) async throws {
        try await waitFor { !reader.hasLiveConnectionForTesting }
    }

    @discardableResult
    private static func readOnce(_ reader: AVIOReader, at offset: Int64, bytes: Int) -> Int32 {
        #expect(reader.seek(offset: offset, whence: SEEK_SET) == offset)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
        defer { buf.deallocate() }
        return reader.read(into: buf, size: Int32(bytes))
    }

    private static func readForward(_ reader: AVIOReader, bytes: Int) -> Int {
        let slice = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: slice)
        defer { buf.deallocate() }
        var got = 0
        while got < bytes {
            let n = reader.read(into: buf, size: Int32(min(slice, bytes - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        return got
    }

    private static func chargeLadderFromWindow(_ reader: AVIOReader, near offset: Int64) -> Int {
        for step in 0..<200 {
            readOnce(reader, at: offset + Int64(step % 8) * 64 * 1024, bytes: 32 * 1024)
            if reader.rateLimitStreakForTesting >= 3 { return reader.rateLimitStreakForTesting }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return reader.rateLimitStreakForTesting
    }
}

/// Tiny counter for the response closure, which is `@Sendable` and called off the test thread.
final class OSAllocatedUnfairLockCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bumpAndGet() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}
