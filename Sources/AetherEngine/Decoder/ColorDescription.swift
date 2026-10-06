import Foundation
import AetherLibavutil
import AetherLibavcodec

/// A stream's colour description, held in one place because it arrives from two (AE#499).
///
/// A decoded `AVFrame` carries what the BITSTREAM declared: libavcodec writes the VUI, and a VUI that
/// says nothing leaves the fields `unspecified` rather than falling back to anything. `AVCodecParameters`
/// carries what the CONTAINER declared (Matroska's Colour element, MP4's `colr`), which for a remux is
/// routinely the only place the description exists at all. Neither is authoritative alone, and reading
/// one where the other was meant is what made an HDR still lose its tone map: the extractor gated on
/// `codecpar` (PQ) and handed zscale the frame (unspecified), and zimg has no path to linear from
/// nothing.
///
/// Same shape as `SoftwareVideoDecoder.declaredStreamSAR(bitstream:container:)`, and for the same
/// reason: two declarations of one fact, resolved once so every consumer sees the same answer.
struct ColorDescription: Equatable {
    var primaries: AVColorPrimaries
    var transfer: AVColorTransferCharacteristic
    var matrix: AVColorSpace
    var range: AVColorRange

    static let unspecified = ColorDescription(
        primaries: AVCOL_PRI_UNSPECIFIED,
        transfer: AVCOL_TRC_UNSPECIFIED,
        matrix: AVCOL_SPC_UNSPECIFIED,
        range: AVCOL_RANGE_UNSPECIFIED)

    init(primaries: AVColorPrimaries,
         transfer: AVColorTransferCharacteristic,
         matrix: AVColorSpace,
         range: AVColorRange) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.range = range
    }

    init(frame: UnsafePointer<AVFrame>) {
        self.init(primaries: frame.pointee.color_primaries,
                  transfer: frame.pointee.color_trc,
                  matrix: frame.pointee.colorspace,
                  range: frame.pointee.color_range)
    }

    init(codecpar: UnsafePointer<AVCodecParameters>) {
        self.init(primaries: codecpar.pointee.color_primaries,
                  transfer: codecpar.pointee.color_trc,
                  matrix: codecpar.pointee.color_space,
                  range: codecpar.pointee.color_range)
    }

    /// [MovieClaw P60] What the parameter sets in `extradata` declare, read by opening the decoder without
    /// feeding it a packet: libavcodec's HEVC decoder exports the first SPS's VUI colour at init
    /// (`hevc_decode_extradata`), which demuxing never copies into codecpar. That is the shape of an
    /// MKV whose Colour element names only the matrix while the VUI says PQ. Nil when no decoder opens.
    static func parameterSets(codecpar: UnsafePointer<AVCodecParameters>) -> ColorDescription? {
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else { return nil }
        var ctx = avcodec_alloc_context3(codec)
        guard let c = ctx else { return nil }
        defer { avcodec_free_context(&ctx) }
        guard avcodec_parameters_to_context(c, codecpar) >= 0 else { return nil }
        c.pointee.thread_count = 1
        guard avcodec_open2(c, codec, nil) >= 0 else { return nil }
        return ColorDescription(primaries: c.pointee.color_primaries, transfer: c.pointee.color_trc,
                                matrix: c.pointee.colorspace, range: c.pointee.color_range)
    }

    /// The description to act on: the bitstream wherever it committed to a value, the container for the
    /// fields it left open. Per field, because a partially filled VUI is the common case and the one
    /// that fails silently (a matrix without a transfer reads HDR to a gate and reads nothing to zimg).
    /// Two silences stay silent: an untagged stream is not improved by inventing BT.709 for it here.
    /// The BT.709 a display needs is chosen where the buffer meets CoreVideo, see
    /// `ColorAttachments.presented` (AE#654), so the HDR gate and the tone mapper still see the gap.
    static func resolved(bitstream: ColorDescription, container: ColorDescription) -> ColorDescription {
        ColorDescription(
            primaries: bitstream.primaries == AVCOL_PRI_UNSPECIFIED ? container.primaries : bitstream.primaries,
            transfer: bitstream.transfer == AVCOL_TRC_UNSPECIFIED ? container.transfer : bitstream.transfer,
            matrix: bitstream.matrix == AVCOL_SPC_UNSPECIFIED ? container.matrix : bitstream.matrix,
            range: bitstream.range == AVCOL_RANGE_UNSPECIFIED ? container.range : bitstream.range)
    }

    /// Write the resolved description back onto a freshly decoded frame, so every consumer downstream
    /// (tone mapper, sws conversion, DV still converter, CoreVideo attachments) reads one answer instead
    /// of each picking a source. Returns whether anything was filled in, which is also what makes it
    /// safe to call per frame: the second pass over an already complete frame is a comparison and no
    /// write.
    @discardableResult
    static func backfill(frame: UnsafeMutablePointer<AVFrame>, container: ColorDescription) -> Bool {
        let current = ColorDescription(frame: frame)
        let resolved = resolved(bitstream: current, container: container)
        guard resolved != current else { return false }
        frame.pointee.color_primaries = resolved.primaries
        frame.pointee.color_trc = resolved.transfer
        frame.pointee.colorspace = resolved.matrix
        frame.pointee.color_range = resolved.range
        return true
    }
}
