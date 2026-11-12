import Testing
import MediaPlayer
@testable import AetherEngine

/// #1041: one Now-Playing contract across the four hosts and the four platforms. Covers where each
/// route publishes, the track commands, the hand-over of the shared surface between engines, and the
/// card kept through the seam between two items.
@Suite("Issue 1041: unified Now-Playing routing")
@MainActor
struct NowPlayingRoutingTests {

    // MARK: - Routing

    @Test("each route publishes only where the host opted in, and a secondary never does")
    func plans() {
        let all = NowPlayingOptIns(software: true, videoSession: true, videoCommands: true, audio: true)
        let none = NowPlayingOptIns()
        func plan(_ kind: NowPlayingRouteKind, session: Bool, _ optIns: NowPlayingOptIns,
                  role: SharedOutputRole = .primary) -> NowPlayingPublisherPlan {
            AetherEngine.nowPlayingPlan(for: kind, hasSession: session, optIns: optIns, role: role)
        }
        for kind in [NowPlayingRouteKind.softwareVideo, .nativeVideo, .audioAVPlayer, .audioFFmpeg] {
            #expect(plan(kind, session: false, none) == .none)
            #expect(plan(kind, session: true, none) == .none)
            #expect(plan(kind, session: false, all, role: .secondary) == .none)
        }
        #expect(plan(.softwareVideo, session: false, all) == .sharedCenter(commands: true))
        #expect(plan(.audioFFmpeg, session: false, all) == .sharedCenter(commands: true))
        // AVPlayer audio: the session where one exists, the shared center on macOS.
        #expect(plan(.audioAVPlayer, session: true, all) == .sessionCommands)
        #expect(plan(.audioAVPlayer, session: false, all) == .sharedCenter(commands: true))
        // Native video: the session publishes by itself, so without the commands opt-in there is nothing to do.
        var sessionOnly = all
        sessionOnly.videoCommands = false
        #expect(plan(.nativeVideo, session: true, all) == .sessionCommands)
        #expect(plan(.nativeVideo, session: true, sessionOnly) == .none)
        #expect(plan(.nativeVideo, session: false, all) == .sharedCenter(commands: true))
        #expect(plan(.nativeVideo, session: false, sessionOnly) == .sharedCenter(commands: false))
        // The audio opt-in says nothing about video and the other way round.
        #expect(plan(.nativeVideo, session: false, NowPlayingOptIns(audio: true)) == .none)
        #expect(plan(.audioFFmpeg, session: false, NowPlayingOptIns(software: true, videoSession: true)) == .none)
    }

    // MARK: - Sink

    @Test("track handlers bind next and previous and turn the skip pair off; clearing them restores both")
    func trackCommands() {
        let surface = FakeSurface()
        let sink = SystemNowPlayingSink(infoCenter: FakeInfoCenter(), commands: surface)
        sink.activate(skipInterval: 10) { _ in }
        #expect(surface.next.targets == 0 && surface.previous.targets == 0)
        #expect(surface.skipForwardCommand.isEnabled && surface.skipBackwardCommand.isEnabled)

        sink.setTrackCommands(NowPlayingTrackAvailability(next: true, previous: false))
        #expect(surface.next.targets == 1 && surface.previous.targets == 1)
        #expect(surface.next.isEnabled && !surface.previous.isEnabled)
        #expect(!surface.skipForwardCommand.isEnabled && !surface.skipBackwardCommand.isEnabled)
        #expect(surface.changePositionCommand.isEnabled)

        sink.setTrackCommands(NowPlayingTrackAvailability(next: true, previous: true))
        #expect(surface.next.targets == 1, "a second availability change must not stack targets")
        #expect(surface.previous.isEnabled)

        sink.setTrackCommands(NowPlayingTrackAvailability())
        #expect(surface.next.targets == 0 && surface.previous.targets == 0)
        #expect(!surface.next.isEnabled && !surface.previous.isEnabled)
        #expect(surface.skipForwardCommand.isEnabled)
        sink.deactivate(clearCard: true)
    }

    @Test("without track handlers a host's own next and previous stay untouched")
    func foreignTrackCommandsUntouched() {
        let surface = FakeSurface()
        surface.next.isEnabled = true
        let sink = SystemNowPlayingSink(infoCenter: FakeInfoCenter(), commands: surface)
        sink.activate(skipInterval: 10) { _ in }
        sink.setSeekingEnabled(false)
        sink.deactivate(clearCard: true)
        #expect(surface.next.isEnabled)
        #expect(surface.next.targets == 0)
    }

