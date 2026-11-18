import AVFoundation
import Combine
import Foundation
import Testing
@testable import AetherEngine

@MainActor
private final class DepartureRecordingTransport: SoftwareNowPlayingTransport {
    var state: PlaybackState = .playing
    var currentTime: Double = 0
    var duration: Double = 100
    var isLive = false
    var hostSeeks: [Double] = []
    var remoteSeeks: [(target: Double, departure: Double)] = []
    private var waiter: CheckedContinuation<Void, Never>?
    func play() {}
    func pause() {}
    func togglePlayPause() {}
    func seek(to seconds: Double) async { hostSeeks.append(seconds) }
    func seekFromRemoteCommand(to seconds: Double, departure: Double) async {
        remoteSeeks.append((seconds, departure))
        waiter?.resume()
        waiter = nil
    }
    func waitForRemoteSeek() async {
        if !remoteSeeks.isEmpty { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

/// AE#1088: a seek the engine makes for a system remote command or a PiP skip button is marked as such,
/// and every seek says where the playhead stood when it was asked for.
@Suite("AE#1088 remote command seek origin", .timeLimit(.minutes(3)))
struct Issue1088RemoteSeekOriginTests {

    @MainActor
    @Test("a remote skip seeks through the remote path with the position it was computed from")
    func skipCarriesDeparture() async {
        let t = DepartureRecordingTransport()
        t.currentTime = 50
        SoftwareNowPlayingPolicy.perform(.skip(seconds: -30), on: t)
        await t.waitForRemoteSeek()
        #expect(t.hostSeeks.isEmpty)
        #expect(t.remoteSeeks.first?.target == 20)
        #expect(t.remoteSeeks.first?.departure == 50)
    }

    @MainActor
    @Test("a scrub from Control Center departs from the playhead, not from the position it asks for")
    func changePositionCarriesDeparture() async {
        let t = DepartureRecordingTransport()
        t.currentTime = 50
        SoftwareNowPlayingPolicy.perform(.changePosition(to: 12), on: t)
        await t.waitForRemoteSeek()
        #expect(t.remoteSeeks.first?.target == 12)
        #expect(t.remoteSeeks.first?.departure == 50)
    }

    @MainActor
    @Test("an intercepted command never reaches the engine's seek")
    func interceptedCommandDoesNotSeek() async throws {
        let engine = try AetherEngine()
        engine.nowPlayingCommandInterceptor = { _ in true }
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        SoftwareNowPlayingPolicy.perform(.skip(seconds: -10), on: engine)
        for _ in 0..<20 { await Task.yield() }

        #expect(events.isEmpty)
    }

    @MainActor
    @Test("a rejected remote seek still names its origin and departure")
    func rejectionNamesOrigin() async throws {
        let engine = try AetherEngine()
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        await engine.seekFromRemoteCommand(to: 5, departure: 35)   // state == .idle

        #expect(events.count == 1)
        #expect(events.first?.outcome == .rejected(.noActiveSession))
        #expect(events.first?.origin == .remoteCommand)
        #expect(events.first?.departure == 35)
    }

    @MainActor
    @Test("a remote skip stashed during load replays as a remote seek and keeps its departure")
    func stashedRemoteSkipKeepsOriginAndDeparture() async throws {
        let engine = try AetherEngine()
        engine.duration = 600
        engine.state = .loading
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        await engine.seekFromRemoteCommand(to: 20, departure: 50)
        // The stash publishes the target on the clock; the replay must not read that back as its start.
        #expect(engine.clock.currentTime == 20)
        engine.state = .playing
        for _ in 0..<200 {
            if events.count >= 4 { break }
            await Task.yield()
        }

        #expect(events.count == 4)
        #expect(events.map(\.origin) == [.deferred, .deferred, .remoteCommand, .remoteCommand])
        #expect(events.allSatisfy { $0.departure == 50 })
        #expect(events[2].outcome == .began)
        #expect(events[2].target == 20)
        if case .landed = events[3].outcome {} else { Issue.record("expected a landing, got \(events[3])") }
    }

    @MainActor
    @Test("a host seek reports the playhead it left from")
    func hostSeekReportsDeparture() async throws {
        let engine = try AetherEngine()
        engine.duration = 600
        engine.clock.currentTime = 75
        engine.state = .loading
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        await engine.seek(to: 300)

        #expect(events.first?.origin == .deferred)
        #expect(events.first?.departure == 75)
    }

    @MainActor
    @Test("a PiP skip button seeks with the pictureInPicture origin")
    func pipSkipOrigin() async throws {
        let engine = try AetherEngine()
        engine.duration = 600
        engine.clock.currentTime = 50
        engine.state = .loading
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }
        let source = SoftwarePiPSource(layer: AVSampleBufferDisplayLayer(), isLive: false, engine: engine)

        await source.skipAndWait(by: -15)
        engine.state = .playing
        for _ in 0..<200 {
            if events.count >= 4 { break }
            await Task.yield()
        }

        #expect(events.count >= 3)
        #expect(events.dropFirst(2).first?.origin == .pictureInPicture)
        #expect(events.dropFirst(2).first?.target == 35)
        #expect(events.dropFirst(2).first?.departure == 50)
    }

    @Test("remote and PiP seeks are held to the scrubber's contract on live, the rejoin is not")
    func liveContract() {
        #expect(AetherEngine.liveSeekRefusedWithoutDVR(origin: .remoteCommand, windowSeconds: nil))
        #expect(AetherEngine.liveSeekRefusedWithoutDVR(origin: .pictureInPicture, windowSeconds: nil))
        #expect(!AetherEngine.liveSeekRefusedWithoutDVR(origin: .liveRejoin, windowSeconds: nil))
    }

    @Test("the description names where a seek started")
    func descriptionCarriesDeparture() {
        let event = SeekEvent(id: 3, origin: .remoteCommand, outcome: .began, target: 20, departure: 50)
        #expect(event.description == "seek#3 remoteCommand began target=20.00 from=50.00")
        let plain = SeekEvent(id: 4, origin: .nativeScrub, outcome: .began, target: 20)
        #expect(plain.description == "seek#4 nativeScrub began target=20.00")
    }
}
