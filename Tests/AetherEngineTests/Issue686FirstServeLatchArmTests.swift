// AE#686: on a source the engine cuts itself (raw MPEG-TS under fastZap) a bounded start holds
// AVPlayer's second plain `/media.m3u8` request for a second grace, measured on an Apple TV as
// 1.015 to 1.384 s on every bounded start. #684 latched the gate for ingest sessions only, because
// whether the engine-cut path pays for skipping that wait (a session closer to the producing edge)
// was never measured. The Apple TV A/B showed it does not, so the latch is now on by default and
// `AETHER_FIRST_SERVE_LATCH_ALL=0` is the opt-out.
import XCTest
@testable import AetherEngine

final class Issue686FirstServeLatchArmTests: XCTestCase {

    private func makeProvider(latchArm: Bool) -> (VideoSegmentProvider, SegmentCache) {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: [],
            codecsString: "avc1.4D001E,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (720, 576),
            videoRange: .sdr,
            frameRate: 25,
            hdcpLevel: nil,
            sourceBitrate: 1_500_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: nil),
            allowsBoundedDegradedStart: true,
            // The grace these cases exercise. The default is 0 since the live start measurements of 2026-11-19.
            startupGraceSeconds: 0.5,
            firstServeLatchCoversEngineCut: latchArm
        )
        return (provider, cache)
    }

    private func seconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now()
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    func testTheLatchIsOnUnlessTheEnvironmentOptsOut() {
        XCTAssertEqual(LiveEdgePolicy.firstServeLatchAllArmed,
                       ProcessInfo.processInfo.environment["AETHER_FIRST_SERVE_LATCH_ALL"] != "0")
    }

    /// Two 0.2 s segments against a 3 s holdback: the bounded start, grace 0.5 s.
    func testArmedASelfCutSourceLetsTheSecondRequestThrough() {
        let (provider, cache) = makeProvider(latchArm: true)
        defer { cache.close() }
        provider.appendLiveSegment(index: 0, startSeconds: 0, durationSeconds: 0.2)
        provider.appendLiveSegment(index: 1, startSeconds: 0.2, durationSeconds: 0.2)

        var served = false
        let first = seconds { served = provider.waitForFirstLiveSegment(timeout: 3) }
        XCTAssertTrue(served)
        XCTAssertGreaterThanOrEqual(first, 0.45, "the first request still pays the grace")

        let second = seconds { served = provider.waitForFirstLiveSegment(timeout: 3) }
        XCTAssertTrue(served)
        XCTAssertLessThan(second, 0.2, "the arm latches the gate once a manifest has gone out")
    }

    func testArmedAnUnservedGateStaysAGate() {
        let (provider, cache) = makeProvider(latchArm: true)
        defer { cache.close() }
        XCTAssertFalse(provider.waitForFirstLiveSegment(timeout: 0.1))
        XCTAssertFalse(provider.waitForFirstLiveSegment(timeout: 0.1))
    }

    /// The repeat line is the measurement both arms are compared on, so it must appear in the
    /// unarmed one too, once, with the held interval.
    func testTheRepeatRequestIsAccountedOnceInEitherArm() {
        for armed in [false, true] {
            let (provider, cache) = makeProvider(latchArm: armed)
            defer { cache.close() }
            provider.appendLiveSegment(index: 0, startSeconds: 0, durationSeconds: 0.2)
            provider.appendLiveSegment(index: 1, startSeconds: 0.2, durationSeconds: 0.2)

            let capture = EngineLogCapture()
            defer { capture.end() }

            XCTAssertTrue(provider.waitForFirstLiveSegment(timeout: 3))
            XCTAssertTrue(provider.waitForFirstLiveSegment(timeout: 3))
            let afterSecond = capture.matching("repeat live manifest request held").count
            XCTAssertTrue(provider.waitForFirstLiveSegment(timeout: 3))

            let repeats = capture.matching("repeat live manifest request held")
            XCTAssertGreaterThanOrEqual(afterSecond, 1, "armed=\(armed)")
            XCTAssertEqual(repeats.count, afterSecond, "armed=\(armed): a third request adds no line")
            if armed {
                XCTAssertTrue(repeats.contains { $0.contains("first-serve latch") })
            } else {
                XCTAssertTrue(repeats.contains { $0.contains("fastZap bounded start") })
            }
        }
    }
}
