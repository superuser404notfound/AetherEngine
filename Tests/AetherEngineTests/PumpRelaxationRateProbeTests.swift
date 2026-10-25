import Testing
@testable import AetherEngine

/// AE#850: the relaxed QoS is only worth keeping while it produces at least as fast as the consumer
/// plays. On an A15 Apple TV a TrueHD Atmos to APAC session ran at 0.10-0.51x on `.utility`, so the
/// lead-only relaxation of AE#286 cycled between a drained lead and a stall for the whole session.
@Suite("Pump relaxation rate probe (#850)")
struct PumpRelaxationRateProbeTests {

    /// Samples once a second from `start` for `seconds`, producing `rate` seconds of content per
    /// second of wall time. Returns the first verdict, if any.
    private func run(_ probe: inout PumpRelaxationRateProbe, from start: Double, seconds: Int,
                     rate: Double, contentStart: Double = 0) -> Double? {
        for i in 0...seconds {
            let t = Double(i)
            if let verdict = probe.observe(wallSeconds: start + t, contentSeconds: contentStart + t * rate) {
                return verdict
            }
        }
        return nil
    }

    @Test("A relaxed pump that keeps up is never refused, however long it runs")
    func keepingUpIsNeverRefused() {
        var probe = PumpRelaxationRateProbe()
        #expect(run(&probe, from: 100, seconds: 600, rate: 1.0) == nil)
        #expect(run(&probe, from: 800, seconds: 600, rate: 4.0, contentStart: 700) == nil)
    }

    @Test("Below real time is refused once a full window is measured, not before")
    func belowRealTimeIsRefused() {
        var probe = PumpRelaxationRateProbe()
        // Seven seconds are not a window yet.
        #expect(run(&probe, from: 0, seconds: 7, rate: 0.12) == nil)
        let verdict = probe.observe(wallSeconds: 8, contentSeconds: 8 * 0.12)
        #expect(verdict != nil)
        #expect(abs((verdict ?? 0) - 0.12) < 1e-9)
    }

    @Test("Short relaxed stretches add up, so a lead-driven promotion cannot hide a slow class")
    func stretchesAddUp() {
        // The reporter's shape with a promotion every 4 s: no single stretch reaches the window.
        var probe = PumpRelaxationRateProbe()
        #expect(run(&probe, from: 0, seconds: 4, rate: 0.3, contentStart: 500) == nil)
        probe.suspend()
        // A seek between the stretches moves the content position; only each stretch's own delta counts.
        let verdict = run(&probe, from: 30, seconds: 4, rate: 0.3, contentStart: 1200)
        #expect(verdict != nil)
        #expect(abs((verdict ?? 0) - 0.3) < 1e-9)
    }

    @Test("A park on the relaxed class clears the window")
    func parkClearsTheWindow() {
        var probe = PumpRelaxationRateProbe()
        #expect(run(&probe, from: 0, seconds: 6, rate: 0.5) == nil)
        probe.reset()
        // The parked time and the slow seconds before it count for nothing afterwards.
        #expect(run(&probe, from: 60, seconds: 7, rate: 1.0) == nil)
    }

    @Test("A slowdown later in the session is caught, not averaged away")
    func laterSlowdownIsCaught() {
        var probe = PumpRelaxationRateProbe()
        #expect(run(&probe, from: 0, seconds: 300, rate: 3.0) == nil)
        #expect(run(&probe, from: 301, seconds: 20, rate: 0.6, contentStart: 900) != nil)
    }
}
