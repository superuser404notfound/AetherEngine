import AVFoundation
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
}
