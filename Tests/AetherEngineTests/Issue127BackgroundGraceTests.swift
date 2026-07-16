import Testing
@testable import AetherEngine

/// #127: iOS quick app switches must not pay a full pipeline rebuild.
///
/// Policy 1 (backgroundStep): the paused-background teardown is deferred by a grace window held
/// under a background-task assertion. Wedge-safety is preserved: the app stays genuinely running
/// for the whole window and the teardown fires at expiry, so the pipeline never crosses an idle
/// suspension. tvOS keeps the unconditional immediate teardown; a PLAYING session with background
/// playback disabled also tears down immediately (its audio would keep sounding through the window).
///
/// Policy 2 (shouldDeferHostSeek): a host seek forwarded into a pre-ready AVPlayer item clamps to 0
/// against empty seekable ranges and replaces load()'s own pending startPosition seek. Defer such
/// seeks and replay the latest at readiness.
@Suite("Issue 127: background grace window + pre-ready seek deferral")
struct Issue127BackgroundGraceTests {

    // MARK: - backgroundStep (grace window policy)

    @Test("paused teardown defers by the grace window where quick app switches exist")
    func pausedTeardownDefers() {
        #expect(AetherEngine.backgroundStep(
            action: .teardownVideo, state: .paused,
            supportsGraceWindow: true, graceSeconds: 15
        ) == .deferTeardown(afterSeconds: 15))
    }

    @Test("playing teardown stays immediate: background audio must stop when playback is disabled")
    func playingTeardownImmediate() {
        #expect(AetherEngine.backgroundStep(
            action: .teardownVideo, state: .playing,
            supportsGraceWindow: true, graceSeconds: 15
        ) == .perform(.teardownVideo))
    }

    @Test("platforms without a grace window (tvOS) keep the unconditional immediate teardown")
    func noGracePlatformImmediate() {
        #expect(AetherEngine.backgroundStep(
            action: .teardownVideo, state: .paused,
            supportsGraceWindow: false, graceSeconds: 15
        ) == .perform(.teardownVideo))
    }

    @Test("zero grace restores the immediate teardown (host opt-out)")
    func zeroGraceImmediate() {
        #expect(AetherEngine.backgroundStep(
            action: .teardownVideo, state: .paused,
            supportsGraceWindow: true, graceSeconds: 0
        ) == .perform(.teardownVideo))
    }

    @Test("non-teardown actions pass through untouched even with grace available")
    func nonTeardownPassesThrough() {
        #expect(AetherEngine.backgroundStep(
            action: .doNothing, state: .paused,
            supportsGraceWindow: true, graceSeconds: 15
        ) == .perform(.doNothing))
        #expect(AetherEngine.backgroundStep(
            action: .enterSoftwareAudioOnly, state: .playing,
            supportsGraceWindow: true, graceSeconds: 15
        ) == .perform(.enterSoftwareAudioOnly))
    }

    // MARK: - shouldDeferHostSeek (pre-ready seek deferral)

    @Test("native VOD seek defers while the item is pre-ready")
    func nativeVODPreReadyDefers() {
        #expect(AetherEngine.shouldDeferHostSeek(
            nativeSessionActive: true, isLive: false, nativeHostReady: false
        ) == true)
    }

    @Test("native VOD seek runs immediately once the item is ready")
    func nativeVODReadyRunsImmediately() {
        #expect(AetherEngine.shouldDeferHostSeek(
            nativeSessionActive: true, isLive: false, nativeHostReady: true
        ) == false)
    }

    @Test("live seeks never defer (rejoin/DVR paths own their own timing)")
    func liveNeverDefers() {
        #expect(AetherEngine.shouldDeferHostSeek(
            nativeSessionActive: true, isLive: true, nativeHostReady: false
        ) == false)
    }

    @Test("non-native sessions never defer (SW/audio hosts resolve synchronously)")
    func nonNativeNeverDefers() {
        #expect(AetherEngine.shouldDeferHostSeek(
            nativeSessionActive: false, isLive: false, nativeHostReady: false
        ) == false)
    }

    // MARK: - engine surface (#127 proposal 4)

    @Test("isSessionReady starts false and the grace window defaults to 15 s")
    @MainActor
    func engineSurfaceDefaults() throws {
        let engine = try AetherEngine()
        #expect(engine.isSessionReady == false)
        #expect(engine.backgroundTeardownGraceSeconds == 15)
    }
}
