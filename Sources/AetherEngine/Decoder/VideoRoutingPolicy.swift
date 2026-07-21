import Libavcodec

/// Pure codec-and-field-order routing decision extracted from AetherEngine.load's dispatch so it is
/// unit-testable. Mirrors the historical switch (AV1 gated on HW, VP9/VP8/MPEG4/MPEG2/VC1 always
/// software) and adds the #107 rule: interlaced H.264 goes software so DeinterlaceFilter (bwdif) can
/// deinterlace it. tvOS AVPlayer does not deinterlace, so 1080i broadcast otherwise combs.
enum VideoRoutingPolicy {

    /// Field orders that indicate interlaced content warranting software deinterlacing.
    static let interlacedFieldOrders: Set<AVFieldOrder> = [
        AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT
    ]

    /// True when a video codec must use the software decode path (SoftwarePlaybackHost) instead of
    /// native AVPlayer. `av1Available` is `VTCapabilityProbe.av1Available` (HW AV1 decode support).
    /// #150: `spsIndicatesInterlaced` (SPS frame_mbs_only_flag == 0) breaks the tie when the demuxer's
    /// field_order probe stays UNKNOWN; a concrete PROGRESSIVE probe analyzed actual frames and wins.
    /// A false positive only costs an unnecessary SW decode (deint=interlaced passes progressive
    /// frames through untouched), never a wrong deinterlace.
    static func requiresSoftwarePath(
        codecID: AVCodecID,
        fieldOrder: AVFieldOrder,
        av1Available: Bool,
        spsIndicatesInterlaced: Bool = false
    ) -> Bool {
        switch codecID {
        case AV_CODEC_ID_AV1:
            return !av1Available
        case AV_CODEC_ID_VP9, AV_CODEC_ID_VP8, AV_CODEC_ID_MPEG4,
             AV_CODEC_ID_MPEG2VIDEO, AV_CODEC_ID_VC1:
            return true
        case AV_CODEC_ID_H264:
            if interlacedFieldOrders.contains(fieldOrder) { return true }
            return fieldOrder == AV_FIELD_UNKNOWN && spsIndicatesInterlaced
        default:
            return false
        }
    }

    /// #150: pure extradata classifier feeding `spsIndicatesInterlaced`. Accepts Annex-B (MPEG-TS) and
    /// avcC (MP4/MKV) extradata; anything unparseable classifies as not-interlaced so a missing or
    /// malformed config never forces the software path.
    static func spsIndicatesInterlaced(extradata: [UInt8]) -> Bool {
        guard let sps = H264SPS.spsNAL(fromExtradata: extradata) else { return false }
        return H264SPS.frameMbsOnly(fromNAL: sps) == false
    }

    /// Second-stage gate (#2): a codec that passed `requiresSoftwarePath` as native (H.264 / HEVC) but whose
    /// specific format VideoToolbox cannot HARDWARE-decode must still fall back to software, or the native
    /// AVPlayer path reaches readyToPlay and then renders nothing (H.264 High 4:2:2/4:4:4/High-10, HEVC Rext
    /// on Intel Macs / older Apple TV). Pure so it is unit-testable; the impure VT probe
    /// (`VTCapabilityProbe.canHardwareDecode`) is injected as the `canHardwareDecode` closure and only runs
    /// when the gate actually consults it. Only H.264 / HEVC consult this gate; AV1 / VP9 / etc. already
    /// have their own routing above and must not be reclassified here.
    ///
    /// #176: HEVC DV Profile 5 bypasses the gate entirely. The probe builds a plain-HEVC format description
    /// from the raw hvcC, which is not what the native path plays (dvh1 + dvcC, decoded by Apple's DV
    /// decoder), so a probe rejection there is not evidence the dvh1 route fails. And P5 has no compatible
    /// base layer: libavcodec decodes its IPT-PQ-c2 signal as YCbCr (green/purple cast), so the software
    /// path is never a correct fallback for it. P7 / P8.x keep the gate; their base layer is standard
    /// Main10 that the software path decodes with correct color.
    static func forcesSoftwareForUndecodableFormat(
        codecID: AVCodecID,
        dvProfile: Int?,
        canHardwareDecode: () -> Bool
    ) -> Bool {
        switch codecID {
        case AV_CODEC_ID_HEVC where dvProfile == 5:
            return false
        case AV_CODEC_ID_H264, AV_CODEC_ID_HEVC:
            return !canHardwareDecode()
        default:
            return false
        }
    }
}
