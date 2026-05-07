import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Session that turns a remote video source (typically a Jellyfin
/// MKV) into a local HLS-fMP4 stream AVPlayer can play. Built so the
/// existing AetherEngine demuxer + new `FMP4VideoMuxer` + new
/// `HLSLocalServer` cooperate around a lazy `HLSSegmentProvider`
/// implementation that generates one fragment per AVPlayer GET.
///
/// Only used for streams the host has classified as Dolby Vision
/// direct-play (the `.native` route in Sodalite's player). HDR10,
/// HDR10+, HLG and SDR continue to flow through AetherEngine's
/// FFmpeg + VideoToolbox + AVSampleBufferDisplayLayer pipeline,
/// because those don't need the AVPlayer-only HDMI handshake that
/// engages tvOS's true Dolby Vision mode on a capable TV.
///
/// Phase 4 of the rollout: video-only fragments. Audio routing into
/// the same fMP4 stream lands in phase 6. AVPlayer will play silent
/// video for now, which is enough to verify the DV signalling path.
final class HLSVideoEngine: @unchecked Sendable {

    // MARK: - Errors

    enum HLSVideoEngineError: Error, CustomStringConvertible {
        case openFailed(reason: String)
        case noVideoStream
        case unsupportedCodec(rawCodecID: UInt32)
        case noKeyframeIndex
        case unsupportedDVProfile(profile: Int, compatID: Int)
        case muxerInit(underlying: Error)
        case alreadyStarted
        case notStarted

        var description: String {
            switch self {
            case .openFailed(let r):     return "HLSVideoEngine: open failed (\(r))"
            case .noVideoStream:         return "HLSVideoEngine: source has no video stream"
            case .unsupportedCodec(let id): return "HLSVideoEngine: unsupported codec id \(id) (only HEVC supported)"
            case .noKeyframeIndex:       return "HLSVideoEngine: source has no keyframe index (cannot build segment boundaries)"
            case .unsupportedDVProfile(let p, let c): return "HLSVideoEngine: unsupported Dolby Vision profile \(p).\(c)"
            case .muxerInit(let e):      return "HLSVideoEngine: muxer init failed (\(e))"
            case .alreadyStarted:        return "HLSVideoEngine: session already started"
            case .notStarted:            return "HLSVideoEngine: session not started"
            }
        }
    }

    /// DV profile + base-layer compatibility classification per the
    /// table in DrHurt's KSPlayer notes (AetherEngine#1) and Apple's
    /// HLS Authoring Spec. The codec FourCC the muxer writes and the
    /// `VIDEO-RANGE` we put on the master playlist depend on which
    /// variant we hit.
    fileprivate enum DVVariant {
        case none           // not DV (would be a routing bug — phase 1 only sends DV here)
        case profile5       // P5 (IPT-PQ-c2, no HDR10 base)         → dvh1 + PQ
        case profile81      // P8 with HDR10-compat base              → dvh1 + PQ
        case profile84      // P8 with HLG-compat base                → hvc1 + HLG
        case profile7       // P7 dual-layer (Apple TV cannot decode) → reject
        case profile82      // P8 with SDR-compat base (rare)         → reject
        case unknown        // anything else (P9, P10/AV1, malformed) → reject
    }

    /// Audio codec compatibility with AVPlayer's native fMP4 decode
    /// pipeline. AAC / AC3 / EAC3 (incl. Atmos JOC) / FLAC / ALAC /
    /// MP3 stream-copy directly into fMP4 segments and AVPlayer
    /// renders them. TrueHD / DTS / DTS-HD MA need transcode to FLAC
    /// (DrHurt's `-c:a flac` trick) which is a phase-7 expansion;
    /// for now we reject unsupported codecs and the host falls back
    /// to AetherEngine.
    fileprivate enum AudioCodecCompat {
        case aac, ac3, eac3, flac, alac, mp3, opus
        case unsupported

        static func from(_ codecID: AVCodecID) -> AudioCodecCompat {
            switch codecID {
            case AV_CODEC_ID_AAC:  return .aac
            case AV_CODEC_ID_AC3:  return .ac3
            case AV_CODEC_ID_EAC3: return .eac3
            case AV_CODEC_ID_FLAC: return .flac
            case AV_CODEC_ID_ALAC: return .alac
            case AV_CODEC_ID_MP3:  return .mp3
            case AV_CODEC_ID_OPUS: return .opus
            default:               return .unsupported
            }
        }

        var hlsCodecsString: String {
            switch self {
            case .aac:  return "mp4a.40.2"
            case .ac3:  return "ac-3"
            case .eac3: return "ec-3"
            case .flac: return "fLaC"
            case .alac: return "alac"
            case .mp3:  return "mp4a.40.34"
            case .opus: return "opus"
            case .unsupported: return ""
            }
        }
    }

    // MARK: - State

    private let sourceURL: URL
    private var demuxer: Demuxer?
    private var server: HLSLocalServer?
    private var provider: VideoSegmentProvider?

    /// Approximate target segment duration in seconds. Actual
    /// fragments may be slightly shorter or longer because we snap
    /// boundaries to source keyframes. 6 s matches Apple's HLS
    /// authoring recommendation.
    private static let targetSegmentDuration: Double = 6.0

    init(url: URL) {
        self.sourceURL = url
    }

    // MARK: - Public API

    /// Open the source, build the segment plan, start the server,
    /// return the URL the host hands to AVPlayer.
    func start() throws -> URL {
        guard demuxer == nil else { throw HLSVideoEngineError.alreadyStarted }

        // 1. Open the source. Reuses AetherEngine's existing AVIO +
        //    HTTP byte-range fetch + Matroska demuxer; nothing new
        //    here on the input side.
        let dem = Demuxer()
        do {
            try dem.open(url: sourceURL)
        } catch {
            throw HLSVideoEngineError.openFailed(reason: "\(error)")
        }
        demuxer = dem

        let videoIndex = dem.videoStreamIndex
        guard videoIndex >= 0, let videoStream = dem.stream(at: videoIndex) else {
            throw HLSVideoEngineError.noVideoStream
        }
        let codecpar = videoStream.pointee.codecpar!
        guard codecpar.pointee.codec_id == AV_CODEC_ID_HEVC else {
            throw HLSVideoEngineError.unsupportedCodec(rawCodecID: codecpar.pointee.codec_id.rawValue)
        }

        // 2. Read keyframe index from the demuxer. For MKV this is
        //    populated from the cues at avformat_open_input time
        //    (already done by Demuxer); no extra network I/O. For
        //    MP4 it's populated from `stss`. Files with neither
        //    fall back to a synthetic index built from a one-shot
        //    linear scan, which would download the whole file —
        //    so we refuse to start in that case (returning to the
        //    caller, who falls back to AetherEngine).
        let keyframes = readKeyframeIndex(stream: videoStream)
        guard !keyframes.isEmpty else {
            throw HLSVideoEngineError.noKeyframeIndex
        }

        // 3. Compute segment boundaries by walking keyframes in
        //    ~targetSegmentDuration strides. Each segment starts
        //    on a real keyframe, so the actual fragment duration
        //    is what AVPlayer will see, not just an EXTINF guess.
        let videoTimeBase = videoStream.pointee.time_base
        let durationSeconds = dem.duration
        let plan = buildSegmentPlan(
            keyframes: keyframes,
            videoTimeBase: videoTimeBase,
            sourceDurationSeconds: durationSeconds
        )

        // 4. Classify the DV variant and pick the codec-tag /
        //    video-range / CODECS-string trio per DrHurt's empirical
        //    AVPlayer profile table (AetherEngine#1):
        //
        //       Profile         | codec_tag | VIDEO-RANGE
        //       ----------------+-----------+------------
        //       P5 (compat 0)   | dvh1      | PQ
        //       P8.1 (compat 1) | dvh1      | PQ
        //       P8.4 (compat 4) | hvc1      | HLG
        //       P7 / P8.2 / etc | unsupported, reject and let host fall back
        //
        //    The earlier "all DV → dvh1 + PQ" approach was wrong for
        //    P8.4: AVPlayer expects an HDR10-compat base layer when
        //    it sees dvh1+PQ, but P8.4 carries HLG bytes underneath,
        //    so the HDMI handshake gets confused.
        let dvRecord = doviConfigRecord(from: codecpar)
        let dvVariant = classifyDVVariant(dvRecord)
        let codecTagOverride: String?
        let videoRange: HLSVideoRange
        let codecsString: String
        switch dvVariant {
        case .profile5:
            codecTagOverride = "dvh1"
            videoRange = .pq
            codecsString = "dvh1"
        case .profile81:
            codecTagOverride = "dvh1"
            videoRange = .pq
            codecsString = "dvh1"
        case .profile84:
            codecTagOverride = nil  // default 'hvc1', AVPlayer reads dvvC + VIDEO-RANGE=HLG to engage DV
            videoRange = .hlg
            codecsString = "hvc1"
        case .profile7:
            throw HLSVideoEngineError.unsupportedDVProfile(profile: 7, compatID: -1)
        case .profile82:
            throw HLSVideoEngineError.unsupportedDVProfile(profile: 8, compatID: 2)
        case .unknown:
            let p = Int(dvRecord?.dv_profile ?? 0)
            let c = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 0)
            throw HLSVideoEngineError.unsupportedDVProfile(profile: p, compatID: c)
        case .none:
            // Phase-1 routing should keep non-DV out of this engine,
            // but be defensive: play as plain HEVC HDR10/HLG/SDR.
            codecTagOverride = nil
            videoRange = isHDRTransfer(codecpar) ? .pq : .sdr
            codecsString = "hvc1"
        }

        let resolution = (Int(codecpar.pointee.width), Int(codecpar.pointee.height))

        // 5. Pick the best audio stream and check codec compat with
        //    AVPlayer. AAC / AC3 / EAC3 (incl. Atmos JOC) / FLAC /
        //    ALAC / MP3 / Opus stream-copy directly. TrueHD / DTS /
        //    DTS-HD MA are unsupported in AVPlayer's fMP4 decode and
        //    would need transcode-to-FLAC (DrHurt's `-c:a flac`
        //    trick from AetherEngine#1) — a phase-7 expansion. For
        //    now we surface them as a routing-incompat signal so the
        //    host falls back to AetherEngine for the affected file.
        let audioStreamIndex = dem.audioStreamIndex
        var audioConfig: FMP4VideoMuxer.StreamConfig? = nil
        var audioHLSCodec: String? = nil
        var resolvedAudioStreamIndex: Int32 = -1
        if audioStreamIndex >= 0, let audioStream = dem.stream(at: audioStreamIndex) {
            let audioCodecID = audioStream.pointee.codecpar.pointee.codec_id
            let compat = AudioCodecCompat.from(audioCodecID)
            if compat != .unsupported {
                audioConfig = FMP4VideoMuxer.StreamConfig(
                    codecpar: audioStream.pointee.codecpar,
                    timeBase: audioStream.pointee.time_base,
                    codecTagOverride: nil
                )
                audioHLSCodec = compat.hlsCodecsString
                resolvedAudioStreamIndex = audioStreamIndex
                EngineLog.emit("[HLSVideoEngine] audio: codec=\(compat) → muxing as `\(compat.hlsCodecsString)`")
            } else {
                EngineLog.emit("[HLSVideoEngine] audio codec id=\(audioCodecID.rawValue) unsupported in fMP4 (probably TrueHD/DTS); video-only fragment")
            }
        }

        // Build the master-playlist CODECS string. AVPlayer reads
        // this at variant-info parse time and filters streams it
        // can't decode. Per RFC 6381: comma-separated, video first,
        // audio after when present.
        let manifestCodecs = audioHLSCodec.map { "\(codecsString),\($0)" } ?? codecsString

        // 6. Build the per-session muxer, generate the init segment.
        //    The muxer is reused across every fragment in this
        //    session; segments may be requested out of order (seeks)
        //    but per ISO BMFF the `mfhd.sequence_number` is only a
        //    "recommended monotonic" hint, not load-bearing for
        //    AVPlayer playback.
        let videoConfig = FMP4VideoMuxer.StreamConfig(
            codecpar: codecpar,
            timeBase: videoTimeBase,
            codecTagOverride: codecTagOverride
        )
        let muxer: FMP4VideoMuxer
        do {
            muxer = try FMP4VideoMuxer(video: videoConfig, audio: audioConfig)
        } catch {
            throw HLSVideoEngineError.muxerInit(underlying: error)
        }
        let initSegmentData: Data
        do {
            initSegmentData = try muxer.writeInitSegment()
        } catch {
            muxer.close()
            throw HLSVideoEngineError.muxerInit(underlying: error)
        }

        EngineLog.emit(
            "[HLSVideoEngine] prepared: codec=\(manifestCodecs) resolution=\(resolution.0)x\(resolution.1) "
            + "range=\(videoRange.rawValue) DV=\(dvVariant) segments=\(plan.count) "
            + "duration=\(String(format: "%.1f", durationSeconds))s init=\(initSegmentData.count)B"
        )

        // 7. Wire the provider, the server, and serve the URL.
        let prov = VideoSegmentProvider(
            demuxer: dem,
            videoStreamIndex: videoIndex,
            audioStreamIndex: resolvedAudioStreamIndex >= 0 ? resolvedAudioStreamIndex : nil,
            videoTimeBase: videoTimeBase,
            muxer: muxer,
            initSegmentData: initSegmentData,
            segments: plan,
            codecsString: manifestCodecs,
            resolution: resolution,
            videoRange: videoRange
        )
        provider = prov

        let srv = HLSLocalServer(provider: prov)
        try srv.start()
        server = srv

        guard let url = srv.playlistURL else {
            stop()
            throw HLSVideoEngineError.openFailed(reason: "server URL not ready")
        }
        EngineLog.emit("[HLSVideoEngine] serving on \(url.absoluteString)")
        return url
    }

    func stop() {
        server?.stop()
        server = nil
        provider?.close()
        provider = nil
        demuxer?.close()
        demuxer = nil
    }

    deinit {
        stop()
    }

    // MARK: - Keyframe index + segment planning

    /// Pull every keyframe entry from the AVStream's index. Returns
    /// timestamps in the stream's own time base.
    private func readKeyframeIndex(stream: UnsafeMutablePointer<AVStream>) -> [Int64] {
        let count = avformat_index_get_entries_count(stream)
        guard count > 0 else { return [] }
        var keyframes: [Int64] = []
        keyframes.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let entry = avformat_index_get_entry(stream, i) else { continue }
            // AVINDEX_KEYFRAME = 0x0001
            if (entry.pointee.flags & 0x0001) != 0 {
                keyframes.append(entry.pointee.timestamp)
            }
        }
        return keyframes
    }

    /// Walk keyframes in `targetSegmentDuration` strides to produce
    /// segment boundaries. Each segment starts on a real keyframe
    /// and ends just before the next selected keyframe; the last
    /// segment ends at source duration.
    private func buildSegmentPlan(
        keyframes: [Int64],
        videoTimeBase: AVRational,
        sourceDurationSeconds: Double
    ) -> [Segment] {
        guard !keyframes.isEmpty else { return [] }
        let tb = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        let stride = Self.targetSegmentDuration

        var selected: [Int64] = [keyframes[0]]
        var lastSelectedTime: Double = Double(keyframes[0]) * tb
        for kf in keyframes.dropFirst() {
            let kfTime = Double(kf) * tb
            if kfTime - lastSelectedTime >= stride {
                selected.append(kf)
                lastSelectedTime = kfTime
            }
        }

        // Synthesise a final boundary at source end so the last
        // segment has a meaningful end-PTS.
        let endPts = Int64(sourceDurationSeconds / tb)

        var plan: [Segment] = []
        for (i, startPts) in selected.enumerated() {
            let nextPts: Int64 = (i + 1 < selected.count) ? selected[i + 1] : endPts
            let durationSeconds = Double(nextPts - startPts) * tb
            let startSeconds = Double(startPts) * tb
            plan.append(Segment(
                startPts: startPts,
                endPts: nextPts,
                startSeconds: startSeconds,
                durationSeconds: max(0.001, durationSeconds)
            ))
        }
        return plan
    }

    // MARK: - DV / HDR detection

    /// Look up FFmpeg's `AV_PKT_DATA_DOVI_CONF` side data on the
    /// codec parameters. Mirrors `VideoDecoder.swift`, intentionally
    /// duplicated rather than refactored shared so the two paths
    /// stay independently maintainable.
    private func doviConfigRecord(
        from codecpar: UnsafePointer<AVCodecParameters>
    ) -> AVDOVIDecoderConfigurationRecord? {
        let count = Int(codecpar.pointee.nb_coded_side_data)
        guard count > 0, let sideData = codecpar.pointee.coded_side_data else {
            return nil
        }
        for i in 0..<count {
            let item = sideData.advanced(by: i).pointee
            guard item.type == AV_PKT_DATA_DOVI_CONF else { continue }
            guard let raw = item.data, item.size >= 8 else { continue }
            return raw.withMemoryRebound(
                to: AVDOVIDecoderConfigurationRecord.self,
                capacity: 1
            ) { $0.pointee }
        }
        return nil
    }

    private func isHDRTransfer(_ codecpar: UnsafePointer<AVCodecParameters>) -> Bool {
        let trc = codecpar.pointee.color_trc
        return trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67
    }

    /// Classify the source's Dolby Vision variant from the parsed
    /// configuration record. P8.6 is normalised to P8.1 per
    /// DrHurt's note: "P8.6 is not a valid profile (but should still
    /// play if treated as 8.1)".
    private func classifyDVVariant(_ record: AVDOVIDecoderConfigurationRecord?) -> DVVariant {
        guard let r = record else { return .none }
        let profile = Int(r.dv_profile)
        let compat = Int(r.dv_bl_signal_compatibility_id)

        if profile == 5 { return .profile5 }
        if profile == 7 { return .profile7 }
        if profile == 8 || profile == 9 || profile == 10 {
            switch compat {
            case 1: return .profile81
            case 2: return .profile82
            case 4: return .profile84
            default: return .profile81  // P8.6 etc → treat as P8.1
            }
        }
        return .unknown
    }

    // No `formatLevel` / `buildHEVCCodecsString` helpers: the
    // master-playlist CODECS attribute uses the bare 4cc (`dvh1` or
    // `hvc1`) per DrHurt's empirical KSPlayer testing
    // (AetherEngine#2). The dotted RFC 6381 form (`dvh1.05.06`) is
    // spec-compliant but Apple TV's AVPlayer treats them as
    // equivalent at variant-info parse time, and the bare form
    // sidesteps any pickiness about exact level encoding.

    // MARK: - Segment plan model

    fileprivate struct Segment {
        let startPts: Int64
        let endPts: Int64
        let startSeconds: Double
        let durationSeconds: Double
    }
}

