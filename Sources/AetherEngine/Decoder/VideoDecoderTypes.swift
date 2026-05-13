import Foundation
import CoreMedia
import CoreVideo

/// Callback type for decoded video frames.
///
/// `hdr10PlusT35` carries the source-frame's HDR10+ dynamic metadata,
/// already serialised to the ITU-T T.35 byte format Apple's
/// `kCMSampleAttachmentKey_HDR10PlusPerFrameData` expects. Nil for
/// non-HDR10+ streams.
typealias DecodedFrameHandler = (CVPixelBuffer, CMTime, Data?) -> Void

enum VideoDecoderError: Error, LocalizedError {
    case noCodecParameters
    case unsupportedCodec(id: UInt32)
    case noExtradata
    case formatDescriptionFailed(status: OSStatus)
    case sessionCreationFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noCodecParameters: "No codec parameters"
        case .unsupportedCodec(let id): "Unsupported video codec (id: \(id))"
        case .noExtradata: "Missing codec extradata"
        case .formatDescriptionFailed(let s): "Format description failed (\(s))"
        case .sessionCreationFailed(let s): "Decoder session failed (\(s))"
        }
    }
}
