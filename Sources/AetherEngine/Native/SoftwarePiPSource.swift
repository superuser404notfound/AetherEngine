import AVFoundation
import Combine
import CoreMedia
import os
#if os(macOS)
import AppKit
#endif
#if canImport(AVKit)
import AVKit
#endif

/// SW-PiP bridge (Sodalite SW-PiP Phase A): everything a host needs to build an
/// AVPictureInPictureController ContentSource around the software path. The layer and the transport
/// answers are plain engine state; AVKit is touched only by the optional controller helpers below.
/// The analog of `currentAVPlayer` for sample-buffer PiP: the layer plus the four transport answers
/// backing AVPictureInPictureSampleBufferPlaybackDelegate. Time answers live here because the
/// enqueued frames' PTS axis (source axis, synchronizer clock) is engine knowledge.
@MainActor
public final class SoftwarePiPSource {
    /// The two transport answers the PiP window polls, copied out of the main actor so a delegate
    /// callback on another thread can answer without waiting for main.
    struct Snapshot: Sendable {
        var isPaused: Bool
        var range: CMTimeRange
    }

    public let layer: AVSampleBufferDisplayLayer
    let isLive: Bool
    /// Last values computed on the main actor. Read off main by the playback delegate.
    nonisolated let snapshot = OSAllocatedUnfairLock(initialState: Snapshot(isPaused: true, range: .invalid))
    private weak var engine: AetherEngine?
    #if canImport(AVKit) && !os(watchOS)
    private weak var controller: AVPictureInPictureController?
    #endif
    #if os(macOS)
    /// The windows that existed when the controller was made, so the PiP window can be told apart later.
    private(set) var windowsBeforeController: NSHashTable<NSWindow>?
    #endif
    private var stateCancellables: Set<AnyCancellable> = []

