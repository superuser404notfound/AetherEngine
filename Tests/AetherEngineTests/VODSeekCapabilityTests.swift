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


}
