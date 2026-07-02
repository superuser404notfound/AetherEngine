// Tests/AetherEngineTests/RestartTimelineContinuityTests.swift
// Restart timeline continuity (#32 renderer detach, #93 decoupling, restart audio desync):
// the loopback's contract with AVPlayer is "static VOD server", so a producer restart must
// reproduce a segment with the SAME media timeline the continuous run gave it. Historically a
// fresh muxer zero-based its timeline (restart segment k carried tfdt=0 while the playlist
// placed it at its plan offset) and the restart audio gate snapped audio onto the video seam,
// off the source frame grid. These tests pin the full contract on a real engine session:
// segment k produced continuously and segment k re-produced by a restart must match.
import Foundation
import Testing
@testable import AetherEngine

// MARK: - Minimal fMP4 reader (moof/traf: tfhd track id, tfdt base time, trun sample count)

private struct TrafSummary: Equatable, CustomStringConvertible {
    let trackID: UInt32
    let baseMediaDecodeTime: UInt64
    let sampleCount: Int
    var description: String { "track=\(trackID) tfdt=\(baseMediaDecodeTime) samples=\(sampleCount)" }
}

private enum FMP4 {
    static func boxes(in data: Data, range: Range<Int>) -> [(type: String, body: Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var off = range.lowerBound
        while off + 8 <= range.upperBound {
            let size = Int(readU32(data, off))
            guard size >= 8, off + size <= range.upperBound else { break }
            let type = String(bytes: data[off + 4..<off + 8], encoding: .isoLatin1) ?? "????"
            out.append((type, (off + 8)..<(off + size)))
            off += size
        }
        return out
    }

    static func readU32(_ d: Data, _ off: Int) -> UInt32 {
        d.withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
        }
    }

    static func readU64(_ d: Data, _ off: Int) -> UInt64 {
        d.withUnsafeBytes { raw in
            UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt64.self))
        }
    }

    static func trafSummaries(of segment: Data) -> [TrafSummary] {
        var out: [TrafSummary] = []
        for (type, body) in boxes(in: segment, range: 0..<segment.count) where type == "moof" {
            for (t2, b2) in boxes(in: segment, range: body) where t2 == "traf" {
                var trackID: UInt32 = 0
                var tfdt: UInt64 = 0
                var samples = 0
                for (t3, b3) in boxes(in: segment, range: b2) {
                    switch t3 {
                    case "tfhd":
                        trackID = readU32(segment, b3.lowerBound + 4)
                    case "tfdt":
                        let version = segment[b3.lowerBound]
                        tfdt = version == 1
                            ? readU64(segment, b3.lowerBound + 4)
                            : UInt64(readU32(segment, b3.lowerBound + 4))
                    case "trun":
                        samples += Int(readU32(segment, b3.lowerBound + 4))
                    default:
                        break
                    }
                }
                out.append(TrafSummary(trackID: trackID, baseMediaDecodeTime: tfdt, sampleCount: samples))
            }
        }
        return out
    }

    /// mfhd sequence_number counts fragments PER MUXER INSTANCE, so it legitimately differs
    /// between a continuous run and a restart; zero it so byte comparison checks everything else.
    static func normalizingFragmentSequence(_ segment: Data) -> Data {
        var d = segment
        for (type, body) in boxes(in: segment, range: 0..<segment.count) where type == "moof" {
            for (t2, b2) in boxes(in: segment, range: body) where t2 == "mfhd" {
                for i in 0..<4 { d[b2.lowerBound + 4 + i] = 0 }
            }
        }
        return d
    }
}

// MARK: - Fixtures

/// Fixtures/ is local-only by design (gitignored; Scripts/fetch-fixtures.sh regenerates the
/// synthetic clips). The tests skip via `.enabled(if:)` when a clip is absent, e.g. on CI.
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

private func inode(of url: URL) -> UInt64? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let num = attrs[.systemFileNumber] as? NSNumber else { return nil }
    return num.uint64Value
}

// MARK: - Tests

@Suite("Restart timeline continuity", .serialized)
struct RestartTimelineContinuityTests {