    init(layer: AVSampleBufferDisplayLayer, isLive: Bool, engine: AetherEngine) {
        self.layer = layer
        self.isLive = isLive
        self.engine = engine
        refreshSnapshot()
        // One subscription per source, independent of any controller: a host that uses
        // `playbackDelegate` with its own ContentSource still gets a fresh off-main snapshot.
        let refresh: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshSnapshot()
                #if canImport(AVKit) && !os(watchOS)
                self.controller?.invalidatePlaybackState()
                #endif
            }
        }
        engine.$state.dropFirst().sink { _ in refresh() }.store(in: &stateCancellables)
        engine.$duration.dropFirst().sink { _ in refresh() }.store(in: &stateCancellables)
    }

    /// Recompute the transport answers from the engine and publish them to `snapshot`.
    @discardableResult
    func refreshSnapshot() -> Snapshot {
        let fresh: Snapshot
        if let engine {
            fresh = Snapshot(
                isPaused: engine.state != .playing,
                range: AetherEngine.softwarePiPTimeRange(
                    isLive: isLive,
                    sourceTime: engine.sourceTime,
                    currentTime: engine.currentTime,
                    duration: engine.duration
                )
            )
        } else {
            // No engine means no content to describe, which is not the same as a live source.
            fresh = Snapshot(isPaused: true, range: .invalid)
        }
        snapshot.withLock { $0 = fresh }
        return fresh
    }

    /// Playable range on the enqueued frames' PTS axis (source axis). Live sources report an
    /// indefinite range so the window shows live UI. `.invalid` when the engine is gone: there is
    /// no content to describe, which is not the same as a live source.
    /// The read also refreshes the off-main snapshot on purpose.
    public func timeRange() -> CMTimeRange { refreshSnapshot().range }

    /// The read also refreshes the off-main snapshot on purpose.
    public var isPaused: Bool { refreshSnapshot().isPaused }

    /// Close the PiP window of the controller this source made, if any. The engine calls this when
    /// the session ends; a host that built its own controller closes it on `softwarePiPSource == nil`.
    func endPictureInPicture() {
        #if canImport(AVKit) && !os(watchOS)
        controller?.stopPictureInPicture()
        #endif
    }

    /// The PiP window changed size (the render-size delegate callback): macOS looks again for the
    /// window's picture area.
    func pictureInPictureRenderSizeChanged() {
        #if os(macOS)
        engine?.pictureInPictureAreaTracker?.refresh()
        #endif
    }

    public func setPlaying(_ playing: Bool) {
        if playing { engine?.play() } else { engine?.pause() }
    }

    public func skip(by seconds: Double) {
        Task { await skipAndWait(by: seconds) }
    }

    /// The seek target for a PiP skip button: relative to the playhead, never before 0, and on a
    /// finite VOD never past the end. Live sources have no end to clamp to.
    nonisolated static func skipTarget(isLive: Bool, currentTime: Double, duration: Double, by seconds: Double) -> Double {
        let target = max(0, currentTime + seconds)
        guard !isLive, duration.isFinite, duration > 0 else { return target }
        return min(target, duration)
    }

    /// `skip(by:)` that returns once the seek has settled, for the PiP skip completion handler.
    func skipAndWait(by seconds: Double) async {
        guard let engine else { return }
        let target = Self.skipTarget(isLive: isLive, currentTime: engine.currentTime, duration: engine.duration, by: seconds)
        await engine.seek(to: target)
    }

    #if canImport(AVKit) && !os(watchOS)
    /// The playback delegate that maps the PiP window's play, pause, skip and time-range queries onto
    /// this source. Held here because `ContentSource` does not keep its delegate alive.
    public private(set) lazy var playbackDelegate = SoftwarePiPPlaybackDelegate(source: self)

    /// True when the system offers PiP at all. The layer exists for the life of the source; the check
    /// is system-wide.
    public static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// A ready `AVPictureInPictureController` for this session's display layer, or nil when PiP is
    /// not supported on this device. A reload replaces `AetherEngine.softwarePiPSource` and the
    /// content source holds its delegate weakly, so rebuild the controller on every source change.
    /// When `state` or `duration` changes, the source refreshes its snapshot and invalidates the
    /// playback state of the controller it made (the latest one). The host keeps the controller, sets its delegate and
    /// calls `startPictureInPicture()`; it must also set `AetherEngine.pictureInPictureActive` from
    /// the controller's will-start / did-stop callbacks. tvOS AVKit accepts the source but does not
    /// present sample-buffer content (README, Picture in Picture).
    public func makePictureInPictureController() -> AVPictureInPictureController? {
        guard Self.isSupported else { return nil }
        let content = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer, playbackDelegate: playbackDelegate)
        #if os(macOS)
        // Weak, so a window freed before PiP starts cannot be mistaken for the PiP window by address.
        let before = NSHashTable<NSWindow>.weakObjects()
        (NSApp?.windows ?? []).forEach(before.add)
        windowsBeforeController = before
        #endif
        let made = AVPictureInPictureController(contentSource: content)
        controller = made
        return made
    }
    #endif
}

#if canImport(AVKit) && !os(watchOS)
/// `AVPictureInPictureSampleBufferPlaybackDelegate` over a `SoftwarePiPSource`. AVKit gives these
/// callbacks no thread contract, and the main thread may be waiting on AVKit itself, so nothing here
/// blocks on main: on main the live values are read, elsewhere the last published snapshot.
public final class SoftwarePiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
    private weak var source: SoftwarePiPSource?

    init(source: SoftwarePiPSource) {
        self.source = source
    }

    public func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { source?.setPlaying(playing) }
        } else {
            Task { @MainActor [weak source] in source?.setPlaying(playing) }
        }
    }

    public func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        guard let source else { return .invalid }
        if Thread.isMainThread { return MainActor.assumeIsolated { source.timeRange() } }
        return source.snapshot.withLock { $0.range }
    }

    public func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        guard let source else { return true }
        if Thread.isMainThread { return MainActor.assumeIsolated { source.isPaused } }
        return source.snapshot.withLock { $0.isPaused }
    }

    public func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { source?.pictureInPictureRenderSizeChanged() }
        } else {
            Task { @MainActor [weak source] in source?.pictureInPictureRenderSizeChanged() }
        }
    }

    public func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping @Sendable () -> Void) {
        let seconds = skipInterval.seconds
        guard skipInterval.isNumeric, seconds.isFinite else {
            completionHandler()
            return
        }
        Task { @MainActor [weak source] in
            await source?.skipAndWait(by: seconds)
            completionHandler()
        }
    }
}
#endif
