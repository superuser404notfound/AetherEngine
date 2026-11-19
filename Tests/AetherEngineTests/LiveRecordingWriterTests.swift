import Testing
import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// The MPEG-TS stream-copy writer (AE#560).
///
/// The container assertion is the point of `writesReadableFile`: MPEG-TS is a continuous run of
/// 188 byte packets, which is exactly what makes a file cut short by a crash still playable, and
/// that is the requirement the container was chosen for.
@Suite("Live recording writer")
struct LiveRecordingWriterTests {

    /// A minimal H.264 video stream descriptor. The writer only copies parameters, it never
    /// decodes, so a synthetic codecpar is enough to exercise header, packets and trailer.
    private func makeVideoParameters() -> UnsafeMutablePointer<AVCodecParameters> {
        let p = avcodec_parameters_alloc()!
        p.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        p.pointee.codec_id = AV_CODEC_ID_H264
        p.pointee.width = 640
        p.pointee.height = 360
        return p
    }

    private func makeAudioParameters() -> UnsafeMutablePointer<AVCodecParameters> {
        let p = avcodec_parameters_alloc()!
        p.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        p.pointee.codec_id = AV_CODEC_ID_AAC
        p.pointee.sample_rate = 48000
        return p
    }

    private func free(_ p: UnsafeMutablePointer<AVCodecParameters>) {
        var q: UnsafeMutablePointer<AVCodecParameters>? = p
        avcodec_parameters_free(&q)
    }

