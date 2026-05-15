import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Drives libavformat's `hls` muxer for the duration of one playback
/// session. Replaces the previous self-built `FMP4VideoMuxer` + lazy
/// per-segment-fragment generator pair with a single long-lived
/// `AVFormatContext` whose segment writes are redirected, via custom
/// `s->io_open` / `s->io_close2` callbacks, into a `SegmentCache`.
///
/// Why this design: the libavformat HLS-fmp4 output is the same
/// pipeline `ffmpeg -f hls -hls_segment_type fmp4` emits, byte-for-byte
/// proven against reference fixtures. The previous design replicated
/// pieces of this pipeline outside libavformat (per-fragment muxer
/// instantiation, manual init capture, manual PTS-shift compensation
/// for B-frame reorder) and accumulated subtle structural drift that
/// caused AVPlayer to lose A/V sync after a handful of seconds. Letting
/// libavformat own the entire mux + segment-cut decision tree removes
/// that whole surface.
///
/// Strict-forward-only in this phase: the muxer pumps from the demuxer
/// in source order and writes segments 0, 1, 2 ... into the cache.
/// Backward scrubs are handled in Phase B by tearing this instance
/// down and constructing a new one with a non-zero `baseIndex`.
final class HLSSegmentProducer: @unchecked Sendable {

    // MARK: - Errors

    enum ProducerError: Error, CustomStringConvertible {
        case muxerAllocFailed(code: Int32)
        case streamCreationFailed
        case copyParametersFailed(code: Int32)
        case writeHeaderFailed(code: Int32)

        var description: String {
            switch self {
            case .muxerAllocFailed(let c):     return "HLSSegmentProducer: avformat_alloc_output_context2 for hls failed (\(c))"
            case .streamCreationFailed:        return "HLSSegmentProducer: avformat_new_stream failed"
            case .copyParametersFailed(let c): return "HLSSegmentProducer: avcodec_parameters_copy failed (\(c))"
            case .writeHeaderFailed(let c):    return "HLSSegmentProducer: avformat_write_header failed (\(c))"
            }
        }
    }

