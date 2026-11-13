// Tests/AetherEngineTests/Issue259A53CaptionAxisTests.swift
// #259: A/53 in-picture captions are extracted in `finalizeAndWriteVideo`, which runs AFTER the
// pump has rebased the packet onto the output (item) axis with `videoShiftPts`. Everything
// downstream of the observer treats those timestamps as source PTS: the tap's cue buffer feeds
// `subtitleCues`, and the host renders that against `currentTime`, which folds the same shift
// back in. Handing the observer post-shift timestamps therefore displaces every A/53 caption by
// `playlistShiftSeconds`, and the shift is recomputed per producer session, so the error changes
// after every seek. The demuxable c608 tap (#77) and the SW-path A53 tap both feed source PTS;
// this pins the producer path to the same axis.
import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

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

/// The observer fires on the producer pump thread; the test reads from the main one.
private final class PTSCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    private var timeBase = AVRational(num: 0, den: 0)

    func append(_ pts: Int64, timeBase tb: AVRational) {
        lock.lock(); values.append(pts); timeBase = tb; lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func snapshot() -> [Int64] { lock.lock(); defer { lock.unlock() }; return values }
    func lastTimeBase() -> AVRational { lock.lock(); defer { lock.unlock() }; return timeBase }
}

@Suite("A53 caption timestamp axis", .serialized)
struct Issue259A53CaptionAxisTests {

    /// Source-axis pts of the first `limit` video packets carrying A/53 cc_data, in decode order.
    private func sourceA53PacketPTS(_ name: String, limit: Int) throws -> (pts: [Int64], timeBase: AVRational) {
        let demuxer = Demuxer()
        try demuxer.open(url: fixtureURL(name), profile: .playback)
        defer { demuxer.close() }
        let videoIdx = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIdx))
        let codecpar = try #require(stream.pointee.codecpar)
        let framing = A53SEIParser.nalFraming(
            codec: .h264,
            extradata: codecpar.pointee.extradata.map { UnsafePointer($0) },
            size: Int(codecpar.pointee.extradata_size))

        var out: [Int64] = []
        while out.count < limit, let pkt = try demuxer.readPacket() {
            var toFree: UnsafeMutablePointer<AVPacket>? = pkt
            defer { trackedPacketFree(&toFree) }
            guard Int(pkt.pointee.stream_index) == videoIdx,
                  let data = pkt.pointee.data, pkt.pointee.pts != Int64.min else { continue }
            let triplets = A53SEIParser.triplets(
                in: data, size: Int(pkt.pointee.size), codec: .h264, framing: framing)
            if !triplets.isEmpty { out.append(pkt.pointee.pts) }
        }
        return (out, stream.pointee.time_base)
    }

    @Test("The A53 observer is fed source PTS, not the shifted output timestamps",
          .enabled(if: fixtureExists("a53-captions.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the A/53 caption clip"),
          .timeLimit(.minutes(3)))
    func a53ObservationsStayOnTheSourceAxis() async throws {
        let witnessCount = 24
        let (expected, sourceTimeBase) = try sourceA53PacketPTS("a53-captions.mp4", limit: witnessCount)
        #expect(expected.count == witnessCount,
                "fixture must carry A/53 cc_data on every picture, got \(expected.count)")

        let engine = HLSVideoEngine(url: fixtureURL("a53-captions.mp4"), dvModeAvailable: false)
        // AE#418 round 5: the witness needs the axes to be apart, and the number that says so is the
        // muxer's own pair. `playlistShiftSeconds` states where AVPlayer places the segment since
        // 6.56.6, which is 0 on a clip started at its own beginning however far the output axis moved.
        let axisSeparation = MuxedAxisSeparation()
        engine.setNativeVideoFrameTimeObserver { axisSeparation.record($0) }
        let collector = PTSCollector()
        engine.a53CaptionObserverForSession = { _, pts, _, tb in
            collector.append(pts, timeBase: tb)
        }
        _ = try engine.start()
        defer { engine.stop() }
        let prov = try #require(engine.provider)
        #expect(prov.mediaSegment(at: 0) != nil)

        try await waitFor { collector.count >= witnessCount }
        let observed = Array(collector.snapshot().prefix(witnessCount))
        try #require(observed.count == witnessCount,
                     "producer emitted only \(observed.count)/\(witnessCount) A/53 observations")

        // Without a separation the witness proves nothing: the two axes coincide.
        let shift = axisSeparation.value ?? 0
        #expect(shift != 0, "fixture muxed on the source axis, the axis witness is vacuous")

        let tb = collector.lastTimeBase()
        #expect(tb.num == sourceTimeBase.num && tb.den == sourceTimeBase.den,
                "observer must report the source video time base, got \(tb.num)/\(tb.den)")

        let scale = tb.den > 0 ? Double(tb.num) / Double(tb.den) : 0
        let worst = zip(observed, expected).map { abs(Double($0 - $1) * scale) }.max() ?? 0
        let detail = "A53 timestamps are off the source axis by up to "
            + "\(String(format: "%.3f", worst))s (playlist shift \(String(format: "%.3f", shift))s); "
            + "observed \(observed.prefix(4)) expected \(expected.prefix(4))"
        #expect(observed == expected, "\(detail)")
    }
}

/// AE#418 round 5: the distance between the source axis and the axis the producer MUXED, read off
/// the frame pair. One number for the whole epoch, so the first frame answers it.
private final class MuxedAxisSeparation: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Double?

    func record(_ frame: NativeVideoFrameTime) {
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = CMTimeGetSeconds(frame.source) - CMTimeGetSeconds(frame.item) }
    }

    var value: Double? {
        lock.lock(); defer { lock.unlock() }; return first
    }
}
