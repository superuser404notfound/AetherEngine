import Foundation
import Testing
@testable import AetherEngine

/// AE#935: the remote-HLS bypass has no engine segment cache, so `bufferedPosition` stayed at its
/// reset value of 0 for the whole session. It now publishes AVPlayer's contiguous loaded frontier.
@MainActor
@Suite("Remote HLS buffered position (#935)")
struct Issue935RemoteHLSBufferedPositionTests {
    private func fixture() throws -> (AetherEngine, NativeAVPlayerHost) {
        let engine = try AetherEngine()
        let host = NativeAVPlayerHost()
        engine.playbackBackend = .native
        engine.nativeHost = host
        engine.currentAVPlayer = host.avPlayer
        engine._testSetLiveRoute(isLive: false, route: .remoteBypass)
        return (engine, host)
    }

    @Test("publishes the loaded range contiguous with the playhead, not disconnected islands")
    func contiguousFrontier() throws {
        let (engine, _) = try fixture()
        engine.clock.currentTime = 2
        engine.refreshRemoteHLSBufferedPosition(rendered: 2, ranges: [(0, 10), (15, 20)])
        #expect(engine.bufferedPosition == 10)
    }

    @Test("a pending seek measures from its target")
    func pendingSeekAnchorsOnTarget() throws {
        let (engine, _) = try fixture()
        defer { engine.setPendingRecoverySeekTarget(nil) }
        engine.clock.currentTime = 16
        engine.setPendingRecoverySeekTarget(16)
        engine.refreshRemoteHLSBufferedPosition(rendered: 2, ranges: [(0, 4), (15, 20)])
        #expect(engine.bufferedPosition == 20)
    }

    @Test("never trails the published playhead")
    func neverTrailsPlayhead() throws {
        let (engine, _) = try fixture()
        engine.clock.currentTime = 9
        engine.refreshRemoteHLSBufferedPosition(rendered: 8.5, ranges: [])
        #expect(engine.bufferedPosition == 9)
        engine.refreshRemoteHLSBufferedPosition(rendered: 8.5, ranges: [(0, 8.6)])
        #expect(engine.bufferedPosition == 9)
    }

    @Test("the shared refresh reaches the bypass, which has no native session")
    func sharedRefreshCoversBypass() throws {
        let (engine, _) = try fixture()
        engine.clock.currentTime = 20.2
        engine.clock.bufferedPosition = 0
        engine.refreshNativeBufferedPosition()
        #expect(engine.bufferedPosition == 20.2)
    }

    @Test("a loopback route without a session still leaves another path's value alone")
    func loopbackWithoutSessionUntouched() throws {
        let (engine, _) = try fixture()
        engine._testSetLiveRoute(isLive: false, route: .loopback)
        engine.clock.bufferedPosition = 42
        engine.refreshNativeBufferedPosition()
        #expect(engine.bufferedPosition == 42)
        engine.refreshRemoteHLSBufferedPosition(rendered: 2, ranges: [(0, 10)])
        #expect(engine.bufferedPosition == 42)
    }
}
