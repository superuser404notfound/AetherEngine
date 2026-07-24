import XCTest
@testable import AetherEngine

private final class Issue208WaitResult: @unchecked Sendable {
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
        timeout: TimeInterval = 3
    ) -> (Issue208WaitResult, XCTestExpectation) {
        let result = Issue208WaitResult()
        let finished = expectation(description: "startup waiter finished")
        DispatchQueue.global().async {
            result.store(provider.waitForFirstLiveSegment(timeout: timeout))
            finished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
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

        wait(for: [finished], timeout: 1.2)
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - threshold.uptimeNanoseconds
        ) / 1_000_000_000
        XCTAssertEqual(result.value, true)
        XCTAssertGreaterThanOrEqual(elapsed, 0.45)
        XCTAssertLessThan(elapsed, 0.9)
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
        wait(for: [finished], timeout: 1)
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
        wait(for: [finished], timeout: 1)
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
        wait(for: [finished], timeout: 1)
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

        wait(for: [finished], timeout: 1)
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - threshold.uptimeNanoseconds
        ) / 1_000_000_000
        XCTAssertEqual(result.value, true)
        XCTAssertLessThan(elapsed, 0.9)
    }
}
