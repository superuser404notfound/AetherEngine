import Foundation

/// The playback state of a `SteelPlayer` instance.
public enum PlaybackState: Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    case error(String)
}

/// The detected video dynamic range format.
public enum VideoFormat: Sendable, Equatable {
    case sdr
    case hdr10
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

    public init(id: Int, name: String, codec: String, language: String?, channels: Int = 0, isDefault: Bool) {
        self.id = id
        self.name = name
        self.codec = codec
        self.language = language
        self.channels = channels
        self.isDefault = isDefault
    }
}

// MARK: - Audio Utilities

import CoreAudio

/// Map channel count to the appropriate CoreAudio channel layout tag.
/// Used by both AudioDecoder and CompressedAudioFeeder.
func audioChannelLayoutTag(for channels: Int32) -> AudioChannelLayoutTag {
    switch channels {
    case 1:  return kAudioChannelLayoutTag_Mono
    case 2:  return kAudioChannelLayoutTag_Stereo
    case 3:  return kAudioChannelLayoutTag_MPEG_3_0_A
    case 4:  return kAudioChannelLayoutTag_Quadraphonic
    case 5:  return kAudioChannelLayoutTag_MPEG_5_0_A
    case 6:  return kAudioChannelLayoutTag_MPEG_5_1_A
    case 7:  return kAudioChannelLayoutTag_MPEG_6_1_A
    case 8:  return kAudioChannelLayoutTag_MPEG_7_1_A
    default: return kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
    }
}
