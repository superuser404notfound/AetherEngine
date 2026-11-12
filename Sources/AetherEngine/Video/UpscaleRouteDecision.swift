import CoreGraphics
import Foundation
import AetherLibavutil

/// Coded picture size plus sample aspect ratio, the geometry the upscale decision works from.
struct SourceGeometry: Equatable {
    var width: Int
    var height: Int
    var sarNum: Int
    var sarDen: Int

    /// A SAR of 0/0 or 0/x counts as 1:1.
    var effectiveSAR: (num: Int, den: Int) {
        sarNum > 0 && sarDen > 0 ? (sarNum, sarDen) : (1, 1)
    }
}

/// What the upscale stage does for one source: a first pass (the ML pass, coded size times `mlScale`, or the
/// line-art 2x), then the rest of the way to the target, which is the display aspect fitted into the display
/// box: MetalFX after an ML pass (or alone), a bilinear resample after the line-art pass.
struct UpscalePlan: Hashable, Sendable {
    var sourceWidth: Int
    var sourceHeight: Int
    /// nil = MetalFX only.
    var mlScale: Float?
    /// The first pass's output: the ML output, twice the source for `.lineArt`, else the source size.
    var mlOutputWidth: Int
    var mlOutputHeight: Int
    var targetWidth: Int
    var targetHeight: Int
    var displayWidth: Int
    var displayHeight: Int
    var scaler: UpscaleScaler = .automatic

    var needsMetalFX: Bool {
        scaler == .automatic && (mlOutputWidth != targetWidth || mlOutputHeight != targetHeight)
    }
}

/// Whether a load takes the low-resolution upscale route, and if not, why. Pure so every exit is
/// unit-testable; the load asks it once and logs `logLine`.
enum UpscaleRouteDecision: Equatable {

    case taken(UpscalePlan)
    case notTaken(Reason)

    /// Every reason the route is not taken, in the order the checks run.
    enum Reason: Equatable {
        case preferenceOff
        case unsupportedOS
        case metalFXUnsupported
        case hdrOrDolbyVision
        case notEightBit420
        /// `.lineArt` only: neither 8 nor 10-bit 4:2:0.
        case notFourTwoZero
        case geometryUnknown
        case notBelow1080p
        /// `.lineArt` only: wider than 1920 or taller than 1080.
        case largerThan1080p
        case displayNotLarger
        case wirelessAirPlayRoute
        case demuxedAudioLive
        case stageFailedEarlier
    }

    static func decide(
        preference: Bool, osSupportsStage: Bool, metalFXSupported: Bool,
        source: SourceGeometry, isSDR: Bool, isDolbyVision: Bool, isEightBit420: Bool,
        display: CGSize, wirelessAirPlayRoute: Bool, demuxedAudioLive: Bool,
        mlScaleFactors: (Int, Int) -> [Float],
        scaler: UpscaleScaler = .automatic, isTenBit420: Bool = false,
        stageFailedEarlier: (UpscalePlan) -> Bool = { _ in false }
    ) -> UpscaleRouteDecision {
        guard preference else { return .notTaken(.preferenceOff) }
        guard osSupportsStage else { return .notTaken(.unsupportedOS) }
        guard isSDR, !isDolbyVision else { return .notTaken(.hdrOrDolbyVision) }
        switch scaler {
        case .automatic: guard isEightBit420 else { return .notTaken(.notEightBit420) }
        case .lineArt: guard isEightBit420 || isTenBit420 else { return .notTaken(.notFourTwoZero) }
        }
        guard source.width > 0, source.height > 0 else { return .notTaken(.geometryUnknown) }
        guard sizeAllowed(width: source.width, height: source.height, scaler: scaler) else {
            return .notTaken(scaler == .lineArt ? .largerThan1080p : .notBelow1080p)
        }
        guard let plan = makePlan(source: source, display: display, mlScaleFactors: mlScaleFactors, scaler: scaler),
              plan.targetWidth > source.width || plan.targetHeight > source.height
        else { return .notTaken(.displayNotLarger) }
        // Without MetalFX an automatic plan needs its ML pass, which then runs alone (the display scales the
        // rest). The line-art stage is plain Metal compute.
        if scaler == .automatic, !metalFXSupported, plan.needsMetalFX, plan.mlScale == nil {
            return .notTaken(.metalFXUnsupported)
        }
        // Any wireless AirPlay route, not only a receiver that shows video: the stage moves a session the
        // native path would play onto the software path, and there the sound goes to the speakers alone.
        guard !wirelessAirPlayRoute else { return .notTaken(.wirelessAirPlayRoute) }
        guard !demuxedAudioLive else { return .notTaken(.demuxedAudioLive) }
        guard !stageFailedEarlier(plan) else { return .notTaken(.stageFailedEarlier) }
        return .taken(plan)
    }

