import Testing
import Foundation
import AVFoundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// AE#1120: CoreMedia reads no channel layout from a FLAC track in fMP4 and assumes the FLAC default for
/// the count, so a 7.1(wide) track played its front-of-centre pair on the side surrounds. A layout FLAC
/// cannot label now leaves the engine as PCM in the source's own layout, which CoreMedia does read.
@Suite("AE#1120: FLAC layouts CoreMedia cannot read from fMP4", .timeLimit(.minutes(3)))
struct Issue1120FLACChannelLayoutTests {

    private static func carries(_ name: String) throws -> Bool {
        var layout = AVChannelLayout()
        defer { av_channel_layout_uninit(&layout) }
        try #require(av_channel_layout_from_string(&layout, name) >= 0, "FFmpeg knows \(name)")
        return FLACChannelLabels.carries(&layout)
    }

    @Test("the FLAC defaults, and a lone back pair, keep stream copy", arguments: [
        "mono", "stereo", "3.0", "quad", "FL+FR+SL+SR", "5.0", "5.0(side)", "5.1", "5.1(side)", "6.1", "7.1",
        // One or two channels, a channel the chnl box cannot name, an ambisonic order: PCM would not help.
        "FL", "FC+LFE", "DL+DR", "DL+DR+LFE", "ambisonic 1",
    ])
    func carried(name: String) throws {
        #expect(try Self.carries(name))
    }

    @Test("a layout CoreMedia would misplace does not", arguments: [
        "2.1", "4.0", "hexagonal", "6.1(back)", "6.1(front)", "7.1(wide)", "7.1(wide-side)",
    ])
    func notCarried(name: String) throws {
        #expect(try !Self.carries(name))
    }

    @Test("a layout of unknown order, or more channels than FLAC holds, is not FLAC's problem")
    func unknownOrTooWide() {
        var unspec = AVChannelLayout()
        unspec.order = AV_CHANNEL_ORDER_UNSPEC
        unspec.nb_channels = 8
        #expect(FLACChannelLabels.carries(&unspec))
        var wide = AVChannelLayout()
        defer { av_channel_layout_uninit(&wide) }
        av_channel_layout_default(&wide, 12)
        #expect(FLACChannelLabels.carries(&wide))
    }

