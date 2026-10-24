import Foundation
import AetherLibavcodec

/// How the software host (the route Dolby Vision Profile 7 FEL takes, and the one for video the hardware
/// decoder cannot play) hands a track's audio to its renderer.
///
/// It decodes to PCM, which is where Atmos was lost: a JOC stream decoded by libavcodec is its 5.1
/// core, and TrueHD Atmos or DTS:X decoded the same way is its 7.1 bed. The two Atmos routes of the
/// AVPlayer path have a software-host counterpart:
///
/// - E-AC-3 JOC is stream-copied there. Here the compressed packets go to the audio renderer, which
///   decodes Atmos once the process has registered the system's Atmos decoder
///   (`AtmosDecoderPrimer`).
/// - TrueHD Atmos and DTS:X are rendered into a speaker bed and encoded as APAC, as for
///   `ObjectAudioRendering.apac`, and the APAC packets go to the renderer.
///
/// The host opts in with `ObjectAudioRendering.apac`, the engine's one setting for object-audio
/// delivery; `.off` keeps the PCM decode on every codec.
enum SoftwareAtmosRoute: Equatable, Sendable {
    case pcm
    case compressedEAC3JOC
    case apac(SpatialSpeakerLayout)

    /// The route for a track. `confirmedJOC` is whether the first E-AC-3 packets carry the JOC flag
    /// (a container does not declare it reliably, so the host reads it off the stream).
    ///
    /// Live sessions stay PCM: their timeline folds and splices re-time audio in ways a compressed
    /// stream, and the APAC encoder's priming, do not follow.
    static func route(
        codecID: AVCodecID,
        profile: Int32,
        sampleRate: Int32,
        channels: Int32,
        framesPerPacket: Int32,
        isLive: Bool,
        rendering: ObjectAudioRendering,
        confirmedJOC: Bool,
        osSupportsAPAC: Bool = ObjectAudioRendering.isAvailable
    ) -> SoftwareAtmosRoute {
        guard let layout = rendering.layout, !isLive else { return .pcm }
        if codecID == AV_CODEC_ID_EAC3 {
            // The 5.1 core of a JOC stream, one 6-block access unit per packet: the shape the renderer's
            // Atmos decoder is described for. Anything else keeps the decode it has.
            guard confirmedJOC, channels == 6, sampleRate == 48_000,
                  framesPerPacket == 0 || framesPerPacket == 1536 else { return .pcm }
            return .compressedEAC3JOC
        }
        guard osSupportsAPAC,
              HLSVideoEngine.spatialRenderingLayout(
                rendering: .apac(layout), codecID: codecID, profile: profile, sampleRate: sampleRate) != nil
        else { return .pcm }
        return .apac(layout)
    }

    /// Packets of the source's head the JOC check may look at, and the bytes it may hold. The check
    /// needs one E-AC-3 access unit, which a muxed file interleaves within the first few packets;
    /// the byte budget keeps a late-starting track in a 4K remux from pinning the video before it.
    static let jocPeekPacketBudget = 512
    static let jocPeekByteBudget = 24 << 20
    /// Audio packets the `dec3` box is tried on before the stream stays PCM.
    static let jocBoxAttempts = 4
}
