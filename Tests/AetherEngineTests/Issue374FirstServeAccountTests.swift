// Tests/AetherEngineTests/Issue374FirstServeAccountTests.swift
// AE#374: the loopback's entire live-join cost is one withheld `/media.m3u8` response, and `.standard`
// used to log only when the gate FAILED. Measured on 6.27.0 against a paced raw-MPEG-TS origin, first
// readyToPlay landed at 18.66s / 12.70s / 6.75s / 0.43s for 0 / 6 / 12 / 30s of origin backlog, while the
// engine's own work was finished at +0.19s in every one of them. A downstream host could see the wait in
// `startupProgress` (it stalls at `sessionConstructed`) but nowhere in the log, so the interval had to be
// measured from the outside. These tests pin that every exit from the gate now names the interval it held.
import XCTest
@testable import AetherEngine

private final class Issue374WaitResult: @unchecked Sendable {
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

/// Captures `EngineLog` lines for the duration of one test. The handler is global, so it is restored in
/// every path rather than at the end of the happy one.
private final class Issue374LogTap: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let previous: ((String) -> Void)?

    init() {
        previous = EngineLog.handler
        let sink = { [self] (line: String) in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        EngineLog.handler = sink
    }

    func restore() { EngineLog.handler = previous }

    func matching(_ needle: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines.filter { $0.contains(needle) }
    }
}

final class Issue374FirstServeAccountTests: XCTestCase {

    // MARK: The account line

    func testAccountNamesTheIntervalTheGateHeld() {
        let line = LiveEdgePolicy.firstServeAccount(
            waitedSeconds: 18.463,
            segmentCount: 6,
            summedDurationSeconds: 18.400,
            targetDuration: 6
        )
        XCTAssertTrue(line.contains("after 18.463s"), line)
    }

    func testAccountDerivesTheHoldbackFromTargetDurationRatherThanTakingItOnTrust() {
        let line = LiveEdgePolicy.firstServeAccount(
            waitedSeconds: 1.0,
            segmentCount: 6,
            summedDurationSeconds: 18.4,
            targetDuration: 6
        )
        XCTAssertTrue(line.contains("18.000s holdback"), line)
        XCTAssertTrue(line.contains("TARGETDURATION 6s"), line)
    }

    func testAccountReportsWhetherTheWindowReachedTheHoldback() {
        let satisfied = LiveEdgePolicy.firstServeAccount(
            waitedSeconds: 0,
            segmentCount: 6,
            summedDurationSeconds: 18.0,
            targetDuration: 6
        )
        XCTAssertTrue(satisfied.contains("18.000s >= 18.000s holdback"), satisfied)

        let short = LiveEdgePolicy.firstServeAccount(
            waitedSeconds: 0,
            segmentCount: 2,
            summedDurationSeconds: 10.0,
            targetDuration: 5
        )
        XCTAssertTrue(short.contains("10.000s < 15.000s holdback"), short)
    }

    /// The free-runway case is the one a host most needs to be able to tell apart from "not logged":
    /// an origin with a deep backlog satisfies the cushion at I/O speed, and that is a measurement.
    func testAFreeRunwayStillGetsItsOwnLine() {
        let line = LiveEdgePolicy.firstServeAccount(
            waitedSeconds: 0.004,
            segmentCount: 30,
            summedDurationSeconds: 30.0,
            targetDuration: 1
        )
        XCTAssertTrue(line.contains("after 0.004s"), line)
        XCTAssertTrue(line.contains("30 segments"), line)
    }

    // MARK: The gate

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

    func testSatisfiedGateAccountsForItsWaitExactlyOnceAcrossRepeatedRequests() {
        let (provider, cache) = makeProvider(allowsBoundedDegradedStart: false)
        defer { cache.close() }
        let tap = Issue374LogTap()
        defer { tap.restore() }

        for index in 0..<15 {
            append(provider, index: index)
        }
        XCTAssertTrue(provider.waitForFirstLiveSegment(timeout: 2))
        // Every /media.m3u8 request without an _HLS_msn re-enters the gate; only the first is a first serve.
        XCTAssertTrue(provider.waitForFirstLiveSegment(timeout: 2))
        XCTAssertTrue(provider.waitForFirstLiveSegment(timeout: 2))

        let accounted = tap.matching("first live manifest")
        XCTAssertEqual(accounted.count, 1, accounted.joined(separator: " | "))
        guard let line = accounted.first else { return XCTFail("no account emitted") }
        XCTAssertTrue(line.contains("15 segments"), line)
    }

    func testBoundedFastZapStartNamesTheWholeWaitAndNotOnlyItsGrace() {
        let (provider, cache) = makeProvider(allowsBoundedDegradedStart: true)
        defer { cache.close() }
        let tap = Issue374LogTap()
        defer { tap.restore() }

        let result = Issue374WaitResult()
        let finished = expectation(description: "startup waiter finished")
        DispatchQueue.global().async {
            result.store(provider.waitForFirstLiveSegment(timeout: 3))
            finished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        append(provider, index: 0)
        append(provider, index: 1)

        wait(for: [finished], timeout: 2)
        XCTAssertEqual(result.value, true)

        let accounted = tap.matching("first live manifest")
        XCTAssertEqual(accounted.count, 1, accounted.joined(separator: " | "))
        guard let line = accounted.first else { return XCTFail("no account emitted") }
        // The bounded path used to report its 0.5s grace and nothing else, which is the last leg of the
        // wait rather than the wait: the total is what a host budgets against.
        XCTAssertTrue(line.contains("bounded start"), line)
        XCTAssertTrue(line.contains("grace"), line)
        guard let held = Self.heldSeconds(in: line) else {
            return XCTFail("no interval in \(line)")
        }
        XCTAssertGreaterThan(held, 0.3)
    }

    func testAGateThatNeverCutASegmentSaysSoRatherThanReturningInSilence() {
        let (provider, cache) = makeProvider(allowsBoundedDegradedStart: false)
        defer { cache.close() }
        let tap = Issue374LogTap()
        defer { tap.restore() }

        XCTAssertFalse(provider.waitForFirstLiveSegment(timeout: 0.2))

        let accounted = tap.matching("first live manifest")
        XCTAssertEqual(accounted.count, 1, accounted.joined(separator: " | "))
        guard let line = accounted.first else { return XCTFail("no account emitted") }
        XCTAssertTrue(line.contains("no segment"), line)
    }

    /// Pulls the `after <x>s` interval back out of the line, so the assertion is about the number the
    /// engine reported rather than about the sentence around it.
    private static func heldSeconds(in line: String) -> Double? {
        guard let range = line.range(of: "after ") else { return nil }
        let tail = line[range.upperBound...]
        guard let end = tail.firstIndex(of: "s") else { return nil }
        return Double(tail[tail.startIndex..<end])
    }
}
