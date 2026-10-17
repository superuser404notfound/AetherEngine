import Testing
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The documented audio trade-off of the Profile 7 FEL dual-layer route (`LoadOptions.preferDualLayerDolbyVision`):
/// the route runs on `SoftwarePlaybackHost`, whose audio is always its own `AudioDecoder` (FFmpeg to PCM,
/// through the sample-buffer audio renderer), never AVPlayer. An E-AC-3 track therefore plays as its channel
/// bed, without Atmos objects; on the native route the same track is AVPlayer-decodable and would keep them.
///
/// There is no pure "audio route" function to test: the software host does not choose per codec, it opens
/// `AudioDecoder` for whatever stream it resolved. So the claim is pinned in three pieces: the FEL route is the
/// software host, the native route would hand E-AC-3 to AVPlayer, and the software host's decoder accepts E-AC-3.
@Suite("Dual-layer route audio: E-AC-3 is decoded by the software host, not AVPlayer")
struct DualLayerRouteAudioTests {

    @Test("a Profile 7 FEL source with the preference on takes the software host; without it, it stays native")
    func felRouteIsTheSoftwareHost() {
        func requiresSoftware(prefer: Bool) -> Bool {
            VideoRoutingPolicy.requiresSoftwarePath(
                codecID: AV_CODEC_ID_HEVC, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true,
                dvProfile: 7, dolbyVisionHandling: .automatic,
                preferDualLayerDolbyVision: prefer, canHardwareDecode: { true }, elType: "FEL")
        }
        #expect(requiresSoftware(prefer: true) == DualLayerRouteDecision.isBuiltIn)
        #expect(!requiresSoftware(prefer: false))
    }

    @Test("E-AC-3 is an AVPlayer-native codec, so only the software host's own decode path explains the core-only audio")
    func eac3IsNativeToAVPlayer() {
        #expect(AetherEngine.avPlayerCanDecodeAudio(AV_CODEC_ID_EAC3))
    }

    @Test("the software host's AudioDecoder opens an E-AC-3 stream and the delivery is the host's own decode")
    func softwareHostDecodesEAC3Itself() throws {
        let formatContext = avformat_alloc_context()
        defer { avformat_free_context(formatContext) }
        let stream = try #require(avformat_new_stream(formatContext, nil))
        let codecpar = try #require(stream.pointee.codecpar)
        codecpar.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        codecpar.pointee.codec_id = AV_CODEC_ID_EAC3
        codecpar.pointee.sample_rate = 48_000
        av_channel_layout_default(&codecpar.pointee.ch_layout, 6)
        stream.pointee.time_base = AVRational(num: 1, den: 48_000)

        let decoder = AudioDecoder()
        defer { decoder.close() }
        try decoder.open(stream: stream)
        #expect(decoder.sampleRate == 48_000)
        #expect(decoder.channels == 6)

        #expect(SoftwarePlaybackHost.audioDelivery(
            resolvedAudioIndex: stream.pointee.index, decoderOpened: true, sourceCarriesAudio: true) == .decoded)
    }
}
