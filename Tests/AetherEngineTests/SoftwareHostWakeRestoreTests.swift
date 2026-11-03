import Foundation
import MediaPlayer
import Testing
@testable import AetherEngine

/// A software session with the engine-owned Now-Playing card (`ownsSoftwareNowPlaying`), paused, then
/// released by the background teardown the way a tvOS sleep releases it. The teardown takes the
/// software host and its remote-command targets with it, so until the host rebuilds the session
/// nothing answers the remote: on a device this reads as a frozen last frame and dead Play/Pause.
/// The rebuild is the host's call (`needsForegroundVideoRestore`, then `reloadAtCurrentPosition`).
/// This pins that the rebuild alone brings the session back where it was, paused, with the card and
/// the remote commands answering again.
@Suite("Software host: restore after a background teardown", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SoftwareHostWakeRestoreTests {

    private static let fixture = Task { try await ItemSwapStillTests.fixtureURL() }

    @MainActor
    private final class Sink: SoftwareNowPlayingSink {
        var handler: (@MainActor (SoftwareNowPlayingCommand) -> Void)?
        var deactivated = false
        var lastState: MPNowPlayingPlaybackState = .unknown
        func activate(skipInterval: Double, handler: @escaping @MainActor (SoftwareNowPlayingCommand) -> Void) {
            self.handler = handler
        }
        func setSeekingEnabled(_ enabled: Bool) {}
        func publish(info: [String: Any]?, playbackState: MPNowPlayingPlaybackState) { lastState = playbackState }
        func deactivate() { deactivated = true; handler = nil }
    }

    @Test("a paused session torn down for the background comes back paused, with Now-Playing and the remote")
    func restoreAfterBackgroundTeardown() async throws {
        let file = try await Self.fixture.value
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.volume = 0
        engine.ownsSoftwareNowPlaying = true
        var sinks: [Sink] = []
        engine.makeSoftwareNowPlayingSink = {
            let sink = Sink()
            sinks.append(sink)
            return sink
        }

        var options = LoadOptions()
        options.preferredDecodePath = .software
        _ = try await engine.load(url: file, options: options)
        #expect(engine.playbackBackend == .software)
        engine.play()
        // Past the one-second floor below which a rebuild deliberately restarts at the head
        // (`LiveReloadPolicy.resumePosition`), so the restore has a position to come back to.
        try await waitFor { engine.currentTime > 1.5 }
        engine.pause()
        let pausedAt = engine.currentTime
        #expect(engine.softwareNowPlayingActive)
        #expect(sinks.count == 1)

        // What didEnterBackground runs on tvOS for a software session with no PiP.
        engine.releaseVideoPipelineForBackground()
        #expect(engine.playbackBackend == .none)
        #expect(engine.softwareHost == nil)
        #expect(engine.state == .paused)
        #expect(engine.needsForegroundVideoRestore)
        // The symptom: the card and its command targets went with the host, so the remote has
        // nothing to reach until the session is rebuilt.
        #expect(!engine.softwareNowPlayingActive)
        #expect(sinks[0].deactivated)
        #expect(sinks[0].handler == nil)

        // The host's half on foreground return: rebuild at the playhead and stay paused.
        try await engine.reloadAtCurrentPosition { $0.autoplay = false }
        #expect(engine.playbackBackend == .software)
        #expect(!engine.needsForegroundVideoRestore)
        #expect(engine.state == .paused)
        #expect(abs(engine.currentTime - pausedAt) < 0.5, "restored at \(engine.currentTime), paused at \(pausedAt)")
        #expect(engine.softwareNowPlayingActive)
        #expect(sinks.count == 2)
        let restored = try #require(sinks.last)
        #expect(!restored.deactivated)

        // A remote Play goes through the rebuilt card's command handler and moves the session again.
        let handler = try #require(restored.handler)
        handler(.play)
        try await waitFor { engine.state == .playing }
        let resumedFrom = engine.currentTime
        try await waitFor { engine.currentTime > resumedFrom + 0.3 }
    }

    @Test("a software host built while the app is in the background starts out knowing it is off screen")
    func hostBuiltInBackgroundKnowsItIsOffScreen() async throws {
        let file = try await Self.fixture.value
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.volume = 0
        engine.noteDidEnterBackground()

        var options = LoadOptions()
        options.preferredDecodePath = .software
        _ = try await engine.load(url: file, options: options)
        #expect(engine.playbackBackend == .software)
        #expect(engine.softwareHost?.appInBackgroundForTesting == true)
    }
}