    /// Per-stream codec config carried from `HLSVideoEngine` into the
    /// muxer setup. Same shape as the previous `FMP4VideoMuxer.StreamConfig`
    /// so the caller's wire-up stays familiar.
    struct StreamConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let timeBase: AVRational
        /// Override the codec_tag emitted by the mp4 sub-muxer. Used to
        /// force `dvh1` / `hvc1` / `avc1` instead of FFmpeg's defaults
        /// of `hev1` / `h264`, which AVPlayer rejects.
        let codecTagOverride: String?
    }

    /// Audio output wiring. The producer is agnostic about whether
    /// the audio is a stream-copy passthrough (e.g. EAC3-JOC Atmos)
    /// or a FLAC bridge (TrueHD / DTS / Vorbis / PCM / MP2 decoded
    /// then re-encoded as FLAC). Both shapes funnel through the
    /// same av_write_frame path; the `bridge` field decides which.
    struct AudioConfig {
        /// codecpar installed on the muxer's audio output stream. For
        /// stream-copy this is the source's codecpar; for FLAC bridge
        /// this is `AudioBridge.encoderCodecpar`.
        let codecpar: UnsafePointer<AVCodecParameters>
        /// time_base set on the muxer stream. The muxer will rewrite
        /// this to its own auto-picked timescale at write_header time
        /// (similar to the video stream), but we still need to set
        /// the input value so libavformat knows the requested base.
        let timeBase: AVRational
        /// Source stream index to filter packets from in the demuxer.
        let sourceStreamIndex: Int32
        /// Time base of packets handed to `av_write_frame`. For
        /// stream-copy this is the source's time_base (the demuxer's
        /// packets are in source units). For FLAC bridge this is
        /// `AudioBridge.encoderTimeBase` (the bridge re-stamps the
        /// FLAC packets it emits into its encoder's time_base).
        let inputTimeBase: AVRational
        /// Optional decode-then-FLAC-encode bridge. Non-nil means the
        /// pump routes each source audio packet through `bridge.feed`
        /// and muxes the returned FLAC packets; nil means the source
        /// packet is muxed directly (stream-copy).
        let bridge: AudioBridge?
    }

    // MARK: - State

    private let demuxer: Demuxer
    private let videoStreamIndex: Int32
    private let videoOutputStreamIndex: Int32 = 0
    private let cache: SegmentCache
    /// Absolute index offset for segments produced by this instance.
    /// Phase A always uses 0; Phase B's restart machinery passes the
    /// scrub-target index here.
    private let baseIndex: Int

    /// Source video stream's time_base. Carried from caller so the
    /// pump can rescale packet timestamps before handing them to the
    /// muxer (avformat_write_header tends to rewrite the muxer
    /// stream's time_base to its own preferred value, e.g. 1/16000 for
    /// 30fps video, which would otherwise make pts=8333 read as 0.52s
    /// instead of 8.333s and suppress every segment cut).
    private let sourceVideoTimeBase: AVRational
    /// Muxer's chosen time_base for the output video stream, latched
    /// after avformat_write_header. Used as the destination time_base
    /// for `av_packet_rescale_ts` on every video packet.
    private var muxerVideoTimeBase: AVRational = AVRational(num: 1, den: 1)

    /// Audio wiring info, nil for video-only sessions.
    private let audioConfig: AudioConfig?
    /// Audio output stream index in the muxer (1 when audio is wired,
    /// unused otherwise). Hardcoded since we add at most one audio
    /// stream and it's always added after the video stream.
    private let audioOutputStreamIndex: Int32 = 1
    /// Muxer's chosen time_base for the output audio stream, latched
    /// after avformat_write_header. Same dance as `muxerVideoTimeBase`.
    private var muxerAudioTimeBase: AVRational = AVRational(num: 1, den: 1)

    /// Last valid dts (in *source* time_base) seen on the video and
    /// audio streams. Used to repair NOPTS dts emitted by the
    /// matroska demuxer mid-cluster after `avformat_seek_file`: we
    /// substitute `lastValidDts + 1` so the muxer's monotonic-dts
    /// check still passes and the packet keeps flowing instead of
    /// being dropped. Init to `AV_NOPTS_VALUE` (Int64.min).
    private var lastVideoSourceDts: Int64 = Int64.min
    private var lastAudioSourceDts: Int64 = Int64.min

    /// Per-frame fallback duration (in source video time_base) used
    /// to backfill the last packet of a fragment when the matroska
    /// demuxer doesn't supply `pkt->duration`. Many MKV remuxers
    /// (HandBrake / MakeMKV variants, web-rip pipelines) drop the
    /// TrackEntry `DefaultDuration` element AND don't write per-
    /// block `BlockDuration`, so every video packet arrives with
    /// `duration == 0`. FFmpeg's mp4 sub-muxer reads `pkt->duration`
    /// only for the LAST sample of each fragment (intermediate
    /// sample durations come from `dts[i+1] - dts[i]`), so the last
    /// `trun` entry ends up with `sample_duration = 0`, the fragment
    /// stops one frame short of where the next fragment's `tfdt`
    /// starts, and AVPlayer's HLS-fMP4 engine sees an unfillable
    /// gap. AVPlayer parks on `WaitingToMinimizeStallsReason` and
    /// never queues seg-N+1.
    ///
    /// Computed from `videoStream.avg_frame_rate` at engine setup
    /// (see `HLSVideoEngine.makeProducer`); applied only when a
    /// pending packet's duration is zero and no successor is
    /// available to compute it from (the EOF case).
    private let videoFallbackDurationPts: Int64

    /// Same as `videoFallbackDurationPts` but for stream-copy
    /// audio. AC3 / EAC3 emit one frame per packet at
    /// `frame_size / sample_rate` seconds; AAC at `1024 / sample_rate`.
    /// Computed from `audioStream.codecpar` at engine setup.
    private let audioFallbackDurationPts: Int64

    /// One-packet look-behind state. The pump holds the most recent
    /// video / stream-copy-audio packet so the NEXT packet's dts can
    /// be used to compute `pending.duration = next.dts - pending.dts`
    /// (the only place to recover from demuxers that don't supply
    /// `pkt->duration`). On EOF the pending packet is flushed using
    /// `*FallbackDurationPts` as the duration.
    private var pendingVideoPkt: UnsafeMutablePointer<AVPacket>?
    private var pendingAudioPkt: UnsafeMutablePointer<AVPacket>?
    private var loggedFirstVideoPktInfo = false

    /// Target first dts (in source video / audio TB respectively) after
    /// `avformat_seek_file` for restart sessions. `matroska_read_seek`
    /// uses MKV `Cues` for seek, while `dem.indexedKeyframes` reports
    /// libavformat's wider AVStream index which can include non-Cue
    /// keyframes that the demuxer's own seek code can NOT land on
    /// precisely. The seek therefore lands at the Cue ≤ target — which
    /// can be 100+ ms before `plan[baseIndex].startPts`. The producer
    /// then writes a fragment whose `tfdt` is well below the playlist's
    /// cumulative-EXTINF position for that segment, AVPlayer's HLS-fMP4
    /// engine sees a position mismatch, and the asset stalls at
    /// `waitingToPlay` without surfacing an error.
    ///
    /// Scan-forward: per stream, drop incoming packets after the seek
    /// until we see a packet whose dts ≥ the target (and, for video,
    /// is a key frame). Once each stream's gate opens, all subsequent
    /// packets pass through normally. Restart-only — for the
    /// initial-start (baseIndex == 0) session both targets are
    /// `AV_NOPTS_VALUE` and the gates start open.
    private let restartTargetVideoDts: Int64
    private let restartTargetAudioDts: Int64
    private var videoScanComplete: Bool
    private var audioScanComplete: Bool

    /// PTS shift applied to all packets after the scan-forward gate
    /// opens (in each stream's own source TB). Aligns the muxer's
    /// fragment `tfdt` with the playlist's cumulative-EXTINF origin:
    ///   - Video shift = `firstKeyframePts` so seg-0 tfdt=0 matches
    ///     the playlist's seg-0 cumulative position of 0.
    ///   - Audio shift = `audio.start_time` so the audio stream's
    ///     first fragment tfdt=0 too. MKV from remuxers often parks
    ///     audio.start_time at 0 even when video.start_time is non-
    ///     zero, so a uniform shift would push audio negative — per
    ///     stream is the correct alignment.
    private let videoShiftPts: Int64
    private let audioShiftPts: Int64

    private var formatContext: UnsafeMutablePointer<AVFormatContext>?

    /// How many segments the pump is allowed to race ahead of the
    /// highest segment AVPlayer has actually fetched. With the
    /// default `SegmentCache.capacity = 30` this leaves ~10 segments
    /// of headroom behind the playhead for cheap short-range backward
    /// scrubs without triggering a producer-restart.
    private static let bufferAheadSegments = 20

    /// Worker queue running the read → write_frame pump. One per
    /// producer instance; the queue is serial, no concurrent writes
    /// to the format context. Closed when `stop()` is called.
    private let pumpQueue = DispatchQueue(
        label: "AetherEngine.HLSSegmentProducer.pump",
        qos: .userInitiated
    )

    private let stateLock = NSLock()
    private var pumpStarted = false
    private var shouldStop = false

    /// Set once the pump exits (EOF, error, or `stop()`). Read by
    /// `waitForFinish(timeout:)` so the host can synchronously
    /// tear down this producer before constructing a successor at a
    /// different `baseIndex` (the backward-scrub restart path).
    private let finishCondition = NSCondition()
    private var didFinishFlag = false
    var didFinish: Bool {
        finishCondition.lock()
        defer { finishCondition.unlock() }
        return didFinishFlag
    }

    /// Fires (off the pump thread) once per producer instance the first
    /// time the byte sequence `B5 00 3C 00 01 04` — the unique HDR10+
    /// T.35 SEI / ITU-T-T.35 OBU prefix (country=US, provider=SMPTE,
    /// oriented_code=HDR10+, application=4) — is seen in a video
    /// packet's payload. HLSVideoEngine debounces across restarts and
    /// forwards to AetherEngine for the `videoFormat` upgrade.
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?

    /// Latched once the signature has been seen in this producer's
    /// packet stream so the scan goes silent for the remainder of the
    /// session. The byte scan is cheap (~µs per packet) but there's no
    /// reason to keep paying for it after detection.
    private var hdr10PlusDetected = false

    // MARK: - Init

    init(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        video: StreamConfig,
        audio: AudioConfig? = nil,
        cache: SegmentCache,
        baseIndex: Int = 0,
        targetSegmentDurationSeconds: Double = 6.0,
        videoFallbackDurationPts: Int64,
        audioFallbackDurationPts: Int64 = 0,
        restartTargetVideoDts: Int64 = Int64.min,
        restartTargetAudioDts: Int64 = Int64.min,
        videoShiftPts: Int64 = 0,
        audioShiftPts: Int64 = 0
    ) throws {
        self.demuxer = demuxer
        self.videoStreamIndex = videoStreamIndex
        self.audioConfig = audio
        self.cache = cache
        self.baseIndex = baseIndex
        self.sourceVideoTimeBase = video.timeBase
        self.videoFallbackDurationPts = videoFallbackDurationPts
        self.audioFallbackDurationPts = audioFallbackDurationPts
        self.restartTargetVideoDts = restartTargetVideoDts
        self.restartTargetAudioDts = restartTargetAudioDts
        self.videoShiftPts = videoShiftPts
        self.audioShiftPts = audioShiftPts
        // Scan-forward gates start open for initial-start sessions
        // (no restart target), closed for restart sessions until the
        // first relevant packet arrives.
        self.videoScanComplete = (restartTargetVideoDts == Int64.min)
        self.audioScanComplete = (restartTargetAudioDts == Int64.min)

        // 1. Allocate hls output context. Output url "playlist.m3u8" is
        //    a placeholder: hlsenc derives segment filenames from it
        //    when `hls_segment_filename` isn't set; we override it
        //    explicitly below.
        var ctxOut: UnsafeMutablePointer<AVFormatContext>?
        let allocRet = avformat_alloc_output_context2(&ctxOut, nil, "hls", "playlist.m3u8")
        guard allocRet == 0, let ctx = ctxOut else {
            throw ProducerError.muxerAllocFailed(code: allocRet)
        }
        formatContext = ctx

        // 2. Allow non-standard extensions so the inner mp4 sub-muxer
        //    writes `dvcC` / `dvvC` atoms (DV-spec, not ISOBMFF base).
        ctx.pointee.strict_std_compliance = -2

        // 3. Wire the IO trampolines. The opaque we stash here is also
        //    propagated to the nested mp4 sub-muxer (hls_mux_init copies
        //    `s->opaque` and the io callbacks onto `oc`), so the
        //    trampolines below receive the same producer pointer
        //    regardless of which AVFormatContext invoked them.
        ctx.pointee.opaque = Unmanaged.passUnretained(self).toOpaque()
        ctx.pointee.io_open = hlsProducerIOOpen
        ctx.pointee.io_close2 = hlsProducerIOClose2

        // 4. Add the video output stream. Time base is the source's;
        //    the mp4 sub-muxer rescales to its track timescale (mvhd /
        //    mdhd) automatically.
        guard let videoStream = avformat_new_stream(ctx, nil) else {
            cleanup()
            throw ProducerError.streamCreationFailed
        }
        let vCopy = avcodec_parameters_copy(videoStream.pointee.codecpar, video.codecpar)
        guard vCopy >= 0 else {
            cleanup()
            throw ProducerError.copyParametersFailed(code: vCopy)
        }
        videoStream.pointee.time_base = video.timeBase
        if let override = video.codecTagOverride,
           let tag = Self.mkTag(fromFourCC: override) {
            videoStream.pointee.codecpar.pointee.codec_tag = tag
        }

        // 4b. Add the audio output stream (if any). Stream-copy and
        //     FLAC-bridge cases use exactly the same wiring here —
        //     the bridge's `encoderCodecpar` is structured identically
        //     to a stream-copy codecpar from the caller's point of view.
        if let audio = audio {
            guard let audioStream = avformat_new_stream(ctx, nil) else {
                cleanup()
                throw ProducerError.streamCreationFailed
            }
            let aCopy = avcodec_parameters_copy(audioStream.pointee.codecpar, audio.codecpar)
            guard aCopy >= 0 else {
                cleanup()
                throw ProducerError.copyParametersFailed(code: aCopy)
            }
            audioStream.pointee.time_base = audio.timeBase
        }

        // 5. Configure hls muxer options. The mp4 sub-muxer's movflags
        //    are set inside hls_mux_init at libavformat/hlsenc.c:867
        //    (`+frag_custom+dash+delay_moov`); we do not override them.
        var opts: OpaquePointer? = nil
        defer { av_dict_free(&opts) }
        av_dict_set(&opts, "hls_segment_type", "fmp4", 0)
        av_dict_set(&opts, "hls_fmp4_init_filename", "init.mp4", 0)
        av_dict_set(&opts, "hls_segment_filename", "seg-%d.m4s", 0)
        let hlsTimeStr = String(format: "%.3f", targetSegmentDurationSeconds)
        av_dict_set(&opts, "hls_time", hlsTimeStr, 0)
        av_dict_set(&opts, "hls_playlist_type", "vod", 0)
        av_dict_set(&opts, "hls_list_size", "0", 0)
        av_dict_set(&opts, "hls_flags", "independent_segments", 0)
        if baseIndex > 0 {
            av_dict_set(&opts, "start_number", String(baseIndex), 0)
        }

        let ret = avformat_write_header(ctx, &opts)
        guard ret >= 0 else {
            cleanup()
            throw ProducerError.writeHeaderFailed(code: ret)
        }

        // Latch the muxer stream's time_base after write_header. The
        // hls muxer (via its mov sub-muxer) rewrites the output stream
        // time_base to its own auto-picked timescale (e.g. 1/16000 for
        // a 30 fps video, 1/<sampleRate> for audio), but the source
        // packets we feed still carry source-time-base pts/dts. Without
        // rescaling, every pkt.pts looks scaled wrong and hlsenc's
        // split threshold against `hls_time * vs->number` never fires
        // — the entire source ends up as a single segment. We use these
        // values as the destination time_base for `av_packet_rescale_ts`
        // on every packet in the pump loop.
        muxerVideoTimeBase = ctx.pointee.streams.advanced(by: 0).pointee!.pointee.time_base
        if audio != nil {
            muxerAudioTimeBase = ctx.pointee.streams.advanced(by: 1).pointee!.pointee.time_base
        }

        let audioDesc = audio.map { a -> String in
            let mode = a.bridge != nil ? "bridge" : "stream-copy"
            return " audio=\(mode) inTb=\(a.inputTimeBase.num)/\(a.inputTimeBase.den) muxerTb=\(muxerAudioTimeBase.num)/\(muxerAudioTimeBase.den)"
        } ?? ""
        EngineLog.emit(
            "[HLSSegmentProducer] muxer init OK (baseIndex=\(baseIndex), targetDur=\(hlsTimeStr)s, "
            + "srcTb=\(video.timeBase.num)/\(video.timeBase.den) "
            + "muxerTb=\(muxerVideoTimeBase.num)/\(muxerVideoTimeBase.den))"
            + audioDesc,
            category: .session
        )
    }

    deinit {
        cleanup()
    }

    // MARK: - Public API

    /// Start the read → write_frame pump on the worker queue.
    func start() {
        stateLock.lock()
        guard !pumpStarted else { stateLock.unlock(); return }
        pumpStarted = true
        stateLock.unlock()

        pumpQueue.async { [weak self] in
            self?.runPumpLoop()
        }
    }

    /// Signal the pump to stop at the next loop iteration. Async —
    /// the pump may be blocked inside `demuxer.readPacket` waiting on
    /// an HTTP byte-range read, which can take up to its own network
    /// timeout to return. Use `waitForFinish(timeout:)` if you need
    /// the pump to actually be gone before proceeding (the restart
    /// path does). Also wakes any pump currently parked in
    /// `cache.awaitFetchHighWater` so the restart path doesn't pay
    /// up to a second of latency waiting for the backpressure poll
    /// to time out on its own.
    func stop() {
        stateLock.lock()
        shouldStop = true
        stateLock.unlock()
        cache.wakeWaiters()
    }

    /// Thread-safe read of `shouldStop`. Used by the dispatchSinkOutput
    /// backpressure loop to poll for cancellation between short cache
    /// waits.
    fileprivate func checkShouldStop() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldStop
    }

    /// Block until the pump has exited or `timeout` elapses. Returns
    /// `true` if the pump finished, `false` on timeout (in which
    /// case the caller can choose to leak this instance and proceed
    /// with a fresh producer; the lingering pump will finish on its
    /// own once the demuxer read returns).
    func waitForFinish(timeout: TimeInterval) -> Bool {
        finishCondition.lock()
        defer { finishCondition.unlock() }
        if didFinishFlag { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while !didFinishFlag {
            if !finishCondition.wait(until: deadline) { return false }
        }
        return true
    }

    // MARK: - Pump

    private func runPumpLoop() {
        guard let ctx = formatContext else { return }

        let pumpStart = DispatchTime.now()
        var packetsRead = 0
        var packetsWritten = 0
        let lastError: Int32 = 0

        do {
            readLoop: while true {
                stateLock.lock()
                let stopRequested = shouldStop
                stateLock.unlock()
                if stopRequested { break readLoop }

                guard let packet = try demuxer.readPacket() else {
                    // EOF
                    break readLoop
                }
                packetsRead += 1
                var pktPtr: UnsafeMutablePointer<AVPacket>? = packet
                defer { av_packet_free(&pktPtr) }

                let pktStreamIdx = packet.pointee.stream_index

                // Repair unset dts. The matroska demuxer can emit
                // packets with `AV_NOPTS_VALUE` for dts on B-frames
                // even from the start of a session — MKV doesn't
                // store dts directly, FFmpeg reconstructs it from
                // ReferenceBlock relations, and that reconstruction
                // intermittently fails for non-leading B-frames.
                //
                // If we forward the NOPTS packet, FFmpeg's muxer
                // fills the missing dts with the stream's `cur_dts`
                // (last written) and the monotonic check fails with
                // `cur_dts >= cur_dts`, returning EINVAL. The
                // resulting segment is corrupt (a few KB instead of
                // 1 MB+) and AVPlayer rejects it with
                // CoreMediaErrorDomain -16046.
                //
                // The correct repair is `lastValidDts + 1` in the
                // source time_base. Using `pts` as a fallback is
                // tempting but WRONG for B-frames: pts is the
                // display timestamp and is BEHIND the packet's
                // decode-order position, so substituting pts as dts
                // produces `new_dts < cur_dts` and re-trips the
                // monotonic check (this was the regression that
                // showed up as e.g. `3280 >= 80` failures from the
                // very third packet of a fresh session, before any
                // seek had happened). `lastValidDts + 1` keeps the
                // packet flowing without violating monotonicity; the
                // next packet with a real dts re-anchors.
                let isVideoPkt = (pktStreamIdx == videoStreamIndex)
                let isAudioPkt = (audioConfig.map { pktStreamIdx == $0.sourceStreamIndex }) ?? false
                if packet.pointee.dts == Int64.min {
                    let anchor: Int64 = isVideoPkt ? lastVideoSourceDts
                                      : isAudioPkt ? lastAudioSourceDts
                                      : Int64.min
                    guard anchor != Int64.min else {
                        // No anchor yet on this stream — drop. Only
                        // possible for the very first packet of a
                        // session. The next packet will set the
                        // anchor for the rest of the run.
                        continue
                    }
                    packet.pointee.dts = anchor + 1
                    if packet.pointee.pts == Int64.min {
                        packet.pointee.pts = packet.pointee.dts
                    }
                }
                if isVideoPkt {
                    lastVideoSourceDts = packet.pointee.dts
                } else if isAudioPkt {
                    lastAudioSourceDts = packet.pointee.dts
                }

                // Subtitles, additional audio tracks, attachments,
                // unknown streams — dropped silently. Embedded
                // subtitles travel through a side Demuxer owned by
                // AetherEngine, not through this pump.
                if !isVideoPkt && !isAudioPkt {
                    continue
                }

                // Scan-forward gate. After a restart-seek the
                // matroska demuxer can land 100+ ms before the
                // requested target (libavformat's keyframe index is
                // wider than MKV's `Cues` table; non-Cue keyframes
                // aren't seekable). Drop incoming packets per stream
                // until the first one whose dts ≥ the recorded
                // target — and, for video, is a real keyframe so the
                // segment starts at a decodable boundary. Once each
                // stream's gate opens it stays open for the rest of
                // the producer session. Initial-start sessions
                // (baseIndex == 0) have both gates pre-opened so
                // this branch is a no-op for them.
                if isVideoPkt && !videoScanComplete {
                    let isKey = (packet.pointee.flags & 0x0001) != 0   // AV_PKT_FLAG_KEY
                    if isKey && packet.pointee.dts != Int64.min && packet.pointee.dts >= restartTargetVideoDts {
                        videoScanComplete = true
                        EngineLog.emit(
                            "[HLSSegmentProducer] video scan-forward complete: target=\(restartTargetVideoDts) "
                            + "landed=\(packet.pointee.dts) (off by \(packet.pointee.dts - restartTargetVideoDts))",
                            category: .session
                        )
                        // Fall through and write this packet.
                    } else {
                        continue
                    }
                }
                if isAudioPkt && !audioScanComplete {
                    if packet.pointee.dts != Int64.min && packet.pointee.dts >= restartTargetAudioDts {
                        audioScanComplete = true
                        EngineLog.emit(
                            "[HLSSegmentProducer] audio scan-forward complete: target=\(restartTargetAudioDts) "
                            + "landed=\(packet.pointee.dts) (off by \(packet.pointee.dts - restartTargetAudioDts))",
                            category: .session
                        )
                        // Fall through and write this packet.
                    } else {
                        continue
                    }
                }

                // Apply per-stream PTS shift to align fragment tfdt
                // with the playlist's cumulative-EXTINF origin.
                // Video shift = firstKeyframePts (subtracted), audio
                // shift = audio.start_time (subtracted). The shift
                // is a constant for the whole producer session so it
                // composes correctly with the scan-forward target.
                if isVideoPkt && videoShiftPts != 0 {
                    if packet.pointee.dts != Int64.min {
                        packet.pointee.dts -= videoShiftPts
                    }
                    if packet.pointee.pts != Int64.min {
                        packet.pointee.pts -= videoShiftPts
                    }
                }
                if isAudioPkt && audioShiftPts != 0 {
                    if packet.pointee.dts != Int64.min {
                        packet.pointee.dts -= audioShiftPts
                    }
                    if packet.pointee.pts != Int64.min {
                        packet.pointee.pts -= audioShiftPts
                    }
                }

                // Look-behind: hold the most recent video / stream-
                // copy-audio packet so the NEXT packet's dts can be
                // used to compute `pending.duration = next.dts -
                // pending.dts`. Many MKV remuxers (HandBrake / web-
                // rip pipelines) drop `DefaultDuration` and don't
                // write per-block `BlockDuration`, so the matroska
                // demuxer emits packets with `duration == 0`. The
                // mp4 sub-muxer in `mov_write_packet` reads
                // `pkt->duration` only for the LAST sample of each
                // fragment, which then writes `trun.last.duration =
                // 0` — the fragment stops one frame short of the
                // next fragment's `tfdt`, AVPlayer's HLS-fMP4
                // engine sees an unfillable gap, and the asset
                // parks on `WaitingToMinimizeStallsReason` and
                // never queues seg-N+1. Backfilling `duration` from
                // the successor's dts cleanly fixes this without
                // touching the demuxer or muxer code.
                if isVideoPkt {
                    if !loggedFirstVideoPktInfo {
                        loggedFirstVideoPktInfo = true
                        EngineLog.emit(
                            "[HLSSegmentProducer] first video pkt: "
                            + "dts=\(packet.pointee.dts) pts=\(packet.pointee.pts) "
                            + "duration=\(packet.pointee.duration) "
                            + "(fallback=\(videoFallbackDurationPts) in srcVideoTb)",
                            category: .session
                        )
                    }
                    if let prev = pendingVideoPkt {
                        finalizeAndWriteVideo(prev, nextDts: packet.pointee.dts, ctx: ctx)
                        packetsWritten += 1
                    }
                    pendingVideoPkt = packet
                    pktPtr = nil  // hand ownership to pendingVideoPkt; suppress defer-free
                    continue
                }

                // Audio path. Bridge audio (FLAC re-encode) emits
                // packets with the encoder's own duration set
                // correctly, so it bypasses the look-behind. Stream-
                // copy audio gets the same look-behind treatment as
                // video.
                if let audio = audioConfig, pktStreamIdx == audio.sourceStreamIndex {
                    if let bridge = audio.bridge {
                        let flacPackets: [UnsafeMutablePointer<AVPacket>]
                        do {
                            flacPackets = try bridge.feed(packet: packet)
                        } catch {
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio bridge.feed failed at pkt#\(packetsRead): \(error)",
                                category: .session
                            )
                            continue
                        }
                        for fp in flacPackets {
                            fp.pointee.stream_index = audioOutputStreamIndex
                            av_packet_rescale_ts(fp, audio.inputTimeBase, muxerAudioTimeBase)
                            _ = av_write_frame(ctx, fp)
                            var fpVar: UnsafeMutablePointer<AVPacket>? = fp
                            av_packet_free(&fpVar)
                        }
                        continue
                    }
                    // Stream-copy audio look-behind.
                    if let prev = pendingAudioPkt {
                        finalizeAndWriteAudio(prev, nextDts: packet.pointee.dts, audio: audio, ctx: ctx)
                    }
                    pendingAudioPkt = packet
                    pktPtr = nil
                    continue
                }
            }
        } catch {
            EngineLog.emit(
                "[HLSSegmentProducer] demuxer.readPacket threw: \(error)",
                category: .session
            )
        }

        // Flush look-behind pending packets. No successor packet
        // available so duration is set from the fallback (computed
        // from `avg_frame_rate` / `frame_size / sample_rate`). This
        // produces a tail-correct `trun` for the final fragment of
        // the source.
        if let prev = pendingVideoPkt {
            finalizeAndWriteVideo(prev, nextDts: nil, ctx: ctx)
            packetsWritten += 1
            pendingVideoPkt = nil
        }
        if let prev = pendingAudioPkt, let audio = audioConfig {
            finalizeAndWriteAudio(prev, nextDts: nil, audio: audio, ctx: ctx)
            pendingAudioPkt = nil
        }

        // Trailer flushes the final segment and writes the playlist;
        // our io_open trampoline still catches whatever bytes that
        // produces. Safe to call on partial / error exit too.
        let trailerRet = av_write_trailer(ctx)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - pumpStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit(
            "[HLSSegmentProducer] pump finished: packetsRead=\(packetsRead) "
            + "packetsWritten=\(packetsWritten) trailer=\(trailerRet) lastError=\(lastError) "
            + "elapsed=\(String(format: "%.0f", elapsedMs))ms cacheCount=\(cache.count)",
            category: .session
        )

        finishCondition.lock()
        didFinishFlag = true
        finishCondition.broadcast()
        finishCondition.unlock()
    }

    // MARK: - Look-behind finalize helpers

    /// Backfill `packet.duration` from `nextDts` (or the fallback
    /// computed from `avg_frame_rate` when there is no successor),
    /// run HDR10+ detection, rescale into muxer time_base, write
    /// via `av_write_frame`, then free the packet. Called from
    /// `runPumpLoop` exactly once per video packet — either when
    /// the next video packet arrives (`nextDts` set) or at EOF
    /// (`nextDts == nil`).
    private func finalizeAndWriteVideo(
        _ packet: UnsafeMutablePointer<AVPacket>,
        nextDts: Int64?,
        ctx: UnsafeMutablePointer<AVFormatContext>
    ) {
        if packet.pointee.duration <= 0 {
            if let next = nextDts {
                let inferred = next - packet.pointee.dts
                packet.pointee.duration = inferred > 0 ? inferred : videoFallbackDurationPts
            } else {
                packet.pointee.duration = videoFallbackDurationPts
            }
        }

        packet.pointee.stream_index = videoOutputStreamIndex

        if !hdr10PlusDetected, let data = packet.pointee.data {
            let size = Int(packet.pointee.size)
            if size >= 6 {
                let needle: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]
                let found = needle.withUnsafeBufferPointer { n -> Bool in
                    memmem(data, size, n.baseAddress, n.count) != nil
                }
                if found {
                    hdr10PlusDetected = true
                    onFirstHDR10PlusDetected?()
                }
            }
        }

        av_packet_rescale_ts(packet, sourceVideoTimeBase, muxerVideoTimeBase)
        _ = av_write_frame(ctx, packet)

        var pkt: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&pkt)
    }

    /// Same shape as `finalizeAndWriteVideo` but for stream-copy
    /// audio. Bridge audio doesn't pass through here — the FLAC
    /// encoder sets durations correctly.
    private func finalizeAndWriteAudio(
        _ packet: UnsafeMutablePointer<AVPacket>,
        nextDts: Int64?,
        audio: AudioConfig,
        ctx: UnsafeMutablePointer<AVFormatContext>
    ) {
        if packet.pointee.duration <= 0 {
            if let next = nextDts {
                let inferred = next - packet.pointee.dts
                packet.pointee.duration = inferred > 0 ? inferred : audioFallbackDurationPts
            } else {
                packet.pointee.duration = audioFallbackDurationPts
            }
        }

        packet.pointee.stream_index = audioOutputStreamIndex
        av_packet_rescale_ts(packet, audio.inputTimeBase, muxerAudioTimeBase)
        _ = av_write_frame(ctx, packet)

        var pkt: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&pkt)
    }

    // MARK: - IO trampoline plumbing (called from the C callbacks below)

    fileprivate func openSink(url: String) -> UnsafeMutablePointer<AVIOContext>? {
        let sink = SegmentSink(url: url)
        let opaque = Unmanaged.passRetained(sink).toOpaque()
        let bufSize: Int32 = 65536
        guard let raw = av_malloc(Int(bufSize)) else {
            Unmanaged<SegmentSink>.fromOpaque(opaque).release()
            return nil
        }
        let buf = raw.assumingMemoryBound(to: UInt8.self)
        guard let pb = avio_alloc_context(
            buf,
            bufSize,
            /* write_flag */ 1,
            opaque,
            nil,
            hlsProducerSinkWrite,
            nil
        ) else {
            av_free(raw)
            Unmanaged<SegmentSink>.fromOpaque(opaque).release()
            return nil
        }
        pb.pointee.seekable = 0
        return pb
    }

    fileprivate func closeSink(pb: UnsafeMutablePointer<AVIOContext>) {
        avio_flush(pb)
        let opaqueRaw = pb.pointee.opaque
        var data = Data()
        var url = ""
        if let opaque = opaqueRaw {
            let sink = Unmanaged<SegmentSink>.fromOpaque(opaque).takeRetainedValue()
            data = sink.buffer
            url = sink.url
        }
        // Free the buffer libavformat currently has on the context. It
        // may have been reallocated since openSink (avio grows it on
        // demand when callers write more than `bufSize` between flushes).
        if pb.pointee.buffer != nil {
            withUnsafeMutablePointer(to: &pb.pointee.buffer) { bufRef in
                bufRef.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) { raw in
                    av_freep(UnsafeMutableRawPointer(raw))
                }
            }
        }
        var pbVar: UnsafeMutablePointer<AVIOContext>? = pb
        avio_context_free(&pbVar)

        dispatchSinkOutput(url: url, data: data)
    }

    private func dispatchSinkOutput(url: String, data: Data) {

        if url == "init.mp4" {
            EngineLog.emit(
                "[HLSSegmentProducer] init.mp4 captured (\(data.count) B)",
                category: .session
            )
            cache.setInit(data)
            return
        }
        // "seg-N.m4s" — N is the hlsenc sequence number, which equals
        // (baseIndex + local segment count) when we set `start_number`.
        // Re-deriving from the filename keeps the cache key authoritative
        // even if hlsenc renumbers internally.
        if url.hasPrefix("seg-"), url.hasSuffix(".m4s") {
            let inner = url.dropFirst("seg-".count).dropLast(".m4s".count)
            if let absIdx = Int(inner) {
                // Backpressure FIRST, store SECOND. Doing the store
                // before the wait lets `pruneOutsideWindow` evict the
                // just-written segment whenever the cache window
                // hasn't slid to include `absIdx` yet (race window:
                // AVPlayer fetch latency greater than muxer cut
                // interval, e.g. H.264 with ~2-3 MB segments on a
                // local LAN where the muxer runs ahead of AVPlayer's
                // network reads). Waiting first keeps the window
                // centred such that every stored segment fits.
                //
                // Poll with short 1 s waits so `stop()` can shut us
                // down promptly during a restart instead of stranding
                // the pump in a 60 s sleep.
                let target = absIdx - Self.bufferAheadSegments
                while !checkShouldStop() {
                    if cache.awaitFetchHighWater(reaching: target, timeout: 1.0) { break }
                }
                if checkShouldStop() { return }

                EngineLog.emit(
                    "[HLSSegmentProducer] seg-\(absIdx).m4s captured (\(data.count) B)",
                    category: .session
                )
                cache.store(index: absIdx, data: data)
                return
            }
        }
        // playlist.m3u8 (or any other path) — we generate our own
        // playlist from the pre-planned keyframe segment list, so any
        // bytes hlsenc writes here are discarded.
    }

    // MARK: - Cleanup

    private func cleanup() {
        if let ctx = formatContext {
            // Clear opaque first so any late io_open from the muxer's
            // own teardown path doesn't dereference a self that's about
            // to disappear. (avformat_free_context shouldn't trigger
            // io_open at this point, but defensive.)
            ctx.pointee.opaque = nil
            avformat_free_context(ctx)
            formatContext = nil
        }
    }

    // MARK: - Helpers

    /// Equivalent of FFmpeg's `MKTAG(a, b, c, d)`. Encodes a four-character
    /// code as a little-endian `UInt32` (byte 0 = a, byte 3 = d).
    private static func mkTag(fromFourCC fourCC: String) -> UInt32? {
        let chars = Array(fourCC)
        guard chars.count == 4 else { return nil }
        var tag: UInt32 = 0
        for (i, ch) in chars.enumerated() {
            guard let ascii = ch.asciiValue else { return nil }
            tag |= UInt32(ascii) << (i * 8)
        }
        return tag
    }
}

