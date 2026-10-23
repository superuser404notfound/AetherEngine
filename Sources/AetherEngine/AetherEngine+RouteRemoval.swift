import AVFoundation
import Foundation

// F3: pause when the audio route a renderer path was playing to goes away.
//
// AVPlayer pauses itself when the output it was playing to is removed (headphones unplugged, a
// Bluetooth device disconnecting). The renderer paths (software and audio hosts) play into a
// sample-buffer renderer that keeps going on whatever route is left, so a viewer who pulled the
// headphones would hear the film on the speakers. The public contract is
// `AVAudioSession.routeChangeNotification` with reason `.oldDeviceUnavailable`; the previous route
// tells what went away. The native AVPlayer path does this on its own and is not touched.
// iOS and tvOS only: macOS has no audio session, so there is no equivalent notification to observe.
extension AetherEngine {

    /// `AVAudioSession.RouteChangeReason.oldDeviceUnavailable`, spelled as its raw value so the
    /// decision compiles and is tested on every platform.
    nonisolated static let routeChangeReasonOldDeviceUnavailableRaw: UInt = 2

    /// The outputs whose removal pauses, as `AVAudioSession.Port` raw values (spelled out so the
    /// decision is testable where there is no session): headphones, Bluetooth (A2DP, LE, HFP),
    /// AirPlay and USB, the outputs a viewer takes away and AVPlayer's documented auto-pause covers.
    /// HDMI is left out on purpose: an Apple TV has no built-in output, so every route change there
    /// is an HDMI one, and an ARC / eARC soundbar or receiver switching on or off, or re-asserting
    /// hotplug from standby, would pause the session. What the native path does on such a swap has
    /// not been measured on a device; until it has, the renderer paths do not pause on it.
    nonisolated static let routeRemovalPausingPortTypes: Set<String> = [
        "Headphones", "BluetoothA2DPOutput", "BluetoothLE", "BluetoothHFP", "AirPlay", "USBAudio",
    ]

    /// Pure decision: an old-device-unavailable change whose previous route had one of
    /// `routeRemovalPausingPortTypes` among its outputs.
    nonisolated static func routeRemovalShouldPause(reasonRaw: UInt?, previousOutputPortTypes: [String]) -> Bool {
        reasonRaw == routeChangeReasonOldDeviceUnavailableRaw
            && previousOutputPortTypes.contains(where: routeRemovalPausingPortTypes.contains)
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
            let portTypes = previous?.outputs.map(\.portType.rawValue) ?? []
            guard Self.routeRemovalShouldPause(reasonRaw: reasonRaw, previousOutputPortTypes: portTypes) else { return }
            Task { @MainActor in self?.noteOutputRouteRemoved() }
        }
        retainLifecycleObserver(observer)
    }
    #endif
}
