import Foundation
import Combine

/// High-frequency playback clock split out of `AetherEngine`'s `ObservableObject` surface (AetherEngine#29). Before the split, every ~10 Hz tick fired `engine.objectWillChange`, causing ALL observing SwiftUI views to re-render -- on tvOS that rebuilt native `Menu` dropdowns and flickered the focus highlight.
///
/// Host usage: time-driven UI (transport bar, labels) observes `engine.clock` directly and applies `.throttle` / `.removeDuplicates`; everything else (menus, pickers) observes the engine and stays quiet.
@MainActor
public final class PlaybackClock: ObservableObject {

    /// ~10 Hz. On native HLS: unified source-PTS clock (AVPlayer time folded with `playlistShiftSeconds`).
    @Published public internal(set) var currentTime: Double = 0

    /// Source PTS of the currently displayed frame. On native: rides AVPlayer's rendered position -- equals `currentTime` in steady play, but holds the on-screen frame during a seek or rebuffer, not the scrub target (issue #49). SW/audio: always equals `currentTime`.
    @Published public internal(set) var sourceTime: Double = 0

    @Published public internal(set) var progress: Float = 0

    /// Largest session-relative time reached on a live source. 0 when not live.
    @Published public internal(set) var liveEdgeTime: Double = 0

    /// DVR-seekable span on the session timeline. nil when DVR is disabled or not live.
    @Published public internal(set) var seekableLiveRange: ClosedRange<Double>? = nil

    @Published public internal(set) var isAtLiveEdge: Bool = false

    /// Seconds behind the live edge. 0 at the edge.
    @Published public internal(set) var behindLiveSeconds: Double = 0

    /// Source-axis buffer frontier (AetherEngine#54). Same axis as `sourceTime`; draw as `bufferedPosition / duration`. Clamped to never trail the rendered frame.
    ///
    /// - Native: end of the contiguous `loadedTimeRanges` span, seam-shifted.
    /// - Software: newest demuxed source PTS.
    /// - Audio: mirrors `currentTime` (no buffer-ahead surface).
    @Published public internal(set) var bufferedPosition: Double = 0
}
