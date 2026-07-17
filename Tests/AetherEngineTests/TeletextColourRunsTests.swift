import Testing
@testable import AetherEngine

struct TeletextColourRunsTests {
    // ASS colour is &Hbbggrr& (BGR). &H00FFFF& = R=255 G=255 B=0 (yellow).
    @Test("parses BGR hex into RGB runs")
    func bgrToRgb() {
        let line = "0,0,Default,,0,0,0,,{\\c&H00FFFF&}Yellow"
        let runs = SubtitleRectText.coloredRuns(fromASSEventLine: line)
        #expect(runs == [SubtitleTextRun(text: "Yellow", color: SubtitleColor(r: 255, g: 255, b: 0))])
    }

    @Test("splits into multiple runs at colour changes, collapses equal-colour neighbours")
    func multiRun() {
        let line = "0,0,Default,,0,0,0,,{\\c&H0000FF&}Red {\\c&HFFFFFF&}White"
        let runs = SubtitleRectText.coloredRuns(fromASSEventLine: line)
        #expect(runs == [
            SubtitleTextRun(text: "Red ", color: SubtitleColor(r: 255, g: 0, b: 0)),
            SubtitleTextRun(text: "White", color: SubtitleColor(r: 255, g: 255, b: 255)),
        ])
    }

    @Test("bare \\c resets to default (nil colour)")
    func resetColour() {
        let line = "0,0,Default,,0,0,0,,{\\c&H0000FF&}Red{\\c}plain"
        let runs = SubtitleRectText.coloredRuns(fromASSEventLine: line)
        #expect(runs == [
            SubtitleTextRun(text: "Red", color: SubtitleColor(r: 255, g: 0, b: 0)),
            SubtitleTextRun(text: "plain", color: nil),
        ])
    }

    @Test("applies \\N newline and \\h hard space escapes")
    func escapes() {
        let line = "0,0,Default,,0,0,0,,line1\\Nline2\\hend"
        let runs = SubtitleRectText.coloredRuns(fromASSEventLine: line)
        #expect(runs == [SubtitleTextRun(text: "line1\nline2 end", color: nil)])
    }

    @Test("uncoloured line yields a single nil-colour run")
    func noColour() {
        let runs = SubtitleRectText.coloredRuns(fromASSEventLine: "0,0,Default,,0,0,0,,just text")
        #expect(runs == [SubtitleTextRun(text: "just text", color: nil)])
    }

    @Test("teletextBody returns richText when coloured, text when not, nil when empty")
    func bodySelection() {
        if case .richText? = SubtitleRectText.teletextBody(fromASSEventLine: "0,0,D,,0,0,0,,{\\c&H0000FF&}Red") {} else { Issue.record("expected richText") }
        if case .text(let s)? = SubtitleRectText.teletextBody(fromASSEventLine: "0,0,D,,0,0,0,,plain") { #expect(s == "plain") } else { Issue.record("expected text") }
        #expect(SubtitleRectText.teletextBody(fromASSEventLine: "0,0,D,,0,0,0,,{\\c&H0&}") == nil)
    }

    @Test("non-event line with too few fields is cleaned as-is")
    func nonEventLine() {
        let runs = SubtitleRectText.coloredRuns(fromASSEventLine: "plain, with, commas")
        #expect(runs == [SubtitleTextRun(text: "plain, with, commas", color: nil)])
    }

    @Test("adjacent same-colour runs collapse into one")
    func collapseSameColour() {
        let line = "0,0,Default,,0,0,0,,{\\c&H0000FF&}A{\\c&H0000FF&}B"
        let runs = SubtitleRectText.coloredRuns(fromASSEventLine: line)
        #expect(runs == [SubtitleTextRun(text: "AB", color: SubtitleColor(r: 255, g: 0, b: 0))])
    }

    @Test("non-colour override tags like \\clip are ignored, not treated as a reset")
    func clipTagIgnored() {
        let line = "0,0,Default,,0,0,0,,{\\c&H0000FF&}Red{\\clip(1,2,3,4)}still"
        let runs = SubtitleRectText.coloredRuns(fromASSEventLine: line)
        #expect(runs == [SubtitleTextRun(text: "Redstill", color: SubtitleColor(r: 255, g: 0, b: 0))])
    }
}
