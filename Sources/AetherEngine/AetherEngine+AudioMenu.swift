import AVFoundation
import Foundation

/// AE#1049: every source audio track in AVKit's audio menu, with a pick answered by a reload.
///
/// The variant carries one muxed audio track. The master lists the others as URI-less entries in
/// the same group (`LoadOptions.nativeAudioTrackMenu`), and this file watches the item's audible
/// selection. A pick of anything but the served track becomes `selectAudioTrack(index:)`.
///
/// What a pick does to the item before the reload lands differs per platform. Measured with a stock
/// player: tvOS 26 keeps playing the muxed track, macOS 27 freezes the clock with rate 1.0 and no
/// error. Either way the reload replaces the item, so a pick must never go unanswered.
extension AetherEngine {

    /// The tracks to list, or empty when the host did not opt in or a switch could not happen.
    func audioMenuChoicesForSession() -> [AudioRenditionChoice] {
        guard loadedOptions.nativeAudioTrackMenu,
              !(isCustomSource && !customSourceIsSeekable),
              !Self.audioSwitchNeedsFreshLoad(isLive: isLive, sequentialOrigin: loadedOptions.sequentialOrigin),
              audioTracks.count > 1 else { return [] }
        return Self.audioMenuChoices(for: audioTracks)
    }

    /// AVFoundation labels the PLAYING entry by its language and ignores its NAME (measured on tvOS 26
    /// and macOS 27, with and without a track title in the fMP4), while the other entries show their
    /// NAME. So when a language repeats, no track of it may be named by the bare language, or the
    /// playing track and that one read the same: "English (Track 2)" instead of "English".
    nonisolated static func audioMenuChoices(for tracks: [TrackInfo]) -> [AudioRenditionChoice] {
        VideoSegmentProvider.uniquelyNamed(tracks.enumerated().map { i, track in
            let bare = track.language.flatMap { Locale.current.localizedString(forIdentifier: $0) }
            var name = nativeSubtitleRenditionBaseName(language: track.language, title: track.sourceTitle)
                ?? "Audio \(i + 1)"
            let languageRepeats = track.language.map { language in
                tracks.filter { languageMatches($0.language, language) }.count > 1
            } ?? false
            if languageRepeats, let bare, name == bare { name = "\(bare) (Track \(i + 1))" }
            return AudioRenditionChoice(trackID: track.id, language: track.language,
                                        name: name, channels: track.channels)
        })
    }

    /// Which declared entry an AVFoundation option stands for. By NAME, which AVFoundation keeps as
    /// the option's common title even where `displayName` shows the language instead; language plus
    /// rank only for an option that carries no title.
    nonisolated static func audioMenuTrackID(
        selectedName: String?, selectedLanguage: String?, rankInLanguage: Int,
        declared: [AudioRenditionChoice]
    ) -> Int? {
        if let selectedName, let exact = declared.first(where: { $0.name == selectedName }) { return exact.trackID }
        guard let selectedLanguage else { return nil }
        let sameLanguage = declared.filter { languageMatches($0.language, selectedLanguage) }
        return rankInLanguage < sameLanguage.count ? sameLanguage[rankInLanguage].trackID : nil
    }

    /// Arms the pick watch for the item this load just mounted. No-op when no alternate was served.
    func armAudioMenuPicks(host: NativeAVPlayerHost) {
        cancelAudioMenuPicks()
        guard let session = nativeVideoSession, let provider = session.provider,
              let item = host.avPlayer.currentItem else { return }
        let alternates = provider.masterAudioAlternates
        guard !alternates.isEmpty, let primary = provider.masterAudioRendition else { return }
        let servedID = Int(session.activeAudioSourceStreamIndex)
        let declared = [AudioRenditionChoice(trackID: servedID, language: primary.language,
                                             name: primary.name, channels: 0)] + alternates
        EngineLog.emit("[AetherEngine] AE#1049 audio menu: served=\(servedID) alternates=\(alternates.map { "\($0.trackID):\($0.name)" })",
                       category: .session)
        audioMenuPickTask = Task { @MainActor [weak self] in
            for await ready in host.$isReady.values where ready { break }
            guard let self, !Task.isCancelled, self.currentAVPlayer?.currentItem === item,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  !Task.isCancelled, self.currentAVPlayer?.currentItem === item else { return }
            // AVKit carries the viewer's last pick over to the next item as a language preference,
            // and with two tracks in one language that lands on the wrong one. Measured on tvOS 26:
            // a pick of "English (Commentary)" reloaded onto it, the new item came up on "English",
            // and the engine followed 56 ms later. The served track is the truth, so select it first.
            if let served = group.options.first(where: { Self.renditionName(of: $0) == primary.name }),
               item.currentMediaSelection.selectedMediaOption(in: group) != served {
                EngineLog.emit("[AetherEngine] AE#1049 audio menu: item came up on "
                               + "\"\(item.currentMediaSelection.selectedMediaOption(in: group)?.displayName ?? "nil")\", "
                               + "selecting the served \"\(primary.name)\"", category: .session)
                item.select(served, in: group)
            }
            self.audioMenuPickObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.audioMenuPickTask = Task { @MainActor [weak self] in
                        await self?.answerAudioMenuPick(item: item, servedID: servedID, declared: declared)
                    }
                }
            }
        }
    }

    private func answerAudioMenuPick(item: AVPlayerItem, servedID: Int, declared: [AudioRenditionChoice]) async {
        guard currentAVPlayer?.currentItem === item,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
              !Task.isCancelled, currentAVPlayer?.currentItem === item,
              let selected = item.currentMediaSelection.selectedMediaOption(in: group) else { return }
        let language = selected.extendedLanguageTag
        let rank = group.options.prefix { $0 != selected }
            .filter { Self.languageMatches($0.extendedLanguageTag, language ?? "") }.count
        guard let trackID = Self.audioMenuTrackID(selectedName: Self.renditionName(of: selected), selectedLanguage: language,
                                                  rankInLanguage: rank, declared: declared) else {
            EngineLog.emit("[AetherEngine] AE#1049 audio menu: pick \"\(selected.displayName)\" lang=\(language ?? "nil") "
                           + "matches no declared track, ignored", category: .session)
            return
        }
        guard trackID != servedID else { return }
        EngineLog.emit("[AetherEngine] AE#1049 audio menu: viewer picked \"\(selected.displayName)\", switching to stream \(trackID)",
                       category: .session)
        selectAudioTrack(index: trackID)
    }

    /// The master's NAME for an option. `displayName` is not it for the playing entry.
    nonisolated static func renditionName(of option: AVMediaSelectionOption) -> String? {
        option.commonMetadata.first { $0.commonKey == .commonKeyTitle }?.stringValue
    }

    func cancelAudioMenuPicks() {
        if let observer = audioMenuPickObserver { NotificationCenter.default.removeObserver(observer) }
        audioMenuPickObserver = nil
        audioMenuPickTask?.cancel()
        audioMenuPickTask = nil
    }
}
