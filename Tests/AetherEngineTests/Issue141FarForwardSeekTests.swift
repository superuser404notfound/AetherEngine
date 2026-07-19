import Testing
import Foundation
@testable import AetherEngine

/// AE#141: a far-forward seek above a retained stale scrub band parked 3x30 s into item death.
/// The forward-wait branch (r.1 < index <= r.1 + forwardWaitWindow) read the resident max as "the
/// producer is about to write this", but with #93 retention the resident max can belong to a DEAD
/// producer's band (600 s scrub left seg150-158) while the active producer marches far below
/// (re-anchored at 75, front ~79). The request for seg159 must re-anchor the producer, not
/// backpressure-wait on a march that is ~2 minutes away.
struct Issue141FarForwardSeekTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var fired: [Int] = []
        func record(_ idx: Int) { lock.lock(); fired.append(idx); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return fired }
    }

    private func segments(_ n: Int) -> [HLSVideoEngine.Segment] {
        (0..<n).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
    }

    private func makeProvider(cache: SegmentCache, recorder: Recorder,
                              producerBase: Int?, initialRestartIndex: Int,
                              storeOnRestart: Bool = false,
                              backpressureWait: TimeInterval = 0.3) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: cache, segments: segments(200), codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (3840, 2160), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 60_000_000,
            restartHandler: { [weak cache] idx in
                recorder.record(idx)
                if storeOnRestart {
                    cache?.store(index: idx, data: Data(repeating: 0x41, count: 8))
                }
            },
            restartActivity: { false },
            activeProducerBase: { producerBase },
            initialRestartIndex: initialRestartIndex,
            repositionWaitSlice: 0.05,
            repositionRideCapSeconds: 5.0,
            forwardBackpressureWaitSeconds: backpressureWait
        )
    }

    /// The device geometry from the report: stale band 150-158 (dead 600 s-scrub producer),
    /// active producer re-anchored at 75 with march front 79. AVPlayer's request for seg159
    /// (the 640 s target) sat exactly in the forward-wait window above the stale band and
    /// parked 30 s with restarted=false, three times, into -1017 item death.
    @Test("a forward request above a stale band re-anchors the producer instead of parking")
    func farForwardAboveStaleBandRestartsInsteadOfParking() {
        // Device shape: VOD sessions run with the #93 retention budget, which is what keeps the
        // dead band resident. Without it, window pruning evicts the band and hides the bug.
        let cache = SegmentCache(forwardWindow: 60, backwardWindow: 60,
                                 retentionBudgetBytes: 512 * 1024 * 1024)
        defer { cache.close() }
        let recorder = Recorder()
        // Dead gen-1 band: written by an earlier producer, still resident under the retention budget.
        for i in 150...158 { cache.store(index: i, data: Data(repeating: 0xA1, count: 8)) }
        // Gen-3 provider-fired restart at 75 reset the high water; the active producer then wrote 75-79.
        cache.resetHighWaterForRestart()
        for i in 75...79 { cache.store(index: i, data: Data(repeating: 0xA3, count: 8)) }
        let provider = makeProvider(cache: cache, recorder: recorder,
                                    producerBase: 75, initialRestartIndex: 75,
                                    storeOnRestart: true)

        let start = DispatchTime.now()
        let served = provider.mediaSegment(at: 159)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9

        #expect(served != nil)
        #expect(recorder.all == [159])
        #expect(elapsed < 2.0)
    }

    /// Healthy forward catch-up must keep its backpressure-wait: single march band, AVPlayer
    /// requests one past the active producer's front, the march delivers moments later. No restart.
    @Test("catch-up one past the active march front still backpressure-waits")
    func forwardCatchupStillBackpressureWaits() {
        let cache = SegmentCache(forwardWindow: 60, backwardWindow: 60,
                                 retentionBudgetBytes: 512 * 1024 * 1024)
        defer { cache.close() }
        let recorder = Recorder()
        for i in 30...40 { cache.store(index: i, data: Data(repeating: 0xB2, count: 8)) }
        // Kernel-scheduled thread, not a GCD timer: oversubscribed CI runners starve
        // global-queue timers past short wait slices (see SegmentFetchWaitTests).
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.05)
            cache.store(index: 41, data: Data(repeating: 0xB3, count: 8))
        }
        let provider = makeProvider(cache: cache, recorder: recorder,
                                    producerBase: 30, initialRestartIndex: 30,
                                    backpressureWait: 1.0)

        let served = provider.mediaSegment(at: 41)

        #expect(served != nil)
        #expect(recorder.all.isEmpty)
    }
}

/// AE#141: the march-coverage predicate the engine's seek-deadline backstop keys on.
extension Issue141FarForwardSeekTests {
    @Test("march coverage spans anchor to front plus the forward-wait window")
    func marchCoverageSpans() {
        let cache = SegmentCache(forwardWindow: 60, backwardWindow: 60,
                                 retentionBudgetBytes: 512 * 1024 * 1024)
        defer { cache.close() }
        let recorder = Recorder()
        // Dead band above, then a provider-fired-restart-shaped reset and an active march 75-79.
        for i in 150...158 { cache.store(index: i, data: Data(repeating: 0xC1, count: 8)) }
        cache.resetHighWaterForRestart()
        for i in 75...79 { cache.store(index: i, data: Data(repeating: 0xC2, count: 8)) }
        let provider = makeProvider(cache: cache, recorder: recorder,
                                    producerBase: 75, initialRestartIndex: 75)

        // Anchor-to-front span and the forward-wait window ahead of the front are covered.
        #expect(provider.activeMarchCovers(75))
        #expect(provider.activeMarchCovers(79))
        #expect(provider.activeMarchCovers(87))   // front 79 + window 8
        // Beyond the window (the 640 s target, seg159) and behind the anchor are not.
        #expect(!provider.activeMarchCovers(88))
        #expect(!provider.activeMarchCovers(159))
        #expect(!provider.activeMarchCovers(74))
    }

    @Test("before its first write a restarted producer covers its anchor window")
    func marchCoverageColdStart() {
        let cache = SegmentCache(forwardWindow: 60, backwardWindow: 60,
                                 retentionBudgetBytes: 512 * 1024 * 1024)
        defer { cache.close() }
        let recorder = Recorder()
        for i in 150...158 { cache.store(index: i, data: Data(repeating: 0xC3, count: 8)) }
        cache.resetHighWaterForRestart()
        let provider = makeProvider(cache: cache, recorder: recorder,
                                    producerBase: 75, initialRestartIndex: 75)

        #expect(provider.activeMarchCovers(75))
        #expect(provider.activeMarchCovers(83))   // anchor 75 + window 8, no writes yet
        #expect(!provider.activeMarchCovers(84))
        #expect(!provider.activeMarchCovers(74))
    }
}
