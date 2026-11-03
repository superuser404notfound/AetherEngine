import Testing
import AetherLibavcodec
@testable import AetherEngine

@Suite("VideoRoutingPolicy (#107 interlaced H.264 deinterlace routing)")
struct VideoRoutingPolicyTests {
    @Test("interlaced H.264 routes to software for deinterlace")
    func interlacedH264Software() {
        for order in [AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT] {
            #expect(VideoRoutingPolicy.requiresSoftwarePath(
                codecID: AV_CODEC_ID_H264, fieldOrder: order, av1Available: true))
        }
    }

    @Test("progressive / unknown H.264 stays native")
    func progressiveH264Native() {
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_H264, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true))
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_H264, fieldOrder: AV_FIELD_UNKNOWN, av1Available: true))
    }

    @Test("interlaced HEVC stays native (documents the intentional limit)")
    func interlacedHEVCNative() {
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC, fieldOrder: AV_FIELD_TT, av1Available: true))
    }

    @Test("MPEG-2 / VC-1 always software regardless of field order")
    func mpeg2AlwaysSoftware() {
        #expect(VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_MPEG2VIDEO, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true))
        #expect(VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_VC1, fieldOrder: AV_FIELD_UNKNOWN, av1Available: true))
    }

    @Test("qtrle and the rest of the long tail route software, not native (FFmpegBuild#1)")
    func unenumeratedVideoCodecsAreSoftware() {
        // HLSVideoEngine accepts HEVC / H.264 / HW AV1 and throws unsupportedCodec on everything else,
        // so a codec the switch never named used to fail the load rather than fall back to libavcodec.
        // The legacy Microsoft tail (FFmpegBuild 2.4.3) is in the same class: a decoder exists for it
        // now, and it only ever reaches that decoder because the default here is software.
        for codec in [AV_CODEC_ID_QTRLE, AV_CODEC_ID_PRORES, AV_CODEC_ID_MJPEG,
                      AV_CODEC_ID_THEORA, AV_CODEC_ID_RAWVIDEO, AV_CODEC_ID_CINEPAK,
                      AV_CODEC_ID_MSMPEG4V1, AV_CODEC_ID_MSMPEG4V2, AV_CODEC_ID_MSMPEG4V3,
                      AV_CODEC_ID_WMV1, AV_CODEC_ID_WMV2, AV_CODEC_ID_WMV3] {
            #expect(VideoRoutingPolicy.requiresSoftwarePath(
                codecID: codec, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true))
            #expect(VideoRoutingPolicy.requiresSoftwarePath(
                codecID: codec, fieldOrder: AV_FIELD_UNKNOWN, av1Available: false))
        }
    }

    @Test("no video stream stays native (audio-only probes as NONE)")
    func audioOnlyStaysNative() {
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_NONE, fieldOrder: AV_FIELD_UNKNOWN, av1Available: true))
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_NONE, fieldOrder: AV_FIELD_UNKNOWN, av1Available: false))
    }

    @Test("AV1 follows hardware availability")
    func av1FollowsHardware() {
        #expect(VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_AV1, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: false))
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_AV1, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true))
    }

    @Test("Only AV1 routing evaluates the hardware capability probe")
    func hardwareProbeIsLazy() {
        var calls = 0
        func probe() -> Bool { calls += 1; return true }
        for codec in [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_NONE,
                      AV_CODEC_ID_VP9, AV_CODEC_ID_MPEG2VIDEO] {
            _ = VideoRoutingPolicy.requiresSoftwarePath(
                codecID: codec, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: probe())
        }
        #expect(calls == 0)
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_AV1, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: probe()))
        #expect(calls == 1)
    }

    @Test("progressive software codecs do not need hardware deinterlace warm-up")
    func progressiveCodecsSkipDeinterlaceWarmup() {
        for codec in [AV_CODEC_ID_NONE, AV_CODEC_ID_VP8, AV_CODEC_ID_VP9, AV_CODEC_ID_AV1, AV_CODEC_ID_HEVC] {
            #expect(!VideoRoutingPolicy.requiresDeinterlaceWarmup(codecID: codec, fieldOrder: AV_FIELD_UNKNOWN))
        }
        for codec in [AV_CODEC_ID_H264, AV_CODEC_ID_MPEG4, AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VC1] {
            #expect(!VideoRoutingPolicy.requiresDeinterlaceWarmup(codecID: codec, fieldOrder: AV_FIELD_PROGRESSIVE))
        }
    }

    @Test("interlaced and unknown legacy sources preserve hardware deinterlace warm-up")
    func interlacedSourcesWarmDeinterlacer() {
        for order in VideoRoutingPolicy.interlacedFieldOrders {
            for codec in [AV_CODEC_ID_H264, AV_CODEC_ID_MPEG4, AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VC1,
                          AV_CODEC_ID_DVVIDEO, AV_CODEC_ID_MPEG1VIDEO, AV_CODEC_ID_H263, AV_CODEC_ID_PRORES] {
                #expect(VideoRoutingPolicy.requiresDeinterlaceWarmup(codecID: codec, fieldOrder: order))
            }
        }
        for codec in [AV_CODEC_ID_MPEG4, AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VC1] {
            #expect(VideoRoutingPolicy.requiresDeinterlaceWarmup(codecID: codec, fieldOrder: AV_FIELD_UNKNOWN))
        }
        #expect(!VideoRoutingPolicy.requiresDeinterlaceWarmup(codecID: AV_CODEC_ID_H264, fieldOrder: AV_FIELD_UNKNOWN))
        #expect(VideoRoutingPolicy.requiresDeinterlaceWarmup(
            codecID: AV_CODEC_ID_H264, fieldOrder: AV_FIELD_UNKNOWN, spsIndicatesInterlaced: true))
        #expect(!VideoRoutingPolicy.requiresDeinterlaceWarmup(
            codecID: AV_CODEC_ID_H264, fieldOrder: AV_FIELD_PROGRESSIVE, spsIndicatesInterlaced: true))
    }

    // MARK: - #150 SPS frame_mbs_only fallback for UNKNOWN field order

    @Test("UNKNOWN field order + SPS frame_mbs_only=0 routes to software")
    func unknownFieldOrderSPSInterlacedSoftware() {
        #expect(VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_H264, fieldOrder: AV_FIELD_UNKNOWN, av1Available: true,
            spsIndicatesInterlaced: true))
    }

    @Test("UNKNOWN field order without SPS interlace signal stays native")
    func unknownFieldOrderNoSPSSignalNative() {
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_H264, fieldOrder: AV_FIELD_UNKNOWN, av1Available: true,
            spsIndicatesInterlaced: false))
    }

    @Test("concrete PROGRESSIVE probe wins over SPS interlaced-capable flag")
    func progressiveProbeWinsOverSPS() {
        // frame_mbs_only=0 only means the stream MAY code interlaced pictures; a demuxer probe that
        // analyzed actual frames and concluded progressive is the stronger signal.
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_H264, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true,
            spsIndicatesInterlaced: true))
    }

    @Test("concrete interlaced field orders ignore the SPS parameter")
    func concreteInterlacedIgnoresSPSParameter() {
        #expect(VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_H264, fieldOrder: AV_FIELD_TT, av1Available: true,
            spsIndicatesInterlaced: false))
    }

    @Test("non-H.264 codecs ignore the SPS parameter")
    func otherCodecsIgnoreSPSParameter() {
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC, fieldOrder: AV_FIELD_UNKNOWN, av1Available: true,
            spsIndicatesInterlaced: true))
    }

    @Test("spsIndicatesInterlaced classifies Annex-B and avcC extradata")
    func spsIndicatesInterlacedFromExtradata() {
        let sc: [UInt8] = [0, 0, 0, 1]
        let spsInterlaced: [UInt8] = [0x67, 0x4d, 0x40, 0x28, 0xec, 0xa0, 0x3c, 0x02, 0x23, 0xed]
        let spsProgressive: [UInt8] = [
            0x67, 0x64, 0x00, 0x1f, 0xac, 0xd9, 0x40, 0x50, 0x05, 0xbb, 0x01, 0x6a, 0x02, 0x04,
            0x02, 0x80, 0x00, 0x00, 0x03, 0x00, 0x80, 0x00, 0x00, 0x1e, 0x07, 0x8c, 0x18, 0xcb,
        ]
        let pps: [UInt8] = [0x68, 0xef, 0xbc, 0xb0]

        #expect(VideoRoutingPolicy.spsIndicatesInterlaced(extradata: sc + spsInterlaced + sc + pps))
        #expect(!VideoRoutingPolicy.spsIndicatesInterlaced(extradata: sc + spsProgressive + sc + pps))

        var avcc: [UInt8] = [0x01, 0x4d, 0x40, 0x28, 0xff, 0xe1]
        avcc += [0x00, UInt8(spsInterlaced.count)]
        avcc += spsInterlaced
        avcc += [0x01, 0x00, UInt8(pps.count)]
        avcc += pps
        #expect(VideoRoutingPolicy.spsIndicatesInterlaced(extradata: avcc))

        #expect(!VideoRoutingPolicy.spsIndicatesInterlaced(extradata: []))
        #expect(!VideoRoutingPolicy.spsIndicatesInterlaced(extradata: [0xde, 0xad]))
    }

    // MARK: - #2 undecodable-format second-stage gate

    @Test("H.264 / HEVC that VideoToolbox can't HW-decode falls back to software")
    func undecodableHEVCH264Software() {
        #expect(VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_H264, dvProfile: nil, canHardwareDecode: { false }))
        #expect(VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_HEVC, dvProfile: nil, canHardwareDecode: { false }))
    }

    @Test("HW-decodable H.264 / HEVC stays native (no Apple Silicon regression)")
    func decodableHEVCH264Native() {
        #expect(!VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_H264, dvProfile: nil, canHardwareDecode: { true }))
        #expect(!VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_HEVC, dvProfile: nil, canHardwareDecode: { true }))
    }

    @Test("codecs outside the gate ignore it (own policy governs them)")
    func otherCodecsIgnoreUndecodableGate() {
        // Must never reclassify VP9 / MPEG-2 / etc. off a codec it doesn't apply to.
        for codec in [AV_CODEC_ID_VP9, AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VC1] {
            #expect(!VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
                codecID: codec, dvProfile: nil, canHardwareDecode: { false }))
        }
    }

    // MARK: - Audit HLS-5: HW AV1 is Main profile only

    @Test("AV1 on a HW-AV1 device the decoder cannot take falls back to software")
    func av1OutsideHardwareProfileSoftware() {
        #expect(VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_AV1, dvProfile: nil, canHardwareDecode: { false }))
        #expect(!VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_AV1, dvProfile: nil, canHardwareDecode: { true }))
    }

    @Test("live consults the format gate for AV1 only; VOD consults it for every codec")
    func liveConsultsFormatGateForAV1Only() {
        #expect(VideoRoutingPolicy.consultsUndecodableFormatGate(codecID: AV_CODEC_ID_AV1, isLive: true))
        #expect(!VideoRoutingPolicy.consultsUndecodableFormatGate(codecID: AV_CODEC_ID_H264, isLive: true))
        #expect(!VideoRoutingPolicy.consultsUndecodableFormatGate(codecID: AV_CODEC_ID_HEVC, isLive: true))
        for codec in [AV_CODEC_ID_AV1, AV_CODEC_ID_H264, AV_CODEC_ID_HEVC] {
            #expect(VideoRoutingPolicy.consultsUndecodableFormatGate(codecID: codec, isLive: false))
        }
    }

    @Test("av1C seq_profile decides: Main fits the hardware decoder, High and Professional do not")
    func av1ProfileFromAV1C() {
        // marker|version 0x81, then seq_profile (3 bits) | seq_level_idx_0 (5 bits), flags, reserved.
        let main10 = [UInt8]([0x81, 0x08, 0x4C, 0x00])      // profile 0, high_bitdepth
        let high444 = [UInt8]([0x81, 0x28, 0x00, 0x00])     // profile 1
        let pro12bit = [UInt8]([0x81, 0x48, 0x60, 0x00])    // profile 2, high_bitdepth + twelve_bit
        #expect(VideoRoutingPolicy.av1FitsHardwareDecoder(av1C: main10, codecparProfile: -99))
        #expect(!VideoRoutingPolicy.av1FitsHardwareDecoder(av1C: high444, codecparProfile: -99))
        #expect(!VideoRoutingPolicy.av1FitsHardwareDecoder(av1C: pro12bit, codecparProfile: -99))
    }

    @Test("without an av1C the codecpar profile decides, and unknown keeps the native route")
    func av1ProfileFallback() {
        #expect(VideoRoutingPolicy.av1FitsHardwareDecoder(av1C: nil, codecparProfile: 0))
        #expect(!VideoRoutingPolicy.av1FitsHardwareDecoder(av1C: nil, codecparProfile: 1))
        #expect(!VideoRoutingPolicy.av1FitsHardwareDecoder(av1C: [], codecparProfile: 2))
        #expect(VideoRoutingPolicy.av1FitsHardwareDecoder(av1C: nil, codecparProfile: -99))
    }

    // MARK: - #176 DV Profile 5 bypasses the VT probe gate

    @Test("HEVC DV P5 stays native even when the raw-hvcC probe says undecodable")
    func dvProfile5StaysNative() {
        #expect(!VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 5, canHardwareDecode: { false }))
    }

    @Test("HEVC DV P5 never runs the VT probe")
    func dvProfile5SkipsProbe() {
        var probed = false
        _ = VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 5, canHardwareDecode: { probed = true; return false })
        #expect(!probed)
    }

    @Test("HEVC DV P7 / P8 keep the gate (base layer is standard Main10)")
    func dvProfile78KeepGate() {
        for profile in [7, 8] {
            #expect(VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
                codecID: AV_CODEC_ID_HEVC, dvProfile: profile, canHardwareDecode: { false }))
            #expect(!VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
                codecID: AV_CODEC_ID_HEVC, dvProfile: profile, canHardwareDecode: { true }))
        }
    }

    @Test("H.264 with DV side-data keeps the gate (P5 is HEVC-only)")
    func h264DVKeepsGate() {
        #expect(VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_H264, dvProfile: 5, canHardwareDecode: { false }))
    }

    // MARK: - #176 follow-up: IPT-only DV is unrepresentable on the software path

    @Test("AV1 DV P10.0 (no base layer) is unrepresentable in software")
    func av1Profile100Unrepresentable() {
        #expect(VideoRoutingPolicy.softwarePathCannotRepresent(
            codecID: AV_CODEC_ID_AV1, dvProfile: 10, dvBlCompatID: 0))
    }

    @Test("AV1 DV P10.1 / P10.2 / P10.4 stay software-eligible (compatible base layer)")
    func av1Profile10CompatBaseEligible() {
        for compat in [1, 2, 4] {
            #expect(!VideoRoutingPolicy.softwarePathCannotRepresent(
                codecID: AV_CODEC_ID_AV1, dvProfile: 10, dvBlCompatID: compat))
        }
    }

    @Test("HEVC DV P5 is unrepresentable in software (forward-only escape hatch)")
    func hevcProfile5Unrepresentable() {
        #expect(VideoRoutingPolicy.softwarePathCannotRepresent(
            codecID: AV_CODEC_ID_HEVC, dvProfile: 5, dvBlCompatID: 0))
    }

    @Test("HEVC DV P7 / P8 and non-DV streams stay software-eligible")
    func hevcOtherProfilesEligible() {
        for profile in [7, 8] {
            #expect(!VideoRoutingPolicy.softwarePathCannotRepresent(
                codecID: AV_CODEC_ID_HEVC, dvProfile: profile, dvBlCompatID: 1))
        }
        #expect(!VideoRoutingPolicy.softwarePathCannotRepresent(
            codecID: AV_CODEC_ID_HEVC, dvProfile: nil, dvBlCompatID: nil))
        #expect(!VideoRoutingPolicy.softwarePathCannotRepresent(
            codecID: AV_CODEC_ID_AV1, dvProfile: nil, dvBlCompatID: nil))
    }

    @Test("non-DV-capable codecs never trip the unrepresentable check")
    func otherCodecsNeverUnrepresentable() {
        for codec in [AV_CODEC_ID_H264, AV_CODEC_ID_VP9, AV_CODEC_ID_MPEG2VIDEO] {
            #expect(!VideoRoutingPolicy.softwarePathCannotRepresent(
                codecID: codec, dvProfile: 10, dvBlCompatID: 0))
        }
    }

    // MARK: - Profile 7 dual-layer routing & hardware capability gate

    @Test("HEVC DV P7 routes to software for dual-layer Metal reconstruction when HW decode confirmed")
    func dvProfile7RoutesToSoftwareWithHardwareDecode() {
        #expect(VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC,
            fieldOrder: AV_FIELD_PROGRESSIVE,
            av1Available: true,
            dvProfile: 7,
            dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: true,
            canHardwareDecode: { true },
            elType: "FEL"
        ) == DualLayerRouteDecision.isBuiltIn)
    }

    @Test("the el_type probe is only wanted when its answer can change the route")
    func enhancementLayerProbeIsGated() {
        func wanted(codec: AVCodecID = AV_CODEC_ID_HEVC, profile: Int? = 7,
                    handling: DolbyVisionHandling = .automatic, prefer: Bool = true,
                    hardware: (() -> Bool)? = { true }) -> Bool {
            VideoRoutingPolicy.dualLayerRouteIsWanted(
                codecID: codec, dvProfile: profile, dolbyVisionHandling: handling,
                preferDualLayerDolbyVision: prefer, canHardwareDecode: hardware)
        }
        #expect(wanted() == DualLayerRouteDecision.isBuiltIn)
        #expect(!wanted(prefer: false), "not opted in: no probe")
        #expect(!wanted(handling: .baseLayerOnly))
        #expect(!wanted(hardware: { false }), "no proven hardware session: the host would not compose")
        #expect(!wanted(profile: 8))
        #expect(!wanted(profile: nil))
        #expect(!wanted(codec: AV_CODEC_ID_H264))
        // The probe's gate and the routing decision share one predicate: FEL routes exactly when it holds.
        for prefer in [true, false] {
            let routes = VideoRoutingPolicy.requiresSoftwarePath(
                codecID: AV_CODEC_ID_HEVC, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true,
                dvProfile: 7, preferDualLayerDolbyVision: prefer, canHardwareDecode: { true }, elType: "FEL")
            #expect(routes == wanted(prefer: prefer))
        }
    }

    @Test("HEVC DV P7 FEL stays native when the caller does not opt in")
    func dvProfile7FelStaysNativeByDefault() {
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC,
            fieldOrder: AV_FIELD_PROGRESSIVE,
            av1Available: true,
            dvProfile: 7,
            canHardwareDecode: { true },
            elType: "FEL"
        ))
    }

    @Test("HEVC DV P7 stays native when preferDualLayerDolbyVision is disabled")
    func dvProfile7StaysNativeWhenPreferDualLayerDisabled() {
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC,
            fieldOrder: AV_FIELD_PROGRESSIVE,
            av1Available: true,
            dvProfile: 7,
            dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: false,
            canHardwareDecode: { true },
            elType: "FEL"
        ))
    }

    @Test("HEVC DV P7 stays native when hardware decode is unsupported")
    func dvProfile7StaysNativeWhenHardwareUnsupported() {
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC,
            fieldOrder: AV_FIELD_PROGRESSIVE,
            av1Available: true,
            dvProfile: 7,
            dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: true,
            canHardwareDecode: { false },
            elType: "FEL"
        ))
    }

    @Test("HEVC DV P7 FEL stays native when the hardware probe is unclassifiable")
    func dvProfile7StaysNativeWhenProbeUnclassifiable() throws {
        // No extradata: the probe has nothing to judge, so the verdict is .unclassifiable. The
        // permissive gate keeps native for that; the strict one the FEL route uses must say no,
        // because SoftwarePlaybackHost would give such a stream to libavcodec.
        let par = try #require(avcodec_parameters_alloc())
        defer { var p: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&p) }
        par.pointee.codec_id = AV_CODEC_ID_HEVC
        par.pointee.width = 3840
        par.pointee.height = 2160
        guard case .unclassifiable = VTCapabilityProbe.hardwareDecodeVerdict(codecpar: par) else {
            Issue.record("expected an unclassifiable verdict for a config record without extradata")
            return
        }
        #expect(VTCapabilityProbe.canHardwareDecode(codecpar: par))
        #expect(!VTCapabilityProbe.opensHardwareDecoder(codecpar: par))
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC,
            fieldOrder: AV_FIELD_PROGRESSIVE,
            av1Available: true,
            dvProfile: 7,
            dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: true,
            canHardwareDecode: { VTCapabilityProbe.opensHardwareDecoder(codecpar: par) },
            elType: "FEL"
        ))
    }

    @Test("HEVC DV P7 stays native when dolbyVisionHandling is baseLayerOnly")
    func dvProfile7StaysNativeWhenBaseLayerOnly() {
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC,
            fieldOrder: AV_FIELD_PROGRESSIVE,
            av1Available: true,
            dvProfile: 7,
            dolbyVisionHandling: .baseLayerOnly,
            preferDualLayerDolbyVision: true,
            canHardwareDecode: { true },
            elType: "FEL"
        ))
    }

    // MARK: - Profile 7 FEL vs MEL routing

    @Test("Profile 7 FEL / MEL table-driven routing matrix (dolby-vision-fel.md §5.2)")
    func profile7RoutingMatrix() {
        struct TestCase {
            let elType: String?
            let handling: DolbyVisionHandling
            let preferDualLayer: Bool
            let canHardwareDecode: Bool
            let expectedSoftware: Bool
        }

        let elTypes: [String?] = ["FEL", "MEL", nil]
        let handlings: [DolbyVisionHandling] = [.automatic, .baseLayerOnly]
        let preferOptions = [true, false]
        let hwOptions = [true, false]

        var cases: [TestCase] = []
        for el in elTypes {
            for handling in handlings {
                for prefer in preferOptions {
                    for hw in hwOptions {
                        // Section 5.2 table:
                        // P7 FEL + .automatic + preferDualLayerDolbyVision (true) + HW decode -> software host,
                        // in a build with the DualLayerDolbyVision trait. All other combinations -> native (false)
                        let expected = DualLayerRouteDecision.isBuiltIn
                            && el == "FEL"
                            && handling == .automatic
                            && prefer
                            && hw
                        cases.append(TestCase(
                            elType: el,
                            handling: handling,
                            preferDualLayer: prefer,
                            canHardwareDecode: hw,
                            expectedSoftware: expected
                        ))
                    }
                }
            }
        }

        #expect(cases.count == 24)

        for c in cases {
            let actual = VideoRoutingPolicy.requiresSoftwarePath(
                codecID: AV_CODEC_ID_HEVC,
                fieldOrder: AV_FIELD_PROGRESSIVE,
                av1Available: true,
                dvProfile: 7,
                dolbyVisionHandling: c.handling,
                preferDualLayerDolbyVision: c.preferDualLayer,
                canHardwareDecode: { c.canHardwareDecode },
                elType: c.elType
            )
            #expect(
                actual == c.expectedSoftware,
                "Failed for elType=\(String(describing: c.elType)), handling=\(c.handling), prefer=\(c.preferDualLayer), hw=\(c.canHardwareDecode): expected \(c.expectedSoftware), got \(actual)"
            )
        }
    }

    @Test("Profile 7 FEL routes to software when HW decode and dual-layer preferred")
    func felRoutesToSoftware() {
        #expect(VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC,
            fieldOrder: AV_FIELD_PROGRESSIVE,
            av1Available: true,
            dvProfile: 7,
            dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: true,
            canHardwareDecode: { true },
            elType: "FEL"
        ) == DualLayerRouteDecision.isBuiltIn)
    }

    @Test("Profile 7 MEL stays native regardless of preferences")
    func melStaysNativeAlways() {
        // All combinations: each dolbyVisionHandling, preferDualLayerDolbyVision, hardware avail
        for handling in [DolbyVisionHandling.automatic, .baseLayerOnly] {
            for prefer in [true, false] {
                for hardware in [true, false] {
                    #expect(!VideoRoutingPolicy.requiresSoftwarePath(
                        codecID: AV_CODEC_ID_HEVC,
                        fieldOrder: AV_FIELD_PROGRESSIVE,
                        av1Available: true,
                        dvProfile: 7,
                        dolbyVisionHandling: handling,
                        preferDualLayerDolbyVision: prefer,
                        canHardwareDecode: { hardware },
                        elType: "MEL"
                    ),
                    "MEL should stay native with handling=\(handling), prefer=\(prefer), hw=\(hardware)")
                }
            }
        }
    }

    @Test("Profile 7 MEL ignores dolbyVisionHandling and prefer settings")
    func melIgnoresOptions() {
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC,
            fieldOrder: AV_FIELD_PROGRESSIVE,
            av1Available: true,
            dvProfile: 7,
            dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: true,
            canHardwareDecode: { true },
            elType: "MEL"
        ))
    }

    @Test("Profile 7 no el_type stays native (docs §5.2: only explicit FEL routes software)")
    func noElTypeStaysNative() {
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC,
            fieldOrder: AV_FIELD_PROGRESSIVE,
            av1Available: true,
            dvProfile: 7,
            dolbyVisionHandling: .automatic,
            preferDualLayerDolbyVision: true,
            canHardwareDecode: { true },
            elType: nil
        ))
    }
}
