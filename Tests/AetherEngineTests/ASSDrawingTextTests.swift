import Testing
import Foundation
@testable import AetherEngine

/// ASS drawing mode (`\p1` and up, until `\p0`) turns the event's text into vector commands. Plain
/// text and styled runs drop it; anime typesetting draws boxes and masks this way, and they showed
/// as rows of numbers ("m 1554.65 51.38 l 1554.29 155.93 ...").
struct ASSDrawingTextTests {

    @Test("a drawing event leaves no text")
    func drawingEventIsEmpty() {
        let line = "0,0,Signs,_Sign,0,0,0,,{\\an7\\pos(-53.5,-29.33)\\frz0\\alpha&H00&\\blur1.06\\bord0\\shad0"
            + "\\c&HABBAD2&\\fscx105.58\\fscy105.58\\p1}m 1554.65 51.38 l 1554.29 155.93 398.32 156.15 398.32 50.93"
        #expect(SubtitleRectText.plainText(fromASSEventLine: line) == nil)
        #expect(SubtitleRectText.styledRuns(fromASSEventLine: line) == nil)
    }

    @Test("text after \\p0 shows again")
    func textAfterDrawingShows() {
        let line = "0,0,Default,,0,0,0,,Before {\\p1}m 0 0 l 10 10{\\p0}after"
        #expect(SubtitleRectText.plainText(fromASSEventLine: line) == "Before after")
        #expect(SubtitleRectText.styledRuns(fromASSEventLine: line)?.runs.map(\.text).joined() == "Before after")
    }

    @Test("a higher drawing scale is drawing mode too")
    func higherScaleIsDrawing() {
        #expect(SubtitleRectText.cleanASSBody("{\\p4}m 0 0 l 100 0 100 100") == nil)
    }

    @Test("tags that only start with p are not drawing mode")
    func otherPTagsKeepText() {
        #expect(SubtitleRectText.cleanASSBody("{\\pos(10,20)}Hello") == "Hello")
        #expect(SubtitleRectText.cleanASSBody("{\\pbo2}Hello") == "Hello")
        #expect(SubtitleRectText.cleanASSBody("{\\p}Hello") == "Hello")
        #expect(SubtitleRectText.cleanASSBody("{\\p0}Hello") == "Hello")
    }

    @Test("the last \\p in a block wins")
    func lastDrawingTagWins() {
        #expect(SubtitleRectText.drawingScale(inBlock: "\\p1\\p0".utf8) == 0)
        #expect(SubtitleRectText.drawingScale(inBlock: "\\an7\\p2".utf8) == 2)
        #expect(SubtitleRectText.drawingScale(inBlock: "\\an7\\pos(1,2)".utf8) == nil)
    }

    @Test("a \\r reset does not end drawing mode, as in libass")
    func resetKeepsDrawing() {
        // libass zeroes the drawing scale only when an event starts, never in its \r reset.
        #expect(SubtitleRectText.cleanASSBody("{\\p1}m 0 0 l 100 0 100 100{\\r}m 5 5 l 6 6") == nil)
        #expect(SubtitleRectText.cleanASSBody("{\\p1}m 0 0 l 1 1{\\rAlt\\p0}Sign text") == "Sign text")
        #expect(SubtitleRectText.styledRuns(fromASSEventLine: "0,0,Signs,,0,0,0,,{\\p1}m 0 0 l 1 1{\\r}m 2 2") == nil)
        #expect(SubtitleRectText.drawingScale(inBlock: "\\r".utf8) == nil)
        #expect(SubtitleRectText.drawingScale(inBlock: "\\r\\p1".utf8) == 1)
    }

    @Test("the \\p argument is read as libass reads it")
    func drawingArgumentLikeLibass() {
        #expect(SubtitleRectText.cleanASSBody("{\\p 1}m 10 20 l 30 40{\\p 0}Text") == "Text")
        #expect(SubtitleRectText.cleanASSBody("{\\p1}m 0 0 l 1 1{\\p}Label") == "Label")
        #expect(SubtitleRectText.drawingScale(inBlock: "\\p2.5".utf8) == 2)
    }

    @Test("a \\p inside \\t(...) counts, as in libass")
    func drawingTagInsideTransform() {
        // libass parses the tags in \t(...) again, and \p has no animation guard there.
        #expect(SubtitleRectText.cleanASSBody("{\\t(0,200,\\p1)}m 0 0 l 1 1") == nil)
        #expect(SubtitleRectText.drawingScale(inBlock: "\\t(0,200,\\p1)".utf8) == 1)
        #expect(SubtitleRectText.drawingScale(inBlock: "\\t(\\clip(1,2,3,4)\\p2)".utf8) == 2)
        #expect(SubtitleRectText.drawingScale(inBlock: "\\t(0,200,\\p1)\\p0".utf8) == 0)
        // Any other tag's parentheses are only an argument.
        #expect(SubtitleRectText.drawingScale(inBlock: "\\clip(\\p1)".utf8) == nil)
    }

    @Test("the tag name and its number are read like libass's strtoll")
    func drawingTagSpacingAndSign() {
        #expect(SubtitleRectText.drawingScale(inBlock: "\\ p1".utf8) == 1)
        #expect(SubtitleRectText.drawingScale(inBlock: "\\p+2".utf8) == 2)
        #expect(SubtitleRectText.drawingScale(inBlock: "\\p-1".utf8) == 0)
    }

    @Test("a stray brace while drawing doesn't bring the commands back")
    func strayBraceWhileDrawing() {
        #expect(SubtitleRectText.cleanASSBody("{\\p1}m 0 0 l 10 10 {b 1 2") == nil)
    }

    @Test("mov_text samples drop drawings too")
    func movTextDropsDrawings() {
        #expect(SubtitleRectText.strippingOverrideBlocks("{\\p1}m 0 0 l 1 1{\\p0}Sign") == "Sign")
    }
}