    @Test("a live source keeps the track buttons but not scrubbing")
    func liveKeepsTracks() {
        let surface = FakeSurface()
        let sink = SystemNowPlayingSink(infoCenter: FakeInfoCenter(), commands: surface)
        sink.activate(skipInterval: 10) { _ in }
        sink.setTrackCommands(NowPlayingTrackAvailability(next: true, previous: true))
        sink.setSeekingEnabled(false)
        #expect(surface.next.isEnabled)
        #expect(!surface.changePositionCommand.isEnabled)
        #expect(!surface.skipForwardCommand.isEnabled)
    }

    @Test("a session sink binds commands but leaves the card to the session")
    func sessionSinkPublishesNothing() {
        let surface = FakeSurface()
        let sink = SystemNowPlayingSink(infoCenter: nil, commands: surface)
        sink.activate(skipInterval: 10) { _ in }
        sink.publish(info: [MPMediaItemPropertyTitle: "x"], playbackState: .playing)
        #expect(surface.playCommand.targets == 1)
        sink.deactivate(clearCard: true)
        #expect(surface.playCommand.targets == 0)
    }

    @Test("a sink without commands publishes the card and binds nothing")
    func cardOnlySink() {
        let center = FakeInfoCenter()
        let sink = SystemNowPlayingSink(infoCenter: center, commands: nil)
        sink.activate(skipInterval: 10) { _ in }
        sink.setTrackCommands(NowPlayingTrackAvailability(next: true, previous: true))
        sink.publish(info: card("A"), playbackState: .playing)
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "A")
        sink.deactivate(clearCard: true)
        #expect(center.nowPlayingInfo == nil)
    }

    @Test("a card kept through the seam survives deactivate and is cleared on request")
    func keptCard() {
        let center = FakeInfoCenter()
        let sink = SystemNowPlayingSink(infoCenter: center, commands: FakeSurface())
        sink.activate(skipInterval: 10) { _ in }
        sink.publish(info: card("A"), playbackState: .playing)
        sink.deactivate(clearCard: false)
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "A")
        sink.clearCard()
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)
    }

    // MARK: - Controller and policy

    @Test("an inactive controller publishes nothing until started")
    func inactiveController() {
        let transport = Transport(), sink = Sink()
        let controller = SoftwareNowPlayingController(sink: sink, transport: transport)
        transport.state = .playing
        controller.refresh(requestedRate: 1, isBuffering: false)
        controller.clockTick(5)
        #expect(sink.published.isEmpty)
        controller.start()
        controller.refresh(requestedRate: 1, isBuffering: false)
        #expect(sink.published.count == 1)
        controller.stop(clearCard: false)
        #expect(sink.clearedOnDeactivate == false)
    }

    @Test("the controller hands its track availability to every sink it starts")
    func controllerReappliesTracks() {
        let transport = Transport(), sink = Sink()
        let controller = SoftwareNowPlayingController(sink: sink, transport: transport)
        controller.setTracks(NowPlayingTrackAvailability(next: true, previous: false))
        #expect(sink.tracks == nil, "a stopped controller does not touch the sink")
        controller.start()
        #expect(sink.tracks == NowPlayingTrackAvailability(next: true, previous: false))
    }

    @Test("track and remote play commands reach the transport's remote entry points")
    func remoteEntryPoints() {
        let transport = Transport()
        SoftwareNowPlayingPolicy.perform(.play, on: transport)
        SoftwareNowPlayingPolicy.perform(.togglePlayPause, on: transport)
        SoftwareNowPlayingPolicy.perform(.nextTrack, on: transport)
        SoftwareNowPlayingPolicy.perform(.previousTrack, on: transport)
        #expect(transport.calls == ["remotePlay", "remoteToggle", "track:next", "track:previous"])
    }

    @Test("the host's interceptor sees every command first and can take it")
    func interceptor() throws {
        let engine = try AetherEngine()
        var seen: [NowPlayingRemoteCommand] = []
        engine.nowPlayingCommandInterceptor = { command in
            seen.append(command)
            return command == .nextTrack
        }
        var fired = 0
        engine.setNowPlayingTrackCommands(next: { fired += 1 }, previous: { fired += 1 })
        SoftwareNowPlayingPolicy.perform(.nextTrack, on: engine)
        SoftwareNowPlayingPolicy.perform(.previousTrack, on: engine)
        #expect(seen == [.nextTrack, .previousTrack])
        #expect(fired == 1, "the intercepted command must not reach the engine's own handling")
    }

    // MARK: - Arbiter

    @Test("the first engine to enlist holds the surface, a later one waits, and a claim moves it")
    func arbiter() {
        let arbiter = NowPlayingArbiter()
        let a = Client(), b = Client(), c = Client()
        #expect(arbiter.enlist(a))
        #expect(!arbiter.enlist(b))
        #expect(arbiter.isOwner(a))

        arbiter.claim(b)
        #expect(a.events == [false])
        #expect(b.events == [true])

        #expect(!arbiter.enlist(c))
        arbiter.claim(c)
        arbiter.release(c)
        #expect(b.events == [true, false, true], "the most recent claimant still waiting takes over")
        arbiter.release(b)
        #expect(a.events == [false, true])
        arbiter.release(a)
        #expect(arbiter.owner == nil)
    }

    @Test("claiming twice is a no-op, and releasing a waiting engine leaves the holder alone")
    func arbiterIdempotent() {
        let arbiter = NowPlayingArbiter()
        let a = Client(), b = Client()
        arbiter.claim(a)
        arbiter.claim(a)
        #expect(a.events == [true])
        arbiter.enlist(b)
        arbiter.release(b)
        #expect(a.events == [true])
        #expect(arbiter.isOwner(a))
    }

    // MARK: - Engine

    @Test("the audio route is off by default and publishes once opted in")
    func engineAudioOptIn() throws {
        let engine = try AetherEngine()
        engine.nowPlayingArbiter = NowPlayingArbiter()
        var sinks: [Sink] = []
        engine.makeNowPlayingSink = { _, _ in let s = Sink(); sinks.append(s); return s }
        engine.startNowPlayingPublisher(.audioFFmpeg, sessionCenter: nil)
        #expect(engine.nowPlayingController == nil)

        engine.ownsAudioNowPlaying = true
        engine.startNowPlayingPublisher(.audioFFmpeg, sessionCenter: nil)
        #expect(engine.nowPlayingController?.isActive == true)
        #expect(engine.nowPlayingRoute?.plan == .sharedCenter(commands: true))
        #expect(!engine.softwareNowPlayingActive, "the software flag stays about the software host")
        engine.stop()
        #expect(engine.nowPlayingController == nil)
        #expect(sinks.count == 1 && sinks[0].deactivated)
    }

    @Test("track handlers reach the engine's controller and the host's closures")
    func engineTrackHandlers() throws {
        let engine = try AetherEngine()
        engine.nowPlayingArbiter = NowPlayingArbiter()
        engine.ownsAudioNowPlaying = true
        let sink = Sink()
        engine.makeNowPlayingSink = { _, _ in sink }
        engine.startNowPlayingPublisher(.audioFFmpeg, sessionCenter: nil)
        var fired: [String] = []
        engine.setNowPlayingTrackCommands(next: { fired.append("next") }, previous: nil)
        #expect(sink.tracks == NowPlayingTrackAvailability(next: true, previous: false))
        engine.performTrackCommand(next: true)
        engine.performTrackCommand(next: false)
        #expect(fired == ["next"])
        engine.setNowPlayingTrackCommands(next: nil, previous: nil)
        #expect(sink.tracks == NowPlayingTrackAvailability())
        engine.stop()
    }

    @Test("a second engine waits for the first one's surface and takes it over when the first stops")
    func twoEngines() throws {
        let arbiter = NowPlayingArbiter()
        let first = try AetherEngine(), second = try AetherEngine()
        for engine in [first, second] {
            engine.nowPlayingArbiter = arbiter
            engine.ownsAudioNowPlaying = true
            engine.makeNowPlayingSink = { _, _ in Sink() }
        }
        first.startNowPlayingPublisher(.audioFFmpeg, sessionCenter: nil)
        second.startNowPlayingPublisher(.audioFFmpeg, sessionCenter: nil)
        #expect(first.nowPlayingController?.isActive == true)
        #expect(second.nowPlayingController?.isActive == false)

        second.claimNowPlaying()
        #expect(first.nowPlayingController?.isActive == false)
        #expect(second.nowPlayingController?.isActive == true)

        second.stop()
        #expect(first.nowPlayingController?.isActive == true)
        first.stop()
    }

    @Test("the previous item's card stays through a load seam and leaves with a route the engine does not own")
    func cardThroughSeam() throws {
        let engine = try AetherEngine()
        engine.nowPlayingArbiter = NowPlayingArbiter()
        engine.ownsAudioNowPlaying = true
        var sinks: [Sink] = []
        engine.makeNowPlayingSink = { _, _ in let s = Sink(); sinks.append(s); return s }
        engine.startNowPlayingPublisher(.audioFFmpeg, sessionCenter: nil)

        // Next track on the same route: the old card is not cleared, the new one is published over it.
        engine.startNowPlayingPublisher(.audioFFmpeg, sessionCenter: nil)
        #expect(sinks[0].clearedOnDeactivate == false)
        #expect(sinks[0].cardCleared == 0)
        #expect(engine.retainedNowPlayingSink == nil)

        // Then a video the engine does not own (an AVKit host): the kept card has to go.
        engine.stopNowPlayingPublisher(clearCard: false)
        #expect(engine.retainedNowPlayingSink != nil)
        engine.startNowPlayingPublisher(.nativeVideo, sessionCenter: nil)
        #expect(sinks[1].cardCleared == 1)
        #expect(engine.retainedNowPlayingSink == nil)
        engine.stop()
    }

    @Test("setNowPlayingInfo stages both routes on every platform, and stop() keeps only the audio one")
    func unifiedStaging() throws {
        let engine = try AetherEngine()
        engine.setNowPlayingInfo([MPMediaItemPropertyTitle: "Song"])
        #expect(engine.pendingVideoNowPlayingInfo[MPMediaItemPropertyTitle] as? String == "Song")
        #expect(engine.pendingAudioNowPlayingInfo[MPMediaItemPropertyTitle] as? String == "Song")
        engine.stop()
        #expect(engine.pendingVideoNowPlayingInfo.isEmpty)
        #expect(engine.pendingAudioNowPlayingInfo[MPMediaItemPropertyTitle] as? String == "Song")
        engine.setAudioNowPlayingInfo([:])
        #expect(engine.pendingAudioNowPlayingInfo.isEmpty)
    }
}

