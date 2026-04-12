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
    /// True if this track is marked as default in the container.
    public let isDefault: Bool

    public init(id: Int, name: String, codec: String, language: String?, isDefault: Bool) {
        self.id = id
        self.name = name
        self.codec = codec
        self.language = language
        self.isDefault = isDefault
    }
}
