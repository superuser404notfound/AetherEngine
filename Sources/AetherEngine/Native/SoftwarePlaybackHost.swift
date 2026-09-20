import Foundation
import AVFoundation
import CoreMedia
import Combine
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Software-decode playback host (FFmpeg/dav1d pipeline): AV1 on Apple TV (no HW AV1 on tvOS), VP9.
/// AVSampleBufferRenderSynchronizer is the master clock; display layer attached for A/V sync.
/// Intentionally skips EAC3+JOC and DV HDMI handshake (AV1 sources rarely carry Atmos or DV).
@MainActor
final class SoftwarePlaybackHost {

    // MARK: - Published state (mirrors NativeAVPlayerHost surface)

    /// Frames enqueued on the display layer; read by LiveTelemetrySampler at 1 Hz for observed FPS. Lock-guarded (demux thread writes, main-actor reads).
    nonisolated var framesEnqueued: Int {
        framesEnqueuedLock.lock()
        defer { framesEnqueuedLock.unlock() }
        return _framesEnqueued
    }
    nonisolated private func bumpFramesEnqueued() -> Int {
        framesEnqueuedLock.lock()
        defer { framesEnqueuedLock.unlock() }
        let previous = _framesEnqueued
        _framesEnqueued &+= 1
        return previous
    }
    private let framesEnqueuedLock = NSLock()
    nonisolated(unsafe) private var _framesEnqueued: Int = 0

    /// #220: the pump demuxer's network sliding window, for the periodic memprobe. Paired with
    /// the subtitle side reader's own window, the two connections are separately attributable.
    var ioWindowDiagnostics: (windowBytes: Int, aheadBytes: Int, parked: Bool)? {
        demuxer?.ioWindowDiagnostics
    }

    /// #240: lifetime bytes this pump pulled from the source, so the memprobe can put it next to the
    /// subtitle side reader's own total and say which one took the link.
    var demuxerBytesFetched: Int64? {
        demuxer?.avioBytesFetched
    }

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    /// Raw synchronizer clock in the SOURCE axis (same axis as demuxed packet PTS and
    /// subtitle cues). Equals `currentTime` for zero-based sources; diverges by the
    /// session-zero offset on live and mid-stream-joined sources (#107). The engine
    /// publishes this as `clock.sourceTime` so the subtitle overlay drainer scans the
    /// packet store on the right axis.
    @Published private(set) var sourceClockSeconds: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    /// #376: carries the classification with the message, so the engine can publish both.
    @Published private(set) var failure: PlaybackErrorInfo?
    @Published private(set) var didReachEnd: Bool = false

    /// #315: `AVSampleBufferDisplayLayer.isReadyForDisplay` for the renderer's layer, this path's
    /// answer to "there is a picture". Frames enqueued is not that answer: it counts what the
    /// decoder handed over, and #298 is the report where every one of them went into a layer no
    /// host had bound.
    ///
    /// A LEVEL that falls whenever the layer loses its picture; the engine folds it into the
    /// load-scoped `AetherEngine.hasFirstFrameReadyForDisplay`, which is what hosts consume. A
    /// session with no video stream never arms the observation and leaves this false.
    @Published private(set) var isVideoReadyForDisplay: Bool = false

    /// #315: `readyForDisplay` observation on the renderer's layer, re-armed per load and torn down
    /// with the session.
    private var readyForDisplayObserver: NSObjectProtocol?

    /// #353: the size this session's picture presents at, coded dimensions under the pixel aspect
    /// ratio the decoder attached; nil until the renderer builds its first sample buffer and on
    /// sources with no video. The engine mirrors it as `AetherEngine.softwareDisplaySize`, which is
    /// what hosts read; this host is built per load, so it starts unknown by construction.
    @Published private(set) var videoDisplaySize: CGSize?

    /// Fires (off-main) once per session the first time HDR10+ dynamic
    /// metadata appears on a decoded frame. Hooked by `AetherEngine` to
    /// upgrade the published `videoFormat` from `.hdr10` → `.hdr10Plus`.
    nonisolated(unsafe) var onFirstHDR10PlusDetected: (@Sendable () -> Void)?

    /// #131: forwarded from the video decoder; decoded-frame A53 cc_data triplets, presentation order.
    nonisolated(unsafe) var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?

    // MARK: - Output

    /// The display layer the engine attaches to the bound `AetherPlayerView`.
    /// Owned by `SampleBufferRenderer`; surfaced here so the engine can
    /// hand it to the view via the same `attach(_ layer: CALayer)` entry
    /// point it uses for `AVPlayerLayer`.
    var displayLayer: AVSampleBufferDisplayLayer { renderer.displayLayer }

    /// SW-PiP Phase C: engine-fed cue mirror + PiP gate for the renderer's frame compositor.
    func updateSubtitleCompositor(cues: [SubtitleCue], enabled: Bool) {
        renderer.subtitleCompositor.update(cues: cues, enabled: enabled)
    }

    // MARK: - Internals

    private let renderer: SampleBufferRenderer
    /// Swapped per codec at load(): SoftwareVideoDecoder for AV1/VP9, HardwareVideoDecoder for HEVC. Protocol keeps the demux loop codec-agnostic.
    private var videoDecoder: any VideoDecodingPipeline
    private var audioDecoder: AudioDecoder?
    private var audioOutput: AudioOutput?
    private var demuxer: Demuxer?
    private var vodPacketReadAhead: SoftwarePacketReadAhead?

    /// The same public buffered-position axis as the live and native hosts, but backed by
    /// actual compressed A/V packet coverage. nil when no continuous cache span contains the clock.
    var cachedVODSessionTime: Double? {
        guard let frontier = vodPacketReadAhead?.snapshot.frontier else { return nil }
        return max(0, frontier - max(0, clockSessionZero))
    }

    var cachedVODBytes: Int64? { vodPacketReadAhead.map { Int64($0.snapshot.residentBytes) } }
    var vodPacketCacheSnapshot: SoftwarePacketReadAhead.Snapshot? { vodPacketReadAhead?.snapshot }

    private let demuxQueue = DispatchQueue(label: "engine.sw.demux", qos: .userInitiated)

    /// #254: every demuxer reposition runs here, never on the main actor. See
    /// `Demuxer.seekBounded(to:anchorStreamIndex:timeout:on:isSuperseded:)` for why the main actor is
    /// the wrong thread for it. Serial and separate from `demuxQueue`, whose block never returns.
    private let seekQueue = DispatchQueue(label: "engine.sw.seek", qos: .userInitiated)

    /// Read-deadline budget for a reposition (#254). Matches the side reader's positioning budget.
    private static let seekBudgetSeconds: TimeInterval = 8.0

    /// True while a reposition is awaiting `seekQueue`. Gates the 0.25 s time tick: the synchronizer
    /// still carries the pre-seek anchor, so an ungated tick would walk the OLD position forward for
    /// the length of the reposition and then snap to the target.
    private var seekInFlight = false

    /// Transport intent for the reposition currently in flight (#292). `seek` clears `isPlaying` to park
    /// the loops, so a seek entering while another is suspended in its off-main reposition (#254) would
    /// read that cleared flag as "was paused" and land a playing session at rate 0. Rewritten by
    /// `pause()` / `play()` so an explicit transport call inside the window still wins.
    private var inFlightSeekResumeIntent = false

    /// Guards isPlaying/stopRequested across demux thread reads and main-actor writes.
    private let flagsLock = NSLock()
    nonisolated(unsafe) private var _isPlaying: Bool = false
    nonisolated(unsafe) private var _stopRequested: Bool = false

