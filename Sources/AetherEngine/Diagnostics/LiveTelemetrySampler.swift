import Foundation
import AVFoundation

/// Bounded ring buffer exposing the sum of the most recent `capacity` values.
/// Used for 10-second rolling windows of byte counts (instant bitrate) and frame counts (observed FPS).
struct RollingWindow<T: AdditiveArithmetic> {
    private var buffer: [T]
    private var index: Int = 0
    private var filled: Bool = false
    let capacity: Int

    init(capacity: Int, zero: T) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.buffer = Array(repeating: zero, count: capacity)
    }

    mutating func push(_ value: T) {
        buffer[index] = value
        index = (index + 1) % capacity
        if index == 0 { filled = true }
    }

    var sum: T {
        let active = filled ? buffer : Array(buffer.prefix(index))
        return active.reduce(.zero, +)
    }

    /// Populated slot count; sampler keeps instant-bitrate nil until count >= 2 (one sample = zero-second delta).
    var count: Int { filled ? capacity : index }

    mutating func reset() {
        for i in 0..<buffer.count { buffer[i] = .zero }
        index = 0
        filled = false
    }
}

/// Value snapshot of every AVFoundation property the native-path tick consumes. Each getter is a
/// synchronous XPC round-trip to mediaserverd; a busy media server (display-mode change on an HDR
/// start) turns any main-actor read into a fully blocked main thread and, past the watchdog
/// threshold, a process kill (#134). The whole set is therefore read as one coalesced batch on
/// `LiveTelemetrySampler.readQueue`, never on the main actor.
struct NativeAVFReadings: Sendable {
    var droppedFrameCount: Int? = nil
    var networkThroughputMbps: Double? = nil
    var networkTransferredBytes: Int64? = nil
    var forwardBufferSeconds: Double? = nil
    /// Sum over all access-log events, for the [LagDiag] tick-over-tick drop delta.
    var droppedFramesLifetimeSum: Int = 0
    var currentTimeSeconds: Double = .nan
    var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    var rate: Float = 0
    var reasonForWaitingToPlay: String? = nil
    var isPlaybackLikelyToKeepUp: Bool = false
    var isPlaybackBufferEmpty: Bool = false
}

/// Drives engine.diagnostics.liveTelemetry at 1 Hz. Reads existing engine counters; owns no playback state.
/// Started with the memprobe task; stopped in stopInternal.
@MainActor
final class LiveTelemetrySampler {
    typealias NativeRead = @Sendable (AVPlayer, AVPlayerItem) -> NativeAVFReadings

    private weak var engine: AetherEngine?
    private var task: Task<Void, Never>?
    private let nativeRead: NativeRead

    /// Dedicated + serial: the sync XPC reads may block for seconds, which must not tie up the
    /// shared cooperative pool, and serial means a stalled tick back-pressures the next one
    /// instead of piling up concurrent reads against an already busy media server.
    private nonisolated static let readQueue = DispatchQueue(label: "engine.telemetry.avfread", qos: .utility)

    /// AVPlayer/AVPlayerItem are not Sendable; the properties the batch reads are documented
    /// thread-safe, so the refs ride to the read queue in an unchecked box.
    private struct PlayerRefs: @unchecked Sendable {
        let player: AVPlayer
        let item: AVPlayerItem
    }

    private var byteWindow = RollingWindow<Int64>(capacity: 10, zero: 0)   // 10-second rolling window
    private var frameWindow = RollingWindow<Int>(capacity: 10, zero: 0)
    private var bridgeByteWindow = RollingWindow<Int64>(capacity: 10, zero: 0)

    private var lastDemuxerBytes: Int64 = 0
    private var lastBridgeBytes: Int64 = 0
    private var lastFramesEnqueued: Int = 0
    private var sessionStartTime: Date?
    private var sessionStartBytes: Int64 = 0

    /// [LagDiag] tick-over-tick state (#93 post-recovery lag diagnosis).
    private var lagLastClock: Double?
    private var lagLastDroppedSum: Int = 0

    init(engine: AetherEngine, nativeRead: @escaping NativeRead = LiveTelemetrySampler.batchReadNativeAVF) {
        self.engine = engine
        self.nativeRead = nativeRead
    }

