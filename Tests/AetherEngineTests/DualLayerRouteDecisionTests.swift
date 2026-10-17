// Only with the DualLayerDolbyVision trait: without it every Profile 7 decision is `notBuiltIn`.
#if DualLayerDolbyVision
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// The Profile 7 dual-layer route is FEL only and capability gated: MEL, an unclassified enhancement
/// layer, a box without a hardware HEVC decoder and a stream too heavy to decode twice in real time all
/// keep the native route, and the load logs one line saying which. These tests hold every exit of that decision.
@Suite("Dual-layer route decision")
struct DualLayerRouteDecisionTests {

    private typealias Geometry = DualLayerRouteDecision.Geometry
    private let uhd24 = Geometry(width: 3840, height: 2160, frameRate: 24000.0 / 1001.0)

    private func decide(
        codec: AVCodecID = AV_CODEC_ID_HEVC, profile: Int? = 7,
        handling: DolbyVisionHandling = .automatic, prefer: Bool = true,
        live: Bool = false, seekable: Bool = true, hardware: (() -> Bool)? = { true },
        elType: String? = "FEL", geometry: Geometry? = nil
    ) -> DualLayerRouteDecision {
        DualLayerRouteDecision.decide(
            codecID: codec, dvProfile: profile, dolbyVisionHandling: handling,
            preferDualLayerDolbyVision: prefer, isLive: live, isSourceSeekable: seekable,
            canHardwareDecode: hardware, elType: elType, geometry: geometry ?? uhd24)
    }

    @Test("a 24p UHD FEL source on a capable box takes the route and logs the budget it uses")
    func felTakesTheRoute() {
        let decision = decide()
        #expect(decision.isTaken)
        #expect(decision.logLine == "[AetherEngine] DV P7 dual-layer route: taken (el_type=FEL, 3840x2160@23.976, budget 80%)")
    }

    @Test("MEL never takes the route, with the flag on")
    func melNeverTakesTheRoute() {
        let decision = decide(prefer: true, elType: "MEL")
        #expect(decision == .notTaken(.melEnhancementLayer))
        #expect(decision.logLine?.contains("el_type=MEL") == true)
        #expect(decision.logLine?.hasSuffix("keeps the native route (8.1 where the display takes Dolby Vision)") == true)
    }

    @Test("an enhancement layer the probe could not classify does not take the route")
    func unknownElTypeDoesNotTakeTheRoute() {
        #expect(decide(elType: nil) == .notTaken(.enhancementLayerTypeUnknown))
        #expect(decide(elType: "other") == .notTaken(.enhancementLayerTypeUnknown))
    }

    @Test("every other exit names its reason")
    func everyExitHasItsReason() {
        #expect(decide(prefer: false) == .notTaken(.preferenceOff))
        #expect(decide(handling: .baseLayerOnly) == .notTaken(.baseLayerOnlyHandling))
        #expect(decide(live: true) == .notTaken(.liveOrNotSeekable))
        #expect(decide(seekable: false) == .notTaken(.liveOrNotSeekable))
        #expect(decide(hardware: { false }) == .notTaken(.noHardwareHEVC))
        #expect(decide(profile: 8) == .notTaken(.notProfile7))
        #expect(decide(profile: nil) == .notTaken(.notProfile7))
        #expect(decide(codec: AV_CODEC_ID_H264) == .notTaken(.notProfile7))
    }

    @Test("a missing hardware verdict assumes hardware decode, as the routing policy does")
    func nilHardwareVerdictAssumesHardware() {
        #expect(decide(hardware: nil).isTaken)
    }

    @Test("a source that is not Profile 7 logs nothing; every Profile 7 outcome logs exactly one line")
    func onlyProfile7LogsALine() {
        #expect(decide(profile: 8).logLine == nil)
        #expect(decide(codec: AV_CODEC_ID_H264, prefer: false).logLine == nil)
        let reasons = [
            decide(prefer: false), decide(handling: .baseLayerOnly), decide(live: true),
            decide(hardware: { false }), decide(elType: "MEL"), decide(elType: nil),
            decide(geometry: Geometry(width: 3840, height: 2160, frameRate: 60)),
        ]
        for decision in reasons {
            guard let line = decision.logLine else {
                Issue.record("a Profile 7 fallback must log its reason: \(decision)")
                continue
            }
            #expect(line.hasPrefix("[AetherEngine] DV P7 dual-layer route: not taken ("))
            #expect(!line.contains("\n"))
        }
        #expect(decide(prefer: false).logLine?.contains("preferDualLayerDolbyVision is off") == true)
        #expect(decide(handling: .baseLayerOnly).logLine?.contains("HDR10 base layer") == true)
    }