// MARK: - Fakes

private func card(_ title: String) -> [String: Any] {
    [MPMediaItemPropertyTitle: title, MPNowPlayingInfoPropertyElapsedPlaybackTime: 1.0,
     MPNowPlayingInfoPropertyPlaybackRate: 1.0]
}

@MainActor
private final class Client: SharedNowPlayingClient {
    var events: [Bool] = []
    func sharedNowPlayingOwnershipChanged(isOwner: Bool) { events.append(isOwner) }
}

@MainActor
private final class Transport: SoftwareNowPlayingTransport {
    var state: PlaybackState = .paused
    var currentTime: Double = 0
    var duration: Double = 100
    var isLive = false
    var calls: [String] = []
    func play() { calls.append("play") }
    func pause() { calls.append("pause") }
    func togglePlayPause() { calls.append("toggle") }
    func seek(to seconds: Double) async {}
    func playFromRemote() { calls.append("remotePlay") }
    func togglePlayPauseFromRemote() { calls.append("remoteToggle") }
    func performTrackCommand(next: Bool) { calls.append(next ? "track:next" : "track:previous") }
}

@MainActor
private final class Sink: SoftwareNowPlayingSink {
    var published: [[String: Any]?] = []
    var tracks: NowPlayingTrackAvailability?
    var deactivated = false
    var clearedOnDeactivate: Bool?
    var cardCleared = 0
    func activate(skipInterval: Double, handler: @escaping @MainActor (NowPlayingRemoteCommand) -> Void) {}
    func setSeekingEnabled(_ enabled: Bool) {}
    func setTrackCommands(_ tracks: NowPlayingTrackAvailability) { self.tracks = tracks }
    func publish(info: [String: Any]?, playbackState: MPNowPlayingPlaybackState) { published.append(info) }
    func deactivate(clearCard: Bool) { deactivated = true; clearedOnDeactivate = clearCard }
    func clearCard() { cardCleared += 1 }
}

