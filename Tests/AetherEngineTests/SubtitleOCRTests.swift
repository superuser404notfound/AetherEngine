import Testing
import CoreGraphics
import CoreText
@testable import AetherEngine

@Suite("Subtitle image OCR")
struct SubtitleOCRTests {
    @Test("line assembly sorts top line first (Vision origin is bottom-left) and drops blanks")
    func lineAssembly() {
        let joined = SubtitleImageOCR.assembleLines([
            (text: "bottom line", midY: 0.2),
            (text: "   ", midY: 0.9),
            (text: "top line", midY: 0.8),
        ])
        #expect(joined == "top line\nbottom line")
        #expect(SubtitleImageOCR.assembleLines([]) == nil)
        #expect(SubtitleImageOCR.assembleLines([(text: " ", midY: 0.5)]) == nil)
    }

    @Test("track languages normalize to alpha-2 for Vision, unknown tags pass through")
    func languageMapping() {
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: "ger") == "de")
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: "eng") == "en")
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: "de") == "de")
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: nil) == nil)
        #expect(SubtitleImageOCR.recognitionLanguage(forTrackLanguage: "") == nil)
    }

    @Test("flatten produces an opaque black canvas with the source drawn on top")
    func flatten() throws {
        // 2x1 image: left pixel white opaque, right pixel fully transparent.
        let ctx = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let src = ctx.makeImage()!
        let flat = try #require(SubtitleImageOCR.flattenedOntoBlack(src))
        let out = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        out.draw(flat, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        let p = out.data!.assumingMemoryBound(to: UInt8.self)
        #expect(p[0] > 200)   // white pixel survives
        #expect(p[4] < 30)    // transparent pixel is now opaque black
    }

    @Test("Vision recognizes clean synthetic subtitle text")
    func visionSynthetic() throws {
        let width = 480, height = 96
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 48, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                      kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(kCFAllocatorDefault, "HELLO 123" as CFString, attrs as CFDictionary)!)
        ctx.textPosition = CGPoint(x: 24, y: 28)
        CTLineDraw(line, ctx)
        let image = ctx.makeImage()!
        let text = try #require(SubtitleImageOCR.recognizeText(in: image, language: "en"))
        #expect(text.contains("HELLO"))
        #expect(text.contains("123"))
    }
}
