import CoreGraphics
import Foundation

/// Where the picture sits inside a decoded frame whose raster may carry black bars painted into it
/// (a 2.39 film delivered as a 16:9 file, a 4:3 show pillarboxed into 16:9).
///
/// `rect` is normalized to the frame, 0...1 on both axes, origin top-left, so it holds for any size
/// the same frame is shown at. `snappedRatio` names the cinema ratio the measurement was rounded to,
/// nil when it was kept as measured.
public struct PictureArea: Sendable, Equatable, Codable {
    public var rect: CGRect
    public var snappedRatio: Double?

    public init(rect: CGRect, snappedRatio: Double? = nil) {
        self.rect = rect
        self.snappedRatio = snappedRatio
    }

    public static let fullFrame = PictureArea(rect: CGRect(x: 0, y: 0, width: 1, height: 1))

    static let fullFrameTolerance: CGFloat = 0.005

    public var isFullFrame: Bool {
        let t = Self.fullFrameTolerance
        return rect.minX <= t && rect.minY <= t && rect.maxX >= 1 - t && rect.maxY >= 1 - t
    }
}