    /// What a line-art plan falls back to when it overruns (AE#1039): the automatic plan for the same
    /// source and display, only below 1080p and only with a VT super-resolution pass (MetalFX alone costs
    /// about what line art does). The pixel aspect comes from the plan's own target.
    static func lineArtFallback(for plan: UpscalePlan, mlScaleFactors: (Int, Int) -> [Float]) -> UpscalePlan? {
        guard plan.scaler == .lineArt,
              sizeAllowed(width: plan.sourceWidth, height: plan.sourceHeight, scaler: .automatic) else { return nil }
        var num = plan.targetWidth * plan.sourceHeight, den = plan.targetHeight * plan.sourceWidth
        guard num > 0, den > 0 else { return nil }
        var a = num, b = den
        while b != 0 { (a, b) = (b, a % b) }
        num /= a; den /= a
        guard let fallback = makePlan(
                source: SourceGeometry(width: plan.sourceWidth, height: plan.sourceHeight, sarNum: num, sarDen: den),
                display: CGSize(width: plan.displayWidth, height: plan.displayHeight),
                mlScaleFactors: mlScaleFactors, scaler: .automatic),
              fallback.mlScale != nil else { return nil }
        return fallback
    }

    /// Below 1080p for `.automatic` (1080p scales well enough without it, and VT super resolution does not
    /// take it); up to and including 1080p for `.lineArt`, whose 2x then fills a UHD display.
    static func sizeAllowed(width: Int, height: Int, scaler: UpscaleScaler) -> Bool {
        switch scaler {
        case .automatic: return width < 1920 && height < 1080
        case .lineArt: return width <= 1920 && height <= 1080
        }
    }

    /// The plan for `source` on `display`, or nil when either size is not positive. Also used to rebuild
    /// the plan when the decoded size changes mid-stream.
    static func makePlan(
        source: SourceGeometry, display: CGSize, mlScaleFactors: (Int, Int) -> [Float],
        scaler: UpscaleScaler = .automatic
    ) -> UpscalePlan? {
        let displayW = Int(display.width.rounded(.down))
        let displayH = Int(display.height.rounded(.down))
        guard source.width > 0, source.height > 0, displayW > 0, displayH > 0 else { return nil }

        let sar = source.effectiveSAR
        let aspect = Double(source.width * sar.num) / Double(source.height * sar.den)
        var targetW = displayW
        var targetH = Int((Double(displayW) / aspect).rounded(.down))
        if targetH > displayH {
            targetH = displayH
            targetW = Int((Double(displayH) * aspect).rounded(.down))
        }
        targetW = even(min(targetW, displayW))
        targetH = even(min(targetH, displayH))
        guard targetW > 0, targetH > 0 else { return nil }

        if scaler == .lineArt {
            return UpscalePlan(
                sourceWidth: source.width, sourceHeight: source.height, mlScale: nil,
                mlOutputWidth: source.width * 2, mlOutputHeight: source.height * 2,
                targetWidth: targetW, targetHeight: targetH, displayWidth: displayW, displayHeight: displayH,
                scaler: .lineArt)
        }

        var mlScale: Float?
        var mlW = source.width
        var mlH = source.height
        for factor in mlScaleFactors(source.width, source.height).sorted(by: >) where factor > 1 {
            let w = even(Int((Float(source.width) * factor).rounded(.down)))
            let h = even(Int((Float(source.height) * factor).rounded(.down)))
            if w <= targetW, h <= targetH {
                mlScale = factor
                mlW = w
                mlH = h
                break
            }
        }
        return UpscalePlan(
            sourceWidth: source.width, sourceHeight: source.height, mlScale: mlScale,
            mlOutputWidth: mlW, mlOutputHeight: mlH, targetWidth: targetW, targetHeight: targetH,
            displayWidth: displayW, displayHeight: displayH)
    }

