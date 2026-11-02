import XCTest
@testable import AetherEngine

private final class Issue936WaitResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func store(_ value: Bool) {
        lock.lock()
        _value = value
        lock.unlock()
    }
}

/// AE#936: a fastZap grace that cannot finalize another segment ends early.
final class Issue936GraceReadHeadTests: XCTestCase {
    // MARK: policy

    func testDrainedBurstOnALongGOPIsFutile() {
        // The reporter's NPO 3 shape: four 5 s segments cut, open segment just begun, source at 1x.
        XCTAssertTrue(LiveEdgePolicy.fastZapGraceIsFutile(
            openSegmentSeconds: 0.3, shortestSegmentSeconds: 5,
            deliveryRate: 1.0, remainingGraceSeconds: 1.5))
    }

    func testShortGOPKeepsTheGrace() {
        // 1 s GOP at 1x: one more segment fits in the grace, which is what the grace is for.
        XCTAssertFalse(LiveEdgePolicy.fastZapGraceIsFutile(
            openSegmentSeconds: 0.2, shortestSegmentSeconds: 1,
            deliveryRate: 1.0, remainingGraceSeconds: 1.0))
    }

    func testGraceSizedToOneGOPKeepsItDespiteALaggingHead() {
        // 1 s GOP, grace 1 s, read head a demuxer chunk behind: reachable reads 0.8 against 1.0.
        XCTAssertFalse(LiveEdgePolicy.fastZapGraceIsFutile(
            openSegmentSeconds: 0.1, shortestSegmentSeconds: 1,
            deliveryRate: 0.6, remainingGraceSeconds: 0.7))
    }

    func testBurstStillArrivingKeepsTheGrace() {
        XCTAssertFalse(LiveEdgePolicy.fastZapGraceIsFutile(
            openSegmentSeconds: 0.3, shortestSegmentSeconds: 5,
            deliveryRate: 12, remainingGraceSeconds: 1.5))
    }

    func testOpenSegmentNearItsKeyframeKeepsTheGrace() {
        XCTAssertFalse(LiveEdgePolicy.fastZapGraceIsFutile(
            openSegmentSeconds: 4.2, shortestSegmentSeconds: 5,
            deliveryRate: 1.0, remainingGraceSeconds: 1.0))
    }

    func testRateBelowRealtimeIsTreatedAsRealtime() {
        // A demuxer pause between chunks reads as 0x; a live source cannot sustain that.
        XCTAssertFalse(LiveEdgePolicy.fastZapGraceIsFutile(
            openSegmentSeconds: 0.2, shortestSegmentSeconds: 1,
            deliveryRate: 0, remainingGraceSeconds: 1.0))
    }

    func testUnknownInputsKeepTheGrace() {
        XCTAssertFalse(LiveEdgePolicy.fastZapGraceIsFutile(
            openSegmentSeconds: 0.3, shortestSegmentSeconds: 5,
            deliveryRate: nil, remainingGraceSeconds: 1.5))
        XCTAssertFalse(LiveEdgePolicy.fastZapGraceIsFutile(
            openSegmentSeconds: -3, shortestSegmentSeconds: 5,
            deliveryRate: 1, remainingGraceSeconds: 1.5))
    }

    // MARK: read head

    func testRateNeedsAMinimumSpan() {
        var head = LiveReadHead()
        head.note(ptsSeconds: 10, at: 100)
        head.note(ptsSeconds: 10.1, at: 100.1)
        XCTAssertNil(head.deliveryRate(now: 100.1, window: 0.5, minimumSpan: 0.25))
        head.note(ptsSeconds: 10.3, at: 100.3)
        XCTAssertEqual(head.deliveryRate(now: 100.3, window: 0.5, minimumSpan: 0.25) ?? -1, 1.0, accuracy: 0.01)
    }

    func testDiscontinuityRestartsTheRate() {
        var head = LiveReadHead()
        head.note(ptsSeconds: 50, at: 100)
        head.note(ptsSeconds: 50.4, at: 100.4)
        head.note(ptsSeconds: 2, at: 100.5)
        XCTAssertEqual(head.latestPtsSeconds, 2)
        XCTAssertNil(head.deliveryRate(now: 100.5, window: 0.5, minimumSpan: 0.25))
    }

    // MARK: gate

    private func makeProvider() -> (VideoSegmentProvider, SegmentCache) {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: [],
            codecsString: "hvc1.2.4.L150,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 50,
            hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(
                targetSegmentDurationSeconds: 0.5,
                dvrWindowSeconds: nil
            ),
            allowsBoundedDegradedStart: true
        )
        return (provider, cache)
    }

    /// Four 5 s segments, then the read head moving from 20 s at `rate` until the waiter returns.
    private func runGate(rate: Double) -> (served: Bool?, elapsed: Double) {
        let (provider, cache) = makeProvider()
        defer { cache.close() }
        let result = Issue936WaitResult()
        let finished = expectation(description: "startup waiter finished")
        Thread.detachNewThread {
            result.store(provider.waitForFirstLiveSegment(timeout: 120))
            finished.fulfill()
        }
        while provider.parkedWaiterCount == 0 { usleep(200) }
        for index in 0..<4 {
            provider.appendLiveSegment(index: index, startSeconds: Double(index) * 5, durationSeconds: 5)
        }
        let started = DispatchTime.now()
        // The head follows the wall clock, not the sleep: a usleep that overslept on a loaded runner
        // would read as a slower source and end the grace for a burst that is still arriving.
        let feeder = Thread {
            while result.value == nil {
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
                provider.noteLiveReadHead(ptsSeconds: 20 + seconds * rate)
                usleep(20_000)
            }
        }
        feeder.start()
        wait(for: [finished], timeout: 300)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
        return (result.value, elapsed)
    }

    func testGateEndsAFutileGraceEarly() {
        let run = runGate(rate: 1)
        XCTAssertEqual(run.served, true)
        // The rate needs 0.25 s of samples, then one poll; the full grace is 2 s.
        XCTAssertLessThan(run.elapsed, 1.2)
    }

    func testGateKeepsTheGraceWhileTheBurstArrives() {
        let run = runGate(rate: 15)
        XCTAssertEqual(run.served, true)
        XCTAssertGreaterThanOrEqual(run.elapsed, 1.9)
    }
}
