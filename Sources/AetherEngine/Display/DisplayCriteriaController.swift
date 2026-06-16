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

/// HDMI HDR-mode handshake controller. tvOS exposes a public
/// AVDisplayManager API (tvOS 11.2+) that lets the app program the
/// preferred display mode (codec, dynamic range, refresh rate) before
/// playback starts, so the panel finishes its mode negotiation before
/// the first frame is decoded.
///
/// On iOS and macOS this controller is a no-op stub: there's no HDMI
/// handshake to drive (the device's own panel is the display surface).
///
/// Lifted from Sodalite's `PlayerViewModel.applyDisplayCriteria` so
/// the engine owns the handshake end-to-end. Hosts no longer touch
/// `UIWindow.avDisplayManager` directly.
@MainActor
final class DisplayCriteriaController {

    /// Optional override for window discovery. The default
    /// implementation walks `UIApplication.shared.connectedScenes` and
    /// picks the first window. Hosts with unusual scene setups (eg.
    /// multi-window iPadOS, custom presentation contexts) can override
    /// this with their own resolver in one place.
    nonisolated(unsafe) static var windowProvider: (@MainActor () -> Any?)?

    /// Tracks whether this controller actually wrote
    /// `preferredDisplayCriteria` during the most recent session.
    /// `reset()` is gated on this so AVKit-sole-writer hosts (those
    /// passing `LoadOptions.suppressDisplayCriteria = true`) get
    /// zero engine writes against `avDisplayManager` — neither
    /// apply nor reset. Otherwise a stop / reload cycle's `nil` write
    /// races AVKit's in-flight criteria negotiation and shows up as
    /// a spurious panel-mode regression mid-session (DrHurt#4 Build
    /// 176: multiple "[DisplayCriteria] RESET" lines during the
    /// succeeding retry attempt, EDR headroom collapsing from the
    /// panel's locked DV value to 1.0).
    private var didApply: Bool = false

    /// Whether the most recent `apply()` attached HDR color extensions
    /// (i.e. asked the panel for an actual dynamic-range switch). Read by
    /// `waitForSwitch` to classify the settle outcome: a panel that ends
    /// at EDR headroom 1.0 is a FAILURE only when HDR was requested; for
    /// an SDR rate-only criteria (Match Frame Rate engaging on a 50/60 fps
    /// stream) headroom 1.0 is the correct, expected result and must not
    /// log an HDR-failure warning. Defaults to false (no HDR asked).
    private var lastCriteriaWasHDR: Bool = false

    init() {}

    /// Apply display criteria for the next playback session.
    ///
    /// - Parameters:
    ///   - format: The detected video dynamic range. `.sdr` programs
    ///     a rate-only criteria so Match Frame Rate can still engage
    ///     (panel keeps SDR mode but switches refresh).
    ///   - frameRate: Real content frame rate, snapped via
    ///     `FrameRateSnap`. Pass `nil` to skip refresh-rate matching
    ///     (the panel keeps its current rate).
    ///   - codecTag: 4CC override for the format description. Pass
    ///     `nil` to derive from format (`'dvh1'` for Dolby Vision,
    ///     `'hvc1'` otherwise). Phase 2 may pass `'vp09'` / `'av01'`.
    ///   - omitColorExtensions: When `true`, build the format
    ///     description without BT.2020 + transfer + matrix extensions
    ///     so AVPlayer falls back to reading the actual bitstream's
    ///     color metadata at session start. Engine-internal toggle for
    ///     diagnostic builds.
    /// - Returns: `true` if the display will switch to HDR mode.
    ///     `false` means no dynamic-range switch happened — either
    ///     SDR content (no switch needed; rate-only criteria may
    ///     still have been programmed), Match Content disabled, no
    ///     window, or tvOS < 17.
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