    // MARK: - Real-time budget

    @Test("the budget is UHD at 30 fps plus a 1080p enhancement layer at 30 fps")
    func budgetConstant() {
        #expect(DualLayerRouteDecision.maximumPixelsPerSecond == 311_040_000)
    }

    @Test("the budget boundary: UHD at 30 fps is exactly in, a hair above it is out")
    func budgetBoundary() {
        let atLimit = decide(geometry: Geometry(width: 3840, height: 2160, frameRate: 30))
        #expect(atLimit.logLine?.contains("budget 100%") == true)
        let justOver = decide(geometry: Geometry(width: 3840, height: 2160, frameRate: 30.01))
        guard case .notTaken(.overBudget) = justOver else {
            Issue.record("30.01 fps UHD should exceed the budget, got \(justOver)")
            return
        }
        #expect(decide(geometry: Geometry(width: 3840, height: 2160, frameRate: 29.97)).isTaken)
    }

    @Test("UHD at 60 fps and 8K at 24 fps are over budget and say how far")
    func heavyStreamsFallBack() {
        let uhd60 = decide(geometry: Geometry(width: 3840, height: 2160, frameRate: 60))
        #expect(uhd60.logLine == "[AetherEngine] DV P7 dual-layer route: not taken (over the real-time budget, 3840x2160@60 needs 200% of it), keeps the native route (8.1 where the display takes Dolby Vision)")
        let uhd8k = decide(geometry: Geometry(width: 7680, height: 4320, frameRate: 24))
        #expect(!uhd8k.isTaken)
    }

    @Test("an unknown frame rate is budgeted at 24 and the line says so")
    func unknownFrameRateAssumes24() {
        let decision = decide(geometry: Geometry(width: 3840, height: 2160, frameRate: nil))
        #expect(decision.logLine == "[AetherEngine] DV P7 dual-layer route: taken (el_type=FEL, 3840x2160@24 (assumed), budget 80%)")
        let nonsense = Geometry(width: 3840, height: 2160, frameRate: -1)
        #expect(nonsense.effectiveFrameRate == 24)
    }

    @Test("the enhancement layer is a quarter of the base layer's area unless the stream says otherwise")
    func enhancementLayerSize() {
        let geometry = Geometry(width: 3840, height: 2160, frameRate: 30)
        let assumed = DualLayerRouteDecision.requiredPixelsPerSecond(geometry: geometry)
        #expect(assumed == DualLayerRouteDecision.maximumPixelsPerSecond)
        let fullSize = DualLayerRouteDecision.requiredPixelsPerSecond(
            geometry: geometry, enhancementLayerSize: (3840, 2160))
        #expect(fullSize > DualLayerRouteDecision.maximumPixelsPerSecond)
    }

    @Test("the el_type probe is only wanted when nothing rules the route out first")
    func probeRunsOnlyWhenItCanChangeTheRoute() {
        func blocked(codec: AVCodecID = AV_CODEC_ID_HEVC, profile: Int? = 7,
                     handling: DolbyVisionHandling = .automatic, prefer: Bool = true,
                     live: Bool = false, seekable: Bool = true,
                     hardware: (() -> Bool)? = { true }) -> DualLayerRouteDecision.Reason? {
            DualLayerRouteDecision.blockingReasonBeforeProbe(
                codecID: codec, dvProfile: profile, dolbyVisionHandling: handling,
                preferDualLayerDolbyVision: prefer, isLive: live, isSourceSeekable: seekable,
                canHardwareDecode: hardware)
        }
        #expect(blocked() == nil)
        #expect(blocked(prefer: false) != nil)
        #expect(blocked(handling: .baseLayerOnly) != nil)
        #expect(blocked(live: true) != nil)
        #expect(blocked(seekable: false) != nil)
        #expect(blocked(hardware: { false }) != nil)
        #expect(blocked(profile: 8) != nil)
    }

