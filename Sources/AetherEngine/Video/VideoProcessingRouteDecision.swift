import Foundation

/// What the picture processing does for one source (#957): the tone curve from the source's declared
/// peak to the target, and the values it was built from.
struct VideoProcessingPlan: Equatable, Sendable {
    var width: Int
    var height: Int
    /// The source's declared HDR10 metadata, the stand-in for a frame that carries none.
    var source: HDR10StaticMetadata
    var sourcePeak: ToneMapSourcePeak
    var curve: BT2390ToneCurve
}

/// Whether a load takes the picture processing route (#957), and if not, why. Pure so every exit is
/// unit-testable; the load asks it once and logs `logLine`.
enum VideoProcessingRouteDecision: Equatable {

    case taken(VideoProcessingPlan)
    case notTaken(Reason)

    /// Every reason the route is not taken, in the order the checks run.
    enum Reason: Equatable {
        case preferenceOff
        case unsupportedOS
        case dolbyVision
        case notHDR10
        case hdr10Plus
        case displayNotHDR10
        case noStaticMetadata
        case peakAtOrBelowTarget(sourcePeakNits: Double, targetPeakNits: Double)
        /// The target is below a third of the source peak on the PQ scale, where BT.2390's knee would be
        /// negative (`BT2390ToneCurve`).
        case targetTooLow(sourcePeakNits: Double, targetPeakNits: Double)
        case notFourTwoZero
        case geometryUnknown
        case wirelessAirPlayRoute
        case demuxedAudioLive
        case stageFailedEarlier
    }

    static func decide(
        options: VideoProcessingOptions?, osSupportsStage: Bool, isPQ: Bool, isDolbyVision: Bool,
        carriesHDR10Plus: Bool, displayTakesHDR10: Bool, declared: HDR10StaticMetadata?,
        width: Int, height: Int, isFourTwoZero: Bool, wirelessAirPlayRoute: Bool, demuxedAudioLive: Bool,
        stageFailedEarlier: (VideoProcessingPlan) -> Bool = { _ in false }
    ) -> VideoProcessingRouteDecision {
        guard let options else { return .notTaken(.preferenceOff) }
        guard osSupportsStage else { return .notTaken(.unsupportedOS) }
        // Dolby Vision first: a Profile 8.1 source is PQ too, and Apple's Dolby Vision is the better picture.
        guard !isDolbyVision else { return .notTaken(.dolbyVision) }
        guard isPQ else { return .notTaken(.notHDR10) }
        guard !carriesHDR10Plus else { return .notTaken(.hdr10Plus) }
        guard displayTakesHDR10 else { return .notTaken(.displayNotHDR10) }
        guard let declared,
              let peak = ToneMapSourcePeak.choose(masteringPeakNits: declared.masteringPeakNits,
                                                  maxCLL: declared.maxCLL)
        else { return .notTaken(.noStaticMetadata) }
        let target = options.targetPeakNits
        guard peak.nits > target else {
            return .notTaken(.peakAtOrBelowTarget(sourcePeakNits: peak.nits, targetPeakNits: target))
        }
        guard let curve = BT2390ToneCurve(sourcePeakNits: peak.nits, targetPeakNits: target) else {
            return .notTaken(.targetTooLow(sourcePeakNits: peak.nits, targetPeakNits: target))
        }
        guard isFourTwoZero else { return .notTaken(.notFourTwoZero) }
        guard width > 0, height > 0 else { return .notTaken(.geometryUnknown) }
        // Any wireless AirPlay route, as for the upscaler: the software path sends the receiver the sound alone.
        guard !wirelessAirPlayRoute else { return .notTaken(.wirelessAirPlayRoute) }
        guard !demuxedAudioLive else { return .notTaken(.demuxedAudioLive) }
        let plan = VideoProcessingPlan(width: width, height: height, source: declared, sourcePeak: peak.from,
                                       curve: curve)
        guard !stageFailedEarlier(plan) else { return .notTaken(.stageFailedEarlier) }
        return .taken(plan)
    }

    /// What an in-session rebuild hands the next software host, and the status it republishes before that
    /// host's first frame. The option turned off builds no stage and publishes nothing; processing that
    /// disabled itself stays off for the session and keeps its disabled status.
    static func forRebuild(
        sessionPlan: VideoProcessingPlan?, optionOn: Bool, disabled: VideoProcessingStatus?
    ) -> (plan: VideoProcessingPlan?, status: VideoProcessingStatus?) {
        guard optionOn, let sessionPlan else { return (nil, nil) }
        if let disabled { return (nil, disabled) }
        return (sessionPlan, nil)
    }

    var plan: VideoProcessingPlan? {
        if case let .taken(plan) = self { return plan }
        return nil
    }

    /// The one diagnostic line for a load, or nil when the option is off.
    var logLine: String? {
        switch self {
        case .notTaken(.preferenceOff):
            return nil
        case let .taken(plan):
            let curve = plan.curve
            return String(format: "[VideoProcessing] taken: %dx%d, tone map %g nit (%@) to %g nit, knee at %.0f nit",
                          plan.width, plan.height, curve.sourcePeakNits, plan.sourcePeak.rawValue,
                          curve.targetPeakNits, curve.kneeNits)
        case let .notTaken(reason):
            return "[VideoProcessing] not taken (\(reason.text))"
        }
    }
}

extension VideoProcessingRouteDecision.Reason {
    var text: String {
        switch self {
        case .preferenceOff: return "videoProcessing is off"
        case .unsupportedOS: return "needs OS 26"
        case .dolbyVision: return "Dolby Vision source"
        case .notHDR10: return "source is not HDR10 (PQ)"
        case .hdr10Plus: return "HDR10+ source"
        case .displayNotHDR10: return "the display does not take HDR10"
        case .noStaticMetadata: return "the source declares no mastering display and no MaxCLL"
        case let .peakAtOrBelowTarget(source, target):
            return String(format: "source peak %g nit is at or below the %g nit target", source, target)
        case let .targetTooLow(source, target):
            return String(format: "the %g nit target is below a third of the %g nit source peak in PQ", target, source)
        case .notFourTwoZero: return "source is not 8 or 10-bit 4:2:0"
        case .geometryUnknown: return "source size unknown"
        case .wirelessAirPlayRoute: return "a wireless AirPlay receiver holds the audio route"
        case .demuxedAudioLive: return "live stream with demuxed audio"
        case .stageFailedEarlier: return "the processing disabled itself for this title earlier in this process"
        }
    }
}

/// The plans whose processing disabled itself, remembered for the process so the reload that returns the
/// session to the native path, or a later load of the same title, stays there. Keyed with the frame rate
/// for an overrun (a slower title may keep up) and without one for HDR10+, which no rate changes. An
/// unknown rate on either side counts as a match.
enum VideoProcessingFailureMemory {
    private struct Entry: Equatable {
        let plan: VideoProcessingPlan
        let frameRate: Double?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var failed: [Entry] = []

    static func record(_ plan: VideoProcessingPlan, frameRate: Double?) {
        lock.lock(); defer { lock.unlock() }
        let entry = Entry(plan: plan, frameRate: frameRate)
        if !failed.contains(entry) { failed.append(entry) }
    }

    /// 1% slack, so 23.976 counts as at least as fast as 24.
    static func contains(_ plan: VideoProcessingPlan, frameRate: Double?) -> Bool {
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
