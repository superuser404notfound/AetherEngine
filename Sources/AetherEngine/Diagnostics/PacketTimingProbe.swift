import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Offline differential probe for the #93 post-recovery judder: opens the source with a chosen
/// demuxer open profile, seeks, and reports raw video packet timing exactly as the demuxer
/// delivers it (before the producer's NOPTS repair and before muxing). Comparing `.playback`
/// against `.restartReopen` (skipStreamInfo) isolates whether the skipped
/// `avformat_find_stream_info` pass degrades dts reconstruction on Matroska B-frame content.
public enum PacketTimingProbe {

    public enum ProbeError: Error, CustomStringConvertible {
        case unknownProfile(String)
        case noVideoStream

        public var description: String {
            switch self {
            case .unknownProfile(let name):
                return "unknown profile '\(name)' (expected playback | restartReopen | stillExtraction)"
            case .noVideoStream:
                return "source has no video stream"
            }
        }
    }

    public static func run(
        url: URL,
        seekSeconds: Double,
        packetCount: Int,
        profileName: String,
        sampleLines: Int = 48
    ) throws -> String {
        let profile: DemuxerOpenProfile
        switch profileName {
        case "playback":        profile = .playback
        case "restartReopen":   profile = .restartReopen
        case "stillExtraction": profile = .stillExtraction
        default: throw ProbeError.unknownProfile(profileName)
        }

        var out = ""
        let demuxer = Demuxer()
        let openStart = DispatchTime.now()
        try demuxer.open(url: url, profile: profile)
        defer { demuxer.close() }
        let openMs = Double(DispatchTime.now().uptimeNanoseconds - openStart.uptimeNanoseconds) / 1_000_000
        out += "[PktDump] profile=\(profileName) open=\(String(format: "%.0f", openMs))ms\n"

        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx) else {
            throw ProbeError.noVideoStream
        }
        let tb = stream.pointee.time_base
        let avg = stream.pointee.avg_frame_rate
        let rfr = stream.pointee.r_frame_rate
        let delay = stream.pointee.codecpar?.pointee.video_delay ?? -1
        out += "[PktDump] stream[\(videoIdx)] tb=\(tb.num)/\(tb.den) "
            + "avg_frame_rate=\(avg.num)/\(avg.den) r_frame_rate=\(rfr.num)/\(rfr.den) "
            + "codecpar.video_delay=\(delay)\n"

        if seekSeconds > 0 {
            let seekStart = DispatchTime.now()
            demuxer.seek(to: seekSeconds)
            let seekMs = Double(DispatchTime.now().uptimeNanoseconds - seekStart.uptimeNanoseconds) / 1_000_000
            out += "[PktDump] seek to \(String(format: "%.2f", seekSeconds))s took \(String(format: "%.0f", seekMs))ms\n"
        }

        var videoSeen = 0
        var noptsDts = 0
        var noptsPts = 0
        var keyCount = 0
        var nonMonotonicDts = 0
        var lastDts: Int64?
        var dtsDeltaHist: [Int64: Int] = [:]
        var durationHist: [Int64: Int] = [:]
        var lines: [String] = []

        while videoSeen < packetCount {
            var pkt: UnsafeMutablePointer<AVPacket>?
            do {
                pkt = try demuxer.readPacket()
            } catch {
                out += "[PktDump] readPacket threw after \(videoSeen) video packets: \(error)\n"
                break
            }
            guard let packet = pkt else {
                out += "[PktDump] EOF after \(videoSeen) video packets\n"
                break
            }
            guard Int32(videoIdx) == packet.pointee.stream_index else {
                var toFree: UnsafeMutablePointer<AVPacket>? = packet
                trackedPacketFree(&toFree)
                continue
            }
            videoSeen += 1

            let dts = packet.pointee.dts
            let pts = packet.pointee.pts
            let dur = packet.pointee.duration
            let isKey = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0

            if dts == Int64.min { noptsDts += 1 }
            if pts == Int64.min { noptsPts += 1 }
            if isKey { keyCount += 1 }
            if dts != Int64.min {
                if let last = lastDts {
                    let d = dts - last
                    dtsDeltaHist[d, default: 0] += 1
                    if d <= 0 { nonMonotonicDts += 1 }
                }
                lastDts = dts
            }
            durationHist[dur, default: 0] += 1

            if lines.count < sampleLines {
                let dtsStr = dts == Int64.min ? "NOPTS" : "\(dts)"
                let ptsStr = pts == Int64.min ? "NOPTS" : "\(pts)"
                lines.append("  #\(String(format: "%03d", videoSeen)) \(isKey ? "K" : ".") dts=\(dtsStr) pts=\(ptsStr) dur=\(dur)")
            }

            var toFree: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&toFree)
        }

        out += "[PktDump] video packets=\(videoSeen) keyframes=\(keyCount) "
            + "NOPTS_dts=\(noptsDts) NOPTS_pts=\(noptsPts) nonMonotonicDts=\(nonMonotonicDts)\n"

        func histLine(_ hist: [Int64: Int], label: String) -> String {
            let top = hist.sorted { $0.value > $1.value }.prefix(8)
                .map { "\($0.key)x\($0.value)" }
                .joined(separator: " ")
            return "[PktDump] \(label): \(top)\n"
        }
        out += histLine(dtsDeltaHist, label: "dts-delta histogram (delta x count)")
        out += histLine(durationHist, label: "duration histogram (dur x count)")
        out += lines.joined(separator: "\n") + "\n"
        return out
    }
}
