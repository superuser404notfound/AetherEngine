import CoreGraphics
import Foundation

/// The zoom behind a host's "Fill" when the picture does not fill its own raster (Sodalite#118).
///
/// The layer showing the video fills `bounds` and lays its content out `.resizeAspect`; `area` is the
/// part of the picture that should cover `bounds` (a `PictureArea.rect`, or the full frame for a plain
/// aspect fill). The transform scales about the centre of `bounds` and moves the area's centre there.
/// Coordinates are top-left based; `sublayerTransform(_:bounds:anchorPoint:yUp:)` adapts the result
/// to a layer with another anchor or a y-up geometry (a macOS view's backing layer).
public enum PictureFillGeometry {
    /// Scales at or below this, with no offset, count as no change (a 2.39 film on a 2.39 screen).
    public static let noChangeScale: CGFloat = 1.01

    /// Where the whole picture plane sits in `bounds` before any zoom: the aspect-fit rectangle.
    public static func fitPlane(presentationSize: CGSize, bounds: CGSize) -> CGRect? {
        guard presentationSize.width > 0, presentationSize.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / presentationSize.width, bounds.height / presentationSize.height)
        let w = presentationSize.width * scale, h = presentationSize.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    public static func coverTransform(presentationSize: CGSize, area: CGRect, bounds: CGSize) -> CGAffineTransform {
        guard let plane = fitPlane(presentationSize: presentationSize, bounds: bounds) else { return .identity }
        return coverTransform(plane: plane, area: area, bounds: bounds)
    }

    /// Same as above for a host that can read the fitted plane off its layer (`AVPlayerLayer.videoRect`).
    public static func coverTransform(plane: CGRect, area: CGRect, bounds: CGSize) -> CGAffineTransform {
        guard plane.width > 0, plane.height > 0, area.width > 0, area.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .identity }
        let onScreen = CGRect(x: plane.minX + area.minX * plane.width, y: plane.minY + area.minY * plane.height,
                              width: area.width * plane.width, height: area.height * plane.height)
        let s = max(bounds.width / onScreen.width, bounds.height / onScreen.height)
        let centre = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        return CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                 tx: -s * (onScreen.midX - centre.x), ty: -s * (onScreen.midY - centre.y))
    }

    /// Where the whole picture plane lands once `coverTransform` is applied. Overlays that place
    /// things against the picture (bitmap subtitles) lay out against this.
    public static func planeRect(presentationSize: CGSize, area: CGRect, bounds: CGSize) -> CGRect {
        guard let plane = fitPlane(presentationSize: presentationSize, bounds: bounds) else {
            return CGRect(origin: .zero, size: bounds)
        }
        let t = coverTransform(plane: plane, area: area, bounds: bounds)
        let c = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        return CGRect(x: c.x + t.a * (plane.minX - c.x) + t.tx, y: c.y + t.d * (plane.minY - c.y) + t.ty,
                      width: plane.width * t.a, height: plane.height * t.d)
    }

    public static func changesPicture(presentationSize: CGSize, area: CGRect, bounds: CGSize) -> Bool {
        let t = coverTransform(presentationSize: presentationSize, area: area, bounds: bounds)
        return t.a > noChangeScale || abs(t.tx) > 0.5 || abs(t.ty) > 0.5
    }

    /// `t` (about the centre, y down) re-expressed for a layer whose transforms apply about
    /// `anchorPoint` (unit coordinates) and whose y axis may point up.
    public static func sublayerTransform(_ t: CGAffineTransform, bounds: CGRect, anchorPoint: CGPoint,
                                         yUp: Bool) -> CGAffineTransform {
        let s = t.a
        let tx = t.tx, ty = yUp ? -t.ty : t.ty
        let a = CGPoint(x: bounds.minX + anchorPoint.x * bounds.width, y: bounds.minY + anchorPoint.y * bounds.height)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        return CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                 tx: (c.x - a.x) - s * (c.x - a.x) + tx,
                                 ty: (c.y - a.y) - s * (c.y - a.y) + ty)
    }
}
