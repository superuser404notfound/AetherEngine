import Foundation
import CoreGraphics
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The object renderer, the dual-layer composer and the Dolby Vision still reshaping are compiled only
/// with their package traits, all off by default. A build without one still accepts the option that asks
/// for it, and the option changes nothing: object audio keeps the channel bridge, a Profile 7 source keeps
/// the native route, a Profile 5 source yields no still. The track pick is pinned the same way in
/// `AudioLanguageSelectionTests.withoutTraitNothingIsPreferred`.
@Suite("Optional components fall back when their trait is off")
struct OptionalComponentFallbackTests {

    @Test("the runtime query reports each component as this build was compiled")
    func runtimeQueryMatchesTheBuild() {
        #expect(AetherEngine.OptionalComponent.allCases.map(\.traitName)
                == ["TrueHDObjectAudio", "DTSXObjectAudio", "DualLayerDolbyVision", "DolbyVisionStillReshaping"])
        #if TrueHDObjectAudio
        #expect(AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn)
        #else
        #expect(!AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn)
        #endif
        #if DTSXObjectAudio
        #expect(AetherEngine.OptionalComponent.dtsxObjectAudio.isBuiltIn)
        #else
        #expect(!AetherEngine.OptionalComponent.dtsxObjectAudio.isBuiltIn)
        #endif
        #if DualLayerDolbyVision
        #expect(AetherEngine.OptionalComponent.dualLayerDolbyVision.isBuiltIn)
        #else
        #expect(!AetherEngine.OptionalComponent.dualLayerDolbyVision.isBuiltIn)
        #endif
        #if DolbyVisionStillReshaping
        #expect(AetherEngine.OptionalComponent.dolbyVisionStillReshaping.isBuiltIn)
        #else
        #expect(!AetherEngine.OptionalComponent.dolbyVisionStillReshaping.isBuiltIn)
        #endif
        #expect(AetherEngine.linksTrueHDObjectDecoder == AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn)
        #expect(DualLayerRouteDecision.isBuiltIn == AetherEngine.OptionalComponent.dualLayerDolbyVision.isBuiltIn)
    }

    #if !DualLayerDolbyVision
    private static let uhd24 = DualLayerRouteDecision.Geometry(width: 3840, height: 2160, frameRate: 24)

    private static func decide(prefer: Bool) -> DualLayerRouteDecision {
        DualLayerRouteDecision.decide(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 7, dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: prefer, isLive: false, isSourceSeekable: true,
            canHardwareDecode: { true }, elType: "FEL", geometry: uhd24)
    }

    @Test("preferDualLayerDolbyVision keeps a Profile 7 FEL source on the native route and says why")
    func dualLayerPreferenceKeepsNativeRoute() {
        #expect(!DualLayerRouteDecision.isBuiltIn)
        #expect(Self.decide(prefer: true) == .notTaken(.notBuiltIn))
        #expect(Self.decide(prefer: true).logLine
                == "[AetherEngine] DV P7 dual-layer route: not taken (built without the DualLayerDolbyVision trait), "
                + "keeps the native route (8.1 where the display takes Dolby Vision)")
        #expect(Self.decide(prefer: false) == .notTaken(.preferenceOff), "not asking is still reported as such")
        #expect(!VideoRoutingPolicy.dualLayerRouteIsWanted(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 7, dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: true, canHardwareDecode: { true }),
            "no el_type probe for a route that cannot be taken")
        for prefer in [true, false] {
            #expect(!VideoRoutingPolicy.requiresSoftwarePath(
                codecID: AV_CODEC_ID_HEVC, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true,
                dvProfile: 7, preferDualLayerDolbyVision: prefer, canHardwareDecode: { true }, elType: "FEL"))
        }
    }

    @Test("flipping preferDualLayerDolbyVision on a custom Profile 7 session is not refused: it moves nothing")
    func dualLayerCorrectionIsNotRefused() {
        var off = LoadOptions()
        off.preferDualLayerDolbyVision = false
        var on = off
        on.preferDualLayerDolbyVision = true
        var baseOnly = on
        baseOnly.dolbyVisionHandling = .baseLayerOnly
        for (from, to) in [(off, on), (on, off), (on, baseOnly)] {
            #expect(SessionOptionCorrection.dualLayerRouteRefusal(
                isCustomSource: true, current: from, proposed: to, dvProfile: 7) == nil)
        }
    }
    #endif

    #if !DolbyVisionStillReshaping
    /// The 64x64 HDR10 fixture with a Profile 5 record: its frames are what a Profile 5 decode hands
    /// the still path. Read as YCbCr, real Profile 5 planes are the green / magenta still of #103, so
    /// without the reshaping the answer is no still at all, while the same frames without the record
    /// still make one.
    @MainActor
    @Test("a Dolby Vision Profile 5 frame yields no still; the same frames without the record do")
    func profile5YieldsNoStill() throws {
        func still(_ data: Data) throws -> (image: CGImage?, isDolbyVision: Bool) {
            let context = FrameDecodeContext(reader: DataIOReader(data: data), formatHint: "mp4")
            defer { context.close() }
            try context.ensureOpen()
            let image = context.decodeFrame(at: 0, mode: .thumbnail, targetWidth: 64, maxSize: nil,
                                            isCancelled: { false })
            return (image, context.isDolbyVisionNoBaseLayer)
        }
        let profile5 = try still(SupersededProbeGeometryTests.dolbyVisionProfile5OverHDR10())
        #expect(profile5.isDolbyVision)
        #expect(profile5.image == nil)
        let hdr10 = try still(ProbeTestFixtures.hdr10Plus())
        #expect(!hdr10.isDolbyVision)
        #expect(hdr10.image != nil)
        #expect(!FrameDecodeContext.yieldsStill(dolbyVisionNoBaseLayer: true))
        #expect(FrameDecodeContext.yieldsStill(dolbyVisionNoBaseLayer: false))
    }

    @Test("an I-frame rendition is not served for a source whose stills cannot be made")
    func iFrameRenditionIsAbsent() {
        let verdict = IFrameRenditionEligibility.candidate(.init(
            requested: true, isLive: false, planBoundariesClaimRandomAccess: true, sequentialOrigin: false,
            heldSourceConnection: false, originIsSerial: false, isDiscSource: false, secondReaderAvailable: true,
            stillsUnavailable: !FrameDecodeContext.yieldsStill(dolbyVisionNoBaseLayer: true)))
        #expect(verdict == .absent(.dolbyVisionStillsNotBuiltIn))
    }
    #endif

    #if !TrueHDObjectAudio
    @Test("objectAudioRendering keeps TrueHD Atmos on the channel bridge")
    func trueHDAtmosKeepsChannelBridge() {
        #expect(HLSVideoEngine.objectAudioSource(codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS) == .trueHDAtmos)
        #expect(HLSVideoEngine.ObjectAudioSource.trueHDAtmos.isBuiltIn == false)
        for layout in SpatialSpeakerLayout.allCases {
            #expect(HLSVideoEngine.spatialRenderingLayout(
                rendering: .apac(layout), codecID: AV_CODEC_ID_TRUEHD,
                profile: AV_PROFILE_TRUEHD_ATMOS, sampleRate: 48_000) == nil)
        }
    }
    #endif

    #if !DTSXObjectAudio
    @Test("objectAudioRendering keeps DTS-HD Master Audio on the channel bridge")
    func dtsHDMasterAudioKeepsChannelBridge() {
        #expect(HLSVideoEngine.ObjectAudioSource.dtsHDMasterAudio.isBuiltIn == false)
        for profile in [AV_PROFILE_DTS_HD_MA, AV_PROFILE_DTS_HD_MA_X, AV_PROFILE_DTS_HD_MA_X_IMAX] {
            #expect(HLSVideoEngine.objectAudioSource(codecID: AV_CODEC_ID_DTS, profile: profile) == .dtsHDMasterAudio)
            #expect(HLSVideoEngine.spatialRenderingLayout(
                rendering: .apac(.l714), codecID: AV_CODEC_ID_DTS, profile: profile, sampleRate: 48_000) == nil)
        }
    }
    #endif
}
