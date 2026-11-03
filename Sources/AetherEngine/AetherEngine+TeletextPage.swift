import Foundation

/// #364: the teletext caption page as a live setting rather than a load option.
///
/// `LoadOptions.teletextPage` reaches `EmbeddedSubtitleDecoder` at construction, and a decoder is
/// built once per drain target, so before this the page was fixed for the life of a selection: a
/// channel whose caption page libzvbi does not flag as a subtitle page could only be corrected by
/// leaving it, changing a setting and coming back. The page now travels with the decoder rebuild the
/// drain path already performs on a target change.
extension AetherEngine {

    /// The teletext caption page in force for this session. nil = libzvbi auto-detect (`txt_page=subtitle`).
    public var teletextPage: Int? { loadedOptions.teletextPage }

    /// Change the teletext caption page while playback runs (#364).
    ///
    /// Applies in three places, because a session can be reading teletext through any of them: the
    /// options replayed on internal reopens, the decoder factories of the two playback hosts, and the
    /// drain decoder of every channel currently showing a teletext track. Channels showing anything
    /// else are left alone; the page reaches them if and when they select a teletext track, since the
    /// factories are already carrying the new value.
    ///
    /// The affected channel's cues are dropped and its window re-decoded on the spot, so the switch
    /// is visible immediately instead of at the next natural reset. Passing the page already in force
    /// does nothing at all.
    public func setTeletextPage(_ page: Int?) {
        guard page != loadedOptions.teletextPage else { return }
        setLoadedTeletextPage(page)
        nativeVideoSession?.teletextPageForSubtitleTap = page
        softwareHost?.teletextPageForSubtitleTap = page
        nativeVideoSession?.refreshSubtitleTapDecoders()

        let rebuilt = rebuildTeletextDrainDecoders()
        let target = page.map(String.init) ?? "auto"
        if rebuilt.isEmpty {
            // Stating the no-op matters: a host that changed the page and saw nothing happen cannot
            // otherwise tell "no teletext track is showing" from "the change did not arrive".
            EngineLog.emit(
                "[AetherEngine] #364: teletext page = \(target), no active teletext track to re-decode",
                category: .engine
            )
        } else {
            EngineLog.emit(
                "[AetherEngine] #364: teletext page = \(target), re-decoding \(rebuilt.count) channel(s)",
                category: .engine
            )
        }
    }

    /// Drop the drain decoder, cursor and cues of every channel whose target is a teletext track, then
    /// tick once. A nil cursor is what makes the next plan a `.resetAndDecode` (see
    /// `SubtitleOverlayDrainer.drainPlan`), which is the same path a fresh selection takes, so the
    /// window around the playhead comes back decoded with the new page.
    /// Returns the channels it touched.
    private func rebuildTeletextDrainDecoders() -> [SubtitleChannel] {
        var affected: [SubtitleChannel] = []
        for (channel, streamIndex) in embeddedSubtitleDrainTargets {
            guard let codec = subtitleTracks.first(where: { $0.id == Int(streamIndex) })?.codec,
                  Self.isTeletextSubtitleCodec(codec) else { continue }
            subtitleDrainDecoders[channel] = nil
            subtitleDrainCursors[channel] = nil
            pgsStaleArrivalGates[channel]?.reset()
            switch channel {
            case .primary: subtitleCues = []
            case .secondary: secondarySubtitleCues = []
            }
            affected.append(channel)
        }
        if !affected.isEmpty { subtitleDrainTick() }
        return affected
    }
}