    private static func even(_ value: Int) -> Int { value & ~1 }

    /// Only PQ and HLG count as HDR here; an unspecified or unknown transfer is treated as SDR.
    static func isSDR(colorTransfer: AVColorTransferCharacteristic) -> Bool {
        colorTransfer != AVCOL_TRC_SMPTE2084 && colorTransfer != AVCOL_TRC_ARIB_STD_B67
    }

    /// 10-bit 4:2:0 decoder output, which only the line-art stage takes. Same rules as `isEightBit420`.
    static func isTenBit420(pixelFormat: Int32, bitsPerRawSample: Int32) -> Bool {
        let format = AVPixelFormat(rawValue: pixelFormat)
        guard format != AV_PIX_FMT_NONE, let desc = av_pix_fmt_desc_get(format) else {
            return bitsPerRawSample == 10
        }
        let d = desc.pointee
        let excluded = UInt64(AV_PIX_FMT_FLAG_RGB) | UInt64(AV_PIX_FMT_FLAG_HWACCEL) | UInt64(AV_PIX_FMT_FLAG_PAL)
        return d.nb_components >= 3 && d.comp.0.depth == 10 && d.log2_chroma_w == 1 && d.log2_chroma_h == 1
            && d.flags & excluded == 0
    }

    /// The stage takes 8-bit 4:2:0 decoder output only. A known pixel format decides; without one the raw
    /// sample depth does, and an unknown depth counts as not 8-bit.
    static func isEightBit420(pixelFormat: Int32, bitsPerRawSample: Int32) -> Bool {
        let format = AVPixelFormat(rawValue: pixelFormat)
        guard format != AV_PIX_FMT_NONE, let desc = av_pix_fmt_desc_get(format) else {
            return (1...8).contains(bitsPerRawSample)
        }
        let d = desc.pointee
        let excluded = UInt64(AV_PIX_FMT_FLAG_RGB) | UInt64(AV_PIX_FMT_FLAG_HWACCEL) | UInt64(AV_PIX_FMT_FLAG_PAL)
        return d.nb_components >= 3 && d.comp.0.depth == 8 && d.log2_chroma_w == 1 && d.log2_chroma_h == 1
            && d.flags & excluded == 0
    }

    /// What an in-session rebuild hands the next software host, and the status it republishes before that
    /// host's first frame. The option turned off builds no stage and publishes nothing; a stage that
    /// disabled itself stays off for the session and keeps its disabled status.
    static func forRebuild(
        sessionPlan: UpscalePlan?, optionOn: Bool, disabled: UpscaleStatus?
    ) -> (plan: UpscalePlan?, status: UpscaleStatus?) {
        guard optionOn, let sessionPlan else { return (nil, nil) }
        if let disabled { return (nil, disabled) }
        return (sessionPlan, nil)
    }

    var plan: UpscalePlan? {
        if case let .taken(plan) = self { return plan }
        return nil
    }

    /// The one diagnostic line for a load, or nil when the preference is off.
    var logLine: String? {
        switch self {
        case .notTaken(.preferenceOff):
            return nil
        case let .taken(plan) where plan.scaler == .lineArt:
            let rest = plan.mlOutputWidth == plan.targetWidth && plan.mlOutputHeight == plan.targetHeight
                ? "" : ", then bilinear"
            return "[Upscale] taken: \(plan.sourceWidth)x\(plan.sourceHeight) -> \(plan.targetWidth)x\(plan.targetHeight) "
                + "(line art 2x to \(plan.mlOutputWidth)x\(plan.mlOutputHeight)\(rest))"
        case let .taken(plan):
            let ml = plan.mlScale.map {
                "ML \(String(format: "%g", $0))x to \(plan.mlOutputWidth)x\(plan.mlOutputHeight)"
            }
            let stages = [ml, plan.needsMetalFX ? "MetalFX" : nil].compactMap { $0 }.joined(separator: ", then ")
            return "[Upscale] taken: \(plan.sourceWidth)x\(plan.sourceHeight) -> "
                + "\(plan.targetWidth)x\(plan.targetHeight) (\(stages))"
        case let .notTaken(reason):
            return "[Upscale] not taken (\(reason.text))"
        }
    }
}