        // Respect the user's Match Content master toggle. tvOS
        // exposes one combined `isDisplayCriteriaMatchingEnabled`
        // flag that is true when EITHER "Match Dynamic Range" OR
        // "Match Frame Rate" is enabled in Settings → Video and
        // Audio → Match Content. tvOS internally decides which
        // dimension to honour based on the user's per-sub-toggle
        // setting; we just have to hand it a criteria with both
        // dimensions populated and let the system pick.
        guard displayManager.isDisplayCriteriaMatchingEnabled else {
            EngineLog.emit("[DisplayCriteria] skipped: Match Content disabled (both Dynamic Range AND Frame Rate off)", category: .engine)
            return false
        }

        // BT.2020 / transfer / YCbCr matrix extensions encode the
        // dynamic-range claim. We only attach them for HDR / DV /
        // HLG sources — for SDR sources the criteria carries the
        // codec FourCC + refresh rate only, so when the user has
        // Match Frame Rate ON but Match Dynamic Range OFF, the
        // panel still switches to the content's native refresh
        // rate (DrHurt #4 observation: previously Match Frame Rate
        // only engaged when Match Dynamic Range was also active,
        // because we early-returned for SDR and never programmed
        // criteria at all).
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

        // Codec FourCC encoded in the format description is what
        // tvOS reads to pick the HDMI display mode: `'hvc1'` →
        // HDR10/HDR10+/HLG; `'dvh1'` → Dolby Vision. Building a
        // criteria with kCMVideoCodecType_HEVC for a DV source makes
        // the TV negotiate plain HDR10 even though the bitstream
        // carries a DV RPU, which is DrHurt's observed Philips DV TV
        // symptom: P8 MKV played end-to-end but the panel stayed in
        // HDR mode instead of Dolby Vision. For DV sources the
        // codecType is the dvh1 FourCC (0x64766831); for everything
        // else, HEVC. Color primaries / TF / matrix stay the same;
        // DV's base is still BT.2020 + ST 2084 PQ.
        // ref: Jellyfin issue #16179, KSPlayer issue #633.
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

