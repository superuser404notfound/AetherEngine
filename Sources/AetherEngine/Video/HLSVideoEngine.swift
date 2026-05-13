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

    /// Source audio codec routed to either fMP4 stream-copy or the
    /// FLAC bridge. Stream-copy preserves Atmos / DTS-HD metadata
    /// (EAC3-JOC stays Atmos); the bridge decodes to S16 PCM and
    /// re-encodes losslessly as FLAC so AVPlayer plays codecs that
    /// aren't legal in fMP4. See `project_audio_rework` memory for
    /// the full trade-off matrix (TrueHD-MAT Atmos loses its object
    /// metadata on the FLAC re-encode; lossless 7.1 PCM survives).
    fileprivate enum AudioCodecCompat {
        // fMP4-legal: stream-copy, no decode.
        case aac, ac3, eac3, flac, alac, mp3, opus
        // Not legal in fMP4: bridge through `AudioBridge` (decode →
        // S16 PCM → FLAC encode).
        case truehd, dts
        case vorbis, pcm, mp2
        case unsupported

        static func from(_ codecID: AVCodecID) -> AudioCodecCompat {
            switch codecID {
            case AV_CODEC_ID_AAC:    return .aac
            case AV_CODEC_ID_AC3:    return .ac3
            case AV_CODEC_ID_EAC3:   return .eac3
            case AV_CODEC_ID_FLAC:   return .flac
            case AV_CODEC_ID_ALAC:   return .alac
            case AV_CODEC_ID_MP3:    return .mp3
            case AV_CODEC_ID_OPUS:   return .opus
            case AV_CODEC_ID_TRUEHD: return .truehd
            case AV_CODEC_ID_DTS:    return .dts
            case AV_CODEC_ID_VORBIS: return .vorbis
            case AV_CODEC_ID_MP2:    return .mp2
            case AV_CODEC_ID_PCM_S16LE,
                 AV_CODEC_ID_PCM_S24LE,
                 AV_CODEC_ID_PCM_F32LE,
                 AV_CODEC_ID_PCM_S16BE,
                 AV_CODEC_ID_PCM_S32LE,
                 AV_CODEC_ID_PCM_U8:
                return .pcm
            default: return .unsupported
            }
        }

        /// CODECS attribute string for the master playlist when this
        /// codec is stream-copied. Empty for codecs that always bridge
        /// (they show up as `fLaC` after the encode, computed by the
        /// engine rather than the enum).
        var hlsCodecsString: String {
            switch self {
            case .aac:    return "mp4a.40.2"
            case .ac3:    return "ac-3"
            case .eac3:   return "ec-3"
            case .flac:   return "fLaC"
            case .alac:   return "alac"
            case .mp3:    return "mp4a.40.34"
            case .opus:   return "opus"
            case .truehd, .dts, .vorbis, .pcm, .mp2, .unsupported:
                return ""
            }
        }

        /// Codecs that aren't legal in fMP4 and always have to go
        /// through `AudioBridge` for FLAC transcoding.
        var requiresBridge: Bool {
            switch self {
            case .truehd, .dts, .vorbis, .pcm, .mp2: return true
            default: return false
            }
        }
    }

    // MARK: - State

    private let sourceURL: URL
    private let dvModeAvailable: Bool

    private var demuxer: Demuxer?
    private var cache: SegmentCache?
    private var producer: HLSSegmentProducer?
    private var server: HLSLocalServer?
    private var provider: VideoSegmentProvider?

    /// Captured at `start()` so the restart path can spin up a fresh
    /// producer at any segment index without re-running the full
    /// DV-classification / codec-pick logic.
    private var videoStreamIndex: Int32 = -1
    private var savedVideoConfig: HLSSegmentProducer.StreamConfig?
    private var savedAudioConfig: HLSSegmentProducer.AudioConfig?
    /// Session-long FLAC bridge for codecs that aren't legal in fMP4.
    /// Owned by the engine (not the producer) so that producer
    /// restarts on scrub don't lose the bridge's encoder state. The
    /// bridge's `startSegment()` is called before each restart so the
    /// FLAC encoder PTS rebases off the new demuxer cursor.
    private var audioBridge: AudioBridge?
    private var segmentPlan: [Segment] = []

    /// Serializes restart requests so multiple AVPlayer GETs racing
    /// the same scrub can't tear down and rebuild the producer in
    /// parallel.
    private let restartLock = NSLock()

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
        self.videoStreamIndex = videoIndex
        self.savedVideoConfig = videoConfig
        self.segmentPlan = plan

        // 6a. Pick the audio routing: stream-copy for codecs legal in
        //     fMP4, FLAC bridge for those that aren't, drop for the
        //     unsupported tail. The fallback cascade tries stream-copy
        //     first (the common case is `ec-3` for streaming UHD with
        //     Atmos JOC); if the muxer rejects the header (EAC3 from
        //     MKV without a parsed `dec3` extradata is the typical
        //     EINVAL), we retry with the FLAC bridge; if that also
        //     fails we ship video-only.
        let audioStreamIndex = dem.audioStreamIndex
        var streamCopyAudio: HLSSegmentProducer.AudioConfig?
        var bridgePreferred = false
        var audioHLSCodecs: String?

        if audioStreamIndex >= 0, let audioStream = dem.stream(at: audioStreamIndex) {
            let codecID = audioStream.pointee.codecpar.pointee.codec_id
            let compat = AudioCodecCompat.from(codecID)
            if compat.requiresBridge {
                bridgePreferred = true
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec=\(compat) (bridge required) — decoding + FLAC re-encode",
                    category: .session
                )
            } else if compat != .unsupported {
                streamCopyAudio = HLSSegmentProducer.AudioConfig(
                    codecpar: audioStream.pointee.codecpar,
                    timeBase: audioStream.pointee.time_base,
                    sourceStreamIndex: audioStreamIndex,
                    inputTimeBase: audioStream.pointee.time_base,
                    bridge: nil
                )
                audioHLSCodecs = compat.hlsCodecsString
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec=\(compat) → stream-copy as `\(compat.hlsCodecsString)`",
                    category: .session
                )
            } else {
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec id=\(codecID.rawValue) unsupported, video-only",
                    category: .session
                )
            }
        }

        // 6b. Attempt the cascade. The bridge instance, if needed, is
        //     constructed up-front so it survives across restarts.
        let prod: HLSSegmentProducer
        prod = try buildProducerWithAudioCascade(
            preferBridge: bridgePreferred,
            streamCopyAudio: streamCopyAudio,
            sourceAudioStreamIndex: audioStreamIndex,
            sourceAudioStream: audioStreamIndex >= 0 ? dem.stream(at: audioStreamIndex) : nil,
            audioHLSCodecs: &audioHLSCodecs
        )
        self.producer = prod

        // 7. Wire the provider, the server, and serve the URL.
        let manifestCodecs = audioHLSCodecs.map { "\(primaryCodecs),\($0)" } ?? primaryCodecs
        let prov = VideoSegmentProvider(
            cache: segmentCache,
            segments: plan,
            codecsString: manifestCodecs,
            supplementalCodecs: supplementalCodecs,
            resolution: resolution,
            videoRange: videoRange,
            frameRate: frameRate,
            hdcpLevel: hdcpLevel,
            restartHandler: { [weak self] idx in
                self?.restartProducer(at: idx)
            }
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
        restartLock.lock()
        producer?.stop()
        let p = producer
        producer = nil
        restartLock.unlock()
        // Wait outside the lock so deinit on the producer (which may
        // touch the engine via weakly-captured closures) doesn't
        // re-enter restartLock.
        _ = p?.waitForFinish(timeout: 3.0)

        server?.stop()
        cache?.close()
        audioBridge?.close()
        provider = nil
        server = nil
        cache = nil
        savedVideoConfig = nil
        savedAudioConfig = nil
        audioBridge = nil
        segmentPlan = []
        demuxer?.close()
        demuxer = nil
    }

    deinit {
        stop()
    }

    // MARK: - Producer construction + restart

    /// Allocate and configure a new `HLSSegmentProducer` rooted at
    /// the given absolute segment index. Used both for the initial
    /// session bring-up (baseIndex=0) and for the backward / forward
    /// scrub restart path.
    private func makeProducer(baseIndex: Int) throws -> HLSSegmentProducer {
        guard let dem = demuxer, let cache = cache, let cfg = savedVideoConfig else {
            throw HLSVideoEngineError.notStarted
        }
        return try HLSSegmentProducer(
            demuxer: dem,
            videoStreamIndex: videoStreamIndex,
            video: cfg,
            audio: savedAudioConfig,
            cache: cache,
            baseIndex: baseIndex,
            targetSegmentDurationSeconds: Self.targetSegmentDuration
        )
    }

    /// Try the stream-copy → FLAC-bridge → video-only cascade for the
    /// initial producer construction. Inspired by the equivalent
    /// cascade the old per-fragment FMP4VideoMuxer ran during init
    /// capture; the failure mode it covers is the EAC3-from-MKV case
    /// where the source codecpar lacks the `dec3` extradata the mp4
    /// muxer needs to write the audio track's sample-entry. The same
    /// bytes that fed AVPlayer through stream-copy under the old
    /// architecture now fail header write here too — the fix on both
    /// sides is the same FLAC bridge fallback.
    private func buildProducerWithAudioCascade(
        preferBridge: Bool,
        streamCopyAudio: HLSSegmentProducer.AudioConfig?,
        sourceAudioStreamIndex: Int32,
        sourceAudioStream: UnsafeMutablePointer<AVStream>?,
        audioHLSCodecs: inout String?
    ) throws -> HLSSegmentProducer {
        // If the source already needs the bridge (TrueHD / DTS / Vorbis
        // / PCM / MP2), skip the stream-copy attempt — we know the
        // muxer won't accept those codecs in fMP4 anyway.
        if !preferBridge, let cfg = streamCopyAudio {
            self.savedAudioConfig = cfg
            do {
                return try makeProducer(baseIndex: 0)
            } catch {
                EngineLog.emit(
                    "[HLSVideoEngine] audio stream-copy header write failed (\(error)), retrying with FLAC bridge",
                    category: .session
                )
                // Fall through to bridge attempt.
            }
        }

        // FLAC bridge attempt. Requires a source audio stream.
        if let audioStream = sourceAudioStream, sourceAudioStreamIndex >= 0 {
            do {
                let bridge = try AudioBridge(
                    srcCodecpar: audioStream.pointee.codecpar,
                    srcTimeBase: audioStream.pointee.time_base
                )
                if let cp = bridge.encoderCodecpar {
                    let cfg = HLSSegmentProducer.AudioConfig(
                        codecpar: cp,
                        timeBase: bridge.encoderTimeBase,
                        sourceStreamIndex: sourceAudioStreamIndex,
                        inputTimeBase: bridge.encoderTimeBase,
                        bridge: bridge
                    )
                    self.savedAudioConfig = cfg
                    self.audioBridge = bridge
                    do {
                        let prod = try makeProducer(baseIndex: 0)
                        audioHLSCodecs = "fLaC"
                        return prod
                    } catch {
                        EngineLog.emit(
                            "[HLSVideoEngine] FLAC bridge header write failed (\(error)), falling back to video-only",
                            category: .session
                        )
                        self.savedAudioConfig = nil
                        self.audioBridge = nil
                        bridge.close()
                    }
                }
            } catch {
                EngineLog.emit(
                    "[HLSVideoEngine] AudioBridge init failed (\(error)), falling back to video-only",
                    category: .session
                )
            }
        }

        // Video-only fallback.
        self.savedAudioConfig = nil
        self.audioBridge = nil
        audioHLSCodecs = nil
        return try makeProducer(baseIndex: 0)
    }

    /// Tear down the current producer, seek the demuxer to the start
    /// of segment `idx`, and spin up a fresh producer with
    /// `baseIndex = idx`. Triggered by `VideoSegmentProvider` when
    /// AVPlayer requests a segment that's outside the current LRU's
    /// reach in either direction.
    ///
    /// The same `init.mp4` bytes are reproduced across restarts
    /// because the muxer's stream configuration is byte-deterministic
    /// for a fixed `StreamConfig`. AVPlayer cached the init segment
    /// from the original session bring-up and never re-fetches it, so
    /// the cache.setInit overwrite during restart is a no-op from
    /// AVPlayer's perspective.
    private func restartProducer(at idx: Int) {
        restartLock.lock()
        defer { restartLock.unlock() }

        guard idx >= 0, idx < segmentPlan.count, demuxer != nil else { return }

        let restartStart = DispatchTime.now()

        if let old = producer {
            old.stop()
            let ok = old.waitForFinish(timeout: 5.0)
            if !ok {
                EngineLog.emit(
                    "[HLSVideoEngine] restart at idx=\(idx): old producer didn't exit within 5s, abandoning it",
                    category: .session
                )
            }
        }
        producer = nil

        let target = segmentPlan[idx].startSeconds
        demuxer?.seek(to: target)
        // Re-arm the FLAC bridge's PTS rebase off the new demuxer
        // cursor. Without this, the bridge's encoder timeline keeps
        // climbing from where the old producer left off, drifting
        // out of alignment with the freshly-seeked video PTS.
        audioBridge?.startSegment()

        do {
            let newProd = try makeProducer(baseIndex: idx)
            producer = newProd
            newProd.start()
        } catch {
            EngineLog.emit(
                "[HLSVideoEngine] restart at idx=\(idx) failed: \(error)",
                category: .session
            )
            return
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - restartStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit(
            "[HLSVideoEngine] producer restarted at idx=\(idx) (seek=\(String(format: "%.2f", target))s, restart took \(String(format: "%.0f", elapsedMs))ms)",
            category: .session
        )
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
/// Scrub policy:
///  - In-cache: fast path, no waiting.
///  - Forward seek within `forwardWaitWindow` of cache.max: wait for
///    the producer to catch up. AVPlayer's normal sequential playback
///    falls in this bucket.
///  - Forward seek beyond that, or any backward seek beyond cache.min:
///    fire `restartHandler` so the engine can teardown + reseek
///    + spin up a fresh producer rooted at the new segment index,
///    then re-block on cache.fetch.
private final class VideoSegmentProvider: HLSSegmentProvider {

    private let cache: SegmentCache
    private let segments: [HLSVideoEngine.Segment]

    private let codecsString: String
    private let supplementalCodecsString: String?
    private let resolution: (Int, Int)
    private let videoRange: HLSVideoRange
    private let frameRate: Double?
    private let hdcpLevel: String?

    /// Closure into the engine that tears down the current producer
    /// and brings up a fresh one rooted at the given absolute segment
    /// index. Synchronous: returns after the new producer's pump has
    /// started writing, which is typically within 50-200 ms on Apple
    /// TV against a local Jellyfin source.
    private let restartHandler: ((Int) -> Void)?

    /// Forward-distance threshold beyond which a fetch triggers a
    /// restart instead of waiting for the producer to catch up. At
    /// 6 s segments, 8 segments ≈ 48 s of source content; further
    /// than that and waiting is slower than tearing down and
    /// resuming at the target.
    private static let forwardWaitWindow = 8

    init(
        cache: SegmentCache,
        segments: [HLSVideoEngine.Segment],
        codecsString: String,
        supplementalCodecs: String?,
        resolution: (Int, Int),
        videoRange: HLSVideoRange,
        frameRate: Double?,
        hdcpLevel: String?,
        restartHandler: ((Int) -> Void)? = nil
    ) {
        self.cache = cache
        self.segments = segments
        self.codecsString = codecsString
        self.supplementalCodecsString = supplementalCodecs
        self.resolution = resolution
        self.videoRange = videoRange
        self.frameRate = frameRate
        self.hdcpLevel = hdcpLevel
        self.restartHandler = restartHandler
    }

    // MARK: - HLSSegmentProvider

    func initSegment() -> Data? {
        return cache.fetchInit(timeout: 30.0)
    }

    func mediaSegment(at index: Int) -> Data? {
        guard index >= 0, index < segments.count else { return nil }
        let totalStart = DispatchTime.now()

        // Declare AVPlayer's target FIRST so the cache window slides
        // to centre on `index` before any subsequent producer store
        // runs `pruneOutsideWindow`. Without this, a resume-style
        // jump to seg-55 races with the producer's first store: the
        // producer (after restart at 55) writes seg-55, the cache
        // prunes with the still-default target=-1 / window=[-16,19],
        // seg-55 is evicted before `fetch(55)` ever sees it, and
        // AVPlayer times out on a segment that did exist for ~10 µs.
        cache.declareTarget(index)

        // Fast path: serve from cache.
        if let hit = cache.peek(index: index) {
            return logServed(index: index, bytes: hit, totalStart: totalStart, restarted: false)
        }

        // Decide whether to restart the producer or wait. Three cases:
        //   - range is empty → the producer hasn't produced (or hasn't
        //     produced anything in our current window after declareTarget
        //     pruned). If the requested index is beyond the producer's
        //     plausible cold-start reach (a few seg-0s), restart at
        //     `index`. Otherwise wait — the producer is about to write
        //     seg-0 / seg-1 / seg-2 and we don't want to thrash.
        //   - index below the cache's low edge → backward seek past
        //     the kept window, restart.
        //   - index too far above the cache's high edge → forward
        //     seek past where the producer can reach via backpressure,
        //     restart.
        let range = cache.indexRange()
        let needsRestart: Bool
        if let r = range {
            needsRestart = (index < r.0) || (index > r.1 + Self.forwardWaitWindow)
        } else {
            // Empty cache. Producer's plausible cold-start reach is
            // ~3 segments; anything past that and we know we want a
            // restart at the requested index rather than wait.
            needsRestart = index > 2
        }

        if needsRestart, let restart = restartHandler {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): out-of-range fetch (cache.range=\(range.map { "\($0.0)..\($0.1)" } ?? "empty")), restarting producer",
                category: .session
            )
            restart(index)
        }

        let bytes = cache.fetch(index: index, timeout: 30.0)
        return logServed(index: index, bytes: bytes, totalStart: totalStart, restarted: needsRestart)
    }

    private func logServed(index: Int, bytes: Data?, totalStart: DispatchTime, restarted: Bool) -> Data? {
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - totalStart.uptimeNanoseconds) / 1_000_000
        if let bytes = bytes {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): served \(bytes.count) B (wait=\(String(format: "%.1f", elapsedMs))ms cache=\(cache.count) restarted=\(restarted))",
                category: .session
            )
        } else {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): cache miss after \(String(format: "%.0f", elapsedMs))ms (cache=\(cache.count) restarted=\(restarted))",
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
