// Tests/AetherEngineTests/PlanBoundaryAxisTests.swift
// AE#561: a keyframe-aligned plan's boundaries ARE the container's index entries, and containers
// disagree about what an entry's timestamp means (mov/mp4 sample tables hold decode times, Matroska
// Cues hold presentation times). The cutter gate has to compare a packet on the plan's own axis.
// Fed a decode timestamp against presentation boundaries, no IRAP ever reached its own boundary:
// the gate never opened on it, audio (routed by boundary, ungated) opened the segment instead, and
// every segment began mid-GOP with no random-access point a cold decode could start on. AVPlayer
// answered that with -19602 the first time it had to decode FROM a segment boundary instead of
// through one.
import Foundation
import Testing
@testable import AetherEngine

// MARK: - Pure decisions

@Suite("Plan boundary axis")
struct PlanBoundaryAxisDecisionTests {

    @Test("Matroska Cues are presentation times, every other index is decode times")
    func containerMapping() {
        #expect(PlanBoundaryAxis.forContainer(formatName: "matroska,webm") == .presentation)
        #expect(PlanBoundaryAxis.forContainer(formatName: "matroska") == .presentation)
        #expect(PlanBoundaryAxis.forContainer(formatName: "webm") == .presentation)
        #expect(PlanBoundaryAxis.forContainer(formatName: "mov,mp4,m4a,3gp,3g2,mj2") == .decode)
        #expect(PlanBoundaryAxis.forContainer(formatName: "mpegts") == .decode)
        // An unrecognised or missing format keeps the behaviour that predates the axis rather than
        // inheriting a guess.
        #expect(PlanBoundaryAxis.forContainer(formatName: "flv") == .decode)
        #expect(PlanBoundaryAxis.forContainer(formatName: nil) == .decode)
    }

    @Test("Each axis picks its own timestamp")
    func timestampPick() {
        #expect(PlanBoundaryAxis.decode.timestamp(dts: 100, pts: 142) == 100)
        #expect(PlanBoundaryAxis.presentation.timestamp(dts: 100, pts: 142) == 142)
    }

    @Test("A missing timestamp falls back to the other axis, never to Int64.min")
    func missingTimestampFallsBack() {
        #expect(PlanBoundaryAxis.decode.timestamp(dts: Int64.min, pts: 142) == 142)
        #expect(PlanBoundaryAxis.presentation.timestamp(dts: 100, pts: Int64.min) == 100)
    }

    /// The gate advances only on a keyframe that has REACHED its boundary. With the boundary stamped
    /// on one axis and the packet on the other, the IRAP that owns the boundary misses it by its
    /// composition offset, so the cutter walks past the index the playlist keeps advertising.
    @Test("A keyframe reaches its own boundary only when both are on the same axis")
    func keyframeReachesItsOwnBoundary() {
        // One IRAP per 21 frames at 1/16000, composition offset 2 frames: presentation 70000,
        // decode 68672. The plan came from Matroska Cues, so its boundary is the presentation time.
        let boundaries: [Int64] = [0, 70000, 140000]
        var matched = VODSegmentCutter(sourceBoundaries: boundaries, planAnchorPts: 0, baseIndex: 0)
        #expect(matched.index(pts: PlanBoundaryAxis.presentation.timestamp(dts: 68672, pts: 70000),
                              isKeyframe: true) == 1)

        var mismatched = VODSegmentCutter(sourceBoundaries: boundaries, planAnchorPts: 0, baseIndex: 0)
        #expect(mismatched.index(pts: PlanBoundaryAxis.decode.timestamp(dts: 68672, pts: 70000),
                                 isKeyframe: true) == 0,
                "the AE#561 shape: the IRAP that owns this boundary does not reach it")
    }
}

// MARK: - Witness on a real session

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

