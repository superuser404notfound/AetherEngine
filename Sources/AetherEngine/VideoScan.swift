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
    /// The FFmpeg filter: `bwdif_videotoolbox` or `yadif_videotoolbox` (Metal), `bwdif`, or `yadif`
    /// on older linked builds.
    public let filter: String
    public let isHardware: Bool
    /// `.field` emits one frame per field (25i to 50p), `.frame` one per frame (25i to 25p). The
    /// software filter always runs `.frame`, whatever `LoadOptions.deinterlaceFieldRate` asks for.
    public let fieldRate: DeinterlaceFieldRate
    /// #853: the graph matches fields back into film frames (`fieldmatch`) and drops the repeated
    /// frame of each five (`decimate`) around `filter`, which then only touches frames left combed
    /// (titles and credits made at video rate). The output runs at 4/5 of the source rate
    /// (29.97 to 23.976 fps) and `fieldRate` is `.frame`.
    public let inverseTelecine: Bool
    /// AE#1108: `fieldmatch` and `decimate` run on the GPU (`fieldmatch_videotoolbox`,
    /// `decimate_videotoolbox`) rather than on the CPU ahead of the upload. Only ever true together
    /// with `inverseTelecine` and `isHardware`. The output is the same either way, only the cost moves.
    public let inverseTelecineIsHardware: Bool

    public init(filter: String, isHardware: Bool, fieldRate: DeinterlaceFieldRate, inverseTelecine: Bool = false,
                inverseTelecineIsHardware: Bool = false) {
        self.filter = filter
        self.isHardware = isHardware
        self.fieldRate = fieldRate
        self.inverseTelecine = inverseTelecine
        self.inverseTelecineIsHardware = inverseTelecine && isHardware && inverseTelecineIsHardware
    }

    /// Frames the deinterlacer emits per frame it takes in. Under `inverseTelecine` the graph then
    /// keeps four of every five, so for the output rate use `outputFrameRateFactor`.
    public var outputFramesPerSourceFrame: Int { fieldRate == .field ? 2 : 1 }

    /// Multiply `sourceVideoFrameRate` by it for the rate the frames come out at: 2 at field rate,
    /// 1 at frame rate, 0.8 under inverse telecine.
    public var outputFrameRateFactor: Double { inverseTelecine ? 0.8 : Double(outputFramesPerSourceFrame) }
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