// MARK: - Lazy segment provider

/// `HLSSegmentProvider` impl that generates each fMP4 fragment on
/// demand the first time AVPlayer GETs `seg{N}.mp4`. Holds the
/// session's demuxer + muxer behind a serial lock; concurrent
/// fetches block each other instead of racing the demuxer.
private final class VideoSegmentProvider: HLSSegmentProvider {

    private let demuxer: Demuxer
    private let videoStreamIndex: Int32
    private let audioStreamIndex: Int32?
    private let videoTimeBase: AVRational
    private let muxer: FMP4VideoMuxer

    private let initSegmentData: Data
    private let segments: [HLSVideoEngine.Segment]

    private let codecsString: String
    private let resolution: (Int, Int)
    private let videoRange: HLSVideoRange

    private let lock = NSLock()
    private var isClosed = false

    init(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        audioStreamIndex: Int32?,
        videoTimeBase: AVRational,
        muxer: FMP4VideoMuxer,
        initSegmentData: Data,
        segments: [HLSVideoEngine.Segment],
        codecsString: String,
        resolution: (Int, Int),
        videoRange: HLSVideoRange
    ) {
        self.demuxer = demuxer
        self.videoStreamIndex = videoStreamIndex
        self.audioStreamIndex = audioStreamIndex
        self.videoTimeBase = videoTimeBase
        self.muxer = muxer
        self.initSegmentData = initSegmentData
        self.segments = segments
        self.codecsString = codecsString
        self.resolution = resolution
        self.videoRange = videoRange
    }

