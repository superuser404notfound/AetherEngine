// Sources/AetherEngine/Video/IFrameFragmentBuilder.swift
import Foundation
import AetherLibavcodec

/// AE#682: wraps one keyframe into one fMP4 fragment on the main rendition's timeline.
///
/// A fresh muxer per fragment, deliberately: the session muxer requires strictly increasing dts,
/// and AVKit asks for I-frames in any order (an overview across the whole title first, then
/// wherever the finger is). The init carries no timing, so every muxer writes the same one.
final class IFrameFragmentBuilder {
    struct Output {
        let initSegment: Data
        let fragment: Data
    }

    private let video: MP4SegmentMuxer.VideoConfig
    private let stagingDir: URL

    init(video: MP4SegmentMuxer.VideoConfig, stagingDir: URL) {
        self.video = video
        self.stagingDir = stagingDir
    }

    func build(payload: Data, index: Int, startSeconds: Double, durationSeconds: Double) -> Output? {
        guard !payload.isEmpty, payload.count <= Int(Int32.max),
              video.timeBase.num > 0, video.timeBase.den > 0 else { return nil }
        var initBytes = Data()
        guard let muxer = try? MP4SegmentMuxer(
            initialSegmentIndex: index, sessionDir: stagingDir, video: video, audio: nil, isOneShot: true,
            onInitCaptured: { initBytes = $0 }) else { return nil }
        var completed: URL?
        defer {
            _ = muxer.finalize()
            if let completed { try? FileManager.default.removeItem(at: completed) }
        }

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        guard let packet, av_new_packet(packet, Int32(payload.count)) == 0,
              let dst = packet.pointee.data else { return nil }
        payload.copyBytes(to: dst, count: payload.count)

        let ticksPerSecond = Double(video.timeBase.den) / Double(video.timeBase.num)
        let start = Int64((startSeconds * ticksPerSecond).rounded())
        packet.pointee.pts = start
        packet.pointee.dts = start
        packet.pointee.duration = max(1, Int64((durationSeconds * ticksPerSecond).rounded()))
        packet.pointee.flags = AV_PKT_FLAG_KEY
        packet.pointee.stream_index = muxer.videoOutputStreamIndex
        av_packet_rescale_ts(packet, video.timeBase, muxer.muxerVideoTimeBase)

        guard muxer.writePacket(packet).rc >= 0,
              case .completed(let path, _) = muxer.cutFragmentForNextSegment(index + 1) else { return nil }
        completed = path
        guard let fragment = try? Data(contentsOf: path), !fragment.isEmpty, !initBytes.isEmpty else {
            return nil
        }
        return Output(initSegment: initBytes, fragment: fragment)
    }
}
