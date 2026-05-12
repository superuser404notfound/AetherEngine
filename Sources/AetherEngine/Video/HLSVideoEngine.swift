import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Session that turns a remote video source (typically a Jellyfin
/// MKV) into a local HLS-fMP4 stream AVPlayer can play.
///
/// Architecture: a single libavformat `hls` muxer instance runs for
/// the duration of the session, fed by the engine's `Demuxer`. Custom
/// `s->io_open` / `s->io_close2` callbacks (see `HLSSegmentProducer`)
/// redirect every fragment write into a `SegmentCache`. The local HTTP
/// server hands AVPlayer fragments from that cache, blocking on a
/// condition variable when AVPlayer requests an index that hasn't been
/// muxed yet. This replaces the previous self-built per-fragment
/// muxer + lazy generator + manual PTS-shift compensation. The
/// libavformat HLS-fmp4 output is byte-identical to `ffmpeg -f hls
/// -hls_segment_type fmp4`, which is the reference Apple's HLS spec
/// is defined against; we no longer carry the burden of reproducing
/// it ourselves.
///
/// Phase A: video-only, strict-forward producer (no backward-scrub
/// teardown, no audio bridge). Audio + scrub-restart follow.
public final class HLSVideoEngine: @unchecked Sendable {

    // MARK: - Errors

    public enum HLSVideoEngineError: Error, CustomStringConvertible, LocalizedError {
        case openFailed(reason: String)
        case noVideoStream
        case unsupportedCodec(rawCodecID: UInt32)
        case zeroDuration
        case unsupportedDVProfile(profile: Int, compatID: Int)
        case muxerInit(underlying: Error)
        case alreadyStarted
        case notStarted

        public var description: String {
            switch self {
            case .openFailed(let r):     return "HLSVideoEngine: open failed (\(r))"
            case .noVideoStream:         return "HLSVideoEngine: source has no video stream"
            case .unsupportedCodec(let id): return "HLSVideoEngine: unsupported codec id \(id) (only HEVC and H.264 supported)"
            case .zeroDuration:          return "HLSVideoEngine: source has zero duration (cannot build segment plan)"
            case .unsupportedDVProfile(let p, let c): return "HLSVideoEngine: unsupported Dolby Vision profile \(p).\(c)"
            case .muxerInit(let e):      return "HLSVideoEngine: muxer init failed (\(e))"
            case .alreadyStarted:        return "HLSVideoEngine: session already started"
            case .notStarted:            return "HLSVideoEngine: session not started"
            }
        }

        public var errorDescription: String? { description }
    }

    /// DV profile + base-layer compatibility classification per the
    /// table in DrHurt's KSPlayer notes (AetherEngine#1) and Apple's
    /// HLS Authoring Spec.
    fileprivate enum DVVariant {
        case none           // not DV
        case profile5       // P5 (IPT-PQ-c2, no HDR10 base)         → dvh1 + PQ
        case profile81      // P8 with HDR10-compat base              → dvh1 + PQ
        case profile84      // P8 with HLG-compat base                → hvc1 + HLG
        case profile7       // P7 dual-layer (Apple TV cannot decode) → reject
        case profile82      // P8 with SDR-compat base (rare)         → reject
        case unknown        // anything else                          → reject
    }

    // MARK: - State

    private let sourceURL: URL
    private let dvModeAvailable: Bool

    private var demuxer: Demuxer?
    private var cache: SegmentCache?
    private var producer: HLSSegmentProducer?
    private var server: HLSLocalServer?
    private var provider: VideoSegmentProvider?

    /// Approximate target segment duration in seconds. The hls muxer
    /// snaps cut points to keyframes at-or-after this threshold, so
    /// actual durations are 6s + GOP length variance. 6s matches
    /// Apple's HLS Authoring Spec recommendation.
    private static let targetSegmentDuration: Double = 6.0

    public init(url: URL, dvModeAvailable: Bool = true) {
        self.sourceURL = url
        self.dvModeAvailable = dvModeAvailable
    }

    // MARK: - Public API

    public func start() throws -> URL {
        guard demuxer == nil else { throw HLSVideoEngineError.alreadyStarted }

        // 1. Open the source.
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
        let isHEVC = codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
        let isH264 = codecpar.pointee.codec_id == AV_CODEC_ID_H264
        guard isHEVC || isH264 else {
            throw HLSVideoEngineError.unsupportedCodec(rawCodecID: codecpar.pointee.codec_id.rawValue)
        }

        let videoTimeBase = videoStream.pointee.time_base
        let durationSeconds = dem.duration
        guard durationSeconds > 0 else {
            throw HLSVideoEngineError.zeroDuration
        }

        // 2. Prewarm the MKV cue table so libavformat's keyframe index
        //    is populated. avformat_seek_file's first invocation on an
        //    MKV source lazily parses the Cues element from the file
        //    tail, which fans out into one or two HTTP byte-range
        //    reads. Mid-duration target so the prewarm doesn't strand
        //    the demuxer cursor far from where playback starts.
        let prewarmStart = DispatchTime.now()
        dem.seek(to: durationSeconds * 0.5)
        let prewarmMs = Double(DispatchTime.now().uptimeNanoseconds - prewarmStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit("[HLSVideoEngine] cue prewarm: seek to \(String(format: "%.1f", durationSeconds * 0.5))s took \(String(format: "%.1f", prewarmMs))ms")

        // 3. Build the segment plan from real keyframes in the index,
        //    using the SAME cut algorithm libavformat's hls muxer uses
        //    internally (first keyframe at-or-after `(segIdx+1) * hls_time`
        //    absolute from start_pts). When the index doesn't have
        //    enough entries we fall back to a uniform stride; the
        //    muxer may then end up making a slightly different number
        //    of segments than we planned, but Phase A doesn't test
        //    that path and Phase B's restart machinery handles any
        //    drift at scrub time.
        let keyframes = dem.indexedKeyframes(streamIndex: videoIndex)
        let plan: [Segment]
        if keyframes.count >= 2 {
            plan = buildKeyframeSegmentPlan(
                keyframes: keyframes,
                videoTimeBase: videoTimeBase,
                sourceDurationSeconds: durationSeconds
            )
            EngineLog.emit(
                "[HLSVideoEngine] segment plan: keyframe-aligned, \(keyframes.count) IRAPs → \(plan.count) segments",
                category: .session
            )
        } else {
            plan = buildUniformSegmentPlan(
                videoTimeBase: videoTimeBase,
                sourceDurationSeconds: durationSeconds
            )
            EngineLog.emit(
                "[HLSVideoEngine] segment plan: uniform stride fallback (\(keyframes.count) IRAPs in index, need >=2)",
                category: .session
            )
        }

        // 4. Classify the DV variant and pick the master-playlist
        //    CODECS string + codec_tag override. Same routing rules as
        //    before: P5 / P8.1 use bare `dvh1.<profile>.<dvLevel>`
        //    direct form; P8.4 keeps the cross-player-compat `hvc1.2.4
        //    .LXX` + SUPPLEMENTAL `dvh1.08.LL/db4h` because its base
        //    layer is HLG-HEVC. With dvModeAvailable=false the engine
        //    downgrades any DV source to plain HEVC (hvc1) so AVPlayer
        //    doesn't reject the asset on a non-DV-capable display.
        let codecTagOverride: String?
        let videoRange: HLSVideoRange
        let primaryCodecs: String
        let supplementalCodecs: String?
        let dvVariant: DVVariant

        if isH264 {
            codecTagOverride = "avc1"
            videoRange = isHDRTransfer(codecpar) ? .pq : .sdr
            let profileIDC = Int(codecpar.pointee.profile)
            let levelIDC = Int(codecpar.pointee.level)
            let safeProfile = profileIDC > 0 ? profileIDC : 100  // High
            let safeLevel = levelIDC > 0 ? levelIDC : 40         // 4.0
            primaryCodecs = String(format: "avc1.%02X%02X%02X", safeProfile, 0, safeLevel)
            supplementalCodecs = nil
            dvVariant = .none
        } else if !dvModeAvailable {
            codecTagOverride = "hvc1"
            let hevcLevelRaw = Int(codecpar.pointee.level)
            let hevcLevel = hevcLevelRaw > 0 ? hevcLevelRaw : 150
            let trc = codecpar.pointee.color_trc
            if trc == AVCOL_TRC_ARIB_STD_B67 {
                videoRange = .hlg
            } else if trc == AVCOL_TRC_SMPTE2084 {
                videoRange = .pq
            } else {
                videoRange = .sdr
            }
            primaryCodecs = "hvc1.2.4.L\(hevcLevel)"
            supplementalCodecs = nil
            dvVariant = .none
        } else {
            let dvRecord = doviConfigRecord(from: codecpar)
            dvVariant = classifyDVVariant(dvRecord)

            let dvLevelRaw = Int(dvRecord?.dv_level ?? 0)
            let dvLevel = dvLevelRaw > 0 ? dvLevelRaw : 6
            let hevcLevelRaw = Int(codecpar.pointee.level)
            let hevcLevel = hevcLevelRaw > 0 ? hevcLevelRaw : 150
            let dvLevelStr = String(format: "%02d", dvLevel)

            switch dvVariant {
            case .profile5:
                codecTagOverride = "dvh1"
                videoRange = .pq
                primaryCodecs = "dvh1.05.\(dvLevelStr)"
                supplementalCodecs = nil
            case .profile81:
                codecTagOverride = "dvh1"
                videoRange = .pq
                primaryCodecs = "dvh1.08.\(dvLevelStr)"
                supplementalCodecs = nil
            case .profile84:
                codecTagOverride = "hvc1"
                videoRange = .hlg
                primaryCodecs = "hvc1.2.4.L\(hevcLevel).b0"
                supplementalCodecs = "dvh1.08.\(dvLevelStr)/db4h"
            case .profile7:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: 7, compatID: -1)
            case .profile82:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: 8, compatID: 2)
            case .unknown:
                let p = Int(dvRecord?.dv_profile ?? 0)
                let c = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 0)
                throw HLSVideoEngineError.unsupportedDVProfile(profile: p, compatID: c)
            case .none:
                codecTagOverride = "hvc1"
                videoRange = isHDRTransfer(codecpar) ? .pq : .sdr
                primaryCodecs = "hvc1.2.4.L\(hevcLevel)"
                supplementalCodecs = nil
            }
        }

        let resolution = (Int(codecpar.pointee.width), Int(codecpar.pointee.height))

        let avgFR = videoStream.pointee.avg_frame_rate
        let frameRate: Double? = (avgFR.den > 0 && avgFR.num > 0)
            ? Double(avgFR.num) / Double(avgFR.den)
            : nil
        let hdcpLevel: String? = (dvVariant != .none) ? "TYPE-1" : nil

        // 5. Position the demuxer at the file's first packet so the
        //    producer's pump starts from byte zero. The cue prewarm
        //    above moved the cursor mid-file; libavformat's index is
        //    populated now, this seek-to-0 is cheap.
        dem.seek(to: 0)

        // 6. Build the segment cache + producer. The producer's
        //    constructor calls avformat_write_header which opens the
        //    init.mp4 sink (no bytes yet) and primes the muxer for
        //    av_write_frame. Pump runs on a worker queue.
        let segmentCache = SegmentCache()
        self.cache = segmentCache

        let videoConfig = HLSSegmentProducer.StreamConfig(
            codecpar: codecpar,
            timeBase: videoTimeBase,
            codecTagOverride: codecTagOverride
        )
        let prod: HLSSegmentProducer
        do {
            prod = try HLSSegmentProducer(
                demuxer: dem,
                videoStreamIndex: videoIndex,
                video: videoConfig,
                cache: segmentCache,
                baseIndex: 0,
                targetSegmentDurationSeconds: Self.targetSegmentDuration
            )
        } catch {
            stop()
            throw HLSVideoEngineError.muxerInit(underlying: error)
        }
        self.producer = prod

        // 7. Wire the provider, the server, and serve the URL.
        let manifestCodecs = primaryCodecs
        let prov = VideoSegmentProvider(
            cache: segmentCache,
            segments: plan,
            codecsString: manifestCodecs,
            supplementalCodecs: supplementalCodecs,
            resolution: resolution,
            videoRange: videoRange,
            frameRate: frameRate,
            hdcpLevel: hdcpLevel
        )
        self.provider = prov

        EngineLog.emit(
            "[HLSVideoEngine] prepared: codec=\(manifestCodecs)"
            + (supplementalCodecs.map { " supplemental=\($0)" } ?? "")
            + " resolution=\(resolution.0)x\(resolution.1) "
            + "fps=\(frameRate.map { String(format: "%.3f", $0) } ?? "nil") "
            + "range=\(videoRange.rawValue) DV=\(dvVariant) segments=\(plan.count) "
            + "duration=\(String(format: "%.1f", durationSeconds))s"
        )

        let srv = HLSLocalServer(provider: prov)
        try srv.start()
        self.server = srv

        // 8. Kick the pump. Producer is now writing init + segments
        //    into the cache as fast as the demuxer can feed packets;
        //    AVPlayer's HTTP fetches block on cache.fetch until the
        //    requested index lands.
        prod.start()

        let resolvedURL: URL?
        if dvModeAvailable {
            resolvedURL = srv.playlistURL
        } else {
            resolvedURL = srv.mediaPlaylistURL
        }
        guard let url = resolvedURL else {
            stop()
            throw HLSVideoEngineError.openFailed(reason: "server URL not ready")
        }
        EngineLog.emit("[HLSVideoEngine] serving on \(url.absoluteString) (dvModeAvailable=\(dvModeAvailable))")
        return url
    }

    public func stop() {
        producer?.stop()
        server?.stop()
        cache?.close()
        provider = nil
        server = nil
        producer = nil
        cache = nil
        demuxer?.close()
        demuxer = nil
    }

    deinit {
        stop()
    }

    // MARK: - Segment planning

    /// Build a uniform-duration segment plan from the source's
    /// reported duration. Used only as a fallback when libavformat's
    /// keyframe index is too sparse for the keyframe-aligned plan.
    /// The hls muxer will still snap actual cut points to real
    /// keyframes, so EXTINF / actual-duration drift accumulates with
    /// each segment in this fallback path. Phase B's restart machinery
    /// renegotiates timeline alignment after scrubs, so the drift
    /// stays bounded within one playback span.
    private func buildUniformSegmentPlan(
        videoTimeBase: AVRational,
        sourceDurationSeconds: Double
    ) -> [Segment] {
        guard sourceDurationSeconds > 0 else { return [] }
        let stride = Self.targetSegmentDuration
        let count = max(1, Int(ceil(sourceDurationSeconds / stride)))
        let tb = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        guard tb > 0 else { return [] }

        var plan: [Segment] = []
        plan.reserveCapacity(count)
        for i in 0..<count {
            let startSeconds = Double(i) * stride
            let endSeconds = min(sourceDurationSeconds, Double(i + 1) * stride)
            let startPts = Int64(startSeconds / tb)
            let endPts = Int64(endSeconds / tb)
            plan.append(Segment(
                startPts: startPts,
                endPts: endPts,
                startSeconds: startSeconds,
                durationSeconds: max(0.001, endSeconds - startSeconds)
            ))
        }
        return plan
    }

    /// Build a segment plan from real keyframes using libavformat's
    /// hls muxer cut algorithm: segment N ends at the first keyframe
    /// whose absolute distance from `start_pts` reaches `(N+1) *
    /// targetSegmentDuration`. `start_pts` is taken as the first
    /// keyframe in the index (sorted ascending), which matches the
    /// muxer's behaviour of latching `vs->start_pts` to the first
    /// packet's pts.
    ///
    /// This algorithm replaces the previous one which walked the
    /// keyframe list with a relative threshold per segment. The
    /// relative walk diverged from libavformat's cut algorithm on
    /// sources with irregular GOPs (e.g. keyframes at 0, 5.8, 11.5,
    /// 17.4, 23.3 produce 3 segments under absolute thresholds but
    /// only 2 under the relative walk), which would translate into
    /// playlist drift the moment the muxer actually cut differently
    /// from what we'd advertised.
    private func buildKeyframeSegmentPlan(
        keyframes: [Int64],
        videoTimeBase: AVRational,
        sourceDurationSeconds: Double
    ) -> [Segment] {
        guard keyframes.count >= 2 else { return [] }
        let tb = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        guard tb > 0 else { return [] }
        let target = Self.targetSegmentDuration

        let sorted = keyframes.sorted()
        let startPts0 = sorted[0]

        var plan: [Segment] = []
        plan.reserveCapacity(sorted.count)
        var i = 0
        var segIdx = 0
        while i < sorted.count {
            let segStartPts = sorted[i]
            let segStartSeconds = Double(segStartPts - startPts0) * tb
            let thresholdSeconds = Double(segIdx + 1) * target

            var j = i + 1
            while j < sorted.count {
                let candidateSeconds = Double(sorted[j] - startPts0) * tb
                if candidateSeconds >= thresholdSeconds { break }
                j += 1
            }

            let segEndPts: Int64
            let segEndSeconds: Double
            if j < sorted.count {
                segEndPts = sorted[j]
                segEndSeconds = Double(segEndPts - startPts0) * tb
            } else {
                segEndSeconds = sourceDurationSeconds
                segEndPts = Int64(sourceDurationSeconds / tb)
            }

            plan.append(Segment(
                startPts: segStartPts,
                endPts: segEndPts,
                startSeconds: segStartSeconds,
                durationSeconds: max(0.001, segEndSeconds - segStartSeconds)
            ))

            i = j
            segIdx += 1
        }

        return plan
    }

    // MARK: - DV / HDR detection

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

    // MARK: - Segment plan model

    fileprivate struct Segment {
        let startPts: Int64
        let endPts: Int64
        let startSeconds: Double
        let durationSeconds: Double
    }
}