    func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        muxer.close()
        lock.unlock()
    }

    // MARK: - HLSSegmentProvider

    func initSegment() -> Data? {
        return initSegmentData
    }

    func mediaSegment(at index: Int) -> Data? {
        guard index >= 0, index < segments.count else { return nil }
        let seg = segments[index]

        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return nil }

        // Seek to the start of this segment. Demuxer.seek expects
        // seconds (it converts to AV_TIME_BASE internally and uses
        // avformat_seek_file for MKV-safe seek behaviour).
        demuxer.seek(to: seg.startSeconds)

        var videoCount = 0
        var audioCount = 0
        var didEnqueueAnyVideo = false
        do {
            while let packet = try demuxer.readPacket() {
                var pktPtr: UnsafeMutablePointer<AVPacket>? = packet
                defer { av_packet_free(&pktPtr) }

                let streamIdx = packet.pointee.stream_index

                if streamIdx == videoStreamIndex {
                    // Stop reading once we've passed this segment's
                    // end boundary, but only on a keyframe (otherwise
                    // we'd cut in the middle of a GOP and break the
                    // next segment's IDR alignment).
                    if didEnqueueAnyVideo,
                       packet.pointee.pts != Int64.min,
                       packet.pointee.pts >= seg.endPts,
                       (packet.pointee.flags & AV_PKT_FLAG_KEY_VALUE) != 0 {
                        break
                    }
                    try muxer.writePacket(packet, toStreamIndex: muxer.videoOutputIndex)
                    didEnqueueAnyVideo = true
                    videoCount += 1
                } else if let aIdx = audioStreamIndex,
                          let aOutIdx = muxer.audioOutputIndex,
                          streamIdx == aIdx {
                    try muxer.writePacket(packet, toStreamIndex: aOutIdx)
                    audioCount += 1
                }
                // Other streams (additional audio tracks, subtitles,
                // attachments) are silently dropped. Audio-track
                // switching mid-session would require re-priming the
                // muxer and is a phase-7 concern.

                // Safety bound: never read more than ~30 s worth of
                // packets for one segment, regardless of where the
                // next keyframe is. Pathological sources without
                // mid-stream keyframes can otherwise gobble the
                // whole file.
                if videoCount + audioCount > 3600 { break }
            }
            let bytes = try muxer.flushFragment()
            EngineLog.emit("[HLSVideoEngine] seg\(index): v=\(videoCount) a=\(audioCount) → \(bytes.count) B (start=\(String(format: "%.2f", seg.startSeconds))s dur=\(String(format: "%.2f", seg.durationSeconds))s)")
            return bytes
        } catch {
            EngineLog.emit("[HLSVideoEngine] seg\(index) generation failed: \(error)")
            return nil
        }
    }

    var segmentCount: Int { segments.count }

    func segmentDuration(at index: Int) -> Double {
        guard index >= 0, index < segments.count else { return 0 }
        return segments[index].durationSeconds
    }

    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { codecsString }
    var masterResolution: (width: Int, height: Int)? {
        return (resolution.0, resolution.1)
    }
    var masterVideoRange: HLSVideoRange? { videoRange }
    var masterBandwidth: Int? { nil }
}

/// `AV_PKT_FLAG_KEY` is `1 << 0` per FFmpeg's `packet.h` (and a C
/// macro Swift can't import directly). Aliased here so callers don't
/// have to re-derive the bit.
private let AV_PKT_FLAG_KEY_VALUE: Int32 = 0x0001
