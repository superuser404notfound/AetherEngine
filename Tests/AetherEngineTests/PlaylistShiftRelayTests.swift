import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

@Suite("The playlist-shift relay writes only for the session it was raised for", .serialized)
@MainActor
struct PlaylistShiftRelayTests {

    /// Audit LOAD-206: the relay re-folded `currentTime` after an off-main buffer read it needs only
    /// for its log line. AE#422 measured that queue blocked for seconds during a stall, and a stop or
    /// a zap that landed meanwhile had its clock overwritten with the old session's shift.
    @Test("A shift relay held on its buffer read does not write the clock of the session after it",
          .timeLimit(.minutes(3)))
    func heldRelayLeavesTheSuccessorsClock() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let log = EngineLogCapture()
        defer { log.end() }
        engine.currentAVPlayer = AVPlayer(playerItem: AVPlayerItem(url: URL(string: "http://127.0.0.1:9/relay.mp4")!))
        let session = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/relay.mkv"), dvModeAvailable: false)
        engine.installPlaylistShiftRelay(on: session, generation: engine.loadGeneration)

        let gate = DispatchSemaphore(value: 0)
        NativeAVPlayerHost.offMainReadQueue.async { gate.wait() }
        var gateOpen = false
        defer { if !gateOpen { gate.signal() } }

        let shift = 7123.25
        session.onPlaylistShiftChanged?(shift, 0)
        // Written before the read; once it shows, the hop is parked on the queue.
        try await waitFor { engine.playlistShiftSeconds == shift }

        engine.stop()
        engine.clock.currentTime = 42
        // Review R-P3-1: the successor's own placement check, which the stale relay used to cancel when it
        // measured the old session against the new item's loaded ranges.
        let successorsCheck = Task<Void, Never> { @MainActor in
            do { try await Task.sleep(for: .seconds(600)) } catch { return }
        }
        defer { successorsCheck.cancel() }
        engine.placementVerificationTask = successorsCheck
        gate.signal()
        gateOpen = true
        try await waitFor {
            !log.matching("VOD shift published: 7123.250s").isEmpty
                || !log.matching("VOD shift relay superseded").isEmpty
        }

        #expect(engine.clock.currentTime == 42)
        #expect(!successorsCheck.isCancelled, "the superseded relay must not touch the successor's placement check")
        #expect(engine.placementVerificationTask == successorsCheck)
    }
}
