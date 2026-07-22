import Testing
import Foundation
@testable import AetherEngine

/// AE#169 round 2 (rrgomes): the final segment's producer died mid-session (source read error after
/// LAN reconnect churn) and the request for seg719 parked in the forward-wait branch forever:
/// `needsRestart = index > activeMarchFront + forwardWaitWindow` judges "will this arrive?" by index
/// distance alone, so a dead producer's frozen front re-arms the 30 s wait indefinitely
/// (`cache miss after 30005ms (cache=46 restarted=false)` x11 into -12889). Two provider-side
/// escapes: a FINISHED pump is proof the march is never coming (skip the wait entirely), and a full
/// backpressure wait that elapsed with zero front progress for the same index escalates on the next
/// request. Both must also bypass the restart loop's producerCovers veto, which reads the dead
/// producer's still-installed base.
struct Issue169DeadProducerEscalationTests {

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
                              producerFinished: @escaping () -> Bool,
                              storeOnRestart: Bool = true,
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
            producerFinished: producerFinished,
            initialRestartIndex: initialRestartIndex,
            repositionWaitSlice: 0.05,
            repositionRideCapSeconds: 5.0,
            forwardBackpressureWaitSeconds: backpressureWait
        )
    }

    /// Seeds the device geometry at test scale: producer anchored at 40 wrote 40..46 then died.
    private func seedDeadProducerBand(_ cache: SegmentCache) {
        cache.resetHighWaterForRestart()
        for i in 40...46 { cache.store(index: i, data: Data(repeating: 0xA9, count: 8)) }
    }

    /// The trace shape: pump exited (readError) with seg719 never written; AVPlayer requests the
    /// next index above the frozen front. A finished pump can never march, so the fetch must
    /// restart immediately instead of burning the 30 s backpressure wait even once. The dead
    /// producer's base still covers the index, so this also proves the producerCovers bypass.
    @Test("a forward-window fetch with a finished producer restarts immediately")
    func finishedProducerForwardFetchRestartsImmediately() {
        let cache = SegmentCache(forwardWindow: 60, backwardWindow: 60)
        defer { cache.close() }
        let recorder = Recorder()
        seedDeadProducerBand(cache)
        let provider = makeProvider(cache: cache, recorder: recorder,
                                    producerBase: 40, initialRestartIndex: 40,
                                    producerFinished: { true },
                                    backpressureWait: 5.0)

        let start = DispatchTime.now()
        let served = provider.mediaSegment(at: 47)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9

        #expect(served != nil)
        #expect(recorder.all == [47])
        #expect(elapsed < 2.0)
    }

    /// The blocked-in-read variant: the pump never finishes (no exit event), the front just stops.
    /// The first fetch keeps the full backpressure patience (slow WAN reads legitimately take
    /// 20-30 s); the SECOND fetch for the same index with an unmoved front is proof the march is
    /// not coming and must escalate to restart.
    @Test("a repeated forward-window miss with a frozen march front escalates to restart")
    func frozenMarchEscalatesOnSecondMiss() {
        let cache = SegmentCache(forwardWindow: 60, backwardWindow: 60)
        defer { cache.close() }
        let recorder = Recorder()
        seedDeadProducerBand(cache)
        let provider = makeProvider(cache: cache, recorder: recorder,
                                    producerBase: 40, initialRestartIndex: 40,
                                    producerFinished: { false })

        let firstStart = DispatchTime.now()
        let first = provider.mediaSegment(at: 47)
        let firstElapsed = Double(DispatchTime.now().uptimeNanoseconds - firstStart.uptimeNanoseconds) / 1e9
        #expect(first == nil)
        #expect(recorder.all.isEmpty)
        #expect(firstElapsed >= 0.25)

        let second = provider.mediaSegment(at: 47)
        #expect(second != nil)
        #expect(recorder.all == [47])
    }

    /// A slow-but-alive producer keeps its patience: the front advanced between the two misses, so
    /// the second fetch must keep waiting (no restart teardown of a healthy march, the #141/#93
    /// protections). Once the front freezes across a full wait, the third fetch escalates.
    @Test("an advancing march front resets the escalation and keeps the backpressure wait")
    func advancingMarchDoesNotEscalate() {
        let cache = SegmentCache(forwardWindow: 60, backwardWindow: 60)
        defer { cache.close() }
        let recorder = Recorder()
        seedDeadProducerBand(cache)
        let provider = makeProvider(cache: cache, recorder: recorder,
                                    producerBase: 40, initialRestartIndex: 40,
                                    producerFinished: { false })

        #expect(provider.mediaSegment(at: 50) == nil)   // miss 1: front 46 recorded
        cache.store(index: 47, data: Data(repeating: 0xA9, count: 8))   // march advances
        #expect(provider.mediaSegment(at: 50) == nil)   // miss 2: front moved, keep waiting
        #expect(recorder.all.isEmpty)

        let third = provider.mediaSegment(at: 50)        // miss 3: front frozen at 47, escalate
        #expect(third != nil)
        #expect(recorder.all == [50])
    }

    /// Escalation is VOD-only: live sessions have their own pump watchdogs and reopen machinery,
    /// and a live forward-window miss (producer briefly behind the playlist edge) must keep its
    /// plain backpressure wait.
    @Test("live sessions never escalate a forward-window miss")
    func liveNeverEscalates() {
        let cache = SegmentCache(forwardWindow: 60, backwardWindow: 60)
        defer { cache.close() }
        let recorder = Recorder()
        seedDeadProducerBand(cache)
        let provider = VideoSegmentProvider(
            cache: cache, segments: segments(200), codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (3840, 2160), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 60_000_000, isLive: true,
            restartHandler: { recorder.record($0) },
            restartActivity: { false },
            activeProducerBase: { 40 },
            producerFinished: { true },
            initialRestartIndex: 40,
            repositionWaitSlice: 0.05,
            repositionRideCapSeconds: 5.0,
            forwardBackpressureWaitSeconds: 0.2
        )

        #expect(provider.mediaSegment(at: 47) == nil)
        #expect(provider.mediaSegment(at: 47) == nil)
        #expect(recorder.all.isEmpty)
    }

    // MARK: - Pure decisions

    @Test("forwardWaitMarchDead: finished pump is dead regardless of miss history")
    func marchDeadOnFinishedPump() {
        #expect(VideoSegmentProvider.forwardWaitMarchDead(
            index: 719, marchFront: 718, producerFinished: true,
            lastMissIndex: Int.min, lastMissFront: Int.min))
    }

    @Test("forwardWaitMarchDead: same index with unmoved front is dead; moved front or new index is not")
    func marchDeadOnFrozenFrontOnly() {
        #expect(VideoSegmentProvider.forwardWaitMarchDead(
            index: 719, marchFront: 718, producerFinished: false,
            lastMissIndex: 719, lastMissFront: 718))
        #expect(!VideoSegmentProvider.forwardWaitMarchDead(
            index: 719, marchFront: 719, producerFinished: false,
            lastMissIndex: 719, lastMissFront: 718))
        #expect(!VideoSegmentProvider.forwardWaitMarchDead(
            index: 720, marchFront: 718, producerFinished: false,
            lastMissIndex: 719, lastMissFront: 718))
        #expect(!VideoSegmentProvider.forwardWaitMarchDead(
            index: 719, marchFront: 718, producerFinished: false,
            lastMissIndex: Int.min, lastMissFront: Int.min))
    }

    /// AE#169 round 2 engine arm: a VOD pump that dies on a read error MID-SESSION (it produced
    /// media before dying) gets a bounded revive; the nothing-ever-produced case stays the #126
    /// fatal surface, and live keeps its reopen machinery.
    @Test("shouldReviveVODAfterReadError: mid-session yes, dead-source no, live no")
    func readErrorReviveDecision() {
        #expect(HLSVideoEngine.shouldReviveVODAfterReadError(
            isLive: false, packetsWritten: 1265, cachedSegments: 46))
        #expect(HLSVideoEngine.shouldReviveVODAfterReadError(
            isLive: false, packetsWritten: 1265, cachedSegments: 0))
        #expect(HLSVideoEngine.shouldReviveVODAfterReadError(
            isLive: false, packetsWritten: 0, cachedSegments: 46))
        #expect(!HLSVideoEngine.shouldReviveVODAfterReadError(
            isLive: false, packetsWritten: 0, cachedSegments: 0))
        #expect(!HLSVideoEngine.shouldReviveVODAfterReadError(
            isLive: true, packetsWritten: 1265, cachedSegments: 46))
    }
}
