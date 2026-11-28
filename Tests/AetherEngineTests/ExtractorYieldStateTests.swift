import Foundation
import Testing
@testable import AetherEngine

/// Sodalite#118: the yield gate used to exist only on the native loopback path. A transcode (remote
/// HLS) and the software host had no session, so the gate said "no gate" and a picture-area scan
/// read the original file unthrottled, on a transcode exactly over the line that was too thin for it.
@Suite("Extractor yield state on every path")
struct ExtractorYieldStateTests {
    @Test("an inactive state never yields (Sodalite#118)", .timeLimit(.minutes(3)))
    func inactiveNeverYields() {
        let state = ExtractorYieldState()
        #expect(!state.shouldYieldNow())
        state.recordTick(healthy: false)
        #expect(!state.shouldYieldNow())
    }

    @Test("a pipeline without a session yields until three healthy ticks (Sodalite#118)", .timeLimit(.minutes(3)))
    func pipelineWithoutSessionYieldsUntilThreeHealthyTicks() {
        let state = ExtractorYieldState()
        state.activatePipeline()
        #expect(state.shouldYieldNow())
        state.recordTick(healthy: true)
        state.recordTick(healthy: true)
        #expect(state.shouldYieldNow())
        state.recordTick(healthy: true)
        #expect(!state.shouldYieldNow())
    }

    @Test("an unhealthy tick resets the run (Sodalite#118)", .timeLimit(.minutes(3)))
    func unhealthyTickResetsRun() {
        let state = ExtractorYieldState()
        state.activatePipeline()
        for _ in 0..<5 { state.recordTick(healthy: true) }
        #expect(!state.shouldYieldNow())
        state.recordTick(healthy: false)
        #expect(state.shouldYieldNow())
        #expect(state.snapshot().consecutiveHealthyTicks == 0)
    }

    @Test("deactivate clears the gate (Sodalite#118)", .timeLimit(.minutes(3)))
    func deactivateClears() {
        let state = ExtractorYieldState()
        state.activatePipeline()
        state.deactivate()
        #expect(!state.snapshot().active)
        #expect(!state.shouldYieldNow())
    }

    private func verdict(_ state: PlaybackState, live: Bool = false, rebuffering: Bool = false,
                         cushion: Double? = 0.4, runway: Int? = 8 * 1_048_576) -> Bool? {
        ExtractorYieldState.softwareTickVerdict(state: state, isLive: live, isRebuffering: rebuffering,
                                                displayCushionSeconds: cushion, readerWindowAheadBytes: runway)
    }

    @Test("a playing software tick needs a cushion, reader runway and no rebuffer (Sodalite#118)",
          .timeLimit(.minutes(3)))
    func softwareTickHealth() {
        let mb = 1_048_576
        #expect(verdict(.playing) == true)
        #expect(verdict(.playing, runway: nil) == true)
        #expect(verdict(.playing, runway: mb) == false)
        #expect(verdict(.playing, rebuffering: true) == false)
        #expect(verdict(.playing, cushion: 0) == false)
    }

    @Test("a paused software pipeline cannot starve, whatever its cushion (Sodalite#118)", .timeLimit(.minutes(3)))
    func pausedIsHealthy() {
        #expect(verdict(.paused, cushion: 0, runway: 0) == true)
        #expect(verdict(.paused, rebuffering: true, cushion: 0, runway: 0) == false)
    }

    @Test("a live software session is not held to the VOD reader runway (Sodalite#118)", .timeLimit(.minutes(3)))
    func liveIgnoresRunway() {
        // Near the live edge the reader only holds what the origin has sent, a few MB at most.
        #expect(verdict(.playing, live: true, runway: 2 * 1_048_576) == true)
        #expect(verdict(.playing, live: true, cushion: 0) == false)
    }

    @Test("a seek or a load gives no verdict, so it does not restart the healthy run (Sodalite#118)",
          .timeLimit(.minutes(3)))
    func seekingIsNeutral() {
        #expect(verdict(.seeking) == nil)
        #expect(verdict(.loading) == nil)
        let state = ExtractorYieldState()
        state.activatePipeline()
        for _ in 0..<3 { state.recordTick(healthy: true) }
        state.recordSoftwareTick(nil)
        #expect(!state.shouldYieldNow())
        state.recordSoftwareTick(false)
        #expect(state.shouldYieldNow())
    }
}
