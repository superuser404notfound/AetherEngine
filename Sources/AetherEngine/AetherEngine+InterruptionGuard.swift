import Foundation

// F5: a transport play while an audio-session interruption is active.
//
// On the renderer paths (software and audio hosts) the system stops the audio clock itself when an
// interruption begins, and starts nothing again when it ends: resuming is the app's policy
// (`shouldResume`). A `play()` or `setRate(>0)` that arrives in between is not neutral, it restarts
// audio under whatever interrupted the session. AVPlayer does not start audible playback in that
// state either, so the renderer paths hold the press and run it when the interruption ends (the
// press is the user's explicit request, so it runs whether or not the system grants `shouldResume`).
// A second press while one is already held goes through, so a BEGAN that never got its ENDED cannot
// make the transport unplayable. The native AVPlayer path owns this itself and is untouched.
extension AetherEngine {

    /// Pure decision: whether a play press is held back. Only a renderer path while interrupted.
    nonisolated static func interruptionHoldsTransport(interrupted: Bool, rendererPath: Bool) -> Bool {
        interrupted && rendererPath
    }

    /// Called from `play()`. True when the press was held (the caller returns). The press is
    /// remembered and runs when the interruption ends, whether or not the system grants `shouldResume`,
    /// because the user asked for it.
    func deferPlayForInterruption() -> Bool {
        guard Self.interruptionHoldsTransport(
            interrupted: audioInterruptionActive, rendererPath: softwareHost != nil || audioHost != nil
        ) else { return false }
        if playDeferredByInterruption {
            audioInterruptionActive = false
            playDeferredByInterruption = false
            EngineLog.emit("[AetherEngine] play() pressed again during an interruption: reactivating the session, then playing", category: .engine)
            playAfterReactivatingSession()
            return true
        }
        playDeferredByInterruption = true
        EngineLog.emit("[AetherEngine] play() held: an audio interruption is active; it runs when the interruption ends", category: .engine)
        return true
    }

    /// A stuck interruption leaves the renderer's session inactive, which stops the audio clock, so the
    /// escape reactivates it before playing. A pause or a new load during the await wins.
    func playAfterReactivatingSession() {
        let pausesBefore = userPauseCount
        let loadBefore = loadGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.activateRendererAudioSession()
            guard self.userPauseCount == pausesBefore, self.loadGeneration == loadBefore else { return }
            self.play()
        }
    }

    /// Pure: whether the end of an interruption plays. The system-granted resume needs the armed
    /// intent; a held press plays regardless. Never in a state that must not start unseen.
    nonisolated static func interruptionEndShouldPlay(
        armed: Bool, shouldResume: Bool, deferredPlay: Bool, backgroundSafe: Bool
    ) -> Bool {
        ((armed && shouldResume) || deferredPlay) && backgroundSafe
    }

    func noteAudioInterruptionBegan() {
        audioInterruptionActive = true
    }

    /// The interruption ended. Returns whether a play press was held meanwhile (and clears it).
    /// The flag is cleared first so the resume that follows is not held by its own guard.
    func noteAudioInterruptionEnded() -> Bool {
        audioInterruptionActive = false
        let deferred = playDeferredByInterruption
        playDeferredByInterruption = false
        return deferred
    }
}
