import Testing
import Foundation
@testable import AetherEngine

/// AE#154: remote HLS in loopback mode. FFmpeg is built with --disable-network, so a non-live
/// m3u8 on the loopback path can never be demuxed; the load reroutes onto the native remote-HLS
/// bypass, where AVPlayer plays the playlist and the engine surfaces the legible
/// AVMediaSelectionGroup as `subtitleTracks`. These cover the pure pieces: the reroute decision
/// and the legible-option -> TrackInfo mapping (AVMediaSelectionOption cannot be constructed in
/// tests, so the mapping runs on value snapshots).
struct RemoteHLSMediaSelectionTests {

    // MARK: - Reroute decision

    @Test("VOD-path playlist misroute on a URL source reroutes")
    func rerouteOnVODPlaylistMisroute() {
        #expect(RemoteHLSMediaSelection.shouldReroute(
            probeFailure: AVIOReaderError.hlsPlaylistOnVODPath, isCustomSource: false))
    }

    @Test("Live raw-path misroute keeps the AE#140 fail-closed behavior")
    func noRerouteOnRawLiveMisroute() {
        #expect(!RemoteHLSMediaSelection.shouldReroute(
            probeFailure: AVIOReaderError.hlsPlaylistOnRawLivePath, isCustomSource: false))
    }

    @Test("Custom sources have no URL to reroute")
    func noRerouteForCustomSource() {
        #expect(!RemoteHLSMediaSelection.shouldReroute(
            probeFailure: AVIOReaderError.hlsPlaylistOnVODPath, isCustomSource: true))
    }

    @Test("Successful or unrelated probes never reroute")
    func noRerouteOtherwise() {
        #expect(!RemoteHLSMediaSelection.shouldReroute(probeFailure: nil, isCustomSource: false))
        #expect(!RemoteHLSMediaSelection.shouldReroute(
            probeFailure: DemuxerError.openFailed(code: -1), isCustomSource: false))
    }

    @Test("VOD-path misroute has an actionable description")
    func vodPathErrorDescription() {
        #expect(AVIOReaderError.hlsPlaylistOnVODPath.description.contains("HLS playlist"))
    }

    // MARK: - Legible option -> TrackInfo mapping

    private func option(
        _ name: String, lang: String? = nil, isDefault: Bool = false,
        isForced: Bool = false, isSDH: Bool = false
    ) -> RemoteHLSMediaSelection.LegibleOption {
        RemoteHLSMediaSelection.LegibleOption(
            displayName: name, extendedLanguageTag: lang,
            isDefault: isDefault, isForced: isForced, isSDH: isSDH)
    }

    @Test("Tracks carry synthetic ids above the remote-HLS base, in group order")
    @MainActor
    func syntheticIDs() {
        let tracks = RemoteHLSMediaSelection.subtitleTrackInfos(from: [
            option("English", lang: "en"), option("Deutsch", lang: "de"),
        ])
        #expect(tracks.map(\.id) == [
            RemoteHLSMediaSelection.subtitleTrackIDBase,
            RemoteHLSMediaSelection.subtitleTrackIDBase + 1,
        ])
        #expect(RemoteHLSMediaSelection.subtitleTrackIDBase > AetherEngine.externalSubtitleTrackIDBase)
    }

    @Test("Display name, language, and codec map through")
    func metadataMapping() {
        let tracks = RemoteHLSMediaSelection.subtitleTrackInfos(from: [
            option("English", lang: "en", isDefault: true),
        ])
        #expect(tracks.count == 1)
        #expect(tracks[0].name == "English")
        #expect(tracks[0].language == "en")
        #expect(tracks[0].codec == "webvtt")
        #expect(tracks[0].isDefault)
        #expect(!tracks[0].isExternal)
    }

    @Test("Forced and SDH characteristics map to the TrackInfo dispositions")
    func characteristicMapping() {
        let tracks = RemoteHLSMediaSelection.subtitleTrackInfos(from: [
            option("English (Forced)", lang: "en", isForced: true),
            option("English CC", lang: "en", isSDH: true),
        ])
        #expect(tracks[0].isForced)
        #expect(!tracks[0].isHearingImpaired)
        #expect(tracks[1].isHearingImpaired)
        #expect(!tracks[1].isForced)
    }

    @Test("Empty display name falls back to a numbered label")
    func emptyNameFallback() {
        let tracks = RemoteHLSMediaSelection.subtitleTrackInfos(from: [
            option(""), option("", lang: "ja"),
        ])
        #expect(tracks[0].name == "Subtitle 1")
        #expect(tracks[1].name == "Subtitle 2")
    }

    @Test("Ordinal round-trips from a track id")
    @MainActor
    func ordinalRoundTrip() {
        let id = RemoteHLSMediaSelection.subtitleTrackIDBase + 3
        #expect(RemoteHLSMediaSelection.ordinal(forTrackID: id) == 3)
        #expect(RemoteHLSMediaSelection.ordinal(forTrackID: 0) == nil)
        #expect(RemoteHLSMediaSelection.ordinal(forTrackID: AetherEngine.externalSubtitleTrackIDBase) == nil)
    }
}
