import Foundation

/// Common transport surface for all four playback hosts so `AetherEngine` resolves ownership once (`activeTransportHost`). The cascade had drifted before: the volume setter wrote into every host, including the inactive audio host, silently changing the next music session's volume.
@MainActor
protocol TransportControllable: AnyObject {
    func play()
    func pause()
    func setRate(_ rate: Float)
    var volume: Float { get set }
}

extension SoftwarePlaybackHost: TransportControllable {}
extension AudioPlaybackHost: TransportControllable {}
extension AudioAVPlayerHost: TransportControllable {}
extension NativeAVPlayerHost: TransportControllable {}
