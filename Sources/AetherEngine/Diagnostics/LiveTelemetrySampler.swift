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

/// Drives engine.diagnostics.liveTelemetry at 1 Hz. Reads existing engine counters; owns no playback state.
/// Started with the memprobe task; stopped in stopInternal.
@MainActor
final class LiveTelemetrySampler {
    private weak var engine: AetherEngine?
    private var task: Task<Void, Never>?

    private var byteWindow = RollingWindow<Int64>(capacity: 10, zero: 0)   // 10-second rolling window
    private var frameWindow = RollingWindow<Int>(capacity: 10, zero: 0)

    private var lastDemuxerBytes: Int64 = 0
    private var lastFramesEnqueued: Int = 0
    private var sessionStartTime: Date?
    private var sessionStartBytes: Int64 = 0

    /// [LagDiag] tick-over-tick state (#93 post-recovery lag diagnosis).
    private var lagLastClock: Double?
    private var lagLastDroppedSum: Int = 0

    init(engine: AetherEngine) {
        self.engine = engine
    }

    func start() {
        stop()
        byteWindow.reset()
        frameWindow.reset()
        // Seed from CURRENT counters: a zero seed pushes all pre-start prefetch bytes into tick 1, inflating instant bitrate for ~10 s.
        lastDemuxerBytes = engine?.demuxerBytesFetched ?? 0
        lastFramesEnqueued = 0
        sessionStartTime = Date()
        sessionStartBytes = 0
        lagLastClock = nil
        lagLastDroppedSum = 0
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() {
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

        // Per-path: FPS, dropped frames, network throughput, A/V sync gap
        let observedFps: Double?
        let droppedFrameCount: Int?
        let networkThroughputMbps: Double?
        let networkTransferredBytes: Int64?
        let avSyncGapMs: Double?
        let forwardBufferSeconds: Double?

        switch engine.playbackBackend {
        case .native:
            observedFps = nil
            if let item = engine.currentAVPlayer?.currentItem,
               let event = item.accessLog()?.events.last {
                droppedFrameCount = event.numberOfDroppedVideoFrames >= 0
                    ? event.numberOfDroppedVideoFrames : nil
                let observed = event.observedBitrate
                networkThroughputMbps = observed.isFinite && observed > 0
                    ? observed / 1_000_000.0 : nil
                networkTransferredBytes = event.numberOfBytesTransferred >= 0
                    ? Int64(event.numberOfBytesTransferred) : nil
            } else {
                droppedFrameCount = nil
                networkThroughputMbps = nil
                networkTransferredBytes = nil
            }
            avSyncGapMs = engine.lastAVGapMs  // HLSSegmentProducer audio-gate-open vs video-gate-open (native path only)
            forwardBufferSeconds = Self.computeNativeForwardBuffer(engine: engine)

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

        if engine.playbackBackend == .native {
            emitLagDiag(engine: engine, forwardBuffer: forwardBufferSeconds, netMbps: instantBitrateMbps)
        }

        let snapshot = LiveTelemetry(
            instantBitrateMbps: instantBitrateMbps,
            averageBitrateMbps: averageBitrateMbps,
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
    private func emitLagDiag(engine: AetherEngine, forwardBuffer: Double?, netMbps: Double?) {
        guard let player = engine.currentAVPlayer, let item = player.currentItem else { return }
        let clock = player.currentTime().seconds
        let dclk = (clock.isFinite && lagLastClock != nil) ? clock - lagLastClock! : nil
        if clock.isFinite { lagLastClock = clock }

        let droppedSum = item.accessLog()?.events.reduce(0) { $0 + max(0, $1.numberOfDroppedVideoFrames) } ?? 0
        let dDrop = droppedSum - lagLastDroppedSum
        lagLastDroppedSum = droppedSum

        let tcs: String
        switch player.timeControlStatus {
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
            + "tcs=\(tcs) rate=\(fmt2(Double(player.rate))) wait=\(player.reasonForWaitingToPlay?.rawValue ?? "-") "
            + "fwd=\(forwardBuffer.map { String(format: "%.1f", $0) } ?? "-") "
            + "keepUp=\(item.isPlaybackLikelyToKeepUp ? "y" : "n") empty=\(item.isPlaybackBufferEmpty ? "y" : "n") "
            + "drop=\(droppedSum)+\(dDrop) stall=\(engine.nativeHost?.stallCount ?? 0) "
            + "ready=\((engine.nativeHost?.playerLayer.isReadyForDisplay ?? false) ? "y" : "n") "
            + "thermal=\(thermal) net=\(netMbps.map { String(format: "%.1f", $0) } ?? "-") "
            + "restarts=\(engine.producerRestartCount)",
            category: .engine, level: .verbose
        )
    }

    private static func computeNativeForwardBuffer(engine: AetherEngine) -> Double? {
        guard let player = engine.currentAVPlayer,
              let item = player.currentItem else { return nil }
        let ranges = item.loadedTimeRanges
        guard let last = ranges.last?.timeRangeValue else { return nil }
        let end = CMTimeGetSeconds(CMTimeAdd(last.start, last.duration))
        let now = CMTimeGetSeconds(player.currentTime())
        guard end.isFinite, now.isFinite else { return nil }
        return max(0, end - now)
    }
}
