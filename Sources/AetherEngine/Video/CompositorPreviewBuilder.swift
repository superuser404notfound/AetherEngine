// Sources/AetherEngine/Video/CompositorPreviewBuilder.swift
import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Turns a resident segment into a standalone video-only fMP4 that a second AVPlayer can show through
/// the system compositor. That is the only place a Dolby Vision Profile 5 / 10.0 picture gets its
/// colour on Apple platforms: no still API applies the RPU, and an `AVPlayerItemVideoOutput` on the
/// item switches that processing off for the layer too.
///
/// The packets come out of the segment the session already muxed, so they carry every conversion the
/// playing picture got, and the init is rebuilt from the segment's own demuxed parameters: the
/// sample entry, `dvcC` and `colr` therefore say what the playing item says. The init carries no
/// audio track, so the item has nothing to wait for.
enum CompositorPreviewBuilder {
    enum Content {
        /// The keyframe that opens the segment, alone, at file time 0 (scrub preview).
        case firstKeyframe
        /// Every video sample of the segment, so a seek can land on any frame of it (held picture).
        /// Where its first frame sits on the player's clock is the player's business: AVFoundation
        /// honours the init's edit list and starts at 0, ffmpeg reports the composition delay.
        case wholeSegment
    }

    struct Output {
        let file: Data
        /// How far the segment's first frame sits behind its first decode time (the B-frame delay).
        /// A frame's offset past the standalone file's first frame is its item time minus the segment's
        /// start plus this delay: measured pixel-exact against the paused outgoing picture on three
        /// Profile 5 clips (24 fps with 0.083 s, 30 fps with 0.067 s, and one cut 1.2 s off a keyframe),
        /// where leaving the delay out lands two frames early. 0 for `.firstKeyframe`.
        let compositionDelaySeconds: Double
    }

    static func build(initData: Data, segmentURL: URL, durationSeconds: Double,
                      codecTagOverride: String?, colorOverride: MP4SegmentMuxer.ColorOverride?,
                      stagingDir: URL, content: Content = .firstKeyframe) -> Output? {
        guard let segment = try? Data(contentsOf: segmentURL, options: .alwaysMapped) else { return nil }
        let demuxer = Demuxer()
        defer { demuxer.close() }
        do {
            try demuxer.open(reader: DataIOReader(parts: [initData, segment]), formatHint: "mp4",
                             profile: .stillExtraction)
        } catch {
            return nil
        }
        let videoIdx = demuxer.videoStreamIndex
        guard videoIdx >= 0, let stream = demuxer.stream(at: videoIdx),
              let codecpar = stream.pointee.codecpar else { return nil }
        demuxer.discardAllStreamsExcept([videoIdx])
        let timeBase = stream.pointee.time_base
        guard timeBase.num > 0, timeBase.den > 0 else { return nil }
        let video = MP4SegmentMuxer.VideoConfig(
            codecpar: UnsafePointer(codecpar), timeBase: timeBase,
            codecTagOverride: codecTagOverride, doviConfig: .keep, colorOverride: colorOverride)

        switch content {
        case .firstKeyframe:
            // The segment opens on its keyframe; a bound keeps a malformed one from walking the file.
            var payload: Data?
            for _ in 0..<64 {
                guard let packet = try? demuxer.readPacket() else { break }
                defer { av_packet_unref(packet); av_packet_free_safe(packet) }
                guard packet.pointee.stream_index == videoIdx,
                      packet.pointee.flags & AV_PKT_FLAG_KEY != 0, let data = packet.pointee.data,
                      packet.pointee.size > 0 else { continue }
                payload = Data(bytes: data, count: Int(packet.pointee.size))
                break
            }
            guard let payload,
                  let output = IFrameFragmentBuilder(video: video, stagingDir: stagingDir)
                    .build(payload: payload, index: 0, startSeconds: 0,
                           durationSeconds: max(durationSeconds, 0.04)) else { return nil }
            return Output(file: output.initSegment + output.fragment, compositionDelaySeconds: 0)

        case .wholeSegment:
            return remuxWholeSegment(demuxer: demuxer, videoIdx: videoIdx, video: video, stagingDir: stagingDir)
        }
    }

    /// Every video packet, shifted so the first decode time is 0, into one fragment.
    private static func remuxWholeSegment(demuxer: Demuxer, videoIdx: Int32,
                                          video: MP4SegmentMuxer.VideoConfig, stagingDir: URL) -> Output? {
        var initBytes = Data()
        guard let muxer = try? MP4SegmentMuxer(
            initialSegmentIndex: 0, sessionDir: stagingDir, video: video, audio: nil, isOneShot: true,
            onInitCaptured: { initBytes = $0 }) else { return nil }
        var completed: URL?
        defer {
            _ = muxer.finalize()
            if let completed { try? FileManager.default.removeItem(at: completed) }
        }
        var firstDts: Int64?
        var firstFramePts: Int64?
        var written = 0
        // A segment is a few seconds of one GOP or a handful; the bound only stops a malformed file.
        for _ in 0..<20_000 {
            guard let packet = try? demuxer.readPacket() else { break }
            defer { av_packet_unref(packet); av_packet_free_safe(packet) }
            guard packet.pointee.stream_index == videoIdx, packet.pointee.size > 0 else { continue }
            let dts = packet.pointee.dts != Int64.min ? packet.pointee.dts : packet.pointee.pts
            let pts = packet.pointee.pts != Int64.min ? packet.pointee.pts : dts
            guard dts != Int64.min else { continue }
            if firstDts == nil {
                guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0 else { return nil }
                firstDts = dts
            }
            let base = firstDts ?? dts
            firstFramePts = min(firstFramePts ?? pts, pts)
            packet.pointee.dts = dts - base
            packet.pointee.pts = pts - base
            packet.pointee.stream_index = muxer.videoOutputStreamIndex
            av_packet_rescale_ts(packet, video.timeBase, muxer.muxerVideoTimeBase)
            guard muxer.writePacket(packet).rc >= 0 else { return nil }
            written += 1
        }
        guard written > 0, let firstDts, let firstFramePts,
              case .completed(let path, _) = muxer.cutFragmentForNextSegment(1) else { return nil }
        completed = path
        guard let fragment = try? Data(contentsOf: path), !fragment.isEmpty, !initBytes.isEmpty else { return nil }
        let ticks = Double(video.timeBase.num) / Double(video.timeBase.den)
        return Output(file: initBytes + fragment,
                      compositionDelaySeconds: max(0, Double(firstFramePts - firstDts) * ticks))
    }
}
