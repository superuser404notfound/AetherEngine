// Tests/AetherEngineTests/Issue684JoinBoundSealTests.swift
// AE#684: the seal over the upstream segment, as far as the join can pay for it.
//
// The join is three upstream segments on anything longer than about 5 s and is not deepened for the
// seal. Three 6 s segments are 18 s joined; the last GOP stays open until the next upstream delivery,
// so 16 s are cut, and the 18 s holdback of a TARGETDURATION 6 is not reachable from the join at all.
// Waiting for it is waiting for the next upstream segment: measured 4.25 s to first picture where
// 7.25.1 took 0.18 s. A join that has handed over everything it will seals the largest value its cut
// content covers, between what the seal was without the upstream term and the full one.
//
// "Has handed over everything" is a fact the reader states. Round 1 derived it from EXTINF sums with
// a tolerance, and a playlist whose EXTINF over-reports its media (6.3 for 6 s, measured in review)
// never added up: TD 7, a 21 s holdback, bounded start after the grace, 2.23 s to first picture.
import XCTest
@testable import AetherEngine

private final class JoinedUpstream: @unchecked Sendable {
    var segmentDuration: Double?
    var joinBacklog: Double?
    var joinSpent: Bool?
}

final class Issue684JoinBoundSealTests: XCTestCase {

