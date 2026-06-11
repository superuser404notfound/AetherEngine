import Foundation
import AVFoundation

/// Bounded ring buffer that retains the most recent `capacity` values
/// and exposes their sum. Used for 10-second rolling windows of byte
/// counts (for instant-bitrate) and frame counts (for observed FPS).
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

    /// Number of slots actually populated (less than `capacity` until
    /// the buffer wraps for the first time). Used by the sampler to
    /// keep instant-bitrate `nil` until the window has at least 2
    /// samples, one sample is a delta of zero seconds.
    var count: Int { filled ? capacity : index }

    mutating func reset() {
        for i in 0..<buffer.count { buffer[i] = .zero }
        index = 0
        filled = false
    }
}

/// Drives `engine.diagnostics.liveTelemetry` at 1 Hz while the engine
/// is `.playing` or `.paused`. Owns no playback state; reads
/// from the engine's existing subsystem counters once per tick and
/// assembles a `LiveTelemetry` snapshot.
///
/// Started from `AetherEngine` at the same lifecycle points as the
/// memprobe task. Stopped in `stopInternal`.
@MainActor
final class LiveTelemetrySampler {
    private weak var engine: AetherEngine?
    private var task: Task<Void, Never>?

    // 10-second rolling windows (10 buckets, 1 second each).
    private var byteWindow = RollingWindow<Int64>(capacity: 10, zero: 0)
    private var frameWindow = RollingWindow<Int>(capacity: 10, zero: 0)

    // Previous-tick snapshots for delta calculation.
    private var lastDemuxerBytes: Int64 = 0
    private var lastFramesEnqueued: Int = 0
    private var sessionStartTime: Date?
    private var sessionStartBytes: Int64 = 0

    init(engine: AetherEngine) {
        self.engine = engine
    }

    func start() {
        stop()
        byteWindow.reset()
        frameWindow.reset()
        // Seed from the CURRENT counters, not zero: the demuxer has
        // already prefetched by the time the sampler starts, and a
        // zero seed pushed the whole accumulated byte count into the
        // first tick's window, inflating the instant bitrate for the
        // first ~10 s of every session.
        lastDemuxerBytes = engine?.demuxerBytesFetched ?? 0
        lastFramesEnqueued = 0
        sessionStartTime = Date()
        sessionStartBytes = 0
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

        // ---- Demuxer-driven instant + average bitrate (works on both paths) ----
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

        // ---- Per-path FPS, dropped frames, network, sync gap ----
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
            // Gap is measured by HLSSegmentProducer (audio gate open vs.
            // video gate open in source-clock ms). The producer only runs
            // on the native path, so this is where the value belongs;
            // the software host enqueues directly into the sample buffer
            // and has no comparable pre-mux gap to expose.
            avSyncGapMs = engine.lastAVGapMs
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
            // Software path: same source as instant bitrate (the
            // demuxer pulls the same bytes off the network).
            networkThroughputMbps = instantBitrateMbps
            networkTransferredBytes = demuxerBytes
            avSyncGapMs = nil  // see .native arm — the producer that measures the gap doesn't run on this path
            forwardBufferSeconds = nil  // software host has no comparable surface yet

        case .aether, .none, .audio:
            observedFps = nil
            droppedFrameCount = nil
            networkThroughputMbps = nil
            networkTransferredBytes = nil
            avSyncGapMs = nil
            forwardBufferSeconds = nil
        }

        // ---- Engine diagnostics (always populated, cheap) ----
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
