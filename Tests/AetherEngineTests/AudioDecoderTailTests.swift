import Testing
import Foundation
import CoreMedia
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Audit AUD-205, AUD-206, AUD-208, AUD-209: what the software PCM path does at the end of a
/// source, and the bounds around the tail fill.
@Suite("Audio tail and clock audit fixes", .serialized, .offCooperativePoolOneLane)
struct AudioDecoderTailTests {

    private func makeWAV(frames: Int) -> Data {
        var pcm = Data(capacity: frames * 4)
        for n in 0..<frames {
            let v = Int16(0.1 * 32767 * sin(2 * .pi * 440 * Double(n) / 48_000))
            for _ in 0..<2 { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        }
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(2); u32(48_000)
        u32(48_000 * 4); u16(4); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    private func withDecoder(_ wav: Data, configure: (AudioDecoder) -> Void,
                             _ body: (AudioDecoder, [UnsafeMutablePointer<AVPacket>]) throws -> Void) throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: wav))
        let idx = demuxer.audioStreamIndex
        let stream = try #require(idx >= 0 ? demuxer.stream(at: idx) : nil)
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        defer { for p in packets { var pp: UnsafeMutablePointer<AVPacket>? = p; trackedPacketFree(&pp) } }
        while let packet = try demuxer.readPacket() {
            if packet.pointee.stream_index == idx { packets.append(packet) } else {
                var p: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&p)
            }
        }
        let decoder = AudioDecoder()
        configure(decoder)
        try decoder.open(stream: stream)
        defer { decoder.close() }
        try body(decoder, packets)
    }

    @Test("the software host's end-of-stream call gives back the shaped tail (AUD-205)")
    func endOfStreamDrainsTheDecoder() throws {
        let frames = 48_000 + 700
        try withDecoder(makeWAV(frames: frames), configure: { $0.shaping = AudioShaping(dialogueGainDB: 6) }) { decoder, packets in
            let producer: any SoftwareAudioProducing = decoder
            var emitted = 0
            for p in packets { emitted += producer.decode(packet: p).reduce(0) { $0 + CMSampleBufferGetNumSamples($1) } }
            #expect(emitted < frames, "the enhancer and the coalescing hold samples back")
            emitted += producer.endOfStream().reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
            #expect(emitted == frames, "\(frames - emitted) samples never reached the renderer")
        }
    }

    @Test("every buffer of a normalized run carries a PTS, the limiter tail included (AUD-206)")
    func normalizationTailIsStamped() throws {
        try withDecoder(makeWAV(frames: 48_000), configure: { $0.normalizationGainDB = 3 }) { decoder, packets in
            var buffers: [CMSampleBuffer] = []
            for p in packets { buffers.append(contentsOf: decoder.decode(packet: p)) }
            buffers.append(contentsOf: decoder.drain())
            #expect(buffers.count > 1)
            var expectedNext: CMTime?
            for b in buffers {
                let pts = CMSampleBufferGetPresentationTimeStamp(b)
                #expect(pts.isValid, "a buffer was stamped invalid")
                if let expectedNext, pts.isValid {
                    #expect(abs(CMTimeGetSeconds(CMTimeSubtract(pts, expectedNext))) < 1e-6, "buffers do not abut")
                }
                expectedNext = CMTimeAdd(pts, CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(b)), timescale: 48_000))
            }
        }
    }

    @Test("a mid-run buffer without a source PTS continues from the running count (AUD-206)")
    func clockExtrapolatesWithoutPTS() {
        var clock = AudioClockAnchor()
        let first = clock.resolve(startPTS: CMTime(seconds: 10, preferredTimescale: 48_000), sampleRate: 48_000)
        #expect(first.reanchor)
        clock.commit(pts: first.pts, reanchor: true, sampleCount: 1024)
        let next = clock.resolve(startPTS: .invalid, sampleRate: 48_000)
        #expect(!next.reanchor)
        #expect(abs(CMTimeGetSeconds(next.pts) - (10 + 1024.0 / 48_000)) < 1e-9)
        #expect(clock.resolve(startPTS: .invalid, sampleRate: 48_000).pts.isValid)
        var fresh = AudioClockAnchor()
        #expect(!fresh.resolve(startPTS: .invalid, sampleRate: 48_000).pts.isValid)
        fresh.reset()
    }

    @Test("the tap callback's pointer overload processes like the array one (AUD-208)")
    func planesOverloadMatchesArray() {
        let frames = 512, channels = 2
        func run(_ body: (NormalizationGainProcessor, [UnsafeMutablePointer<Float>]) -> Void) -> [Float] {
            let storage = (0..<channels).map { c in
                let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                for f in 0..<frames { p[f] = 0.5 * Float(sin(Double(f) * 0.05 + Double(c))) }
                return p
            }
            defer { storage.forEach { $0.deallocate() } }
            body(NormalizationGainProcessor(gainDB: 6, sampleRate: 48_000, channels: channels), storage)
            return storage.flatMap { Array(UnsafeBufferPointer(start: $0, count: frames)) }
        }
        let viaArray = run { $0.process(planes: $1, frames: frames) }
        let viaBuffer = run { p, planes in planes.withUnsafeBufferPointer { p.process(planes: $0, frames: frames) } }
        #expect(viaArray == viaBuffer)
    }

    @Test("the tail fill is capped, and an uncapped span is left alone (AUD-209)")
    func fillSpanIsCapped() {
        let tenHours = AudioTailPadding.span(videoEnd: 36_000, audioEnd: 100, segmentStart: 90)
        #expect(tenHours?.capped == true)
        #expect(tenHours?.start == 100)
        #expect(tenHours?.end == 100 + AudioTailPadding.maxFillSeconds)
        let normal = AudioTailPadding.span(videoEnd: 60, audioEnd: 57.5, segmentStart: 55.96)
        #expect(normal?.capped == false)
        #expect(normal?.end == 60)
    }

    @Test("the streamed fill hands out the same stamped packets the collected one returns (AUD-209)")
    func streamingMatchesCollecting() throws {
        var parOpt = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&parOpt) }
        let par = try #require(parOpt)
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_AC3
        par.pointee.sample_rate = 48_000
        av_channel_layout_default(&par.pointee.ch_layout, 2)
        guard avcodec_find_encoder(AV_CODEC_ID_AC3) != nil else { return }
        let tb = AVRational(num: 1, den: 48_000)
        var streamed: [(Int64, Int64)] = []
        let outcome = AudioTailPadding.streamSilence(codecpar: par, startTicks: 1000, endTicks: 1000 + 48_000 * 5,
                                                     timeBase: tb) { packet in
            streamed.append((packet.pointee.pts, packet.pointee.duration))
            var p: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&p)
        }
        guard case .streamed(_, let count) = outcome else { Issue.record("expected .streamed"); return }
        #expect(count == streamed.count)
        guard case .packets(let collected, _) = AudioTailPadding.silencePackets(
            codecpar: par, startTicks: 1000, endTicks: 1000 + 48_000 * 5, timeBase: tb) else {
            Issue.record("expected .packets"); return
        }
        defer { for p in collected { var q: UnsafeMutablePointer<AVPacket>? = p; trackedPacketFree(&q) } }
        #expect(collected.map { ($0.pointee.pts, $0.pointee.duration) }.elementsEqual(streamed) { $0 == $1 })
        #expect(streamed.first?.0 == 1000)
    }
}
