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

    // MARK: - Pump-exit classification

    func testHostRetuneExitsHaltLiveProduction() {
        XCTAssertTrue(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .segmentStall, sourceReopenableByURL: true),
            "cutter wedge exits to host retune; the provider will never cut again")
        XCTAssertTrue(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .sourceReplay, sourceReopenableByURL: true))
        XCTAssertTrue(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .eof, sourceReopenableByURL: false),
            "custom-reader pump death delegates to host retune")
        XCTAssertTrue(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .readError(code: -5), sourceReopenableByURL: false))
    }

    func testRecoverableExitsDoNotHaltLiveProduction() {
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .eof, sourceReopenableByURL: true),
            "reopenable URL exits resume cutting into the same provider")
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .readError(code: -5), sourceReopenableByURL: true))
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .keyframeStarvation, sourceReopenableByURL: true))
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .stopRequested, sourceReopenableByURL: false))
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .muxerFailed, sourceReopenableByURL: false))
        XCTAssertFalse(HLSVideoEngine.shouldHaltLiveProduction(
            reason: .backpressureWedge, sourceReopenableByURL: false))
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
        DispatchQueue.global().async {
            // The reporter's shape: playlist ends at segment 11, AVPlayer holds ?_HLS_msn=12.
            box.value = provider.waitForLiveSegment(index: 12, timeout: 10)
            released.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)  // let the waiter park
        provider.markLiveProductionHalted()
        wait(for: [released], timeout: 2.0)
        XCTAssertFalse(box.value, "released waiter must report the segment as unavailable, well before its 10s timeout")
        XCTAssertFalse(provider.liveBlockingReloadEnabled,
                       "halted session must stop advertising CAN-BLOCK-RELOAD, beating the host override")
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
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success, "request to \(url) timed out")
        if let error = box.error { throw error }
        return (box.status, box.body)
    }

    func testUnsatisfiedHeldBlockingReloadReturns503() throws {
        let provider = ScriptedLiveHoldProvider(count: 3, blockingReload: true, holdSatisfied: false)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }
        let result = try fetch(URL(string: "http://127.0.0.1:\(server.port)/media.m3u8?_HLS_msn=99")!)
        XCTAssertEqual(result.status, 503,
                       "a held blocking reload that cannot be satisfied must 503 (retriable), never serve the unchanged playlist (-15410)")
    }

    func testSatisfiedHeldBlockingReloadServesPlaylist() throws {
        let provider = ScriptedLiveHoldProvider(count: 3, blockingReload: true, holdSatisfied: true)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }
        let result = try fetch(URL(string: "http://127.0.0.1:\(server.port)/media.m3u8?_HLS_msn=2")!)
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
        let result = try fetch(URL(string: "http://127.0.0.1:\(server.port)/media.m3u8?_HLS_msn=99")!)
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