    /// The core witness: segment 1 produced continuously vs re-produced by a restart at
    /// segment 1 must carry the identical media timeline (tfdt per track, sample counts),
    /// and the bytes must match modulo the per-muxer mfhd sequence number.
    @Test("A restart reproduces a segment with the continuous run's timeline",
          .enabled(if: fixtureExists("restart-witness-av.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clip"),
          .timeLimit(.minutes(2)))
    func restartReproducesContinuousTimeline() throws {
        let engine = HLSVideoEngine(url: fixtureURL("restart-witness-av.mp4"), dvModeAvailable: false)
        _ = try engine.start()
        defer { engine.stop() }
        let prov = try #require(engine.provider)

        #expect(prov.mediaSegment(at: 0) != nil)
        let continuous = try #require(prov.mediaSegment(at: 1))
        let continuousTrafs = FMP4.trafSummaries(of: continuous)
        #expect(continuousTrafs.count == 2, "fixture must carry video + audio: \(continuousTrafs)")
        // The continuous segment 1 must sit at its playlist offset, not at 0: a zero tfdt here
        // would make the whole witness vacuous.
        #expect(continuousTrafs.allSatisfy { $0.baseMediaDecodeTime > 0 }, "\(continuousTrafs)")

        let segURL = try #require(prov.mediaSegmentURL(at: 1))
        let inodeBefore = try #require(inode(of: segURL))

        engine.requestRestart(at: 1)

        // The restarted producer rewrites seg-1 via rename(2), which changes the inode.
        let deadline = Date().addingTimeInterval(30)
        var rewritten = false
        while Date() < deadline {
            if let url = prov.mediaSegmentURL(at: 1), inode(of: url) != inodeBefore {
                rewritten = true
                break
            }
            usleep(50_000)
        }
        try #require(rewritten, "restarted producer did not rewrite seg-1 within 30s")

        let restarted = try #require(prov.mediaSegment(at: 1))
        let restartedTrafs = FMP4.trafSummaries(of: restarted)

        #expect(restartedTrafs == continuousTrafs,
                "restart timeline diverged: continuous=\(continuousTrafs) restart=\(restartedTrafs)")
        #expect(FMP4.normalizingFragmentSequence(restarted) == FMP4.normalizingFragmentSequence(continuous),
                "restart segment bytes diverged beyond the mfhd sequence number (continuous \(continuous.count) B vs restart \(restarted.count) B)")
    }

    /// A restart teardown leaves the in-flight segment PARTIAL: its content is shorter than the
    /// playlist's EXTINF, and video/audio end at different interleave-drain points. Adopting it
    /// caches a lie under a full segment's index; byte-budgeted retention then keeps it replayable
    /// (device: seeking back to 0 played a teardown-partial with ~2 s of A/V split). VOD must only
    /// adopt the natural EOF tail (a legitimately short final segment); live keeps adopting, since
    /// its playlist advertises the ACTUAL duration via the finalize report.
    @Test("Teardown adoption policy: VOD adopts only the natural EOF tail; live always adopts")
    func teardownAdoptionPolicy() {
        typealias Reason = HLSSegmentProducer.PumpExitReason
        let abnormal: [Reason] = [.stopRequested, .readError(code: -5), .muxerFailed,
                                  .backpressureWedge, .segmentStall, .sourceReplay,
                                  .keyframeStarvation]
        #expect(HLSSegmentProducer.shouldAdoptTeardownSegment(exitReason: .eof, isLive: false))
        for reason in abnormal {
            #expect(!HLSSegmentProducer.shouldAdoptTeardownSegment(exitReason: reason, isLive: false),
                    "VOD must discard the partial on \(reason)")
        }
        for reason in abnormal + [.eof] {
            #expect(HLSSegmentProducer.shouldAdoptTeardownSegment(exitReason: reason, isLive: true),
                    "live must keep adopting on \(reason)")
        }
    }

    /// Sources whose audio leads the video at head-of-stream: the inherited audio shift maps the
    /// leading audio to negative output timestamps, which the muxer no longer absorbs
    /// (avoid_negative_ts=disabled; tfdt is unsigned). The producer must drop that pre-roll so
    /// segment 0 still opens with sane, non-huge timestamps.
    @Test("Leading head-of-stream audio never produces a negative/wrapped tfdt",
          .enabled(if: fixtureExists("restart-witness-leadaudio.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clip"),
          .timeLimit(.minutes(2)))
    func leadingAudioIsGuardedAtHeadOfStream() throws {
        let engine = HLSVideoEngine(url: fixtureURL("restart-witness-leadaudio.mp4"), dvModeAvailable: false)
        _ = try engine.start()
        defer { engine.stop() }
        let prov = try #require(engine.provider)

        let seg0 = try #require(prov.mediaSegment(at: 0))
        let trafs = FMP4.trafSummaries(of: seg0)
        #expect(trafs.count == 2, "fixture must carry video + audio: \(trafs)")
        for traf in trafs {
            // A negative timestamp written into the unsigned tfdt shows up as a huge value;
            // one source second is comfortably above any sane head-of-stream base time.
            #expect(traf.baseMediaDecodeTime < 100_000,
                    "head-of-stream tfdt out of range (negative wrap?): \(traf)")
        }
    }
}

// MARK: - Subtitle pump tap (Sodalite#32)

@Suite("Subtitle pump tap", .serialized)
struct SubtitlePumpTapTests {

    /// The pump already reads the source's full interleave; tapping the text-subtitle streams there
    /// must fill the native cue stores for the produced region with NO side reader (this bare
    /// HLSVideoEngine layer has none), and the served .vtt window must carry those cues.
    @Test("Producing segments fills the native cue stores via the pump tap alone",
          .enabled(if: fixtureExists("restart-witness-subs.mkv"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clip"),
          .timeLimit(.minutes(2)))
    func pumpTapFillsStores() throws {
        let engine = HLSVideoEngine(url: fixtureURL("restart-witness-subs.mkv"), dvModeAvailable: false)
        engine.requestNativeSubtitleTrack()
        _ = try engine.start()
        defer { engine.stop() }
        let prov = try #require(engine.provider)

        #expect(prov.mediaSegment(at: 0) != nil)
        #expect(prov.mediaSegment(at: 1) != nil)

        let store = try #require(engine.nativeSubtitleCueStoresForSession.first)
        let deadline = Date().addingTimeInterval(10)
        while store.cueCount == 0, Date() < deadline { usleep(50_000) }
        #expect(store.cueCount > 0, "pump tap delivered no cues for the produced region")

        let vtt = try #require(prov.nativeSubtitleVTT(ordinal: 0, segmentIndex: 0))
        #expect(vtt.contains("-->"), "served .vtt window for seg-0 carries no cues")
        #expect(vtt.contains("First cue"))
    }
}
