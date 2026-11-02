import Foundation
import CoreMedia
import CoreVideo
import AVFoundation

#if canImport(UIKit)
import UIKit
#endif

#if os(tvOS)
import AVKit
import QuartzCore
#endif

/// HDMI HDR-mode handshake via AVDisplayManager (tvOS 11.2+). Programs AVDisplayCriteria before playback so the panel finishes its mode negotiation before the first frame. No-op stub on iOS/macOS. Lifted from Sodalite's PlayerViewModel so the engine owns the handshake; hosts no longer touch UIWindow.avDisplayManager.
@MainActor
final class DisplayCriteriaController {

    /// Override window discovery. Default walks connectedScenes and picks the first window; multi-window or custom-presentation hosts can supply their own resolver here.
    nonisolated(unsafe) static var windowProvider: (@MainActor () -> Any?)?

    /// Whether apply() wrote preferredDisplayCriteria this session. reset() is gated on this so AVKit-sole-writer hosts (LoadOptions.suppressDisplayCriteria=true) get zero engine writes; a nil write on a suppressed session races AVKit's in-flight criteria and collapsed EDR headroom to 1.0 (DrHurt#4 Build 176).
    private var didApply: Bool = false

    /// True when the last apply() set HDR color extensions. waitForSwitch uses this to distinguish a legitimate SDR rate-only settle (headroom 1.0 expected) from an HDR handshake failure (headroom 1.0 is wrong).
    private var lastCriteriaWasHDR: Bool = false

    /// #133: the criteria last written to the panel (nil until the first apply, cleared by reset()). Lets a
    /// same-format zap detect that the mode is already active and skip the redundant write + settle wait,
    /// which on unobservable-DV panels otherwise burns the full ~3s waitForSwitch cap on every channel change.
    private var lastApplied: AppliedCriteria?

    /// Has this display demonstrably engaged HDR (headroom observed above 1.0, or an HDR master accepted)?
    ///
    /// Never cleared by `reset()` or by a switch that ends at headroom 1.0. The headroom collapses while
    /// HDR video is on the screen (see `panelPresentsHDR`), so its absence at exactly the moment a load asks
    /// proves nothing, and any invalidation rule built on it would re-arm the very false negative this
    /// exists to answer. Only an event that can mean a changed output configuration clears it: leaving for
    /// the background or a refused HDR master (`forgetPanelProof`). A display change cannot strand it either:
    /// `effectiveVideoFormat` clamps to `displayCapabilities` before `apply()`, so an SDR route writes SDR
    /// criteria and never consults the proof.
    ///
    /// Process-wide, like the display it describes: a host that builds an engine per item gets a fresh
    /// controller for every load, and an instance flag lost the proof at every one, so an Apple TV whose
    /// headroom never moves read `provenHDR=no` on the next title moments after AVFoundation had
    /// accepted an HDR master on it. Readable for the tests; set only through `notePanelEngagedHDR`,
    /// a headroom reading, and cleared by `forgetPanelProof`.
    private static var panelProvenToEngageHDRInProcess = false {
        didSet { if panelProvenToEngageHDRInProcess { observeProofInvalidation() } }
    }
    private(set) var panelProvenToEngageHDR: Bool {
        get { Self.panelProvenToEngageHDRInProcess }
        set { Self.panelProvenToEngageHDRInProcess = newValue }
    }

    #if os(iOS) || os(tvOS)
    /// Installed once, the first time the proof latches, and kept for the process: the proof outlives
    /// every engine (and every engine's lifecycle observers), so its invalidation must too.
    private static var proofInvalidationObserver: NSObjectProtocol?

