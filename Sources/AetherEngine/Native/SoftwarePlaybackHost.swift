import Foundation
import AVFoundation
import CoreMedia
import Combine
import Libavformat
import Libavcodec
import Libavutil

/// Software-decode playback host. Parallel to `NativeAVPlayerHost` but
/// drives decode + render through the engine's own FFmpeg/dav1d
/// pipeline instead of handing the source to AVPlayer. Used for codecs
/// AVPlayer cannot decode on the active platform — primarily AV1 on
/// Apple TV today, where Apple ships dav1d on iOS / macOS but not on
/// tvOS, and no Apple TV chip has HW AV1.
///
/// The pipeline:
///
/// ```
/// Demuxer ─┬─ video pkt ──► SoftwareVideoDecoder ──► SampleBufferRenderer ──► AVSampleBufferDisplayLayer
///          │                                                                     │
///          └─ audio pkt ──► AudioDecoder ──► CMSampleBuffer ──► AudioOutput ─────┘
///                                                                  (AVSampleBufferRenderSynchronizer
///                                                                   is the master clock; display layer
///                                                                   is attached to it for A/V sync)
/// ```
///
/// AV1 sources in the wild almost never carry Atmos or Dolby Vision
/// (DV is HEVC-profile-driven; Atmos mastering runs in HEVC), so this
/// host intentionally skips the EAC3+JOC fMP4 pipe + DV HDMI handshake
/// that the native path provides. If those gaps ever bite an AV1+DV or
/// AV1+Atmos source, route handling lives in `AetherEngine.load` and
/// can be revisited there without changing this host.
@MainActor
final class SoftwarePlaybackHost {

    // MARK: - Published state (mirrors NativeAVPlayerHost surface)

    /// Frames successfully enqueued into the AVSampleBufferDisplayLayer.
    /// Incremented from the decoder callback (demux thread), read by the
    /// engine's LiveTelemetrySampler at 1 Hz to compute observed FPS on
    /// the software path. Lock-guarded: the previous bare property was a
    /// MainActor-isolated var mutated off-main (the compiler only let it
    /// through because the callback isn't @Sendable-typed).
    nonisolated var framesEnqueued: Int {
        framesEnqueuedLock.lock()
        defer { framesEnqueuedLock.unlock() }
        return _framesEnqueued
    }
    /// Increments and returns the PREVIOUS value (the first-frame log
    /// site needs to know whether this was frame zero).
    nonisolated private func bumpFramesEnqueued() -> Int {
        framesEnqueuedLock.lock()
        defer { framesEnqueuedLock.unlock() }
        let previous = _framesEnqueued
        _framesEnqueued &+= 1
        return previous
    }
    private let framesEnqueuedLock = NSLock()
    nonisolated(unsafe) private var _framesEnqueued: Int = 0

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    @Published private(set) var failureMessage: String?
    @Published private(set) var didReachEnd: Bool = false

    /// Fires (off-main) once per session the first time HDR10+ dynamic
    /// metadata appears on a decoded frame. Hooked by `AetherEngine` to
    /// upgrade the published `videoFormat` from `.hdr10` → `.hdr10Plus`.
    nonisolated(unsafe) var onFirstHDR10PlusDetected: (@Sendable () -> Void)?

    // MARK: - Output

    /// The display layer the engine attaches to the bound `AetherPlayerView`.
    /// Owned by `SampleBufferRenderer`; surfaced here so the engine can
    /// hand it to the view via the same `attach(_ layer: CALayer)` entry
    /// point it uses for `AVPlayerLayer`.
    var displayLayer: AVSampleBufferDisplayLayer { renderer.displayLayer }

    // MARK: - Internals

    private let renderer: SampleBufferRenderer
    /// Video decoder. Swapped per codec at `load()` time:
    /// `SoftwareVideoDecoder` for AV1 / VP9 (libavcodec / dav1d), and
    /// `HardwareVideoDecoder` for HEVC (VTDecompressionSession HW).
    /// The protocol is `VideoDecodingPipeline` so the demux loop
    /// stays codec-agnostic.
    private var videoDecoder: any VideoDecodingPipeline
    private var audioDecoder: AudioDecoder?
    private var audioOutput: AudioOutput?
    private var demuxer: Demuxer?

    /// Background queue the demux loop runs on. One queue per host so
    /// hosts created across rapid load() calls don't fight over the
    /// same execution context.
    private let demuxQueue = DispatchQueue(label: "engine.sw.demux", qos: .userInitiated)

    /// Lock guarding the playing / stop flags. Read on the demux thread
    /// every iteration, written on the main actor from play/pause/stop.
    private let flagsLock = NSLock()
    nonisolated(unsafe) private var _isPlaying: Bool = false
    nonisolated(unsafe) private var _stopRequested: Bool = false

    /// Condition the demux thread waits on while paused so it doesn't
    /// busy-loop reading packets that would just stack up.
    private let demuxCondition = NSCondition()

    private var videoStreamIndex: Int32 = -1
    private var audioStreamIndex: Int32 = -1

    /// Video stream time base (seconds per PTS unit) captured at load.
    /// Used both to convert raw packet PTS to seconds for the DVR ring
    /// and, on the replay path, to convert ring seconds back into the
    /// time_base units the decoders expect on a reconstructed AVPacket.
    private var videoTimeBaseSeconds: Double = 0
    /// Audio stream time base (seconds per PTS unit), same role as the
    /// video one for replayed audio packets. 0 when there is no audio.
    private var audioTimeBaseSeconds: Double = 0

    // MARK: - Live / DVR

    /// Disk-spooled packet ring backing the software-path DVR rewind
    /// buffer. Non-nil only for a live session loaded with a DVR window
    /// (`dvrWindowSeconds != nil`). Appended on the demux thread (the
    /// ring is internally locked), read on the seek path. Closed + niled
    /// in `stop()`.
    nonisolated(unsafe) private var dvrRing: PacketRingBuffer?

    /// True for a live session. Gates ring fill, edge publishing, and the
    /// live-DVR seek branch so the non-live SW path is untouched.
    private var isLive: Bool = false

