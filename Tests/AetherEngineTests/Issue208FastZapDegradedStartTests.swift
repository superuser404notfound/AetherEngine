import XCTest
@testable import AetherEngine

private final class Issue208WaitResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool?
    private var _releasedAt: DispatchTime?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    /// Stamped on the waiter's own thread the moment the wait returns, so a timing assertion does
    /// not also measure how late XCTest's `wait(for:)` wakes the test thread afterwards.
    var releasedAt: DispatchTime? {
        lock.lock()
        defer { lock.unlock() }
        return _releasedAt
    }

    func store(_ value: Bool) {
        let now = DispatchTime.now()
        lock.lock()
        _value = value
        _releasedAt = now
        lock.unlock()
    }
}

final class Issue208FastZapDegradedStartTests: XCTestCase {
    func testDegradedGraceIsOneSegmentDurationClampedToBounds() {
        XCTAssertEqual(
            LiveEdgePolicy.fastZapDegradedGraceSeconds(maxSegmentDuration: 0.2),
            0.5
        )
        XCTAssertEqual(
            LiveEdgePolicy.fastZapDegradedGraceSeconds(maxSegmentDuration: 0.8),
            0.8
        )
        XCTAssertEqual(
            LiveEdgePolicy.fastZapDegradedGraceSeconds(maxSegmentDuration: 4.0),
            2.0
        )
    }

    private func makeProvider(
        allowsBoundedDegradedStart: Bool
    ) -> (VideoSegmentProvider, SegmentCache) {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: [],
            codecsString: "hvc1.2.4.L150,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (3840, 2160),
            videoRange: .pq,
            frameRate: 50,
            hdcpLevel: "TYPE-1",
            sourceBitrate: 20_000_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(
                targetSegmentDurationSeconds: 0.5,
                dvrWindowSeconds: nil
            ),
            allowsBoundedDegradedStart: allowsBoundedDegradedStart
        )
        return (provider, cache)
    }

    private func startWaiter(
        _ provider: VideoSegmentProvider,
        timeout: TimeInterval = 120
    ) -> (Issue208WaitResult, XCTestExpectation) {
        let result = Issue208WaitResult()
        let finished = expectation(description: "startup waiter finished")
        // A thread of its own, and then wait for the PARK rather than for a duration: on a pool
        // whose workers all block, this waiter can be minutes from its first instruction, and a
        // sleep long enough to "probably" have parked it decides what the test measures.
        Thread.detachNewThread {
            result.store(provider.waitForFirstLiveSegment(timeout: timeout))
            finished.fulfill()
        }
        while provider.parkedWaiterCount == 0 { usleep(200) }
        return (result, finished)
    }

    private func append(
        _ provider: VideoSegmentProvider,
        index: Int,
        duration: Double = 0.2
    ) {
        provider.appendLiveSegment(
            index: index,
            startSeconds: Double(index) * duration,
            durationSeconds: duration
        )
    }

    func testFastZapReleasesAfterTwoSegmentsAndBoundedGrace() {
        let (provider, cache) = makeProvider(allowsBoundedDegradedStart: true)
        defer { cache.close() }
        let (result, finished) = startWaiter(provider)

        append(provider, index: 0)
        let threshold = DispatchTime.now()
        append(provider, index: 1)

        wait(for: [finished], timeout: 300)
        XCTAssertEqual(result.value, true)
        // Measured to the waiter's own release stamp: read after `wait(for:)` returned, the same
        // 0.5 s grace came out at 1.03 s on a loaded CI runner. The ceiling still has to sit well
        // below the 2.0 s clamp, which is what a wrongly sized grace would land on.
        let released = result.releasedAt ?? DispatchTime.now()
        let elapsed = Double(
            released.uptimeNanoseconds - threshold.uptimeNanoseconds
        ) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(elapsed, 0.45)
        XCTAssertLessThan(elapsed, 1.5)
    }

    func testStandardStillWaitsForFullHoldback() {
        let (provider, cache) = makeProvider(allowsBoundedDegradedStart: false)
        defer { cache.close() }
        let (result, finished) = startWaiter(provider)

        append(provider, index: 0)
        append(provider, index: 1)
        Thread.sleep(forTimeInterval: 0.7)
        XCTAssertNil(result.value)

        for index in 2..<15 {
            append(provider, index: index)
        }
        wait(for: [finished], timeout: 300)
        XCTAssertEqual(result.value, true)
    }

    func testFastZapNeverServesOneSegmentThroughBoundedPath() {
        let (provider, cache) = makeProvider(allowsBoundedDegradedStart: true)
        defer { cache.close() }
        let (result, finished) = startWaiter(provider)

        append(provider, index: 0)
        Thread.sleep(forTimeInterval: 0.7)
        XCTAssertNil(result.value)

        provider.cancelWaiters()
        wait(for: [finished], timeout: 300)
        XCTAssertEqual(result.value, false)
    }

    func testBacklogFullCushionWinsBeforeGrace() {
        let (provider, cache) = makeProvider(allowsBoundedDegradedStart: true)
        defer { cache.close() }
        let (result, finished) = startWaiter(provider)
        let started = DispatchTime.now()

        for index in 0..<15 {
            append(provider, index: index)
        }
        wait(for: [finished], timeout: 300)
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
        ) / 1_000_000_000
        XCTAssertEqual(result.value, true)
        XCTAssertLessThan(elapsed, 0.45)
    }

    func testLaterAppendDoesNotExtendDegradedDeadline() {
        let (provider, cache) = makeProvider(allowsBoundedDegradedStart: true)
        defer { cache.close() }
        let (result, finished) = startWaiter(provider)

        append(provider, index: 0)
        let threshold = DispatchTime.now()
        append(provider, index: 1)
        Thread.sleep(forTimeInterval: 0.25)
        append(provider, index: 2)

        wait(for: [finished], timeout: 300)
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - threshold.uptimeNanoseconds
        ) / 1_000_000_000
        XCTAssertEqual(result.value, true)
        XCTAssertLessThan(elapsed, 0.9)
    }
}
