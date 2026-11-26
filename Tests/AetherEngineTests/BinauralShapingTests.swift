import Testing
import AudioToolbox
import Foundation
import CoreMedia
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// `AudioShaping.binaural` through the two PCM paths, the bridge and the software decoder.
///
/// The fixture is 5.1 with a 500 Hz tone on the left surround only. A plain fold puts it in the left
/// channel and leaves the right one silent; the binaural render puts it on the left ear and, later
/// and quieter, on the right one too, the way a speaker beside the listener reaches both ears. At
/// 500 Hz the head shadows little (measured: the far ear 5 dB down, against 16 dB for broadband
/// noise in `BinauralRendererTests`), hence the loose bound.
@Suite("Binaural audio shaping", .serialized, .offCooperativePoolOneLane, .timeLimit(.minutes(5)))
struct BinauralShapingTests {

    // MARK: - The value

    @Test("binaural is active shaping, renders only above stereo, and a mono cap wins")
    func value() {
        let b = AudioShaping(binaural: true)
        #expect(b.isActive)
        #expect(b.isBinauralOnly)
        #expect(!AudioShaping(compressor: .night, binaural: true).isBinauralOnly)
        #expect(!AudioShaping().isBinauralOnly)
        #expect(b.outputChannels(forSource: 6) == 2)
        #expect(b.outputChannels(forSource: 12) == 2)
        #expect(b.outputChannels(forSource: 2) == 2)
        #expect(b.outputChannels(forSource: 1) == 1)
        #expect(b.rendersBinaural(sourceChannels: 6))
        #expect(!b.rendersBinaural(sourceChannels: 2))
        #expect(!AudioShaping(maxChannels: 1, binaural: true).rendersBinaural(sourceChannels: 6))
        #expect(AudioShaping(maxChannels: 1, binaural: true).outputChannels(forSource: 6) == 1)
        #expect(AudioShaping(dialogueGainDB: 3, binaural: true).summary == "dialogue +3.0 dB, binaural")
        #expect(!b.isActive(forSourceChannels: 2), "a stereo source keeps its stream copy")
        #expect(!b.isActive(forSourceChannels: 1))
        #expect(b.isActive(forSourceChannels: 6))
        #expect(b.isActive(forSourceChannels: 0), "an unknown width counts as shaped")
        #expect(AudioShaping(dialogueGainDB: 3, binaural: true).isActive(forSourceChannels: 2))
    }

    @Test("a bed the mixer refuses: nil without a double free, and the resampler stays on the fold")
    func refusedRendererFolds() throws {
        try #require(BinauralRenderer.isAvailable)
        // Measured: the mixer refuses unknown labels and a 10 MHz rate, after the unit is allocated.
        #expect(BinauralRenderer(labels: [kAudioChannelLabel_Unknown, 9999], sampleRate: 48_000) == nil)
        #expect(BinauralRenderer(labels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right], sampleRate: 10_000_000) == nil)

        var stereo = layout("stereo"), five = layout("5.1"), bed = AVChannelLayout()
        defer { for case var l in [stereo, five, bed] { av_channel_layout_uninit(&l) } }
        let stage = AudioShapingStage(shaping: AudioShaping(binaural: true), outputFormat: AV_SAMPLE_FMT_FLT)
        let hasGraph = stage.configure(sampleRate: 10_000_000, outputLayout: &stereo, sourceLayout: &five, emit: nil)
        #expect(hasGraph, "the graph takes the rate, only the mixer refuses it")
        #expect(stage.renderer == nil)
        stage.resamplerLayout(source: &five, output: &stereo, into: &bed)
        #expect(bed.nb_channels == 2, "no renderer, so swr folds instead of writing a bed nothing takes (graph: \(hasGraph))")
    }

    // MARK: - The stage

    private func layout(_ name: String) -> AVChannelLayout {
        var l = AVChannelLayout()
        _ = av_channel_layout_from_string(&l, name)
        return l
    }

