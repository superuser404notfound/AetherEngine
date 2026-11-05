import AetherLibavcodec

/// AE#983: how the source picture is scanned, from the same evidence the engine routes on.
public enum VideoScan: Sendable, Equatable {
    /// The probe gave no field order and nothing else settles it (the probe-free remote-HLS bypass,
    /// sources without video, codecs whose parser leaves the field order open).
    case unknown
    case progressive
    case interlaced(VideoFieldOrder)

    public var isInterlaced: Bool {
        if case .interlaced = self { return true }
        return false
    }
}

/// The field shown first. libavformat's coded-versus-displayed pairs (TB, BT) are folded into the
/// display order, which is the one a viewer means by "top field first".
public enum VideoFieldOrder: String, Sendable, Equatable {
    case topFieldFirst
    case bottomFieldFirst
    /// Interlaced by the H.264 SPS (`frame_mbs_only_flag` = 0) while the demuxer reported no order.
    case unknown
}

/// AE#983: the deinterlace graph in the software decoder's frame path, part of `DecodedVideoFormat`.
public struct VideoDeinterlace: Sendable, Equatable {
    /// The FFmpeg filter: `yadif_videotoolbox` (Metal), `bwdif`, or `yadif` on older linked builds.
    public let filter: String
    public let isHardware: Bool
    /// `.field` emits one frame per field (25i to 50p), `.frame` one per frame (25i to 25p). The
    /// software filter always runs `.frame`, whatever `LoadOptions.deinterlaceFieldRate` asks for.
    public let fieldRate: DeinterlaceFieldRate

    public init(filter: String, isHardware: Bool, fieldRate: DeinterlaceFieldRate) {
        self.filter = filter
        self.isHardware = isHardware
        self.fieldRate = fieldRate
    }

    /// Output frames per source frame: multiply `sourceVideoFrameRate` by it for the output rate.
    public var outputFramesPerSourceFrame: Int { fieldRate == .field ? 2 : 1 }
}

extension VideoScan {

    /// Pure resolution of the routing evidence. A clean #232 sample with no interlaced frame
    /// overrules the declaration (1080i25 carriage of progressive Blu-ray pictures plays as
    /// progressive); an inconclusive one leaves it standing, as it does for routing.
    static func resolve(
        codecID: AVCodecID,
        fieldOrder: AVFieldOrder,
        spsIndicatesInterlaced: Bool,
        frameSampleRefutesInterlace: Bool = false
    ) -> VideoScan {
        if frameSampleRefutesInterlace { return .progressive }
        switch fieldOrder {
        case AV_FIELD_PROGRESSIVE: return .progressive
        case AV_FIELD_TT, AV_FIELD_BT: return .interlaced(.topFieldFirst)
        case AV_FIELD_BB, AV_FIELD_TB: return .interlaced(.bottomFieldFirst)
        default: break
        }
        if spsIndicatesInterlaced { return .interlaced(.unknown) }
        switch codecID {
        // No field coding in these bitstreams, so an open field order cannot hide an interlaced one.
        case AV_CODEC_ID_AV1, AV_CODEC_ID_VP9, AV_CODEC_ID_VP8: return .progressive
        default: return .unknown
        }
    }
}