    /// Session-start PTS in seconds (the first packet's PTS, video or
    /// audio, whichever arrives first). The SW session timeline (and the
    /// engine's `currentTime` on this path) is "seconds since first
    /// frame", so the session-relative edge is `newestPts - sessionStartPts`.
    /// `nan` until the first packet is seen.
    nonisolated(unsafe) private var sessionStartPts: Double = .nan

    /// Newest source PTS (seconds) demuxed so far, tracked on the demux
    /// thread. The live edge in session time is `newestSourcePts - sessionStartPts`.
    nonisolated(unsafe) private var newestSourcePts: Double = .nan

    /// Guards `sessionStartPts` / `newestSourcePts` against the demux
    /// thread writing while the main-actor time tick reads them.
    private let liveEdgeLock = NSLock()

    /// Newest demuxed source position in session time (seconds), i.e. how
    /// far ahead of the playhead the demuxer has pulled and demuxed data
    /// from the (possibly remote) source (AetherEngine#54). This is the
    /// SW path's buffered frontier; the engine publishes it as
    /// `clock.bufferedPosition`. Returns 0 before the first packet. Reads
    /// the same demux-thread state as the live edge, under `liveEdgeLock`.
    nonisolated var bufferedSessionTime: Double {
        liveEdgeLock.lock()
        defer { liveEdgeLock.unlock() }
        guard sessionStartPts.isFinite, newestSourcePts.isFinite else { return 0 }
        return max(0, newestSourcePts - sessionStartPts)
    }

    // MARK: - Live reader/feeder split (DVR sessions)
    //
    // A live session WITH a DVR ring runs two loops instead of the
    // combined demux loop:
    //
    //   reader (demuxQueue): source -> discontinuity reconcile -> edge
    //     note -> ring append. Runs regardless of play/pause, so the
    //     ring keeps filling during a pause (pause = timeshift) and the
    //     source connection never backs up.
    //   feeder (feedQueue): ring cursor -> decoders -> renderer, paced
    //     by the renderer's back-pressure. Parks while paused; resumes
    //     at the cursor, so pause/resume and DVR rewinds are the same
    //     operation (move the cursor). This replaces the old
    //     synchronous whole-tail replay in seekLiveDVR, which decoded
    //     tens of thousands of packets in a tight loop on the main
    //     actor without back-pressure (multi-second UI freeze, renderer
    //     queue overflow, decoded-frame memory spike).
    //
    // Live-only sessions (no DVR window -> no ring) keep the combined
    // loop: there is no buffer to time-shift into, so pause keeps its
    // old park-the-loop behavior.

    /// Background queue for the live feeder loop.
    private let feedQueue = DispatchQueue(label: "engine.sw.feed", qos: .userInitiated)

    /// Guards `_feedCursor` / `_sourceEnded`.
    private let feedLock = NSLock()
    /// Ring sequence number of the NEXT packet the feeder will decode.
    nonisolated(unsafe) private var _feedCursor: Int = 0
    /// Set when the reader hit EOF / a read error on the live source;
    /// the feeder drains the ring and then reports the end.
    nonisolated(unsafe) private var _sourceEnded = false

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

    /// Reposition the cursor (DVR seek / fell-out-of-window clamp) and
    /// wake the feeder.
    nonisolated private func setFeedCursor(_ value: Int) {
        feedLock.lock()
        _feedCursor = value
        feedLock.unlock()
        demuxCondition.lock()
        demuxCondition.broadcast()
        demuxCondition.unlock()
    }

    /// Clamp the cursor to `first` only if it still equals `old` (the
    /// feeder detected it fell below the retained window).
    nonisolated private func clampFeedCursor(from old: Int, to first: Int) {
        feedLock.lock()
        if _feedCursor == old { _feedCursor = first }
        feedLock.unlock()
    }

