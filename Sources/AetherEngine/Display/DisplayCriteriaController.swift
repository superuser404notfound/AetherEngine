import Foundation
import CoreMedia
import CoreVideo
import AVFoundation

#if canImport(UIKit)
import UIKit
#endif

#if os(tvOS)
import AVKit
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

    init() {}

    /// Program AVDisplayCriteria before the session starts. `.sdr` programs a rate-only criteria so Match Frame Rate still engages. `codecTag` nil derives from format (`'dvh1'` for DV, `'hvc1'` otherwise). `omitColorExtensions` skips BT.2020 extensions for diagnostic builds. Returns true when a dynamic-range switch is expected (caller should call waitForSwitch).
    @discardableResult
    func apply(format: VideoFormat, frameRate: Double?, codecTag: FourCharCode?, omitColorExtensions: Bool) -> Bool {
        #if os(tvOS)
        // Reset up front so a skipped apply (Match Content off, no window)
        // can't leave a prior HDR session's flag for waitForSwitch to read.
        lastCriteriaWasHDR = false
        guard #available(tvOS 17.0, *) else {
            EngineLog.emit("[DisplayCriteria] skipped: tvOS < 17", category: .engine)
            return false
        }

        guard let window = resolveWindow() else {
            EngineLog.emit("[DisplayCriteria] skipped: no window", category: .engine)
            return false
        }

        let displayManager = window.avDisplayManager

        // isDisplayCriteriaMatchingEnabled covers both Match Dynamic Range and Match Frame Rate; tvOS picks the applicable dimension internally.
        guard displayManager.isDisplayCriteriaMatchingEnabled else {
            EngineLog.emit("[DisplayCriteria] skipped: Match Content disabled (both Dynamic Range AND Frame Rate off)", category: .engine)
            return false
        }

        // HDR sources attach BT.2020 + transfer + matrix extensions; SDR carries only codec + rate so Match Frame Rate can engage without Match Dynamic Range (DrHurt #4: previously early-returned for SDR and Match Frame Rate never fired).
        let isHDR = (format != .sdr)
        let transferFunction: CFString = switch format {
        case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default:   kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        }
        let extensions: NSDictionary? = (isHDR && !omitColorExtensions) ? [
            kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: transferFunction,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
        ] : nil

        // Codec FourCC drives the HDMI mode: 'hvc1' -> HDR10/HLG, 'dvh1' -> Dolby Vision. Using HEVC for a DV source kept DrHurt's Philips panel in HDR10 instead of DV (P8 MKV). ref: Jellyfin #16179, KSPlayer #633.
        let dvh1: FourCharCode = 0x64766831
        let codecType: CMVideoCodecType = codecTag ?? (format == .dolbyVision ? dvh1 : kCMVideoCodecType_HEVC)

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: 3840, height: 2160,
            extensions: extensions,
            formatDescriptionOut: &formatDesc
        )
        guard let desc = formatDesc else { return false }

        // Always pass the real rate; tvOS uses it when Match Frame Rate is on, ignores it otherwise (dynamic-range switch still fires).
        let effectiveRate = Float(frameRate ?? 24.0)
        let criteria = AVDisplayCriteria(refreshRate: effectiveRate, formatDescription: desc)
        displayManager.preferredDisplayCriteria = criteria
        didApply = true
        lastCriteriaWasHDR = isHDR

        EngineLog.emit(
            "[DisplayCriteria] SET: format=\(format) codec=\(fourccString(codecType)) "
            + "rate=\(frameRate.map { String(format: "%.3f", $0) } ?? "default(24)") "
            + "extensions=\(extensions != nil ? "HDR" : "none")",
            category: .engine
        )
        // SDR rate-only switches are sub-second; only HDR criteria need the waitForSwitch delay.
        return isHDR
        #else
        return false
        #endif
    }

    /// Block until the panel settles its HDR mode negotiation, bounded so an
    /// unobservable switch can't stall the first frame.
    ///
    /// The caller only invokes this when an HDR/DV mode switch is actually expected
    /// (it gates on `apply()`'s isHDR return), so SDR / rate-only loads and non-HDR
    /// panels never enter here.
    ///
    /// `preferredDisplayCriteria` is a *hint*: when Match Content is enabled the TV
    /// performs the switch over HDMI and reports progress via the AVDisplayManager
    /// mode-switch notifications. We proceed the instant the OS signals the switch
    /// is done (`AVDisplayManagerModeSwitchEndNotification`) or EDR headroom rises.
    /// Otherwise we bound the wait, because on some panels a Dolby Vision switch is
    /// effectively unobservable to the app — `currentEDRHeadroom` stays 1.0 and
    /// `isDisplayModeSwitchInProgress` can stick `true` even though the panel
    /// visibly enters DV. A blind fixed poll made every such load wait the full
    /// timeout. Presenting slightly early on that fallback is at worst cosmetic:
    /// the panel is mid re-sync (black) during the handshake and shows the correct
    /// frame once it locks — the decode/color-correctness guard is Stage 1 below.
    func waitForSwitch() async {
        #if os(tvOS)
        guard let window = resolveWindow() else { return }
        let displayManager = window.avDisplayManager
        let screen = window.screen

        // Fast exit: panel already in HDR (headroom already raised, e.g. a prior
        // HDR/DV session left it there).
        if screen.currentEDRHeadroom > 1.001 {
            EngineLog.emit("[DisplayCriteria] no switch needed (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)) at entry)", category: .engine)
            return
        }

        // Observe the OS mode-switch notifications. Start marks the HDMI handshake
        // beginning — more reliable than polling `isDisplayModeSwitchInProgress`,
        // which can read false for a beat right after the criteria write. End is
        // the authoritative "settled" signal. Referenced by raw name to avoid Swift
        // import-form ambiguity across SDKs.
        let switchStarted = SwitchFlag()
        let switchEnded = SwitchFlag()
        let startToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("AVDisplayManagerModeSwitchStartNotification"),
            object: displayManager, queue: nil
        ) { _ in switchStarted.fire() }
        let endToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("AVDisplayManagerModeSwitchEndNotification"),
            object: displayManager, queue: nil
        ) { _ in switchEnded.fire() }
        defer {
            NotificationCenter.default.removeObserver(startToken)
            NotificationCenter.default.removeObserver(endToken)
        }

        // Stage 1: up to 1000ms for the switch to actually start. The handshake
        // initiates asynchronously after the criteria write (and AVKit's sole-writer
        // path fires it later than the engine pre-flight), so give it headroom
        // before the DV asset loads — starting the decode mid-write races an
        // AVPlayer error on DV Profile 8.1.
        var sawSwitchStart = false
        for _ in 0..<100 {
            if switchEnded.fired || screen.currentEDRHeadroom > 1.001 {
                EngineLog.emit("[DisplayCriteria] settled during start phase (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
                return
            }
            if switchStarted.fired || displayManager.isDisplayModeSwitchInProgress {
                sawSwitchStart = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !sawSwitchStart {
            // No switch started within 1000ms: panel already satisfies the criteria
            // or the setter was a no-op. Don't block; AVPlayer tonemaps or errors for real.
            EngineLog.emit("[DisplayCriteria] no switch started (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)) after 1000ms); proceeding", category: .engine)
            return
        }

        // Stage 2: proceed as soon as ANY reliable signal says settled — the
        // mode-switch-end notification, EDR headroom rising (HDR10/HLG), or the
        // in-progress flag clearing — else a bounded ~2s cap so a panel whose DV
        // switch is unobservable to the app can't gate the first frame the way the
        // old fixed 5s poll did.
        let capTicks = 40  // 40 × 50ms = 2000ms
        for tick in 0..<capTicks {
            try? await Task.sleep(for: .milliseconds(50))
            let elapsed = (tick + 1) * 50 + 1000
            if switchEnded.fired {
                EngineLog.emit("[DisplayCriteria] switch settled via modeSwitchEnd (~\(elapsed)ms)", category: .engine)
                return
            }
            if screen.currentEDRHeadroom > 1.001 {
                EngineLog.emit("[DisplayCriteria] switch settled via EDR (~\(elapsed)ms, headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
                return
            }
            if !displayManager.isDisplayModeSwitchInProgress {
                EngineLog.emit("[DisplayCriteria] switch in-progress cleared (~\(elapsed)ms, EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
                return
            }
        }
        EngineLog.emit("[DisplayCriteria] proceed after ~\(capTicks * 50 + 1000)ms cap (switch not observable — likely DV; EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
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
            return
        }
        window.avDisplayManager.preferredDisplayCriteria = nil
        didApply = false
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
#endif
