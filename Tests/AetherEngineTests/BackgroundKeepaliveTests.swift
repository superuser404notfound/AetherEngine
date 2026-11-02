import Testing
@testable import AetherEngine

/// Wedge-safe background keepalive policy (iOS): the video pipeline survives backgrounding ONLY while
/// the app stays genuinely running (PiP active, or actively playing for background audio), never across
/// an idle suspension. See AetherEngine.shouldKeepVideoAlive.
@Suite("Background keepalive policy", .timeLimit(.minutes(3)))
struct BackgroundKeepaliveTests {

    @Test("keep alive while playing and enabled")
    func keepAliveWhilePlaying() {
        #expect(AetherEngine.shouldKeepVideoAlive(enabled: true, pipActive: false, state: .playing) == true)
    }

    @Test("keep alive while PiP active even if paused")
    func keepAliveWhilePiP() {
        #expect(AetherEngine.shouldKeepVideoAlive(enabled: true, pipActive: true, state: .paused) == true)
    }

    @Test("teardown when paused with no PiP")
    func teardownWhenPausedNoPiP() {
        #expect(AetherEngine.shouldKeepVideoAlive(enabled: true, pipActive: false, state: .paused) == false)
    }

    @Test("teardown when background playback disabled")
    func teardownWhenDisabled() {
        #expect(AetherEngine.shouldKeepVideoAlive(enabled: false, pipActive: true, state: .playing) == false)
    }

