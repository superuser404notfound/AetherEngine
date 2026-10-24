import Foundation

/// How a TrueHD track carrying Dolby Atmos, or a DTS-HD Master Audio track carrying DTS:X, is
/// delivered.
///
/// Apple TV cannot bitstream TrueHD or DTS-HD, so `audioBridgeMode` decodes their 7.1 channel
/// presentation and the objects and heights are lost. `.apac` keeps them: the engine renders the
/// objects and heights into the listener's speaker bed and delivers it as Apple Positional Audio,
/// which tvOS sends to an Atmos receiver as Dolby MAT. The price is a lossy encode (several Mbit/s)
/// in place of the lossless 7.1, which is why this is the host's choice and not the engine's.
///
/// Applies to TrueHD sources FFmpeg identifies as Atmos (profile 30) and to DTS-HD Master Audio that
/// decodes as DTS:X in its standard presentation on its first frame, at 48 kHz, and only on OS 26 and later, where the
/// APAC encoder API exists. Everything else keeps `audioBridgeMode`.
///
/// The software playback host (the route Dolby Vision Profile 7 FEL and video the hardware decoder
/// cannot play take) honours the same setting on VOD sessions. It renders TrueHD Atmos and DTS:X as APAC
/// for the sample-buffer audio renderer, and it hands an E-AC-3 JOC track to that renderer
/// compressed, so the system's Atmos decoder gets the objects; without the setting, or for live
/// sessions, it decodes every track to PCM as before.
///
/// The renderer is an optional component: TrueHD needs the `TrueHDObjectAudio` package trait and DTS:X
/// the `DTSXObjectAudio` trait, both off by default. Without a codec's trait `.apac` is a no-op for it
/// (`AetherEngine.OptionalComponent.isBuiltIn` answers which are in a build).
public enum ObjectAudioRendering: Equatable, Sendable {
    case off
    /// Render into `layout`, which should match the speakers the receiver actually drives.
    case apac(SpatialSpeakerLayout)

    /// The only rate object audio is rendered at. TrueHD Atmos and DTS:X are authored at 48 kHz.
    static let sampleRate = 48_000

    /// Whether this OS has the APAC encoder API the route needs. Below it, `.apac` changes nothing:
    /// the track plays through `audioBridgeMode` as if rendering were off.
    static var isAvailable: Bool {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) { return true }
        return false
    }

    var layout: SpatialSpeakerLayout? {
        if case .apac(let layout) = self { return layout }
        return nil
    }
}
