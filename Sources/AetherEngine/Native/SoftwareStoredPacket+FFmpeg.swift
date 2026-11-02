import Foundation
import AetherLibavcodec
import AetherLibavutil

extension SoftwareStoredPacket {
    enum PacketError: Error { case invalidPacket, allocationFailed }

    init(copying packet: UnsafeMutablePointer<AVPacket>) throws {
        let p = packet.pointee
        guard p.size >= 0, p.side_data_elems >= 0,
              p.size == 0 || p.data != nil,
              p.side_data_elems == 0 || p.side_data != nil else { throw PacketError.invalidPacket }
        var sides: [SideData] = []
        for index in 0..<Int(p.side_data_elems) {
            let side = p.side_data[index]
            guard side.size == 0 || side.data != nil else { throw PacketError.invalidPacket }
            sides.append(SideData(type: side.type.rawValue,
                                  bytes: side.size == 0 ? Data() : Data(bytes: side.data, count: side.size)))
        }
        self.init(pts: p.pts, dts: p.dts, duration: p.duration, position: p.pos,
                  streamIndex: p.stream_index, flags: p.flags,
                  timeBaseNumerator: p.time_base.num, timeBaseDenominator: p.time_base.den,
                  bytes: p.size == 0 ? Data() : Data(bytes: p.data, count: Int(p.size)), sideData: sides)
    }

    /// Ownership transfers to the existing demux-loop caller, which uses av_packet_free_safe.
    func makeAVPacket() throws -> UnsafeMutablePointer<AVPacket> {
        guard bytes.count <= Int(Int32.max), let packet = trackedPacketAlloc() else {
            throw PacketError.allocationFailed
        }
        do {
            guard av_new_packet(packet, Int32(bytes.count)) >= 0 else { throw PacketError.allocationFailed }
            if !bytes.isEmpty { bytes.copyBytes(to: packet.pointee.data, count: bytes.count) }
            packet.pointee.pts = pts
            packet.pointee.dts = dts
            packet.pointee.duration = duration
            packet.pointee.pos = position
            packet.pointee.stream_index = streamIndex
            packet.pointee.flags = flags
            packet.pointee.time_base = AVRational(num: timeBaseNumerator, den: timeBaseDenominator)
            for side in sideData {
                guard let target = av_packet_new_side_data(
                    packet, AVPacketSideDataType(rawValue: side.type), side.bytes.count) else {
                    throw PacketError.allocationFailed
                }
                side.bytes.copyBytes(to: target, count: side.bytes.count)
            }
            if let cacheTimingEpoch {
                SoftwarePacketCacheIdentity.attach(epoch: cacheTimingEpoch, position: position, to: packet)
            }
            return packet
        } catch {
            av_packet_unref(packet)
            av_packet_free_safe(packet)
            throw error
        }
    }
}

/// The (source epoch, packet position) a stored video packet carries through the decoder for
/// `SoftwarePacketCacheTiming`. Ref-counted private observation metadata, never serialized and never
/// used to schedule frames. Kept apart from the timing class so this file still compiles on its own
/// (`Scripts/test-software-stored-packet.sh`).
enum SoftwarePacketCacheIdentity {
    static func attach(epoch: UInt64, position: Int64, to packet: UnsafeMutablePointer<AVPacket>) {
        guard packet.pointee.opaque_ref == nil, let buffer = av_buffer_alloc(24),
              let data = buffer.pointee.data else { return }
        var values = [UInt64(0x434143484554494d), epoch, UInt64(bitPattern: position)]
        values.withUnsafeMutableBytes { data.update(from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: 24) }
        packet.pointee.opaque_ref = buffer
    }

    static func identity(_ frame: UnsafeMutablePointer<AVFrame>) -> (UInt64, Int64)? {
        guard let buffer = frame.pointee.opaque_ref, buffer.pointee.size == 24,
              let data = buffer.pointee.data else { return nil }
        let raw = UnsafeRawPointer(data)
        guard raw.loadUnaligned(as: UInt64.self) == 0x434143484554494d else { return nil }
        return (raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                Int64(bitPattern: raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
    }
}
