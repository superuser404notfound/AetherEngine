// Tests/AetherEngineTests/Issue684FirstServeLatchTests.swift
// AE#684 review: on an INGEST the first-serve gate held the second playlist request too. AVPlayer opens
// a session with two `/media.m3u8` requests back to back, each without an `_HLS_msn`, so each re-enters
// the gate. With the cushion satisfied both pass at once. On a bounded start (the window under the
// holdback, served after its grace) the second one waited out a second grace: measured on a
// three-segment 6 s upstream as 2.012 s to the first manifest, then 2.02 s more before `init.mp4`.
//
// Scoped to ingest sessions on purpose. On a source the engine cuts itself (raw MPEG-TS) the second
// grace is part of where the session ends up behind the producing edge: without it the first picture
// comes 2 s sooner and the session sits up to 2 s closer to the edge for its whole life, which nobody
// has measured on a device. That is AE#594's open question, so that path behaves as it did in 7.25.1.
import XCTest
@testable import AetherEngine

final class Issue684FirstServeLatchTests: XCTestCase {

    private func makeProvider(ingest: Bool) -> (VideoSegmentProvider, SegmentCache) {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        let policy = ingest ? LiveCadencePolicy(observe: { 0.1 }, cutTargetSeconds: 0.5, clock: { 0 }) : nil
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
            liveCadencePolicy: policy
        )
        return (provider, cache)
    }

    private func seconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now()
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// Two 0.2 s segments against a 3 s holdback: the bounded start, grace 0.5 s.
    func testOnAnIngestASecondRequestIsNotHeldForASecondGrace() {
        let (provider, cache) = makeProvider(ingest: true)
        defer { cache.close() }
        provider.appendLiveSegment(index: 0, startSeconds: 0, durationSeconds: 0.2)
        provider.appendLiveSegment(index: 1, startSeconds: 0.2, durationSeconds: 0.2)

        var served = false
        let first = seconds { served = provider.waitForFirstLiveSegment(timeout: 3) }
        XCTAssertTrue(served)
        XCTAssertGreaterThanOrEqual(first, 0.45, "the first request pays the grace, as before")

        let second = seconds { served = provider.waitForFirstLiveSegment(timeout: 3) }
        XCTAssertTrue(served)
        XCTAssertLessThan(second, 0.2, "a manifest has gone out; the gate is open")
    }

    /// A source the engine cuts itself keeps 7.25.1's gate: the second request waits its own grace.
    func testOnASelfCutSourceTheSecondRequestStillWaitsItsGrace() {
        let (provider, cache) = makeProvider(ingest: false)
        defer { cache.close() }
        provider.appendLiveSegment(index: 0, startSeconds: 0, durationSeconds: 0.2)
        provider.appendLiveSegment(index: 1, startSeconds: 0.2, durationSeconds: 0.2)

        var served = false
        let first = seconds { served = provider.waitForFirstLiveSegment(timeout: 3) }
        XCTAssertTrue(served)
        XCTAssertGreaterThanOrEqual(first, 0.45)
        let second = seconds { served = provider.waitForFirstLiveSegment(timeout: 3) }
        XCTAssertTrue(served)
        XCTAssertGreaterThanOrEqual(second, 0.45, "unchanged from 7.25.1")
    }

    /// The latch is on a SERVED manifest. A gate that gave up with nothing cut has served none.
    func testAnUnservedGateStaysAGate() {
        let (provider, cache) = makeProvider(ingest: true)
        defer { cache.close() }
        XCTAssertFalse(provider.waitForFirstLiveSegment(timeout: 0.1))
        XCTAssertFalse(provider.waitForFirstLiveSegment(timeout: 0.1))
    }
}
