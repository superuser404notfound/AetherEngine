import XCTest
@testable import AetherEngine

/// AE#594 arm B. `fastZap`'s bounded start serves once two segments exist plus a clamped grace, and
/// that window can be shallower than the holdback the same manifest advertises, so AVPlayer's
/// initial seek to edge-minus-holdback lands at the very start of the window. Arm B floors the
/// bounded branch at the holdback, leaving the outer wall-clock deadline as the only shortcut.
///
/// The hypothesis this arm exists to price: the floor is free on an origin that arrives with a
/// backlog, and costs only on a strict-realtime one. `floorIsFreeOnABacklogOrigin` is that
/// hypothesis at unit scale, and it is also the control that keeps the floor from being read as
/// "wait longer always".
private final class Issue594WaitResult: @unchecked Sendable {
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

final class Issue594BoundedStartFloorTests: XCTestCase {

    private func makeProvider(floorsAtHoldback: Bool) -> (VideoSegmentProvider, SegmentCache) {
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
            allowsBoundedDegradedStart: true,
            // The grace these cases exercise. The default is 0 since the live start measurements of 2026-11-19.
            startupGraceSeconds: 0.5,
            boundedStartFloorsAtHoldback: floorsAtHoldback
        )
        return (provider, cache)
    }

    private func startWaiter(
        _ provider: VideoSegmentProvider,
        timeout: TimeInterval = 3
    ) -> (Issue594WaitResult, XCTestExpectation) {
        let result = Issue594WaitResult()
        let finished = expectation(description: "startup waiter finished")
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

    /// Arm A serves here at about 0.5 s. Arm B must not: two 0.2 s segments are 0.4 s of content
    /// against a 3 s holdback (TARGETDURATION 1 s).
    func testFloorHoldsAStrictRealtimeOriginPastTheGrace() {
        let (provider, cache) = makeProvider(floorsAtHoldback: true)
        defer { cache.close() }
        // No outer deadline within reach: it serves a degraded start, which would read as the floor
        // releasing.
        let (result, finished) = startWaiter(provider, timeout: 300)

        append(provider, index: 0)
        append(provider, index: 1)
        Thread.sleep(forTimeInterval: 0.9)
        XCTAssertNil(result.value, "the bounded start served a window shallower than the holdback")

        for index in 2..<15 {
            append(provider, index: index)
        }
        wait(for: [finished], timeout: 300)
        XCTAssertEqual(result.value, true, "the floor never released once the cushion was built")
    }

    /// The control, and the hypothesis: an origin that hands its window over in one go satisfies the
    /// full cushion before the grace would ever have fired, so the floor costs it nothing.
    func testFloorIsFreeOnABacklogOrigin() {
        let (provider, cache) = makeProvider(floorsAtHoldback: true)
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
        XCTAssertLessThan(elapsed, 0.45, "the floor delayed an origin that already had the cushion")
    }

    /// Arm A is untouched by the flag's presence, so the A/B compares one changed thing.
    func testArmAStillServesAtTheGrace() {
        let (provider, cache) = makeProvider(floorsAtHoldback: false)
        defer { cache.close() }
        let (result, finished) = startWaiter(provider)

        append(provider, index: 0)
        let threshold = DispatchTime.now()
        append(provider, index: 1)

        wait(for: [finished], timeout: 300)
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - threshold.uptimeNanoseconds
        ) / 1_000_000_000
        XCTAssertEqual(result.value, true)
        XCTAssertGreaterThanOrEqual(elapsed, 0.45)
        XCTAssertLessThan(elapsed, 0.9)
    }
}
