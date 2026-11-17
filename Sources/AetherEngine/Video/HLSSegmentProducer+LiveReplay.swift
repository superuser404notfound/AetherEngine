import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

// The live replay buffer: packet lifetimes across its commit, rollback, forward and free paths.
extension HLSSegmentProducer {
    func commitReplayCandidate() {
        let boundary = LivePacketReplayGuard.videoBoundarySummary(replayPending.map {
            (signature: $0.sample?.signature, corrupt: damagedLivePacketStream($0.packet, origin: $0.origin) != nil,
             duplicate: $0.isDuplicate, keyframe: ($0.packet.pointee.flags & AV_PKT_FLAG_KEY) != 0)
        })
        EngineLog.emit("[ReplayVideoBoundary] route=native damaged=\(boundary.damaged) replaced=\(boundary.replaced) unreplaced=\(boundary.unreplaced) retained=\(boundary.retained) keyframes=\(boundary.keyframes) superseded=\(boundary.superseded) untimed=\(replayPending.filter { $0.untimedBoundaryVideo }.count)", category: .session)
        for entry in replayPending {
            // Once both tracks prove the overlap, discard its damaged boundary packets too.
            // A truncated PES can carry valid timestamps beyond the retained audio frontier.
            let damaged = damagedLivePacketStream(entry.packet, origin: entry.origin) != nil
            if entry.isDuplicate || damaged || entry.untimedBoundaryVideo {
                if damaged { logDamagedLivePacket(entry.packet, origin: entry.origin, action: "discarded") }
                var packet: UnsafeMutablePointer<AVPacket>? = entry.packet
                trackedPacketFree(&packet)
            } else {
                replayReady.append(entry)
            }
        }
        let order = LivePacketReplayGuard.verifiedPacketOrder(replayReady.map { $0.sample?.signature })
        let kept = Set(order)
        for index in replayReady.indices where !kept.contains(index) {
            var duplicate: UnsafeMutablePointer<AVPacket>? = replayReady[index].packet
            trackedPacketFree(&duplicate)
        }
        replayReady = order.map { replayReady[$0] }
        for entry in replayReady {
            if let signature = entry.sample?.signature { liveReplayGuard.retainForwardedReplayPacket(signature) }
        }
        replayPending.removeAll(keepingCapacity: true)
        replayPendingBytes = 0
        noCutWatchdog?.setReplayChecking(false, at: Date())
    }

    func rollbackReplayCandidate(reason: String,
                                         divergentStream: LivePacketReplayGuard.Stream? = nil) throws {
        if liveReplayGuard.isHoldingDamagedBoundary {
            forwardUnverifiedDamagedBoundary()
            return
        }
        if let evidence = liveReplayGuard.confirmedPrefix {
            let code: String = switch reason {
            case let value where value.hasPrefix("track diverged"): "track_diverged"
            case "source read failed before overlap was confirmed": "read_failed"
            case "source ended before overlap was confirmed": "source_ended"
            case "bounded overlap check reached its limit": "bounded_limit"
            default: "unknown"
            }
            let stream = divergentStream.map { $0 == .video ? "video" : "audio" } ?? "none"
            EngineLog.emit(
                "[HLSSegmentProducer] verified live replay interrupted: reason=\(code) stream=\(stream) "
                + "videoMatches=\(evidence.videoPackets) audioMatches=\(evidence.audioPackets) "
                + "videoSeconds=\(String(format: "%.2f", evidence.videoSeconds)) "
                + "audioSeconds=\(String(format: "%.2f", evidence.audioSeconds)); "
                + "requesting fresh source without forwarding overlap",
                category: .session)
            freeReplayPackets()
            interruptedReplayHistory = liveReplayGuard.sourceContinuation()
            liveReplayGuard.reset()
            throw InterruptedSourceReplay()
        }
        replayReady.append(contentsOf: replayPending)
        replayPending.removeAll(keepingCapacity: true)
        replayPendingBytes = 0
        liveReplayGuard.reset()
        noCutWatchdog?.setReplayChecking(false, at: Date())
        EngineLog.emit(
            "[HLSSegmentProducer] live source overlap unconfirmed: \(reason); "
            + "forwarding all packets to normal discontinuity handling",
            category: .session)
    }