    @Test("audio backend is always spared")
    func audioBackendSpared() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: true, hasSoftwareHost: false, softwareHostHasAudio: true, keepVideoAlive: false, pipActive: false, state: .playing) == .doNothing)
        #expect(AetherEngine.backgroundAction(isAudioBackend: true, hasSoftwareHost: true, softwareHostHasAudio: true, keepVideoAlive: true, pipActive: false, state: .playing) == .doNothing)
    }

    @Test("native keepalive leaves the session alone")
    func nativeKeepaliveLeavesAlone() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: false, softwareHostHasAudio: true, keepVideoAlive: true, pipActive: false, state: .playing) == .doNothing)
    }

    @Test("software host kept alive enters audio-only")
    func softwareEntersAudioOnly() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: true, softwareHostHasAudio: true, keepVideoAlive: true, pipActive: false, state: .playing) == .enterSoftwareAudioOnly)
    }

    /// AE#739: audio-only mode paces the demux loop on the audio renderer, so a source without audio
    /// raced to EOF in the background and parked its clock at end of media.
    @Test("software host without audio is released instead of entering audio-only")
    func softwareWithoutAudioTearsDown() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: true, softwareHostHasAudio: false, keepVideoAlive: true, pipActive: false, state: .playing) == .teardownVideo)
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: true, softwareHostHasAudio: false, keepVideoAlive: true, pipActive: false, state: .paused) == .teardownVideo)
        // A PiP window still renders its frames.
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: true, softwareHostHasAudio: false, keepVideoAlive: true, pipActive: true, state: .playing) == .doNothing)
    }

    @Test("teardown video when not kept alive and playing or paused")
    func teardownWhenNotKeptAlive() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: false, softwareHostHasAudio: true, keepVideoAlive: false, pipActive: false, state: .playing) == .teardownVideo)
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: true, softwareHostHasAudio: true, keepVideoAlive: false, pipActive: false, state: .paused) == .teardownVideo)
    }

    /// Audit CORE-2: a load or seek in flight DOES have a pipeline (loopback server, AVIO connection,
    /// the item). It is not torn down mid-flight, it is judged once it settles, and that judgement is
    /// owed rather than skipped: a load finishing after the TV button used to start playing in the
    /// background and cross the suspension whole.
    @Test("a load or seek in flight is not torn down mid-flight, the decision is owed until it settles")
    func loadOrSeekInFlightOwesTheDecision() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: false, softwareHostHasAudio: true, keepVideoAlive: false, pipActive: false, state: .loading) == .doNothing)
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: false, softwareHostHasAudio: true, keepVideoAlive: false, pipActive: false, state: .seeking) == .doNothing)
        #expect(AetherEngine.backgroundActionIsOwed(state: .loading))
        #expect(AetherEngine.backgroundActionIsOwed(state: .seeking))
    }

    @Test("a settled or idle session owes nothing")
    func settledStatesOweNothing() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: false, softwareHostHasAudio: true, keepVideoAlive: false, pipActive: false, state: .idle) == .doNothing)
        for state: PlaybackState in [.idle, .playing, .paused, .ended, .error("x")] {
            #expect(!AetherEngine.backgroundActionIsOwed(state: state))
        }
    }

    @Test("tvOS: an active PiP window keeps the video pipeline alive")
    func tvKeepAliveWithPiP() {
        #expect(AetherEngine.shouldKeepVideoAliveTV(enabled: true, pipActive: true) == true)
    }

    @Test("tvOS: playing without PiP still tears down (wedge-safe)")
    func tvTeardownWithoutPiP() {
        #expect(AetherEngine.shouldKeepVideoAliveTV(enabled: true, pipActive: false) == false)
    }

    @Test("tvOS: master disable overrides PiP")
    func tvDisabledOverridesPiP() {
        #expect(AetherEngine.shouldKeepVideoAliveTV(enabled: false, pipActive: true) == false)
    }

    @Test("software host kept alive WITH PiP keeps video (the window needs frames)")
    func softwareKeepsVideoInPiP() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: true, softwareHostHasAudio: true, keepVideoAlive: true, pipActive: true, state: .playing) == .doNothing)
    }

    @Test("software host kept alive WITHOUT PiP still drops to audio-only")
    func softwareAudioOnlyWithoutPiP() {
        #expect(AetherEngine.backgroundAction(isAudioBackend: false, hasSoftwareHost: true, softwareHostHasAudio: true, keepVideoAlive: true, pipActive: false, state: .playing) == .enterSoftwareAudioOnly)
    }
    @MainActor
    @Test("retaining paused pipelines is opt-in")
    func retentionDefault() throws {
        #expect(try AetherEngine().retainsVideoPipelineWhenBackgrounded == false)
    }

    @Test("retention keeps paused native and software sessions, without enabling background playback")
    func retainedPausedPipelinePolicy() {
        for software in [false, true] {
            for audio in [false, true] {
                #expect(AetherEngine.backgroundAction(
                    isAudioBackend: false, hasSoftwareHost: software, softwareHostHasAudio: audio,
                    keepVideoAlive: false, pipActive: false, state: .paused,
                    retainPausedVideoPipeline: true) == .doNothing)
                #expect(AetherEngine.backgroundAction(
                    isAudioBackend: false, hasSoftwareHost: software, softwareHostHasAudio: audio,
                    keepVideoAlive: false, pipActive: false, state: .playing,
                    retainPausedVideoPipeline: true) == .teardownVideo)
            }
        }
        #expect(AetherEngine.backgroundAction(
            isAudioBackend: false, hasSoftwareHost: true, softwareHostHasAudio: true,
            keepVideoAlive: true, pipActive: false, state: .playing,
            retainPausedVideoPipeline: true) == .enterSoftwareAudioOnly)
    }

    @Test("a retained paused session that resumes in the background owes the playing-session policy (AE#870)")
    func resumeOwesPolicyMatrix() {
        #expect(AetherEngine.backgroundPolicyIsOwedOnResume(
            isBackgrounded: true, retainsPausedPipeline: true, from: .paused, to: .playing))
        #expect(!AetherEngine.backgroundPolicyIsOwedOnResume(
            isBackgrounded: false, retainsPausedPipeline: true, from: .paused, to: .playing))
        #expect(!AetherEngine.backgroundPolicyIsOwedOnResume(
            isBackgrounded: true, retainsPausedPipeline: false, from: .paused, to: .playing))
        #expect(!AetherEngine.backgroundPolicyIsOwedOnResume(
            isBackgrounded: true, retainsPausedPipeline: true, from: .playing, to: .paused))
        #expect(!AetherEngine.backgroundPolicyIsOwedOnResume(
            isBackgrounded: true, retainsPausedPipeline: true, from: .loading, to: .playing))
    }

    @MainActor
    @Test("a background resume of a retained paused session runs the background policy once (AE#870)",
          arguments: [true, false])
    func resumeRunsPolicy(retains: Bool) async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var runs: [PlaybackState] = []
        engine.owedBackgroundPolicyForTesting = { runs.append($0.state) }
        engine.retainsVideoPipelineWhenBackgrounded = retains
        engine.state = .paused
        engine.noteDidEnterBackground()
        engine.state = .playing
        if retains {
            try await waitFor { !runs.isEmpty }
        } else {
            for _ in 0..<50 { await Task.yield() }
        }
        #expect(runs == (retains ? [.playing] : []))
    }

    @Test("a seek or reload from a retained pause owes background policy until it settles (AE#870)",
          arguments: [PlaybackState.seeking, .loading])
    func retainedOperationOwesPolicy(transition: PlaybackState) {
        #expect(AetherEngine.backgroundPolicyIsOwedOnResume(
            isBackgrounded: true, retainsPausedPipeline: true, from: .paused, to: transition))
        #expect(!AetherEngine.backgroundPolicyIsOwedOnResume(
            isBackgrounded: false, retainsPausedPipeline: true, from: .paused, to: transition))
        #expect(!AetherEngine.backgroundPolicyIsOwedOnResume(
            isBackgrounded: true, retainsPausedPipeline: false, from: .paused, to: transition))
        #expect(!AetherEngine.backgroundDecisionSettles(state: transition, loadInFlight: false))
    }

    @MainActor
    @Test("a retained background seek applies its final transport policy (AE#870)",
          .timeLimit(.minutes(3)), arguments: [
            (true, true, true), (true, true, false), (true, false, true), (true, false, false),
            (false, true, true), (false, true, false), (false, false, true), (false, false, false),
          ])
    func retainedSeekSettlesPolicy(resumes: Bool, backgroundEnabled: Bool, software: Bool) async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var actions: [AetherEngine.BackgroundAction] = []
        engine.owedBackgroundPolicyForTesting = { engine in
            actions.append(AetherEngine.backgroundAction(
                isAudioBackend: false, hasSoftwareHost: software, softwareHostHasAudio: true,
                keepVideoAlive: AetherEngine.shouldKeepVideoAlive(
                    enabled: engine.backgroundPlaybackEnabled, pipActive: false, state: engine.state),
                pipActive: false, state: engine.state,
                retainPausedVideoPipeline: engine.retainsVideoPipelineWhenBackgrounded))
        }
        engine.backgroundPlaybackEnabled = backgroundEnabled
        engine.retainsVideoPipelineWhenBackgrounded = true
        engine.state = .paused
        engine.noteDidEnterBackground()
        // A seek publishes .seeking before awaiting its host. Play during that wait updates
        // transport intent without publishing .playing until the seek settles.
        engine.state = .seeking
        if resumes { engine.play() }
        #expect(engine.state == .seeking)
        #expect(actions.isEmpty)
        engine.state = resumes ? .playing : .paused
        try await waitFor { !actions.isEmpty }
        let expected: AetherEngine.BackgroundAction = !resumes ? .doNothing
            : !backgroundEnabled ? .teardownVideo
            : software ? .enterSoftwareAudioOnly : .doNothing
        #expect(actions == [expected])
    }

}
