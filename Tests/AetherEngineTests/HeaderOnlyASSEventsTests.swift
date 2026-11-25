import Foundation
import Testing
@testable import AetherEngine

/// AE#1127: an ASS track whose events live in its CodecPrivate and in no block at all.
@Suite("ASS events a muxer left in the track header reach the session as cues")
struct HeaderOnlyASSEventsTests {

    private static let header = """
    [Script Info]
    ScriptType: v4.00+

    [V4+ Styles]
    Format: Name, Fontname, Fontsize
    Style: Default,Arial,20

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:05.00,0:00:07.50,Default,,0,0,0,,Second, with a comma
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,First
    """

    @Test("the Dialogue lines leave the header and come back as Matroska blocks in start order",
          .timeLimit(.minutes(3)))
    func liftsDialogueLines() throws {
        let (header, events) = ASSHeaderEvents.split(Self.header)
        #expect(!header.contains("Dialogue:"))
        #expect(header.contains("Style: Default,Arial,20"))
        #expect(header.contains("Format: Layer, Start, End"))
        try #require(events.count == 2)
        #expect(events[0].startSeconds == 1 && events[0].durationSeconds == 2)
        #expect(events[1].startSeconds == 5 && events[1].durationSeconds == 2.5)
        // ReadOrder is the line's place in the file, not in the sorted list.
        #expect(String(decoding: events[0].payload, as: UTF8.self) == "1,0,Default,,0,0,0,,First")
        #expect(String(decoding: events[1].payload, as: UTF8.self) == "0,0,Default,,0,0,0,,Second, with a comma")
    }

    @Test("a header without events, or with Dialogue lines outside [Events], is left as it is",
          .timeLimit(.minutes(3)))
    func leavesOtherHeadersAlone() {
        let plain = "[Script Info]\r\nTitle: x\r\n\r\n[Events]\r\nFormat: Layer, Start, End, Style, Text\r\n"
        #expect(ASSHeaderEvents.split(plain) == (plain, []))
        let elsewhere = "[Script Info]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,x\n"
        #expect(ASSHeaderEvents.split(elsewhere) == (elsewhere, []))
    }

    @Test("any Format line order becomes the fixed Matroska block layout, and CRLF headers split per line",
          .timeLimit(.minutes(3)))
    func followsTheFormatLine() throws {
        let header = "[Events]\r\nFormat: Start, End, Style, Text\r\nDialogue: 0:01:00.50,0:01:02.00,Default,a,b\r\n"
        let (stripped, events) = ASSHeaderEvents.split(header)
        try #require(events.count == 1)
        #expect(events[0].startSeconds == 60.5 && events[0].durationSeconds == 1.5)
        #expect(String(decoding: events[0].payload, as: UTF8.self) == "0,0,Default,,0,0,0,,a,b")
        #expect(stripped == "[Events]\nFormat: Start, End, Style, Text\n")

        let ssa = "[Events]\nFormat: Marked, Start, End, Actor, Style, MarginL, MarginR, MarginV, Effect, Text\n"
            + "Dialogue: Marked=0,0:00:01.00,0:00:02.00,Bob,Main,1,2,3,,Hi, there\n"
        let lifted = try #require(ASSHeaderEvents.split(ssa).events.first)
        #expect(String(decoding: lifted.payload, as: UTF8.self) == "0,0,Main,Bob,1,2,3,,Hi, there")
    }

    @Test("only CR and LF end a line, as in libass", .timeLimit(.minutes(3)))
    func splitsOnlyOnCarriageReturnAndLineFeed() throws {
        let header = "[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,one\u{2028}two\u{85}three\n"
        let event = try #require(ASSHeaderEvents.split(header).events.first)
        #expect(String(decoding: event.payload, as: UTF8.self) == "0,0,Default,,0,0,0,,one\u{2028}two\u{85}three")
    }

