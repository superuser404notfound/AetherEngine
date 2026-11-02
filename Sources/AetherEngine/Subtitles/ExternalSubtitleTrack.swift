import Foundation

/// Host-registered external subtitle file (AetherEngine#88). Registered via
/// `LoadOptions.externalSubtitles` (load time, eligible for the native WebVTT rendition / PiP) or
/// `AetherEngine.addExternalSubtitleTrack` (any time, host overlay only). Appears in
/// `engine.$subtitleTracks` as a `TrackInfo` with a synthetic id
/// (`AetherEngine.externalSubtitleTrackIDBase` + registration ordinal) and `isExternal == true`,
/// selectable through the same `selectSubtitleTrack(index:)` as embedded streams.
public struct ExternalSubtitleTrack: Sendable, Equatable {
    var preparationPolicy: ExternalSubtitlePreparationPolicy? = nil

    public var url: URL
    public var name: String?
    /// BCP-47 / ISO 639 code, same convention as `TrackInfo.language`.
    public var language: String?
    public var isForced: Bool
    public var isHearingImpaired: Bool
    public var isDefault: Bool
    /// nil forwards `LoadOptions.httpHeaders` (same auth as the media).
    public var httpHeaders: [String: String]?
    /// File-extension override ("srt", "ass", "vtt", "ssa") for URLs whose path hides the format.
    public var formatHint: String?
    /// Absolute `AVStream` index of the subtitle stream to decode inside the container at `url`
    /// (#266), for URLs that are containers holding several subtitle streams: register one track
    /// per stream, each with its own index. nil decodes the container's first subtitle stream.
    /// An index that is out of range or names a non-subtitle stream fails the decode instead of
    /// falling back, which would be indistinguishable from leaving it nil.
    ///
    /// This indexes the container at `url`, NOT the played media: it is unrelated to the embedded
    /// stream indices that `TrackInfo.id` carries for the main demuxer.
    public var sourceStreamIndex: Int32?

    public init(url: URL, name: String? = nil, language: String? = nil,
                isForced: Bool = false, isHearingImpaired: Bool = false, isDefault: Bool = false,
                httpHeaders: [String: String]? = nil, formatHint: String? = nil,
                sourceStreamIndex: Int32? = nil) {
        self.sourceStreamIndex = sourceStreamIndex
        self.url = url
        self.name = name
        self.language = language
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.isDefault = isDefault
        self.httpHeaders = httpHeaders
        self.formatHint = formatHint
    }

    /// libavcodec decoder name for `TrackInfo.codec`, so host codec checks (ASS styling, text/bitmap
    /// classification) treat external tracks like embedded ones. A `.sup` is a PGS bitmap sidecar
    /// (#921): labelled "subrip" it joined the text renditions and missed the bitmap OCR path.
    /// Unknown formats fall back to "subrip"; `SubtitleDecoder.decodeFile` sniffs the real format
    /// at decode time anyway.
    public static func codecName(url: URL, formatHint: String?) -> String {
        let ext = (formatHint ?? url.pathExtension).lowercased()
        switch ext {
        case "srt", "subrip": return "subrip"
        case "ass", "ssa": return "ass"
        case "vtt", "webvtt": return "webvtt"
        case "sup": return "pgssub"
        default: return "subrip"
        }
    }

    /// Text formats the engine can turn into a WebVTT rendition (#316). `codecName` falls back to
    /// subrip for anything it does not recognise, which is a fine host label but would promise a
    /// rendition for a bitmap sidecar it cannot name; those stay on the overlay (and Phase D's OCR).
    var isTextFormat: Bool {
        ["srt", "subrip", "ass", "ssa", "vtt", "webvtt"]
            .contains((formatHint ?? url.pathExtension).lowercased())
    }

    func makeTrackInfo(id: Int, fallbackNumber: Int) -> TrackInfo {
        let resolvedName: String
        if let name, !name.isEmpty {
            resolvedName = name
        } else if let language, let localized = Locale.current.localizedString(forIdentifier: language) {
            resolvedName = localized
        } else {
            resolvedName = "External \(fallbackNumber)"
        }
        return TrackInfo(id: id, name: resolvedName,
                         codec: Self.codecName(url: url, formatHint: formatHint),
                         language: language, channels: 0, isDefault: isDefault,
                         isForced: isForced, isHearingImpaired: isHearingImpaired,
                         isExternal: true)
    }
}
