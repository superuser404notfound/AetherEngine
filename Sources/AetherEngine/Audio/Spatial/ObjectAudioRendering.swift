import Foundation

/// How a TrueHD track carrying Dolby Atmos, or a DTS-HD Master Audio track carrying DTS:X, is
/// delivered.
///
/// Apple TV cannot bitstream TrueHD or DTS-HD, so `audioBridgeMode` decodes their 7.1 channel
/// presentation and the objects and heights are lost. Rendering keeps them: the engine renders the
/// objects and heights into the listener's speaker bed and hands that bed to the system, which sends
/// it to an Atmos receiver as Dolby MAT.
///
/// The bed travels in one of two forms (`SpatialBedFormat`). Linear PCM keeps it bit for bit: tvOS
/// takes 12 or 16 channels of it and wraps them in MAT itself, and iOS spatialises it on AirPods.
/// Apple Positional Audio is a lossy encode (several Mbit/s), the form an AirPlay route has been seen
/// to carry as Atmos. `.render` picks per route at load, `.apac` and `.lpcm` force one. Either way the
/// 7.1 lossless presentation gives way to the rendered bed, which is why this is the host's choice and
/// not the engine's.
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
    /// Render into `layout` and deliver the bed in the form the output route carries: linear PCM,
    /// unless the route plays over AirPlay, then APAC. Decided at load
    /// (`SpatialBedFormat.forCurrentRoute`).
    case render(SpatialSpeakerLayout)
    /// Render into `layout`, which should match the speakers the receiver actually drives, and
    /// always deliver it as APAC.
    case apac(SpatialSpeakerLayout)
    /// Render into `layout` and always deliver it as linear PCM.
    case lpcm(SpatialSpeakerLayout)

    /// The only rate object audio is rendered at. TrueHD Atmos and DTS:X are authored at 48 kHz.
    static let sampleRate = 48_000

    /// Whether this OS has the APAC encoder API the route needs. Below it, `.apac` changes nothing:
    /// the track plays through `audioBridgeMode` as if rendering were off.
    static var isAvailable: Bool {
        if #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) { return true }
        return false
    }

    var layout: SpatialSpeakerLayout? {
        switch self {
        case .off: return nil
        case .render(let layout), .apac(let layout), .lpcm(let layout): return layout
        }
    }

    /// The form the bed is delivered in, with `routeFormat` the one `.render` takes.
    func bedFormat(routeFormat: @autoclosure () -> SpatialBedFormat) -> SpatialBedFormat? {
        switch self {
        case .off: return nil
        case .render: return routeFormat()
        case .apac: return .apac
        case .lpcm: return .lpcm
        }
    }
}