    @Test("an unreadable or empty line is dropped from the header and lifts nothing",
          .timeLimit(.minutes(3)))
    func dropsBrokenLines() {
        let header = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:0x.00,0:00:02.00,Default,,0,0,0,,bad time
        Dialogue: 0,0:00:03.00,0:00:03.00,Default,,0,0,0,,no duration
        Dialogue: 0,0:00:04.00
        Dialogue: 0,9999999:00:00.00,9999999:00:01.00,Default,,0,0,0,,past any plausible time
        """
        let (stripped, events) = ASSHeaderEvents.split(header)
        #expect(events.isEmpty)
        #expect(!stripped.contains("Dialogue:"))
    }

    @Test("lifted payload stops at the per-track ceiling and the rest stays in the header",
          .timeLimit(.minutes(3)))
    func boundsThePayload() {
        let text = String(repeating: "x", count: 4096)
        let total = 1100
        var lines = ["[Events]", "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"]
        for i in 0..<total { lines.append("Dialogue: 0,0:00:\(String(format: "%02d", i % 60)).00,0:59:00.00,D,,0,0,0,,\(text)") }
        let (header, events) = ASSHeaderEvents.split(lines.joined(separator: "\n"))
        #expect(!events.isEmpty && events.count < total)
        #expect(events.reduce(0) { $0 + $1.payload.count } <= ASSHeaderEvents.maxPayloadBytesPerTrack)
        #expect(header.components(separatedBy: "Dialogue:").count - 1 == total - events.count,
                "a line past the ceiling must stay where a libass host can still draw it")
    }

    @Test("the demuxer hands the events to the track, and the packet store decodes them",
          .timeLimit(.minutes(3)))
    func demuxedTrackCarriesItsEvents() throws {
        let url = try Self.writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        let track = try #require(demuxer.subtitleTrackInfos().first)
        #expect(track.headerEvents.map(\.startSeconds) == [1, 5, 12, 20])
        #expect(track.assHeader?.contains("Dialogue:") == false)
        #expect(track.assHeader?.contains("[V4+ Styles]") == true)

        let store = SubtitlePacketStore()
        store.seedHeaderEvents(from: [track])
        store.seedHeaderEvents(from: [track])
        let entries = store.entries(streamIndex: Int32(track.id), from: 0, through: 100)
        #expect(entries.count == 4, "a second seed must collapse onto the first")

        let decoder = try #require(demuxer.withStream(at: Int32(track.id)) {
            EmbeddedSubtitleDecoder(stream: $0, sourceVideoWidth: 640, sourceVideoHeight: 360)
        } ?? nil)
        let cues = entries.compactMap { AetherEngine.decodeStoredSubtitlePacket($0, with: decoder) }
            .flatMap(\.cues)
        #expect(cues.map(\.startTime) == [1, 5, 12, 20])
        #expect(cues.map(\.endTime) == [3, 7.5, 14, 22])
        #expect(cues.first?.text == "First line, with a comma")
    }

    @Test("aggregate pressure spares a stream holding lifted events", .timeLimit(.minutes(3)))
    func liftedEventsSurviveAggregateEviction() throws {
        let track = TrackInfo(id: 3, name: "ass", codec: "ass", language: nil, isDefault: false)
        var seeded = track
        seeded.headerEvents = ASSHeaderEvents.split(Self.header).events
        let store = SubtitlePacketStore(perStreamByteCap: 1 << 20, aggregateByteCap: 4096)
        store.seedHeaderEvents(from: [seeded])
        for i in 0..<64 {
            store.append(streamIndex: 4, ptsSeconds: Double(i), durationSeconds: 1, payload: Data(repeating: 1, count: 256))
            store.append(streamIndex: 5, ptsSeconds: Double(i), durationSeconds: 1, payload: Data(repeating: 2, count: 256))
        }
        #expect(store.entries(streamIndex: 3, from: 0, through: 100).count == 2)
    }

    @Test("a seeded stream that also harvests blocks past its seed competes for room again",
          .timeLimit(.minutes(3)))
    func seededStreamThatGrowsIsEvictable() {
        var seeded = TrackInfo(id: 3, name: "ass", codec: "ass", language: nil, isDefault: false)
        seeded.headerEvents = ASSHeaderEvents.split(Self.header).events
        let store = SubtitlePacketStore(perStreamByteCap: 1 << 20, aggregateByteCap: 4096)
        store.seedHeaderEvents(from: [seeded])
        for i in 0..<16 {
            store.append(streamIndex: 3, ptsSeconds: 100 + Double(i), durationSeconds: 1,
                         payload: Data(repeating: 3, count: 256))
        }
        for i in 0..<64 {
            store.append(streamIndex: 4, ptsSeconds: Double(i), durationSeconds: 1, payload: Data(repeating: 1, count: 256))
        }
        #expect(store.entries(streamIndex: 3, from: 0, through: 200).count < 18)
    }

    @Test("a sidecar container whose events live in the header decodes to cues", .timeLimit(.minutes(3)))
    func sidecarContainerDecodesHeaderEvents() async throws {
        let url = try Self.writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let cues = try await SubtitleDecoder.decodeFile(url: url).cues
        #expect(cues.map(\.startTime) == [1, 5, 12, 20])
        #expect(cues.map(\.endTime) == [3, 7.5, 14, 22])

        let markup = try await SubtitleDecoder.decodeFile(url: url, preserveASSMarkup: true)
        #expect(markup.cues.count == 4)
        #expect(markup.assHeader?.contains("Dialogue:") == false)
    }

    private static func writeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("header-only-ass-\(UUID().uuidString).mks")
        try fixture.write(to: url)
        return url
    }

    // A 16x16 black picture for 2 s and one ASS track with four events, all of them in the track's
    // CodecPrivate and none in a block. ffmpeg moves Dialogue lines into packets, so the lines are
    // muxed as "Xialogue: " and renamed in place (same length, so every EBML size stays right):
    // ffmpeg -f lavfi -i color=c=black:size=16x16:rate=1 -i hdr.ass -t 2 -map 0:v -map 1:s
    //   -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:s copy -map_metadata -1 -fflags +bitexact
    //   -flags:v +bitexact -f matroska t.mks
    // LC_ALL=C perl -pe 's/Xialogue: /Dialogue: /g' t.mks > header-only-ass.mks
    // SHA-256: 158df92b778645cf83868f6841257c581ec30d366d33ef88be4834f843c54b81
    private static let fixture = Data(base64Encoded: [
        "GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAH6RFNm3TAv4TGTe05TbuLU6uEFUmpZlOs",
        "gaFNu4tTq4QWVK5rU6yBzE27jFOrhBJUw2dTrIIEsU27jFOrhBxTu2tTrIIHzewBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZqa/hJQWulIq",
        "17GDD0JATYCETGF2ZldBhExhdmZEiYhAn0AAAAAAABZUrmtD37+EY64CS64BAAAAAAAAf9eBAXPFiAAAAAAAAAABnIEAIrWcg3Vu",
        "ZIiBAIaPVl9NUEVHNC9JU08vQVZDg4EBI+ODhDuaygDgkLCBELqBEJqBAlWwhFW5gQFV7oEA7AEAAAAAAAACAABjoqQBQsAK/+EA",
        "FWdCwAraewEQAAADABAAAAMAIPEiagEABGjOD8iuAQAAAAAAA0jXgQJzxYgAAAAAAAAAApyBACK1nIN1bmSIgQCGilNfVEVYVC9B",
        "U1ODgRFV7oEAY6JDFltTY3JpcHQgSW5mb10KU2NyaXB0VHlwZTogdjQuMDArClBsYXlSZXNYOiA2NDAKUGxheVJlc1k6IDM2MAoK",
        "W1Y0KyBTdHlsZXNdCkZvcm1hdDogTmFtZSwgRm9udG5hbWUsIEZvbnRzaXplLCBQcmltYXJ5Q29sb3VyLCBTZWNvbmRhcnlDb2xv",
        "dXIsIE91dGxpbmVDb2xvdXIsIEJhY2tDb2xvdXIsIEJvbGQsIEl0YWxpYywgVW5kZXJsaW5lLCBTdHJpa2VPdXQsIFNjYWxlWCwg",
        "U2NhbGVZLCBTcGFjaW5nLCBBbmdsZSwgQm9yZGVyU3R5bGUsIE91dGxpbmUsIFNoYWRvdywgQWxpZ25tZW50LCBNYXJnaW5MLCBN",
        "YXJnaW5SLCBNYXJnaW5WLCBFbmNvZGluZwpTdHlsZTogRGVmYXVsdCxBcmlhbCwyMCwmSDAwRkZGRkZGLCZIMDAwMDAwRkYsJkgw",
        "MDAwMDAwMCwmSDAwMDAwMDAwLDAsMCwwLDAsMTAwLDEwMCwwLDAsMSwxLDAsMiwxMCwxMCwxMCwxCgpbRXZlbnRzXQpGb3JtYXQ6",
        "IExheWVyLCBTdGFydCwgRW5kLCBTdHlsZSwgTmFtZSwgTWFyZ2luTCwgTWFyZ2luUiwgTWFyZ2luViwgRWZmZWN0LCBUZXh0CkRp",
        "YWxvZ3VlOiAwLDA6MDA6MDEuMDAsMDowMDowMy4wMCxEZWZhdWx0LCwwLDAsMCwsRmlyc3QgbGluZSwgd2l0aCBhIGNvbW1hCkRp",
        "YWxvZ3VlOiAwLDA6MDA6MDUuMDAsMDowMDowNy41MCxEZWZhdWx0LCwwLDAsMCwse1xpMX1TZWNvbmR7XGkwfSBsaW5lCkRpYWxv",
        "Z3VlOiAwLDA6MDA6MTIuMDAsMDowMDoxNC4wMCxEZWZhdWx0LCwwLDAsMCwsVGhpcmQgbGluZVxOVHdvIHJvd3MKRGlhbG9ndWU6",
        "IDAsMDowMDoyMC4wMCwwOjAwOjIyLjAwLERlZmF1bHQsLDAsMCwwLCxGb3VydGggbGluZQoSVMNnQIy/hE5rXgdzc85jwItjxYgA",
        "AAAAAAAAAWfImUWjh0VOQ09ERVJEh4xMYXZjIGxpYngyNjRnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAyLjAwMDAwMDAwMABzc7Jj",
        "wItjxYgAAAAAAAAAAmfIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDAuMDAwMDAwMDAwAB9DtnVChL+EzfSglOeBAKNCaYEAAIAAAAJT",
        "BgX//0/cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVj",
        "IC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9",
        "MCByZWY9MSBkZWJsb2NrPTA6MDowIGFuYWx5c2U9MDowIG1lPWRpYSBzdWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4",
        "ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZh",
        "c3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFkcz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9",
        "MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9",
        "MCB3ZWlnaHRwPTAga2V5aW50PTI1MCBrZXlpbnRfbWluPTEgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3JmIG1idHJl",
        "ZT0wIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTAAgAAAAApl",
        "iIQ6JigACQLgo42BA+gAAAAABUGaIBSlHFO7a5e/hOD6sUS7j7OBALeK94EB8YIFQ/CBCQ==",
    ].joined())!
}
