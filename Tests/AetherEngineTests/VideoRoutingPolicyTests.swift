import Testing
import Libavcodec
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

    @Test("AV1 follows hardware availability")
    func av1FollowsHardware() {
        #expect(VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_AV1, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: false))
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_AV1, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true))
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

    @Test("non-H.264/HEVC codecs ignore the undecodable gate (own policy governs them)")
    func otherCodecsIgnoreUndecodableGate() {
        // AV1 without HW is already routed software by requiresSoftwarePath; this gate must not double-handle
        // it, and must never reclassify VP9 / MPEG-2 / etc. off a codec they don't apply to.
        for codec in [AV_CODEC_ID_AV1, AV_CODEC_ID_VP9, AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VC1] {
            #expect(!VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
                codecID: codec, dvProfile: nil, canHardwareDecode: { false }))
        }
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
}
