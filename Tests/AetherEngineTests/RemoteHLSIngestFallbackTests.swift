import XCTest
@testable import AetherEngine

/// AetherEngine#168 follow-up: AVFoundation's HLS demuxer builds no video track for HEVC carried in
/// MPEG-TS segments (the HLS Authoring Spec sanctions HEVC only in fMP4), so a master that advertises
/// hvc1 but serves .ts reaches readyToPlay with audio only and a black picture. The engine reroutes such
/// live sessions onto the loopback ingest path (HLSLiveIngestReader remuxes TS to fMP4). These tests pin
/// the pure decision logic: the per-tick watchdog, the variant-advertisement mapper, and the arm gate.
final class RemoteHLSIngestFallbackTests: XCTestCase {

    // MARK: - Watchdog verdicts

    func testVideoTrackPresentDisarmsImmediately() {
        var dog = RemoteHLSIngestFallback.Watchdog(graceTicks: 8)
        XCTAssertEqual(dog.tick(videoTrackCount: 1, variantsAdvertiseVideo: true), .disarm)
    }

    func testAdvertisedVideoNeverBuiltFiresAtGraceExhaustion() {
        var dog = RemoteHLSIngestFallback.Watchdog(graceTicks: 8)
        for _ in 1...7 {
            XCTAssertEqual(dog.tick(videoTrackCount: 0, variantsAdvertiseVideo: true), .keepWaiting)
        }
        XCTAssertEqual(dog.tick(videoTrackCount: 0, variantsAdvertiseVideo: true), .fire)
    }

    func testAudioOnlyMasterDisarmsImmediately() {
        // A master whose variants advertise no video (radio channel): zero video tracks is the
        // legitimate steady state, never a reroute signal.
        var dog = RemoteHLSIngestFallback.Watchdog(graceTicks: 8)
        XCTAssertEqual(dog.tick(videoTrackCount: 0, variantsAdvertiseVideo: false), .disarm)
    }

    func testUnknownAdvertisementNeverFires() {
        // Media-playlist-direct URL: AVAsset has no variants, so there is no positive evidence that
        // video was ever advertised. Conservative: wait out the grace, then disarm without firing.
        var dog = RemoteHLSIngestFallback.Watchdog(graceTicks: 4)
        for _ in 1...3 {
            XCTAssertEqual(dog.tick(videoTrackCount: 0, variantsAdvertiseVideo: nil), .keepWaiting)
        }
        XCTAssertEqual(dog.tick(videoTrackCount: 0, variantsAdvertiseVideo: nil), .disarm)
    }

    func testLateAdvertisementResolutionStillFires() {
        // asset.load(.variants) resolving a few ticks after readyToPlay must not lose the reroute.
        var dog = RemoteHLSIngestFallback.Watchdog(graceTicks: 6)
        for _ in 1...3 {
            XCTAssertEqual(dog.tick(videoTrackCount: 0, variantsAdvertiseVideo: nil), .keepWaiting)
        }
        for _ in 4...5 {
            XCTAssertEqual(dog.tick(videoTrackCount: 0, variantsAdvertiseVideo: true), .keepWaiting)
        }
        XCTAssertEqual(dog.tick(videoTrackCount: 0, variantsAdvertiseVideo: true), .fire)
    }

    func testLateVideoTrackDisarmsBeforeGraceExhaustion() {
        // HLS video tracks can join item.tracks well after readyToPlay; a late build is a healthy session.
        var dog = RemoteHLSIngestFallback.Watchdog(graceTicks: 8)
        for _ in 1...5 {
            XCTAssertEqual(dog.tick(videoTrackCount: 0, variantsAdvertiseVideo: true), .keepWaiting)
        }
        XCTAssertEqual(dog.tick(videoTrackCount: 1, variantsAdvertiseVideo: true), .disarm)
    }

    func testDefaultGraceCoversFourSecondsAtHalfSecondCadence() {
        XCTAssertEqual(RemoteHLSIngestFallback.Watchdog().graceTicks, 8)
    }

    // MARK: - Variant advertisement mapper

    func testAdvertisesVideoWithNoVariantsIsUnknown() {
        XCTAssertNil(RemoteHLSIngestFallback.advertisesVideo(variantHasVideoAttributes: []))
    }

    func testAdvertisesVideoWhenAnyVariantCarriesVideoAttributes() {
        XCTAssertEqual(RemoteHLSIngestFallback.advertisesVideo(variantHasVideoAttributes: [false, true]), true)
    }

    func testAdvertisesVideoAllAudioVariantsIsFalse() {
        XCTAssertEqual(RemoteHLSIngestFallback.advertisesVideo(variantHasVideoAttributes: [false, false]), false)
    }

    // MARK: - Arm gate

    func testLoadOptionsIngestFallbackDefaultsOn() {
        XCTAssertTrue(LoadOptions().nativeRemoteHLSIngestFallback)
    }

    func testArmsOnlyLiveSessionsWithFallbackEnabled() {
        XCTAssertTrue(RemoteHLSIngestFallback.shouldArm(isLive: true, fallbackEnabled: true))
        XCTAssertFalse(RemoteHLSIngestFallback.shouldArm(isLive: false, fallbackEnabled: true))
        XCTAssertFalse(RemoteHLSIngestFallback.shouldArm(isLive: true, fallbackEnabled: false))
        XCTAssertFalse(RemoteHLSIngestFallback.shouldArm(isLive: false, fallbackEnabled: false))
    }
}
