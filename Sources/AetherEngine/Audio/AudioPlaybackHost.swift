import Foundation
import AVFoundation
import CoreMedia
import Combine
import Libavformat
import Libavcodec
import Libavutil

/// Audio-only playback host. The lean sibling of `SoftwarePlaybackHost`:
/// it drives FFmpeg decode -> `AVSampleBufferAudioRenderer` for sources
/// with no video track (music, audiobooks), skipping the video decoder,
/// the `SampleBufferRenderer`, the display layer, the HDR handshake, and
/// the entire HLS / segment-producer / muxer / loopback stack the video
/// paths carry.
///
/// The pipeline:
///
/// ```
/// Demuxer -- audio pkt --► AudioDecoder --► CMSampleBuffer --► AudioOutput
///                                            (AVSampleBufferRenderSynchronizer
///                                             is the master clock)
/// ```
///
/// The synchronizer is the clock; `AudioOutput.seekClock(to:rate:)` is
/// called once on the first decoded audio packet to anchor it (matching
/// the proven `SoftwarePlaybackHost` clock-arming pattern), then the
/// `currentTime` mirror is polled at 4 Hz off the synchronizer.
@MainActor
final class AudioPlaybackHost {

    // MARK: - Published state (mirrors SoftwarePlaybackHost surface)

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    @Published private(set) var failureMessage: String?
    @Published private(set) var didReachEnd: Bool = false

    // MARK: - Internals

    private var audioDecoder: AudioDecoder?
    private var audioOutput: AudioOutput?
    private var demuxer: Demuxer?

    /// Background queue the demux loop runs on. One per host so hosts
    /// created across rapid load() calls don't fight over the same
    /// execution context.
    private let demuxQueue = DispatchQueue(label: "engine.audio.demux", qos: .userInitiated)

    /// Lock guarding the playing / stop flags, read on the demux thread
    /// every iteration, written on the main actor from play/pause/stop.
    private let flagsLock = NSLock()
    nonisolated(unsafe) private var _isPlaying: Bool = false
    nonisolated(unsafe) private var _stopRequested: Bool = false

    /// Condition the demux thread waits on while paused so it doesn't
    /// busy-loop reading packets that would just stack up.
    private let demuxCondition = NSCondition()

    private var audioStreamIndex: Int32 = -1

    /// Periodic mirror of `audioOutput.currentTimeSeconds` into the
    /// published `currentTime`. 250 ms matches `SoftwarePlaybackHost`.
    private var timeTimer: AnyCancellable?

    /// Cached rate so resume() restores the right speed after a pause.
    private var lastRate: Float = 1.0

    /// Source-position seconds the host opened at, captured so the demux
    /// loop can align the synchronizer's master clock to the first
    /// decoded sample's PTS. `.zero` on cold start; the resume offset on
    /// a start-position load.
    private var initialClockTime: CMTime = .zero

    /// Latched once the first `play()` has spun up the demux loop.
    private var demuxLoopStarted: Bool = false

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

    init() {}

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

        let resolvedAudioIdx: Int32 = audioSourceStreamIndex ?? dem.audioStreamIndex
        guard resolvedAudioIdx >= 0, let aStream = dem.stream(at: resolvedAudioIdx) else {
            throw HostError.noAudioStream
        }

        let aCodecID = aStream.pointee.codecpar?.pointee.codec_id.rawValue ?? 0
        EngineLog.emit(
            "[AudioHost] session start: audioCodecID=\(aCodecID) "
            + "duration=\(String(format: "%.1f", dem.duration))s",
            category: .swPlayback
        )

        let aDec = AudioDecoder()
        try aDec.open(stream: aStream)
        self.audioDecoder = aDec
        self.audioStreamIndex = resolvedAudioIdx
        self.audioOutput = AudioOutput()

        if let start = startPosition, start > 0 {
            dem.seek(to: start)
            initialClockTime = CMTime(seconds: start, preferredTimescale: 90000)
            currentTime = start
        } else {
            initialClockTime = .zero
        }

