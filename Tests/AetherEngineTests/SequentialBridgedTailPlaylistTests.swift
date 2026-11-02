import Foundation
import Testing
@testable import AetherEngine

/// Audit SEG-103: on a sequential origin the bridged audio follows the video cutter (7.22), but the
/// end-of-file flush of the bridge still routed its tail by plan time. When the last GOP crossed the
/// last plan boundary, that tail opened the plan index the cutter never reached: the real final
/// segment was closed as not-final, its duration never reported, and ENDLIST landed one segment early,
/// cutting the end of the archive off.
@Suite("A sequential archive whose last GOP crosses the last plan boundary lists its whole tail")
struct SequentialBridgedTailPlaylistTests {

    /// 16 s, H.264 16x16 at 10 fps with keyframes at 0, 9 and 11 s, and silent mono Opus (bridged to
    /// FLAC) in 120 ms frames. The first GOP outlasts every packet the open samples, so a forward-only
    /// session knows one keyframe and plans the uniform 4 s stride (boundaries 0, 4, 8, 12). The cutter
    /// ends in seg2 ([9, 16)), while the flushed audio tail sits in plan seg3. Regenerate with:
    ///
    ///     ffmpeg -f lavfi -i "color=c=black:s=16x16:r=10:d=16" -f lavfi -i "anullsrc=r=48000:cl=mono" \
    ///       -map 0:v -map 1:a -c:v libx264 -preset ultrafast -profile:v baseline -crf 51 -g 1000 \
    ///       -sc_threshold 0 -force_key_frames "0,9,11" -x264-params bframes=0 -pix_fmt yuv420p \
    ///       -c:a libopus -b:a 6k -frame_duration 120 -ac 1 -t 16 -f matroska - > tail.mkv
    ///
    /// Written to a pipe so the file carries no Cues: the whole file fits the first read, and with its
    /// Cues in the buffer the plan would come out keyframe-aligned and hide the defect.
    private static let fixtureBase64 = [
        "GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcB/////////xFNm3Sxv4S8aizJTbuLU6uEFUmp",
        "ZlOsgaFNu4tTq4QWVK5rU6yB8U27jFOrhBJUw2dTrIIB3OwBAAAAAAAAYgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmp",
        "Zsu/hLjH+Nwq17GDD0JATYCNTGF2ZjYyLjEyLjEwMVdBjUxhdmY2Mi4xMi4xMDFzpJA0kss7xod4ugMjeGfAY/KcRImIQM9A",
        "AAAAAAAWVK5rQOW/hJ6CS2SuAQAAAAAAAHHXgQFzxYiAoAqYJZs2m5yBACK1nIN1bmSIgQCGj1ZfTVBFRzQvSVNPL0FWQ4OB",
        "ASPjg4QF9eEA4JCwgRC6gRCagQJVsIRVuYEBY6KlAULACv/hABVnQsAK2nsBEAAAAwAQAAADAUDxImoBAAVozgGXIK4BAAAA",
        "AAAAXNeBAnPFiM7OMF8gqYhDnIEAIrWcg3VuZIiBAIaGQV9PUFVTVqqDYy6gVruEBMS0AIOBAuGRn4EBtYhA53AAAAAAAGJk",
        "gRBjopNPcHVzSGVhZAEBOAGAuwAAAAAAElTDZ0CVv4Qb4HYic3OgY8CAZ8iaRaOHRU5DT0RFUkSHjUxhdmY2Mi4xMi4xMDFz",
        "c7NjwItjxYiAoAqYJZs2m2fIokWjh0VOQ09ERVJEh5VMYXZjNjIuMjguMTAxIGxpYngyNjRzc7NjwItjxYjOzjBfIKmIQ2fI",
        "okWjh0VOQ09ERVJEh5VMYXZjNjIuMjguMTAxIGxpYm9wdXMfQ7Z1RDe/hAXdYNDngQCjoYIAAIAaDgL5jsjhz5S+lx76gm6w",
        "Aissw4zYC9cFtr0Q0qNCaoEAAIAAAAJVBgX//1HcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYw",
        "NWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5v",
        "cmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MSBkZWJsb2NrPTA6MDowIGFuYWx5c2U9MDowIG1lPWRpYSBz",
        "dWJtZT0wIHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxp",
        "cz0wIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PTAgdGhyZWFk",
        "cz0xIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJs",
        "dXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTEwMDAga2V5aW50",
        "X21pbj0xMCBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTUxLjAgcWNvbXA9MC42MCBx",
        "cG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MACAAAAACWWIhDomKAAVwKONgQBkAAAAAAVBmiAy",
        "lKOfggB5gBkCKyzDjNgL1wW2vRDSAissw4zYC9cFtr0Q0qONgQDIAAAAAAVBmkA2lKOfggDxgBkCKyzDjNgL1wW2vRDSAiss",
        "w4zYC9cFtr0Q0qONgQEsAAAAAAVBmmA2lKOfggFpgBkCKyzDjNgL1wW2vRDSAissw4zYC9cFtr0Q0qONgQGQAAAAAAVBmoA2",
        "lKOfggHhgBkCKyzDjNgL1wW2vRDSAissw4zYC9cFtr0Q0qONgQH0AAAAAAVBmqA2lKOfggJZgBkCKyzDjNgL1wW2vRDSAiss",
        "w4zYC9cFtr0Q0qONgQJYAAAAAAVBmsA6lKONgQK8AAAAAAVBmuA6lKOfggLRgBkCKyzDjNgL1wW2vRDSAissw4zYC9cFtr0Q",
        "0qONgQMgAAAAAAVBmwA6lKOfggNJgBkCKyzDjNgL1wW2vRDSAissw4zYC9cFtr0Q0qONgQOEAAAAAAVBmyA6lKOfggPBgBkC",
        "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",
    ]
    private static let videoFrames = 160

