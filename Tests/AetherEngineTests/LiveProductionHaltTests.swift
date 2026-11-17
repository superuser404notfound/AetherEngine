// Tests/AetherEngineTests/LiveProductionHaltTests.swift
// AetherEngine#167 follow-up: a live session whose LOCAL segment producer stalls (SSAI cutter wedge,
// field log G00380316 2026-07) while blocking-reload is latched ON must (a) answer the held ?_HLS_msn=
// reload with a retriable 503 instead of a spec-invalid unchanged 200 (RFC 8216bis blocking reload;
// AVPlayer -15410 otherwise), and (b) stop advertising CAN-BLOCK-RELOAD for the rest of the session,
// including a client-initiated item reload against the same zombie server. The cadence policy cannot
// see this failure mode: it observes ingest arrivals, which keep flowing while the cutter is wedged.
import XCTest
@testable import AetherEngine

final class LiveProductionHaltTests: XCTestCase {

    // MARK: - Resolver precedence

    func testHaltBeatsOverrideAndPolicy() {
        XCTAssertFalse(
            VideoSegmentProvider.resolveLiveBlockingReload(halted: true, override: true, policy: nil),
            "a dead producer cannot honor blocking-reload no matter what the host forces")
        XCTAssertFalse(
            VideoSegmentProvider.resolveLiveBlockingReload(halted: true, override: nil, policy: nil))
        XCTAssertTrue(
            VideoSegmentProvider.resolveLiveBlockingReload(halted: false, override: nil, policy: nil),
            "non-halted signal-less live keeps the low-latency default")
    }

    // MARK: - Delivery stall (AE#446)

    /// Same policy as the halt above, applied one watchdog earlier. A source that has stopped
    /// delivering cannot satisfy a blocking reload either, and holding the client's poll for
    /// 3 x TARGETDURATION costs it every segment it would otherwise have fetched from the cache.
    func testDeliveryStallBeatsOverrideAndPolicy() {
        XCTAssertFalse(
            VideoSegmentProvider.resolveLiveBlockingReload(
                deliveryStalled: true, override: true, policy: nil),
            "a source that is not delivering cannot honor blocking-reload however loudly the host asks")
        XCTAssertFalse(
            VideoSegmentProvider.resolveLiveBlockingReload(
                deliveryStalled: true, override: nil, policy: nil))
        XCTAssertTrue(
            VideoSegmentProvider.resolveLiveBlockingReload(
                deliveryStalled: false, override: nil, policy: nil),
            "a delivering source keeps the low-latency default")
    }

    func testHaltAndDeliveryStallAreIndependentRoutesToTheSameAnswer() {
        XCTAssertFalse(VideoSegmentProvider.resolveLiveBlockingReload(
            halted: true, deliveryStalled: false, override: true, policy: nil))
        XCTAssertFalse(VideoSegmentProvider.resolveLiveBlockingReload(
            halted: false, deliveryStalled: true, override: true, policy: nil))
    }

    // MARK: - Pump-exit classification