    private static func observeProofInvalidation() {
        guard proofInvalidationObserver == nil else { return }
        proofInvalidationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { forgetPanelProof("leaving for the background") }
        }
    }
    #else
    private static func observeProofInvalidation() {}
    #endif

    #if os(tvOS)
    /// #339: armed at the criteria write, not when the play gate opens, so an engine-written switch is
    /// observable end to end instead of having to be guessed at from the in-progress flag.
    private let observation = SwitchObservation()
    /// DEC-105: what is left of the observed-end wait for the armed switch (`observedEndCap`).
    private var observedEndBudget: ObservedEndBudget?
    /// AE#950: the panel's cadence read up to the criteria write, started by `beginPreWriteCadence()`.
    private var preWriteCadence: DisplayLinkSampler?
    #endif

    /// AE#950: how the panel's cadence just before a write related to the rate that write asked for, keyed
    /// by the arm generation of that write so a later gate without a write of its own cannot read it.
    private var preWriteRelation: (armGeneration: Int, relation: PanelRateRelation)?
    /// AE#950: which load the running pre-write reading belongs to (`beginPreWriteCadence`).
    private var preWriteCadenceToken = 0

    /// The arm generation whose record has been spent. Only a gate that ends the load's wait spends it, so
    /// both gates of one load see the same evidence while a later, unarmed gate sees none
    /// (`recordIsFreshEvidence`).
    private var spentArmGeneration: Int = 0

    /// The identifying inputs of an apply(): equal signatures mean the panel is already in the target mode.
    struct AppliedCriteria: Equatable {
        let isHDR: Bool
        let effectiveRate: Float
        let codecType: CMVideoCodecType
        let hasExtensions: Bool
    }

    enum ApplyResult {
        /// HDR/DV criteria written; a dynamic-range switch is expected (caller should pre-flight waitForSwitch).
        case willSwitch
        /// SDR rate-only criteria written; sub-second, no pre-flight wait needed.
        case applied
        /// Criteria identical to what is already active; nothing written, no switch pending (#133).
        case unchanged
    }

    /// #133 pure decision: skip only when we previously applied (`didApply`) exactly these criteria and have
    /// not reset since. Otherwise write, returning whether a dynamic-range switch is expected (HDR) or not (SDR).
    ///
    /// AE#678: `managerHoldsCriteria` is the display manager's own answer. A host that wrote
    /// `preferredDisplayCriteria = nil` itself (leaving full screen for a preview) leaves `lastApplied`
    /// describing criteria the panel no longer has, and the skip then kept the UI mode on a channel that
    /// needed its frame rate.
    nonisolated static func applyOutcome(didApply: Bool, last: AppliedCriteria?, target: AppliedCriteria,
                                         managerHoldsCriteria: Bool = true) -> ApplyResult {
        if didApply, managerHoldsCriteria, last == target { return .unchanged }
        return target.isHDR ? .willSwitch : .applied
    }

    /// How long `waitForSwitch` blind-polls for a switch to *start* before giving up (Stage 1). The wait is
    /// blind by construction: nothing reports "a criteria write is inbound", so the budget is a bet on the
    /// writer's latency and every millisecond of it is startup time when the bet is wrong (#274).
    enum StartGrace: Equatable {
        /// Nothing can be pending; return before touching the display manager.
        case skip
        /// 200 ms: only a rate-only switch could still start (the pre-#274 budget, sized for a synchronous
        /// engine write). The engine declines to pre-flight its own rate-only writes on the d87b54d premise
        /// that they are sub-second.
        ///
        /// That premise is now contradicted, though not yet by a run that also juddered: on the Sodalite#49
        /// reporter's Apple TV a rate-only SDR switch was measured at ~2.9 s end to end, and two further
        /// runs never reported an end at all inside Stage 2's cap. Reading that as "shorten nothing, widen
        /// nothing" is deliberate: one panel is not grounds for making every session's cold start wait
        /// longer, and the runs that produced these numbers played cleanly.
        case brief
        /// 1000 ms: a dynamic-range switch may still be inbound from a writer whose timing we don't control
        /// (AVKit's auto-criteria path fires from the AVPlayerItem formatDescription). DV P5 cold start
        /// depends on this budget.
        case full

        /// The budget both as the log lines report it and as Stage 1 spends it. Latency fixes are verified
        /// off the number they moved, so both the spent-time line and the #289 skip line name it (#274).
        var budgetMs: Int {
            switch self {
            case .skip:  0
            case .brief: 200
            case .full:  1000
            }
        }
    }

    /// Stage 2's ceiling: long enough that an unobservable DV switch does not gate the first frame the way
    /// the old fixed 5 s poll did, short enough to stay a startup cost.
    ///
    /// **Do not raise this to "fit" the measured switch duration.** Twelve device measurements (Apple TV 4K
    /// 3rd gen, tvOS 26.5, 2026-08-09, dynamic-range and range-plus-rate alike) put a real switch at 2779 to
    /// 2898 ms, so the pre-flight gate reliably breaks out here at ~2.0 s with the panel still switching.
    /// That looks like a defect and is currently load-bearing: breaking out is what lets `loadNative` start
    /// while the switch finishes, and the play gate then waits out whatever is left. Timed end to end:
    ///
    ///     cap 2000: pre-flight breaks +2020, load ~850 ms, play() at ~+2918
    ///     cap 4000: pre-flight ends +2892 on the notification, load ~850 ms, play() at ~+3740
    ///
    /// The "corrected" cap costs a full load's worth of startup, ~820 ms here, because the load is serialised
    /// behind the wait. A VOD load no longer is: since AE#348 the segment production runs during the switch
    /// and only the routing read waits for this gate (`preflightGateRunsBesideLoad`). Live still loads
    /// behind it, so for live this number is still doing both jobs.
    nonisolated static let stage2CapMs = 2000

    /// What the settle wait is allowed to cost, decided by what else is waiting on it.
    enum SettleCap: Equatable {
        /// `stage2CapMs`. For a gate that runs *before* the item is built, where breaking out early is what
        /// releases the load, and for live, where a zap must not sit behind a panel handshake.
        case standard
        /// Wait for the end that was observed to be coming, up to `observedEndCapMs`. For a gate that runs
        /// after the item is ready: nothing else is pending, so the wait costs only itself.
        case awaitObservedEnd
    }

    /// Ceiling for `awaitObservedEnd`. Only reachable when a start notification was recorded and its end
    /// never arrives, which did not happen once across sixteen device switches; the real numbers are 2.8 s
    /// for a dynamic-range switch and 3.55 s for a rate switch.
    nonisolated static let observedEndCapMs = 6000

    /// A gate that ran after the load, on a switch it saw start, waits for that switch to end.
    ///
    /// The measurement that decides this (Apple TV 4K 3rd gen, tvOS 26.5, 2026-08-09, SDR 25p on a 60 Hz
    /// system, so a rate-only write with no pre-flight): the item was ready at +443 ms, the cap released
    /// `play()` at +2130 ms, and the panel finished switching at +3555 ms. **The panel blanks throughout**,
    /// which is the part no log shows: the first visible frame lands at +3555 ms either way, so releasing
    /// early buys no picture at all and costs 1.4 s of content played into a dark screen.
    ///
    /// This is the answer to "a rate-only switch does not need to be waited out" (Sodalite#49, DrHurt). It
    /// does not need to be waited out for *correctness*, since only a range change can fail AVPlayer, but
    /// waiting is free where the panel is dark anyway, and not waiting is not.
    nonisolated static func settleCapMs(cap: SettleCap, startRecorded: Bool) -> Int {
        guard cap == .awaitObservedEnd, startRecorded else { return stage2CapMs }
        return observedEndCapMs
    }

    /// The observed-end wait left for one armed switch, shared by every gate that waits on it.
    struct ObservedEndBudget: Equatable {
        let armGeneration: Int
        let deadlineNanos: UInt64
    }

    /// DEC-105: `observedEndCapMs` is one budget per armed switch, not per gate. The #667 wait leaves the
    /// record unspent for the play gate, so on a panel whose end is never announced (or whose in-progress
    /// flag sticks) both read the same `.running`, and each used to spend the whole cap on one switch.
    /// The first gate to wait sets the deadline; a later gate on the same arm gets what is left of it.
    nonisolated static func observedEndCap(settleCap: SettleCap, startRecorded: Bool, armGeneration: Int,
                                           nowNanos: UInt64, budget: ObservedEndBudget?)
        -> (capMs: Int, budget: ObservedEndBudget?) {
        let capMs = settleCapMs(cap: settleCap, startRecorded: startRecorded)
        guard capMs == observedEndCapMs, armGeneration != 0 else { return (capMs, budget) }
        if let budget, budget.armGeneration == armGeneration {
            return (min(capMs, elapsedMs(fromNanos: nowNanos, toNanos: budget.deadlineNanos)), budget)
        }
        let deadline = nowNanos &+ UInt64(capMs) * 1_000_000
        return (capMs, ObservedEndBudget(armGeneration: armGeneration, deadlineNanos: deadline))
    }

    /// Audit LIF-106: one poll of a switch wait. False once the load waiting on it is gone: its task
    /// was cancelled (a cancelled `Task.sleep` returns at once, so the `try?` these loops used turned
    /// them into a hot spin on the main actor until the cap) or a newer load or stop superseded it.
    static func gateTick(milliseconds: Int, isCurrent: () -> Bool) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
        } catch {
            return false
        }
        return isCurrent()
    }

    /// Both stages spend a deadline, not a poll count. `n` sleeps of `m` ms is only `n * m` on an idle
    /// scheduler: the same 40 x 50 ms Stage 2 ran 2082 ms in one of the reporter's runs and 2862 ms in
    /// another, on a device reporting `thermal=serious` throughout. A budget that stretches 40 % under the
    /// load it exists to survive is not a budget, and it was the second measurement defect in a row to make
    /// #49's logs unreadable (Sodalite#49).
    nonisolated static func isBudgetSpent(elapsedMs: Int, budgetMs: Int) -> Bool {
        elapsedMs >= budgetMs
    }

    /// #289: with Match Content off, nothing can start a switch, so waiting for one is pure startup latency
    /// on the path that gates `play()`. `apply()` already declines to write criteria in that state, but it
    /// returns `.applied`, which is neither of the two outcomes the play-gate short-circuits on, and a
    /// sole-writer host never reaches `apply()` at all: tvOS ignores `preferredDisplayCriteria` for AVKit's
    /// write just the same, so that path can only be caught here.
    ///
    /// Read live from the display manager rather than from `LoadOptions.matchContentEnabled`: the host flag
    /// is a snapshot that can be stale in the dangerous direction (reporting off while matching is on would
    /// skip a wait a DV cold start needs).
    nonisolated static func shouldWait(startGrace: StartGrace, matchingEnabled: Bool) -> Bool {
        startGrace != .skip && matchingEnabled
    }

    /// Who wrote the criteria a switch belongs to, and what range they asked for. Only the engine's own HDR
    /// write makes a switch that ends with EDR headroom still at 1.0 a failure; a switch the engine never
    /// initiated carries no target range it could check against, so attributing one produced a false "panel
    /// stayed SDR despite HDR criteria" WARN on sole-writer hosts (#274). The Stage 2 cap reads the same
    /// attribution: an engine rate-only write that never reports an end is not the unobservable-DV case its
    /// log line claimed for every session alike (Sodalite#49).
    enum CriteriaAttribution: Equatable {
        /// Engine wrote SDR rate-only criteria: a settle at headroom 1.0 is the expected end state.
        case engineRateOnly
        /// Engine wrote HDR criteria: a settle at headroom 1.0 is a real dynamic-range handshake failure.
        case engineHDR
        /// Engine never wrote this session (sole-writer host): the switch was somebody else's, its target
        /// range is not knowable here.
        case hostDriven
    }

    /// Will the panel present this session in HDR?
    ///
    /// `UIScreen.currentEDRHeadroom` is honest exactly when no video is on the screen, and dishonest for
    /// seconds to tens of seconds after HDR video has been. Measured on an Apple TV 4K (3rd gen), HDR10+
    /// panel, 2026-09-02, seven runs across four configurations:
    ///
    ///     output fixed 4K HDR, nothing playing:      1.20, and again 1.20 fifty-five seconds later
    ///     output fixed 4K HDR, SDR content playing:  1.20
    ///     output fixed 4K SDR, either of the above:  1.00
    ///     output fixed 4K HDR, 17s after HDR ended:  1.20
    ///
    /// So a panel parked in HDR does report itself, with no transition anywhere in sight, and it keeps
    /// reporting itself: the value is stable rather than decaying, and a rate-only criteria write does not
    /// collapse it either (measured with Match Frame Rate on, `SET: format=sdr rate=25.000 extensions=none`,
    /// headroom 1.20 straight through). What DOES collapse it is HDR video on the screen: the 2026-08-02
    /// trace has it falling 1.20 -> 1.00 thirteen seconds into a confirmed HDR10 session with
    /// `isDisplayModeSwitchInProgress` false throughout, and the 2026-08-09 table below is the same effect.
    /// It recovers once that video is gone.
    ///
    /// That is why a REPLAY was the failure shape: it starts while the previous HDR session has already
    /// pulled the value down, the single read taken after `waitForSwitch` sees 1.0, and on tvOS that one
    /// boolean IS the master-vs-media routing gate (`resolveUseMasterPlaylist`, where
    /// `builtInPanelEngagesOnDemand` is false), so the session was served media-direct with no HDR signaling
    /// and labelled SDR while the TV itself reported HDR.
    ///
    /// Do not read "the headroom is a transition artifact" into this. That was the model until 2026-09-02 and
    /// it is wrong in the direction that costs a search: it predicts a parked panel can never prove itself,
    /// which sends the next reader hunting for a way to force a transition. The engine's problem was never
    /// that the panel had nothing to say, it was WHEN the question gets asked.
    ///
    /// The reading is still trusted only as a positive, because a 1.0 at the moment of asking cannot be told
    /// apart from a panel that is genuinely SDR. Its absence is answered by what this display has already
    /// proven: once a criteria write has driven it into HDR, asking for HDR again puts it there. A panel that
    /// never engages (Match Frame Rate on, Match Dynamic Range off, which tvOS reports through the same
    /// combined toggle) never sets the proof and keeps the conservative answer, so it is still never offered a
    /// PQ master it would reject with -11848.
    ///
    /// `UIScreen.potentialEDRHeadroom` looks like the way out of all of this and is not. It reads **1.00 on
    /// tvOS regardless of the display's mode**, measured 2026-08-09 on an Apple TV 4K (3rd gen), tvOS 26.5,
    /// HDR10 panel, same title played once with the box set to 4K HDR and once to 4K SDR:
    ///
    ///     4K HDR, t+2.5s:  current 1.20, potential 1.00
    ///     4K HDR, t+20s:   current 1.00, potential 1.00
    ///     4K SDR, t+2.5s:  current 1.00, potential 1.00
    ///
    /// Those three rows were taken DURING playback, which is why the second one reads 1.00; see the idle
    /// table above for the same box with nothing on the screen. The first row is the one that closes it:
    /// the panel was demonstrably in an HDR mode, and the value
    /// documented as the maximum the screen can display read *lower* than the live one at the same instant,
    /// from the same `UIScreen`. That is not a sampling-time problem, it is a property tvOS does not
    /// maintain. There is no mode read-back; do not go looking for one here again (Sodalite#49).
    ///
    /// The residual risk is the reverse: the output configuration changed after a proven session without the
    /// app leaving the foreground (Settings itself is only reachable by leaving, which clears the proof). That
    /// offers one master to an SDR panel, which the reactive master-to-media fallback (#98) and the
    /// startup-readiness gate (#35) already recover from, and the refusal clears the proof. Trading a rare, self-healing
    /// fallback for a silent permanent HDR loss on every replay is the point of this function.
    ///
    /// `matchingDisabled` is the one case where the proof counts without an HDR write. With Match Content
    /// off nobody can switch the panel, neither the engine nor an AVKit sole writer, so it stays in the
    /// output mode the user parked it in, and the proof (an accepted HDR master, typically) describes
    /// exactly that mode. Changing it goes through Settings, which means leaving the app, which clears the
    /// proof. AE#887: without this a live channel after a proven VOD title, both on a box parked in 4K HDR, was
    /// labelled SDR for its whole length, because the skipped write left the attribution `.hostDriven`.
    nonisolated static func panelPresentsHDR(
        headroomAboveOne: Bool,
        attribution: CriteriaAttribution,
        matchingDisabled: Bool,
        panelProvenToEngageHDR: Bool
    ) -> Bool {
        if headroomAboveOne { return true }
        return (attribution == .engineHDR || matchingDisabled) && panelProvenToEngageHDR
    }

    nonisolated static func criteriaAttribution(didApply: Bool, lastCriteriaWasHDR: Bool) -> CriteriaAttribution {
        guard didApply else { return .hostDriven }
        return lastCriteriaWasHDR ? .engineHDR : .engineRateOnly
    }

    // MARK: - Late panel probe (#459)

    /// How long after the first frames the panel is re-asked whether it is presenting HDR, and how often.
    ///
    /// Every reading `panelPresentsHDR` gets is taken around the criteria write. On a box that has just been
    /// playing HDR, that is the one moment the value is still pulled down by the session being replaced, so a
    /// panel parked in HDR can read SDR there and keep reading SDR for good (#459). The 2026-08-09 device
    /// trace has the reading this window exists to catch, on an Apple TV whose output was fixed to 4K HDR:
    /// headroom 1.20 at t+2.5s, back to 1.00 by t+20s, against a flat 1.00 for the same title with the output
    /// fixed to 4K SDR.
    ///
    /// So the window opens wide enough to contain that rise and closes before the value decays into
    /// meaninglessness. A window that closes with nothing seen is itself the measurement: it says this panel
    /// never raises the headroom, which is the one thing no log line could say before.
    ///
    /// This probe is the instrument, not the last word on the cause. The 2026-09-02 runs (see
    /// `panelPresentsHDR`) could not reproduce #459 on an HDR10+ panel in any configuration, including the
    /// reporter's, because there the idle reading is honest and the load-time read inherits it. Whether the
    /// reporter's panel raises the headroom at all is what this probe's own log line answers, and nothing
    /// further should be built here before it has.
    nonisolated static let playbackProbeWindowMs = 12_000
    nonisolated static let playbackProbeIntervalMs = 250

    /// Whether a session's label can still change by asking the panel again once frames are running.
    ///
    /// SDR sessions are excluded on both counts: SDR content composites no HDR, so the headroom cannot rise
    /// for it, and there would be nothing to upgrade the label to if it did. A paused mount (#124) is
    /// excluded for the first of those reasons alone: no frames, nothing composited, and a window that
    /// closes on that would report the panel's silence as if it had been asked.
    nonisolated static func shouldProbePanelDuringPlayback(
        effectiveFormat: VideoFormat,
        panelPresentedHDRAtLoad: Bool,
        sessionIsPlaying: Bool
    ) -> Bool {
        effectiveFormat != .sdr && !panelPresentedHDRAtLoad && sessionIsPlaying
    }

    /// How long to let a served master settle before reading acceptance as proof.
    ///
    /// A display rejection is fast and arrives before the item is playable: measured on device at 54 to
    /// 61 ms from serving the master to `item.status=failed` with zero `errorLog` events, because
    /// AVFoundation decides at parse and eligibility time rather than after any network activity. Half a
    /// second is an order of magnitude past that and still inside the probe window it delays.
    nonisolated static let masterAcceptanceSettleMs = 500

    /// AE#459: an accepted HDR master answers the panel question better than the headroom does.
    ///
    /// `UIScreen.currentEDRHeadroom` has been measured reading 1.00 on a panel that, in the same session,
    /// accepted an HLG master which AVFoundation then reported as `ITU_R_2100_HLG`. A display that takes an
    /// HDR master is presenting HDR; one that is not refuses with -11868 or -11848, which is exactly what
    /// the same box does when its output is locked to SDR. So where the headroom is silent, acceptance is
    /// not a weaker substitute for it, it is the stronger reading.
    ///
    /// This proves the LABEL only. It deliberately does not latch the panel proof or re-route the running
    /// session: the route already reaches the master on its own through the attempt, and a diagnostic that
    /// also decided routing would answer a different question than the one being asked.
    ///
    /// `fellBackToMedia` is what separates acceptance from mere service. The fallback withdraws the master
    /// in place, so a session that is still serving it after the settle window was not refused.
    nonisolated static func masterAcceptanceProvesPanel(
        servingHDRMaster: Bool, fellBackToMedia: Bool, sessionIsPlaying: Bool
    ) -> Bool {
        servingHDRMaster && !fellBackToMedia && sessionIsPlaying
    }

    /// Whether the probe takes another sample. One reading above 1.0 is authoritative and latches the proof
    /// for good, so the first hit ends the probe.
    nonisolated static func playbackProbeContinues(elapsedMs: Int, observedHDR: Bool) -> Bool {
        !observedHDR && elapsedMs < playbackProbeWindowMs
    }

    /// How the gate learned a switch was running. This is the one bit that separates "the panel was already
    /// switching while the AVPlayerItem was built" from "the switch started after the gate opened", the
    /// ordering question Sodalite#49 was filed on and which no log line could answer.
    ///
    /// Since #339 the notifications are recorded from the criteria write onward rather than from gate entry,
    /// so `preGateObserved` answers that question with two timestamps. The flag-derived cases remain for what
    /// the notifications miss, and each one now indicts something specific: `preGate` says a switch was
    /// running that this session's write never announced, `inGateFlagOnly` says the start notification for a
    /// switch inside the gate went missing. Both are measurements of the observation itself, which is what
    /// makes the #339 change checkable on a device rather than only in review.
    enum StartSignal: String, Equatable {
        /// Start notification recorded between the criteria write and the gate opening.
        case preGateObserved = "pre-gate (start notification, before gate entry)"
        /// In-progress flag set on the first poll with no start recorded since the write: the switch began
        /// before the observation was armed, or its notification never arrived.
        case preGate = "pre-gate (flag only, no start notification since the criteria write)"
        /// Mode-switch-start notification arrived while the gate was polling.
        case inGate = "in-gate"
        /// The flag rose after the first poll and no start notification ever arrived. The switch began
        /// inside the gate either way; what is missing is the notification, not the ordering.
        case inGateFlagOnly = "in-gate (flag only, start notification missed)"
        /// Nothing observed within the budget.
        case none = "none"
    }

    /// Stage 1's per-poll verdict, `nil` while nothing has been observed yet. Pure so the distinction the
    /// whole of #49 rests on is covered by tests rather than by reading a device log.
    nonisolated static func classifyStart(isFirstPoll: Bool,
                                          startNotificationFired: Bool,
                                          switchInProgress: Bool) -> StartSignal? {
        if startNotificationFired { return .inGate }
        guard switchInProgress else { return nil }
        return isFirstPoll ? .preGate : .inGateFlagOnly
    }

    /// What the observation already knows when the gate opens (#339). The observers are armed at the
    /// criteria write, so a switch that started, or started and finished, while the item was being built is
    /// knowable here instead of having to be inferred from a flag inside Stage 1.
    enum ObservedSwitch: Equatable {
        /// Start and end both recorded before the gate opened, and the panel is not switching now: there is
        /// nothing left to wait for.
        case settled(startBeforeGateMs: Int, switchMs: Int)
        /// A start was recorded and no end followed it. Stage 1 has nothing left to discover, so the gate
        /// goes straight to waiting the end out.
        case running(startBeforeGateMs: Int)
        /// Nothing usable recorded since the write.
        case none
    }

    /// May a raised EDR headroom end the wait?
    ///
    /// The headroom rises *with* the dynamic-range transition, so during a switch it reports "HDR is coming
    /// up", not "the panel is done". Device measurement (Apple TV 4K 3rd gen, tvOS 26.5, 2026-08-09): a run
    /// whose headroom reached 1.20 at +374 ms belonged to a switch that ended at +2853 ms, and the gate
    /// released `play()` 2.5 s into a running HDMI handshake. That is the "first frame hits a mid-transition
    /// panel" case the whole wait exists to prevent, and the shape Sodalite#49 was filed on.
    ///
    /// The deciding input is whether **this load recorded a start notification at all**, not whether one
    /// arrived since this gate opened. A load runs two gates (pre-flight, then play), the second finds the
    /// record already consumed, and reading that as "no observable switch" let the headroom end the wait
    /// 759 ms early on the very next device run. If a start was recorded, its end will be too, and the
    /// notification or the in-progress flag is the authority: on that device the flag cleared within 1 ms of
    /// the notification.
    ///
    /// Without a recorded start the headroom is the only end signal there is, which is the unobservable-DV
    /// panel the Stage 2 cap exists for, so it keeps its say there.
    nonisolated static func startPhaseHeadroomSettles(startRecorded: Bool, switchInProgress: Bool) -> Bool {
        !startRecorded && !switchInProgress
    }

    /// Stage 2 has already classified a start, so the flag is expected to be set and cannot disqualify the
    /// headroom the way it does in Stage 1; an unobservable-DV panel sticks it `true` for the whole switch.
    /// A recorded start still rules the headroom out.
    nonisolated static func settlePhaseHeadroomSettles(startRecorded: Bool) -> Bool {
        !startRecorded
    }

    /// May the entry fast-exit take a raised headroom as "nothing to wait for"?
    ///
    /// Its purpose is the panel a previous session already drove into HDR: no transition is pending and the
    /// wait would be dead time. A panel that is mid-switch produces the same raised headroom for the
    /// opposite reason, so the in-progress flag has to agree. Same device run: the play gate read headroom
    /// 1.20 at entry and returned in 0 ms while the switch had another 2.4 s to run.
    nonisolated static func entryHeadroomIsSettled(headroomAboveOne: Bool, switchInProgress: Bool) -> Bool {
        headroomAboveOne && !switchInProgress
    }

    /// How the cadence the panel is measurably running relates to the rate the criteria asked for (#449).
    enum PanelRateRelation: Equatable {
        /// The panel is running the requested rate.
        case exact(panelRate: Double)
        /// The panel is running an exact integer multiple of the requested rate. Every frame lands on a
        /// whole number of refreshes, which is the mode tvOS itself picks for sub-50 content (a 25.000
        /// request measured on a panel held at 50.002 Hz, #449), so nothing is wrong with it.
        ///
        /// Unlike an exact match this reading cannot rule out a switch to the requested rate still being
        /// in flight, because both cadences satisfy the request. It settles only after `panelMultipleDwellMs`
        /// of holding it unbroken; see `rateOnlySwitchIsSettled`.
        case multiple(panelRate: Double, factor: Int)
        /// Measured, and neither. A switch may still be running, or the panel ignored the criteria.
        case different(panelRate: Double)
        /// No fresh display-link tick, or no rate was requested. The panel is not presenting frames, which
        /// is exactly what a blanked mid-handshake panel looks like from here.
        case unmeasured

        /// Whether two readings describe the same panel state. Deliberately not `==`: the per-tick figure
        /// moves in the fourth decimal, so comparing the hertz would restart the dwell on nearly every
        /// tick and no run could ever complete.
        func describesSameStateAs(_ other: PanelRateRelation) -> Bool {
            switch (self, other) {
            case (.exact, .exact), (.different, .different), (.unmeasured, .unmeasured): true
            case (.multiple(_, let a), .multiple(_, let b)): a == b
            default: false
            }
        }

        var logDescription: String {
            switch self {
            case .exact(let rate):
                String(format: "panel %.3fHz, the requested rate", rate)
            case .multiple(let rate, let factor):
                String(format: "panel %.3fHz", rate) + ", an exact x\(factor) multiple of the requested rate"
            case .different(let rate):
                String(format: "panel %.3fHz, neither the requested rate nor a multiple of it", rate)
            case .unmeasured:
                "panel cadence unmeasured (no display-link tick within the freshness window)"
            }
        }
    }

    /// How far two refresh rates may differ and still be the same mode, as a fraction of the rate (#449).
    ///
    /// The binding pair is 23.976 against 24.000: 0.024 Hz apart, and they are genuinely different modes
    /// (mixing them repeats a frame every ~42 s). At 24 Hz this tolerance is 0.012 Hz, half that gap.
    /// The other direction is a panel that reports its mode slightly off nominal, which is the normal case:
    /// the #449 reporter's 50 Hz panel reads 50.002 Hz.
    nonisolated static let panelRateTolerance: Double = 0.0005

    nonisolated static func panelRateRelation(requestedRate: Float?, panelNominalRate: Double?) -> PanelRateRelation {
        guard let requested = requestedRate.map(Double.init), requested > 0, requested.isFinite,
              let panel = panelNominalRate, panel > 0, panel.isFinite else { return .unmeasured }
        if abs(panel - requested) <= requested * panelRateTolerance { return .exact(panelRate: panel) }
        // Bounded before the Int conversion: the ratio is derived from a display-link duration, and an
        // Int(_:) of a value outside Int's range traps.
        let factor = (panel / requested).rounded()
        if factor >= 2, factor <= 16, abs(panel - factor * requested) <= panel * panelRateTolerance {
            return .multiple(panelRate: panel, factor: Int(factor))
        }
        return .different(panelRate: panel)
    }

    /// #449: a rate-only criteria write asks the panel to change exactly one thing, so once the panel is
    /// measurably running the requested rate that change is done, whatever the notifications say.
    ///
    /// It has to be said that way round, because on the reporter's panel the notifications say nothing
    /// usable: a `rate=50.000` write to a display already running 50.002 Hz still posts a mode-switch
    /// start, never posts an end, and leaves `isDisplayModeSwitchInProgress` set for the whole cap. Eight
    /// of nine gates in an 18 minute session spent the full 2 s that way, and with the #447 holdback down
    /// to 6 s the manifest no longer hides it: the first frame reaches the panel a second earlier and then
    /// sits there frozen, which reads worse than the longer join it replaced.
    ///
    /// Restricted to `engineRateOnly` on purpose. An HDR write asks for a dynamic range as well, and a
    /// matching rate says nothing about that handshake; a switch nobody here initiated has no requested
    /// rate to compare against at all. The residual case this does not cover, and which the 2 s cap does
    /// not cover either, is a range transition started elsewhere (a preceding `reset()`, a sole-writer
    /// host) that is still running under a rate the panel never had to change: real switches on this
    /// hardware measure 2.8 s, so the cap was already releasing ~800 ms into them.
    /// Round 2 (#449) adds the integer multiple, and it has to be earned rather than read once, which is
    /// the whole difference between the two cases.
    ///
    /// An exact match settles on sight because the requested state and the observed state are the same,
    /// so a pending switch, if there is one, is a switch to what is already on screen. A multiple cannot
    /// argue that: a 25.000 request is satisfied by the 50.002 Hz the panel already runs AND by a 25 Hz
    /// mode it might still be switching to. What separates them is time. A real switch on this hardware
    /// takes ~2.8 s and blanks the panel while it runs, so a display link that keeps delivering ticks at
    /// an unbroken cadence is a panel that is presenting, not one mid-handshake. `panelMultipleDwellMs`
    /// of that is the evidence, and any tick that reads a different cadence or none at all restarts it.
    ///
    /// What this does NOT claim is that no switch will begin later. Nothing here could: the 2 s cap never
    /// covered that either, since a 2.8 s switch outlives it and the gate was already releasing ~800 ms
    /// into one. The choice is between releasing into a hypothetical blank and holding a frame still for
    /// two seconds on every 25 fps join, which the reporter measured at 2.05 s and 2.02 s of visibly
    /// frozen picture on a panel that was demonstrably presenting throughout. The `mode check (native)`
    /// line a few seconds later is the witness for the residue: it reads the panel again, so a switch
    /// that did arrive late is visible in the same capture rather than assumed away.
    ///
    /// AE#950 narrows both readings to a panel that did not have to change rate. When the panel read
    /// something else just before the write (`preWrite` is `.different`), the display link reports the new
    /// cadence as soon as the compositor runs at it, well before the HDMI sink has re-locked: on an LG C2
    /// the gate released 50 to 135 ms after the switch started, tvOS reports such switches ending after
    /// ~2.5 s, and half the starts flashed pink noise over the black in between. A reading reached by
    /// switching says only that the switch began, so that write waits for the end, the in-progress flag or
    /// the cap, as an HDR write does. The #449 panel read the requested rate before the write, which keeps
    /// its fast exit; a missing pre-write reading changes nothing.
    nonisolated static func rateOnlySwitchIsSettled(attribution: CriteriaAttribution,
                                                    relation: PanelRateRelation,
                                                    heldForMs: Int,
                                                    preWrite: PanelRateRelation? = nil) -> Bool {
        guard attribution == .engineRateOnly else { return false }
        if case .different = preWrite { return false }
        switch relation {
        case .exact: return true
        case .multiple: return heldForMs >= panelMultipleDwellMs
        case .different, .unmeasured: return false
        }
    }

    /// How long the panel must hold an integer multiple of the requested rate before that reading is
    /// allowed to settle a rate-only write (#449).
    ///
    /// Six Stage 2 polls, and more than seven frame intervals at the slowest mode tvOS switches to
    /// (23.976 Hz, 41.7 ms), so a blank cannot hide inside it. Against the 2 s cap it returns 85% of the
    /// wait; against a switch that begins after it, nothing was protecting that case anyway.
    nonisolated static let panelMultipleDwellMs = 300

    /// An unbroken run of the same panel reading, in Stage 2 milliseconds.
    struct PanelCadenceRun: Equatable {
        let relation: PanelRateRelation
        let startedAtMs: Int

        func heldMs(atMs: Int) -> Int { max(0, atMs - startedAtMs) }
    }

    /// Carry a run forward, or start a new one where the reading changed. A panel that blanks mid-dwell
    /// reads `.unmeasured` for those ticks, which is a different state and therefore a new run: that is
    /// the case the dwell exists to catch.
    nonisolated static func extendCadenceRun(_ run: PanelCadenceRun?,
                                             relation: PanelRateRelation,
                                             nowMs: Int) -> PanelCadenceRun {
        if let run, run.relation.describesSameStateAs(relation) { return run }
        return PanelCadenceRun(relation: relation, startedAtMs: nowMs)
    }

    /// What the dwell did across a whole Stage 2, so a reading that never settled can say why (#449).
    ///
    /// The reporter's caution, from the same capture that confirmed the fix: `mode check (native)` read
    /// cadences well away from nominal on 4 of 12 reads (35.456 Hz against a nominal 50.002), and a tick
    /// like that landing inside the dwell restarts the run. It cannot reach the gate's reading, because
    /// the two measure different things: `mode check` reports THROUGHPUT averaged over its whole sample
    /// (`tickCount / span`, which missed ticks drag down), while the gate reads the mode interval of a
    /// single tick (`targetTimestamp - timestamp`), which is why `nominal` stayed at 50.002 in every one
    /// of those four lines. What CAN break the run is the freshness guard, if the missed ticks arrive in
    /// one block longer than `panelCadenceFreshnessMs`. That outcome is safe (the cap stands, as before
    /// the fix), so this is not a guard, it is the evidence: a cap line that names the breaks and the
    /// longest run turns "I would look here first" into a reading.
    struct PanelCadenceHistory: Equatable {
        var run: PanelCadenceRun?
        /// How many times a tick reported something other than what the run held.
        var restarts: Int = 0
        /// The longest unbroken run this Stage 2 achieved, in milliseconds.
        var longestHeldMs: Int = 0

        var logDescription: String {
            "the cadence run broke \(restarts) time\(restarts == 1 ? "" : "s"), "
            + "longest unbroken \(longestHeldMs)ms of the \(panelMultipleDwellMs)ms a multiple needs"
        }
    }

    /// Fold one Stage 2 tick into the history above. Pure, because the case it describes is the one a
    /// device run does not produce on demand.
    nonisolated static func extendCadenceHistory(_ history: PanelCadenceHistory,
                                                 relation: PanelRateRelation,
                                                 nowMs: Int) -> PanelCadenceHistory {
        var next = history
        let run = extendCadenceRun(history.run, relation: relation, nowMs: nowMs)
        if let previous = history.run, previous.startedAtMs != run.startedAtMs {
            next.restarts += 1
            next.longestHeldMs = max(next.longestHeldMs, previous.heldMs(atMs: nowMs))
        }
        next.run = run
        next.longestHeldMs = max(next.longestHeldMs, run.heldMs(atMs: nowMs))
        return next
    }

    /// How stale a display-link tick may be and still describe the panel's current cadence (#449). Three
    /// frame intervals at the slowest mode tvOS switches to (23.976 Hz), so a panel that is merely running
    /// slowly is not mistaken for one that has stopped presenting.
    nonisolated static let panelCadenceFreshnessMs = 125

    /// Whether a recorded switch belongs to the load whose gate is asking (#339).
    ///
    /// The record survives between loads, so a gate that runs without a preceding arm must not read it: an
    /// engine-writer reload re-applies no criteria and arms nothing, and inheriting the previous load's start
    /// would make it wait out an end that can no longer arrive.
    ///
    /// Marking the record spent is a separate decision (`consumesRecord`), because a load runs up to two
    /// gates and both are entitled to the same evidence. The pre-flight deliberately does not spend it: on
    /// the device, a play gate that opened after its switch had ended found the record already spent, fell
    /// back to Stage 1 and paid its 200 ms grace for a switch it could have known was over.
    nonisolated static func recordIsFreshEvidence(recordGeneration: Int, lastSpentGeneration: Int) -> Bool {
        recordGeneration != 0 && recordGeneration != lastSpentGeneration
    }

    /// Pure verdict on the recorded timestamps.
    ///
    /// Two asymmetries are deliberate. A `settled` conclusion needs *both* a start and an end, because an end
    /// alone can belong to an older switch (the criteria reset a sole-writer load performs makes one), and
    /// mistaking that for this session's settle would hand a DV P5 cold start to a panel still in SDR. And
    /// `switchInProgress` may only veto, never confirm: the flag is documented as unreliable right after a
    /// write, so it can move the gate towards waiting and never towards proceeding.
    nonisolated static func observedSwitch(startedAtNanos: UInt64?,
                                           endedAtNanos: UInt64?,
                                           gateEntryNanos: UInt64,
                                           switchInProgress: Bool) -> ObservedSwitch {
        guard let started = startedAtNanos else { return .none }
        let startBeforeGateMs = elapsedMs(fromNanos: started, toNanos: gateEntryNanos)
        if let ended = endedAtNanos, ended >= started, !switchInProgress {
            return .settled(startBeforeGateMs: startBeforeGateMs,
                            switchMs: elapsedMs(fromNanos: started, toNanos: ended))
        }
        return .running(startBeforeGateMs: startBeforeGateMs)
    }

    /// The numbers a settle log needs to be usable: when the switch started relative to the gate, how long
    /// the whole gate took, and, when both notifications were seen, how long the panel's switch actually
    /// took. All three used to be unavailable: the stage budgets were reported instead of measurements
    /// (#49), and a switch that completed before the gate opened produced no numbers at all (#339).
    nonisolated static func timingSuffix(startSignal: StartSignal, stage1Ms: Int, totalMs: Int,
                                         startBeforeGateMs: Int? = nil, switchMs: Int? = nil) -> String {
        let start = startBeforeGateMs.map { "start \(startSignal.rawValue) \($0)ms before gate entry" }
            ?? "start \(startSignal.rawValue) after \(stage1Ms)ms"
        let measured = switchMs.map { ", switch \($0)ms end to end" } ?? ""
        return "\(start), total \(totalMs)ms\(measured)"
    }

    /// Guarded against reversed arguments: unsigned uptime subtraction traps, and a diagnostic helper is a
    /// poor reason to crash playback.
    nonisolated static func elapsedMs(fromNanos start: UInt64, toNanos end: UInt64) -> Int {
        guard end > start else { return 0 }
        return Int(Double(end - start) / 1_000_000)
    }

    nonisolated static func elapsedMs(since start: DispatchTime) -> Int {
        elapsedMs(fromNanos: start.uptimeNanoseconds, toNanos: DispatchTime.now().uptimeNanoseconds)
    }

    /// AE#459: one line carrying everything the system will say about the display, in a fixed shape so a
    /// reporter can be asked to grep for it.
    ///
    /// Built pure because the values come from four different objects and the line is the instrument: a
    /// diagnostic whose format drifts cannot be compared against the one a reporter posted last month.
    ///
    /// `headroomLimit` is `UITraitCollection.hdrHeadroomUsageLimit` (tvOS 26), which the header describes
    /// as whether HDR headroom should be used for the current UI configuration, disabled for instance while
    /// an app's windows are in the background. It is not a panel readout, and that is exactly why it belongs
    /// next to one: a limit that is ACTIVE caps what the headroom properties are allowed to report, so a
    /// 1.00 under it is a statement about this app's UI state and not about the display. Without it, that
    /// case is indistinguishable from a panel that genuinely presents SDR. The reporter's own hypothesis for
    /// the tvOS 27 silence is that the system UI is now mastered in HDR, which is precisely the kind of
    /// change that would move when these limits apply.
    ///
    /// `potentialEDR` is in here at DrHurt's suggestion and against my own measurement, which is the point.
    /// It read a flat 1.00 on an Apple TV 4K 3rd gen on tvOS 26.5 while `currentEDR` read 1.20 on the same
    /// `UIScreen` in the same moment, so it looked like a property tvOS does not maintain. That was one box
    /// on one OS, and the box this issue is about answers differently on the other property, so the honest
    /// move is to print both and let a second panel decide rather than to carry my own result as a rule.
    nonisolated static func panelReadoutLine(
        phase: String,
        currentEDR: CGFloat,
        potentialEDR: CGFloat,
        switching: Bool,
        matching: Bool,
        hdrEligible: Bool,
        proven: Bool,
        headroomLimit: String
    ) -> String {
        "[DisplayCriteria] panel readout \(phase): "
        + "currentEDR=\(String(format: "%.2f", currentEDR)) "
        + "potentialEDR=\(String(format: "%.2f", potentialEDR)) "
        + "headroomLimit=\(headroomLimit) "
        + "switching=\(switching ? "yes" : "no") "
        + "matching=\(matching ? "on" : "off") "
        + "hdrEligible=\(hdrEligible ? "yes" : "no") "
        + "provenHDR=\(proven ? "yes" : "no")"
    }

    init() {}

    /// Program AVDisplayCriteria before the session starts. `.sdr` programs a rate-only criteria so Match Frame Rate still engages. `codecTag` nil derives from format (`'dvh1'` for DV, `'hvc1'` otherwise). `omitColorExtensions` skips BT.2020 extensions for diagnostic builds. Returns `.willSwitch` when a dynamic-range switch is expected (caller should call waitForSwitch), `.applied` for an SDR rate-only write, or `.unchanged` when the criteria are already active and nothing was written (#133).
    @discardableResult
    func apply(format: VideoFormat, frameRate: Double?, codecTag: FourCharCode?, omitColorExtensions: Bool) -> ApplyResult {
        #if os(tvOS)
        // Reset up front so a skipped apply (Match Content off, no window)
        // can't leave a prior HDR session's flag for waitForSwitch to read.
        lastCriteriaWasHDR = false
        defer { endPreWriteCadence() }

        guard let window = resolveWindow() else {
            EngineLog.emit("[DisplayCriteria] skipped: no window", category: .engine)
            return .applied
        }

        let displayManager = window.avDisplayManager
        // AE#459: before the guard below, not after. A box with Match Content off is exactly the
        // configuration whose panel state nothing else in this log describes.
        logPanelReadout("before apply", window: window)

        // isDisplayCriteriaMatchingEnabled covers both Match Dynamic Range and Match Frame Rate; tvOS picks the applicable dimension internally.
        guard displayManager.isDisplayCriteriaMatchingEnabled else {
            EngineLog.emit("[DisplayCriteria] skipped: Match Content disabled (both Dynamic Range AND Frame Rate off)", category: .engine)
            return .applied
        }

        // HDR sources attach BT.2020 + transfer + matrix extensions; SDR carries only codec + rate so Match Frame Rate can engage without Match Dynamic Range (DrHurt #4: previously early-returned for SDR and Match Frame Rate never fired).
        let isHDR = (format != .sdr)
        // Codec FourCC drives the HDMI mode: 'hvc1' -> HDR10/HLG, 'dvh1' -> Dolby Vision. Using HEVC for a DV source kept DrHurt's Philips panel in HDR10 instead of DV (P8 MKV). ref: Jellyfin #16179, KSPlayer #633.
        let dvh1: FourCharCode = 0x64766831
        let codecType: CMVideoCodecType = codecTag ?? (format == .dolbyVision ? dvh1 : kCMVideoCodecType_HEVC)
        let effectiveRate = Float(frameRate ?? 24.0)
        let hasExtensions = isHDR && !omitColorExtensions

        // #133: skip the panel write when these criteria are already active. Re-writing identical criteria
        // triggers a redundant mode switch that, on unobservable-DV panels, sticks isDisplayModeSwitchInProgress
        // true and makes the following waitForSwitch burn its full ~3s cap on every same-format zap.
        let target = AppliedCriteria(isHDR: isHDR, effectiveRate: effectiveRate,
                                     codecType: codecType, hasExtensions: hasExtensions)
        // #133 follow-up diag: the unchanged-skip only fires for ~1/3-1/2 of eligible same-format zaps. When we have
        // a prior applied signature and still don't skip, log the exact field that diverged (rate/codec/HDR/ext or
        // didApply cleared) so the retest pinpoints why last != target instead of guessing.
        if didApply, let last = lastApplied, last != target {
            EngineLog.emit(
                "[DisplayCriteria] diag no-skip: signature diverged"
                + " rate \(last.effectiveRate)->\(target.effectiveRate)"
                + " codec \(fourccString(last.codecType))->\(fourccString(target.codecType))"
                + " hdr \(last.isHDR)->\(target.isHDR)"
                + " ext \(last.hasExtensions)->\(target.hasExtensions)",
                category: .engine
            )
        } else if !didApply, lastApplied == nil {
            EngineLog.emit(
                "[DisplayCriteria] diag no-skip: no baseline (didApply=false, lastApplied=nil) "
                + "-> first apply this controller instance (a RESET or a fresh controller cleared it)",
                category: .engine
            )
        }
        let managerHoldsCriteria = displayManager.preferredDisplayCriteria != nil
        if didApply, !managerHoldsCriteria {
            EngineLog.emit(
                "[DisplayCriteria] criteria were cleared outside the engine since its last SET; writing again",
                category: .engine
            )
        }
        if case .unchanged = Self.applyOutcome(didApply: didApply, last: lastApplied, target: target,
                                               managerHoldsCriteria: managerHoldsCriteria) {
            // Keep lastCriteriaWasHDR consistent with the still-active criteria for any waitForSwitch classification.
            lastCriteriaWasHDR = isHDR
            EngineLog.emit(
                "[DisplayCriteria] skipped SET reason=unchanged (format=\(format) codec=\(fourccString(codecType)) "
                + "rate=\(frameRate.map { String(format: "%.3f", $0) } ?? "default(24)"))",
                category: .engine
            )
            return .unchanged
        }

        let transferFunction: CFString = switch format {
        case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default:   kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        }
        let extensions: NSDictionary? = hasExtensions ? [
            kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: transferFunction,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
        ] : nil

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: 3840, height: 2160,
            extensions: extensions,
            formatDescriptionOut: &formatDesc
        )
        guard let desc = formatDesc else { return .applied }

        // Always pass the real rate; tvOS uses it when Match Frame Rate is on, ignores it otherwise (dynamic-range switch still fires).
        let criteria = AVDisplayCriteria(refreshRate: effectiveRate, formatDescription: desc)
        // AE#950: read before the write, which is what makes the reading say where the panel came from.
        let preWrite = Self.panelRateRelation(
            requestedRate: effectiveRate,
            panelNominalRate: preWriteCadence?.nominalRateNow(freshWithinMs: Self.panelCadenceFreshnessMs))
        // #339: arm before the write. The switch this triggers can start and finish while the AVPlayerItem
        // is being built, and observers registered at gate entry miss both notifications; that is why two of
        // three device runs in Sodalite#49 never saw an end for a switch that was already over.
        observation.arm()
        preWriteRelation = (observation.snapshot().generation, preWrite)
        displayManager.preferredDisplayCriteria = criteria
        didApply = true
        lastCriteriaWasHDR = isHDR
        lastApplied = target

        EngineLog.emit(
            "[DisplayCriteria] SET: format=\(format) codec=\(fourccString(codecType)) "
            + "rate=\(frameRate.map { String(format: "%.3f", $0) } ?? "default(24)") "
            + "extensions=\(extensions != nil ? "HDR" : "none") "
            + "before write: \(preWrite.logDescription)",
            category: .engine
        )
        // SDR rate-only switches are sub-second; only HDR criteria need the waitForSwitch delay.
        return isHDR ? .willSwitch : .applied
        #else
        return .applied
        #endif
    }

    /// Arm the mode-switch observation for a write this controller does not make.
    ///
    /// A sole-writer host (`LoadOptions.suppressDisplayCriteria`) leaves the criteria to AVKit, which writes
    /// them from the AVPlayerItem's formatDescription somewhere inside the load. The engine has to be
    /// listening before that load starts, not when the gate opens, or the same switch goes unobserved as in
    /// the engine-writer case (#339). Idempotent: re-arming only clears the record and keeps the observers.
    func armSwitchObservation() {
        #if os(tvOS)
        guard resolveWindow() != nil else { return }
        observation.arm()
        #endif
    }

    /// AE#950: start reading the panel's cadence ahead of a criteria write the engine is about to make, so
    /// `apply()` can tell a panel already at the requested rate from one that has to switch to it. Called
    /// at the start of a load, before the probe whose result decides the rate: a display link needs a tick
    /// before it says anything, and the write itself follows the probe without a pause. `apply()` stops it.
    ///
    /// Returns the token the load hands back to `endPreWriteCadence(token:)`. A newer load replaces the
    /// reading of one it superseded, so the older load's exit cannot stop the reading the newer one needs.
    @discardableResult
    func beginPreWriteCadence() -> Int {
        preWriteCadenceToken &+= 1
        #if os(tvOS)
        preWriteCadence?.invalidate()
        preWriteCadence = nil
        if let window = resolveWindow() {
            let sampler = DisplayLinkSampler()
            sampler.start(screen: window.screen)
            preWriteCadence = sampler
        }
        #endif
        return preWriteCadenceToken
    }

    /// Stop the pre-write reading. Idempotent. A load calls it with its token on every exit, so one that
    /// never writes criteria (audio only, a host that owns them) does not leave it running; `apply()`
    /// calls it without one, because the write is what the reading was for.
    func endPreWriteCadence(token: Int? = nil) {
        if let token, token != preWriteCadenceToken { return }
        #if os(tvOS)
        preWriteCadence?.invalidate()
        preWriteCadence = nil
        #endif
    }

    /// AE#667: whether a switch this load was armed for has been seen to start and not yet to end.
    ///
    /// Read from the notifications, not from `isDisplayModeSwitchInProgress` alone, because the flag is
    /// documented as unreliable around a write and sticks `true` on panels whose DV switch never reports.
    /// A switch nobody saw start answers false, so a caller waiting on this never waits for an end that
    /// cannot be announced.
    func observedSwitchIsRunning() -> Bool {
        #if os(tvOS)
        guard let window = resolveWindow() else { return false }
        let snapshot = observation.snapshot()
        guard Self.recordIsFreshEvidence(recordGeneration: snapshot.generation,
                                         lastSpentGeneration: spentArmGeneration) else { return false }
        let observed = Self.observedSwitch(
            startedAtNanos: snapshot.startedAt,
            endedAtNanos: snapshot.endedAt,
            gateEntryNanos: DispatchTime.now().uptimeNanoseconds,
            switchInProgress: window.avDisplayManager.isDisplayModeSwitchInProgress)
        if case .running = observed { return true }
        return false
        #else
        return false
        #endif
    }

    /// AE#667: the system's in-progress flag, for a decision that may only be made more cautious by it.
    var displayModeSwitchInProgress: Bool {
        #if os(tvOS)
        resolveWindow()?.avDisplayManager.isDisplayModeSwitchInProgress ?? false
        #else
        false
        #endif
    }

    /// Block until the panel settles its HDR mode negotiation, bounded so an
    /// unobservable switch can't stall the first frame.
    ///
    /// Callers: the engine pre-flight gates this on `apply()`'s isHDR return; the
    /// play-gate call after the host loads sizes `startGrace` by what can still be
    /// inbound (`AetherEngine.playGateGrace`), so a session that no dynamic-range
    /// switch can reach doesn't pay the DV cold-start budget (#274).
    ///
    /// `preferredDisplayCriteria` is a *hint*: when Match Content is enabled the TV
    /// performs the switch over HDMI and reports progress via the AVDisplayManager
    /// mode-switch notifications. We proceed the instant the OS signals the switch
    /// is done (`AVDisplayManagerModeSwitchEndNotification`) or EDR headroom rises.
    /// Otherwise we bound the wait, because on some panels a Dolby Vision switch is
    /// effectively unobservable to the app: `currentEDRHeadroom` stays 1.0 and
    /// `isDisplayModeSwitchInProgress` can stick `true` even though the panel
    /// visibly enters DV. A blind fixed poll made every such load wait the full
    /// timeout. Presenting slightly early on that fallback is at worst cosmetic:
    /// the panel is mid re-sync (black) during the handshake and shows the correct
    /// frame once it locks. The decode/color-correctness guard is Stage 1 below.
    /// `consumesRecord: false` leaves the observation readable for the load's second gate. The pre-flight
    /// passes it: it waits an HDR switch out before the item is built, and the play gate that follows is
    /// entitled to the same start/end timestamps (#339).
    ///
    /// `isCurrent` answers whether the load this gate holds is still the engine's; the wait is abandoned
    /// at the next tick once it is not, or once its task is cancelled (audit LIF-106).
    func waitForSwitch(startGrace: StartGrace = .full,
                       consumesRecord: Bool = true,
                       settleCap: SettleCap = .standard,
                       isCurrent: () -> Bool = { true }) async {
        #if os(tvOS)
        guard startGrace != .skip else { return }
        guard let window = resolveWindow() else { return }
        let displayManager = window.avDisplayManager
        let screen = window.screen
        let entry = DispatchTime.now()

        // #289: Match Content off means no writer can start a switch, so every millisecond of the budget is
        // dead startup time. The headroom fast-exit below cannot cover it: the panel never transitioned, so
        // the headroom sits at 1.0 and the wait runs its full Stage 1.
        guard Self.shouldWait(startGrace: startGrace,
                              matchingEnabled: displayManager.isDisplayCriteriaMatchingEnabled) else {
            EngineLog.emit("[DisplayCriteria] no wait: Match Content disabled, nothing can start a switch (skipped \(startGrace.budgetMs)ms Stage 1 budget)", category: .engine)
            return
        }

        // #449: what the panel is actually doing while the gate holds play(). Started here rather than at
        // the criteria write so its lifetime is the gate's, and read per tick rather than averaged, because
        // the question is which mode the panel is in *now*. Stage 1 gives it the ticks Stage 2 reads.
        let cadence = DisplayLinkSampler()
        cadence.start(screen: screen)
        defer { cadence.invalidate() }
        func panelRelation() -> PanelRateRelation {
            Self.panelRateRelation(
                requestedRate: lastApplied?.effectiveRate,
                panelNominalRate: cadence.nominalRateNow(freshWithinMs: Self.panelCadenceFreshnessMs))
        }

        // Fast exit: panel already in HDR (headroom already raised, e.g. a prior
        // HDR/DV session left it there) and not currently switching.
        if Self.entryHeadroomIsSettled(headroomAboveOne: observeHeadroom(screen),
                                       switchInProgress: displayManager.isDisplayModeSwitchInProgress) {
            EngineLog.emit("[DisplayCriteria] no switch needed (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)) at entry, panel not switching)", category: .engine)
            return
        }

        // What the observation armed at the criteria write already knows (#339). Everything the stages read
        // from here on is measured against this snapshot, so an end belonging to an older switch (the reset
        // a sole-writer load performs can produce one) cannot settle a gate waiting on a newer one.
        let gateSnapshot = observation.snapshot()
        var startSignal = StartSignal.none
        var stage1Ms = 0
        var preGateStartMs: Int?

        let observed: ObservedSwitch
        if Self.recordIsFreshEvidence(recordGeneration: gateSnapshot.generation,
                                      lastSpentGeneration: spentArmGeneration) {
            observed = Self.observedSwitch(
                startedAtNanos: gateSnapshot.startedAt,
                endedAtNanos: gateSnapshot.endedAt,
                gateEntryNanos: entry.uptimeNanoseconds,
                switchInProgress: displayManager.isDisplayModeSwitchInProgress)
        } else {
            observed = .none
        }
        if consumesRecord { spentArmGeneration = gateSnapshot.generation }

        switch observed {
        case .settled(let before, let measured):
            // The whole switch happened while the item was being built. Before #339 this run was
            // indistinguishable from an unobservable panel and paid the full Stage 2 cap for it.
            EngineLog.emit("[DisplayCriteria] switch settled before the gate opened (\(Self.timingSuffix(startSignal: .preGateObserved, stage1Ms: 0, totalMs: Self.elapsedMs(since: entry), startBeforeGateMs: before, switchMs: measured))); nothing left to wait for", category: .engine)
            return
        case .running(let before):
            // Start already recorded: Stage 1 has nothing to discover, only the end is still open.
            startSignal = .preGateObserved
            preGateStartMs = before
        case .none:
            break
        }

        // Stage 1: `startGrace` for the switch to actually start. The handshake
        // initiates asynchronously after the criteria write (and AVKit's sole-writer
        // path fires it later than the engine pre-flight), so give it headroom
        // before the DV asset loads; starting the decode mid-write races an
        // AVPlayer error on DV Profile 8.1.
        //
        // Which signal ends this stage is recorded, not just that one did: the in-progress flag being set on
        // the *first* poll means the panel was already switching while the item was built, which is the
        // ordering Sodalite#49 suspected. Reading that same flag on a later poll says the opposite (the
        // switch began after entry) and used to be logged as if it said the same, which is why the second
        // round of reporter logs still could not answer the question. `classifyStart` holds that line, and
        // with the observation armed at the write both of its flag-only verdicts now report a missing
        // notification rather than standing in for one.
        if startSignal == .none {
            var isFirstPoll = true
            while !Self.isBudgetSpent(elapsedMs: Self.elapsedMs(since: entry), budgetMs: startGrace.budgetMs) {
                let headroomSettles = observeHeadroom(screen)
                    && Self.startPhaseHeadroomSettles(
                        startRecorded: gateSnapshot.startedAt != nil || observation.hasNewStart(since: gateSnapshot),
                        switchInProgress: displayManager.isDisplayModeSwitchInProgress)
                if observation.hasNewEnd(since: gateSnapshot) || headroomSettles {
                    EngineLog.emit("[DisplayCriteria] settled during start phase (after \(Self.elapsedMs(since: entry))ms, EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
                    return
                }
                if let signal = Self.classifyStart(
                    isFirstPoll: isFirstPoll,
                    startNotificationFired: observation.hasNewStart(since: gateSnapshot),
                    switchInProgress: displayManager.isDisplayModeSwitchInProgress) {
                    startSignal = signal
                    break
                }
                isFirstPoll = false
                guard await Self.gateTick(milliseconds: 10, isCurrent: isCurrent) else {
                    EngineLog.emit("[DisplayCriteria] gate abandoned in the start phase after \(Self.elapsedMs(since: entry))ms: the load it held was cancelled or superseded", category: .engine)
                    return
                }
            }
            // Time spent, not the budget: the polls carry scheduler overhead, and everything downstream is
            // reported relative to this (#49).
            stage1Ms = Self.elapsedMs(since: entry)
            if startSignal == .none {
                // No switch started within the grace: panel already satisfies the criteria
                // or the setter was a no-op. Don't block; AVPlayer tonemaps or errors for real.
                EngineLog.emit("[DisplayCriteria] no switch started (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)) after \(stage1Ms)ms, budget \(startGrace.budgetMs)ms); proceeding", category: .engine)
                return
            }
        }

        // Stage 2: proceed as soon as ANY reliable signal says settled (the
        // mode-switch-end notification, EDR headroom rising for HDR10/HLG, or the
        // in-progress flag clearing), else a bounded ~2s cap so a panel whose DV
        // switch is unobservable to the app can't gate the first frame the way the
        // old fixed 5s poll did.
        // What this gate may spend waiting for the end, given who is waiting on it (`settleCapMs`).
        let stage2Entry = DispatchTime.now()
        let cap = Self.observedEndCap(
            settleCap: settleCap,
            startRecorded: gateSnapshot.startedAt != nil || observation.hasNewStart(since: gateSnapshot),
            armGeneration: gateSnapshot.generation,
            nowNanos: stage2Entry.uptimeNanoseconds,
            budget: observedEndBudget)
        observedEndBudget = cap.budget
        let capMs = cap.capMs
        func timing() -> String {
            // The panel's own switch duration whenever both notifications were seen. This is the number the
            // `.brief` premise ("engine rate-only writes settle sub-second") has never been checked against
            // on hardware, and before #339 an engine-written switch could not produce it at all.
            let now = observation.snapshot()
            let switchMs: Int? = {
                guard let started = now.startedAt, let ended = now.endedAt, ended >= started else { return nil }
                return Self.elapsedMs(fromNanos: started, toNanos: ended)
            }()
            return Self.timingSuffix(startSignal: startSignal, stage1Ms: stage1Ms,
                                     totalMs: Self.elapsedMs(since: entry),
                                     startBeforeGateMs: preGateStartMs, switchMs: switchMs)
        }
        // #449 round 2: the unbroken run of the same panel reading, so a cadence that only settles a
        // multiple after a dwell can be asked how long it has actually held it.
        var cadenceHistory = PanelCadenceHistory()
        // AE#950: where the panel came from, for the write this gate is settling and no other.
        let preWrite = preWriteRelation.flatMap {
            $0.armGeneration == gateSnapshot.generation ? $0.relation : nil
        }
        var reportedSwitchedReading = false
        while !Self.isBudgetSpent(elapsedMs: Self.elapsedMs(since: stage2Entry), budgetMs: capMs) {
            guard await Self.gateTick(milliseconds: 50, isCurrent: isCurrent) else {
                EngineLog.emit("[DisplayCriteria] gate abandoned while waiting for the end (\(timing())): the load it held was cancelled or superseded", category: .engine)
                return
            }
            let stage2Ms = Self.elapsedMs(since: stage2Entry)
            let relation = panelRelation()
            cadenceHistory = Self.extendCadenceHistory(cadenceHistory, relation: relation, nowMs: stage2Ms)
            let heldMs = cadenceHistory.run?.heldMs(atMs: stage2Ms) ?? 0
            if observation.hasNewEnd(since: gateSnapshot) {
                EngineLog.emit("[DisplayCriteria] switch settled via modeSwitchEnd (\(timing()), \(relation.logDescription))", category: .engine)
                return
            }
            // #449: the panel is measurably running the rate this rate-only write asked for, so the switch
            // the notifications never finish reporting has nothing left to do. Named with the cap it did
            // not spend, because that is the number the fix has to be verified against, and with the dwell
            // where one was required, because a multiple settles on having HELD the reading.
            let attribution = Self.criteriaAttribution(didApply: didApply, lastCriteriaWasHDR: lastCriteriaWasHDR)
            if !reportedSwitchedReading, attribution == .engineRateOnly, let preWrite,
               Self.rateOnlySwitchIsSettled(attribution: attribution, relation: relation, heldForMs: heldMs),
               !Self.rateOnlySwitchIsSettled(attribution: attribution, relation: relation, heldForMs: heldMs,
                                             preWrite: preWrite) {
                reportedSwitchedReading = true
                EngineLog.emit("[DisplayCriteria] #950: \(relation.logDescription) after \(stage2Ms)ms of the wait, but before the write it read \(preWrite.logDescription); the panel switched to it and the sink may still be re-locking, so waiting for the end", category: .engine)
            }
            if Self.rateOnlySwitchIsSettled(
                attribution: attribution,
                relation: relation, heldForMs: heldMs, preWrite: preWrite) {
                let dwell: String = {
                    guard case .multiple = relation else { return "" }
                    return ", held unbroken for \(heldMs)ms"
                }()
                EngineLog.emit("[DisplayCriteria] rate-only criteria already satisfied (\(timing()), \(relation.logDescription)\(dwell); released \(capMs - Self.elapsedMs(since: stage2Entry))ms before the \(capMs)ms cap)", category: .engine)
                return
            }
            // Only meaningful when this load recorded no start: the headroom rises with the transition, so
            // during an observable switch it is the panel warming up, not the panel being done.
            if observeHeadroom(screen), Self.settlePhaseHeadroomSettles(
                startRecorded: gateSnapshot.startedAt != nil || observation.hasNewStart(since: gateSnapshot)) {
                EngineLog.emit("[DisplayCriteria] switch settled via EDR (\(timing()), headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
                return
            }
            if !displayManager.isDisplayModeSwitchInProgress {
                // Headroom is still 1.0 here (the EDR check above runs first each tick).
                switch Self.criteriaAttribution(didApply: didApply, lastCriteriaWasHDR: lastCriteriaWasHDR) {
                case .engineRateOnly:
                    // SDR rate-only criteria: refresh-rate switch settled, panel correctly stayed SDR.
                    EngineLog.emit("[DisplayCriteria] rate-only switch settled (\(timing()), SDR, \(relation.logDescription), EDR headroom 1.0 as expected)", category: .engine)
                case .engineHDR:
                    // Headroom 1.0 after an HDR write is NOT evidence of a refusal. The value is only raised
                    // by a dynamic-range transition, so a panel that was already in HDR reads identically to
                    // one that refused. The proof is the tie-breaker this line used to lack, and without it
                    // it accused a panel that was demonstrably showing HDR at that moment.
                    EngineLog.emit(panelProvenToEngageHDR
                        ? "[DisplayCriteria] switch ended (\(timing())) at EDR headroom 1.0; this panel is proven to engage HDR, so it was already in the target mode and no transition raised the headroom"
                        : "[DisplayCriteria] WARN switch ended (\(timing())) at EDR headroom 1.0 and this panel has never been observed engaging HDR: rate-only matching, or a real dynamic-range handshake failure",
                        category: .engine)
                case .hostDriven:
                    // #274: sole-writer host. The engine wrote nothing, so it has no target range to compare
                    // the SDR end state against; a host SDR rate write ending SDR is correct and used to be
                    // logged as an HDR handshake failure.
                    EngineLog.emit("[DisplayCriteria] host switch ended (\(timing()), EDR headroom 1.0; engine wrote no criteria this session, target range unknown)", category: .engine)
                }
                return
            }
        }
        // Cap reached: the in-progress flag never cleared. "Unobservable DV panel" was the blanket
        // explanation, but it only fits an HDR write; an engine rate-only write sitting here for two
        // seconds contradicts the sub-second premise the .brief budget rests on and is worth reading as
        // its own event (Sodalite#49). Two of the reporter's three second-round runs landed here, both
        // rate-only SDR, so this is the common outcome on that panel rather than an edge case.
        let headroom = String(format: "%.2f", screen.currentEDRHeadroom)
        let capRelation = panelRelation()
        switch Self.criteriaAttribution(didApply: didApply, lastCriteriaWasHDR: lastCriteriaWasHDR) {
        case .engineRateOnly:
            // #449: the cadence is the part that says whether this was a switch in flight or a write the
            // panel had nothing to do about. Reaching here on a `.multiple` means the reading never held
            // for `panelMultipleDwellMs` unbroken, so the panel kept changing what it reported or stopped
            // reporting; a `.different` reading is a panel in neither mode.
            EngineLog.emit("[DisplayCriteria] proceed after cap (\(timing()); engine rate-only criteria, switch never reported end, panel may still be mid-switch; \(capRelation.logDescription); \(cadenceHistory.logDescription); EDR headroom \(headroom))", category: .engine)
        case .engineHDR:
            // "Unobservable DV panel" was the blanket reading here, but a panel that was already in HDR
            // when the criteria were re-written produces the same silence: no transition, so no headroom
            // rise and no end within the cap. The proof separates the two.
            // AE#348: the proof says the panel CAN engage HDR, not that it already has. Once this gate saw
            // the switch start, the panel is mid-switch at the cap, and its end is still to come.
            let startRecorded = gateSnapshot.startedAt != nil || observation.hasNewStart(since: gateSnapshot)
            EngineLog.emit(startRecorded
                ? "[DisplayCriteria] proceed after cap (\(timing()); engine HDR criteria, switch started and not yet ended, panel still mid-switch; EDR headroom \(headroom))"
                : panelProvenToEngageHDR
                ? "[DisplayCriteria] proceed after cap (\(timing()); engine HDR criteria on a panel proven to engage HDR, so most likely already in the target mode; EDR headroom \(headroom))"
                : "[DisplayCriteria] proceed after cap (\(timing()); engine HDR criteria, switch not observable, likely DV; EDR headroom \(headroom))",
                category: .engine)
        case .hostDriven:
            EngineLog.emit("[DisplayCriteria] proceed after cap (\(timing()); engine wrote no criteria this session, switch not observable; EDR headroom \(headroom))", category: .engine)
        }
        #endif
    }

    /// Measure the refresh rate the panel is actually running at, by timing display-link ticks over
    /// `ticks` callbacks (~0.7 s at 60 Hz). tvOS exposes no read-back of the mode a criteria write landed
    /// on (`UIScreen.maximumFramesPerSecond` reports what the screen is capable of, not the active HDMI
    /// mode), so this is the only evidence that separates a panel which ignored the criteria and kept the
    /// system rate from one that took a rate not dividing the content rate (60.000 for 29.970 content).
    /// Returns the measured rate plus the mode's nominal rate from the link's frame duration.
    func measureRefreshRate(ticks: Int = 40) async -> (measured: Double, nominal: Double)? {
        #if os(tvOS)
        guard let window = resolveWindow() else { return nil }
        let sampler = DisplayLinkSampler()
        sampler.start(screen: window.screen)
        for _ in 0..<120 {
            if sampler.tickCount >= ticks { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return sampler.finish()
        #else
        return nil
        #endif
    }

    /// Whether the panel presents this session in HDR, read after apply() + waitForSwitch() settle. A live
    /// headroom above 1.0 answers it; a decayed one is answered by `panelPresentsHDR` from what this display
    /// has already proven, because HDR video on the screen pulls the value down and a replay asks while the
    /// previous session was still doing that.
    func currentPanelIsHDR() -> Bool {
        #if os(tvOS)
        guard let window = resolveWindow() else { return false }
        return Self.panelPresentsHDR(
            headroomAboveOne: observeHeadroom(window.screen),
            attribution: Self.criteriaAttribution(didApply: didApply, lastCriteriaWasHDR: lastCriteriaWasHDR),
            matchingDisabled: !window.avDisplayManager.isDisplayCriteriaMatchingEnabled,
            // A proof from an earlier session is about this display's HDR mode; a display that cannot
            // play HDR now (another TV, HDR switched off) has nothing for it to vouch for.
            panelProvenToEngageHDR: panelProvenToEngageHDR && AVPlayer.eligibleForHDRPlayback
        )
        #else
        return false
        #endif
    }

    /// Re-ask the panel whether it is presenting HDR, now that the session's frames are on screen.
    ///
    /// The load-time read cannot answer for a panel already parked in HDR: it is taken around the criteria
    /// write, and that panel makes no dynamic-range transition to raise the headroom (#459). This one is
    /// taken while HDR content composites, which is when Vincent's device trace shows the value rising, and
    /// it goes through `observeHeadroom` so a hit latches the proof for every later load in the process.
    ///
    /// Returns whether the panel answered HDR. Bounded by `playbackProbeWindowMs`, and a window that closes
    /// with nothing seen is logged as the measurement it is.
    func probePanelDuringPlayback() async -> Bool {
        #if os(tvOS)
        guard let window = resolveWindow() else { return false }
        let started = DispatchTime.now()
        var samples = 0
        var maxHeadroom = 0.0
        var observedHDR = false
        while !Task.isCancelled,
              Self.playbackProbeContinues(elapsedMs: Self.elapsedMs(since: started),
                                          observedHDR: observedHDR) {
            samples += 1
            maxHeadroom = max(maxHeadroom, Double(window.screen.currentEDRHeadroom))
            observedHDR = observeHeadroom(window.screen)
            if !observedHDR {
                try? await Task.sleep(for: .milliseconds(Self.playbackProbeIntervalMs))
            }
        }
        guard !Task.isCancelled else { return false }
        let headroom = String(format: "%.2f", maxHeadroom)
        if observedHDR {
            EngineLog.emit(
                "[DisplayCriteria] playback probe: panel reports HDR after "
                + "\(Self.elapsedMs(since: started))ms (headroom \(headroom), \(samples) samples)",
                category: .engine)
        } else {
            EngineLog.emit(
                "[DisplayCriteria] playback probe: no HDR reading in \(Self.elapsedMs(since: started))ms "
                + "(max headroom \(headroom), \(samples) samples); this panel does not raise the EDR "
                + "headroom for HDR content, so the session keeps its SDR label",
                category: .engine)
        }
        return observedHDR
        #else
        return false
        #endif
    }

    #if os(tvOS)
    /// Single funnel for every headroom read, so one observation of a real HDR engage is remembered after the
    /// value decays. Returns whether the panel reports HDR right now.
    private func observeHeadroom(_ screen: UIScreen) -> Bool {
        guard screen.currentEDRHeadroom > 1.001 else { return false }
        if !panelProvenToEngageHDR {
            EngineLog.emit("[DisplayCriteria] panel proven to engage HDR (headroom \(String(format: "%.2f", screen.currentEDRHeadroom))); later sessions trust an accepted HDR write even after the headroom decays", category: .engine)
            panelProvenToEngageHDR = true
        }
        return true
    }
    #endif

    /// AE#459's other proof: AVFoundation accepted an HDR master, which a display presenting SDR refuses.
    /// It answers the same question the headroom does, so it latches the same proof. Without it a display
    /// whose headroom never moves (an Apple TV 4K 1st generation on tvOS 26.6 read 1.00 throughout HDR and
    /// Dolby Vision playback) proves HDR only on the AVPlayer route, and every later session on a path with
    /// no master to accept (the software host, the Dolby Vision FEL route) kept its SDR label.
    func notePanelEngagedHDR(_ evidence: String) {
        guard !panelProvenToEngageHDR else { return }
        EngineLog.emit("[DisplayCriteria] panel proven to engage HDR (\(evidence)); later sessions trust an accepted HDR write even without a headroom reading", category: .engine)
        panelProvenToEngageHDR = true
    }

    /// AE#588's rule applied to the proof: it describes an output configuration, which the user changes in
    /// Settings (only reachable by leaving the app) or by swapping the TV, so leaving for the background
    /// forgets it (observed process-wide, with or without an engine alive), and so does an HDR master the
    /// display refused. The next HDR session on the AVPlayer route proves it again.
    static func forgetPanelProof(_ reason: String) {
        guard panelProvenToEngageHDRInProcess else { return }
        panelProvenToEngageHDRInProcess = false
        EngineLog.emit("[DisplayCriteria] \(reason) clears the panel's HDR proof; the next session asks the display again",
                       category: .engine)
    }
    /// Nil-out preferredDisplayCriteria to return the panel to default. No-op when apply() was never called this session (suppressed host) to avoid racing AVKit's in-flight criteria management.
    func reset() {
        #if os(tvOS)
        guard didApply else { return }
        guard let window = resolveWindow() else {
            didApply = false
            lastApplied = nil
            return
        }
        logPanelReadout("before reset", window: window)
        window.avDisplayManager.preferredDisplayCriteria = nil
        didApply = false
        lastApplied = nil   // #133: a RESET returns the panel to default; the next apply must re-establish it.
        preWriteRelation = nil
        EngineLog.emit("[DisplayCriteria] RESET", category: .engine)
        #endif
    }

    // MARK: - Window resolution

    #if os(tvOS)
    /// Emit the readout for one phase. Called before the engine writes or clears criteria, because a write
    /// is what makes a later reading unattributable: the whole of #459 is a value read at the one moment it
    /// has nothing to say. Deliberately NOT routed through `observeHeadroom`: a diagnostic that also latches
    /// the HDR proof would change routing, and this round is meant to measure, not to decide.
    private func logPanelReadout(_ phase: String, window: UIWindow) {
        let manager = window.avDisplayManager
        EngineLog.emit(
            Self.panelReadoutLine(
                phase: phase,
                currentEDR: window.screen.currentEDRHeadroom,
                potentialEDR: window.screen.potentialEDRHeadroom,
                switching: manager.isDisplayModeSwitchInProgress,
                matching: manager.isDisplayCriteriaMatchingEnabled,
                hdrEligible: AVPlayer.eligibleForHDRPlayback,
                proven: panelProvenToEngageHDR,
                headroomLimit: Self.headroomLimitLabel(window.traitCollection)),
            category: .engine)
    }

    /// The trait's own three states, spelled out rather than mapped to a Bool: "unspecified" is a real
    /// answer here and folding it into either of the others would invent a claim.
    private static func headroomLimitLabel(_ traits: UITraitCollection) -> String {
        guard #available(tvOS 26.0, *) else { return "n/a" }
        switch traits.hdrHeadroomUsageLimit {
        case .active: return "active"
        case .inactive: return "inactive"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }

    private func resolveWindow() -> UIWindow? {
        if let provider = Self.windowProvider, let win = provider() as? UIWindow {
            return win
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first
    }

    #endif
}

#if os(tvOS)
/// Records `AVDisplayManager` mode-switch notifications from the moment a criteria write is imminent.
///
/// `waitForSwitch` used to register these observers when it opened, which is after the engine's own write and
/// sometimes after the switch that write triggers has already finished. Both notifications then landed
/// outside the window and the gate fell back on `isDisplayModeSwitchInProgress`, a flag its own call site
/// documents as unreliable right after a write. Sodalite#49's device logs are that defect twice over: two
/// runs spent the entire Stage 2 cap waiting for an end that had happened, and a third labelled a switch it
/// had watched begin as one that predated it (#339).
///
/// Notifications arrive on an arbitrary queue, so every field is lock-guarded. The counters exist to keep
/// "recorded before I looked" apart from "arrived while I waited": an end belonging to an older switch must
/// never settle a gate that is waiting on a newer one.
private final class SwitchObservation: @unchecked Sendable {
    struct Snapshot {
        let startedAt: UInt64?
        let endedAt: UInt64?
        let startCount: Int
        let endCount: Int
        /// Bumped by every arm, 0 until the first one. Lets a gate tell a record written for this load from
        /// one left by the previous load, which must not settle anything.
        let generation: Int
    }

    private let lock = NSLock()
    private var startedAt: UInt64?
    private var endedAt: UInt64?
    private var startCount = 0
    private var endCount = 0
    private var generation = 0
    private var tokens: [NSObjectProtocol] = []

    /// Clear the record and, on first use, register. Called immediately before a criteria write so
    /// everything the following gate reads belongs to that write.
    ///
    /// `object: nil` is the load-bearing part. tvOS posts both notifications from an
    /// **`AVSharedDisplayManager`**, not from the `AVDisplayManager` that `window.avDisplayManager` returns
    /// and that `preferredDisplayCriteria` is written to. Filtering on that manager, which is what this code
    /// did from the start, dropped every notification the settle gate exists to read. Device probe, Apple TV
    /// 4K (3rd gen), tvOS 26.5, 2026-08-09, listening on all objects:
    ///
    ///     FIRED AVDisplayManagerModeSwitchStartNotification object=AVSharedDisplayManager@0x10b581a10
    ///     our manager=AVDisplayManager@0x1036fdfa0
    ///
    /// Six start/end pairs arrived that way in three playbacks while the engine's filtered observers saw
    /// none. That, not the registration point, is why no run in Sodalite#49 ever reported an end.
    func arm() {
        lock.lock()
        startedAt = nil
        endedAt = nil
        startCount = 0
        endCount = 0
        generation += 1
        let needsRegistration = tokens.isEmpty
        lock.unlock()

        guard needsRegistration else { return }
        // Weak, or the token retains the block retains this object for the process lifetime.
        let start = NotificationCenter.default.addObserver(
            forName: .AVDisplayManagerModeSwitchStart, object: nil, queue: nil
        ) { [weak self] _ in self?.record(isStart: true) }
        let end = NotificationCenter.default.addObserver(
            forName: .AVDisplayManagerModeSwitchEnd, object: nil, queue: nil
        ) { [weak self] _ in self?.record(isStart: false) }
        lock.lock()
        tokens = [start, end]
        lock.unlock()
    }

    /// First start since arming (so a switch is measured from its beginning), latest end.
    private func record(isStart: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if isStart {
            startedAt = startedAt ?? now
            startCount += 1
        } else {
            endedAt = now
            endCount += 1
        }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(startedAt: startedAt, endedAt: endedAt,
                        startCount: startCount, endCount: endCount, generation: generation)
    }

    func hasNewStart(since snapshot: Snapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startCount > snapshot.startCount
    }

    func hasNewEnd(since snapshot: Snapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return endCount > snapshot.endCount
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

/// Times display-link ticks so the caller can read the active HDMI mode's refresh rate. Enough ticks
/// separate 59.940 from 60.000 (a 0.1% miss against 29.970 content is a repeated frame every ~16 s).
@MainActor
private final class DisplayLinkSampler: NSObject {
    private var link: CADisplayLink?
    private var firstTimestamp: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var nominalDuration: CFTimeInterval = 0
    private var lastTickNanos: UInt64 = 0
    private(set) var tickCount = 0

    func start(screen: UIScreen) {
        let link = screen.displayLink(withTarget: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        nominalDuration = link.targetTimestamp - link.timestamp
        if tickCount == 0 { firstTimestamp = link.timestamp }
        lastTimestamp = link.timestamp
        lastTickNanos = DispatchTime.now().uptimeNanoseconds
        tickCount += 1
    }

    /// The rate of the mode the panel is running *now*, or nil when no tick has landed within
    /// `freshWithinMs` (#449).
    ///
    /// Taken from a single tick's `targetTimestamp - timestamp` rather than averaged over a window, because
    /// a window spanning a mode switch reports neither of the two rates it straddles. Staleness is not a
    /// measurement failure here, it is the reading: a panel that is not putting frames on screen is what a
    /// blanked HDMI re-sync looks like from inside the app, and the gate is supposed to keep waiting for it.
    func nominalRateNow(freshWithinMs: Int) -> Double? {
        guard tickCount > 0, nominalDuration > 0 else { return nil }
        let age = DisplayCriteriaController.elapsedMs(
            fromNanos: lastTickNanos, toNanos: DispatchTime.now().uptimeNanoseconds)
        guard age <= freshWithinMs else { return nil }
        return 1.0 / nominalDuration
    }

    func invalidate() {
        link?.invalidate()
        link = nil
    }

    func finish() -> (measured: Double, nominal: Double)? {
        invalidate()
        guard tickCount >= 2, lastTimestamp > firstTimestamp else { return nil }
        return (
            measured: Double(tickCount - 1) / (lastTimestamp - firstTimestamp),
            nominal: nominalDuration > 0 ? 1.0 / nominalDuration : 0
        )
    }
}
#endif
