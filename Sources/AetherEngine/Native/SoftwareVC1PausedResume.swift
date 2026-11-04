import Foundation
import AetherLibavcodec
import AetherLibavutil

/// A cold VC-1 decoder cannot reconstruct a paused picture from a mid-GOP packet.
/// Leave the demux cursor on a verified keyframe BEFORE the requested picture. The
/// normal decode loop then builds its references with the original skip/clock target.
enum SoftwareVC1PausedResume {
    static let lookbackSeconds = 4.0
    static let maximumPrerollSeconds = 8.0
    static let budgetSeconds = 8.0
    static let packetLimit = 8192
    static let byteLimit = 32 * 1024 * 1024

    static func acceptsKeyframe(pts: Double, target: Double) -> Bool {
        pts.isFinite && target.isFinite && pts <= target
            && target - pts <= maximumPrerollSeconds
    }

    /// The actual load boundary: blocking preparation stays off the cooperative pool, and
    /// cancelling the task awaiting it interrupts the source rather than just abandoning a wait.
    static func prepareOffMain(dem: Demuxer, target: Double, origin: Double,
                               videoIndex: Int32, timeBase: Double,
                               isCurrent: @escaping @Sendable () -> Bool) async throws -> Double {
        let priming = BlockingWork.detached(priority: .userInitiated) {
            try prepare(dem: dem, target: target, origin: origin,
                        videoIndex: videoIndex, timeBase: timeBase, isCurrent: isCurrent)
        }
        return try await withTaskCancellationHandler {
            try await priming.value
        } onCancel: {
            priming.cancel()
            dem.markClosed()
        }
    }

    /// Runs before any cache producer or decoder loop owns the demuxer. Peeking one
    /// packet leaves the admitted keyframe intact for either the disk or direct route.
    static func prepare(dem: Demuxer, target: Double, origin: Double,
                        videoIndex: Int32, timeBase: Double,
                        isCurrent: @Sendable () -> Bool) throws -> Double {
        let deadline = ProcessInfo.processInfo.systemUptime + budgetSeconds
        guard isCurrent() else { throw CancellationError() }
        guard dem.seekBounded(to: max(origin, target - lookbackSeconds),
                              timeout: budgetSeconds) else {
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
        // Never fail open on a non-key packet or move the requested pause to a later GOP.
        throw SoftwarePlaybackHost.HostError.repositionFailed
    }
}