    @Test("lossless picks PCM where FLAC cannot label; surround-compat keeps E-AC-3 for surround")
    func encoderChoice() {
        #expect(AudioBridge.bridgeEncoder(for: .lossless, sourceChannels: 8, flacCarriesLayout: false)
                == AudioBridge.pcmOutputCodecID)
        #expect(AudioBridge.bridgeEncoder(for: .lossless, sourceChannels: 8) == AV_CODEC_ID_FLAC)
        #expect(AudioBridge.bridgeEncoder(for: .surroundCompat, sourceChannels: 8, flacCarriesLayout: false)
                == AV_CODEC_ID_EAC3)
        #expect(AudioBridge.bridgeEncoder(for: .surroundCompat, sourceChannels: 2, flacCarriesLayout: false)
                == AudioBridge.pcmOutputCodecID)
        // A FLAC source is bridged for its layout alone, so it stays lossless in either mode.
        #expect(AudioBridge.bridgeEncoder(for: .surroundCompat, sourceChannels: 8, flacCarriesLayout: false,
                                          sourceIsFLAC: true) == AudioBridge.pcmOutputCodecID)
        #expect(AudioBridge.bridgeEncoder(for: .surroundCompat, sourceChannels: 8, sourceIsFLAC: true)
                == AV_CODEC_ID_EAC3)
        // A PCM track that cannot be built falls back to FLAC, which still plays every channel.
        #expect(HLSVideoEngine.bridgeEncoderCascade(firstAttempt: AudioBridge.pcmOutputCodecID)
                == [AudioBridge.pcmOutputCodecID, AV_CODEC_ID_FLAC])
    }

    @Test("a FLAC stream in 7.1(wide) is taken off stream copy, a 7.1 one is not")
    func streamCopyDecision() throws {
        for (name, relabels) in [("7.1(wide)", true), ("7.1", false), ("5.1", false)] {
            let codecpar = try #require(avcodec_parameters_alloc())
            defer { var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar; avcodec_parameters_free(&p) }
            codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
            codecpar.pointee.codec_id = AV_CODEC_ID_FLAC
            try #require(av_channel_layout_from_string(&codecpar.pointee.ch_layout, name) >= 0)
            #expect(HLSVideoEngine.flacNeedsRelabel(codecpar) == relabels, "\(name)")
            codecpar.pointee.codec_id = AV_CODEC_ID_ALAC
            #expect(!HLSVideoEngine.flacNeedsRelabel(codecpar), "only FLAC: \(name)")
        }
    }

    // MARK: - End to end

    /// The FFmpeg mask of 7.1(wide): FL FR FC LFE BL BR FLC FRC.
    static let wideMask: UInt32 = 0xFF
    static let channels = 8
    static let frames = 4_800

    /// Channel c carries `(c + 1) * 1000 + frame % 97`, so every channel is told apart and any
    /// rematrix or reorder shows up as a wrong value.
    static func sample(channel: Int, frame: Int) -> Int16 { Int16((channel + 1) * 1000 + frame % 97) }

    /// A 16-bit WAVE_FORMAT_EXTENSIBLE file in 7.1(wide), which the demuxer opens as `pcm_s16le` with
    /// that layout: the bridged case (DTS-HD MA, PCM) in its simplest form.
    static func wideWAV() -> Data {
        var d = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        let rate: UInt32 = 48_000
        let block = UInt16(channels * 2)
        let dataBytes = UInt32(frames * channels * 2)
        str("RIFF"); u32(4 + 8 + 40 + 8 + dataBytes); str("WAVE")
        str("fmt "); u32(40); u16(0xFFFE); u16(UInt16(channels)); u32(rate)
        u32(rate * UInt32(block)); u16(block); u16(16); u16(22); u16(16); u32(wideMask)
        // KSDATAFORMAT_SUBTYPE_PCM
        d.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
                              0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        str("data"); u32(dataBytes)
        for f in 0..<frames {
            for c in 0..<channels { u16(UInt16(bitPattern: sample(channel: c, frame: f))) }
        }
        return d
    }

    /// The bridged packets of the fixture under `mode`, with the bridge's output parameters copied out.
    private func bridgeWide(mode: AudioBridgeMode,
                            _ body: (AudioBridge, [UnsafeMutablePointer<AVPacket>]) throws -> Void) throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Self.wideWAV()))
        let index = demuxer.audioStreamIndex
        let stream = try #require(index >= 0 ? demuxer.stream(at: index) : nil)
        let described = Demuxer.channelLayoutDescription(&stream.pointee.codecpar.pointee.ch_layout)
        try #require(described == "7.1(wide)", "fixture opens as \(described ?? "nil")")
        var source: [UnsafeMutablePointer<AVPacket>] = []
        defer { for p in source { var pp: UnsafeMutablePointer<AVPacket>? = p; trackedPacketFree(&pp) } }
        while let packet = try demuxer.readPacket() {
            if packet.pointee.stream_index == index { source.append(packet) } else {
                var p: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&p)
            }
        }
        let bridge = try AudioBridge(srcCodecpar: stream.pointee.codecpar, srcTimeBase: stream.pointee.time_base,
                                     mode: mode)
        defer { bridge.close() }
        var out: [UnsafeMutablePointer<AVPacket>] = []
        defer { for p in out { var pp: UnsafeMutablePointer<AVPacket>? = p; trackedPacketFree(&pp) } }
        for p in source { out.append(contentsOf: try bridge.feed(packet: p)) }
        out.append(contentsOf: bridge.flush())
        try body(bridge, out)
    }

    @Test("lossless bridges 7.1(wide) to PCM in 7.1(wide), every channel bit-exact on its own slot")
    func losslessKeepsTheLayout() throws {
        try bridgeWide(mode: .lossless) { bridge, packets in
            #expect(bridge.outputCodecID == AudioBridge.pcmOutputCodecID)
            let cp = try #require(bridge.encoderCodecpar)
            #expect(Demuxer.channelLayoutDescription(&cp.pointee.ch_layout) == "7.1(wide)")
            #expect(cp.pointee.bits_per_coded_sample == 24)
            #expect(cp.pointee.block_align == Int32(Self.channels * 3))
            #expect(bridge.peakOutputBitRate == Int64(Self.channels) * 24 * 48_000)

            var frame = 0
            var mismatches = 0
            for packet in packets {
                let bytes = Int(packet.pointee.size)
                #expect(bytes % (Self.channels * 3) == 0)
                #expect(packet.pointee.pts == Int64(frame))
                let data = try #require(packet.pointee.data)
                for f in 0..<(bytes / (Self.channels * 3)) {
                    for c in 0..<Self.channels {
                        let o = (f * Self.channels + c) * 3
                        let v24 = Int32(data[o]) | Int32(data[o + 1]) << 8 | Int32(Int8(bitPattern: data[o + 2])) << 16
                        if v24 >> 8 != Int32(Self.sample(channel: c, frame: frame + f)) { mismatches += 1 }
                    }
                }
                frame += bytes / (Self.channels * 3)
            }
            #expect(frame == Self.frames)
            #expect(mismatches == 0)
        }
    }

    @Test("surround-compat still folds 7.1(wide) into E-AC-3 5.1")
    func surroundCompatStaysEAC3() throws {
        try bridgeWide(mode: .surroundCompat) { bridge, packets in
            #expect(bridge.outputCodecID == AV_CODEC_ID_EAC3)
            #expect(bridge.encoderCodecpar?.pointee.ch_layout.nb_channels == 6)
            #expect(!packets.isEmpty)
        }
    }

    /// The observable of the report: what AVFoundation reads from the track movenc writes. FLAC there
    /// reads `L R C LFE Rls Rrs Ls Rs` whatever the source was; the PCM must read the source's layout.
    @Test("movenc's PCM track reads back in AVFoundation as L R C LFE Rls Rrs Lc Rc")
    func avFoundationReadsTheLayout() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae1120-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try bridgeWide(mode: .lossless) { bridge, packets in
            let cp = try #require(bridge.encoderCodecpar)
            var output: UnsafeMutablePointer<AVFormatContext>?
            try #require(avformat_alloc_output_context2(&output, nil, "mp4", url.path) >= 0)
            let context = try #require(output)
            defer { avformat_free_context(context) }
            let stream = try #require(avformat_new_stream(context, nil))
            try #require(avcodec_parameters_copy(stream.pointee.codecpar, cp) >= 0)
            stream.pointee.time_base = bridge.encoderTimeBase
            try #require(avio_open(&context.pointee.pb, url.path, AVIO_FLAG_WRITE) >= 0)
            defer { avio_closep(&context.pointee.pb) }
            try #require(avformat_write_header(context, nil) >= 0)
            for packet in packets {
                let copy = try #require(av_packet_clone(packet))
                var owned: UnsafeMutablePointer<AVPacket>? = copy
                defer { av_packet_free(&owned) }
                av_packet_rescale_ts(copy, bridge.encoderTimeBase, stream.pointee.time_base)
                copy.pointee.stream_index = 0
                try #require(av_interleaved_write_frame(context, copy) >= 0)
            }
            try #require(av_write_trailer(context) >= 0)
        }

        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        var size = 0
        let layout = try #require(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size))
        #expect(layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions)
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        // The descriptions run past the struct's one declared element, so read them in place.
        let offset = try #require(MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions))
        let first = UnsafeRawPointer(layout).advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
        let read = UnsafeBufferPointer(start: first, count: count).map(\.mChannelLabel)
        #expect(read == [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                         kAudioChannelLabel_LFEScreen, kAudioChannelLabel_RearSurroundLeft,
                         kAudioChannelLabel_RearSurroundRight, kAudioChannelLabel_LeftCenter,
                         kAudioChannelLabel_RightCenter])
    }
}
