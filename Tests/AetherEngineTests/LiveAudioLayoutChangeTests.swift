import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// A live channel that carries AC-3 2.0 during ads and 5.1 during the programme on the same PID. The
/// fMP4 `dac3` box is written once per init from a parsed frame, so a session that started on the 2.0
/// part stayed 2.0 after the programme switched to 5.1. The producer now cuts at the next keyframe and
/// rotates to a versioned init primed with a frame in the new layout.
///
/// The fixture is 4 s of AC-3 2.0 followed by 4 s of AC-3 5.1, H.264 on 0x100 and AC-3 on 0x101 in both
/// halves, the second half shifted by 4 s so the clock runs on. Regenerate with (`CL`=stereo, `O`=0,
/// `B`=64k, then `CL`=5.1, `O`=4, `B`=192k, and concatenate the two files):
///
///     ffmpeg -f lavfi -i "color=c=black:s=16x16:r=2:d=4" -f lavfi -i "anullsrc=r=48000:cl=CL" \
///       -t 4 -c:v libx264 -preset ultrafast -profile:v baseline -crf 51 -g 2 -keyint_min 2 \
///       -sc_threshold 0 -x264-params "bframes=0:repeat-headers=1" -pix_fmt yuv420p -c:a ac3 -b:a B \
///       -streamid 0:0x100 -streamid 1:0x101 -output_ts_offset O -f mpegts \
///       -mpegts_service_type digital_tv -pat_period 0.5 out.ts
///
/// and store raw DEFLATE (`zlib.compressobj(9, zlib.DEFLATED, -15)`) as base64.
@Suite("Live AC-3 layout change: new init with the new dac3", .serialized, .timeLimit(.minutes(3)))
struct LiveAudioLayoutChangeTests {

    // MARK: - Header parsing

    private static func bits(_ fields: [(value: Int, width: Int)]) -> [UInt8] {
        var out: [UInt8] = []
        var acc = 0
        var count = 0
        for field in fields {
            for shift in stride(from: field.width - 1, through: 0, by: -1) {
                acc = acc << 1 | (field.value >> shift) & 1
                count += 1
                if count == 8 {
                    out.append(UInt8(acc))
                    acc = 0
                    count = 0
                }
            }
        }
        if count > 0 { out.append(UInt8(acc << (8 - count))) }
        return out
    }

    /// AC-3 sync frame header up to `lfeon`, 48 kHz, bsid 8.
    private static func ac3Header(codingMode: Int, lfe: Bool) -> [UInt8] {
        var fields: [(value: Int, width: Int)] = [(0x0B77, 16), (0, 16), (0, 2), (0x1C, 6), (8, 5), (0, 3),
                                                  (codingMode, 3)]
        if codingMode & 1 != 0, codingMode != 1 { fields.append((0, 2)) }
        if codingMode & 4 != 0 { fields.append((0, 2)) }
        if codingMode == 2 { fields.append((0, 2)) }
        fields.append((lfe ? 1 : 0, 1))
        return bits(fields) + [0, 0]
    }

    /// One 8-byte E-AC-3 sync frame, 48 kHz, six blocks, bsid 16.
    private static func eac3Frame(streamType: Int, codingMode: Int, lfe: Bool) -> [UInt8] {
        let header = bits([(0x0B77, 16), (streamType, 2), (0, 3), (3, 11), (0, 2), (3, 2),
                           (codingMode, 3), (lfe ? 1 : 0, 1), (16, 5)])
        return header + [UInt8](repeating: 0, count: 8 - header.count)
    }

