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

private func imageCue(_ id: Int, _ start: Double, _ end: Double) -> SubtitleCue {
    // Minimal 1x1 image body; only timing matters for the pending state.
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = SubtitleImage(cgImage: ctx.makeImage()!, position: .zero, canvasSize: .zero)
    return SubtitleCue(id: id, startTime: start, endTime: end, body: .image(image))
}

@Suite("OCR pending-composition end clamp")
struct SubtitleOCRPendingStateTests {
    @Test("the next event closes an open composition at its PTS; earlier real ends survive")
    func clampSemantics() {
        var state = SubtitleOCRPendingState()
        // Placeholder end (start+5) still open at the next event: clamps to event PTS.
        #expect(state.consume(eventPts: 10, cues: [imageCue(1, 10, 15)], trimAt: nil).isEmpty)
        let closed = state.consume(eventPts: 12, cues: [imageCue(2, 12, 17)], trimAt: nil)
        #expect(closed.map(\.id) == [1])
        #expect(closed[0].endTime == 12)
        // Real earlier end survives a later successor.
        var s2 = SubtitleOCRPendingState()
        _ = s2.consume(eventPts: 10, cues: [imageCue(3, 10, 11.5)], trimAt: nil)
        let c2 = s2.consume(eventPts: 20, cues: [], trimAt: 20)
        #expect(c2[0].endTime == 11.5)
    }

    @Test("a clear event closes via trimAt; expired emits with the decoder end at EOF")
    func clearAndExpiry() {
        var state = SubtitleOCRPendingState()
        _ = state.consume(eventPts: 10, cues: [imageCue(1, 10, 15)], trimAt: nil)
        let cleared = state.consume(eventPts: 13, cues: [], trimAt: 13)
        #expect(cleared[0].endTime == 13)
        _ = state.consume(eventPts: 30, cues: [imageCue(2, 30, 35)], trimAt: nil)
        #expect(state.expired(asOf: 36).isEmpty)          // margin not yet passed
        let expired = state.expired(asOf: 38)             // 35 + 2s margin crossed, no successor
        #expect(expired.map(\.id) == [2])
        #expect(expired[0].endTime == 35)
        #expect(state.expired(asOf: 60).isEmpty)          // emitted only once
    }
}
