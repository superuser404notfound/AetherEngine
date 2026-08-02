import Testing
@testable import AetherEngine

// #274: the post-load play-gate called waitForSwitch() with the same 1000 ms Stage 1 budget on every load.
// That budget exists for one case, a sole-writer host whose criteria write lands during the load (AVKit's
// auto path, DV P5 cold start). Sessions no dynamic-range switch can reach paid it as dead startup time,
// and the Stage 2 classification attributed a host-driven switch that ended SDR to a failed HDR handshake.
// Both are pure decisions; this suite covers them.
//
// Sodalite#49: the settle log those decisions would be verified against was reporting Stage 1's whole
// budget as time spent, so no run ever showed how long a switch really took. The timing helpers are pure
// too, and covered here alongside.
@Suite("DisplayCriteria play-gate grace, switch attribution and settle timing")
struct DisplayCriteriaPlayGateTests {

    // MARK: - Stage 1 budget

    @Test("Unchanged criteria skip the gate entirely (#133 behaviour preserved)")
    func unchangedCriteriaSkip() {
        #expect(AetherEngine.playGateGrace(
            criteriaUnchanged: true, engineIsCriteriaWriter: true,
            formatKnown: true, effectiveFormat: .dolbyVision) == .skip)
        #expect(AetherEngine.playGateGrace(
            criteriaUnchanged: true, engineIsCriteriaWriter: false,
            formatKnown: false, effectiveFormat: .sdr) == .skip)
    }

    @Test("Engine-writer sessions take the brief budget: their write already happened, pre-load and synchronously")
    func engineWriterIsBrief() {
        for format: VideoFormat in [.sdr, .hdr10, .hdr10Plus, .hlg, .dolbyVision] {
            #expect(AetherEngine.playGateGrace(
                criteriaUnchanged: false, engineIsCriteriaWriter: true,
                formatKnown: true, effectiveFormat: format) == .brief)
        }
    }

    @Test("Sole-writer host with HDR/DV content keeps the full budget (the DV P5 cold-start case the gate exists for)")
    func suppressedHostHDRIsFull() {
        for format: VideoFormat in [.hdr10, .hdr10Plus, .hlg, .dolbyVision] {
            #expect(AetherEngine.playGateGrace(
                criteriaUnchanged: false, engineIsCriteriaWriter: false,
                formatKnown: true, effectiveFormat: format) == .full)
        }
    }

    @Test("Sole-writer host with SDR content takes the brief budget: only a rate-only write can still arrive")
    func suppressedHostSDRIsBrief() {
        #expect(AetherEngine.playGateGrace(
            criteriaUnchanged: false, engineIsCriteriaWriter: false,
            formatKnown: true, effectiveFormat: .sdr) == .brief)
    }

    @Test("Sole-writer host keeps the full budget when the probe failed and the range is unknown")
    func suppressedHostUnknownFormatIsFull() {
        // effectiveFormat defaults to .sdr on a failed probe, so the format alone must not decide here.
        #expect(AetherEngine.playGateGrace(
            criteriaUnchanged: false, engineIsCriteriaWriter: false,
            formatKnown: false, effectiveFormat: .sdr) == .full)
    }

    @Test("Budgets are the documented millisecond values")
    func graceTicks() {
        #expect(DisplayCriteriaController.StartGrace.skip.ticks == 0)
        #expect(DisplayCriteriaController.StartGrace.brief.ticks == 20)   // 20 x 10ms = 200ms
        #expect(DisplayCriteriaController.StartGrace.full.ticks == 100)   // 100 x 10ms = 1000ms
    }

    // MARK: - Criteria attribution

    @Test("Engine HDR criteria ending with headroom 1.0 stays a real handshake failure")
    func engineHDRFailureStillWarns() {
        #expect(DisplayCriteriaController.criteriaAttribution(
            didApply: true, lastCriteriaWasHDR: true) == .engineHDR)
    }

    @Test("Engine SDR rate-only criteria ending SDR is the expected outcome")
    func engineRateOnlySettles() {
        #expect(DisplayCriteriaController.criteriaAttribution(
            didApply: true, lastCriteriaWasHDR: false) == .engineRateOnly)
    }

    @Test("A switch the engine never wrote is unattributable, not an HDR failure")
    func hostDrivenSwitchIsUnattributable() {
        // The reporter's symptom: a host SDR rate write, mid-load, logged as
        // "panel stayed SDR despite HDR criteria" because didApply was false.
        #expect(DisplayCriteriaController.criteriaAttribution(
            didApply: false, lastCriteriaWasHDR: false) == .hostDriven)
        // lastCriteriaWasHDR is stale state from a previous session once didApply is false; it must not
        // resurrect the HDR verdict.
        #expect(DisplayCriteriaController.criteriaAttribution(
            didApply: false, lastCriteriaWasHDR: true) == .hostDriven)
    }

    // MARK: - Settle timing (Sodalite#49)

    @Test("Reported timings are the measured ones, not the Stage 1 budget added back in")
    func timingSuffixReportsMeasuredValues() {
        let suffix = DisplayCriteriaController.timingSuffix(
            startSignal: .preGate, stage1Ms: 5, totalMs: 55)
        #expect(suffix == "start pre-gate after 5ms, total 55ms")
        // The line this replaces read "~1050ms" for exactly this switch: Stage 1's full 1000 ms budget,
        // which it never spent, plus one 50 ms Stage 2 tick.
        #expect(!suffix.contains("1050"))
        #expect(!suffix.contains("1000"))
    }

    @Test("Start signal distinguishes a switch already running from one that began inside the gate")
    func startSignalNamesTheOrdering() {
        // The whole point of #49: a pre-gate start means the panel was switching while the item was built.
        #expect(DisplayCriteriaController.StartSignal.preGate.rawValue == "pre-gate")
        #expect(DisplayCriteriaController.StartSignal.inGate.rawValue == "in-gate")
        #expect(DisplayCriteriaController.timingSuffix(
            startSignal: .inGate, stage1Ms: 120, totalMs: 300)
            == "start in-gate after 120ms, total 300ms")
    }

    @Test("Elapsed conversion is nanoseconds to whole milliseconds, truncating")
    func elapsedMsConvertsNanoseconds() {
        let base: UInt64 = 1_000_000_000
        #expect(DisplayCriteriaController.elapsedMs(fromNanos: base, toNanos: 1_050_000_000) == 50)
        #expect(DisplayCriteriaController.elapsedMs(fromNanos: base, toNanos: base) == 0)
        #expect(DisplayCriteriaController.elapsedMs(fromNanos: base, toNanos: 1_000_999_000) == 0)
        // Reversed arguments must not trap on the unsigned subtraction.
        #expect(DisplayCriteriaController.elapsedMs(fromNanos: base, toNanos: 0) == 0)
    }
}
