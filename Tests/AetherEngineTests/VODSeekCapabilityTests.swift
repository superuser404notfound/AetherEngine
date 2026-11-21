import Foundation
import Combine
import Testing
@testable import AetherEngine

@Suite(.timeLimit(.minutes(3)))
@MainActor
struct VODSeekCapabilityTests {
    @Test("A known duration never makes a forward-only source seekable")
    func rejectsForwardOnlySeek() async throws {
        let engine = try AetherEngine()
        engine.state = .playing
        engine.isSessionReady = true
        engine.duration = 493.6
        engine.isSourceSeekable = false
        engine.clock.currentTime = 14.99
        engine.clock.sourceTime = 4.99 // sequential source PTS can differ from display time
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel(); engine.stop() }
        #expect(!engine.canSeek)
        await engine.seek(to: 271.7)
        #expect(events.map(\.outcome) == [.rejected(.sourceNotSeekable)])
        #expect(engine.currentTime == 14.99)
        #expect(engine.state == .playing)
        #expect(!engine.isSeeking)
    }

    @Test("Seekability belongs to this load and clears at stop")
    func capabilityLifecycle() throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.duration = 493.6
        engine.isSessionReady = true
        engine.state = .playing
        #expect(!engine.canSeek)
        engine.isSourceSeekable = true
        #expect(engine.canSeek)
        engine.isSourceSeekable = false
        #expect(!engine.canSeek)
        engine.stop()
        #expect(engine.isSourceSeekable == nil)
        #expect(!engine.canSeek)
    }

    @Test("Native seek completion requires success and an actual landing")
    func completionValidation() {
        #expect(!NativeAVPlayerHost.seekCompletionReachedTarget(finished: true, actual: 14.99, target: 271.7))
        #expect(!NativeAVPlayerHost.seekCompletionReachedTarget(finished: false, actual: 271.7, target: 271.7))
        #expect(!NativeAVPlayerHost.seekCompletionReachedTarget(finished: true, actual: 271.7, target: 14.99))
        #expect(!NativeAVPlayerHost.seekCompletionReachedTarget(finished: true, actual: .nan, target: 14.99))
        #expect(NativeAVPlayerHost.seekCompletionReachedTarget(finished: true, actual: 271.72, target: 271.7))
        #expect(NativeAVPlayerHost.seekCompletionReachedTarget(finished: true, actual: 14.99, target: 15))
    }
    @Test("A deferred seek drops its optimistic clock when the source proves forward-only")
    func deferredSeekRejectedAfterProbe() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        engine.duration = 493.6
        engine.state = .loading
        engine.clock.sourceTime = 5
        await engine.seek(to: 271.7)
        #expect(engine.isSeeking)
        engine.isSourceSeekable = false
        engine.state = .playing
        try await waitFor { !engine.isSeeking }
        #expect(engine.currentTime == 5)
    }

    @Test("An audio switch keeps a seekable source seekable on both decode paths",
          arguments: [DecodePath.automatic, DecodePath.software])
    func audioSwitchKeepsSeekability(path: DecodePath) async throws {
        // On the CI run of 2026-11-21 both cases ran into the suite's time limit at once and the log
        // could not say where. The watchdog names the step it hung in. A plain Task, so the issue is
        // filed against this test; the wait itself runs off the main actor, which may be the stuck part.
        let step = StepMarker("load")
        let watchdog = Task { await Self.reportIfStuck(step, path: path) }
        defer { watchdog.cancel() }
        let origin = try ProbeHTTPTestOrigin(data: TwoAudioTrackFixture.data)
        let engine = try AetherEngine()
        defer { engine.stop(); origin.stop() }
        var options = LoadOptions()
        options.preferredDecodePath = path
        options.suppressDisplayCriteria = true
        try await engine.load(url: URL(string: "http://127.0.0.1:\(origin.port)/two-audio.mkv")!, options: options)
        step.value = "seekable and playing"
        try await waitFor { engine.canSeek && engine.currentTime > 0.5 }
        // The clip is 6 s and plays in real time. On a starved CI pool the switch took long enough for
        // it to reach .ended, which refuses the seek for a reason this test is not about. Paused, it
        // cannot run out.
        step.value = "paused"
        engine.pause()
        try await waitFor { engine.state == .paused }
        let other = try #require(engine.audioTracks.first { $0.id != engine.activeAudioTrackIndex })
        step.value = "audio switch to \(other.id)"
        engine.selectAudioTrack(index: other.id)
        try await waitFor { engine.activeAudioTrackIndex == other.id && engine.isSessionReady }
        #expect(engine.isSourceSeekable == true)
        #expect(engine.canSeek)
        step.value = "seek to 4"
        await engine.seek(to: 4)
        step.value = "landing past 3.5"
        try await waitFor { engine.currentTime > 3.5 }
        #expect(abs(engine.currentTime - 4) < 1)
    }

    nonisolated private static func reportIfStuck(_ step: StepMarker, path: DecodePath) async {
        do { try await Task.sleep(for: .seconds(150)) } catch { return }
        Issue.record("audio switch test (\(path)) still at step '\(step.value)' after 150 s")
    }
}

/// Which step a long test is in, readable from the detached watchdog.
private final class StepMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String
    init(_ initial: String) { current = initial }
    var value: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
