import Combine
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// Audit LIF-107: the probe block wrote the source geometry and codec into engine state before its
/// post-probe generation check. The AE#532 RPU audit (a Dolby Vision Profile 5 record over an HDR10
/// VUI) is a second network read `stopInternal` cannot abort, so a load superseded inside it came
/// back after its successor's prologue and wrote its own width, height and codec over the reset.
/// A successor that never probes (the remote-HLS bypass) then kept them for the session.
@Suite("A superseded probe leaves its successor's geometry alone", .timeLimit(.minutes(2)))
@MainActor
struct SupersededProbeGeometryTests {

    /// The 64x64 HDR10 fixture with a Dolby Vision Profile 5 record added: the one pairing the
    /// AE#532 audit reads the bitstream for.
    static func dolbyVisionProfile5OverHDR10() throws -> Data {
        let video = Demuxer()
        defer { video.close() }
        try video.open(reader: DataIOReader(data: ProbeTestFixtures.hdr10Plus()), formatHint: "mp4")
        let source = try #require(video.stream(at: video.videoStreamIndex))

        var output: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_alloc_output_context2(&output, nil, "mp4", nil) >= 0)
        let context = try #require(output)
        defer { avformat_free_context(context) }
        // movenc writes the dvcC box only when unofficial extensions are allowed.
        context.pointee.strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL

        var io: UnsafeMutablePointer<AVIOContext>?
        try #require(avio_open_dyn_buf(&io) >= 0)
        let buffer = try #require(io)
        context.pointee.pb = buffer
        var bytes: UnsafeMutablePointer<UInt8>?
        var bufferClosed = false
        defer {
            if !bufferClosed { _ = avio_close_dyn_buf(buffer, &bytes) }
            av_free(bytes)
        }

        let target = try #require(avformat_new_stream(context, nil))
        let codecpar = try #require(target.pointee.codecpar)
        try #require(avcodec_parameters_copy(codecpar, source.pointee.codecpar) >= 0)
        target.pointee.time_base = source.pointee.time_base
        var recordSize = 0
        let record = try #require(av_dovi_alloc(&recordSize))
        record.pointee.dv_version_major = 1
        record.pointee.dv_profile = 5
        record.pointee.dv_level = 1
        record.pointee.rpu_present_flag = 1
        record.pointee.bl_present_flag = 1
        record.pointee.dv_bl_signal_compatibility_id = 0
        guard av_packet_side_data_add(&codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
                                      AV_PKT_DATA_DOVI_CONF, UnsafeMutableRawPointer(record), recordSize, 0) != nil else {
            av_free(record)
            throw DemuxerError.openFailed(code: -1)
        }

        try #require(avformat_write_header(context, nil) >= 0)
        while let packet = try video.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            guard packet.pointee.stream_index == video.videoStreamIndex else { continue }
            av_packet_rescale_ts(packet, source.pointee.time_base, target.pointee.time_base)
            packet.pointee.stream_index = 0
            packet.pointee.pos = -1
            try #require(av_interleaved_write_frame(context, packet) >= 0)
        }
        try #require(av_write_trailer(context) >= 0)
        let count = avio_close_dyn_buf(buffer, &bytes)
        bufferClosed = true
        context.pointee.pb = nil
        try #require(count > 0)
        return Data(bytes: try #require(bytes), count: Int(count))
    }

    @Test("The fixture is the pairing the RPU audit exists for")
    func fixtureIsAContradictedRecord() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Self.dolbyVisionProfile5OverHDR10()), formatHint: "mp4")
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let codecpar = try #require(stream.pointee.codecpar)
        #expect(AetherEngine.dvConfig(stream: stream)?.profile == 5)
        #expect(DolbyVisionRecordAudit.recordIsContradicted(
            codecID: codecpar.pointee.codec_id, dvProfile: 5,
            colorTransfer: codecpar.pointee.color_trc, colorMatrix: codecpar.pointee.color_space))
    }

    @Test("A load superseded during its RPU audit does not write its width over the successor's")
    func supersededAuditPublishesNothing() async throws {
        let origin = try ProbeHTTPTestOrigin(data: try Self.dolbyVisionProfile5OverHDR10())
        defer { origin.stop() }
        let engine = try AetherEngine()
        defer { engine.stop() }
        // The open's last stage hops to the main actor ahead of the open's own continuation, so
        // every request from here on is the audit's.
        let sub = engine.$startupProgress.sink { progress in
            if progress?.checkpoint == .streamsProbed { origin.holdLaterRequests() }
        }
        defer { sub.cancel() }

        let superseded = Task { @MainActor in
            try await engine.load(url: try #require(URL(string: "http://127.0.0.1:\(origin.port)/p5.mp4")))
        }
        try await waitFor { origin.held.entered }
        _ = try await engine.load(url: try #require(URL(string: "http://127.0.0.1:9/vod.m3u8")),
                                  options: LoadOptions(nativeRemoteHLS: true))
        #expect(engine.sourceVideoWidth == 0)
        origin.held.open()

        await #expect(throws: CancellationError.self) { try await superseded.value }
        #expect(engine.sourceVideoWidth == 0)
        #expect(engine.sourceVideoHeight == 0)
        #expect(engine.sourceDVBLCompatID == nil)
        #expect(!engine.sourceDolbyVisionBaseLayerPresentable)
    }
}
