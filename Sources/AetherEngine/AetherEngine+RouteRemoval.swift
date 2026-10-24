import AVFoundation
import Foundation

// F3: pause when the audio route a renderer path was playing to goes away.
//
// AVPlayer pauses itself when the output it was playing to is removed (headphones unplugged, a
// Bluetooth device disconnecting, a receiver switching off). The renderer paths (software and audio
// hosts) play into a sample-buffer renderer that keeps going on whatever route is left, so a viewer
// who pulled the headphones would hear the film on the speakers. The public contract is
// `AVAudioSession.routeChangeNotification` with reason `.oldDeviceUnavailable`; the previous route
// tells what went away. The native AVPlayer path does this on its own and is not touched.
// iOS and tvOS only: macOS has no audio session, so there is no equivalent notification to observe.
extension AetherEngine {

    /// `AVAudioSession.RouteChangeReason.oldDeviceUnavailable`, spelled as its raw value so the
    /// decision compiles and is tested on every platform.
    nonisolated static let routeChangeReasonOldDeviceUnavailableRaw: UInt = 2

    /// Pure decision. A removal of the built-in speaker or receiver is not a loss the viewer chose
    /// to make audible, anything else (headphones, Bluetooth, HDMI, AirPlay, USB) is.
    nonisolated static func routeRemovalShouldPause(reasonRaw: UInt?, previousOutputsWereExternal: Bool) -> Bool {
        reasonRaw == routeChangeReasonOldDeviceUnavailableRaw && previousOutputsWereExternal
    }

    /// The reaction. Only a renderer path that is playing: a paused session has nothing to stop, and
    /// the native path is paused by AVPlayer. Goes through `pause()`, so it is a pause like any other
    /// (disarms an interruption resume, publishes `.paused`).
    func noteOutputRouteRemoved() {
        guard softwareHost != nil || audioHost != nil else { return }
        // A seek in flight is playing as far as the viewer is concerned and resumes into the new route.
        guard state == .playing || state == .seeking else { return }
        EngineLog.emit("[AetherEngine] audio route removed while playing; pausing like AVPlayer", category: .engine)
        pause()
    }

    #if os(iOS) || os(tvOS)
    func installRouteRemovalObserver() {
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt
            let previous = info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let external = previous?.outputs.contains {
                $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
            } ?? false
            guard Self.routeRemovalShouldPause(reasonRaw: reasonRaw, previousOutputsWereExternal: external) else { return }
            Task { @MainActor in self?.noteOutputRouteRemoved() }
        }
        retainLifecycleObserver(observer)
    }
    #endif
}
