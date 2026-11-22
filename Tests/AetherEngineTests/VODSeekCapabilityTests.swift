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
        // The clip is 6 s and plays in real time, and on the all-traits CI job one main-actor wait can
        // take longer than that. Autostarted, it ran to .ended before the first check saw it seekable,
        // and .ended is never seekable: both cases hung for 150 s at once (2026-11-21 and 2026-11-22).
        // Mounted paused it cannot run out. What the test is about does not need it to have played:
        // stopInternal clears isSourceSeekable and the software reload never wrote it back (#1086).
        options.autoplay = false
        try await engine.load(url: URL(string: "http://127.0.0.1:\(origin.port)/two-audio.mkv")!, options: options)
        step.value = "seekable and paused"
        try await step.wait(engine) { engine.canSeek && engine.state == .paused }
        let other = try #require(engine.audioTracks.first { $0.id != engine.activeAudioTrackIndex })
        step.value = "audio switch to \(other.id)"
        engine.selectAudioTrack(index: other.id)
        try await step.wait(engine) { engine.activeAudioTrackIndex == other.id && engine.isSessionReady }
        #expect(engine.isSourceSeekable == true)
        #expect(engine.canSeek)
        step.value = "seek to 4"
        await engine.seek(to: 4)
        step.value = "landing past 3.5"
        try await step.wait(engine) { engine.currentTime > 3.5 }
        #expect(abs(engine.currentTime - 4) < 1)
    }

    nonisolated private static func reportIfStuck(_ step: StepMarker, path: DecodePath) async {
        do { try await Task.sleep(for: .seconds(150)) } catch { return }
        Issue.record("audio switch test (\(path)) still at step '\(step.value)' after 150 s; \(step.report())")
    }
}

/// Which step a long test is in, and what the engine looked like the last time that step's wait
/// checked, readable from the watchdog off the main actor. The report says how long ago that check
/// ran, so a main actor that stopped running the wait shows up as an old snapshot, not as a healthy one.
private final class StepMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String
    private var lastSeen: String?
    private var lastSeenAt: ContinuousClock.Instant?
    private var checks = 0
    init(_ initial: String) { current = initial }

    var value: String {
        get { lock.withLock { current } }
        set {
            lock.withLock {
                current = newValue
                lastSeen = nil
                lastSeenAt = nil
                checks = 0
            }
        }
    }

    /// `waitFor` that records the engine's state before every check.
    @MainActor
    func wait(_ engine: AetherEngine, _ condition: () -> Bool) async throws {
        try await waitFor {
            observe(engine)
            return condition()
        }
    }

    @MainActor
    private func observe(_ engine: AetherEngine) {
        let snapshot = "state \(engine.state), phase \(engine.playbackPhase), canSeek \(engine.canSeek), "
            + "sessionReady \(engine.isSessionReady), sourceSeekable \(String(describing: engine.isSourceSeekable)), "
            + "buffering \(engine.isBuffering), seeking \(engine.isSeeking), live \(engine.isLive), "
            + "sequentialOrigin \(engine.loadedOptions.sequentialOrigin), duration \(engine.duration), "
            + "time \(engine.currentTime), audio \(String(describing: engine.activeAudioTrackIndex))"
        let now = ContinuousClock.now
        lock.withLock {
            lastSeen = snapshot
            lastSeenAt = now
            checks += 1
        }
    }

    func report() -> String {
        lock.withLock {
            guard let lastSeen, let lastSeenAt else { return "this step's wait never checked" }
            let age = ContinuousClock.now - lastSeenAt
            return "\(checks) checks, the last \(age) ago saw \(lastSeen)"
        }
    }
}
