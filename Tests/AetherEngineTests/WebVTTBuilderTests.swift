import Testing
@testable import AetherEngine

struct WebVTTBuilderTests {
    @Test("formats header, timestamps, and sanitized text")
    func formatsCues() {
        let vtt = WebVTTBuilder.body(cues: [
            (start: 0, end: 1.5, text: "Hello"),
            (start: 61.25, end: 3661.004, text: "{\\an8}World\\Nline2"),
        ])
        #expect(vtt.hasPrefix("WEBVTT\n"))
        #expect(vtt.contains("00:00:00.000 --> 00:00:01.500\nHello"))
        // 61.25s -> 00:01:01.250 ; 3661.004s -> 01:01:01.004 ; ASS block stripped, \N -> newline
        #expect(vtt.contains("00:01:01.250 --> 01:01:01.004\nWorld\nline2"))
    }

    @Test("empty cues still yields a valid WEBVTT header")
    func emptyIsValid() {
        #expect(WebVTTBuilder.body(cues: []) == "WEBVTT\n\n")
    }

    @Test("cue that sanitizes to empty is skipped")
    func skipsEmpty() {
        let vtt = WebVTTBuilder.body(cues: [(start: 0, end: 1, text: "{\\an8}")])
        #expect(vtt == "WEBVTT\n\n")
    }
}
