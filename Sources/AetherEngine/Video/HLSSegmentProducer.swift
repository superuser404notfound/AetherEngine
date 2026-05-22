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
        /// Time base of *source* packets as they arrive from the
        /// demuxer, BEFORE the bridge re-stamps them. Used by the
        /// scan-forward gate to compare `packet.dts` (always in
        /// source TB) against the gate target — that target gets
        /// rescaled from videoSourceTB into this TB. For stream-copy
        /// this equals `inputTimeBase`; for the FLAC bridge it does
        /// NOT (inputTimeBase is the encoder TB 1/48000, while
        /// sourceTimeBase is whatever the demuxer reported, typically
        /// matroska's 1/1000). Pre-fix the gate rescaled into
        /// `inputTimeBase`, so for bridged DTS sources the target
        /// landed 48x further into the source than the video gate did
        /// — symptom was "audio starts ~44 s after video and stays
        /// drifted by exactly the same offset for the whole session".
        let sourceTimeBase: AVRational
        /// Optional decode-then-FLAC-encode bridge. Non-nil means the
        /// pump routes each source audio packet through `bridge.feed`
        /// and muxes the returned FLAC packets; nil means the source
        /// packet is muxed directly (stream-copy).
        let bridge: AudioBridge?
    }

    // MARK: - State

    /// The source demuxer the pump reads packets from. Owned by this
    /// producer for the session's lifetime.
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
    /// Video stream configuration (codecpar + time base + codec_tag
    /// override). Stored so each per-segment MP4SegmentMuxer can be
    /// built with the same parameters.
    private let videoConfig: StreamConfig

    /// Audio wiring info, nil for video-only sessions.
    private let audioConfig: AudioConfig?

    /// Boundaries (start PTS in source video TB) for every segment in
    /// the producer's range. `segmentBoundaries[i]` is the startPts of
    /// the segment at absolute index `baseIndex + i`. The pump uses
    /// this to decide when the current video packet has crossed into
    /// a new segment and the per-segment muxer needs to be cycled.
    private let segmentBoundaries: [Int64]

    /// Target segment duration in seconds. Passed to each per-segment
    /// MP4SegmentMuxer as the `frag_duration` defensive backstop;
    /// `+frag_keyframe` auto-cuts at keyframes so this rarely fires
    /// for our keyframe-aligned segments, but we still set it so a
    /// segment without a trailing IRAP doesn't sit unflushed.
    private let targetSegmentDurationSeconds: Double

    /// The mp4 muxer currently accumulating packets for one segment.
    /// Replaced each time the video pump crosses a segment boundary
    /// (per-segment teardown is the leak-free pattern that replaced
    /// the long-lived libavformat `hls` wrapper; see
    /// `MP4SegmentMuxer`'s class docstring).
    private var currentMuxer: MP4SegmentMuxer?

    /// Absolute index of the segment `currentMuxer` is writing.
    /// `Int.min` before the first muxer is created. Compared against
    /// each video packet's computed segment index to decide whether
    /// to finalize the current muxer and open a new one.
    private var currentMuxerSegmentIndex: Int = .min

    /// Latched once the first MP4SegmentMuxer has emitted its
    /// ftyp + moov bytes via FragmentSplitter. The captured bytes go
    /// to `cache.setInit`; subsequent muxers' init bytes are
    /// discarded because identical codec params + flags produce
    /// byte-equivalent output (modulo the mvhd creation_time drift,
    /// which AVPlayer ignores at fragment-level fetches once init.mp4
    /// is cached on its side).
    private var initCaptured: Bool = false

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
    /// demuxer doesn't supply `pkt->duration`. Defensive: most
    /// MKVs in production carry intact per-block durations, but
    /// some remuxer pipelines drop the TrackEntry `DefaultDuration`
    /// element AND don't write per-block `BlockDuration`, so every
    /// video packet arrives with `duration == 0`. FFmpeg's mp4
    /// sub-muxer reads `pkt->duration` only for the LAST sample of
    /// each fragment (intermediate sample durations come from
    /// `dts[i+1] - dts[i]`), so a missing duration would write
    /// `trun.last.sample_duration = 0` and the fragment would stop
    /// one frame short of the next fragment's `tfdt`.
    ///
    /// Computed from `videoStream.avg_frame_rate` at engine setup
    /// (see `HLSVideoEngine.makeProducer`); applied only when a
    /// pending packet's duration is zero AND no successor is
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
    /// when the source's per-block duration was missing. On EOF the
    /// pending packet is flushed using `*FallbackDurationPts`.
    private var pendingVideoPkt: UnsafeMutablePointer<AVPacket>?
    private var pendingAudioPkt: UnsafeMutablePointer<AVPacket>?

    private var loggedFirstVideoPktInfo = false
    /// One-shot log latches for the monotonic-dts repair. Bumps and
    /// drops both fire once per producer instance so the log shows
    /// the first occurrence without going noisy.
    private var loggedFirstDtsBump = false
    private var loggedFirstDtsDrop = false
    private var loggedFirstAudioDtsBump = false

    /// Scan-forward + dynamic-shift state. The static `restart*Target`
    /// fields are seeded from `plan[baseIndex]` for restart sessions
    /// (Int64.min for initial-start). The dynamic `firstActual*Dts`
    /// fields are filled in once the corresponding stream's gate
    /// opens — they record where the producer actually landed and
    /// determine the constant PTS shift applied to every subsequent
    /// packet on that stream.
    ///
    /// The gate logic uses `AV_PKT_FLAG_KEY` for video because
    /// libavformat's keyframe index can include non-IDR I-frames
    /// that aren't flagged as keyframes in the matroska block
    /// stream; starting a fragment on one of those would feed
    /// AVPlayer a non-decodable seg-N first sample. Audio doesn't
    /// have a keyframe concept (every audio frame is independently
    /// decodable in our supported codecs).
    ///
    /// Audio scan-forward is GATED on video scan-forward: for restart
    /// sessions audio waits until video's actual landing is known,
    /// then targets the same source-time position so the audio and
    /// video first samples come from the same scene in the source.
    /// Without this gating, audio scans to the playlist target
    /// independently of where video can actually land, and a
    /// non-IDR-keyframe miss in video puts video ~10 seconds later
    /// in source than audio — the symptom Vincent reported as
    /// "video läuft aber Ton setzt erst später ein und ist asynchron".
    private let restartTargetVideoDts: Int64
    private var restartTargetAudioDts: Int64
    private var audioWaitForVideo: Bool
    private var firstActualVideoDts: Int64 = Int64.min
    private var firstActualAudioDts: Int64 = Int64.min

    /// Source-TB pts of the first kept video packet (= the AV_PKT_FLAG_KEY
    /// packet that opened the video gate). Used to detect and drop pre-
    /// keyframe leading B-frames (HEVC RASL) that follow an open-GOP CRA:
    /// they have display-order pts before the CRA and reference frames
    /// from before it, so AVPlayer's HEVC decoder stalls on the first
    /// display sample if we let them through.
    private var firstActualVideoPts: Int64 = Int64.min
    private var loggedFirstLeadingDrop: Bool = false

    /// Diagnostic counters for the pre-gate drop loop. If the video
    /// gate never opens (no IDR found, or every IDR sits before the
    /// restart target dts), the pump silently reads + drops packets
    /// forever and AVPlayer sits in `waitingToPlay`. Counters surface
    /// the silent failure mode in the log so the user-visible "lädt
    /// unendlich" symptom maps to a concrete cause.
    private var pregateVideoDropCount: Int = 0
    private var pregateAudioDropCount: Int = 0
    private var lastPregateVideoLog: Int = 0
    private var lastPregateAudioLog: Int = 0
    private static let pregateLogInterval = 200

    /// Desired first-sample dts (in source TB) for each stream — the
    /// value the muxer's fragment `tfdt` will end up at after the
    /// dynamic shift is applied. Set at init to align with the
    /// playlist's cumulative-EXTINF origin for the segment we're
    /// producing:
    ///   - baseIndex == 0: desired = 0 (playlist origin).
    ///   - baseIndex > 0: desired = plan[baseIndex].startPts -
    ///     firstKeyframePts (= plan[baseIndex].startSeconds in source
    ///     TB).
    private let desiredFirstVideoTfdtPts: Int64
    private var desiredFirstAudioTfdtPts: Int64

    /// Dynamic PTS shift = `firstActualDts - desiredFirstTfdt`,
    /// computed once each stream's first kept packet arrives, applied
    /// to every subsequent packet on that stream so the fragment's
    /// `tfdt` lands at the desired value. Int64.min == "not yet
    /// computed".
    private var videoShiftPts: Int64 = Int64.min
    private var audioShiftPts: Int64 = Int64.min

    /// How many segments the pump is allowed to race ahead of the
    /// highest segment AVPlayer has actually fetched. Matches the
    /// SegmentCache's forwardWindow so the muxer never writes past
    /// the cache's forward edge. Cut from 20 to 10 alongside the
    /// SegmentCache window tightening — 4K HEVC at ~10 MB/seg made
    /// the old buffer 200 MB on its own.
    private static let bufferAheadSegments = 10

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

    /// Cumulative count of `av_write_frame` calls the pump has made for
    /// video packets. Promoted from a local `packetsWritten` in
    /// `runPumpLoop` to an instance var so the engine memprobe can
    /// observe pump throughput. Audio-bridge packets are not counted
    /// here (they go through a different write path).
    private let packetCounterLock = NSLock()
    private var _packetsWrittenCount: Int = 0
    var packetsWrittenCount: Int {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _packetsWrittenCount
    }
    private func bumpPacketsWritten() {
        packetCounterLock.lock()
        _packetsWrittenCount &+= 1
        packetCounterLock.unlock()
    }

    /// Lifetime fragment bytes the current muxer has emitted via the
    /// FragmentSplitter. Compared against observed RSS growth in the
    /// engine memprobe to attribute the long-form leak: if this counter
    /// climbs at the leak rate, libavformat is retaining the bytes
    /// somewhere reachable; if much slower, the leak is outside the
    /// muxer's output volume.
    var muxerLifetimeFragmentBytes: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentMuxer?.lifetimeFragmentBytesEmitted ?? 0
    }

    /// Number of successful fragment cuts the current muxer has done.
    /// Together with muxerLifetimeFragmentBytes this gives an average
    /// fragment size; divergence from the per-segment served bytes would
    /// flag a hidden secondary output.
    var muxerFragmentCuts: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentMuxer?.fragmentCutCount ?? 0
    }

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

    /// Fires once when the video gate opens, with the producer's
    /// videoShiftPts in source video time base units. Lets the engine
    /// translate AVPlayer's playlist clock back to source PTS for the
    /// independent side-demuxer subtitle reader (subtitle cues land in
    /// raw source PTS but AVPlayer.currentTime sits at
    /// `source_pts - videoShiftPts`). Re-fires on every producer
    /// restart since matroska seek imprecision can produce a different
    /// shift for the same source.
    var onVideoShiftKnown: (@Sendable (Int64) -> Void)?

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
        desiredFirstVideoTfdtPts: Int64,
        desiredFirstAudioTfdtPts: Int64 = 0,
        segmentBoundaries: [Int64]
    ) throws {
        self.demuxer = demuxer
        self.videoStreamIndex = videoStreamIndex
        self.videoConfig = video
        self.audioConfig = audio
        self.cache = cache
        self.baseIndex = baseIndex
        self.sourceVideoTimeBase = video.timeBase
        self.targetSegmentDurationSeconds = targetSegmentDurationSeconds
        self.segmentBoundaries = segmentBoundaries
        self.videoFallbackDurationPts = videoFallbackDurationPts
        self.audioFallbackDurationPts = audioFallbackDurationPts
        self.restartTargetVideoDts = restartTargetVideoDts
        // Audio scan target is set DYNAMICALLY once video scan
        // completes (= videoActualDts rescaled to audio TB), so the
        // first kept audio sample is from the same source-time as
        // the first video keyframe we land on.
        self.restartTargetAudioDts = Int64.min
        // Audio always waits for video, even on initial-start. The video
        // gate may skip leading non-key packets while scanning for the
        // first AV_PKT_FLAG_KEY (some MKV remuxes have a non-IDR first
        // packet, e.g. Bluey BD remuxes); if audio anchored itself at
        // its own first packet in the meantime, the two streams' first
        // kept sample would come from different source-times and play
        // back desynced by `firstVideoKeyDts - firstAudioDts` even
        // though their tfdts after shift both equal 0.
        self.audioWaitForVideo = true
        self.desiredFirstVideoTfdtPts = desiredFirstVideoTfdtPts
        self.desiredFirstAudioTfdtPts = desiredFirstAudioTfdtPts

        // Tell the source demuxer to drop every stream we don't read.
        // Without this the matroska demuxer parses + queues per-block
        // packets for the secondary audio + every PGS subtitle bitmap
        // (large per-frame payloads) that we then `continue` out of
        // the pump anyway — pure heap churn.
        var keep: Set<Int32> = [videoStreamIndex]
        if let audio = audio {
            keep.insert(audio.sourceStreamIndex)
        }
        demuxer.discardAllStreamsExcept(keep)

        let audioDesc = audio.map { a -> String in
            let mode = a.bridge != nil ? "bridge" : "stream-copy"
            return " audio=\(mode) inTb=\(a.inputTimeBase.num)/\(a.inputTimeBase.den)"
        } ?? ""
        EngineLog.emit(
            "[HLSSegmentProducer] init OK (baseIndex=\(baseIndex), "
            + "segments=\(max(0, segmentBoundaries.count - 1)), "
            + "targetDur=\(String(format: "%.3f", targetSegmentDurationSeconds))s, "
            + "srcVideoTb=\(video.timeBase.num)/\(video.timeBase.den))"
            + audioDesc,
            category: .session
        )
    }

    /// Map an absolute video PTS (in source video TB) to the segment
    /// index that contains it. Returns `baseIndex` for any pts before
    /// the first boundary (defensive: shouldn't happen post-gate);
    /// returns the last segment index for any pts past the last
    /// boundary.
    private func segmentIndex(forSourcePts pts: Int64) -> Int {
        guard !segmentBoundaries.isEmpty else { return baseIndex }
        // Linear scan is fine here — segmentBoundaries is at most
        // ~2k entries and this is called once per video packet on a
        // worker queue. Binary search would be premature.
        for i in 0..<(segmentBoundaries.count - 1) {
            if pts < segmentBoundaries[i + 1] {
                return baseIndex + i
            }
        }
        return baseIndex + max(0, segmentBoundaries.count - 2)
    }

    /// Make sure `currentMuxer` is the muxer for segment `targetIdx`.
    /// If a different segment's muxer is currently active, finalize
    /// it, adopt the resulting staging file into the cache, and
    /// allocate a fresh MP4SegmentMuxer for `targetIdx`. Also applies
    /// the producer's cache-window backpressure (the cache won't let
    /// us race more than `bufferAheadSegments` past the player's
    /// declared target).
    ///
    /// FORWARD-ONLY: callers may pass a `targetIdx` lower than the
    /// current muxer's segment when a packet's computed segment lags
    /// the producer's actual progress (HEVC leading B-frames after a
    /// CRA have PTS in the previous segment; FLAC bridge can emit
    /// packets a few frames behind the FIFO read cursor). Routing
    /// those packets backwards would finalize the current muxer
    /// prematurely and let `cache.adopt` overwrite the already-good
    /// segment with a partial one. Clamp upward: route the late
    /// packet into the current muxer instead. Tiny audio / B-frame
    /// timing offset at the boundary is within AVPlayer's tolerance.
    ///
    /// Returns the active muxer, or `nil` if a stop was requested
    /// during the backpressure wait or a new muxer alloc failed.
    private func ensureMuxer(forSegmentIndex targetIdx: Int) -> MP4SegmentMuxer? {
        let effectiveIdx = max(targetIdx, currentMuxerSegmentIndex)

        // Hot path: muxer exists AND currently writing the desired
        // segment.
        if let m = currentMuxer, m.currentSegmentIndex == effectiveIdx {
            return m
        }

        // First-time alloc: build the single session-wide muxer and
        // open its first segment's staging file.
        if currentMuxer == nil {
            return allocateMuxer(initialSegmentIndex: effectiveIdx)
        }

        // Forward boundary crossing on an existing muxer: trigger a
        // fragment cut. The muxer flushes the in-flight fragment to
        // the old segment's fd, adopts that file into the cache, and
        // rotates fd + currentSegmentIndex to the new segment.
        return advanceMuxer(to: effectiveIdx)
    }

    /// First-time allocation of the session's single mp4 muxer. Wires
    /// the init.mp4 callback so the cache gets seeded once.
    private func allocateMuxer(initialSegmentIndex: Int) -> MP4SegmentMuxer? {
        // Backpressure even on the first segment so the producer
        // doesn't try to allocate ahead of AVPlayer's declared target.
        let backpressureTarget = initialSegmentIndex - Self.bufferAheadSegments
        while !checkShouldStop() {
            if cache.awaitFetchHighWater(reaching: backpressureTarget, timeout: 1.0) { break }
        }
        if checkShouldStop() { return nil }

        let muxerVideo = MP4SegmentMuxer.VideoConfig(
            codecpar: videoConfig.codecpar,
            timeBase: videoConfig.timeBase,
            codecTagOverride: videoConfig.codecTagOverride
        )
        let muxerAudio: MP4SegmentMuxer.AudioConfig? = audioConfig.map { a in
            MP4SegmentMuxer.AudioConfig(codecpar: a.codecpar, timeBase: a.inputTimeBase)
        }

        do {
            let muxer = try MP4SegmentMuxer(
                initialSegmentIndex: initialSegmentIndex,
                sessionDir: cache.sessionDir,
                video: muxerVideo,
                audio: muxerAudio,
                targetSegmentDurationSeconds: targetSegmentDurationSeconds,
                onInitCaptured: { [weak self] initBytes in
                    guard let self = self else { return }
                    if !self.initCaptured {
                        self.initCaptured = true
                        self.cache.setInit(initBytes)
                        EngineLog.emit(
                            "[HLSSegmentProducer] init.mp4 captured (\(initBytes.count) B)",
                            category: .session
                        )
                        let label = self.audioConfig?.bridge != nil
                            ? "bridge-audio"
                            : "stream-copy-audio"
                        InitSegmentInspector.dumpAudioSampleEntry(
                            initBytes: initBytes,
                            sessionLabel: label
                        )
                    }
                }
            )
            self.currentMuxer = muxer
            self.currentMuxerSegmentIndex = initialSegmentIndex
            return muxer
        } catch {
            EngineLog.emit(
                "[HLSSegmentProducer] muxer alloc for seg-\(initialSegmentIndex) failed: \(error)",
                category: .session
            )
            return nil
        }
    }

    /// Cross a fragment boundary on the existing single-session muxer:
    /// trigger a fragment cut (= flush queued packets + close the
    /// completed segment's fd + open the next segment's fd), then
    /// apply the cache-window backpressure for the new index.
    private func advanceMuxer(to newIdx: Int) -> MP4SegmentMuxer? {
        guard let muxer = currentMuxer else { return nil }

        if let result = muxer.cutFragmentForNextSegment(newIdx) {
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(currentMuxerSegmentIndex).m4s captured (\(result.bytesWritten) B)",
                category: .session
            )
            cache.adopt(index: currentMuxerSegmentIndex,
                        stagingPath: result.path,
                        byteCount: result.bytesWritten)
        } else {
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(currentMuxerSegmentIndex).m4s cut failed; not adopted",
                category: .session
            )
        }
        currentMuxerSegmentIndex = newIdx

        // Producer backpressure for the new segment.
        let backpressureTarget = newIdx - Self.bufferAheadSegments
        while !checkShouldStop() {
            if cache.awaitFetchHighWater(reaching: backpressureTarget, timeout: 1.0) { break }
        }
        if checkShouldStop() { return nil }

        return muxer
    }

    /// Finalize the session-wide muxer at pump exit and adopt the
    /// final segment.
    private func finalizeSessionMuxerAndAdopt() {
        guard let muxer = currentMuxer else { return }
        let idx = currentMuxerSegmentIndex
        if let result = muxer.finalize() {
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(idx).m4s captured (\(result.bytesWritten) B)",
                category: .session
            )
            cache.adopt(index: idx, stagingPath: result.path,
                        byteCount: result.bytesWritten)
        } else {
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(idx).m4s final finalize failed; not adopted",
                category: .session
            )
        }
        currentMuxer = nil
        currentMuxerSegmentIndex = .min
    }

    deinit {
        // Defensive: if the pump was killed without running the
        // muxer-finalize path, finalize once more. The muxer's deinit
        // also closes its fd; this is belt-and-suspenders.
        if currentMuxer != nil {
            finalizeSessionMuxerAndAdopt()
        }
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
        let pumpStart = DispatchTime.now()
        var packetsRead = 0
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
                defer { trackedPacketFree(&pktPtr) }

                // Drop any AVPacket side data the demuxer attached
                // (matroska's BlockAddition path allocates side data
                // per packet for HDR10+ / DV RPU / generic
                // BlockAdditional payloads — see matroskadec.c
                // matroska_parse_block_additional, ~6 KB/HDR10+ entry
                // plus the AVPacketSideData struct + AVDictionary
                // overhead per allocation). For HEVC stream-copy the
                // metadata already lives in the bitstream as SEI NAL
                // units; the side data is redundant and the mp4 mux
                // path doesn't need it. Dropping it before any
                // downstream code touches the packet avoids the
                // matroska→muxer side-data copy cycle entirely. If
                // this knocks the residual leak rate down, matroska's
                // per-packet side-data allocations were the missing
                // piece beyond URLSession dispatch_data retention.
                av_packet_free_side_data(packet)

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
                    if anchor == Int64.min {
                        // No anchor yet on this stream — this is the
                        // very first packet. For keyframes (IDR / CRA)
                        // we can safely use pts as dts because in
                        // decode order pts == dts for sync samples; the
                        // pts-fallback hazard only applies to B-frames
                        // where pts is BEHIND decode-order position,
                        // and B-frames can't be the first packet of a
                        // GOP. Dropping the first IDR shifts seg-0
                        // onto the next IDR, which lands seg-0 with a
                        // different leading SEI sequence and (for
                        // DV-tagged HEVC) prevents AVPlayer's DV
                        // processor from initialising correctly:
                        // playback renders the IPT-PQ-c2 chroma as
                        // BT.709 YCbCr, producing the green/purple
                        // cast DrHurt reported in AetherEngine#4 for
                        // Build 154+. The Build 153 producer used
                        // pts-as-dts unconditionally and DV5 worked.
                        //
                        // For a non-keyframe first packet with NOPTS
                        // dts (no preceding anchor, no IDR to lean on),
                        // we still drop. Decode order can't be
                        // reconstructed from pts alone for B/P frames,
                        // and a corrupt seg-0 is a worse failure mode
                        // than a small drop at session start.
                        let isKey = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                        guard isKey, packet.pointee.pts != Int64.min else {
                            continue
                        }
                        packet.pointee.dts = packet.pointee.pts
                    } else {
                        packet.pointee.dts = anchor + 1
                        if packet.pointee.pts == Int64.min {
                            packet.pointee.pts = packet.pointee.dts
                        }
                    }
                }
                // Monotonic-dts enforcement at source TB. The matroska
                // demuxer's reconstructed dts can go non-monotonic
                // across HEVC open-GOP leading B-frames: after a
                // CRA, packet 2 arrives with NOPTS dts (we repair to
                // lastValid+1) and packet 3 arrives with a real dts
                // that's smaller than the repaired #2. FFmpeg's hls
                // muxer rejects the resulting non-monotonic packet
                // with "Application provided invalid, non monotonically
                // increasing dts to muxer", and the rejected leading
                // B-frame leaves a gap in the fmp4 fragment's sample
                // table. AVPlayer's HLS-fMP4 demuxer appears to react
                // to that gap with pathological internal buffer
                // management, which is the long-form 4K HDR HEVC
                // memory growth pattern we've been chasing.
                //
                // Bump to lastValid+1 when real dts goes backward,
                // but only if the bump doesn't push dts past pts
                // (dts <= pts is a hard invariant for the muxer).
                // If both checks fail, drop the packet (loses one
                // leading B-frame at most per CRA, acceptable).
                if isVideoPkt, lastVideoSourceDts != Int64.min,
                   packet.pointee.dts != Int64.min,
                   packet.pointee.dts <= lastVideoSourceDts {
                    let original = packet.pointee.dts
                    let bumped = lastVideoSourceDts + 1
                    let ptsValid = packet.pointee.pts != Int64.min
                    if !ptsValid || bumped <= packet.pointee.pts {
                        packet.pointee.dts = bumped
                        if !loggedFirstDtsBump {
                            loggedFirstDtsBump = true
                            EngineLog.emit(
                                "[HLSSegmentProducer] video dts non-monotonic at source: "
                                + "orig=\(original) lastValid=\(lastVideoSourceDts) "
                                + "pts=\(packet.pointee.pts) → bumped to \(bumped)",
                                category: .session
                            )
                        }
                    } else {
                        // Bump would violate dts<=pts. Drop the packet
                        // rather than feed the muxer a bad combo.
                        if !loggedFirstDtsDrop {
                            loggedFirstDtsDrop = true
                            EngineLog.emit(
                                "[HLSSegmentProducer] video dts unrecoverable, dropping: "
                                + "orig=\(original) lastValid=\(lastVideoSourceDts) "
                                + "pts=\(packet.pointee.pts)",
                                category: .session
                            )
                        }
                        continue
                    }
                }
                if isAudioPkt, lastAudioSourceDts != Int64.min,
                   packet.pointee.dts != Int64.min,
                   packet.pointee.dts <= lastAudioSourceDts {
                    // Same logic for audio. Audio doesn't have B-frame
                    // pts/dts skew so dts <= pts isn't a useful gate;
                    // just bump.
                    let original = packet.pointee.dts
                    packet.pointee.dts = lastAudioSourceDts + 1
                    if !loggedFirstAudioDtsBump {
                        loggedFirstAudioDtsBump = true
                        EngineLog.emit(
                            "[HLSSegmentProducer] audio dts non-monotonic at source: "
                            + "orig=\(original) lastValid=\(lastAudioSourceDts) → bumped to \(packet.pointee.dts)",
                            category: .session
                        )
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

                // Scan-forward + dynamic-shift gate.
                //
                // For restart sessions, the matroska demuxer's seek
                // can land 100+ ms before our target (libavformat's
                // keyframe index includes non-IDR keyframes that
                // the demuxer's own seek can't precisely reach). On
                // top of that, the keyframe at the planned position
                // may not be flagged with `AV_PKT_FLAG_KEY` in the
                // block stream — the libavformat index recorded it
                // as a keyframe via MKV `Cues`, but matroskadec sets
                // the packet flag from the SimpleBlock keyframe bit
                // which can be off. Scanning to the next IDR is
                // necessary to give AVPlayer a decodable start.
                //
                // Once the video gate opens at the next true IDR,
                // the audio gate is opened against the SAME source-
                // time so both streams' first kept packet comes from
                // the same scene. Dynamic shift = actual - desired
                // is then applied per-stream so the fragment's tfdt
                // lands at the playlist's cumulative-EXTINF origin
                // for this segment.
                //
                // Initial-start sessions (baseIndex == 0) still wait
                // for a true IDR before opening the gate. Trusting the
                // demuxer's first packet to be a sync sample broke on
                // files whose decode-order leading packet is not (some
                // Bluey MKV remuxes — first H.264 packet was dts=0
                // pts=33 without AV_PKT_FLAG_KEY, seg-0 was emitted
                // without a leading sync sample, AVPlayer rejected it
                // with -12860 and an indefinite NoItemToPlay stall).
                // The restart path's keyframe scan is the correct
                // behaviour for initial-start too; only the target
                // DTS check is restart-specific.
                if isVideoPkt {
                    if firstActualVideoDts == Int64.min {
                        // Always wait for a keyframe to open the gate.
                        //
                        // Restart sessions also enforce that the keyframe
                        // sits at or past `restartTargetVideoDts` so the
                        // segment we're building covers its planned range.
                        // Initial-start sessions used to trust the
                        // demuxer's first packet, which broke on files
                        // whose first decode-order video packet isn't a
                        // sync sample (some Bluey MKV remuxes — the
                        // gate opened on a non-key packet, seg-0 was
                        // produced without a leading sync sample, and
                        // AVPlayer rejected the asset with -12860 and
                        // `AVPlayerWaitingWithNoItemToPlay` followed by
                        // an indefinite stall).
                        let isKey = (packet.pointee.flags & 0x0001) != 0   // AV_PKT_FLAG_KEY
                        let targetSatisfied = restartTargetVideoDts == Int64.min
                            || (packet.pointee.dts != Int64.min && packet.pointee.dts >= restartTargetVideoDts)
                        guard isKey, targetSatisfied else {
                            pregateVideoDropCount += 1
                            if pregateVideoDropCount - lastPregateVideoLog >= Self.pregateLogInterval {
                                lastPregateVideoLog = pregateVideoDropCount
                                EngineLog.emit(
                                    "[HLSSegmentProducer] still waiting for video keyframe: "
                                    + "dropped=\(pregateVideoDropCount) "
                                    + "lastDts=\(packet.pointee.dts) isKey=\(isKey) "
                                    + "target=\(restartTargetVideoDts) "
                                    + "baseIndex=\(baseIndex)",
                                    category: .session
                                )
                            }
                            continue
                        }
                        firstActualVideoDts = packet.pointee.dts
                        firstActualVideoPts = packet.pointee.pts != Int64.min
                            ? packet.pointee.pts
                            : packet.pointee.dts
                        videoShiftPts = firstActualVideoDts - desiredFirstVideoTfdtPts
                        // Open the audio gate now that we know where
                        // video actually landed. Audio shift will be
                        // computed against the same desired tfdt so
                        // both streams' first sample lines up in
                        // source-time AND in muxer-time.
                        if audioWaitForVideo, let audio = audioConfig {
                            // Rescale into the *source* audio TB,
                            // because `packet.dts` on incoming audio
                            // packets is always in source TB — never
                            // in the bridge's encoder TB. Stream-copy
                            // happens to have sourceTimeBase ==
                            // inputTimeBase so the bug was invisible
                            // for AAC / EAC3 sources; the FLAC bridge
                            // exposes the mismatch and the gate target
                            // landed 48x too far into the source.
                            restartTargetAudioDts = av_rescale_q(
                                firstActualVideoDts,
                                sourceVideoTimeBase,
                                audio.sourceTimeBase
                            )
                            audioWaitForVideo = false
                        }
                        EngineLog.emit(
                            "[HLSSegmentProducer] video gate open: "
                            + "actual=\(firstActualVideoDts) "
                            + "anchorPts=\(firstActualVideoPts) "
                            + "target=\(restartTargetVideoDts) "
                            + "desired=\(desiredFirstVideoTfdtPts) "
                            + "shift=\(videoShiftPts)",
                            category: .session
                        )
                        onVideoShiftKnown?(videoShiftPts)
                    } else {
                        // Drop pre-keyframe leading B-frames (HEVC RASL).
                        // An open-GOP source can emit B-frames whose
                        // display-order pts is before the CRA that
                        // opened our gate. They reference pre-CRA
                        // frames not in our segment stream, so AVPlayer's
                        // HEVC decoder fails on the first display sample
                        // and the player stalls in waitingToPlay
                        // forever. Repro: Bombige Magenverstimmung
                        // (open-GOP HEVC, firstKeyframePts=88,
                        // CRA pts=172 with two leading B-frames at
                        // pts=88 and pts=131).
                        //
                        // Within a single GOP, only the leading region
                        // before the CRA has pts < CRA.pts; once we
                        // cross the next IDR/CRA, all subsequent
                        // packets have pts >= firstActualVideoPts and
                        // this check becomes a no-op for the rest of
                        // the session.
                        if firstActualVideoPts != Int64.min,
                           packet.pointee.pts != Int64.min,
                           packet.pointee.pts < firstActualVideoPts {
                            if !loggedFirstLeadingDrop {
                                loggedFirstLeadingDrop = true
                                EngineLog.emit(
                                    "[HLSSegmentProducer] drop pre-keyframe "
                                    + "leading B-frame: pts=\(packet.pointee.pts) "
                                    + "dts=\(packet.pointee.dts) "
                                    + "anchor=\(firstActualVideoPts) "
                                    + "(open-GOP RASL)",
                                    category: .session
                                )
                            }
                            continue
                        }
                    }
                }
                if isAudioPkt {
                    if audioWaitForVideo {
                        // Restart session, video scan hasn't completed
                        // yet — drop audio so audio doesn't anchor
                        // ahead of video.
                        pregateAudioDropCount += 1
                        if pregateAudioDropCount - lastPregateAudioLog >= Self.pregateLogInterval {
                            lastPregateAudioLog = pregateAudioDropCount
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio waiting for video gate: "
                                + "dropped=\(pregateAudioDropCount) "
                                + "lastDts=\(packet.pointee.dts) baseIndex=\(baseIndex)",
                                category: .session
                            )
                        }
                        continue
                    }
                    if restartTargetAudioDts != Int64.min && firstActualAudioDts == Int64.min {
                        guard packet.pointee.dts != Int64.min, packet.pointee.dts >= restartTargetAudioDts else {
                            pregateAudioDropCount += 1
                            if pregateAudioDropCount - lastPregateAudioLog >= Self.pregateLogInterval {
                                lastPregateAudioLog = pregateAudioDropCount
                                EngineLog.emit(
                                    "[HLSSegmentProducer] audio waiting for target dts: "
                                    + "dropped=\(pregateAudioDropCount) "
                                    + "lastDts=\(packet.pointee.dts) "
                                    + "target=\(restartTargetAudioDts) baseIndex=\(baseIndex)",
                                    category: .session
                                )
                            }
                            continue
                        }
                    }
                    if firstActualAudioDts == Int64.min {
                        firstActualAudioDts = packet.pointee.dts
                        audioShiftPts = firstActualAudioDts - desiredFirstAudioTfdtPts
                        EngineLog.emit(
                            "[HLSSegmentProducer] audio gate open: "
                            + "actual=\(firstActualAudioDts) "
                            + "target=\(restartTargetAudioDts) "
                            + "desired=\(desiredFirstAudioTfdtPts) "
                            + "shift=\(audioShiftPts)",
                            category: .session
                        )
                    }
                }

                // Apply the per-stream dynamic shift. After both
                // gates have opened, every subsequent packet on each
                // stream is shifted by its constant per-session
                // value so the muxer sees a contiguous, playlist-
                // aligned timeline.
                let activeShift: Int64 = isVideoPkt ? videoShiftPts : audioShiftPts
                if activeShift != Int64.min && activeShift != 0 {
                    if packet.pointee.dts != Int64.min {
                        packet.pointee.dts -= activeShift
                    }
                    if packet.pointee.pts != Int64.min {
                        packet.pointee.pts -= activeShift
                    }
                }

                // Look-behind: hold the most recent video / stream-
                // copy-audio packet so the NEXT packet's dts can be
                // used to compute `pending.duration = next.dts -
                // pending.dts`. Defensive against MKVs without
                // per-block durations (some remuxer pipelines drop
                // `DefaultDuration` and `BlockDuration` both) — in
                // that case the mp4 sub-muxer would write the
                // fragment's last `trun` entry with
                // `sample_duration = 0` and the fragment would
                // stop one frame short of the next fragment's
                // `tfdt`. Non-issue for sources with intact
                // durations: the look-behind branch is taken but
                // the backfill condition (`prev.duration == 0`)
                // never fires.
                if isVideoPkt {
                    if !loggedFirstVideoPktInfo {
                        loggedFirstVideoPktInfo = true
                        EngineLog.emit(
                            "[HLSSegmentProducer] first video pkt: "
                            + "dts=\(packet.pointee.dts) pts=\(packet.pointee.pts) "
                            + "duration=\(packet.pointee.duration) size=\(packet.pointee.size) "
                            + "(fallback=\(videoFallbackDurationPts) in srcVideoTb)",
                            category: .session
                        )
                    }
                    if let prev = pendingVideoPkt {
                        // Determine which segment `prev` belongs to.
                        // Use DTS, not PTS — HEVC open-GOP CRA emits
                        // leading B-frames whose display PTS sits in
                        // the previous segment (PTS < CRA.pts) even
                        // though their decode order is in the current
                        // segment. DTS is monotonic in decode order
                        // and segment boundaries (= IRAP keyframes)
                        // have DTS == PTS, so DTS-based lookup matches
                        // the segmentPlan exactly without the B-frame
                        // reorder false-positive.
                        let prevSeg = segmentIndex(forSourcePts: prev.pointee.dts)
                        if let muxer = ensureMuxer(forSegmentIndex: prevSeg) {
                            finalizeAndWriteVideo(prev, nextDts: packet.pointee.dts, muxer: muxer)
                            bumpPacketsWritten()
                        } else {
                            // Stop requested mid-pump; free the pending
                            // packet ourselves since it wasn't transferred
                            // to the muxer.
                            var pkt: UnsafeMutablePointer<AVPacket>? = prev
                            trackedPacketFree(&pkt)
                            pendingVideoPkt = nil
                            break readLoop
                        }
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
                            // FLAC packet pts is in audio inputTimeBase.
                            // Rescale to source video TB for the segment
                            // lookup so audio and video share one segmentation.
                            let fpPtsInVideoTb = av_rescale_q(
                                fp.pointee.pts,
                                audio.inputTimeBase,
                                sourceVideoTimeBase
                            )
                            let fpSeg = segmentIndex(forSourcePts: fpPtsInVideoTb)
                            guard let muxer = ensureMuxer(forSegmentIndex: fpSeg) else {
                                var fpVar: UnsafeMutablePointer<AVPacket>? = fp
                                trackedPacketFree(&fpVar)
                                continue
                            }
                            fp.pointee.stream_index = muxer.audioOutputStreamIndex
                            av_packet_rescale_ts(fp, audio.inputTimeBase, muxer.muxerAudioTimeBase)
                            _ = muxer.writePacket(fp)
                            var fpVar: UnsafeMutablePointer<AVPacket>? = fp
                            trackedPacketFree(&fpVar)
                        }
                        continue
                    }
                    // Stream-copy audio look-behind.
                    if let prev = pendingAudioPkt {
                        let prevPtsInVideoTb = av_rescale_q(
                            prev.pointee.pts,
                            audio.inputTimeBase,
                            sourceVideoTimeBase
                        )
                        let prevSeg = segmentIndex(forSourcePts: prevPtsInVideoTb)
                        if let muxer = ensureMuxer(forSegmentIndex: prevSeg) {
                            finalizeAndWriteAudio(prev, nextDts: packet.pointee.dts, audio: audio, muxer: muxer)
                        } else {
                            var pkt: UnsafeMutablePointer<AVPacket>? = prev
                            trackedPacketFree(&pkt)
                            pendingAudioPkt = nil
                            break readLoop
                        }
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
            // DTS-based lookup mirrors the in-loop site above; see
            // its comment for why this isn't `prev.pointee.pts`.
            let prevSeg = segmentIndex(forSourcePts: prev.pointee.dts)
            if let muxer = ensureMuxer(forSegmentIndex: prevSeg) {
                finalizeAndWriteVideo(prev, nextDts: nil, muxer: muxer)
                bumpPacketsWritten()
            } else {
                var pkt: UnsafeMutablePointer<AVPacket>? = prev
                trackedPacketFree(&pkt)
            }
            pendingVideoPkt = nil
        }
        if let prev = pendingAudioPkt, let audio = audioConfig {
            let prevPtsInVideoTb = av_rescale_q(
                prev.pointee.pts,
                audio.inputTimeBase,
                sourceVideoTimeBase
            )
            let prevSeg = segmentIndex(forSourcePts: prevPtsInVideoTb)
            if let muxer = ensureMuxer(forSegmentIndex: prevSeg) {
                finalizeAndWriteAudio(prev, nextDts: nil, audio: audio, muxer: muxer)
            } else {
                var pkt: UnsafeMutablePointer<AVPacket>? = prev
                trackedPacketFree(&pkt)
            }
            pendingAudioPkt = nil
        }

        // Finalize the session-wide muxer's final segment so its
        // bytes land in the cache. write_trailer also fires inside
        // finalize() for the libavformat-side cleanup.
        finalizeSessionMuxerAndAdopt()
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - pumpStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit(
            "[HLSSegmentProducer] pump finished: packetsRead=\(packetsRead) "
            + "packetsWritten=\(packetsWrittenCount) lastError=\(lastError) "
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
    /// run HDR10+ detection, rescale into the muxer's video time_base,
    /// write via `MP4SegmentMuxer.writePacket`, then free the packet.
    /// Called from `runPumpLoop` exactly once per video packet —
    /// either when the next video packet arrives (`nextDts` set) or
    /// at EOF (`nextDts == nil`).
    private func finalizeAndWriteVideo(
        _ packet: UnsafeMutablePointer<AVPacket>,
        nextDts: Int64?,
        muxer: MP4SegmentMuxer
    ) {
        if packet.pointee.duration <= 0 {
            if let next = nextDts {
                let inferred = next - packet.pointee.dts
                packet.pointee.duration = inferred > 0 ? inferred : videoFallbackDurationPts
            } else {
                packet.pointee.duration = videoFallbackDurationPts
            }
        }

        packet.pointee.stream_index = muxer.videoOutputStreamIndex

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

        av_packet_rescale_ts(packet, sourceVideoTimeBase, muxer.muxerVideoTimeBase)
        _ = muxer.writePacket(packet)

        var pkt: UnsafeMutablePointer<AVPacket>? = packet
        trackedPacketFree(&pkt)
    }

    /// Same shape as `finalizeAndWriteVideo` but for stream-copy
    /// audio. Bridge audio doesn't pass through here — the FLAC
    /// encoder sets durations correctly.
    private func finalizeAndWriteAudio(
        _ packet: UnsafeMutablePointer<AVPacket>,
        nextDts: Int64?,
        audio: AudioConfig,
        muxer: MP4SegmentMuxer
    ) {
        if packet.pointee.duration <= 0 {
            if let next = nextDts {
                let inferred = next - packet.pointee.dts
                packet.pointee.duration = inferred > 0 ? inferred : audioFallbackDurationPts
            } else {
                packet.pointee.duration = audioFallbackDurationPts
            }
        }

        packet.pointee.stream_index = muxer.audioOutputStreamIndex
        av_packet_rescale_ts(packet, audio.inputTimeBase, muxer.muxerAudioTimeBase)
        _ = muxer.writePacket(packet)

        var pkt: UnsafeMutablePointer<AVPacket>? = packet
        trackedPacketFree(&pkt)
    }

}