/// Whether the first VIDEO sample of each fragment in `segment` is a sync sample, in fragment order.
///
/// A sample is non-sync when bit 16 of its `sample_flags` is set. The flags can arrive three ways
/// and the first sample reads them in this precedence: `trun`'s `first_sample_flags` (0x04), then
/// its per-sample flags (0x400), then `tfhd`'s `default_sample_flags` (0x20).
private func firstSampleIsSyncPerFragment(_ segment: Data, videoTrackID: UInt32 = 1) -> [Bool] {
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

    var out: [Bool] = []
    for (type, moof) in boxes(0..<segment.count) where type == "moof" {
        for (t2, traf) in boxes(moof) where t2 == "traf" {
            var trackID: UInt32 = 0
            var defaultFlags: UInt32?
            var firstFlags: UInt32?
            for (t3, body) in boxes(traf) {
                switch t3 {
                case "tfhd":
                    let flags = u32(body.lowerBound) & 0xFF_FFFF
                    var p = body.lowerBound + 4
                    trackID = u32(p); p += 4
                    if flags & 0x01 != 0 { p += 8 }
                    if flags & 0x02 != 0 { p += 4 }
                    if flags & 0x08 != 0 { p += 4 }
                    if flags & 0x10 != 0 { p += 4 }
                    if flags & 0x20 != 0 { defaultFlags = u32(p) }
                case "trun":
                    let flags = u32(body.lowerBound) & 0xFF_FFFF
                    var p = body.lowerBound + 8
                    if flags & 0x01 != 0 { p += 4 }
                    if flags & 0x04 != 0 {
                        firstFlags = u32(p)
                    } else if flags & 0x400 != 0 {
                        // Per-sample flags: walk the first record's preceding fields.
                        var q = p
                        if flags & 0x100 != 0 { q += 4 }
                        if flags & 0x200 != 0 { q += 4 }
                        firstFlags = u32(q)
                    }
                default:
                    break
                }
            }
            guard trackID == videoTrackID else { continue }
            let effective = firstFlags ?? defaultFlags ?? 0
            out.append(effective & 0x0001_0000 == 0)
        }
    }
    return out
}

@Suite("Segment opens on a random-access point", .serialized)
struct SegmentOpensOnIRAPTests {

    /// The witness: the SAME HEVC stream, once as Matroska and once as MP4, has to produce segments
    /// that open on an IRAP in both. Before AE#561 the MKV opened every segment on a dependent
    /// picture, with its first IRAP a full IRAP interval inside the segment, while the MP4 (whose
    /// index entries already matched the axis the gate compared) was correct.
    @Test("Every produced segment opens on a sync sample, in both containers",
          .enabled(if: fixtureExists("cue-axis-bframes.mkv") && fixtureExists("cue-axis-bframes.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the witness clips"),
          .timeLimit(.minutes(3)),
          arguments: ["cue-axis-bframes.mkv", "cue-axis-bframes.mp4"])
    func segmentsOpenOnSyncSample(fixture: String) throws {
        let engine = HLSVideoEngine(url: fixtureURL(fixture), dvModeAvailable: false)
        let playbackURL = try engine.start()
        defer { engine.stop() }
        var comps = try #require(URLComponents(url: playbackURL.deletingLastPathComponent(),
                                               resolvingAgainstBaseURL: false))
        comps.query = nil
        let base = try #require(comps.url)

        // Fetched over the loopback and sequentially, both on purpose and both for the same reason
        // `aetherctl segverify` does it: a sequential fetch is what advances the producer's consumer
        // target (it parks otherwise), and jumping straight to a deeper index triggers a producer
        // restart whose keyframe gate re-anchors a clean IRAP, hiding exactly the defect under test.
        // seg0 is fetched but not judged: its opening fragment is the muxer's primed moov fragment,
        // a shape both containers share.
        var judged = 0
        for index in 0...7 {
            guard let data = try? Data(contentsOf: base.appendingPathComponent("seg\(index).mp4"))
            else { break }   // past the plan's tail; the clip's segment count is not the subject
            guard index > 0 else { continue }
            judged += 1
            let sync = firstSampleIsSyncPerFragment(data)
            #expect(!sync.isEmpty, "\(fixture): seg\(index) carries no video fragment")
            #expect(sync.first == true,
                    "\(fixture): seg\(index) opens on a dependent picture, so nothing in it can start a decode run (AE#561)")
        }
        #expect(judged >= 2, "\(fixture): only \(judged) segment(s) past seg0 were served, too few to witness anything")
    }
}
