import Foundation
import CoreGraphics

/// The playback state of a `AetherEngine` instance.
public enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    case error(String)
}

/// The detected video dynamic range format.
///
/// `hdr10Plus` shares the underlying HDR10 base layer with `hdr10`,
/// what makes it distinct is the per-frame ST 2094-40 dynamic metadata
/// the engine forwards to the display via
/// `kCMSampleAttachmentKey_HDR10PlusPerFrameData`. From an
/// AVDisplayCriteria perspective both formats request the same TV
/// mode (PQ + BT.2020); the badge / detection split exists so the host
/// UI can show the right label and so reporting is accurate.
public enum VideoFormat: Sendable, Equatable {
    case sdr
    case hdr10
    case hdr10Plus
    case dolbyVision
    case hlg
}

/// Metadata about an audio or subtitle track in the loaded media.
public struct TrackInfo: Identifiable, Sendable, Equatable {
    /// Track index as reported by FFmpeg's AVStream.
    public let id: Int
    /// Human-readable track name (title or fallback).
    public let name: String
    /// Codec name (e.g. "aac", "ac3", "subrip").
    public let codec: String
    /// BCP-47 language tag if available (e.g. "en", "de", "ja").
    public let language: String?
    /// Number of audio channels (2=stereo, 6=5.1, 8=7.1). 0 for non-audio.
    public let channels: Int
    /// True if this track is marked as default in the container.
    public let isDefault: Bool
    /// True if this is a Dolby Atmos track, currently means EAC3 with
    /// the JOC (Joint Object Coding) profile, which is what every
    /// streaming-quality Atmos elementary stream looks like in practice.
    /// Lets the player UI surface "Atmos" instead of just the channel
    /// count of the bed (typically 5.1).
    public let isAtmos: Bool

    public init(id: Int, name: String, codec: String, language: String?, channels: Int = 0, isDefault: Bool, isAtmos: Bool = false) {
        self.id = id
        self.name = name
        self.codec = codec
        self.language = language
        self.channels = channels
        self.isDefault = isDefault
        self.isAtmos = isAtmos
    }
}

/// A single decoded subtitle cue, start/end in container seconds plus a
/// payload. The payload is either plain text (SubRip / ASS / SSA / WebVTT
/// / mov_text after override-stripping) or a rendered bitmap (PGS / DVB
/// / HDMV) with a position normalised against the source video frame.
/// Both paths land in the same `subtitleCues` array, so the host renders
/// them with one switch in the overlay view.
public struct SubtitleCue: Identifiable, Sendable {
    public let id: Int
    public let startTime: Double
    public let endTime: Double
    public let body: Body

    public enum Body: Sendable {
        case text(String)
        case image(SubtitleImage)
    }

    public init(id: Int, startTime: Double, endTime: Double, body: Body) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.body = body
    }

    /// Convenience for callers that only handle text cues. Returns nil
    /// for bitmap cues, which the host should render as `.image` instead.
    public var text: String? {
        if case .text(let s) = body { return s }
        return nil
    }
}

extension SubtitleCue: Equatable {
    public static func == (lhs: SubtitleCue, rhs: SubtitleCue) -> Bool {
        // ID is monotonic per subtitle session and unique within the
        // current `subtitleCues` array, that's enough to drive
        // SwiftUI animation diffing without comparing CGImage refs.
        lhs.id == rhs.id
            && lhs.startTime == rhs.startTime
            && lhs.endTime == rhs.endTime
    }
}

/// A decoded bitmap subtitle rect, the kind PGS, HDMV PGS, DVB and
/// DVD subtitles produce. The CGImage is fully rendered (palette
/// applied, RGBA, premultiplied alpha) and ready to display. Position
/// is normalised in [0, 1] against the source video frame so the host
/// can scale to any display rect.
public struct SubtitleImage: @unchecked Sendable {
    public let cgImage: CGImage
    /// Origin and size in [0, 1] coordinates of the source video frame.
    /// Hosts multiply by the on-screen video rect to position the
    /// bitmap correctly.
    public let position: CGRect

    public init(cgImage: CGImage, position: CGRect) {
        self.cgImage = cgImage
        self.position = position
    }
}

// MARK: - Audio Utilities

import CoreAudio

/// Map channel count to the appropriate CoreAudio channel layout tag.
/// Used by AudioDecoder for channel layout mapping.
///
/// 7.1 note: `MPEG_7_1_A` is the ITU "center-sides" layout (L R C LFE
/// Ls Rs Lc Rc) almost nobody ships. Blu-ray, TrueHD, DTS-HD MA and
/// streaming 7.1 are all the "Hollywood" layout, L R C LFE Ls Rs Lsr
/// Rsr, which is `MPEG_7_1_C`. Using the wrong tag made tvOS silently
/// drop the stream: the audio pipeline can't reconcile 7.1-A samples
/// with a 7.1-C output route, and just emits silence instead of
/// routing them.
func audioChannelLayoutTag(for channels: Int32) -> AudioChannelLayoutTag {
    switch channels {
    case 1:  return kAudioChannelLayoutTag_Mono
    case 2:  return kAudioChannelLayoutTag_Stereo
    case 3:  return kAudioChannelLayoutTag_MPEG_3_0_A
    case 4:  return kAudioChannelLayoutTag_Quadraphonic
    case 5:  return kAudioChannelLayoutTag_MPEG_5_0_A
    case 6:  return kAudioChannelLayoutTag_MPEG_5_1_A
    case 7:  return kAudioChannelLayoutTag_MPEG_6_1_A
    case 8:  return kAudioChannelLayoutTag_AAC_7_1
    default: return kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
    }
}
