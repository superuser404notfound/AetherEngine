import Testing
@testable import AetherEngine

// #339: the mode-switch observers used to be registered when the play gate opened. The engine's own criteria
// write happens in the pre-flight, before the item is built, so a switch could start and finish outside that
// window: both notifications were lost and the gate was left inferring from `isDisplayModeSwitchInProgress`.
// Two of the three device runs in Sodalite#49 spent the whole Stage 2 cap that way, waiting for an end that
// had already happened.
//
// The observation is now armed at the write and the gate reads what it recorded. That verdict is a pure
// function of four values, and the two asymmetries in it are the load-bearing part: an end alone must never
// settle the gate (it can belong to an older switch, e.g. the criteria reset a sole-writer load performs),
// and the in-progress flag may only veto a settle, never confirm one.
@Suite("DisplayCriteria pre-gate switch observation (#339)")
struct DisplayCriteriaSwitchObservationTests {

    private let ms: UInt64 = 1_000_000
    private var gateEntry: UInt64 { 10_000 * 1_000_000 }

    // MARK: - Nothing to go on

    @Test("Nothing recorded since the write leaves the gate to its normal Stage 1 poll")
    func nothingRecorded() {
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: nil, endedAtNanos: nil,
            gateEntryNanos: gateEntry, switchInProgress: false) == .none)
    }

    @Test("An in-progress flag alone is not a recorded switch: Stage 1 still classifies it")
    func flagAloneIsNotObserved() {
        // The flag is what #49 showed to be unreliable right after a write; it cannot stand in for a start.
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: nil, endedAtNanos: nil,
            gateEntryNanos: gateEntry, switchInProgress: true) == .none)
    }

    @Test("An end with no start never settles the gate (it can belong to an older switch)")
    func endWithoutStartIsNotSettled() {
        // The sole-writer path resets the criteria before the load, which can produce an end of its own. If
        // that settled the gate, a DV P5 cold start would be handed to a panel that is still SDR.
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: nil, endedAtNanos: gateEntry - 300 * 1_000_000,
            gateEntryNanos: gateEntry, switchInProgress: false) == .none)
    }

    // MARK: - The headroom is not an end signal

    @Test("A recorded start rules the headroom out as an end signal, in both stages")
    func headroomIsNotAnEndSignalForAnObservableSwitch() {
        // Device run, ATV 4K 3rd gen, tvOS 26.5: headroom 1.20 at +374ms for a switch that ended at +2853ms.
        #expect(!DisplayCriteriaController.startPhaseHeadroomSettles(startRecorded: true, switchInProgress: false))
        #expect(!DisplayCriteriaController.settlePhaseHeadroomSettles(startRecorded: true))
    }

    @Test("Without a recorded start the headroom keeps its say: that is the unobservable-DV panel")
    func headroomStillSettlesAnUnobservableSwitch() {
        #expect(DisplayCriteriaController.startPhaseHeadroomSettles(startRecorded: false, switchInProgress: false))
        // Stage 2 has classified a start already, so a stuck flag must not disqualify the only signal left.
        #expect(DisplayCriteriaController.settlePhaseHeadroomSettles(startRecorded: false))
    }

    @Test("Stage 1 also refuses the headroom while the panel reports a switch in progress")
    func startPhaseHeadroomRespectsTheFlag() {
        // The second gate of a load finds the record consumed, so "no new start" is not "no switch": on the
        // device that read ended the wait 759 ms before the switch did.
        #expect(!DisplayCriteriaController.startPhaseHeadroomSettles(startRecorded: false, switchInProgress: true))
    }

    @Test("The entry fast-exit needs the in-progress flag to agree with the headroom")
    func entryFastExitRequiresAnIdlePanel() {
        // Same run: the play gate read headroom 1.20 at entry and returned in 0 ms while the switch had
        // 2.4 s left. A panel already in HDR and a panel mid-transition read identically here.
        #expect(DisplayCriteriaController.entryHeadroomIsSettled(headroomAboveOne: true, switchInProgress: false))
        #expect(!DisplayCriteriaController.entryHeadroomIsSettled(headroomAboveOne: true, switchInProgress: true))
        #expect(!DisplayCriteriaController.entryHeadroomIsSettled(headroomAboveOne: false, switchInProgress: false))
    }

    // MARK: - Whose switch is it

    @Test("A record is evidence until a gate spends it, which the pre-flight does not")
    func recordIsEvidenceUntilSpent() {
        // Both gates of one load are entitled to the same switch: the pre-flight waits it out without
        // spending the record, so the play gate can still see that it settled instead of paying Stage 1.
        #expect(DisplayCriteriaController.recordIsFreshEvidence(recordGeneration: 7, lastSpentGeneration: 6))
        #expect(!DisplayCriteriaController.recordIsFreshEvidence(recordGeneration: 7, lastSpentGeneration: 7))
    }

    @Test("A load that arms nothing reads no record: the previous load's switch is not its own")
    func unarmedGateHasNoRecord() {
        // An engine-writer reload re-applies no criteria, so it arms nothing. Reading the last load's start
        // would send it into Stage 2 to wait out an end that can no longer arrive, adding the full cap to a
        // load where nothing is switching.
        #expect(!DisplayCriteriaController.recordIsFreshEvidence(recordGeneration: 0, lastSpentGeneration: 0))
        #expect(!DisplayCriteriaController.recordIsFreshEvidence(recordGeneration: 3, lastSpentGeneration: 3))
    }

    // MARK: - Started, not finished

    @Test("A start with no end sends the gate straight to Stage 2, with the start measured")
    func startedButNotEnded() {
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: gateEntry - 420 * ms, endedAtNanos: nil,
            gateEntryNanos: gateEntry, switchInProgress: true) == .running(startBeforeGateMs: 420))
    }

    @Test("An end that predates the start belongs to the previous switch, so the new one is still running")
    func endBeforeStartIsStale() {
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: gateEntry - 200 * ms, endedAtNanos: gateEntry - 500 * ms,
            gateEntryNanos: gateEntry, switchInProgress: false) == .running(startBeforeGateMs: 200))
    }

    @Test("The in-progress flag vetoes a settle, but a start/end pair is not a running switch")
    func inProgressFlagVetoesSettle() {
        // AE#1067: reading this as `.running` sent the gate to wait for an end that was already on the
        // record. On the reporter's Apple TV the flag stayed set for 8 s after modeSwitchEnd, so the play
        // gate spent the rest of the observed-end budget (5.2 s) on a panel that had finished.
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: gateEntry - 900 * ms, endedAtNanos: gateEntry - 100 * ms,
            gateEntryNanos: gateEntry, switchInProgress: true)
            == .endedFlagStillSet(startBeforeGateMs: 900, switchMs: 800))
    }

    // MARK: - Ended, flag still set (AE#1067)

    @Test("After a recorded end, a new start is a follow-on switch and the gate waits for its end")
    func followOnStartAfterEnd() {
        #expect(DisplayCriteriaController.endedSwitchFlagWatch(
            elapsedMs: 300, newStart: true, switchInProgress: true) == .followOnStart)
    }

    @Test("After a recorded end, the flag clearing settles the gate")
    func flagClearsAfterEnd() {
        #expect(DisplayCriteriaController.endedSwitchFlagWatch(
            elapsedMs: 300, newStart: false, switchInProgress: false) == .flagCleared)
    }

    @Test("After a recorded end, a flag that stays set only costs the follow-on grace, not the end budget")
    func stuckFlagCostsOnlyTheGrace() {
        let grace = DisplayCriteriaController.endedSwitchFlagGraceMs
        #expect(grace <= DisplayCriteriaController.StartGrace.full.budgetMs)
        #expect(DisplayCriteriaController.endedSwitchFlagWatch(
            elapsedMs: grace - 1, newStart: false, switchInProgress: true) == nil)
        #expect(DisplayCriteriaController.endedSwitchFlagWatch(
            elapsedMs: grace, newStart: false, switchInProgress: true) == .graceSpent)
    }

    @Test("A new start wins over a spent grace in the same poll")
    func newStartBeatsSpentGrace() {
        #expect(DisplayCriteriaController.endedSwitchFlagWatch(
            elapsedMs: 5_000, newStart: true, switchInProgress: true) == .followOnStart)
    }

    // MARK: - Finished before the gate opened

    @Test("Start and end both before the gate, panel idle: settled, with the switch measured end to end")
    func settledBeforeGate() {
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: gateEntry - 3_100 * ms, endedAtNanos: gateEntry - 200 * ms,
            gateEntryNanos: gateEntry, switchInProgress: false)
            == .settled(startBeforeGateMs: 3_100, switchMs: 2_900))
    }

    @Test("A start and end in the same instant still settle rather than falling through to a wait")
    func zeroLengthSwitchSettles() {
        let at = gateEntry - 50 * ms
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: at, endedAtNanos: at,
            gateEntryNanos: gateEntry, switchInProgress: false)
            == .settled(startBeforeGateMs: 50, switchMs: 0))
    }

    @Test("Timestamps after the gate entry clamp to zero rather than trapping on unsigned subtraction")
    func timestampsAfterEntryClampToZero() {
        #expect(DisplayCriteriaController.observedSwitch(
            startedAtNanos: gateEntry + 5 * ms, endedAtNanos: gateEntry + 9 * ms,
            gateEntryNanos: gateEntry, switchInProgress: false)
            == .settled(startBeforeGateMs: 0, switchMs: 4))
    }

    // MARK: - How the settle reads in the log

    @Test("A pre-gate start reports its distance to the gate, not a Stage 1 duration it never spent")
    func preGateTimingSuffix() {
        let line = DisplayCriteriaController.timingSuffix(
            startSignal: .preGateObserved, stage1Ms: 0, totalMs: 1_830,
            startBeforeGateMs: 412, switchMs: nil)
        #expect(line == "start pre-gate (start notification, before gate entry) 412ms before gate entry, total 1830ms")
    }

    @Test("The measured switch duration is appended whenever both notifications were seen")
    func measuredSwitchIsReported() {
        let line = DisplayCriteriaController.timingSuffix(
            startSignal: .preGateObserved, stage1Ms: 0, totalMs: 90,
            startBeforeGateMs: 3_100, switchMs: 2_900)
        #expect(line.hasSuffix("total 90ms, switch 2900ms end to end"))
    }

    @Test("The in-gate form is unchanged, so #49's settle lines keep reading the same way")
    func inGateTimingSuffixUnchanged() {
        #expect(DisplayCriteriaController.timingSuffix(startSignal: .inGate, stage1Ms: 90, totalMs: 240)
            == "start in-gate after 90ms, total 240ms")
    }

    @Test("Flag-only verdicts name what is missing: a notification, not an ordering")
    func flagOnlySignalsNameTheDefect() {
        #expect(DisplayCriteriaController.StartSignal.preGate.rawValue
            == "pre-gate (flag only, no start notification since the criteria write)")
        #expect(DisplayCriteriaController.StartSignal.inGateFlagOnly.rawValue
            == "in-gate (flag only, start notification missed)")
    }

    // MARK: - Stage 1 classification is unchanged by the arming point

    @Test("With a start recorded pre-gate the gate skips Stage 1, so classifyStart only sees in-gate starts")
    func stage1StillClassifiesInGateStarts() {
        #expect(DisplayCriteriaController.classifyStart(
            isFirstPoll: true, startNotificationFired: true, switchInProgress: false) == .inGate)
        #expect(DisplayCriteriaController.classifyStart(
            isFirstPoll: true, startNotificationFired: false, switchInProgress: true) == .preGate)
        #expect(DisplayCriteriaController.classifyStart(
            isFirstPoll: false, startNotificationFired: false, switchInProgress: true) == .inGateFlagOnly)
        #expect(DisplayCriteriaController.classifyStart(
            isFirstPoll: false, startNotificationFired: false, switchInProgress: false) == nil)
    }
}

