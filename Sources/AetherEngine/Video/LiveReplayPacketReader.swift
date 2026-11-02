import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Demux-thread-only admission before software clock folding, recording, and DVR storage.
/// Owns quarantined packets; the caller owns each returned packet. A single source worker owns
/// every operation; unchecked Sendable permits transferring that ownership to its read closure.
final class LiveReplayPacketReader: @unchecked Sendable {
    enum Failure: LocalizedError {
        case interruptedReplay
        var errorDescription: String? { "Live source ended or diverged during verified replay." }
    }
    private struct Pending {
        let packet: UnsafeMutablePointer<AVPacket>
        let signature: LivePacketReplayGuard.Signature?
        let seconds: Double
        let duplicate: Bool
        var untimedBoundaryVideo = false
    }
    private var guardState = LivePacketReplayGuard()
    private var pending: [Pending] = []
    private var ready: [Pending] = []
    private var readyIndex = 0
    private var pendingBytes = 0
    private var deferredError: Error?
    private var videoFrontier = Int64.min
    private var audioFrontier = Int64.min
    private let videoIndex: Int32
    private let audioIndex: Int32
    private let videoTimeBase: Double
    private let audioTimeBase: Double
    private var videoProgress = VideoPacketProgress()

    init(videoIndex: Int32, audioIndex: Int32, videoTimeBase: Double, audioTimeBase: Double) {
        self.videoIndex = videoIndex
        self.audioIndex = audioIndex
        self.videoTimeBase = videoTimeBase
        self.audioTimeBase = audioTimeBase
    }

    deinit { free(pending); free(Array(ready.dropFirst(readyIndex))) }

    private func free(_ packets: [Pending]) {
        for entry in packets {
            var packet: UnsafeMutablePointer<AVPacket>? = entry.packet
            av_packet_free(&packet)
        }
    }

    /// Only explicit positioning invalidates source history. Transport reconnects retain it.
    func reset() {
        free(pending); free(Array(ready.dropFirst(readyIndex)))
        pending.removeAll(); ready.removeAll(); readyIndex = 0; pendingBytes = 0
        deferredError = nil
        videoFrontier = Int64.min; audioFrontier = Int64.min
        guardState.reset()
        videoProgress = VideoPacketProgress()
    }

    private func finish(verified: Bool, preserveHistory: Bool = false) throws {
        let preserveHistory = preserveHistory || guardState.isHoldingDamagedBoundary
        if !verified, guardState.confirmedPrefix != nil {
            free(pending); pending.removeAll(); pendingBytes = 0
            throw Failure.interruptedReplay
        }
        if verified {
            let boundary = LivePacketReplayGuard.videoBoundarySummary(pending.map {
                (signature: $0.signature, corrupt: ($0.packet.pointee.flags & AV_PKT_FLAG_CORRUPT) != 0,
                 duplicate: $0.duplicate, keyframe: ($0.packet.pointee.flags & AV_PKT_FLAG_KEY) != 0)
            })
            EngineLog.emit("[ReplayVideoBoundary] route=software damaged=\(boundary.damaged) replaced=\(boundary.replaced) unreplaced=\(boundary.unreplaced) retained=\(boundary.retained) keyframes=\(boundary.keyframes) superseded=\(boundary.superseded) untimed=\(pending.filter { $0.untimedBoundaryVideo }.count)", category: .swPlayback)
        }
        for entry in pending {
            let corrupt = (entry.packet.pointee.flags & AV_PKT_FLAG_CORRUPT) != 0
            if verified && (entry.duplicate || corrupt || entry.untimedBoundaryVideo) { free([entry]) }
            else { ready.append(entry) }
        }
        if verified {
            let order = LivePacketReplayGuard.verifiedPacketOrder(ready.map(\.signature))
            let kept = Set(order)
            for index in ready.indices where !kept.contains(index) { free([ready[index]]) }
            ready = order.map { ready[$0] }
            for entry in ready {
                if let signature = entry.signature { guardState.retainForwardedReplayPacket(signature) }
            }
        }
        pending.removeAll(keepingCapacity: true); pendingBytes = 0
        if !verified {
            if preserveHistory {
                guardState.releaseDamagedBoundary()
                EngineLog.emit("[SWHost] live damaged boundary unconfirmed: forwarding retained packets without resetting source history", category: .swPlayback)
            }
            else { guardState.reset() }
        }
    }

