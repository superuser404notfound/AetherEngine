import Foundation
import Testing
@testable import AetherEngine

/// Sodalite#118: the yield gate used to exist only on the native loopback path. A transcode (remote
/// HLS) and the software host had no session, so the gate said "no gate" and a picture-area scan
/// read the original file unthrottled, on a transcode exactly over the line that was too thin for it.
@Suite("Extractor yield state on every path")
struct ExtractorYieldStateTests {
    @Test("an inactive state never yields", .timeLimit(.minutes(3)))
    func inactiveNeverYields() {
        let state = ExtractorYieldState()
        #expect(!state.shouldYieldNow())
        state.recordTick(healthy: false)
        #expect(!state.shouldYieldNow())
    }

    @Test("a pipeline without a session yields until three healthy ticks", .timeLimit(.minutes(3)))
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

    @Test("an unhealthy tick resets the run", .timeLimit(.minutes(3)))
    func unhealthyTickResetsRun() {
        let state = ExtractorYieldState()
        state.activatePipeline()
        for _ in 0..<5 { state.recordTick(healthy: true) }
        #expect(!state.shouldYieldNow())
        state.recordTick(healthy: false)
        #expect(state.shouldYieldNow())
        #expect(state.snapshot().consecutiveHealthyTicks == 0)
    }

    @Test("deactivate clears the gate", .timeLimit(.minutes(3)))
    func deactivateClears() {
        let state = ExtractorYieldState()
        state.activatePipeline()
        state.deactivate()
        #expect(!state.snapshot().active)
        #expect(!state.shouldYieldNow())
    }

    @Test("a software tick is healthy only with a cushion and no rebuffer", .timeLimit(.minutes(3)))
    func softwareTickHealth() {
        #expect(ExtractorYieldState.softwareTickIsHealthy(state: .playing, isRebuffering: false, displayCushionSeconds: 0.4))
        #expect(ExtractorYieldState.softwareTickIsHealthy(state: .paused, isRebuffering: false, displayCushionSeconds: 0.4))
        #expect(!ExtractorYieldState.softwareTickIsHealthy(state: .playing, isRebuffering: true, displayCushionSeconds: 0.4))
        #expect(!ExtractorYieldState.softwareTickIsHealthy(state: .playing, isRebuffering: false, displayCushionSeconds: 0))
        #expect(!ExtractorYieldState.softwareTickIsHealthy(state: .playing, isRebuffering: false, displayCushionSeconds: nil))
        #expect(!ExtractorYieldState.softwareTickIsHealthy(state: .seeking, isRebuffering: false, displayCushionSeconds: 0.4))
    }
}
