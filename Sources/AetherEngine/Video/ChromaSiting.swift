import CoreVideo

/// Where the chroma samples of a 4:2:0 buffer sit, read from its chroma location tag. The value is the offset
/// of each chroma sample from the top-left luma sample of its 2x2 block, in luma samples.
///
/// An untagged or unrecognised buffer counts as left, the default of MPEG-2, H.264, HEVC and VC-1 (libplacebo
/// and FFmpeg read it the same way). The scalers read the chroma at this position and write it back at the
/// same position, because every output buffer keeps the input's tag. DV 4:2:0 puts Cb and Cr on different
/// rows, which one position cannot express, so it counts as left too.
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

    private static let tags: [(String, ChromaSiting)] = [
        (kCVImageBufferChromaLocation_Left as String, .left), (kCVImageBufferChromaLocation_Center as String, .center),
        (kCVImageBufferChromaLocation_TopLeft as String, .topLeft), (kCVImageBufferChromaLocation_Top as String, .top),
        (kCVImageBufferChromaLocation_BottomLeft as String, .bottomLeft),
        (kCVImageBufferChromaLocation_Bottom as String, .bottom),
    ]

    /// The top field's tag, else the bottom field's. A progressive frame carries the top one.
    static func of(_ buffer: CVPixelBuffer) -> ChromaSiting {
        let tag = CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
            ?? CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey, nil) as? String
        guard let tag else { return .left }
        return tags.first { $0.0 == tag }?.1 ?? .left
    }

    /// How far the chroma samples sit from where a plane scaled on its own puts them (centred in their
    /// block), in chroma samples. A plane scaler adds `offset * (ratio - 1)` to each output sample's source
    /// position (`LanczosTaps`), which keeps the chroma on the same spot of the picture.
    var chromaOffset: (x: Double, y: Double) {
        ((Double(x) - 0.5) / 2, (Double(y) - 0.5) / 2)
    }

    /// True for a buffer whose chroma planes are half the luma plane's size both ways.
    static func isFourTwoZero(_ buffer: CVPixelBuffer) -> Bool {
        let planes = CVPixelBufferGetPlaneCount(buffer)
        guard planes >= 2 else { return false }
        return CVPixelBufferGetWidthOfPlane(buffer, 1) < CVPixelBufferGetWidthOfPlane(buffer, 0)
            && CVPixelBufferGetHeightOfPlane(buffer, 1) < CVPixelBufferGetHeightOfPlane(buffer, 0)
    }

    /// Metal functions both shader libraries include, so the frame chain and the MetalFX conversion agree on
    /// the arithmetic. `siting` is (x, y).
    ///
    /// `chromaSitingSamplePos` is where luma sample `luma` reads the chroma plane, in its pixel coordinates.
    /// `chromaSitingWeight` is how much sample `k` of a 2x2 block (x = k & 1, y = k >> 1) counts in the
    /// block's chroma, which takes the block's RGB at the chroma sample's position. For centred chroma that
    /// is the mean. For a sample on a luma column or row it is a point sample on that axis, the exact
    /// inverse of the read in a same-size round trip. A [1, 2, 1] prefilter would need the neighbouring
    /// block, which the line-art output kernel does not have, and the chroma a scaler produces comes from
    /// the source's chroma plane, a quarter of the target width at 2x, so it holds little for it to remove.
    static let shaderSource = """
    inline float2 chromaSitingSamplePos(float2 luma, float2 siting) {
        return (luma - siting) * 0.5 + 0.5;
    }
    inline float chromaSitingWeight(float2 siting, uint k) {
        return ((k & 1) ? siting.x : 1.0 - siting.x) * ((k >> 1) ? siting.y : 1.0 - siting.y);
    }
    """
}