    func forwardUnverifiedDamagedBoundary() {
        replayReady.append(contentsOf: replayPending)
        replayPending.removeAll(keepingCapacity: true)
        replayPendingBytes = 0
        liveReplayGuard.releaseDamagedBoundary()
        noCutWatchdog?.setReplayChecking(false, at: Date())
        EngineLog.emit("[HLSSegmentProducer] live damaged boundary unconfirmed: forwarding retained packets without resetting source history", category: .session)
    }

    /// AE#996 round 3: a timeline rebase starts the replay history over, and the packets a held
    /// damaged boundary retained belong to that history. The guard stops holding on reset, but the
    /// pump does not: with retained packets and an idle guard it read every later packet as part of
    /// an overlap and buffered it, so nothing was cut until the 10 s watchdog retuned (Kim's
    /// Convenience, at every seam whose outgoing PES was truncated). The seam is the evidence the
    /// boundary was not a replay, so its packets go out first, as an unconfirmed boundary does.
    ///
    /// Only an audio seam can forward them. A held boundary retains video alone, and a new picture
    /// passes it only from below the boundary's timestamp, so a VIDEO seam reached while holding
    /// leaves nothing in the buffer but the outgoing programme's last pictures. Behind the first
    /// picture of the new one they would only rebase the stream back; they are dropped, as the
    /// damaged packets of a confirmed overlap are.
    func resetLiveReplayGuardAtSeam(isVideoSeam: Bool) {
        if liveReplayGuard.isHoldingDamagedBoundary, !replayPending.isEmpty {
            if isVideoSeam {
                EngineLog.emit(
                    "[HLSSegmentProducer] live damaged boundary superseded by a video seam: "
                    + "dropping \(replayPending.count) retained outgoing packet(s)",
                    category: .session)
                for entry in replayPending {
                    var packet: UnsafeMutablePointer<AVPacket>? = entry.packet
                    trackedPacketFree(&packet)
                }
                replayPending.removeAll(keepingCapacity: true)
                replayPendingBytes = 0
                noCutWatchdog?.setReplayChecking(false, at: Date())
            } else {
                forwardUnverifiedDamagedBoundary()
            }
        }
        liveReplayGuard.reset()
    }

    func freeReplayPackets() {
        for entry in replayPending + replayReady.dropFirst(replayReadyIndex) {
            var packet: UnsafeMutablePointer<AVPacket>? = entry.packet
            trackedPacketFree(&packet)
        }
        replayPending.removeAll()
        replayReady.removeAll()
        replayReadyIndex = 0
        replayPendingBytes = 0
        replayDeferredError = nil
        noCutWatchdog?.setReplayChecking(false, at: Date())
    }

    func liveReplaySample(packet: UnsafeMutablePointer<AVPacket>, origin: PacketOrigin)
        -> LiveReplaySample? {
        // Only the single-demuxer stream-copy path has one source timeline for both tracks.
        // Side audio and bridged audio have independent clocks; the existing rebase owns them.
        guard isLive, sideAudioDemuxer == nil, audioConfig?.bridge == nil,
              packet.pointee.dts != Int64.min, packet.pointee.pts != Int64.min,
              packet.pointee.size > 0, let bytes = packet.pointee.data else { return nil }
        let stream: LivePacketReplayGuard.Stream
        let timeBaseSeconds: Double
        if origin == .main, packet.pointee.stream_index == videoStreamIndex {
            stream = .video
            timeBaseSeconds = sourceVideoTbSeconds
        } else if let audio = audioConfig,
                  packet.pointee.stream_index == audio.sourceStreamIndex,
                  origin == .main {
            stream = .audio
            timeBaseSeconds = audioSourceTbSeconds
        } else {
            return nil
        }
        guard timeBaseSeconds > 0 else { return nil }
        let signature = LivePacketReplayGuard.Signature(
            stream: stream, dts: packet.pointee.dts, pts: packet.pointee.pts,
            payload: UnsafeRawBufferPointer(start: bytes, count: Int(packet.pointee.size)))
        return LiveReplaySample(signature: signature,
                                seconds: Double(packet.pointee.dts) * timeBaseSeconds,
                                timeBaseSeconds: timeBaseSeconds)
    }
}
