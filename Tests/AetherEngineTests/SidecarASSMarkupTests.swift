import XCTest
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
        // Each cue body is the raw libavcodec event line
        // (ReadOrder,Layer,Style,...,Text) WITH override tags intact.
        guard case let .text(first) = result.cues[0].body else {
            return XCTFail("expected text body")
        }
        XCTAssertTrue(first.contains("{\\i1}Hello{\\i0} world"), "override tags must survive: \(first)")
        // It must be parseable by ASSScriptBuilder (9 comma fields,
        // numeric ReadOrder), the host's whole-script reassembler.
        let builder = ASSScriptBuilder(header: header)
        XCTAssertTrue(builder.add(rawEventText: first, start: result.cues[0].startTime, end: result.cues[0].endTime))
        XCTAssertEqual(builder.eventCount, 1)
        XCTAssertTrue(builder.script().contains("{\\i1}Hello{\\i0} world"))
    }

    func testDefaultPathStaysPlainTextAndHeaderless() async throws {
        let url = try writeTempASS()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await SubtitleDecoder.decodeFile(url: url)

        XCTAssertNil(result.assHeader, "no header when markup preservation is off")
        XCTAssertEqual(result.cues.count, 2)
        guard case let .text(first) = result.cues[0].body else {
            return XCTFail("expected text body")
        }
        // Plain text: override tags stripped, no event-line prefix.
        XCTAssertEqual(first, "Hello world")
    }
}
