import Darwin
import Foundation
import AetherLibavcodec
import AetherLibavutil

/// A forward-only source worker for software Live without a DVR feeder. The existing demuxer
/// remains the only source connection; consumed packets provide no seek history.
final class DirectLiveAudioReadAhead: @unchecked Sendable {
    /// Compressed source packets, admitted through replay filtering before reaching the consumer.
    let packets: SoftwarePacketReadAhead
    /// Maximum retained compressed video cost, including packet envelopes and side data.
    let parkedByteLimit: Int
    /// Maximum admitted packet cost; bounds source-read overshoot and transient copies.
    let packetByteLimit: Int
    /// Shared allowance retained by this consumer owner and independently by the producer.
    private let claim: RetentionClaims.Claim

    // Failure modes:
    // - No usable tracks or allowance: fail before starting a worker.
    // - Oversized packet or replay quarantine: fail explicitly, never discard valid media to fit.
    // - Stop during source I/O: keep the reservation until producer and consumer both retire.
    /// Reserves a bounded compressed reservoir off-main before starting any source reads.
    /// The reservation includes memory-store packing slack, parked video, replay and packet copies.
    init(
        demuxer: Demuxer,
        videoIndex: Int32,
        audioIndex: Int32,
        requestedBytes: Int?,
        retentionClaims: RetentionClaims = .shared
    ) throws {
        guard
            let vb = demuxer.withStream(at: videoIndex, { $0.pointee.time_base }),
            let ab = demuxer.withStream(at: audioIndex, { $0.pointee.time_base })
        else {
            throw Failure.unavailable
        }
        let available = (try? FileManager.default.temporaryDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityKey]
        ))?.volumeAvailableCapacity.map(Int64.init)
        let claim = retentionClaims.claim(volumeAvailableBytes: available) {
            min(64 << 20, SoftwarePlaybackHost.packetCacheBudgetBytes(
                requestedBytes: requestedBytes, availableBytes: $0, capRelaxed: false
            ))
        }
        // Each partition must cover at least sixteen VM pages. The whole reservation stays
        // unwritten in the ledger: memory allocation does not reduce free volume capacity.
        let unit = claim.bytes / 16
        guard unit >= 16 * Int(getpagesize()) else {
            claim.release()
            throw Failure.unavailable
        }
        self.claim = claim
        parkedByteLimit = unit
        packetByteLimit = unit
        let admission = LiveReplayPacketReader(
            videoIndex: videoIndex, audioIndex: audioIndex,
            videoTimeBase: av_q2d(vb), audioTimeBase: av_q2d(ab),
            residentLimit: 2 * unit, retainedSize: Self.packetBytes
        )
        // The producer gate permits one record of overshoot. Memory-store allocated capacity
        // is conservatively covered by four units plus two chunks (partially filled sealed
        // chunks count too). One unit parks video, two hold replay, and six cover simultaneous
        // AVPacket/Data/envelope copies. The remainder covers chunk/page overhead. The existing
        // replay guard separately bounds its digest-only history; it retains no media payload.
        let fifo = SoftwarePacketMemoryFIFO(
            chunkTargetBytes: Int(getpagesize()), historyCapBytes: 0
        )
        packets = SoftwarePacketReadAhead(
            video: .init(index: videoIndex, numerator: vb.num, denominator: vb.den),
            audio: .init(index: audioIndex, numerator: ab.num, denominator: ab.den),
            byteBudget: unit, forwardSeconds: AudioLookaheadPolicy.targetLeadSeconds,
            initialSourceClock: demuxer.resolvedSourceStartOrigin, fifo: fifo,
            forwardOnly: true
        ) { [claim] isCurrent in
            defer { withExtendedLifetime(claim) {} }
            guard let packet = try admission.read(isCurrent: isCurrent, from: {
                guard let packet = try demuxer.readPacket(isCurrent: isCurrent) else { return nil }
                do {
                    try Self.validatePacketSize(packet, limit: unit)
                } catch {
                    var oversized = Optional(packet)
                    av_packet_free(&oversized)
                    throw error
                }
                return packet
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

    /// Rejects a packet whose referenced allocation cannot fit the source's compressed allowance.
    /// Ownership stays with the caller on success and failure, so the source can retire it once.
    /// - Throws: `Failure.packetTooLarge` with the required and permitted allocation sizes.
    static func validatePacketSize(
        _ packet: UnsafePointer<AVPacket>,
        limit: Int
    ) throws {
        let bytes = packetBytes(packet)
        if bytes > limit {
            throw Failure.packetTooLarge(bytes: bytes, limit: limit)
        }
    }

    /// Retires the FIFO worker; host Demuxer.close interrupts any outstanding source read.
    /// Does not release the reservation while either producer or parked-video consumer owns it.
    func close() { packets.close() }

    /// Actionable resource failures for this forward-only path.
    enum Failure: Error, LocalizedError {
        /// A usable audio/video pair and minimum bounded allowance could not be obtained.
        case unavailable
        /// A packet cannot fit the compressed allowance without violating its bound.
        case packetTooLarge(bytes: Int, limit: Int)

        /// Explains which resource prevented playback and how the host can recover.
        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Live audio read-ahead requires usable audio/video tracks and a cache allowance. Increase the session allowance or free storage and retry."
            case .packetTooLarge(let bytes, let limit):
                return "A compressed Live packet needs \(bytes) bytes, exceeding its \(limit)-byte allowance. Increase the session cache allowance and retry."
            }
        }
    }
}