        // AVDisplayManager exposes one combined toggle
        // (`isDisplayCriteriaMatchingEnabled`) that gates the entire
        // handshake. Apple TV's Settings split it into Match Dynamic
        // Range and Match Frame Rate but tvOS doesn't surface the
        // frame-rate sub-toggle to apps; the system internally
        // decides whether to honour the rate field based on the
        // user's setting. Passing the real rate here is correct in
        // both cases: when Match Frame Rate is on, tvOS uses it;
        // when off, tvOS ignores it and keeps the panel's current
        // rate (dynamic-range switch still happens).
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
        // Return true only when an actual dynamic-range switch is on
        // the table — the caller uses this to decide whether to wait
        // up to 5 s for the panel handshake to settle. SDR rate-only
        // criteria don't need the wait (refresh-rate switches are
        // sub-second on every panel we care about).
        return isHDR
        #else
        return false
        #endif
    }

    /// Block until the panel finishes its mode negotiation (or settles
    /// at the target dynamic range), or up to ~5 seconds.
    ///
    /// Two-stage poll so we don't race the setter's async handshake:
    ///
    ///   1. Start phase (up to 1000ms, 10ms ticks). `displayManager.
    ///      preferredDisplayCriteria = criteria` in `apply()` returns
    ///      immediately, but the HDMI handshake initiates asynchronously
    ///      a moment later, which means `isDisplayModeSwitchInProgress`
    ///      can still be `false` for a beat after we wrote the criteria.
    ///      The previous implementation's `guard
    ///      isDisplayModeSwitchInProgress else { return }` mis-classified
    ///      that beat as "no switch needed" and let `asset.load` proceed
    ///      while the panel was still in its old mode. On DV8.1 + HDR10
    ///      panel + match-content this surfaced as AVPlayer -11848
    ///      "Cannot Open" because the master playlist's `VIDEO-RANGE=PQ`
    ///      hit AVPlayer before the panel transitioned out of SDR.
    ///
    ///      When AVKit's auto-criteria path is the sole writer (engine
    ///      pre-flight suppressed via LoadOptions), the write fires
    ///      later and more variably than a synchronous engine pre-flight.
    ///      We give the handshake up to 1000ms to start. If
    ///      `currentEDRHeadroom > 1.001` already, the panel was already
    ///      in HDR mode for the target format and no switch is needed
    ///      (e.g., user replays an HDR title that left the panel in HDR
    ///      mode from the previous session). Return early in that case.
    ///
    ///   2. Settle phase (up to 5s, 100ms ticks). Same as before:
    ///      wait for `isDisplayModeSwitchInProgress` to clear. After
    ///      it clears, sanity-check `currentEDRHeadroom`; if the panel
    ///      ended back in SDR (handshake failed silently), emit a
    ///      warning so the diagnostic overlay can show the regression.
    func waitForSwitch() async {
        #if os(tvOS)
        guard let window = resolveWindow() else { return }
        let displayManager = window.avDisplayManager
        let screen = window.screen

        // Stage 1: wait for the handshake to start. Cap 1000ms so
        // when AVKit's auto-criteria path drives the write (instead
        // of the engine's pre-flight) we don't bail before AVKit has
        // had time to parse the manifest + fMP4 sample entry and
        // produce its own preferredDisplayCriteria write. Auto-path
        // timing is later and more variable than the engine pre-flight
        // (which writes synchronously); 1000ms gives AVKit comfortable
        // headroom while still failing fast on panels that genuinely
        // don't engage HDR (criteria silently rejected).
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
            // 1000ms (100 x 10ms) elapsed and the handshake never started. Either
            // the panel can't satisfy the criteria (non-HDR display,
            // unsupported codec) or the setter was a no-op (criteria
            // already matched). Don't block playback further; AVPlayer
            // will either tonemap or fail with a real error.
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
                    // We explicitly programmed an SDR rate-only criteria (Match
                    // Frame Rate): a refresh-rate switch settled and the panel
                    // correctly stayed SDR. EDR headroom 1.0 is the expected
                    // result, not a failure.
                    EngineLog.emit("[DisplayCriteria] rate-only switch settled after ~\(totalMs)ms (SDR, EDR headroom 1.0 as expected)", category: .engine)
                } else {
                    // HDR was requested (or AVKit drives criteria on a
                    // suppressed host and we can't prove it asked for SDR) yet
                    // the panel ended back in SDR: a real dynamic-range
                    // handshake failure worth flagging.
                    EngineLog.emit("[DisplayCriteria] WARN switch ended after ~\(totalMs)ms but EDR headroom still 1.0 (panel stayed SDR despite HDR criteria)", category: .engine)
                }
                return
            }
        }
        EngineLog.emit("[DisplayCriteria] WARN switch did not settle within 5s; proceeding anyway (EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))", category: .engine)
        #endif
    }

    /// Snapshot the panel's current dynamic-range mode after the
    /// criteria handshake has settled. Reads `UIScreen.currentEDRHeadroom`
    /// (> 1.0 means HDR mode is active, accepting extended-range pixels).
    ///
    /// Called by the engine after `apply` + `waitForSwitch` so the
    /// rest of the load path can use the panel's *actual* mode instead
    /// of the host's pre-load snapshot. This matters because tvOS
    /// exposes only one combined `isDisplayCriteriaMatchingEnabled`
    /// toggle — there's no API to tell whether Match Dynamic Range
    /// specifically is on or only Match Frame Rate. A user with rate
    /// matching on and range matching off shows up as
    /// `isDisplayCriteriaMatchingEnabled == true`, but the panel stays
    /// SDR when we ask for HDR. Reading the headroom after the
    /// handshake settles is the only authoritative way to know which
    /// of the two sub-toggles is active.
    func currentPanelIsHDR() -> Bool {
        #if os(tvOS)
        guard let window = resolveWindow() else { return false }
        return window.screen.currentEDRHeadroom > 1.001
        #else
        return false
        #endif
    }

    /// Clear the preferred display criteria so the panel returns to
    /// its default mode after playback. Idempotent. No-op when the
    /// controller never wrote criteria during the current session
    /// (eg. AVKit-sole-writer hosts that pass `LoadOptions.
    /// suppressDisplayCriteria = true`); writing `nil` in that case
    /// races AVKit's own in-flight criteria management and shows up
    /// as a mid-session panel-mode regression.
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
