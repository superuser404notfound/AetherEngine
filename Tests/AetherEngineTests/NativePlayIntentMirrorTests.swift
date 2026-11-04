import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// AVKit's own pause and play (a rate write on the AVPlayer) update the host's play intent;
/// every other rate change leaves it alone.
struct NativePlayIntentMirrorTests {

    @Test("an explicit rate write sets the intent from the live rate")
    func setRateCalled() {
        #expect(!NativeAVPlayerHost.playIntentAfterRateChange(reason: .setRateCalled, rate: 0, current: true))
        #expect(NativeAVPlayerHost.playIntentAfterRateChange(reason: .setRateCalled, rate: 1, current: false))
        #expect(NativeAVPlayerHost.playIntentAfterRateChange(reason: .setRateCalled, rate: 2, current: false))
    }

    @Test("a missing or other reason keeps the current intent")
    func otherReasons() {
        for current in [true, false] {
            #expect(NativeAVPlayerHost.playIntentAfterRateChange(reason: nil, rate: 0, current: current) == current)
            #expect(NativeAVPlayerHost.playIntentAfterRateChange(reason: .appBackgrounded, rate: 0, current: current) == current)
            #expect(NativeAVPlayerHost.playIntentAfterRateChange(reason: .audioSessionInterrupted, rate: 0, current: current) == current)
            #expect(NativeAVPlayerHost.playIntentAfterRateChange(reason: .setRateFailed, rate: 1, current: current) == current)
        }
    }

    // MARK: - The wiring, on a host that has loaded media

    @Test("AVKit's pause and play on a ready item move the host's intent", .timeLimit(.minutes(3)))
    @MainActor
    func transportBarMovesTheIntent() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        host.load(url: file, startPosition: nil, contract: .init())
        host.play()
        try await waitFor { host.isReady }

        // The transport bar calls the player directly, past host.pause() and host.play().
        host.avPlayer.pause()
        try await waitFor { !host.transportIntentIsPlaying }
        host.avPlayer.play()
        try await waitFor { host.transportIntentIsPlaying }
    }

    /// Issue #15: a swap on a reused host can drop the rate while the new item loads, and the
    /// readyToPlay observer re-issues play() only if the intent is still set. The mirror used to be
    /// live in that window, so a rate write there cleared the latch and the session parked at
    /// readyToPlay and paused. On macOS the swap posts no rate change at all (measured), so this write,
    /// made before the new item is ready, stands in for the drop; its reason on a device is unmeasured.
    @Test("issue #15: a rate drop while the swapped-in item loads does not park the session", .timeLimit(.minutes(3)))
    @MainActor
    func issue15SwapDropDoesNotParkTheSession() async throws {
        let file = try await ItemSwapStillTests.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let host = NativeAVPlayerHost()
        defer { host.tearDown() }
        host.load(url: file, startPosition: nil, contract: .init())
        host.play()
        try await waitFor { host.isReady }

        host.swapItem(url: file, startPosition: nil)
        #expect(!host.isReady)
        host.avPlayer.pause()
        try await waitFor { host.isReady }

        // #require, not #expect: with the intent lost nothing ever plays, and the wait below would run to the time limit.
        try #require(host.transportIntentIsPlaying)
        try await waitFor { host.avPlayer.timeControlStatus != .paused }
    }
}