    /// Sodalite#104 round 4: a pause arrived before the first frame, so the loops keep reading until one
    /// is in (`PausedFirstFrame`). Set by `pause()`, cleared by `play()`, `stop()` and that frame.
    nonisolated private var pausedBeforeFirstFrame: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _pausedBeforeFirstFrame }
        set { flagsLock.lock(); _pausedBeforeFirstFrame = newValue; flagsLock.unlock() }
    }
    nonisolated(unsafe) private var _pausedBeforeFirstFrame = false

    /// Clears the flag and says whether it was set, in one step, so the first frame and a `play()` cannot
    /// both act on it.
    nonisolated private func takePausedBeforeFirstFrame() -> Bool {
        flagsLock.lock(); defer { flagsLock.unlock() }
        let was = _pausedBeforeFirstFrame
        _pausedBeforeFirstFrame = false
        return was
    }

    /// Condition the demux thread waits on while paused so it doesn't
    /// busy-loop reading packets that would just stack up.
    private let demuxCondition = NSCondition()

    private var videoStreamIndex: Int32 = -1
    /// The audio stream this host actually serves, or -1 when it serves none: the source had no audio
    /// track, or `AudioDecoder.open` refused it and the session went video-only (AE#462). Read by the
    /// engine for the published decoder label, which used to be built from the PROBE and therefore
    /// named a decoder that never opened. Also the host's own resolve, which is not always the
    /// engine's pick (#133 live-TS by-type fallback).
    private(set) var audioStreamIndex: Int32 = -1

    /// AE#464: the host's audio presentation offset in seconds, positive = audio later. Kept here as
    /// well as on the decoder so a decoder opened later in the session (an audio-track switch, a
    /// rebuild) starts out carrying it rather than at zero.
    private(set) var audioDelaySeconds: Double = 0

    /// AE#462: how this host delivers audio, as a typed fact for the engine's published
    /// `audioDelivery`. Set once the audio decoder has been given its chance.
    private(set) var audioDelivery: AudioDelivery = .none

    private var videoTimeBaseSeconds: Double = 0
    private var audioTimeBaseSeconds: Double = 0

    // MARK: - Live / DVR

    /// #544: decodes a scrub still out of `dvrRing`. Built beside the playback decoder so it never
    /// holds a stream pointer of its own, and driven only from `stillQueue`, off the demux and feed
    /// loops, so a preview frame never costs playback a packet.
    private var stillExtractor: SoftwareStillExtractor?
    private let stillQueue = DispatchQueue(label: "engine.sw.still", qos: .userInitiated)
    private let stillRequests = StillRequestCounter()

    /// Newest-wins ticket for still requests. A held scrub asks about sixteen times a second and the
    /// queue is serial, so without a ticket the queue takes work faster than it retires it: the card
    /// falls further behind the thumb with every request, and the decoding outlives the commit.
    final class StillRequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            value &+= 1
            return value
        }

        var latest: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Disk-spooled DVR rewind ring; non-nil for live sessions with dvrWindowSeconds set. Demux-thread appended (internally locked).
    nonisolated(unsafe) private var dvrRing: PacketRingBuffer?

    /// AE#560: the live recording sink, read on the demux thread for every source packet.
    nonisolated(unsafe) fileprivate var recordingSink: LiveRecordingSink?
    fileprivate let recordingSinkLock = NSLock()

    /// True for a live session. Gates ring fill, edge publishing, and the
    /// live-DVR seek branch so the non-live SW path is untouched.
    private var isLive: Bool = false

    /// First packet's PTS (seconds); SW timeline is "seconds since first frame" = newestPts - sessionStartPts. nan until first packet.
    nonisolated(unsafe) private var sessionStartPts: Double = .nan

    nonisolated(unsafe) private var newestSourcePts: Double = .nan

    /// Guards `sessionStartPts` / `newestSourcePts` against the demux
    /// thread writing while the main-actor time tick reads them.
    private let liveEdgeLock = NSLock()

    /// #303: seconds of decoded video queued ahead of the clock, nil before the first frame. This is
    /// the cushion an IO hiccup eats into, and the reason a blocked read reaches the picture here
    /// while the native path swallows the same event. Distinct from `bufferedSessionTime`, which is
    /// the DEMUXED frontier and is only fed on live sessions.
    var displayCushionSeconds: Double? {
        SoftwareBufferFrontier.cushionSeconds(newestEnqueuedPts: renderer.newestEnqueuedPtsSeconds,
                                              sourceClock: sourceClockSeconds)
    }

    /// #311: the timebase the master clock runs on, or nil before the session owns one. This is the
    /// `AVSampleBufferRenderSynchronizer`'s timebase, and it is created unconditionally, including for
    /// a source with no audio track, so on this path it exists for the whole session rather than only
    /// when something is playing.
    ///
    /// It reads the SOURCE axis, the same axis as `SoftwareVideoFrameTime.presentation` and as the
    /// subtitle cues, so an overlay paced against it needs no conversion.
    var presentationTimebase: CMTimebase? {
        audioOutput?.synchronizer.timebase
    }

    /// #311: forwarded to the renderer, which is where a frame is actually handed over. Set through
    /// the host rather than on the renderer directly so the engine has one place to re-arm it across
    /// a `load()`, the same shape the native path uses for its own observer.
    func setVideoFrameTimeObserver(_ observer: SoftwareVideoFrameTimeObserver?) {
        renderer.setFrameEnqueuedObserver(observer)
    }

    /// #303: the renderer's own view of what reached the display. Async because the AVFoundation
    /// accessor is; the memprobe already runs in an async context, so it is read there rather than
    /// cached, and the line never carries a stale snapshot.
    func loadRenderMetrics() async -> SampleBufferRenderer.RenderMetrics? {
        await renderer.loadRenderMetrics()
    }

    /// SW path's buffered frontier (AetherEngine#54): newest demuxed source PTS in session time. Published as clock.bufferedPosition.
    nonisolated var bufferedSessionTime: Double {
        liveEdgeLock.lock()
        defer { liveEdgeLock.unlock() }
        guard sessionStartPts.isFinite, newestSourcePts.isFinite else { return 0 }
        return max(0, newestSourcePts - sessionStartPts)
    }

    // MARK: - Live reader/feeder split (DVR sessions)
    //
    // DVR live sessions: reader (demuxQueue) fills ring regardless of play/pause; feeder (feedQueue) decodes from ring cursor with renderer back-pressure.
    // Pause = timeshift (reader keeps filling); DVR rewind = cursor move. Replaces synchronous whole-tail replay (multi-second UI freeze, queue overflow).
    // Live-only (no ring): combined loop; pause parks the loop.

    /// Background queue for the live feeder loop.
    private let feedQueue = DispatchQueue(label: "engine.sw.feed", qos: .userInitiated)

    /// Guards `_feedCursor` / `_sourceEnded`.
    private let feedLock = NSLock()
    nonisolated(unsafe) private var _feedCursor: Int = 0
    nonisolated(unsafe) private var _sourceEnded = false

    /// Audio look-ahead pump cursor (#107 audio chopping): the feeder advances it ahead of
    /// `_feedCursor`, seek paths reset it alongside `setFeedCursor`.
    private let audioLookahead = AudioLookaheadState()

    nonisolated private func readFeedCursor() -> Int {
        feedLock.lock(); defer { feedLock.unlock() }
        return _feedCursor
    }

    /// Compare-and-advance: only advance when the cursor is still at
    /// `old`, so a concurrent DVR seek (which repositions the cursor)
    /// is never overwritten by the feeder's post-decode increment.
    nonisolated private func advanceFeedCursor(from old: Int) {
        feedLock.lock()
        if _feedCursor == old { _feedCursor = old + 1 }
        feedLock.unlock()
    }

    nonisolated private func setFeedCursor(_ value: Int) {
        feedLock.lock()
        _feedCursor = value
        feedLock.unlock()
        audioLookahead.reset(to: value)
        demuxCondition.lock()
        demuxCondition.broadcast()
        demuxCondition.unlock()
    }

    nonisolated private func clampFeedCursor(from old: Int, to first: Int) {
        feedLock.lock()
        if _feedCursor == old { _feedCursor = first }
        feedLock.unlock()
    }

    nonisolated private var sourceEnded: Bool {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _sourceEnded }
        set { feedLock.lock(); _sourceEnded = newValue; feedLock.unlock() }
    }

    nonisolated private func resetFeederState() {
        feedLock.lock()
        _feedCursor = 0
        _sourceEnded = false
        _clockArmed = false
        _clockSessionZero = 0
        feedLock.unlock()
        audioLookahead.reset(to: 0)
    }

    /// Whether the synchronizer clock has been anchored this session. Shared with seek paths so a DVR seek before feeder arming is not overwritten by a late re-arm.
    nonisolated(unsafe) private var _clockArmed = false
    nonisolated private var clockArmed: Bool {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _clockArmed }
        set { feedLock.lock(); _clockArmed = newValue; feedLock.unlock() }
    }

    /// Session-zero offset for non-live sources whose first decoded sample deviated from
    /// the load anchor (mid-stream-joined TS, #107): raw clock minus this is the published
    /// position. 0 for zero-based sources and aligned resumes. Written once by the demux
    /// thread at clock arming, read by the main-actor time tick.
    nonisolated(unsafe) private var _clockSessionZero: Double = 0
    nonisolated private var clockSessionZero: Double {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _clockSessionZero }
        set { feedLock.lock(); _clockSessionZero = newValue; feedLock.unlock() }
    }

    /// Bumped at every seek; demux loop re-checks around blocking readPacket to discard stale pre-seek packets that would clear the skip threshold (visible fast-forward burst).
    nonisolated(unsafe) private var _seekGeneration: UInt64 = 0
    nonisolated private var seekGeneration: UInt64 {
        feedLock.lock(); defer { feedLock.unlock() }; return _seekGeneration
    }
    nonisolated private func bumpSeekGeneration() {
        feedLock.lock(); _seekGeneration &+= 1; feedLock.unlock()
    }

    /// AE#491 round 2: the generation whose seek is FINISHED, meaning the source stands at that
    /// target and the clock has been re-anchored there. The gap to `_seekGeneration` is the seek
    /// window; see `SeekWindow` for what a packet read inside it does to the frontier and to the
    /// audio lead.
    nonisolated(unsafe) private var _settledSeekGeneration: UInt64 = 0

    nonisolated var seekWindowOpen: Bool {
        feedLock.lock(); defer { feedLock.unlock() }
        return SeekWindow.isOpen(requested: _seekGeneration, settled: _settledSeekGeneration)
    }

    /// A single seek-state snapshot is needed for packet, EOF and error admission. Reading the
    /// generation and window separately can straddle a seek that opens and settles between them.
    nonisolated private func admitsRead(generation: UInt64) -> Bool {
        feedLock.lock()
        let requested = _seekGeneration
        let settled = _settledSeekGeneration
        feedLock.unlock()
        return SoftwareReadAdmission.admits(readGeneration: generation,
            requestedGeneration: requested, settledGeneration: settled, stopRequested: stopRequested)
    }

    nonisolated private func noteSeekSettled(_ generation: UInt64) {
        feedLock.lock()
        if SeekWindow.closes(settling: generation, live: _seekGeneration) {
            _settledSeekGeneration = generation
        }
        feedLock.unlock()
        demuxCondition.lock()
        demuxCondition.broadcast()
        demuxCondition.unlock()
    }

    /// AE#491: the generation the packet now in the decoder was read under. The decoder callback
    /// compares it against the live one, because a flush cannot reach a frame that is already
    /// inside the decoder: `videoDecoder.flush()` runs on the actor while the demux thread sits in
    /// `decode(packet:)`, and the hardware decoder answers on its own thread later still. A frame
    /// that comes out under a newer generation belongs to the position the seek left behind, and
    /// handing it over makes it the renderer's newest timestamp - the frame after it then reports
    /// the whole seek distance as one inter-frame interval.
    nonisolated(unsafe) private var _decodeGeneration: UInt64 = 0
    nonisolated private var decodeGeneration: UInt64 {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _decodeGeneration }
        set { feedLock.lock(); _decodeGeneration = newValue; feedLock.unlock() }
    }

    /// Set when pause() stopped the synchronizer; play() restores the rate (previously play() only flipped isPlaying, leaving the clock frozen).
    private var pausedByHost = false

    /// AE#374: end of media parks the clock exactly once. Both demux loops can reach `onEnd`, and the
    /// park is deferred by the queued audio tail, so the guard covers a second arrival mid-defer.
    private var didParkClockAtEnd = false

    /// Invoked on the main-actor time-update cadence with the current
    /// session-relative live edge (seconds since first frame) while live.
    /// Wired by the engine to `publishLiveWindow(edgeSessionTime:)`.
    var onLiveEdge: (@MainActor (Double) -> Void)?

    /// Session-relative live edge in seconds, or nil before the first
    /// packet. Read on the main actor by the time tick.
    private var liveEdgeSessionTime: Double? {
        liveEdgeLock.lock()
        defer { liveEdgeLock.unlock() }
        guard sessionStartPts.isFinite, newestSourcePts.isFinite else { return nil }
        return max(0, newestSourcePts - sessionStartPts)
    }

    private var timeTimer: AnyCancellable?

    // MARK: - Surface visibility (#298)

    /// Where a software session's frames end up on screen, or why they cannot.
    enum SurfaceVisibility: Equatable {
        case onScreen
        /// The display layer is in no view hierarchy: the host never bound a render surface.
        case notInViewHierarchy
        /// Attached, but the bound view never got a layout, so nothing can be visible.
        case zeroSized(width: Int, height: Int)
    }

    /// #298: a software session renders into `renderer.displayLayer`, which only reaches the screen
    /// once the host binds a surface (`AetherEngine.bind(view:)` / `AetherPlayerSurface`). A host that
    /// presents an AVPlayerViewController instead gets audio, a completely healthy engine log, and no
    /// picture, because this path has no AVPlayerItem for AVKit to show (its own spinner then sits
    /// there forever). Neither condition left a trace before, so the report reads as a renderer stall.
    /// "Never bound" wins over the size: an unbound layer is usually zero-sized as well, and the bind
    /// is the actionable half.
    nonisolated static func assessSurface(hasSuperlayer: Bool, size: CGSize) -> SurfaceVisibility {
        guard hasSuperlayer else { return .notInViewHierarchy }
        guard size.width > 0, size.height > 0 else {
            return .zeroSized(width: Int(size.width), height: Int(size.height))
        }
        return .onScreen
    }

    /// Ticks (0.25 s each) the surface check waits after the first enqueued frame. A host binding its
    /// view during load, and the first layout pass after that, both land well inside this.
    private static let surfaceCheckTicks = 8

    private var surfaceCheckTicksSeen = 0
    private var surfaceChecked = false

    /// Runs once per session, ~2 s after frames start flowing. Reads CALayer state, so main actor only.
    private func checkSurfaceVisibilityIfDue() {
        guard !surfaceChecked, !backgroundAudioOnly, framesEnqueued > 0 else { return }
        surfaceCheckTicksSeen += 1
        guard surfaceCheckTicksSeen >= Self.surfaceCheckTicks else { return }
        surfaceChecked = true

        let layer = renderer.displayLayer
        switch Self.assessSurface(hasSuperlayer: layer.superlayer != nil, size: layer.bounds.size) {
        case .onScreen:
            return
        case .notInViewHierarchy:
            EngineLog.emit(
                "[SWHost] \(framesEnqueued) frames decoded into a display layer that is in no view "
                + "hierarchy: the host never bound a render surface (AetherEngine.bind(view:) / "
                + "AetherPlayerSurface). The software path renders into that layer, not through "
                + "AVPlayerViewController, so audio plays and no picture can appear",
                category: .swPlayback
            )
        case .zeroSized(let width, let height):
            EngineLog.emit(
                "[SWHost] display layer is bound but sized \(width)x\(height) after "
                + "\(framesEnqueued) frames: the bound view has no layout, so no frame can be visible",
                category: .swPlayback
            )
        }
    }

    /// #315: publish the renderer layer's own `readyForDisplay` as `isVideoReadyForDisplay`.
    /// AVFoundation posts a notification for it rather than supporting KVO, and it arrived in
    /// tvOS/iOS 17.4, macOS 14.4 and visionOS 1.1. Only visionOS still has a floor below that (1.0).
    /// Where it is missing the fallback is the first frame handed to the renderer
    /// (`disarmedFallbackFirstFrame`), which is one hop earlier than presentation and is documented as
    /// such on the public property.
    ///
    /// #344: visionOS has to be named. Falling through to `*` resolves it to the package's declared
    /// visionOS floor, which is 1.0, and that is a compile error rather than a runtime fallback.
    private func armReadyForDisplayObserver() {
        disarmReadyForDisplayObserver()
        guard #available(visionOS 1.1, *) else { return }
        let layer = renderer.displayLayer
        readyForDisplayObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
            object: layer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let ready = self.renderer.displayLayer.isReadyForDisplay
                guard ready != self.isVideoReadyForDisplay else { return }
                EngineLog.emit(
                    "[SWHost] layer.isReadyForDisplay=\(ready) after \(self.framesEnqueued) frames",
                    category: .swPlayback
                )
                self.isVideoReadyForDisplay = ready
            }
        }
    }

    private func disarmReadyForDisplayObserver() {
        if let readyForDisplayObserver {
            NotificationCenter.default.removeObserver(readyForDisplayObserver)
            self.readyForDisplayObserver = nil
        }
    }

    /// #315 fallback below visionOS 1.1, the one floor that predates `readyForDisplay` on the layer,
    /// so the first frame the decoder hands the renderer is the closest observable. Called off-main.
    /// Mirrors the observer's list exactly: a platform named there and not here would get neither the
    /// notification nor the fallback, so it would never publish readiness at all.
    nonisolated private func noteFirstFrameEnqueuedForDisplayFallback() {
        guard #unavailable(visionOS 1.1) else { return }
        Task { @MainActor [weak self] in self?.isVideoReadyForDisplay = true }
    }

    /// Caching the chosen rate so resume() restores the right speed after a pause without the
    /// host needing to know its history. Lock-guarded: the demux/feeder threads read it at clock
    /// arming so a host rate change between load and arm is not lost (#107).
    nonisolated(unsafe) private var _lastRate: Float = 1.0
    nonisolated private var lastRate: Float {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _lastRate }
        set { flagsLock.lock(); _lastRate = newValue; flagsLock.unlock() }
    }

    /// Start position captured so the demux loop aligns the synchronizer clock to the first sample's PTS; non-zero resume without this would cause "frozen frame, no audio".
    private var initialClockTime: CMTime = .zero

    nonisolated var isPlaying: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _isPlaying }
        set {
            flagsLock.lock(); _isPlaying = newValue; flagsLock.unlock()
            demuxCondition.lock()
            demuxCondition.broadcast()
            demuxCondition.unlock()
        }
    }

    nonisolated var stopRequested: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _stopRequested }
        set {
            flagsLock.lock(); _stopRequested = newValue; flagsLock.unlock()
            demuxCondition.lock()
            demuxCondition.broadcast()
            demuxCondition.unlock()
        }
    }

    /// Set by the engine on background-enter (iOS keepalive) and cleared on foreground. While true the
    /// combined demux loop drops video packets and paces on the audio renderer, so audio keeps playing in
    /// the background. The setter broadcasts the demux condition so a parked loop re-evaluates immediately.
    nonisolated(unsafe) private var _backgroundAudioOnly = false
    nonisolated var backgroundAudioOnly: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _backgroundAudioOnly }
        set {
            flagsLock.lock(); _backgroundAudioOnly = newValue; flagsLock.unlock()
            demuxCondition.lock()
            demuxCondition.broadcast()
            demuxCondition.unlock()
        }
    }

    // MARK: - Init

    init(videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.renderer = SampleBufferRenderer(videoGravity: videoGravity)
        // Default to the software decoder; load() swaps it for the
        // VT-backed one when the source's video codec is HEVC.
        self.videoDecoder = SoftwareVideoDecoder()
        armDisplaySizeObserver()
    }

    /// #353: the renderer settles the picture size on the decode thread, where it builds the format
    /// description; publish it on the main actor like every other mirror on this host. Armed in init
    /// rather than at load: the renderer is this host's own and lives exactly as long as it does.
    private func armDisplaySizeObserver() {
        renderer.setDisplaySizeObserver { [weak self] size in
            Task { @MainActor in
                guard let self, self.videoDisplaySize != size else { return }
                self.videoDisplaySize = size
                EngineLog.emit(
                    "[SWHost] picture settles at \(Int(size.width))x\(Int(size.height)) "
                    + "after \(self.framesEnqueued) frames",
                    category: .swPlayback
                )
            }
        }
    }

    // MARK: - Audio stream resolution (#133)

    /// AE#462: how this host's audio ended up, from the two facts that decide it. Silence has two
    /// causes here exactly as it does in the loopback cascade, and only one of them is a reason for
    /// a host to demote to a source that carries the audio differently.
    nonisolated static func audioDelivery(resolvedAudioIndex: Int32, decoderOpened: Bool) -> AudioDelivery {
        guard resolvedAudioIndex >= 0 else { return .noAudioInSource }
        return decoderOpened ? .decoded : .droppedNoPipeline
    }

    /// Resolve the audio stream index for a SW-host session. `av_find_best_stream` (`bestStream`)
    /// returns -1 for a live-MPEG-TS AAC stream whose codecpar the probe left empty
    /// (sample_rate/channels=0 because find_stream_info bailed before decoding a frame). On live
    /// sources fall back to the first audio-type stream (`firstByType`) so the AudioDecoder, which
    /// fills rate/channels from the first decoded frame, is reachable and the session is not silent.
    /// Mirrors HLSVideoEngine's native live-audio fallback; VOD keeps av_find_best_stream semantics.
    nonisolated static func resolveAudioStreamIndex(
        explicit: Int32?, bestStream: Int32, firstByType: Int32, isLive: Bool
    ) -> Int32 {
        if let explicit, explicit >= 0 { return explicit }
        if bestStream >= 0 { return bestStream }
        if isLive, firstByType >= 0 { return firstByType }
        return -1
    }

    /// True when a live-MPEG-TS AAC stream needs codecpar repair before the decoder opens: the probe
    /// left `sample_rate=0`. Mirrors HLSVideoEngine's native repair (fill 48 kHz stereo AAC-LC). VOD
    /// probes the whole file, so its codecpar is trusted and never repaired.
    nonisolated static func shouldRepairLiveAACCodecpar(
        isLive: Bool, codecID: AVCodecID, sampleRate: Int32
    ) -> Bool {
        isLive && codecID == AV_CODEC_ID_AAC && sampleRate == 0
    }

    /// Pure decision: whether the demux loop folds PTS discontinuities into one continuous
    /// timeline. Live always folds (encoder restarts mid-session). A forward-only non-live
    /// source folds too: sequential-origin IPTV timeshift archives are chunked recordings
    /// whose every chunk restarts at PTS ~0, FFmpeg's wrap correction turns that backward
    /// jump into a ~26.5 h forward one, and a non-seekable pb offers no seek-based recovery.
    /// Seekable VOD keeps its trusted container timeline untouched.
    nonisolated static func shouldFoldTimeline(isLive: Bool, sourceSeekable: Bool) -> Bool {
        isLive || !sourceSeekable
    }

    /// Pure decision: whether the combined demux loop stops pulling packets. It stops once
    /// decoded audio holds `AudioLookaheadPolicy.targetLeadSeconds` over the clock, which is
    /// what the parked-video FIFO exists to allow; the packet cap is only a memory backstop,
    /// and letting it do the pacing would make the effective lead a function of frame rate.
    /// Before the clock is armed the lead is meaningless (the clock reads garbage), so only
    /// the backstop applies: the loop has to keep reading to produce the buffers that arm it.
    nonisolated static func shouldHoldDemuxRead(
        parkedCount: Int,
        parkedCap: Int,
        clockArmed: Bool,
        lastAudioPts: Double,
        clockSeconds: Double
    ) -> Bool {
        if parkedCount >= parkedCap { return true }
        guard clockArmed, clockSeconds.isFinite else { return false }
        return AudioLookaheadPolicy.decide(
            clockArmed: true,
            preArmPacketsFed: 0,
            lastFedAudioPTS: lastAudioPts,
            clockSeconds: clockSeconds
        ) == .stop
    }

    // MARK: - Load

    func load(
        demuxer dem: Demuxer,
        startPosition: Double?,
        audioSourceStreamIndex: Int32?,
        isLive: Bool = false,
        dvrWindowSeconds: Double? = nil,
        forwardBufferSegments: Int? = nil
    ) async throws {
        self.demuxer = dem
        self.duration = dem.duration
        self.isLive = isLive

        guard dem.videoStreamIndex >= 0,
              let vStream = dem.stream(at: dem.videoStreamIndex) else {
            throw HostError.noVideoStream
        }
        self.videoStreamIndex = dem.videoStreamIndex
        let vtb = vStream.pointee.time_base
        self.videoTimeBaseSeconds = vtb.den > 0 ? Double(vtb.num) / Double(vtb.den) : 0
        // #315: armed once there is a video stream to display. A fresh host means a fresh layer, so
        // there is no carried-in picture to guard against here (the native path's problem).
        armReadyForDisplayObserver()

        // DVR ring scratch dir mirrors SegmentCache's <tmpdir>/aether-segments/<uuid> convention.
        if isLive, let window = dvrWindowSeconds {
            let baseDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("aether-segments", isDirectory: true)
            let scratch = baseDir.appendingPathComponent("dvr-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                self.dvrRing = try PacketRingBuffer(windowSeconds: window, scratch: scratch)
                EngineLog.emit("[SWHost] DVR ring armed window=\(String(format: "%.0f", window))s scratch=\(scratch.lastPathComponent)", category: .swPlayback)
            } catch {
                EngineLog.emit("[SWHost] DVR ring create failed (\(error)); live-only fallback", category: .swPlayback)
                self.dvrRing = nil
            }
        }

        // Resolve the audio stream up front so the session-start log and the decoder agree. #133:
        // live-TS AAC whose codecpar the probe left empty makes av_find_best_stream return -1; the
        // by-type fallback (live-only) is what keeps SW-routed live TS from coming up silent.
        let bestAudioIdx = dem.audioStreamIndex
        let resolvedAudioIdx = Self.resolveAudioStreamIndex(
            explicit: audioSourceStreamIndex,
            bestStream: bestAudioIdx,
            firstByType: dem.firstAudioStreamIndexByType,
            isLive: isLive
        )
        if audioSourceStreamIndex == nil, bestAudioIdx < 0, resolvedAudioIdx >= 0 {
            EngineLog.emit(
                "[SWHost] audio: av_find_best_stream found no usable audio "
                + "(live probe left empty codecpar?); falling back to first audio-type stream \(resolvedAudioIdx)",
                category: .swPlayback
            )
        }

        // Release-visible session-start log: SW-path black-screens were indistinguishable from "never dispatched" (DrHurt #4).
        let vCodecID = vStream.pointee.codecpar?.pointee.codec_id.rawValue ?? 0
        let aCodecID: UInt32 = resolvedAudioIdx >= 0
            ? (dem.stream(at: resolvedAudioIdx)?.pointee.codecpar?.pointee.codec_id.rawValue ?? 0)
            : 0
        EngineLog.emit(
            "[SWHost] session start: videoCodecID=\(vCodecID) "
            + "audioCodecID=\(aCodecID == 0 ? "none" : String(aCodecID)) "
            + "duration=\(String(format: "%.1f", dem.duration))s",
            category: .swPlayback
        )

        // HEVC -> VTDecompressionSession (HW) when VideoToolbox PROVABLY HW-decodes this exact format;
        // everything else -> libavcodec. Replace wholesale to prevent state bleed. #2: HardwareVideoDecoder
        // requires a HW decoder and has no software fallback, so an HEVC Rext stream on hardware without a
        // HW decoder must go to libavcodec. AE#461: so must every format the probe cannot classify (in-band
        // parameter sets, Annex-B extradata), which the routing gate reads as "keep native" but which
        // HardwareVideoDecoder, building from the hvcC alone, can never open.
        if let codecpar = vStream.pointee.codecpar,
           codecpar.pointee.codec_id == AV_CODEC_ID_HEVC,
           VTCapabilityProbe.hardwareDecodeVerdict(codecpar: codecpar).opensHardwareDecoder {
            videoDecoder.close()
            videoDecoder = HardwareVideoDecoder()
            EngineLog.emit(
                "[SWHost] selected HardwareVideoDecoder (VT HEVC) for codec_id=\(codecpar.pointee.codec_id.rawValue)",
                category: .swPlayback
            )
        } else if !(videoDecoder is SoftwareVideoDecoder) {
            videoDecoder.close()
            videoDecoder = SoftwareVideoDecoder()
            EngineLog.emit(
                "[SWHost] selected SoftwareVideoDecoder (libavcodec) for codec_id="
                + "\(vStream.pointee.codecpar?.pointee.codec_id.rawValue ?? 0)",
                category: .swPlayback
            )
        }

        // Flip display layer into HDR mode before frames arrive; without this preferredDynamicRange stays .standard and PQ/HLG renders desaturated.
        if let codecpar = vStream.pointee.codecpar {
            let trc = codecpar.pointee.color_trc
            let sourceIsHDR = trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67
            if sourceIsHDR {
                renderer.setHDROutput(true)
                EngineLog.emit(
                    "[SWHost] HDR mode ON on display layer (transfer=\(trc.rawValue))",
                    category: .swPlayback
                )
            }
        }

        // Applied here (not init) so it also covers a decoder replaced above.
        (videoDecoder as? SoftwareVideoDecoder)?.deinterlaceConfig = deinterlaceConfig

        try videoDecoder.open(stream: vStream) { [weak self] pixelBuffer, pts, hdr10PlusData in
            guard let self else { return }
            // AE#491: a frame decoded from a pre-seek packet is not late, it is from somewhere else.
            guard self.decodeGeneration == self.seekGeneration else { return }
            // Decoder callback is off-main; SampleBufferRenderer is internally locked.
            self.renderer.enqueue(pixelBuffer: pixelBuffer, pts: pts, hdr10PlusData: hdr10PlusData)
            // First-frame milestone: demux reached a video packet + decoder produced a pixel buffer.
            if self.bumpFramesEnqueued() == 0 {
                self.noteFirstFrameEnqueuedForDisplayFallback()
                if self.takePausedBeforeFirstFrame() {
                    // The reorder buffer holds four frames before it hands one to the layer, and the
                    // loops park again from here: without the drain the frame never leaves it.
                    self.renderer.drainReorderBuffer()
                    self.presentFirstFrameUnderPause(pts: pts.seconds, generation: self.decodeGeneration)
                }
                let pfType = CVPixelBufferGetPixelFormatType(pixelBuffer)
                EngineLog.emit(
                    "[SWHost] first video frame enqueued: "
                    + "pixfmt=0x\(String(pfType, radix: 16)) "
                    + "size=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) "
                    + "pts=\(String(format: "%.3f", pts.seconds))s",
                    category: .swPlayback
                )
            }
        }
        if isLive, dvrRing != nil {
            do {
                stillExtractor = try SoftwareStillExtractor(
                    stream: vStream,
                    videoStreamIndex: videoStreamIndex,
                    timeBaseSeconds: videoTimeBaseSeconds,
                    deinterlace: deinterlaceConfig)
            } catch {
                // A session without scrub stills still plays; the preview just stays empty.
                EngineLog.emit("[SWHost] #544 still extractor unavailable (\(error))", category: .swPlayback)
                stillExtractor = nil
            }
        }

        videoDecoder.onFirstHDR10PlusDetected = { [weak self] in
            self?.onFirstHDR10PlusDetected?()
        }
        videoDecoder.onA53Captions = { [weak self] triplets, pts in
            self?.onA53Captions?(triplets, pts)
        }

        if resolvedAudioIdx >= 0, let aStream = dem.stream(at: resolvedAudioIdx),
           let acp = aStream.pointee.codecpar {
            // Live AAC the probe never filled (sample_rate=0): assume 48 kHz stereo AAC-LC so channel
            // negotiation and the published track are correct. The AudioDecoder otherwise recovers
            // rate/channels from the first decoded frame, but not before the session reports zero.
            if Self.shouldRepairLiveAACCodecpar(
                isLive: isLive, codecID: acp.pointee.codec_id, sampleRate: acp.pointee.sample_rate) {
                acp.pointee.sample_rate = 48000
                if acp.pointee.ch_layout.nb_channels <= 0 {
                    av_channel_layout_default(&acp.pointee.ch_layout, 2)
                }
                if acp.pointee.profile < 0 {
                    acp.pointee.profile = 1  // FF_PROFILE_AAC_LOW
                }
                EngineLog.emit(
                    "[SWHost] audio: live AAC had no codec parameters from the probe; "
                    + "assuming 48 kHz stereo AAC-LC",
                    category: .swPlayback
                )
            }
            let aDec = AudioDecoder()
            do {
                // AE#462 harness (TEST-ONLY): same forced drop the loopback cascade honors.
                if AetherEngine.forceAudioPipelineFailureForTesting {
                    throw NSError(domain: "AetherEngineTestHook", code: -462, userInfo: [
                        NSLocalizedDescriptionKey: "audio pipeline forced to fail (TEST-ONLY)"])
                }
                try aDec.open(stream: aStream)
                self.audioDecoder = aDec
                self.audioStreamIndex = resolvedAudioIdx
                let atb = aStream.pointee.time_base
                self.audioTimeBaseSeconds = atb.den > 0 ? Double(atb.num) / Double(atb.den) : 0
            } catch {
                EngineLog.emit("[SWHost] audio open failed (\(error)); video-only", category: .swPlayback)
                self.audioStreamIndex = -1
            }
        }
        // AE#462: after the decoder has had its chance, whichever way the block above left it, so a
        // stream present but unusable (no codecpar) classifies as the drop it is rather than as a
        // source without audio.
        self.audioDelivery = Self.audioDelivery(resolvedAudioIndex: resolvedAudioIdx,
                                                decoderOpened: self.audioDecoder != nil)
        // #112 rework: capture embedded subtitle stream indices + time bases for the demux
        // loop's subtitle tap dispatch.
        var subIndices: Set<Int32> = []
        var subTimeBases: [Int32: AVRational] = [:]
        for info in dem.subtitleTrackInfos() {
            let idx = Int32(info.id)
            subIndices.insert(idx)
            subTimeBases[idx] = dem.stream(at: idx)?.pointee.time_base ?? AVRational(num: 1, den: 1000)
        }
        self.subtitleStreamIndices = subIndices
        self.subtitleStreamTimeBases = subTimeBases
        // #112: split-PES PGS streams (MPEG-TS) need display-set reassembly in the packet
        // store; the tap sink consults this per packet.
        self.splitDisplaySetSubtitleStreamIndices = dem.splitDisplaySetSubtitleStreamIndices()

        // AudioOutput owns the AVSampleBufferRenderSynchronizer (master clock). Created unconditionally: video-only previously got no clock (frozen frame, currentTime=0). Layer attached in play() after the engine hangs it in the view hierarchy (attaching free-floating fails FigVideoQueueRemote -12080 on tvOS 26+).
        self.audioOutput = AudioOutput()
        self.audioOutput?.setPresentationOffset(seconds: audioDelaySeconds)   // AE#464

        // Reset the live feeder state for the new session.
        resetFeederState()

        if let start = startPosition, start > 0 {
            // #254: same off-main, deadline-bounded reposition the transport seek uses. A resume into a
            // remote source that has to scan for its landing would otherwise block the main thread here.
            _ = await dem.seekBounded(to: start, timeout: Self.seekBudgetSeconds, on: seekQueue)
            // This is load()'s only suspension point, so it is also the only place a stop() can land
            // mid-load. Arming the clock and publishing isReady on a session already torn down would
            // hand the engine a host it has stopped.
            guard !stopRequested else { return }
            // Mirror seek() skip-PTS + clock alignment so demux drops pre-keyframe frames and synchronizer starts at the resume offset.
            let startTime = CMTime(seconds: start, preferredTimescale: 90000)
            videoDecoder.skipUntilPTS = startTime
            renderer.setSkipThreshold(startTime)
            initialClockTime = startTime
            currentTime = start
        } else {
            initialClockTime = .zero
        }

        // A local path is left on the direct loop: the spool exists to avoid a second trip to a
        // SOURCE, and re-reading a file is a page-cache hit. Measured on a file:// session, the
        // cache wrote 14 MB of temporary chunks in 25 s (the source bitrate) for a seek that would
        // have cost nothing anyway.
        if !isLive, dem.isSourceSeekable, !dem.readsSourceDirectly {
            let video = SoftwarePacketReadAhead.Stream(index: videoStreamIndex,
                                                       numerator: vtb.num, denominator: vtb.den)
            let audio: SoftwarePacketReadAhead.Stream? = audioStreamIndex >= 0
                ? dem.stream(at: audioStreamIndex).map {
                    .init(index: audioStreamIndex, numerator: $0.pointee.time_base.num,
                          denominator: $0.pointee.time_base.den)
                } : nil
            let initialSourceClock = initialClockTime.seconds
            let videoReorderDepth: Int? = vCodecID == AV_CODEC_ID_H264.rawValue ? 32 : nil
            let cacheResult = await Task.detached(priority: .utility) { () throws -> SoftwarePacketReadAhead? in
                let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                let available = (try? temp.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
                    .volumeAvailableCapacity.map(Int64.init)
                let segments = HLSVideoEngine.clampedForwardWindow(forwardBufferSegments)
                let bytes = HLSVideoEngine.sessionRetentionBudgetBytes(
                    volumeAvailableBytes: available,
                    capRelaxed: HLSVideoEngine.retentionCapRelaxed(forwardWindowSegments: segments))
                guard bytes > 0 else { return Optional<SoftwarePacketReadAhead>.none }
                let fifo = try SoftwarePacketDiskFIFO(
                    chunkTargetBytes: min(4 << 20, max(8, bytes)), retainConsumed: true)
                return SoftwarePacketReadAhead(
                    video: video, audio: audio, byteBudget: bytes,
                    forwardSeconds: Double(segments) * 4,
                    initialSourceClock: initialSourceClock, fifo: fifo,
                    videoReorderDepth: videoReorderDepth
                ) { isCurrent in
                    guard let packet = try dem.readPacket(isCurrent: isCurrent) else { return nil }
                    defer { av_packet_unref(packet); av_packet_free_safe(packet) }
                    return try SoftwareStoredPacket(copying: packet)
                }
            }.result
            let readAhead: SoftwarePacketReadAhead?
            switch cacheResult {
            case .success(let cache): readAhead = cache
            case .failure:
                // A cache-directory failure must not stop a source that the old direct loop can
                // still play. Runtime spool corruption is explicit, never silently skipped.
                EngineLog.emit("[SWHost] packet cache unavailable; retaining direct playback", category: .swPlayback)
                readAhead = nil
            }
            guard !stopRequested else { readAhead?.close(); return }
            vodPacketReadAhead = readAhead
            readAhead?.start()
        }

        startTimeUpdates()
        isReady = true
    }

    // MARK: - Transport

    func play() {
        // Resume after pause(): gate on clockArmed, not demuxLoopStarted. A rate change on the
        // un-anchored synchronizer (no media at its clock time yet) wedges the delayed-rate-change
        // machinery permanently frozen; the arming seekClock applies the current lastRate (#107).
        switch RendererClockResume.onPlay(
            hostPaused: pausedByHost,
            clockArmed: clockArmed,
            synchronizerRate: audioOutput?.rate ?? 0,
            rebuffering: demuxDiag.snapshot.rebuffering,
            parkedAtEndOfMedia: didParkClockAtEnd
        ) {
        case .resumeHostPause:
            pausedByHost = false
            _ = takePausedBeforeFirstFrame()
            if clockArmed {
                audioOutput?.setRate(lastRate)
            }
        case .restartStalledClock:
            restartStalledClock()
        case .none:
            break
        }
        if !demuxLoopStarted, let aOut = audioOutput {
            aOut.attachVideoRenderer(renderer.videoRenderer)
        }
        if !demuxLoopStarted {
            demuxLoopStarted = true
            startDemuxLoop()
        }
        // Cold start: demux loop arms the clock on first decoded audio sample; don't eager-start.
        rate = lastRate
        isPlaying = true
        inFlightSeekResumeIntent = true
    }

    private var demuxLoopStarted: Bool = false

    /// #95 audio tap: mirrors every decoded audio CMSampleBuffer to the tap (nil = tap off).
    /// Set/cleared on the main actor by AetherEngine+AudioTap; read per packet on the demux and
    /// feeder threads (same unsynchronized-flag pattern as `_isPlaying`; worst case one buffer
    /// reaches a just-removed sink).
    nonisolated(unsafe) var audioTapSink: (@Sendable (CMSampleBuffer) -> Void)?

    /// #112 rework subtitle tap: the demux loop hands every embedded subtitle packet to this
    /// sink (nil = tap off), which copies the payload into the session's SubtitlePacketStore.
    /// Same unsynchronized-flag pattern as `audioTapSink`; the sink copies synchronously, so
    /// the packet pointer never escapes the demux thread. The trailing Bool marks packets of
    /// split-PES PGS streams (MPEG-TS) that need display-set reassembly in the store.
    nonisolated(unsafe) var subtitleTapSink: (@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational, Bool) -> Void)?

    /// #112 rework: embedded subtitle stream indices + time bases, captured at load before the
    /// demux loop starts (the SW host applies no stream discard, so these packets already flow).
    private(set) var subtitleStreamIndices: Set<Int32> = []
    private(set) var subtitleStreamTimeBases: [Int32: AVRational] = [:]
    /// #112: streams whose PGS display sets arrive split across PES packets (MPEG-TS) and need
    /// reassembly in the packet store. Captured at load, read by the tap sink per packet.
    private(set) var splitDisplaySetSubtitleStreamIndices: Set<Int32> = []

    /// Host's ASS markup preference for overlay decoders (mirrors the HLS session flag).
    var preserveASSMarkupForSubtitleTap = false
    var teletextPageForSubtitleTap: Int? = nil
    var deinterlaceConfig = DeinterlaceConfig()

    /// #112 rework: build an overlay decoder for any embedded subtitle stream, seeded from the
    /// session's video dims like the HLS tap routes. The drainer owns the returned decoder.
    func makeOverlayDecoder(streamIndex: Int32) -> EmbeddedSubtitleDecoder? {
        guard let dem = demuxer, let stream = dem.stream(at: streamIndex) else { return nil }
        let vpar = dem.stream(at: videoStreamIndex)?.pointee.codecpar
        let w = vpar?.pointee.width ?? 1920
        let h = vpar?.pointee.height ?? 1080
        return EmbeddedSubtitleDecoder(stream: stream,
                                       sourceVideoWidth: w > 0 ? w : 1920,
                                       sourceVideoHeight: h > 0 ? h : 1080,
                                       preserveASSMarkup: preserveASSMarkupForSubtitleTap,
                                       teletextPage: teletextPageForSubtitleTap)
    }

    #if DEBUG
    /// AE#549 drill: stop the master clock the way an interrupted audio session does, leaving
    /// `pausedByHost` alone. Nothing outside the drill may do this.
    func stallClockForTesting() -> Bool {
        guard let aOut = audioOutput, clockArmed else { return false }
        aOut.pause()
        return true
    }

    var clockRateForTesting: Float? { audioOutput?.rate }
    #endif

    /// AE#549: re-anchor a master clock that stopped without a pause of ours, where it stands.
    ///
    /// The one re-anchor this path can make: the demuxer is an audio lead ahead of the clock by now
    /// and the sources this happens to are the ones that cannot seek backwards, so moving the clock
    /// anywhere but onto itself would either skip content or ask for a rewind the source refuses.
    /// The rate and the flush count go in the line because they are what the next field log needs to
    /// separate a zeroed rate from a timebase that stalled under a deactivated audio session.
    private func restartStalledClock() {
        guard let aOut = audioOutput else { return }
        EngineLog.emit(
            "[SWHost] AE#549: the clock stopped without a pause of ours; restarting at "
            + "\(String(format: "%.3f", aOut.currentTimeSeconds))s rate=\(lastRate) "
            + "(was \(aOut.rate), renderer self-flushes=\(aOut.automaticFlushCount))",
            category: .swPlayback
        )
        aOut.seekClock(to: aOut.currentTime, rate: lastRate)
    }

    func pause() {
        // Un-anchored clock: only latch the pause; the loops park on isPlaying (#107).
        if clockArmed {
            audioOutput?.pause()
        }
        pausedByHost = true
        rate = 0
        if PausedFirstFrame.holdsForFirstFrame(loopsStarted: demuxLoopStarted, framesEnqueued: framesEnqueued),
           !stopRequested {
            pausedBeforeFirstFrame = true
            EngineLog.emit(
                "[SWHost] #104 paused before the first frame: the loops keep reading at a stopped clock until it presents",
                category: .swPlayback
            )
        }
        isPlaying = false
        inFlightSeekResumeIntent = false
    }

    /// Sodalite#104 round 4: the first frame of a session paused before it is in. Moves the stopped clock
    /// onto it where it stands before the frame (`PausedFirstFrame.presentationAnchor`). On the main actor,
    /// so a `play()` either runs first and finds the flag gone, or runs after and restarts this clock.
    nonisolated private func presentFirstFrameUnderPause(pts: Double, generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, !self.stopRequested, !self.isPlaying, self.pausedByHost,
                  generation == self.seekGeneration, let aOut = self.audioOutput else { return }
            let clock = aOut.currentTimeSeconds
            let anchor = PausedFirstFrame.presentationAnchor(
                framePTS: pts, clockArmed: self.clockArmed, clockSeconds: clock)
            if let anchor {
                aOut.seekClock(to: CMTime(seconds: anchor, preferredTimescale: 90000), rate: 0)
            }
            EngineLog.emit(
                "[SWHost] #104 first frame in under the pause: pts=\(String(format: "%.3f", pts))s "
                + "clock=\(String(format: "%.3f", clock))s"
                + (anchor != nil ? ", stopped clock moved onto the frame" : ", presented where the clock stands"),
                category: .swPlayback
            )
        }
    }

    /// AE#374: stop the master clock on the last sample instead of letting it free-run past the end.
    ///
    /// `.ended` is terminal, so nothing will consume the clock again, but the synchronizer used to keep
    /// its rate: `currentTime` then walked past `duration` without bound (measured: 20.13 s published on
    /// a 12.0 s source, against a native session that parks on 11.97 s and stays there). Deferred by the
    /// audio still queued ahead of the playhead, because parking the synchronizer stops its renderers
    /// too and an immediate park would cut that tail. `pausedByHost` stays false: the viewer did not
    /// pause this, the source ran out.
    private func parkClockAtEndOfMedia() {
        guard !didParkClockAtEnd else { return }
        didParkClockAtEnd = true
        guard clockArmed, let aOut = audioOutput else { return }
        let tail = SoftwareEndOfMediaClock.tailPlayoutSeconds(
            clockSeconds: aOut.currentTimeSeconds,
            lastAudioPts: demuxDiag.snapshot.lastAudioPts
        )
        guard tail > 0 else { return parkClockNow() }
        let generation = seekGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(tail * 1_000_000_000))
            guard let self, self.admitsRead(generation: generation) else { return }
            self.parkClockNow()
        }
    }

    private func parkClockNow() {
        guard !stopRequested, let aOut = audioOutput else { return }
        aOut.pause()
        rate = 0
        EngineLog.emit(
            "[SWHost] end of media: clock parked at "
            + "\(String(format: "%.3f", aOut.currentTimeSeconds))s",
            category: .swPlayback
        )
    }

    /// Background-enter (iOS keepalive): keep audio flowing, stop feeding video. The demux loop reads the flag.
    func enterBackgroundAudioOnly() {
        backgroundAudioOnly = true
    }

    /// Foreground return: resume video. Flush the video decoder + renderer (NOT audio) so video resyncs at the
    /// next keyframe; the synchronizer is already at the audio time, so the keyframe presents promptly. Order
    /// matters: while backgroundAudioOnly is still true the loop drops video and never touches videoDecoder /
    /// renderer, so flushing here from the main actor cannot race the demux queue. Clear the flag last.
    func exitBackgroundAudioOnly() {
        guard backgroundAudioOnly else { return }
        videoDecoder.flush()
        renderer.flush()
        backgroundAudioOnly = false
    }

    func setRate(_ newRate: Float) {
        // #436: zero is a pause, not a speed. `lastRate` is what the clock arms at and what a
        // rebuffer resumes at, so storing a zero there brings the session back frozen while it
        // reports itself playing. Park it the way pause() does and keep the last real speed.
        if newRate == 0 {
            pause()
            return
        }
        lastRate = newRate
        rate = newRate
        // Same rule as play(): never rate-change the un-anchored synchronizer. A host setRate
        // right after load(), before the demux/feeder loop armed the clock, wedged the
        // delayed-rate-change machinery and froze live sessions on the first frame; the arming
        // seekClock picks up lastRate instead (#107).
        if clockArmed {
            audioOutput?.setRate(newRate)
        }
    }

    /// AE#464: set the audio presentation offset. Positive delivers audio later relative to video.
    ///
    /// Only the stamp changes; nothing is flushed here. The samples already decoded (up to
    /// `AudioLookaheadPolicy.targetLeadSeconds` of them on the decoupled VOD arm) still carry the
    /// previous offset, so a caller that wants the change to be audible now re-anchors at the
    /// playhead afterwards. `AetherEngine.setAudioDelay` does exactly that.
    func setAudioDelay(_ seconds: Double) {
        audioDelaySeconds = seconds
        audioOutput?.setPresentationOffset(seconds: seconds)
    }

    func setResumeRate(_ rate: Float) {
        guard rate != 0 else { return }
        lastRate = rate
    }

    /// #254: the demuxer reposition is awaited off the main actor. It used to run inline here, and
    /// because `Demuxer.readPacket` holds the access lock across the whole `av_read_frame`, a seek
    /// issued while the demux loop sat in a slow remote read parked the main thread for the length of
    /// that read (App Hangs of 4.4 s and 5.2 s in the field on a WAN source).
    @discardableResult
    func seek(to seconds: Double) async -> Demuxer.RepositionOutcome {
        guard !stopRequested else { return .superseded }
        guard let dem = demuxer else { return .stalled }
        // Stop loop + bump generation to invalidate in-flight packets. Captured right after, so the
        // reposition can tell on `seekQueue` whether a newer seek has already taken over.
        bumpSeekGeneration()
        let generation = seekGeneration
        didReachEnd = false
        didParkClockAtEnd = false
        didEmitParkedDiag = false
        let packetSource = vodPacketReadAhead
        let cacheGeneration = packetSource?.beginSeek(to: seconds)
        // #292: inside another seek's window `isPlaying` is that seek's parked flag, not the transport's
        // intent. Inherit what it captured, and hand the same value on to whoever supersedes this one.
        let wasPlaying = SeekResumeIntent.resolve(isPlaying: isPlaying,
                                                  seekInFlight: seekInFlight,
                                                  inFlightIntent: inFlightSeekResumeIntent)
        inFlightSeekResumeIntent = wasPlaying
        isPlaying = false

        videoDecoder.flush()
        audioDecoder?.flush()
        // Hold the last frame through the seek (don't blank the display) so the viewer sees the previous
        // frame until the post-seek frame decodes, instead of a black flash (issue #90). Stop/teardown and
        // background-return still clear via the default.
        renderer.flush(removingDisplayedImage: false)
        audioOutput?.flush()
        // AE#479: the flush just emptied the queue the diag marker describes, and the pump learns of
        // this seek only at its next iteration, which a paused landing never reaches until play().
        demuxDiag.audioFlushed(generation: generation)

        // Live source is forward-only; DVR rewind reseeds decoders from the ring without touching the live demuxer's read position.
        if isLive, let ring = dvrRing {
            await seekLiveDVR(to: seconds, ring: ring, wasPlaying: wasPlaying)
            noteSeekSettled(generation)
            return .landed
        }

        // Publish the target and hold it across the await, so the scrub clock snaps the way the native
        // path's optimistic publish does instead of drifting on the stale synchronizer anchor.
        currentTime = seconds
        seekInFlight = true

        // AE#491: armed BEFORE the reposition, not after it. The flushes above emptied both queues,
        // but the reposition is awaited and the decode thread runs under it, so a frame from a
        // packet read before the seek used to meet a renderer with no threshold standing and was
        // taken. It then owns the newest handed-over timestamp, and the first real post-seek frame
        // reports the entire seek distance as one inter-frame interval.
        let targetTime = CMTime(seconds: seconds, preferredTimescale: 90000)
        videoDecoder.skipUntilPTS = targetTime
        renderer.setSkipThreshold(targetTime)

        var cacheHit = false
        if let packetSource, let cacheGeneration {
            let preparation = await Task.detached(priority: .userInitiated) {
                try packetSource.prepareSeek(cacheGeneration, to: seconds)
            }.result
            guard seekGeneration == generation, !stopRequested else { return .superseded }
            switch preparation {
            case .success(let hit):
                cacheHit = hit
                EngineLog.emit(
                    "[SWHost] packet cache seek generation=\(generation) "
                    + "result=\(hit ? "hit" : "miss") "
                    + "target_s=\(String(format: "%.3f", seconds)) "
                    + "resident_bytes=\(packetSource.snapshot.residentBytes)",
                    category: .swPlayback
                )
            case .failure(SoftwarePacketReadAhead.ReadError.interrupted),
                 .failure(SoftwarePacketReadAhead.ReadError.closed):
                return .superseded
            case .failure:
                // A corrupt/unreadable retained packet must not be silently skipped or treated as
                // a normal cache miss. Leave playback parked and publish an explicit failure.
                seekInFlight = false
                packetSource.close()
                noteSeekSettled(generation)
                EngineLog.emit("[SWHost] packet cache seek generation=\(generation) result=error",
                               category: .swPlayback)
                failure = PlaybackErrorInfo(kind: .softwarePipelineFailed,
                                            message: "Playback cache could not reposition.")
                return .stalled
            }
        }
        let outcome: Demuxer.RepositionOutcome
        if cacheHit {
            // The decode cursor now points at retained preroll. The source reader remains at its
            // existing frontier; seeking it too would duplicate or skip already retained packets.
            outcome = .landed
        } else {
            outcome = await dem.seekBounded(
                to: seconds, timeout: Self.seekBudgetSeconds, on: seekQueue,
                isSuperseded: { [weak self] in
                    self?.seekGeneration != generation || (self?.stopRequested ?? true)
                })
        }
        // A newer seek owns the state from here: it published its own target and clears the hold itself.
        // stop() can also land in the await now that this suspends, and re-arming the clock or flipping
        // isPlaying on a torn-down session would resurrect a loop that has already been told to quit.
        guard seekGeneration == generation, !stopRequested else { return .superseded }
        seekInFlight = false
        if outcome == .stalled {
            EngineLog.emit(
                "[SWHost] reposition to \(String(format: "%.2f", seconds))s did not complete within "
                + "\(String(format: "%.0f", Self.seekBudgetSeconds))s; read position is undefined",
                category: .swPlayback
            )
        }

        // Re-armed after the landing: a pre-seek frame PAST the target (a backward seek) clears the
        // threshold on its way through, and the generation guard on the decoder callback is what
        // stops it. Both stand, because neither alone covers both seek directions.
        videoDecoder.skipUntilPTS = targetTime
        renderer.setSkipThreshold(targetTime)

        currentTime = seconds

        // #292: the intent is read HERE, not from what this seek captured on entry. `pause()` / `play()`
        // during the reposition rewrite the stash, and a landing that ignored them either overrode the
        // pause (kept playing) or, from the other side, anchored at rate 0 under a running loop.
        if inFlightSeekResumeIntent {
            // Anchor clock at seek target: clock at .zero + PTS=seekTarget would stall rendering for seekTarget seconds (FigVideoQueueRemote -12080).
            audioOutput?.seekClock(to: targetTime, rate: lastRate)
            isPlaying = true
        } else {
            // Paused seek: anchor at target with rate 0 so play() resumes from the seek position (without this, scrubs freeze or drop all samples).
            audioOutput?.seekClock(to: targetTime, rate: 0)
            pausedByHost = true
        }
        // Arm now so the demux loop doesn't re-arm at stale initialClockTime (a pre-first-audio seek snapped back to session start without this).
        clockArmed = true
        // The source stands at the target and the clock is anchored on it: everything the loop
        // reads from here belongs to this position. Closing the window releases the loop.
        noteSeekSettled(generation)
        if let cacheGeneration { packetSource?.endSeek(cacheGeneration, sourceClock: seconds) }
        return outcome
    }

    /// #544: a scrub still for the live DVR window, decoded out of the packet ring.
    ///
    /// Takes the session axis, exactly as `seek` does, and converts it with the same `sessionStartPts`
    /// the rewind uses, so the still and the commit can never name two different moments. Runs on its
    /// own queue: the ring is internally locked and safe to read alongside the feeder, but decoding on
    /// the demux or feed loop would make the viewer pay for the preview in dropped packets.
    func liveScrubStill(atSessionSeconds seconds: Double, maxWidth: Int) async -> CGImage? {
        guard isLive, let ring = dvrRing, let extractor = stillExtractor else { return nil }
        let startPts: Double = {
            liveEdgeLock.lock()
            defer { liveEdgeLock.unlock() }
            return sessionStartPts.isFinite ? sessionStartPts : 0
        }()
        let targetSource = startPts + seconds
        let requests = stillRequests
        let ticket = requests.next()
        return await withCheckedContinuation { continuation in
            stillQueue.async {
                guard ticket == requests.latest else {
                    // Superseded while it waited: decoding it would only push the newer one later.
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: extractor.still(from: ring, targetPts: targetSource, maxWidth: maxWidth))
            }
        }
    }

    /// Live DVR rewind: reseeds decoder from the ring (source PTS axis; maps via sessionStartPts) without touching the live demuxer. After return, the loop reads new packets forward and plays back to live.
    private func seekLiveDVR(to targetSession: Double, ring: PacketRingBuffer, wasPlaying: Bool) async {
        let startPts: Double = {
            liveEdgeLock.lock(); defer { liveEdgeLock.unlock() }
            return sessionStartPts.isFinite ? sessionStartPts : 0
        }()
        let targetSource = startPts + targetSession

        let targetTime = CMTime(seconds: targetSource, preferredTimescale: 90000)
        videoDecoder.skipUntilPTS = targetTime
        renderer.setSkipThreshold(targetTime)

        // Anchor clock at target (paused scrubs: rate 0 so resume continues from seek position).
        if wasPlaying {
            audioOutput?.seekClock(to: targetTime, rate: lastRate)
        } else {
            audioOutput?.seekClock(to: targetTime, rate: 0)
            pausedByHost = true
        }
        clockArmed = true

        // Reposition cursor to the newest keyframe at or before target. If the target precedes every
        // retained keyframe, fall to the EARLIEST keyframe, not seqBounds.first, which can be a mid-GOP
        // leading entry before the ring's first eviction and would decode as garbage until the next keyframe.
        let seq = ring.seq(forKeyframeAtOrBefore: targetSource)
            ?? ring.firstKeyframeSeq()
            ?? ring.seqBounds.first
        setFeedCursor(seq)
        EngineLog.emit(
            "[SWHost] DVR rewind: targetSession=\(String(format: "%.2f", targetSession)) "
            + "targetSource=\(String(format: "%.2f", targetSource)) -> cursor seq=\(seq)",
            category: .swPlayback
        )

        currentTime = targetSession
        if wasPlaying {
            isPlaying = true
        }
    }

    /// Reconstruct AVPacket from ring entry, convert PTS from seconds back to stream time_base, and route to decoders. Returns true when audio buffers were enqueued (used for feeder clock arming).
    @discardableResult
    nonisolated private static func feedRingPacket(
        _ pkt: PacketRingBuffer.Packet,
        videoDecoder: any VideoDecodingPipeline,
        audioDecoder: AudioDecoder?,
        audioOutput: AudioOutput?,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        audioTapSink: (@Sendable (CMSampleBuffer) -> Void)?,
        noteDecodeGeneration: @Sendable () -> Void
    ) -> Bool {
        let tbSec = pkt.isVideo ? videoTimeBaseSeconds : audioTimeBaseSeconds
        guard tbSec > 0, !pkt.bytes.isEmpty else { return false }

        guard let p = trackedPacketAlloc() else { return false }
        var avPkt: UnsafeMutablePointer<AVPacket>? = p
        defer { trackedPacketFree(&avPkt) }

        if av_new_packet(p, Int32(pkt.bytes.count)) < 0 { return false }
        pkt.bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let dst = p.pointee.data {
                memcpy(dst, base, pkt.bytes.count)
            }
        }
        p.pointee.pts = Int64((pkt.pts / tbSec).rounded())
        p.pointee.dts = p.pointee.pts
        p.pointee.flags = pkt.isKeyframe ? AV_PKT_FLAG_KEY : 0
        p.pointee.stream_index = pkt.isVideo ? videoStreamIndex : audioStreamIndex

        if pkt.isVideo {
            noteDecodeGeneration()
            // AE#492: no epoch. This replays from the DVR ring after a reseed, so there is no batch
            // of packets decided on before a flush for one to invalidate.
            videoDecoder.decode(packet: p, epoch: nil)
            return false
        } else if let aDec = audioDecoder, let aOut = audioOutput {
            var enqueued = false
            for buf in aDec.decode(packet: p) {
                audioTapSink?(buf)   // #95: mirror before enqueue
                aOut.enqueue(sampleBuffer: buf)
                enqueued = true
            }
            return enqueued
        }
        return false
    }

    func stop() {
        stopRequested = true
        pausedBeforeFirstFrame = false
        isPlaying = false
        seekInFlight = false
        // A teardown inside a seek's window would otherwise leave it open on this instance.
        noteSeekSettled(seekGeneration)
        timeTimer?.cancel()
        timeTimer = nil
        vodPacketReadAhead?.close()
        vodPacketReadAhead = nil
        renderer.subtitleCompositor.reset()

        if let extractor = stillExtractor {
            stillExtractor = nil
            // Torn down ON the still queue, so a decode already in flight finishes against a codec
            // context that is still open rather than one freed out from under it.
            stillQueue.async { extractor.close() }
        }
        dvrRing?.close()
        dvrRing = nil
        liveEdgeLock.lock()
        sessionStartPts = .nan
        newestSourcePts = .nan
        liveEdgeLock.unlock()

        if let aOut = audioOutput {
            aOut.stop()
            aOut.detachVideoRenderer(renderer.videoRenderer)
        }
        audioOutput = nil
        audioDecoder?.close()
        audioDecoder = nil
        videoDecoder.close()
        renderer.flush()
        demuxer?.close()
        demuxer = nil

        isReady = false
        // #315: the session's picture goes with the session. `flush()` above already removed it.
        disarmReadyForDisplayObserver()
        isVideoReadyForDisplay = false
    }

    var volume: Float {
        get { audioOutput?.volume ?? 1.0 }
        set { audioOutput?.volume = newValue }
    }

    // MARK: - Demux loop

    /// Capture dependencies as locals so the demux loop runs off-main without re-entering the actor.
    private func startDemuxLoop() {
        guard let dem = demuxer else { return }
        let vDec = videoDecoder
        let vIdx = videoStreamIndex
        let aDec = audioDecoder
        let aOut = audioOutput
        let aIdx = audioStreamIndex
        let rndr = renderer
        let condition = demuxCondition
        let initialClock = initialClockTime
        // Read at arm time, not captured: a host setRate between load and arming must reach
        // the anchor (the eager synchronizer call it replaced is gated on clockArmed, #107).
        let currentRate: @Sendable () -> Float = { [weak self] in
            guard let self else { return 1.0 }
            return PausedFirstFrame.armingRate(lastRate: self.lastRate,
                                               pausedBeforeFirstFrame: self.pausedBeforeFirstFrame)
        }
        let ring = dvrRing
        let vTbSec = videoTimeBaseSeconds
        let aTbSec = audioTimeBaseSeconds
        let liveSession = isLive
        let noteEdge: @Sendable (Double) -> Void = { [weak self] ptsSec in
            guard let self, ptsSec.isFinite else { return }
            self.liveEdgeLock.lock()
            if self.sessionStartPts.isNaN { self.sessionStartPts = ptsSec }
            if self.newestSourcePts.isNaN || ptsSec > self.newestSourcePts {
                self.newestSourcePts = ptsSec
            }
            self.liveEdgeLock.unlock()
        }
        // Sodalite#104 round 4: the LOOPS' flag, which also runs them under a pause that arrived before
        // the first frame. The transport's own flag stays `isPlaying`.
        let getIsPlaying: @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return PausedFirstFrame.loopsMayRun(isPlaying: self.isPlaying,
                                                pausedBeforeFirstFrame: self.pausedBeforeFirstFrame)
        }
        let getStopRequested: @Sendable () -> Bool = { [weak self] in self?.stopRequested ?? true }
        // #95: resolved per packet so a tap installed mid-session is picked up by running loops.
        let getAudioTapSink: @Sendable () -> ((@Sendable (CMSampleBuffer) -> Void)?) = { [weak self] in
            self?.audioTapSink
        }
        // #112 rework: same late-install resolution for the subtitle tap.
        let getSubtitleTapSink: @Sendable () -> ((@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational, Bool) -> Void)?) = { [weak self] in
            self?.subtitleTapSink
        }
        // AE#560: both read loops hand every source packet to this before any branching.
        let recordingTap: @Sendable (UnsafeMutablePointer<AVPacket>) -> Void = { [weak self] pkt in
            self?.tapForRecording(pkt)
        }
        let subIndices = subtitleStreamIndices
        let subTimeBases = subtitleStreamTimeBases
        let subSplitSetIndices = splitDisplaySetSubtitleStreamIndices
        let onErrorForGeneration: @Sendable (String, UInt64) -> Void = { [weak self] msg, generation in
            Task { @MainActor [weak self] in
                guard let self, self.admitsRead(generation: generation) else { return }
                self.failure = PlaybackErrorInfo(kind: .softwarePipelineFailed, message: msg)
            }
        }
        let onEndForGeneration: @Sendable (UInt64) -> Void = { [weak self] generation in
            Task { @MainActor [weak self] in
                guard let self, self.admitsRead(generation: generation) else { return }
                // Only current EOF may mark the diagnostic source exhausted or stop playback.
                // A queued pre-seek EOF task must not end a freshly positioned generation.
                self.demuxDiag.markSourceExhausted()
                self.parkClockAtEndOfMedia()
                self.didReachEnd = true
                self.isPlaying = false
            }
        }
        let onError: @Sendable (String) -> Void = { [weak self] message in
            guard let self else { return }
            onErrorForGeneration(message, self.seekGeneration)
        }
        let onEnd: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            onEndForGeneration(self.seekGeneration)
        }

        // Live + DVR ring: reader/feeder split; live-only and VOD use the combined loop below.
        let getClockArmed: @Sendable () -> Bool = { [weak self] in
            self?.clockArmed ?? true
        }
        let setClockArmed: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.clockArmed = true
            // Sodalite#104 round 4: a pause() or play() between this arm reading its rate and the line
            // above found no clock to act on.
            guard let aOut, let rate = PausedFirstFrame.rateCorrectionAtArm(
                transportPlaying: self.isPlaying, pausedBeforeFirstFrame: self.pausedBeforeFirstFrame,
                synchronizerRate: aOut.synchronizer.rate, lastRate: self.lastRate) else { return }
            if rate == 0 { aOut.pause() } else { aOut.setRate(rate) }
        }
        let getSeekGeneration: @Sendable () -> UInt64 = { [weak self] in
            self?.seekGeneration ?? 0
        }
        let admitsRead: @Sendable (UInt64) -> Bool = { [weak self] generation in
            self?.admitsRead(generation: generation) ?? false
        }
        let getSeekWindowOpen: @Sendable () -> Bool = { [weak self] in
            self?.seekWindowOpen ?? false
        }
        let setDecodeGeneration: @Sendable (UInt64) -> Void = { [weak self] gen in
            self?.decodeGeneration = gen
        }
        let noteDecodeGeneration: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.decodeGeneration = self.seekGeneration
        }
        let getBackgroundAudioOnly: @Sendable () -> Bool = { [weak self] in
            self?.backgroundAudioOnly ?? false
        }
        // #107: the demux loop reports the resolved session-zero offset when it re-anchors
        // the clock at a deviating first-sample PTS (mid-stream-joined source).
        let onClockAnchored: @Sendable (Double) -> Void = { [weak self] zero in
            self?.clockSessionZero = zero
        }

        if liveSession, let ring {
            let readCursor: @Sendable () -> Int = { [weak self] in
                self?.readFeedCursor() ?? 0
            }
            let advanceCursor: @Sendable (Int) -> Void = { [weak self] old in
                self?.advanceFeedCursor(from: old)
            }
            let clampCursor: @Sendable (Int, Int) -> Void = { [weak self] old, first in
                self?.clampFeedCursor(from: old, to: first)
            }
            let setSourceEnded: @Sendable () -> Void = { [weak self] in
                self?.sourceEnded = true
            }
            let getSourceEnded: @Sendable () -> Bool = { [weak self] in
                self?.sourceEnded ?? true
            }
            demuxQueue.async {
                Self.runLiveReaderLoop(
                    demuxer: dem,
                    videoStreamIndex: vIdx,
                    audioStreamIndex: aIdx,
                    condition: condition,
                    ring: ring,
                    videoTimeBaseSeconds: vTbSec,
                    audioTimeBaseSeconds: aTbSec,
                    noteEdge: noteEdge,
                    stopRequested: getStopRequested,
                    onError: onError,
                    onSourceEnded: setSourceEnded,
                    subtitleStreamIndices: subIndices,
                    subtitleTimeBases: subTimeBases,
                    splitDisplaySetSubtitleStreamIndices: subSplitSetIndices,
                    subtitleTapSink: getSubtitleTapSink,
                    recordingTap: recordingTap
                )
            }
            let lookahead = audioLookahead
            feedQueue.async {
                Self.runLiveFeederLoop(
                    videoDecoder: vDec,
                    audioDecoder: aDec,
                    audioOutput: aOut,
                    videoStreamIndex: vIdx,
                    audioStreamIndex: aIdx,
                    renderer: rndr,
                    condition: condition,
                    ring: ring,
                    audioLookahead: lookahead,
                    videoTimeBaseSeconds: vTbSec,
                    audioTimeBaseSeconds: aTbSec,
                    readCursor: readCursor,
                    advanceCursor: advanceCursor,
                    clampCursor: clampCursor,
                    currentRate: currentRate,
                    isPlaying: getIsPlaying,
                    stopRequested: getStopRequested,
                    sourceEnded: getSourceEnded,
                    clockArmed: getClockArmed,
                    markClockArmed: setClockArmed,
                    onEnd: onEnd,
                    audioTapSink: getAudioTapSink,
                    noteDecodeGeneration: noteDecodeGeneration
                )
            }
            return
        }

        let diag = demuxDiag
        let readAhead = vodPacketReadAhead
        demuxQueue.async {
            Self.runDemuxLoop(
                demuxer: dem,
                readAhead: readAhead,
                videoDecoder: vDec,
                videoStreamIndex: vIdx,
                audioDecoder: aDec,
                audioOutput: aOut,
                audioStreamIndex: aIdx,
                renderer: rndr,
                condition: condition,
                initialClockTime: initialClock,
                currentRate: currentRate,
                diag: diag,
                ring: ring,
                videoTimeBaseSeconds: vTbSec,
                audioTimeBaseSeconds: aTbSec,
                isLive: liveSession,
                foldTimeline: Self.shouldFoldTimeline(
                    isLive: liveSession, sourceSeekable: dem.isSourceSeekable),
                noteEdge: noteEdge,
                isPlaying: getIsPlaying,
                stopRequested: getStopRequested,
                clockArmed: getClockArmed,
                markClockArmed: setClockArmed,
                onClockAnchored: onClockAnchored,
                seekGeneration: getSeekGeneration,
                admitsRead: admitsRead,
                seekWindowOpen: getSeekWindowOpen,
                setDecodeGeneration: setDecodeGeneration,
                noteDecodeGeneration: noteDecodeGeneration,
                backgroundAudioOnly: getBackgroundAudioOnly,
                onError: onErrorForGeneration,
                onEnd: onEndForGeneration,
                audioTapSink: getAudioTapSink,
                subtitleStreamIndices: subIndices,
                subtitleTimeBases: subTimeBases,
                splitDisplaySetSubtitleStreamIndices: subSplitSetIndices,
                subtitleTapSink: getSubtitleTapSink,
                recordingTap: recordingTap
            )
        }
    }

    // MARK: - Live reader loop (DVR sessions)

    /// Source -> ring (runs regardless of play/pause). Discontinuity reconciliation before ring append so the ring carries one continuous timeline.
    nonisolated private static func runLiveReaderLoop(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32,
        condition: NSCondition,
        ring: PacketRingBuffer,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        noteEdge: @Sendable (Double) -> Void,
        stopRequested: @Sendable () -> Bool,
        onError: @Sendable (String) -> Void,
        onSourceEnded: @Sendable () -> Void,
        subtitleStreamIndices: Set<Int32> = [],
        subtitleTimeBases: [Int32: AVRational] = [:],
        splitDisplaySetSubtitleStreamIndices: Set<Int32> = [],
        subtitleTapSink: @Sendable () -> ((@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational, Bool) -> Void)?) = { nil },
        recordingTap: @escaping @Sendable (UnsafeMutablePointer<AVPacket>) -> Void = { _ in }
    ) {
        let discontinuityThresholdSeconds = 10.0
        var prevRawVideoPtsSec = Double.nan
        var frameIntervalSec = 0.0
        var discontinuityOffsetSec = 0.0
        var loggedSWDiscontinuity = false
        var lastSeenExtradata: Data? = nil

        defer {
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }

        func readerIteration() -> Bool {
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                EngineLog.emit("[SWHost] live reader read failed: \(error)", category: .swPlayback)
                onError("Playback error: \(error.localizedDescription)")
                onSourceEnded()
                return false
            }
            guard let packet else {
                EngineLog.emit("[SWHost] live reader EOF (source lost)", category: .swPlayback)
                onSourceEnded()
                return false
            }

            // AE#560: record before any branch. The DVR ring append further down sits inside
            // `if let ring`, so a tap placed there would silently do nothing for a live session
            // loaded without dvrWindowSeconds.
            recordingTap(packet)

            let streamIdx = packet.pointee.stream_index

            // In-band codec parameter change detection. libavcodec SW
            // decoders pick up in-band SPS/PPS changes on their own; the
            // VT HEVC path keeps its session-start format description and
            // would wedge or corrupt on a real change. Log loudly so a
            // real-world repro is identifiable; the
            // VTDecompressionSession reinit is gated on one.
            if streamIdx == videoStreamIndex {
                var sdSize: Int = 0
                if let sd = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &sdSize),
                   sdSize > 0 {
                    let newExtra = Data(bytes: sd, count: sdSize)
                    if newExtra != lastSeenExtradata {
                        lastSeenExtradata = newExtra
                        EngineLog.emit(
                            "[SWHost] WARNING: in-band video extradata change (\(sdSize) bytes) "
                            + "on the live source. SW decoders follow in-band parameter sets; "
                            + "the VT HEVC decoder keeps its session-start format description "
                            + "and needs a reinit if artifacts follow.",
                            category: .swPlayback
                        )
                    }
                }
            }

            // NOPTS repair: ring gates on valid PTS; MPEG-TS/H.264 field packets with NOPTS would starve the decoder. Synthesize PTS from DTS.
            if streamIdx == videoStreamIndex || streamIdx == audioStreamIndex,
               packet.pointee.pts == Int64.min, packet.pointee.dts != Int64.min {
                packet.pointee.pts = packet.pointee.dts
            }

            // Live PTS-discontinuity: same accrual as combined loop.
            if streamIdx == videoStreamIndex, videoTimeBaseSeconds > 0,
               packet.pointee.pts != Int64.min {
                let rawPtsSec = Double(packet.pointee.pts) * videoTimeBaseSeconds
                if !prevRawVideoPtsSec.isNaN {
                    let deltaSec = rawPtsSec - prevRawVideoPtsSec
                    if abs(deltaSec) >= discontinuityThresholdSeconds {
                        let expectedContinuation = prevRawVideoPtsSec
                            + (frameIntervalSec > 0 ? frameIntervalSec : 0)
                        discontinuityOffsetSec += (rawPtsSec - expectedContinuation)
                        if !loggedSWDiscontinuity {
                            loggedSWDiscontinuity = true
                            EngineLog.emit(
                                "[SWHost] live PTS discontinuity (reader): prevPts="
                                + "\(String(format: "%.2f", prevRawVideoPtsSec))s "
                                + "rawPts=\(String(format: "%.2f", rawPtsSec))s "
                                + "delta=\(String(format: "%.2f", deltaSec))s -> "
                                + "offset=\(String(format: "%.2f", discontinuityOffsetSec))s "
                                + "(timeline held continuous)",
                                category: .swPlayback
                            )
                        }
                    } else if deltaSec > 0 {
                        frameIntervalSec = deltaSec
                    }
                }
                prevRawVideoPtsSec = rawPtsSec
            }
            if discontinuityOffsetSec != 0 {
                let tbSec = (streamIdx == videoStreamIndex)
                    ? videoTimeBaseSeconds : audioTimeBaseSeconds
                if tbSec > 0 {
                    let offsetTicks = Int64((discontinuityOffsetSec / tbSec).rounded())
                    if packet.pointee.pts != Int64.min { packet.pointee.pts -= offsetTicks }
                    if packet.pointee.dts != Int64.min { packet.pointee.dts -= offsetTicks }
                }
            }

            let isVideo = streamIdx == videoStreamIndex
            let isAudio = streamIdx == audioStreamIndex
            if isVideo || isAudio {
                let tbSec = isVideo ? videoTimeBaseSeconds : audioTimeBaseSeconds
                let rawPts = packet.pointee.pts
                if rawPts != Int64.min, tbSec > 0 {
                    let ptsSec = Double(rawPts) * tbSec
                    noteEdge(ptsSec)
                    if let data = packet.pointee.data, packet.pointee.size > 0 {
                        let bytes = Data(bytes: data, count: Int(packet.pointee.size))
                        let isKey = isVideo && (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                        // Best-effort: a write failure just shrinks the
                        // rewind window, it must not stall the reader.
                        try? ring.append(pts: ptsSec, isKeyframe: isKey, isVideo: isVideo, bytes: bytes)
                        condition.lock()
                        condition.broadcast()
                        condition.unlock()
                    }
                }
            } else if subtitleStreamIndices.contains(streamIdx), let sink = subtitleTapSink() {
                // #107: the ring holds only A/V; subtitle packets tap into the session packet
                // store here, mirroring the combined demux loop (the playhead-paced drainer
                // decodes them on selection).
                sink(streamIdx, packet,
                     subtitleTimeBases[streamIdx] ?? AVRational(num: 1, den: 1000),
                     splitDisplaySetSubtitleStreamIndices.contains(streamIdx))
            }

            av_packet_unref(packet)
            av_packet_free_safe(packet)
            return true
        }

        while !stopRequested() {
            let keepGoing: Bool = autoreleasepool {
                readerIteration()
            }
            if !keepGoing { break }
        }
    }

    // MARK: - Live feeder loop (DVR sessions)

    /// Ring cursor -> decoders -> renderer with back-pressure. Pause = timeshift (reader keeps filling); DVR seek = cursor move.
    nonisolated private static func runLiveFeederLoop(
        videoDecoder: any VideoDecodingPipeline,
        audioDecoder: AudioDecoder?,
        audioOutput: AudioOutput?,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32,
        renderer: SampleBufferRenderer,
        condition: NSCondition,
        ring: PacketRingBuffer,
        audioLookahead: AudioLookaheadState,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        readCursor: @Sendable () -> Int,
        advanceCursor: @Sendable (Int) -> Void,
        clampCursor: @Sendable (Int, Int) -> Void,
        currentRate: @Sendable () -> Float,
        isPlaying: @Sendable () -> Bool,
        stopRequested: @Sendable () -> Bool,
        sourceEnded: @Sendable () -> Bool,
        clockArmed: @Sendable () -> Bool,
        markClockArmed: @Sendable () -> Void,
        onEnd: @Sendable () -> Void,
        audioTapSink: @Sendable () -> ((@Sendable (CMSampleBuffer) -> Void)?),
        noteDecodeGeneration: @Sendable () -> Void
    ) {
        // Audio look-ahead pump (#107 audio chopping): feed audio packets ahead of the
        // combined cursor so the audio renderer holds AudioLookaheadPolicy.targetLeadSeconds
        // of decoded audio regardless of video decode pace. Without it audio lead is capped
        // by the video renderer queue (<1 s) and any feeder stall is an audible dropout.
        var preArmPacketsFed = 0
        var hadLead = false
        var rebuffering = false
        var lastLowLeadLog = DispatchTime(uptimeNanoseconds: 0)
        func pumpAudio() {
            guard let aDec = audioDecoder, let aOut = audioOutput, audioStreamIndex >= 0 else { return }
            var seq = audioLookahead.align(to: readCursor())
            func pumpIteration() -> Bool {
                let armed = clockArmed()
                guard AudioLookaheadPolicy.decide(
                    clockArmed: armed,
                    preArmPacketsFed: preArmPacketsFed,
                    lastFedAudioPTS: audioLookahead.lastFedAudioPTS,
                    clockSeconds: aOut.currentTimeSeconds
                ) == .feed else { return false }
                guard seq < ring.seqBounds.end else { return false }  // live edge: nothing to pump yet
                guard let pkt = ring.packet(atSeq: seq) else {
                    // Evicted/unreadable under the pump: skip, same as the combined loop.
                    guard audioLookahead.advance(from: seq, fedPTS: nil) else { return false }
                    seq += 1
                    return true
                }
                if pkt.isVideo {
                    guard audioLookahead.advance(from: seq, fedPTS: nil) else { return false }
                    seq += 1
                    return true
                }
                let producedAudio = feedRingPacket(
                    pkt,
                    videoDecoder: videoDecoder,
                    audioDecoder: aDec,
                    audioOutput: aOut,
                    videoStreamIndex: videoStreamIndex,
                    audioStreamIndex: audioStreamIndex,
                    videoTimeBaseSeconds: videoTimeBaseSeconds,
                    audioTimeBaseSeconds: audioTimeBaseSeconds,
                    audioTapSink: audioTapSink(),
                    noteDecodeGeneration: noteDecodeGeneration
                )
                if !armed {
                    preArmPacketsFed += 1
                    if producedAudio {
                        // First decoded buffers arm the clock at their packet PTS, exactly as
                        // the combined loop did before the pump took over audio delivery.
                        let armTime = CMTime(seconds: pkt.pts, preferredTimescale: 90000)
                        aOut.seekClock(to: armTime, rate: currentRate())
                        markClockArmed()
                    }
                }
                guard audioLookahead.advance(from: seq, fedPTS: pkt.pts) else { return false }
                seq += 1
                return true
            }

            while !stopRequested() && isPlaying() {
                let keepGoing: Bool = autoreleasepool {
                    pumpIteration()
                }
                if !keepGoing { break }
            }
            // Live-edge underrun handling (#107): a source delivering below real time would
            // otherwise leave the free-running clock permanently ahead of the stream, and
            // every later sample lands in the clock's past (continuous chopping that never
            // recovers). Pause the clock, refill, resume; the native path gets the same
            // behavior from AVPlayer's stall handling.
            if clockArmed(), isPlaying() {
                let lastPTS = audioLookahead.lastFedAudioPTS
                let lead = lastPTS.isFinite ? lastPTS - aOut.currentTimeSeconds : 0
                switch AudioLookaheadPolicy.clockAction(
                    rebuffering: rebuffering,
                    lastFedAudioPTS: lastPTS,
                    clockSeconds: aOut.currentTimeSeconds,
                    atRingEnd: audioLookahead.current >= ring.seqBounds.end,
                    sourceEnded: sourceEnded()
                ) {
                case .pauseForRebuffer:
                    rebuffering = true
                    EngineLog.emit(
                        "[SWHost] live source underrun: pausing clock to rebuffer "
                        + "(lead=\(String(format: "%.2f", lead))s)",
                        category: .swPlayback
                    )
                    aOut.pause()
                case .resume:
                    rebuffering = false
                    EngineLog.emit(
                        "[SWHost] rebuffered: resuming clock (lead=\(String(format: "%.2f", lead))s)",
                        category: .swPlayback
                    )
                    aOut.setRate(currentRate())
                case .none:
                    // Decode-lag visibility for device logs: only after lead was once
                    // healthy (startup fill must not trip it), rate-limited to one per 5 s.
                    if lead >= 0.5 { hadLead = true }
                    if hadLead, lead < 0.1, !rebuffering {
                        let now = DispatchTime.now()
                        if now.uptimeNanoseconds &- lastLowLeadLog.uptimeNanoseconds > 5_000_000_000 {
                            lastLowLeadLog = now
                            EngineLog.emit(
                                "[SWHost] audio lead low: \(String(format: "%.2f", lead))s "
                                + "(ring end=\(ring.seqBounds.end) audioSeq=\(audioLookahead.current))",
                                category: .swPlayback
                            )
                        }
                    }
                }
            }
        }

        func feederIteration() -> Bool {
            if !isPlaying() {
                condition.lock()
                while !isPlaying() && !stopRequested() {
                    autoreleasepool {
                        _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                    }
                }
                condition.unlock()
                return true
            }

            // Keep the audio renderer topped up before (possibly expensive) video work.
            pumpAudio()

            let cursor = readCursor()
            let bounds = ring.seqBounds
            if cursor < bounds.first {
                // Paused/behind longer than the retention window: the
                // packets under the cursor were evicted. Clamp to the
                // oldest retained packet (keyframe-aligned by eviction).
                EngineLog.emit(
                    "[SWHost] feeder cursor \(cursor) fell below window (first=\(bounds.first)); clamping",
                    category: .swPlayback
                )
                clampCursor(cursor, bounds.first)
                return true
            }
            guard let pkt = ring.packet(atSeq: cursor) else {
                // Resident entry whose file read failed (disk hiccup,
                // pruned mid-read): skip it, or the feeder would spin on
                // the same sequence number forever in a silent freeze.
                if cursor < bounds.end {
                    EngineLog.emit(
                        "[SWHost] feeder: packet seq=\(cursor) unreadable; skipping",
                        category: .swPlayback
                    )
                    advanceCursor(cursor)
                    return true
                }
                // At the live edge (cursor == end): wait for the reader's
                // next append, or finish when the source is gone and the
                // ring is fully drained.
                if sourceEnded() {
                    videoDecoder.flush()
                    audioDecoder?.flush()
                    renderer.drainReorderBuffer()
                    onEnd()
                    return false
                }
                condition.lock()
                autoreleasepool {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.25))
                }
                condition.unlock()
                return true
            }

            if pkt.isVideo {
                // Back-pressure against renderer queue; also bail on pause without consuming.
                // The wait can outlast the audio lead, so keep pumping audio while parked.
                var waitTicks = 0
                while !renderer.isReadyForMoreMediaData && !stopRequested() && isPlaying() {
                    autoreleasepool {
                        Thread.sleep(forTimeInterval: 0.005)
                        waitTicks += 1
                        if waitTicks % 20 == 0 { pumpAudio() }
                        // #337: the pump is what can still arm the clock from here, so its spent
                        // pre-arm budget is what turns this park terminal (an audio track that
                        // never decodes a buffer). The renderer cannot drain at a stopped clock,
                        // so waiting past that point is a deadlock, not patience.
                        if SWClockAnchorPolicy.shouldArmFromParkedVideo(
                            clockArmed: clockArmed(),
                            isPlaying: isPlaying(),
                            rendererReadyForMoreData: renderer.isReadyForMoreMediaData,
                            audioArmingStillPossible: preArmPacketsFed < AudioLookaheadPolicy.preArmPacketBudget),
                           let aOut = audioOutput {
                            EngineLog.emit(
                                "[SWHost] clock unarmed at the video gate: the look-ahead pump spent its "
                                + "pre-arm budget (\(preArmPacketsFed) packets) without a decoded buffer; "
                                + "anchoring on video at \(String(format: "%.3f", pkt.pts))s",
                                category: .swPlayback
                            )
                            aOut.seekClock(to: CMTime(seconds: pkt.pts, preferredTimescale: 90000),
                                           rate: currentRate())
                            markClockArmed()
                        }
                    }
                }
                if stopRequested() { return false }
                if !isPlaying() { return true }
            } else if cursor < audioLookahead.current {
                // Audio the pump already delivered: consume the slot without re-decoding.
                advanceCursor(cursor)
                return true
            }

            let producedAudio = feedRingPacket(
                pkt,
                videoDecoder: videoDecoder,
                audioDecoder: audioDecoder,
                audioOutput: audioOutput,
                videoStreamIndex: videoStreamIndex,
                audioStreamIndex: audioStreamIndex,
                videoTimeBaseSeconds: videoTimeBaseSeconds,
                audioTimeBaseSeconds: audioTimeBaseSeconds,
                audioTapSink: audioTapSink(),
                noteDecodeGeneration: noteDecodeGeneration
            )

            // Arm clock once on first packet PTS (anchoring at .zero caused delay). Audio: first decoded buffers; video-only: first video packet (no clock without audio = frozen frame).
            if !clockArmed(), let aOut = audioOutput {
                let shouldArm = (audioDecoder == nil) ? pkt.isVideo : producedAudio
                if shouldArm {
                    let armTime = CMTime(seconds: pkt.pts, preferredTimescale: 90000)
                    // Latest host rate, read at arm time (a setRate before arming is deferred here, #107).
                    aOut.seekClock(to: armTime, rate: currentRate())
                    markClockArmed()
                }
            }

            advanceCursor(cursor)
            return true
        }

        while !stopRequested() {
            let keepGoing: Bool = autoreleasepool {
                feederIteration()
            }
            if !keepGoing { break }
        }
    }

    /// Apply a resolved clock anchor: seek the synchronizer, report a non-zero session
    /// zero to the host, and log a re-anchor (release-visible; a mid-stream join is
    /// otherwise indistinguishable from a frozen-frame wedge, #107).
    nonisolated private static func armClock(
        _ aOut: AudioOutput,
        resolution: SWClockAnchorPolicy.Resolution,
        initialClockTime: CMTime,
        rate: Float,
        onClockAnchored: @Sendable (Double) -> Void
    ) {
        let anchorTime = resolution.anchorSeconds == initialClockTime.seconds
            ? initialClockTime
            : CMTime(seconds: resolution.anchorSeconds, preferredTimescale: 90000)
        aOut.seekClock(to: anchorTime, rate: rate)
        if resolution.anchorSeconds != initialClockTime.seconds {
            EngineLog.emit(
                "[SWHost] clock re-anchored to first sample: anchor=\(String(format: "%.3f", resolution.anchorSeconds))s "
                + "(load anchor \(String(format: "%.3f", initialClockTime.seconds))s, "
                + "sessionZero=\(String(format: "%.3f", resolution.sessionZeroSeconds))s)",
                category: .swPlayback
            )
            onClockAnchored(resolution.sessionZeroSeconds)
        }
    }

    /// Demux loop: reads packets, dispatches by stream index, back-pressures against renderer's isReadyForMoreMediaData, flushes decoders at EOF.
    nonisolated private static func runDemuxLoop(
        demuxer: Demuxer,
        readAhead: SoftwarePacketReadAhead?,
        videoDecoder: any VideoDecodingPipeline,
        videoStreamIndex: Int32,
        audioDecoder: AudioDecoder?,
        audioOutput: AudioOutput?,
        audioStreamIndex: Int32,
        renderer: SampleBufferRenderer,
        condition: NSCondition,
        initialClockTime: CMTime,
        currentRate: @Sendable () -> Float,
        diag: SWPlaybackDiagState? = nil,
        ring: PacketRingBuffer?,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        isLive: Bool,
        foldTimeline: Bool,
        noteEdge: @Sendable (Double) -> Void,
        isPlaying: @Sendable () -> Bool,
        stopRequested: @Sendable () -> Bool,
        clockArmed: @Sendable () -> Bool,
        markClockArmed: @Sendable () -> Void,
        onClockAnchored: @Sendable (Double) -> Void,
        seekGeneration: @Sendable () -> UInt64,
        admitsRead: @Sendable (UInt64) -> Bool,
        seekWindowOpen: @Sendable () -> Bool,
        setDecodeGeneration: @Sendable (UInt64) -> Void,
        noteDecodeGeneration: @Sendable () -> Void,
        backgroundAudioOnly: @Sendable () -> Bool,
        onError: @Sendable (String, UInt64) -> Void,
        onEnd: @Sendable (UInt64) -> Void,
        audioTapSink: @Sendable () -> ((@Sendable (CMSampleBuffer) -> Void)?),
        subtitleStreamIndices: Set<Int32> = [],
        subtitleTimeBases: [Int32: AVRational] = [:],
        splitDisplaySetSubtitleStreamIndices: Set<Int32> = [],
        subtitleTapSink: @Sendable () -> ((@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational, Bool) -> Void)?) = { nil },
        recordingTap: @escaping @Sendable (UnsafeMutablePointer<AVPacket>) -> Void = { _ in }
    ) {
        // Clock arming: one-shot latch (seekClock is not idempotent -- re-calling snaps clock back to initialClockTime). Shared with host so a seek before first audio isn't overridden by a late re-arm.

        // PTS-discontinuity fold (SW): accrue (jumpedPts - expectedContinuation) into discontinuityOffset; subtract from all subsequent PTS so the whole pipeline sees one continuous timeline. Threshold 10s (mirrors native producer); flush decoders at the seam.
        // Runs for live AND for forward-only (sequential-origin) VOD: IPTV timeshift archives are
        // chunked recordings whose every chunk restarts at PTS ~0 (device trace: 89 s chunk ending
        // at raw 2717.9 s, next chunk at 0.04 s; FFmpeg's 33-bit wrap correction turned that -2718 s
        // into +92726 s, the renderer then waited 25 h for the frame's display time and died with
        // -12080). Seekable VOD keeps the fold off: its timeline is trusted, and a threshold-sized
        // jump there is a container seek artifact the native path also leaves alone.
        let discontinuityThresholdSeconds = 10.0
        var prevRawVideoPtsSec = Double.nan
        var frameIntervalSec = 0.0
        var discontinuityOffsetSec = 0.0
        var loggedSeamCount = 0

        // Clock-arming fallback bookkeeping: a declared audio track whose
        // decoder never produces buffers (corrupt stream) must not leave
        // the session unarmed forever. See the video-branch arming below.
        var audioPacketsSeen = 0
        var audioBuffersProduced = false

        // VOD audio decoupling (#107 family). The combined loop paced EVERYTHING on the video
        // renderer's ~10-frame queue, so interleaved audio could never build more than ~0.3 s
        // of lead over the synchronizer clock. Any decode/deinterlace jitter beyond that
        // starved the audio renderer, the synchronizer leapt to the next sample's PTS, the
        // whole queued video was suddenly late and the layer dropped it - a visible forward
        // skip (1080i50 archive replay trace: periodic +0.25 s clock leaps, 17 % renderer
        // drops). Video packets now PARK in a bounded FIFO while audio keeps decoding up to
        // AudioLookaheadPolicy.targetLeadSeconds ahead of the clock, and a genuine underrun
        // pauses the clock for a rebuffer (AudioLookaheadPolicy.clockAction) instead of
        // letting it free-run, mirroring the DVR feeder arm. Live sessions keep the historical
        // lockstep pacing: their delivery is origin-paced realtime, and the ones that need a
        // pump get it from the DVR feeder arm on its own thread.
        var parkedVideo: [UnsafeMutablePointer<AVPacket>] = []
        let parkedVideoCap = 256
        var terminalGeneration = SoftwareTerminalGeneration()
        var lastEnqueuedAudioPtsSec = Double.nan
        var rebuffering = false
        // The pause/rebuffer arm stays off until the source has proven it can deliver a real
        // lead once: an exactly-realtime origin whose lead never leaves the start offset must
        // not eat a rebuffer pause at every session start.
        var everHadLead = false
        var parkedSeekGeneration = seekGeneration()
        let decoupleAudio = !isLive && audioDecoder != nil && audioOutput != nil

        func freeParkedVideo() {
            for p in parkedVideo {
                av_packet_unref(p)
                av_packet_free_safe(p)
            }
            parkedVideo.removeAll()
        }

        // Decode+enqueue parked video while the renderer will take it. Never blocks.
        // Generation-checked: the blocking waits below can sit here across a seek, and the
        // lockstep gate discards a pre-seek packet for the same reason (decoding one clears
        // the decoder's skip threshold = visible fast-forward burst).
        //
        // AE#492: the check is per PACKET, and the epoch travels with it. Read once at the top, this
        // loop emptied the whole four-second FIFO into the decoder while a seek was landing, so the
        // packets kept arriving AFTER that seek's `videoDecoder.flush()` and refilled what the flush
        // had just cleared. Their own frames were still refused at the decoder callback, but the last
        // one stayed inside the deinterlacer's lookahead and came out on the FIRST post-seek decode,
        // by which time `decodeGeneration` was the new one and every gate passed it. One such frame
        // is a sample whose presentation time is the whole seek distance in the future: the layer
        // takes it, holds it, stops reporting `isReadyForMoreMediaData`, and the loop parks on that
        // signal until its FIFO caps out. Measured here as three to four seconds of `enq=+0` with the
        // audio lead decaying under it, on a session that reports playing and never rebuffers.
        func drainParkedVideoNonblocking() {
            if seekGeneration() != parkedSeekGeneration { return }
            let epoch = videoDecoder.feedEpoch
            while !parkedVideo.isEmpty, renderer.isReadyForMoreMediaData,
                  !stopRequested(), !backgroundAudioOnly() {
                // Leave the rest standing: the next iteration of the loop frees the FIFO as a batch
                // once it has read the new generation.
                if seekGeneration() != parkedSeekGeneration { return }
                let p = parkedVideo.removeFirst()
                setDecodeGeneration(parkedSeekGeneration)
                videoDecoder.decode(packet: p, epoch: epoch)
                av_packet_unref(p)
                av_packet_free_safe(p)
            }
        }

        func releaseRebufferHold(_ why: String) {
            guard rebuffering else { return }
            rebuffering = false
            EngineLog.emit("[SWHost] releasing rebuffer hold: \(why)", category: .swPlayback)
            audioOutput?.setRate(currentRate())
        }

        // #337 on the decoupled path. The lockstep gate arms the clock off the packet it is
        // holding when the renderer is full and the selected audio stream will never produce
        // the buffer the clock waits for; parked, the equivalent packet is the FIFO head. The
        // gate below is the same shape of park, so it needs the same exit.
        func armFromParkedVideoIfStuck() {
            guard let head = parkedVideo.first, let aOut = audioOutput,
                  SWClockAnchorPolicy.shouldArmFromParkedVideo(
                    clockArmed: clockArmed(),
                    isPlaying: isPlaying(),
                    rendererReadyForMoreData: renderer.isReadyForMoreMediaData,
                    audioArmingStillPossible: false)
            else { return }
            EngineLog.emit(
                "[SWHost] clock unarmed with \(parkedVideo.count) video packets parked: the selected "
                + "audio stream (index \(audioStreamIndex)) has produced nothing by the renderer's "
                + "fill point (audioPacketsSeen=\(audioPacketsSeen)); anchoring on video",
                category: .swPlayback
            )
            armFromVideoPacket(head, aOut)
        }

        enum ParkWait {
            /// Hold the read until audio is back under its lead target / the FIFO under its cap.
            case readGate
            /// Feed the whole parked tail out (seam flush, end of media).
            case drainAll
        }

        // The one place the loop waits on the renderer. A rebuffer hold stops the synchronizer,
        // and a stopped synchronizer never drains the renderer: this thread is the only one that
        // could lift the hold, so waiting under it waits forever (the DVR arm may wait because
        // its pump runs on a second thread). Lift first, then wait.
        func waitForRenderer(_ reason: ParkWait) {
            func stillWaiting() -> Bool {
                switch reason {
                case .readGate:
                    return Self.shouldHoldDemuxRead(
                        parkedCount: parkedVideo.count, parkedCap: parkedVideoCap,
                        clockArmed: clockArmed(), lastAudioPts: lastEnqueuedAudioPtsSec,
                        clockSeconds: audioOutput?.currentTimeSeconds ?? .nan)
                case .drainAll:
                    return !parkedVideo.isEmpty
                }
            }
            while stillWaiting(), !stopRequested(), !backgroundAudioOnly() {
                if seekGeneration() != parkedSeekGeneration { return }
                if !isPlaying() {
                    condition.lock()
                    while !isPlaying() && !stopRequested() {
                        autoreleasepool {
                            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                        }
                    }
                    condition.unlock()
                    continue
                }
                releaseRebufferHold("the renderer needs a running clock to take parked video")
                armFromParkedVideoIfStuck()
                drainParkedVideoNonblocking()
                diag?.update(lastAudioPts: lastEnqueuedAudioPtsSec,
                             parked: parkedVideo.count, rebuffering: rebuffering,
                             generation: parkedSeekGeneration)
                if stillWaiting() { Thread.sleep(forTimeInterval: 0.005) }
            }
        }

        // Pause the master clock when the audio lead is genuinely exhausted, resume once the
        // rebuffer target is met. In this loop there is no ring to distinguish decode lag
        // from a dry source, so a sub-threshold lead IS treated as source-starved - the
        // everHadLead latch keeps that from firing on realtime-paced sources that never had
        // a lead to lose.
        func applyAudioClockAction() {
            guard decoupleAudio, clockArmed(), let aOut = audioOutput else { return }
            let lead = lastEnqueuedAudioPtsSec.isFinite
                ? lastEnqueuedAudioPtsSec - aOut.currentTimeSeconds : 0
            if lead >= AudioLookaheadPolicy.rebufferResumeLeadSeconds { everHadLead = true }
            guard everHadLead, isPlaying() || rebuffering else { return }
            switch AudioLookaheadPolicy.clockAction(
                rebuffering: rebuffering,
                lastFedAudioPTS: lastEnqueuedAudioPtsSec,
                clockSeconds: aOut.currentTimeSeconds,
                atRingEnd: true,
                // End of media releases the hold explicitly in the read path below; there is no
                // ring here whose end this could be read from.
                sourceEnded: false
            ) {
            case .pauseForRebuffer:
                rebuffering = true
                EngineLog.emit(
                    "[SWHost] audio lead exhausted (\(String(format: "%.2f", lead))s); "
                    + "pausing clock for rebuffer",
                    category: .swPlayback
                )
                aOut.pause()
            case .resume:
                rebuffering = false
                EngineLog.emit(
                    "[SWHost] rebuffered to \(String(format: "%.2f", lead))s audio lead; "
                    + "resuming clock",
                    category: .swPlayback
                )
                aOut.setRate(currentRate())
            case .none:
                break
            }
        }

        // Anchor the clock on a video packet. SWClockAnchorPolicy keeps the load anchor unless the
        // source joined mid-stream, so the frames already queued still present. Shared by the
        // undecodable-audio fallback and the #337 parked-gate exit.
        func armFromVideoPacket(_ packet: UnsafeMutablePointer<AVPacket>, _ aOut: AudioOutput) {
            // #107: a mid-stream-joined source delivers first samples far past the load
            // anchor; anchor at the packet PTS so they ever present (see SWClockAnchorPolicy).
            let pktPtsSec = (packet.pointee.pts != Int64.min && videoTimeBaseSeconds > 0)
                ? Double(packet.pointee.pts) * videoTimeBaseSeconds : Double.nan
            let resolution = SWClockAnchorPolicy.resolve(
                initialSeconds: initialClockTime.seconds, firstSampleSeconds: pktPtsSec)
            armClock(aOut, resolution: resolution, initialClockTime: initialClockTime,
                     rate: currentRate(), onClockAnchored: onClockAnchored)
            markClockArmed()
        }

        func demuxIteration() -> Bool {
            // A valid EOF/error can be queued for MainActor just before a newer seek supersedes
            // it. Keep the VOD consumer parked (without duplicate callbacks), not permanently
            // exited, so that newer generation still has a loop to consume its retained packets.
            if !isLive, terminalGeneration.shouldPark(generation: seekGeneration()) {
                condition.lock()
                while terminalGeneration.shouldPark(generation: seekGeneration()), !stopRequested() {
                    autoreleasepool {
                        _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                    }
                }
                condition.unlock()
                return !stopRequested()
            }
            // AE#491 round 2: the seek window is part of this park, not a second one. Keyed on it,
            // the loop stands still from the generation bump until the source and the clock are
            // both at the target, so nothing it does can be measured against, or fed from, the
            // position the seek left behind.
            if !SeekWindow.loopMayRead(isPlaying: isPlaying(), windowOpen: seekWindowOpen()) {
                condition.lock()
                while !SeekWindow.loopMayRead(isPlaying: isPlaying(), windowOpen: seekWindowOpen()),
                      !stopRequested() {
                    autoreleasepool {
                        _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                    }
                }
                condition.unlock()
                return true
            }

            if decoupleAudio {
                // Parked packets are pre-seek stale once the generation moves; the seek path
                // has already flushed decoders and re-anchored the clock.
                let gen = seekGeneration()
                if gen != parkedSeekGeneration {
                    parkedSeekGeneration = gen
                    freeParkedVideo()
                    lastEnqueuedAudioPtsSec = .nan
                    rebuffering = false
                    // The lead is zero again after a seek, so the latch has to earn itself back:
                    // keeping it set pauses the clock for a rebuffer on the first post-seek check.
                    everHadLead = false
                }
                drainParkedVideoNonblocking()
                applyAudioClockAction()
                // Read gate: stop pulling once decoded audio holds its target lead. The FIFO cap
                // is the memory backstop, not the pacing rule - what bounds the lead has to be
                // the lead itself, or the effective ceiling becomes "however many seconds of
                // video fit in 256 packets" and moves with frame rate.
                if Self.shouldHoldDemuxRead(
                    parkedCount: parkedVideo.count, parkedCap: parkedVideoCap,
                    clockArmed: clockArmed(), lastAudioPts: lastEnqueuedAudioPtsSec,
                    clockSeconds: audioOutput?.currentTimeSeconds ?? .nan) {
                    waitForRenderer(.readGate)
                    return true
                }
            }

            let genBeforeRead = seekGeneration()
            // AE#492: captured before the read, so a flush that lands during it retires this packet
            // inside the decoder rather than leaving the caller to re-check a value it cannot hold
            // across the call.
            var epochBeforeRead = videoDecoder.feedEpoch
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                if let readAhead {
                    packet = try readAhead.read(isCurrent: { admitsRead(genBeforeRead) })?.makeAVPacket()
                } else {
                    packet = try demuxer.readPacket(isCurrent: { admitsRead(genBeforeRead) })
                }
            } catch {
                // Stop/seek cancellation is not a playback failure, including a normal .closed
                // returned by the packet source during teardown. Errors belong to the read's
                // captured host generation, just like packets and EOF.
                guard admitsRead(genBeforeRead) else { return !stopRequested() }
                if case SoftwarePacketReadAhead.ReadError.interrupted = error { return true }
                EngineLog.emit("[SWHost] demux read failed: \(error)", category: .swPlayback)
                if terminalGeneration.record(genBeforeRead) {
                    onError("Playback error: \(error.localizedDescription)", genBeforeRead)
                }
                return !isLive
            }

            // Admit every result BEFORE interpreting nil as EOF. Otherwise an old read can drain
            // or end the new seek generation without ever reaching the old packet-only gate.
            guard admitsRead(genBeforeRead) else {
                if let packet { av_packet_unref(packet); av_packet_free_safe(packet) }
                return !stopRequested()
            }
            guard let packet else {
                // Play the parked tail out before the flush: nothing more will arrive, the queues
                // must drain to end-of-media. The wait lifts a rebuffer hold on its own - held,
                // the clock would never take the tail and end-of-media would never be reached.
                releaseRebufferHold("end of media, nothing left to rebuffer from")
                waitForRenderer(.drainAll)
                guard admitsRead(genBeforeRead) else { return !stopRequested() }
                freeParkedVideo()
                videoDecoder.flush()
                audioDecoder?.flush()
                renderer.drainReorderBuffer()
                if terminalGeneration.record(genBeforeRead) { onEnd(genBeforeRead) }
                return !isLive
            }

            // AE#560: record before any branch. The DVR ring append further down sits inside
            // `if let ring`, so a tap placed there would silently do nothing for a live session
            // loaded without dvrWindowSeconds.
            recordingTap(packet)

            let streamIdx = packet.pointee.stream_index

            // Discontinuity runs before any timestamp read; offset applied to both streams.
            if foldTimeline, streamIdx == videoStreamIndex, videoTimeBaseSeconds > 0,
               packet.pointee.pts != Int64.min {
                let rawPtsSec = Double(packet.pointee.pts) * videoTimeBaseSeconds
                if !prevRawVideoPtsSec.isNaN {
                    let deltaSec = rawPtsSec - prevRawVideoPtsSec
                    if abs(deltaSec) >= discontinuityThresholdSeconds {
                        // Accrue (jumpedPts - expectedContinuation) into offset; flush decoders at the seam.
                        let expectedContinuation = prevRawVideoPtsSec
                            + (frameIntervalSec > 0 ? frameIntervalSec : 0)
                        discontinuityOffsetSec += (rawPtsSec - expectedContinuation)
                        // Feed the parked pre-seam tail to the decoder before the flush drops
                        // its reference chain; the seam packet itself parks after this block.
                        waitForRenderer(.drainAll)
                        freeParkedVideo()
                        videoDecoder.flush()
                        // AE#492: this flush is THIS thread's, made after the read and on behalf of
                        // the packet in hand. Retiring that packet along with the seam it opens
                        // would drop the first picture of every new segment, so the epoch moves with
                        // it. A seek's flush comes from the other thread and is not re-read here.
                        epochBeforeRead = videoDecoder.feedEpoch
                        audioDecoder?.flush()
                        renderer.drainReorderBuffer()
                        // Chunked archives seam every minute or two; log each seam (bounded by the
                        // 10 s threshold to at most one line per 10 s of content) with a soft cap
                        // so a pathological source cannot flood the log.
                        if loggedSeamCount < 20 {
                            loggedSeamCount += 1
                            EngineLog.emit(
                                "[SWHost] PTS discontinuity #\(loggedSeamCount): prevPts="
                                + "\(String(format: "%.2f", prevRawVideoPtsSec))s "
                                + "rawPts=\(String(format: "%.2f", rawPtsSec))s "
                                + "delta=\(String(format: "%.2f", deltaSec))s -> "
                                + "offset=\(String(format: "%.2f", discontinuityOffsetSec))s "
                                + "(timeline held continuous)"
                                + (loggedSeamCount == 20 ? " [further seams unlogged]" : ""),
                                category: .swPlayback
                            )
                        }
                    } else if deltaSec > 0 {
                        frameIntervalSec = deltaSec
                    }
                }
                prevRawVideoPtsSec = rawPtsSec
            }

            // Apply discontinuity offset to timestamps in-place; converts seconds to stream TB ticks.
            if foldTimeline, discontinuityOffsetSec != 0 {
                let tbSec = (streamIdx == videoStreamIndex)
                    ? videoTimeBaseSeconds : audioTimeBaseSeconds
                if tbSec > 0 {
                    let offsetTicks = Int64((discontinuityOffsetSec / tbSec).rounded())
                    if packet.pointee.pts != Int64.min { packet.pointee.pts -= offsetTicks }
                    if packet.pointee.dts != Int64.min { packet.pointee.dts -= offsetTicks }
                }
            }

            // Fill ring before decode so the ring holds every packet. Audio appended for sync; only video keyframes tagged for eviction alignment.
            if isLive {
                let isVideo = streamIdx == videoStreamIndex
                let isAudio = streamIdx == audioStreamIndex
                if isVideo || isAudio {
                    let tbSec = isVideo ? videoTimeBaseSeconds : audioTimeBaseSeconds
                    let rawPts = packet.pointee.pts
                    if rawPts != Int64.min, tbSec > 0 {
                        let ptsSec = Double(rawPts) * tbSec
                        noteEdge(ptsSec)
                        if let ring {
                            let isKey = isVideo && (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                            if let data = packet.pointee.data, packet.pointee.size > 0 {
                                let bytes = Data(bytes: data, count: Int(packet.pointee.size))
                                // Append is a small file write; off-main and
                                // internally locked, so it never touches the
                                // decoders' state. Best-effort: a write failure
                                // just shrinks the rewind window, it must not
                                // stall live playback.
                                try? ring.append(pts: ptsSec, isKeyframe: isKey, isVideo: isVideo, bytes: bytes)
                            }
                        }
                    }
                }
            }

            if streamIdx == videoStreamIndex {
                // Background audio-only: drop video, don't gate on the non-draining display layer.
                if backgroundAudioOnly() {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    return true
                }
                if decoupleAudio {
                    // Park; the drains at the iteration top and the bounded-park gate feed the
                    // renderer. Ownership moves to the FIFO - no free here.
                    parkedVideo.append(packet)
                    // Broken-audio clock-arming fallback still applies (decoupleAudio only
                    // requires a DECLARED audio track, not a producing one). The stream that
                    // produces NO packets at all is #337's case and exits at the read gate.
                    if !clockArmed(), let aOut = audioOutput,
                       audioPacketsSeen >= 50, !audioBuffersProduced {
                        armFromVideoPacket(packet, aOut)
                    }
                    drainParkedVideoNonblocking()
                    return true
                }
                // Back-pressure via SampleBufferRenderer.isReadyForMoreMediaData (not the deprecated layer property). Park on condition while paused to avoid 200 Hz CPU spin.
                while !renderer.isReadyForMoreMediaData && !stopRequested() && !backgroundAudioOnly() {
                    autoreleasepool {
                        if !isPlaying() {
                            condition.lock()
                            while !isPlaying() && !stopRequested() {
                                autoreleasepool {
                                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                                }
                            }
                            condition.unlock()
                        } else {
                            // #337: this loop is the only reader, so an unarmed clock here is a
                            // deadlock and not latency: the renderer waits for the clock, the clock
                            // waits for a selected-stream audio buffer, and that packet is behind
                            // this park. Anchor on the video the renderer is holding instead.
                            if SWClockAnchorPolicy.shouldArmFromParkedVideo(
                                clockArmed: clockArmed(),
                                isPlaying: isPlaying(),
                                rendererReadyForMoreData: renderer.isReadyForMoreMediaData,
                                audioArmingStillPossible: false),
                               let aOut = audioOutput {
                                EngineLog.emit(
                                    "[SWHost] clock unarmed at the video gate: the selected audio stream "
                                    + "(index \(audioStreamIndex)) has produced nothing by the renderer's "
                                    + "fill point (audioPacketsSeen=\(audioPacketsSeen)); anchoring on video",
                                    category: .swPlayback
                                )
                                armFromVideoPacket(packet, aOut)
                            }
                            Thread.sleep(forTimeInterval: 0.005)
                        }
                    }
                }
                // Entered background while parked on back-pressure: drop this frame.
                if backgroundAudioOnly() {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    return true
                }
                if stopRequested() {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    return false
                }
                // Re-check generation after the back-pressure wait (seek can land there; pre-seek packet would clear skip thresholds).
                if seekGeneration() != genBeforeRead {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    return true
                }
                setDecodeGeneration(genBeforeRead)
                videoDecoder.decode(packet: packet, epoch: epochBeforeRead)
                // Video-only / undecodable audio fallback: arm clock off first video packet (50+ audio packets with zero buffers = decoder not recovering).
                if !clockArmed(), let aOut = audioOutput,
                   audioDecoder == nil || (audioPacketsSeen >= 50 && !audioBuffersProduced) {
                    armFromVideoPacket(packet, aOut)
                }
            } else if streamIdx == audioStreamIndex, let aDec = audioDecoder, let aOut = audioOutput {
                // Background audio-only: the video gate is bypassed, so pace on the audio renderer to avoid
                // buffering the rest of the file. Park on condition while paused (same shape as the video gate).
                if backgroundAudioOnly() {
                    while !aOut.isReadyForMoreMediaData && !stopRequested() && backgroundAudioOnly() {
                        autoreleasepool {
                            if !isPlaying() {
                                condition.lock()
                                while !isPlaying() && !stopRequested() {
                                    autoreleasepool {
                                        _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                                    }
                                }
                                condition.unlock()
                            } else {
                                Thread.sleep(forTimeInterval: 0.005)
                            }
                        }
                    }
                    if stopRequested() {
                        av_packet_unref(packet)
                        av_packet_free_safe(packet)
                        return false
                    }
                }
                // AE#491: the video branch discards a pre-seek packet here and audio has to do the
                // same. `audioOutput.flush()` has already emptied the queue these buffers would
                // join, and their PTS is the marker `applyAudioClockAction` measures the lead
                // against: one pre-seek buffer past this point reads as a lead the size of the
                // seek and pauses the clock for a rebuffer that is not happening.
                if seekGeneration() != genBeforeRead {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    return true
                }
                audioPacketsSeen += 1
                let buffers = aDec.decode(packet: packet)
                if !buffers.isEmpty { audioBuffersProduced = true }
                let tapSink = audioTapSink()
                // The flush can also land inside `decode`, so the buffers are checked out again.
                if seekGeneration() != genBeforeRead {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    return true
                }
                for buf in buffers {
                    tapSink?(buf)   // #95: mirror before enqueue
                    aOut.enqueue(sampleBuffer: buf)
                }
                if decoupleAudio, let last = buffers.last {
                    let pts = CMSampleBufferGetPresentationTimeStamp(last)
                    if pts.isValid { lastEnqueuedAudioPtsSec = pts.seconds }
                }
                // Arm clock on first decoded audio buffer; latch so subsequent packets don't snap clock back.
                if !clockArmed(), !buffers.isEmpty {
                    // #107: anchor at the buffer PTS when it deviates from the load anchor
                    // (mid-stream-joined source); aligned sources keep the anchor verbatim.
                    let firstPts = CMSampleBufferGetPresentationTimeStamp(buffers[0])
                    let resolution = SWClockAnchorPolicy.resolve(
                        initialSeconds: initialClockTime.seconds,
                        firstSampleSeconds: firstPts.isValid ? firstPts.seconds : Double.nan)
                    armClock(aOut, resolution: resolution, initialClockTime: initialClockTime,
                             rate: currentRate(), onClockAnchored: onClockAnchored)
                    markClockArmed()
                }
            } else if subtitleStreamIndices.contains(streamIdx), let sink = subtitleTapSink() {
                // #112 rework: hand embedded subtitle packets to the tap sink (copies the payload
                // into the session's SubtitlePacketStore). The SW host applies no stream discard,
                // so these packets were already being read and dropped here.
                sink(streamIdx, packet,
                     subtitleTimeBases[streamIdx] ?? AVRational(num: 1, den: 1000),
                     splitDisplaySetSubtitleStreamIndices.contains(streamIdx))
            }

            av_packet_unref(packet)
            av_packet_free_safe(packet)
            return true
        }

        while !stopRequested() {
            let keepGoing: Bool = autoreleasepool {
                demuxIteration()
            }
            diag?.update(lastAudioPts: lastEnqueuedAudioPtsSec,
                         parked: parkedVideo.count,
                         rebuffering: rebuffering,
                         generation: parkedSeekGeneration)
            if !keepGoing { break }
        }
        freeParkedVideo()
    }

    // MARK: - Time updates

    private func startTimeUpdates() {
        timeTimer = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                // Independent of the clock below: a seek in flight must not defer the one check.
                self.checkSurfaceVisibilityIfDue()
                guard let aOut = self.audioOutput else { return }
                // #254: a reposition in flight holds `currentTime` at its target; the synchronizer is
                // still on the pre-seek anchor and would drag the published position backwards.
                guard !self.seekInFlight else { return }
                let raw = aOut.currentTimeSeconds
                self.emitDiagIfDue(clock: raw)
                if raw.isFinite, raw >= 0 {
                    self.vodPacketReadAhead?.updatePlayhead(raw)
                    // Raw clock = source/subtitle axis; published alongside the mapped position (#107).
                    self.sourceClockSeconds = raw
                    // Live: subtract sessionStartPts to convert to "seconds since first frame"; VOD
                    // subtracts the anchor's session zero (0 for zero-based sources, #107).
                    if self.isLive {
                        let start: Double = {
                            self.liveEdgeLock.lock(); defer { self.liveEdgeLock.unlock() }
                            return self.sessionStartPts.isFinite ? self.sessionStartPts : 0
                        }()
                        self.currentTime = max(0, raw - start)
                    } else {
                        let zero = self.clockSessionZero
                        self.currentTime = zero > 0 ? max(0, raw - zero) : raw
                    }
                }
                // Feed the live edge; publishLiveWindow in the engine reads currentTime for the playhead.
                if self.isLive, let edge = self.liveEdgeSessionTime {
                    self.onLiveEdge?(edge)
                }
            }
    }

    // MARK: - SW diagnostics (1 Hz)

    private let demuxDiag = SWPlaybackDiagState()
    private var diagTickCounter = 0
    private var diagPrevClock = Double.nan
    private var diagPrevDropped = 0
    private var diagPrevEnqueued = 0
    private var diagPrevDelay: TimeInterval = 0
    /// #407: the layer's side of the frame count. `framesEnqueued` is bumped in the decoder callback,
    /// so it counts frames PRODUCED; anything lost between there and the layer is invisible in it and
    /// invisible in the layer's own drop counter too, which only sees frames it received.
    private var diagPrevHandedOver = 0
    private var diagPrevLost = 0
    /// #407: smallest video cushion seen since the last emitted line. The tick runs at 4 Hz and the
    /// line at 1 Hz, so an instantaneous read would miss three quarters of the interval, and a
    /// cushion that dips is exactly what a report of a picture that hitches while the per-second
    /// frame count stays at rate would look like.
    private var diagMinVideoLead = Double.infinity
    /// AE#374: the post-end line reporting the parked clock has been emitted; the session is over and
    /// the line stops rather than repeating itself at 1 Hz for as long as the host holds the engine.
    private var didEmitParkedDiag = false

    /// 1 Hz [SWDiag] line: clock + clock delta, decoded-audio and video lead over the clock, parked
    /// video PACKET FIFO depth, rebuffer state, frames produced vs frames handed to the layer with
    /// the spacing of the timestamps they carried, and the display layer's OWN drop counter with its
    /// per-second delta. The layer counter is the one place render-deadline misses are
    /// visible - swDropped in the memprobe only counts pre-enqueue drops, so a session can
    /// stutter visibly while every 30 s probe reads clean.
    ///
    /// #407: `enq` alone cannot describe cadence. It is a count per wall second taken on the
    /// decoder's side of the layer, so an even 24 fps timeline and one carrying a doubled interval,
    /// a duplicate timestamp or a frame that never reached the layer all read `+24`. `disp`, `lost`
    /// and `dpts` are the three that separate them, and `vLead` says whether the frames were queued
    /// ahead of their presentation time or handed over at their deadline.
    private func emitDiagIfDue(clock: Double) {
        diagTickCounter += 1
        if let frontier = renderer.newestEnqueuedPtsSeconds, clock.isFinite {
            diagMinVideoLead = min(diagMinVideoLead, frontier - clock)
        }
        guard diagTickCounter % 4 == 0 else { return }
        let prevClock = diagPrevClock
        let d = demuxDiag.snapshot
        // AE#374: past end of media the line has no news left, and a 1 Hz report of a falling aLead
        // over a frozen audio PTS is a finding that does not exist. Keep reporting while the tail is
        // still playing out, name the exhaustion, and fall silent on the tick that shows the clock
        // parked on it.
        if d.sourceExhausted {
            if didEmitParkedDiag { return }
            if prevClock.isFinite, clock == prevClock { didEmitParkedDiag = true }
        }
        diagPrevClock = clock
        let lead = d.lastAudioPts.isFinite && clock.isFinite ? d.lastAudioPts - clock : Double.nan
        let enqueued = framesEnqueued
        let dEnq = enqueued - diagPrevEnqueued
        diagPrevEnqueued = enqueued
        let cadence = renderer.takeCadence()
        let dHanded = cadence.handedOver - diagPrevHandedOver
        diagPrevHandedOver = cadence.handedOver
        let dLost = cadence.lostBeforeLayer - diagPrevLost
        diagPrevLost = cadence.lostBeforeLayer
        // #407: how far ahead of the clock the newest admitted frame sat, at its LOWEST over the
        // interval. `parkedPkts` counts undecoded PACKETS, so it says nothing about the video
        // pipeline's depth in TIME, which is what a report of frames arriving late needs.
        let videoLead = diagMinVideoLead.isFinite ? diagMinVideoLead : nil
        diagMinVideoLead = .infinity
        let spacing: String
        if let lo = cadence.minDeltaSeconds, let hi = cadence.maxDeltaSeconds {
            spacing = String(format: "%.1f/%.1f", lo * 1000, hi * 1000)
        } else {
            spacing = "-"
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let m = await self.loadRenderMetrics()
            let dropped = m?.dropped ?? -1
            let dDrop = dropped >= 0 ? dropped - self.diagPrevDropped : 0
            if dropped >= 0 { self.diagPrevDropped = dropped }
            // Accumulated render delay is the one metric that shows frames displayed LATE:
            // a layer that stalls a few seconds and then catches up (picture leaps forward,
            // audio uninterrupted) drops nothing and enqueues on pace - only this grows.
            let delay = m?.accumulatedDelay ?? -1
            let dDelay = delay >= 0 ? delay - self.diagPrevDelay : 0
            if delay >= 0 { self.diagPrevDelay = delay }
            let dclk = clock.isFinite && prevClock.isFinite ? clock - prevClock : Double.nan
            let layer = self.renderer.displayLayer
            let surface = layer.superlayer != nil
                ? "\(Int(layer.bounds.width))x\(Int(layer.bounds.height))" : "DETACHED"
            let r4d: String
            // #344: `*` is visionOS's declared floor (1.0), not "anything newer", and
            // isReadyForDisplay arrived in 1.1. Name the platform or the visionOS build breaks.
            if #available(visionOS 1.1, *) {
                r4d = layer.isReadyForDisplay ? "y" : "n"
            } else {
                r4d = "-"
            }
            EngineLog.emit(
                "[SWDiag] clk=\(String(format: "%.2f", clock)) "
                + "dclk=\(dclk.isFinite ? String(format: "%.2f", dclk) : "-") "
                // AE#549: a stopped clock and a running one whose timebase stalled under a
                // deactivated audio session are the same "dclk=0.00" and different defects.
                + "rate=\(String(format: "%.2f", self.audioOutput?.rate ?? 0)) "
                + "aLead=\(lead.isFinite ? String(format: "%.2f", lead) : "-") "
                + "vLead=\(videoLead.map { String(format: "%.2f", $0) } ?? "-") "
                + "parkedPkts=\(d.parked) rebuf=\(d.rebuffering ? "y" : "n") "
                + (d.sourceExhausted ? "eof=y " : "")
                + "enq=+\(dEnq) disp=+\(dHanded) "
                + "lost=\(cadence.lostBeforeLayer)(\(dLost >= 0 ? "+" : "")\(dLost)) "
                + "dpts=\(spacing) layerDrop=\(dropped)(\(dDrop >= 0 ? "+" : "")\(dDrop)) "
                + "delay=\(delay >= 0 ? String(format: "%.2f", delay) : "-")"
                + "(\(dDelay >= 0 ? "+" : "")\(String(format: "%.2f", dDelay))) "
                + "corrupt=\(m?.corrupted ?? -1) "
                + "status=\(self.renderer.diagStatusName) surf=\(surface) "
                + "r4d=\(r4d)",
                category: .swPlayback
            )
        }
    }

    // MARK: - Errors

    enum HostError: Error, LocalizedError {
        case noVideoStream

        var errorDescription: String? {
            switch self {
            case .noVideoStream: return "Source has no video stream"
            }
        }
    }
}

