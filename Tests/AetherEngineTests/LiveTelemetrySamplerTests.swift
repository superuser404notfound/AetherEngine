import Foundation
import Testing
import AVFoundation
@testable import AetherEngine

/// #134: on the native path every 1 Hz tick used to make ~6 synchronous AVFoundation reads
/// (each a sync XPC round-trip to mediaserverd) on the main actor. A momentarily busy media
/// server turned the tick into a fully blocked main thread and, past the watchdog threshold,
/// a process kill. The reads now run as one coalesced batch on a dedicated background queue;
/// these tests pin the off-main behavior via an injected read in place of the AVFoundation batch.
@MainActor
struct LiveTelemetrySamplerTests {

    private func makeNativeEngine() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.playbackBackend = .native
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-134.mp4"))
        engine.currentAVPlayer = AVPlayer(playerItem: item)
        return engine
    }

    /// Generous default: on a loaded CI runner the main actor can be scheduled tens of seconds late
    /// (a CPU-heavy Vision OCR test running in parallel starved it past a 15 s bound), so a tight
    /// bound flakes even when the behavior under test is correct. It only needs to be a finite
    /// backstop, not a measurement: a genuine main-actor block never signals at any size.
    private func waitUntil(
        timeout: Duration = .seconds(90),
        _ condition: @MainActor () -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        while !condition() {
            if clock.now - start > timeout { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test("a stalled AVFoundation read must not block the main actor")
    func stalledReadKeepsMainActorResponsive() async throws {
        let engine = try makeNativeEngine()
        let release = DispatchSemaphore(value: 0)
        // If the read ran on the main actor (the #134 regression), the release signal below could
        // never be sent while the read blocks, the wait would exhaust its backstop timeout, and the
        // published forward buffer would be the 99 sentinel instead of 12. The timeout is generous
        // (a genuine main-actor block never signals at any size; only CI scheduling starvation from
        // a parallel CPU-heavy test needs absorbing, which can run tens of seconds).
        let sampler = LiveTelemetrySampler(engine: engine, nativeRead: { _, _ in
            let releasedInTime = release.wait(timeout: .now() + 90) == .success
            return NativeAVFReadings(forwardBufferSeconds: releasedInTime ? 12.0 : 99.0)
        })
        sampler.start()
        // Main-actor work that must proceed while the read is stalled.
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)) }
        release.signal()
        let published = try await waitUntil { engine.diagnostics.liveTelemetry != nil }
        #expect(published)
        #expect(engine.diagnostics.liveTelemetry?.forwardBufferSeconds == 12.0)
        sampler.stop()
    }

    @Test("injected readings populate the snapshot and feed the extractor yield gate")
    func readingsFeedSnapshotAndYieldGate() async throws {
        let engine = try makeNativeEngine()
        let sampler = LiveTelemetrySampler(engine: engine, nativeRead: { _, _ in
            NativeAVFReadings(
                droppedFrameCount: 7,
                networkThroughputMbps: 42.0,
                networkTransferredBytes: 1_234_567,
                forwardBufferSeconds: 12.0
            )
        })
        sampler.start()
        let published = try await waitUntil { engine.diagnostics.liveTelemetry != nil }
        #expect(published)
        let snapshot = engine.diagnostics.liveTelemetry
        #expect(snapshot?.droppedFrameCount == 7)
        #expect(snapshot?.networkThroughputMbps == 42.0)
        #expect(snapshot?.networkTransferredBytes == 1_234_567)
        #expect(snapshot?.forwardBufferSeconds == 12.0)
        #expect(engine.extractorYieldState.snapshot().consecutiveHealthyTicks >= 1)
        sampler.stop()
    }

    @Test("a player swap during a stalled read drops the in-flight snapshot")
    func playerSwapDuringStalledReadDropsSnapshot() async throws {
        let engine = try makeNativeEngine()
        let entered = AtomicBool(false)
        let release = DispatchSemaphore(value: 0)
        // Barrier, not a measurement: the read must stay in flight until the test performs the swap
        // below and signals. A finite wall-clock cap here (previously 30 s) races the outer 90 s
        // main-actor backstop: under CI starvation the read self-releases before the swap, publishes
        // a still-valid snapshot, and the drop assertion flakes. The defer guarantees release on any
        // early throw so an unsignalled wait can't park a read-queue thread.
        defer { release.signal() }
        let sampler = LiveTelemetrySampler(engine: engine, nativeRead: { _, _ in
            entered.set(true)
            release.wait()
            return NativeAVFReadings(forwardBufferSeconds: 12.0)
        })
        sampler.start()
        let readStarted = try await waitUntil { entered.get() }
        #expect(readStarted)
        // Reload seam: the engine swaps in a new player while the old item's read is in flight.
        engine.currentAVPlayer = AVPlayer(playerItem: AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-134b.mp4")))
        release.signal()
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.diagnostics.liveTelemetry == nil)
        #expect(engine.extractorYieldState.snapshot().consecutiveHealthyTicks == 0)
        sampler.stop()
    }

    @Test("stop() during a stalled read drops the in-flight snapshot")
    func stopDuringStalledReadDropsSnapshot() async throws {
        let engine = try makeNativeEngine()
        let entered = AtomicBool(false)
        let release = DispatchSemaphore(value: 0)
        // Barrier, not a measurement (see the swap test): the read must stay in flight until stop()
        // below and the signal. A finite cap races the outer 90 s backstop and flakes under CI
        // starvation; the defer releases on any early throw.
        defer { release.signal() }
        let sampler = LiveTelemetrySampler(engine: engine, nativeRead: { _, _ in
            entered.set(true)
            release.wait()
            return NativeAVFReadings(forwardBufferSeconds: 12.0)
        })
        sampler.start()
        let readStarted = try await waitUntil { entered.get() }
        #expect(readStarted)
        sampler.stop()
        release.signal()
        // The cancelled tick resumes after stop(); give it time to (incorrectly) publish.
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.diagnostics.liveTelemetry == nil)
    }

    @Test("default AVFoundation batch read completes off-main against an idle player")
    func defaultReadPublishesNilFieldsForIdlePlayer() async throws {
        let engine = try makeNativeEngine()
        let sampler = LiveTelemetrySampler(engine: engine)
        sampler.start()
        let published = try await waitUntil { engine.diagnostics.liveTelemetry != nil }
        #expect(published)
        // Idle player: no access log, no loaded ranges.
        #expect(engine.diagnostics.liveTelemetry?.droppedFrameCount == nil)
        #expect(engine.diagnostics.liveTelemetry?.forwardBufferSeconds == nil)
        sampler.stop()
    }
}