    /// Video samples (track 1) across every fragment of a segment, from the `trun` sample counts.
    private static func videoSampleCount(_ segment: Data) -> Int {
        let bytes = [UInt8](segment)
        func u32(_ off: Int) -> Int {
            Int(bytes[off]) << 24 | Int(bytes[off + 1]) << 16 | Int(bytes[off + 2]) << 8 | Int(bytes[off + 3])
        }
        func boxes(_ range: Range<Int>) -> [(String, Range<Int>)] {
            var out: [(String, Range<Int>)] = []
            var off = range.lowerBound
            while off + 8 <= range.upperBound {
                let size = u32(off)
                guard size >= 8, off + size <= range.upperBound else { break }
                out.append((String(decoding: bytes[off + 4..<off + 8], as: UTF8.self), (off + 8)..<(off + size)))
                off += size
            }
            return out
        }
        var count = 0
        for (type, moof) in boxes(0..<bytes.count) where type == "moof" {
            for (t2, traf) in boxes(moof) where t2 == "traf" {
                var track = 0
                var samples = 0
                for (t3, body) in boxes(traf) {
                    if t3 == "tfhd" { track = u32(body.lowerBound + 4) }
                    if t3 == "trun" { samples += u32(body.lowerBound + 4) }
                }
                if track == 1 { count += samples }
            }
        }
        return count
    }

    @Test("the finished playlist lists every video frame and the whole duration", .timeLimit(.minutes(3)))
    func bridgedTailKeepsTheFinalSegment() async throws {
        let body = try #require(Data(base64Encoded: Self.fixtureBase64.joined()))
        let server = try #require(ScriptedOriginServer { _ in
            .init(status: 200, declaredLength: nil, close: true, body: body)
        })
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/tail.mkv")!
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false,
                                    sequentialOrigin: true, declaredDurationSeconds: 16)
        _ = try engine.start()
        defer { engine.stop() }
        let mediaURL = try #require(engine.mediaPlaylistURL)

        func playlistText() -> String { (try? String(contentsOf: mediaURL, encoding: .utf8)) ?? "" }
        try await waitFor { playlistText().contains("#EXT-X-ENDLIST") }
        let playlist = playlistText()

        let lines = playlist.split(whereSeparator: \.isNewline).map(String.init)
        let durations = lines.filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") }
        #expect(abs(durations.reduce(0, +) - 16) < 0.6,
                "EXTINF sums to \(durations.reduce(0, +)) s for a 16 s source:\n\(playlist)")

        var frames = 0
        for uri in lines where uri.hasSuffix(".mp4") && !uri.hasPrefix("#") {
            let data = try Data(contentsOf: mediaURL.deletingLastPathComponent().appendingPathComponent(uri))
            frames += Self.videoSampleCount(data)
        }
        #expect(frames == Self.videoFrames,
                "the listed segments carry \(frames) of \(Self.videoFrames) video frames:\n\(playlist)")
    }
}
