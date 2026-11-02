import Darwin
import Foundation
import AetherLibavcodec
import AetherLibavutil

/// A forward-only source worker for software Live without a DVR feeder. The existing demuxer
/// remains the only source connection; consumed packets provide no seek history.
final class DirectLiveAudioReadAhead: @unchecked Sendable {
    /// Compressed source packets, admitted through replay filtering before reaching the consumer.
    let packets: SoftwarePacketReadAhead
    /// Pauses further source consumption after parked video reaches this in-memory cost.
    /// One valid packet may cross the bound; packet envelopes and side data count toward it.
    let parkedByteLimit = 4 << 20

    // Failure modes:
    // - No usable audio/video tracks: fail before starting a worker.
    // - A packet crosses the pacing bound: deliver it, then pause until consumption resumes.
    // - Stop during source I/O: the worker retains its source until the read unwinds.
    /// Creates independent in-memory forward and parked-video pacing bounds.
    /// Large packets may cross a bound once; disk capacity and DVR allowances do not apply.
    /// - Throws: `Failure.unavailable` when either selected stream is unavailable.
    init(
        demuxer: Demuxer,
        videoIndex: Int32,
        audioIndex: Int32
    ) throws {
        guard
            let vb = demuxer.withStream(at: videoIndex, { $0.pointee.time_base }),
            let ab = demuxer.withStream(at: audioIndex, { $0.pointee.time_base })
        else {
            throw Failure.unavailable
        }
        let admission = LiveReplayPacketReader(
            videoIndex: videoIndex, audioIndex: audioIndex,
            videoTimeBase: av_q2d(vb), audioTimeBase: av_q2d(ab)
        )
        // The producer parks after one record crosses its 4 MiB pacing bound. Consumed
        // packets retain no seek history; replay admission keeps its existing quarantine policy.
        let fifo = SoftwarePacketMemoryFIFO(
            chunkTargetBytes: Int(getpagesize()), historyCapBytes: 0
        )
        packets = SoftwarePacketReadAhead(
            video: .init(index: videoIndex, numerator: vb.num, denominator: vb.den),
            audio: .init(index: audioIndex, numerator: ab.num, denominator: ab.den),
            byteBudget: 4 << 20, forwardSeconds: AudioLookaheadPolicy.targetLeadSeconds,
            initialSourceClock: demuxer.resolvedSourceStartOrigin, fifo: fifo,
            forwardOnly: true
        ) { isCurrent in
            guard let packet = try admission.read(isCurrent: isCurrent, from: {
                try demuxer.readPacket(isCurrent: isCurrent)
            }) else { return nil }
            defer { av_packet_unref(packet); av_packet_free_safe(packet) }
            return try SoftwareStoredPacket(copying: packet)
        }
    }

    /// Counts referenced allocation capacity, side data and conservative packet/record headers.
    static func packetBytes(_ packet: UnsafePointer<AVPacket>) -> Int {
        let payload = max(Int(max(0, packet.pointee.size)), Int(packet.pointee.buf?.pointee.size ?? 0))
        if payload > Int.max - 512 { return Int.max }
        var bytes = 512 + payload
        if let side = packet.pointee.side_data {
            for index in 0..<Int(max(0, packet.pointee.side_data_elems)) {
                let size = side[index].size
                if size > Int.max - 64 || Int(size) + 64 > Int.max - bytes { return Int.max }
                bytes += Int(size) + 64
            }
        }
        return bytes
    }

    /// Retires the FIFO worker; host Demuxer.close interrupts any outstanding source read.
    func close() { packets.close() }

    /// Actionable stream-selection failures for this forward-only path.
    enum Failure: Error, LocalizedError {
        /// The selected audio/video stream pair is unavailable in the open demuxer.
        case unavailable

        /// Explains which source prerequisite prevented playback.
        var errorDescription: String? {
            "Live audio read-ahead requires usable audio and video tracks. Reopen the source and retry."
        }
    }
}
