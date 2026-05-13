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

    init() {}

    /// Apply display criteria for the next playback session.
    ///
    /// - Parameters:
    ///   - format: The detected video dynamic range. `.sdr` returns
    ///     `false` immediately (no handshake needed).
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
    ///     `false` means the caller should tone-map HDR content down
    ///     to SDR (Match Content disabled, no window, SDR content).
    @discardableResult
    func apply(format: VideoFormat, frameRate: Double?, codecTag: FourCharCode?, omitColorExtensions: Bool) -> Bool {
        #if os(tvOS)
        guard #available(tvOS 17.0, *) else {
            EngineLog.emit("[DisplayCriteria] skipped: tvOS < 17", category: .engine)
            return false
        }
        guard format != .sdr else { return false }

        guard let window = resolveWindow() else {
            EngineLog.emit("[DisplayCriteria] skipped: no window", category: .engine)
            return false
        }

        let displayManager = window.avDisplayManager

        // Respect user's "Match Content → Match Dynamic Range" toggle
        // (Apple TV → Settings → Video and Audio). When OFF, the
        // system refuses to switch the panel; a preferredDisplayCriteria
        // assignment would silently no-op and we'd ship HDR pixel data
        // into an SDR-locked panel, which renders as black or massively
        // over-saturated. The tone-map path is the safe fallback.
        guard displayManager.isDisplayCriteriaMatchingEnabled else {
            EngineLog.emit("[DisplayCriteria] skipped: Match Dynamic Range disabled, falling back to tonemap", category: .engine)
            return false
        }

        let transferFunction: CFString = switch format {
        case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default:   kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        }

        // BT.2020 / transfer / YCbCr matrix in the format description
        // gives tvOS an explicit hint for the pre-playback handshake.
        // The `omitColorExtensions` flag drops them so AVPlayer falls
        // back to reading the actual bitstream's color metadata at
        // session start instead. Off by default; engine-internal
        // diagnostic lever.
        let extensions: NSDictionary? = omitColorExtensions ? nil : [
            kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: transferFunction,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
        ]

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

        EngineLog.emit("[DisplayCriteria] SET: format=\(format) codec=\(fourccString(codecType)) rate=\(frameRate.map { String(format: "%.3f", $0) } ?? "default(24)")", category: .engine)
        return true
        #else
        return false
        #endif
    }

    /// Block until the panel finishes its mode negotiation, or up to
    /// 5 seconds. Polls every 100ms. Emits an `EngineLog` warning if
    /// the cap fires (mode switch never completed in the budget).
    func waitForSwitch() async {
        #if os(tvOS)
        guard let window = resolveWindow() else { return }
        let displayManager = window.avDisplayManager
        guard displayManager.isDisplayModeSwitchInProgress else { return }

        // 50 × 100ms = 5s
        for tick in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if !displayManager.isDisplayModeSwitchInProgress {
                EngineLog.emit("[DisplayCriteria] switch settled after ~\((tick + 1) * 100)ms", category: .engine)
                return
            }
        }
        EngineLog.emit("[DisplayCriteria] WARN switch did not settle within 5s; proceeding anyway", category: .engine)
        #endif
    }

    /// Clear the preferred display criteria so the panel returns to
    /// its default mode after playback. Always safe to call; idempotent.
    func reset() {
        #if os(tvOS)
        guard let window = resolveWindow() else { return }
        window.avDisplayManager.preferredDisplayCriteria = nil
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

    private func fourccString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        let chars = bytes.map { (b: UInt8) -> Character in
            (b >= 0x20 && b < 0x7f) ? Character(UnicodeScalar(b)) : "."
        }
        return String(chars)
    }
    #endif
}
