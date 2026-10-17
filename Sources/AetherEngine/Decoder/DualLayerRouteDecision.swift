import AetherLibavcodec

/// Whether a Profile 7 load takes the dual-layer route (`SoftwarePlaybackHost` + `DualLayerVideoDecoder`)
/// or keeps the native route (single-layer 8.1 where the display takes Dolby Vision), and if not, why. Pure so every exit is unit-testable; the load asks it
/// once per P7 source and logs `logLine`, so the diagnostic and the routing cannot disagree.
///
/// The route is FEL only and capability gated: MEL, an unclassifiable enhancement layer, a box without a
/// hardware HEVC decoder, and a stream the box could not decode twice in real time all fall back to the
/// native route, which is the 8.1 conversion where the display takes Dolby Vision and the HDR10 base
/// layer where it does not. (The conversion loses nothing for MEL; for FEL it drops the residual.)
enum DualLayerRouteDecision: Equatable {

    case taken(elType: String, geometry: Geometry, budgetFraction: Double)
    case notTaken(Reason)

    /// Every reason the route is not taken, in the order the checks run.
    enum Reason: Equatable {
        /// Not HEVC Dolby Vision Profile 7: nothing to decide, and nothing is logged.
        case notProfile7
        case preferenceOff
        /// The package was built without the `DualLayerDolbyVision` trait, so there is no composer.
        case notBuiltIn
        case baseLayerOnlyHandling
        case liveOrNotSeekable
        case noHardwareHEVC
        case melEnhancementLayer
        case enhancementLayerTypeUnknown
        /// The base layer's width or height is not positive (the probe found none): the budget cannot be
        /// computed, and a zero requirement must not read as "fits".
        case geometryUnknown
        case overBudget(requiredPixelsPerSecond: Double, geometry: Geometry)
    }

    /// Base-layer picture geometry the budget is computed from. `frameRate` is nil when the container
    /// declares none; the budget then assumes `assumedFrameRate`.
    struct Geometry: Equatable {
        var width: Int
        var height: Int
        var frameRate: Double?

        var effectiveFrameRate: Double {
            guard let frameRate, frameRate.isFinite, frameRate > 0 else { return DualLayerRouteDecision.assumedFrameRate }
            return frameRate
        }

        var text: String {
            let rate = frameRate.map { rateText($0) } ?? "\(rateText(DualLayerRouteDecision.assumedFrameRate)) (assumed)"
            return "\(width)x\(height)@\(rate)"
        }

        private func rateText(_ value: Double) -> String {
            value.rounded() == value ? String(Int(value)) : String(format: "%.3f", value)
        }
    }

    /// Whether the composer is compiled in (the `DualLayerDolbyVision` package trait, off by default).
    static let isBuiltIn = AetherEngine.OptionalComponent.dualLayerDolbyVision.isBuiltIn

    /// The most pixels per second, base layer plus enhancement layer, the route is willing to decode in
    /// real time: UHD 3840x2160 at 30 fps (248.8 Mpx/s) plus a 1920x1080 enhancement layer at 30 fps
    /// (62.2 Mpx/s), 311.04 Mpx/s in all. The anchor is a 24p UHD FEL master, the shape UHD Blu-ray
    /// remuxes have in practice (248.8 Mpx/s with its enhancement layer, 80% of this). Measured: the Mac
    /// soak runs of this stack, and the composer's GPU time on an Apple TV 4K 2nd generation in earlier
    /// development builds (12.9-14.3 ms per 23.976 fps frame, docs/dolby-vision-fel.md §4.2). The budget
    /// itself, and 30 fps as a ceiling above 24p, are an assumption until the Apple TV run of this
    /// stack. Anything heavier (UHD at 60 fps, 8K) keeps the native route instead of
    /// risking dropped frames.
    static let maximumPixelsPerSecond: Double =
        (3840.0 * 2160.0 + 1920.0 * 1080.0) * 30.0

    /// Frame rate the budget assumes when the container declares none. 24, because FEL masters are 24p.
    static let assumedFrameRate: Double = 24

    /// The enhancement layer's share of the base layer's area when the stream's own enhancement-layer
    /// dimensions are not known: a quarter, which is what a 4K FEL disc ships (1080p over UHD).
    static let assumedEnhancementLayerAreaFraction: Double = 0.25

    /// Pixels per second both layers need: the base layer's, plus the enhancement layer's, taken from
    /// `enhancementLayerSize` when the stream states it and as a quarter of the base layer's area otherwise.
    /// The load passes no `enhancementLayerSize`: it budgets a quarter-area enhancement layer (every retail
    /// FEL title's layout), and a 1:1 enhancement layer is not detected at load.
    static func requiredPixelsPerSecond(
        geometry: Geometry, enhancementLayerSize: (width: Int, height: Int)? = nil
    ) -> Double {
        let base = Double(geometry.width) * Double(geometry.height)
        let enhancement = enhancementLayerSize.map { Double($0.width) * Double($0.height) }
            ?? base * assumedEnhancementLayerAreaFraction
        return (base + enhancement) * geometry.effectiveFrameRate
    }