    func start() {
        stop()
        byteWindow.reset()
        frameWindow.reset()
        bridgeByteWindow.reset()
        // Seed from CURRENT counters: a zero seed pushes all pre-start prefetch bytes into tick 1, inflating instant bitrate for ~10 s.
        lastDemuxerBytes = engine?.demuxerBytesFetched ?? 0
        lastBridgeBytes = engine?.audioBridgeOutputBytesLifetime ?? 0
        lastFramesEnqueued = 0
        sessionStartTime = Date()
        sessionStartBytes = 0
        lagLastClock = nil
        lagLastDroppedSum = 0
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() async {
        guard let engine = engine else { return }

        // Instant + average bitrate from demuxer byte counters (both native and SW paths)
        let demuxerBytes = engine.demuxerBytesFetched
        let bytesThisTick = max(0, demuxerBytes - lastDemuxerBytes)
        lastDemuxerBytes = demuxerBytes
        if sessionStartBytes == 0 { sessionStartBytes = demuxerBytes }
        byteWindow.push(bytesThisTick)

        let instantBitrateMbps: Double?
        if byteWindow.count >= 2 {
            let totalBytes = byteWindow.sum
            let seconds = Double(byteWindow.count)
            instantBitrateMbps = Double(totalBytes) * 8.0 / seconds / 1_000_000.0
        } else {
            instantBitrateMbps = nil
        }

        let averageBitrateMbps: Double?
        if let start = sessionStartTime {
            let elapsed = max(0.5, Date().timeIntervalSince(start))
            let lifetimeBytes = max(0, demuxerBytes - sessionStartBytes)
            averageBitrateMbps = Double(lifetimeBytes) * 8.0 / elapsed / 1_000_000.0
        } else {
            averageBitrateMbps = nil
        }

        // Live audio-bridge output bitrate from the bridge's cumulative encoded-byte counter. 0 on the
        // stream-copy / AVPlayer-native / video-only paths (no bridge), which surfaces as nil.
        let bridgeBytes = engine.audioBridgeOutputBytesLifetime
        let bridgeBytesThisTick = max(0, bridgeBytes - lastBridgeBytes)
        lastBridgeBytes = bridgeBytes
        bridgeByteWindow.push(bridgeBytesThisTick)
        let audioBridgeBitrateMbps: Double?
        if bridgeBytes > 0, bridgeByteWindow.count >= 2 {
            audioBridgeBitrateMbps = Double(bridgeByteWindow.sum) * 8.0 / Double(bridgeByteWindow.count) / 1_000_000.0
        } else {
            audioBridgeBitrateMbps = nil
        }

        // Per-path: FPS, dropped frames, network throughput, A/V sync gap
        let observedFps: Double?
        let droppedFrameCount: Int?
        let networkThroughputMbps: Double?
        let networkTransferredBytes: Int64?
        let avSyncGapMs: Double?
        let forwardBufferSeconds: Double?
        var nativeReadings: NativeAVFReadings?

        switch engine.playbackBackend {
        case .native:
            observedFps = nil
            avSyncGapMs = engine.lastAVGapMs  // HLSSegmentProducer audio-gate-open vs video-gate-open (native path only)
            if let player = engine.currentAVPlayer, let item = player.currentItem {
                let readings = await readNativeOffMain(player: player, item: item)
                // stop() may have cancelled this tick while the read was in flight; publishing
                // now would leak a stale snapshot and yield-gate tick into the next session.
                guard !Task.isCancelled else { return }
                nativeReadings = readings
                droppedFrameCount = readings.droppedFrameCount
                networkThroughputMbps = readings.networkThroughputMbps
                networkTransferredBytes = readings.networkTransferredBytes
                forwardBufferSeconds = readings.forwardBufferSeconds
            } else {
                droppedFrameCount = nil
                networkThroughputMbps = nil
                networkTransferredBytes = nil
                forwardBufferSeconds = nil
            }

        case .software:
            let frames = engine.softwareHostFramesEnqueued
            let framesThisTick = max(0, frames - lastFramesEnqueued)
            lastFramesEnqueued = frames
            frameWindow.push(framesThisTick)
            if frameWindow.count >= 2 {
                let totalFrames = frameWindow.sum
                let seconds = Double(frameWindow.count)
                observedFps = Double(totalFrames) / seconds
            } else {
                observedFps = nil
            }
            droppedFrameCount = nil
            networkThroughputMbps = instantBitrateMbps  // SW: demuxer pulls the same bytes
            networkTransferredBytes = demuxerBytes
            avSyncGapMs = nil          // HLSSegmentProducer doesn't run on SW path
            forwardBufferSeconds = nil // SW host has no loadedTimeRanges equivalent

        case .aether, .none, .audio:
            observedFps = nil
            droppedFrameCount = nil
            networkThroughputMbps = nil
            networkTransferredBytes = nil
            avSyncGapMs = nil
            forwardBufferSeconds = nil
        }

        // Feed the extractor yield gate (#93 startup): nil on non-native paths keeps the
        // gate conservative there, but those paths have no active session to gate anyway.
        engine.extractorYieldState.setForwardBuffer(forwardBufferSeconds)

        if let readings = nativeReadings {
            emitLagDiag(engine: engine, readings: readings, netMbps: instantBitrateMbps)
        }

        let snapshot = LiveTelemetry(
            instantBitrateMbps: instantBitrateMbps,
            averageBitrateMbps: averageBitrateMbps,
            audioBridgeBitrateMbps: audioBridgeBitrateMbps,
            observedFps: observedFps,
            droppedFrameCount: droppedFrameCount,
            forwardBufferSeconds: forwardBufferSeconds,
            cachedBytes: engine.cachedBytes,
            networkThroughputMbps: networkThroughputMbps,
            networkTransferredBytes: networkTransferredBytes,
            avSyncGapMs: avSyncGapMs,
            producerRestartCount: engine.producerRestartCount,
            muxedBytesLifetime: engine.muxedBytesLifetime,
            serverBytesSentLifetime: engine.serverBytesSentLifetime,
            serverRequestCount: engine.serverRequestCount,
            demuxerBytesFetched: demuxerBytes,
            audioBridgeLiveBytes: engine.audioBridgeLiveBytes,
            rssMb: AetherEngine.residentMemoryMB()
        )
        engine.applyLiveTelemetry(snapshot)
    }

    /// One line per tick on the native path (#93 post-recovery lag diagnosis). Discriminates
    /// buffer starvation (fwd/keepUp/empty + dclk pauses) from render-side stutter (drop
    /// climbing while tcs=playing and dclk~1.0) from thermal throttling (thermal field).
    /// All AVFoundation inputs arrive pre-read from the off-main batch (#134); only engine
    /// state and the tick-over-tick lag counters are touched here.
    private func emitLagDiag(engine: AetherEngine, readings: NativeAVFReadings, netMbps: Double?) {
        let clock = readings.currentTimeSeconds
        let dclk = (clock.isFinite && lagLastClock != nil) ? clock - lagLastClock! : nil
        if clock.isFinite { lagLastClock = clock }

        let droppedSum = readings.droppedFramesLifetimeSum
        let dDrop = droppedSum - lagLastDroppedSum
        lagLastDroppedSum = droppedSum

        let tcs: String
        switch readings.timeControlStatus {
        case .paused:                       tcs = "paused"
        case .waitingToPlayAtSpecifiedRate: tcs = "waiting"
        case .playing:                      tcs = "playing"
        @unknown default:                   tcs = "unknown"
        }
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:    thermal = "nominal"
        case .fair:       thermal = "fair"
        case .serious:    thermal = "serious"
        case .critical:   thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let fmt2 = { (v: Double) in String(format: "%.2f", v) }
        EngineLog.emit(
            "[LagDiag] clk=\(clock.isFinite ? fmt2(clock) : "-") dclk=\(dclk.map(fmt2) ?? "-") "
            + "tcs=\(tcs) rate=\(fmt2(Double(readings.rate))) wait=\(readings.reasonForWaitingToPlay ?? "-") "
            + "fwd=\(readings.forwardBufferSeconds.map { String(format: "%.1f", $0) } ?? "-") "
            + "keepUp=\(readings.isPlaybackLikelyToKeepUp ? "y" : "n") empty=\(readings.isPlaybackBufferEmpty ? "y" : "n") "
            + "drop=\(droppedSum)+\(dDrop) stall=\(engine.nativeHost?.stallCount ?? 0) "
            + "ready=\((engine.nativeHost?.playerLayer.isReadyForDisplay ?? false) ? "y" : "n") "
            + "thermal=\(thermal) net=\(netMbps.map { String(format: "%.1f", $0) } ?? "-") "
            + "restarts=\(engine.producerRestartCount)",
            category: .engine, level: .verbose
        )
    }

    /// Hops the AVFoundation batch onto the dedicated read queue and back. The main actor only
    /// suspends here; a stalled mediaserverd reply parks a GCD thread, not the main thread.
    private func readNativeOffMain(player: AVPlayer, item: AVPlayerItem) async -> NativeAVFReadings {
        let refs = PlayerRefs(player: player, item: item)
        let read = nativeRead
        return await withCheckedContinuation { continuation in
            Self.readQueue.async {
                continuation.resume(returning: read(refs.player, refs.item))
            }
        }
    }

    /// The real batch, run on `readQueue`: one accessLog() shared by the snapshot fields and the
    /// LagDiag lifetime drop sum, one currentTime() shared by the forward-buffer math and the
    /// LagDiag clock (previously two of each per tick, all on the main actor).
    private nonisolated static func batchReadNativeAVF(player: AVPlayer, item: AVPlayerItem) -> NativeAVFReadings {
        var readings = NativeAVFReadings()
        let events = item.accessLog()?.events
        if let event = events?.last {
            readings.droppedFrameCount = event.numberOfDroppedVideoFrames >= 0
                ? event.numberOfDroppedVideoFrames : nil
            let observed = event.observedBitrate
            readings.networkThroughputMbps = observed.isFinite && observed > 0
                ? observed / 1_000_000.0 : nil
            readings.networkTransferredBytes = event.numberOfBytesTransferred >= 0
                ? Int64(event.numberOfBytesTransferred) : nil
        }
        readings.droppedFramesLifetimeSum = events?.reduce(0) { $0 + max(0, $1.numberOfDroppedVideoFrames) } ?? 0

        let now = player.currentTime().seconds
        readings.currentTimeSeconds = now
        if let last = item.loadedTimeRanges.last?.timeRangeValue {
            let end = CMTimeGetSeconds(CMTimeAdd(last.start, last.duration))
            if end.isFinite, now.isFinite {
                readings.forwardBufferSeconds = max(0, end - now)
            }
        }

        readings.timeControlStatus = player.timeControlStatus
        readings.rate = player.rate
        readings.reasonForWaitingToPlay = player.reasonForWaitingToPlay?.rawValue
        readings.isPlaybackLikelyToKeepUp = item.isPlaybackLikelyToKeepUp
        readings.isPlaybackBufferEmpty = item.isPlaybackBufferEmpty
        return readings
    }
}
