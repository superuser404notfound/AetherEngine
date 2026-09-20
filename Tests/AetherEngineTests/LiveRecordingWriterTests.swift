import Testing
import Foundation
import AetherLibavcodec
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
}
