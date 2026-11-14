import CoreVideo
import Foundation

/// The colour volume a frame chain stage's output fits in (AE#957). The chain writes the frame's HDR10
/// metadata from it, so a stage that changes the picture's brightness (a tone mapper to a target peak)
/// tells the display what it now gets, and the display does not tone map a second time.
enum FrameChainColorVolume: Equatable, Sendable {
    /// The stage keeps the picture's brightness and gamut: the source's own metadata still holds.
    case unchanged
    /// The stage's output fits this volume: the frames carry it as their HDR10 static metadata (PQ output).
    case hdr10(HDR10StaticMetadata)

    /// A chain's output volume from its stages' volumes in order: the last stage that declares one sets it,
    /// so a dither or LUT stage after a tone mapper keeps the tone mapper's volume.
    static func ofChain(_ stages: [FrameChainColorVolume]) -> FrameChainColorVolume {
        stages.last { $0 != .unchanged } ?? .unchanged
    }
}

/// What a chain's output buffer carries (AE#957): the input's attachments, minus the keys that describe
/// the input's geometry, then the HDR10 metadata of the chain's colour volume.
enum FrameChainOutputAttachments {
    /// Geometry and field keys describe the input buffer. The output is the picture region alone, so a
    /// clean aperture would crop it a second time.
    static let inputGeometryKeys: Set<String> = [
        kCVImageBufferCleanApertureKey as String, kCVImageBufferPreferredCleanApertureKey as String,
        kCVImageBufferFieldCountKey as String, kCVImageBufferFieldDetailKey as String,
        kCVImageBufferDisplayDimensionsKey as String,
    ]

    /// Replaces every attachment on `output`. With `.unchanged` the input's own HDR10 keys (or their
    /// absence) carry over; with `.hdr10` both keys are the declared values.
    static func carry(from input: CVPixelBuffer, to output: CVPixelBuffer, volume: FrameChainColorVolume) {
        CVBufferRemoveAllAttachments(output)
        if let attachments = CVBufferCopyAttachments(input, .shouldPropagate) as? [String: Any] {
            CVBufferSetAttachments(output, attachments.filter { !inputGeometryKeys.contains($0.key) } as CFDictionary,
                                   .shouldPropagate)
        }
        guard case .hdr10(let values) = volume else { return }
        CVBufferSetAttachment(output, kCVImageBufferMasteringDisplayColorVolumeKey,
                              values.masteringDisplayColorVolume as CFData, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferContentLightLevelInfoKey,
                              values.contentLightLevel as CFData, .shouldPropagate)
    }
}
