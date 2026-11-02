import Testing
import Foundation
@testable import AetherEngine

/// A forward request a few segments past the producer's march
/// front waited for the march (7.50.0: anything within `forwardWaitWindow` = 8). On a link near the
/// media bitrate the march advances about one segment per segment duration, so a +30 s seek waited
/// 23.6 s while a restart at the target resumed in 4.3 to 4.9 s on the same session (Apple TV 4K,
/// 74 Mbps link, 71.5 Mbps remux, ~4.1 s segments). The provider now waits only while the measured
/// march reaches the target sooner than a restart would.
@Suite(.offCooperativePool)
struct ForwardWaitMarchRateTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var fired: [Int] = []
        func record(_ idx: Int) { lock.lock(); fired.append(idx); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return fired }
    }

    /// Seconds per segment of the measured slow-link march (0.27 segments per second).
    private static let slowSegmentSeconds = 3.7

    private func segments(_ n: Int) -> [HLSVideoEngine.Segment] {
        (0..<n).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
    }

    private func makeCache(forwardWindow: Int = 60) -> SegmentCache {
        SegmentCache(forwardWindow: forwardWindow, backwardWindow: 60, retentionBudgetBytes: 512 * 1024 * 1024)
    }

    /// The producer parks on backpressure the way the pump does (a target it may not write past yet).
    private func parkProducer(_ cache: SegmentCache) {
        _ = cache.awaitFetchHighWater(reaching: Int.max, timeout: 0.01)
    }

    private func makeProvider(cache: SegmentCache, recorder: Recorder, marchRate: Bool = true,
                              producerBase: Int, initialRestartIndex: Int,
                              backpressureWait: TimeInterval = 0.3,
                              settle: TimeInterval = 0.2,
                              burstWindow: TimeInterval = 1.5) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: cache, segments: segments(200), codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (3840, 2160), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 60_000_000,
            restartHandler: { [weak cache] idx in
                recorder.record(idx)
                cache?.store(index: idx, data: Data(repeating: 0x41, count: 8))
            },
            restartActivity: { false },
            activeProducerBase: { producerBase },
            decidesForwardWaitByMarchRate: marchRate,
            marchRateSettleSeconds: settle,
            marchRateBurstWindowSeconds: burstWindow,
            initialRestartIndex: initialRestartIndex,
            repositionWaitSlice: 0.05,
            repositionRideCapSeconds: 5.0,
            forwardBackpressureWaitSeconds: backpressureWait
        )
    }

    /// Feeds `indices` to the march tracker as completions `slowSegmentSeconds` apart, the last one
    /// `endingAgo` seconds before now.
    private func recordSlowMarch(_ provider: VideoSegmentProvider, _ indices: ClosedRange<Int>,
                                 endingAgo: Double = 0) {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9 - endingAgo
        for (k, i) in indices.enumerated() {
            let age = Double(indices.count - 1 - k) * Self.slowSegmentSeconds
            provider.recordMarchStore(index: i, bytes: 34_500_000, time: now - age)
        }
    }

    /// A fast link with the default forward window of 10: the producer fills the window at 4 segments
    /// per second (11...20, no park), then writes one segment per 4 s of playback, each after a park
    /// (21...30). The last completion is `endingAgo` seconds before now.
    private func recordFastLinkPacedByPlayback(_ provider: VideoSegmentProvider, endingAgo: Double = 0) {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9 - endingAgo
        let pacedStart = now - 9 * 4.0
        for (k, i) in (11...20).enumerated() {
            provider.recordMarchStore(index: i, bytes: 10_000_000, time: pacedStart - 4.0 - Double(9 - k) * 0.25)
        }
        for (k, i) in (21...30).enumerated() {
            provider.recordMarchStore(index: i, bytes: 10_000_000, parkedBefore: true, time: pacedStart + Double(k) * 4.0)
        }
    }

    private func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }

    // MARK: - Provider decisions

    @Test("a jump six segments past a slow march restarts at the target at once")
    func slowMarchJumpRestarts() {
        let cache = makeCache()
        defer { cache.close() }
        for i in 0...25 { cache.store(index: i, data: Data(repeating: 0xA1, count: 8)) }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, producerBase: 0, initialRestartIndex: 0,
                                    backpressureWait: 30.0)
        recordSlowMarch(provider, 18...25)
        _ = provider.mediaSegment(at: 25)  // the playhead's request before the seek

        let start = DispatchTime.now()
        let served = provider.mediaSegment(at: 31)

        #expect(served != nil)
        #expect(recorder.all == [31])
        #expect(seconds(since: start) < 10.0)  // not the 30 s forward wait
    }

    /// The loopback server asks the file fast path first, and that declares the target before
    /// `serveSource` runs. Read in `serveSource`, the previous target was the request itself and every jump kept the wait.
    @Test("a jump requested the way the loopback server asks (file path first) still restarts")
    func jumpThroughServerOrderRestarts() {
        let cache = makeCache()
        defer { cache.close() }
        for i in 0...25 { cache.store(index: i, data: Data(repeating: 0xAA, count: 8)) }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, producerBase: 0, initialRestartIndex: 0,
                                    backpressureWait: 30.0)
        recordSlowMarch(provider, 18...25)
        _ = provider.mediaSegmentURL(at: 25)

        #expect(provider.mediaSegmentURL(at: 31) == nil)  // not produced: the server falls through
        let start = DispatchTime.now()
        let served = provider.mediaSegmentSource(at: 31, onSlow: nil)

        #expect(served != nil)
        #expect(recorder.all == [31])
        #expect(seconds(since: start) < 10.0)
    }

    @Test("the same jump with the fixed window alone (7.50.0) still waits for the march")
    func stockPolicyStillWaits() {
        let cache = makeCache()
        defer { cache.close() }
        for i in 0...25 { cache.store(index: i, data: Data(repeating: 0xA2, count: 8)) }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, marchRate: false,
                                    producerBase: 0, initialRestartIndex: 0)
        recordSlowMarch(provider, 18...25)
        _ = provider.mediaSegment(at: 25)

        _ = provider.mediaSegment(at: 31)

        #expect(recorder.all.isEmpty)
    }

    /// Two +30 s presses on the slow link. The second lands while
    /// the producer restarted for the first has written one segment, so its own run has no rate yet,
    /// and the target is inside the base's 8-segment cover that vetoes a restart in 7.50.0.
    @Test("a second jump right after a restart uses the previous producer's rate and is not vetoed")
    func secondJumpUsesPreviousRate() {
        let cache = makeCache()
        defer { cache.close() }
        for i in 0...20 { cache.store(index: i, data: Data(repeating: 0xA3, count: 8)) }
        cache.resetHighWaterForRestart()  // provider-fired restart at 24
        cache.store(index: 24, data: Data(repeating: 0xA4, count: 8))
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, producerBase: 24, initialRestartIndex: 24,
                                    backpressureWait: 30.0)
        recordSlowMarch(provider, 13...20)
        provider.recordMarchStore(index: 24, bytes: 34_500_000)
        _ = provider.mediaSegment(at: 24)

        let start = DispatchTime.now()
        let served = provider.mediaSegment(at: 31)

        #expect(served != nil)
        #expect(recorder.all == [31])
        #expect(seconds(since: start) < 10.0)
    }

    @Test("a jump onto the segment the slow march is writing waits for it")
    func jumpOntoWritingSegmentWaits() {
        let cache = makeCache()
        defer { cache.close() }
        for i in 0...25 { cache.store(index: i, data: Data(repeating: 0xA5, count: 8)) }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, producerBase: 0, initialRestartIndex: 0, backpressureWait: 60.0)
        recordSlowMarch(provider, 18...25)
        _ = provider.mediaSegment(at: 22)
        // Kernel-scheduled thread, as in Issue141FarForwardSeekTests: the march delivers seg26.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.05)
            cache.store(index: 26, data: Data(repeating: 0xA6, count: 8))
        }

        let served = provider.mediaSegment(at: 26)

        #expect(served != nil)
        #expect(recorder.all.isEmpty)
    }

    /// The jump guard (anything past the next segment) must not touch steady playback. AVPlayer asks
    /// for each segment after the one before it (device logs), and re-asks the same
    /// one after a timeout. Neither is a jump, so a slow march is waited for, never restarted.
    @Test("steady playback on a slow march never restarts")
    func steadyPlaybackNeverRestarts() {
        let cache = makeCache()
        defer { cache.close() }
        for i in 0...25 { cache.store(index: i, data: Data(repeating: 0xA7, count: 8)) }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, producerBase: 0, initialRestartIndex: 0, backpressureWait: 60.0)
        recordSlowMarch(provider, 18...25)
        _ = provider.mediaSegment(at: 25)
        // The march writes 26...33 behind the requests, as on a link at the media bitrate.
        Thread.detachNewThread {
            for i in 26...33 {
                Thread.sleep(forTimeInterval: 0.03)
                cache.store(index: i, data: Data(repeating: 0xA8, count: 8))
            }
        }

        var served = 0
        for i in 26...33 {
            // The loopback server's order: the file path first, the waiting path when it is not there.
            let delivered = provider.mediaSegmentURL(at: i) != nil
                || provider.mediaSegmentSource(at: i, onSlow: nil) != nil
            if delivered { served += 1 }
            _ = provider.mediaSegment(at: i)  // AVPlayer's re-request of the same segment
        }

        #expect(served == 8)
        #expect(recorder.all.isEmpty)
    }

    /// A remote burst on device: the restart at seg65 had sealed nothing yet, so the highest sealed
    /// segment was seg60 from the producer before. seg70 fell in `index > r.1 + 8`, which never asked
    /// the march rate, and the veto (base 65, 70 - 65 within 8) kept the restart from firing: 20.5 s on the march.
    @Test("right after a restart, a jump inside the new producer's window restarts")
    func jumpAfterUnsealedRestartRestarts() {
        let cache = makeCache()
        defer { cache.close() }
        for i in 0...60 { cache.store(index: i, data: Data(repeating: 0xAB, count: 8)) }
        cache.resetHighWaterForRestart()  // provider-fired restart at 65, nothing sealed from it yet
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, producerBase: 65, initialRestartIndex: 65,
                                    backpressureWait: 30.0)
        recordSlowMarch(provider, 53...60)
        _ = provider.mediaSegmentURL(at: 67)

        #expect(provider.mediaSegmentURL(at: 70) == nil)
        let start = DispatchTime.now()
        let served = provider.mediaSegmentSource(at: 70, onSlow: nil)

        #expect(served != nil)
        #expect(recorder.all == [70])
        #expect(seconds(since: start) < 10.0)
    }

    @Test("the same request with the fixed window alone (7.50.0) is vetoed and rides the march")
    func jumpAfterUnsealedRestartStockIsVetoed() {
        let cache = makeCache()
        defer { cache.close() }
        for i in 0...60 { cache.store(index: i, data: Data(repeating: 0xAC, count: 8)) }
        cache.resetHighWaterForRestart()
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, marchRate: false,
                                    producerBase: 65, initialRestartIndex: 65)
        _ = provider.mediaSegmentURL(at: 67)

        _ = provider.mediaSegmentSource(at: 70, onSlow: nil)

        #expect(recorder.all.isEmpty)
    }

    /// the first press of a burst is a lone jump and restarts at
    /// once; every later press within the burst window settles, and only the last one restarts. The
    /// requests are the device burst's (62, 65, 67, 70, 72). Each press is sent once the one before
    /// has declared its target, never on a timer: two presses that swapped under a full parallel run made
    /// the earlier index a backward jump, which restarts on its own.
    @Test("a burst restarts for its first press and then only for the last target",
          .timeLimit(.minutes(2)))
    func burstRestartsOnlyForTheLastTarget() async throws {
        let cache = makeCache()
        defer { cache.close() }
        for i in 0...60 { cache.store(index: i, data: Data(repeating: 0xAD, count: 8)) }
        let recorder = Recorder()
        // The settle and the burst window outlast the whole burst, so every later press is still settling
        // when the next arrives, and a press delayed by a loaded runner still counts as part of the burst.
        // A 2 s settle ran out between two presses on CI (65 restarted); the presses settle in parallel,
        // so the longer settle costs the run about one settle.
        let provider = makeProvider(cache: cache, recorder: recorder, producerBase: 0, initialRestartIndex: 0,
                                    settle: 10.0, burstWindow: 60.0)
        recordSlowMarch(provider, 53...60)
        _ = provider.mediaSegment(at: 60)

        let finished = Recorder()
        func press(_ index: Int) {
            Thread.detachNewThread {
                if provider.mediaSegmentURL(at: index) == nil {
                    _ = provider.mediaSegmentSource(at: index, onSlow: nil)
                }
                finished.record(index)
            }
        }
        press(62)
        try await waitFor { finished.all.contains(62) }  // the lone first press has restarted
        for index in [65, 67, 70, 72] {
            press(index)
            try await waitFor { cache.targetIndex == index }
        }
        try await waitFor { finished.all.count == 5 }

        #expect(recorder.all == [62, 72])
    }

    @Test("a lone jump restarts at once, without the settle")
    func loneJumpDoesNotSettle() {
        let cache = makeCache()
        defer { cache.close() }
        for i in 0...25 { cache.store(index: i, data: Data(repeating: 0xAE, count: 8)) }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, producerBase: 0, initialRestartIndex: 0,
                                    backpressureWait: 30.0, settle: 30.0)
        recordSlowMarch(provider, 18...25)
        _ = provider.mediaSegment(at: 25)

        let start = DispatchTime.now()
        let served = provider.mediaSegmentSource(at: 31, onSlow: nil)

        #expect(served != nil)
        #expect(recorder.all == [31])
        #expect(seconds(since: start) < 10.0)  // the 30 s settle did not run
    }

    @Test("a second jump more than the burst window after the first does not settle")
    func jumpAfterBurstWindowDoesNotSettle() {
        let cache = makeCache()
        defer { cache.close() }
        for i in 0...25 { cache.store(index: i, data: Data(repeating: 0xAF, count: 8)) }
        let recorder = Recorder()
        let provider = VideoSegmentProvider(
            cache: cache, segments: segments(200), codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (3840, 2160), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 60_000_000,
            restartHandler: { [weak cache] idx in
                recorder.record(idx)
                cache?.store(index: idx, data: Data(repeating: 0x41, count: 8))
            },
            restartActivity: { false },
            activeProducerBase: { 0 },
            decidesForwardWaitByMarchRate: true,
            marchRateSettleSeconds: 30.0,
            marchRateBurstWindowSeconds: 0,  // any earlier jump is outside the window, no sleep needed
            initialRestartIndex: 0,
            repositionWaitSlice: 0.05,
            repositionRideCapSeconds: 5.0,
            forwardBackpressureWaitSeconds: 30.0
        )
        recordSlowMarch(provider, 18...25)
        _ = provider.mediaSegment(at: 25)
        _ = provider.mediaSegmentSource(at: 31, onSlow: nil)

        let start = DispatchTime.now()
        let served = provider.mediaSegmentSource(at: 34, onSlow: nil)

        #expect(served != nil)
        #expect(recorder.all == [31, 34])
        #expect(seconds(since: start) < 10.0)  // the 30 s settle did not run
    }

    /// Quint review of #933: with the default forward window of 10 on a fast link, the producer spends
    /// its time parked on backpressure and writes one segment per segment of playback. Read as the link,
    /// that is 0.25 segments per second, and a jump 60 to 68 s past the playhead (6 to 8 segments past the
    /// front) restarted a producer that reaches it in about a second. Only unparked intervals measure the link.
    @Test("on a fast link with the default forward window, a jump just past the front waits for the march",
          arguments: [36, 38])
    func fastLinkDefaultWindowWaits(target: Int) {
        let cache = makeCache(forwardWindow: 10)
        defer { cache.close() }
        for i in 11...30 { cache.store(index: i, data: Data(repeating: 0xB1, count: 8)) }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, producerBase: 11, initialRestartIndex: 11,
                                    backpressureWait: 30.0)
        recordFastLinkPacedByPlayback(provider)
        _ = provider.mediaSegment(at: 21)  // the playhead, ten segments behind the front
        parkProducer(cache)  // the window is full
        // The released march writes up to the target at the link rate.
        Thread.detachNewThread {
            for i in 31...target {
                Thread.sleep(forTimeInterval: 0.02)
                cache.store(index: i, data: Data(repeating: 0xB2, count: 8))
            }
        }

        let served = provider.mediaSegment(at: target)

        #expect(served != nil)
        #expect(recorder.all.isEmpty)
    }

    /// While the consumer is paused the producer parks once its window is full, and the last store
    /// grows old. Counted as time spent writing, a long pause made the next segment look nearly done,
    /// so a slow march looked fast enough to wait for.
    @Test("a long pause does not change the decision on a slow march")
    func longPauseKeepsSlowMarchRestart() {
        let cache = makeCache()
        defer { cache.close() }
        for i in 0...25 { cache.store(index: i, data: Data(repeating: 0xB3, count: 8)) }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, producerBase: 0, initialRestartIndex: 0,
                                    backpressureWait: 30.0)
        recordSlowMarch(provider, 18...25, endingAgo: 120)
        parkProducer(cache)  // paused for two minutes with the window full
        _ = provider.mediaSegment(at: 25)

        let served = provider.mediaSegment(at: 31)

        #expect(served != nil)
        #expect(recorder.all == [31])
    }

    @Test("a long pause does not change the decision on a fast link")
    func longPauseKeepsFastLinkWait() {
        let cache = makeCache(forwardWindow: 10)
        defer { cache.close() }
        for i in 11...30 { cache.store(index: i, data: Data(repeating: 0xB4, count: 8)) }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, producerBase: 11, initialRestartIndex: 11,
                                    backpressureWait: 30.0)
        recordFastLinkPacedByPlayback(provider, endingAgo: 120)
        parkProducer(cache)
        _ = provider.mediaSegment(at: 21)
        Thread.detachNewThread {
            for i in 31...36 {
                Thread.sleep(forTimeInterval: 0.02)
                cache.store(index: i, data: Data(repeating: 0xB5, count: 8))
            }
        }

        let served = provider.mediaSegment(at: 36)

        #expect(served != nil)
        #expect(recorder.all.isEmpty)
    }

    @Test("without any march measurement in the session the stock wait is kept")
    func noMeasurementKeepsStock() {
        let cache = makeCache()
        defer { cache.close() }
        for i in 0...25 { cache.store(index: i, data: Data(repeating: 0xA8, count: 8)) }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, producerBase: 0, initialRestartIndex: 0)
        _ = provider.mediaSegment(at: 25)

        _ = provider.mediaSegment(at: 31)

        #expect(recorder.all.isEmpty)
    }

    // MARK: - Pure pieces

    @Test("the march rate is one over the median interval of the active run")
    func trackerCurrentRate() {
        var tracker = MarchRateTracker()
        // Intervals 4, 4, 30 (a stall without a park), 4.
        for (k, time) in [0.0, 4.0, 8.0, 38.0, 42.0].enumerated() {
            tracker.record(index: 10 + k, time: time, bytes: 1000, sourceBytes: nil)
        }
        let estimate = tracker.estimate(activeAnchor: 10)
        #expect(estimate?.source == .current)
        #expect(abs((estimate?.rate ?? 0) - 0.25) < 1e-9)  // one 30 s stall does not count
    }

    @Test("below three intervals the active run defers to the previous run, then to throughput")
    func trackerFallbacks() {
        var tracker = MarchRateTracker()
        #expect(tracker.estimate(activeAnchor: 0) == nil)

        tracker.record(index: 0, time: 0, bytes: 1000, sourceBytes: 0)
        tracker.record(index: 5, time: 2, bytes: 1000, sourceBytes: 2000)
        let throughput = tracker.estimate(activeAnchor: 5)
        #expect(throughput?.source == .throughput)
        #expect(abs((throughput?.rate ?? 0) - 1.0) < 1e-9)  // 1000 B/s over 1000 B segments

        for i in 6...9 { tracker.record(index: i, time: 2 + Double(i - 5) * 2, bytes: 1000, sourceBytes: nil) }
        tracker.record(index: 40, time: 20, bytes: 1000, sourceBytes: nil)  // a restart's first write
        let previous = tracker.estimate(activeAnchor: 40)
        #expect(previous?.source == .previous)
        #expect(abs((previous?.rate ?? 0) - 0.5) < 1e-9)
    }

    @Test("intervals after a park are not read as the link, for the run or for throughput")
    func trackerParksCutTheRun() {
        var tracker = MarchRateTracker()
        // Unparked fill at 4 segments per second, 10 MB segments, 40 MB/s from the source.
        for k in 0...9 {
            tracker.record(index: 11 + k, time: Double(k) * 0.25, bytes: 10_000_000,
                           sourceBytes: Int64(k) * 10_000_000)
        }
        // Then one segment per 4 s, each after a park; the source is idle while parked.
        for k in 0...9 {
            tracker.record(index: 21 + k, time: 2.25 + Double(k + 1) * 4, bytes: 10_000_000,
                           sourceBytes: Int64(10 + k) * 10_000_000, parkedBefore: true)
        }
        let estimate = tracker.estimate(activeAnchor: 11)
        #expect(estimate?.source == .previous)
        #expect(abs((estimate?.rate ?? 0) - 4.0) < 1e-9)

        // A restart with no run of its own yet falls through to throughput, which skips the parked spans too.
        var fresh = MarchRateTracker()
        for k in 0...2 {
            fresh.record(index: 11 + k, time: Double(k) * 0.25, bytes: 10_000_000, sourceBytes: Int64(k) * 10_000_000)
        }
        fresh.record(index: 14, time: 30, bytes: 10_000_000, sourceBytes: 30_000_000, parkedBefore: true)
        let throughput = fresh.estimate(activeAnchor: 14)
        #expect(throughput?.source == .throughput)
        #expect(abs((throughput?.rate ?? 0) - 4.0) < 1e-9)
    }

    @Test("a run the new producer has not split off yet is reported as the previous one")
    func trackerRunBelowAnchorIsPrevious() {
        var tracker = MarchRateTracker()
        for i in 0...4 { tracker.record(index: i, time: Double(i) * 4, bytes: 1000, sourceBytes: nil) }
        #expect(tracker.estimate(activeAnchor: 0)?.source == .current)
        #expect(tracker.estimate(activeAnchor: 31)?.source == .previous)
    }

    @Test("restart only when the march needs longer than the restart budget")
    func pureDecision() {
        // Slow link (0.27 seg/s), six segments to go: about 22 s against a 3 s budget.
        let far = VideoSegmentProvider.marchRateRestarts(
            distance: 6, rate: 0.27, secondsSinceLastStore: 0, budgetSeconds: 3)
        #expect(far.restart)
        #expect(far.eta > 20)
        // The segment being written now costs nothing to wait for.
        #expect(!VideoSegmentProvider.marchRateRestarts(
            distance: 0, rate: 0.27, secondsSinceLastStore: 0, budgetSeconds: 3).restart)
        // One segment further, most of the way through the current one: under budget.
        #expect(!VideoSegmentProvider.marchRateRestarts(
            distance: 1, rate: 0.27, secondsSinceLastStore: 2, budgetSeconds: 3).restart)
        // A fast march (3 seg/s) six segments away arrives in 2 s.
        #expect(!VideoSegmentProvider.marchRateRestarts(
            distance: 6, rate: 3, secondsSinceLastStore: 0, budgetSeconds: 3).restart)
    }
}