    /// A payload the MPEG-TS muxer will accept for an H.264 stream.
    ///
    /// Zero bytes are not enough: the muxer checks for an Annex-B start code before it will build a
    /// PES packet, and refuses the write otherwise. That refusal is silent in the file (nothing is
    /// written), which is exactly why the tests below assert on bytes rather than on a return code.
    /// The NAL payload past the header is filler; nothing here decodes, and nothing needs to.
    private func annexBPayload(_ size: Int, nalType: UInt8) -> [UInt8] {
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x01, nalType]
        bytes.append(contentsOf: [UInt8](repeating: 0x88, count: max(0, size - bytes.count)))
        return bytes
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).ts")
    }

    @Test("writes an MPEG-TS file that is a whole number of 188 byte packets")
    func writesReadableFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let params = makeVideoParameters()
        defer { free(params) }

        let writer = try LiveRecordingWriter(
            url: url,
            streams: [RecordingStreamDescriptor(sourceStreamIndex: 0,
                                                timeBaseNum: 1, timeBaseDen: 90000,
                                                codecParameters: params, isVideo: true)],
            ceilingBytes: 1 << 20,
            onFailure: { _ in }
        )

        for i in 0..<30 {
            // NAL type 5 is an IDR slice, 1 a non-IDR slice.
            let payload = annexBPayload(1024, nalType: i == 0 ? 0x65 : 0x41)
            payload.withUnsafeBytes { buf in
                writer.accept(packetBytes: buf, sourceStreamIndex: 0,
                              pts: Int64(i) * 3000, dts: Int64(i) * 3000,
                              duration: 3000, isKeyframe: i == 0)
            }
        }
        writer.finish(reason: .stoppedByHost)

        let data = try Data(contentsOf: url)
        #expect(data.count > 0)
        #expect(data.first == 0x47, "an MPEG-TS file starts with the sync byte")
        #expect(data.count % 188 == 0, "a TS file is a whole number of 188 byte packets")
    }

    @Test("nothing is written before the first keyframe, so the file opens on a decodable picture")
    func dropsUntilFirstKeyframe() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let params = makeVideoParameters()
        defer { free(params) }

        let writer = try LiveRecordingWriter(
            url: url,
            streams: [RecordingStreamDescriptor(sourceStreamIndex: 0,
                                                timeBaseNum: 1, timeBaseDen: 90000,
                                                codecParameters: params, isVideo: true)],
            ceilingBytes: 1 << 20,
            onFailure: { _ in }
        )

        for i in 0..<10 {
            let payload = annexBPayload(1024, nalType: 0x41)
            payload.withUnsafeBytes { buf in
                writer.accept(packetBytes: buf, sourceStreamIndex: 0,
                              pts: Int64(i) * 3000, dts: Int64(i) * 3000,
                              duration: 3000, isKeyframe: false)
            }
        }
        #expect(writer.bytesWritten == 0, "packets before the first keyframe must be dropped")
        writer.finish(reason: .stoppedByHost)
    }

    /// SUB-202: the mpegts muxer is not TS_NONSTRICT, so a packet whose dts does not rise returns
    /// EINVAL. One such packet used to end a multi-hour recording as `.writeFailed`.
    @Test("a repeated dts does not end the recording, and the packets after it still land")
    func nonMonotonicDtsDoesNotEndRecording() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let params = makeVideoParameters()
        defer { free(params) }

        let failures = RecordingFailureBox()
        let writer = try LiveRecordingWriter(
            url: url,
            streams: [RecordingStreamDescriptor(sourceStreamIndex: 0,
                                                timeBaseNum: 1, timeBaseDen: 90000,
                                                codecParameters: params, isVideo: true)],
            ceilingBytes: 1 << 20,
            onFailure: { failures.record($0) }
        )

        func feed(_ i: Int, dts: Int64) {
            annexBPayload(1024, nalType: i == 0 ? 0x65 : 0x41).withUnsafeBytes { buf in
                writer.accept(packetBytes: buf, sourceStreamIndex: 0,
                              pts: dts, dts: dts, duration: 3000, isKeyframe: i == 0)
            }
        }
        for i in 0..<10 { feed(i, dts: Int64(i) * 3000) }
        feed(10, dts: 9 * 3000)            // repeated dts
        feed(11, dts: 5 * 3000)            // jumps back
        for i in 12..<30 { feed(i, dts: Int64(i) * 3000) }
        let failure = writer.finish(reason: .stoppedByHost)

        #expect(failure == nil)
        #expect(failures.all.isEmpty, "a non-increasing dts must never end the recording")
        let data = try Data(contentsOf: url)
        #expect(data.count % 188 == 0)
        #expect(data.count > 30 * 1024, "the packets after the bad one must reach the file")
    }

    @Test("an audio keyframe does not arm the recording, only a video one does")
    func audioKeyframeDoesNotArm() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let video = makeVideoParameters()
        let audio = makeAudioParameters()
        defer { free(video); free(audio) }

        let writer = try LiveRecordingWriter(
            url: url,
            streams: [
                RecordingStreamDescriptor(sourceStreamIndex: 0, timeBaseNum: 1, timeBaseDen: 90000,
                                          codecParameters: video, isVideo: true),
                RecordingStreamDescriptor(sourceStreamIndex: 1, timeBaseNum: 1, timeBaseDen: 90000,
                                          codecParameters: audio, isVideo: false),
            ],
            ceilingBytes: 1 << 20,
            onFailure: { _ in }
        )

        // Every AAC packet carries AV_PKT_FLAG_KEY. Measured against a real 640x360 H.264 + AAC
        // MPEG-TS source, an any-stream gate armed on the first audio packet and the head of the
        // recording then read `non-existing PPS 0 referenced` for the whole first GOP.
        let audioPayload = [UInt8](repeating: 0x21, count: 256)
        let videoPayload = annexBPayload(1024, nalType: 0x41)   // non-IDR slice
        for i in 0..<5 {
            audioPayload.withUnsafeBytes { buf in
                writer.accept(packetBytes: buf, sourceStreamIndex: 1,
                              pts: Int64(i) * 1920, dts: Int64(i) * 1920,
                              duration: 1920, isKeyframe: true)
            }
            videoPayload.withUnsafeBytes { buf in
                writer.accept(packetBytes: buf, sourceStreamIndex: 0,
                              pts: Int64(i) * 3600, dts: Int64(i) * 3600,
                              duration: 3600, isKeyframe: false)
            }
        }
        #expect(writer.bytesWritten == 0,
                "an audio keyframe must not open the file before the first video keyframe")

        let idr = annexBPayload(1024, nalType: 0x65)
        idr.withUnsafeBytes { buf in
            writer.accept(packetBytes: buf, sourceStreamIndex: 0,
                          pts: 18000, dts: 18000, duration: 3600, isKeyframe: true)
        }
        writer.finish(reason: .stoppedByHost)
        #expect(writer.bytesWritten == 1024, "the video keyframe is what arms it")
    }

    @Test("a descriptor list with nothing copyable fails rather than producing an empty file")
    func refusesWhenNothingCopyable() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: RecordingFailure.noStreamsToCopy) {
            _ = try LiveRecordingWriter(url: url, streams: [],
                                        ceilingBytes: 1 << 20, onFailure: { _ in })
        }
    }

    @Test("a path that cannot be created fails with cannotCreateFile")
    func refusesUnwritablePath() {
        let params = makeVideoParameters()
        defer { free(params) }
        let url = URL(fileURLWithPath: "/this/path/does/not/exist/rec.ts")
        #expect(throws: RecordingFailure.self) {
            _ = try LiveRecordingWriter(
                url: url,
                streams: [RecordingStreamDescriptor(sourceStreamIndex: 0,
                                                    timeBaseNum: 1, timeBaseDen: 90000,
                                                    codecParameters: params, isVideo: true)],
                ceilingBytes: 1 << 20, onFailure: { _ in })
        }
    }

    @Test("a stop flushes what is still queued instead of truncating the tail")
    func stopFlushesTheQueue() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let params = makeVideoParameters()
        defer { free(params) }

        let writer = try LiveRecordingWriter(
            url: url,
            streams: [RecordingStreamDescriptor(sourceStreamIndex: 0,
                                                timeBaseNum: 1, timeBaseDen: 90000,
                                                codecParameters: params, isVideo: true)],
            ceilingBytes: 1 << 20,
            onFailure: { _ in }
        )

        // Hand over a batch and stop immediately, so the drain is still behind when `finish` runs.
        // The first version of this writer gated its write on the same flag `finish` sets before
        // draining, which silently discarded every packet still queued at the moment of a stop:
        // up to the full ceiling, several seconds of video off the end of every recording.
        let count = 200
        for i in 0..<count {
            let payload = annexBPayload(1024, nalType: i == 0 ? 0x65 : 0x41)
            payload.withUnsafeBytes { buf in
                writer.accept(packetBytes: buf, sourceStreamIndex: 0,
                              pts: Int64(i) * 3000, dts: Int64(i) * 3000,
                              duration: 3000, isKeyframe: i == 0)
            }
        }
        writer.finish(reason: .stoppedByHost)

        #expect(writer.droppedBytes == 0, "nothing should hit the ceiling in this test")
        #expect(writer.bytesWritten == Int64(count) * 1024,
                "every accepted packet must reach the file, including the ones still queued at stop")
    }

    @Test("a packet for an unmapped source stream is ignored rather than mis-routed")
    func ignoresUnmappedStream() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let params = makeVideoParameters()
        defer { free(params) }

        let writer = try LiveRecordingWriter(
            url: url,
            streams: [RecordingStreamDescriptor(sourceStreamIndex: 0,
                                                timeBaseNum: 1, timeBaseDen: 90000,
                                                codecParameters: params, isVideo: true)],
            ceilingBytes: 1 << 20,
            onFailure: { _ in }
        )

        let payload = annexBPayload(512, nalType: 0x65)
        payload.withUnsafeBytes { buf in
            writer.accept(packetBytes: buf, sourceStreamIndex: 0,
                          pts: 0, dts: 0, duration: 3000, isKeyframe: true)
            writer.accept(packetBytes: buf, sourceStreamIndex: 7,
                          pts: 3000, dts: 3000, duration: 3000, isKeyframe: true)
        }
        writer.finish(reason: .stoppedByHost)
        #expect(writer.bytesWritten == 512, "only the mapped stream's packet is written")
    }

    // MARK: - The file starts at zero (#560 round 2, #574)

    /// The presentation timestamps of the first packet of each stream, read back out of the
    /// written file. Demuxing is enough here: nothing is decoded, and the TS demuxer reports the
    /// timestamps the muxer wrote whether or not the payload means anything.
    private func firstTimestamps(in url: URL) throws -> [Int32: Int64] {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctx, url.path, nil, nil) >= 0, let context = ctx else {
            throw RecordingFailure.writeFailed("could not open the written file")
        }
        defer { var c: UnsafeMutablePointer<AVFormatContext>? = context; avformat_close_input(&c) }

        var first: [Int32: Int64] = [:]
        guard let pkt = av_packet_alloc() else { return first }
        defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
        while av_read_frame(context, pkt) >= 0 {
            if first[pkt.pointee.stream_index] == nil, pkt.pointee.pts != Int64.min {
                first[pkt.pointee.stream_index] = pkt.pointee.pts
            }
            av_packet_unref(pkt)
        }
        return first
    }

    @Test("a channel that has been up since morning still records a file that begins at zero")
    func recordingBeginsAtZero() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let params = makeVideoParameters()
        defer { free(params) }

        let writer = try LiveRecordingWriter(
            url: url,
            streams: [RecordingStreamDescriptor(sourceStreamIndex: 0,
                                                timeBaseNum: 1, timeBaseDen: 90000,
                                                codecParameters: params, isVideo: true)],
            ceilingBytes: 1 << 20,
            onFailure: { _ in }
        )

        // 24549.835 s at 90 kHz: where a channel's clock stands seven hours into its day.
        let origin: Int64 = 2_209_485_150
        for i in 0..<30 {
            let payload = annexBPayload(1024, nalType: i == 0 ? 0x65 : 0x41)
            payload.withUnsafeBytes { buf in
                writer.accept(packetBytes: buf, sourceStreamIndex: 0,
                              pts: origin + Int64(i) * 3000, dts: origin + Int64(i) * 3000,
                              duration: 3000, isKeyframe: i == 0)
            }
        }
        writer.finish(reason: .stoppedByHost)

        let first = try firstTimestamps(in: url)
        #expect(first[0] == 0, "a duration probe reads a broadcast clock as the length")
    }

    @Test("the audio that leads the arming keyframe keeps its distance from the picture")
    func keepsTheLeadOfInterleavedAudio() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let video = makeVideoParameters()
        let audio = avcodec_parameters_alloc()!
        audio.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        audio.pointee.codec_id = AV_CODEC_ID_AC3
        audio.pointee.sample_rate = 48000
        defer { free(video); free(audio) }

        let writer = try LiveRecordingWriter(
            url: url,
            streams: [
                RecordingStreamDescriptor(sourceStreamIndex: 0, timeBaseNum: 1, timeBaseDen: 90000,
                                          codecParameters: video, isVideo: true),
                RecordingStreamDescriptor(sourceStreamIndex: 1, timeBaseNum: 1, timeBaseDen: 90000,
                                          codecParameters: audio, isVideo: false),
            ],
            ceilingBytes: 1 << 20,
            onFailure: { _ in }
        )

        // A TS interleaves the audio that belongs with a picture ahead of the picture itself, so
        // the packets that arrive just after the arming keyframe carry EARLIER timestamps than it.
        // Rebasing on the keyframe rather than on the lowest timestamp in the file has to clamp
        // them, and the lead is what gets lost: measured at 100 ms, four frames came out sharing
        // instant zero with a picture that belongs 100 ms later.
        let origin: Int64 = 2_209_485_150
        let lead: Int64 = 9_000                                  // 100 ms at 90 kHz
        let idr = annexBPayload(1024, nalType: 0x65)
        idr.withUnsafeBytes { buf in
            writer.accept(packetBytes: buf, sourceStreamIndex: 0,
                          pts: origin, dts: origin, duration: 3000, isKeyframe: true)
        }
        let audioPayload = [UInt8](repeating: 0x0B, count: 256)
        for i in 0..<10 {
            audioPayload.withUnsafeBytes { buf in
                writer.accept(packetBytes: buf, sourceStreamIndex: 1,
                              pts: origin - lead + Int64(i) * 2_880,
                              dts: origin - lead + Int64(i) * 2_880,
                              duration: 2_880, isKeyframe: true)
            }
        }
        for i in 1..<10 {
            let payload = annexBPayload(1024, nalType: 0x41)
            payload.withUnsafeBytes { buf in
                writer.accept(packetBytes: buf, sourceStreamIndex: 0,
                              pts: origin + Int64(i) * 3_000, dts: origin + Int64(i) * 3_000,
                              duration: 3_000, isKeyframe: false)
            }
        }
        writer.finish(reason: .stoppedByHost)

        let first = try firstTimestamps(in: url)
        #expect(first[1] == 0, "the earliest packet in the file is the one that becomes zero")
        #expect(first[0] == lead, "the picture still sits the source's 100 ms behind its audio")
    }

    // MARK: - Dolby Vision keeps its record

    /// An HEVC stream carrying the Dolby Vision configuration record the TS demuxer reads from a
    /// source's DOVI video stream descriptor.
    private func makeDolbyVisionParameters(profile: UInt8, compatibility: UInt8) throws -> UnsafeMutablePointer<AVCodecParameters> {
        let p = avcodec_parameters_alloc()!
        p.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        p.pointee.codec_id = AV_CODEC_ID_HEVC
        p.pointee.width = 3840
        p.pointee.height = 2160
        var size = 0
        let dovi = av_dovi_alloc(&size)!
        dovi.pointee.dv_version_major = 1
        dovi.pointee.dv_profile = profile
        dovi.pointee.dv_level = 6
        dovi.pointee.rpu_present_flag = 1
        dovi.pointee.bl_present_flag = 1
        dovi.pointee.dv_bl_signal_compatibility_id = compatibility
        // On failure the record stays ours, so free it here instead of failing later on a nil profile.
        guard av_packet_side_data_add(&p.pointee.coded_side_data, &p.pointee.nb_coded_side_data,
                                      AV_PKT_DATA_DOVI_CONF, dovi, size, 0) != nil else {
            av_free(dovi)
            var q: UnsafeMutablePointer<AVCodecParameters>? = p
            avcodec_parameters_free(&q)
            throw RecordingFailure.writeFailed("could not attach the Dolby Vision record")
        }
        return p
    }

    /// The record the engine's own probe reads from the written file, the one routing follows.
    private func dolbyVisionRecord(in url: URL) throws -> (profile: Int, blCompatID: Int)? {
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&ctx, url.path, nil, nil) >= 0, let context = ctx else {
            throw RecordingFailure.writeFailed("could not open the written file")
        }
        defer { var c: UnsafeMutablePointer<AVFormatContext>? = context; avformat_close_input(&c) }
        guard context.pointee.nb_streams == 1, let stream = context.pointee.streams[0] else { return nil }
        return AetherEngine.dvConfig(stream: stream)
    }

    /// A Dolby Vision channel recorded as HDR10 (8.1), HLG (8.4) or wrong-coloured HDR10 (5): the
    /// RPUs reached the file, the record did not, because FFmpeg's TS muxer wrote no DOVI descriptor
    /// before FFmpegBuild wrote the DOVI descriptors.
    @Test("a Dolby Vision recording keeps its configuration record", arguments: [
        (UInt8(8), UInt8(1)), (UInt8(8), UInt8(4)), (UInt8(5), UInt8(0)),
    ])
    func keepsDolbyVisionRecord(profile: UInt8, compatibility: UInt8) throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let params = try makeDolbyVisionParameters(profile: profile, compatibility: compatibility)
        // avcodec_parameters_free, not free: the codecpar owns the side data.
        defer { var q: UnsafeMutablePointer<AVCodecParameters>? = params; avcodec_parameters_free(&q) }

        let writer = try LiveRecordingWriter(
            url: url,
            streams: [RecordingStreamDescriptor(sourceStreamIndex: 0,
                                                timeBaseNum: 1, timeBaseDen: 90000,
                                                codecParameters: params, isVideo: true)],
            ceilingBytes: 1 << 20,
            onFailure: { _ in }
        )
        for i in 0..<10 {
            // First HEVC NAL header byte only: type 19 (IDR_W_RADL), then type 1 (TRAIL_R). The
            // second byte is filler, which the muxer never reads.
            let payload = annexBPayload(1024, nalType: i == 0 ? 0x26 : 0x02)
            payload.withUnsafeBytes { buf in
                writer.accept(packetBytes: buf, sourceStreamIndex: 0,
                              pts: Int64(i) * 3_600, dts: Int64(i) * 3_600,
                              duration: 3_600, isKeyframe: i == 0)
            }
        }
        writer.finish(reason: .stoppedByHost)

        let record = try dolbyVisionRecord(in: url)
        #expect(record?.profile == Int(profile))
        #expect(record?.blCompatID == Int(compatibility))
    }
}

private final class RecordingFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [RecordingFailure] = []
    func record(_ f: RecordingFailure) { lock.lock(); failures.append(f); lock.unlock() }
    var all: [RecordingFailure] { lock.lock(); defer { lock.unlock() }; return failures }
}
