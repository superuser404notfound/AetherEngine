import Testing
@testable import AetherEngine

/// #107 whole-branch review follow-up: `SubtitleCue.Body.richText` (coloured teletext pages) was added
/// alongside `.text` and `.image`, but the retained-store filters that gate on `.text` specifically
/// (`trimTextCues`, the re-decode dedupe guard in `insertCueSorted`) never learned about it. Coloured
/// teletext pages then never closed at their successor's start and re-decoded duplicates on a live-DVR
/// seek slipped past the dedupe guard. Both filters must treat `.richText` the same as `.text`.
struct SubtitleStoreRichTextTests {

    private func richTextCue(id: Int, start: Double, end: Double, _ text: String) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .richText([SubtitleTextRun(text: text, color: nil)]))
    }

    @Test("trimTextCues closes an open richText teletext cue at the trim point")
    func trimClosesOpenRichTextCue() {
        var cues = [richTextCue(id: 0, start: 100, end: 100 + 4_294_967, "coloured page")]
        AetherEngine.trimTextCues(&cues, at: 110)
        #expect(cues.count == 1)
        #expect(cues[0].startTime == 100)
        #expect(cues[0].endTime == 110)
    }

    @Test("insertCueSorted dedupes a re-decoded richText cue with the same start and flattened text")
    func insertDedupesReDecodedRichTextCue() {
        var cues: [SubtitleCue] = []
        var nextID = 0
        AetherEngine.insertCueSorted(richTextCue(id: 0, start: 100, end: 110, "coloured page"), into: &cues, nextID: &nextID)
        #expect(cues.count == 1)
        // A seek rebuilds the decoder and re-emits the same page with a reset id; must not duplicate.
        AetherEngine.insertCueSorted(richTextCue(id: 0, start: 100, end: 100 + 4_294_967, "coloured page"), into: &cues, nextID: &nextID)
        #expect(cues.count == 1)
    }
}
