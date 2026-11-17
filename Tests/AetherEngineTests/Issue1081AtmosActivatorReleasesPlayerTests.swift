import AVFoundation
import Testing
@testable import AetherEngine

/// AE#1081: the activator's player outlived the rendered session on a reused engine. Paused and
/// emptied, it still held the Apple TV's HDMI route in 32 channels, so the next title's 5.1 PCM reached
/// the receiver as Dolby Atmos. The player now exists only while the stream is wanted.
@MainActor
@Suite("The Atmos output activator lets its player go with the stream (#1081)", .serialized, .timeLimit(.minutes(3)))
struct Issue1081AtmosActivatorReleasesPlayerTests {

    private func attached(ports: [String] = ["HDMIOutput"]) -> (AtmosOutputActivator, AVPlayer) {
        let host = AVPlayer(playerItem: AVPlayerItem(url: AtmosOutputActivator.silentAtmosStream))
        host.isMuted = true
        host.actionAtItemEnd = .none
        let activator = AtmosOutputActivator(outputPortTypes: { ports }, pauseGrace: .seconds(60))
        activator.attach(to: host) { _ in true }
        return (activator, host)
    }

    @Test("no player before the stream is wanted")
    func noPlayerUntilPlaying() {
        let (activator, _) = attached()
        defer { activator.detach() }
        #expect(!activator.holdsStreamPlayer)
    }

    @Test("detaching, which stop() reaches through currentAVPlayer going nil, drops the player")
    func detachDropsThePlayer() {
        let (activator, host) = attached()
        host.play()
        #expect(activator.holdsStreamPlayer)
        activator.detach()
        #expect(!activator.holdsStreamPlayer)
        #expect(!activator.isPlayingStream)
    }

    @Test("a host item that is not a rendered bed drops the player")
    func nonBedItemDropsThePlayer() {
        let (activator, host) = attached()
        defer { activator.detach() }
        host.play()
        #expect(activator.holdsStreamPlayer)
        host.replaceCurrentItem(with: nil)
        #expect(!activator.holdsStreamPlayer)
    }

    @Test("the next rendered session builds a fresh player")
    func nextSessionBuildsAgain() {
        let (activator, host) = attached()
        host.play()
        activator.detach()
        #expect(!activator.holdsStreamPlayer)
        activator.attach(to: host) { _ in true }
        defer { activator.detach() }
        #expect(activator.holdsStreamPlayer)
        #expect(activator.isPlayingStream)
    }

    @Test("a pause inside the grace keeps the player (#848)")
    func pauseKeepsThePlayer() {
        let (activator, host) = attached()
        defer { activator.detach() }
        host.play()
        host.pause()
        #expect(activator.holdsStreamPlayer)
    }

    @Test("the software host's session ending drops the player")
    func rendererEndDropsThePlayer() {
        var playing: Bool? = true
        let activator = AtmosOutputActivator(outputPortTypes: { ["HDMIOutput"] }, pauseGrace: .seconds(60))
        defer { activator.detach() }
        activator.attachRenderer { playing }
        #expect(activator.holdsStreamPlayer)
        playing = nil
        activator.refresh()
        #expect(!activator.holdsStreamPlayer)
    }
}