    @Test("the stage asks for the source's own bed, renders it to stereo, and follows a layout change")
    func stageFollowsTheSource() throws {
        try #require(BinauralRenderer.isAvailable)
        var stereo = layout("stereo"), five = layout("5.1"), seven = layout("7.1"), bed = AVChannelLayout()
        defer { for case var l in [stereo, five, seven, bed] { av_channel_layout_uninit(&l) } }
        let stage = AudioShapingStage(shaping: AudioShaping(binaural: true), outputFormat: AV_SAMPLE_FMT_FLT)
        #expect(stage.configure(sampleRate: 48_000, outputLayout: &stereo, sourceLayout: &five, emit: nil))
        stage.resamplerLayout(source: &five, output: &stereo, into: &bed)
        #expect(av_channel_layout_compare(&bed, &five) == 0)
        #expect(stage.renderer?.inputChannels == 6)

        stage.configure(sampleRate: 48_000, outputLayout: &stereo, sourceLayout: &seven) { _, _, _ in }
        #expect(stage.renderer?.inputChannels == 8)

        stage.configure(sampleRate: 48_000, outputLayout: &stereo, sourceLayout: &stereo) { _, _, _ in }
        #expect(stage.renderer == nil, "a stereo source plays as it is")
        stage.resamplerLayout(source: &stereo, output: &stereo, into: &bed)
        #expect(bed.nb_channels == 2)
    }

    @Test("a source the mixer cannot place is folded to 7.1 first")
    func unknownChannelsFoldTo71() {
        var ambisonic = layout("ambisonic 1"), bed = AVChannelLayout()
        defer { av_channel_layout_uninit(&ambisonic); av_channel_layout_uninit(&bed) }
        AudioShapingStage.binauralBed(for: &ambisonic, into: &bed)
        #expect(bed.nb_channels == 8)
    }

    // MARK: - End to end

