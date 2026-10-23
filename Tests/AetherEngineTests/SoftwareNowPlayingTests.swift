import Testing
import MediaPlayer
@testable import AetherEngine

@MainActor
private final class RecordingTransport: SoftwareNowPlayingTransport {
    var state: PlaybackState = .paused
    var currentTime: Double = 0
    var duration: Double = 100
    var isLive = false
    var calls: [String] = [] { didSet { resumeWaiter() } }
    private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?
    func play() { calls.append("play") }
    func pause() { calls.append("pause") }
    func togglePlayPause() { calls.append("toggle") }
    func seek(to seconds: Double) async { calls.append("seek:\(seconds)") }

    /// Suspends until `count` calls were recorded; the commands run in tasks the test cannot await.
    func waitForCalls(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { waiter = (count, $0) }
    }
    private func resumeWaiter() {
        guard let w = waiter, calls.count >= w.count else { return }
        waiter = nil
        w.continuation.resume()
    }
}

private final class FakeCommand: RemoteCommandHandle {
    var isEnabled: Bool
    var targets = 0
    init(enabled: Bool) { isEnabled = enabled }
    func addTarget(handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) -> Any {
        targets += 1
        return NSObject()
    }
    func removeTarget(_ target: Any?) { targets -= 1 }
}

private final class FakeSurface: RemoteCommandSurface {
    let all = [FakeCommand(enabled: false), FakeCommand(enabled: true), FakeCommand(enabled: false),
               FakeCommand(enabled: true), FakeCommand(enabled: false), FakeCommand(enabled: false)]
    var play: any RemoteCommandHandle { all[0] }
    var pause: any RemoteCommandHandle { all[1] }
    var togglePlayPause: any RemoteCommandHandle { all[2] }
    var skipForward: any RemoteCommandHandle { all[3] }
    var skipBackward: any RemoteCommandHandle { all[4] }
    var changePosition: any RemoteCommandHandle { all[5] }
    var interval: Double?
    func setSkipInterval(_ seconds: Double) { interval = seconds }
}

private final class FakeInfoCenter: NowPlayingInfoStore {
    var nowPlayingInfo: [String: Any]?
    var playbackState: MPNowPlayingPlaybackState = .unknown
}

@MainActor
private final class RecordingSink: SoftwareNowPlayingSink {
    var handler: (@MainActor (SoftwareNowPlayingCommand) -> Void)?
    var seekingEnabled: Bool?
    var published: [(info: [String: Any]?, state: MPNowPlayingPlaybackState)] = []
    var deactivated = false
    var skipInterval: Double?
    func activate(skipInterval: Double, handler: @escaping @MainActor (SoftwareNowPlayingCommand) -> Void) {
        self.skipInterval = skipInterval
        self.handler = handler
    }
    func setSeekingEnabled(_ enabled: Bool) { seekingEnabled = enabled }
    func publish(info: [String: Any]?, playbackState: MPNowPlayingPlaybackState) {
        published.append((info, playbackState))
    }
    func deactivate() { deactivated = true }
}

private func rate(_ info: [String: Any]?) -> Double? { info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double }
private func elapsed(_ info: [String: Any]?) -> Double? { info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double }

@Suite("SoftwareNowPlaying (state mapping and command routing for the software host)")
@MainActor
struct SoftwareNowPlayingTests {

    @Test("playing publishes elapsed, duration and the requested speed")
    func playing() {
        let info = SoftwareNowPlayingPolicy.info(state: .playing, elapsed: 42, duration: 100, isLive: false,
                                                 isBuffering: false, requestedRate: 1.5, identity: [:])
        #expect(elapsed(info) == 42)
        #expect(rate(info) == 1.5)
        #expect(info?[MPMediaItemPropertyPlaybackDuration] as? Double == 100)
    }

    @Test("paused, seeking, loading and buffering all publish rate 0")
    func notAdvancing() {
        for state in [PlaybackState.paused, .seeking, .loading] {
            let info = SoftwareNowPlayingPolicy.info(state: state, elapsed: 7, duration: 100, isLive: false,
                                                     isBuffering: false, requestedRate: 1, identity: [:])
            #expect(rate(info) == 0)
            #expect(elapsed(info) == 7)
        }
        let stalled = SoftwareNowPlayingPolicy.info(state: .playing, elapsed: 7, duration: 100, isLive: false,
                                                    isBuffering: true, requestedRate: 1, identity: [:])
        #expect(rate(stalled) == 0)
    }

