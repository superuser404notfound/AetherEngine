import Testing
import Foundation
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

/// AetherPlayer#2: sources whose HEVC parameter sets live in-band ship an hvcC with
/// `numOfArrays = 0`, and the init.mp4 normalizer rebuilds the record by scanning packets for the
/// VPS/SPS/PPS. That scan ran on whatever cursor the preceding cue prewarm and segment-plan pass
/// had left behind, so on a real film it read 16 mid-GOP packets, found nothing, and let the muxer
/// emit an empty hvcC. AVPlayer then buffers the whole forward window and never renders a frame
/// (CoreMediaErrorDomain -19601, no code the master fallback reacts to): frozen at 00:00.
@Suite("In-band parameter-set rebuild")
struct InBandParameterSetRebuildTests {

    @Test("The rebuild finds the parameter sets from a mid-GOP cursor",
          .enabled(if: fixtureExists("hev1-inband-xps.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the in-band xPS clip"),
          .timeLimit(.minutes(1)))
    func rebuildIsIndependentOfDemuxerCursor() throws {
        let demuxer = Demuxer()
        try demuxer.open(url: fixtureURL("hev1-inband-xps.mp4"), profile: .playback)
        defer { demuxer.close() }
        let videoIdx = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIdx))
        let codecpar = try #require(stream.pointee.codecpar)
        #expect(codecpar.pointee.extradata_size == 23,
                "fixture must ship the bare hvcC header, i.e. numOfArrays = 0")

        // Park the cursor mid-GOP, the state the cue prewarm plus plan pass leaves behind. The
        // fixture's IRAPs are 120 frames apart, so nothing in the scan's packet budget from here
        // carries a parameter set.
        var advanced = 0
        while advanced < 30, let pkt = try demuxer.readPacket() {
            var toFree: UnsafeMutablePointer<AVPacket>? = pkt
            defer { trackedPacketFree(&toFree) }
            if Int(pkt.pointee.stream_index) == videoIdx { advanced += 1 }
        }
        #expect(advanced == 30)

        let engine = HLSVideoEngine(url: fixtureURL("hev1-inband-xps.mp4"), dvModeAvailable: false)
        let rebuilt = engine.rebuildHEVCExtradataWithInBandParameterSets(
            demuxer: demuxer, videoStreamIndex: Int32(videoIdx), codecpar: codecpar)

        let record = try #require(rebuilt, "in-band VPS/SPS/PPS must be recoverable from any cursor")
        #expect(record.count > 23)
        #expect(record[22] == 3, "numOfArrays must cover VPS, SPS and PPS")
    }

    /// The Profile 7 FEL route needs a proven hardware session, which the strict verdict cannot give
    /// an empty hvcC; the load completes the demuxer's own record so the route and the decoders see
    /// what AVPlayer would have rebuilt.
    @Test("Completing the record in place makes the strict verdict classifiable and rewinds",
          .enabled(if: fixtureExists("hev1-inband-xps.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the in-band xPS clip"),
          .timeLimit(.minutes(1)))
    func completionInPlace() throws {
        let demuxer = Demuxer()
        try demuxer.open(url: fixtureURL("hev1-inband-xps.mp4"), profile: .playback)
        defer { demuxer.close() }
        let videoIdx = demuxer.videoStreamIndex
        let codecpar = try #require(demuxer.stream(at: videoIdx)?.pointee.codecpar)
        #expect(VTCapabilityProbe.hardwareDecodeVerdict(codecpar: codecpar)
                == .unclassifiable(reason: "in-band parameter sets"))

        #expect(VideoConfigRecord.completeHEVCRecordFromInBandParameterSets(demuxer: demuxer, streamIndex: videoIdx))
        #expect(codecpar.pointee.extradata_size > 23)
        #expect(codecpar.pointee.extradata?[22] == 3)
        #expect(VTCapabilityProbe.hardwareDecodeVerdict(codecpar: codecpar) != .unclassifiable(reason: "in-band parameter sets"))

        // Back at the head: the next video packet is the opening keyframe.
        var first: (key: Bool, pts: Int64)?
        while first == nil, let pkt = try demuxer.readPacket() {
            var toFree: UnsafeMutablePointer<AVPacket>? = pkt
            defer { trackedPacketFree(&toFree) }
            if pkt.pointee.stream_index == videoIdx {
                first = ((pkt.pointee.flags & AV_PKT_FLAG_KEY) != 0, pkt.pointee.pts)
            }
        }
        #expect(first?.key == true)
        #expect(first?.pts == 0)

        // A complete record is left alone.
        #expect(!VideoConfigRecord.completeHEVCRecordFromInBandParameterSets(demuxer: demuxer, streamIndex: videoIdx))
    }

    @Test("The scan stops on whichever of the packet, video-packet and byte budgets is spent first")
    func scanStopsOnEachBudget() {
        func more(read: Int = 0, video: Int = 0, bytes: Int = 0) -> Bool {
            VideoConfigRecord.scanMayContinue(packetsRead: read, videoPackets: video, bytesRead: bytes,
                                              packetBudget: 16, readBudget: 512, byteBudget: 1_000_000)
        }
        #expect(more())
        #expect(!more(read: 512))
        #expect(!more(video: 16))
        #expect(!more(bytes: 1_000_000), "a stream of huge packets with no parameter sets stops on bytes")
        #expect(more(read: 511, video: 15, bytes: 999_999))
        #expect(VideoConfigRecord.inBandScanByteBudget > 0)
    }

    @Test("A spent byte budget leaves the record as it was and the demuxer at the head",
          .enabled(if: fixtureExists("hev1-inband-xps.mp4"),
                   "run Scripts/fetch-fixtures.sh to generate the in-band xPS clip"),
          .timeLimit(.minutes(1)))
    func spentByteBudgetLeavesRecordAlone() throws {
        let demuxer = Demuxer()
        try demuxer.open(url: fixtureURL("hev1-inband-xps.mp4"), profile: .playback)
        defer { demuxer.close() }
        let videoIdx = demuxer.videoStreamIndex
        let codecpar = try #require(demuxer.stream(at: videoIdx)?.pointee.codecpar)
        let before = codecpar.pointee.extradata_size
        #expect(!VideoConfigRecord.completeHEVCRecordFromInBandParameterSets(
            demuxer: demuxer, streamIndex: videoIdx, byteBudget: 0))
        #expect(codecpar.pointee.extradata_size == before)
        #expect(VideoConfigRecord.completeHEVCRecordFromInBandParameterSets(demuxer: demuxer, streamIndex: videoIdx))
    }

    /// A Profile 7 enhancement layer carries its own VPS / SPS / PPS inside `unspec63` NAL units;
    /// only the base layer's top-level parameter sets may seed the base layer's record.
    @Test("The collector keeps top-level parameter sets and skips enhancement-layer ones")
    func collectorSkipsWrappedEnhancementLayerSets() {
        func nal(_ bytes: [UInt8]) -> [UInt8] {
            let n = bytes.count
            return [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + bytes
        }
        // unspec63 header (0x7E 0x01) wrapping an EL SPS (0x42 0x01), then the BL's VPS, SPS, PPS.
        let packet = nal([0x7E, 0x01, 0x42, 0x01, 0xEE])
            + nal([0x40, 0x01, 0xA1]) + nal([0x42, 0x01, 0xB2]) + nal([0x44, 0x01, 0xC3])
        var sets = VideoConfigRecord.HEVCParameterSets()
        packet.withUnsafeBufferPointer { sets.collect(from: $0.baseAddress!, size: $0.count) }
        #expect(sets.isComplete)
        #expect(sets.vps == [0x40, 0x01, 0xA1])
        #expect(sets.sps == [0x42, 0x01, 0xB2])
        #expect(sets.pps == [0x44, 0x01, 0xC3])
    }
}
