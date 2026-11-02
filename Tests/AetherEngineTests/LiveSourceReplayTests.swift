import Foundation
import CryptoKit
import AVFoundation
import VideoToolbox
import Testing
import AetherLibavutil
import AetherLibavcodec
@testable import AetherEngine

@Suite("Live source replay", .serialized, .timeLimit(.minutes(3)))
struct LiveSourceReplayTests {
    private final class Reader: IOReader, @unchecked Sendable {
        private let bytes: Data
        private let failAtEnd: Bool
        private let lock = NSLock()
        private var position = 0
        init(_ bytes: Data, failAtEnd: Bool = false) {
            self.bytes = bytes
            self.failAtEnd = failAtEnd
        }
        var consumedBytes: Int { lock.withLock { position } }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            return lock.withLock {
                let count = min(Int(size), bytes.count - position)
                guard count > 0 else { return failAtEnd ? -1 : 0 }
                bytes.withUnsafeBytes { _ = memcpy(buffer, $0.baseAddress! + position, count) }
                position += count
                return Int32(count)
            }
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() {}
        var discImageProbeEnabled: Bool { false }
    }

    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var exit: HLSSegmentProducer.PumpExitReason?
        private var rebases = 0
        func finish(_ reason: HLSSegmentProducer.PumpExitReason) { lock.withLock { exit = reason } }
        func rebase() { lock.withLock { rebases += 1 } }
        var reason: HLSSegmentProducer.PumpExitReason? { lock.withLock { exit } }
        var rebaseCount: Int { lock.withLock { rebases } }
    }

    /// Split on TS packets carrying a video access-unit delimiter, retaining the original
    /// compressed frames and source timestamps. Changing an AUD leaves the picture intact.
    private func fixture(data: Data = TinyTransportStreamFixture.data,
                         divergenceFrame: Int = 5,
                         divergenceFrames: Int = 1,
                         headFrames: Int = 8,
                         replayStartFrame: Int = 0) throws -> (head: Data, tail: Data,
                                                              replay: Data, diverged: Data) {
        let aud = Data([0, 0, 0, 1, 9])
        var offsets: [Int] = []
        var position = 0
        while let range = data.range(of: aud, in: position..<data.count) {
            offsets.append(range.lowerBound)
            position = range.upperBound
        }
        #expect(offsets.count > headFrames)
        let seam = try #require(offsets.dropFirst(headFrames).first) / 188 * 188
        let head = Data(data[..<seam])
        let replayStart = replayStartFrame == 0 ? 0 : offsets[replayStartFrame] / 188 * 188
        let replay = Data(head[replayStart...])
        var diverged = replay
        for offset in offsets.dropFirst(divergenceFrame).prefix(divergenceFrames) {
            let changedAUD = offset + 5 - replayStart
            if changedAUD >= 0 && changedAUD < diverged.count { diverged[changedAUD] = 0xD0 }
        }
        return (head, Data(data[seam...]), replay, diverged)
    }

    @discardableResult
    private func run(_ bytes: Data, expected: String, expectedRebases: Int,
                     failAtEnd: Bool = false, mustLeaveUnreadBytes: Bool = false,
                     retainedCache: SegmentCache? = nil,
                     predecessor: HLSSegmentProducer? = nil) async throws -> HLSSegmentProducer {
        let demuxer = Demuxer()
        let reader = Reader(bytes, failAtEnd: failAtEnd)
        try demuxer.open(reader: reader, formatHint: "mpegts")
        let index = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: index))
        var audio: HLSSegmentProducer.AudioConfig?
        if let stream = demuxer.stream(at: demuxer.audioStreamIndex) {
            audio = .init(codecpar: UnsafePointer(stream.pointee.codecpar),
                          timeBase: stream.pointee.time_base,
                          sourceStreamIndex: demuxer.audioStreamIndex,
                          inputTimeBase: stream.pointee.time_base,
                          sourceTimeBase: stream.pointee.time_base,
                          bridge: nil, stripAacAdts: true)
        }
        let cache = retainedCache ?? SegmentCache(forwardWindow: 32, backwardWindow: 32)
        let baseIndex = predecessor == nil ? 0 : cache.count
        let producer = try HLSSegmentProducer(
            demuxer: demuxer, videoStreamIndex: index,
            video: .init(codecpar: UnsafePointer(stream.pointee.codecpar),
                         timeBase: stream.pointee.time_base, codecTagOverride: "avc1"),
            audio: audio, cache: cache, baseIndex: baseIndex, targetSegmentDurationSeconds: 1,
            videoFallbackDurationPts: 45_000, desiredFirstVideoTfdtPts: Int64(baseIndex) * 90_000,
            segmentBoundaries: [], isLive: true, bufferAheadSegments: 32)
        if let predecessor { producer.continueLiveReplayHistory(from: predecessor) }
        let result = Result()
        defer {
            producer.stop()
            // Cancellation may leave the pump unwinding; its demuxer/cache must stay alive.
            if result.reason != nil, retainedCache == nil { cache.close() }
        }
        producer.onPumpFinished = { result.finish($0) }
        producer.onLiveTimelineRebase = { _, _ in result.rebase() }
        producer.onLiveSegmentFinalized = { _, _, _, _ in }
        producer.start()
        try await waitFor { result.reason != nil }
        #expect(result.reason?.description == expected)
        #expect(result.rebaseCount == expectedRebases,
                "confirmed old media must never enter the discontinuity/mux path")
        #expect(cache.count > 0, "the already-produced good media remains available")
        if mustLeaveUnreadBytes {
            #expect(reader.consumedBytes < bytes.count, "the packet bound fires before source EOF")
        }
        return producer
    }

    private final class AdmissionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var held = false
        private var sawHold = false
        private var reads = 0
        private var ended = false
        private var stopped = false
        func noteRead() { lock.withLock { reads += 1; if reads == 1 { held = true } } }
        func mayRead() -> Bool { lock.withLock { if held { sawHold = true }; return !held } }
        func release() { lock.withLock { held = false } }
        func stop() { lock.withLock { stopped = true; held = false } }
        func finish() { lock.withLock { ended = true } }
        var blocked: Bool { lock.withLock { sawHold } }
        var done: Bool { lock.withLock { ended } }
        var shouldStop: Bool { lock.withLock { stopped } }
    }

    @Test("software acquisition cannot evict a cursor while its recovery transition is held")
    func readerHonoursDVRRecoveryHold() async throws {
        let demuxer = Demuxer()
        try demuxer.open(reader: Reader(TinyTransportStreamFixture.data), formatHint: "mpegts")
        let video = demuxer.videoStreamIndex
        let tb = try #require(demuxer.stream(at: video)).pointee.time_base
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ring = try PacketRingBuffer(windowSeconds: 2, scratch: directory)
        let condition = NSCondition()
        let gate = AdmissionGate()
        defer { gate.stop(); condition.withLock { condition.broadcast() } }
        Thread.detachNewThread {
            defer { demuxer.close(); gate.finish() }
            SoftwarePlaybackHost.runLiveReaderLoop(demuxer: demuxer,
                videoStreamIndex: video, audioStreamIndex: -1, condition: condition, ring: ring,
                videoTimeBaseSeconds: Double(tb.num) / Double(tb.den), audioTimeBaseSeconds: 0,
                noteEdge: { _ in gate.noteRead() }, readerMayAdvance: { gate.mayRead() },
                stopRequested: { gate.shouldStop }, onError: { _ in gate.stop() },
                onSourceEnded: {})
        }
        try await waitFor { gate.blocked || gate.done }
        #expect(gate.blocked)
        #expect(ring.seqBounds.first == 0)
        #expect(ring.seqBounds.end == 1)
        gate.release(); condition.withLock { condition.broadcast() }
        try await waitFor { gate.done }
        #expect(ring.seqBounds.end > 1)
        ring.close()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("software admission removes real H264/AAC replay before the DVR timeline")
    func softwarePacketAdmission() throws {
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        func signatures(_ bytes: Data) throws -> [LivePacketReplayGuard.Signature] {
            let demuxer = Demuxer()
            try demuxer.open(reader: Reader(bytes), formatHint: "mpegts", isLive: true)
            defer { demuxer.close() }
            let video = demuxer.videoStreamIndex
            let audio = demuxer.audioStreamIndex
            let vt = try #require(demuxer.stream(at: video)).pointee.time_base
            let at = try #require(demuxer.stream(at: audio)).pointee.time_base
            let filter = LiveReplayPacketReader(videoIndex: video, audioIndex: audio,
                videoTimeBase: Double(vt.num) / Double(vt.den), audioTimeBase: Double(at.num) / Double(at.den))
            var result: [LivePacketReplayGuard.Signature] = []
            while let packet = try filter.read(from: { try demuxer.readPacket() }) {
                defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }
                guard packet.pointee.stream_index == video || packet.pointee.stream_index == audio,
                      let data = packet.pointee.data, packet.pointee.size > 0 else { continue }
                result.append(.init(stream: packet.pointee.stream_index == video ? .video : .audio,
                    dts: packet.pointee.dts, pts: packet.pointee.pts,
                    payload: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size))))
            }
            return result
        }
        let baseline = try signatures(clip.head + clip.tail)
        let recovered = try signatures(clip.head + clip.replay + clip.tail)
        // TS/PES interleaving can change at the seam; each decoder must still receive
        // exactly its original compressed packets, in original per-track order.
        for track in [LivePacketReplayGuard.Stream.video, .audio] {
            #expect(recovered.filter { $0.stream == track } == baseline.filter { $0.stream == track })
        }
    }

    @Test("fresh producers keep cached replay history through repeated source recoveries")
    func freshProducerDoesNotAppendCachedPicturesAgain() async throws {
        let clip = try fixture()
        let cache = SegmentCache(forwardWindow: 32, backwardWindow: 32)
        defer { cache.close() }
        let first = try await run(clip.head + clip.diverged, expected: "sourceReplay", expectedRebases: 0,
                                  retainedCache: cache)
        let retainedSegments = cache.count
        let second = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0,
                                   retainedCache: cache, predecessor: first)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(first.packetsWrittenCount + second.packetsWrittenCount == control.packetsWrittenCount,
                "every picture is admitted once, including intact tail packets held before source loss")
        #expect(cache.count > retainedSegments)
        let beforeThird = cache.count
        let third = try await run(clip.head + clip.tail, expected: "sourceReplay", expectedRebases: 0,
                                  retainedCache: cache, predecessor: second)
        #expect(third.packetsWrittenCount == 0,
                "a third fresh connection repeating the entire cached broadcast produces nothing")
        #expect(cache.count == beforeThird, "previous DVR media is retained through repeated source loss")
    }

    @Test("exact overlap continues without rebasing the output")
    func exactOverlap() async throws {
        let clip = try fixture()
        try await run(clip.head + clip.head + clip.tail, expected: "eof", expectedRebases: 0)
    }

    @Test("a damaged packet inside verified overlap does not replay or restart the source")
    func divergentOverlapDoesNotReplayItsPrefix() async throws {
        let clip = try fixture()
        let result = try await run(clip.head + clip.diverged + clip.tail,
                                   expected: "eof", expectedRebases: 0)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(result.packetsWrittenCount == control.packetsWrittenCount)
    }

    @Test("a source ending inside a long exact overlap never publishes that overlap")
    func truncatedOverlapDoesNotReplayItsPrefix() async throws {
        let clip = try fixture()
        try await run(clip.head + clip.head, expected: "sourceReplay", expectedRebases: 0)
    }

    @Test("a read failure inside a confirmed overlap requests a fresh source")
    func failedOverlapDoesNotReplayItsPrefix() async throws {
        let clip = try fixture()
        try await run(clip.head + clip.head, expected: "sourceReplay", expectedRebases: 0,
                      failAtEnd: true)
    }

    @Test("a repeated overlap exceeding the packet bound never forwards its old media")
    func boundedOverlapDoesNotReplayItsPrefix() async throws {
        let clip = try fixture()
        var bytes = clip.head
        for _ in 0..<2_000 { bytes.append(clip.head) }
        try await run(bytes, expected: "sourceReplay", expectedRebases: 0,
                      mustLeaveUnreadBytes: true)
    }

    @Test("a short ambiguous match preserves a genuine source clock reset")
    func ambiguousOverlapKeepsNewMedia() async throws {
        let clip = try fixture(divergenceFrame: 1, divergenceFrames: 7)
        try await run(clip.head + clip.diverged + clip.tail, expected: "eof", expectedRebases: 1)
    }

    @Test("paired H.264/AAC replay continues only after both tracks finish the overlap")
    func pairedExactOverlap() async throws {
        // Leading AAC before the initial video gate was never accepted into replay history.
        // Replay the played A/V interval, not that unplayed join preroll.
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        try await run(clip.head + clip.replay + clip.tail, expected: "eof", expectedRebases: 0)
    }

    @Test("paired H.264/AAC divergence does not replay video or rebase either track")
    func pairedDivergentOverlap() async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), divergenceFrame: 9,
                               headFrames: 12, replayStartFrame: 2)
        let result = try await run(clip.head + clip.diverged + clip.tail,
                                   expected: "eof", expectedRebases: 0)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(result.packetsWrittenCount == control.packetsWrittenCount)
    }

    @Test("changed AAC at the first match or inside paired overlap continues without replay", arguments: [0, 150])
    func pairedAudioDivergence(packetIndex: Int) async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        var replay = clip.replay
        let adts = Data([0xFF, 0xF1, 0x4C])
        var offsets: [Int] = []
        var position = 0
        while let range = replay.range(of: adts, in: position..<replay.count) {
            offsets.append(range.lowerBound)
            position = range.upperBound
        }
        let offset = try #require(offsets.dropFirst(packetIndex).first)
        replay[offset + 2] ^= 0x02 // ADTS private bit: different bytes, same AAC configuration.
        let result = try await run(clip.head + replay + clip.tail, expected: "eof", expectedRebases: 0)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(result.packetsWrittenCount == control.packetsWrittenCount)
    }

    @Test("a different paired programme with reused timestamps preserves every video packet")
    func differentPairedProgramme() async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), divergenceFrame: 2,
                               divergenceFrames: 10, headFrames: 12, replayStartFrame: 2)
        var changed = clip.diverged
        var position = 0
        while let adts = changed.range(of: Data([0xFF, 0xF1, 0x4C]), in: position..<changed.count) {
            changed[adts.lowerBound + 2] ^= 0x02
            position = adts.upperBound
        }
        let result = try await run(clip.head + changed + clip.tail, expected: "eof", expectedRebases: 1)
        #expect(result.packetsWrittenCount == 26, "12 initial + 10 changed + 4 trailing pictures")
    }

    @Test("a clean outgoing PES before rollback cannot release the damaged video boundary")
    func corruptOutgoingVideoBeforeCleanTail() async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        var head = clip.head
        let aud = Data([0, 0, 0, 1, 9, 0xF0])
        let last = try #require(head.range(of: aud, options: .backwards))
        let previous = try #require(head.range(of: aud, options: .backwards, in: 0..<last.lowerBound))
        head[previous.lowerBound / 188 * 188 + 1] |= 0x80
        let capture = EngineLogCapture()
        defer { capture.end() }
        let result = try await run(head + clip.replay + clip.tail, expected: "eof", expectedRebases: 0)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(result.packetsWrittenCount == control.packetsWrittenCount)
        #expect(!capture.matching("live damaged packet: stream=video action=discarded").isEmpty)
        #expect(capture.matching("live damaged packet: stream=video action=forwarded").isEmpty)
    }

    @Test("the damaged outgoing video boundary is withheld until its intact replay arrives")
    func corruptOutgoingVideoBoundary() async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        var head = clip.head
        let aud = try #require(head.range(of: Data([0, 0, 0, 1, 9, 0xF0]), options: .backwards))
        // TS transport-error indicator flags this PES without changing its compressed payload.
        head[aud.lowerBound / 188 * 188 + 1] |= 0x80
        let capture = EngineLogCapture()
        defer { capture.end() }
        let result = try await run(head + clip.replay + clip.tail, expected: "eof", expectedRebases: 0)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(result.packetsWrittenCount == control.packetsWrittenCount)
        #expect(!capture.matching("live damaged boundary held:").isEmpty)
        #expect(!capture.matching("live damaged packet: stream=video action=discarded").isEmpty)
        #expect(capture.matching("live damaged packet: stream=video action=forwarded").isEmpty)
    }

    @Test("a corrupt first audio PES is held and discarded only after paired replay is verified")
    func corruptFirstAudioPES() async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        var replay = clip.replay
        let adts = try #require(replay.range(of: Data([0xFF, 0xF1, 0x4C])))
        let pes = try #require(replay.range(of: Data([0, 0, 1, 0xC0]), in: 0..<adts.lowerBound))
        let lengthOffset = pes.lowerBound + 4
        let length = Int(replay[lengthOffset]) * 256 + Int(replay[lengthOffset + 1]) + 1
        replay[lengthOffset] = UInt8(length >> 8)
        replay[lengthOffset + 1] = UInt8(length & 0xFF) // Truncated PES: one declared byte never arrives.
        let capture = EngineLogCapture()
        defer { capture.end() }
        let result = try await run(clip.head + replay + clip.tail, expected: "eof", expectedRebases: 0)
        let control = try await run(clip.head + clip.tail, expected: "eof", expectedRebases: 0)
        #expect(result.packetsWrittenCount == control.packetsWrittenCount)
        #expect(!capture.matching("live damaged packet: stream=audio action=held").isEmpty)
        #expect(!capture.matching("live damaged packet: stream=audio action=discarded").isEmpty)
    }

    @Test("paired replay interrupted by EOF or read failure never re-enters either timeline")
    func pairedInterruptedOverlap() async throws {
        let clip = try fixture(data: Self.audioVideoFixture(), headFrames: 12, replayStartFrame: 2)
        for failAtEnd in [false, true] {
            try await run(clip.head + clip.replay, expected: "sourceReplay", expectedRebases: 0,
                          failAtEnd: failAtEnd)
        }
    }


    /// Decode the actual admitted/remuxed media, including delayed B-frames. Packet counts
    /// alone cannot detect a lost reference picture or a broken fMP4 sample description.
    private func decodedPictures(_ bytes: Data, format: String, filterReplay: Bool) throws -> [SHA256.Digest] {
        let demuxer = Demuxer()
        try demuxer.open(reader: Reader(bytes), formatHint: format)
        defer { demuxer.close() }
        let video = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: video))
        let codec = try #require(avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id))
        let context = try #require(avcodec_alloc_context3(codec))
        let frame = try #require(av_frame_alloc())
        defer {
            var c: UnsafeMutablePointer<AVCodecContext>? = context; avcodec_free_context(&c)
            var f: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&f)
        }
        #expect(avcodec_parameters_to_context(context, stream.pointee.codecpar) >= 0)
        #expect(avcodec_open2(context, codec, nil) >= 0)
        let tb = stream.pointee.time_base
        let audio = demuxer.audioStreamIndex
        let at = try #require(demuxer.stream(at: audio)).pointee.time_base
        let admission = LiveReplayPacketReader(videoIndex: video, audioIndex: audio,
            videoTimeBase: Double(tb.num) / Double(tb.den), audioTimeBase: Double(at.num) / Double(at.den))
        var hashes: [SHA256.Digest] = []
        func drain() {
            while avcodec_receive_frame(context, frame) >= 0 {
                #expect(frame.pointee.decode_error_flags == 0)
                #expect(frame.pointee.format == AV_PIX_FMT_YUV420P.rawValue)
                var pixels = Data()
                for (plane, stride, divisor) in [(frame.pointee.data.0, frame.pointee.linesize.0, 1),
                                                  (frame.pointee.data.1, frame.pointee.linesize.1, 2),
                                                  (frame.pointee.data.2, frame.pointee.linesize.2, 2)] {
                    guard let plane else { Issue.record("missing decoded plane"); continue }
                    for row in 0..<(Int(frame.pointee.height) / divisor) {
                        pixels.append(plane + row * Int(stride), count: Int(frame.pointee.width) / divisor)
                    }
                }
                hashes.append(SHA256.hash(data: pixels))
                av_frame_unref(frame)
            }
        }
        while let packet = try (filterReplay ? admission.read(from: { try demuxer.readPacket() }) : demuxer.readPacket()) {
            defer { var p: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&p) }
            if packet.pointee.stream_index == video {
                #expect(avcodec_send_packet(context, packet) >= 0)
                drain()
            }
        }
        #expect(avcodec_send_packet(context, nil) >= 0)
        drain()
        return hashes
    }

    @Test("long GOP replay preserves every decoded picture on software and remux paths", arguments: [false, true])
    func longGOPDecodedContinuity(damaged: Bool) async throws {
        let bytes = try LongGOPTransportStreamFixture.data()
        let clip = try fixture(data: bytes, headFrames: 620, replayStartFrame: 120)
        var head = clip.head
        if damaged {
            let aud = Data([0, 0, 0, 1, 9])
            let last = try #require(head.range(of: aud, options: .backwards))
            let previous = try #require(head.range(of: aud, options: .backwards, in: 0..<last.lowerBound))
            head[previous.lowerBound / 188 * 188 + 1] |= 0x80
        }
        let expected = try decodedPictures(bytes, format: "mpegts", filterReplay: false)
        #expect(expected.count == 800)
        let replay = head + clip.replay + clip.tail
        #expect(try decodedPictures(replay, format: "mpegts", filterReplay: true) == expected)
        let cache = SegmentCache(forwardWindow: 32, backwardWindow: 32)
        defer { cache.close() }
        _ = try await run(replay, expected: "eof", expectedRebases: 0, retainedCache: cache)
        var remuxed = try #require(cache.initData(versionID: 0))
        for index in 0..<cache.count {
            remuxed.append(try #require(cache.fetch(index: index, timeout: 0)))
        }
        #expect(try decodedPictures(remuxed, format: "mov", filterReplay: false) == expected)
    }

    /// Exercise Apple's decoder as well as FFmpeg: the native consumer can reject a
    /// reference chain which FFmpeg conceals. Compare every pixel and presentation time.
    @Test("native decoding preserves long-GOP pictures through flagged and truncated replay seams", arguments: [0, 1, 2, 3, 4])
    func nativeLongGOPContinuity(seam: Int) async throws {
        let bytes = try LongGOPTransportStreamFixture.data()
        let clip = try fixture(data: bytes, headFrames: (seam == 2 || seam == 4) ? 501 : 620, replayStartFrame: 120)
        var head = clip.head
        let aud = Data([0, 0, 0, 1, 9])
        let last = try #require(head.range(of: aud, options: .backwards))
        if seam == 0 {
            let previous = try #require(head.range(of: aud, options: .backwards, in: 0..<last.lowerBound))
            head[previous.lowerBound / 188 * 188 + 1] |= 0x80
        } else {
            // Real transport loss inside the outgoing access unit, not just a flag on intact bytes.
            head = Data(head.prefix(last.lowerBound + (seam >= 3 ? 80 : 10)))
        }
        let expected = try decodedPictures(bytes, format: "mpegts", filterReplay: false)
        #expect(expected.count == 800)
        #expect(try decodedPictures(head + clip.replay + clip.tail, format: "mpegts", filterReplay: true) == expected)
        var decoded: [[NativePicture]] = []
        for input in [bytes, head + clip.replay + clip.tail] {
            let cache = SegmentCache(forwardWindow: 32, backwardWindow: 32)
            defer { cache.close() }
            _ = try await run(input, expected: "eof", expectedRebases: 0, retainedCache: cache)
            var remuxed = try #require(cache.initData(versionID: 0))
            for index in 0..<cache.count { remuxed.append(try #require(cache.fetch(index: index, timeout: 0))) }
            decoded.append(try await nativePictures(remuxed))
        }
        #expect(decoded[0].count == 800)
        #expect(decoded[1] == decoded[0])
    }

    private struct NativePicture: Equatable, Sendable {
        let ticks: Int64
        let digest: SHA256.Digest
    }

    private final class NativePictures: @unchecked Sendable {
        private let lock = NSLock()
        private var pictures: [NativePicture] = []
        private var failure: OSStatus = noErr
        func record(_ status: OSStatus, _ pixel: CVPixelBuffer?, _ pts: CMTime) {
            guard status == noErr, let pixel else { lock.withLock { failure = status }; return }
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixel) else { return }
            var hasher = SHA256()
            for row in 0..<CVPixelBufferGetHeight(pixel) {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: base + row * CVPixelBufferGetBytesPerRow(pixel), count: CVPixelBufferGetWidth(pixel) * 4))
            }
            let picture = NativePicture(ticks: CMTimeConvertScale(pts, timescale: 90_000,
                method: .roundHalfAwayFromZero).value, digest: hasher.finalize())
            lock.withLock { pictures.append(picture) }
        }
        func result() throws -> [NativePicture] {
            try lock.withLock {
                guard failure == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(failure)) }
                return pictures.sorted { $0.ticks < $1.ticks }
            }
        }
    }

    /// Decode the remuxed packet stream with Apple's VideoToolbox, not FFmpeg's decoder.
    /// AVAssetReader treats a concatenated, unindexed HLS fragment file as its first fragment;
    /// extracting compressed packets here avoids mistaking that file-container limit for lost video.
    private func nativePictures(_ data: Data) async throws -> [NativePicture] {
        let cancelled = ProbeTestBox(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(with: Swift.Result { try Self.decodeNative(data, cancelled: cancelled) })
                }
            }
        } onCancel: { cancelled.update { $0 = true } }
    }

    private static func decodeNative(_ data: Data, cancelled: ProbeTestBox<Bool>) throws -> [NativePicture] {
        func check(_ status: OSStatus) throws {
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        let demuxer = Demuxer()
        try demuxer.open(reader: ProbeRecordingReader(data: data), formatHint: "mov")
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let codec = try #require(stream.pointee.codecpar).pointee
        let extra = try #require(codec.extradata)
        let extensions: NSDictionary = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms:
            ["avcC": Data(bytes: extra, count: Int(codec.extradata_size))]]
        var description: CMVideoFormatDescription?
        try check(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264,
            width: codec.width, height: codec.height, extensions: extensions, formatDescriptionOut: &description))
        let pictures = NativePictures()
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { context, _, status, _, pixel, pts, _ in
            guard let context else { return }
            Unmanaged<NativePictures>.fromOpaque(context).takeUnretainedValue().record(status, pixel, pts)
        }, decompressionOutputRefCon: Unmanaged.passUnretained(pictures).toOpaque())
        var decoder: VTDecompressionSession?
        try check(VTDecompressionSessionCreate(allocator: nil, formatDescription: try #require(description),
            decoderSpecification: nil, imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &decoder))
        let session = try #require(decoder)
        defer { VTDecompressionSessionInvalidate(session) }
        while let packet = try demuxer.readPacket() {
            defer { var owned: UnsafeMutablePointer<AVPacket>? = packet; av_packet_free(&owned) }
            if cancelled.value { throw CancellationError() }
            guard packet.pointee.stream_index == demuxer.videoStreamIndex else { continue }
            let size = Int(packet.pointee.size)
            var block: CMBlockBuffer?
            try check(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block))
            let buffer = try #require(block)
            try check(CMBlockBufferReplaceDataBytes(with: try #require(packet.pointee.data), blockBuffer: buffer,
                offsetIntoDestination: 0, dataLength: size))
            let tb = stream.pointee.time_base
            var timing = CMSampleTimingInfo(duration: SourceTimestampBounds.cmTime(ticks: packet.pointee.duration, timeBase: tb),
                presentationTimeStamp: SourceTimestampBounds.cmTime(ticks: packet.pointee.pts, timeBase: tb),
                decodeTimeStamp: SourceTimestampBounds.cmTime(ticks: packet.pointee.dts, timeBase: tb))
            var sampleSize = size
            var sample: CMSampleBuffer?
            try check(CMSampleBufferCreateReady(allocator: nil, dataBuffer: buffer, formatDescription: description,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample))
            try check(VTDecompressionSessionDecodeFrame(session, sampleBuffer: try #require(sample), flags: [],
                frameRefcon: nil, infoFlagsOut: nil))
        }
        try check(VTDecompressionSessionFinishDelayedFrames(session))
        try check(VTDecompressionSessionWaitForAsynchronousFrames(session))
        return try pictures.result()
    }

    /// 8 s, 16x16 H.264 Baseline at 2 fps + AAC-LC stereo at 48 kHz, no B-frames.
    /// Regenerate with the TinyTransportStreamFixture command plus
    /// `-f lavfi -i anullsrc=r=48000:cl=stereo -t 8 -c:a aac -b:a 16k`, then raw DEFLATE.
    private static func audioVideoFixture() throws -> Data {
        let compressed = Data(base64Encoded: [
            "3VpbbBRVGD7TCxRIhW0pFSvxLLeWS3dnZi+0hSm7FLp9gKTGxCeTZXb2bHfs7s50ZkpbJc2CjeHBYEy8EIzBS/AZjInxwUhV",
            "vCAieEEwxJQYMSZeSqJvJOt/FpJ2u0nrimH392xy5pw5Z2b/+c/3/9+cLxMJuVaQXdMbiDBJSE7IEeFWdmVfg7CotzdtsoEl",
            "jzDrgK4xURo52HMuV1klEiIrCDlVn7edCNNk8+mat8pt1D8skX6wvepUc97262SatPBq+XV4Cu/ud18ut3nzlkiYiIv7CRk/",
            "P879PkVINlvrJot/Vnl3yTSvB3adWfr9kwKsTzXJV6Gbax/nA8kLwksUjotqc7l91/b88t6Nq33vvLj1Cr267vc/RuWgn7ZT",
            "zbAYlYIBavlkWaYxXyAoBlQY6PPABO++/j2Rdj8NP9oDM+NMg4EewxxLsYRDZVH0tcuiHICTSccxu7zekZERzwE9zoyUmvFE",
            "BOIyrAEv/ydP0kmnYJ5hOrqRsbuopsZUTRGpxRKKROMsljK0QUXsgh9VM2pqzGa8R9NMiesqtYdj0BKpaY/BdKijVlyRPCJM",
            "gYqm9VEWj/J78SuilpoZYIoUpFrSMtJqFC6VqGOxVEq3YUbHaEdcc6ChDaWhjjM1/oSRYYosbZUkmlBtJwq2N5j2oG7ChXdu",
            "MmRGjUTCZvxCJ2nBRTYMpgxjUE1CJzpzzk5BGM+cEGnGyv+NpqdVh5uiZxxmpVSYBOdjqWFLHYtqRtpU80aBfxxL1TNwC5ho",
            "qXxOwlLTjN9qhOkDSceE1iAbg2FFvtOIpvUMdGyNge2+MLlb5GWYNszNyZvAXWsxO8kXTFM0K0HTMfAnXxHoKAFYCTrEn0AR",
            "PUFomtyY/FEdVYKd0LAdZip+qpuwOAABWDs/LPSQIpIsIJQdmeja2EaazkTCgiiE4MwZ8udtpF9Rczf3ZqtP3LpG9qoHtKDP",
            "I3kkUSa7aN3k/R18THj/lntFzf5nHixzJyIIkn3Xfi+9/BdPAXnGfxySx+VT42V4ggXLrNS3rPfmTOoLH6cNJwEz8h3M/JSf",
            "suQ7tZJwMV8HMOM7XH6P/zvMhIgL8TuBC/E7QcDuJ4Ln+Xsbq7OCsP7NQyW8f7Ajh6vbjr1K6M4sxKq/IFaXXcYUqwG0sRoW",
            "ggV+r/8Wk9+34fU7CQKvCk+PVjqvuha5inm1owAzy7/BhJlOtJgJkQbEvNqAmFe3OcCrPzx2j2N1VhQ2stdKItaJ+16PZcmh",
            "oxCrXQWx6voaU6xuRxurYdIB+b0qGKr0/N50VirO7zsKMNP4FSbMKHgxI3QX+L3pEia/70Tr9xBpRMyrjYh5tRP2q1VH15dt",
            "v7p6/WRp+1Vh6cY2UkenZumRt2O1+SKmWJXQxmqYdHFevVFX6bzaMvHwQnrk6i8xYQavHjlXW2q5gMnveLWlEFmJmFdXIubV",
            "7cCr1cqvZePVNT9eL227WpPXgZ/KFumRa77AFKuY9cgdwKvVL1ysdF519wwtpEc+dB4TZjDrkU2I83sT4vyu8Pz+29tly+/r",
            "3hBK3Dc9wPdNrVNFeqT7c0yxiliPnKPprTuHye+INT3SDbxas+dYpfNqa9VzxbzaXfDN1YbPijFToR9gcT0S7TdXIbIKMa+u",
            "QsyrO4FXa145WDZe3RRzl7hvSvJ904lskR7Z+imm/I5ZjxR5fv9rf6Xn9y2TpxfSIzd9ggkz/x89csvHmPyOWY9sRsyrzYh5",
            "VQJerd23u2y86nWHS9yvbub7Ve9UkR7ZfhZTrGLWI2Xg1dqTbZXOq1L20kJ6pPcjTJjBq0fO1ZakDzH5HbW29Gyo3KYXljwK",
            "1uZR4PtgHhT8DQ==",
        ].joined())!
        return try (compressed as NSData).decompressed(using: .zlib) as Data
    }
}
