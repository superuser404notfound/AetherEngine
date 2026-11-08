import Foundation
import CoreGraphics
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#1006 (stehanOSX): on an HDR UHD Blu-ray the PGS palette is PQ-coded, and the engine published
/// it as sRGB, so the disc's ~294-nit white (158 after pgssubdec) showed as 62 % grey.
struct Issue1006PGSPQPaletteTests {

    @Test("the PQ EOTF hits the reference points")
    func eotf() {
        #expect(PQSubtitlePalette.nits(pq: 0) == 0)
        #expect(abs(PQSubtitlePalette.nits(pq: 1) - 10000) < 0.01)
        #expect(abs(PQSubtitlePalette.nits(pq: 0.5081) - 100) < 1)
        #expect(abs(PQSubtitlePalette.nits(pq: 158.0 / 255) - 294) < 5)
    }

    @Test("the reported grey ramp becomes a white glyph with a falling edge, neutral and ordered")
    func reportedRamp() {
        let fill = PQSubtitlePalette.sRGB(fromPQ: 158, 158, 158)
        let edge = PQSubtitlePalette.sRGB(fromPQ: 140, 140, 140)
        let aa = PQSubtitlePalette.sRGB(fromPQ: 115, 115, 115)
        let outline = PQSubtitlePalette.sRGB(fromPQ: 0, 0, 0)
        #expect(fill == (255, 255, 255))
        #expect(outline == (0, 0, 0))
        #expect(edge.r == edge.g && edge.g == edge.b)
        #expect(aa.r == aa.g && aa.g == aa.b)
        #expect(edge.r > 200 && edge.r < 255)
        #expect(aa.r > 115 && aa.r < edge.r)
    }

    @Test("a coloured entry keeps its hue")
    func yellowStaysYellow() {
        // BT.709 full-range yellow at about the white's signal level.
        let yellow = PQSubtitlePalette.sRGB(fromPQ: 160, 160, 40)
        #expect(yellow.r > 200 && yellow.g > 200)
        #expect(yellow.b < yellow.r / 2)
    }

    private static func firstPixel(palette: [UInt8], pqPalette: Bool) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 1, count: 8 * 2)
        var palette = palette
        let image = try pixels.withUnsafeMutableBufferPointer { px in
            try palette.withUnsafeMutableBufferPointer { pal in
                var rect = AVSubtitleRect()
                rect.type = SUBTITLE_BITMAP
                rect.w = 8; rect.h = 2; rect.linesize.0 = 8
                rect.data.0 = px.baseAddress
                rect.data.1 = pal.baseAddress
                return try #require(withUnsafeMutablePointer(to: &rect) {
                    EmbeddedSubtitleDecoder.imageForSubtitleRect($0, videoWidth: 1920, videoHeight: 1080,
                                                                 pqPalette: pqPalette)
                })
            }
        }
        let data = try #require(image.cgImage.dataProvider?.data) as Data
        return Array(data.prefix(4))
    }

    @Test("the blit converts the palette only when asked, and premultiplies after the conversion")
    func blitHonoursFlag() throws {
        var palette = [UInt8](repeating: 0, count: 256 * 4)
        palette[4...7] = [158, 158, 158, 255]
        #expect(try Self.firstPixel(palette: palette, pqPalette: false) == [158, 158, 158, 255])
        #expect(try Self.firstPixel(palette: palette, pqPalette: true) == [255, 255, 255, 255])
        palette[7] = 128
        #expect(try Self.firstPixel(palette: palette, pqPalette: true) == [128, 128, 128, 128])
    }
}