// MARK: - Cache-backed provider

/// Thin `HLSSegmentProvider` over a `SegmentCache`. The cache is
/// populated by the session's `HLSSegmentProducer`. AVPlayer GETs are
/// served from cache hits when the producer is ahead of the playhead;
/// misses block on the cache's per-index condvar with a generous
/// timeout (the producer is on a worker thread, so blocking the HTTP
/// server's connection thread is the natural backpressure model).
///
/// Phase A: no scrub-restart logic; cache misses past timeout return
/// nil and let AVPlayer's own retry logic handle it. Phase B adds the
/// "muxer is ahead, can't go back" restart trigger.
private final class VideoSegmentProvider: HLSSegmentProvider {

    private let cache: SegmentCache
    private let segments: [HLSVideoEngine.Segment]

    private let codecsString: String
    private let supplementalCodecsString: String?
    private let resolution: (Int, Int)
    private let videoRange: HLSVideoRange
    private let frameRate: Double?
    private let hdcpLevel: String?

    init(
        cache: SegmentCache,
        segments: [HLSVideoEngine.Segment],
        codecsString: String,
        supplementalCodecs: String?,
        resolution: (Int, Int),
        videoRange: HLSVideoRange,
        frameRate: Double?,
        hdcpLevel: String?
    ) {
        self.cache = cache
        self.segments = segments
        self.codecsString = codecsString
        self.supplementalCodecsString = supplementalCodecs
        self.resolution = resolution
        self.videoRange = videoRange
        self.frameRate = frameRate
        self.hdcpLevel = hdcpLevel
    }