    nonisolated private var sourceEnded: Bool {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _sourceEnded }
        set { feedLock.lock(); _sourceEnded = newValue; feedLock.unlock() }
    }

    /// Synchronous helper so the async `load()` can reset the feeder
    /// state (NSLock is unavailable from async contexts).
    nonisolated private func resetFeederState() {
        feedLock.lock()
        _feedCursor = 0
        _sourceEnded = false
        _clockArmed = false
        feedLock.unlock()
    }

    /// Whether the synchronizer master clock has been anchored for this
    /// session (first decoded audio buffers, first video packet on
    /// video-only, or an explicit seekClock from a seek path). Shared
    /// between the feeder loop and the seek paths so a DVR seek issued
    /// before the feeder's own arming doesn't get its clock position
    /// overwritten by a late re-arm.
    nonisolated(unsafe) private var _clockArmed = false
    nonisolated private var clockArmed: Bool {
        get { feedLock.lock(); defer { feedLock.unlock() }; return _clockArmed }
        set { feedLock.lock(); _clockArmed = newValue; feedLock.unlock() }
    }

    /// Bumped at the head of every seek. The combined demux loop
    /// re-checks it around its blocking `readPacket`, so a packet that
    /// was in flight when the seek flushed the pipeline is discarded
    /// instead of decoded: a stale pre-seek frame with pts past the
    /// target would clear the renderer's one-shot skip threshold, and
    /// the anchor-keyframe frames before the target then played as a
    /// visible fast-forward burst.
    nonisolated(unsafe) private var _seekGeneration: UInt64 = 0
    nonisolated private var seekGeneration: UInt64 {
        feedLock.lock(); defer { feedLock.unlock() }; return _seekGeneration
    }
    nonisolated private func bumpSeekGeneration() {
        feedLock.lock(); _seekGeneration &+= 1; feedLock.unlock()
    }

    /// Set when pause() stopped the synchronizer, so play() knows to
    /// restore the rate. play() previously never resumed the
    /// synchronizer at all (pause() set its rate to 0, play() only
    /// flipped `isPlaying`), leaving the clock frozen after any
    /// pause/resume on the SW path.
    private var pausedByHost = false

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

    /// Periodic mirror of `audioOutput.currentTimeSeconds` into the
    /// published `currentTime`. 250 ms is the same cadence the pre-
    /// collapse engine used; granular enough for transport-bar UX,
    /// cheap enough to ignore.
    private var timeTimer: AnyCancellable?

    /// Caching the chosen rate so resume() restores the right speed
    /// after a pause without the host needing to know its history.
    private var lastRate: Float = 1.0

    /// Source-position seconds the host opened at, captured so the
    /// demux loop can align the synchronizer's master clock to the
    /// first decoded sample's PTS. Cold-start at 0 is fine because
    /// the source's first packet PTS is also ~0; resume / audio-switch
    /// reload with a non-zero startPosition would otherwise leave the
    /// clock at .zero while samples arrive with PTS=startPosition,
    /// causing the synchronizer to wait `startPosition` seconds
    /// before rendering — visible as "frozen frame, no audio".
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

    // MARK: - Init

    init() {
        self.renderer = SampleBufferRenderer()
        // Default to the software decoder; load() swaps it for the
        // VT-backed one when the source's video codec is HEVC.
        self.videoDecoder = SoftwareVideoDecoder()
    }

    // MARK: - Load

    func load(
        demuxer dem: Demuxer,
        startPosition: Double?,
        audioSourceStreamIndex: Int32?,
        isLive: Bool = false,
        dvrWindowSeconds: Double? = nil
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

        // Build the DVR rewind ring for a live session that opted into a
        // window. Live-only (no window) keeps unbounded forward playback
        // with no rewind buffer. Scratch dir mirrors SegmentCache's
        // <tmpdir>/aether-segments/<uuid> convention so stale-dir cleanup
        // and disk accounting stay uniform.
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

        // Release-visible session-start log so the diagnostic overlay
        // shows the SW path was entered at all. Without this, a SW-path
        // session that black-screens looks identical in logs to a session
        // that never dispatched here (DrHurt #4 MPEG-4 "not much on log").
        let vCodecID = vStream.pointee.codecpar?.pointee.codec_id.rawValue ?? 0
        let aIdx = audioSourceStreamIndex ?? dem.audioStreamIndex
        let aCodecID: UInt32 = aIdx >= 0
            ? (dem.stream(at: aIdx)?.pointee.codecpar?.pointee.codec_id.rawValue ?? 0)
            : 0
        EngineLog.emit(
            "[SWHost] session start: videoCodecID=\(vCodecID) "
            + "audioCodecID=\(aCodecID == 0 ? "none" : String(aCodecID)) "
            + "duration=\(String(format: "%.1f", dem.duration))s",
            category: .swPlayback
        )

        // Pick the right decoder for the source codec. HEVC routes
        // to VTDecompressionSession (HW); AV1 / VP9 / anything else
        // stays on libavcodec via SoftwareVideoDecoder. The current
        // instance is replaced wholesale so the previous decoder's
        // state cannot bleed into the new session.
        if let codecpar = vStream.pointee.codecpar,
           codecpar.pointee.codec_id == AV_CODEC_ID_HEVC {
            videoDecoder.close()
            videoDecoder = HardwareVideoDecoder()
            EngineLog.emit(
                "[SWHost] selected HardwareVideoDecoder (VT HEVC) for codec_id=\(codecpar.pointee.codec_id.rawValue)",
                category: .swPlayback
            )
        } else if !(videoDecoder is SoftwareVideoDecoder) {
            // Restoring the software default if a previous load left
            // a HW decoder in place and this load isn't HEVC.
            videoDecoder.close()
            videoDecoder = SoftwareVideoDecoder()
        }

        // Detect HDR transfer characteristic from the source codecpar
        // and flip the display layer into HDR mode before any frames
        // arrive. Without this `displayLayer.preferredDynamicRange`
        // stays at `.standard` and AVSampleBufferDisplayLayer renders
        // PQ / HLG content desaturated. Matches what AVPlayer's
        // internal pipeline does implicitly via AVAsset metadata.
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

        try videoDecoder.open(stream: vStream) { [weak self] pixelBuffer, pts, hdr10PlusData in
            // Decoder callback fires on the demux thread. SampleBufferRenderer
            // is internally locked + safe to call off-main; the engine's
            // public state stays untouched here, only the layer's frame queue.
            self?.renderer.enqueue(pixelBuffer: pixelBuffer, pts: pts, hdr10PlusData: hdr10PlusData)
            // Release-visible first-frame-enqueued log. After [SWDecoder]
            // Opened and [SWHost] session start, this is the next milestone:
            // proves the demux loop reached a video packet, the decoder
            // produced a pixel buffer, and the renderer accepted the
            // enqueue. If this never fires after several seconds, the
            // failure is between decoder-open and first-frame.
            if self?.bumpFramesEnqueued() == 0 {
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
        videoDecoder.onFirstHDR10PlusDetected = { [weak self] in
            self?.onFirstHDR10PlusDetected?()
        }

        let resolvedAudioIdx: Int32 = audioSourceStreamIndex ?? dem.audioStreamIndex
        if resolvedAudioIdx >= 0, let aStream = dem.stream(at: resolvedAudioIdx) {
            let aDec = AudioDecoder()
            do {
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
        // AudioOutput owns the AVSampleBufferRenderSynchronizer, which is
        // the MASTER CLOCK for the whole session, video included. It is
        // created unconditionally: a video-only source (no audio stream,
        // or audio decoder open failure above) previously got no clock
        // at all, rendering one frozen frame with currentTime stuck at 0.
        // The demux/feeder loops arm the clock off the first VIDEO frame
        // when there is no audio decoder. The display layer is NOT yet
        // attached to the synchronizer here; that happens in play() after
        // the engine has hung the layer in the bound view's CALayer
        // hierarchy (attaching a free-floating layer fails with
        // `FigVideoQueueRemote err=-12080` after the first enqueue on
        // tvOS 26+).
        self.audioOutput = AudioOutput()

        // Reset the live feeder state for the new session.
        resetFeederState()

        if let start = startPosition, start > 0 {
            dem.seek(to: start)
            // Mirror the same skip-PTS + clock-alignment dance the
            // seek() path performs, so the demux loop drops pre-
            // keyframe frames and the synchronizer starts ticking at
            // the resume offset (not at .zero) once the first audio
            // sample arrives.
            let startTime = CMTime(seconds: start, preferredTimescale: 90000)
            videoDecoder.skipUntilPTS = startTime
            renderer.setSkipThreshold(startTime)
            initialClockTime = startTime
            currentTime = start
        } else {
            initialClockTime = .zero
        }

        startTimeUpdates()
        isReady = true
        // Demux loop only spins up once play() actually fires; no point
        // pulling packets while the synchronizer hasn't claimed the
        // layer yet.
    }

    // MARK: - Transport

    func play() {
        // First play() since load(): claim the display layer for the
        // synchronizer (now that the engine has hung it in the bound
        // view's CALayer hierarchy via presentCurrentLayer) and kick
        // off the demux loop. Idempotent across repeated play() calls;
        // the layer-attach + loop-spin-up only fire on the first one.
        // Resume the synchronizer after a pause(). Handled BEFORE the
        // demuxLoopStarted flip below: the guard distinguishes a real
        // resume (loop already ran, clock armed by its first decoded
        // sample) from a pause()-before-first-play(), where an eager
        // setRate would tick the un-anchored clock forward through the
        // spin-up and drop the first samples as "in the past". With the
        // flip first, the guard was always true and the cold case
        // eager-started anyway (mirrors AudioPlaybackHost's ordering).
        if pausedByHost {
            pausedByHost = false
            if demuxLoopStarted {
                audioOutput?.setRate(lastRate)
            }
        }
        if !demuxLoopStarted, let aOut = audioOutput {
            aOut.attachVideoLayer(renderer.displayLayer)
        }
        if !demuxLoopStarted {
            demuxLoopStarted = true
            startDemuxLoop()
        }
        // Don't eager-start the audio synchronizer on a cold start: the
        // demux loop arms the master clock via `seekClock` on the first
        // decoded audio sample, so the clock's time-zero aligns with
        // that sample's PTS.
        rate = lastRate
        isPlaying = true
    }

    /// Latched once the first `play()` has wired the audio synchronizer
    /// to the display layer and spun up the demux loop. Subsequent
    /// `play()` calls only flip `isPlaying` without re-attaching.
    private var demuxLoopStarted: Bool = false

    func pause() {
        audioOutput?.pause()
        pausedByHost = true
        rate = 0
        isPlaying = false
    }

    func setRate(_ newRate: Float) {
        lastRate = newRate
        audioOutput?.setRate(newRate)
        rate = newRate
    }

    func seek(to seconds: Double) async {
        guard let dem = demuxer else { return }
        // Pause the demux loop so we don't race the seek against
        // in-flight packet reads, and invalidate any packet the loop has
        // already pulled out of the demuxer (see _seekGeneration).
        bumpSeekGeneration()
        let wasPlaying = isPlaying
        isPlaying = false

        videoDecoder.flush()
        audioDecoder?.flush()
        renderer.flush()
        audioOutput?.flush()

        // Live + DVR rewind: a live source CANNOT be demuxer-seeked (it
        // is a forward-only stream). Instead we reseed the decoder from
        // the retained ring. The demux loop, once resumed, keeps reading
        // NEW packets forward from where the live source already sits
        // (its read position is untouched), so playback shows the
        // buffered past from the seek target and then catches back up to
        // live as the loop continues appending + decoding fresh packets.
        if isLive, let ring = dvrRing {
            await seekLiveDVR(to: seconds, ring: ring, wasPlaying: wasPlaying)
            return
        }

        dem.seek(to: seconds)

        // Drop frames before the seek target until a keyframe lines up.
        // SoftwareVideoDecoder honors `skipUntilPTS` internally per
        // pre-collapse contract.
        let targetTime = CMTime(seconds: seconds, preferredTimescale: 90000)
        videoDecoder.skipUntilPTS = targetTime
        renderer.setSkipThreshold(targetTime)

        currentTime = seconds

        if wasPlaying {
            // Jump the synchronizer's master clock to the seek target so
            // PTS-stamped samples decoded after the seek align with the
            // clock. Calling `start(at: .zero)` here would wedge the
            // queue: samples come back with PTS=seekTarget but the clock
            // is at 0, so the synchronizer waits seekTarget seconds
            // before rendering — visible as "frozen frame, no audio"
            // until the wait elapses, plus the renderer's queue fills
            // up and trips err=-12080 from FigVideoQueueRemote.
            audioOutput?.seekClock(to: targetTime, rate: lastRate)
            isPlaying = true
        } else {
            // Paused seek: anchor the clock at the target with rate 0 so
            // the eventual play() resumes from the SEEK position. Without
            // this, play()'s synchronizer resume continued from the stale
            // pre-seek clock: a forward scrub froze the frame for the
            // scrubbed span of wall time, a backward scrub made every
            // sample 'late' and the renderer dropped everything.
            audioOutput?.seekClock(to: targetTime, rate: 0)
            pausedByHost = true
        }
        // The clock is positioned either way; the demux loop must not
        // re-arm it at the (stale) initialClockTime. Without this latch a
        // seek landing before the first decoded audio packet got snapped
        // back to the session start by the loop's one-shot arming (frozen
        // picture until the clock walked to the target). The DVR path
        // (seekLiveDVR) has carried the same latch since the feeder split.
        clockArmed = true
    }

    /// Live DVR rewind: reseed the decoder pipeline from the retained
    /// ring without touching the live demuxer's read position.
    ///
    /// `targetSession` is session-relative seconds (the engine clock).
    /// The ring + audio synchronizer + sample PTS all live on the source
    /// PTS axis, so we map via the captured `sessionStartPts`. After this
    /// returns and the loop resumes, the demux loop keeps reading NEW
    /// packets forward from the live source, so the buffered past plays
    /// out from the target and then catches back up to live.
    private func seekLiveDVR(to targetSession: Double, ring: PacketRingBuffer, wasPlaying: Bool) async {
        // Map session time to source PTS. sessionStartPts is set by the
        // demux loop on the first packet; if it has not been seen yet
        // (extremely early seek), treat session == source.
        let startPts: Double = {
            liveEdgeLock.lock(); defer { liveEdgeLock.unlock() }
            return sessionStartPts.isFinite ? sessionStartPts : 0
        }()
        let targetSource = startPts + targetSession

        // Skip threshold (in source PTS) drops frames decoded from the
        // anchor keyframe up to the requested target, so the playhead
        // lands exactly at `targetSource` even though decoding resumes at
        // the earlier keyframe. Set BEFORE moving the cursor so the
        // decoder honors it on the first decoded frame.
        let targetTime = CMTime(seconds: targetSource, preferredTimescale: 90000)
        videoDecoder.skipUntilPTS = targetTime
        renderer.setSkipThreshold(targetTime)

        // Anchor the master clock at the target so the post-skip samples
        // (which carry source PTS >= targetSource) align with the clock.
        // Paused DVR scrubs anchor at rate 0 so the resume continues from
        // the scrub position (see the VOD seek path for the rationale).
        if wasPlaying {
            audioOutput?.seekClock(to: targetTime, rate: lastRate)
        } else {
            audioOutput?.seekClock(to: targetTime, rate: 0)
            pausedByHost = true
        }
        // The clock is positioned either way; the feeder must not re-arm
        // it at the (earlier) anchor keyframe's PTS.
        clockArmed = true

        // Reposition the feeder cursor onto the newest keyframe at or
        // before the target (clamped to the oldest retained packet, which
        // eviction keeps keyframe-aligned; on an empty ring the cursor
        // parks at the next append). The feeder streams from there with
        // renderer back-pressure; this replaces the old synchronous
        // whole-tail replay (see the reader/feeder split docs).
        let seq = ring.seq(forKeyframeAtOrBefore: targetSource) ?? ring.seqBounds.first
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

    /// Reconstruct an AVPacket from a ring packet and route it to the
    /// same decode entry the demux/feeder loops use (video -> the video
    /// decoder, audio -> the audio decoder + audio output). PTS is
    /// converted from ring seconds back into the owning stream's
    /// time_base units so the decoders recover the identical source PTS
    /// on the replayed sample. The ring records `isVideo` per entry so
    /// the route is unambiguous (a video non-keyframe and an audio packet
    /// both carry `isKeyframe == false`). Returns true when audio sample
    /// buffers were enqueued (used by the feeder's clock arming).
    @discardableResult
    nonisolated private static func feedRingPacket(
        _ pkt: PacketRingBuffer.Packet,
        videoDecoder: any VideoDecodingPipeline,
        audioDecoder: AudioDecoder?,
        audioOutput: AudioOutput?,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double
    ) -> Bool {
        let tbSec = pkt.isVideo ? videoTimeBaseSeconds : audioTimeBaseSeconds
        guard tbSec > 0, !pkt.bytes.isEmpty else { return false }

        guard var avPkt: UnsafeMutablePointer<AVPacket>? = trackedPacketAlloc(),
              let p = avPkt else { return false }
        defer { trackedPacketFree(&avPkt) }

        // Allocate a ref-counted buffer and copy the stored bytes in, so
        // the decoder owns a normal AVBufferRef-backed packet just like
        // one from av_read_frame.
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
            videoDecoder.decode(packet: p)
            return false
        } else if let aDec = audioDecoder, let aOut = audioOutput {
            var enqueued = false
            for buf in aDec.decode(packet: p) {
                aOut.enqueue(sampleBuffer: buf)
                enqueued = true
            }
            return enqueued
        }
        return false
    }

    func stop() {
        stopRequested = true
        isPlaying = false
        timeTimer?.cancel()
        timeTimer = nil

        dvrRing?.close()
        dvrRing = nil
        liveEdgeLock.lock()
        sessionStartPts = .nan
        newestSourcePts = .nan
        liveEdgeLock.unlock()

        if let aOut = audioOutput {
            aOut.stop()
            aOut.detachVideoLayer(renderer.displayLayer)
        }
        audioOutput = nil
        audioDecoder?.close()
        audioDecoder = nil
        videoDecoder.close()
        renderer.flush()
        demuxer?.close()
        demuxer = nil

        isReady = false
    }

    var volume: Float {
        get { audioOutput?.volume ?? 1.0 }
        set { audioOutput?.volume = newValue }
    }

    // MARK: - Demux loop

    /// Captures the dependencies the demux loop needs as locals so the
    /// loop runs fully off the main actor without re-entering it on
    /// every packet. All captured types are `@unchecked Sendable` with
    /// internal locks, so off-main use is safe.
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
        let initialRate = lastRate
        let ring = dvrRing
        let vTbSec = videoTimeBaseSeconds
        let aTbSec = audioTimeBaseSeconds
        let liveSession = isLive
        // Demux-thread edge tracker. Records the session-start PTS once and
        // the newest PTS continuously so the main-actor time tick can read
        // the live edge. Captured weakly so it can't pin `self` past stop.
        let noteEdge: @Sendable (Double) -> Void = { [weak self] ptsSec in
            guard let self, ptsSec.isFinite else { return }
            self.liveEdgeLock.lock()
            if self.sessionStartPts.isNaN { self.sessionStartPts = ptsSec }
            if self.newestSourcePts.isNaN || ptsSec > self.newestSourcePts {
                self.newestSourcePts = ptsSec
            }
            self.liveEdgeLock.unlock()
        }
        let getIsPlaying: @Sendable () -> Bool = { [weak self] in self?.isPlaying ?? false }
        let getStopRequested: @Sendable () -> Bool = { [weak self] in self?.stopRequested ?? true }
        let onError: @Sendable (String) -> Void = { [weak self] msg in
            Task { @MainActor [weak self] in self?.failureMessage = msg }
        }
        let onEnd: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.didReachEnd = true
                self?.isPlaying = false
            }
        }

        // Live with a DVR ring: reader/feeder split (see the docs at the
        // live section above). The reader fills the ring regardless of
        // play/pause; the feeder decodes from its cursor with renderer
        // back-pressure. Live-only (no ring) and VOD keep the combined
        // loop below.
        let getClockArmed: @Sendable () -> Bool = { [weak self] in
            self?.clockArmed ?? true
        }
        let setClockArmed: @Sendable () -> Void = { [weak self] in
            self?.clockArmed = true
        }
        let getSeekGeneration: @Sendable () -> UInt64 = { [weak self] in
            self?.seekGeneration ?? 0
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
                    onSourceEnded: setSourceEnded
                )
            }
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
                    videoTimeBaseSeconds: vTbSec,
                    audioTimeBaseSeconds: aTbSec,
                    readCursor: readCursor,
                    advanceCursor: advanceCursor,
                    clampCursor: clampCursor,
                    initialRate: initialRate,
                    isPlaying: getIsPlaying,
                    stopRequested: getStopRequested,
                    sourceEnded: getSourceEnded,
                    clockArmed: getClockArmed,
                    markClockArmed: setClockArmed,
                    onEnd: onEnd
                )
            }
            return
        }

        demuxQueue.async {
            Self.runDemuxLoop(
                demuxer: dem,
                videoDecoder: vDec,
                videoStreamIndex: vIdx,
                audioDecoder: aDec,
                audioOutput: aOut,
                audioStreamIndex: aIdx,
                renderer: rndr,
                condition: condition,
                initialClockTime: initialClock,
                initialRate: initialRate,
                ring: ring,
                videoTimeBaseSeconds: vTbSec,
                audioTimeBaseSeconds: aTbSec,
                isLive: liveSession,
                noteEdge: noteEdge,
                isPlaying: getIsPlaying,
                stopRequested: getStopRequested,
                clockArmed: getClockArmed,
                markClockArmed: setClockArmed,
                seekGeneration: getSeekGeneration,
                onError: onError,
                onEnd: onEnd
            )
        }
    }

    // MARK: - Live reader loop (DVR sessions)

    /// Source -> ring, unconditionally (play, pause, scrub). No decoding
    /// here: the feeder owns the decoders. Discontinuity reconciliation
    /// happens BEFORE the ring append, so the ring carries one
    /// continuous timeline and the feeder (which is usually elsewhere on
    /// the timeline) never sees the raw jump; unlike the combined loop
    /// there is consequently no decoder flush at the seam.
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
        onSourceEnded: @Sendable () -> Void
    ) {
        let discontinuityThresholdSeconds = 10.0
        var prevRawVideoPtsSec = Double.nan
        var frameIntervalSec = 0.0
        var discontinuityOffsetSec = 0.0
        var loggedSWDiscontinuity = false
        var lastSeenExtradata: Data? = nil

        defer {
            // Whatever the exit path, wake the feeder so it can drain +
            // report the end instead of sleeping out its wait timeout.
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }

        while !stopRequested() {
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                EngineLog.emit("[SWHost] live reader read failed: \(error)", category: .swPlayback)
                onError("Playback error: \(error.localizedDescription)")
                onSourceEnded()
                break
            }
            guard let packet else {
                EngineLog.emit("[SWHost] live reader EOF (source lost)", category: .swPlayback)
                onSourceEnded()
                break
            }

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

            // NOPTS repair. In the reader/feeder split the ring is the
            // ONLY route to the decoder, and the ring append below gates
            // on a valid pts: dropping NOPTS packets (not unusual for
            // MPEG-TS / field-coded H.264) starved the decoder of
            // reference frames and produced decode artifacts in DVR mode
            // (the combined loop decodes such packets regardless).
            // Synthesize a pts from the dts; decode order matches
            // presentation order for the typical field-pair case, and a
            // slightly mis-ordered ring entry beats a missing reference.
            if streamIdx == videoStreamIndex || streamIdx == audioStreamIndex,
               packet.pointee.pts == Int64.min, packet.pointee.dts != Int64.min {
                packet.pointee.pts = packet.pointee.dts
            }

            // Live PTS-discontinuity detection + reconciliation, same
            // accrual as the combined loop (see its comment block).
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
            }

            av_packet_unref(packet)
            av_packet_free_safe(packet)
        }
    }

    // MARK: - Live feeder loop (DVR sessions)

    /// Ring cursor -> decoders -> renderer, paced by the renderer's
    /// back-pressure. Parks while paused (the reader keeps filling the
    /// ring, so pause IS timeshift); a DVR seek just moves the cursor.
    nonisolated private static func runLiveFeederLoop(
        videoDecoder: any VideoDecodingPipeline,
        audioDecoder: AudioDecoder?,
        audioOutput: AudioOutput?,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32,
        renderer: SampleBufferRenderer,
        condition: NSCondition,
        ring: PacketRingBuffer,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        readCursor: @Sendable () -> Int,
        advanceCursor: @Sendable (Int) -> Void,
        clampCursor: @Sendable (Int, Int) -> Void,
        initialRate: Float,
        isPlaying: @Sendable () -> Bool,
        stopRequested: @Sendable () -> Bool,
        sourceEnded: @Sendable () -> Bool,
        clockArmed: @Sendable () -> Bool,
        markClockArmed: @Sendable () -> Void,
        onEnd: @Sendable () -> Void
    ) {
        while !stopRequested() {
            if !isPlaying() {
                condition.lock()
                while !isPlaying() && !stopRequested() {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                }
                condition.unlock()
                continue
            }

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
                continue
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
                    continue
                }
                // At the live edge (cursor == end): wait for the reader's
                // next append, or finish when the source is gone and the
                // ring is fully drained.
                if sourceEnded() {
                    videoDecoder.flush()
                    audioDecoder?.flush()
                    renderer.drainReorderBuffer()
                    onEnd()
                    break
                }
                condition.lock()
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.25))
                condition.unlock()
                continue
            }

            if pkt.isVideo {
                // Back-pressure against the renderer's actual queue, same
                // as the combined loop. Also bail to the pause-park when
                // pause() lands mid-wait, WITHOUT consuming the packet.
                while !renderer.isReadyForMoreMediaData && !stopRequested() && isPlaying() {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                if stopRequested() { break }
                if !isPlaying() { continue }
            }

            let producedAudio = feedRingPacket(
                pkt,
                videoDecoder: videoDecoder,
                audioDecoder: audioDecoder,
                audioOutput: audioOutput,
                videoStreamIndex: videoStreamIndex,
                audioStreamIndex: audioStreamIndex,
                videoTimeBaseSeconds: videoTimeBaseSeconds,
                audioTimeBaseSeconds: audioTimeBaseSeconds
            )

            // Arm the master clock once, at the first fed packet's PTS
            // (samples carry source PTS; anchoring at the actual first
            // PTS renders immediately instead of waiting out the gap
            // from .zero). Audio sessions arm on the first decoded audio
            // buffers; video-only sessions arm on the first video packet
            // (previously NO clock was armed without audio: one frozen
            // frame, currentTime stuck at 0).
            if !clockArmed(), let aOut = audioOutput {
                let shouldArm = (audioDecoder == nil) ? pkt.isVideo : producedAudio
                if shouldArm {
                    let armTime = CMTime(seconds: pkt.pts, preferredTimescale: 90000)
                    // initialRate, not a hard 1.0: a rate set before the
                    // arming would otherwise be silently reset to 1x
                    // until the next setRate (the combined loop already
                    // arms with initialRate).
                    aOut.seekClock(to: armTime, rate: initialRate)
                    markClockArmed()
                }
            }

            advanceCursor(cursor)
        }
    }

    /// Hot-path demux loop modeled on the pre-collapse pattern. Reads
    /// packets from the demuxer, dispatches by stream index, applies
    /// inline back-pressure on the video display layer's
    /// `isReadyForMoreMediaData` so the decoder doesn't outpace the
    /// renderer. EOF flushes both decoders and the renderer's reorder
    /// buffer, then flips the engine state via the published
    /// `didReachEnd` mirror.
    nonisolated private static func runDemuxLoop(
        demuxer: Demuxer,
        videoDecoder: any VideoDecodingPipeline,
        videoStreamIndex: Int32,
        audioDecoder: AudioDecoder?,
        audioOutput: AudioOutput?,
        audioStreamIndex: Int32,
        renderer: SampleBufferRenderer,
        condition: NSCondition,
        initialClockTime: CMTime,
        initialRate: Float,
        ring: PacketRingBuffer?,
        videoTimeBaseSeconds: Double,
        audioTimeBaseSeconds: Double,
        isLive: Bool,
        noteEdge: @Sendable (Double) -> Void,
        isPlaying: @Sendable () -> Bool,
        stopRequested: @Sendable () -> Bool,
        clockArmed: @Sendable () -> Bool,
        markClockArmed: @Sendable () -> Void,
        seekGeneration: @Sendable () -> UInt64,
        onError: @Sendable (String) -> Void,
        onEnd: @Sendable () -> Void
    ) {
        // One-shot latch so the synchronizer clock is anchored exactly
        // once per session, on the first decoded audio packet. seekClock
        // is NOT idempotent (it always re-sets the synchronizer rate
        // and time), so calling it on every packet would snap the clock
        // back to `initialClockTime` 50× per second and freeze playback.
        // The latch is SHARED with the host (not loop-local): seek()
        // anchors the clock itself and sets it, so a seek landing before
        // the first decoded packet isn't overridden by a late re-arm at
        // the stale initialClockTime (the DVR feeder has used the shared
        // flag since the feeder split; this loop predates it).

        // Live PTS-discontinuity reconciliation (SW path). A program
        // boundary leaps the source PTS (forward or backward) far beyond
        // normal frame spacing. Without compensation, the session edge
        // (`newestPts - sessionStartPts`) would jump by the raw delta and the
        // decoder clock would choke. We keep a running `discontinuityOffset`
        // (in source-PTS seconds): on a detected jump we add
        // `(jumpedPts - expectedContinuationPts)` to it, then subtract the
        // offset from every subsequent packet's PTS BEFORE the live-edge note,
        // the ring append, and the decoder stamping, so the whole pipeline
        // sees one continuous timeline. The decoders are also flushed so they
        // do not stall on the seam (same flush pattern the SW seek path uses).
        //
        // Threshold mirrors the native producer: 10 s, far above any frame
        // interval or the look-behind inference, well below the synthetic
        // +1000 s test jump. Live-only; non-live SW never enters this branch.
        let discontinuityThresholdSeconds = 10.0
        var prevRawVideoPtsSec = Double.nan
        var frameIntervalSec = 0.0
        var discontinuityOffsetSec = 0.0
        var loggedSWDiscontinuity = false

        // Clock-arming fallback bookkeeping: a declared audio track whose
        // decoder never produces buffers (corrupt stream) must not leave
        // the session unarmed forever. See the video-branch arming below.
        var audioPacketsSeen = 0
        var audioBuffersProduced = false

        while !stopRequested() {
            if !isPlaying() {
                condition.lock()
                while !isPlaying() && !stopRequested() {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                }
                condition.unlock()
                continue
            }

            let genBeforeRead = seekGeneration()
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                EngineLog.emit("[SWHost] demux read failed: \(error)", category: .swPlayback)
                onError("Playback error: \(error.localizedDescription)")
                break
            }

            guard let packet else {
                videoDecoder.flush()
                audioDecoder?.flush()
                renderer.drainReorderBuffer()
                onEnd()
                break
            }

            // A seek landed while this packet was in flight: it predates
            // the seek's pipeline flush, and decoding it would clear the
            // renderer's/decoder's one-shot skip threshold ahead of the
            // real post-seek frames (visible fast-forward burst after a
            // backward seek). Discard and re-read at the new position.
            if seekGeneration() != genBeforeRead {
                av_packet_unref(packet)
                av_packet_free_safe(packet)
                continue
            }

            let streamIdx = packet.pointee.stream_index

            // Live PTS-discontinuity detection + reconciliation. Runs before
            // anything reads the packet's timestamps so the live-edge note,
            // the ring append, and the decoder all see the reconciled
            // (continuous) PTS. Detection keys on the VIDEO stream's raw pts;
            // the resulting offset is applied to BOTH streams so audio stays
            // aligned. Non-live SW skips this entirely.
            if isLive, streamIdx == videoStreamIndex, videoTimeBaseSeconds > 0,
               packet.pointee.pts != Int64.min {
                let rawPtsSec = Double(packet.pointee.pts) * videoTimeBaseSeconds
                if !prevRawVideoPtsSec.isNaN {
                    let deltaSec = rawPtsSec - prevRawVideoPtsSec
                    if abs(deltaSec) >= discontinuityThresholdSeconds {
                        // Program boundary. The timeline should continue from
                        // where it was: one frame past the previous packet.
                        // Accrue (jumpedPts - expectedContinuationPts) into the
                        // offset so post-jump PTS map back onto the prior
                        // trajectory.
                        let expectedContinuation = prevRawVideoPtsSec
                            + (frameIntervalSec > 0 ? frameIntervalSec : 0)
                        discontinuityOffsetSec += (rawPtsSec - expectedContinuation)
                        // Flush the decoders / renderer so they do not choke
                        // on the seam (codec params may also have changed; a
                        // flush is sufficient for the synthetic test, a fuller
                        // reinit is the device-verify follow-up).
                        videoDecoder.flush()
                        audioDecoder?.flush()
                        renderer.drainReorderBuffer()
                        if !loggedSWDiscontinuity {
                            loggedSWDiscontinuity = true
                            EngineLog.emit(
                                "[SWHost] live PTS discontinuity: prevPts="
                                + "\(String(format: "%.2f", prevRawVideoPtsSec))s "
                                + "rawPts=\(String(format: "%.2f", rawPtsSec))s "
                                + "delta=\(String(format: "%.2f", deltaSec))s -> "
                                + "offset=\(String(format: "%.2f", discontinuityOffsetSec))s "
                                + "(timeline held continuous)",
                                category: .swPlayback
                            )
                        }
                    } else if deltaSec > 0 {
                        // Track the running frame interval from normal advance
                        // so the expected-continuation estimate is accurate.
                        frameIntervalSec = deltaSec
                    }
                }
                prevRawVideoPtsSec = rawPtsSec
            }

            // Apply the accrued discontinuity offset to the packet's
            // timestamps in-place (live only, once a jump has been seen). The
            // offset is in source-PTS seconds; convert to this stream's TB
            // ticks. After this, every downstream consumer (edge note, ring,
            // decoder) operates on the continuous timeline.
            if isLive, discontinuityOffsetSec != 0 {
                let tbSec = (streamIdx == videoStreamIndex)
                    ? videoTimeBaseSeconds : audioTimeBaseSeconds
                if tbSec > 0 {
                    let offsetTicks = Int64((discontinuityOffsetSec / tbSec).rounded())
                    if packet.pointee.pts != Int64.min { packet.pointee.pts -= offsetTicks }
                    if packet.pointee.dts != Int64.min { packet.pointee.dts -= offsetTicks }
                }
            }

            // Live edge + DVR ring fill. Done BEFORE decode so the ring
            // holds every packet handed to the pipeline. Both video and
            // audio are appended (the reseed replays both so audio stays
            // in sync); only video keyframes are tagged as keyframes so
            // the ring's keyframe-aligned eviction + reseed anchor on a
            // decodable access point.
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
                // Back-pressure against the renderer's actual queue, not
                // the display layer's deprecated property — see
                // `SampleBufferRenderer.isReadyForMoreMediaData` doc.
                // While paused with a full queue, park on the condition
                // instead of spinning: the renderer consumes nothing at
                // rate 0, so the 5 ms poll otherwise burns CPU at 200 Hz
                // for the whole pause.
                while !renderer.isReadyForMoreMediaData && !stopRequested() {
                    if !isPlaying() {
                        condition.lock()
                        while !isPlaying() && !stopRequested() {
                            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                        }
                        condition.unlock()
                    } else {
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                }
                if stopRequested() {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    break
                }
                // Re-check the seek generation AFTER the back-pressure
                // wait: that wait is where the loop spends most of its
                // time during playback, and a seek landing there flushes
                // the renderer (freeing the queue and ending the wait)
                // with this pre-seek packet still in hand. Decoding it
                // would clear the decoder/renderer skip thresholds ahead
                // of the real post-seek frames, the exact fast-forward
                // burst the gen check at the read site exists to prevent.
                if seekGeneration() != genBeforeRead {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    continue
                }
                videoDecoder.decode(packet: packet)
                // Video-only source (no audio stream, or the audio
                // decoder failed open and load() continued video-only):
                // nothing below would ever arm the master clock, so the
                // session rendered one frozen frame with currentTime
                // stuck at 0. Arm off the first video packet instead.
                // ALSO the fallback for a declared-but-undecodable audio
                // track (decoder opened but never produces buffers, e.g.
                // a corrupt stream): without it neither arming branch
                // ever fires and the session freezes on one frame. Many
                // audio packets with zero produced buffers means the
                // decoder is not going to recover.
                if !clockArmed(), let aOut = audioOutput,
                   audioDecoder == nil || (audioPacketsSeen >= 50 && !audioBuffersProduced) {
                    aOut.seekClock(to: initialClockTime, rate: initialRate)
                    markClockArmed()
                }
            } else if streamIdx == audioStreamIndex, let aDec = audioDecoder, let aOut = audioOutput {
                audioPacketsSeen += 1
                let buffers = aDec.decode(packet: packet)
                if !buffers.isEmpty { audioBuffersProduced = true }
                for buf in buffers {
                    aOut.enqueue(sampleBuffer: buf)
                }
                // Anchor the synchronizer clock to `initialClockTime`
                // (.zero on cold-start, the resume offset on
                // resume / audio-switch reload) the first time we've
                // got real audio in the renderer. Latched so subsequent
                // packets don't keep snapping the clock back.
                if !clockArmed(), !buffers.isEmpty {
                    aOut.seekClock(to: initialClockTime, rate: initialRate)
                    markClockArmed()
                }
            }

            av_packet_unref(packet)
            av_packet_free_safe(packet)
        }
    }

    // MARK: - Time updates

    private func startTimeUpdates() {
        timeTimer = Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let aOut = self.audioOutput else { return }
                let raw = aOut.currentTimeSeconds
                if raw.isFinite, raw >= 0 {
                    // The synchronizer clock runs on the source PTS axis
                    // (samples carry source PTS). For a live session the
                    // engine timeline is "seconds since first frame", so
                    // subtract the session-start PTS. VOD / cold-start
                    // (sessionStartPts unset) keeps the raw clock.
                    if self.isLive {
                        let start: Double = {
                            self.liveEdgeLock.lock(); defer { self.liveEdgeLock.unlock() }
                            return self.sessionStartPts.isFinite ? self.sessionStartPts : 0
                        }()
                        self.currentTime = max(0, raw - start)
                    } else {
                        self.currentTime = raw
                    }
                }
                // Publish the live edge for DVR surfaces. currentTime (just
                // set) is the playhead; the edge is the newest demuxed PTS
                // in session time. publishLiveWindow (in the engine) reads
                // currentTime for the playhead, so we only feed the edge.
                if self.isLive, let edge = self.liveEdgeSessionTime {
                    self.onLiveEdge?(edge)
                }
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

/// Symmetric `av_packet_free` that handles the in/out double-pointer
/// dance FFmpeg expects. Pre-collapse code had this as a top-level
/// helper; restored here so the SW demux loop can call it cleanly.
func av_packet_free_safe(_ packet: UnsafeMutablePointer<AVPacket>) {
    var p: UnsafeMutablePointer<AVPacket>? = packet
    trackedPacketFree(&p)
}
