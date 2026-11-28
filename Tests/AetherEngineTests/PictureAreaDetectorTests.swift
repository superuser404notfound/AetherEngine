import CoreGraphics
import Foundation
import Testing
@testable import AetherEngine

/// Synthetic frames: black canvas, a noisy mid-grey picture region, optional grain in the bars.
enum SyntheticFrame {
    static func make(width: Int = 480, height: Int = 270,
                     picture: CGRect,
                     pictureLuma: Double = 0.45,
                     barNoise: Double = 0,
                     extra: [(rect: CGRect, luma: Double)] = []) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) & 0xFFFF) / 65535.0
        }
        func px(_ r: CGRect) -> (Int, Int, Int, Int) {
            (Int((r.minX * Double(width)).rounded()), Int((r.minY * Double(height)).rounded()),
             Int((r.maxX * Double(width)).rounded()), Int((r.maxY * Double(height)).rounded()))
        }
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = UInt8(min(255, max(0, barNoise * noise() * 255)))
            }
        }
        let (x0, y0, x1, y1) = px(picture)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let v = pictureLuma + (noise() - 0.5) * 0.3
                pixels[y * width + x] = UInt8(min(255, max(0, v * 255)))
            }
        }
        for e in extra {
            let (ex0, ey0, ex1, ey1) = px(e.rect)
            for y in ey0..<ey1 { for x in ex0..<ex1 { pixels[y * width + x] = UInt8(e.luma * 255) } }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Normalized rect of a centred picture of `ratio` inside a 16:9 frame.
    static func centred(ratio: Double, frameAspect: Double = 16.0 / 9.0) -> CGRect {
        if ratio > frameAspect {
            let h = frameAspect / ratio
            return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
        let w = ratio / frameAspect
        return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
    }
}

@Suite("Picture area detector")
struct PictureAreaDetectorTests {
    private static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    private func reading(_ picture: CGRect, barNoise: Double = 0,
                         extra: [(rect: CGRect, luma: Double)] = []) -> PictureAreaReading? {
        PictureAreaDetector.reading(of: SyntheticFrame.make(picture: picture, barNoise: barNoise, extra: extra))
    }

    @Test("a 2.39 picture in a 16:9 frame reads as its band", .timeLimit(.minutes(3)))
    func letterbox239In16x9() throws {
        let r = try #require(reading(SyntheticFrame.centred(ratio: 2.39)))
        #expect(abs(r.rect.height - 0.744) <= 0.01)
        #expect(abs(r.rect.midY - 0.5) <= 0.01)
        #expect(abs(r.rect.width - 1) <= 0.01)
    }

    @Test("a 4:3 picture in a 16:9 frame reads as its pillar", .timeLimit(.minutes(3)))
    func pillarbox4x3In16x9() throws {
        let r = try #require(reading(SyntheticFrame.centred(ratio: 4.0 / 3.0)))
        #expect(abs(r.rect.width - 0.75) <= 0.01)
        #expect(abs(r.rect.height - 1) <= 0.01)
    }

    @Test("a windowboxed picture is inset on both axes", .timeLimit(.minutes(3)))
    func windowbox() throws {
        let r = try #require(reading(CGRect(x: 0.1, y: 0.12, width: 0.8, height: 0.76)))
        #expect(abs(r.rect.minX - 0.1) <= 0.01)
        #expect(abs(r.rect.minY - 0.12) <= 0.01)
        #expect(abs(r.rect.width - 0.8) <= 0.01)
        #expect(abs(r.rect.height - 0.76) <= 0.01)
    }

    @Test("frames without bars combine to the full frame", .timeLimit(.minutes(3)))
    func noBarsIsFullFrame() throws {
        let r = try #require(reading(Self.full))
        let area = try #require(PictureAreaDetector.combine(Array(repeating: r, count: 5), displayAspect: 16.0 / 9.0))
        #expect(area.isFullFrame)
    }

    @Test("a dark scene is unusable, never a bar", .timeLimit(.minutes(3)))
    func darkSceneIsUnusable() {
        let image = SyntheticFrame.make(picture: Self.full, pictureLuma: 0.03)
        #expect(PictureAreaDetector.reading(of: image) == nil)
    }

    @Test("grain in the bars still reads as bar", .timeLimit(.minutes(3)))
    func grainInBarsStillBar() throws {
        let clean = try #require(reading(SyntheticFrame.centred(ratio: 2.39)))
        let grainy = try #require(reading(SyntheticFrame.centred(ratio: 2.39), barNoise: 0.05))
        #expect(abs(clean.rect.minY - grainy.rect.minY) <= 0.005)
        #expect(abs(clean.rect.maxY - grainy.rect.maxY) <= 0.005)
    }

    @Test("burned-in text in the bottom bar counts as picture", .timeLimit(.minutes(3)))
    func textInBarCountsAsPicture() throws {
        let band = SyntheticFrame.centred(ratio: 2.39)
        let text = CGRect(x: 0.4, y: band.maxY + 0.03, width: 0.2, height: 0.04)
        let r = try #require(reading(band, extra: [(text, 0.95)]))
        #expect(r.rect.maxY >= text.maxY - 0.005)
    }

    @Test("one full-frame passage keeps the union at full frame", .timeLimit(.minutes(3)))
    func unionKeepsImaxPassage() throws {
        let scope = try #require(reading(SyntheticFrame.centred(ratio: 2.39)))
        let imax = try #require(reading(Self.full))
        let area = try #require(PictureAreaDetector.combine(Array(repeating: scope, count: 8) + [imax],
                                                            displayAspect: 16.0 / 9.0))
        #expect(area.isFullFrame)
    }

    @Test("fewer than five usable frames give no answer", .timeLimit(.minutes(3)))
    func tooFewUsableIsNil() throws {
        let scope = try #require(reading(SyntheticFrame.centred(ratio: 2.39)))
        #expect(PictureAreaDetector.combine(Array(repeating: scope, count: 4), displayAspect: 16.0 / 9.0) == nil)
    }

    @Test("a measurement close to 2.39 snaps to it", .timeLimit(.minutes(3)))
    func snapsTo239() throws {
        let measured = PictureAreaReading(rect: CGRect(x: 0, y: 0.126, width: 1, height: 0.748))
        let area = try #require(PictureAreaDetector.combine(Array(repeating: measured, count: 5),
                                                            displayAspect: 16.0 / 9.0))
        #expect(area.snappedRatio == 2.39)
        #expect(abs(area.rect.height - (16.0 / 9.0) / 2.39) <= 0.0005)
        #expect(abs(area.rect.midY - 0.5) <= 0.0005)
    }

    @Test("snapping uses the display aspect, not the coded one", .timeLimit(.minutes(3)))
    func snapsUsingDisplayAspect() throws {
        // 720x576 at 64:45 presents as 1024x576; the same normalized band is 2.35 there and 1.65 coded.
        let measured = PictureAreaReading(rect: CGRect(x: 0, y: 0.122, width: 1, height: 0.756))
        let anamorphic = try #require(PictureAreaDetector.combine(Array(repeating: measured, count: 5),
                                                                  displayAspect: 1024.0 / 576.0))
        let coded = try #require(PictureAreaDetector.combine(Array(repeating: measured, count: 5),
                                                             displayAspect: 720.0 / 576.0))
        #expect(anamorphic.snappedRatio == 2.35)
        #expect(coded.snappedRatio != 2.35)
    }

    @Test("a ratio outside every snap tolerance keeps its measured rect", .timeLimit(.minutes(3)))
    func noSnapOutsideTolerance() throws {
        let h = (16.0 / 9.0) / 2.10
        let measured = PictureAreaReading(rect: CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h))
        let area = try #require(PictureAreaDetector.combine(Array(repeating: measured, count: 5),
                                                            displayAspect: 16.0 / 9.0))
        #expect(area.snappedRatio == nil)
        #expect(abs(area.rect.height - h) <= 0.0005)
    }

    @Test("snapping never cuts more than a sliver of measured picture", .timeLimit(.minutes(3)))
    func snapDoesNotCropInward() throws {
        // 2.33 is within 2 % of 2.35, but snapping would cut 0.65 % of the height.
        let h = (16.0 / 9.0) / 2.33
        let measured = PictureAreaReading(rect: CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h))
        let area = try #require(PictureAreaDetector.combine(Array(repeating: measured, count: 5),
                                                            displayAspect: 16.0 / 9.0))
        #expect(area.snappedRatio == nil)
        #expect(abs(area.rect.height - h) <= 0.0005)
    }
}
