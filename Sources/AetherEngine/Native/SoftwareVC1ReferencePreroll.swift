import Foundation
import AetherLibavcodec
import AetherLibavutil

/// A flushed VC-1 decoder cannot reconstruct a target picture from a mid-GOP packet.
/// Leave the demux cursor on a verified keyframe BEFORE the requested picture. The
/// normal decode loop then builds its references with the original skip/clock target.
enum SoftwareVC1ReferencePreroll {
    static let lookbackSeconds = 4.0
    static let maximumPrerollSeconds = 8.0
    static let budgetSeconds = 8.0
    static let packetLimit = 8192
    static let byteLimit = 32 * 1024 * 1024

    static func acceptsKeyframe(pts: Double, target: Double) -> Bool {
        pts.isFinite && target.isFinite && pts <= target
            && target - pts <= maximumPrerollSeconds
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var cancelled: Bool { lock.withLock { value } }
        func cancel() { lock.withLock { value = true } }
    }

    /// Both load and cache-miss seek use the host's serial seek queue. A failed probe is
    /// inconclusive, not a failed load: the existing reposition gets the remaining budget.
    static func reposition(dem: Demuxer, target: Double, origin: Double,
                           videoIndex: Int32, timeBase: Double, budget: TimeInterval,
                           queue: DispatchQueue, closesOnCancel: Bool,
                           isSuperseded: @escaping @Sendable () -> Bool,
                           fallback: SoftwarePlaybackHost.Reposition) async -> Demuxer.RepositionOutcome {
        let cancellation = Cancellation()
        let current: @Sendable () -> Bool = { !cancellation.cancelled && !isSuperseded() }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        return await withTaskCancellationHandler {
            let primed: Bool = await withCheckedContinuation { continuation in
                queue.async {
                    guard current() else { continuation.resume(returning: false); return }
                    do {
                        _ = try prepare(dem: dem, target: target, origin: origin,
                                        videoIndex: videoIndex, timeBase: timeBase,
                                        deadline: min(deadline, ProcessInfo.processInfo.systemUptime + budgetSeconds),
                                        isCurrent: current)
                        continuation.resume(returning: true)
                    } catch {
                        // Cancellation is distinguished below; every other probe failure falls back.
                        continuation.resume(returning: false)
                    }
                }
            }
            guard current() else { return .superseded }
            if primed { return .landed }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return .stalled }
            // seekBounded drops peeked packets and clears latched AVIO errors before retrying.
            let result = await fallback(dem, target, remaining, queue, { !current() })
            return current() ? result : .superseded
        } onCancel: {
            cancellation.cancel()
            // Only a cancelled whole load destroys this demuxer. A superseded transport
            // seek leaves it open for the newer operation on the same serial queue.
            if closesOnCancel { dem.markClosed() }
        }
    }

    /// Runs before readers start, or while their seek window parks them. Peeking one
    /// packet leaves the admitted keyframe intact for either the disk or direct route.
    static func prepare(dem: Demuxer, target: Double, origin: Double,
                        videoIndex: Int32, timeBase: Double,
                        deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + budgetSeconds,
                        isCurrent: @Sendable () -> Bool) throws -> Double {
        let initialRemaining = deadline - ProcessInfo.processInfo.systemUptime
        guard initialRemaining > 0 else { throw SoftwarePlaybackHost.HostError.repositionFailed }
        guard isCurrent() else { throw CancellationError() }
        guard dem.seekBounded(to: max(origin, target - lookbackSeconds),
                              timeout: initialRemaining) else {
            throw SoftwarePlaybackHost.HostError.repositionFailed
        }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw SoftwarePlaybackHost.HostError.repositionFailed }
        dem.beginReadDeadline(secondsFromNow: remaining)
        defer { dem.endReadDeadline() }
        return try findKeyframe(dem: dem, target: target, videoIndex: videoIndex,
                                timeBase: timeBase, deadline: deadline, isCurrent: isCurrent)
    }

    static func findKeyframe(dem: Demuxer, target: Double, videoIndex: Int32,
                             timeBase: Double, deadline: TimeInterval,
                             packetLimit: Int = packetLimit, byteLimit: Int = byteLimit,
                             isCurrent: @Sendable () -> Bool) throws -> Double {
        var bytes = 0
        for _ in 0..<packetLimit {
            guard isCurrent() else { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline, bytes < byteLimit else { break }
            var keyPTS: Double?
            var crossedTarget = false
            var sawPacket = false
            try dem.peekPackets(maxPackets: 1) { packet in
                sawPacket = true
                bytes += max(0, Int(packet.pointee.size))
                if packet.pointee.stream_index == videoIndex,
                   packet.pointee.pts != Int64.min, timeBase > 0 {
                    let pts = Double(packet.pointee.pts) * timeBase
                    crossedTarget = pts > target
                    if packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
                       acceptsKeyframe(pts: pts, target: target) { keyPTS = pts }
                }
                return true
            }
            guard isCurrent() else { throw CancellationError() }
            if let keyPTS, bytes <= byteLimit,
               ProcessInfo.processInfo.systemUptime < deadline { return keyPTS }
            guard sawPacket, !crossedTarget else { break }
            if let packet = try dem.readPacket(isCurrent: isCurrent) {
                var owned: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&owned)
            }
        }
        // The shared wrapper restores the original target through the fallback reposition.
        throw SoftwarePlaybackHost.HostError.repositionFailed
    }
}
