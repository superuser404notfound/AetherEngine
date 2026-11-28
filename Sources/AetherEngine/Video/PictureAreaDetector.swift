import CoreGraphics
import Foundation

/// The picture area one frame shows, normalized like `PictureArea.rect`.
public struct PictureAreaReading: Sendable, Equatable {
    public let rect: CGRect
    public init(rect: CGRect) { self.rect = rect }
}

/// Finds baked-in bars in decoded frames and combines many frames into one `PictureArea`.
///
/// Conservative on purpose (Sodalite#118). A frame that is mostly dark says nothing and is dropped,
/// never read as bars, and frames combine by UNION: one frame that shows picture in a band keeps that
/// band, so a film with IMAX passages or a single night scene can only end up zooming less.
public enum PictureAreaDetector {
    /// Luma under this (fraction of full scale) is black. Film grain and compression noise in a bar
    /// stay well under it.
    public static let darkThreshold: Double = 0.08
    /// A row or column is picture once more than this share of its pixels is above `darkThreshold`.
    /// Burned-in subtitle text in a bar passes it, which is intended: that text is content.
    public static let pictureShare: Double = 0.02
    /// A frame whose picture region averages under this is too dark to say where the picture ends.
    public static let minimumPictureLuma: Double = 0.06
    /// A found picture smaller than this share of either axis is implausible (a logo on black).
    public static let minimumPictureExtent: Double = 0.3
    public static let minimumUsableFrames = 5
    public static let snapTolerance: Double = 0.02
    /// How much of the measured picture a snap may cut, as a share of the cropped axis. About one row
    /// at the analysis height, which is the measurement's own error; more would crop real picture.
    public static let maximumInwardSnap: CGFloat = 0.005
    public static let snapRatios: [Double] = [4.0 / 3.0, 1.66, 1.78, 1.85, 2.00, 2.20, 2.35, 2.39, 2.40]
    /// Frames are measured at most this wide; enough to tell 1.85, 2.00 and 2.39 apart.
    public static let analysisWidth = 480

    public static func reading(of image: CGImage) -> PictureAreaReading? {
        guard let luma = GrayFrame(image: image, maxWidth: analysisWidth) else { return nil }
        let w = luma.width, h = luma.height
        let limit = UInt8(min(255, (darkThreshold * 255).rounded()))
        let rowNeed = Int(Double(w) * pictureShare)

        var top = -1, bottom = -1
        for y in 0..<h where luma.countAbove(limit, row: y) > rowNeed {
            if top < 0 { top = y }
            bottom = y
        }
        guard top >= 0 else { return nil }

        let colNeed = Int(Double(bottom - top + 1) * pictureShare)
        var left = -1, right = -1
        for x in 0..<w where luma.countAbove(limit, column: x, rows: top...bottom) > colNeed {
            if left < 0 { left = x }
            right = x
        }
        guard left >= 0 else { return nil }

        let rect = CGRect(x: Double(left) / Double(w), y: Double(top) / Double(h),
                          width: Double(right - left + 1) / Double(w),
                          height: Double(bottom - top + 1) / Double(h))
        guard rect.width >= minimumPictureExtent, rect.height >= minimumPictureExtent else { return nil }
        guard luma.mean(columns: left...right, rows: top...bottom) >= minimumPictureLuma else { return nil }
        return PictureAreaReading(rect: rect)
    }

    /// Union of the readings, snapped to a cinema ratio when one is within `snapTolerance`.
    /// `displayAspect` is the frame's PRESENTED aspect (pixel aspect applied), so an anamorphic
    /// source snaps against the shape it is shown at, not the shape it is coded at.
    public static func combine(_ readings: [PictureAreaReading], displayAspect: Double) -> PictureArea? {
        guard readings.count >= minimumUsableFrames, displayAspect > 0 else { return nil }
        var union = readings[0].rect
        for r in readings.dropFirst() { union = union.union(r.rect) }
        let area = PictureArea(rect: union)
        if area.isFullFrame { return .fullFrame }
        return snapped(area.rect, displayAspect: displayAspect)
    }

    static func snapped(_ rect: CGRect, displayAspect: Double) -> PictureArea {
        let measured = Double(rect.width) * displayAspect / Double(rect.height)
        guard let ratio = snapRatios.min(by: { abs($0 / measured - 1) < abs($1 / measured - 1) }),
              abs(ratio / measured - 1) <= snapTolerance else {
            return PictureArea(rect: rect)
        }
        let tol = PictureArea.fullFrameTolerance
        var out = rect
        if rect.height >= 1 - tol, rect.width < 1 - tol {
            let width = CGFloat(ratio) * rect.height / CGFloat(displayAspect)
            out = CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        } else {
            let height = rect.width * CGFloat(displayAspect) / CGFloat(ratio)
            out = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        }
        out = out.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        if rect.width - out.width > maximumInwardSnap || rect.height - out.height > maximumInwardSnap {
            return PictureArea(rect: rect)
        }
        return PictureArea(rect: out, snappedRatio: ratio)
    }
}

/// An 8-bit grey copy of a frame, drawn once so rows and columns can be scanned cheaply.
private struct GrayFrame {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init?(image: CGImage, maxWidth: Int) {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = min(1, Double(maxWidth) / Double(image.width))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        var buffer = [UInt8](repeating: 0, count: w * h)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        pixels = buffer
    }

    func countAbove(_ limit: UInt8, row y: Int) -> Int {
        var n = 0
        let base = y * width
        for x in 0..<width where pixels[base + x] > limit { n += 1 }
        return n
    }

    func countAbove(_ limit: UInt8, column x: Int, rows: ClosedRange<Int>) -> Int {
        var n = 0
        for y in rows where pixels[y * width + x] > limit { n += 1 }
        return n
    }

    func mean(columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> Double {
        var sum = 0
        for y in rows { for x in columns { sum += Int(pixels[y * width + x]) } }
        return Double(sum) / Double(columns.count * rows.count) / 255
    }
}
