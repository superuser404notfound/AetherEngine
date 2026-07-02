import Testing
import Foundation
@testable import AetherEngine

/// #93 residual: a waiting out-of-range segment fetch must RIDE an in-flight restart instead of
/// burning a fixed 3x8 s budget into a 503 (device: every pending fetch 503'd while a 44 s restart
/// was genuinely progressing, and AVPlayer gave up), it must not re-fire a restart at its own
/// stale index against the coalescer's newer target, and a re-request for the index a restart
/// JUST targeted must wait for the fresh producer instead of tearing it down (device: three
/// back-to-back restarts at the same index, one dropped frame each).
struct SegmentFetchWaitTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var fired: [Int] = []
        func record(_ idx: Int) { lock.lock(); fired.append(idx); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return fired }
    }

    /// Deterministic activity signal: true for the first `n` polls, false after. Avoids
    /// wall-clock scheduling, which flakes under parallel test load.
    private final class ActivityFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        init(truePolls: Int) { remaining = truePolls }
        func get() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if remaining == Int.max { return true }
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        static func always() -> ActivityFlag { ActivityFlag(truePolls: Int.max) }
        static func never() -> ActivityFlag { ActivityFlag(truePolls: 0) }
    }

    private func segments(_ n: Int) -> [HLSVideoEngine.Segment] {
        (0..<n).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
    }

    private func makeProvider(cache: SegmentCache, recorder: Recorder, activity: ActivityFlag,
                              slice: TimeInterval = 0.05, rideCap: TimeInterval = 5.0,
                              initialRestartIndex: Int = 0,
                              storeOnRestart: Bool = false) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: cache, segments: segments(60), codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            restartHandler: { [weak cache] idx in
                recorder.record(idx)
                if storeOnRestart {
                    cache?.store(index: idx, data: Data(repeating: 0xCD, count: 8))
                }
            },
            restartActivity: { activity.get() },
            initialRestartIndex: initialRestartIndex,
            repositionWaitSlice: slice,
            repositionRideCapSeconds: rideCap
        )
    }

    /// Puts the cache into the device-repro shape: resident segments ABOVE the requested index,
    /// so the request takes the out-of-range fire loop (index < range.lowerBound), not the
    /// empty-cache cold-start wait.
    private func storeAbove(_ cache: SegmentCache, range: ClosedRange<Int>) {
        for i in range { cache.store(index: i, data: Data(repeating: 0xEE, count: 8)) }
    }

    @Test("a fetch rides an in-flight restart to a late segment instead of 503ing")
    func ridesInFlightRestart() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, activity: .always())
        // The in-flight restart delivers the segment after ~6 wait slices, well past the old
        // fixed 3-attempt budget.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            cache.store(index: 40, data: Data(repeating: 0xAB, count: 8))
        }
        let served = provider.mediaSegment(at: 40)
        #expect(served != nil)
        #expect(recorder.all.isEmpty)
    }

    @Test("riding is bounded: nil at the ride cap when nothing arrives, still no stale re-fire")
    func rideCapBounds() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, activity: .always(),
                                    slice: 0.05, rideCap: 0.3)
        let start = DispatchTime.now()
        let served = provider.mediaSegment(at: 40)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        #expect(served == nil)
        #expect(recorder.all.isEmpty)
        #expect(elapsed >= 0.3)
    }

    @Test("resume-anchored provider cold-waits at the anchor instead of restarting the producer")
    func resumeAnchorColdStart() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let recorder = Recorder()
        // #93 residual: the first producer anchors at the resume segment; without the matching
        // initialRestartIndex the cold-start heuristic (abs(index - 0) > 2) restarted it immediately.
        let provider = makeProvider(cache: cache, recorder: recorder, activity: .never(),
                                    initialRestartIndex: 40)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            cache.store(index: 40, data: Data(repeating: 0x11, count: 8))
        }
        let served = provider.mediaSegment(at: 40)
        #expect(served != nil)
        #expect(recorder.all.isEmpty)
    }

    @Test("without an in-flight restart the fixed-budget behavior is unchanged")
    func fixedBudgetWithoutActivity() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, activity: .never())
        let served = provider.mediaSegment(at: 40)
        #expect(served == nil)
        #expect(recorder.all == [40])
    }

    /// Activity signal that also DELIVERS a segment on its nth poll: the fire loop polls activity
    /// once per iteration, so this simulates the fresh producer capturing the segment during the
    /// re-request's grace window, without wall-clock timers (which flake under parallel test load).
    private final class DeliveringFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var polls = 0
        private let deliverOnPoll: Int
        private let deliver: @Sendable () -> Void
        init(deliverOnPoll: Int, deliver: @escaping @Sendable () -> Void) {
            self.deliverOnPoll = deliverOnPoll
            self.deliver = deliver
        }
        func get() -> Bool {
            lock.lock()
            polls += 1
            let fire = polls == deliverOnPoll
            lock.unlock()
            if fire { deliver() }
            return false
        }
    }

    @Test("a re-request for the index a restart just targeted waits instead of re-firing")
    func sameIndexNoRedundantFire() {
        let cache = SegmentCache(forwardWindow: 30, backwardWindow: 30)
        defer { cache.close() }
        let recorder = Recorder()
        // Device shape: old segments above the request are still resident, so the request takes
        // the out-of-range fire loop. The first request fires and misses.
        let deliverer = DeliveringFlag(deliverOnPoll: 5) { [weak cache] in
            cache?.store(index: 40, data: Data(repeating: 0x22, count: 8))
        }
        let provider = VideoSegmentProvider(
            cache: cache, segments: segments(60), codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            restartHandler: { idx in recorder.record(idx) },
            restartActivity: { deliverer.get() },
            repositionWaitSlice: 0.05,
            repositionRideCapSeconds: 5.0
        )
        storeAbove(cache, range: 45...50)
        #expect(provider.mediaSegment(at: 40) == nil)   // polls 1-3: fires once, misses
        #expect(recorder.all == [40])
        // AVPlayer re-requests while the restarted producer is still capturing: delivery lands on
        // poll 5 (second iteration of this call), inside the same-index grace window, and no
        // second restart tears the producer down.
        let served = provider.mediaSegment(at: 40)
        #expect(served != nil)
        #expect(recorder.all == [40])
    }

    @Test("same-index orphan gets one backstop re-fire on the final attempt")
    func sameIndexOrphanBackstop() {
        let cache = SegmentCache(forwardWindow: 30, backwardWindow: 30)
        defer { cache.close() }
        let recorder = Recorder()
        let provider = makeProvider(cache: cache, recorder: recorder, activity: .never())
        storeAbove(cache, range: 45...50)
        #expect(provider.mediaSegment(at: 40) == nil)  // fires once, producer never delivers
        #expect(provider.mediaSegment(at: 40) == nil)  // waits, then backstop-fires on the last attempt
        #expect(recorder.all == [40, 40])
    }

    @Test("restart settling mid-wait hands control back to the fixed budget")
    func settleThenFire() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let recorder = Recorder()
        // The foreign restart reports activity for the first three polls, then settles without
        // covering seg 40; the fetch then fires its own restart (the #50 orphan recovery), whose
        // producer delivers the segment (storeOnRestart).
        let provider = makeProvider(cache: cache, recorder: recorder,
                                    activity: ActivityFlag(truePolls: 3), storeOnRestart: true)
        let served = provider.mediaSegment(at: 40)
        #expect(served != nil)
        #expect(recorder.all == [40])
    }
}