// MARK: - AVPacket free helper

/// av_packet_free wrapper for the double-pointer FFmpeg API.
func av_packet_free_safe(_ packet: UnsafeMutablePointer<AVPacket>) {
    var p: UnsafeMutablePointer<AVPacket>? = packet
    trackedPacketFree(&p)
}

/// 1 Hz SW-session diagnostics shared between the combined demux loop (writes once per
/// iteration) and the host's time-update timer (reads + emits the [SWDiag] line). The native
/// path has LagDiag; the SW path had only the 30 s memprobe, which is too coarse to see the
/// clock leaps and layer-drop bursts a stuttering session is made of. Lock-guarded.
final class SWPlaybackDiagState: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastAudioPts = Double.nan
    private var _audioFlushGeneration: UInt64 = 0
    private var _parked = 0
    private var _rebuffering = false
    private var _sourceExhausted = false

    /// `lastAudioPts` names the newest audio the pump has enqueued, and the pump is the only writer.
    /// AE#479: a seek flushes that audio on the main actor while the pump is still on the pre-seek
    /// generation, so its next write (one more after a playing seek, none at all while a paused
    /// landing parks it until `play()`) republished a PTS the queue no longer held, and the line read
    /// `aLead` as old PTS minus re-anchored clock (475 s in the field). The write carries the
    /// generation the pump produced it under and is refused for the marker when the flush is newer;
    /// `parked` and `rebuffering` are the pump's own state and stay unconditional.
    func update(lastAudioPts: Double, parked: Int, rebuffering: Bool, generation: UInt64) {
        lock.lock()
        if generation >= _audioFlushGeneration { _lastAudioPts = lastAudioPts }
        _parked = parked
        _rebuffering = rebuffering
        lock.unlock()
    }

    /// The seek path emptied the audio queue: nothing is enqueued, so there is no newest PTS, and
    /// writes from before `generation` describe the queue that was flushed.
    func audioFlushed(generation: UInt64) {
        lock.lock()
        if generation >= _audioFlushGeneration {
            _audioFlushGeneration = generation
            _lastAudioPts = .nan
            _sourceExhausted = false
        }
        lock.unlock()
    }

    /// AE#374: the producer will yield nothing further. Set from the demux loops' end-of-media exit,
    /// read by the diagnostic line, which without it describes a finished session as a drifting one.
    func markSourceExhausted() {
        lock.lock()
        _sourceExhausted = true
        lock.unlock()
    }

    var snapshot: (lastAudioPts: Double, parked: Int, rebuffering: Bool, sourceExhausted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (_lastAudioPts, _parked, _rebuffering, _sourceExhausted)
    }
}

