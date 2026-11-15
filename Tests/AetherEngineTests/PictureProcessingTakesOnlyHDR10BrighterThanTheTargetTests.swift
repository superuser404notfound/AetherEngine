import Foundation
import AetherLibavcodec
import AetherLibavutil
import Testing
@testable import AetherEngine

/// #957: `LoadOptions.videoProcessing` takes an HDR10 title onto the software path only when the tone map
/// can improve it: a PQ source with declared metadata whose peak is above the target, on a display that
/// takes HDR10. Everything else keeps its route, and the load says why in one line.
@Suite("Picture processing takes only HDR10 brighter than the target (#957)", .serialized)
struct PictureProcessingTakesOnlyHDR10BrighterThanTheTargetTests {

    private static let master = HDR10StaticMetadata(maxCLL: 1000, maxFALL: 400, masteringPeakNits: 1000,
                                                    masteringMinNits: 0.005)
    private static let target = VideoProcessingOptions(targetPeakNits: 600)

    private static func decide(
        options: VideoProcessingOptions? = target, osSupportsStage: Bool = true, isPQ: Bool = true,
        isDolbyVision: Bool = false, carriesHDR10Plus: Bool = false, displayTakesHDR10: Bool = true,
        declared: HDR10StaticMetadata? = master, width: Int = 3840, height: Int = 2160,
        isFourTwoZero: Bool = true, wirelessAirPlayRoute: Bool = false, demuxedAudioLive: Bool = false,
        stageFailedEarlier: @escaping (VideoProcessingPlan) -> Bool = { _ in false }
    ) -> VideoProcessingRouteDecision {
        VideoProcessingRouteDecision.decide(
            options: options, osSupportsStage: osSupportsStage, isPQ: isPQ, isDolbyVision: isDolbyVision,
            carriesHDR10Plus: carriesHDR10Plus, displayTakesHDR10: displayTakesHDR10, declared: declared,
            width: width, height: height, isFourTwoZero: isFourTwoZero,
            wirelessAirPlayRoute: wirelessAirPlayRoute, demuxedAudioLive: demuxedAudioLive,
            stageFailedEarlier: stageFailedEarlier)
    }

    private static func plan() throws -> VideoProcessingPlan {
        try #require(decide().plan)
    }