// MARK: - Sink storage

private final class SegmentSink {
    let url: String
    var buffer = Data()
    init(url: String) { self.url = url }
}

// MARK: - C callback bridges

/// `s->io_open` trampoline. Routed back into the `HLSSegmentProducer`
/// via the `s->opaque` pointer set at construction. Returns a custom
/// `AVIOContext` whose write callback appends to a per-sink `Data`
/// buffer; the closeSink path drains that buffer into the `SegmentCache`.
private func hlsProducerIOOpen(
    s: UnsafeMutablePointer<AVFormatContext>?,
    pb: UnsafeMutablePointer<UnsafeMutablePointer<AVIOContext>?>?,
    url: UnsafePointer<CChar>?,
    flags: Int32,
    options: UnsafeMutablePointer<OpaquePointer?>?
) -> Int32 {
    guard let s = s, let pb = pb, let url = url, let opaque = s.pointee.opaque else {
        return -1
    }
    let producer = Unmanaged<HLSSegmentProducer>.fromOpaque(opaque).takeUnretainedValue()
    let urlStr = String(cString: url)
    guard let ctx = producer.openSink(url: urlStr) else { return -1 }
    pb.pointee = ctx
    return 0
}

/// `s->io_close2` trampoline. Drains the sink's accumulated buffer
/// into the producer's dispatch path and frees the `AVIOContext`.
private func hlsProducerIOClose2(
    s: UnsafeMutablePointer<AVFormatContext>?,
    pb: UnsafeMutablePointer<AVIOContext>?
) -> Int32 {
    guard let s = s, let pb = pb, let opaque = s.pointee.opaque else { return 0 }
    let producer = Unmanaged<HLSSegmentProducer>.fromOpaque(opaque).takeUnretainedValue()
    producer.closeSink(pb: pb)
    return 0
}

/// `avio_alloc_context` write callback. `opaque` is the retained
/// `SegmentSink` pointer set in `openSink`.
private func hlsProducerSinkWrite(
    opaque: UnsafeMutableRawPointer?,
    buf: UnsafePointer<UInt8>?,
    size: Int32
) -> Int32 {
    guard let opaque = opaque, let buf = buf, size > 0 else { return -1 }
    let sink = Unmanaged<SegmentSink>.fromOpaque(opaque).takeUnretainedValue()
    sink.buffer.append(buf, count: Int(size))
    return size
}