    @Test("end of media parks the position at the duration with rate 0 and keeps the card paused")
    func ended() {
        let info = SoftwareNowPlayingPolicy.info(state: .ended, elapsed: 99.2, duration: 100, isLive: false,
                                                 isBuffering: false, requestedRate: 1, identity: [:])
        #expect(elapsed(info) == 100)
        #expect(rate(info) == 0)
        #expect(SoftwareNowPlayingPolicy.playbackState(state: .ended, intendedPlaying: true) == .paused)
    }

    @Test("idle and error clear the card")
    func clears() {
        for state in [PlaybackState.idle, .error("x")] {
            #expect(SoftwareNowPlayingPolicy.info(state: state, elapsed: 0, duration: 0, isLive: false,
                                                  isBuffering: false, requestedRate: 1, identity: [:]) == nil)
        }
    }

    @Test("live sources carry no duration and the live flag")
    func live() {
        let info = SoftwareNowPlayingPolicy.info(state: .playing, elapsed: 5, duration: 0, isLive: true,
                                                 isBuffering: false, requestedRate: 1,
                                                 identity: [MPMediaItemPropertyPlaybackDuration: 9.0])
        #expect(info?[MPMediaItemPropertyPlaybackDuration] == nil)
        #expect(info?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true)
        #expect(SoftwareNowPlayingPolicy.seekingEnabled(isLive: true) == false)
    }

    @Test("identity keys survive into the published info")
    func identity() {
        let info = SoftwareNowPlayingPolicy.info(state: .paused, elapsed: 0, duration: 10, isLive: false,
                                                 isBuffering: false, requestedRate: 1,
                                                 identity: [MPMediaItemPropertyTitle: "Title"])
        #expect(info?[MPMediaItemPropertyTitle] as? String == "Title")
    }

    @Test("a seek keeps the transport glyph of the last play or pause intent")
    func glyphThroughSeek() {
        #expect(SoftwareNowPlayingPolicy.playbackState(state: .seeking, intendedPlaying: true) == .playing)
        #expect(SoftwareNowPlayingPolicy.playbackState(state: .seeking, intendedPlaying: false) == .paused)
    }

    @Test("drift beyond the tolerance republishes, extrapolation within it does not")
    func drift() {
        #expect(!SoftwareNowPlayingPolicy.needsRepublish(publishedElapsed: 10, publishedRate: 1,
                                                         secondsSincePublish: 5, currentElapsed: 15.4))
        #expect(SoftwareNowPlayingPolicy.needsRepublish(publishedElapsed: 10, publishedRate: 1,
                                                        secondsSincePublish: 5, currentElapsed: 60))
        // Paused: a seek moves the clock while the extrapolation stays put.
        #expect(SoftwareNowPlayingPolicy.needsRepublish(publishedElapsed: 10, publishedRate: 0,
                                                        secondsSincePublish: 5, currentElapsed: 30))
    }

    @Test("commands map to host actions")
    func commands() async {
        let t = RecordingTransport()
        t.currentTime = 50
        SoftwareNowPlayingPolicy.perform(.play, on: t)
        SoftwareNowPlayingPolicy.perform(.pause, on: t)
        SoftwareNowPlayingPolicy.perform(.togglePlayPause, on: t)
        SoftwareNowPlayingPolicy.perform(.skip(seconds: 10), on: t)
        SoftwareNowPlayingPolicy.perform(.skip(seconds: -10), on: t)
        SoftwareNowPlayingPolicy.perform(.changePosition(to: 77), on: t)
        await t.waitForCalls(6)
        #expect(t.calls.prefix(3) == ["play", "pause", "toggle"])
        #expect(Set(t.calls.dropFirst(3)) == ["seek:60.0", "seek:40.0", "seek:77.0"])
    }

    @Test("skip and position targets clamp to the item")
    func clamps() {
        #expect(SoftwareNowPlayingPolicy.skipTarget(current: 3, delta: -10, duration: 100) == 0)
        #expect(SoftwareNowPlayingPolicy.skipTarget(current: 95, delta: 10, duration: 100) == 100)
        #expect(SoftwareNowPlayingPolicy.skipTarget(current: 500, delta: 0, duration: 100) == 100)
    }

    @Test("controller publishes on refresh and routes a remote command to the transport")
    func controller() async {
        let t = RecordingTransport(), sink = RecordingSink()
        let c = SoftwareNowPlayingController(sink: sink, transport: t)
        c.start(skipInterval: 15)
        #expect(sink.skipInterval == 15)
        t.state = .playing; t.currentTime = 12
        c.refresh(requestedRate: 2, isBuffering: false)
        #expect(rate(sink.published.last?.info) == 2)
        #expect(sink.published.last?.state == .playing)
        #expect(sink.seekingEnabled == true)
        sink.handler?(.changePosition(to: 30))
        await t.waitForCalls(1)
        #expect(t.calls == ["seek:30.0"])
        c.stop()
        #expect(sink.deactivated)
    }

    @Test("controller republishes a clock jump but not steady playback")
    func controllerClock() {
        var now: TimeInterval = 1000
        let t = RecordingTransport(), sink = RecordingSink()
        let c = SoftwareNowPlayingController(sink: sink, transport: t, uptime: { now })
        t.state = .playing; t.currentTime = 10
        c.refresh(requestedRate: 1, isBuffering: false)
        let base = sink.published.count
        now += 3
        c.clockTick(13.1)
        #expect(sink.published.count == base)
        now += 1
        t.currentTime = 90
        c.clockTick(90)
        #expect(sink.published.count == base + 1)
        #expect(elapsed(sink.published.last?.info) == 90)
    }

    @Test("a clock that stands still while playing publishes rate 0, and the next advance restores it")
    func stallAndRecover() {
        var now: TimeInterval = 1000
        let t = RecordingTransport(), sink = RecordingSink()
        let c = SoftwareNowPlayingController(sink: sink, transport: t, uptime: { now })
        t.state = .playing; t.currentTime = 10
        c.refresh(requestedRate: 1, isBuffering: false)
        now += 0.3
        c.clockTick(10)
        #expect(rate(sink.published.last?.info) == 1)
        now += 0.3
        c.clockTick(10)
        #expect(rate(sink.published.last?.info) == 0)
        #expect(sink.published.last?.state == .playing)
        now += 0.1
        c.clockTick(10.4)
        #expect(rate(sink.published.last?.info) == 1)
        #expect(elapsed(sink.published.last?.info) == 10.4)
    }

    @Test("a paused clock is not a stall")
    func pausedIsNotAStall() {
        var now: TimeInterval = 1000
        let t = RecordingTransport(), sink = RecordingSink()
        let c = SoftwareNowPlayingController(sink: sink, transport: t, uptime: { now })
        t.state = .paused; t.currentTime = 10
        c.refresh(requestedRate: 1, isBuffering: false)
        let base = sink.published.count
        now += 5
        c.clockTick(10)
        #expect(sink.published.count == base)
    }

    @Test("only the latest identity ticket is applied")
    func identityTickets() {
        let t = RecordingTransport(), sink = RecordingSink()
        let c = SoftwareNowPlayingController(sink: sink, transport: t)
        t.state = .paused
        let first = c.beginIdentityUpdate()
        let second = c.beginIdentityUpdate()
        c.setIdentity([MPMediaItemPropertyTitle: "new"], ticket: second)
        c.setIdentity([MPMediaItemPropertyTitle: "old"], ticket: first)
        #expect(sink.published.last?.info?[MPMediaItemPropertyTitle] as? String == "new")
        #expect(sink.published.count == 1)
    }

    @Test("the engine builds no publisher by default")
    func engineDefaultOff() throws {
        let engine = try AetherEngine()
        #expect(!engine.ownsSoftwareNowPlaying)
        engine.startSoftwareNowPlaying()
        #expect(engine.softwareNowPlaying == nil)
        #expect(!engine.softwareNowPlayingActive)
    }

    @Test("a secondary engine never takes Now-Playing even when opted in")
    func engineSecondaryRole() throws {
        let engine = try AetherEngine()
        engine.ownsSoftwareNowPlaying = true
        var options = engine.loadedOptions
        options.sharedOutputRole = .secondary
        engine.setLoadedOptionsForTesting(options)
        engine.startSoftwareNowPlaying()
        #expect(engine.softwareNowPlaying == nil)
        #expect(!engine.softwareNowPlayingActive)
    }

    @Test("an opted-in primary engine publishes, and stopping releases it")
    func enginePrimaryOptIn() throws {
        let engine = try AetherEngine()
        engine.ownsSoftwareNowPlaying = true
        engine.makeSoftwareNowPlayingSink = { RecordingSink() }
        engine.startSoftwareNowPlaying()
        #expect(engine.softwareNowPlaying != nil)
        #expect(engine.softwareNowPlayingActive)
        engine.stopSoftwareNowPlaying()
        #expect(engine.softwareNowPlaying == nil)
        #expect(!engine.softwareNowPlayingActive)
    }

    @Test("a backward reposition counts as the clock moving, not a stall")
    func backwardRepositionIsNotAStall() {
        var now: TimeInterval = 1000
        let t = RecordingTransport(), sink = RecordingSink()
        let c = SoftwareNowPlayingController(sink: sink, transport: t, uptime: { now })
        t.state = .playing; t.currentTime = 100
        c.refresh(requestedRate: 1, isBuffering: false)
        now += 0.25
        c.clockTick(40)
        now += 0.25
        c.clockTick(40.25)
        #expect(rate(sink.published.last?.info) == 1)
        #expect(elapsed(sink.published.last?.info) == 40)
    }

    @Test("the sink restores command enablement and removes only its own targets on deactivate")
    func sinkRestoresCommands() {
        let surface = FakeSurface(), center = FakeInfoCenter()
        let sink = SystemNowPlayingSink(infoCenter: center, commands: surface)
        sink.activate(skipInterval: 15) { _ in }
        #expect(surface.interval == 15)
        #expect(surface.all.allSatisfy { $0.isEnabled && $0.targets == 1 })
        sink.setSeekingEnabled(false)
        sink.deactivate()
        #expect(surface.all.map(\.isEnabled) == [false, true, false, true, false, false])
        #expect(surface.all.allSatisfy { $0.targets == 0 })
    }

    @Test("deactivate clears the card only while the center still holds what the sink published")
    func sinkClearsOnlyItsOwnCard() {
        let surface = FakeSurface(), center = FakeInfoCenter()
        let sink = SystemNowPlayingSink(infoCenter: center, commands: surface)
        sink.activate(skipInterval: 10) { _ in }
        let mine: [String: Any] = [
            MPMediaItemPropertyTitle: "Mine", MPMediaItemPropertyPlaybackDuration: 60.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 5.0, MPNowPlayingInfoPropertyPlaybackRate: 1.0]
        sink.publish(info: mine, playbackState: .playing)
        sink.deactivate()
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)

        // A foreign card survives: different title, same title and duration but another elapsed value,
        // and one with no title or duration at all.
        var sameTitle = mine
        sameTitle[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 33.0
        let foreign: [[String: Any]] = [
            [MPMediaItemPropertyTitle: "Someone else", MPNowPlayingInfoPropertyElapsedPlaybackTime: 5.0,
             MPNowPlayingInfoPropertyPlaybackRate: 1.0],
            sameTitle,
            [MPNowPlayingInfoPropertyElapsedPlaybackTime: 5.0, MPNowPlayingInfoPropertyPlaybackRate: 1.0]]
        for card in foreign {
            sink.activate(skipInterval: 10) { _ in }
            sink.publish(info: mine, playbackState: .playing)
            center.nowPlayingInfo = card
            center.playbackState = .paused
            sink.deactivate()
            #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double
                    == card[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double)
            #expect(center.nowPlayingInfo?.count == card.count)
            #expect(center.playbackState == .paused)
        }

        // A card with no elapsed value never matches, even against an identical one.
        let bare: [String: Any] = [MPMediaItemPropertyTitle: "Live"]
        sink.activate(skipInterval: 10) { _ in }
        sink.publish(info: bare, playbackState: .playing)
        sink.deactivate()
        #expect(center.nowPlayingInfo != nil)
    }

    @Test("a command someone else re-enabled or disabled meanwhile keeps its state on deactivate")
    func sinkRespectsForeignEnablement() {
        let surface = FakeSurface(), center = FakeInfoCenter()
        let sink = SystemNowPlayingSink(infoCenter: center, commands: surface)
        sink.activate(skipInterval: 10) { _ in }
        surface.all[0].isEnabled = false   // play: we wrote true, a foreign owner turned it off
        sink.deactivate()
        #expect(surface.all[0].isEnabled == false)
        #expect(surface.all[1].isEnabled == true)   // pause: untouched, restored to its prior true
        #expect(surface.all[2].isEnabled == false)  // toggle: prior false restored
    }
}
