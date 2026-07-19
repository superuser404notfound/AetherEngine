import Foundation

/// AE#154: remote HLS on the loopback path. FFmpeg is built with --disable-network, so its hls
/// demuxer can neither probe a playlist behind a custom AVIO context (no extension / MIME hint)
/// nor fetch a single variant or segment; a non-live m3u8 handed to the loopback path used to die
/// with a bare AVERROR_INVALIDDATA. Remote HLS is AVPlayer's native domain: `load()` reroutes the
/// source onto the `nativeRemoteHLS` bypass instead, and the bypass surfaces the item's legible
/// AVMediaSelectionGroup as `subtitleTracks` so hosts with their own picker (AetherPlayer) see the
/// external WebVTT renditions AVPlayer already renders.
enum RemoteHLSMediaSelection {

    /// Synthetic id base for legible-option tracks on the remote-HLS bypass. Above
    /// `AetherEngine.externalSubtitleTrackIDBase` so the id spaces stay disjoint
    /// (embedded ids are AVStream indices, external ids start at 100_000).
    static let subtitleTrackIDBase = 200_000

    /// Value snapshot of an `AVMediaSelectionOption` (not constructible in tests).
    struct LegibleOption: Sendable, Equatable {
        let displayName: String
        let extendedLanguageTag: String?
        let isDefault: Bool
        let isForced: Bool
        let isSDH: Bool
    }

    /// Reroute only the typed VOD-path misroute, and only for URL sources: custom readers have no
    /// URL for AVPlayer to open, and the AE#140 live raw-path misroute keeps its fail-closed
    /// contract (live hosts choose their own DVR/rejoin options before going native).
    static func shouldReroute(probeFailure: Error?, isCustomSource: Bool) -> Bool {
        guard !isCustomSource,
              let readerError = probeFailure as? AVIOReaderError,
              case .hlsPlaylistOnVODPath = readerError else { return false }
        return true
    }

    /// Map the legible group's options (in group order) onto the public track model. HLS subtitle
    /// renditions are WebVTT by spec on Apple origins; the codec is informational for host UIs.
    static func subtitleTrackInfos(from options: [LegibleOption]) -> [TrackInfo] {
        options.enumerated().map { i, option in
            TrackInfo(
                id: subtitleTrackIDBase + i,
                name: option.displayName.isEmpty ? "Subtitle \(i + 1)" : option.displayName,
                codec: "webvtt",
                language: option.extendedLanguageTag,
                isDefault: option.isDefault,
                isForced: option.isForced,
                isHearingImpaired: option.isSDH
            )
        }
    }

    /// Group-order ordinal backing a synthetic track id; nil for ids outside the remote-HLS range.
    static func ordinal(forTrackID id: Int) -> Int? {
        id >= subtitleTrackIDBase ? id - subtitleTrackIDBase : nil
    }
}
