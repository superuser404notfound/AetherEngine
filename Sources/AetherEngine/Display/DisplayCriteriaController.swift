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
    nonisolated static func applyOutcome(didApply: Bool, last: AppliedCriteria?, target: AppliedCriteria) -> ApplyResult {
        if didApply, last == target { return .unchanged }
        return target.isHDR ? .willSwitch : .applied
    }

    /// How long `waitForSwitch` blind-polls for a switch to *start* before giving up (Stage 1). The wait is
    /// blind by construction: nothing reports "a criteria write is inbound", so the budget is a bet on the
    /// writer's latency and every millisecond of it is startup time when the bet is wrong (#274).
    enum StartGrace: Equatable {
        /// Nothing can be pending; return before touching the display manager.
        case skip
        /// 200 ms: only a rate-only switch could still start (the pre-#274 budget, sized for a synchronous
        /// engine write). The engine already declines to pre-flight its own rate-only writes on the premise
        /// that they are sub-second, which is an assumption from d87b54d that no log has ever measured: the
        /// settle times it would have been read off were inflated by the whole Stage 1 budget (Sodalite#49).
        /// `timingSuffix` now reports the real number, so this budget can be confirmed or corrected.
        case brief
        /// 1000 ms: a dynamic-range switch may still be inbound from a writer whose timing we don't control
        /// (AVKit's auto-criteria path fires from the AVPlayerItem formatDescription). DV P5 cold start
        /// depends on this budget.
        case full

        var ticks: Int {
            switch self {
            case .skip:  0
            case .brief: 20
            case .full:  100
            }
        }
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

    nonisolated static func criteriaAttribution(didApply: Bool, lastCriteriaWasHDR: Bool) -> CriteriaAttribution {
        guard didApply else { return .hostDriven }
        return lastCriteriaWasHDR ? .engineHDR : .engineRateOnly
    }

    /// How Stage 1 learned a switch was running. This is the one bit that separates "the panel was already
    /// switching while the AVPlayerItem was built" from "the switch started after the gate opened", the
    /// ordering question Sodalite#49 was filed on and which no log line could answer. The observers are
    /// registered on entry, so a switch that began earlier is only visible through the in-progress flag;
    /// a start notification means it began inside the gate.
    enum StartSignal: String, Equatable {
        /// In-progress flag already set when polling began: the switch started before the gate, i.e. during
        /// the load that built the item.
        case preGate = "pre-gate"
        /// Mode-switch-start notification arrived while the gate was polling.
        case inGate = "in-gate"
        /// Nothing observed within the budget.
        case none = "none"
    }

    /// The two numbers a settle log needs to be usable: when Stage 1 saw the switch start, and how long the
    /// whole gate took. Both used to be reported as `startGrace.ticks * 10 + stage2Ticks * 50`, which counts
    /// the Stage 1 *budget* rather than the time actually spent in it, so every settle in every log read up
    /// to a full second slower than it was and no measurement of real switch latency was possible (#49).
    nonisolated static func timingSuffix(startSignal: StartSignal, stage1Ms: Int, totalMs: Int) -> String {
        "start \(startSignal.rawValue) after \(stage1Ms)ms, total \(totalMs)ms"
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

    init() {}

    /// Program AVDisplayCriteria before the session starts. `.sdr` programs a rate-only criteria so Match Frame Rate still engages. `codecTag` nil derives from format (`'dvh1'` for DV, `'hvc1'` otherwise). `omitColorExtensions` skips BT.2020 extensions for diagnostic builds. Returns `.willSwitch` when a dynamic-range switch is expected (caller should call waitForSwitch), `.applied` for an SDR rate-only write, or `.unchanged` when the criteria are already active and nothing was written (#133).
    @discardableResult
    func apply(format: VideoFormat, frameRate: Double?, codecTag: FourCharCode?, omitColorExtensions: Bool) -> ApplyResult {
        #if os(tvOS)
        // Reset up front so a skipped apply (Match Content off, no window)
        // can't leave a prior HDR session's flag for waitForSwitch to read.
        lastCriteriaWasHDR = false
        guard #available(tvOS 17.0, *) else {
            EngineLog.emit("[DisplayCriteria] skipped: tvOS < 17", category: .engine)
            return .applied
        }

        guard let window = resolveWindow() else {
            EngineLog.emit("[DisplayCriteria] skipped: no window", category: .engine)
            return .applied
        }

        let displayManager = window.avDisplayManager

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
        if case .unchanged = Self.applyOutcome(didApply: didApply, last: lastApplied, target: target) {
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
        displayManager.preferredDisplayCriteria = criteria
        didApply = true
        lastCriteriaWasHDR = isHDR
        lastApplied = target

        EngineLog.emit(
            "[DisplayCriteria] SET: format=\(format) codec=\(fourccString(codecType)) "
            + "rate=\(frameRate.map { String(format: "%.3f", $0) } ?? "default(24)") "
            + "extensions=\(extensions != nil ? "HDR" : "none")",
            category: .engine
        )
        // SDR rate-only switches are sub-second; only HDR criteria need the waitForSwitch delay.
        return isHDR ? .willSwitch : .applied
        #else
        return .applied
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
    func waitForSwitch(startGrace: StartGrace = .full) async {
        #if os(tvOS)
        guard startGrace != .skip else { return }
        guard let window = resolveWindow() else { return }
        let displayManager = window.avDisplayManager
        let screen = window.screen
        let entry = DispatchTime.now()

        // Fast exit: panel already in HDR (headroom already raised, e.g. a prior
        // HDR/DV session left it there).
        if screen.currentEDRHeadroom > 1.001 {
            EngineLog.emit("[DisplayCriteria] no switch needed (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)) at entry)", category: .engine)
            return
        }

        // Observe the OS mode-switch notifications. Start marks the HDMI handshake
        // beginning, more reliable than polling `isDisplayModeSwitchInProgress`,
        // which can read false for a beat right after the criteria write. End is
        // the authoritative "settled" signal.
        let switchStarted = SwitchFlag()
        let switchEnded = SwitchFlag()
        let startToken = NotificationCenter.default.addObserver(
            forName: .AVDisplayManagerModeSwitchStart,
            object: displayManager, queue: nil
        ) { _ in switchStarted.fire() }
        let endToken = NotificationCenter.default.addObserver(
            forName: .AVDisplayManagerModeSwitchEnd,
            object: displayManager, queue: nil
        ) { _ in switchEnded.fire() }
        defer {
            NotificationCenter.default.removeObserver(startToken)
            NotificationCenter.default.removeObserver(endToken)
        }

        // Stage 1: `startGrace` for the switch to actually start. The handshake
        // initiates asynchronously after the criteria write (and AVKit's sole-writer
        // path fires it later than the engine pre-flight), so give it headroom
        // before the DV asset loads; starting the decode mid-write races an
        // AVPlayer error on DV Profile 8.1.
        //
        // Which of the two signals ends this stage is recorded, not just that one did: the in-progress flag
        // being set on the first poll means the panel was already switching while the item was built, which
        // is the ordering Sodalite#49 suspected and which nothing in the log used to distinguish from a
        // switch that started inside the gate.
        var startSignal = StartSignal.none
        for _ in 0..<startGrace.ticks {
            if switchEnded.fired || screen.currentEDRHeadroom > 1.001 {
                EngineLog.emit("[DisplayCriteria] settled during start phase (after \(Self.elapsedMs(since: entry))ms, EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
                return
            }
            if switchStarted.fired { startSignal = .inGate; break }
            if displayManager.isDisplayModeSwitchInProgress { startSignal = .preGate; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Time spent, not the budget: the polls carry scheduler overhead, and everything downstream is
        // reported relative to this (#49).
        let stage1Ms = Self.elapsedMs(since: entry)
        let startBudgetMs = startGrace.ticks * 10
        if startSignal == .none {
            // No switch started within the grace: panel already satisfies the criteria
            // or the setter was a no-op. Don't block; AVPlayer tonemaps or errors for real.
            EngineLog.emit("[DisplayCriteria] no switch started (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)) after \(stage1Ms)ms, budget \(startBudgetMs)ms); proceeding", category: .engine)
            return
        }

        // Stage 2: proceed as soon as ANY reliable signal says settled (the
        // mode-switch-end notification, EDR headroom rising for HDR10/HLG, or the
        // in-progress flag clearing), else a bounded ~2s cap so a panel whose DV
        // switch is unobservable to the app can't gate the first frame the way the
        // old fixed 5s poll did.
        let capTicks = 40  // 40 x 50ms = 2000ms
        func timing() -> String {
            Self.timingSuffix(startSignal: startSignal, stage1Ms: stage1Ms,
                              totalMs: Self.elapsedMs(since: entry))
        }
        for _ in 0..<capTicks {
            try? await Task.sleep(for: .milliseconds(50))
            if switchEnded.fired {
                EngineLog.emit("[DisplayCriteria] switch settled via modeSwitchEnd (\(timing()))", category: .engine)
                return
            }
            if screen.currentEDRHeadroom > 1.001 {
                EngineLog.emit("[DisplayCriteria] switch settled via EDR (\(timing()), headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
                return
            }
            if !displayManager.isDisplayModeSwitchInProgress {
                // Headroom is still 1.0 here (the EDR check above runs first each tick).
                switch Self.criteriaAttribution(didApply: didApply, lastCriteriaWasHDR: lastCriteriaWasHDR) {
                case .engineRateOnly:
                    // SDR rate-only criteria: refresh-rate switch settled, panel correctly stayed SDR.
                    EngineLog.emit("[DisplayCriteria] rate-only switch settled (\(timing()), SDR, EDR headroom 1.0 as expected)", category: .engine)
                case .engineHDR:
                    // HDR was requested but panel ended in SDR: real dynamic-range handshake failure.
                    EngineLog.emit("[DisplayCriteria] WARN switch ended (\(timing())) but EDR headroom still 1.0 (panel stayed SDR despite HDR criteria)", category: .engine)
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
        // its own event (Sodalite#49).
        let headroom = String(format: "%.2f", screen.currentEDRHeadroom)
        switch Self.criteriaAttribution(didApply: didApply, lastCriteriaWasHDR: lastCriteriaWasHDR) {
        case .engineRateOnly:
            EngineLog.emit("[DisplayCriteria] proceed after cap (\(timing()); engine rate-only criteria, switch never reported end, panel may still be mid-switch; EDR headroom \(headroom))", category: .engine)
        case .engineHDR:
            EngineLog.emit("[DisplayCriteria] proceed after cap (\(timing()); engine HDR criteria, switch not observable, likely DV; EDR headroom \(headroom))", category: .engine)
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

    /// True when UIScreen.currentEDRHeadroom > 1.001 after apply() + waitForSwitch() settle. Reading headroom post-settle is the only authoritative way to distinguish Match Dynamic Range ON vs. rate-only (no public per-sub-toggle API).
    func currentPanelIsHDR() -> Bool {
        #if os(tvOS)
        guard let window = resolveWindow() else { return false }
        return window.screen.currentEDRHeadroom > 1.001
        #else
        return false
        #endif
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
        window.avDisplayManager.preferredDisplayCriteria = nil
        didApply = false
        lastApplied = nil   // #133: a RESET returns the panel to default; the next apply must re-establish it.
        EngineLog.emit("[DisplayCriteria] RESET", category: .engine)
        #endif
    }

    // MARK: - Window resolution

    #if os(tvOS)
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
/// Minimal thread-safe one-shot flag set from an `AVDisplayManager` mode-switch
/// notification (delivered on an arbitrary queue) and polled from the settle loop.
private final class SwitchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func fire() { lock.lock(); value = true; lock.unlock() }
}

/// Times display-link ticks so the caller can read the active HDMI mode's refresh rate. Enough ticks
/// separate 59.940 from 60.000 (a 0.1% miss against 29.970 content is a repeated frame every ~16 s).
@MainActor
private final class DisplayLinkSampler: NSObject {
    private var link: CADisplayLink?
    private var firstTimestamp: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var nominalDuration: CFTimeInterval = 0
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
        tickCount += 1
    }

    func finish() -> (measured: Double, nominal: Double)? {
        link?.invalidate()
        link = nil
        guard tickCount >= 2, lastTimestamp > firstTimestamp else { return nil }
        return (
            measured: Double(tickCount - 1) / (lastTimestamp - firstTimestamp),
            nominal: nominalDuration > 0 ? 1.0 / nominalDuration : 0
        )
    }
}
#endif
