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
        // The watchdog names the step a hang sits in and what the engine last looked like. A plain
        // Task, so the issue is filed against this test; the wait itself runs off the main actor.
        let step = StepMarker("load")
        let watchdog = Task { await Self.reportIfStuck(step, path: path) }
        defer { watchdog.cancel() }
        let origin = try ProbeHTTPTestOrigin(data: TwoAudioTrackFixture.data)
        let engine = try AetherEngine()
        defer { engine.stop(); origin.stop() }
        var options = LoadOptions()
        options.preferredDecodePath = path
        options.suppressDisplayCriteria = true
        // Mounted paused, the 6 s clip cannot reach .ended (never seekable) while a slow runner keeps
        // the main actor from this test longer than the clip lasts.
        options.autoplay = false
        try await engine.load(url: URL(string: "http://127.0.0.1:\(origin.port)/two-audio.mkv")!, options: options)
        step.value = "seekable and paused"
        try await step.wait(engine) { engine.canSeek && engine.state == .paused }
        // Off position 0, so the switch rebuilds from a resume point inside the clip.
        step.value = "seek to 1.5"
        step.record(engine)
        await engine.seek(to: 1.5)
        step.value = "landing past 1"
        try await step.wait(engine) { engine.currentTime > 1 && !engine.isSeeking }
        let other = try #require(engine.audioTracks.first { $0.id != engine.activeAudioTrackIndex })
        step.value = "audio switch to \(other.id)"
        step.record(engine)
        engine.selectAudioTrack(index: other.id)
        try await step.wait(engine) { engine.activeAudioTrackIndex == other.id && engine.isSessionReady }
        // This is the line that catches #1086. canSeek treats an unknown seekability as seekable, so
        // the expectations after it would pass with the bug back in.
        #expect(engine.isSourceSeekable == true)
        #expect(engine.canSeek)
        #expect(engine.state == .paused, "the rebuild keeps the paused transport")
        step.value = "seek to 4"
        step.record(engine)
        await engine.seek(to: 4)
        step.value = "landing past 3.5"
        try await step.wait(engine) { engine.currentTime > 3.5 }
        #expect(abs(engine.currentTime - 4) < 1)
    }

    nonisolated private static func reportIfStuck(_ step: StepMarker, path: DecodePath) async {
        do { try await Task.sleep(for: .seconds(150)) } catch { return }
        Issue.record("audio switch test (\(path)) stuck after 150 s: \(step.report())")
    }
}

/// The step a long test is in, and the engine state the test last read, labelled with the step it
/// was read in and how long ago, so a main actor that stopped running the test shows as an old
/// reading. Readable from the watchdog off the main actor.
private final class StepMarker: @unchecked Sendable {
    private struct Reading {
        var step: String
        var at: ContinuousClock.Instant
        var state: PlaybackState
        var phase: PlaybackPhase
        var canSeek, sessionReady, buffering, seeking, live, sequentialOrigin: Bool
        var sourceSeekable: Bool?
        var duration, time: Double
        var audio: Int?
    }

    private let lock = NSLock()
    private var current: String
    private var last: Reading?
    private var checks = 0
    init(_ initial: String) { current = initial }

    var value: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue; checks = 0 } }
    }

    /// `waitFor` that records the engine before every check.
    @MainActor
    func wait(_ engine: AetherEngine, _ condition: () -> Bool) async throws {
        try await waitFor {
            record(engine)
            return condition()
        }
    }

    /// One reading, also taken right before an awaited engine call, so a hang inside it still has one.
    @MainActor
    func record(_ engine: AetherEngine) {
        let reading = Reading(
            step: value, at: .now, state: engine.state, phase: engine.playbackPhase,
            canSeek: engine.canSeek, sessionReady: engine.isSessionReady, buffering: engine.isBuffering,
            seeking: engine.isSeeking, live: engine.isLive,
            sequentialOrigin: engine.loadedOptions.sequentialOrigin,
            sourceSeekable: engine.isSourceSeekable, duration: engine.duration,
            time: engine.currentTime, audio: engine.activeAudioTrackIndex)
        lock.withLock {
            last = reading
            checks += 1
        }
    }

    /// The step and the last reading, taken under one lock so they cannot come from different steps.
    func report() -> String {
        lock.withLock {
            guard let r = last else { return "step '\(current)', no reading yet" }
            return "step '\(current)' (\(checks) checks in it); last reading \(ContinuousClock.now - r.at) ago "
                + "in step '\(r.step)': state \(r.state), phase \(r.phase), canSeek \(r.canSeek), "
                + "sessionReady \(r.sessionReady), sourceSeekable \(String(describing: r.sourceSeekable)), "
                + "buffering \(r.buffering), seeking \(r.seeking), live \(r.live), "
                + "sequentialOrigin \(r.sequentialOrigin), duration \(r.duration), time \(r.time), "
                + "audio \(String(describing: r.audio))"
        }
    }
}
