import Testing
import Foundation
import CoreMedia
import AudioToolbox
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Binaural on the object render: the TrueHD Atmos or DTS:X bed, heights included, leaves as two
/// channels of PCM, and nothing treats that as Atmos.
@Suite("Binaural object audio", .serialized, .timeLimit(.minutes(3)))
struct BinauralObjectAudioTests {

    @Test("the binaural bed route is shaped, bridged, named, and never wakes the Atmos output")
    func route() {
        let route = SoftwareAtmosRoute.binauralBed(.l714)
        #expect(!route.takesAtmosOutputActivator)
        #expect(!route.needsAtmosDecoder)
        #expect(route.carriesShaping)
        #expect(SoftwareAtmosRoute.pcm.carriesShaping)
        #expect(!SoftwareAtmosRoute.pcmBed(.l714).carriesShaping)
        #expect(SoftwarePlaybackHost.audioDelivery(resolvedAudioIndex: 1, decoderOpened: true,
                                                   sourceCarriesAudio: true, route: route) == .bridged)
        #expect(AetherEngine.softwareAudioDecoderLabel(
            audioTracks: [TrackInfo(id: 1, name: "", codec: "truehd", language: nil, isDefault: true)],
            activeIndex: 1, route: route) == "TRUEHD Atmos → binaural (7.1.4)")
    }

    @Test("the stereo PCM description and codec parameters are plain stereo")
    func stereoDescription() throws {
        let cp = try #require(PCMBedPacker.makeCodecpar(speakers: [.left, .right], sampleRate: 48_000))
        defer { var p: UnsafeMutablePointer<AVCodecParameters>? = cp; avcodec_parameters_free(&p) }
        var stereo = AVChannelLayout()
        av_channel_layout_default(&stereo, 2)
        defer { av_channel_layout_uninit(&stereo) }
        #expect(av_channel_layout_compare(&cp.pointee.ch_layout, &stereo) == 0)
        #expect(cp.pointee.block_align == 6)
        let description = try #require(PCMBedPacker.stereoFormatDescription(sampleRate: 48_000))
        #expect(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mChannelsPerFrame == 2)
    }

    /// Decodes the sink's packets (packed s24le stereo) back to two float arrays.
    private func unpack(_ packets: [SpatialBedPacket]) -> (left: [Float], right: [Float]) {
        var l: [Float] = [], r: [Float] = []
        for packet in packets {
            packet.data.withUnsafeBytes { raw in
                let b = raw.bindMemory(to: UInt8.self)
                var i = 0
                while i + 6 <= b.count {
                    func s24(_ o: Int) -> Float {
                        let v = Int32(b[o]) | Int32(b[o + 1]) << 8 | Int32(Int8(bitPattern: b[o + 2])) << 16
                        return Float(v) / 8_388_608
                    }
                    l.append(s24(i)); r.append(s24(i + 3))
                    i += 6
                }
            }
        }
        return (l, r)
    }

    @Test("the sink renders a 7.1.4 bed to two channels: a left top-rear lands left, on both ears")
    func sinkPlacesAHeight() throws {
        try #require(BinauralRenderer.isAvailable)
        let sink = try #require(BinauralBedSink(layout: .l714, sampleRate: 48_000, bufferFrames: 8192))
        let frames = 9600
        var buffer = sink.takeInitialBuffer()
        buffer.ensureCapacity(frames, keeping: 0)
        // CoreAudio Atmos 7.1.4 order: L R C LFE Ls Rs Rls Rrs Vhl Vhr Ltr Rtr; Ltr is slot 10.
        var seed: UInt64 = 5
        for (c, plane) in buffer.planes.enumerated() {
            for f in 0..<frames {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                plane[f] = c == 10 ? Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max) * 0.25 : 0
            }
        }
        buffer = sink.submit(buffer, frames: frames, position: 0)
        let packets = sink.collect().packets
        #expect(packets.first?.pts == 0)
        #expect(packets.reduce(0) { $0 + $1.frames } == frames)
        let out = unpack(packets)
        #expect(out.left.count == frames)
        let el = out.left.reduce(0) { $0 + Double($1 * $1) }, er = out.right.reduce(0) { $0 + Double($1 * $1) }
        #expect(el > er * 2, "near ear louder")
        #expect(er > 0, "far ear hears it too")
    }

    @Test("the sink keeps two ears under full scale when the whole bed is loud")
    func sinkLimits() throws {
        try #require(BinauralRenderer.isAvailable)
        let sink = try #require(BinauralBedSink(layout: .l714, sampleRate: 48_000, bufferFrames: 4096))
        let frames = 4096
        let buffer = sink.takeInitialBuffer()
        for plane in buffer.planes {
            for f in 0..<frames { plane[f] = 0.95 * Float(sin(2 * Double.pi * 200 * Double(f) / 48_000)) }
        }
        _ = sink.submit(buffer, frames: frames, position: 0)
        let out = unpack(sink.collect().packets)
        let peak = (out.left + out.right).map(abs).max() ?? 0
        #expect(peak <= PeakLimiter.threshold + 1e-3)
    }

    #if TrueHDObjectAudio
    /// Dolby's "Unfold" demo, as for `TrueHDAtmosSampleTests`; skipped without `AE_TRUEHD_ATMOS_SAMPLE`.
    @Test("TrueHD Atmos through the bridge as binaural: contiguous stereo PCM with sound on both ears")
    func trueHDSampleBinaural() throws {
        guard let path = ProcessInfo.processInfo.environment["AE_TRUEHD_ATMOS_SAMPLE"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        try #require(BinauralRenderer.isAvailable)
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 48_000), layout: .l714, decoder: TrueHDObjectAudioDecoder(),
            format: .apac, binaural: true)
        defer { bridge.close() }
        #expect(bridge.format == .lpcm, "binaural is PCM whatever was asked")
        #expect(bridge.servedChannelCount == 2)
        #expect(bridge.encoderCodecpar?.pointee.ch_layout.nb_channels == 2)
        var pts: [Int64] = []
        var ends: [Int64] = []
        // AE_BINAURAL_WAV=<path> keeps what the bridge made, for listening on headphones.
        var pcm = Data()
        let keep = ProcessInfo.processInfo.environment["AE_BINAURAL_WAV"]
        var energy = (left: 0.0, right: 0.0)
        func take(_ fp: UnsafeMutablePointer<AVPacket>) {
            pts.append(fp.pointee.pts)
            ends.append(fp.pointee.pts + fp.pointee.duration)
            let n = Int(fp.pointee.size)
            #expect(n == Int(fp.pointee.duration) * 6)
            let b = fp.pointee.data!
            if keep != nil { pcm.append(b, count: n) }
            var i = 0
            while i + 6 <= n {
                func s24(_ o: Int) -> Double {
                    Double(Int32(b[o]) | Int32(b[o + 1]) << 8 | Int32(Int8(bitPattern: b[o + 2])) << 16) / 8_388_608
                }
                energy.left += s24(i) * s24(i); energy.right += s24(i + 3) * s24(i + 3)
                i += 6
            }
            var p: UnsafeMutablePointer<AVPacket>? = fp; trackedPacketFree(&p)
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = min(3000, raw.count - offset)
                let pkt = av_packet_alloc()!
                defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
                _ = av_new_packet(pkt, Int32(n))
                pkt.pointee.data.update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + offset, count: n)
                pkt.pointee.pts = offset == 0 ? 0 : Int64.min
                for fp in try bridge.feed(packet: pkt) { take(fp) }
                offset += n
            }
        }
        for fp in bridge.flush() { take(fp) }
        if let keep {
            var wav = Data()
            func str(_ s: String) { wav.append(s.data(using: .ascii)!) }
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
            str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
            str("fmt "); u32(16); u16(1); u16(2); u32(48_000); u32(48_000 * 6); u16(6); u16(24)
            str("data"); u32(UInt32(pcm.count)); wav.append(pcm)
            try wav.write(to: URL(fileURLWithPath: keep))
        }
        #expect(pts.first == Int64(0))
        // PCM packets are 1024 frames, the last of each chunk shorter; each starts where the last ended.
        #expect(zip(ends, pts.dropFirst()).allSatisfy { $0 == $1 })
        #expect(ends.last == 1_298_000)
        #expect(energy.left > 0 && energy.right > 0)
        let balance = 10 * log10(energy.left / energy.right)
        #expect(abs(balance) < 6, "a film mix sits roughly centred, got \(balance) dB")
    }
    #endif
}
