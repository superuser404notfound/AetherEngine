import Testing
#if os(iOS) || os(tvOS)
import AVFoundation
#endif
@testable import AetherEngine

/// F3: a renderer path pauses when the route it was playing to is removed, as AVPlayer does. The
/// notification exists on iOS and tvOS only; the tests drive the decision and the reaction directly.
@Suite("F3: pause on audio route removal")
@MainActor
struct RouteRemovalPauseTests {

    private func engine(software: Bool = true, state: PlaybackState = .playing) throws -> AetherEngine {
        let engine = try AetherEngine()
        if software { engine.softwareHost = SoftwarePlaybackHost(videoGravity: .resizeAspect) }
        engine.state = state
        return engine
    }

    @Test("decision: only old-device-unavailable of a removable output pauses")
    func decision() {
        let removed = AetherEngine.routeChangeReasonOldDeviceUnavailableRaw
        for port in ["Headphones", "BluetoothA2DPOutput", "BluetoothLE", "BluetoothHFP", "AirPlay", "USBAudio"] {
            #expect(AetherEngine.routeRemovalShouldPause(reasonRaw: removed, previousOutputPortTypes: [port]), "\(port)")
        }
        #expect(!AetherEngine.routeRemovalShouldPause(reasonRaw: removed, previousOutputPortTypes: ["Speaker"]))
        #expect(!AetherEngine.routeRemovalShouldPause(reasonRaw: removed, previousOutputPortTypes: ["Receiver"]))
        #expect(!AetherEngine.routeRemovalShouldPause(reasonRaw: removed, previousOutputPortTypes: []))
        let headphones = ["Headphones"]
        #expect(!AetherEngine.routeRemovalShouldPause(reasonRaw: 1, previousOutputPortTypes: headphones))   // newDeviceAvailable
        #expect(!AetherEngine.routeRemovalShouldPause(reasonRaw: 3, previousOutputPortTypes: headphones))   // categoryChange
        #expect(!AetherEngine.routeRemovalShouldPause(reasonRaw: nil, previousOutputPortTypes: headphones))
    }

    @Test("an HDMI route going away does not pause: an ARC / eARC receiver toggling on an Apple TV is not a removal")
    func hdmiDoesNotPause() {
        let removed = AetherEngine.routeChangeReasonOldDeviceUnavailableRaw
        #expect(!AetherEngine.routeRemovalShouldPause(reasonRaw: removed, previousOutputPortTypes: ["HDMIOutput"]))
        #expect(!AetherEngine.routeRemovalShouldPause(reasonRaw: removed, previousOutputPortTypes: ["HDMIOutput", "LineOut"]))
    }

    #if os(iOS) || os(tvOS)
    @Test("the spelled-out port types are the session's own")
    func portTypesMatchTheSession() {
        let ports: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay, .usbAudio]
        #expect(Set(ports.map(\.rawValue)) == AetherEngine.routeRemovalPausingPortTypes)
        #expect(!AetherEngine.routeRemovalPausingPortTypes.contains(AVAudioSession.Port.HDMI.rawValue))
    }
    #endif

    @Test("a playing software session pauses")
    func pausesWhilePlaying() throws {
        let engine = try engine()
        defer { engine.stop() }
        engine.noteOutputRouteRemoved()
        #expect(engine.state == .paused)
    }

    @Test("a paused session stays paused and a loading one is left alone")
    func otherStatesUntouched() throws {
        for state in [PlaybackState.paused, .loading, .idle] {
            let engine = try engine(state: state)
            engine.isBuffering = true
            engine.noteOutputRouteRemoved()
            #expect(engine.isBuffering, "pause() must not have run")
            #expect(engine.state == state)
            engine.stop()
        }
    }

    @Test("the native path is left to AVPlayer")
    func nativeUntouched() throws {
        let engine = try engine(software: false)
        defer { engine.stop() }
        engine.noteOutputRouteRemoved()
        #expect(engine.state == .playing)
    }

    /// Review R-P5-2: AirPods taken out during a call left the interruption armed, so ENDED with
    /// `shouldResume` restarted the film on the phone speaker. AVPlayer's own pause on the removal does
    /// not reach `pause()`, so the native path disarmed nothing.
    @Test("a route removal disarms the interruption resume on every path and in every state (review R-P5-2)",
          arguments: [false, true], [PlaybackState.playing, .paused, .loading, .seeking, .idle])
    func removalDisarmsInterruptionResume(software: Bool, state: PlaybackState) throws {
        let engine = try engine(software: software, state: state)
        defer { engine.stop() }
        engine.resumeAfterInterruption = true
        engine.playDeferredByInterruption = true
        engine.noteOutputRouteRemoved()
        #expect(!engine.resumeAfterInterruption)
        #expect(!engine.playDeferredByInterruption)
    }

    @Test("a route removal during a seek still pauses")
    func pausesDuringSeek() throws {
        let engine = try engine(state: .seeking)
        defer { engine.stop() }
        engine.isBuffering = true
        engine.noteOutputRouteRemoved()
        #expect(!engine.isBuffering, "pause() ran: it clears the buffering flag")
    }
}
