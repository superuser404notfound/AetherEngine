import Testing
@testable import AetherEngine

@Suite("ASSScriptBuilder")
struct ASSScriptBuilderTests {
    let header = """
    [Script Info]
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize
    Style: Default,Open Sans,48

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    """

    @Test("Builds a script with synthesized Dialogue timestamps")
    func basicSynthesis() {
        let b = ASSScriptBuilder(header: header)
        let added = b.add(rawEventText: "5,0,Default,,0,0,0,,Hello {\\i1}there{\\i0}", start: 61.5, end: 63.875)
        #expect(added)
        let script = b.script()
        #expect(script.hasPrefix(header))
        #expect(script.contains("Dialogue: 0,0:01:01.50,0:01:03.88,Default,,0,0,0,,Hello {\\i1}there{\\i0}"))
    }

    @Test("Dedupes by ReadOrder across re-emits")
    func readOrderDedupe() {
        let b = ASSScriptBuilder(header: header)
        #expect(b.add(rawEventText: "7,0,Default,,0,0,0,,First", start: 1, end: 2))
        #expect(!b.add(rawEventText: "7,0,Default,,0,0,0,,First", start: 1, end: 2))
        #expect(b.eventCount == 1)
    }

    @Test("Splits multi-line cue bodies into separate events")
    func multiLineBody() {
        let b = ASSScriptBuilder(header: header)
        #expect(b.add(rawEventText: "1,0,Default,,0,0,0,,Top\n2,0,Default,,0,0,0,,Bottom", start: 0, end: 4))
        #expect(b.eventCount == 2)
    }

    @Test("Text field keeps embedded commas intact")
    func commasInText() {
        let b = ASSScriptBuilder(header: header)
        #expect(b.add(rawEventText: "9,1,Sign,Actor,10,20,30,fx,One, two, three", start: 0, end: 1))
        #expect(b.script().contains("Dialogue: 1,0:00:00.00,0:00:01.00,Sign,Actor,10,20,30,fx,One, two, three"))
    }

    @Test("Hour-plus timestamps and centisecond rounding")
    func timestampEdges() {
        #expect(ASSScriptBuilder.timestamp(3661.01) == "1:01:01.01")
        #expect(ASSScriptBuilder.timestamp(0) == "0:00:00.00")
        #expect(ASSScriptBuilder.timestamp(-3) == "0:00:00.00")
        #expect(ASSScriptBuilder.timestamp(35999.999) == "10:00:00.00")
    }

    @Test("Malformed lines are skipped, reset clears state")
    func malformedAndReset() {
        let b = ASSScriptBuilder(header: header)
        #expect(!b.add(rawEventText: "no-commas-here", start: 0, end: 1))
        #expect(b.add(rawEventText: "3,0,Default,,0,0,0,,Ok", start: 0, end: 1))
        b.reset()
        #expect(b.eventCount == 0)
        #expect(b.add(rawEventText: "3,0,Default,,0,0,0,,Ok", start: 0, end: 1))
    }
}