        startTimeUpdates()
        isReady = true
        // Demux loop only spins up once play() fires.
    }

    // MARK: - Transport

    func play() {
        if !demuxLoopStarted {
            demuxLoopStarted = true
            startDemuxLoop()
        }
        // The demux loop calls `audioOutput.seekClock(to:rate:)` on the
        // first decoded audio packet, so the master clock's time-zero
        // aligns with that sample's PTS. Eager-starting here against an
        // empty renderer queue would tick the clock forward through the
        // loop's spin-up and drop the first samples (silent gap).
        rate = lastRate
        isPlaying = true
    }

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
        let wasPlaying = isPlaying
        isPlaying = false

        audioDecoder?.flush()
        audioOutput?.flush()

        dem.seek(to: seconds)
        currentTime = seconds

        if wasPlaying {
            // Jump the master clock to the seek target so PTS-stamped
            // samples decoded after the seek align with the clock.
            let targetTime = CMTime(seconds: seconds, preferredTimescale: 90000)
            audioOutput?.seekClock(to: targetTime, rate: lastRate)
            isPlaying = true
        } else {
            // Paused seek: stash the target so the next play()'s first
            // decoded packet anchors the clock there, not at .zero.
            initialClockTime = CMTime(seconds: seconds, preferredTimescale: 90000)
        }
    }

    func stop() {
        stopRequested = true
        isPlaying = false
        timeTimer?.cancel()
        timeTimer = nil

        audioOutput?.stop()
        audioOutput = nil
        audioDecoder?.close()
        audioDecoder = nil
        demuxer?.close()
        demuxer = nil

        isReady = false
    }

    var volume: Float {
        get { audioOutput?.volume ?? 1.0 }
        set { audioOutput?.volume = newValue }
    }

    // MARK: - Demux loop

    private func startDemuxLoop() {
        guard let dem = demuxer else { return }
        let aDec = audioDecoder
        let aOut = audioOutput
        let aIdx = audioStreamIndex
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
                audioDecoder: aDec,
                audioOutput: aOut,
                audioStreamIndex: aIdx,
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

    /// Audio-only demux loop. Reads packets, decodes the audio stream,
    /// enqueues the resulting CMSampleBuffers, and anchors the
    /// synchronizer clock once on the first decoded packet. Non-audio
    /// packets are discarded. EOF flushes the decoder and signals end.
    nonisolated private static func runDemuxLoop(
        demuxer: Demuxer,
        audioDecoder: AudioDecoder?,
        audioOutput: AudioOutput?,
        audioStreamIndex: Int32,
        condition: NSCondition,
        initialClockTime: CMTime,
        initialRate: Float,
        isPlaying: @Sendable () -> Bool,
        stopRequested: @Sendable () -> Bool,
        onError: @Sendable (String) -> Void,
        onEnd: @Sendable () -> Void
    ) {
        // One-shot latch: anchor the clock exactly once, on the first
        // decoded audio packet. seekClock is NOT idempotent (it re-sets
        // rate + time), so calling it per packet would snap the clock
        // back ~47x/sec and freeze playback.
        var clockArmed = false

        // Bound how far the demuxer may run ahead of the playback clock.
        // Without this the loop reads the ENTIRE file's packets in a tight
        // burst, enqueues them all into the renderer, hits readPacket()==nil
        // (demuxer EOF) within a second or two, and fires onEnd() while the
        // audio is still playing out of the renderer's buffer. The host then
        // mistakes demuxer-EOF for end-of-track and advances early. Pacing
        // the loop to keep at most `maxBufferAhead` seconds queued ahead of
        // the synchronizer clock makes demuxer-EOF land near actual playback
        // end and bounds the decoded-PCM memory held in the renderer.
        let maxBufferAhead: Double = 8.0
        // Source-time (seconds) of the end of the last sample handed to the
        // renderer. Drives both the back-pressure gate and the end-of-track
        // drain below. lastEnqueuedEnd and currentTimeSeconds share the same
        // source-PTS timeline (samples carry source PTS; the clock is
        // anchored to initialClockTime), so their difference is the seconds
        // of audio queued ahead of the playhead.
        var lastEnqueuedEnd: Double = 0

        while !stopRequested() {
            if !isPlaying() {
                condition.lock()
                while !isPlaying() && !stopRequested() {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                }
                condition.unlock()
                continue
            }

            // Back-pressure: once the clock is running, don't outrun it by
            // more than `maxBufferAhead` seconds. Skipped until the clock is
            // armed so the initial buffer can prime.
            if clockArmed, let aOut = audioOutput {
                while !stopRequested() && isPlaying()
                    && (lastEnqueuedEnd - aOut.currentTimeSeconds) > maxBufferAhead {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if stopRequested() { break }
            }

            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                EngineLog.emit("[AudioHost] demux read failed: \(error)", category: .swPlayback)
                onError("Playback error: \(error.localizedDescription)")
                break
            }

            guard let packet else {
                audioDecoder?.flush()
                // Demuxer EOF is NOT end-of-track: the renderer still has up
                // to `maxBufferAhead` seconds queued. Wait for the clock to
                // play through everything enqueued before signaling the end,
                // otherwise the host advances to the next track seconds early.
                while !stopRequested()
                    && (audioOutput?.currentTimeSeconds ?? lastEnqueuedEnd) < lastEnqueuedEnd - 0.25 {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                onEnd()
                break
            }

            if packet.pointee.stream_index == audioStreamIndex,
               let aDec = audioDecoder, let aOut = audioOutput {
                let buffers = aDec.decode(packet: packet)
                for buf in buffers {
                    aOut.enqueue(sampleBuffer: buf)
                }
                if let last = buffers.last {
                    let end = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(last))
                        + CMTimeGetSeconds(CMSampleBufferGetDuration(last))
                    if end.isFinite, end > lastEnqueuedEnd { lastEnqueuedEnd = end }
                }
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
        case noAudioStream

        var errorDescription: String? {
            switch self {
            case .noAudioStream: return "Source has no audio stream"
            }
        }
    }
}