extension UpscaleRouteDecision.Reason {
    var text: String {
        switch self {
        case .preferenceOff: return "upscalesLowResolutionVideo is off"
        case .unsupportedOS: return "needs OS 26"
        case .metalFXUnsupported: return "MetalFX spatial scaling unsupported on this device"
        case .hdrOrDolbyVision: return "HDR or Dolby Vision source"
        case .notEightBit420: return "source is not 8-bit 4:2:0"
        case .notFourTwoZero: return "source is not 8 or 10-bit 4:2:0"
        case .geometryUnknown: return "source size unknown"
        case .notBelow1080p: return "source is not below 1080p"
        case .largerThan1080p: return "source is larger than 1920x1080"
        case .displayNotLarger: return "display is not larger than the source"
        case .wirelessAirPlayRoute: return "a wireless AirPlay receiver holds the audio route"
        case .demuxedAudioLive: return "live stream with demuxed audio"
        case .stageFailedEarlier: return "the stage disabled itself for this plan earlier in this process"
        }
    }
}

/// The plans whose stage disabled itself, remembered for the process so a reload or a later title with the
/// same geometry stays on the route it would have taken without the stage. Keyed with the frame rate, like
/// `MetalFXCostMemory`: a stage that gave up at one rate blocks the same plan at that rate or faster, not
/// a slower title it might have kept up with. An unknown rate on either side counts as a match.
enum UpscaleFailureMemory {
    private struct Entry: Hashable {
        let plan: UpscalePlan
        let frameRate: Double?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var failed: Set<Entry> = []

    static func record(_ plan: UpscalePlan, frameRate: Double?) {
        lock.lock(); failed.insert(Entry(plan: plan, frameRate: frameRate)); lock.unlock()
    }

    /// 1% slack, so 23.976 counts as at least as fast as 24.
    static func contains(_ plan: UpscalePlan, frameRate: Double?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return failed.contains { entry in
            guard entry.plan == plan else { return false }
            guard let failedAt = entry.frameRate, let frameRate else { return true }
            return frameRate >= failedAt * 0.99
        }
    }

    static func reset() {
        lock.lock(); failed.removeAll(); lock.unlock()
    }
}

// MARK: - Process-wide line-art cost

/// Here and not beside `FrameUpscaler` because the load reads it on every platform, the simulator included,
/// where the stage itself is not built.
/// Line-art overruns seen in this process, per rung: a later source at least as large, at a frame interval
/// no longer, would overrun again. A restore overrun starts later stages without the restore pass, an
/// upscale overrun makes the load decide for the automatic scaler instead (AE#1039).
enum LineArtCostMemory {
    enum Rung: Sendable { case restore, upscale }

    struct Overrun: Equatable, Sendable {
        var width: Int, height: Int
        var frameInterval: Double
        var meanMs: Double
        var pixels: Int { width * height }

        /// 1% slack, so 24 fps counts as at least as fast as 23.976.
        func covers(pixels other: Int, frameInterval interval: Double) -> Bool {
            other >= pixels && interval <= frameInterval * 1.01
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var overruns: [Rung: [Overrun]] = [:]

    static func record(_ overrun: Overrun, rung: Rung) {
        lock.lock(); defer { lock.unlock() }
        var list = overruns[rung] ?? []
        guard !list.contains(where: { $0.pixels <= overrun.pixels && $0.frameInterval >= overrun.frameInterval })
        else { return }
        list.removeAll { $0.pixels >= overrun.pixels && $0.frameInterval <= overrun.frameInterval }
        list.append(overrun)
        overruns[rung] = list
    }

    /// The overrun of `rung` covering a line-art plan for this source at `frameInterval` (unknown counts as
    /// covered by any rate, like `UpscaleFailureMemory`).
    static func overrun(covering plan: UpscalePlan, frameInterval: Double?, rung: Rung) -> Overrun? {
        lock.lock(); defer { lock.unlock() }
        let pixels = plan.sourceWidth * plan.sourceHeight
        return (overruns[rung] ?? []).first { o in
            guard let frameInterval else { return pixels >= o.pixels }
            return o.covers(pixels: pixels, frameInterval: frameInterval)
        }
    }

    static func reset() {
        lock.lock(); overruns.removeAll(); lock.unlock()
    }
}