    func testHostRetuneExitsHaltLiveProduction() {
        XCTAssertTrue(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .segmentStall, sourceReopenable: true),
            "cutter wedge exits to host retune; the provider will never cut again")
        XCTAssertTrue(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .sourceReplay, sourceReopenable: false))
        XCTAssertTrue(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .eof, sourceReopenable: false),
            "host-provided custom-reader pump death delegates to host retune")
        XCTAssertTrue(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .readError(code: -5), sourceReopenable: false))
    }

    func testRecoverableExitsDoNotHaltLiveProduction() {
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .sourceReplay, sourceReopenable: true),
            "fresh source continues the retained cache and its exact-packet history")
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .eof, sourceReopenable: true),
            "reopenable exits (URL source, or #199 engine-created ingest reader with a fresh-reader factory) resume cutting into the same provider")
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .readError(code: -5), sourceReopenable: true))
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .keyframeStarvation, sourceReopenable: true))
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .stopRequested, sourceReopenable: false))
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .muxerFailed, sourceReopenable: false),
            "handleLiveMuxerFailure rebuilds the producer into the same provider; an eager halt would 503 the provider the rebuild serves, and the arm halts itself on budget exhaustion")
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .backpressureWedge, sourceReopenable: false))
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .needsAudioSampleEntryPrime, sourceReopenable: false),
            "the AE#222 arm rebuilds into the same provider with a primed muxer (in place for live), so production continues")
    }

    // MARK: - Live recovery budget (shared by the in-place muxer rebuild and the reopen ladder)

    /// Both arms carry their own counter pair but the same decision, and both ship the same cap. Pinned
    /// because the reopen arm ran an untested inline copy of this until the muxer arm needed it too.
    func testBothLiveRecoveryArmsShipTheSameCap() {
        XCTAssertEqual(HLSVideoEngine.maxBarrenReopenCycles, 3)
        XCTAssertEqual(HLSVideoEngine.maxLiveMuxerRebuildCycles, 3)
    }

    func testFirstLiveMuxerDeathAlwaysRebuilds() {
        let d = HLSVideoEngine.liveRecoveryBudgetDecision(
            progressIndex: 414, lastProgressIndex: -1, barrenCycles: 0, cap: 3)
        XCTAssertTrue(d.proceed, "a fresh death at a new continuation point starts a fresh budget")
        XCTAssertEqual(d.newBarrenCycles, 0)
    }

    func testProgressSinceLastDeathResetsTheBudget() {
        let d = HLSVideoEngine.liveRecoveryBudgetDecision(
            progressIndex: 431, lastProgressIndex: 414, barrenCycles: 2, cap: 3)
        XCTAssertTrue(d.proceed,
            "segments were cut since the last death: an hours-long channel crossing several encoder restarts must not exhaust a session-lifetime budget")
        XCTAssertEqual(d.newBarrenCycles, 0)
    }

    func testConsecutiveBarrenDeathsExhaustTheBudget() {
        var cycles = 0
        var last = -1
        var rebuilds = 0
        // Death after death at the same continuation point: nothing was ever produced in between.
        for _ in 0..<10 {
            let d = HLSVideoEngine.liveRecoveryBudgetDecision(
                progressIndex: 414, lastProgressIndex: last, barrenCycles: cycles, cap: 3)
            cycles = d.newBarrenCycles
            last = 414
            if d.proceed { rebuilds += 1 } else { break }
        }
        XCTAssertEqual(rebuilds, 3,
            "exactly the cap's worth of barren rebuilds, then halt + host retune, never an endless rebuild storm against an unmuxable source")
    }

    // MARK: - Provider halt latch

    private func segments(_ n: Int) -> [HLSVideoEngine.Segment] {
        (0..<n).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
    }

    func testMarkHaltDropsAdvertAndReleasesHeldWaiter() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let provider = VideoSegmentProvider(
            cache: cache, segments: segments(12), codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 25.0, hdcpLevel: nil,
            sourceBitrate: 8_000_000, isLive: true,
            blockingReloadOverride: true)
        XCTAssertTrue(provider.liveBlockingReloadEnabled, "override ON before the halt")

        final class ResultBox: @unchecked Sendable { var value = true }
        let box = ResultBox()
        let released = expectation(description: "held blocking-reload waiter released")
        Thread.detachNewThread {
            // The reporter's shape: playlist ends at segment 11, AVPlayer holds ?_HLS_msn=12.
            // A timeout out of reach, so only the halt can release it.
            box.value = provider.waitForLiveSegment(index: 12, timeout: 600)
            released.fulfill()
        }
        while provider.parkedWaiterCount == 0 { usleep(200) }  // the park, not a guess at it
        provider.markLiveProductionHalted()
        wait(for: [released], timeout: 300)
        XCTAssertFalse(box.value, "released waiter must report the segment as unavailable, well before its own timeout")
        XCTAssertFalse(provider.liveBlockingReloadEnabled,
                       "halted session must stop advertising CAN-BLOCK-RELOAD, beating the host override")
    }

    /// Audit HLS-203: a host retry resumes production, and the next blocking reload must hold again.
    func testResumeLetsALiveHoldWaitAgainAfterAHalt() {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        let provider = VideoSegmentProvider(
            cache: cache, segments: segments(12), codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 25.0, hdcpLevel: nil,
            sourceBitrate: 8_000_000, isLive: true,
            blockingReloadOverride: true)
        provider.markLiveProductionHalted()
        XCTAssertFalse(provider.waitForLiveSegment(index: 12, timeout: 600), "halted: answers at once")
        provider.resumeLiveProduction()

        final class ResultBox: @unchecked Sendable { var value = false }
        let box = ResultBox()
        let released = expectation(description: "resumed hold released by the new segment")
        Thread.detachNewThread {
            box.value = provider.waitForLiveSegment(index: 12, timeout: 600)
            released.fulfill()
        }
        while provider.parkedWaiterCount == 0 { usleep(200) }
        provider.appendLiveSegment(index: 12, startSeconds: 48, durationSeconds: 4)
        wait(for: [released], timeout: 300)
        XCTAssertTrue(box.value, "after resume the hold waits for the segment instead of answering at once")
    }

    // MARK: - Server 503 on unsatisfiable held reload (socket level)

    private func fetch(_ url: URL) throws -> (status: Int, body: String) {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var status = -1
            var body = ""
            var error: Error?
        }
        let box = Box()
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            box.error = error
            box.status = (response as? HTTPURLResponse)?.statusCode ?? -1
            box.body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            semaphore.signal()
        }
        task.resume()
        XCTAssertEqual(semaphore.wait(timeout: .now() + 120), .success, "request to \(url) timed out")
        if let error = box.error { throw error }
        return (box.status, box.body)
    }

    func testUnsatisfiedHeldBlockingReloadReturns503() throws {
        let provider = ScriptedLiveHoldProvider(count: 3, blockingReload: true, holdSatisfied: false)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }
        let result = try fetch(URL(string: "http://127.0.0.1:\(server.port)/\(server.pathToken)/media.m3u8?_HLS_msn=99")!)
        XCTAssertEqual(result.status, 503,
                       "a held blocking reload that cannot be satisfied must 503 (retriable), never serve the unchanged playlist (-15410)")
    }

    func testSatisfiedHeldBlockingReloadServesPlaylist() throws {
        let provider = ScriptedLiveHoldProvider(count: 3, blockingReload: true, holdSatisfied: true)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }
        let result = try fetch(URL(string: "http://127.0.0.1:\(server.port)/\(server.pathToken)/media.m3u8?_HLS_msn=2")!)
        XCTAssertEqual(result.status, 200)
        XCTAssertTrue(result.body.contains("#EXTM3U"), "satisfied hold serves the playlist as before")
    }

    func testGateOffMsnRequestServesImmediatelyWithoutHolding() throws {
        // Field-proven 5.16.0 path: gate OFF ignores the directive and serves plainly; it must not
        // start holding (or 503ing) now that unsatisfied holds are refused.
        let provider = ScriptedLiveHoldProvider(count: 3, blockingReload: false, holdSatisfied: false)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }
        let result = try fetch(URL(string: "http://127.0.0.1:\(server.port)/\(server.pathToken)/media.m3u8?_HLS_msn=99")!)
        XCTAssertEqual(result.status, 200)
        XCTAssertTrue(result.body.contains("#EXTM3U"))
        XCTAssertEqual(provider.holdCalls, 0, "gate OFF must never park the request in waitForLiveSegment")
    }
}

/// Minimal live provider with a scripted waitForLiveSegment outcome, so the server's held-reload
/// response shape can be pinned over a real socket without a producer.
private final class ScriptedLiveHoldProvider: HLSSegmentProvider, @unchecked Sendable {
    let count: Int
    let blockingReload: Bool
    let holdSatisfied: Bool
    private let lock = NSLock()
    private var _holdCalls = 0
    var holdCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _holdCalls
    }

    init(count: Int, blockingReload: Bool, holdSatisfied: Bool) {
        self.count = count
        self.blockingReload = blockingReload
        self.holdSatisfied = holdSatisfied
    }

    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { count }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .live }
    var liveTargetSegmentDuration: Double? { 4.0 }
    var liveBlockingReloadEnabled: Bool { blockingReload }
    var liveTargetDurationFloorSeconds: Double? { nil }

    func waitForLiveSegment(index: Int, timeout: TimeInterval) -> Bool {
        lock.lock()
        _holdCalls += 1
        lock.unlock()
        return holdSatisfied
    }
    func waitForFirstLiveSegment(timeout: TimeInterval) -> Bool { true }

    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int) {
        (count, 0, 1, false, 0)
    }
}
