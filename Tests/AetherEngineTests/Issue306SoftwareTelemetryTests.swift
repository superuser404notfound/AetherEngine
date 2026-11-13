import Foundation
import Testing
import AVFoundation
@testable import AetherEngine

/// #306: a software session publishes network telemetry of its own.
///
/// Two separate defects hid behind one symptom. The byte counter the sampler derives every
/// byte-shaped figure from was read through `nativeVideoSession`, which a software session does not
/// have, so bitrate, throughput and transferred bytes were a hard zero for the whole session rather
/// than the real numbers. And the read-ahead the path does hold was computed for the memprobe only,
/// so nothing on the public surface answered "is the network keeping up" where it matters most.
@Suite(.timeLimit(.minutes(3)))
@MainActor
struct Issue306SoftwareTelemetryTests {

    private func makeSoftwareEngine() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.playbackBackend = .software
        return engine
    }


    // MARK: - The byte counter

    /// The precedence, stated directly: only one of the two readers exists per session, and the
    /// software one is the half that used to be dropped on the floor.
    @Test("the pump byte counter prefers the software reader over the native one")
    func pumpBytesPrefersSoftwareReader() {
        #expect(AetherEngine.pumpBytesFetched(software: 4_096, native: nil) == 4_096)
        #expect(AetherEngine.pumpBytesFetched(software: nil, native: 8_192) == 8_192)
        #expect(AetherEngine.pumpBytesFetched(software: nil, native: nil) == 0)
        // A software session that has read nothing yet is still the authority: falling back to the
        // native side here would publish a stale counter from a previous native session.
        #expect(AetherEngine.pumpBytesFetched(software: 0, native: 8_192) == 0)
    }

    // MARK: - The rate the link delivers at

    /// Retest finding: the Network section only read sensibly on a struggling session. The reader
    /// fetches a large range and parks on backpressure until low water, so on a fast link the window is
    /// mostly empty. Measured over a local origin, a healthy 2.8 Mbps VP9 session pulled 16.4 MB in one
    /// tick and then exactly nothing for 23 more, so a wall-clock mean published 0.00 Mbps while the
    /// stream played perfectly, one field over from the zero #306 was filed about.
    @Test("a parked reader reports the rate it delivered at, not a wall-clock mean over the park")
    func burstyLinkReportsItsDeliveredRate() {
        // The measured shape: 16.4 MB in one tick of a ten-second window, then silence.
        let burst = LiveTelemetrySampler.observedTransferMbps(
            windowBytes: 17_196_646, activeSeconds: 1, samples: 10)
        #expect(burst != nil)
        #expect((burst ?? 0) > 100.0, "a loopback burst reports its own rate, got \(burst ?? -1) Mbps")

        // The same bytes charged to every second of the window is the reading that used to ship, and
        // it is the one a host renders as a near-dead link.
        let wallClockMean = Double(17_196_646) * 8.0 / 10.0 / 1_000_000.0
        #expect((burst ?? 0) > wallClockMean)
    }

    /// A paced origin fills every tick, so both readings coincide there. This is the arm that must not
    /// move: the reporter's throttled run is the one the section was already legible on.
    @Test("a steadily paced link reads the same either way")
    func pacedLinkIsUnchanged() {
        // 2 Mbps for ten seconds: 250 000 bytes in each of ten ticks.
        let rate = LiveTelemetrySampler.observedTransferMbps(
            windowBytes: 2_500_000, activeSeconds: 10, samples: 10)
        #expect(abs((rate ?? 0) - 2.0) < 0.001)
    }

    /// Nothing arrived in the whole window: that is a gap, not a rate of zero. A host cannot tell a
    /// confident 0.0 Mbps from a dead link, and the reporter's overlay renders any non-nil number.
    @Test("an idle window publishes nil rather than zero")
    func idleWindowPublishesNil() {
        #expect(LiveTelemetrySampler.observedTransferMbps(
            windowBytes: 0, activeSeconds: 0, samples: 10) == nil)
        // And a single sample spans no time at all, whatever it carries.
        #expect(LiveTelemetrySampler.observedTransferMbps(
            windowBytes: 4_096, activeSeconds: 1, samples: 1) == nil)
    }

    /// The window counts the slots that carried bytes, not the slots that exist.
    @Test("the rolling window separates the seconds that carried bytes")
    func rollingWindowCountsActiveSlots() {
        var window = RollingWindow<Int64>(capacity: 10, zero: 0)
        window.push(17_196_646)
        for _ in 0..<9 { window.push(0) }
        #expect(window.count == 10)
        #expect(window.activeCount == 1)
        #expect(window.sum == 17_196_646)
    }

    // MARK: - The software snapshot

    @Test("a software tick publishes cushion, reader runway and dropped frames")
    func softwareTickPublishesReadAhead() async throws {
        let engine = try makeSoftwareEngine()
        let sampler = LiveTelemetrySampler(engine: engine, softwareRead: { _ in
            SoftwareReadings(
                displayCushionSeconds: 0.36,
                readerWindowAheadBytes: 3_145_728,
                droppedFrameCount: 8,
                accumulatedFrameDelaySeconds: 0.21)
        })
        sampler.start()
        try await waitFor { engine.diagnostics.liveTelemetry != nil }
        let snapshot = engine.diagnostics.liveTelemetry
        #expect(snapshot?.displayCushionSeconds == 0.36)
        #expect(snapshot?.readerWindowAheadBytes == 3_145_728)
        #expect(snapshot?.droppedFrameCount == 8)
        #expect(snapshot?.accumulatedFrameDelaySeconds == 0.21)
        sampler.stop()
    }

    /// The cushion is a fraction of a second on a perfectly healthy session, so publishing it as the
    /// forward buffer would report a near-stall with confidence. It stays nil, and the two fields that
    /// carry the software path's runway say what they are.
    @Test("the forward buffer stays nil on the software path")
    func forwardBufferStaysNilOnSoftware() async throws {
        let engine = try makeSoftwareEngine()
        let sampler = LiveTelemetrySampler(engine: engine, softwareRead: { _ in
            SoftwareReadings(displayCushionSeconds: 0.02)
        })
        sampler.start()
        try await waitFor { engine.diagnostics.liveTelemetry != nil }
        #expect(engine.diagnostics.liveTelemetry?.forwardBufferSeconds == nil)
        #expect(engine.diagnostics.liveTelemetry?.displayCushionSeconds == 0.02)
        sampler.stop()
    }

    /// An OS without `videoPerformanceMetrics`, or a session before the first frame: the fields read
    /// nil rather than zero. Zero is a measurement, nil is "not asked yet", and a host watchdog that
    /// cannot tell them apart reads a cold start as a perfect one.
    @Test("an unavailable metrics read publishes nil, not zero")
    func unavailableMetricsPublishNil() async throws {
        let engine = try makeSoftwareEngine()
        let sampler = LiveTelemetrySampler(engine: engine, softwareRead: { _ in SoftwareReadings() })
        sampler.start()
        try await waitFor { engine.diagnostics.liveTelemetry != nil }
        #expect(engine.diagnostics.liveTelemetry?.droppedFrameCount == nil)
        #expect(engine.diagnostics.liveTelemetry?.displayCushionSeconds == nil)
        #expect(engine.diagnostics.liveTelemetry?.accumulatedFrameDelaySeconds == nil)
        sampler.stop()
    }

    /// The metrics read is async, so a session can end under it. The native branch drops a snapshot
    /// whose player was swapped mid-read; the software branch owes the same guarantee.
    @Test("a backend change during the software read drops the snapshot")
    func backendChangeDuringReadDropsSnapshot() async throws {
        let engine = try makeSoftwareEngine()
        let entered = AtomicBool(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let sampler = LiveTelemetrySampler(engine: engine, softwareRead: { _ in
            entered.set(true)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread {
                    release.wait()
                    continuation.resume()
                }
            }
            return SoftwareReadings(displayCushionSeconds: 0.36)
        })
        sampler.start()
        try await waitFor { entered.get() }
        // Teardown seam: the session ends while the metrics read is still in flight.
        engine.playbackBackend = .none
        release.signal()
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.diagnostics.liveTelemetry == nil)
        sampler.stop()
    }

    /// The software fields are not a second name for values the native path already publishes: a
    /// native tick leaves them nil whatever the software read would have returned.
    @Test("a native tick leaves the software fields nil")
    func nativeTickLeavesSoftwareFieldsNil() async throws {
        let engine = try AetherEngine()
        engine.playbackBackend = .native
        engine.currentAVPlayer = AVPlayer(
            playerItem: AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent-306.mp4")))
        let sampler = LiveTelemetrySampler(
            engine: engine,
            nativeRead: { _, _ in NativeAVFReadings(forwardBufferSeconds: 12.0) },
            softwareRead: { _ in SoftwareReadings(displayCushionSeconds: 0.36, droppedFrameCount: 8) })
        sampler.start()
        try await waitFor { engine.diagnostics.liveTelemetry != nil }
        #expect(engine.diagnostics.liveTelemetry?.forwardBufferSeconds == 12.0)
        #expect(engine.diagnostics.liveTelemetry?.displayCushionSeconds == nil)
        #expect(engine.diagnostics.liveTelemetry?.accumulatedFrameDelaySeconds == nil)
        sampler.stop()
    }
}
