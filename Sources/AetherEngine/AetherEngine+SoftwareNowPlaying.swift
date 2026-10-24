import AVFoundation
import Combine
import Foundation
import MediaPlayer

/// Engine wiring for the software host's Now-Playing card (see `SoftwareNowPlayingController`).
extension AetherEngine {
    /// Builds the publisher for a freshly created software host when the app opted in via
    /// `ownsSoftwareNowPlaying`. Primary role only: a secondary never takes Now-Playing (Sodalite#175).
    func startSoftwareNowPlaying() {
        stopSoftwareNowPlaying()
        guard Self.ownsNowPlaying(hostOptIn: ownsSoftwareNowPlaying, role: loadedOptions.sharedOutputRole)
        else { return }
        let sink = makeSoftwareNowPlayingSink()
        let controller = SoftwareNowPlayingController(sink: sink, transport: self)
        softwareNowPlaying = controller
        controller.start(skipInterval: remoteSkipInterval)
        softwareNowPlayingActive = true
        // @Published emits before the stored value changes, so a synchronous read in the sink would see the
        // previous state; the hop lets the controller read the settled values.
        Publishers.CombineLatest4($state, $isBuffering, $duration, $isLive)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshSoftwareNowPlaying() }
            }
            .store(in: &softwareCancellables)
        clock.$currentTime
            .sink { [weak self] elapsed in self?.softwareNowPlaying?.clockTick(elapsed) }
            .store(in: &softwareCancellables)
        refreshSoftwareNowPlayingIdentity()
    }

    func stopSoftwareNowPlaying() {
        softwareNowPlaying?.stop()
        softwareNowPlaying = nil
        if softwareNowPlayingActive { softwareNowPlayingActive = false }
    }

    /// Republish after a state-independent change such as a speed change.
    func refreshSoftwareNowPlaying() {
        softwareNowPlaying?.refresh(requestedRate: desiredRate, isBuffering: isBuffering)
    }

    /// Identity from the staged `externalMetadata`, overlaid by the staged `setVideoNowPlayingInfo`
    /// dictionary where both name a key, so the explicit dictionary wins as it does on the audio path.
    func refreshSoftwareNowPlayingIdentity() {
        guard let controller = softwareNowPlaying else { return }
        let items = pendingExternalMetadata
        #if os(tvOS) || os(iOS)
        let explicit = pendingVideoNowPlayingInfo
        #else
        let explicit: [String: Any] = [:]
        #endif
        let generation = loadGeneration
        // Loads finish out of order when metadata is restaged quickly; only the latest ticket applies.
        let ticket = controller.beginIdentityUpdate()
        Task { @MainActor [weak self] in
            var identity = await SoftwareNowPlayingIdentity.make(from: items)
            identity.merge(explicit) { _, new in new }
            guard let self, self.loadGeneration == generation, self.softwareNowPlaying === controller else { return }
            controller.setIdentity(identity, ticket: ticket)
        }
    }
}