    @Test func issue957AnHDR10TitleBrighterThanTheTargetIsTaken() throws {
        let plan = try Self.plan()
        #expect(plan.width == 3840 && plan.height == 2160)
        #expect(plan.source == Self.master)
        #expect(plan.sourcePeak == .mastering)
        #expect(plan.curve == BT2390ToneCurve(sourcePeakNits: 1000, targetPeakNits: 600))
        #expect(Self.decide().logLine
                == "[VideoProcessing] taken: 3840x2160, tone map 1000 nit (mastering) to 600 nit, knee at 464 nit")
    }

    @Test func issue957MaxCLLBelowTheMasteringPeakSetsTheCurve() throws {
        let declared = HDR10StaticMetadata(maxCLL: 1200, maxFALL: 300, masteringPeakNits: 4000, masteringMinNits: 0.005)
        let plan = try #require(Self.decide(declared: declared).plan)
        #expect(plan.sourcePeak == .maxCLL)
        #expect(plan.curve.sourcePeakNits == 1200)
    }

    /// Each exit, with every earlier check passing, so the order is pinned too.
    @Test func issue957EveryOtherSourceKeepsItsRoute() {
        typealias R = VideoProcessingRouteDecision.Reason
        let cases: [(VideoProcessingRouteDecision, R)] = [
            (Self.decide(options: nil), .preferenceOff),
            (Self.decide(osSupportsStage: false), .unsupportedOS),
            (Self.decide(isPQ: true, isDolbyVision: true), .dolbyVision),
            (Self.decide(isPQ: false), .notHDR10),
            (Self.decide(carriesHDR10Plus: true), .hdr10Plus),
            (Self.decide(displayTakesHDR10: false), .displayNotHDR10),
            (Self.decide(declared: nil), .noStaticMetadata),
            (Self.decide(declared: HDR10StaticMetadata(maxCLL: 0, maxFALL: 0, masteringPeakNits: 0, masteringMinNits: 0)),
             .noStaticMetadata),
            (Self.decide(options: VideoProcessingOptions(targetPeakNits: 1000)),
             .peakAtOrBelowTarget(sourcePeakNits: 1000, targetPeakNits: 1000)),
            (Self.decide(options: VideoProcessingOptions(targetPeakNits: 5)),
             .targetTooLow(sourcePeakNits: 1000, targetPeakNits: 5)),
            (Self.decide(isFourTwoZero: false), .notFourTwoZero),
            (Self.decide(width: 0), .geometryUnknown),
            (Self.decide(wirelessAirPlayRoute: true), .wirelessAirPlayRoute),
            (Self.decide(demuxedAudioLive: true), .demuxedAudioLive),
            (Self.decide(stageFailedEarlier: { _ in true }), .stageFailedEarlier),
        ]
        for (decision, reason) in cases {
            #expect(decision == .notTaken(reason))
            if reason == .preferenceOff {
                #expect(decision.logLine == nil, "the option off logs nothing")
            } else {
                #expect(decision.logLine == "[VideoProcessing] not taken (\(reason.text))")
            }
        }
        #expect(R.peakAtOrBelowTarget(sourcePeakNits: 1000, targetPeakNits: 1000).text
                == "source peak 1000 nit is at or below the 1000 nit target")
    }

    /// AE#348's gate runs beside a VOD load, so the panel may not be settled where the route is chosen. An
    /// opted-in HDR10 load settles it first, and an unsettled or SDR panel never takes the route.
    @Test func issue957TheRouteReadsOnlyASettledHDRPanel() {
        #expect(AetherEngine.videoProcessingSettlesPanelFirst(processingOn: true, effectiveFormat: .hdr10))
        #expect(AetherEngine.videoProcessingSettlesPanelFirst(processingOn: true, effectiveFormat: .hdr10Plus))
        #expect(!AetherEngine.videoProcessingSettlesPanelFirst(processingOn: false, effectiveFormat: .hdr10),
                "the option off keeps the overlap")
        #expect(!AetherEngine.videoProcessingSettlesPanelFirst(processingOn: true, effectiveFormat: .sdr))
        #expect(!AetherEngine.videoProcessingSettlesPanelFirst(processingOn: true, effectiveFormat: .dolbyVision))

        func takes(_ format: VideoFormat, settled: Bool, hdr: Bool) -> Bool {
            AetherEngine.videoProcessingDisplayTakesHDR10(effectiveFormat: format, panelRoutingSettled: settled,
                                                          routingPanelHDR: hdr)
        }
        #expect(!takes(.hdr10, settled: false, hdr: false), "an unsettled panel is no answer")
        #expect(!takes(.hdr10, settled: true, hdr: false), "a panel left in SDR would map the picture again")
        #expect(takes(.hdr10, settled: true, hdr: true))
        #expect(!takes(.sdr, settled: true, hdr: true))
        #expect(Self.decide(displayTakesHDR10: takes(.hdr10, settled: true, hdr: false)) == .notTaken(.displayNotHDR10))
    }

    @Test func issue957ARebuildKeepsThePlanUntilTheProcessingDisabledItself() throws {
        let plan = try Self.plan()
        let on = VideoProcessingRouteDecision.forRebuild(sessionPlan: plan, optionOn: true, disabled: nil)
        #expect(on.plan == plan && on.status == nil)
        let off = VideoProcessingRouteDecision.forRebuild(sessionPlan: plan, optionOn: false, disabled: nil)
        #expect(off.plan == nil && off.status == nil)
        let gaveUp = VideoProcessingStatus(plan: plan, disabledReason: "over budget")
        let disabled = VideoProcessingRouteDecision.forRebuild(sessionPlan: plan, optionOn: true, disabled: gaveUp)
        #expect(disabled.plan == nil && disabled.status == gaveUp)
        let none = VideoProcessingRouteDecision.forRebuild(sessionPlan: nil, optionOn: true, disabled: nil)
        #expect(none.plan == nil && none.status == nil)
    }

    @Test func issue957ATitleThatGaveUpStaysNativeForTheProcess() throws {
        VideoProcessingFailureMemory.reset()
        defer { VideoProcessingFailureMemory.reset() }
        let plan = try Self.plan()
        // An overrun at 59.94 blocks that rate and faster, not a 24 fps title of the same size.
        VideoProcessingFailureMemory.record(plan, frameRate: 59.94)
        #expect(VideoProcessingFailureMemory.contains(plan, frameRate: 59.94))
        #expect(VideoProcessingFailureMemory.contains(plan, frameRate: 60))
        #expect(!VideoProcessingFailureMemory.contains(plan, frameRate: 23.976))
        #expect(VideoProcessingFailureMemory.contains(plan, frameRate: nil))
        // HDR10+ is kept without a rate: no rate makes the title processable.
        var other = plan
        other.width = 1920
        other.height = 1080
        VideoProcessingFailureMemory.record(other, frameRate: nil)
        #expect(VideoProcessingFailureMemory.contains(other, frameRate: 23.976))
        let decision = Self.decide(width: 1920, height: 1080,
                                   stageFailedEarlier: { VideoProcessingFailureMemory.contains($0, frameRate: 24) })
        #expect(decision == .notTaken(.stageFailedEarlier))
    }

    @Test func issue957TheStatusKeepsWhatRanAndAddsTheDisable() throws {
        let plan = try Self.plan()
        let ran = VideoProcessingStatus(stages: [.toneMap], sourcePeakNits: 1200, sourcePeak: .maxCLL, targetPeakNits: 600)
        #expect(VideoProcessingStatus.afterProcessedFrame(ran, current: nil) == ran)
        let disabled = VideoProcessingStatus.afterDisable(reason: "HDR10+", current: ran, plan: plan)
        #expect(disabled.sourcePeakNits == 1200 && disabled.sourcePeak == .maxCLL && disabled.disabledReason == "HDR10+")
        #expect(VideoProcessingStatus.afterProcessedFrame(ran, current: disabled) == disabled, "a disable is not undone")
        let early = VideoProcessingStatus.afterDisable(reason: "failures", current: nil, plan: plan)
        #expect(early.stages == [.toneMap] && early.sourcePeakNits == 1000 && early.targetPeakNits == 600)
    }

    @Test func issue957ACustomSourceRefusesTurningItOnInPlace() {
        let off = LoadOptions()
        var on = off
        on.videoProcessing = Self.target
        var brighter = off
        brighter.videoProcessing = VideoProcessingOptions(targetPeakNits: 800)
        func refusal(custom: Bool, from: LoadOptions, to: LoadOptions) -> SessionReloadRefusal? {
            SessionOptionCorrection.videoProcessingRouteRefusal(isCustomSource: custom, current: from, proposed: to)
        }
        #expect(refusal(custom: true, from: off, to: on) == .videoProcessingRouteNeedsFreshLoad)
        #expect(refusal(custom: true, from: on, to: brighter) == .videoProcessingRouteNeedsFreshLoad)
        #expect(refusal(custom: true, from: on, to: off) == nil)
        #expect(refusal(custom: true, from: on, to: on) == nil)
        #expect(refusal(custom: false, from: off, to: on) == nil)
        #expect(SessionOptionCorrection.knownFields.contains("videoProcessing"))
        #expect(!SessionOptionCorrection.loadIdentityFields.contains("videoProcessing"))
        #expect(!SessionReloadRefusal.videoProcessingRouteNeedsFreshLoad.description.isEmpty)
    }

    @Test func issue957TheLoadReadsWhatTheStreamDeclares() throws {
        let codecpar = try #require(avcodec_parameters_alloc())
        defer { var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar; avcodec_parameters_free(&p) }
        let cll = try #require(av_packet_side_data_new(
            &codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
            AV_PKT_DATA_CONTENT_LIGHT_LEVEL, MemoryLayout<AVContentLightMetadata>.size, 0))
        try #require(cll.pointee.data).withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) {
            $0.pointee.MaxCLL = 1200
            $0.pointee.MaxFALL = 300
        }
        codecpar.pointee.color_trc = AVCOL_TRC_BT709
        #expect(HDR10StaticMetadataSEI.declared(by: codecpar).values.isEmpty, "only a PQ stream is read")
        codecpar.pointee.color_trc = AVCOL_TRC_SMPTE2084
        let found = HDR10StaticMetadataSEI.declared(by: codecpar)
        #expect(found.source == "container")
        let declared = try #require(HDR10StaticMetadata(masteringDisplayColorVolume: found.values.masteringDisplay,
                                                        contentLightLevel: found.values.contentLightLevel))
        #expect(declared.maxCLL == 1200 && declared.masteringPeakNits == 0)
        #expect(Self.decide(declared: declared).plan?.sourcePeak == .maxCLL)
    }
}