    func read(isCurrent: () -> Bool = { true },
              from source: () throws -> UnsafeMutablePointer<AVPacket>?) throws -> UnsafeMutablePointer<AVPacket>? {
        while isCurrent() {
            if readyIndex < ready.count {
                let entry = ready[readyIndex]
                readyIndex += 1
                if readyIndex == ready.count { ready.removeAll(keepingCapacity: true); readyIndex = 0 }
                admit(entry)
                return entry.packet
            }
            if let error = deferredError { deferredError = nil; throw error }
            let packet: UnsafeMutablePointer<AVPacket>?
            do { packet = try source() }
            catch {
                guard !pending.isEmpty else { throw error }
                deferredError = error
                try finish(verified: false)
                continue
            }
            guard let packet else {
                if pending.isEmpty { return nil }
                try finish(verified: false)
                continue
            }
            guard isCurrent() else {
                var stale: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&stale)
                reset()
                return nil
            }
            let index = packet.pointee.stream_index
            let stream: LivePacketReplayGuard.Stream? = index == videoIndex ? .video
                : (index == audioIndex ? .audio : nil)
            let timeBase = stream == .video ? videoTimeBase : audioTimeBase
            var signature: LivePacketReplayGuard.Signature?
            let seconds = Double(packet.pointee.dts) * timeBase
            if let stream, timeBase > 0, packet.pointee.dts != Int64.min, packet.pointee.pts != Int64.min,
               let data = packet.pointee.data, packet.pointee.size > 0 {
                signature = .init(stream: stream, dts: packet.pointee.dts, pts: packet.pointee.pts,
                    payload: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)))
            }
            let decision = signature.map {
                guardState.inspect($0, sourceSeconds: seconds, timeBaseSeconds: timeBase,
                    videoFrontier: videoFrontier, audioFrontier: audioFrontier, hasAudio: audioIndex >= 0,
                    isCorrupt: (packet.pointee.flags & AV_PKT_FLAG_CORRUPT) != 0)
            }
            if decision?.drop == true, !guardState.isDroppingReplay, decision?.event == nil {
                var duplicate: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&duplicate)
                continue
            }
            let untimedBoundaryVideo = guardState.isHoldingDamagedBoundary && signature == nil && index == videoIndex
            let entry = Pending(packet: packet, signature: signature, seconds: seconds,
                                duplicate: decision?.drop ?? false, untimedBoundaryVideo: untimedBoundaryVideo)
            if guardState.isDroppingReplay || decision?.holdDamagedBoundary == true || decision?.event != nil
                || (!pending.isEmpty && (!guardState.isHoldingDamagedBoundary || untimedBoundaryVideo)) {
                if signature == nil, (packet.pointee.flags & AV_PKT_FLAG_CORRUPT) != 0 {
                    guardState.noteDamagedPacket()
                }
                pending.append(entry); pendingBytes += max(0, Int(packet.pointee.size))
                switch decision?.event {
                case .damagedBoundaryHeld:
                    EngineLog.emit("[SWHost] live damaged boundary held: sourceSeconds=\(String(format: "%.3f", seconds)); waiting for replay evidence before publishing video", category: .swPlayback)
                case .damagedBoundaryForwarded:
                    try finish(verified: false, preserveHistory: true)
                case .finished(let video, let audio, let duration):
                    try finish(verified: true)
                    EngineLog.emit("[SWHost] live source overlap resolved: removed \(video) video + \(audio) audio packets across \(String(format: "%.2f", duration))s; preserving DVR timeline", category: .swPlayback)
                case .mismatch, .interrupted:
                    try finish(verified: false)
                default:
                    if pending.count > LivePacketReplayGuard.maximumPendingPackets
                        || pendingBytes > LivePacketReplayGuard.maximumPendingBytes {
                        try finish(verified: false)
                    }
                }
                continue
            }
            admit(entry)
            return packet
        }
        reset()
        return nil
    }

    private func admit(_ entry: Pending) {
        guard let signature = entry.signature else { return }
        if signature.stream == .video, let gap = videoProgress.observe(entry.seconds) {
            EngineLog.emit("[VideoPacketProgress] event=gap route=software previous=\(String(format: "%.3f", gap.previous)) dts=\(String(format: "%.3f", entry.seconds)) gap=\(String(format: "%.3f", gap.seconds)) cadence=\(String(format: "%.3f", gap.cadence))", category: .swPlayback)
        }
        guardState.record(signature, sourceSeconds: entry.seconds)
        if signature.stream == .video { videoFrontier = signature.dts }
        else { audioFrontier = signature.dts }
    }
}
