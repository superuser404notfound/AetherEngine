import Foundation
import AetherLibavcodec
import AetherLibavutil

enum H264RecoveryPointProbe {
    struct Result {
        var evidence = H264RecoveryPoint.Evidence()
        var videoPackets = 0
        var packetsRead = 0
    }

    /// Consumes a bounded packet sample; the caller must rewind the reused demuxer.
    /// Like InterlaceProbe, this does not race AVIO prefetch by changing its deadline.
    static func run(demuxer: Demuxer, streamIndex: Int32) -> Result {
        var result = Result()
        guard streamIndex >= 0, let stream = demuxer.stream(at: streamIndex),
              let parameters = stream.pointee.codecpar,
              parameters.pointee.codec_id == AV_CODEC_ID_H264 else { return result }
        let framing = A53SEIParser.nalFraming(codec: .h264,
            extradata: parameters.pointee.extradata, size: Int(parameters.pointee.extradata_size))
        let deadline = Date(timeIntervalSinceNow: 3)
        while result.videoPackets < 180, result.packetsRead < 600, Date() < deadline {
            guard let packet = try? demuxer.readPacket() else { break }
            result.packetsRead += 1
            defer {
                av_packet_unref(packet)
                av_packet_free_safe(packet)
            }
            guard packet.pointee.stream_index == streamIndex else { continue }
            result.videoPackets += 1
            guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0,
                  let data = packet.pointee.data, packet.pointee.size > 0 else { continue }
            var hasIDR = false
            var hasNonIDRSlice = false
            var recovery = false
            A53SEIParser.forEachNAL(data, Int(packet.pointee.size), framing) { nal, size in
                guard size > 0 else { return }
                if nal[0] & 31 == 5 { hasIDR = true }
                if nal[0] & 31 == 1, nal[0] & 0x80 == 0 { hasNonIDRSlice = true }
                if nal[0] & 31 == 6, size <= 4096 {
                    recovery = recovery || H264RecoveryPoint.isImmediateExactRecovery(
                        seiNAL: Array(UnsafeBufferPointer(start: nal, count: size)))
                }
            }
            result.evidence.observe(containerKey: true, hasIDR: hasIDR,
                                    immediateExactRecovery: recovery && hasNonIDRSlice)
            if result.evidence.requiresCompatibilityPath { break }
        }
        return result
    }
}
