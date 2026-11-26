import CoreVideo

/// Where the chroma samples of a 4:2:0 buffer sit, from its `kCVImageBufferChromaLocationTopFieldKey` tag:
/// the offset of each chroma sample from the top-left luma sample of its 2x2 block, in luma samples.
///
/// An untagged or unrecognised buffer counts as left, the default of MPEG-2, H.264, HEVC and VC-1 (libplacebo
/// and FFmpeg read it the same way). The scalers read the chroma at this position and write it back at the
/// same position, because every output buffer keeps the input's tag.
struct ChromaSiting: Hashable, Sendable {
    /// 0 (on the left luma column), 0.5 (between the two) or 1.
    let x: Float
    /// 0 (on the top luma row), 0.5 (between the two) or 1.
    let y: Float

    static let left = ChromaSiting(x: 0, y: 0.5)
    static let center = ChromaSiting(x: 0.5, y: 0.5)
    static let topLeft = ChromaSiting(x: 0, y: 0)
    static let top = ChromaSiting(x: 0.5, y: 0)
    static let bottomLeft = ChromaSiting(x: 0, y: 1)
    static let bottom = ChromaSiting(x: 0.5, y: 1)

    static func of(_ buffer: CVPixelBuffer) -> ChromaSiting {
        guard let tag = CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
        else { return .left }
        let tags: [(CFString, ChromaSiting)] = [
            (kCVImageBufferChromaLocation_Center, .center), (kCVImageBufferChromaLocation_TopLeft, .topLeft),
            (kCVImageBufferChromaLocation_Top, .top), (kCVImageBufferChromaLocation_BottomLeft, .bottomLeft),
            (kCVImageBufferChromaLocation_Bottom, .bottom),
        ]
        return tags.first { $0.0 as String == tag }?.1 ?? .left
    }

    /// How far the chroma samples sit from where a plane scaled on its own puts them (centred in their
    /// block), in chroma samples. A plane scaler adds `offset * (ratio - 1)` to each output sample's source
    /// position (`LanczosTaps`), which keeps the chroma on the same spot of the picture.
    var chromaOffset: (x: Double, y: Double) {
        ((Double(x) - 0.5) / 2, (Double(y) - 0.5) / 2)
    }
}
