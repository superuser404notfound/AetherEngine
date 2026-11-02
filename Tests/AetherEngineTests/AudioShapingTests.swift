import Testing
import Foundation
import CoreMedia
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#923: a channel cap, a dialogue lift and night-mode compression, applied to decoded PCM on the
/// bridge (loopback) and the software decoder.
///
/// The end-to-end checks drive a 5.1 fixture that puts a 1 kHz tone on the front centre only and a
/// 250 Hz tone on every other channel, so "the dialogue got louder" is a measured ratio between two
/// frequencies rather than a level that a fold or a limiter could also have moved.
@Suite("AE#923 audio shaping", .serialized, .offCooperativePoolOneLane)
struct AudioShapingTests {

    // MARK: - The value

    @Test("the default shapes nothing, and a cap of 8 is no cap")
    func defaultIsInactive() {
        #expect(!AudioShaping().isActive)
        #expect(!AudioShaping(maxChannels: 8).isActive)
        #expect(!AudioShaping(maxChannels: 12).isActive)
        #expect(AudioShaping(maxChannels: 2).isActive)
        #expect(AudioShaping(dialogueGainDB: 3).isActive)
        #expect(AudioShaping(compressor: .night).isActive)
    }

    @Test("every field is clamped, and a non-finite value takes the neutral end")
    func clamping() {
        let c = AudioShaping(maxChannels: 0, dialogueGainDB: 40,
                             compressor: .init(thresholdDB: -100, ratio: .nan, makeupGainDB: 99)).clamped
        #expect(c.maxChannels == 1)
        #expect(c.dialogueGainDB == AudioShaping.maxDialogueGainDB)
        #expect(c.compressor?.thresholdDB == -60)
        #expect(c.compressor?.ratio == 1)
        #expect(c.compressor?.makeupGainDB == 24)
        #expect(AudioShaping(dialogueGainDB: -6).clamped.dialogueGainDB == 0)
        #expect(LoadOptions(audioShaping: AudioShaping(dialogueGainDB: 40)).audioShaping.dialogueGainDB
                == AudioShaping.maxDialogueGainDB)
    }

    @Test("a cap never upmixes")
    func capNeverUpmixes() {
        let cap = AudioShaping(maxChannels: 6)
        #expect(cap.outputChannels(forSource: 8) == 6)
        #expect(cap.outputChannels(forSource: 2) == 2)
        #expect(AudioShaping().outputChannels(forSource: 8) == 8)
    }

    @Test("the state is off without shaping, and follows the pipeline's report with it")
    func stateDerivation() {
        let on = AudioShaping(compressor: .night)
        #expect(AudioShapingState.derive(shaping: AudioShaping(), pipelineApplies: true) == .off)
        #expect(AudioShapingState.derive(shaping: on, pipelineApplies: nil) == .off)
        #expect(AudioShapingState.derive(shaping: on, pipelineApplies: true) == .applied)
        #expect(AudioShapingState.derive(shaping: on, pipelineApplies: false) == .unavailable)
    }

    // MARK: - The matrix

    private func withLayouts<T>(_ input: String, _ output: String,
                                _ body: (UnsafePointer<AVChannelLayout>, UnsafePointer<AVChannelLayout>) -> T) -> T {
        var i = AVChannelLayout(), o = AVChannelLayout()
        defer { av_channel_layout_uninit(&i); av_channel_layout_uninit(&o) }
        _ = av_channel_layout_from_string(&i, input)
        _ = av_channel_layout_from_string(&o, output)
        return body(&i, &o)
    }

    @Test("same layout and no lift leaves libswresample's default in place")
    func identityIsNil() {
        #expect(withLayouts("5.1", "5.1") { AudioShapingMatrix.coefficients(input: $0, output: $1, dialogueGain: 1) } == nil)
    }

    @Test("a 5.1 fold to stereo raises only the centre column")
    func foldLiftsCentreColumn() throws {
        let plain = try #require(withLayouts("5.1", "stereo") {
            AudioShapingMatrix.coefficients(input: $0, output: $1, dialogueGain: 1) })
        let lifted = try #require(withLayouts("5.1", "stereo") {
            AudioShapingMatrix.coefficients(input: $0, output: $1, dialogueGain: 2) })
        // 5.1 order: FL FR FC LFE BL BR (or SL SR); FC is input 2.
        for o in 0..<2 {
            for i in 0..<6 {
                let expected = i == 2 ? plain[o * 6 + i] * 2 : plain[o * 6 + i]
                #expect(abs(lifted[o * 6 + i] - expected) < 1e-12, "out \(o) in \(i)")
            }
        }
        #expect(abs(plain[0 * 6 + 2] - M_SQRT1_2) < 1e-9, "libswresample's -3 dB centre level")
        #expect(plain[0 * 6 + 3] == 0, "LFE stays out of the fold")
    }

    @Test("a source without a centre gets nothing from the matrix; the graph lifts it instead")
    func noCentreNoMatrixLift() throws {
        #expect(withLayouts("stereo", "stereo") { AudioShapingMatrix.coefficients(input: $0, output: $1, dialogueGain: 2) }
                .map { $0 == [1, 0, 0, 1] } ?? false)
        #expect(withLayouts("stereo", "stereo") { i, _ in AudioShapingMatrix.hasCentre(i) } == false)
        #expect(withLayouts("5.1", "stereo") { i, _ in AudioShapingMatrix.hasCentre(i) })
        #expect(withLayouts("mono", "mono") { i, _ in AudioShapingMatrix.hasCentre(i) } == false,
                "a mono track is the whole mix, not a centre")
    }

    @Test("an unspecified order reads as the default order for its channel count")
    func unspecifiedOrder() throws {
        var i = AVChannelLayout(), o = AVChannelLayout()
        defer { av_channel_layout_uninit(&i); av_channel_layout_uninit(&o) }
        i.order = AV_CHANNEL_ORDER_UNSPEC
        i.nb_channels = 6
        av_channel_layout_default(&o, 2)
        let m = try #require(AudioShapingMatrix.coefficients(input: &i, output: &o, dialogueGain: 2))
        #expect(abs(m[2] - 2 * M_SQRT1_2) < 1e-9, "FC found at index 2 of the default 5.1 order")
    }

    // MARK: - The filter graph

    @Test("the chain: the limiter always, the compressor and the stereo enhancer only when asked")
    func chainShape() {
        let plain = AudioShapingGraph.chain(shaping: AudioShaping(maxChannels: 2), stereoDialogueEnhance: false,
                                            outputFormat: AV_SAMPLE_FMT_FLT, layoutDescription: "stereo")
        #expect(plain == "alimiter=limit=0.891251:attack=5.000000:release=50.000000:level=0:latency=1,"
                + "aformat=sample_fmts=flt:channel_layouts=stereo")
        let full = AudioShapingGraph.chain(shaping: AudioShaping(dialogueGainDB: 6, compressor: .night),
                                           stereoDialogueEnhance: true, outputFormat: AV_SAMPLE_FMT_S16,
                                           layoutDescription: "stereo")
        #expect(full.hasPrefix("dialoguenhance=original=1:enhance=1:voice=2,pan=stereo|c0=c0+0.995262*c2|c1=c1+0.995262*c2,acompressor="))
        #expect(full.contains("link=maximum:detection=peak"))
        #expect(full.hasSuffix("aformat=sample_fmts=s16:channel_layouts=stereo"))
    }

    @Test("the stereo enhancer runs only on stereo out without a centre to lift")
    func enhancerGate() {
        let lift = AudioShaping(dialogueGainDB: 6)
        #expect(AudioShapingGraph.usesStereoDialogueEnhance(shaping: lift, outputChannels: 2, sourceHasCentre: false))
        #expect(!AudioShapingGraph.usesStereoDialogueEnhance(shaping: lift, outputChannels: 2, sourceHasCentre: true))
        #expect(!AudioShapingGraph.usesStereoDialogueEnhance(shaping: lift, outputChannels: 6, sourceHasCentre: false))
        #expect(!AudioShapingGraph.usesStereoDialogueEnhance(shaping: AudioShaping(compressor: .night),
                                                              outputChannels: 2, sourceHasCentre: false))
        #expect(AudioShapingGraph.dialogueEnhanceLatency(sampleRate: 48_000) == 1536)
        #expect(AudioShapingGraph.dialogueEnhanceLatency(sampleRate: 44_100) == 1536)
        #expect(AudioShapingGraph.dialogueEnhanceLatency(sampleRate: 96_000) == 3072)
    }

    /// Runs interleaved Float32 through a graph in `chunk`-sized pushes and drains it.
    private func runGraph(_ input: [Float], channels: Int32, shaping: AudioShaping, sourceHasCentre: Bool = false,
                          chunk: Int = 1000, pts: Int64? = 0) throws -> (out: [Float], pts: [(Int64?, Int)], latency: Int) {
        var layout = AVChannelLayout()
        defer { av_channel_layout_uninit(&layout) }
        av_channel_layout_default(&layout, channels)
        let graph = try #require(AudioShapingGraph(shaping: shaping, sampleRate: 48_000, layout: &layout,
                                                   sourceHasCentre: sourceHasCentre, outputFormat: AV_SAMPLE_FMT_FLT))
        var out: [Float] = []
        var stamps: [(Int64?, Int)] = []
        let ch = Int(channels)
        let collect: ([UnsafeMutableRawPointer?], Int, Int64?) -> Void = { planes, count, p in
            let base = planes[0]!.assumingMemoryBound(to: Float.self)
            stamps.append((p, out.count / ch))
            out.append(contentsOf: UnsafeBufferPointer(start: base, count: count * ch))
        }
        let frames = input.count / ch
        var at = 0
        input.withUnsafeBufferPointer { buf in
            while at < frames {
                let n = min(chunk, frames - at)
                graph.process(buf.baseAddress! + at * ch, frames: n, pts: pts.map { $0 + Int64(at) }, emit: collect)
                at += n
            }
        }
        graph.drain(emit: collect)
        return (out, stamps, graph.latency)
    }

    private func noise(_ frames: Int, seed: UInt64, level: Float) -> [Float] {
        var x = seed
        return (0..<frames).map { _ in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return level * (Float(Int64(bitPattern: x >> 1) % 2_000_001) / 1_000_000 - 1)
        }
    }

    @Test("the enhancer's latency is taken back out: same sample count, an impulse lands on its own sample")
    func enhancerIsSampleAligned() throws {
        let frames = 48_000
        let l = noise(frames, seed: 1, level: 0.05), r = noise(frames, seed: 2, level: 0.05)
        var input = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames { input[2 * f] = l[f]; input[2 * f + 1] = r[f] }
        input[2 * 30_000] = 0.6; input[2 * 30_000 + 1] = 0.6
        let run = try runGraph(input, channels: 2, shaping: AudioShaping(dialogueGainDB: 6))
        #expect(run.latency == 1536)
        #expect(run.out.count == input.count, "every sample in comes out, priming dropped and tail drained")
        let peak = stride(from: 0, to: run.out.count, by: 2).max { abs(run.out[$0]) < abs(run.out[$1]) }! / 2
        #expect(peak == 30_000, "impulse at 30000 came out at \(peak)")
    }

    @Test("pts rides with its sample through the graph")
    func ptsFollowsSamples() throws {
        let input = noise(20_000 * 2, seed: 3, level: 0.05)
        let run = try runGraph(input, channels: 2, shaping: AudioShaping(dialogueGainDB: 6), chunk: 777, pts: 1_000_000)
        for (pts, index) in run.pts {
            #expect(pts == 1_000_000 + Int64(index), "chunk at output sample \(index) carried \(String(describing: pts))")
        }
    }

    @Test("the limiter holds every sample under -1 dBFS")
    func limiterHoldsCeiling() throws {
        let frames = 48_000
        let input = (0..<frames).flatMap { f -> [Float] in
            let v = 2.5 * Float(sin(2 * .pi * 1000 * Double(f) / 48_000)); return [v, v]
        }
        let run = try runGraph(input, channels: 2, shaping: AudioShaping(maxChannels: 2))
        let ceiling = Float(pow(10, AudioShapingGraph.ceilingDBFS / 20))
        #expect((run.out.map { abs($0) }.max() ?? 0) <= ceiling + 1e-4)
        #expect(run.out.count == input.count)
    }

    @Test("night mode brings a loud passage down and a quiet one up")
    func nightNarrowsTheRange() throws {
        func settledPeakDB(amplitude: Float) throws -> Double {
            let frames = 96_000
            let input = (0..<frames).flatMap { f -> [Float] in
                let v = amplitude * Float(sin(2 * .pi * 1000 * Double(f) / 48_000)); return [v, v]
            }
            let run = try runGraph(input, channels: 2, shaping: AudioShaping(compressor: .night))
            return 20 * log10(Double(run.out.suffix(19_200).map { abs($0) }.max() ?? 0))
        }
        let loud = try settledPeakDB(amplitude: 1)
        let quiet = try settledPeakDB(amplitude: 0.01)
        #expect(loud < -10 && loud > -15, "0 dBFS comes down to about -12.5, got \(loud)")
        #expect(quiet > -31 && quiet < -29, "-40 dBFS comes up to -30, got \(quiet)")
    }

    // MARK: - End to end

    /// 16-bit WAV, `channels` wide: a 1 kHz tone on channel 2 (the front centre of a 5.1 default
    /// order) and a 250 Hz tone on every other channel, each at `amplitude` of full scale.
    private func makeDialogueWAV(channels: Int, seconds: Double = 0.5, amplitude: Double = 0.25) -> Data {
        let rate = 48_000
        let frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for n in 0..<frames {
            let t = Double(n) / Double(rate)
            let dialogue = Int16(amplitude * 32767 * sin(2 * .pi * 1000 * t))
            let score = Int16(amplitude * 32767 * sin(2 * .pi * 250 * t))
            for c in 0..<channels {
                let v = (channels > 2 && c == 2) ? dialogue : score
                withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
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

    /// Stereo WAV with no centre channel: a 1 kHz tone identical in both channels, switched on and
    /// off every 150 ms the way speech comes and goes, over noise that differs between the two
    /// sides. Optionally a full-scale-ish impulse in both channels at `impulseAt`.
    private func makeStereoWAV(seconds: Double = 2, impulseAt: Int? = nil) -> Data {
        let rate = 48_000
        let frames = Int(Double(rate) * seconds)
        var pcm = Data(capacity: frames * 4)
        var seed: UInt64 = 9
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: seed >> 1) % 2_000_001) / 1_000_000 - 1
        }
        for n in 0..<frames {
            let t = Double(n) / Double(rate)
            let on = Int(t / 0.15) % 2 == 0 ? 1.0 : 0.0
            let centre = 0.1 * on * sin(2 * .pi * 1000 * t)
            for _ in 0..<2 {
                var v = centre + 0.1 * rnd()
                if n == impulseAt { v = 0.7 }
                let s = Int16(max(-1, min(1, v)) * 32767)
                withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(2); u32(UInt32(rate))
        u32(UInt32(rate * 4)); u16(4); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    /// Goertzel magnitude of `hz` over `samples`.
    private func level(_ samples: [Float], hz: Double, rate: Double = 48_000) -> Double {
        let w = 2 * .pi * hz / rate
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for x in samples {
            let s0 = Double(x) + coeff * s1 - s2
            s2 = s1; s1 = s0
        }
        return sqrt(s1 * s1 + s2 * s2 - coeff * s1 * s2) / Double(samples.count)
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

    /// Runs the fixture through a bridge and decodes what it encoded, channel 0 only.
    private func bridgedLeftChannel(sourceChannels: Int, shaping: AudioShaping, amplitude: Double = 0.25,
                                    wav: Data? = nil) throws -> (codec: AVCodecID, channels: Int32, left: [Float]) {
        var result: (AVCodecID, Int32, [Float]) = (AV_CODEC_ID_NONE, 0, [])
        try withAudioStream(wav ?? makeDialogueWAV(channels: sourceChannels, amplitude: amplitude)) { stream, packets in
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
            dec.pointee.request_sample_fmt = AV_SAMPLE_FMT_FLT
            #expect(avcodec_open2(dec, codec, nil) >= 0)
            var frame = av_frame_alloc()
            defer { av_frame_free(&frame) }
            var left: [Float] = []
            for pkt in encoded {
                _ = avcodec_send_packet(dec, pkt)
                while avcodec_receive_frame(dec, frame) >= 0, let f = frame {
                    let n = Int(f.pointee.nb_samples)
                    let ch = Int(f.pointee.ch_layout.nb_channels)
                    let fmt = AVSampleFormat(rawValue: f.pointee.format)
                    for i in 0..<n {
                        switch fmt {
                        case AV_SAMPLE_FMT_S16:
                            left.append(Float(f.pointee.data.0!.withMemoryRebound(to: Int16.self, capacity: n * ch) { $0[i * ch] }) / 32768)
                        case AV_SAMPLE_FMT_S32:
                            left.append(Float(f.pointee.data.0!.withMemoryRebound(to: Int32.self, capacity: n * ch) { $0[i * ch] }) / 2147483648)
                        case AV_SAMPLE_FMT_FLTP:
                            left.append(f.pointee.data.0!.withMemoryRebound(to: Float.self, capacity: n) { $0[i] })
                        default:
                            left.append(f.pointee.data.0!.withMemoryRebound(to: Float.self, capacity: n * ch) { $0[i * ch] })
                        }
                    }
                }
            }
            result = (cp.pointee.codec_id, cp.pointee.ch_layout.nb_channels, left)
        }
        return result
    }

    @Test("a 5.1 source capped to stereo is bridged as stereo FLAC, not stereo E-AC-3")
    func capPicksTheStereoEncoder() throws {
        let out = try bridgedLeftChannel(sourceChannels: 6, shaping: AudioShaping(maxChannels: 2))
        #expect(out.codec == AV_CODEC_ID_FLAC)
        #expect(out.channels == 2)
        #expect(!out.left.isEmpty)
    }

    @Test("the dialogue lift raises the centre against the rest in the bridged fold")
    func bridgedDialogueLift() throws {
        let plain = try bridgedLeftChannel(sourceChannels: 6, shaping: AudioShaping(maxChannels: 2))
        let lifted = try bridgedLeftChannel(sourceChannels: 6, shaping: AudioShaping(maxChannels: 2, dialogueGainDB: 6))
        func ratioDB(_ s: [Float]) -> Double {
            let body = Array(s.dropFirst(4800).prefix(9600))
            return 20 * log10(level(body, hz: 1000) / level(body, hz: 250))
        }
        let gained = ratioDB(lifted.left) - ratioDB(plain.left)
        #expect(abs(gained - 6) < 0.5, "centre against the rest moved by \(gained) dB, asked for 6")
    }

    @Test("a loud fold with a lift never clips through the bridge")
    func bridgedLimiter() throws {
        let out = try bridgedLeftChannel(sourceChannels: 6, shaping: AudioShaping(maxChannels: 2, dialogueGainDB: 12),
                                         amplitude: 0.9)
        let ceiling = Float(pow(10, AudioShapingGraph.ceilingDBFS / 20))
        #expect((out.left.map { abs($0) }.max() ?? 0) <= ceiling + 1e-3)
    }

    @Test("the software decoder carries the cap and the lift")
    func softwareDecoderShapes() throws {
        func decodedLeft(_ shaping: AudioShaping) throws -> (channels: Int32, left: [Float]) {
            var out: (Int32, [Float]) = (0, [])
            try withAudioStream(makeDialogueWAV(channels: 6)) { stream, packets in
                let decoder = AudioDecoder()
                decoder.shaping = shaping
                try decoder.open(stream: stream)
                defer { decoder.close() }
                var buffers: [CMSampleBuffer] = []
                for p in packets { buffers.append(contentsOf: decoder.decode(packet: p)) }
                buffers.append(contentsOf: decoder.drain())
                var left: [Float] = []
                for b in buffers {
                    let n = CMSampleBufferGetNumSamples(b)
                    let block = try #require(CMSampleBufferGetDataBuffer(b))
                    var data = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
                    _ = data.withUnsafeMutableBytes {
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                    }
                    let ch = data.count / n
                    for i in 0..<n { left.append(data[i * ch]) }
                }
                out = (decoder.channels, left)
            }
            return out
        }
        let plain = try decodedLeft(AudioShaping(maxChannels: 2))
        let lifted = try decodedLeft(AudioShaping(maxChannels: 2, dialogueGainDB: 6))
        #expect(plain.channels == 2)
        func ratioDB(_ s: [Float]) -> Double {
            let body = Array(s.dropFirst(4800).prefix(9600))
            return 20 * log10(level(body, hz: 1000) / level(body, hz: 250))
        }
        let gained = ratioDB(lifted.left) - ratioDB(plain.left)
        #expect(abs(gained - 6) < 0.5, "centre against the rest moved by \(gained) dB, asked for 6")
    }

    @Test("a stereo source gets the dialogue extracted and lifted against the wide content")
    func bridgedStereoEnhance() throws {
        let plain = try bridgedLeftChannel(sourceChannels: 2, shaping: AudioShaping(maxChannels: 2), wav: makeStereoWAV())
        let lifted = try bridgedLeftChannel(sourceChannels: 2, shaping: AudioShaping(dialogueGainDB: 6), wav: makeStereoWAV())
        #expect(lifted.codec == AV_CODEC_ID_FLAC)
        func ratioDB(_ s: [Float]) -> Double {
            let body = Array(s.dropFirst(24_000).prefix(48_000))
            return 20 * log10(level(body, hz: 1000) / level(body, hz: 3000))
        }
        let gained = ratioDB(lifted.left) - ratioDB(plain.left)
        #expect(gained > 3, "the centred tone rose \(gained) dB against the wide noise")
    }

    @Test("the bridged stereo lift keeps the audio on the source's timeline, to the sample")
    func bridgedEnhanceIsSampleAligned() throws {
        let out = try bridgedLeftChannel(sourceChannels: 2, shaping: AudioShaping(dialogueGainDB: 9),
                                         wav: makeStereoWAV(impulseAt: 60_000))
        let peak = out.left.indices.max { abs(out.left[$0]) < abs(out.left[$1]) }!
        #expect(abs(peak - 60_000) <= 1, "impulse at sample 60000 came out at \(peak)")
        #expect(abs(out.left.count - 96_000) <= 1, "\(out.left.count) samples out for 96000 in")
    }

    @Test("the software decoder stamps the shaped stereo audio with its source time, to the sample")
    func decoderEnhanceIsSampleAligned() throws {
        try withAudioStream(makeStereoWAV(impulseAt: 60_000)) { stream, packets in
            let decoder = AudioDecoder()
            decoder.shaping = AudioShaping(dialogueGainDB: 9)
            try decoder.open(stream: stream)
            defer { decoder.close() }
            var buffers: [CMSampleBuffer] = []
            for p in packets { buffers.append(contentsOf: decoder.decode(packet: p)) }
            buffers.append(contentsOf: decoder.drain())
            var best: (value: Float, time: Double) = (0, -1)
            var total = 0
            for b in buffers {
                let n = CMSampleBufferGetNumSamples(b)
                total += n
                let start = CMSampleBufferGetPresentationTimeStamp(b).seconds
                let block = try #require(CMSampleBufferGetDataBuffer(b))
                var data = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
                _ = data.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                for i in 0..<n where abs(data[i * 2]) > best.value {
                    best = (abs(data[i * 2]), start + Double(i) / 48_000)
                }
            }
            #expect(abs(best.time - 1.25) <= 1.0 / 48_000, "impulse at 1.25 s presented at \(best.time) s")
            #expect(total == 96_000, "\(total) samples out for 96000 in")
        }
    }
}
