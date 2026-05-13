import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Session that turns a remote video source (typically a Jellyfin
/// MKV) into a local HLS-fMP4 stream AVPlayer can play.
///
/// Architecture: one `HLSSegmentProducer` per HLS rendition published
/// through `HLSLocalServer`. The video rendition is mandatory; audio
/// renditions are spawned one-per-source-audio-track and shown to
/// AVPlayer as `EXT-X-MEDIA TYPE=AUDIO` entries in the master
/// playlist, enabling AVMediaSelection-based seamless audio switching
/// without item reload. Each producer owns its own `Demuxer`, its own
/// `SegmentCache`, and its own pump worker queue.
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
    /// the full trade-off matrix.
    fileprivate enum AudioCodecCompat {
        // fMP4-legal: stream-copy, no decode.
        case aac, ac3, eac3, flac, alac, mp3, opus
        // Not legal in fMP4: bridge through `AudioBridge`.
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

        /// CODECS attribute string when this codec is stream-copied.
        /// Empty for codecs that always bridge (they become `fLaC`
        /// after re-encode).
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
    /// Caller-chosen audio source stream index. When non-nil, the
    /// audio rendition spun up for this stream is marked
    /// `DEFAULT=YES` in the master playlist so AVPlayer picks it as
    /// the initial audio selection. When nil, `av_find_best_stream`
    /// picks the default (typically the container's default-disposition
    /// audio track).
    private let preferredDefaultAudioStreamIndex: Int32?

    /// Video rendition state.
    private var videoDemuxer: Demuxer?
    private var videoCache: SegmentCache?
    private var videoProducer: HLSSegmentProducer?
    private var videoProvider: VideoSegmentProvider?
    private var videoStreamIndex: Int32 = -1
    private var savedVideoConfig: HLSSegmentProducer.StreamConfig?
    private var videoSegmentPlan: [Segment] = []

    /// Audio renditions in the order they were spawned. Phase 1+2:
    /// at most one entry (the default audio track). Phase 3 expands
    /// to all audio tracks discovered at probe time.
    private var audioRenditions: [AudioRenditionState] = []

    private var server: HLSLocalServer?

    /// Serializes restart requests for the video producer so multiple
    /// AVPlayer GETs racing the same scrub can't tear down and rebuild
    /// in parallel. Each audio rendition has its own restart lock.
    private let videoRestartLock = NSLock()

    /// Approximate target segment duration in seconds. The hls muxer
    /// snaps cut points to keyframes at-or-after this threshold for
    /// video (so actual durations are this + GOP variance) and to
    /// audio-packet boundaries for audio (so actual durations are
    /// this + audio-frame variance, ±32ms). Apple's HLS Authoring
    /// Spec recommends 6 s; we drop to 4 s here so initial playback
    /// latency (dominated by the producer's time to demux + mux the
    /// first segment) halves while staying inside the spec's 2-6 s
    /// acceptable range.
    private static let targetSegmentDuration: Double = 4.0

    public init(
        url: URL,
        dvModeAvailable: Bool = true,
        audioSourceStreamIndexOverride: Int32? = nil
    ) {
        self.sourceURL = url
        self.dvModeAvailable = dvModeAvailable
        self.preferredDefaultAudioStreamIndex = audioSourceStreamIndexOverride
    }

    // MARK: - Public API

    public func start() throws -> URL {
        guard videoDemuxer == nil else { throw HLSVideoEngineError.alreadyStarted }

        // 1. Open the primary (video) demuxer. Audio renditions get
        //    their own demuxers later.
        let dem = Demuxer()
        do {
            try dem.open(url: sourceURL)
        } catch {
            throw HLSVideoEngineError.openFailed(reason: "\(error)")
        }
        videoDemuxer = dem

        let videoIndex = dem.videoStreamIndex
        guard videoIndex >= 0, let videoStream = dem.stream(at: videoIndex) else {
            throw HLSVideoEngineError.noVideoStream
        }
        let codecpar = videoStream.pointee.codecpar!
        let isHEVC = codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
        let isH264 = codecpar.pointee.codec_id == AV_CODEC_ID_H264
        let isVP9 = codecpar.pointee.codec_id == AV_CODEC_ID_VP9
        let isAV1 = codecpar.pointee.codec_id == AV_CODEC_ID_AV1

        let vp9OK = isVP9 && VTCapabilityProbe.vp9Available
        let av1OK = isAV1 && Self.av1ProfileIsAccepted(codecpar: codecpar) && VTCapabilityProbe.av1Available
        guard isHEVC || isH264 || vp9OK || av1OK else {
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
        //    tail.
        let prewarmStart = DispatchTime.now()
        dem.seek(to: durationSeconds * 0.5)
        let prewarmMs = Double(DispatchTime.now().uptimeNanoseconds - prewarmStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit("[HLSVideoEngine] cue prewarm: seek to \(String(format: "%.1f", durationSeconds * 0.5))s took \(String(format: "%.1f", prewarmMs))ms")

        // 3. Build the video segment plan from real keyframes.
        let keyframes = dem.indexedKeyframes(streamIndex: videoIndex)
        let plan: [Segment]
        if keyframes.count >= 2 {
            plan = buildKeyframeSegmentPlan(
                keyframes: keyframes,
                videoTimeBase: videoTimeBase,
                sourceDurationSeconds: durationSeconds
            )
            EngineLog.emit(
                "[HLSVideoEngine] video segment plan: keyframe-aligned, \(keyframes.count) IRAPs → \(plan.count) segments",
                category: .session
            )
        } else {
            plan = buildUniformSegmentPlan(
                timeBase: videoTimeBase,
                sourceDurationSeconds: durationSeconds
            )
            EngineLog.emit(
                "[HLSVideoEngine] video segment plan: uniform stride fallback (\(keyframes.count) IRAPs in index, need >=2)",
                category: .session
            )
        }
        videoSegmentPlan = plan

        // 4. Classify DV variant + pick CODECS / codecTag overrides.
        let videoCodecRouting = try classifyVideoCodec(
            codecpar: codecpar,
            isHEVC: isHEVC,
            isH264: isH264,
            isVP9: isVP9,
            isAV1: isAV1
        )

        let resolution = (Int(codecpar.pointee.width), Int(codecpar.pointee.height))
        let avgFR = videoStream.pointee.avg_frame_rate
        let frameRate: Double? = (avgFR.den > 0 && avgFR.num > 0)
            ? Double(avgFR.num) / Double(avgFR.den)
            : nil
        let hdcpLevel: String? = (videoCodecRouting.dvVariant != .none) ? "TYPE-1" : nil

        // 5. Position the demuxer at the file's first packet so the
        //    video producer's pump starts from byte zero.
        dem.seek(to: 0)

        // 6. Build the video cache + provider + config + producer.
        let segmentCache = SegmentCache()
        self.videoCache = segmentCache

        let videoConfig = HLSSegmentProducer.StreamConfig(
            codecpar: codecpar,
            timeBase: videoTimeBase,
            codecTagOverride: videoCodecRouting.codecTagOverride,
            sourceStreamIndex: videoIndex
        )
        self.videoStreamIndex = videoIndex
        self.savedVideoConfig = videoConfig

        let vProvider = VideoSegmentProvider(
            cache: segmentCache,
            segments: plan,
            restartHandler: { [weak self] idx in
                self?.restartVideoProducer(at: idx)
            }
        )
        self.videoProvider = vProvider

        let vProducer = try HLSSegmentProducer(
            demuxer: dem,
            kind: .video(videoConfig),
            cache: segmentCache,
            baseIndex: 0,
            targetSegmentDurationSeconds: Self.targetSegmentDuration
        )
        self.videoProducer = vProducer

        // 7. Resolve which source audio stream becomes the default
        //    rendition. Override wins when valid; otherwise auto.
        let autoAudioStreamIndex = dem.audioStreamIndex
        let defaultAudioStreamIndex: Int32
        if let override = preferredDefaultAudioStreamIndex,
           Self.isAudioStream(demuxer: dem, index: override) {
            defaultAudioStreamIndex = override
        } else {
            defaultAudioStreamIndex = autoAudioStreamIndex
        }

        // 8. Enumerate every audio stream in the container and spawn
        //    one rendition per track. Each gets its own demuxer (one
        //    extra HTTP connection to the source per track) so that
        //    AVMediaSelection can switch between them without the
        //    host having to bounce the pipeline.
        //
        //    The DEFAULT=YES flag goes on the rendition matching the
        //    host's audio-track preference; AVPlayer picks that one
        //    as the initial selection. Per-rendition spawn failures
        //    are logged + skipped — if exactly one track is
        //    intractable (e.g. a damaged DTS-X core), the user still
        //    gets the rest.
        //
        //    Bandwidth: N+1 HTTP connections to the source for N
        //    audio tracks. Audio packets themselves are small, but
        //    each demuxer pulls the full source byte stream because
        //    libavformat doesn't byte-skip non-target streams for
        //    container formats like MKV. Acceptable on LAN; bandwidth-
        //    constrained setups are a follow-up.
        let allAudioStreamIndexes: [Int32] = dem.audioTrackInfos().map { Int32($0.id) }
        var audioCodecsForMaster: String? = nil
        for streamIdx in allAudioStreamIndexes {
            guard let audioStream = dem.stream(at: streamIdx) else { continue }
            let isDefault = (streamIdx == defaultAudioStreamIndex)
            do {
                let rendition = try spawnAudioRendition(
                    sourceStreamIndex: streamIdx,
                    sourceAudioStream: audioStream,
                    sourceDurationSeconds: durationSeconds,
                    isDefault: isDefault
                )
                audioRenditions.append(rendition)
                if isDefault {
                    audioCodecsForMaster = rendition.info.codecs
                }
            } catch {
                EngineLog.emit(
                    "[HLSVideoEngine] audio rendition spawn failed for stream=\(streamIdx) (isDefault=\(isDefault)): \(error), skipping",
                    category: .session
                )
            }
        }
        // If the chosen default failed but others succeeded, surface
        // the first surviving rendition's codec on the master variant
        // so the EXT-X-STREAM-INF CODECS attribute stays accurate.
        if audioCodecsForMaster == nil, let first = audioRenditions.first {
            audioCodecsForMaster = first.info.codecs
        }

        // 9. Build the server with video rendition metadata, register
        //    audio renditions, then start it.
        let videoInfo = HLSVideoRenditionInfo(
            codecs: videoCodecRouting.primaryCodecs,
            supplementalCodecs: videoCodecRouting.supplementalCodecs,
            resolution: (resolution.0, resolution.1),
            videoRange: videoCodecRouting.videoRange,
            frameRate: frameRate,
            bandwidth: 5_000_000,
            averageBandwidth: 5_000_000,
            hdcpLevel: hdcpLevel,
            closedCaptions: "NONE"
        )
        let srv = HLSLocalServer(videoProvider: vProvider, videoInfo: videoInfo)
        for rendition in audioRenditions {
            srv.registerAudioRendition(info: rendition.info, provider: rendition.provider)
        }
        try srv.start()
        self.server = srv

        // 10. Kick the pumps. AVPlayer's HTTP fetches block on each
        //     cache.fetch until the requested index lands.
        vProducer.start()
        for rendition in audioRenditions {
            rendition.producer?.start()
        }

        guard let url = srv.playlistURL else {
            stop()
            throw HLSVideoEngineError.openFailed(reason: "server URL not ready")
        }

        EngineLog.emit(
            "[HLSVideoEngine] prepared: codec=\(videoCodecRouting.primaryCodecs)"
            + (videoCodecRouting.supplementalCodecs.map { " supplemental=\($0)" } ?? "")
            + " resolution=\(resolution.0)x\(resolution.1) "
            + "fps=\(frameRate.map { String(format: "%.3f", $0) } ?? "nil") "
            + "range=\(videoCodecRouting.videoRange.rawValue) "
            + "DV=\(videoCodecRouting.dvVariant) "
            + "videoSegments=\(plan.count) "
            + "audioRenditions=\(audioRenditions.count)"
            + (audioCodecsForMaster.map { " audioCodecs=\($0)" } ?? "")
            + " duration=\(String(format: "%.1f", durationSeconds))s "
            + "url=\(url.absoluteString) "
            + "(dvModeAvailable=\(dvModeAvailable))"
        )
        return url
    }

    public func stop() {
        // Stop pumps first; let them drain. Each producer's stop()
        // is async + cache.wakeWaiters() so it unblocks fast.
        videoRestartLock.lock()
        videoProducer?.stop()
        let oldVideoProducer = videoProducer
        videoProducer = nil
        videoRestartLock.unlock()
        _ = oldVideoProducer?.waitForFinish(timeout: 3.0)

        for rendition in audioRenditions {
            rendition.restartLock.lock()
            rendition.producer?.stop()
            let oldProducer = rendition.producer
            rendition.producer = nil
            rendition.restartLock.unlock()
            _ = oldProducer?.waitForFinish(timeout: 3.0)
        }

        server?.stop()
        videoCache?.close()
        videoProvider = nil
        server = nil
        videoCache = nil
        savedVideoConfig = nil
        videoSegmentPlan = []
        videoStreamIndex = -1

        for rendition in audioRenditions {
            rendition.cache.close()
            rendition.bridge?.close()
            rendition.demuxer.close()
        }
        audioRenditions = []

        videoDemuxer?.close()
        videoDemuxer = nil
    }

    deinit {
        stop()
    }

    // MARK: - Audio rendition spawn

    /// Open a dedicated demuxer for one source audio track, build its
    /// segment plan + cache + provider + producer config, and return
    /// the `AudioRenditionState` ready to register with the server.
    /// The producer is constructed but not yet started; caller starts
    /// it after server.start() so the pump doesn't race the server's
    /// readiness.
    private func spawnAudioRendition(
        sourceStreamIndex: Int32,
        sourceAudioStream: UnsafeMutablePointer<AVStream>,
        sourceDurationSeconds: Double,
        isDefault: Bool
    ) throws -> AudioRenditionState {
        // Open a fresh demuxer for this rendition. Each rendition
        // needs its own pump cursor, and the existing video demuxer
        // is owned by the video producer's pump.
        //
        // Bandwidth cost: each demuxer fetches all source bytes
        // (libavformat doesn't byte-skip non-target streams for most
        // containers, MKV in particular), then filters in-memory.
        // For a 4K HEVC source at 25 Mbps and one audio rendition,
        // that's roughly 25 Mbps × 2 = 50 Mbps of source traffic.
        // Acceptable on LAN; bandwidth-constrained setups may want a
        // master-demuxer fan-out as a follow-up.
        let audioDemuxer = Demuxer()
        do {
            try audioDemuxer.open(url: sourceURL)
        } catch {
            throw HLSVideoEngineError.openFailed(reason: "audio demuxer open: \(error)")
        }
        audioDemuxer.seek(to: 0)

        // Probe the stream from the audio demuxer's own context. The
        // stream pointer passed in (`sourceAudioStream`) belongs to
        // the VIDEO demuxer; we shouldn't pin codecpar pointers from
        // it into a config used by another demuxer's pump because the
        // video demuxer may close before this rendition does. Look
        // up the equivalent stream in the audio demuxer.
        guard let localAudioStream = audioDemuxer.stream(at: sourceStreamIndex) else {
            audioDemuxer.close()
            throw HLSVideoEngineError.openFailed(reason: "audio stream \(sourceStreamIndex) missing from fresh demuxer")
        }

        let codecID = localAudioStream.pointee.codecpar.pointee.codec_id
        let compat = AudioCodecCompat.from(codecID)
        let usesBridge = compat.requiresBridge

        // Build the AudioConfig + optional bridge.
        var bridge: AudioBridge? = nil
        var audioConfig: HLSSegmentProducer.AudioConfig
        var hlsCodecs: String

        if usesBridge {
            let br = try AudioBridge(
                srcCodecpar: localAudioStream.pointee.codecpar,
                srcTimeBase: localAudioStream.pointee.time_base
            )
            guard let encoderCp = br.encoderCodecpar else {
                br.close()
                audioDemuxer.close()
                throw HLSVideoEngineError.openFailed(reason: "audio bridge: encoder codecpar nil after init")
            }
            bridge = br
            audioConfig = HLSSegmentProducer.AudioConfig(
                codecpar: encoderCp,
                timeBase: br.encoderTimeBase,
                sourceStreamIndex: sourceStreamIndex,
                inputTimeBase: br.encoderTimeBase,
                bridge: br
            )
            hlsCodecs = "fLaC"
            EngineLog.emit(
                "[HLSVideoEngine] audio rendition \(sourceStreamIndex): codec=\(compat) (bridged → fLaC)",
                category: .session
            )
        } else if !compat.hlsCodecsString.isEmpty {
            audioConfig = HLSSegmentProducer.AudioConfig(
                codecpar: localAudioStream.pointee.codecpar,
                timeBase: localAudioStream.pointee.time_base,
                sourceStreamIndex: sourceStreamIndex,
                inputTimeBase: localAudioStream.pointee.time_base,
                bridge: nil
            )
            hlsCodecs = compat.hlsCodecsString
            EngineLog.emit(
                "[HLSVideoEngine] audio rendition \(sourceStreamIndex): codec=\(compat) stream-copy → \(hlsCodecs)",
                category: .session
            )
        } else {
            audioDemuxer.close()
            throw HLSVideoEngineError.openFailed(reason: "audio stream \(sourceStreamIndex) codec=\(compat) unsupported")
        }

        // Build the audio segment plan. Uniform 4 s stride keyed off
        // the source duration. hlsenc will cut at audio-packet
        // boundaries within ~32 ms of each threshold, so each
        // advertised EXTINF (always 4 s here) is within audio-frame
        // accuracy of the actual segment duration. AVPlayer
        // reconciles audio vs. video at PTS level inside the fMP4
        // fragments, not at EXTINF level, so the residual drift is
        // invisible.
        let audioTimeBase = localAudioStream.pointee.time_base
        let audioPlan = buildUniformSegmentPlan(
            timeBase: audioTimeBase,
            sourceDurationSeconds: sourceDurationSeconds
        )

        let audioCache = SegmentCache()
        let provider = AudioSegmentProvider(cache: audioCache, segments: audioPlan)

        // Build track metadata for the master playlist entry.
        let trackInfo = singleTrackInfo(from: localAudioStream, index: Int(sourceStreamIndex))
        let renditionID = String(sourceStreamIndex)
        let renditionInfo = HLSAudioRendition(
            id: renditionID,
            name: trackInfo.name,
            language: trackInfo.language,
            isDefault: isDefault,
            codecs: hlsCodecs,
            channels: trackInfo.channels
        )

        // Try to build the producer. Stream-copy of EAC3 from MKV
        // sometimes fails write_header (missing `dec3` extradata);
        // if that happens, retry through the FLAC bridge.
        let producer: HLSSegmentProducer
        do {
            producer = try HLSSegmentProducer(
                demuxer: audioDemuxer,
                kind: .audio(audioConfig),
                cache: audioCache,
                baseIndex: 0,
                targetSegmentDurationSeconds: Self.targetSegmentDuration
            )
        } catch where !usesBridge {
            EngineLog.emit(
                "[HLSVideoEngine] audio rendition \(sourceStreamIndex) stream-copy write_header failed: \(error), retrying via FLAC bridge",
                category: .session
            )
            let br = try AudioBridge(
                srcCodecpar: localAudioStream.pointee.codecpar,
                srcTimeBase: localAudioStream.pointee.time_base
            )
            guard let encoderCp = br.encoderCodecpar else {
                br.close()
                audioDemuxer.close()
                throw HLSVideoEngineError.openFailed(reason: "audio bridge fallback: encoder codecpar nil")
            }
            bridge = br
            audioConfig = HLSSegmentProducer.AudioConfig(
                codecpar: encoderCp,
                timeBase: br.encoderTimeBase,
                sourceStreamIndex: sourceStreamIndex,
                inputTimeBase: br.encoderTimeBase,
                bridge: br
            )
            hlsCodecs = "fLaC"
            do {
                producer = try HLSSegmentProducer(
                    demuxer: audioDemuxer,
                    kind: .audio(audioConfig),
                    cache: audioCache,
                    baseIndex: 0,
                    targetSegmentDurationSeconds: Self.targetSegmentDuration
                )
            } catch {
                br.close()
                audioDemuxer.close()
                throw error
            }
        } catch {
            audioDemuxer.close()
            throw error
        }

        let rendition = AudioRenditionState(
            info: HLSAudioRendition(
                id: renditionID,
                name: renditionInfo.name,
                language: renditionInfo.language,
                isDefault: renditionInfo.isDefault,
                codecs: hlsCodecs,
                channels: renditionInfo.channels
            ),
            demuxer: audioDemuxer,
            cache: audioCache,
            provider: provider,
            config: audioConfig,
            bridge: bridge,
            segmentPlan: audioPlan,
            producer: producer
        )
        provider.restartHandler = { [weak self, weak rendition] idx in
            guard let self = self, let rendition = rendition else { return }
            self.restartAudioProducer(rendition: rendition, at: idx)
        }
        return rendition
    }

    // MARK: - Producer restart

    /// Tear down the current video producer, seek the video demuxer to
    /// the start of segment `idx`, and spin up a fresh producer with
    /// `baseIndex = idx`. Triggered by `VideoSegmentProvider` when
    /// AVPlayer requests a segment that's outside the current cache
    /// window.
    private func restartVideoProducer(at idx: Int) {
        videoRestartLock.lock()
        defer { videoRestartLock.unlock() }

        guard idx >= 0,
              idx < videoSegmentPlan.count,
              videoDemuxer != nil,
              let cache = videoCache,
              let cfg = savedVideoConfig else { return }

        let restartStart = DispatchTime.now()

        if let old = videoProducer {
            old.stop()
            let ok = old.waitForFinish(timeout: 5.0)
            if !ok {
                EngineLog.emit(
                    "[HLSVideoEngine] video restart at idx=\(idx): old producer didn't exit within 5s, abandoning",
                    category: .session
                )
            }
        }
        videoProducer = nil

        // Seek the demuxer to the ABSOLUTE source-PTS of the target
        // segment's first keyframe, not to the relative playlist time
        // — see the original Phase B restart logic for the
        // rationale (B-frame head padding / non-zero start_pts).
        let absoluteTargetPts = videoSegmentPlan[idx].startPts
        let videoTb = cfg.timeBase
        let absoluteTargetSeconds = Double(absoluteTargetPts) * Double(videoTb.num) / Double(videoTb.den)
        videoDemuxer?.seek(to: absoluteTargetSeconds)

        do {
            let newProd = try HLSSegmentProducer(
                demuxer: videoDemuxer!,
                kind: .video(cfg),
                cache: cache,
                baseIndex: idx,
                targetSegmentDurationSeconds: Self.targetSegmentDuration
            )
            videoProducer = newProd
            newProd.start()
        } catch {
            EngineLog.emit(
                "[HLSVideoEngine] video restart at idx=\(idx) failed: \(error)",
                category: .session
            )
            return
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - restartStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit(
            "[HLSVideoEngine] video producer restarted at idx=\(idx) (seek=\(String(format: "%.2f", absoluteTargetSeconds))s, took \(String(format: "%.0f", elapsedMs))ms)",
            category: .session
        )
    }

    /// Tear down + rebuild one audio rendition's producer at `idx`.
    /// Triggered by `AudioSegmentProvider` on out-of-range fetch.
    private func restartAudioProducer(rendition: AudioRenditionState, at idx: Int) {
        rendition.restartLock.lock()
        defer { rendition.restartLock.unlock() }

        guard idx >= 0, idx < rendition.segmentPlan.count else { return }

        let restartStart = DispatchTime.now()

        if let old = rendition.producer {
            old.stop()
            let ok = old.waitForFinish(timeout: 5.0)
            if !ok {
                EngineLog.emit(
                    "[HLSVideoEngine] audio restart id=\(rendition.info.id) idx=\(idx): old producer didn't exit within 5s, abandoning",
                    category: .session
                )
            }
        }
        rendition.producer = nil

        let targetSeconds = rendition.segmentPlan[idx].startSeconds
        rendition.demuxer.seek(to: targetSeconds)
        // Re-arm the FLAC bridge's PTS rebase off the new cursor.
        rendition.bridge?.startSegment()

        do {
            let newProd = try HLSSegmentProducer(
                demuxer: rendition.demuxer,
                kind: .audio(rendition.config),
                cache: rendition.cache,
                baseIndex: idx,
                targetSegmentDurationSeconds: Self.targetSegmentDuration
            )
            rendition.producer = newProd
            newProd.start()
        } catch {
            EngineLog.emit(
                "[HLSVideoEngine] audio restart id=\(rendition.info.id) idx=\(idx) failed: \(error)",
                category: .session
            )
            return
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - restartStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit(
            "[HLSVideoEngine] audio producer id=\(rendition.info.id) restarted at idx=\(idx) (seek=\(String(format: "%.2f", targetSeconds))s, took \(String(format: "%.0f", elapsedMs))ms)",
            category: .session
        )
    }

    // MARK: - Video codec classification

    private struct VideoCodecRouting {
        let codecTagOverride: String?
        let videoRange: HLSVideoRange
        let primaryCodecs: String
        let supplementalCodecs: String?
        let dvVariant: DVVariant
    }

    private func classifyVideoCodec(
        codecpar: UnsafePointer<AVCodecParameters>,
        isHEVC: Bool,
        isH264: Bool,
        isVP9: Bool,
        isAV1: Bool
    ) throws -> VideoCodecRouting {
        if isVP9 {
            let trc = codecpar.pointee.color_trc
            let videoRange: HLSVideoRange
            if trc == AVCOL_TRC_ARIB_STD_B67 {
                videoRange = .hlg
            } else if trc == AVCOL_TRC_SMPTE2084 {
                videoRange = .pq
            } else {
                videoRange = .sdr
            }
            let profile = Int(codecpar.pointee.profile)
            let safeProfile = (profile >= 0 && profile <= 3) ? profile : 0
            let level = Int(codecpar.pointee.level)
            let safeLevel = level > 0 ? level : 41
            let bitDepth = Int(codecpar.pointee.bits_per_raw_sample) > 0
                ? Int(codecpar.pointee.bits_per_raw_sample)
                : (videoRange == .sdr ? 8 : 10)
            let primaryCodecs = String(
                format: "vp09.%02d.%02d.%02d.01.01.01.01.00",
                safeProfile, safeLevel, bitDepth
            )
            return VideoCodecRouting(
                codecTagOverride: "vp09",
                videoRange: videoRange,
                primaryCodecs: primaryCodecs,
                supplementalCodecs: nil,
                dvVariant: .none
            )
        } else if isAV1 {
            let trc = codecpar.pointee.color_trc
            let videoRange: HLSVideoRange
            if trc == AVCOL_TRC_ARIB_STD_B67 {
                videoRange = .hlg
            } else if trc == AVCOL_TRC_SMPTE2084 {
                videoRange = .pq
            } else {
                videoRange = .sdr
            }
            let level = Int(codecpar.pointee.level)
            let safeLevel = (level >= 0 && level <= 31) ? level : 8
            let bitDepth = Int(codecpar.pointee.bits_per_raw_sample) > 0
                ? Int(codecpar.pointee.bits_per_raw_sample)
                : (videoRange == .sdr ? 8 : 10)
            let primaryCodecs = String(
                format: "av01.0.%02dM.%02d.0.111.01.01.01.0",
                safeLevel, bitDepth
            )
            return VideoCodecRouting(
                codecTagOverride: "av01",
                videoRange: videoRange,
                primaryCodecs: primaryCodecs,
                supplementalCodecs: nil,
                dvVariant: .none
            )
        } else if isH264 {
            let videoRange: HLSVideoRange = isHDRTransfer(codecpar) ? .pq : .sdr
            let profileIDC = Int(codecpar.pointee.profile)
            let levelIDC = Int(codecpar.pointee.level)
            let safeProfile = profileIDC > 0 ? profileIDC : 100
            let safeLevel = levelIDC > 0 ? levelIDC : 40
            let primaryCodecs = String(format: "avc1.%02X%02X%02X", safeProfile, 0, safeLevel)
            return VideoCodecRouting(
                codecTagOverride: "avc1",
                videoRange: videoRange,
                primaryCodecs: primaryCodecs,
                supplementalCodecs: nil,
                dvVariant: .none
            )
        } else if !dvModeAvailable {
            let hevcLevelRaw = Int(codecpar.pointee.level)
            let hevcLevel = hevcLevelRaw > 0 ? hevcLevelRaw : 150
            let trc = codecpar.pointee.color_trc
            let videoRange: HLSVideoRange
            if trc == AVCOL_TRC_ARIB_STD_B67 {
                videoRange = .hlg
            } else if trc == AVCOL_TRC_SMPTE2084 {
                videoRange = .pq
            } else {
                videoRange = .sdr
            }
            return VideoCodecRouting(
                codecTagOverride: "hvc1",
                videoRange: videoRange,
                primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                supplementalCodecs: nil,
                dvVariant: .none
            )
        } else {
            let dvRecord = doviConfigRecord(from: codecpar)
            let dvVariant = classifyDVVariant(dvRecord)

            let dvLevelRaw = Int(dvRecord?.dv_level ?? 0)
            let dvLevel = dvLevelRaw > 0 ? dvLevelRaw : 6
            let hevcLevelRaw = Int(codecpar.pointee.level)
            let hevcLevel = hevcLevelRaw > 0 ? hevcLevelRaw : 150
            let dvLevelStr = String(format: "%02d", dvLevel)

            switch dvVariant {
            case .profile5:
                return VideoCodecRouting(
                    codecTagOverride: "dvh1",
                    videoRange: .pq,
                    primaryCodecs: "dvh1.05.\(dvLevelStr)",
                    supplementalCodecs: nil,
                    dvVariant: .profile5
                )
            case .profile81:
                return VideoCodecRouting(
                    codecTagOverride: "dvh1",
                    videoRange: .pq,
                    primaryCodecs: "dvh1.08.\(dvLevelStr)",
                    supplementalCodecs: nil,
                    dvVariant: .profile81
                )
            case .profile84:
                return VideoCodecRouting(
                    codecTagOverride: "hvc1",
                    videoRange: .hlg,
                    primaryCodecs: "hvc1.2.4.L\(hevcLevel).b0",
                    supplementalCodecs: "dvh1.08.\(dvLevelStr)/db4h",
                    dvVariant: .profile84
                )
            case .profile7:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: 7, compatID: -1)
            case .profile82:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: 8, compatID: 2)
            case .unknown:
                let p = Int(dvRecord?.dv_profile ?? 0)
                let c = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 0)
                throw HLSVideoEngineError.unsupportedDVProfile(profile: p, compatID: c)
            case .none:
                let videoRange: HLSVideoRange = isHDRTransfer(codecpar) ? .pq : .sdr
                return VideoCodecRouting(
                    codecTagOverride: "hvc1",
                    videoRange: videoRange,
                    primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                    supplementalCodecs: nil,
                    dvVariant: .none
                )
            }
        }
    }

    // MARK: - Segment planning

    /// Build a uniform-duration segment plan from the source's
    /// reported duration. Used for audio renditions (always) and for
    /// video when libavformat's keyframe index is too sparse for the
    /// keyframe-aligned plan.
    private func buildUniformSegmentPlan(
        timeBase: AVRational,
        sourceDurationSeconds: Double
    ) -> [Segment] {
        guard sourceDurationSeconds > 0 else { return [] }
        let stride = Self.targetSegmentDuration
        let count = max(1, Int(ceil(sourceDurationSeconds / stride)))
        let tb = Double(timeBase.num) / Double(timeBase.den)
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

    /// Build a video segment plan from real keyframes using
    /// libavformat's hls muxer cut algorithm: segment N ends at the
    /// first keyframe whose absolute distance from the first index
    /// keyframe's PTS reaches `(N+1) * targetSegmentDuration`.
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

    private static func av1ProfileIsAccepted(codecpar: UnsafePointer<AVCodecParameters>) -> Bool {
        let profile = codecpar.pointee.profile
        if profile != -99 && profile != 0 {
            EngineLog.emit("[HLSVideoEngine] AV1 profile=\(profile) rejected (Main/Profile 0 only)", category: .session)
            return false
        }
        let level = codecpar.pointee.level
        if level >= 0 && level > 13 {
            EngineLog.emit("[HLSVideoEngine] AV1 level=\(level) rejected (cap at 5.3 / level 13)", category: .session)
            return false
        }
        return true
    }

    private static func isAudioStream(demuxer: Demuxer, index: Int32) -> Bool {
        guard index >= 0, let stream = demuxer.stream(at: index) else {
            return false
        }
        return stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
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
            default: return .profile81
            }
        }
        return .unknown
    }

    // MARK: - Track metadata lookup

    /// Build a `TrackInfo` for a single audio stream. Mirrors the
    /// logic in `Demuxer.audioTrackInfos()` but takes a caller-known
    /// stream pointer so we avoid enumerating all streams again.
    private func singleTrackInfo(
        from stream: UnsafeMutablePointer<AVStream>,
        index: Int
    ) -> TrackInfo {
        let codecpar = stream.pointee.codecpar!
        let codecName: String
        if let codec = avcodec_find_decoder(codecpar.pointee.codec_id) {
            codecName = String(cString: codec.pointee.name)
        } else {
            codecName = "unknown"
        }
        let language = metadataValue(stream.pointee.metadata, key: "language")
        let title = metadataValue(stream.pointee.metadata, key: "title")
        let name: String
        if let title = title, !title.isEmpty {
            name = title
        } else if let lang = language {
            name = "\(lang.uppercased()) (\(codecName))"
        } else {
            name = "Track \(index) (\(codecName))"
        }
        let isDefault = (stream.pointee.disposition & AV_DISPOSITION_DEFAULT) != 0
        let channels = Int(codecpar.pointee.ch_layout.nb_channels)
        let isAtmos = (codecpar.pointee.codec_id == AV_CODEC_ID_EAC3)
            && codecpar.pointee.profile == 30
        return TrackInfo(
            id: index,
            name: name,
            codec: codecName,
            language: language,
            channels: channels,
            isDefault: isDefault,
            isAtmos: isAtmos
        )
    }

    private func metadataValue(_ dict: OpaquePointer?, key: String) -> String? {
        guard let dict = dict else { return nil }
        guard let entry = av_dict_get(dict, key, nil, 0) else { return nil }
        return String(cString: entry.pointee.value)
    }
}

// MARK: - Segment plan model

fileprivate struct Segment {
    let startPts: Int64
    let endPts: Int64
    let startSeconds: Double
    let durationSeconds: Double
}

// MARK: - Audio rendition state

/// Aggregates everything one alternate audio rendition needs: its
/// own demuxer, segment cache, provider, producer config + producer
/// instance, optional FLAC bridge, segment plan, and a per-rendition
/// restart lock. Owned by `HLSVideoEngine` and torn down in
/// `stop()`.
private final class AudioRenditionState {
    let info: HLSAudioRendition
    let demuxer: Demuxer
    let cache: SegmentCache
    let provider: AudioSegmentProvider
    let config: HLSSegmentProducer.AudioConfig
    let bridge: AudioBridge?
    let segmentPlan: [Segment]
    var producer: HLSSegmentProducer?
    let restartLock = NSLock()

    init(
        info: HLSAudioRendition,
        demuxer: Demuxer,
        cache: SegmentCache,
        provider: AudioSegmentProvider,
        config: HLSSegmentProducer.AudioConfig,
        bridge: AudioBridge?,
        segmentPlan: [Segment],
        producer: HLSSegmentProducer?
    ) {
        self.info = info
        self.demuxer = demuxer
        self.cache = cache
        self.provider = provider
        self.config = config
        self.bridge = bridge
        self.segmentPlan = segmentPlan
        self.producer = producer
    }
}

// MARK: - Cache-backed providers

/// Shared restart + cache logic for both video and audio renditions.
/// Each rendition has its own cache; on a fetch that's outside the
/// current cache window, the restart handler fires to tear down +
/// rebuild that rendition's producer at the requested index.
private class CachedSegmentProvider: HLSSegmentProvider {
    let cache: SegmentCache
    let segments: [Segment]
    var restartHandler: ((Int) -> Void)?

    /// Forward-distance threshold beyond which a fetch triggers a
    /// restart instead of waiting for the producer to catch up. At
    /// 4 s segments, 8 segments ≈ 32 s of source content; further
    /// than that and waiting is slower than tearing down + resuming
    /// at the target.
    private static let forwardWaitWindow = 8

    init(cache: SegmentCache, segments: [Segment], restartHandler: ((Int) -> Void)? = nil) {
        self.cache = cache
        self.segments = segments
        self.restartHandler = restartHandler
    }

    func initSegment() -> Data? {
        return cache.fetchInit(timeout: 30.0)
    }

    func mediaSegment(at index: Int) -> Data? {
        guard index >= 0, index < segments.count else { return nil }
        let totalStart = DispatchTime.now()

        // Declare AVPlayer's target FIRST so the cache window slides
        // to centre on `index` before any subsequent producer store
        // runs `pruneOutsideWindow`.
        cache.declareTarget(index)

        if let hit = cache.peek(index: index) {
            return logServed(index: index, bytes: hit, totalStart: totalStart, restarted: false)
        }

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
}

/// Video rendition provider. Same shared cache+restart behavior as
/// the audio provider; kept as a distinct type so HLSLocalServer can
/// identify the video provider via `===`.
private final class VideoSegmentProvider: CachedSegmentProvider {
}

/// Audio rendition provider. Symmetric to `VideoSegmentProvider`;
/// distinct type so the master-builder can tell renditions apart from
/// the video stream.
private final class AudioSegmentProvider: CachedSegmentProvider {
}
