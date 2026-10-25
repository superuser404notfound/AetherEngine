import Testing
import Foundation
import CoreMedia
import AudioToolbox
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The software host (Dolby Vision FEL, and video the hardware decoder cannot play) decodes audio to PCM,
/// which loses Atmos. These pin which tracks leave that route, and the pieces of the compressed
/// E-AC-3 route that the renderer is picky about.
@Suite("Software host Atmos routes")
struct SoftwareAtmosRouteTests {

    private func route(
        codec: AVCodecID, profile: Int32 = 0, rate: Int32 = 48_000, channels: Int32 = 6,
        frame: Int32 = 1536, live: Bool = false, rendering: ObjectAudioRendering = .apac(.l714),
        joc: Bool = true, apacOS: Bool = true
    ) -> SoftwareAtmosRoute {
        SoftwareAtmosRoute.route(
            codecID: codec, profile: profile, sampleRate: rate, channels: channels,
            framesPerPacket: frame, isLive: live, rendering: rendering, confirmedJOC: joc,
            osSupportsAPAC: apacOS)
    }

    @Test("JOC E-AC-3 goes to the renderer compressed")
    func jocCompressed() {
        #expect(route(codec: AV_CODEC_ID_EAC3) == .compressedEAC3JOC)
        #expect(route(codec: AV_CODEC_ID_EAC3, frame: 0) == .compressedEAC3JOC)
    }

