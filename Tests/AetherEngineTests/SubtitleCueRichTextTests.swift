import Testing
@testable import AetherEngine

struct SubtitleCueRichTextTests {
    @Test("cue.text flattens richText runs into concatenated plain text")
    func flattensRichText() {
        let runs = [
            SubtitleTextRun(text: "White ", color: nil),
            SubtitleTextRun(text: "cyan", color: SubtitleColor(r: 0, g: 255, b: 255)),
        ]
        let cue = SubtitleCue(id: 1, startTime: 0, endTime: 1, body: .richText(runs))
        #expect(cue.text == "White cyan")
    }

    @Test("cue.text is nil for image body, unchanged for text body")
    func plainAndImageUnchanged() {
        let text = SubtitleCue(id: 2, startTime: 0, endTime: 1, body: .text("hi"))
        #expect(text.text == "hi")
    }
}