    private func makeProvider(_ upstream: JoinedUpstream, cutTarget: Double,
                              boundedStart: Bool) -> (VideoSegmentProvider, SegmentCache) {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        let policy = LiveCadencePolicy(
            observe: { 0.1 },
            cutTargetSeconds: cutTarget,
            observeSealEvidence: {
                LiveCadenceEvidence(closedCadenceSeconds: nil,
                                    servedSegmentDurationSeconds: upstream.segmentDuration,
                                    joinBacklogSeconds: upstream.joinBacklog,
                                    joinIsSpent: upstream.joinSpent)
            },
            selfReportedTargetDurationSeconds: upstream.segmentDuration,
            clock: { 0 }
        )
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
            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: cutTarget, dvrWindowSeconds: nil),
            allowsBoundedDegradedStart: boundedStart,
            liveCadencePolicy: policy
        )
        return (provider, cache)
    }

    private func append(_ provider: VideoSegmentProvider, count: Int, each: Double) {
        for index in 0..<count {
            provider.appendLiveSegment(index: index, startSeconds: Double(index) * each, durationSeconds: each)
        }
    }

    private func seconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now()
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// The reviewer's shape: three 6 s segments, fastZap, eight 2 s GOPs cut.
    func testShallowFastZapJoinServesAtOnceOnTheSealItCanPay() {
        let upstream = JoinedUpstream()
        upstream.segmentDuration = 6.0
        upstream.joinBacklog = 18.0
        upstream.joinSpent = true
        let (provider, cache) = makeProvider(upstream, cutTarget: 0.5, boundedStart: true)
        defer { cache.close() }
        append(provider, count: 8, each: 2.0)

        var served = false
        let waited = seconds { served = provider.waitForFirstLiveSegment(timeout: 5) }
        XCTAssertTrue(served)
        XCTAssertLessThan(waited, 0.5, "no grace: the join has nothing more to give")
        let td = provider.liveTargetDurationSeconds(maxSegmentDuration: 2.0)
        XCTAssertEqual(td, 5, "16 s of window pays for 5, between the old 4 and the full 6")
        XCTAssertLessThanOrEqual(LiveEdgePolicy.holdBackSeconds(targetDuration: td), 16.0,
                                 "and the holdback it advertises is one the window holds")
    }

    /// A join that does cover the full holdback pays in full (the reporting channel's own shape:
    /// 6 s and 4 s segments alternating, four joined, 18 s cut or more).
    func testAJoinThatCoversTheHoldbackKeepsTheFullSeal() {
        let upstream = JoinedUpstream()
        upstream.segmentDuration = 6.0
        upstream.joinBacklog = 24.0
        upstream.joinSpent = true
        let (provider, cache) = makeProvider(upstream, cutTarget: 0.5, boundedStart: true)
        defer { cache.close() }
        append(provider, count: 11, each: 2.0)
        XCTAssertTrue(provider.waitForFirstLiveSegment(timeout: 5))
        XCTAssertEqual(provider.liveTargetDurationSeconds(maxSegmentDuration: 2.0), 6)
    }

    /// A join still arriving is not spent: the gate keeps waiting for the cushion, as before.
    func testAJoinStillArrivingIsNotSealedShort() {
        let upstream = JoinedUpstream()
        upstream.segmentDuration = 6.0
        upstream.joinBacklog = 24.0
        upstream.joinSpent = false
        let (provider, cache) = makeProvider(upstream, cutTarget: 0.5, boundedStart: false)
        defer { cache.close() }
        append(provider, count: 5, each: 2.0)
        let derivation = provider.firstServeTargetDuration((count: 5, summed: 10.0, maxDuration: 2.0), joinIsSpent: upstream.joinSpent)
        XCTAssertEqual(derivation.value, 6)
        XCTAssertNil(derivation.joinBound)
    }

    /// `.standard` on a 10 s provider listing three segments: 4 s cuts, 28 s of them. It has no
    /// bounded start, so without this it waits for the next upstream segment, up to 10 s of wall clock.
    func testShallowStandardJoinOnTenSecondSegmentsServesAtOnce() {
        let upstream = JoinedUpstream()
        upstream.segmentDuration = 10.0
        upstream.joinBacklog = 30.0
        upstream.joinSpent = true
        let (provider, cache) = makeProvider(upstream, cutTarget: 4.0, boundedStart: false)
        defer { cache.close() }
        append(provider, count: 7, each: 4.0)

        var served = false
        let waited = seconds { served = provider.waitForFirstLiveSegment(timeout: 5) }
        XCTAssertTrue(served)
        XCTAssertLessThan(waited, 0.5)
        XCTAssertEqual(provider.liveTargetDurationSeconds(maxSegmentDuration: 4.0), 9,
                       "28 s of window pays for 9, between the old 7 and the full 10")
    }

    /// `.standard` on 6 s segments was at 6 before the term and is at 6 with it: nothing to pay down.
    func testStandardOnSixSecondSegmentsIsWhatItWas() {
        let upstream = JoinedUpstream()
        upstream.segmentDuration = 6.0
        upstream.joinBacklog = 18.0
        upstream.joinSpent = true
        let (provider, cache) = makeProvider(upstream, cutTarget: 4.0, boundedStart: false)
        defer { cache.close() }
        append(provider, count: 4, each: 4.0)
        let derivation = provider.firstServeTargetDuration((count: 4, summed: 16.0, maxDuration: 4.0), joinIsSpent: upstream.joinSpent)
        XCTAssertEqual(derivation.value, 6)
        XCTAssertNil(derivation.joinBound)
    }

    // MARK: - EXTINF and media need not agree

    /// The re-review's shape: 6 s of media per segment listed as 6.3 (advertised 7). EXTINF says
    /// 18.9 s were joined; 16 s are cut and nothing more is coming. Arithmetic on the sum (16 + 2 +
    /// tolerance against 18.9) said "still arriving" and sealed the full 7.
    func testInflatedExtinfStillSealsWhatTheJoinPays() {
        let upstream = JoinedUpstream()
        upstream.segmentDuration = 6.3
        upstream.joinBacklog = 18.9
        upstream.joinSpent = true
        let (provider, cache) = makeProvider(upstream, cutTarget: 0.5, boundedStart: true)
        defer { cache.close() }
        append(provider, count: 8, each: 2.0)

        var served = false
        let waited = seconds { served = provider.waitForFirstLiveSegment(timeout: 5) }
        XCTAssertTrue(served)
        XCTAssertLessThan(waited, 0.5)
        XCTAssertEqual(provider.liveTargetDurationSeconds(maxSegmentDuration: 2.0), 5,
                       "what 7.25.1 sealed here too: ceil(6.3 / 1.5)")
    }

    /// The other way round: the media runs longer than its EXTINF says. The sum is already reached
    /// (16 + 2 against 18) while the reader is still handing media over, so the arithmetic called
    /// the join exhausted and would have sealed short of what the rest of it pays for.
    func testMediaLongerThanExtinfIsNotSealedBeforeTheJoinIsSpent() {
        let upstream = JoinedUpstream()
        upstream.segmentDuration = 6.0
        upstream.joinBacklog = 18.0
        upstream.joinSpent = false
        let (provider, cache) = makeProvider(upstream, cutTarget: 0.5, boundedStart: false)
        defer { cache.close() }
        append(provider, count: 8, each: 2.0)
        let arriving = provider.firstServeTargetDuration((count: 8, summed: 16.0, maxDuration: 2.0), joinIsSpent: upstream.joinSpent)
        XCTAssertEqual(arriving.value, 6)
        XCTAssertNil(arriving.joinBound)

        // One more GOP lands, the reader runs dry: 18 s cut pays for the full 6.
        provider.appendLiveSegment(index: 8, startSeconds: 16.0, durationSeconds: 2.0)
        upstream.joinSpent = true
        XCTAssertTrue(provider.waitForFirstLiveSegment(timeout: 5))
        XCTAssertEqual(provider.liveTargetDurationSeconds(maxSegmentDuration: 2.0), 6)
    }

    /// The gate has no event for "the cutter parked on an empty reader", so it has to look again by
    /// itself: a join that turns spent while a request is waiting is served then, not at the grace.
    func testAWaitingRequestIsServedWhenTheJoinTurnsSpent() {
        let upstream = JoinedUpstream()
        upstream.segmentDuration = 10.0
        upstream.joinBacklog = 30.0
        upstream.joinSpent = false
        let (provider, cache) = makeProvider(upstream, cutTarget: 4.0, boundedStart: false)
        defer { cache.close() }
        append(provider, count: 7, each: 4.0)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.2)
            upstream.joinSpent = true
        }
        var served = false
        let waited = seconds { served = provider.waitForFirstLiveSegment(timeout: 5) }
        XCTAssertTrue(served)
        XCTAssertGreaterThanOrEqual(waited, 0.15)
        XCTAssertLessThan(waited, 1.5, "not the 5 s deadline: the gate noticed")
        XCTAssertEqual(provider.liveTargetDurationSeconds(maxSegmentDuration: 4.0), 9)
    }

    /// The reader's half of the fact: nothing queued and its consumer parked.
    func testAnEmptyFIFOWithAParkedReaderIsTheSpentSignal() {
        let fifo = ByteFIFO(capacity: 1024)
        XCTAssertFalse(fifo.isEmptyWithReaderParked, "nobody is reading")
        XCTAssertTrue(fifo.write(Data([1, 2, 3])))
        XCTAssertFalse(fifo.isEmptyWithReaderParked, "bytes are waiting")
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
        defer { buffer.deallocate() }
        XCTAssertEqual(fifo.read(into: buffer, maxLength: 16), 3)
        XCTAssertFalse(fifo.isEmptyWithReaderParked, "drained, but the consumer has not come back for more")
        let done = expectation(description: "reader returned")
        Thread.detachNewThread {
            let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
            _ = fifo.read(into: scratch, maxLength: 16)
            scratch.deallocate()
            done.fulfill()
        }
        while fifo.parkedWaiterCount == 0 { usleep(200) }
        XCTAssertTrue(fifo.isEmptyWithReaderParked)
        fifo.cancel()
        wait(for: [done], timeout: 300)
        XCTAssertFalse(fifo.isEmptyWithReaderParked, "a cancelled reader is not a spent join")
    }

    /// The seal line says what was paid and what was asked, and the drift line names the term too.
    func testSealAccountStatesWhatTheJoinPaid() {
        var derivation = LiveTargetDurationDerivation(
            value: 5, maxSegmentDuration: 2.0, cutTargetFloor: 0.5,
            cadenceFloor: .measured(6.0), upstreamSegment: 6.0, selfReported: 6.0)
        derivation.joinBound = (backlogSeconds: 18.0, finalizedSeconds: 16.0, full: 6)
        let account = derivation.account
        XCTAssertTrue(account.contains("sealed at 5s (holdback 15.000s)"), account)
        XCTAssertTrue(account.contains("upstream segment 6.000s"), account)
        XCTAssertTrue(account.contains("of which the join pays 5s of 6s (16.000s cut of the 18.000s it listed)"),
                      account)
    }
}
