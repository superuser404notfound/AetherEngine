import Testing
import Foundation
@testable import AetherEngine

/// #169: a mid-session VOD read error gets a bounded producer revive. Once the gate was
/// exhausted, `handleVODReadErrorExit` used to log "giving up" and return WITHOUT any
/// terminal surface — no producer, no error, AVPlayer parked in waitingToPlay forever.
/// The cap-reached arm must fire `onVODSourceFailed` exactly like the produced-nothing arm.
@Suite("VOD readError revive-cap exhaustion")
struct ReadErrorReviveCapTests {

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _code: Int32?
        var code: Int32? {
            lock.lock(); defer { lock.unlock() }
            return _code
        }
        func set(_ code: Int32) {
            lock.lock(); _code = code; lock.unlock()
        }
    }

    @Test("an exhausted revive gate surfaces onVODSourceFailed instead of dying silently")
    func exhaustedGateSurfacesFailure() {
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/witness.mkv"),
                                    dvModeAvailable: false)
        engine.readErrorReviveGate = ReviveBudget(maxAttempts: 0)
        let failed = Flag()
        engine.onVODSourceFailed = { code, _, _ in failed.set(code) }

        engine.handleVODReadErrorExit(-5)

        #expect(failed.code == -5,
                "the cap-reached arm must surface the terminal failure to the host")
    }

    @Test("the revive gate admits within its cap and refuses past it")
    func gateAdmitsWithinCap() {
        var gate = ReviveBudget(maxAttempts: 2)
        let first = gate.admit()
        let second = gate.admit()
        let third = gate.admit()
        #expect(first)
        #expect(second)
        #expect(!third, "the third failure must exhaust a two-attempt gate")
        #expect(gate.attempts == 3)
    }

    @Test("HLS-201: outages separated by produced segments all revive, back-to-back ones still give up")
    func onProgressBudgetResetsOnlyOnProduction() {
        var healing = ReviveBudget(maxAttempts: 2, reset: .onProgress)
        let h1 = healing.admit(progress: 10)
        let h2 = healing.admit(progress: 400)
        let h3 = healing.admit(progress: 900)
        let h4 = healing.admit(progress: 1_500)
        #expect(h1 && h2 && h3 && h4, "an outage after healthy progress is a new outage")
        #expect(healing.attempts == 1)

        var barren = ReviveBudget(maxAttempts: 2, reset: .onProgress)
        let b1 = barren.admit(progress: 10)
        let b2 = barren.admit(progress: 10)
        let b3 = barren.admit(progress: 10)
        #expect(b1 && b2)
        #expect(!b3, "three deaths without a stored segment between them exhaust the cap")

        var sessionCap = ReviveBudget(maxAttempts: 2, reset: .never)
        let s1 = sessionCap.admit(progress: 1)
        let s2 = sessionCap.admit(progress: 100)
        let s3 = sessionCap.admit(progress: 200)
        #expect(s1 && s2)
        #expect(!s3, ".never ignores progress")
    }

    @Test("HLS-201: the segment cache counts every stored segment and never goes back")
    func cacheTotalStoredCountIsMonotonic() throws {
        let cache = SegmentCache(forwardWindow: 10, backwardWindow: 10)
        defer { cache.close() }
        #expect(cache.totalStoredCount == 0)
        cache.store(index: 0, data: Data([1]))
        cache.store(index: 1, data: Data([2]))
        #expect(cache.totalStoredCount == 2)
        cache.resetHighWaterForRestart()
        #expect(cache.totalStoredCount == 2)
    }
}