// Sodalite#49, rate-only round: the play gate used to break out of a switch it had watched start, because
// Stage 2's cap is sized for a gate that runs BEFORE the load. Device measurement (ATV 4K 3rd gen,
// tvOS 26.5, SDR 25p on a 60 Hz system, so a rate-only write with no pre-flight): item ready +443 ms, cap
// released play() +2130 ms, panel finished +3555 ms. The panel is dark the whole time, so the early release
// bought no picture and cost 1.4 s of content played into a black screen.
@Suite("DisplayCriteria settle cap by what waits on the gate (Sodalite#49)")
struct DisplayCriteriaSettleCapTests {

    @Test("A play gate that saw the switch start waits for its end")
    func playGateAwaitsObservedEnd() {
        #expect(DisplayCriteriaController.settleCapMs(cap: .awaitObservedEnd, startRecorded: true)
            == DisplayCriteriaController.observedEndCapMs)
    }

    @Test("Without a recorded start there is no end to await, so the standard cap holds")
    func unobservedSwitchKeepsTheStandardCap() {
        // The unobservable-DV panel: nothing will report an end, so a longer ceiling is pure startup cost.
        #expect(DisplayCriteriaController.settleCapMs(cap: .awaitObservedEnd, startRecorded: false)
            == DisplayCriteriaController.stage2CapMs)
    }

    @Test("The pre-flight and live keep the standard cap whatever was recorded")
    func standardCapIsUnconditional() {
        // Pre-flight: breaking out early is what releases loadNative (AE#348). Live: a zap must not sit
        // behind a panel handshake.
        for recorded in [true, false] {
            #expect(DisplayCriteriaController.settleCapMs(cap: .standard, startRecorded: recorded)
                == DisplayCriteriaController.stage2CapMs)
        }
    }

    @Test("The awaited ceiling clears the measured switches with room, and is still a ceiling")
    func observedEndCapIsSized() {
        // Measured: 2779-2898 ms dynamic range, ~3550 ms rate-only. Reachable only if a start was recorded
        // and its end never arrives, which happened in none of sixteen device switches.
        #expect(DisplayCriteriaController.observedEndCapMs > 3600)
        #expect(DisplayCriteriaController.observedEndCapMs <= 6000)
    }
}
