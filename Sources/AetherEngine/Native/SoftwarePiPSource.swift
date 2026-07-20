import AVFoundation
import CoreMedia

/// SW-PiP bridge (Sodalite SW-PiP Phase A): everything a host needs to build an
/// AVPictureInPictureController ContentSource around the software path, WITHOUT AVKit entering the
/// engine. The analog of `currentAVPlayer` for sample-buffer PiP: the layer plus the four transport
/// answers backing AVPictureInPictureSampleBufferPlaybackDelegate. Time answers live here because
/// the enqueued frames' PTS axis (source axis, synchronizer clock) is engine knowledge.
@MainActor
public final class SoftwarePiPSource {
    public let layer: AVSampleBufferDisplayLayer
    let isLive: Bool
    private weak var engine: AetherEngine?

    init(layer: AVSampleBufferDisplayLayer, isLive: Bool, engine: AetherEngine) {
        self.layer = layer
        self.isLive = isLive
        self.engine = engine
    }

    /// Playable range on the enqueued frames' PTS axis (source axis). Live sources report an
    /// indefinite range so the window shows live UI.
    public func timeRange() -> CMTimeRange {
        guard let engine else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return AetherEngine.softwarePiPTimeRange(
            isLive: isLive,
            sourceTime: engine.sourceTime,
            currentTime: engine.currentTime,
            duration: engine.duration
        )
    }

    public var isPaused: Bool { engine?.state != .playing }

    public func setPlaying(_ playing: Bool) {
        if playing { engine?.play() } else { engine?.pause() }
    }

    public func skip(by seconds: Double) {
        guard let engine else { return }
        let target = max(0, engine.currentTime + seconds)
        Task { await engine.seek(to: target) }
    }
}
