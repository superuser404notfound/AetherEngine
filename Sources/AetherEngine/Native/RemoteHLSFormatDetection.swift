import CoreMedia
import CoreVideo

/// AetherEngine#168: dynamic-range classification for the `nativeRemoteHLS` bypass. That path hands the
/// m3u8 straight to AVPlayer and runs no libav probe, so `videoFormat` used to stay at its `.sdr` default
/// (the reporter saw `fmt=sdr` on an HDR10 4K50 stream). Instead of reopening the origin a second time
/// (a real cost against per-token IPTV origins), the dynamic range is read back from AVPlayer's already
/// parsed video-track `CMFormatDescription` at readyToPlay. This is the pure classifier feeding that read.
enum RemoteHLSFormatDetection {

    /// Dolby Vision video sample types. A DV track carries a PQ base transfer, so the subtype must be
    /// consulted before the transfer function or the badge would read HDR10.
    static let dvh1: FourCharCode = 0x64766831 // 'dvh1'
    static let dvhe: FourCharCode = 0x64766865 // 'dvhe'

    /// Map the color transfer function (and video sample type for DV) to a `VideoFormat`.
    /// `transferFunction` is the `kCMFormatDescriptionExtension_TransferFunction` value read as a String;
    /// nil / unrecognized values classify as `.sdr` so a missing or future signal never mislabels a source.
    /// HDR10+ cannot be distinguished from HDR10 without per-frame ST 2094-40 metadata, so PQ maps to
    /// `.hdr10` (the base badge); the per-frame refinement stays on the loopback path's SEI tap.
    static func videoFormat(transferFunction: String?, videoSubType: FourCharCode?) -> VideoFormat {
        if let videoSubType, videoSubType == dvh1 || videoSubType == dvhe {
            return .dolbyVision
        }
        guard let transferFunction else { return .sdr }
        if transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String {
            return .hdr10
        }
        if transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
            return .hlg
        }
        return .sdr
    }

    /// Whether the nativeRemoteHLS bypass should program `preferredDisplayCriteria` for a detected format.
    /// Only an HDR range needs the panel switch that lets AVPlayer present HDR at all; SDR is presented in
    /// any panel mode, and a sole-writer host (`suppressDisplayCriteria`) is left untouched so the engine
    /// and the host never fight over the criteria. Pure so it is unit-testable.
    static func shouldApplyDisplayCriteria(format: VideoFormat, suppressDisplayCriteria: Bool) -> Bool {
        format != .sdr && !suppressDisplayCriteria
    }
}
