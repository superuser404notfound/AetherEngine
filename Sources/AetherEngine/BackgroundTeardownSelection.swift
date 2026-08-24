import Foundation
import Libavcodec

/// AetherEngine#357: the session selection a teardown hands to the reload that follows it.
///
/// Every reload path snapshots what it restores immediately before its own `stopInternal`: the
/// #170 subtitle carryover, the audio pick, the disc title (#67). That contract holds only while
/// teardown and reload are the same call. The paused-background teardown (#127) breaks it: it runs
/// `stopInternal` when the app goes to sleep, and the reload happens on foreground return minutes
/// later, by which time the state the reload would snapshot is already wiped. The reload then
/// restored nothing, which for subtitles means no drain target and total silence on every delivery
/// instrument. So the teardown takes the snapshot itself and parks it here for the reload to claim.
struct BackgroundTeardownSelection: Sendable, Equatable {
    var subtitles = SubtitleSessionCarryover()
    var audioTrackIndex: Int?
    var discTitleID: Int?
    var playbackBackend: PlaybackBackend = .none
    var videoCodecID: AVCodecID = AV_CODEC_ID_NONE
}

extension AetherEngine {

    /// Park the current selection for the reload that follows this teardown. Called by both #127
    /// teardown paths (grace expiry and the synchronous assertion backstop) BEFORE `stopInternal`.
    func captureBackgroundTeardownSelection() {
        backgroundTeardownSelection = BackgroundTeardownSelection(
            subtitles: captureSubtitleSessionCarryover(),
            audioTrackIndex: activeAudioTrackIndex,
            discTitleID: activeDiscTitleID,
            playbackBackend: playbackBackend,
            videoCodecID: lastDetectedVideoCodec
        )
    }

    /// The selection a session-preserving reload must restore, claiming any parked teardown
    /// snapshot on the way (once: a second reload reads the live session only).
    func consumeReloadSelection() -> BackgroundTeardownSelection {
        let parked = backgroundTeardownSelection
        backgroundTeardownSelection = nil
        return BackgroundTeardownSelection(
            subtitles: Self.mergedSubtitleCarryover(
                live: captureSubtitleSessionCarryover(), snapshot: parked?.subtitles),
            audioTrackIndex: activeAudioTrackIndex ?? parked?.audioTrackIndex,
            discTitleID: activeDiscTitleID ?? parked?.discTitleID,
            playbackBackend: playbackBackend != .none
                ? playbackBackend : parked?.playbackBackend ?? .none,
            videoCodecID: lastDetectedVideoCodec != AV_CODEC_ID_NONE
                ? lastDetectedVideoCodec : parked?.videoCodecID ?? AV_CODEC_ID_NONE
        )
    }

    /// Merge rule for a reload that follows a teardown. `stopInternal` keeps the external registry,
    /// its ordinal counter and the host's subtitle authority, so the LIVE read owns those (a track
    /// registered while the session was down must not be dropped by an older snapshot). It wipes
    /// the selection, so those fields come from the snapshot, unless the live read carries a
    /// selection of its own: that is newer host intent and wins, the same rule
    /// `pendingNativeRenderingRequest` follows across a reload.
    nonisolated static func mergedSubtitleCarryover(
        live: SubtitleSessionCarryover,
        snapshot: SubtitleSessionCarryover?
    ) -> SubtitleSessionCarryover {
        guard let snapshot else { return live }
        var merged = live
        merged.hostExplicitSubtitleAction = live.hostExplicitSubtitleAction || snapshot.hostExplicitSubtitleAction
        merged.nextExternalOrdinal = max(live.nextExternalOrdinal, snapshot.nextExternalOrdinal)
        if live.activeSubtitleTrackIndex == nil, live.primarySidecarURL == nil {
            merged.activeSubtitleTrackIndex = snapshot.activeSubtitleTrackIndex
            merged.primarySidecarURL = snapshot.primarySidecarURL
            // The ordinal is the active pick's mapping through the rendition table, so it travels
            // with the pick rather than on its own.
            merged.nativeReapplyOrdinal = snapshot.nativeReapplyOrdinal
            merged.reapplyOrdinalMatchesActiveTrack = snapshot.reapplyOrdinalMatchesActiveTrack
        }
        if live.secondaryTrackIndex == nil, live.secondarySidecarURL == nil {
            merged.secondaryTrackIndex = snapshot.secondaryTrackIndex
            merged.secondarySidecarURL = snapshot.secondarySidecarURL
        }
        return merged
    }
}
