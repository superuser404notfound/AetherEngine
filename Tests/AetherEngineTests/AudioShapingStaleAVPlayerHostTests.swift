import Foundation
import Testing
@testable import AetherEngine

/// AUD-201: the audio-only AVPlayer host outlives `stopInternal` (its Now Playing session must
/// persist), so "the host exists" says nothing about the current session. A music track followed
/// by a film must not leave live shaping changes ignored.
@Suite(.timeLimit(.minutes(3)))
@MainActor
struct AudioShapingStaleAVPlayerHostTests {

    private func engineAfterMusicTrack() throws -> AetherEngine {
        let engine = try AetherEngine()
        engine.audioAVPlayerHost = AudioAVPlayerHost()
        engine.audioAVPlayerActive = false
        engine.playbackBackend = .software
        engine.state = .playing
        return engine
    }

    @Test("a stale AVPlayer host does not park a live shaping change on a later video session")
    func staleHostDoesNotSwallowShapingChange() throws {
        let engine = try engineAfterMusicTrack()
        let capture = EngineLogCapture()
        defer { capture.end() }
        engine.setAudioShaping(AudioShaping(dialogueGainDB: 6))
        #expect(capture.matching("kept for the next load").isEmpty)
    }

    @Test("the same change is still parked while the AVPlayer host owns the session")
    func activeHostStillParksShapingChange() throws {
        let engine = try engineAfterMusicTrack()
        engine.audioAVPlayerActive = true
        engine.playbackBackend = .audio
        let capture = EngineLogCapture()
        defer { capture.end() }
        engine.setAudioShaping(AudioShaping(dialogueGainDB: 6))
        #expect(capture.matching("kept for the next load").count == 1)
        #expect(engine.audioShapingState == .unavailable)
    }

    @Test("an FFmpeg-hosted track after a native one reports its own shaping state, not unavailable")
    func staleHostDoesNotForceUnavailable() throws {
        let engine = try engineAfterMusicTrack()
        engine.playbackBackend = .audio
        engine.setLoadedAudioShaping(AudioShaping(dialogueGainDB: 6))
        engine.recomputeAudioShapingState()
        #expect(engine.audioShapingState != .unavailable)
    }
}
