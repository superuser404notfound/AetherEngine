// A sequential origin advertises its segments from the VIDEO cut ledger: a segment's EXTINF is the
// distance between two keyframe-gated opens, and a plan index no keyframe opened is a zero-duration
// hole with no URI. Audio used to be routed by time against the plan instead, so on a source whose
// GOP is longer than the 4 s stride it opened that hole on its own, the video after it went into a
// file the playlist never listed, and AVPlayer stalled at the end of seg0 (a remote MKV with an
// 11.3 s first GOP lost 4 to 11 s). The same hole arrived before seg0's capture had, and the report
// funnel anchored on it, so every later report was refused as out of order and the playlist stayed
// empty. Both are witnessed here by counting what the finished playlist actually carries.
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

/// Video samples (track 1) across every fragment of a segment, from the `trun` sample counts.
private func videoSampleCount(_ segment: Data) -> Int {
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
    var count = 0
    for (type, moof) in boxes(0..<segment.count) where type == "moof" {
        for (t2, traf) in boxes(moof) where t2 == "traf" {
            var track: UInt32 = 0
            var samples = 0
            for (t3, body) in boxes(traf) {
                if t3 == "tfhd" { track = u32(body.lowerBound + 4) }
                if t3 == "trun" { samples += Int(u32(body.lowerBound + 4)) }
            }
            if track == 1 { count += samples }
        }
    }
    return count
}

@Suite("Sequential origin with a GOP longer than the stride", .serialized)
struct SequentialLongGOPPlaylistTests {

    /// `aac` is passed through, `pcm` goes through the FLAC bridge (the reporter's Vorbis did); the two
    /// route their packets to segments at different sites, and both used to route by time.
    @Test("the finished playlist lists every video frame and the whole duration",
          .enabled(if: fixtureExists("long-first-gop-aac.mkv") && fixtureExists("long-first-gop-pcm.mkv"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clips"),
          .timeLimit(.minutes(3)),
          arguments: ["aac", "pcm"])
    func longFirstGOPLosesNothing(audio: String) async throws {
        // Served the way the reporting origin served it: `Range` ignored, no length, one plain 200.
        // Over a seekable file the plan would come from the Cues and cut on the keyframes, which
        // hides the defect; a forward-only source never reads them and gets the uniform stride.
        let name = "long-first-gop-\(audio).mkv"
        let body = try Data(contentsOf: fixtureURL(name))
        let server = try #require(ScriptedOriginServer { _ in
            .init(status: 200, declaredLength: nil, close: true, body: body)
        })
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/\(name)")!
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false,
                                    sequentialOrigin: true, declaredDurationSeconds: 30)
        _ = try engine.start()
        defer { engine.stop() }
        let mediaURL = try #require(engine.mediaPlaylistURL)

        func playlistText() -> String { (try? String(contentsOf: mediaURL, encoding: .utf8)) ?? "" }
        try await waitFor { playlistText().contains("#EXT-X-ENDLIST") }
        let playlist = playlistText()

        let lines = playlist.split(whereSeparator: \.isNewline).map(String.init)
        let durations = lines.filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst("#EXTINF:".count).split(separator: ",").first ?? "") }
        let uris = lines.filter { $0.hasSuffix(".mp4") && !$0.hasPrefix("#") }
        #expect(!uris.isEmpty)
        #expect(abs(durations.reduce(0, +) - 30) < 0.5,
                "EXTINF sums to \(durations.reduce(0, +)) s for a 30 s source:\n\(playlist)")

        var frames = 0
        for uri in uris {
            let data = try Data(contentsOf: mediaURL.deletingLastPathComponent().appendingPathComponent(uri))
            frames += videoSampleCount(data)
        }
        #expect(frames == 720, "the listed segments carry \(frames) of 720 video frames:\n\(playlist)")
    }
}

/// Device log 2026-09-27: an AirPlay receiver had prefetched to seg20, the hop back swapped in a
/// loopback item at 22.8 s, and its first fetch was seg5. The contiguity scan from there read the
/// hole the cutter left at seg7 as a gap, asked for a restart, and the sequential origin's refusal
/// published "Source cannot be repositioned" over a session that had every segment it needed.
@Suite("A sequential origin serves a resident backward target from the cache")
struct SequentialBackwardTargetTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _indices: [Int] = []
        func record(_ i: Int) { lock.lock(); _indices.append(i); lock.unlock() }
        var indices: [Int] { lock.lock(); defer { lock.unlock() }; return _indices }
    }

    @Test("a backward jump across a cutter hole restarts nothing")
    func backwardAcrossHoleKeepsProducer() throws {
        let cache = SegmentCache(forwardWindow: 60, backwardWindow: 60)
        defer { cache.close() }
        let recorder = Recorder()
        let plan = (0..<30).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
        let provider = VideoSegmentProvider(
            cache: cache, segments: plan, codecsString: "avc1.64001F,fLaC", supplementalCodecs: nil,
            resolution: (1280, 720), videoRange: .sdr, frameRate: 23.976, hdcpLevel: nil,
            sourceBitrate: 3_000_000, sequentialAppendPlaylist: true,
            restartHandler: { recorder.record($0) })
        for i in 0...20 {
            let hole = i == 1 || i == 7
            provider.appendSequentialSegmentDuration(index: i, durationSeconds: hole ? 0 : 4)
            if !hole { cache.store(index: i, data: Data(repeating: 0x5A, count: 8)) }
        }

        _ = provider.mediaSegmentURL(at: 20)
        let url = provider.mediaSegmentURL(at: 5)
        #expect(url != nil)
        #expect(recorder.indices.isEmpty, "restart requested at \(recorder.indices)")
    }
}