private final class FakeInfoCenter: NowPlayingInfoStore {
    var nowPlayingInfo: [String: Any]?
    var playbackState: MPNowPlayingPlaybackState = .unknown
}

private final class FakeCommand: RemoteCommandHandle {
    var isEnabled: Bool
    var targets = 0
    init(enabled: Bool = false) { isEnabled = enabled }
    func addTarget(handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) -> Any {
        targets += 1
        return NSObject()
    }
    func removeTarget(_ target: Any?) { targets -= 1 }
}

private final class FakeSurface: RemoteCommandSurface {
    let playCommand = FakeCommand(), pauseCommand = FakeCommand(), toggleCommand = FakeCommand()
    let skipForwardCommand = FakeCommand(), skipBackwardCommand = FakeCommand()
    let changePositionCommand = FakeCommand(), next = FakeCommand(), previous = FakeCommand()
    var play: any RemoteCommandHandle { playCommand }
    var pause: any RemoteCommandHandle { pauseCommand }
    var togglePlayPause: any RemoteCommandHandle { toggleCommand }
    var skipForward: any RemoteCommandHandle { skipForwardCommand }
    var skipBackward: any RemoteCommandHandle { skipBackwardCommand }
    var changePosition: any RemoteCommandHandle { changePositionCommand }
    var nextTrack: any RemoteCommandHandle { next }
    var previousTrack: any RemoteCommandHandle { previous }
    func setSkipInterval(_ seconds: Double) {}
}