    @Test("object audio off keeps every codec on the PCM decode")
    func offIsPCM() {
        #expect(route(codec: AV_CODEC_ID_EAC3, rendering: .off) == .pcm)
        #expect(route(codec: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, channels: 8, frame: 0,
                      rendering: .off) == .pcm)
    }

    @Test("live sessions keep the PCM decode")
    func liveIsPCM() {
        #expect(route(codec: AV_CODEC_ID_EAC3, live: true) == .pcm)
        #expect(route(codec: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, live: true) == .pcm)
    }

    @Test("E-AC-3 without JOC, or in a shape the Atmos decoder is not described for, stays PCM")
    func nonJOC() {
        #expect(route(codec: AV_CODEC_ID_EAC3, joc: false) == .pcm)
        #expect(route(codec: AV_CODEC_ID_EAC3, channels: 8) == .pcm)
        #expect(route(codec: AV_CODEC_ID_EAC3, rate: 44_100) == .pcm)
        #expect(route(codec: AV_CODEC_ID_EAC3, frame: 768) == .pcm)
        #expect(route(codec: AV_CODEC_ID_AC3) == .pcm)
    }

    @Test("TrueHD Atmos and DTS-HD MA render as APAC on an OS that has the encoder, in a build with the codec's trait")
    func apacRoutes() {
        // Without a codec's object-audio trait the renderer is not built in and the track keeps the PCM decode.
        let trueHD: SoftwareAtmosRoute = AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn ? .apac(.l714) : .pcm
        let dtsx: SoftwareAtmosRoute = AetherEngine.OptionalComponent.dtsxObjectAudio.isBuiltIn ? .apac(.l714) : .pcm
        #expect(route(codec: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, channels: 8, frame: 0)
                == trueHD)
        #expect(route(codec: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA, channels: 8, frame: 0,
                      rendering: .apac(.l714)) == dtsx)
        #expect(route(codec: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, apacOS: false) == .pcm)
    }

    @Test("DTS:X renders only into a bed that carries its channels one to one, and TrueHD Atmos into any")
    func dtsxNeedsAOneToOneBed() {
        // DTS:X's 7.1 bed and four heights map onto 7.1.4 and 9.1.6 only (`carriesDTSXOneToOne`);
        // a smaller bed keeps the PCM decode, where TrueHD Atmos is rendered into whatever bed is asked.
        for layout in SpatialSpeakerLayout.allCases where !layout.carriesDTSXOneToOne {
            #expect(route(codec: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS_HD_MA, channels: 8, frame: 0,
                          rendering: .apac(layout)) == .pcm, "\(layout.rawValue)")
            let trueHD: SoftwareAtmosRoute = AetherEngine.OptionalComponent.trueHDObjectAudio.isBuiltIn ? .apac(layout) : .pcm
            #expect(route(codec: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, channels: 8, frame: 0,
                          rendering: .apac(layout)) == trueHD, "\(layout.rawValue)")
        }
    }

    @Test("TrueHD without Atmos, lossy DTS and a rate other than 48 kHz stay PCM")
    func apacIneligible() {
        #expect(route(codec: AV_CODEC_ID_TRUEHD, profile: 0) == .pcm)
        #expect(route(codec: AV_CODEC_ID_DTS, profile: AV_PROFILE_DTS) == .pcm)
        #expect(route(codec: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, rate: 96_000) == .pcm)
        #expect(route(codec: AV_CODEC_ID_AAC) == .pcm)
    }

    @Test("only Dolby Atmos reaches the receiver as Dolby Atmos: TrueHD Atmos as APAC and JOC E-AC-3, not DTS:X")
    func dolbyAtmosRoutes() {
        #expect(SoftwareAtmosRoute.apac(.l714).carriesDolbyAtmos(sourceCodec: AV_CODEC_ID_TRUEHD))
        #expect(SoftwareAtmosRoute.compressedEAC3JOC.carriesDolbyAtmos(sourceCodec: AV_CODEC_ID_EAC3))
        #expect(!SoftwareAtmosRoute.apac(.l714).carriesDolbyAtmos(sourceCodec: AV_CODEC_ID_DTS))
        #expect(!SoftwareAtmosRoute.pcm.carriesDolbyAtmos(sourceCodec: AV_CODEC_ID_TRUEHD))
    }

    // MARK: - dec3

    /// The box AVFoundation's own format description carries for a 5.1 JOC stream.
    private static let jocBox = Data([0, 0, 0, 0x0f, 0x64, 0x65, 0x63, 0x33, 0x0e, 0, 0x20, 0x0f, 0, 0x01, 0x0c])
    private static let plainBox = Data([0, 0, 0, 0x0d, 0x64, 0x65, 0x63, 0x33, 0x0e, 0, 0x20, 0x0f, 0])

    @Test("the format description carries the dec3 box as its magic cookie, and the JOC flag reads back")
    func formatDescriptionCookie() throws {
        let description = try #require(SoftwareEAC3Passthrough.formatDescription(dec3Box: Self.jocBox))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatEnhancedAC3)
        #expect(asbd.mFramesPerPacket == 1536)
        #expect(asbd.mChannelsPerFrame == 6)
        var size = 0
        let cookie = try #require(CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size))
        #expect(Data(bytes: cookie, count: size) == Self.jocBox)
        #expect(RemoteHLSStreamDescription.eac3CarriesJOC(dec3: Self.jocBox))
        #expect(!RemoteHLSStreamDescription.eac3CarriesJOC(dec3: Self.plainBox))
    }

    private static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(payload.count + 8)
        return [UInt8(size >> 24 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)]
            + Array(type.utf8) + payload
    }

    @Test("a box is found by its type inside moov and checked against its size")
    func findBox() {
        let trak = Self.box("trak", [UInt8](Self.jocBox))
        let bytes = Self.box("ftyp", [1, 2, 3, 4, 5, 6, 7, 8]) + Self.box("moov", trak)
        bytes.withUnsafeBufferPointer { buffer in
            #expect(SoftwareEAC3Passthrough.findBox("dec3", in: buffer) == Self.jocBox)
            #expect(SoftwareEAC3Passthrough.findBox("dac3", in: buffer) == nil)
        }
        // A box whose size runs past the end of its parent is not a box.
        let truncated = Self.box("moov", [UInt8](Self.jocBox).dropLast(4).map { $0 })
        truncated.withUnsafeBufferPointer { #expect(SoftwareEAC3Passthrough.findBox("dec3", in: $0) == nil) }
    }

    @Test("a dec3 code that sits outside moov, in sample data, is not taken for the box")
    func findBoxIgnoresPayloadOutsideMoov() {
        let bytes = Self.box("ftyp", [1, 2, 3, 4]) + Self.box("mdat", [UInt8](Self.jocBox))
            + Self.box("moov", Self.box("trak", [9, 9, 9, 9]))
        bytes.withUnsafeBufferPointer { #expect(SoftwareEAC3Passthrough.findBox("dec3", in: $0) == nil) }
        // And with no moov at all.
        let noMoov = Self.box("mdat", [UInt8](Self.jocBox))
        noMoov.withUnsafeBufferPointer { #expect(SoftwareEAC3Passthrough.findBox("dec3", in: $0) == nil) }
    }

    @Test("FFmpeg's muxer builds a dec3 box from a real E-AC-3 packet, and a plain stream is not JOC")
    func dec3FromRealPacket() throws {
        var packet = try Self.encodedEAC3Packet()
        defer { av_packet_free(&packet) }
        let par = try #require(avcodec_parameters_alloc())
        var owned: UnsafeMutablePointer<AVCodecParameters>? = par
        defer { avcodec_parameters_free(&owned) }
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_EAC3
        par.pointee.sample_rate = 48_000
        av_channel_layout_default(&par.pointee.ch_layout, 6)
        let pkt = try #require(packet)
        let entry = try #require(SoftwareEAC3Passthrough.entry(codecpar: par, packet: pkt))
        #expect(!entry.carriesJOC)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(entry.formatDescription)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatEnhancedAC3)
    }

    @Test("a packet becomes a one-sample buffer stamped where the source puts it")
    func sampleBuffer() throws {
        let description = try #require(SoftwareEAC3Passthrough.formatDescription(dec3Box: Self.jocBox))
        let bytes = [UInt8](repeating: 0xAB, count: 1792)
        let made = bytes.withUnsafeBytes {
            SoftwareEAC3Passthrough.sampleBuffer(bytes: $0, seconds: 12.5, formatDescription: description)
        }
        let buffer = try #require(made)
        #expect(CMSampleBufferGetNumSamples(buffer) == 1)
        #expect(CMSampleBufferGetPresentationTimeStamp(buffer).seconds == 12.5)
        #expect(abs(CMSampleBufferGetDuration(buffer).seconds - 1536.0 / 48000.0) < 1e-6)
        #expect(CMSampleBufferGetTotalSampleSize(buffer) == 1792)
    }

    /// One E-AC-3 access unit of silence from libavcodec's own encoder.
    private static func encodedEAC3Packet() throws -> UnsafeMutablePointer<AVPacket>? {
        let codec = try #require(avcodec_find_encoder(AV_CODEC_ID_EAC3))
        var ctx: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&ctx) }
        let c = try #require(ctx)
        c.pointee.sample_rate = 48_000
        c.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        c.pointee.bit_rate = 448_000
        av_channel_layout_default(&c.pointee.ch_layout, 6)
        c.pointee.time_base = AVRational(num: 1, den: 48_000)
        #expect(avcodec_open2(c, codec, nil) >= 0)
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let f = try #require(frame)
        f.pointee.nb_samples = 1536
        f.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        f.pointee.sample_rate = 48_000
        av_channel_layout_default(&f.pointee.ch_layout, 6)
        #expect(av_frame_get_buffer(f, 0) >= 0)
        for plane in 0..<6 {
            if let data = f.pointee.extended_data[plane] { memset(data, 0, 1536 * 4) }
        }
        #expect(avcodec_send_frame(c, f) >= 0)
        _ = avcodec_send_frame(c, nil)
        let packet = av_packet_alloc()
        guard avcodec_receive_packet(c, packet) >= 0 else { return nil }
        return packet
    }

    // MARK: - Host

    @Test("the primer is awaited on the compressed JOC route and on no other")
    @MainActor
    func primerAwaitedOnlyForJOC() async {
        var waits = 0
        for route in [SoftwareAtmosRoute.pcm, .apac(.l714), .apac(.l512)] {
            await SoftwarePlaybackHost.awaitAtmosPrimer(for: route) { waits += 1 }
        }
        #expect(waits == 0)
        await SoftwarePlaybackHost.awaitAtmosPrimer(for: .compressedEAC3JOC) { waits += 1 }
        #expect(waits == 1)
    }

    @Test("a PCM track stays on the PCM route whatever the rendering option says")
    @MainActor
    func hostKeepsPCMTrackOnPCM() async throws {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: Self.silentWAV()))
        defer { demuxer.close() }
        for rendering in [ObjectAudioRendering.off, .apac(.l714)] {
            let host = SoftwarePlaybackHost()
            host.objectAudioRendering = rendering
            let made = try await host.makeAudioProducer(demuxer: demuxer, streamIndex: 0, isLive: false)
            defer { made.producer.close() }
            #expect(made.route == .pcm)
            #expect(made.producer is AudioDecoder)
        }
    }

    @Test("a stop during the APAC verdict throws before the PCM fallback can open the stream")
    func stopSettlesBeforeThePCMFallback() throws {
        // The verdict await returns nil on a stop, on purpose; the nil must not read as "use PCM".
        #expect(throws: CancellationError.self) {
            _ = try SoftwarePlaybackHost.settleAPACProducer(nil, stopped: true)
        }
        // A producer built before the stop is closed, not leaked.
        let built = ClosingProducer()
        #expect(throws: CancellationError.self) {
            _ = try SoftwarePlaybackHost.settleAPACProducer(built, stopped: true)
        }
        #expect(built.closeCount == 1)
        // No stop: a producer is kept open, and nil still means the PCM decode.
        let kept = ClosingProducer()
        let settled = try SoftwarePlaybackHost.settleAPACProducer(kept, stopped: false)
        #expect(settled === kept)
        #expect(kept.closeCount == 0)
        #expect(try SoftwarePlaybackHost.settleAPACProducer(nil, stopped: false) == nil)
    }

    private final class ClosingProducer: SoftwareAudioProducing, @unchecked Sendable {
        private let lock = NSLock()
        private var closes = 0
        var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }
        func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] { [] }
        func flush() {}
        func close() { lock.lock(); closes += 1; lock.unlock() }
    }

    @Test("the look at a closed demuxer finds no audio packet and touches no stream")
    func closedDemuxerYieldsNoPacket() throws {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: Self.silentWAV()))
        demuxer.close()
        let probe = SoftwarePlaybackHost.firstEAC3Entry(demuxer: demuxer, streamIndex: 0)
        guard case .noAudioPacket = probe else {
            Issue.record("expected .noAudioPacket, got \(probe)")
            return
        }
    }

    private static func silentWAV() -> Data {
        let pcm = Data(count: 48_000 * 2 * 2)
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(2); u32(48_000); u32(48_000 * 4); u16(4); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}
