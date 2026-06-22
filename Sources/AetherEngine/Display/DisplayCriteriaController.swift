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

    /// Block until the panel finishes its HDR mode negotiation, or up to ~5s.
    ///
    /// Two-stage poll: (1) start phase 1000ms/10ms ticks -- the HDMI handshake initiates asynchronously after the preferredDisplayCriteria write, so isDisplayModeSwitchInProgress can be false for a beat (old single-check guard let asset.load race on DV8.1 -> AVPlayer -11848). AVKit-sole-writer path also fires later, so 1000ms gives headroom. Early-return if EDR headroom is already > 1.001 (panel already in HDR). (2) settle phase 50 x 100ms; sanity-checks headroom after the switch clears.
    func waitForSwitch() async {
        #if os(tvOS)
        guard let window = resolveWindow() else { return }
        let displayManager = window.avDisplayManager
        let screen = window.screen

        // Stage 1: wait up to 1000ms for the handshake to start (AVKit-sole-writer path fires later than engine pre-flight).
        var sawSwitchStart = false
        for _ in 0..<100 {
            if displayManager.isDisplayModeSwitchInProgress {
                sawSwitchStart = true
                break
            }
            if screen.currentEDRHeadroom > 1.001 {
                // Panel already in HDR mode; no switch needed.
                EngineLog.emit("[DisplayCriteria] no switch needed (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)) at entry)", category: .engine)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        if !sawSwitchStart {
            // 1000ms elapsed with no switch: panel can't satisfy criteria or setter was a no-op. Don't block playback; AVPlayer will tonemap or fail with a real error.
            EngineLog.emit("[DisplayCriteria] WARN handshake never started (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)) after 1000ms); proceeding", category: .engine)
            return
        }

        // Stage 2: wait for the handshake to complete. 50 × 100ms = 5s.
        for tick in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if !displayManager.isDisplayModeSwitchInProgress {
                let totalMs = (tick + 1) * 100 + 1000  // include stage 1 budget
                if screen.currentEDRHeadroom > 1.001 {
                    EngineLog.emit("[DisplayCriteria] switch settled after ~\(totalMs)ms (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
                } else if didApply && !lastCriteriaWasHDR {
                    // SDR rate-only criteria: refresh-rate switch settled, panel correctly stayed SDR.
                    EngineLog.emit("[DisplayCriteria] rate-only switch settled after ~\(totalMs)ms (SDR, EDR headroom 1.0 as expected)", category: .engine)
                } else {
                    // HDR was requested but panel ended in SDR: real dynamic-range handshake failure.
                    EngineLog.emit("[DisplayCriteria] WARN switch ended after ~\(totalMs)ms but EDR headroom still 1.0 (panel stayed SDR despite HDR criteria)", category: .engine)
                }
                return
            }
        }
        EngineLog.emit("[DisplayCriteria] WARN switch did not settle within 5s; proceeding anyway (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
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
