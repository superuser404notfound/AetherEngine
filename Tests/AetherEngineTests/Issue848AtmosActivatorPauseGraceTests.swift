import AVFoundation
import Testing
@testable import AetherEngine

/// AE#848: pausing the silent Atmos stream with the host let an HDMI soundbar drop out of Dolby Atmos
/// and re-lock on every resume and scrub. The stream now rides through a pause for a bounded grace.
@MainActor
@Suite("The Atmos output activator holds through a short pause (#848)", .serialized, .timeLimit(.minutes(3)))
struct Issue848AtmosActivatorPauseGraceTests {

    /// The host holds at the end of its 2 s clip instead of pausing: a host that paused on its own
    /// would start a grace the test never asked for, which a loaded runner stretching the body past
    /// 2 s did.
    private func attached(grace: Duration, ports: [String] = ["HDMIOutput"]) -> (AtmosOutputActivator, AVPlayer) {
        let host = AVPlayer(playerItem: AVPlayerItem(url: AtmosOutputActivator.silentAtmosStream))
        host.isMuted = true
        host.actionAtItemEnd = .none
        let activator = AtmosOutputActivator(outputPortTypes: { ports }, pauseGrace: grace)
        activator.attach(to: host) { _ in true }
        return (activator, host)
    }

    @Test("a pause keeps the stream playing until the grace runs out")
    func pauseHoldsThenPauses() async throws {
        let (activator, host) = attached(grace: .milliseconds(300))
        defer { activator.detach() }
        host.play()
        #expect(activator.isPlayingStream)
        host.pause()
        #expect(activator.isPlayingStream)
        try await waitFor { !activator.isPlayingStream }
        host.play()
        #expect(activator.isPlayingStream)
    }

    @Test("a resume inside the grace keeps the stream playing past it")
    func resumeInsideGraceCancelsThePause() async throws {
        let (activator, host) = attached(grace: .milliseconds(300))
        defer { activator.detach() }
        host.play()
        host.pause()
        // No sleep in between: any wait here can outlast the grace on a loaded runner.
        host.play()
        try await Task.sleep(for: .milliseconds(700))
        #expect(activator.isPlayingStream)
    }

    @Test("a paused host never starts the stream")
    func pausedHostDoesNotStart() {
        let (activator, _) = attached(grace: .seconds(60))
        defer { activator.detach() }
        #expect(!activator.isPlayingStream)
    }

    @Test("detaching during the grace stops the stream at once")
    func detachEndsTheGrace() {
        let (activator, host) = attached(grace: .seconds(60))
        host.play()
        host.pause()
        activator.detach()
        #expect(!activator.isPlayingStream)
    }

    @Test("a route that is not HDMI never plays it")
    func nonHDMIRouteStaysOff() {
        let (activator, host) = attached(grace: .seconds(60), ports: ["AirPlay"])
        defer { activator.detach() }
        host.play()
        #expect(!activator.isPlayingStream)
    }

    @Test("the default grace ends before the shortest tvOS screen saver delay")
    func defaultGraceIsBounded() {
        #expect(AtmosOutputActivator.defaultPauseGrace > .seconds(10))
        #expect(AtmosOutputActivator.defaultPauseGrace < .seconds(120))
    }

    @Test("the software host's renderer path rides through a pause for the same grace")
    func rendererPathHoldsThroughPause() async throws {
        var playing: Bool? = true
        let activator = AtmosOutputActivator(outputPortTypes: { ["HDMIOutput"] }, pauseGrace: .milliseconds(300))
        defer { activator.detach() }
        activator.attachRenderer { playing }
        #expect(activator.isPlayingStream)
        playing = false
        activator.refresh()
        #expect(activator.isPlayingStream)
        try await waitFor { !activator.isPlayingStream }
        playing = true
        activator.refresh()
        #expect(activator.isPlayingStream)
        playing = false
        activator.refresh()
        playing = nil
        activator.refresh()
        #expect(!activator.isPlayingStream)
    }
}
