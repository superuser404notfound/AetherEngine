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
    private let videoDecoder: SoftwareVideoDecoder
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
        self.videoDecoder = SoftwareVideoDecoder()
    }

    // MARK: - Load

    func load(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        startPosition: Double?,
        audioSourceStreamIndex: Int32?
    ) async throws {
        let dem = Demuxer()
        try dem.open(url: url, extraHeaders: sourceHTTPHeaders)
        self.demuxer = dem
        self.duration = dem.duration

        guard dem.videoStreamIndex >= 0,
              let vStream = dem.stream(at: dem.videoStreamIndex) else {
            throw HostError.noVideoStream
        }
        self.videoStreamIndex = dem.videoStreamIndex

        try videoDecoder.open(stream: vStream) { [weak self] pixelBuffer, pts, hdr10PlusData in
            // Decoder callback fires on the demux thread. SampleBufferRenderer
            // is internally locked + safe to call off-main; the engine's
            // public state stays untouched here, only the layer's frame queue.
            self?.renderer.enqueue(pixelBuffer: pixelBuffer, pts: pts, hdr10PlusData: hdr10PlusData)
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

                // AudioOutput is created here but the display layer is
                // NOT yet attached to its synchronizer — that happens in
                // play() after the engine has hung the layer in the
                // bound view's CALayer hierarchy. Attaching a free-
                // floating layer to the synchronizer has been observed
                // to fail with `FigVideoQueueRemote err=-12080` after
                // the first enqueue on tvOS 26+.
                self.audioOutput = AudioOutput()
            } catch {
                EngineLog.emit("[SWHost] audio open failed (\(error)); video-only", category: .engine)
                self.audioStreamIndex = -1
            }
        }

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
        if !demuxLoopStarted, let aOut = audioOutput {
            aOut.attachVideoLayer(renderer.displayLayer)
        }
        if !demuxLoopStarted {
            demuxLoopStarted = true
            startDemuxLoop()
        }

        // Don't eager-start the audio synchronizer. The pre-collapse
        // pattern was: start(at:) fires only on the first decoded audio
        // sample, so the master clock's time-zero aligns with the
        // sample's PTS. Eager-starting here with an empty renderer queue
        // means the clock ticks forward through the demux loop's spin-up
        // and the first sample lands "in the past" — dropped, with a
        // visible initial flicker or audio gap. The demux loop calls
        // `audioOutput.start(at: .zero)` itself on first enqueue;
        // `start()` is idempotent so the duplicate call from `seek()`'s
        // resume path is a no-op.
        rate = lastRate
        isPlaying = true
    }

    /// Latched once the first `play()` has wired the audio synchronizer
    /// to the display layer and spun up the demux loop. Subsequent
    /// `play()` calls only flip `isPlaying` without re-attaching.
    private var demuxLoopStarted: Bool = false

    func pause() {
        audioOutput?.pause()
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
        // in-flight packet reads.
        let wasPlaying = isPlaying
        isPlaying = false

        videoDecoder.flush()
        audioDecoder?.flush()
        renderer.flush()
        audioOutput?.flush()

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
        }
    }

    func stop() {
        stopRequested = true
        isPlaying = false
        timeTimer?.cancel()
        timeTimer = nil

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
        // `AVSampleBufferDisplayLayer` isn't Sendable in Apple's
        // headers, but we only read `isReadyForMoreMediaData` off-main
        // (which is documented as thread-safe by AVFoundation).
        // Wrapping in `UncheckedSendable` quiets the closure-capture
        // diagnostic without forcing the loop back to the main actor.
        let layer = UncheckedSendable(renderer.displayLayer)
        let vDec = videoDecoder
        let vIdx = videoStreamIndex
        let aDec = audioDecoder
        let aOut = audioOutput
        let aIdx = audioStreamIndex
        let rndr = renderer
        let condition = demuxCondition
        let initialClock = initialClockTime
        let initialRate = lastRate
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

        demuxQueue.async {
            Self.runDemuxLoop(
                demuxer: dem,
                videoDecoder: vDec,
                videoStreamIndex: vIdx,
                audioDecoder: aDec,
                audioOutput: aOut,
                audioStreamIndex: aIdx,
                renderer: rndr,
                displayLayer: layer.value,
                condition: condition,
                initialClockTime: initialClock,
                initialRate: initialRate,
                isPlaying: getIsPlaying,
                stopRequested: getStopRequested,
                onError: onError,
                onEnd: onEnd
            )
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
        videoDecoder: SoftwareVideoDecoder,
        videoStreamIndex: Int32,
        audioDecoder: AudioDecoder?,
        audioOutput: AudioOutput?,
        audioStreamIndex: Int32,
        renderer: SampleBufferRenderer,
        displayLayer: AVSampleBufferDisplayLayer,
        condition: NSCondition,
        initialClockTime: CMTime,
        initialRate: Float,
        isPlaying: @Sendable () -> Bool,
        stopRequested: @Sendable () -> Bool,
        onError: @Sendable (String) -> Void,
        onEnd: @Sendable () -> Void
    ) {
        // One-shot latch so the synchronizer clock is anchored exactly
        // once per session, on the first decoded audio packet. seekClock
        // is NOT idempotent (it always re-sets the synchronizer rate
        // and time), so calling it on every packet would snap the clock
        // back to `initialClockTime` 50× per second and freeze playback.
        var clockArmed = false

        while !stopRequested() {
            if !isPlaying() {
                condition.lock()
                while !isPlaying() && !stopRequested() {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                }
                condition.unlock()
                continue
            }

            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                EngineLog.emit("[SWHost] demux read failed: \(error)", category: .engine)
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

            let streamIdx = packet.pointee.stream_index

            if streamIdx == videoStreamIndex {
                // Back-pressure against the renderer's actual queue, not
                // the display layer's deprecated property — see
                // `SampleBufferRenderer.isReadyForMoreMediaData` doc.
                while !renderer.isReadyForMoreMediaData && !stopRequested() {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                if stopRequested() {
                    av_packet_unref(packet)
                    av_packet_free_safe(packet)
                    break
                }
                videoDecoder.decode(packet: packet)
            } else if streamIdx == audioStreamIndex, let aDec = audioDecoder, let aOut = audioOutput {
                let buffers = aDec.decode(packet: packet)
                for buf in buffers {
                    aOut.enqueue(sampleBuffer: buf)
                }
                // Anchor the synchronizer clock to `initialClockTime`
                // (.zero on cold-start, the resume offset on
                // resume / audio-switch reload) the first time we've
                // got real audio in the renderer. Latched so subsequent
                // packets don't keep snapping the clock back.
                if !clockArmed, !buffers.isEmpty {
                    aOut.seekClock(to: initialClockTime, rate: initialRate)
                    clockArmed = true
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
                let t = aOut.currentTimeSeconds
                if t.isFinite, t >= 0 {
                    self.currentTime = t
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
    av_packet_free(&p)
}

// MARK: - Sendable wrapper

/// Box for non-Sendable reference types that we only touch on a single
/// background queue. Captures the value once at construction so the
/// closure that owns it can be marked `@Sendable` without Swift 6
/// strict concurrency rejecting the capture. Used for
/// `AVSampleBufferDisplayLayer`, whose `isReadyForMoreMediaData`
/// reads are documented as thread-safe.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