    /// 16-bit 5.1 WAV with a 500 Hz tone on channel `active` only.
    private func makeWAV(active: Int, channels: Int = 6, seconds: Double = 0.5) -> Data {
        let rate = 48_000
        let frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for n in 0..<frames {
            let v = Int16(0.25 * 32767 * sin(2 * .pi * 500 * Double(n) / Double(rate)))
            for c in 0..<channels {
                withUnsafeBytes(of: (c == active ? v : 0).littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(rate))
        u32(UInt32(rate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    private func withAudioStream(_ wav: Data,
                                 _ body: (UnsafeMutablePointer<AVStream>, [UnsafeMutablePointer<AVPacket>]) throws -> Void) throws {
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
        try body(stream, packets)
    }

    /// RMS of each output channel past the first 100 ms, and the output's codec and width.
    private struct Output { var codec: AVCodecID; var channels: Int32; var left: Double; var right: Double }

    private func rms(_ s: [Float]) -> Double {
        let body = s.dropFirst(4800)
        return sqrt(body.reduce(0) { $0 + Double($1 * $1) } / Double(max(body.count, 1)))
    }

    private func bridged(_ shaping: AudioShaping, active: Int) throws -> Output {
        var out = Output(codec: AV_CODEC_ID_NONE, channels: 0, left: 0, right: 0)
        try withAudioStream(makeWAV(active: active)) { stream, packets in
            let bridge = try AudioBridge(srcCodecpar: stream.pointee.codecpar, srcTimeBase: stream.pointee.time_base,
                                         mode: .surroundCompat, shaping: shaping)
            defer { bridge.close() }
            let cp = try #require(bridge.encoderCodecpar)
            var encoded: [UnsafeMutablePointer<AVPacket>] = []
            defer { for o in encoded { var oo: UnsafeMutablePointer<AVPacket>? = o; trackedPacketFree(&oo) } }
            for p in packets { encoded.append(contentsOf: try bridge.feed(packet: p)) }
            encoded.append(contentsOf: bridge.flush())

            let codec = try #require(avcodec_find_decoder(cp.pointee.codec_id))
            var ctx = avcodec_alloc_context3(codec)
            defer { avcodec_free_context(&ctx) }
            let dec = try #require(ctx)
            _ = avcodec_parameters_to_context(dec, cp)
            #expect(avcodec_open2(dec, codec, nil) >= 0)
            var frame = av_frame_alloc()
            defer { av_frame_free(&frame) }
            var l: [Float] = [], r: [Float] = []
            for pkt in encoded {
                _ = avcodec_send_packet(dec, pkt)
                while avcodec_receive_frame(dec, frame) >= 0, let f = frame {
                    let n = Int(f.pointee.nb_samples)
                    let ch = Int(f.pointee.ch_layout.nb_channels)
                    if AVSampleFormat(rawValue: f.pointee.format) == AV_SAMPLE_FMT_S16 {
                        f.pointee.data.0!.withMemoryRebound(to: Int16.self, capacity: n * ch) { p in
                            for i in 0..<n { l.append(Float(p[i * ch]) / 32768); r.append(Float(p[i * ch + 1]) / 32768) }
                        }
                    } else {
                        #expect(AVSampleFormat(rawValue: f.pointee.format) == AV_SAMPLE_FMT_S32)
                        f.pointee.data.0!.withMemoryRebound(to: Int32.self, capacity: n * ch) { p in
                            for i in 0..<n {
                                l.append(Float(p[i * ch]) / 2147483648)
                                r.append(Float(p[i * ch + 1]) / 2147483648)
                            }
                        }
                    }
                }
            }
            out = Output(codec: cp.pointee.codec_id, channels: cp.pointee.ch_layout.nb_channels, left: rms(l), right: rms(r))
        }
        return out
    }

    private func decoded(_ shaping: AudioShaping, active: Int) throws -> Output {
        var out = Output(codec: AV_CODEC_ID_NONE, channels: 0, left: 0, right: 0)
        try withAudioStream(makeWAV(active: active)) { stream, packets in
            let decoder = AudioDecoder()
            decoder.shaping = shaping
            try decoder.open(stream: stream)
            defer { decoder.close() }
            var buffers: [CMSampleBuffer] = []
            for p in packets { buffers.append(contentsOf: decoder.decode(packet: p)) }
            buffers.append(contentsOf: decoder.drain())
            var l: [Float] = [], r: [Float] = []
            for b in buffers {
                let n = CMSampleBufferGetNumSamples(b)
                let block = try #require(CMSampleBufferGetDataBuffer(b))
                var data = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
                _ = data.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                #expect(data.count == n * 2, "the decoder hands out stereo")
                for i in 0..<n { l.append(data[i * 2]); r.append(data[i * 2 + 1]) }
            }
            out = Output(codec: AV_CODEC_ID_NONE, channels: decoder.channels, left: rms(l), right: rms(r))
        }
        return out
    }

    private func db(_ a: Double, over b: Double) -> Double { 20 * log10(max(a, 1e-9) / max(b, 1e-9)) }

    @Test("bridge: the left surround reaches both ears in a stereo FLAC, the plain fold leaves the right silent")
    func bridgePlacesTheSurround() throws {
        try #require(BinauralRenderer.isAvailable)
        let fold = try bridged(AudioShaping(maxChannels: 2), active: 4)
        let binaural = try bridged(AudioShaping(binaural: true), active: 4)
        #expect(binaural.codec == AV_CODEC_ID_FLAC)
        #expect(binaural.channels == 2)
        #expect(db(fold.right, over: fold.left) < -60)
        let crossfeed = db(binaural.right, over: binaural.left)
        #expect(crossfeed > -30 && crossfeed < -2, "far ear \(crossfeed) dB under the near one")
        #expect(abs(db(binaural.left, over: fold.left)) < 6, "near ear within 6 dB of the fold's level")
    }

    @Test("bridge: the centre lands evenly on both ears")
    func bridgeCentre() throws {
        try #require(BinauralRenderer.isAvailable)
        let out = try bridged(AudioShaping(binaural: true), active: 2)
        #expect(abs(db(out.left, over: out.right)) < 1.5)
    }

    @Test("software decoder: stereo out, the surround on both ears")
    func decoderPlacesTheSurround() throws {
        try #require(BinauralRenderer.isAvailable)
        let out = try decoded(AudioShaping(binaural: true), active: 5)
        #expect(out.channels == 2)
        let crossfeed = db(out.left, over: out.right)
        #expect(crossfeed > -30 && crossfeed < -2, "far ear \(crossfeed) dB under the near one")
    }
}
