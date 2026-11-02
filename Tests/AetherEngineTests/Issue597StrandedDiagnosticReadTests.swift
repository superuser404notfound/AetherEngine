import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// AE#597: the diagnostic reads are synchronous XPC round trips to mediaserverd, and the pool that
/// bounds them assumed every one of them comes back. When the media server stops answering, which
/// is the one state these reads exist to describe, a read never returns, its lane is never given
/// back, and the shared pool admits nothing again for the lifetime of the process.
///
/// The lane is the thing under test, not the read. A stranded read cannot be cancelled (the thread
/// is inside a platform getter), so the contract is that the POOL stops waiting for it.
private final class StrandedReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var reads = 0
    let blocks: Bool

    init(blocks: Bool) { self.blocks = blocks }

    var count: Int { lock.withLock { reads } }

    func read(_ item: AVPlayerItem, _ request: ItemDiagnosticRequest) -> ItemDiagnosticSnapshot {
        lock.withLock { reads += 1 }
        if blocks { release.wait() }
        return .init()
    }

    /// Let the stranded threads go at the end of the test so they do not outlive the suite.
    func drain() { for _ in 0..<8 { release.signal() } }
}

@MainActor
@Suite(.timeLimit(.minutes(3)))
struct Issue597StrandedDiagnosticReadTests {

    private func item() -> AVPlayerItem { AVPlayerItem(asset: AVMutableComposition()) }

    @Test("a read that never returns gives its lane back anyway")
    func strandedReadDoesNotHoldTheLane() async throws {
        let pool = ItemDiagnosticReadPool(readTimeout: 0.2)
        let stranded = StrandedReadProbe(blocks: true)
        defer { stranded.drain() }
        let answering = StrandedReadProbe(blocks: false)

        // Occupy every lane with a read the media server will never answer.
        var blockers: [AVPlayerItemDiagnostics] = []
        for _ in 0..<ItemDiagnosticReadPool.maximumConcurrentReads {
            let reader = AVPlayerItemDiagnostics(item: item(), pool: pool, read: stranded.read)
            reader.request(.counters)
            blockers.append(reader)
        }
        // Every lane has entered a read that will not come back. Deliberately not asserting the
        // pool's occupancy here: on a loaded runner the lanes' own budget can expire before the
        // assertion runs, which would pin the harness's timing rather than the contract. That the
        // reads started at all is the fact this arm needs, and the two below are the contract.
        try await waitFor {
            stranded.count == ItemDiagnosticReadPool.maximumConcurrentReads
        }

        // A later reader, queued behind them, must still be served once the lanes time out.
        let later = AVPlayerItemDiagnostics(item: item(), pool: pool, read: answering.read)
        later.request(.counters)

        try await waitFor { answering.count == 1 }
        #expect(answering.count == 1, "the pool never admitted a read after the stranded ones")

        try await waitFor { pool.runningCount == 0 }
        #expect(pool.runningCount == 0, "lanes were still held after every read had settled")
        _ = blockers
    }

    /// The reader half of the same contract: a reader whose read was abandoned is not left marked
    /// as busy, or it can never ask again for the rest of the session.
    @Test("an abandoned reader can ask again")
    func abandonedReaderIsNotLeftInFlight() async throws {
        let pool = ItemDiagnosticReadPool(readTimeout: 0.2)
        let stranded = StrandedReadProbe(blocks: true)
        defer { stranded.drain() }

        let reader = AVPlayerItemDiagnostics(item: item(), pool: pool, read: stranded.read)
        reader.request(.counters)
        try await waitFor { stranded.count == 1 }

        // Deliberately not asserting that it is in flight first: under a loaded runner the lane's
        // own budget can expire before the assertion runs, and that would pin the harness rather
        // than the contract. What is being pinned is that it does not STAY in flight.
        try await waitFor { !reader.inFlight }
        #expect(!reader.inFlight, "the reader stayed in flight behind a read nobody will answer")

        reader.request(.counters)
        try await waitFor { stranded.count == 2 }
        #expect(stranded.count == 2, "a second request never reached the read")
    }
}
