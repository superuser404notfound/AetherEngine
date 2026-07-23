// Tests/AetherEngineTests/Issue199RerouteRecoveryTests.swift
// AetherEngine#199: a #168-rerouted live-ingest session that died (looped-pool MSN reset, CDN gap,
// encoder restart) used to reland on the known-bad native bypass every time the host retuned, because
// (a) the no-video-track carriage verdict was discovered per mount and thrown away, and (b) the
// engine-created ingest reader had no in-engine reopen path (every pump exit delegated to host retune).
// These tests pin the verdict memory, the direct-to-ingest load routing, the reopen transport decision,
// and the fresh-reader factory.
import XCTest
@testable import AetherEngine

final class Issue199RerouteRecoveryTests: XCTestCase {

    // MARK: - Reroute verdict memory

    private let base = Date(timeIntervalSince1970: 1_000_000)
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testRecordedMasterIsRemembered() {
        var memory = RerouteVerdictMemory()
        memory.record(url("http://origin/live/master.m3u8"), now: base)
        XCTAssertTrue(memory.remembers(url("http://origin/live/master.m3u8"), now: base))
        XCTAssertFalse(memory.remembers(url("http://origin/live/other.m3u8"), now: base),
                       "verdicts are per exact URL; a different channel must not inherit them")
    }

    func testEntryExpiresAfterTTL() {
        var memory = RerouteVerdictMemory(capacity: 32, ttl: 60)
        memory.record(url("http://origin/live/master.m3u8"), now: base)
        XCTAssertTrue(memory.remembers(url("http://origin/live/master.m3u8"), now: base.addingTimeInterval(59)))
        XCTAssertFalse(memory.remembers(url("http://origin/live/master.m3u8"), now: base.addingTimeInterval(61)),
                       "an origin that fixes its packaging must not stay exiled from the native bypass")
    }

    func testCapacityEvictsOldestEntry() {
        var memory = RerouteVerdictMemory(capacity: 2, ttl: 3600)
        memory.record(url("http://a/1.m3u8"), now: base)
        memory.record(url("http://a/2.m3u8"), now: base.addingTimeInterval(1))
        memory.record(url("http://a/3.m3u8"), now: base.addingTimeInterval(2))
        XCTAssertFalse(memory.remembers(url("http://a/1.m3u8"), now: base.addingTimeInterval(3)),
                       "capacity overflow evicts the oldest verdict")
        XCTAssertTrue(memory.remembers(url("http://a/2.m3u8"), now: base.addingTimeInterval(3)))
        XCTAssertTrue(memory.remembers(url("http://a/3.m3u8"), now: base.addingTimeInterval(3)))
    }

    func testRerecordRefreshesEntryAge() {
        var memory = RerouteVerdictMemory(capacity: 2, ttl: 3600)
        memory.record(url("http://a/1.m3u8"), now: base)
        memory.record(url("http://a/2.m3u8"), now: base.addingTimeInterval(1))
        memory.record(url("http://a/1.m3u8"), now: base.addingTimeInterval(2)) // re-fire refreshes 1
        memory.record(url("http://a/3.m3u8"), now: base.addingTimeInterval(3))
        XCTAssertTrue(memory.remembers(url("http://a/1.m3u8"), now: base.addingTimeInterval(4)))
        XCTAssertFalse(memory.remembers(url("http://a/2.m3u8"), now: base.addingTimeInterval(4)),
                       "with 1 refreshed, 2 is now the oldest and gets evicted")
    }

    // MARK: - Direct-to-ingest load routing

    func testKnownVerdictRoutesDirectlyToIngest() {
        XCTAssertTrue(RemoteHLSIngestFallback.shouldRouteDirectlyToIngest(
            isLive: true, fallbackEnabled: true, verdictRemembered: true))
    }

    func testDirectRouteRespectsWatchdogGates() {
        XCTAssertFalse(RemoteHLSIngestFallback.shouldRouteDirectlyToIngest(
            isLive: false, fallbackEnabled: true, verdictRemembered: true),
            "VOD remote HLS is the AE#154 reroute target; ingesting it back would ping-pong")
        XCTAssertFalse(RemoteHLSIngestFallback.shouldRouteDirectlyToIngest(
            isLive: true, fallbackEnabled: false, verdictRemembered: true),
            "hosts that opted out of the fallback must never be silently rerouted")
        XCTAssertFalse(RemoteHLSIngestFallback.shouldRouteDirectlyToIngest(
            isLive: true, fallbackEnabled: true, verdictRemembered: false))
    }

    // MARK: - Reopen transport decision

    func testURLSourcesReopenByURL() {
        XCTAssertEqual(HLSVideoEngine.liveReopenTransport(
            sourceReopenableByURL: true, hasCustomSourceReopenFactory: false), .url)
    }

    func testEngineCreatedIngestSourcesReopenViaFactory() {
        XCTAssertEqual(HLSVideoEngine.liveReopenTransport(
            sourceReopenableByURL: false, hasCustomSourceReopenFactory: true), .customFactory)
    }

    func testHostProvidedCustomSourcesCannotReopen() {
        XCTAssertEqual(HLSVideoEngine.liveReopenTransport(
            sourceReopenableByURL: false, hasCustomSourceReopenFactory: false), .none)
    }

    // MARK: - Fresh-reader factory

    func testMainVideoReaderVendsFreshIndependentReader() {
        let reader = HLSLiveIngestReader(playlistURL: url("http://origin/live/master.m3u8"),
                                         httpHeaders: ["Referer": "http://origin/"])
        defer { reader.close() }
        let fresh = reader.makeFreshMainReader()
        XCTAssertNotNil(fresh)
        XCTAssertTrue(fresh !== reader, "factory must vend a fresh reader, not the dead one")
        fresh?.close()
    }

    func testCompanionAudioReaderDoesNotVendFreshReader() {
        let companion = HLSLiveIngestReader(playlistURL: url("http://origin/live/audio.m3u8"),
                                            httpHeaders: [:], role: .companionAudio)
        defer { companion.close() }
        XCTAssertNil(companion.makeFreshMainReader(),
                     "only the main video reader owns the session's reopen identity")
    }
}