    @Test("AC-3 2.0 and 5.1 headers read as different layouts")
    func ac3Layouts() throws {
        let stereo = try #require(AC3FrameLayout(packet: Self.ac3Header(codingMode: 2, lfe: false)))
        let surround = try #require(AC3FrameLayout(packet: Self.ac3Header(codingMode: 7, lfe: true)))
        #expect(stereo.channelLayoutLabel == "2.0")
        #expect(surround.channelLayoutLabel == "5.1")
        #expect(stereo != surround)
        #expect(AC3FrameLayout(packet: Self.ac3Header(codingMode: 2, lfe: false)) == stereo,
                "the same header twice is no change")
        #expect(AC3FrameLayout(packet: Self.ac3Header(codingMode: 3, lfe: false))?.channelLayoutLabel == "3.0")
    }

    @Test("E-AC-3 substreams in one packet are all read")
    func eac3Substreams() throws {
        let independent = Self.eac3Frame(streamType: 0, codingMode: 7, lfe: true)
        let dependent = Self.eac3Frame(streamType: 1, codingMode: 2, lfe: false)
        let bed = try #require(AC3FrameLayout(packet: independent))
        let withDependent = try #require(AC3FrameLayout(packet: independent + dependent))
        #expect(bed.substreams.count == 1)
        #expect(withDependent.substreams.count == 2)
        #expect(bed != withDependent, "a dependent substream appearing changes dec3")
        #expect(bed.substreams[0].bitstreamID == 16)
        #expect(bed != AC3FrameLayout(packet: Self.eac3Frame(streamType: 0, codingMode: 2, lfe: false)))
    }

    @Test("anything that is not an AC-3 or E-AC-3 sync frame has no layout")
    func notAC3() {
        #expect(AC3FrameLayout(packet: [0xFF, 0xF1, 0x50, 0x80, 0x00, 0x1F, 0xFC, 0x00]) == nil, "ADTS")
        #expect(AC3FrameLayout(packet: [0x0B, 0x77, 0x00]) == nil, "truncated")
        #expect(AC3FrameLayout(packet: [0xF8, 0x72, 0x6F, 0xBA, 0, 0, 0, 0]) == nil, "TrueHD major sync")
    }

    // MARK: - Through the producer

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var exit: HLSSegmentProducer.PumpExitReason?
        private var finalized: [(index: Int, discontinuous: Bool)] = []
        func finish(_ reason: HLSSegmentProducer.PumpExitReason) { lock.withLock { exit = reason } }
        func segment(_ index: Int, _ discontinuous: Bool) {
            lock.withLock { finalized.append((index, discontinuous)) }
        }
        var reason: HLSSegmentProducer.PumpExitReason? { lock.withLock { exit } }
        var segments: [(index: Int, discontinuous: Bool)] { lock.withLock { finalized } }
    }

    private struct Dac3: Equatable {
        let codingMode: Int
        let lfeOn: Bool
    }

    /// ETSI TS 102 366 F.4: fscod(2) bsid(5) bsmod(3) acmod(3) lfeon(1) bit_rate_code(5) reserved(5).
    private static func dac3(in initSegment: Data?) -> Dac3? {
        guard let initSegment, let box = initSegment.range(of: Data("dac3".utf8)),
              box.upperBound + 3 <= initSegment.endIndex else { return nil }
        let second = initSegment[box.upperBound + 1]
        return Dac3(codingMode: Int(second >> 3) & 7, lfeOn: (second >> 2) & 1 == 1)
    }

    private struct Run {
        let exit: String?
        let initDac3: Dac3?
        /// The `dac3` of the init each finalized segment decodes against, in segment order.
        let segments: [(index: Int, dac3: Dac3?, discontinuous: Bool)]
    }

    private func run(_ bytes: Data) async throws -> Run {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: bytes), formatHint: "mpegts",
                         profile: DemuxerOpenProfile.playback.withProbeBudget(probesize: 32 * 1024,
                                                                              maxAnalyzeDuration: 1_000_000))
        let videoIndex = demuxer.videoStreamIndex
        let audioIndex = demuxer.audioStreamIndex
        let video = try #require(demuxer.stream(at: videoIndex))
        let audioStream = try #require(demuxer.stream(at: audioIndex))
        #expect(audioStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_AC3)
        let audio = HLSSegmentProducer.AudioConfig(
            codecpar: UnsafePointer(audioStream.pointee.codecpar),
            timeBase: audioStream.pointee.time_base, sourceStreamIndex: audioIndex,
            inputTimeBase: audioStream.pointee.time_base, sourceTimeBase: audioStream.pointee.time_base,
            bridge: nil)
        let cache = SegmentCache(forwardWindow: 64, backwardWindow: 64)
        let producer = try HLSSegmentProducer(
            demuxer: demuxer, videoStreamIndex: videoIndex,
            video: .init(codecpar: UnsafePointer(video.pointee.codecpar),
                         timeBase: video.pointee.time_base, codecTagOverride: "avc1"),
            audio: audio, cache: cache, baseIndex: 0, targetSegmentDurationSeconds: 1,
            videoFallbackDurationPts: 45_000, desiredFirstVideoTfdtPts: 0,
            segmentBoundaries: [], isLive: true, bufferAheadSegments: 64)
        let outcome = Outcome()
        producer.onPumpFinished = { outcome.finish($0) }
        producer.onLiveTimelineRebase = { _, _ in }
        producer.onLiveSegmentFinalized = { index, _, _, discontinuous in outcome.segment(index, discontinuous) }
        producer.start()
        defer {
            producer.stop()
            cache.close()
        }
        try await waitFor { outcome.reason != nil }
        let segments = outcome.segments.map { segment in
            (index: segment.index,
             dac3: Self.dac3(in: cache.initData(versionID: cache.initVersionID(forSegment: segment.index))),
             discontinuous: segment.discontinuous)
        }
        return Run(exit: outcome.reason?.description,
                   initDac3: Self.dac3(in: cache.initData(versionID: 0)),
                   segments: segments)
    }

    private static let stereo = Dac3(codingMode: 2, lfeOn: false)
    private static let surround = Dac3(codingMode: 7, lfeOn: true)

    @Test("a 2.0 start gets a new init with the 5.1 dac3 once the programme switches to 5.1")
    func stereoThenSurroundGetsNewInit() async throws {
        let run = try await run(Self.stereoThenSurround)
        #expect(run.exit == "eof")
        #expect(run.initDac3 == Self.stereo, "the session init describes the 2.0 start")
        let last = try #require(run.segments.last)
        #expect(last.dac3 == Self.surround,
                "the last segment must decode against a 5.1 dac3, got \(String(describing: last.dac3))")
        let switched = run.segments.filter { $0.dac3 == Self.surround }
        let first = try #require(switched.first)
        #expect(first.discontinuous, "the init change sits behind an EXT-X-DISCONTINUITY")
        #expect(switched.dropFirst().allSatisfy { !$0.discontinuous }, "one rotation, not one per segment")
        #expect(run.segments.prefix { $0.dac3 == Self.stereo }.count >= 3, "the 2.0 part keeps the session init")
    }

    // MARK: - Fixture

    private static func inflate(_ lines: [String]) -> Data {
        let compressed = Data(base64Encoded: lines.joined())!
        return try! (compressed as NSData).decompressed(using: .zlib) as Data
    }

    private static let stereoThenSurround = inflate([
            "7d0PbJz3Xcfx5/KvSaOuz9/7/+dJS0tGE/vufL44js+xm3UOEhWWBgVNgtvj82P78P3z3aW2u6q4bYQ6DVo2TWOkbOsmTQIBYp2g",
            "BdJWQQKCkOhUDY10bSEh0KmgpbGCRMdKze+52EkeoqkODs69pZ8jnZ9/99wvz3PP87w+3+d+vrERTVXuv3iPEvgLRVkJrCiB95fM",
            "o3pgx8c/Xm2407s+4TYfLpfcdGb+0SN/u9JdP2Mjiqoo37yj03YlcFH5qee3fWuF8TM2Ltq+5ZuJTtvPKReVmPfw+LnAxR3bt40e",
            "2d/36vj7L3Vr20eV9G3jivLp9x/ztvtZRVla2r5Hue3NPd7orove4/T9p27/3qcDYv9sVToPI8t3/Yo3Y+bVwG/Z4veO7SsrD775",
            "wDsvv/360Re/uO+M/frdF95dyOZz9n67VG+6dibfbzf7stk+O50bSJcm0mLG0R6xQO+D4w+M7c/Zow8dEUtOuiUx40i9sVhxp9p2",
            "Np3u259NZ/vFxJl2uzHY2zs/P9/zcHnSrVecWs9YQNHqzele75V6ZtrViliu3miX67XWoF1yJpxSIW033alCxp50Jyr10mwhPSj+",
            "2U7NqSy2XG/MrrqFybJjt45NiKG03WgtisXFY7E5Wcj0pMUi4sGulhfcyaK3Lu8ZxaZTm3YLmbxdmmnWq05RPDVjt5tupVJuiSUG",
            "FgYmS20xUJqrisdJ15l8pF5zC9nMvkzGnnJa7aJou95ozZYb4omrK5lrFOtTUy3Xe2J7pime1BIzK/X6rDMjRopXp7Uq4jC+OiFt",
            "15qdlymVq07ba0q51nabFUcsJKZPVI41ncViqV5tOJ1Gie3TbjrlmliFWLDpeMtMNZ2q661q3i1Pz7QbYmjWXRSzC9nVgWK1XBMj",
            "rZIr2t43qmz0nVdzS8e85nSa4G3aptua8XZYqVBqTtnVCbE9vT0iRgr9Yk/Yc97/oJDuyYvBhteYzm9noZA/KAZabbdRyNnlhtg5",
            "4i0g9l1O7Oi5QlpZEu9Q96njg/fuVaxTY6OBdGBETHl5987L7/Qzzu75P/7KzpEj53ZcDOzcuXNPILDtF1LDj/7w0ve//dXhR3/0",
            "wbG1wfdWvlxcm55d2fKxz9jeQfAnYvzZ6gtv1JNDYvSOPxILviFGF5bPiRdWlB3/IJYW49WXFryDKf+KWIE3ev70r3mzlZi3SjH+",
            "wvL5U2L0e2L1fydGX3wmGe7Mr4rl3/ZWePqZsUBAE1O2zooG5MWkfxxa+JSyoSZ0Zouff37o/3sbiLbrN2s7bPY2EG03uu29sN5t",
            "INpudtt7Yb3bQLTd6rb3wnq3gWh7sNveC+vdBqLtoW57L6x3G4i2h2nnxrUGiLZHaOfGtW0g2h6lnRvXXl60PUY7N65tA9H2OO3c",
            "uNYA0fYE7dy4tg1E25O0c+PaNhBtP1xXNjdn3rTtPqJp4BqHBq5xaOAaR+6EqijfOfuY0oXNu6bssvvQ81fLLqMnbP0b1+XVXd8+",
            "J/OqzKsyr8q8KvOqzKsyr8q8KvOqzKsyr3ZtXtXBeVUH51UdnFf7W+NK4L6/3Ny8ek0QvePZ0Ru4/+8+9cTWvV96TrEPL12XV3ef",
            "lvdXZV6VeVXmVZlXZV6VeVXmVZlXZV6VebVb8+r/9vsdr8j7TdLv0u/S79Lv0u/S79Lv0u/S79Lv3Xu/yQDfbzLA95sM8P2m/AlV",
            "CTz5u93++cg7/+u1D/t85J0vyPtNMq/KvCrzqsyrMq/KvCrzqsyrMq/KvNq9edUE51UTnFdNcF490B5XAm/8+ibn1WuSqPFJ54Y+",
            "IHn8I1+fWFIef/q6vKr9oby/KvOqzKsyr8q8KvOqzKsyr8q8KvOqzKuUz0ca35D3m6Tfpd+l36Xfpd+l36Xfpd+l36Xfu/d+kwW+",
            "32SB7zdZ4PtNAydUZUtfo9s/H2n92fKHfT7S+h15v0nmVZlXZV6VeVXmVZlXZV6VeVXmVZlXuzevBsF5NQjOq0FwXj3YGle2fPbn",
            "btnfj4xEHr+xvx8ZuP3evcpO++x1eTX0BXl/VeZVmVdlXpV5VeZVmVdlXpV5VeZVmVe7N6+GwHk1BM6rIXBeHfTur54f6Pb7q7FF",
            "7cPur0Y+K++vyrwq86rMqzKvyrwq86rMqzKvyrwq8yqlP1/sSXm/Sfpd+l36Xfpd+l36Xfpd+l36Xfq96/2+7bLfE4/I+rv0u/R7",
            "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",
    ])
}
