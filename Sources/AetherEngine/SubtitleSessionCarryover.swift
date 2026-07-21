import Foundation

/// AetherEngine#170: subtitle session state carried across an engine-initiated
/// `reloadAtCurrentPosition` (AirPlay LAN swap, background-return reopen). The reload is a
/// from-scratch `load()` that rebuilds the session from `LoadOptions` alone; everything the
/// session accumulated since load (mid-session `addExternalSubtitleTrack` registrations, the
/// explicit audio/subtitle selection including subtitles explicitly OFF, and
/// `nativeSubtitleReapplyOrdinal`) would be wiped and re-derived by auto-selection. The reload
/// captures this snapshot first, `load()` seeds the fresh registry from it id-exactly (rides
/// `LoadOptions` engine-internally, like `isLiveRejoin`), and `restoreSubtitleSelection` replays
/// the selection afterwards. Seeding happens BEFORE the native rendition table is built, so
/// mid-session external tracks also become WebVTT-rendition-eligible on the reloaded item, which
/// is exactly the AirPlay/PiP window where the overlay cannot draw.
struct SubtitleSessionCarryover: Sendable, Equatable {
    struct SeededExternalTrack: Sendable, Equatable {
        var id: Int
        var track: ExternalSubtitleTrack
    }

    /// Registry entries in id order, ids verbatim (removal gaps preserved so future adds
    /// cannot collide with the session's id history).
    var externalTracks: [SeededExternalTrack] = []
    var nextExternalOrdinal = 0
    /// Whether the host had taken explicit subtitle authority (select or clear); suppresses the
    /// reload's preferred-language auto-selection, mirroring the in-session contract.
    var hostExplicitSubtitleAction = false
    var activeSubtitleTrackIndex: Int?
    /// One-shot `selectSidecarSubtitle` source (active with no track id); restored by URL.
    var primarySidecarURL: URL?
    /// Secondary channel: external synthetic id or embedded stream index, whichever was active.
    var secondaryTrackIndex: Int?
    var secondarySidecarURL: URL?
    var nativeReapplyOrdinal: Int?
    /// True when the ordinal equals the mapping of the active track through the pre-reload
    /// rendition table (a `setNativeSubtitleRendering` pick). Such ordinals are recomputed
    /// against the reloaded table, which the seeded externals can grow or reorder; a diverging
    /// host-positional ordinal replays positionally like the #65 recovery.
    var reapplyOrdinalMatchesActiveTrack = false
}

/// What the post-reload session must do to return to the pre-reload subtitle selection.
enum SubtitleSelectionRestoreAction: Equatable {
    case none
    case reselect(index: Int)
    case sidecar(URL)
    case clear
}

extension AetherEngine {
    /// Pure restore decision for the primary subtitle channel after a session-preserving reload.
    nonisolated static func subtitleSelectionRestoreAction(
        previousActiveIndex: Int?,
        previousSidecarURL: URL?,
        hostHadExplicitAction: Bool,
        postLoadActiveIndex: Int?,
        postLoadSubtitleActive: Bool
    ) -> SubtitleSelectionRestoreAction {
        if let index = previousActiveIndex {
            return index == postLoadActiveIndex ? .none : .reselect(index: index)
        }
        if let url = previousSidecarURL { return .sidecar(url) }
        // Nothing was active before the reload. An explicit OFF must win over a reload
        // auto-pick (defense in depth; the seeded authority flag already suppresses it).
        if hostHadExplicitAction && postLoadSubtitleActive { return .clear }
        return .none
    }

    /// Pure replay decision for `nativeSubtitleReapplyOrdinal` across a reload, mirroring the
    /// #65 recovery replay but table-aware: rendering-derived ordinals are recomputed against
    /// the rebuilt table (the carryover-seeded externals can shift ordinals), host-positional
    /// ordinals replay positionally. A request that landed mid-reload is newer intent and wins.
    nonisolated static func nativeOrdinalToReplay(
        previousOrdinal: Int?,
        matchesActiveTrack: Bool,
        previousActiveTrack: Int?,
        currentOrdinal: Int?,
        table: [NativeSubtitleTrackEntry]
    ) -> Int? {
        guard let previousOrdinal else { return nil }
        guard currentOrdinal == nil else { return nil }
        if matchesActiveTrack, let track = previousActiveTrack,
           let recomputed = nativeSubtitleOrdinal(forActiveTrack: track, in: table) {
            return recomputed
        }
        return previousOrdinal
    }
}
