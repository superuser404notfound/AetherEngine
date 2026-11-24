import Foundation
import Testing
@testable import AetherEngine

/// AE#1126: a VOD revive before the first frame aimed at the rendered position, which is 0 until
/// something renders, so a resume at 4086 s restarted the producer at seg0 while AVPlayer was mounted
/// at 4086 s and asked for a segment there.
@Suite("Startup revive aim", .timeLimit(.minutes(3)))
struct StartupReviveAimTests {

    private func makeEngine(sequential: Bool = false, start: Double?, rendered: Bool,
                            position: Double = 0, pendingSeek: Double? = nil) -> HLSVideoEngine {
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/movie.mkv"),
                                    dvModeAvailable: false,
                                    sequentialOrigin: sequential,
                                    declaredDurationSeconds: sequential ? 8100 : nil)
        engine.initialStartSeconds = start
        engine.hasStartedRenderingProvider = { rendered }
        engine.currentPlaybackPositionProvider = { position }
        engine.recoverySeekTargetProvider = { pendingSeek }
        return engine
    }

    @Test("before the first frame the revive keeps the load's start position")
    func startupKeepsStartPosition() {
        let engine = makeEngine(start: 4086.2, rendered: false)
        #expect(engine.consumerRecoveryTarget().anchor == 4086.2)
    }

    @Test("once a frame rendered, the rendered position owns the aim")
    func renderedPositionAfterFirstFrame() {
        let engine = makeEngine(start: 4086.2, rendered: true, position: 4210.5)
        #expect(engine.consumerRecoveryTarget().anchor == 4210.5)
    }

    @Test("a pending seek outranks the start position during startup")
    func pendingSeekWins() {
        let engine = makeEngine(start: 4086.2, rendered: false, pendingSeek: 120)
        #expect(engine.consumerRecoveryTarget().anchor == 120)
    }

    @Test("a load without a start position still revives at 0")
    func noStartPosition() {
        #expect(makeEngine(start: nil, rendered: false).consumerRecoveryTarget().anchor == 0)
        #expect(makeEngine(start: 0, rendered: false).consumerRecoveryTarget().anchor == 0)
    }

    @Test("a sequential origin produced from 0, so its revive does not claim the start position")
    func sequentialOriginIgnoresStart() {
        let engine = makeEngine(sequential: true, start: 4086.2, rendered: false)
        #expect(engine.consumerRecoveryTarget().anchor == 0)
    }

    @Test("the pure decision")
    func pureDecision() {
        #expect(HLSVideoEngine.vodRecoveryAnchor(frozenPosition: 0, pendingSeekTarget: nil,
                                                 hasRendered: false, startPosition: 4086.2) == 4086.2)
        #expect(HLSVideoEngine.vodRecoveryAnchor(frozenPosition: 50, pendingSeekTarget: nil,
                                                 hasRendered: true, startPosition: 4086.2) == 50)
        #expect(HLSVideoEngine.vodRecoveryAnchor(frozenPosition: 0, pendingSeekTarget: 7,
                                                 hasRendered: false, startPosition: 4086.2) == 7)
        #expect(HLSVideoEngine.vodRecoveryAnchor(frozenPosition: 0, pendingSeekTarget: nil,
                                                 hasRendered: false, startPosition: nil) == 0)
    }
}