    /// The reason the route cannot be taken whatever the enhancement layer is, or nil when only the
    /// `el_type` (and the budget) remain to decide. The load runs this first so the `el_type` probe, a
    /// packet scan and a seek, only happens when its answer can change the route. A nil
    /// `canHardwareDecode` assumes hardware decode.
    static func blockingReasonBeforeProbe(
        codecID: AVCodecID,
        dvProfile: Int?,
        dolbyVisionHandling: DolbyVisionHandling,
        preferDualLayerDolbyVision: Bool,
        isLive: Bool,
        isSourceSeekable: Bool,
        canHardwareDecode: (() -> Bool)?
    ) -> Reason? {
        guard codecID == AV_CODEC_ID_HEVC, dvProfile == 7 else { return .notProfile7 }
        guard preferDualLayerDolbyVision else { return .preferenceOff }
        guard isBuiltIn else { return .notBuiltIn }
        guard dolbyVisionHandling == .automatic else { return .baseLayerOnlyHandling }
        guard !isLive, isSourceSeekable else { return .liveOrNotSeekable }
        guard canHardwareDecode?() ?? true else { return .noHardwareHEVC }
        return nil
    }

    /// The full decision. `elType` is the probe's answer ("FEL", "MEL", or nil when it found none).
    static func decide(
        codecID: AVCodecID,
        dvProfile: Int?,
        dolbyVisionHandling: DolbyVisionHandling,
        preferDualLayerDolbyVision: Bool,
        isLive: Bool,
        isSourceSeekable: Bool,
        canHardwareDecode: (() -> Bool)?,
        elType: String?,
        geometry: Geometry,
        enhancementLayerSize: (width: Int, height: Int)? = nil
    ) -> DualLayerRouteDecision {
        if let reason = blockingReasonBeforeProbe(
            codecID: codecID, dvProfile: dvProfile, dolbyVisionHandling: dolbyVisionHandling,
            preferDualLayerDolbyVision: preferDualLayerDolbyVision, isLive: isLive,
            isSourceSeekable: isSourceSeekable, canHardwareDecode: canHardwareDecode) {
            return .notTaken(reason)
        }
        switch elType {
        case "FEL":
            guard geometry.width > 0, geometry.height > 0 else { return .notTaken(.geometryUnknown) }
            let required = requiredPixelsPerSecond(geometry: geometry, enhancementLayerSize: enhancementLayerSize)
            guard required <= maximumPixelsPerSecond else {
                return .notTaken(.overBudget(requiredPixelsPerSecond: required, geometry: geometry))
            }
            return .taken(elType: "FEL", geometry: geometry, budgetFraction: required / maximumPixelsPerSecond)
        case "MEL":
            return .notTaken(.melEnhancementLayer)
        default:
            return .notTaken(.enhancementLayerTypeUnknown)
        }
    }

    var isTaken: Bool {
        if case .taken = self { return true }
        return false
    }

    /// The one diagnostic line for a Profile 7 load, or nil for a source this decision does not concern.
    var logLine: String? {
        switch self {
        case .notTaken(.notProfile7):
            return nil
        case let .taken(elType, geometry, fraction):
            return "[AetherEngine] DV P7 dual-layer route: taken (el_type=\(elType), \(geometry.text), "
                + "budget \(Int((fraction * 100).rounded()))%)"
        case let .notTaken(reason):
            return "[AetherEngine] DV P7 dual-layer route: not taken (\(reason.text)), \(reason.fallbackText)"
        }
    }
}

extension DualLayerRouteDecision.Reason {

    var text: String {
        switch self {
        case .notProfile7:
            return "not Dolby Vision Profile 7"
        case .preferenceOff:
            return "preferDualLayerDolbyVision is off"
        case .notBuiltIn:
            return "built without the DualLayerDolbyVision trait"
        case .baseLayerOnlyHandling:
            return "dolbyVisionHandling is baseLayerOnly"
        case .liveOrNotSeekable:
            return "live or non-seekable source"
        case .noHardwareHEVC:
            return "no hardware HEVC decoder for this stream"
        case .melEnhancementLayer:
            return "el_type=MEL, nothing to compose"
        case .enhancementLayerTypeUnknown:
            return "el_type unknown, no enhancement layer classified in the first RPU"
        case .geometryUnknown:
            return "base-layer size unknown"
        case let .overBudget(required, geometry):
            let percent = Int((required / DualLayerRouteDecision.maximumPixelsPerSecond * 100).rounded())
            return "over the real-time budget, \(geometry.text) needs \(percent)% of it"
        }
    }

    /// What the not-taken line says plays instead. Deliberately about the ROUTE, not the picture: the
    /// native route presents 8.1 only where the display takes Dolby Vision, and the HDR10 base layer
    /// where it does not (`CodecRoutePolicy` strips the Dolby Vision) or `preferredDecodePath` is
    /// `.software`. Pinned by `DualLayerRouteDecisionTests`.
    static let nativeRouteFallback = "keeps the native route (8.1 where the display takes Dolby Vision)"

    /// What plays instead.
    var fallbackText: String {
        switch self {
        case .baseLayerOnlyHandling: return "playing the HDR10 base layer"
        default: return Self.nativeRouteFallback
        }
    }
}
