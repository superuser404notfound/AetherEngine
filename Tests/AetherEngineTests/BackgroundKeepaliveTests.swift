import Testing
@testable import AetherEngine

/// Wedge-safe background keepalive policy (iOS): the video pipeline survives backgrounding ONLY while
/// the app stays genuinely running (PiP active, or actively playing for background audio), never across
/// an idle suspension. See AetherEngine.shouldKeepVideoAlive.
@Suite("Background keepalive policy")
struct BackgroundKeepaliveTests {

    @Test("keep alive while playing and enabled")
    func keepAliveWhilePlaying() {
        #expect(AetherEngine.shouldKeepVideoAlive(enabled: true, pipActive: false, state: .playing) == true)
    }

    @Test("keep alive while PiP active even if paused")
    func keepAliveWhilePiP() {
        #expect(AetherEngine.shouldKeepVideoAlive(enabled: true, pipActive: true, state: .paused) == true)
    }

    @Test("teardown when paused with no PiP")
    func teardownWhenPausedNoPiP() {
        #expect(AetherEngine.shouldKeepVideoAlive(enabled: true, pipActive: false, state: .paused) == false)
    }

    @Test("teardown when background playback disabled")
    func teardownWhenDisabled() {
        #expect(AetherEngine.shouldKeepVideoAlive(enabled: false, pipActive: true, state: .playing) == false)
    }

    @Test("audio backend is always spared")
    func audioBackendSpared() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: true, hasSoftwareHost: false, keepVideoAlive: false, state: .playing) == .doNothing)
        #expect(AetherEngine.backgroundAction(isAudioBackend: true, hasSoftwareHost: true, keepVideoAlive: true, state: .playing) == .doNothing)
    }

    @Test("native keepalive leaves the session alone")
    func nativeKeepaliveLeavesAlone() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: false, keepVideoAlive: true, state: .playing) == .doNothing)
    }

    @Test("software host kept alive enters audio-only")
    func softwareEntersAudioOnly() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: true, keepVideoAlive: true, state: .playing) == .enterSoftwareAudioOnly)
    }

    @Test("teardown video when not kept alive and playing or paused")
    func teardownWhenNotKeptAlive() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: false, keepVideoAlive: false, state: .playing) == .teardownVideo)
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: true, keepVideoAlive: false, state: .paused) == .teardownVideo)
    }

    @Test("do nothing when idle or loading (nothing to tear down)")
    func doNothingWhenNotPlayable() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: false, keepVideoAlive: false, state: .loading) == .doNothing)
    }

    @Test("tvOS: an active PiP window keeps the video pipeline alive")
    func tvKeepAliveWithPiP() {
        #expect(AetherEngine.shouldKeepVideoAliveTV(enabled: true, pipActive: true) == true)
    }

    @Test("tvOS: playing without PiP still tears down (wedge-safe)")
    func tvTeardownWithoutPiP() {
        #expect(AetherEngine.shouldKeepVideoAliveTV(enabled: true, pipActive: false) == false)
    }

    @Test("tvOS: master disable overrides PiP")
    func tvDisabledOverridesPiP() {
        #expect(AetherEngine.shouldKeepVideoAliveTV(enabled: false, pipActive: true) == false)
    }
}
