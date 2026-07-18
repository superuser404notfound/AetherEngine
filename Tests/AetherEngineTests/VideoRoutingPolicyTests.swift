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

    // MARK: - #2 undecodable-format second-stage gate

    @Test("H.264 / HEVC that VideoToolbox can't HW-decode falls back to software")
    func undecodableHEVCH264Software() {
        #expect(VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_H264, canHardwareDecode: false))
        #expect(VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_HEVC, canHardwareDecode: false))
    }

    @Test("HW-decodable H.264 / HEVC stays native (no Apple Silicon regression)")
    func decodableHEVCH264Native() {
        #expect(!VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_H264, canHardwareDecode: true))
        #expect(!VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
            codecID: AV_CODEC_ID_HEVC, canHardwareDecode: true))
    }

    @Test("non-H.264/HEVC codecs ignore the undecodable gate (own policy governs them)")
    func otherCodecsIgnoreUndecodableGate() {
        // AV1 without HW is already routed software by requiresSoftwarePath; this gate must not double-handle
        // it, and must never reclassify VP9 / MPEG-2 / etc. off a codec they don't apply to.
        for codec in [AV_CODEC_ID_AV1, AV_CODEC_ID_VP9, AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VC1] {
            #expect(!VideoRoutingPolicy.forcesSoftwareForUndecodableFormat(
                codecID: codec, canHardwareDecode: false))
        }
    }
}
