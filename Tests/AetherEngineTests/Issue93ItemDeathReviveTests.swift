import Testing
import Foundation
@testable import AetherEngine

/// #93 round 3: accumulated -12889 media timeouts kill the AVPlayerItem
/// (failedToPlayToEndTime, rate 0, tcs .paused). Every recovery layer then
/// misreads the dead item as a user pause and disarms, making the session
/// terminal. These tests cover the pure decisions of the escalation path:
/// counting the death on the loopback path, bypassing the pause guard for
/// this one trigger, and bounding the reload storm.
struct Issue93ItemDeathReviveTests {

    // MARK: - ItemDeathReviveGate

    @Test("admits reloads up to the cap at a frozen position")
    func admitsWithinCap() {
        var gate = ItemDeathReviveGate(maxAttempts: 3)
        let admitted = (0..<3).map { _ in gate.admit(position: 354.8) }
        #expect(admitted == [true, true, true])
    }

    @Test("exhausts after the cap when the position never advances")
    func exhaustsAtCap() {
        var gate = ItemDeathReviveGate(maxAttempts: 3)
        _ = gate.admit(position: 354.8)
        _ = gate.admit(position: 354.8)
        _ = gate.admit(position: 354.8)
        let fourth = gate.admit(position: 354.8)
        let wiggle = gate.admit(position: 354.9)   // sub-epsilon wiggle is not progress
        #expect(!fourth)
        #expect(!wiggle)
    }

    @Test("playback progress since the last death resets the budget")
    func progressResets() {
        var gate = ItemDeathReviveGate(maxAttempts: 2)
        _ = gate.admit(position: 100.0)
        _ = gate.admit(position: 100.0)
        let exhausted = gate.admit(position: 100.0)
        // The reload finally lands and plays for a while before dying again:
        // a fresh episode, full budget.
        let freshEpisode = gate.admit(position: 130.0)
        #expect(!exhausted)
        #expect(freshEpisode)
    }

    @Test("a user seek to a different position is a fresh episode too")
    func seekAwayResets() {
        var gate = ItemDeathReviveGate(maxAttempts: 2)
        _ = gate.admit(position: 500.0)
        _ = gate.admit(position: 500.0)
        let exhausted = gate.admit(position: 500.0)
        // Backward jump (user scrubbed away from the dead window).
        let scrubbedAway = gate.admit(position: 320.0)
        #expect(!exhausted)
        #expect(scrubbedAway)
    }

    // MARK: - Pause-guard bypass

    @Test("recovery guard keeps refusing a genuinely paused consumer")
    func guardRefusesPausedConsumer() {
        #expect(!AetherEngine.stalledConsumerRecoveryAllowed(
            consumerIsPaused: true, allowPausedConsumer: false))
    }

    @Test("item-death trigger may recover a consumer that LOOKS paused")
    func guardAllowsItemDeathTrigger() {
        // failedToPlayToEndTime parks tcs at .paused; that pause is the
        // failure itself, not user intent.
        #expect(AetherEngine.stalledConsumerRecoveryAllowed(
            consumerIsPaused: true, allowPausedConsumer: true))
    }

    @Test("a playing consumer is always recoverable")
    func guardAllowsPlayingConsumer() {
        #expect(AetherEngine.stalledConsumerRecoveryAllowed(
            consumerIsPaused: false, allowPausedConsumer: false))
    }

    // MARK: - Host-side counting decision

    @Test("loopback path counts an end failure after playback was established")
    func countsLoopbackDeath() {
        #expect(NativeAVPlayerHost.shouldCountEndFailureForRevive(
            surfaceEndFailures: false, hasEverPlayed: true, hasPresentedFrame: true))
    }

    @Test("AE#1043: a death after the first frame but before the first .playing is counted")
    func countsDeathBetweenFirstFrameAndFirstPlaying() {
        #expect(NativeAVPlayerHost.shouldCountEndFailureForRevive(
            surfaceEndFailures: false, hasEverPlayed: false, hasPresentedFrame: true))
    }

    @Test("lean remote-live path keeps its own deferred-failure contract")
    func leanLivePathDoesNotDoubleHandle() {
        #expect(!NativeAVPlayerHost.shouldCountEndFailureForRevive(
            surfaceEndFailures: true, hasEverPlayed: true, hasPresentedFrame: true))
        #expect(!NativeAVPlayerHost.shouldCountEndFailureForRevive(
            surfaceEndFailures: true, hasEverPlayed: false, hasPresentedFrame: true))
    }

    @Test("startup death before the first frame stays with the startup watchdogs")
    func startupDeathNotCounted() {
        #expect(!NativeAVPlayerHost.shouldCountEndFailureForRevive(
            surfaceEndFailures: false, hasEverPlayed: false, hasPresentedFrame: false))
    }
}

/// #93: item death parks AVPlayer at `.paused` whatever the viewer wanted, so the stage-2 reload runs
/// for a paused consumer too. Whether the fresh item then PLAYS is the viewer's call, read from the
/// host's durable intent (#122), which the in-place swap keeps.
///
/// Field log, Apple TV 4K 3rd gen, tvOS 27.0, HDR10+ HEVC Matroska: paused at 2605.23 s, the item died
/// with -11868 two minutes later as the tvOS screensaver took the display, and the recovery called
/// `play()` on the fresh item. The title started itself and the screensaver was dismissed.
@Suite("#93: the stage-2 reload resumes only a viewer who was playing")
@MainActor
struct ItemDeathRecoveryTransportTests {

    private let url = URL(fileURLWithPath: "/nonexistent-item-death-recovery-transport-test.m3u8")

    /// An engine holding a native host with one mounted item, the state the recovery reloads from.
    private func engineWithMountedItem() throws -> (AetherEngine, NativeAVPlayerHost) {
        let engine = try AetherEngine()
        let host = NativeAVPlayerHost()
        engine.nativeHost = host
        engine.currentAVPlayer = host.avPlayer
        host.load(url: url, startPosition: 2605.23, contract: .init())
        return (engine, host)
    }

    @Test("A paused viewer stays paused through the reload")
    func pausedViewerStaysPaused() throws {
        let (engine, host) = try engineWithMountedItem()
        defer { host.tearDown() }
        host.pause()

        engine.forceStalledConsumerReloadForTesting()

        #expect(!host.transportIntentIsPlaying)
        #expect(host.avPlayer.rate == 0)
    }

    @Test("A playing viewer is resumed on the fresh item, as before")
    func playingViewerResumes() throws {
        let (engine, host) = try engineWithMountedItem()
        defer { host.tearDown() }
        host.play()

        engine.forceStalledConsumerReloadForTesting()

        #expect(host.transportIntentIsPlaying)
    }

    /// The #98 media fallback needs a live loopback session to run, so this reads its call site, as
    /// the #535 latch test does.
    @Test("The media fallback asks the same intent before it plays")
    func fallbackAsksTheIntent() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/AetherEngine.swift")
        let text = try #require(try? String(contentsOf: source, encoding: .utf8))
        let fn = try #require(text.range(of: "func fallBackToMediaPlaylist("))
        let end = try #require(text[fn.upperBound...].range(of: "\n    }\n"))
        let body = String(text[fn.lowerBound..<end.upperBound])
        #expect(body.contains("if host.transportIntentIsPlaying { host.play() }"))
        #expect(!body.contains("\n        host.play()\n"))
    }
}