    // MARK: - Reload of a custom source

    /// A custom source's rebuild keeps the backend and el_type the session was loaded with, so a flip
    /// of the flag on a Profile 7 session would be logged as applied and change nothing. It is refused
    /// instead, before any teardown; URL sources re-run `load()` and are not.
    @Test("flipping preferDualLayerDolbyVision on a custom Profile 7 session is refused, nothing else is")
    func customSourceFlagFlipIsRefused() {
        var off = LoadOptions()
        off.preferDualLayerDolbyVision = false
        var on = off
        on.preferDualLayerDolbyVision = true
        func refusal(custom: Bool, from: LoadOptions, to: LoadOptions, profile: Int?) -> SessionReloadRefusal? {
            SessionOptionCorrection.dualLayerRouteRefusal(
                isCustomSource: custom, current: from, proposed: to, dvProfile: profile)
        }
        #expect(refusal(custom: true, from: off, to: on, profile: 7) == .dualLayerRouteNeedsFreshLoad)
        #expect(refusal(custom: true, from: on, to: off, profile: 7) == .dualLayerRouteNeedsFreshLoad)
        // A URL source re-runs load(), a non-P7 source routes the same either way, an unchanged flag moves nothing.
        #expect(refusal(custom: false, from: off, to: on, profile: 7) == nil)
        #expect(refusal(custom: true, from: off, to: on, profile: 8) == nil)
        #expect(refusal(custom: true, from: off, to: on, profile: nil) == nil)
        #expect(refusal(custom: true, from: on, to: on, profile: 7) == nil)
        #expect(!SessionReloadRefusal.dualLayerRouteNeedsFreshLoad.description.isEmpty)
    }

    /// The route needs `dolbyVisionHandling` `.automatic`, so on a custom Profile 7 session a handling
    /// change that can turn the route on or off is refused like a flag flip. With the preference off the
    /// handling cannot move the route and is not refused.
    @Test("a dolbyVisionHandling change that can move the route on a custom Profile 7 session is refused")
    func customSourceHandlingChangeIsRefused() {
        var automatic = LoadOptions()
        automatic.preferDualLayerDolbyVision = true
        automatic.dolbyVisionHandling = .automatic
        var baseOnly = automatic
        baseOnly.dolbyVisionHandling = .baseLayerOnly
        var offAutomatic = automatic
        offAutomatic.preferDualLayerDolbyVision = false
        var offBaseOnly = offAutomatic
        offBaseOnly.dolbyVisionHandling = .baseLayerOnly
        func refusal(custom: Bool = true, from: LoadOptions, to: LoadOptions, profile: Int? = 7) -> SessionReloadRefusal? {
            SessionOptionCorrection.dualLayerRouteRefusal(
                isCustomSource: custom, current: from, proposed: to, dvProfile: profile)
        }
        #expect(refusal(from: automatic, to: baseOnly) == .dualLayerRouteNeedsFreshLoad)
        #expect(refusal(from: baseOnly, to: automatic) == .dualLayerRouteNeedsFreshLoad)
        // The preference is off on both sides: the route is not taken either way.
        #expect(refusal(from: offAutomatic, to: offBaseOnly) == nil)
        // URL sources re-run load(), other profiles route the same, an unchanged handling moves nothing.
        #expect(refusal(custom: false, from: automatic, to: baseOnly) == nil)
        #expect(refusal(from: automatic, to: baseOnly, profile: 8) == nil)
        #expect(refusal(from: automatic, to: automatic) == nil)
    }

    /// A fatal decode error is the decoder session's, reported once; only a stopped host drops it, a
    /// seek in flight does not.
    @Test("a session failure is admitted across a seek and dropped only by a stop")
    func sessionFailureIgnoresSeekGeneration() {
        #expect(SoftwareReadAdmission.admitsSessionFailure(stopRequested: false))
        #expect(!SoftwareReadAdmission.admitsSessionFailure(stopRequested: true))
        // The per-seek admission it replaces rejects the same event once a seek has opened.
        #expect(!SoftwareReadAdmission.admits(readGeneration: 3, requestedGeneration: 4,
                                              settledGeneration: 3, stopRequested: false))
    }
}
#endif
