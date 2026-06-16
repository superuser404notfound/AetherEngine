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
        /// Strip the source's Dolby Vision configuration record before
        /// `avformat_write_header`. Forwarded to the muxer for paths
        /// where the engine has chosen to play a DV source as plain
        /// HEVC HDR10 (P7 today). See
        /// `MP4SegmentMuxer.VideoConfig.stripDolbyVisionMetadata`.
        let stripDolbyVisionMetadata: Bool
        /// Optional color-signaling override forwarded to the muxer.
        /// See `MP4SegmentMuxer.ColorOverride`.
        let colorOverride: MP4SegmentMuxer.ColorOverride?
        /// Optional replacement for the source's `codecpar.extradata`
        /// before `avformat_write_header`. See
        /// `MP4SegmentMuxer.VideoConfig.extradataOverride`.
        let extradataOverride: [UInt8]?

        init(
            codecpar: UnsafePointer<AVCodecParameters>,
            timeBase: AVRational,
            codecTagOverride: String?,
            stripDolbyVisionMetadata: Bool = false,
            colorOverride: MP4SegmentMuxer.ColorOverride? = nil,
            extradataOverride: [UInt8]? = nil
        ) {
            self.codecpar = codecpar
            self.timeBase = timeBase
            self.codecTagOverride = codecTagOverride
            self.stripDolbyVisionMetadata = stripDolbyVisionMetadata
            self.colorOverride = colorOverride
            self.extradataOverride = extradataOverride
        }
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
        /// True when the source is AAC carried as ADTS (the typical shape
        /// out of an MPEG-TS feed: no AudioSpecificConfig in `extradata`,
        /// a 7/9-byte ADTS header on every frame). To stream-copy that into
        /// fMP4 the pump must strip the ADTS header from each packet; the
        /// engine separately synthesises the ASC into the muxer codecpar so
        /// the `mp4a`/`esds` sample entry is well-formed. Without this the
        /// mux write_header fails (EINVAL) and the channel falls back to the
        /// lossy FLAC bridge. Only set for the stream-copy AAC path.
        let stripAacAdts: Bool

        init(codecpar: UnsafePointer<AVCodecParameters>,
             timeBase: AVRational,
             sourceStreamIndex: Int32,
             inputTimeBase: AVRational,
             sourceTimeBase: AVRational,
             bridge: AudioBridge?,
             stripAacAdts: Bool = false) {
            self.codecpar = codecpar
            self.timeBase = timeBase
            self.sourceStreamIndex = sourceStreamIndex
            self.inputTimeBase = inputTimeBase
            self.sourceTimeBase = sourceTimeBase
            self.bridge = bridge
            self.stripAacAdts = stripAacAdts
        }
    }

    // MARK: - State

    /// The source demuxer the pump reads packets from. Owned by this
    /// producer for the session's lifetime.
    private let demuxer: Demuxer

    /// Optional SECOND demuxer carrying the audio of a demuxed-audio
    /// HLS ingest (video-only variant + separate audio rendition,
    /// ARD-style). When non-nil, the pump pull-merges packets from both
    /// demuxers by DTS (see `readNextSourcePacket`) and classifies audio
    /// by ORIGIN instead of stream index: the side demuxer's stream
    /// numbering is independent of the main demuxer's, so its audio
    /// index can collide with the main video index. Owned by
    /// HLSVideoEngine (which closes it in stop()); the producer only
    /// reads from it. nil for every muxed-audio session, in which case
    /// the pump behaves exactly as before.
    private let sideAudioDemuxer: Demuxer?

    /// One-packet lookahead per source for the dual-demuxer pull-merge.
    /// `readNextSourcePacket` keeps both filled and yields the lower-DTS
    /// one, so packets enter the (single) downstream pipeline in global
    /// decode order even though they come from two independent FIFOs.
    /// Freed in the pump's exit path when the loop breaks between fills.
    private var mergeMainLookahead: UnsafeMutablePointer<AVPacket>?
    private var mergeSideLookahead: UnsafeMutablePointer<AVPacket>?

    /// Synthesized timestamp clock for PACKED side audio (Apple HLS
    /// packed audio: raw ADTS AAC rendition). FFmpeg's raw "aac"
    /// demuxer puts the stream on its own zero-based clock and never
    /// sees Apple's ID3 PRIV program-clock anchor, so its timestamps
    /// would break the DTS merge ordering and strand the audio gate in
    /// the wrong clock domain. Instead the clock starts at the PRIV
    /// timestamp (rescaled into the side stream's time base by the
    /// engine) and advances by each packet's duration, putting the
    /// synthesized pts/dts on the same 90 kHz program clock as the
    /// video, exactly like a TS companion's real timestamps. Pulled out
    /// as a struct so the accumulation is unit-testable.
    struct PackedAudioSynthClock {
        /// Next pts/dts to stamp, in the side audio stream's time base.
        private(set) var nextPts: Int64
        /// Advance for packets whose demuxer duration is missing or
        /// zero: one AAC frame (1024 samples) in the stream time base,
        /// computed by the engine from the stream's sample rate.
        let fallbackDurationPts: Int64

        init(startPts: Int64, fallbackDurationPts: Int64) {
            self.nextPts = startPts
            self.fallbackDurationPts = max(1, fallbackDurationPts)
        }

        /// Timestamp for the current packet; advances the clock by the
        /// packet's own duration when valid, else by the fallback.
        mutating func stamp(packetDuration: Int64) -> Int64 {
            let pts = nextPts
            nextPts += packetDuration > 0 ? packetDuration : fallbackDurationPts
            return pts
        }
    }

    /// Non-nil only for packed side-audio sessions (see the struct doc).
    private var packedSideAudioClock: PackedAudioSynthClock?
    /// EOF latches per merge source. The first EOF on EITHER source ends
    /// the merged stream: a healthy live rendition never EOFs, and
    /// draining the survivor alone would produce a silent (or frozen)
    /// tail the engine cannot recover from. Ending the pump routes into
    /// the same host-retune path as a main-source loss.
    private var mergeMainEOF = false
    private var mergeSideEOF = false
    // Not `let`: an SSAI ad creative is authored with a different video
    // PID than the program, so libavformat hands its video on a fresh
    // stream index mid-pump. The live loop re-points this at the new
    // video stream (see the SSAI program-switch detection in the read
    // loop) so the ad's video keeps flowing instead of being dropped as
    // a foreign stream.
    private var videoStreamIndex: Int32
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

    /// Live mode. When true the pump ignores `segmentBoundaries` /
    /// `segmentIndex(forSourcePts:)` and instead cuts a new segment at
    /// each video keyframe once `targetSegmentDurationSeconds` of source
    /// time has elapsed since the current segment opened. Finalized
    /// segments are reported via `onLiveSegmentFinalized` so the provider
    /// can grow its playlist. The EOF break stays as a safety net but a
    /// genuine live feed never reaches it. VOD leaves this false.
    private let isLive: Bool

    /// Absolute index of the segment the live cutter is currently filling.
    /// Starts at `baseIndex` (0 for live) when the first video keyframe
    /// opens segment 0; advances by one on each keyframe-driven cut.
    private var liveCurrentSegmentIndex: Int

    /// Source-PTS (seconds) at which the current live segment opened (=
    /// the keyframe that started it). The next keyframe whose pts is at
    /// least `targetSegmentDurationSeconds` past this triggers a cut.
    private var liveSegmentStartPtsSeconds: Double = 0

    /// Whether the live cutter has opened its first segment yet (set when
    /// the first video keyframe arrives post-gate). Until then there is no
    /// current segment and the first keyframe opens segment 0 without a
    /// cut.
    private var liveFirstSegmentOpened = false

    /// Per-index start-PTS (seconds) of each live segment the cutter has
    /// opened, so a fragment cut / final finalize can report the finished
    /// segment's `[startSeconds, duration]` to the provider. Entries are
    /// removed once reported to keep the map bounded over a long session.
    private var liveSegmentStartByIndex: [Int: Double] = [:]

    /// Fires once per finalized live segment (cut or EOF), SYNCHRONOUSLY
    /// ON the pump thread (via advanceMuxer -> reportLiveSegmentFinalized),
    /// with the segment's absolute index, measured duration in
    /// seconds, start-PTS in seconds, and a `discontinuous` flag (true when
    /// the segment opened at a detected program-boundary PTS jump). The
    /// engine wires this to the provider's `appendLiveSegment` so the
    /// growing playlist exposes the segment, with `#EXT-X-DISCONTINUITY`
    /// prefixed on the boundary segment. Live-only; nil for VOD.
    /// The callee must therefore be lock-safe and must not block
    /// (appendLiveSegment is; a blocking callee would stall the pump).
    var onLiveSegmentFinalized: (@Sendable (Int, Double, Double, Bool) -> Void)?

    /// Live PTS-discontinuity detection. A real broadcast / IPTV feed can
    /// cross a program boundary where the source PTS leaps (forward or
    /// backward) well beyond normal frame spacing and codec params may
    /// change. We track the previous video packet's RAW source PTS (before
    /// any shift) and the per-frame spacing, and flag a discontinuity when
    /// the next video packet's PTS deviates from the expected continuation
    /// by more than `discontinuityThresholdSeconds`. This is DISTINCT from
    /// the NOPTS-dts repair (which operates on dts at the +1-tick scale,
    /// far below this threshold) and from the keyframe gate: it only fires
    /// on a genuine multi-second leap.
    ///
    /// 10 s is the threshold: orders of magnitude above any frame interval
    /// (≤ ~40 ms) or the look-behind duration inference, and well below the
    /// synthetic +1000 s test jump, so it never trips on normal advance but
    /// always catches a program boundary.
    static let discontinuityThresholdSeconds: Double = 10.0

    /// Tighter rebase threshold for BACKWARD source-clock jumps. A live
    /// source's clock only advances within a program, so any backward leap
    /// past the small-glitch ceiling (matroska B-frame reconstruction,
    /// <= 0.5 s, handled by the monotonic gate) is a program discontinuity,
    /// not jitter. The forward threshold stays at 10 s (a forward gap can be
    /// benign buffering). The 10 s symmetric threshold left a dead zone:
    /// SHORT SSAI elements (e.g. a 5 s ad bumper between the ad pod and the
    /// returning program) reset the clock by only ~5 s, so neither the
    /// monotonic gate (> 0.5 s) nor the rebase (< 10 s) fired. The stream
    /// then kept the old shift across the reset, overlapping the new element
    /// against the last one by seconds: video froze on the bumper's last
    /// frame and the audio splice flooded OutputTimestampSanitizer with
    /// hundreds of 1-tick-collapsed packets (audible stutter). Catching
    /// backward jumps at 1.5 s rebases those short elements cleanly.
    static let discontinuityBackwardThresholdSeconds: Double = 1.5

    /// The audio stream's per-session shift across an SSAI program boundary,
    /// derived so the audio boundary packet lands exactly on the video seam
    /// output. Output dts = srcDts - shift, so a shift of
    /// `audioBoundarySrcDts - seamOutAudioTb` makes the boundary packet's
    /// output equal `seamOutAudioTb` (the video seam, in audio TB) for ANY
    /// audio source base. This is the fix for amux ad creatives, which mux
    /// audio on a different source clock than video (Pluto: video from 0,
    /// audio near 2^33): copying the video's shift verbatim would offset
    /// audio by that base difference and hang it ~2^33 ticks in the future.
    static func seamDerivedAudioShift(
        audioBoundarySrcDts: Int64,
        seamOutAudioTb: Int64
    ) -> Int64 {
        audioBoundarySrcDts - seamOutAudioTb
    }

    /// Previous video packet's RAW source PTS (source video TB), before the
    /// dynamic shift is applied. `Int64.min` until the first post-gate video
    /// packet. Used only in live mode to detect the program-boundary leap.
    private var lastRawVideoPts: Int64 = Int64.min

    /// When the live cutter next opens a segment, mark it discontinuous so
    /// the playlist builder prefixes it with `#EXT-X-DISCONTINUITY`. Latched
    /// on detection, consumed (cleared) when the next segment opens.
    private var pendingDiscontinuityFlag: Bool = false

    /// Latched alongside `pendingDiscontinuityFlag` when a live timeline
    /// rebase fires. Makes the keyframe cutter cut at the NEXT keyframe
    /// regardless of the 4 s minimum-duration condition. Without this the
    /// splice usually lands mid-segment (the cutter only cuts at a
    /// keyframe >= target duration past the segment start), so the
    /// #EXT-X-DISCONTINUITY tag would arrive one segment late while the
    /// boundary segment itself mixes old- and new-program content.
    private var pendingForceCutFlag: Bool = false

    /// Latched when an SSAI program switch re-points `videoStreamIndex` at
    /// a new video PID whose codec params (SPS/resolution) differ. The next
    /// segment that opens must start a FRESH muxer so a new init segment is
    /// captured and the playlist emits a per-discontinuity EXT-X-MAP for it
    /// (versioned-init path). Consumed when that segment opens.
    private var pendingVideoProgramSwitch: Bool = false

    /// The ad creative's video config parsed from its keyframe's in-band
    /// SPS/PPS at the program switch (the mid-stream demuxer codecpar is
    /// unparsed, width/height == 0). Used to build the rotation muxer:
    /// explicit dimensions + Annex-B extradata the mov muxer packs into
    /// avcC. Set with `pendingVideoProgramSwitch`, consumed at the rotation.
    private var pendingAdVideoConfig: (width: Int32, height: Int32, extradata: [UInt8])?

    /// Cross-stream rebase pairing. A program boundary jumps the shared
    /// MPEG-TS source clock on BOTH streams, but the content gap at the
    /// splice is rarely symmetric (audio lead-out / silence / dropped
    /// corrupt packets differ per stream). Rebasing each stream
    /// independently "one frame past its own last output" collapses each
    /// stream's gap separately, turning the asymmetry into a PERMANENT
    /// A/V offset for the rest of the program. The video rebase is the
    /// master: when video rebases, the audio adopts the video's ABSOLUTE
    /// shift (rescaled into the audio time base), NOT a relative delta.
    /// Both streams are 90 kHz here, so an equal shift makes the output
    /// A/V offset exactly the intrinsic source skew, every boundary,
    /// independent of history. The earlier delta-based handoff
    /// (audio += video's per-boundary delta) preserved whatever offset
    /// already existed, so a sub-frame splice error at one creative was
    /// carried into the next and ACCUMULATED across a long ad pod (audio
    /// drifted further and further behind, the device symptom). Absolute
    /// re-anchoring zeroes that: each boundary snaps audio back onto
    /// video, and OutputTimestampSanitizer absorbs the lone sub-frame
    /// output overlap at the seam.
    ///
    /// The handoff carries the seam's OUTPUT dts (the position on the
    /// unified output timeline where the new program begins), NOT the
    /// video shift. An SSAI ad creative can mux its audio on a DIFFERENT
    /// source clock than its video (Pluto's amux ads start the video at
    /// source dts 0 but the amux audio near 2^33), so the two streams do
    /// not share a source base across the boundary. Handing audio the
    /// video's shift verbatim would then offset audio by the base
    /// difference (audio launched ~2^33 ticks into the future, the audio
    /// hangs). Instead audio derives its own shift from its OWN boundary
    /// srcDts and the shared seam output position
    /// (`audioShift = audioBoundarySrcDts - seamOutAudioTb`), which snaps
    /// audio onto the video timeline regardless of source base.
    ///
    /// `pendingAudioInheritSeamOut` is the seam output dts (audio TB)
    /// waiting for the audio stream's own boundary packet (video usually
    /// crosses first; a transient double-rebase just overwrites it, latest
    /// seam wins). `lastIndependentAudioRebase` records an audio rebase
    /// that fired BEFORE the video one (packet interleave can deliver the
    /// first new-program audio packet early), keeping that boundary
    /// packet's srcDts; the subsequent video rebase then re-derives the
    /// audio shift from it and the seam via `pendingAudioShiftOverride`,
    /// applied at the next audio packet. All pairing state expires after
    /// `rebasePairingWindowSeconds` so a stale half-boundary can never
    /// poison a later, unrelated one.
    private var pendingAudioInheritSeamOut: (seamOutAudioTb: Int64, at: Date)? = nil
    private var lastIndependentAudioRebase: (boundarySrcDts: Int64, at: Date)? = nil
    private var pendingAudioShiftOverride: (seamOutAudioTb: Int64, boundarySrcDts: Int64, at: Date)? = nil
    private static let rebasePairingWindowSeconds: TimeInterval = 5.0

    /// Last in-band video extradata observed via
    /// AV_PKT_DATA_NEW_EXTRADATA (live only). Used to deduplicate the
    /// codec-parameter-change detection: some demuxers re-emit identical
    /// extradata side data periodically.
    private var lastSeenVideoExtradata: Data? = nil
    /// Number of distinct in-band extradata changes seen this session.
    private var codecParamChangeCount = 0

    /// Per-index discontinuity flag for live segments the cutter has opened.
    /// Mirrors `liveSegmentStartByIndex`'s lifetime: set when the segment
    /// opens, read + removed when the segment is reported to the provider.
    private var liveSegmentDiscontinuousByIndex: [Int: Bool] = [:]

    /// One-shot log latch for the first detected discontinuity.
    private var loggedFirstDiscontinuity: Bool = false

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

    /// First source dts ever seen per stream in THIS producer session.
    /// Replay detection: after an unplanned reader reconnect, a backward
    /// rebase whose target lands at or below this value (plus a small
    /// window) means the server re-served the stream from its beginning
    /// rather than continuing "from now". A genuine program-boundary PTS
    /// reset lands at an arbitrary new origin and is NOT correlated with
    /// a reconnect, so it never trips this.
    private var firstSeenVideoSourceDts: Int64 = Int64.min
    private var firstSeenAudioSourceDts: Int64 = Int64.min

    /// How recently an unplanned reader reconnect must have happened for
    /// a backward PTS reset to count as a server-side replay. The
    /// reconnect and the first replayed packets arrive within seconds of
    /// each other (the demuxer's internal buffering adds at most a few
    /// seconds of old data in between).
    private static let sourceReplayReconnectWindowSeconds: TimeInterval = 30

    /// How close (in stream time) to the session's first-seen dts the
    /// reset must land to count as a replay-from-start.
    private static let sourceReplayStartWindowSeconds: Double = 10

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

    /// Live-mode segment index assigned to `pendingVideoPkt` /
    /// `pendingAudioPkt` at the moment that packet was examined (the
    /// live cutter advances at keyframe boundaries, so the index has to
    /// be captured then, not recomputed when the look-behind flushes the
    /// pending packet). Unused for VOD.
    private var pendingVideoSegIndex: Int = 0
    private var pendingAudioSegIndex: Int = 0

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

    /// Counter for forward-only producer restarts triggered by
    /// HLSVideoEngine. Surfaced via the engine's live telemetry so the
    /// stats overlay can show how aggressively AVPlayer is re-priming
    /// segment requests after scrubs. Reset to 0 on every new session
    /// (each producer instance is per-session).
    ///
    /// Written on the pump thread, read by the telemetry sampler:
    /// guarded by `packetCounterLock` like the packet counters.
    var restartCount: Int {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _restartCount
    }
    private var _restartCount: Int = 0
    func bumpRestartCount() {
        packetCounterLock.lock()
        _restartCount &+= 1
        packetCounterLock.unlock()
    }

    /// Most recently measured open-audio-gate vs. open-video-gate gap,
    /// in source-clock milliseconds. Already computed inline for the
    /// existing log line at the gap-detection site; stored here so the
    /// engine memprobe and the live telemetry sampler can read it
    /// without re-deriving it. Same cross-thread shape as
    /// `restartCount`, same lock.
    var lastAVGapMs: Double {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _lastAVGapMs
    }
    private var _lastAVGapMs: Double = 0
    private func setLastAVGapMs(_ value: Double) {
        packetCounterLock.lock()
        _lastAVGapMs = value
        packetCounterLock.unlock()
    }

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
    /// Wall-clock start of the video keyframe-gate wait (first dropped
    /// pre-gate packet). Live sessions bound the wait with
    /// `liveKeyframeGateTimeoutSeconds`; see the gate for rationale.
    private var pregateWaitStart: Date?
    private static let liveKeyframeGateTimeoutSeconds: TimeInterval = 15

    /// Wall-clock start of the audio target-gate wait (first dropped
    /// pre-gate audio packet). Live sessions bound the wait with
    /// `liveAudioGateTimeoutSeconds`: a backward source-clock reset
    /// between video gate-open and the first kept audio packet strands
    /// the target in the old clock domain (permanent silence otherwise).
    /// 5 s is generous; the gap the gate bridges is normally < 100 ms of
    /// interleave.
    private var audioGateWaitStart: Date?
    private static let liveAudioGateTimeoutSeconds: TimeInterval = 5
    private var pregateAudioDropCount: Int = 0

    /// Wall-clock of the last finalized live segment. Drives the
    /// no-cut stall watchdog: while the pump keeps reading packets but
    /// finalizes no segment for `liveSegmentStallTimeoutSeconds`, the
    /// cutter is wedged (hostile SSAI ad pod) and the pump exits with
    /// `.segmentStall` so the host can retune to the server route.
    /// nil until the first segment is finalized (startup has its own
    /// gates); set on every `reportLiveSegmentFinalized`.
    private var lastLiveSegmentFinalizeAt: Date?
    /// No-cut watchdog window for a genuine CUTTER WEDGE: the pump is
    /// reading packets at a healthy rate but finalizes no segment (hostile
    /// SSAI ad pod the re-mux can't cut through). Comfortably above the
    /// ~5 s segment cadence and the 12 s playlist refresh budget, but well
    /// under the buffer the player holds, so a wedged cutter fails over
    /// before AVPlayer drains. Live-only.
    private static let liveSegmentStallTimeoutSeconds: TimeInterval = 10
    /// No-cut watchdog window for SOURCE STARVATION: the pump is barely
    /// reading (a slow / flaky CDN segment trickling in or timing out), so
    /// the cutter is fine, the upstream is the problem. The HLS ingest
    /// reader owns this: it retries each segment up to 3x (~31 s budget)
    /// and then goes terminal, which exits the pump cleanly via readError.
    /// Escalating at the tight wedge timeout instead would turn a single
    /// transient slow segment into a full host retune (device repro:
    /// playback hung ~17 s after start on a -1001 segment timeout). This
    /// longer backstop only fires if the ingest neither recovers nor
    /// terminates (e.g. a sustained 404-window slide), well past the
    /// ingest's own retry budget. Live-only.
    private static let liveSourceStarvationTimeoutSeconds: TimeInterval = 35
    /// Packets-per-second in the no-cut window above which the stall is a
    /// genuine CUTTER WEDGE (source streaming at full rate, the cutter just
    /// can't find a keyframe to cut on) rather than SOURCE STARVATION (the
    /// feed itself slowed to a trickle, e.g. a Wowza SMIL `bounce`
    /// re-buffering at an SSAI ad splice). A healthy 1080p25 program
    /// delivers ~60 pkt/s (video + audio); a trickle delivers a handful.
    /// Measured as a RATE over the elapsed-since-last-finalize window, not
    /// a cumulative count: a slow feed that accumulates a high packet count
    /// over a long stall used to be misread as a wedge and forced a
    /// premature host retune (device repro: Alex Berlin read 137 packets in
    /// 13 s = 10.5 pkt/s, an obvious trickle, but 137 > the old count
    /// threshold of 60 tripped the tight wedge timeout instead of waiting
    /// the source out on the starvation backstop).
    private static let liveWedgeProgressRateThreshold: Double = 40
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

    /// Fires when a live timeline rebase changes `videoShiftPts` at a
    /// program boundary. Distinct from `onVideoShiftKnown`: the new
    /// shift describes packets at the PRODUCER edge, which AVPlayer
    /// renders ~buffer + holdback later, so the engine must defer
    /// applying it to the published clock until playback crosses the
    /// seam. `seamOutputSeconds` is the seam's position on the output
    /// (AVPlayer clock) timeline, directly comparable to the host's raw
    /// currentTime.
    var onLiveTimelineRebase: (@Sendable (_ shiftPts: Int64, _ seamOutputSeconds: Double) -> Void)?

    /// Why the pump loop exited. Set exactly once, right before
    /// `didFinishFlag`; readable after `waitForFinish` returns true and
    /// delivered via `onPumpFinished`.
    enum PumpExitReason: Sendable, CustomStringConvertible {
        /// Clean end of stream (VOD tail, or a live source that closed
        /// gracefully; for live the engine treats this like a source
        /// loss, a healthy live source never EOFs).
        case eof
        /// `stop()` was called (teardown / scrub restart).
        case stopRequested
        /// `demuxer.readPacket()` threw after the AVIO reader exhausted
        /// its reconnect budget (live) or hit a hard I/O error.
        case readError(code: Int32)
        /// A muxer allocation / rotation failed mid-pump.
        case muxerFailed
        /// Live keyframe gate: no `AV_PKT_FLAG_KEY` video packet arrived
        /// within the timeout (mis-flagged source); the stream would
        /// starve forever, so the pump exits and lets the engine's
        /// reopen path retry with a fresh source connection.
        case keyframeStarvation
        /// After an unplanned reader reconnect the source PTS reset back
        /// to the session's start: the server restarted its stream from
        /// the beginning on re-GET (Jellyfin transcode respawn re-serving
        /// from byte 0). Stitching that in would splice REPLAYED content
        /// into the live timeline (the user sees the program jump), and
        /// reopening the same URL would replay it again, so the pump
        /// exits terminally and the engine asks the host to re-negotiate
        /// a fresh playback session at the live edge.
        case sourceReplay
        /// Live: the pump kept reading packets but finalized no new
        /// segment for the stall window. Hostile server-side ad
        /// insertion (Pluto/FAST ad pods restarting source timestamps
        /// per creative) can wedge the segment cutter even when bytes
        /// keep flowing; rather than let AVPlayer hang on the missing
        /// next segment, exit so the engine asks the host to retune
        /// (which falls back to the server-muxed route that tolerates
        /// the ad pod). Defense-in-depth behind the discontinuity
        /// rebase: if rebasing ever fails to keep cutting, this fires.
        case segmentStall

        var description: String {
            switch self {
            case .eof: return "eof"
            case .stopRequested: return "stopRequested"
            case .readError(let code): return "readError(\(code))"
            case .muxerFailed: return "muxerFailed"
            case .keyframeStarvation: return "keyframeStarvation"
            case .sourceReplay: return "sourceReplay"
            case .segmentStall: return "segmentStall"
            }
        }
    }

    /// Fires exactly once when the pump loop has fully unwound (after
    /// the final segment was finalized and `didFinishFlag` broadcast).
    /// The engine uses this on live sessions to drive the bounded
    /// reopen-with-backoff recovery when the source was lost.
    var onPumpFinished: (@Sendable (PumpExitReason) -> Void)?

    /// Marks the FIRST segment this producer opens as discontinuous
    /// (`#EXT-X-DISCONTINUITY`). Set by the engine's live-reopen path:
    /// the fresh source connection joins the broadcast at "now", so the
    /// content (and source clock) jump relative to the last segment the
    /// failed producer delivered.
    var firstSegmentDiscontinuous = false

    /// Latched once the signature has been seen in this producer's
    /// packet stream so the scan goes silent for the remainder of the
    /// session. The byte scan is cheap (~µs per packet) but there's no
    /// reason to keep paying for it after detection.
    private var hdr10PlusDetected = false

    /// Whether a live timeline jump is a server-side replay-from-start
    /// rather than a genuine program boundary: the jump goes BACKWARD,
    /// lands at (or below) the first dts this producer ever saw, and an
    /// unplanned reader reconnect happened moments ago. All three must
    /// hold; a program-boundary PTS reset is not reconnect-correlated,
    /// and a reconnect that genuinely resumes "from now" produces no
    /// backward jump. A continuation producer (post-reopen) starts
    /// mid-stream, so a replay from the resource's byte 0 lands BELOW
    /// its first-seen dts and still matches.
    private func isSourceReplay(newDts: Int64,
                                jumpTicks: Int64,
                                firstSeenDts: Int64,
                                tbSeconds: Double,
                                stream: String) -> Bool {
        guard jumpTicks < 0, firstSeenDts != Int64.min, tbSeconds > 0 else { return false }
        guard let reconnectAt = demuxer.lastUnplannedSourceReconnectAt,
              Date().timeIntervalSince(reconnectAt) < Self.sourceReplayReconnectWindowSeconds
        else { return false }
        let windowTicks = Int64(Self.sourceReplayStartWindowSeconds / tbSeconds)
        guard newDts <= firstSeenDts + windowTicks else { return false }
        EngineLog.emit(
            "[HLSSegmentProducer] live source REPLAY detected on \(stream): "
            + "srcDts=\(newDts) firstSeenDts=\(firstSeenDts) jumpTicks=\(jumpTicks) "
            + "reconnect \(String(format: "%.1f", Date().timeIntervalSince(reconnectAt)))s ago; "
            + "server restarted the stream from its beginning, exiting pump for host retune",
            category: .session
        )
        return true
    }

    // MARK: - Init

    init(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        video: StreamConfig,
        audio: AudioConfig? = nil,
        sideAudioDemuxer: Demuxer? = nil,
        cache: SegmentCache,
        baseIndex: Int = 0,
        targetSegmentDurationSeconds: Double = 6.0,
        videoFallbackDurationPts: Int64,
        audioFallbackDurationPts: Int64 = 0,
        restartTargetVideoDts: Int64 = Int64.min,
        desiredFirstVideoTfdtPts: Int64,
        desiredFirstAudioTfdtPts: Int64 = 0,
        segmentBoundaries: [Int64],
        isLive: Bool = false,
        packedSideAudioStartPts: Int64? = nil,
        packedSideAudioFallbackDurationPts: Int64 = 0
    ) throws {
        self.demuxer = demuxer
        self.sideAudioDemuxer = sideAudioDemuxer
        // Packed (raw ADTS) side audio: synthesize program-clock
        // timestamps anchored at the segment's ID3 PRIV value. TS-side
        // sessions (startPts nil) keep using the demuxer's real
        // program-clock timestamps.
        if let startPts = packedSideAudioStartPts {
            self.packedSideAudioClock = PackedAudioSynthClock(
                startPts: startPts,
                fallbackDurationPts: packedSideAudioFallbackDurationPts
            )
        }
        self.videoStreamIndex = videoStreamIndex
        self.videoConfig = video
        self.audioConfig = audio
        self.cache = cache
        self.baseIndex = baseIndex
        self.sourceVideoTimeBase = video.timeBase
        self.targetSegmentDurationSeconds = targetSegmentDurationSeconds
        self.segmentBoundaries = segmentBoundaries
        self.isLive = isLive
        self.liveCurrentSegmentIndex = baseIndex
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
        //
        // Dual-demuxer sessions split the keep sets: the audio config's
        // sourceStreamIndex numbers a stream in the SIDE demuxer, not in
        // the main one (it could alias an unrelated main stream), so the
        // main demuxer keeps only video and the side demuxer keeps only
        // its audio stream.
        if let side = sideAudioDemuxer {
            demuxer.discardAllStreamsExcept([videoStreamIndex])
            if let audio = audio {
                side.discardAllStreamsExcept([audio.sourceStreamIndex])
            }
        } else {
            var keep: Set<Int32> = [videoStreamIndex]
            if let audio = audio {
                keep.insert(audio.sourceStreamIndex)
            }
            demuxer.discardAllStreamsExcept(keep)
        }

        let audioDesc = audio.map { a -> String in
            let mode = a.bridge != nil ? "bridge" : "stream-copy"
            let origin: String
            if packedSideAudioClock != nil {
                origin = " (side demuxer, packed synth clock start=\(packedSideAudioStartPts ?? 0))"
            } else if sideAudioDemuxer != nil {
                origin = " (side demuxer)"
            } else {
                origin = ""
            }
            return " audio=\(mode)\(origin) inTb=\(a.inputTimeBase.num)/\(a.inputTimeBase.den)"
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

    /// Live-mode segment index for a VIDEO packet. Forward-only keyframe
    /// cutter: the first keyframe opens segment `baseIndex`; a later
    /// keyframe whose source-pts is at least `targetSegmentDurationSeconds`
    /// past the current segment's start advances the cutter by one (which
    /// the look-behind's `ensureMuxer(forSegmentIndex:)` then turns into a
    /// fragment cut + adopt). `pts` is the post-shift packet pts in source
    /// video TB. Non-keyframe packets stay in the current segment.
    /// Returns the absolute index this packet belongs to.
    private func liveVideoSegmentIndex(pts: Int64, isKeyframe: Bool) -> Int {
        let ptsSeconds = Double(pts) * sourceVideoTbSeconds
        if !liveFirstSegmentOpened {
            // First kept video packet opens segment baseIndex. The gate
            // guarantees it is a keyframe, so this is always an IRAP start.
            liveFirstSegmentOpened = true
            liveCurrentSegmentIndex = baseIndex
            liveSegmentStartPtsSeconds = ptsSeconds
            liveSegmentStartByIndex[liveCurrentSegmentIndex] = ptsSeconds
            liveSegmentDiscontinuousByIndex[liveCurrentSegmentIndex] = firstSegmentDiscontinuous
            // A boundary before the first segment has nothing to separate.
            pendingForceCutFlag = false
            return liveCurrentSegmentIndex
        }
        // `pendingForceCutFlag` (set by the timeline rebase) cuts at the
        // NEXT keyframe regardless of the 4 s minimum, so the boundary
        // segment starts at the new program's first IRAP and carries the
        // #EXT-X-DISCONTINUITY tag exactly at the splice instead of one
        // segment late. The short pre-boundary segment this produces is
        // spec-legal (EXTINF < TARGETDURATION).
        if isKeyframe,
           pendingForceCutFlag
            || ptsSeconds - liveSegmentStartPtsSeconds >= targetSegmentDurationSeconds {
            // Cut: this keyframe starts a new segment. The finalize of the
            // segment we are leaving happens inside ensureMuxer/advanceMuxer
            // when the look-behind routes the previous packet; the duration
            // is reported there from the recorded start times.
            liveCurrentSegmentIndex += 1
            liveSegmentStartPtsSeconds = ptsSeconds
            liveSegmentStartByIndex[liveCurrentSegmentIndex] = ptsSeconds
            pendingForceCutFlag = false
            // A discontinuity detected since the last cut marks THIS new
            // segment as the boundary segment. AVPlayer keeps its own
            // timeline continuous across the #EXT-X-DISCONTINUITY tag, which
            // is what holds seekableEnd (and the engine's native session
            // edge) monotonic across the jump. Consume the latch.
            liveSegmentDiscontinuousByIndex[liveCurrentSegmentIndex] = pendingDiscontinuityFlag
            pendingDiscontinuityFlag = false
        }
        return liveCurrentSegmentIndex
    }

    /// Source video TB in seconds per tick, for live pts→seconds. Mirrors
    /// the engine's `sourceVideoTbSeconds`; derived from the configured
    /// time base.
    private var sourceVideoTbSeconds: Double {
        guard sourceVideoTimeBase.num > 0, sourceVideoTimeBase.den > 0 else { return 0 }
        return Double(sourceVideoTimeBase.num) / Double(sourceVideoTimeBase.den)
    }

    /// Map an absolute video PTS (in source video TB) to the segment
    /// index that contains it. Returns `baseIndex` for any pts before
    /// the first boundary (defensive: shouldn't happen post-gate);
    /// returns the last segment index for any pts past the last
    /// boundary.
    private func segmentIndex(forSourcePts pts: Int64) -> Int {
        guard !segmentBoundaries.isEmpty else { return baseIndex }
        // Callers pass POST-shift (output-timeline) values: the
        // look-behind stashes packets after the dynamic shift was
        // applied, and the bridge re-stamps onto the shifted timeline.
        // The plan boundaries are ABSOLUTE source PTS, so fold the
        // shift back before comparing; the two axes only coincided when
        // the source's first keyframe sat at pts 0 (the dominant case,
        // which is why the skew went unnoticed). With a non-zero start
        // or a restart whose gate landed past the planned target, every
        // boundary crossing was detected late by that offset and cut
        // content drifted from the declared EXTINFs.
        let absolute = videoShiftPts == Int64.min ? pts : pts &+ videoShiftPts
        // Linear scan is fine here — segmentBoundaries is at most
        // ~2k entries and this is called once per video packet on a
        // worker queue. Binary search would be premature.
        for i in 0..<(segmentBoundaries.count - 1) {
            if absolute < segmentBoundaries[i + 1] {
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

        // SSAI program switch crossing a segment boundary: the new
        // program's video has different codec params, so it cannot share
        // the old init. Finalize the old muxer's last segment, then build
        // a FRESH muxer (new init version) for the new segment. The
        // playlist emits a per-discontinuity EXT-X-MAP for it.
        if pendingVideoProgramSwitch, effectiveIdx > currentMuxerSegmentIndex {
            return rotateMuxerForProgramSwitch(to: effectiveIdx)
        }

        // Forward boundary crossing on an existing muxer: trigger a
        // fragment cut. The muxer flushes the in-flight fragment to
        // the old segment's fd, adopts that file into the cache, and
        // rotates fd + currentSegmentIndex to the new segment.
        return advanceMuxer(to: effectiveIdx)
    }

    /// SSAI versioned-init rotation: finalize the program's last segment
    /// on the old muxer, then allocate a fresh muxer (new init version)
    /// for the ad creative at `newIdx`, built from the ad config parsed
    /// out of its keyframe's SPS at the program switch.
    private func rotateMuxerForProgramSwitch(to newIdx: Int) -> MP4SegmentMuxer? {
        let finishedIdx = currentMuxerSegmentIndex
        finalizeSessionMuxerAndAdopt() // adopts finishedIdx, nils currentMuxer
        pendingVideoProgramSwitch = false
        guard let adConfig = pendingAdVideoConfig else {
            EngineLog.emit(
                "[HLSSegmentProducer] program switch: no parsed ad video config; "
                + "cannot re-init muxer",
                category: .session
            )
            return nil
        }
        pendingAdVideoConfig = nil
        EngineLog.emit(
            "[HLSSegmentProducer] muxer rotation at SSAI program switch: "
            + "seg-\(finishedIdx) finalized on old init, fresh init for seg-\(newIdx) "
            + "(\(adConfig.width)x\(adConfig.height))",
            category: .session
        )
        return allocateMuxer(initialSegmentIndex: newIdx, adVideoConfig: adConfig)
    }

    /// Parse the ad creative's video config from a keyframe packet's
    /// in-band Annex-B SPS/PPS: explicit dimensions (from the SPS) plus
    /// Annex-B extradata the mov muxer packs into avcC. nil when the
    /// packet carries no parameter sets (mid-GOP join). H.264 only; other
    /// codecs fall back (the switch won't fire and the watchdog catches it).
    private func extractAdVideoConfig(_ packet: UnsafeMutablePointer<AVPacket>) -> (width: Int32, height: Int32, extradata: [UInt8])? {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
        let buf = UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))
        guard let (sps, pps) = H264SPS.extractSPSandPPS(fromAnnexB: buf),
              let dim = H264SPS.dimensions(fromNAL: sps) else { return nil }
        return (Int32(dim.width), Int32(dim.height),
                H264SPS.annexBExtradata(sps: sps, pps: pps))
    }

    /// First-time allocation of the session's single mp4 muxer. Wires
    /// the init.mp4 callback so the cache gets seeded once.
    ///
    /// `adVideoConfig` re-allocates the muxer at an SSAI program switch
    /// with the AD creative's parsed dimensions + Annex-B SPS/PPS
    /// extradata (the mid-stream demuxer codecpar is unparsed). The
    /// captured init becomes a NEW version in the cache (so the playlist
    /// emits a per-discontinuity EXT-X-MAP) rather than overwriting the
    /// session init.
    private func allocateMuxer(initialSegmentIndex: Int,
                               adVideoConfig: (width: Int32, height: Int32, extradata: [UInt8])? = nil) -> MP4SegmentMuxer? {
        // Backpressure even on the first segment so the producer
        // doesn't try to allocate ahead of AVPlayer's declared target.
        let backpressureTarget = initialSegmentIndex - Self.bufferAheadSegments
        while !checkShouldStop() {
            if cache.awaitFetchHighWater(reaching: backpressureTarget, timeout: 1.0) { break }
        }
        if checkShouldStop() { return nil }

        let isReinit = adVideoConfig != nil

        // Build a fresh codecpar from the parsed ad SPS for a re-init:
        // explicit dimensions + Annex-B extradata. avcodec_parameters_copy
        // (inside the muxer) copies it; we free our temporary right after.
        var adPar: UnsafeMutablePointer<AVCodecParameters>?
        defer { if adPar != nil { avcodec_parameters_free(&adPar) } }
        let videoCodecpar: UnsafePointer<AVCodecParameters>
        if let adVideoConfig {
            guard let par = avcodec_parameters_alloc() else { return nil }
            par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
            par.pointee.codec_id = AV_CODEC_ID_H264
            par.pointee.width = adVideoConfig.width
            par.pointee.height = adVideoConfig.height
            let ed = adVideoConfig.extradata
            let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
            if let raw = av_malloc(ed.count + pad) {
                let bytes = raw.assumingMemoryBound(to: UInt8.self)
                ed.withUnsafeBytes { _ = memcpy(bytes, $0.baseAddress, ed.count) }
                memset(bytes + ed.count, 0, pad)
                par.pointee.extradata = bytes
                par.pointee.extradata_size = Int32(ed.count)
            }
            adPar = par
            videoCodecpar = UnsafePointer(par)
        } else {
            videoCodecpar = videoConfig.codecpar
        }

        let muxerVideo = MP4SegmentMuxer.VideoConfig(
            codecpar: videoCodecpar,
            timeBase: videoConfig.timeBase,
            codecTagOverride: videoConfig.codecTagOverride,
            // The session's DV-strip / color / extradata overrides were
            // derived from the program's codecpar; on a re-init the ad's
            // own codecpar carries its signaling, so don't force the
            // program's values onto it.
            stripDolbyVisionMetadata: isReinit ? false : videoConfig.stripDolbyVisionMetadata,
            colorOverride: isReinit ? nil : videoConfig.colorOverride,
            extradataOverride: isReinit ? nil : videoConfig.extradataOverride
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
                onInitCaptured: { [weak self] initBytes in
                    guard let self = self else { return }
                    if isReinit {
                        self.cache.addInitVersion(initBytes, fromSegment: initialSegmentIndex)
                        EngineLog.emit(
                            "[HLSSegmentProducer] versioned init captured for seg-\(initialSegmentIndex) "
                            + "(\(initBytes.count) B, SSAI program switch)",
                            category: .session
                        )
                    } else if !self.initCaptured {
                        self.initCaptured = true
                        self.cache.setInit(initBytes)
                        EngineLog.emit(
                            "[HLSSegmentProducer] init.mp4 captured (\(initBytes.count) B)",
                            category: .session
                        )
                    }
                }
            )
            // currentMuxer is read under stateLock by the telemetry
            // getters (muxerLifetimeFragmentBytes / muxerFragmentCuts);
            // the write must take the same lock or the reader-side lock
            // is useless (ARC race on the strong ref).
            stateLock.lock()
            self.currentMuxer = muxer
            stateLock.unlock()
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
                category: .session, level: .verbose
            )
            cache.adopt(index: currentMuxerSegmentIndex,
                        stagingPath: result.path,
                        byteCount: result.bytesWritten)
            // Live: report the just-finalized segment to the provider so
            // its growing EVENT playlist exposes it. Duration is the gap
            // between this segment's start and the next segment's start
            // (both recorded by the keyframe cutter); if the next start
            // isn't known yet, fall back to the duration target.
            if isLive {
                reportLiveSegmentFinalized(index: currentMuxerSegmentIndex,
                                           nextIndex: newIdx)
            }
            // The cut completed but the muxer failed to open the NEXT
            // staging file: it has no fd, so every byte of the next
            // segment would be silently discarded. End the pump here, at
            // the actual failure point (the completed segment above was
            // still adopted).
            if muxer.isWedged {
                EngineLog.emit(
                    "[HLSSegmentProducer] muxer wedged after seg-\(currentMuxerSegmentIndex) cut "
                    + "(next staging fd open failed), ending pump",
                    category: .session
                )
                return nil
            }
        } else {
            // A failed fragment cut leaves the muxer WITHOUT an open
            // staging fd: the splitter callback then silently discards
            // every subsequent fragment byte while the pump keeps
            // burning network + CPU producing nothing (AVPlayer starves
            // into per-segment fetch timeouts). The muxer cannot recover
            // mid-session (the avformat context's fragment state is
            // tied to the lost fd), so treat the cut failure as fatal:
            // returning nil makes the pump exit with .muxerFailed, and
            // a live session takes the engine's reopen path with a
            // fresh producer + muxer.
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(currentMuxerSegmentIndex).m4s cut FAILED; "
                + "muxer is wedged, ending pump",
                category: .session
            )
            return nil
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

    /// Report a finalized live segment to the engine (which forwards to
    /// the provider's growing EVENT playlist). `index` is the segment that
    /// was just adopted into the cache; `nextIndex` is the segment the
    /// cutter advanced to (nil at EOF). Duration is the gap between this
    /// segment's recorded start and the next segment's start, falling back
    /// to the duration target when the next start is unknown. The start
    /// entry for `index` is removed once reported.
    private func reportLiveSegmentFinalized(index: Int, nextIndex: Int?) {
        guard let startSeconds = liveSegmentStartByIndex[index] else {
            EngineLog.emit(
                "[HLSSegmentProducer] live finalize: no recorded start for seg-\(index); skipping append",
                category: .session
            )
            return
        }
        let duration: Double
        if let nextIndex = nextIndex, let nextStart = liveSegmentStartByIndex[nextIndex] {
            let d = nextStart - startSeconds
            duration = d > 0 ? d : targetSegmentDurationSeconds
        } else {
            duration = targetSegmentDurationSeconds
        }
        let discontinuous = liveSegmentDiscontinuousByIndex[index] ?? false
        liveSegmentStartByIndex.removeValue(forKey: index)
        liveSegmentDiscontinuousByIndex.removeValue(forKey: index)
        // Feed the no-cut stall watchdog: a finalized segment means the
        // cutter is alive, so reset its clock.
        lastLiveSegmentFinalizeAt = Date()
        EngineLog.emit(
            "[HLSSegmentProducer] live seg-\(index) finalized: start=\(String(format: "%.3f", startSeconds))s "
            + "dur=\(String(format: "%.3f", duration))s"
            + (discontinuous ? " [DISCONTINUITY]" : ""),
            category: .session
        )
        onLiveSegmentFinalized?(index, duration, startSeconds, discontinuous)
    }

    /// Finalize the session-wide muxer at pump exit and adopt the
    /// final segment.
    private func finalizeSessionMuxerAndAdopt() {
        guard let muxer = currentMuxer else { return }
        let idx = currentMuxerSegmentIndex
        if let result = muxer.finalize() {
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(idx).m4s captured (\(result.bytesWritten) B)",
                category: .session, level: .verbose
            )
            cache.adopt(index: idx, stagingPath: result.path,
                        byteCount: result.bytesWritten)
            // Live safety-net: a real live feed never reaches EOF, but if
            // the pump exits (stop / error) we still report the final
            // partial segment so the provider lists it. No next-segment
            // start exists, so duration falls back to the target.
            if isLive {
                reportLiveSegmentFinalized(index: idx, nextIndex: nil)
            }
        } else {
            EngineLog.emit(
                "[HLSSegmentProducer] seg-\(idx).m4s final finalize failed; not adopted",
                category: .session
            )
        }
        // Locked for the same reason as the write in allocateMuxer: the
        // telemetry getters read currentMuxer under stateLock.
        stateLock.lock()
        currentMuxer = nil
        stateLock.unlock()
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

    // MARK: - Dual-source pull-merge

    /// Where a merged packet came from. Classification in the pump keys
    /// off this when a side demuxer is active (see `sideAudioDemuxer`).
    private enum PacketOrigin { case main, side }

    /// Next packet for the pump, in global decode order. Single-demuxer
    /// sessions read the main demuxer directly (the pre-merge fast
    /// path, byte-for-byte the old behaviour). Dual-demuxer sessions
    /// keep one lookahead per source and yield the lower DTS first,
    /// rescaled to a common clock via each stream's time_base (both are
    /// MPEG-TS 1/90000 in practice, but the rescale keeps the merge
    /// correct for any pairing).
    ///
    /// Blocking and pacing: each underlying read blocks until that
    /// source's ingest FIFO has bytes. Holding one lookahead per source
    /// means the pump only ever waits for whichever rendition is
    /// BEHIND, which naturally paces both ingests to the live rate;
    /// both renditions come off the same CDN clock, so neither can run
    /// unboundedly ahead. A stall on either source stalls the pump the
    /// same way a muxed-audio stall always has.
    ///
    /// EOF: the FIRST source to EOF ends the merged stream (nil), even
    /// if the other still has a lookahead pending; see the latch docs.
    /// The unconsumed lookahead is freed by the pump's exit path. Read
    /// errors throw through unchanged so the pump exits with the same
    /// `.readError` reason that triggers the host-retune path today.
    private func readNextSourcePacket() throws -> (packet: UnsafeMutablePointer<AVPacket>, origin: PacketOrigin)? {
        guard let side = sideAudioDemuxer else {
            guard let packet = try demuxer.readPacket() else { return nil }
            return (packet, .main)
        }
        // Fill both lookaheads. Order matters for teardown: a stop()
        // marks both demuxers closed, so neither read can block forever.
        if mergeMainLookahead == nil, !mergeMainEOF {
            mergeMainLookahead = try demuxer.readPacket()
            if mergeMainLookahead == nil { mergeMainEOF = true }
        }
        if mergeSideLookahead == nil, !mergeSideEOF {
            mergeSideLookahead = try side.readPacket()
            if mergeSideLookahead == nil {
                mergeSideEOF = true
            } else if packedSideAudioClock != nil, let pkt = mergeSideLookahead {
                // Stamp synthesized program-clock timestamps at the
                // lookahead fill, BEFORE the merge compares DTS, so
                // ordering / NOPTS repair / gates / rebase / mux all see
                // the same values a TS companion would deliver.
                stampPackedSideAudio(pkt)
            }
        }
        guard !mergeMainEOF, !mergeSideEOF,
              let main = mergeMainLookahead, let sidePkt = mergeSideLookahead else {
            // Either source ended; the merged stream ends with it.
            return nil
        }
        let sideTb = audioConfig?.sourceTimeBase ?? sourceVideoTimeBase
        let sideFirst = DualSourceMergeOrder.sideFirst(
            mainTicks: Self.mergeOrderingTicks(main),
            mainTimeBase: sourceVideoTimeBase,
            sideTicks: Self.mergeOrderingTicks(sidePkt),
            sideTimeBase: sideTb
        )
        if sideFirst {
            mergeSideLookahead = nil
            return (sidePkt, .side)
        }
        mergeMainLookahead = nil
        return (main, .main)
    }

    /// Ordering key for the merge: dts when valid, else pts. A packet
    /// with NEITHER (rare demuxer glitch) keys to Int64.min so it is
    /// yielded immediately instead of wedging the comparison; the
    /// pump's NOPTS repair downstream handles it like any other
    /// timestamp-less packet.
    private static func mergeOrderingTicks(_ packet: UnsafeMutablePointer<AVPacket>) -> Int64 {
        if packet.pointee.dts != Int64.min { return packet.pointee.dts }
        return packet.pointee.pts
    }

    /// Overwrite a packed side-audio packet's timestamps with the
    /// synthesized program clock. The raw "aac" demuxer's own values
    /// (zero-based, its private 1/28224000 clock with no PRIV anchor)
    /// are useless for the merge and the audio gate; the synth clock
    /// puts the stream on the variant group's shared 90 kHz program
    /// clock (rescaled into the side stream's time base), so everything
    /// downstream of this point treats the session exactly like a
    /// TS-companion one.
    ///
    /// KNOWN LIMITATION: if the VIDEO rebases on a live discontinuity,
    /// this free-running clock does NOT jump with it; A/V sync is lost
    /// from that boundary on (a loud warning fires at the video rebase
    /// site). Packed-audio providers (ARD live) have no in-stream
    /// discontinuities in practice, so this stays a documented edge
    /// instead of carrying speculative re-anchor machinery.
    private func stampPackedSideAudio(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard audioConfig.map({ packet.pointee.stream_index == $0.sourceStreamIndex }) ?? false,
              var clock = packedSideAudioClock else { return }
        let pts = clock.stamp(packetDuration: packet.pointee.duration)
        packedSideAudioClock = clock
        packet.pointee.pts = pts
        packet.pointee.dts = pts
        if packet.pointee.duration <= 0 {
            packet.pointee.duration = clock.fallbackDurationPts
        }
    }

    /// Free any unconsumed merge lookaheads. Called once from the
    /// pump's exit path: the loop can break (stop / error / EOF latch)
    /// between a fill and a yield, leaving up to one packet per source
    /// in the lookahead slots.
    private func freeMergeLookaheads() {
        trackedPacketFree(&mergeMainLookahead)
        trackedPacketFree(&mergeSideLookahead)
    }

    // MARK: - Pump

    private func runPumpLoop() {
        if restartTargetVideoDts > Int64.min {
            bumpRestartCount()
        }
        let pumpStart = DispatchTime.now()
        var packetsRead = 0
        var lastError: Int32 = 0
        var exitReason: PumpExitReason = .eof
        // No-cut watchdog progress tracking: snapshot packetsRead each time
        // a segment finalizes, so the watchdog can tell a cutter wedge
        // (many packets read since, no cut) from source starvation (a
        // trickle). Updated when lastLiveSegmentFinalizeAt advances.
        var packetsReadAtLastFinalize = 0
        var lastFinalizeSeen: Date? = lastLiveSegmentFinalizeAt
        // Per-window breakdown for the no-cut wedge trace: what actually
        // arrived since the last finalize. Reset alongside
        // packetsReadAtLastFinalize so the numbers describe the stall, not
        // the whole session. A wedge with video=N key=0 means "frames
        // flowing, no keyframe to cut on"; foreign>0 means "the ad came on
        // a stream we're dropping"; all-low means a genuine trickle.
        var videoPktsSinceFinalize = 0
        var audioPktsSinceFinalize = 0
        var videoKeyframesSinceFinalize = 0
        var foreignPktsSinceFinalize = 0
        var lastForeignStreamIndexSinceFinalize: Int32 = -1
        var firstVideoPtsSinceFinalize: Int64 = Int64.min
        var lastVideoPtsSinceFinalize: Int64 = Int64.min

        do {
            readLoop: while true {
                stateLock.lock()
                let stopRequested = shouldStop
                stateLock.unlock()
                if stopRequested {
                    exitReason = .stopRequested
                    break readLoop
                }

                // Pick up a finalize that happened since the last iteration
                // so the watchdog's progress baseline tracks the cut cadence.
                if lastLiveSegmentFinalizeAt != lastFinalizeSeen {
                    lastFinalizeSeen = lastLiveSegmentFinalizeAt
                    packetsReadAtLastFinalize = packetsRead
                    videoPktsSinceFinalize = 0
                    audioPktsSinceFinalize = 0
                    videoKeyframesSinceFinalize = 0
                    foreignPktsSinceFinalize = 0
                    lastForeignStreamIndexSinceFinalize = -1
                    firstVideoPtsSinceFinalize = Int64.min
                    lastVideoPtsSinceFinalize = Int64.min
                }
                // No-cut stall watchdog (live, defense-in-depth behind the
                // discontinuity rebase). The loop only reaches here when
                // readNextSourcePacket returns, so distinguish the two ways
                // a cut can stall: a WEDGE reads packets at a healthy rate
                // but can't finalize (hostile SSAI ad pod) and must fail
                // over fast; SOURCE STARVATION barely reads (a slow / flaky
                // CDN segment) and belongs to the ingest reader's own retry
                // + terminal budget, so escalating it at the tight wedge
                // timeout would turn one transient slow segment into a full
                // host retune. Use the longer starvation backstop unless the
                // pump made real read progress without cutting.
                if isLive, let lastFinalize = lastLiveSegmentFinalizeAt {
                    let stalledFor = Date().timeIntervalSince(lastFinalize)
                    let progress = packetsRead - packetsReadAtLastFinalize
                    // Classify by READ RATE, not cumulative count: a real
                    // wedge streams at full rate but can't cut, a starved
                    // source trickles. A long stall can accumulate a high
                    // cumulative count from a trickle, which the old
                    // count-only test misread as a wedge and failed over at
                    // the tight 10 s timeout instead of waiting the source
                    // out on the 35 s starvation backstop.
                    let readRate = stalledFor > 0 ? Double(progress) / stalledFor : 0
                    let isWedge = readRate >= Self.liveWedgeProgressRateThreshold
                    let timeout = isWedge
                        ? Self.liveSegmentStallTimeoutSeconds
                        : Self.liveSourceStarvationTimeoutSeconds
                    if stalledFor > timeout {
                        // Window breakdown turns the next stall into a
                        // root-causable trace instead of a guess: key=0
                        // means no keyframe to cut on, foreign>0 means the
                        // ad arrived on a dropped stream, all-low means a
                        // genuine source trickle.
                        let ptsAdvance = (lastVideoPtsSinceFinalize != Int64.min
                            && firstVideoPtsSinceFinalize != Int64.min && sourceVideoTbSeconds > 0)
                            ? Double(lastVideoPtsSinceFinalize - firstVideoPtsSinceFinalize) * sourceVideoTbSeconds
                            : -1
                        EngineLog.emit(
                            "[HLSSegmentProducer] no-cut stall: no segment finalized for "
                            + "\(Int(stalledFor))s (packetsRead=\(packetsRead), "
                            + "sinceFinalize=\(progress), "
                            + "rate=\(String(format: "%.1f", readRate))pkt/s, "
                            + "\(isWedge ? "cutter wedge" : "source starvation")); "
                            + "window video=\(videoPktsSinceFinalize) key=\(videoKeyframesSinceFinalize) "
                            + "audio=\(audioPktsSinceFinalize) foreign=\(foreignPktsSinceFinalize)"
                            + (lastForeignStreamIndexSinceFinalize >= 0
                                ? " lastForeignIdx=\(lastForeignStreamIndexSinceFinalize)" : "")
                            + (ptsAdvance >= 0
                                ? " videoPtsAdvance=\(String(format: "%.1f", ptsAdvance))s" : "")
                            + "; exiting for host retune",
                            category: .session
                        )
                        exitReason = .segmentStall
                        break readLoop
                    }
                }

                guard let (packet, origin) = try readNextSourcePacket() else {
                    // EOF (for dual-source sessions: EOF on EITHER source)
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
                //
                // Live exception: AV_PKT_DATA_NEW_EXTRADATA is inspected
                // FIRST. A broadcast program boundary can change the video
                // codec parameters (resolution / SPS / PPS), which the
                // demuxer surfaces as in-band new-extradata side data. The
                // fMP4 init segment was captured once at session start, so
                // a real parameter change makes subsequent segments
                // undecodable against the stale hvcC/avcC. Detect it,
                // force a discontinuity cut (the tag at least resets
                // AVPlayer's decoder at the seam), and log loudly: the
                // full fix (versioned init.mp4 + per-discontinuity
                // EXT-X-MAP) is gated on a real-world repro channel.
                if isLive, origin == .main, packet.pointee.stream_index == videoStreamIndex {
                    var sdSize: Int = 0
                    if let sd = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &sdSize),
                       sdSize > 0 {
                        let newExtra = Data(bytes: sd, count: sdSize)
                        if newExtra != lastSeenVideoExtradata {
                            lastSeenVideoExtradata = newExtra
                            codecParamChangeCount += 1
                            pendingDiscontinuityFlag = true
                            pendingForceCutFlag = true
                            EngineLog.emit(
                                "[HLSSegmentProducer] WARNING: in-band video extradata change #\(codecParamChangeCount) "
                                + "(\(sdSize) bytes) at a live boundary. The init segment is from session "
                                + "start; if this is a real SPS/resolution change, expect decode artifacts "
                                + "until the versioned-init (EXT-X-MAP) path exists. Forcing a discontinuity cut.",
                                category: .session
                            )
                        }
                    }
                }
                av_packet_free_side_data(packet)

                let pktStreamIdx = packet.pointee.stream_index

                // SSAI program switch. An ad creative is authored with a
                // DIFFERENT video PID than the program (content video=PID
                // 0x102, ad video=PID 0x100; audio shares its PID), so
                // libavformat hands the ad's video on a fresh stream index
                // mid-pump. With videoStreamIndex pinned to the program's
                // video, the ad's video is classified as a foreign stream
                // and dropped → no keyframe → the cutter wedges and AVPlayer
                // hangs. Re-point videoStreamIndex at the new video stream
                // so the ad keeps flowing, reset the dts baseline (the new
                // program owns its own clock; judging it against the old
                // one mis-drops every packet), and force a discontinuity so
                // the seam carries a fresh init (versioned-init path below).
                if isLive, origin == .main, sideAudioDemuxer == nil,
                   pktStreamIdx != videoStreamIndex,
                   pktStreamIdx != (audioConfig?.sourceStreamIndex ?? -1),
                   demuxer.isVideoStream(pktStreamIdx),
                   // The mid-stream demuxer codecpar is unparsed (width 0),
                   // so build the ad's config from its keyframe's in-band
                   // SPS/PPS. Only switch on a packet that carries them; a
                   // mid-GOP join without parameter sets is dropped as a
                   // foreign stream until the next keyframe.
                   let adConfig = extractAdVideoConfig(packet) {
                    EngineLog.emit(
                        "[HLSSegmentProducer] SSAI video program switch: "
                        + "videoStreamIndex \(videoStreamIndex) → \(pktStreamIdx) "
                        + "(ad/program \(adConfig.width)x\(adConfig.height) on a new video PID)",
                        category: .session
                    )
                    videoStreamIndex = pktStreamIdx
                    // Do NOT null lastVideoSourceDts: the existing live
                    // timeline rebase (below) needs it to fire on the big
                    // backward dts jump, which is what re-bases the output
                    // timeline AND re-anchors firstActualVideoPts so the
                    // ad's video isn't dropped by the leading-B-frame gate.
                    lastSeenVideoExtradata = nil
                    pendingVideoProgramSwitch = true
                    pendingAdVideoConfig = adConfig
                    // A program switch is active boundary work, not a wedge:
                    // give the next cut a fresh watchdog window so the no-cut
                    // stall doesn't trip mid-ad-pod and force a needless
                    // server retune.
                    if lastLiveSegmentFinalizeAt != nil { lastLiveSegmentFinalizeAt = Date() }
                    // (pendingDiscontinuityFlag / pendingForceCutFlag are
                    // set by the rebase that follows.)
                }

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
                // Classification is ORIGIN-aware when a side demuxer is
                // active: the two demuxers number their streams
                // independently, so the side audio's sourceStreamIndex can
                // alias an unrelated main-demuxer stream (typically the
                // video at index 0). Side packets are audio iff they carry
                // the configured stream; main packets can never be audio in
                // a dual-source session (the main variant is video-only).
                // Single-demuxer sessions keep the original index checks.
                let isVideoPkt = origin == .main && (pktStreamIdx == videoStreamIndex)
                let isAudioPkt: Bool
                if sideAudioDemuxer != nil {
                    isAudioPkt = origin == .side
                        && (audioConfig.map { pktStreamIdx == $0.sourceStreamIndex } ?? false)
                } else {
                    isAudioPkt = (audioConfig.map { pktStreamIdx == $0.sourceStreamIndex }) ?? false
                }
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
                // Live timeline-discontinuity rebase. A broadcast program
                // boundary or an MPEG-TS PCR wrap resets the source dts to a
                // small value, so the incoming packet's dts sits many seconds
                // BELOW lastValid. The per-frame monotonic gate below is tuned
                // for +1-tick MKV B-frame reconstruction glitches: for a video
                // packet it would bump to lastValid+1, find that exceeds the
                // (also-reset, small) pts, and DROP. Because lastVideoSourceDts
                // only advances on KEPT packets, every subsequent video packet
                // would then drop forever — the keyframe cutter stalls, the
                // live playlist stops growing, and AVPlayer parks on -12888
                // ("Playlist File unchanged"). For audio the same gate bumps
                // dts to lastValid+1 while pts stays small, so the muxer emits
                // pts<dts and audio timing corrupts. Both are exactly the
                // failure modes seen on Jellyfin live channels at a program
                // change.
                //
                // The correct repair for a multi-second source-clock leap is
                // not per-packet monotonicity but a timeline REBASE: shift this
                // stream so its OUTPUT dts continues one frame past the last
                // output dts. pts and dts move by the same delta, preserving
                // their skew (no pts<dts), and the next opened segment carries
                // #EXT-X-DISCONTINUITY so AVPlayer resyncs its clock across the
                // seam. We set lastValid to dts-1 so the monotonic gate below
                // sees the rebased packet as already-monotonic and leaves it
                // alone. Live-only: VOD's B-frame glitch handling is untouched.
                if isLive, isVideoPkt, lastVideoSourceDts != Int64.min,
                   videoShiftPts != Int64.min, packet.pointee.dts != Int64.min {
                    let jumpTicks = packet.pointee.dts - lastVideoSourceDts
                    let thresholdSeconds = jumpTicks < 0
                        ? Self.discontinuityBackwardThresholdSeconds
                        : Self.discontinuityThresholdSeconds
                    let thresholdTicks = sourceVideoTbSeconds > 0
                        ? Int64(thresholdSeconds / sourceVideoTbSeconds)
                        : Int64.max
                    if abs(jumpTicks) >= thresholdTicks {
                        if isSourceReplay(newDts: packet.pointee.dts,
                                          jumpTicks: jumpTicks,
                                          firstSeenDts: firstSeenVideoSourceDts,
                                          tbSeconds: sourceVideoTbSeconds,
                                          stream: "video") {
                            exitReason = .sourceReplay
                            break readLoop
                        }
                        let lastOutputDts = lastVideoSourceDts - videoShiftPts
                        let continuationDts = lastOutputDts + max(videoFallbackDurationPts, 1)
                        let newShift = packet.pointee.dts - continuationDts
                        EngineLog.emit(
                            "[HLSSegmentProducer] live video timeline rebase: "
                            + "jumpTicks=\(jumpTicks) srcDts=\(packet.pointee.dts) "
                            + "lastSrcDts=\(lastVideoSourceDts) oldShift=\(videoShiftPts) "
                            + "newShift=\(newShift) lastOutDts=\(lastOutputDts)",
                            category: .session
                        )
                        if packedSideAudioClock != nil {
                            // See stampPackedSideAudio: the synthesized
                            // side-audio clock free-runs from the join
                            // anchor and cannot follow this jump, so the
                            // audio-side inherit below will never apply
                            // (synth timestamps never leap). Expect A/V
                            // desync from this boundary on. Packed-audio
                            // providers have no in-stream discontinuities
                            // in practice; this warning is the breadcrumb
                            // if one ever does.
                            EngineLog.emit(
                                "[HLSSegmentProducer] WARNING: live video rebase with a "
                                + "packed-audio synth clock active; synthesized side-audio "
                                + "timestamps do NOT follow the jump, A/V sync is lost from "
                                + "this boundary on",
                                category: .session
                            )
                        }
                        videoShiftPts = newShift
                        // dts-1 so the monotonic gate below is a no-op for this
                        // packet; line ~1126 then sets lastValid = dts exactly.
                        lastVideoSourceDts = packet.pointee.dts - 1
                        // Re-anchor the leading-B-frame drop to the new program;
                        // otherwise its `pts < firstActualVideoPts` test (raw
                        // source space) would drop every reset-timeline packet.
                        if packet.pointee.pts != Int64.min {
                            firstActualVideoPts = packet.pointee.pts
                        }
                        // Reset the PTS-detector baseline so it doesn't also
                        // double-flag this same leap one packet later.
                        lastRawVideoPts = Int64.min
                        pendingDiscontinuityFlag = true
                        pendingForceCutFlag = true
                        // Hand the seam's OUTPUT dts to the audio stream
                        // (rescaled), NOT the video shift. Audio then derives
                        // its own shift from its OWN boundary srcDts against
                        // this shared seam position, so a creative that muxes
                        // audio on a different source base than video (Pluto
                        // amux ads: video from 0, audio near 2^33) still snaps
                        // audio cleanly onto the video timeline. The output A/V
                        // offset is re-anchored fresh at every boundary (no
                        // cross-pod accumulation). See the pairing-state docs.
                        if let audio = audioConfig {
                            let seamOutAudioTb = av_rescale_q(
                                continuationDts,
                                sourceVideoTimeBase,
                                audio.sourceTimeBase
                            )
                            if let prior = lastIndependentAudioRebase,
                               Date().timeIntervalSince(prior.at) < Self.rebasePairingWindowSeconds {
                                // Audio crossed the boundary first (interleave)
                                // and measured independently; re-derive its shift
                                // from its recorded boundary srcDts and the seam
                                // at the next audio packet.
                                pendingAudioShiftOverride = (seamOutAudioTb, prior.boundarySrcDts, Date())
                                lastIndependentAudioRebase = nil
                            } else {
                                // Audio crosses after video (the common case):
                                // stash the seam output. A transient double-
                                // rebase just overwrites it; the latest seam is
                                // the correct one to snap onto.
                                pendingAudioInheritSeamOut = (seamOutAudioTb, Date())
                            }
                        }
                        // Deferred host-clock handoff: the shift describes
                        // packets at the PRODUCER edge, which AVPlayer renders
                        // ~buffer + holdback later. Publishing it immediately
                        // would jump the host's currentTime/sourceTime while
                        // the old program is still on screen (a backward
                        // program reset would jump it by hours). The seam's
                        // output-timeline position is exactly continuationDts;
                        // the engine applies the new shift when the playback
                        // clock crosses it.
                        let seamOutputSeconds = Double(continuationDts) * sourceVideoTbSeconds
                        onLiveTimelineRebase?(newShift, seamOutputSeconds)
                    }
                }
                if isLive, isAudioPkt, lastAudioSourceDts != Int64.min,
                   audioShiftPts != Int64.min, packet.pointee.dts != Int64.min,
                   let audio = audioConfig {
                    let jumpTicks = packet.pointee.dts - lastAudioSourceDts
                    let tb = audio.sourceTimeBase
                    let thresholdSeconds = jumpTicks < 0
                        ? Self.discontinuityBackwardThresholdSeconds
                        : Self.discontinuityThresholdSeconds
                    let thresholdTicks = tb.num > 0
                        ? Int64(thresholdSeconds * Double(tb.den) / Double(tb.num))
                        : Int64.max
                    if abs(jumpTicks) >= thresholdTicks {
                        if isSourceReplay(newDts: packet.pointee.dts,
                                          jumpTicks: jumpTicks,
                                          firstSeenDts: firstSeenAudioSourceDts,
                                          tbSeconds: tb.den > 0
                                              ? Double(tb.num) / Double(tb.den) : 0,
                                          stream: "audio") {
                            exitReason = .sourceReplay
                            break readLoop
                        }
                        // A fresh jump supersedes any pending correction from
                        // the PREVIOUS boundary; applying it later would shift
                        // audio by a stale delta.
                        if pendingAudioShiftOverride != nil {
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio rebase: discarding stale shift override (new boundary)",
                                category: .session
                            )
                            pendingAudioShiftOverride = nil
                        }
                        let lastOutputDts = lastAudioSourceDts - audioShiftPts
                        // Independent measurement: continue one audio frame
                        // past the last output dts. Used directly only when
                        // no video-derived delta is available (audio crossed
                        // the boundary first); otherwise it bounds the
                        // monotonic clamp below.
                        let measuredShift = packet.pointee.dts
                            - (lastOutputDts + max(audioFallbackDurationPts, 1))
                        var newShift = measuredShift
                        var inherited = false
                        if let p = pendingAudioInheritSeamOut,
                           Date().timeIntervalSince(p.at) < Self.rebasePairingWindowSeconds {
                            // Snap audio onto the video timeline: derive the
                            // shift from THIS audio boundary packet's srcDts and
                            // the shared seam output position, so a differing
                            // audio source base (amux ads) is absorbed and the
                            // first audio packet lands exactly on the seam. This
                            // discards any prior audio offset (what stops the
                            // cross-pod accumulation).
                            let candidate = Self.seamDerivedAudioShift(
                                audioBoundarySrcDts: packet.pointee.dts,
                                seamOutAudioTb: p.seamOutAudioTb
                            )
                            if let bridge = audio.bridge {
                                // Bridge path: shifts never reach the encoder
                                // timeline (the bridge re-stamps from its
                                // free-running sample counter, collapsing the
                                // audio splice gap sample-continuously while
                                // the video timeline keeps its relative gap).
                                // Reproduce the A/V relationship by jumping
                                // the encoder timeline by the residual gap.
                                let driftTicks = measuredShift - candidate
                                let tbSec = tb.den > 0
                                    ? Double(tb.num) / Double(tb.den) : 0
                                bridge.noteTimelineJump(
                                    deltaSeconds: Double(driftTicks) * tbSec
                                )
                                inherited = true
                            } else {
                                // Stream-copy: snap audio onto the seam output
                                // (candidate lands this packet exactly at the
                                // video seam, base-correct for amux ads). Both
                                // streams are 90 kHz, so the output A/V offset is
                                // the intrinsic source skew, re-anchored fresh at
                                // this boundary. Apply it verbatim; do NOT clamp
                                // it to the last output dts. A genuine
                                // SSAI splice changes the audio-vs-video start
                                // skew by a sub-frame amount (Pluto content leads
                                // by ~51 ms, the spliced ad by ~67 ms) and the
                                // audio buffer runs ~100 ms ahead of video, so
                                // the first rebased audio packet lands a little
                                // before the last emitted one. The old delta
                                // handoff + clamp absorbed that by moving the
                                // shift, which both dragged audio late AND
                                // carried the error into the next creative, so it
                                // ACCUMULATED across the ad pod (audio ended up
                                // seconds behind by the time content returned:
                                // the device symptom). Keeping the absolute shift
                                // leaves the lone sub-frame output overlap at the
                                // seam to OutputTimestampSanitizer, which nudges
                                // just those packets forward by a tick. Guard: a
                                // physically implausible overlap (> 0.5 s, e.g. a
                                // malformed reset) re-anchors so we never compress
                                // a long audio region into 1-tick spacing.
                                let firstOutputDts = packet.pointee.dts - candidate
                                let overlapTicks = lastOutputDts - firstOutputDts
                                let maxOverlapTicks = audio.sourceTimeBase.num > 0
                                    ? Int64(0.5 * Double(audio.sourceTimeBase.den)
                                            / Double(audio.sourceTimeBase.num))
                                    : Int64.max
                                if overlapTicks > maxOverlapTicks {
                                    newShift = packet.pointee.dts - lastOutputDts - 1
                                    EngineLog.emit(
                                        "[HLSSegmentProducer] audio rebase inherit re-anchored: "
                                        + "candidate=\(candidate) overlap=\(overlapTicks) ticks "
                                        + "exceeds \(maxOverlapTicks) (implausible reset)",
                                        category: .session
                                    )
                                } else {
                                    newShift = candidate
                                }
                                inherited = true
                            }
                        } else {
                            // Audio crossed first; remember THIS boundary
                            // packet's srcDts so the upcoming video rebase can
                            // re-derive the audio shift from it and the seam.
                            lastIndependentAudioRebase = (packet.pointee.dts, Date())
                        }
                        pendingAudioInheritSeamOut = nil
                        EngineLog.emit(
                            "[HLSSegmentProducer] live audio timeline rebase: "
                            + "jumpTicks=\(jumpTicks) srcDts=\(packet.pointee.dts) "
                            + "lastSrcDts=\(lastAudioSourceDts) oldShift=\(audioShiftPts) "
                            + "newShift=\(newShift) "
                            + "(\(inherited ? "video-derived" : "independent"))",
                            category: .session
                        )
                        audioShiftPts = newShift
                        lastAudioSourceDts = packet.pointee.dts - 1
                    } else if let override_ = pendingAudioShiftOverride {
                        // The video rebase arrived AFTER this stream already
                        // rebased independently (interleave delivered audio's
                        // boundary packet first). Correct toward the
                        // video-derived value; only the few packets between
                        // the two boundary packets carried the uncorrected
                        // shift. Expired overrides (no quiet audio packet
                        // within the pairing window) are dropped: applying a
                        // boundary-old delta later shifts audio wrongly.
                        pendingAudioShiftOverride = nil
                        // Re-derive the base-correct absolute shift from the
                        // recorded audio boundary srcDts and the seam, so a
                        // differing audio source base (amux ads) is absorbed
                        // instead of copying the video shift into a wrong base.
                        let derivedShift = Self.seamDerivedAudioShift(
                            audioBoundarySrcDts: override_.boundarySrcDts,
                            seamOutAudioTb: override_.seamOutAudioTb
                        )
                        if Date().timeIntervalSince(override_.at) < Self.rebasePairingWindowSeconds {
                            if let bridge = audio.bridge {
                                // Bridge path: see the inherit branch; the
                                // residual between the applied (measured)
                                // shift and the video-derived one becomes an
                                // encoder-timeline jump.
                                let driftTicks = audioShiftPts - derivedShift
                                let tbSec = tb.den > 0
                                    ? Double(tb.num) / Double(tb.den) : 0
                                bridge.noteTimelineJump(
                                    deltaSeconds: Double(driftTicks) * tbSec
                                )
                                EngineLog.emit(
                                    "[HLSSegmentProducer] audio rebase corrected via bridge jump (drift=\(driftTicks) ticks)",
                                    category: .session
                                )
                            } else {
                                // Apply the seam-derived shift (both streams
                                // 90 kHz, so it is sample-exact). Same reasoning
                                // as the inherit branch above: do not clamp the
                                // shift to the last output dts, which dragged
                                // audio permanently late and accumulated across
                                // creatives. Leave the sub-frame splice overlap
                                // to OutputTimestampSanitizer; only an
                                // implausibly large overlap (> 0.5 s) re-anchors.
                                let lastOutputDts = lastAudioSourceDts - audioShiftPts
                                let firstOutputDts = override_.boundarySrcDts - derivedShift
                                let overlapTicks = lastOutputDts - firstOutputDts
                                let maxOverlapTicks = tb.num > 0
                                    ? Int64(0.5 * Double(tb.den) / Double(tb.num))
                                    : Int64.max
                                let applied = overlapTicks > maxOverlapTicks
                                    ? packet.pointee.dts - lastOutputDts - 1
                                    : derivedShift
                                EngineLog.emit(
                                    "[HLSSegmentProducer] audio rebase corrected to video-derived shift: "
                                    + "old=\(audioShiftPts) new=\(applied)"
                                    + (applied != derivedShift ? " (re-anchored, overlap \(overlapTicks) ticks)" : ""),
                                    category: .session
                                )
                                audioShiftPts = applied
                                lastAudioSourceDts = packet.pointee.dts - 1
                            }
                        } else {
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio rebase: shift override expired unapplied",
                                category: .session
                            )
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
                // Small-glitch ceiling: this monotonic repair is for MKV
                // B-frame reconstruction glitches (a few ticks backward). A
                // LARGE backward jump is an SSAI ad-pod / program
                // discontinuity (source clock reset); the timeline rebase
                // handles the shift and the OutputTimestampSanitizer
                // guarantees output monotonicity + pts>=dts at the muxer.
                // Bumping/dropping a big jump here is what dropped ad-return
                // frames (cutter wedge → reload) and bumped audio forward
                // (dropouts + A/V drift). Let big jumps pass; only repair
                // small ones.
                let monoGlitchVideoTicks = sourceVideoTbSeconds > 0
                    ? Int64(0.5 / sourceVideoTbSeconds) : Int64.max
                if isVideoPkt, lastVideoSourceDts != Int64.min,
                   packet.pointee.dts != Int64.min,
                   packet.pointee.dts <= lastVideoSourceDts,
                   lastVideoSourceDts - packet.pointee.dts <= monoGlitchVideoTicks {
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
                let monoGlitchAudioTicks: Int64 = {
                    let tb = audioConfig?.sourceTimeBase
                    guard let tb, tb.num > 0, tb.den > 0 else { return monoGlitchVideoTicks }
                    return Int64(0.5 * Double(tb.den) / Double(tb.num))
                }()
                if isAudioPkt, lastAudioSourceDts != Int64.min,
                   packet.pointee.dts != Int64.min,
                   packet.pointee.dts <= lastAudioSourceDts,
                   lastAudioSourceDts - packet.pointee.dts <= monoGlitchAudioTicks {
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
                    videoPktsSinceFinalize += 1
                    if (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 {
                        videoKeyframesSinceFinalize += 1
                    }
                    if packet.pointee.pts != Int64.min {
                        if firstVideoPtsSinceFinalize == Int64.min {
                            firstVideoPtsSinceFinalize = packet.pointee.pts
                        }
                        lastVideoPtsSinceFinalize = packet.pointee.pts
                    }
                    if firstSeenVideoSourceDts == Int64.min {
                        firstSeenVideoSourceDts = packet.pointee.dts
                    }
                    lastVideoSourceDts = packet.pointee.dts
                } else if isAudioPkt {
                    audioPktsSinceFinalize += 1
                    if firstSeenAudioSourceDts == Int64.min {
                        firstSeenAudioSourceDts = packet.pointee.dts
                    }
                    lastAudioSourceDts = packet.pointee.dts
                }

                // Subtitles, additional audio tracks, attachments,
                // unknown streams — dropped silently. Embedded
                // subtitles travel through a side Demuxer owned by
                // AetherEngine, not through this pump.
                if !isVideoPkt && !isAudioPkt {
                    foreignPktsSinceFinalize += 1
                    lastForeignStreamIndexSinceFinalize = pktStreamIdx
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
                        let isKey = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                        let targetSatisfied = restartTargetVideoDts == Int64.min
                            || (packet.pointee.dts != Int64.min && packet.pointee.dts >= restartTargetVideoDts)
                        guard isKey, targetSatisfied else {
                            pregateVideoDropCount += 1
                            if pregateVideoDropCount == 1 {
                                pregateWaitStart = Date()
                            }
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
                            // Live-only bounded wait: a source that never
                            // flags a keyframe (mis-flagged TS) would starve
                            // the cutter forever with nothing but the
                            // periodic log above. Exit with a terminal
                            // reason instead and let the engine's reopen
                            // path retry with a fresh source connection.
                            // VOD keeps the unbounded wait (the scan-forward
                            // restart machinery depends on it).
                            if isLive, let started = pregateWaitStart,
                               Date().timeIntervalSince(started) > Self.liveKeyframeGateTimeoutSeconds {
                                EngineLog.emit(
                                    "[HLSSegmentProducer] live keyframe gate timed out after "
                                    + "\(Int(Self.liveKeyframeGateTimeoutSeconds))s "
                                    + "(dropped=\(pregateVideoDropCount)); exiting pump for reopen",
                                    category: .session
                                )
                                exitReason = .keyframeStarvation
                                break readLoop
                            }
                            continue
                        }
                        firstActualVideoDts = packet.pointee.dts
                        firstActualVideoPts = packet.pointee.pts != Int64.min
                            ? packet.pointee.pts
                            : packet.pointee.dts
                        // Arm the no-cut watchdog at playback start so it also
                        // catches a wedge BEFORE the first segment ever cuts
                        // (e.g. an SSAI ad pod right after the join). Cleared
                        // and re-armed on every finalize thereafter.
                        if isLive, lastLiveSegmentFinalizeAt == nil {
                            lastLiveSegmentFinalizeAt = Date()
                        }
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
                        let meetsTarget = packet.pointee.dts != Int64.min
                            && packet.pointee.dts >= restartTargetAudioDts
                        // Live escape: the target was derived from the video
                        // gate's landing dts; a backward source-clock reset
                        // (program boundary, PCR wrap) in the gap between
                        // video gate-open and the first kept audio packet
                        // strands the target in the OLD clock domain and no
                        // audio packet ever reaches it: the session plays
                        // permanently silent. Bound the wait; on timeout,
                        // accept the current packet (the head-of-stream-style
                        // inherit below still aligns it to the video shift).
                        // VOD keeps the unbounded wait (its targets come from
                        // a fixed plan, the clock cannot reset).
                        var escape = false
                        if isLive, !meetsTarget {
                            if audioGateWaitStart == nil { audioGateWaitStart = Date() }
                            if let started = audioGateWaitStart,
                               Date().timeIntervalSince(started) > Self.liveAudioGateTimeoutSeconds {
                                EngineLog.emit(
                                    "[HLSSegmentProducer] live audio gate timed out after "
                                    + "\(Int(Self.liveAudioGateTimeoutSeconds))s "
                                    + "(dropped=\(pregateAudioDropCount) dts=\(packet.pointee.dts) "
                                    + "target=\(restartTargetAudioDts)); accepting current packet",
                                    category: .session
                                )
                                escape = packet.pointee.dts != Int64.min
                            }
                        }
                        guard meetsTarget || escape else {
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
                        let audioTb = audioConfig?.sourceTimeBase ?? AVRational(num: 1, den: 1000)
                        if restartTargetVideoDts == Int64.min {
                            // Head-of-stream. The audio track's first
                            // packet carries its intrinsic offset from
                            // video: audio frame boundaries almost never
                            // line up with video frame 0, so the first
                            // full audio frame routinely lands tens to
                            // hundreds of ms into the source (Cars: EAC3
                            // first frame at +256 ms). Snapping that packet
                            // onto the video's tfdt (desired = 0, the
                            // playlist origin) — as the restart branch
                            // does — would subtract the whole offset from
                            // EVERY audio packet, pulling the entire track
                            // that far ahead of the picture for the rest of
                            // the session (audio leads video). Instead the
                            // audio inherits the video's origin shift, so
                            // both streams undergo ONE shared transform and
                            // their true source-time relationship is kept
                            // by construction. A global container start
                            // (video itself starting late) is still removed,
                            // because videoShiftPts already captures it; only
                            // the audio-minus-video offset survives, which is
                            // exactly the part that must survive to stay in
                            // sync. The audio fragment's tfdt then starts a
                            // little after the video's, which fmp4 / AVPlayer
                            // represent natively (audio is simply silent for
                            // the leading offset). videoShiftPts is already
                            // set here: the video gate always opens first.
                            audioShiftPts = av_rescale_q(
                                videoShiftPts,
                                sourceVideoTimeBase,
                                audioTb
                            )
                            // The inherited shift is the CURRENT (possibly
                            // already-rebased) video shift; a seam handoff
                            // still armed from before gate-open is thereby
                            // consumed and must not apply again at the next
                            // audio jump.
                            pendingAudioInheritSeamOut = nil
                        } else {
                            // Restart session: keep the gate-on-video snap.
                            // The first audio packet is aligned to the video
                            // keyframe's tfdt so both fragments share a
                            // baseMediaDecodeTime after a mid-stream seek.
                            // The residual offset removed here is sub-frame
                            // (the demuxer is reading interleaved packets
                            // around the seek point, so the nearest audio
                            // packet sits within one frame of the keyframe),
                            // hence imperceptible. This is part of the
                            // delicate HEVC-resume alignment stack; do NOT
                            // fold it into the head-of-stream branch.
                            audioShiftPts = firstActualAudioDts - desiredFirstAudioTfdtPts
                        }
                        // Diagnostic A/V gap. On restart this is the offset
                        // the snap removes (first audio packet vs. the
                        // rescaled video keyframe dts). At head-of-stream we
                        // PRESERVE the intrinsic offset rather than removing
                        // it, so no misalignment is introduced and the
                        // reported gap is 0.
                        let gapInAudioTb: Int64
                        if restartTargetVideoDts == Int64.min {
                            gapInAudioTb = 0
                        } else {
                            gapInAudioTb = restartTargetAudioDts == Int64.min
                                ? 0
                                : firstActualAudioDts - restartTargetAudioDts
                        }
                        let gapMs = audioTb.den > 0
                            ? Double(gapInAudioTb) * Double(audioTb.num) * 1000.0 / Double(audioTb.den)
                            : 0
                        self.setLastAVGapMs(gapMs)
                        EngineLog.emit(
                            "[HLSSegmentProducer] audio gate open: "
                            + "actual=\(firstActualAudioDts) "
                            + "target=\(restartTargetAudioDts) "
                            + "desired=\(desiredFirstAudioTfdtPts) "
                            + "shift=\(audioShiftPts) "
                            + "gapMs=\(String(format: "%.1f", gapMs))",
                            category: .session
                        )
                        if abs(gapMs) > 50 {
                            EngineLog.emit(
                                "[HLSSegmentProducer] WARNING: audio gate "
                                + "opened \(String(format: "%.1f", gapMs)) ms "
                                + "after video gate (baseIndex=\(baseIndex)). "
                                + "Audio content for seg-\(baseIndex)'s first "
                                + "video frame is offset from the video by "
                                + "this much, expect A/V drift to be audible.",
                                category: .session
                            )
                        }
                    }
                }

                // Live PTS-discontinuity detection on RAW source video PTS
                // (before the dynamic shift below mutates it). Only after the
                // video gate has opened, and only in live mode. Compare the
                // incoming raw pts against the previous video packet's raw
                // pts: a leap (forward OR backward) larger than the threshold
                // is a program boundary. This sits well above the NOPTS-dts
                // repair scale (+1 tick) and any frame interval, so it does
                // not interfere with either. The look-behind cut that opens
                // the next segment consumes `pendingDiscontinuityFlag`.
                if isVideoPkt, isLive, firstActualVideoDts != Int64.min,
                   packet.pointee.pts != Int64.min {
                    let rawPts = packet.pointee.pts
                    if lastRawVideoPts != Int64.min {
                        let deltaTicks = rawPts - lastRawVideoPts
                        let deltaSeconds = Double(deltaTicks) * sourceVideoTbSeconds
                        if abs(deltaSeconds) >= Self.discontinuityThresholdSeconds {
                            pendingDiscontinuityFlag = true
                            pendingForceCutFlag = true
                            if !loggedFirstDiscontinuity {
                                loggedFirstDiscontinuity = true
                                EngineLog.emit(
                                    "[HLSSegmentProducer] live PTS discontinuity detected: "
                                    + "prevRawPts=\(lastRawVideoPts) rawPts=\(rawPts) "
                                    + "delta=\(String(format: "%.2f", deltaSeconds))s "
                                    + "(threshold=\(String(format: "%.1f", Self.discontinuityThresholdSeconds))s); "
                                    + "next segment will carry #EXT-X-DISCONTINUITY",
                                    category: .session
                                )
                            }
                        }
                    }
                    lastRawVideoPts = rawPts
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
                    // Compute THIS packet's segment index now. Live: the
                    // keyframe cutter advances on a keyframe past the
                    // duration target (using the shifted pts so the
                    // segment boundaries align with the muxer timeline).
                    // VOD: unused below; routing uses prev.dts at the look-behind site.
                    let thisVideoSeg = isLive
                        ? liveVideoSegmentIndex(
                            pts: packet.pointee.pts,
                            isKeyframe: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                          )
                        : 0
                    if let prev = pendingVideoPkt {
                        // Determine which segment `prev` belongs to.
                        // VOD: DTS lookup against the precomputed plan
                        // (DTS, not PTS, because HEVC open-GOP CRA emits leading
                        // B-frames whose display PTS sits in the previous
                        // segment even though decode order is in the
                        // current one; segment boundaries are IRAP
                        // keyframes where DTS == PTS). Live: the index was
                        // captured when `prev` was examined.
                        let prevSeg = isLive
                            ? pendingVideoSegIndex
                            : segmentIndex(forSourcePts: prev.pointee.dts)
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
                            exitReason = .muxerFailed
                            break readLoop
                        }
                    }
                    pendingVideoPkt = packet
                    if isLive { pendingVideoSegIndex = thisVideoSeg }
                    pktPtr = nil  // hand ownership to pendingVideoPkt; suppress defer-free
                    continue
                }

                // Audio path. Bridge audio (FLAC re-encode) emits
                // packets with the encoder's own duration set
                // correctly, so it bypasses the look-behind. Stream-
                // copy audio gets the same look-behind treatment as
                // video. Gated on the origin-aware isAudioPkt (not a
                // raw index compare) so a dual-source session can't
                // route an aliasing main-stream index here.
                if let audio = audioConfig, isAudioPkt {
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
                        // Symmetric with the video path: a nil muxer
                        // (stop requested or alloc failure) ends the
                        // pump. The old per-packet `continue` kept the
                        // pump reading and silently dropping every
                        // bridged frame until the next VIDEO packet
                        // tripped the same nil. The flag drains the
                        // remaining bridged packets (each must still be
                        // freed) before exiting the read loop.
                        var bridgedMuxerGone = false
                        for fp in flacPackets {
                            var fpVar: UnsafeMutablePointer<AVPacket>? = fp
                            if bridgedMuxerGone {
                                trackedPacketFree(&fpVar)
                                continue
                            }
                            // FLAC packet pts is in audio inputTimeBase.
                            // Rescale to source video TB for the segment
                            // lookup so audio and video share one segmentation.
                            // Live: audio follows the video cutter's current
                            // segment (the playlist segmentation is driven by
                            // video keyframes; audio rides along).
                            let fpSeg: Int
                            if isLive {
                                fpSeg = liveCurrentSegmentIndex
                            } else {
                                let fpPtsInVideoTb = av_rescale_q(
                                    fp.pointee.pts,
                                    audio.inputTimeBase,
                                    sourceVideoTimeBase
                                )
                                fpSeg = segmentIndex(forSourcePts: fpPtsInVideoTb)
                            }
                            guard let muxer = ensureMuxer(forSegmentIndex: fpSeg) else {
                                trackedPacketFree(&fpVar)
                                bridgedMuxerGone = true
                                continue
                            }
                            fp.pointee.stream_index = muxer.audioOutputStreamIndex
                            av_packet_rescale_ts(fp, audio.inputTimeBase, muxer.muxerAudioTimeBase)
                            _ = muxer.writePacket(fp)
                            trackedPacketFree(&fpVar)
                        }
                        if bridgedMuxerGone {
                            exitReason = .muxerFailed
                            break readLoop
                        }
                        continue
                    }
                    // ADTS-AAC from MPEG-TS: strip the per-frame ADTS header
                    // so the bytes muxed into fMP4 are raw AAC (the sample
                    // entry's esds/ASC was synthesised at setup). Done in place
                    // before the look-behind stashes the packet.
                    if audio.stripAacAdts { Self.stripADTSHeader(packet) }
                    // Stream-copy audio look-behind.
                    let thisAudioSeg: Int = isLive ? liveCurrentSegmentIndex : 0
                    if let prev = pendingAudioPkt {
                        let prevSeg: Int
                        if isLive {
                            prevSeg = pendingAudioSegIndex
                        } else {
                            let prevPtsInVideoTb = av_rescale_q(
                                prev.pointee.pts,
                                audio.inputTimeBase,
                                sourceVideoTimeBase
                            )
                            prevSeg = segmentIndex(forSourcePts: prevPtsInVideoTb)
                        }
                        if let muxer = ensureMuxer(forSegmentIndex: prevSeg) {
                            finalizeAndWriteAudio(prev, nextDts: packet.pointee.dts, audio: audio, muxer: muxer)
                        } else {
                            var pkt: UnsafeMutablePointer<AVPacket>? = prev
                            trackedPacketFree(&pkt)
                            pendingAudioPkt = nil
                            exitReason = .muxerFailed
                            break readLoop
                        }
                    }
                    pendingAudioPkt = packet
                    if isLive { pendingAudioSegIndex = thisAudioSeg }
                    pktPtr = nil
                    continue
                }
            }
        } catch {
            if case DemuxerError.readFailed(let code) = error {
                lastError = code
                exitReason = .readError(code: code)
            } else {
                lastError = -1
                exitReason = .readError(code: -1)
            }
            EngineLog.emit(
                "[HLSSegmentProducer] demuxer.readPacket threw: \(error)",
                category: .session
            )
        }

        // A muxer-failure break during a stop()-initiated backpressure
        // wait is teardown, not an error; report it as such.
        if case .muxerFailed = exitReason {
            stateLock.lock()
            let stopped = shouldStop
            stateLock.unlock()
            if stopped { exitReason = .stopRequested }
        }

        // Dual-source sessions: drop any unconsumed merge lookaheads
        // (the loop can break between a fill and a yield).
        freeMergeLookaheads()

        // Flush look-behind pending packets. No successor packet
        // available so duration is set from the fallback (computed
        // from `avg_frame_rate` / `frame_size / sample_rate`). This
        // produces a tail-correct `trun` for the final fragment of
        // the source.
        if let prev = pendingVideoPkt {
            // DTS-based lookup mirrors the in-loop site above; see
            // its comment for why this isn't `prev.pointee.pts`. Live
            // uses the index captured when `prev` was examined.
            let prevSeg = isLive
                ? pendingVideoSegIndex
                : segmentIndex(forSourcePts: prev.pointee.dts)
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
            let prevSeg: Int
            if isLive {
                prevSeg = pendingAudioSegIndex
            } else {
                let prevPtsInVideoTb = av_rescale_q(
                    prev.pointee.pts,
                    audio.inputTimeBase,
                    sourceVideoTimeBase
                )
                prevSeg = segmentIndex(forSourcePts: prevPtsInVideoTb)
            }
            if let muxer = ensureMuxer(forSegmentIndex: prevSeg) {
                finalizeAndWriteAudio(prev, nextDts: nil, audio: audio, muxer: muxer)
            } else {
                var pkt: UnsafeMutablePointer<AVPacket>? = prev
                trackedPacketFree(&pkt)
            }
            pendingAudioPkt = nil
        }

        // EOF tail flush for bridged audio: emit the decoder/FIFO/encoder
        // remainder (~100-200 ms) that the per-feed drain never produces
        // (it only emits FULL encoder frames). Without this the final
        // moments of audio of every bridged VOD title were dropped. Only
        // on a clean EOF; stop/error paths skip it.
        if case .eof = exitReason, let audio = audioConfig, let bridge = audio.bridge {
            for fp in bridge.flush() {
                let fpSeg: Int
                if isLive {
                    fpSeg = liveCurrentSegmentIndex
                } else {
                    let fpPtsInVideoTb = av_rescale_q(
                        fp.pointee.pts,
                        audio.inputTimeBase,
                        sourceVideoTimeBase
                    )
                    fpSeg = segmentIndex(forSourcePts: fpPtsInVideoTb)
                }
                if let muxer = ensureMuxer(forSegmentIndex: fpSeg) {
                    fp.pointee.stream_index = muxer.audioOutputStreamIndex
                    av_packet_rescale_ts(fp, audio.inputTimeBase, muxer.muxerAudioTimeBase)
                    _ = muxer.writePacket(fp)
                }
                var fpVar: UnsafeMutablePointer<AVPacket>? = fp
                trackedPacketFree(&fpVar)
            }
        }

        // Finalize the session-wide muxer's final segment so its
        // bytes land in the cache. write_trailer also fires inside
        // finalize() for the libavformat-side cleanup.
        finalizeSessionMuxerAndAdopt()
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - pumpStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit(
            "[HLSSegmentProducer] pump finished: reason=\(exitReason) "
            + "packetsRead=\(packetsRead) "
            + "packetsWritten=\(packetsWrittenCount) lastError=\(lastError) "
            + "elapsed=\(String(format: "%.0f", elapsedMs))ms cacheCount=\(cache.count)",
            category: .session
        )

        finishCondition.lock()
        didFinishFlag = true
        finishCondition.broadcast()
        finishCondition.unlock()

        onPumpFinished?(exitReason)
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

    /// Strip a single ADTS header off an AAC packet in place so the bytes
    /// are raw AAC, suitable for the fMP4 `mp4a` sample entry. ADTS frames
    /// carry a 7-byte header (or 9 with a CRC, flagged by the
    /// `protection_absent` bit), then the raw AAC payload. We advance the
    /// packet's `data` pointer past the header and shrink `size`; the packet's
    /// `buf` (what `av_packet_unref` frees) is untouched, so this is safe.
    /// No-ops unless the packet actually starts with the 0xFFF ADTS sync,
    /// which guards against double-stripping or a source that already emits
    /// raw AAC. Assumes one raw-data-block per ADTS frame (the universal case
    /// for streamed AAC); multi-block ADTS is not split here.
    private static func stripADTSHeader(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard let data = packet.pointee.data, packet.pointee.size >= 7 else { return }
        // Sync word: 12 bits of 1s (0xFFF) → data[0]==0xFF, top 4 bits of data[1] set.
        guard data[0] == 0xFF, (data[1] & 0xF0) == 0xF0 else { return }
        let headerLen: Int32 = (data[1] & 0x01) != 0 ? 7 : 9
        guard packet.pointee.size > headerLen else { return }
        packet.pointee.data = data.advanced(by: Int(headerLen))
        packet.pointee.size -= headerLen
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

/// Pure DTS ordering for the producer's dual-source pull-merge. Pulled
/// out of the pump so the decision is unit-testable without demuxers:
/// given the two lookahead packets' ordering ticks and time bases,
/// decide whether the SIDE (audio rendition) packet is yielded before
/// the MAIN (video variant) packet.
enum DualSourceMergeOrder {

    /// Compare in a 1/1000000 common clock (microseconds), the same
    /// rescale convention `av_rescale_q` uses for cross-timebase
    /// comparisons elsewhere in the engine. Both live HLS renditions
    /// are MPEG-TS 1/90000 in practice, where the rescale is exact;
    /// for any other pairing the rounding error is sub-microsecond,
    /// far below frame spacing.
    ///
    /// Ties yield MAIN first: at equal timestamps the video packet
    /// should lead the interleave (the muxer's segment cut decisions
    /// key off video keyframes, and a video-first tie matches how
    /// libavformat interleaves a muxed TS).
    static func sideFirst(
        mainTicks: Int64,
        mainTimeBase: AVRational,
        sideTicks: Int64,
        sideTimeBase: AVRational
    ) -> Bool {
        // Int64.min is the "no timestamp" key (see mergeOrderingTicks):
        // yield such a packet immediately rather than rescaling NOPTS.
        if sideTicks == Int64.min { return true }
        if mainTicks == Int64.min { return false }
        let micro = AVRational(num: 1, den: 1_000_000)
        let mainUs = av_rescale_q(mainTicks, mainTimeBase, micro)
        let sideUs = av_rescale_q(sideTicks, sideTimeBase, micro)
        return sideUs < mainUs
    }
}
