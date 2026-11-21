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

// MARK: - AE#1103: a host-supplied reading of an untagged stream

extension ColorDescription {

    /// The description `LoadOptions.untaggedVideoColor` gives a stream, or nil when it does not apply.
    ///
    /// Only a stream that says nothing about primaries, transfer and matrix is touched; one field is
    /// enough to keep the stream's own word, so the option can sit on a whole library. Under 10 bit a
    /// PQ or HLG reading is a guess the stream contradicts by its depth, and a Dolby Vision stream is
    /// described by its record (a recordless Profile 5 has one by now, see `DolbyVisionRecordAudit`).
    /// The range is kept when declared and limited otherwise, which is what an HDR10 encode carries.
    static func assumed(
        _ assumption: UntaggedVideoColor, for declared: ColorDescription, bitDepth: Int, isDolbyVision: Bool
    ) -> ColorDescription? {
        let transfer: AVColorTransferCharacteristic
        switch assumption {
        case .standard: return nil
        case .hdr10: transfer = AVCOL_TRC_SMPTE2084
        case .hlg: transfer = AVCOL_TRC_ARIB_STD_B67
        }
        guard bitDepth >= 10, !isDolbyVision,
              declared.primaries == AVCOL_PRI_UNSPECIFIED,
              declared.transfer == AVCOL_TRC_UNSPECIFIED,
              declared.matrix == AVCOL_SPC_UNSPECIFIED else { return nil }
        return ColorDescription(
            primaries: AVCOL_PRI_BT2020, transfer: transfer, matrix: AVCOL_SPC_BT2020_NCL,
            range: declared.range == AVCOL_RANGE_UNSPECIFIED ? AVCOL_RANGE_MPEG : declared.range)
    }

    /// Bits per luma sample. The pixel format's when the probe resolved one, the container's figure
    /// otherwise, 0 when neither is known (which `assumed` treats as too shallow). `VideoStreamFormat`
    /// reports the same number, so the gate and the host never see two depths for one stream.
    static func bitDepth(pixelFormat: Int32, bitsPerRawSample: Int32) -> Int {
        if pixelFormat >= 0, let desc = av_pix_fmt_desc_get(AVPixelFormat(rawValue: pixelFormat)),
           desc.pointee.nb_components > 0 {
            return Int(desc.pointee.comp.0.depth)
        }
        return max(0, Int(bitsPerRawSample))
    }
}
