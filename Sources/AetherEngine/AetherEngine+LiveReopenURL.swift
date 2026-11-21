import Foundation

// AE#1100: a live URL source opened again inside one session asks the host for the URL first.
extension AetherEngine {

    /// The URL a live reopen opens: the host's answer from `liveReopenURL`, else `url` itself.
    func urlForLiveReopen(of url: URL, site: String) -> URL {
        guard loadedOptions.isLive, !isCustomSource, let provider = liveReopenURL else { return url }
        guard let fresh = provider(url) else {
            EngineLog.emit("[AetherEngine] AE#1100 \(site): liveReopenURL kept the loaded URL", category: .session)
            return url
        }
        EngineLog.emit("[AetherEngine] AE#1100 \(site): reopening the live source on the URL the host handed over",
                       category: .session)
        return fresh
    }

    /// The engine side of an in-place live audio switch: publish what a rebuild would have.
    func noteLiveAudioSwitchedInPlace(host: SoftwarePlaybackHost) {
        activeAudioTrackIndex = host.audioStreamIndex >= 0 ? Int(host.audioStreamIndex) : nil
        activeAudioDecoder = Self.softwareAudioDecoderLabel(
            audioTracks: audioTracks, activeIndex: host.audioStreamIndex, route: host.audioRoute)
        #if os(iOS) || os(tvOS)
        refreshRendererChannelPreference(reason: "AE#1100 live audio switch")
        #endif
    }
}
