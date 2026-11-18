import Testing
import Foundation
import AetherLibavutil
import AetherLibavcodec
import AetherLibavformat
@testable import AetherEngine

/// AetherEngine#1087: an ATSC 3.0 channel (HEVC, two AC-4 tracks, one STPP caption track) that
/// still held `find_stream_info` to its byte ceiling with the AC-4 tracks parked. The caption track
/// is a private stream with no descriptor, so `mpegts.c` names it `bin_data` and asks libavformat
/// to sniff its content. Until that sniff ends (2500 packets of its own, or the probe size in
/// queued bytes) `ff_read_packet` holds every packet behind its first one, the video included. A
/// caption track that sends a PES every few seconds never gets there.
///
/// The synthetic stream carries that track with its first PES ahead of the first picture, the
/// order that failed on two of the three reported opens.
@Suite("Unnamed data streams parked out of the playback probe", .timeLimit(.minutes(3)))
struct Issue1087DataStreamProbeParkingTests {

    @Test("only a stream the demuxer could not name is parked")
    func predicate() {
        #expect(Demuxer.dataNeedsNoProbe(codecID: AV_CODEC_ID_BIN_DATA, codecType: AVMEDIA_TYPE_DATA))
        #expect(!Demuxer.dataNeedsNoProbe(codecID: AV_CODEC_ID_SCTE_35, codecType: AVMEDIA_TYPE_DATA))
        #expect(!Demuxer.dataNeedsNoProbe(codecID: AV_CODEC_ID_TIMED_ID3, codecType: AVMEDIA_TYPE_DATA))
        #expect(!Demuxer.dataNeedsNoProbe(codecID: AV_CODEC_ID_NONE, codecType: AVMEDIA_TYPE_DATA))
        #expect(!Demuxer.dataNeedsNoProbe(codecID: AV_CODEC_ID_BIN_DATA, codecType: AVMEDIA_TYPE_ATTACHMENT))
    }

    @Test("a sparse caption track costs the probe nothing")
    func dataDoesNotExtendTheProbe() throws {
        let plain = try reach(SyntheticTS.broadcast(accessUnits: 3000, audio: .ac4))
        let withData = try reach(SyntheticTS.broadcast(accessUnits: 3000, audio: .ac4, data: .sparse))
        #expect(withData <= plain)
    }

    @Test("the data track survives the probe unchanged and readable")
    func dataTrackIsKept() throws {
        let ts = SyntheticTS.broadcast(accessUnits: 3000, audio: .ac4, data: .sparse)
        #expect(ts.count > 5_000_000)
        let reader = ProbeReachReader(data: ts)
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "mpegts", profile: .playback, isLive: true)
        defer { demuxer.close() }

        #expect(reader.highWaterMark < 1_000_000)
        let data = try #require(demuxer.stream(at: 2))
        #expect(data.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_DATA)
        #expect(data.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_BIN_DATA)
        #expect(data.pointee.discard == AVDISCARD_DEFAULT)

        let video = try #require(demuxer.stream(at: 0)?.pointee.codecpar)
        #expect(demuxer.videoStreamIndex == 0)
        #expect(video.pointee.width == 64)
        #expect(video.pointee.height == 64)
    }

    private func reach(_ ts: Data) throws -> Int {
        let reader = ProbeReachReader(data: ts)
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "mpegts", profile: .playback, isLive: true)
        defer { demuxer.close() }
        #expect(demuxer.videoStreamIndex == 0)
        return reader.highWaterMark
    }
}