    // MARK: - HLSSegmentProvider

    func initSegment() -> Data? {
        return cache.fetchInit(timeout: 30.0)
    }

    func mediaSegment(at index: Int) -> Data? {
        guard index >= 0, index < segments.count else { return nil }
        let totalStart = DispatchTime.now()
        let bytes = cache.fetch(index: index, timeout: 30.0)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - totalStart.uptimeNanoseconds) / 1_000_000
        if let bytes = bytes {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): served \(bytes.count) B (wait=\(String(format: "%.1f", elapsedMs))ms cache=\(cache.count))",
                category: .session
            )
        } else {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): cache miss after \(String(format: "%.0f", elapsedMs))ms (cache=\(cache.count))",
                category: .session
            )
        }
        return bytes
    }

    var segmentCount: Int { segments.count }

    func segmentDuration(at index: Int) -> Double {
        guard index >= 0, index < segments.count else { return 0 }
        return segments[index].durationSeconds
    }

    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { codecsString }
    var masterSupplementalCodecs: String? { supplementalCodecsString }
    var masterResolution: (width: Int, height: Int)? {
        return (resolution.0, resolution.1)
    }
    var masterVideoRange: HLSVideoRange? { videoRange }
    var masterBandwidth: Int? { 5_000_000 }
    var masterAverageBandwidth: Int? { 5_000_000 }
    var masterFrameRate: Double? { frameRate }
    var masterHDCPLevel: String? { hdcpLevel }
    var masterClosedCaptions: String? { "NONE" }
}
