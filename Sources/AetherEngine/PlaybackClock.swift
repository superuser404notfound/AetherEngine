import Foundation
import Combine

/// High-frequency playback clock, split out of `AetherEngine`'s own
/// `ObservableObject` surface (AetherEngine#29).
///
/// `currentTime` ticks at ~10 Hz from AVPlayer's periodic time
/// observer. While these values lived as `@Published` properties on
/// the engine itself, every tick fired `engine.objectWillChange`, so
/// ANY SwiftUI view observing the engine (via `@ObservedObject` /
/// `@EnvironmentObject`) re-rendered its body 10 times a second even
/// if it only read track lists or playback state. On tvOS that
/// re-render tears down and rebuilds native `Menu` dropdowns, which
/// makes the focused item's highlight flicker at the publish rate.
///
/// The split mirrors AVFoundation's own shape: AVPlayer exposes time
/// via `addPeriodicTimeObserver`, not via KVO-observable state, so
/// time-driven UI opts in explicitly and everything else stays quiet.
///
/// Host usage:
/// - **Polling / one-shot reads** keep working unchanged through the
///   engine's computed forwarders (`engine.currentTime` etc.).
/// - **Time-driven UI** (transport bar, time labels) observes the
///   clock, not the engine: put `@ObservedObject var clock =
///   engine.clock` in the leaf view that renders time, or subscribe
///   to `engine.clock.$currentTime` in a view model. Apply
///   `.throttle` / `.removeDuplicates` downstream for lower rates.
/// - **Everything else** (menus, track pickers, settings panes)
///   observes the engine and no longer re-renders on clock ticks.
@MainActor
public final class PlaybackClock: ObservableObject {

    /// Current playback position in seconds, ~10 Hz. On the native
    /// HLS path this is the unified source-PTS clock (AVPlayer time
    /// folded with `playlistShiftSeconds`).
    @Published public internal(set) var currentTime: Double = 0

    /// Source PTS of the currently displayed frame. On the native path
    /// this rides AVPlayer's actually-rendered position, so it equals
    /// `currentTime` in steady playback but holds the on-screen frame
    /// while a seek is in flight or the loopback source rebuffers,
    /// rather than jumping to the seek target the scrub clock
    /// (`currentTime`) shows. Frame-accurate consumers (subtitle
    /// overlay, side-demuxer re-arm) read this so they follow the
    /// picture and not the scrub intent (issue #49). On the SW / audio
    /// paths it equals `currentTime` always.
    @Published public internal(set) var sourceTime: Double = 0

    /// Fractional progress through the loaded item. Reset to 0 on
    /// load/stop; hosts typically derive their own from
    /// `currentTime / duration`.
    @Published public internal(set) var progress: Float = 0

    /// Largest session-relative time reached on a live source
    /// (seconds since first frame). Meaningful only while
    /// `engine.isLive`. 0 otherwise.
    @Published public internal(set) var liveEdgeTime: Double = 0

    /// DVR-seekable span on the session timeline, or nil when DVR is
    /// disabled or the source is not live.
    @Published public internal(set) var seekableLiveRange: ClosedRange<Double>? = nil

    /// True when playback is at / near the live edge.
    @Published public internal(set) var isAtLiveEdge: Bool = false

    /// Seconds the playhead trails the live edge. 0 at the edge.
    @Published public internal(set) var behindLiveSeconds: Double = 0

    /// Source-axis position (seconds) up to which the engine has data
    /// buffered ahead of the playhead (AetherEngine#54). On the SAME
    /// axis as `sourceTime`, so a host draws a YouTube-style buffer bar
    /// as `bufferedPosition / duration`. Clamped to never trail the
    /// rendered frame, so it equals `sourceTime` when nothing ahead is
    /// buffered or before the first frame.
    ///
    /// What "buffered" means per path:
    /// - **Native AVPlayer** (HLS / direct): end of the contiguous
    ///   `loadedTimeRanges` span covering the playhead, folded onto the
    ///   source axis with the same seam shift as `sourceTime`.
    /// - **Software** (dav1d / libavcodec): the newest source PTS the
    ///   demuxer has pulled from the (possibly remote) source, i.e. how
    ///   far ahead bytes have been fetched and demuxed.
    /// - **Audio**: mirrors `currentTime` (no buffer-ahead surface).
    @Published public internal(set) var bufferedPosition: Double = 0
}
