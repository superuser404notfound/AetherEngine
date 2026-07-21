// Tests/AetherEngineTests/LiveCadencePolicyTests.swift
// AetherEngine#167: LL-HLS blocking-reload eligibility and the TARGETDURATION floor must derive from the
// OBSERVED upstream arrival cadence, not the upstream's self-reported EXT-X-TARGETDURATION. Pins the
// cadence meter, the latch state machine, and the server-manifest shaping that consumes them.
import XCTest
@testable import AetherEngine

/// Scriptable observe/clock backing so tests drive exact (cadence, now) sequences into the policy.
private final class ScriptedCadence: @unchecked Sendable {
    var now: Double = 0
    var cadence: Double?
}

final class LiveCadencePolicyTests: XCTestCase {

    // MARK: - LiveArrivalCadenceMeter

    func testMeterIsNilBeforeAnyArrival() {
        let meter = LiveArrivalCadenceMeter()
        XCTAssertNil(meter.observedCadence(at: 5))
    }

    func testMeterOpenGapGrowsEstimateBeforeNextArrival() throws {
        var meter = LiveArrivalCadenceMeter()
        meter.recordArrival(at: 0)
        XCTAssertEqual(try XCTUnwrap(meter.observedCadence(at: 0.5)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(meter.observedCadence(at: 3)), 3, accuracy: 1e-9)
    }

    func testMeterClosedIntervalIsRememberedAsRecentMax() throws {
        var meter = LiveArrivalCadenceMeter()
        meter.recordArrival(at: 0)
        meter.recordArrival(at: 4)          // disciplined 4s interval
        XCTAssertEqual(try XCTUnwrap(meter.observedCadence(at: 4)), 4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(meter.observedCadence(at: 5)), 4, accuracy: 1e-9) // ongoing 1s < closed 4s
        meter.recordArrival(at: 24)         // a 20s bursty inter-batch gap
        XCTAssertEqual(try XCTUnwrap(meter.observedCadence(at: 24)), 20, accuracy: 1e-9)
    }

    func testMeterRecentWindowForgetsOldGaps() throws {
        var meter = LiveArrivalCadenceMeter()
        var t = 0.0
        meter.recordArrival(at: t)
        t += 30; meter.recordArrival(at: t)          // one 30s outlier
        // Nine disciplined 4s arrivals push the outlier out of the trailing window.
        for _ in 0..<9 { t += 4; meter.recordArrival(at: t) }
        XCTAssertEqual(try XCTUnwrap(meter.observedCadence(at: t)), 4, accuracy: 1e-9)
    }

    // MARK: - LiveCadencePolicy gate latch

    private func makePolicy(_ s: ScriptedCadence, cutTarget: Double = 4, discipline: Double = 12, floor: Double? = 6) -> LiveCadencePolicy {
        LiveCadencePolicy(
            observe: { s.cadence },
            cutTargetSeconds: cutTarget,
            disciplineObservationSeconds: discipline,
            initialFloorSeconds: floor,
            clock: { s.now }
        )
    }

    func testBurstySourceNeverEnablesBlockingReload() {
        let s = ScriptedCadence()
        let policy = makePolicy(s)
        s.now = 0; s.cadence = 0
        XCTAssertFalse(policy.blockingReloadEnabled, "starts OFF until discipline proven")
        s.now = 7; s.cadence = 7                       // open gap exceeds 1.5x cut target (6s)
        XCTAssertFalse(policy.blockingReloadEnabled, "latched bursty")
        s.now = 25; s.cadence = 20                     // a real 20s inter-batch interval closed
        XCTAssertFalse(policy.blockingReloadEnabled)
        s.now = 60; s.cadence = 4                      // clean cadence afterwards cannot un-latch
        XCTAssertFalse(policy.blockingReloadEnabled, "bursty is terminal")
    }

    func testBurstyFloorTracksWorstObservedGapMonotonically() {
        let s = ScriptedCadence()
        let policy = makePolicy(s)
        s.now = 0; s.cadence = 0
        XCTAssertEqual(policy.targetDurationFloorSeconds, 6)   // seeded by self-reported TD lower bound
        s.now = 25; s.cadence = 20
        XCTAssertEqual(policy.targetDurationFloorSeconds, 20)  // widened to the real gap
        s.now = 60; s.cadence = 4
        XCTAssertEqual(policy.targetDurationFloorSeconds, 20)  // never shrinks back
    }

    func testDisciplinedSourceLatchesOnAfterObservationWindow() {
        let s = ScriptedCadence()
        let policy = makePolicy(s)
        s.now = 0; s.cadence = 0
        XCTAssertFalse(policy.blockingReloadEnabled)
        s.now = 5; s.cadence = 4
        XCTAssertFalse(policy.blockingReloadEnabled, "only 5s of clean observation")
        s.now = 13; s.cadence = 4
        XCTAssertTrue(policy.blockingReloadEnabled, "12s of sustained discipline earns blocking-reload")
        s.now = 30; s.cadence = 5
        XCTAssertTrue(policy.blockingReloadEnabled)
    }

    func testDisciplinedThenBurstyLatchesOffTerminally() {
        let s = ScriptedCadence()
        let policy = makePolicy(s)
        s.now = 0; s.cadence = 4
        _ = policy.blockingReloadEnabled                // anchor the observation window at session start
        s.now = 13; s.cadence = 4
        XCTAssertTrue(policy.blockingReloadEnabled)
        s.now = 20; s.cadence = 9                       // a burst after going ON
        XCTAssertFalse(policy.blockingReloadEnabled, "single ON -> OFF, terminal")
        s.now = 40; s.cadence = 4
        XCTAssertFalse(policy.blockingReloadEnabled)
    }

    func testNoObservationYetKeepsBlockingReloadOff() {
        let s = ScriptedCadence()          // cadence stays nil (no arrival observed)
        let policy = makePolicy(s, floor: nil)
        s.now = 100
        XCTAssertFalse(policy.blockingReloadEnabled)
        XCTAssertNil(policy.targetDurationFloorSeconds)
    }

    // MARK: - Provider override precedence

    func testOverrideForcesGateRegardlessOfPolicy() {
        let s = ScriptedCadence()
        s.now = 0; s.cadence = 0
        let bursty = makePolicy(s)
        s.now = 7; s.cadence = 7
        _ = bursty.blockingReloadEnabled                 // latch it bursty (OFF)
        XCTAssertTrue(VideoSegmentProvider.resolveLiveBlockingReload(override: true, policy: bursty),
                      "host override ON wins over an observed-bursty policy")
        XCTAssertFalse(VideoSegmentProvider.resolveLiveBlockingReload(override: false, policy: nil),
                       "host override OFF wins for a signal-less source")
    }

    func testSignallessSourceDefaultsBlockingReloadOn() {
        XCTAssertTrue(VideoSegmentProvider.resolveLiveBlockingReload(override: nil, policy: nil),
                      "plain-url live (Jellyfin transcode) keeps low-latency blocking-reload by default")
    }

    // MARK: - Manifest shaping via the server

    private func lines(_ playlist: String) -> [String] {
        playlist.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func testBurstyProviderOmitsBlockingReloadAndRaisesTargetDuration() {
        let provider = ScriptedManifestProvider(count: 5, blockingReload: false, floor: 20)
        let ls = lines(HLSLocalServer.buildMediaPlaylistText(provider: provider))
        XCTAssertFalse(ls.contains("#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES"),
                       "bursty ingest must not advertise blocking-reload (-15410)")
        XCTAssertTrue(ls.contains("#EXT-X-TARGETDURATION:20"),
                      "TARGETDURATION floor must cover the observed inter-batch gap (anti -12888)")
    }

    func testDisciplinedProviderAdvertisesBlockingReload() {
        let provider = ScriptedManifestProvider(count: 5, blockingReload: true, floor: nil)
        let ls = lines(HLSLocalServer.buildMediaPlaylistText(provider: provider))
        XCTAssertTrue(ls.contains("#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES"))
    }
}

/// Minimal live provider whose blocking-reload / TARGETDURATION-floor decisions are injected, so the
/// server manifest shaping can be pinned independently of the cadence policy plumbing.
private final class ScriptedManifestProvider: HLSSegmentProvider, @unchecked Sendable {
    let count: Int
    let blockingReload: Bool
    let floor: Double?

    init(count: Int, blockingReload: Bool, floor: Double?) {
        self.count = count
        self.blockingReload = blockingReload
        self.floor = floor
    }

    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { count }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .live }
    var liveTargetSegmentDuration: Double? { 4.0 }
    var liveBlockingReloadEnabled: Bool { blockingReload }
    var liveTargetDurationFloorSeconds: Double? { floor }

    func notePlaylistBuild() -> (visibleCount: Int, firstVisible: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int) {
        (count, 0, 1, false, 0)
    }
}
