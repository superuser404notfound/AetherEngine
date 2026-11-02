import Foundation

/// AE#923: audio shaping as a live setting.
///
/// A dialogue lift or night mode is a per-room setting the viewer toggles while watching, so it has
/// to reach a running session the way `setAudioDelay(_:)` does. Shaping changes which pipeline the
/// session runs (stream copy or bridge, compressed passthrough or PCM decode) and the channel count
/// the renderer is handed, so unlike the delay it cannot be patched into a pipeline in place on any
/// route; every change is the session-preserving reload (#460).
extension AetherEngine {

    /// The audio shaping in force for this session, as clamped by the engine.
    public var audioShaping: AudioShaping { loadedOptions.audioShaping }

    /// Change the audio shaping while playback runs.
    ///
    /// The value is clamped (`AudioShaping.clamped`) and stored in the options every rebuild replays,
    /// so it survives audio-track switches, reloads and background returns, and it is what the next
    /// load uses. Passing the value already in force does nothing.
    ///
    /// **What it costs.** A change rebuilds the session at the playhead (`reloadAtCurrentPosition`):
    /// measured for the delay on the loopback route, about 0.3 s of held picture with the position
    /// preserved to the sample. Turning shaping on moves a stream-copied track onto the PCM bridge,
    /// turning it off moves it back. Changes that arrive while a rebuild is running are folded into
    /// it, as the delay's are.
    ///
    /// Where AVPlayer owns the audio (`.remoteBypass`, the native audio-only host) the engine has no
    /// PCM to shape: the value is kept for a later load, logged, and `audioShapingState` reads
    /// `.unavailable`. A live session without a DVR window has no position to come back to, so the
    /// value arrives at the next rebuild the session makes on its own.
    public func setAudioShaping(_ shaping: AudioShaping) {
        let next = shaping.clamped
        guard next != loadedOptions.audioShaping else { return }
        setLoadedAudioShaping(next)
        // Only a pipeline the engine owns carries it, and that pipeline is what decides the state.
        // Asked off the old pipeline until the rebuild replaces it, which is exactly what is playing.
        recomputeAudioShapingState()

        guard state != .loading else {
            EngineLog.emit("[AetherEngine] AE#923: audio shaping = \(next.summary) set while the session is "
                           + "being rebuilt; the load in flight reads it from the options", category: .engine)
            return
        }
        if videoRoute == .remoteBypass || audioAVPlayerHost != nil || playbackBackend == .none {
            EngineLog.emit("[AetherEngine] AE#923: audio shaping = \(next.summary), kept for the next load: "
                           + "this session's audio is not decoded by the engine (route=\(videoRoute.rawValue))",
                           category: .engine)
            return
        }
        reanchorForAudioShaping()
    }

    /// The rebuild, with `reanchorForAudioDelay`'s folding: the value does not ride the call, so a
    /// rebuild that has not read the options yet already carries the newest one, and one catch-up
    /// pass covers a change that landed after it had.
    private func reanchorForAudioShaping() {
        guard Self.audioDelayRecutIsPossible(state: state, isLive: isLive, liveWindow: liveWindow) else {
            EngineLog.emit("[AetherEngine] AE#923: audio shaping = \(loadedOptions.audioShaping.summary) stands, "
                           + "but this session cannot rebuild at the playhead (state=\(state), live=\(isLive)); "
                           + "it arrives at the next rebuild", category: .engine)
            return
        }
        guard !audioShapingReanchorInFlight else {
            EngineLog.emit("[AetherEngine] AE#923: audio shaping folded into the rebuild already in flight",
                           category: .engine)
            return
        }
        if let refusal = sessionReloadRefusal {
            EngineLog.emit("[AetherEngine] AE#923: audio shaping = \(loadedOptions.audioShaping.summary) stands, "
                           + "but this session cannot be rebuilt in place (\(refusal.rawValue)); it arrives at "
                           + "the next load", category: .engine)
            return
        }
        audioShapingReanchorInFlight = true
        Task { @MainActor in
            defer { self.audioShapingReanchorInFlight = false }
            var delivered: AudioShaping
            repeat {
                delivered = self.loadedOptions.audioShaping
                do {
                    try await self.reloadAtCurrentPosition()
                    EngineLog.emit("[AetherEngine] AE#923: rebuilt at the playhead with audio shaping "
                                   + delivered.summary, category: .engine)
                } catch is CancellationError {
                    EngineLog.emit("[AetherEngine] AE#923: the rebuild was superseded by a newer load, which "
                                   + "reads the shaping in force", category: .engine)
                    return
                } catch {
                    EngineLog.emit("[AetherEngine] AE#923: the rebuild failed (\(error)); the audio shaping "
                                   + "stands and arrives at the next load", category: .engine)
                    return
                }
            } while delivered != self.loadedOptions.audioShaping
                && Self.audioDelayRecutIsPossible(state: self.state, isLive: self.isLive, liveWindow: self.liveWindow)
        }
    }
}