// MARK: - Live recording (AE#560)

extension SoftwarePlaybackHost: LiveRecordingHost {

    func recordingStreamDescriptors() -> [RecordingStreamDescriptor] {
        guard let demuxer else { return [] }
        var out: [RecordingStreamDescriptor] = []
        let videoIndex = demuxer.videoStreamIndex
        for index in [videoIndex, demuxer.audioStreamIndex] where index >= 0 {
            guard let stream = demuxer.stream(at: index) else { continue }
            out.append(RecordingStreamDescriptor(
                sourceStreamIndex: index,
                timeBaseNum: stream.pointee.time_base.num,
                timeBaseDen: stream.pointee.time_base.den,
                codecParameters: stream.pointee.codecpar,
                isVideo: index == videoIndex))
        }
        return out
    }

    func setRecordingSink(_ sink: LiveRecordingSink?) {
        recordingSinkLock.lock()
        recordingSink = sink
        recordingSinkLock.unlock()
    }

    /// Demux thread. Non-blocking by the sink's contract.
    nonisolated func tapForRecording(_ packet: UnsafeMutablePointer<AVPacket>) {
        recordingSinkLock.lock()
        let sink = recordingSink
        recordingSinkLock.unlock()
        guard let sink, let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        sink.accept(
            packetBytes: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)),
            sourceStreamIndex: packet.pointee.stream_index,
            pts: packet.pointee.pts,
            dts: packet.pointee.dts,
            duration: packet.pointee.duration,
            isKeyframe: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
        )
    }
}
