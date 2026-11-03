#if DualLayerDolbyVision
import CoreVideo
import Foundation

/// The chroma sampling of a composed Dolby Vision frame.
///
/// The composition is defined on the 4:2:0 sites, where the base layer's chroma sits: the luma it reads
/// is aligned to those sites. So 4:2:0 is the composer's native output, and 4:2:2 and 4:4:4 are that
/// composition stepped up by co-sited means (a copy on a site, the mean of the sites either side between
/// them). 4:2:0 is the default and what playback outputs. The other two are chosen only by the
/// `AETHER_FEL_CHROMA` experiment switch, which playback reads too, so set it deliberately.
enum DoviFelChromaFormat: String, CaseIterable, Sendable {
    case yuv420 = "420"
    case yuv422 = "422"
    case yuv444 = "444"

    /// The 10-bit biplanar video-range layout the composed picture is written in.
    var pixelFormat: OSType {
        switch self {
        case .yuv420: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .yuv422: return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case .yuv444: return kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        }
    }

    /// The chroma plane's size for a luma plane of `width` x `height`. Odd sizes round up.
    func chromaSize(width: Int, height: Int) -> (width: Int, height: Int) {
        switch self {
        case .yuv420: return ((width + 1) / 2, (height + 1) / 2)
        case .yuv422: return ((width + 1) / 2, height)
        case .yuv444: return (width, height)
        }
    }

    /// The format an `AETHER_FEL_CHROMA` value names (`420`, `422` or `444`). Anything else, and no value,
    /// is 4:2:0.
    static func from(environmentValue: String?) -> DoviFelChromaFormat {
        environmentValue.flatMap { DoviFelChromaFormat(rawValue: $0.trimmingCharacters(in: .whitespaces)) } ?? .yuv420
    }

    /// The format a composer starts with: `AETHER_FEL_CHROMA` when set, 4:2:0 otherwise.
    static var fromEnvironment: DoviFelChromaFormat {
        from(environmentValue: ProcessInfo.processInfo.environment["AETHER_FEL_CHROMA"])
    }
}
#endif
