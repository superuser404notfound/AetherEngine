// AE#962: when the audio outlasts the video by more than the 60 s an index may stop short of the
// duration, the plan is the uniform stride and the audio-only tail is cut into its own segments. The
// last video packet waits for a successor to learn its duration, none ever comes, and the EOF flush
// used to route it into whichever segment was open by then: the LAST one, a minute of item time
// after the picture it carries. A session joining inside the tail took that stray sample as its
// first video, AVPlayer placed the item a minute later than the playlist did (playhead 120 s, item
// duration 187 s on a 127 s title), ended at once, and the in-place #287 re-seek never landed.
import Foundation
import Testing
@testable import AetherEngine

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(name)
}

private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: fixtureURL(name).path)
}

/// Per video fragment of a segment: its `tfdt` and its sample count. Track 1 is the video track.
private func videoRuns(_ segment: Data) -> [(decodeTime: UInt64, samples: Int)] {
    func u32(_ off: Int) -> UInt32 {
        segment.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: off, as: UInt32.self)) }
    }
    func boxes(_ range: Range<Int>) -> [(String, Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var off = range.lowerBound
        while off + 8 <= range.upperBound {
            let size = Int(u32(off))
            guard size >= 8, off + size <= range.upperBound else { break }
            let type = String(bytes: segment[off + 4..<off + 8], encoding: .isoLatin1) ?? "????"
            out.append((type, (off + 8)..<(off + size)))
            off += size
        }
        return out
    }
    var runs: [(UInt64, Int)] = []
    for (type, moof) in boxes(0..<segment.count) where type == "moof" {
        for (t2, traf) in boxes(moof) where t2 == "traf" {
            var track: UInt32 = 0
            var decodeTime: UInt64 = 0
            var samples = 0
            for (t3, body) in boxes(traf) {
                if t3 == "tfhd" { track = u32(body.lowerBound + 4) }
                if t3 == "tfdt" {
                    let version = segment[body.lowerBound]
                    decodeTime = version == 1
                        ? UInt64(u32(body.lowerBound + 4)) << 32 | UInt64(u32(body.lowerBound + 8))
                        : UInt64(u32(body.lowerBound + 4))
                }
                if t3 == "trun" { samples += Int(u32(body.lowerBound + 4)) }
            }
            if track == 1, samples > 0 { runs.append((decodeTime, samples)) }
        }
    }
    return runs
}

@Suite("AE#962: the last video sample of an audio-tailed title", .serialized)
struct Issue962AudioTailFinalVideoSampleTests {

    @Test("stays in the segment its picture belongs to",
          .enabled(if: fixtureExists("audio-tail.mkv"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clip"),
          .timeLimit(.minutes(3)))
    func finalVideoSampleIsNotCarriedIntoTheTail() async throws {
        let engine = HLSVideoEngine(url: fixtureURL("audio-tail.mkv"), dvModeAvailable: false)
        _ = try engine.start()
        defer { engine.stop() }
        let mediaURL = try #require(engine.mediaPlaylistURL)

        let playlist = try String(contentsOf: mediaURL, encoding: .utf8)
        let lines = playlist.split(whereSeparator: \.isNewline).map(String.init)
        let uris = lines.filter { $0.hasSuffix(".mp4") && !$0.hasPrefix("#") }
        let durations = lines.filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") }
        // The witness only exists on the uniform stride: a keyframe plan folds the tail into one segment.
        try #require(uris.count > 4, "expected the tail cut into stride segments:\n\(playlist)")
        try #require(durations.count == uris.count)

        var frames = 0
        var advertisedStart = 0.0
        for (uri, duration) in zip(uris, durations) {
            let data = try Data(contentsOf: mediaURL.deletingLastPathComponent().appendingPathComponent(uri))
            for run in videoRuns(data) {
                frames += run.samples
                // The init declares a 1/24000 video timescale for this 24 fps fixture.
                let seconds = Double(run.decodeTime) / 24000
                #expect(seconds >= advertisedStart - HLSVideoEngine.targetSegmentDuration,
                        "\(uri), advertised from \(advertisedStart) s, carries \(run.samples) video sample(s) decoded at \(seconds) s")
            }
            advertisedStart += duration
        }
        #expect(frames == 144, "the segments carry \(frames) of 144 video frames")
    }
}
