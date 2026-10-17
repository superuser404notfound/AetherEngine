import AVFoundation
import Foundation

// F4: follow a change of the route's output channel count.
//
// The channel preference of a renderer path is written once, at activation, as
// `min(source channels, maximum the route can output)`. A route that changes mid-play (a 7.1
// receiver switching off for the 2.0 TV speakers, or back) leaves that number describing a route
// that is gone. AVPlayer re-evaluates its configuration on a route change; the renderer paths do
// the equivalent through the public session: on every route change the preference is recomputed
// against the new maximum and rewritten when it differs.
//
// What is deliberately not done: re-decoding or re-feeding in a new layout. The renderer takes the
// PCM layout the engine decoded and the system adapts it to the route (the sources this matters to
// are forward-only and cannot be re-fed, the same reason the automatic-flush handler leaves a gap
// rather than rewinding). The renderer's own output-configuration notification is deprecated in
// favour of the enqueue result and is not used (SDK availability annotation).
// iOS and tvOS only: macOS has no audio session to carry a channel preference.

/// Pure: the channel count a renderer path asks the session for.
nonisolated func preferredOutputChannels(sourceChannels: Int?, maxOutput: Int) -> Int {
    min(sourceChannels ?? maxOutput, maxOutput)
}

extension AetherEngine {

    /// Pure: the value to write, or nil when the session already holds it. The compare runs where
    /// the write does (on the session queue, against freshly read values), so a burst of route
    /// notifications, or the one a write may itself trigger, ends at the first no-op.
    nonisolated static func channelPreferenceTarget(preferredNow: Int, sourceChannels: Int?, maxOutput: Int) -> Int? {
        let wanted = preferredOutputChannels(sourceChannels: sourceChannels, maxOutput: maxOutput)
        return wanted == preferredNow ? nil : wanted
    }

    /// Only a renderer path owns its channel preference; the native path leaves it to AVKit.
    var ownsChannelPreference: Bool { softwareHost != nil || audioHost != nil }

    #if os(iOS) || os(tvOS)
    func installChannelCountChangeObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.ownsChannelPreference else { return }
                // Same source the activation path resolves: the engines' coordinated maximum, else this
                // engine's own track, so a stereo title is never presented to the route as 8 channels.
                let sources = SharedOutputCoordinator.shared.preferredSourceChannels ?? self.ownSourceChannels()
                _ = self.enqueueAudioSessionTransition {
                    // Off the main actor (AE#538): the reads, the compare and the write are one step.
                    let session = AVAudioSession.sharedInstance()
                    guard session.maximumOutputNumberOfChannels > 0,
                          let wanted = AetherEngine.channelPreferenceTarget(
                        preferredNow: session.preferredOutputNumberOfChannels,
                        sourceChannels: sources, maxOutput: session.maximumOutputNumberOfChannels
                    ) else { return }
                    do {
                        try session.setPreferredOutputNumberOfChannels(wanted)
                        EngineLog.emit("[AetherEngine] route change: channel preference -> \(wanted) (source=\(sources?.formatted() ?? "unknown") max=\(session.maximumOutputNumberOfChannels) output=\(session.outputNumberOfChannels))", category: .engine)
                    } catch {
                        EngineLog.emit("[AetherEngine] route change: channel preference write failed: \(error)", category: .engine)
                    }
                }
            }
        }
        retainLifecycleObserver(observer)
    }
    #endif
}
