import Testing
import Foundation
import AetherLibavutil
import AetherLibavcodec
import AetherLibavformat
@testable import AetherEngine

/// AetherEngine#858: four PGS tracks with no cue inside the probe held `find_stream_info` to its
/// 50 MiB ceiling, ~14 s on a remote Matroska source before playback could be built.
/// `has_codec_parameters` wants a PGS width, and only a decoded composition segment carries one.
///
/// The synthetic stream reproduces the exit condition: a PGS PID declared in the PMT that never
/// carries a packet. Without the parking that probe reads to its analyze-duration cap; with it, the
/// reach matches the same stream without the subtitle track (measured: 1,572,864 bytes against
/// 262,144).
@Suite("PGS tracks parked out of the playback probe")
struct Issue858PGSProbeParkingTests {

    @Test("only a known PGS subtitle is parked")
    func predicate() {
        #expect(Demuxer.subtitleNeedsNoProbe(codecID: AV_CODEC_ID_HDMV_PGS_SUBTITLE,
                                             codecType: AVMEDIA_TYPE_SUBTITLE))
        #expect(!Demuxer.subtitleNeedsNoProbe(codecID: AV_CODEC_ID_DVB_SUBTITLE,
                                              codecType: AVMEDIA_TYPE_SUBTITLE))
        #expect(!Demuxer.subtitleNeedsNoProbe(codecID: AV_CODEC_ID_NONE,
                                              codecType: AVMEDIA_TYPE_SUBTITLE))
        #expect(!Demuxer.subtitleNeedsNoProbe(codecID: AV_CODEC_ID_HDMV_PGS_SUBTITLE,
                                              codecType: AVMEDIA_TYPE_ATTACHMENT))
    }

    @Test("a cue-less PGS track costs the probe nothing")
    func pgsDoesNotExtendTheProbe() throws {
        let plain = try reach(SyntheticTS.broadcast(accessUnits: 3000))
        let withPGS = try reach(SyntheticTS.broadcast(accessUnits: 3000, subtitle: .pgs))
        #expect(withPGS <= plain)
    }

    @Test("the PGS track survives the probe as a subtitle with its width still pending")
    func pgsTrackIsKept() throws {
        let reader = ProbeReachReader(data: SyntheticTS.broadcast(accessUnits: 3000, subtitle: .pgs))
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "mpegts", profile: .playback, isLive: true)
        defer { demuxer.close() }

        #expect(reader.highWaterMark < 1_000_000)
        let pgs = try #require(demuxer.stream(at: 1)?.pointee.codecpar)
        #expect(pgs.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE)
        #expect(pgs.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE)
        #expect(pgs.pointee.width == 0)
        #expect(demuxer.subtitleTrackInfos().map(\.codec) == ["pgssub"])

        let video = try #require(demuxer.stream(at: 0)?.pointee.codecpar)
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
