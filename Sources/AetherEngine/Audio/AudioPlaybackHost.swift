import Foundation
import AVFoundation
import CoreMedia
import Combine
import Libavformat
import Libavcodec
import Libavutil

/// Audio-only playback host (lean sibling of `SoftwarePlaybackHost`): FFmpeg decode -> `AVSampleBufferAudioRenderer`
/// for sources with no video track, skipping video decoder/display/HDR/HLS/muxer/loopback. The synchronizer is the
/// master clock; `seekClock(to:rate:)` anchors it once on the first decoded packet (SoftwarePlaybackHost clock-arming
/// pattern), then `currentTime` is polled at 4 Hz off the synchronizer.
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

    /// One demux queue per host so rapid load() calls don't fight over the same execution context.
    private let demuxQueue = DispatchQueue(label: "engine.audio.demux", qos: .userInitiated)

    /// Guards playing/stop flags: read on demux thread every iteration, written on main actor.
    private let flagsLock = NSLock()
    nonisolated(unsafe) private var _isPlaying: Bool = false
    nonisolated(unsafe) private var _stopRequested: Bool = false

    /// Demux thread waits on this while paused so it doesn't busy-loop stacking up packets.
    private let demuxCondition = NSCondition()

    private var audioStreamIndex: Int32 = -1

    /// 250 ms mirror of currentTimeSeconds into published currentTime (matches SoftwarePlaybackHost).
    private var timeTimer: AnyCancellable?

    private var lastRate: Float = 1.0

    /// Source-position seconds the host opened at; the demux loop aligns the master clock to the first
    /// decoded sample's PTS. `.zero` on cold start, resume offset on a start-position load.
    private var initialClockTime: CMTime = .zero

    /// Latched once the first `play()` has spun up the demux loop.
    private var demuxLoopStarted: Bool = false

    /// True between pause() and next play() so play() resumes the synchronizer rate (mirrors SoftwarePlaybackHost.pausedByHost).
    private var pausedByHost: Bool = false

    /// Shared clock-armed latch (mirrors SoftwarePlaybackHost._clockArmed): demux loop arms once on first decoded
    /// packet; seek() anchors directly and sets this so the loop doesn't snap back to the stale initial anchor.
    nonisolated(unsafe) private var _clockArmed = false
    nonisolated private var clockArmed: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _clockArmed }
        set { flagsLock.lock(); _clockArmed = newValue; flagsLock.unlock() }
    }

    /// Bumped by every seek(); demux loop resets its enqueue high-water mark on change so the back-pressure
    /// gate can't park against a pre-seek mark after a backward seek.
    nonisolated(unsafe) private var _seekGeneration: UInt64 = 0
    nonisolated private var seekGeneration: UInt64 {
        flagsLock.lock(); defer { flagsLock.unlock() }; return _seekGeneration
    }

    /// Sync hop for seek(to:): NSLock is unavailable directly from async contexts.
    nonisolated private func bumpSeekGeneration() {
        flagsLock.lock(); _seekGeneration &+= 1; flagsLock.unlock()
    }

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
        demuxer dem: Demuxer,
        startPosition: Double?,
        audioSourceStreamIndex: Int32?
    ) async throws {
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
        // Resume the synchronizer a pause() froze (rate 0). Guarded on demuxLoopStarted so a pause() before
        // first play() doesn't eager-start the un-anchored synchronizer (would tick the clock through spin-up
        // and drop the first samples; clock is armed off the first decoded sample).
        if pausedByHost {
            pausedByHost = false
            if demuxLoopStarted {
                audioOutput?.setRate(lastRate)
            }
        }
        if !demuxLoopStarted {
            demuxLoopStarted = true
            startDemuxLoop()
        }
        // Demux loop calls seekClock(to:rate:) on the first decoded packet so master-clock time-zero aligns
        // with that sample's PTS. Eager-starting against an empty queue would drop the first samples (silent gap).
        rate = lastRate
        isPlaying = true
    }

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
        let wasPlaying = isPlaying
        isPlaying = false

        audioDecoder?.flush()
        audioOutput?.flush()

        dem.seek(to: seconds)
        currentTime = seconds

        // Drop the demux loop's enqueue high-water mark; after a backward seek the stale mark would park the
        // back-pressure gate until the clock walked back up to the pre-seek position (minutes of silence).
        bumpSeekGeneration()

        let targetTime = CMTime(seconds: seconds, preferredTimescale: 90000)
        guard demuxLoopStarted else {
            // Cold seek (no play() yet): stash target so the loop's first decoded packet anchors there, not at .zero.
            initialClockTime = targetTime
            return
        }
        if wasPlaying {
            audioOutput?.seekClock(to: targetTime, rate: lastRate)
            isPlaying = true
        } else {
            // Paused seek: anchor at target rate 0 so play() resumes from the SEEK position not the stale
            // pre-seek clock (mirrors SoftwarePlaybackHost's VOD path).
            audioOutput?.seekClock(to: targetTime, rate: 0)
            pausedByHost = true
        }
        // Clock is now positioned; demux loop must not re-arm it at the stale initial anchor.
        clockArmed = true
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
        let getClockArmed: @Sendable () -> Bool = { [weak self] in self?.clockArmed ?? true }
        let setClockArmed: @Sendable () -> Void = { [weak self] in self?.clockArmed = true }
        let getSeekGeneration: @Sendable () -> UInt64 = { [weak self] in self?.seekGeneration ?? 0 }
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
                clockArmed: getClockArmed,
                armClock: setClockArmed,
                seekGeneration: getSeekGeneration,
                onError: onError,
                onEnd: onEnd
            )
        }
    }

    /// Audio-only demux loop: reads packets, decodes audio, enqueues CMSampleBuffers, anchors the clock once on
    /// the first decoded packet. Non-audio discarded; EOF flushes decoder and signals end.
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
        clockArmed: @Sendable () -> Bool,
        armClock: @Sendable () -> Void,
        seekGeneration: @Sendable () -> UInt64,
        onError: @Sendable (String) -> Void,
        onEnd: @Sendable () -> Void
    ) {
        // Clock-armed latch is SHARED with the host: anchor the clock exactly once on the first decoded packet.
        // seekClock is NOT idempotent (re-sets rate+time), so per-packet calls would snap the clock back ~47x/sec
        // and freeze playback. seek() arms it itself so the loop doesn't override the seek anchor.

        // Bound how far the demuxer runs ahead of the clock. Without this the loop bursts the ENTIRE file's
        // packets, hits readPacket()==nil (demuxer EOF) in ~1-2s, fires onEnd() while audio is still playing out
        // of the renderer, and the host advances early. Pacing to maxBufferAhead lands demuxer-EOF near actual
        // playback end and bounds decoded-PCM memory in the renderer.
        let maxBufferAhead: Double = 8.0
        // Source-time seconds of the last sample handed to the renderer. lastEnqueuedEnd and currentTimeSeconds
        // share the source-PTS timeline (clock anchored to initialClockTime), so their difference is seconds queued ahead.
        var lastEnqueuedEnd: Double = 0
        var seenSeekGeneration = seekGeneration()

        while !stopRequested() {
            if !isPlaying() {
                condition.lock()
                while !isPlaying() && !stopRequested() {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.5))
                }
                condition.unlock()
                continue
            }

            // A seek invalidates the enqueue high-water mark: a stale pre-seek value after a backward seek
            // would park the gate below until the clock walked back up.
            let gen = seekGeneration()
            if gen != seenSeekGeneration {
                seenSeekGeneration = gen
                lastEnqueuedEnd = 0
            }

            // Back-pressure: once the clock runs, don't outrun it by more than maxBufferAhead. Skipped until
            // the clock is armed so the initial buffer can prime.
            if clockArmed(), let aOut = audioOutput {
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
                // Drain decoder-delay frames + the sub-threshold tail and enqueue them before flush()
                // discards pending; extend the high-water mark so the playthrough wait below covers the
                // tail. flush() alone dropped the final ~21ms+ of every audio-only title.
                if let aDec = audioDecoder, let aOut = audioOutput,
                   seekGeneration() == seenSeekGeneration {
                    let tail = aDec.drain()
                    for buf in tail { aOut.enqueue(sampleBuffer: buf) }
                    if let last = tail.last {
                        let end = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(last))
                            + CMTimeGetSeconds(CMSampleBufferGetDuration(last))
                        if end.isFinite, end > lastEnqueuedEnd { lastEnqueuedEnd = end }
                    }
                }
                audioDecoder?.flush()
                // Demuxer EOF is NOT end-of-track: renderer still has up to maxBufferAhead seconds queued.
                // Wait for the clock to play through before signaling end, else host advances seconds early.
                var seekedAway = false
                while !stopRequested()
                    && (audioOutput?.currentTimeSeconds ?? lastEnqueuedEnd) < lastEnqueuedEnd - 0.25 {
                    // A seek during the drain re-positions the demuxer so EOF no longer holds. Without this check
                    // the drain played silence up to the stale high-water mark then fired onEnd(), skipping the seek.
                    if seekGeneration() != seenSeekGeneration {
                        seekedAway = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if seekedAway { continue }
                if seekGeneration() != seenSeekGeneration { continue }
                onEnd()
                break
            }

            // A seek landed while this packet was in flight: it predates the seek's renderer flush, so enqueueing
            // would park a stale-position buffer in the fresh queue. Discard and re-read at the new position.
            if seekGeneration() != seenSeekGeneration {
                av_packet_unref(packet)
                av_packet_free_safe(packet)
                continue
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
                if !clockArmed(), !buffers.isEmpty {
                    aOut.seekClock(to: initialClockTime, rate: initialRate)
                    armClock()
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
