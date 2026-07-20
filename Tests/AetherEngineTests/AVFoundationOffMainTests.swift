import Foundation
import Testing
import AVFoundation
@testable import AetherEngine

/// #134: shared hop that runs batched synchronous AVFoundation property reads on a
/// caller-owned serial queue instead of the main actor.
@MainActor
struct AVFoundationOffMainTests {

    @Test("body runs off the main thread and the value round-trips")
    func bodyRunsOffMain() async {
        let queue = DispatchQueue(label: "test.avfread")
        let player = AVPlayer()
        let wasOffMain = await AVFoundationOffMain.read(player, on: queue) { player -> Bool in
            _ = player.rate
            return !Thread.isMainThread
        }
        #expect(wasOffMain)
    }

    @Test("a blocked body must not block the main actor")
    func blockedBodyKeepsMainActorResponsive() async {
        let queue = DispatchQueue(label: "test.avfread.stall")
        let release = DispatchSemaphore(value: 0)
        let player = AVPlayer()
        async let result = AVFoundationOffMain.read(player, on: queue) { _ -> Bool in
            // Signalled only if the main actor keeps running below while this body blocks.
            // Generous backstop: a real main-actor block never signals at any size, so only CI
            // scheduling starvation needs absorbing (a parallel CPU-heavy test can starve the main
            // actor for tens of seconds), not a tight race that flakes under parallel load.
            release.wait(timeout: .now() + 90) == .success
        }
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)) }
        release.signal()
        #expect(await result)
    }
}

/// #134 follow-up: seekable-end mapping used by the host's KVO mirror of
/// `seekableTimeRanges`, replacing per-call synchronous reads at clock-tick cadence.
struct NativeAVPlayerHostSeekableEndTests {

    @Test("empty ranges map to 0")
    func emptyRanges() {
        #expect(NativeAVPlayerHost.seekableEnd(from: []) == 0)
    }

    @Test("end of the last range wins")
    func lastRangeEnd() {
        let ranges = [
            NSValue(timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1))),
            NSValue(timeRange: CMTimeRange(start: CMTime(value: 20, timescale: 1),
                                           duration: CMTime(value: 15, timescale: 1))),
        ]
        #expect(NativeAVPlayerHost.seekableEnd(from: ranges) == 35)
    }

    @Test("non-finite end maps to 0")
    func nonFiniteEnd() {
        let ranges = [NSValue(timeRange: CMTimeRange(start: .zero, duration: .indefinite))]
        #expect(NativeAVPlayerHost.seekableEnd(from: ranges) == 0)
    }
}
