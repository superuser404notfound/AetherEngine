import XCTest
@testable import AetherEngine

// A host cushion floors `.fastZap`'s bounded start at the cushion (as `liveEdgeCushionSeconds`
// documents), it does not switch the bounded start off. Reported from NowSeen: a 2.5 s "network
// buffer" on a 10 s-GOP channel (TARGETDURATION 10, holdback 30 s) made every join wait for a third
// segment in real time, so the channel never reached a picture inside the host's 8 s watchdog.

private final class BoundedStartCushionWaitResult: @unchecked Sendable {
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

final class BoundedStartCushionTests: XCTestCase {

    private func makeProvider(cushion: Double) -> (VideoSegmentProvider, SegmentCache) {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: [],
            codecsString: "avc1.640028,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 25,
            hdcpLevel: nil,
            sourceBitrate: 6_000_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(
                targetSegmentDurationSeconds: 0.5,
                dvrWindowSeconds: nil,
                edgeCushionSeconds: LiveEdgePolicy.edgeCushion(cushion)
            ),
            allowsBoundedDegradedStart: true
        )
        return (provider, cache)
    }

    private func startWaiter(_ provider: VideoSegmentProvider) -> (BoundedStartCushionWaitResult, XCTestExpectation) {
        let result = BoundedStartCushionWaitResult()
        let finished = expectation(description: "startup waiter finished")
        Thread.detachNewThread {
            result.store(provider.waitForFirstLiveSegment(timeout: 300))
            finished.fulfill()
        }
        while provider.parkedWaiterCount == 0 { usleep(200) }
        return (result, finished)
    }

    private func append(_ provider: VideoSegmentProvider, index: Int, duration: Double = 0.2) {
        provider.appendLiveSegment(index: index, startSeconds: Double(index) * duration, durationSeconds: duration)
    }

    /// The reported shape, scaled down: a cushion far below the holdback (0.3 s against 3 s) is held by
    /// two segments, so the join serves at the grace instead of waiting for the full holdback.
    func testCushionBelowTheHoldbackKeepsTheBoundedStart() {
        let (provider, cache) = makeProvider(cushion: 0.3)
        defer { cache.close() }
        let (result, finished) = startWaiter(provider)

        append(provider, index: 0)
        let threshold = DispatchTime.now()
        append(provider, index: 1)

        wait(for: [finished], timeout: 10)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - threshold.uptimeNanoseconds) / 1_000_000_000
        XCTAssertEqual(result.value, true)
        XCTAssertLessThan(elapsed, 0.9, "a cushion the window already holds still barred the bounded start")
    }

    /// The floor: two segments that do not yet hold the cushion must not serve, however long the grace
    /// runs, and the third one that does hold it releases the bounded start.
    func testBoundedStartWaitsUntilTheWindowHoldsTheCushion() {
        let (provider, cache) = makeProvider(cushion: 0.5)
        defer { cache.close() }
        let (result, finished) = startWaiter(provider)

        append(provider, index: 0)
        append(provider, index: 1)
        Thread.sleep(forTimeInterval: 0.9)
        XCTAssertNil(result.value, "a 0.4 s window served under a 0.5 s cushion")

        append(provider, index: 2)
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(result.value, true)
    }
}
