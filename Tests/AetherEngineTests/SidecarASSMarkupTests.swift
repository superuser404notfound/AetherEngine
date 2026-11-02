import XCTest
import Testing
import Foundation
@testable import AetherEngine

/// Covers AetherEngine#48: a sidecar ASS file decoded under
/// `preserveASSMarkup` must surface the script header AND keep raw
/// event lines (so a host can rebuild a styled script), while the
/// default path stays plain-text and header-less.
final class SidecarASSMarkupTests: XCTestCase {

    private static let assFile = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\i1}Hello{\\i0} world
    Dialogue: 0,0:00:04.00,0:00:06.00,Default,,0,0,0,,Second line
    """

    private func writeTempASS() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("sodalite-issue48-\(ProcessInfo.processInfo.globallyUniqueString).ass")
        try Self.assFile.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testPreserveASSMarkupKeepsRawLinesAndHeader() async throws {
        let url = try writeTempASS()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await SubtitleDecoder.decodeFile(url: url, preserveASSMarkup: true)

        // Header carries the style table so a renderer can resolve refs.
        let header = try XCTUnwrap(result.assHeader, "ASS header must be surfaced under preserveASSMarkup")
        XCTAssertTrue(header.contains("[V4+ Styles]"))
        XCTAssertTrue(header.contains("Style: Default"))

        XCTAssertEqual(result.cues.count, 2)
        // Each cue body is the raw libavcodec event line (ReadOrder,Layer,Style,...,Text) with override tags intact.
        guard case let .text(first) = result.cues[0].body else {
            return XCTFail("expected text body")
        }
        XCTAssertTrue(first.contains("{\\i1}Hello{\\i0} world"), "override tags must survive: \(first)")
        // Must be parseable by ASSScriptBuilder (9 comma fields, numeric ReadOrder).
        let builder = ASSScriptBuilder(header: header)
        XCTAssertTrue(builder.add(rawEventText: first, start: result.cues[0].startTime, end: result.cues[0].endTime))
        XCTAssertEqual(builder.eventCount, 1)
        XCTAssertTrue(builder.script().contains("{\\i1}Hello{\\i0} world"))
    }

    /// #233 changed half of this contract. The default path is still header-less and still hands
    /// over no raw event lines, but it no longer flattens the markup away: a styled cue arrives as
    /// `.richText` with the attributes resolved, and only an unstyled one stays `.text`. The
    /// flattened string a host reads through `SubtitleCue.text` is unchanged either way.
    func testDefaultPathResolvesStylingAndStaysHeaderless() async throws {
        let url = try writeTempASS()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await SubtitleDecoder.decodeFile(url: url)

        XCTAssertNil(result.assHeader, "no header when markup preservation is off")
        XCTAssertEqual(result.cues.count, 2)

        guard case let .richText(runs) = result.cues[0].body else {
            return XCTFail("expected a styled body for {\\i1}Hello{\\i0} world")
        }
        XCTAssertEqual(runs.map(\.text), ["Hello", " world"])
        XCTAssertTrue(runs[0].isItalic, "the \\i1 run must reach the host italic")
        XCTAssertFalse(runs[1].isItalic, "\\i0 must end the italic run")
        XCTAssertEqual(result.cues[0].text, "Hello world", "the flattened accessor is unchanged")

        // No override tags, so nothing to resolve and the body stays exactly what it was.
        guard case let .text(second) = result.cues[1].body else {
            return XCTFail("expected a plain body for an unstyled line")
        }
        XCTAssertEqual(second, "Second line")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(3)))
struct SecondarySidecarASSMarkupTests {
    @Test("secondary ASS preserves raw events and its own script header when requested")
    func secondaryASSPreservesMarkupAndHeader() async throws {
        let url = try MultiASSPlayResFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: true))
        let primary = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(
            url: url, name: "English ASS", language: "eng", formatHint: "ass",
            sourceStreamIndex: MultiASSPlayResFixture.englishStreamIndex))
        let secondary = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(
            url: url, name: "Spanish ASS", language: "spa", formatHint: "ass",
            sourceStreamIndex: MultiASSPlayResFixture.spanishStreamIndex))

        engine.selectSubtitleTrack(index: primary.id)
        engine.selectSecondarySubtitleTrack(index: secondary.id)
        await engine.sidecarTask?.value
        await engine.secondarySidecarTask?.value

        #expect(engine.sidecarASSHeader?.contains("PlayResX: 640") == true)
        #expect(engine.secondarySidecarASSHeader?.contains("PlayResX: 1920") == true)
        guard case .text(let primaryRaw) = try #require(engine.subtitleCues.first).body,
              case .text(let secondaryRaw) = try #require(engine.secondarySubtitleCues.first).body
        else {
            Issue.record("preserved ASS cues must publish raw event lines on both channels")
            return
        }
        #expect(primaryRaw.contains(#"{\pos(320,240)}"#))
        #expect(secondaryRaw.contains(#"{\pos(320,240)}"#))

        engine.loadedURL = URL(string: "https://media.example/movie.mkv")!
        engine.selectSecondarySubtitleTrack(index: 3)
        #expect(engine.secondarySidecarASSHeader == nil)
    }


    @Test("default secondary ASS output stays headerless")
    func defaultOutput() async throws {
        let url = try MultiASSPlayResFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.clearSecondarySubtitle() }
        engine.selectSecondarySidecarSubtitle(url: url)
        await engine.secondarySidecarTask?.value
        #expect(!engine.secondarySubtitleCues.isEmpty)
        #expect(engine.secondarySidecarASSHeader == nil)
        #expect(engine.secondarySubtitleCues.allSatisfy { !($0.text ?? "").contains("{\\pos") })
    }

    @Test("clear, stop and cancelled decode cannot leave secondary ASS metadata behind")
    func lifecycle() async throws {
        let url = try MultiASSPlayResFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: true))
        engine.selectSecondarySidecarSubtitle(url: url)
        await engine.secondarySidecarTask?.value
        #expect(engine.secondarySidecarASSHeader != nil)
        engine.clearSubtitle()
        #expect(engine.secondarySidecarASSHeader != nil)
        engine.clearSecondarySubtitle()
        #expect(engine.secondarySidecarASSHeader == nil)
        engine.selectSecondarySidecarSubtitle(url: url)
        let pending = engine.secondarySidecarTask
        engine.clearSecondarySubtitle()
        await pending?.value
        #expect(engine.secondarySidecarASSHeader == nil)
        #expect(engine.secondarySubtitleCues.isEmpty)
        engine.selectSecondarySidecarSubtitle(url: url)
        await engine.secondarySidecarTask?.value
        #expect(engine.secondarySidecarASSHeader != nil)
        engine.stopInternal()
        #expect(engine.secondarySidecarASSHeader == nil)
    }

    @Test("switching to SubRip removes ASS header without turning its text into ASS")
    func switchToSubRip() async throws {
        let ass = try MultiASSPlayResFixture.write()
        let srt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".srt")
        try "1\n00:00:01,000 --> 00:00:03,000\nHello\n".write(to: srt, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: ass); try? FileManager.default.removeItem(at: srt) }
        let engine = try AetherEngine()
        defer { engine.clearSecondarySubtitle() }
        engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: true))
        engine.selectSecondarySidecarSubtitle(url: ass)
        await engine.secondarySidecarTask?.value
        #expect(engine.secondarySidecarASSHeader != nil)
        engine.selectSecondarySidecarSubtitle(url: srt)
        #expect(engine.secondarySidecarASSHeader == nil)
        await engine.secondarySidecarTask?.value
        #expect(engine.secondarySidecarASSHeader == nil)
        #expect(engine.secondarySubtitleCues.compactMap(\.text) == ["Hello"])
    }

    @Test("session carryover restores the secondary ASS header from its sidecar")
    func restoreAfterTeardown() async throws {
        let url = try MultiASSPlayResFixture.write()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.clearSecondarySubtitle() }
        engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: true))
        engine.selectSecondarySidecarSubtitle(url: url)
        await engine.secondarySidecarTask?.value
        let header = try #require(engine.secondarySidecarASSHeader)
        let carryover = engine.captureSubtitleSessionCarryover()
        engine.stopInternal()
        #expect(engine.secondarySidecarASSHeader == nil)
        engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: true))
        engine.restoreSubtitleSelection(from: carryover, resumeAnchor: 0)
        await engine.secondarySidecarTask?.value
        #expect(engine.secondarySidecarASSHeader == header)
        #expect(!engine.secondarySubtitleCues.isEmpty)
    }

    @Test("preserveASSMarkup does not turn secondary WebVTT into raw ASS")
    func webVTTStaysText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vtt")
        try "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello VTT\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try AetherEngine()
        defer { engine.clearSecondarySubtitle() }
        engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: true))
        engine.selectSecondarySidecarSubtitle(url: url)
        await engine.secondarySidecarTask?.value
        #expect(engine.secondarySidecarASSHeader == nil)
        #expect(engine.secondarySubtitleCues.compactMap(\.text) == ["Hello VTT"])
    }
}
