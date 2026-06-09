import AVFoundation
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
    /// table in DrHurt's KSPlayer notes (AetherEngine#1), Apple's HLS
    /// Authoring Spec, and Dolby's ETSI TS 103 572. HEVC profiles
    /// 5 / 8 carry HEVC streams; profile 10 carries AV1 streams.
    fileprivate enum DVVariant {
        case none              // not DV
        case profile5          // HEVC P5  (IPT-PQ-c2, no base)     → dvh1 + PQ
        case profile81         // HEVC P8.1 with HDR10-compat base  → dvh1 + PQ  (on DV display)
        case profile84         // HEVC P8.4 with HLG-compat base    → hvc1 + HLG + SUPPLEMENTAL dvh1/db4h
        case profile7          // HEVC P7 dual-layer (BL = HDR10)   → hvc1 + PQ (BL only)
        case profile82         // HEVC P8.2 with SDR-compat base    → reject
        case av1Profile10      // AV1 P10.0 (no base)               → dav1 + PQ
        case av1Profile101     // AV1 P10.1 with HDR10-compat base  → dav1 + PQ
        case av1Profile104     // AV1 P10.4 with HLG-compat base    → av01 + HLG + SUPPLEMENTAL dav1
        case av1Profile102     // AV1 P10.2 with SDR-compat base    → reject
        case unknown           // anything else                     → reject
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
            case .mp3, .opus, .truehd, .dts, .vorbis, .pcm, .mp2, .unsupported:
                // mp3 is theoretically `mp4a.40.34`, but AVPlayer reads
                // any mp4a sample entry as AAC, so we bridge it to FLAC
                // instead, the engine then computes `fLaC` from the
                // bridged stream rather than reading this enum.
                return ""
            }
        }

        /// Codecs that aren't legal in fMP4 and always have to go
        /// through `AudioBridge` for FLAC transcoding.
        ///
        /// Opus is in this set despite being fMP4-spec-legal: AVPlayer
        /// rejects `opus` inside HLS-fMP4 in practice (only the CAF
        /// container path or WebM-with-VP9-video gets Opus direct-play
        /// on Apple platforms; HLS-fMP4 segments with Opus audio fail
        /// header validation downstream). Routing Opus pre-emptively
        /// through the FLAC bridge avoids a "stream-copy header write
        /// failed, retrying with FLAC bridge" round-trip on every
        /// Opus source.
        ///
        /// MP3 is in the same bucket for the same reason: the muxer
        /// happily writes `mp4a.40.34` (MP3-in-MP4 sample entry), but
        /// AVPlayer reads any `mp4a` entry as AAC and fails to decode
        /// the MP3 frames with -11829 / CoreMedia -12848. Bridge cost
        /// on a lossy mono/stereo source is negligible.
        var requiresBridge: Bool {
            switch self {
            case .opus, .mp3, .truehd, .dts, .vorbis, .pcm, .mp2: return true
            default: return false
            }
        }
    }

    // MARK: - State

    private let sourceURL: URL
    private let sourceHTTPHeaders: [String: String]
    private let dvModeAvailable: Bool

    /// Opt-in override from `LoadOptions.keepDvh1TagWithoutDV`.
    /// See LoadOptions for the full rationale — default OFF, set
    /// only for misreporting DV panels.
    private let keepDvh1TagWithoutDV: Bool

    /// Mirror of the user's tvOS Match Content master toggle at load
    /// time. One of two inputs to the master-vs-media-playlist routing
    /// decision (the other is `panelIsInHDRMode`). When `false`, the
    /// panel is user-locked to its current mode regardless of what the
    /// playlist advertises, so the engine treats it as "panel won't
    /// switch into HDR" when the panel is in SDR.
    private let matchContentEnabled: Bool

    /// Whether the connected display can present any HDR (HDR10, HLG,
    /// HDR10+, or DV). Sourced from `AVPlayer.eligibleForHDRPlayback`
    /// upstream. Used together with `matchContentEnabled` and
    /// `panelIsInHDRMode` to decide whether master-playlist routing is
    /// safe.
    private let displaySupportsHDR: Bool

    /// Whether the connected panel was already presenting in HDR at
    /// load time (EDR active, `UIScreen.main.currentEDRHeadroom > 1`).
    /// When `true`, master-playlist routing is safe regardless of
    /// `matchContentEnabled`: the panel already accepts HDR signaling
    /// and the master's `SUPPLEMENTAL-CODECS=dvh1` can upgrade an
    /// HDR10-locked panel to DV mode per DrHurt's empirical test in
    /// AetherEngine#4. When `false`, master is only safe if
    /// `displaySupportsHDR && matchContentEnabled` so AVKit can drive
    /// the panel-mode switch from SDR into HDR.
    private let panelIsInHDRMode: Bool

    /// `dvModeAvailable || keepDvh1TagWithoutDV`. The DV
    /// classification + codec-tag + master-playlist routing branches
    /// key off this single boolean.
    private var effectiveDvMode: Bool { dvModeAvailable || keepDvh1TagWithoutDV }

    /// Optional caller-chosen audio source stream index. When `nil` the
    /// engine falls back to `av_find_best_stream(AVMEDIA_TYPE_AUDIO)`,
    /// which picks whichever stream libavformat ranks highest (typically
    /// the container's default flag, then bitrate). When set, the start
    /// path uses this stream for the muxed audio output, enabling host
    /// driven mid-playback audio track switching via the
    /// `AetherEngine.selectAudioTrack(index:)` reload.
    private let audioSourceStreamIndexOverride: Int32?

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

    /// Per-frame fallback durations (in the respective source
    /// time_base) so the producer can backfill `pkt->duration` when
    /// the matroska demuxer doesn't supply per-block durations.
    /// Computed once at `start()` from `videoStream.avg_frame_rate`
    /// and `audioStream.codecpar` and carried across producer
    /// restarts so the scrub path doesn't have to recompute them.
    private var videoFallbackDurationPts: Int64 = 40
    private var audioFallbackDurationPts: Int64 = 0

    /// First video keyframe PTS (in source video TB), latched after
    /// the segment plan is built. Source `videoStream.start_time`
    /// is non-zero on MKV remuxes where the first usable IDR lives
    /// past PTS=0 (e.g. 5 ms on Lila Giraffe, 88 ms on Bombige
    /// Magenverstimmung). The producer subtracts this from every
    /// video packet's pts/dts so seg-0's fragment tfdt aligns with
    /// the playlist's cumulative-EXTINF origin of 0, AVPlayer's
    /// HLS-fMP4 engine stalls at `waitingToPlay` otherwise.
    private var firstKeyframePts: Int64 = 0

    /// `firstKeyframePts` converted to seconds using the source video
    /// time base. Retained for diagnostics; the actual AVPlayer-clock
    /// to source-PTS translation lives in `playlistShiftSeconds` below,
    /// which the producer updates dynamically on each gate open (the
    /// shift can differ from `firstKeyframeSeconds` on restart sessions
    /// when matroska seek imprecision lands past the planned target).
    public private(set) var firstKeyframeSeconds: Double = 0

    /// Human-readable description of the audio path that won the
    /// stream-copy → FLAC-bridge → video-only cascade for this session.
    /// Set inside `buildProducerWithAudioCascade` and read by the host
    /// for diagnostic surfaces. `nil` while no audio pipeline is live
    /// (source had no audio, or video-only fallback engaged).
    ///
    /// Possible values:
    /// - `"Stream-copy (EAC3+JOC Atmos)"`
    /// - `"Stream-copy (<CODEC>)"` for non-Atmos passthrough
    /// - `"FLAC bridge ← <CODEC>"` for codecs re-encoded into the fMP4
    public private(set) var audioPipelineDescription: String?

    /// `videoShiftPts` of the currently active producer, converted to
    /// seconds via the source video time base. Updated by the producer's
    /// `onVideoShiftKnown` callback on every gate open. AVPlayer's HLS
    /// clock sits at `source_pts - playlistShiftSeconds`; the subtitle
    /// path and side-demuxer seek read this to translate back to
    /// source time.
    public private(set) var playlistShiftSeconds: Double = 0

    /// Source video time base, latched in `start()` so the
    /// `onVideoShiftKnown` callback can convert producer PTS shift to
    /// seconds without having to thread the TB through the callback
    /// signature on every fire.
    private var sourceVideoTbSeconds: Double = 1.0 / 1000.0

    /// Source container's reported total bitrate in bits-per-second,
    /// captured at `start()`. Populates the HLS master playlist's
    /// BANDWIDTH / AVERAGE-BANDWIDTH attributes from real source data
    /// instead of a hardcoded 5 Mbps default. `0` when libavformat
    /// can't compute it from the container metadata; callers fall back
    /// to a safe over-declared estimate to avoid AVPlayer's
    /// `CoreMediaErrorDomain -12318 'Segment exceeds specified
    /// bandwidth for variant'` log entries on high-bitrate sources.
    private var sourceBitrate: Int64 = 0

    /// Fires when the active producer's `playlistShiftSeconds` changes
    /// (initial gate open or restart). AetherEngine wires this to keep
    /// its own published shift in step so the subtitle overlay's cue
    /// lookup uses the right source-time conversion.
    var onPlaylistShiftChanged: (@Sendable (Double) -> Void)?
    /// Fires when a live program-boundary rebase changes the shift.
    /// Carries (newShiftSeconds, seamOutputSeconds): AetherEngine queues
    /// the new shift and applies it to its published clock only when
    /// playback crosses `seamOutputSeconds` on the raw AVPlayer timeline,
    /// so currentTime/sourceTime don't jump while the old program is
    /// still on screen.
    var onPlaylistShiftRebased: (@Sendable (Double, Double) -> Void)?
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

    /// Fires once per session, the first time the producer sees an
    /// HDR10+ T.35 signature in a packet. Hooked by `AetherEngine` to
    /// upgrade the published `videoFormat` from `.hdr10` → `.hdr10Plus`.
    /// Debounced here so producer restarts on scrub don't re-fire.
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    private var hasReportedHDR10Plus = false
    private let hdr10PlusLock = NSLock()

    /// Whether the current audio output route can carry an EAC3+JOC
    /// Atmos bitstream end-to-end. Atmos requires either HDMI
    /// passthrough to an Atmos-decoding AVR / soundbar (DD+ JOC
    /// passthrough, or MAT 2.0 carrier for Apple's 2-channel-tunneled
    /// variant) or Apple's spatial-audio renderer over a spatial-
    /// capable route (AirPods H1 / H2 with HRTF). The Bluetooth A2DP
    /// / LE codec stack (SBC / AAC / aptX, all stereo PCM) cannot
    /// carry EAC3+JOC under any circumstances.
    ///
    /// On A2DP / LE routes AVPlayer's variant-selection refuses to
    /// construct an AVPlayerItem for a JOC variant and fails item
    /// open with `AVFoundationErrorDomain -11868` / `CoreMediaError
    /// Domain -17223` before any segment is fetched (errorLog stays
    /// empty, init.mp4 never requested). Vincent test 2026-05-26 on
    /// Bose SLIII A2DP sink: stream 1 (EAC3 5.1) downmixed and played
    /// fine, audio-track switch to stream 2 (EAC3+JOC Atmos) failed
    /// with the -11868 signature and a "Wiedergabe gestoppt" overlay.
    ///
    /// Returns false only when Atmos is provably impossible
    /// (`.bluetoothA2DP`, `.bluetoothLE`); the cascade then forces
    /// the FLAC bridge so the bed channels still play (JOC objects
    /// are discarded, but no renderer on this route could use them
    /// anyway). Returns true for HDMI, AirPlay, and everything else
    /// since the downstream path handles fallback there (HDMI
    /// handshake decides passthrough vs LPCM; AirPlay receivers vary
    /// and the engine has no portable way to probe them).
    private static func currentRouteSupportsAtmosPassthrough() -> Bool {
        #if os(iOS) || os(tvOS)
        let route = AVAudioSession.sharedInstance().currentRoute
        guard let primary = route.outputs.first else { return true }
        switch primary.portType {
        case .bluetoothA2DP, .bluetoothLE:
            return false
        default:
            return true
        }
        #else
        return true
        #endif
    }

    /// Approximate target segment duration in seconds. The hls muxer
    /// snaps cut points to keyframes at-or-after this threshold, so
    /// actual durations are this + GOP length variance. Apple's HLS
    /// Authoring Spec recommends 6 s as the target; we drop to 4 s
    /// here because initial playback latency is dominated by the
    /// time the producer takes to demux + mux the first segment
    /// before AVPlayer can begin playback (~370 ms at 6 s on a 24 fps
    /// 1440p source over LAN). 4 s halves that, stays comfortably
    /// inside the spec's 2-6 s acceptable range, and the slightly
    /// larger playlist footprint is negligible.
    private static let targetSegmentDuration: Double = 4.0

    // MARK: - Measurement spike: sliding-window prototype (superseded)
    //
    // PRODUCTIZED (Task B3): the throwaway `_liveSlidingPrototype` flag and
    // `slidingWindowSize = 12` constant this block originally documented are
    // GONE. A live session now ALWAYS serves a sliding `.live` playlist
    // (no PLAYLIST-TYPE, no ENDLIST, advancing MEDIA-SEQUENCE) sized from
    // `LoadOptions.dvrWindowSeconds` (with a live-only floor) via the shared
    // `LiveWindowSizing` helper, and the cache evicts strictly below the
    // playlist's firstVisible. The stall the spike observed (AVPlayer paused
    // at 81 s) traced to the EVENT-vs-removal contradiction plus an
    // uncoordinated MEDIA-SEQUENCE slide; the `.live` type plus a
    // minSafeSegments floor that keeps AVPlayer's live-edge buffer inside
    // the window removes it. The off-device measurement below is retained
    // as documentation; on-device tvOS RSS verification is pending with the
    // maintainer and is NOT this task's success bar (sustained no-stall
    // playback + advancing MEDIA-SEQUENCE + bounded on-disk bytes is).
    //
    // SPIKE RESULT (2026-06-07, aetherctl on macOS, h264-ts-sample.ts,
    // 300 s each run):
    //
    // Baseline (append-only EVENT, _liveSlidingPrototype=false):
    //   elapsed   phys_footprint_mb   resident_mb
    //      31s        3625.6              243.1
    //      61s        7085.4              325.9
    //      92s        7088.7               48.2
    //     123s        7087.8               38.8
    //     154s        7088.0               42.0
    //     184s        7089.4               41.9
    //     215s        7089.5               45.6
    //     246s        7089.6               48.2
    //     277s        7088.7               41.4
    //     299s        7087.8               42.6
    //   Last-half slope (154s-299s, 145s window):
    //     phys: 7088.0->7087.8 = -0.08 MB/min (FLAT)
    //     resident: 42.0->42.6 = +0.25 MB/min (noise)
    //   VERDICT for baseline: FLAT after initial AVPlayer load spike.
    //
    // Prototype (sliding MEDIA-SEQUENCE, _liveSlidingPrototype=true):
    //   elapsed   phys_footprint_mb   resident_mb
    //      31s        4190.8              268.6
    //      62s        8312.0              216.0
    //      92s        8311.3               30.8
    //     122s        8311.2               24.8
    //     152s        8311.1               23.9
    //     183s        8311.1               23.7
    //     213s        8311.1               22.8
    //     243s        8311.1               21.9
    //     273s        8311.1               20.9
    //     304s        8311.1               21.8
    //   Last-half slope (152s-304s):
    //     phys: 8311.1->8311.1 = 0.00 MB/min (FLAT)
    //     resident: 23.9->21.8 = -0.83 MB/min (DECLINING - eviction working)
    //   NOTE: AVPlayer stalled (state=paused at 81s). The sliding window
    //   caused AVPlayer to lose its place when segments fell off the back.
    //   The measurement is therefore of a stalled, not live-playing session.
    //
    // VERDICT: SLIDING BOUNDS FOOTPRINT: NO (on macOS with this fixture)
    //
    // Key findings:
    //   1. Both configurations show FLAT phys_footprint after the initial
    //      AVPlayer framework load (~90s). The "leak" from the prior EVENT
    //      experiment (3.0->1.3 MB/sec) was likely a different measurement
    //      context or a larger/real-world source. The tiny H.264 fixture
    //      at ~0.5 MB/s does not reproduce linear growth on macOS.
    //   2. The sliding window DID reduce resident_size (on-disk eviction
    //      works: old seg files are removed and resident pages drop).
    //   3. The sliding window BROKE AVPlayer playback (state=paused). This
    //      is expected: a MEDIA-SEQUENCE sliding window without proper
    //      live-edge sync causes AVPlayer to lose the playlist window
    //      mid-play and pause.
    //   4. phys_footprint on macOS includes compressed VM from all loaded
    //      frameworks (~7-8 GB for AVFoundation + Swift runtime + aetherctl
    //      debug binary). On tvOS the equivalent budget is ~500-800 MB.
    //      This measurement is NOT representative of tvOS jetsam pressure.
    //
    // Conclusion for next task:
    //   The on-disk SegmentCache eviction in the sliding prototype does
    //   reduce disk pressure and resident pages. The phys_footprint plateau
    //   on macOS does not prove AVPlayer actually releases segments on tvOS.
    //   A replaceCurrentItem-based periodic rebuild is still the recommended
    //   approach for bounding tvOS jetsam-relevant footprint. This spike
    //   confirmed the measurement harness works and on-disk eviction is
    //   effective; device-level tvOS measurement is needed for a definitive
    //   answer.
    //
    // End of spike documentation. Sliding is now unconditional for a live
    // session (see `LiveWindowSizing`).

    public init(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        dvModeAvailable: Bool = true,
        displaySupportsHDR: Bool = true,
        keepDvh1TagWithoutDV: Bool = false,
        matchContentEnabled: Bool = true,
        panelIsInHDRMode: Bool = false,
        audioSourceStreamIndexOverride: Int32? = nil,
        initialPositionSeconds: Double? = nil,
        audioBridgeMode: AudioBridgeMode = .surroundCompat,
        isLiveSession: Bool = false,
        dvrWindowSeconds: Double? = nil,
        preopenedDemuxer: Demuxer? = nil
    ) {
        self.sourceURL = url
        self.sourceHTTPHeaders = sourceHTTPHeaders
        self.dvModeAvailable = dvModeAvailable
        self.displaySupportsHDR = displaySupportsHDR
        self.keepDvh1TagWithoutDV = keepDvh1TagWithoutDV
        self.matchContentEnabled = matchContentEnabled
        self.panelIsInHDRMode = panelIsInHDRMode
        self.audioSourceStreamIndexOverride = audioSourceStreamIndexOverride
        self.initialPositionSeconds = initialPositionSeconds
        self.audioBridgeMode = audioBridgeMode
        self.isLiveSession = isLiveSession
        self.dvrWindowSeconds = dvrWindowSeconds
        self.preopenedDemuxer = preopenedDemuxer
    }

    /// Whether this engine is serving an unbounded (live) source. Set
    /// once at init from `LoadOptions.isLive`. When true, `start()`
    /// skips the VOD-only duration guard, mid-duration cue prewarm, and
    /// precomputed segment plan, and instead builds the provider +
    /// producer in their forward-only live cut mode (the producer cuts
    /// a new segment at each video keyframe past the duration target and
    /// appends it to the provider's growing segment list). VOD paths
    /// leave this false and are unaffected.
    private let isLiveSession: Bool

    /// DVR window in seconds for a live session (from `LoadOptions`).
    /// `nil` means live-only: no DVR seek, but the live window is still
    /// bounded to `LiveWindowSizing.liveOnlyFloorSeconds`. Threaded into
    /// the provider so the sliding playlist window and the cache eviction
    /// share one size. Ignored for VOD.
    private let dvrWindowSeconds: Double?

    /// Encoder choice for the audio bridge (used for source codecs that
    /// can't stream-copy into fMP4: TrueHD, DTS, DTS-HD MA, MP3, Opus,
    /// and EAC3-from-MKV-without-dec3-extradata).
    private let audioBridgeMode: AudioBridgeMode

    /// Optional Demuxer that the host already opened + ran
    /// `find_stream_info` on (typically `AetherEngine.load`'s probe
    /// Demuxer for the same URL). When non-nil, `start()` reuses this
    /// instance instead of opening a fresh one, halving the
    /// per-`load()` HTTP probe + `avformat_find_stream_info` work
    /// (~1-3 s on slow CDN). Consumed in `start()`: cleared from
    /// this property and assigned to `self.demuxer`. Unconsumed
    /// preopened demuxers (e.g. if `start()` is never called before
    /// `stop()`) are closed by `stop()` so the resource doesn't
    /// linger after the engine is torn down.
    private var preopenedDemuxer: Demuxer?

    /// Resume position used to seed the sliding-window playlist so its
    /// initial visible range covers the segment AVPlayer will seek to.
    /// Without this seed, a resume at e.g. 4368 s lands AVPlayer on a
    /// playlist that only lists segs 0-29, and the seek either fails
    /// outright or stalls waiting for the playlist to grow past 4368 s.
    private let initialPositionSeconds: Double?

    // MARK: - Public API

    public func start() throws -> URL {
        guard demuxer == nil else { throw HLSVideoEngineError.alreadyStarted }

        // 1. Open the source. If the caller pre-opened a Demuxer for
        //    this URL (typically `AetherEngine.load`'s probe Demuxer)
        //    reuse it — avformat_find_stream_info is already done,
        //    AVIO buffer is warm, the seek that follows for cue
        //    prewarm invalidates any stale read position. Saves
        //    ~1-3 s per load on slow CDN sources by not running
        //    open_input + find_stream_info twice.
        let dem: Demuxer
        if let preopened = preopenedDemuxer {
            dem = preopened
            preopenedDemuxer = nil
        } else {
            dem = Demuxer()
            do {
                try dem.open(url: sourceURL, extraHeaders: sourceHTTPHeaders, isLive: isLiveSession)
            } catch {
                throw HLSVideoEngineError.openFailed(reason: "\(error)")
            }
        }
        demuxer = dem

        let videoIndex = dem.videoStreamIndex
        guard videoIndex >= 0, let videoStream = dem.stream(at: videoIndex) else {
            throw HLSVideoEngineError.noVideoStream
        }
        let codecpar = videoStream.pointee.codecpar!
        let isHEVC = codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
        let isH264 = codecpar.pointee.codec_id == AV_CODEC_ID_H264
        let isAV1 = codecpar.pointee.codec_id == AV_CODEC_ID_AV1

        // Accepted codecs: HEVC, H.264, AV1 (when AVPlayer can decode
        // it on the active platform).
        //
        // AV1 is gated on `VTCapabilityProbe.av1Available`, which
        // returns true on iOS 17+ / macOS 14+ (Apple ships dav1d via
        // VideoToolbox) and false on tvOS (no SW dav1d on tvOS, no HW
        // AV1 on any current Apple TV chip). When the gate says false
        // for AV1, `AetherEngine.load`'s dispatch routes the source
        // through `SoftwarePlaybackHost` instead of reaching this
        // engine, so the guard below never sees an AV1 source on
        // unsupported platforms.
        //
        // VP9 is explicitly NOT here: AVPlayer's HLS manifest parser
        // rejects the `vp09` CODECS attribute even though VideoToolbox
        // can HW-decode VP9 (empirically verified). `AetherEngine.load`
        // dispatches all VP9 sources to `SoftwarePlaybackHost`.
        let av1OK = isAV1 && VTCapabilityProbe.av1Available
        guard isHEVC || isH264 || av1OK else {
            throw HLSVideoEngineError.unsupportedCodec(rawCodecID: codecpar.pointee.codec_id.rawValue)
        }

        let videoTimeBase = videoStream.pointee.time_base
        if videoTimeBase.num > 0, videoTimeBase.den > 0 {
            sourceVideoTbSeconds = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        }
        // Live sources are unbounded: `dem.duration` is 0 (or negative).
        // The VOD-only duration guard, mid-duration cue prewarm, and
        // precomputed keyframe plan all assume a finite source, so the
        // whole block below is gated. For live, the producer's
        // forward-only live cut mode (keyframe + elapsed-time cuts)
        // replaces the precomputed plan, and the provider's segment
        // list grows as the producer appends finalized segments.
        let durationSeconds = dem.duration
        let plan: [Segment]
        if isLiveSession {
            // Unbounded source. No duration guard, no prewarm seek, no
            // precomputed plan. The producer cuts segments live and the
            // provider's list starts empty and grows.
            sourceBitrate = dem.bitRate
            self.firstKeyframePts = 0
            self.firstKeyframeSeconds = 0
            plan = []
            EngineLog.emit(
                "[HLSVideoEngine] LIVE session: skipping duration guard / prewarm / plan "
                + "(dem.duration=\(String(format: "%.1f", durationSeconds))s, producer cuts segments forward)",
                category: .session
            )
        } else {
            guard durationSeconds > 0 else {
                throw HLSVideoEngineError.zeroDuration
            }
            sourceBitrate = dem.bitRate

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
            if keyframes.count >= 2 {
                plan = buildKeyframeSegmentPlan(
                    keyframes: keyframes,
                    videoTimeBase: videoTimeBase,
                    sourceDurationSeconds: durationSeconds
                )
                let detectedFirstKeyframePts = keyframes.sorted().first ?? 0
                self.firstKeyframePts = detectedFirstKeyframePts
                let firstKeyframePts = detectedFirstKeyframePts
                let firstKeyframeSeconds = Double(firstKeyframePts) * Double(videoTimeBase.num) / Double(videoTimeBase.den)
                self.firstKeyframeSeconds = firstKeyframeSeconds
                let videoStreamStart = videoStream.pointee.start_time
                let formatStart = dem.formatStartTime
                EngineLog.emit(
                    "[HLSVideoEngine] segment plan: keyframe-aligned, \(keyframes.count) IRAPs → \(plan.count) segments " +
                    "[firstKeyframePts=\(firstKeyframePts) (\(String(format: "%.3f", firstKeyframeSeconds))s) " +
                    "videoStream.start_time=\(videoStreamStart) format.start_time=\(formatStart)us " +
                    "plan[0].startSeconds=\(String(format: "%.3f", plan.first?.startSeconds ?? -1))]",
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
        }

        // 4. Classify the DV variant + dispatch codec / CODECS /
        //    SUPPLEMENTAL-CODECS / VIDEO-RANGE / DV-strip policy.
        //    Per-profile policy lives in `resolveCodecRoute`.
        let route = try resolveCodecRoute(codecpar: codecpar)
        let codecTagOverride = route.codecTagOverride
        let videoRange = route.videoRange
        let primaryCodecs = route.primaryCodecs
        let supplementalCodecs = route.supplementalCodecs
        let stripDolbyVisionMetadata = route.stripDolbyVisionMetadata
        let dvVariant = route.dvVariant

        let resolution = (Int(codecpar.pointee.width), Int(codecpar.pointee.height))

        let avgFR = videoStream.pointee.avg_frame_rate
        let frameRate: Double? = (avgFR.den > 0 && avgFR.num > 0)
            ? Double(avgFR.num) / Double(avgFR.den)
            : nil
        // HDCP-LEVEL intentionally omitted. Apple Tech Talk 501 recommends
        // `TYPE-1` (HDCP 2.2) for 4K HDR / DV variants in CDN distribution
        // for DRM enforcement, but our local loopback HLS server doesn't
        // carry that requirement (no content protection scope, the source
        // file is already in the user's possession). Vincent test 2026-05-26
        // on HDR10 panel: emitting `HDCP-LEVEL=TYPE-1` caused AVPlayer to
        // filter out the only variant with `item.status=failed` /
        // `AVFoundationErrorDomain -11868` / `tracks count=0` when the
        // Apple TV's HDMI link's HDCP 2.2 negotiation state didn't match
        // the assertion (occurs intermittently in Xcode debug builds and
        // on edge-case HDMI hardware chains). Plain HDR10 sources never
        // had this attribute and play fine on the same setup; matching
        // that behavior for DV-routed-as-HDR10 is the right default.
        let hdcpLevel: String? = nil

        // 5. Scan for in-band HEVC parameter sets when the source's
        //    hvcC carries only the configuration header (numOfArrays
        //    = 0). Some DV Profile 5 MP4 encoders ship parameter sets
        //    in-band on every IRAP instead of in the configuration
        //    record (issue #19 Wandering Earth 2 WEB-DL). Without
        //    VPS / SPS / PPS in the output hvcC, AVPlayer cannot
        //    build a CMVideoFormatDescription for the dvh1 sample
        //    entry and the item fails with CoreMediaErrorDomain -4.
        //    Reads consume packets; the seek-to-0 below resets the
        //    cursor for the producer pump.
        let hevcExtradataOverride = rebuildHEVCExtradataWithInBandParameterSets(
            demuxer: dem,
            videoStreamIndex: videoIndex,
            codecpar: codecpar
        )
        if let rebuilt = hevcExtradataOverride {
            EngineLog.emit(
                "[HLSVideoEngine] rebuilt hvcC with in-band parameter sets: "
                + "\(codecpar.pointee.extradata_size) B → \(rebuilt.count) B",
                category: .session
            )
        }

        // 6. Position the demuxer at the file's first packet so the
        //    producer's pump starts from byte zero. The cue prewarm
        //    above moved the cursor mid-file; libavformat's index is
        //    populated now, this seek-to-0 is cheap. Skipped for live:
        //    there was no prewarm seek to undo, and an unbounded source
        //    is forward-only (seek-to-0 would either no-op or disturb
        //    the producer's read cursor on the loopback feed).
        if !isLiveSession {
            dem.seek(to: 0)
        }

        // 6. Build the segment cache + producer. The producer's
        //    constructor calls avformat_write_header which opens the
        //    init.mp4 sink (no bytes yet) and primes the muxer for
        //    av_write_frame. Pump runs on a worker queue.
        let segmentCache = SegmentCache()
        self.cache = segmentCache

        // DV Profile 5 is defined as IPT-PQ-c2 (BT.2020 primaries, PQ
        // transfer, BT.2020-NCL matrix, limited range). The `dvcC`
        // record implies that signaling, but some P5 MP4 encoders
        // omit the HEVC SPS VUI fields and the container `colr` atom
        // (Wandering Earth 2 WEB-DL 2026-05-28 issue #19: dvh1
        // sample entry + dvcC P5 L6 present, but color_trc /
        // color_primaries / color_space all unspecified, no nclx).
        // Without an explicit transfer signal on the output fMP4,
        // AVPlayer's DV decoder won't engage on the dvh1 sample
        // entry (item.status .failed) even though the elementary
        // stream is well-formed P5. The matroska demuxer reads the
        // Colour element directly into codecpar.color_* so the same
        // content as MKV plays cleanly; the mp4 demuxer has no
        // equivalent fallback. Forcing the canonical P5 color tuple
        // here makes the muxer write a `colr nclx` atom that AVPlayer
        // reads as the missing PQ signal.
        //
        // Primaries / transfer / matrix are spec-fixed for P5 (IPT-PQ-c2
        // has no legal alternate), so forcing them is a repair, not an
        // overwrite of valid data. Color range is the exception: P5 is
        // typically limited but full-range P5 is legal, so a source that
        // already signals a range keeps it (fill-the-gap, not stomp).
        // The #19 repro has range unspecified, so it still resolves to
        // limited; a properly-signaled full-range P5 is no longer forced
        // down to limited (issue #20, DrHurt).
        let p5ColorOverride: MP4SegmentMuxer.ColorOverride?
        if dvVariant == .profile5 {
            let sourceRange = codecpar.pointee.color_range
            p5ColorOverride = MP4SegmentMuxer.ColorOverride(
                primaries: AVCOL_PRI_BT2020,
                trc: AVCOL_TRC_SMPTE2084,
                space: AVCOL_SPC_BT2020_NCL,
                range: sourceRange == AVCOL_RANGE_UNSPECIFIED
                    ? AVCOL_RANGE_MPEG
                    : sourceRange
            )
        } else {
            p5ColorOverride = nil
        }
        let videoConfig = HLSSegmentProducer.StreamConfig(
            codecpar: codecpar,
            timeBase: videoTimeBase,
            codecTagOverride: codecTagOverride,
            stripDolbyVisionMetadata: stripDolbyVisionMetadata,
            colorOverride: p5ColorOverride,
            extradataOverride: hevcExtradataOverride
        )
        self.videoStreamIndex = videoIndex
        self.savedVideoConfig = videoConfig
        self.segmentPlan = plan

        // Per-frame fallback duration in the source video time_base,
        // computed from `avg_frame_rate`. Handed to the producer so
        // it can backfill `pkt->duration` when the source MKV
        // doesn't supply per-block durations (HandBrake / web-rip
        // pipelines drop the TrackEntry `DefaultDuration`, so every
        // packet emerges with `duration == 0`). Without this the
        // mp4 sub-muxer writes `trun.last.duration = 0` and the
        // fragment ends one frame short of where the next fragment
        // starts → AVPlayer's HLS-fMP4 engine sees an unfillable
        // gap, parks on `WaitingToMinimizeStallsReason`, and never
        // queues seg-N+1.
        //
        // 25 fps in a 1/1000 source TB → fallback = 40 ticks (40 ms).
        // 23.976 fps (24000/1001) in 1/1000 → 41 ticks.
        let videoFallbackDuration: Int64 = {
            guard avgFR.num > 0 && avgFR.den > 0,
                  videoTimeBase.num > 0, videoTimeBase.den > 0 else {
                // Defensive default for the 25 fps / 1 ms case.
                return 40
            }
            let num = Int64(avgFR.den) * Int64(videoTimeBase.den)
            let den = Int64(avgFR.num) * Int64(videoTimeBase.num)
            return max(1, num / den)
        }()
        self.videoFallbackDurationPts = videoFallbackDuration

        // 6a. Pick the audio routing: stream-copy for codecs legal in
        //     fMP4, FLAC bridge for those that aren't, drop for the
        //     unsupported tail. The fallback cascade tries stream-copy
        //     first (the common case is `ec-3` for streaming UHD with
        //     Atmos JOC); if the muxer rejects the header (EAC3 from
        //     MKV without a parsed `dec3` extradata is the typical
        //     EINVAL), we retry with the FLAC bridge; if that also
        //     fails we ship video-only.
        //
        // Source selection: caller can override the auto-picked stream
        // (host-driven audio track switching). Override is validated
        // against the container; an invalid index logs and falls back
        // to libavformat's pick so a stale picker selection from a
        // previous title can't strand playback without audio.
        let autoAudioStreamIndex = dem.audioStreamIndex
        let audioStreamIndex: Int32
        if let override = audioSourceStreamIndexOverride {
            if Self.isAudioStream(demuxer: dem, index: override) {
                audioStreamIndex = override
                EngineLog.emit(
                    "[HLSVideoEngine] audio: override accepted, sourceStreamIndex=\(override) (auto would have picked \(autoAudioStreamIndex))",
                    category: .session
                )
            } else {
                EngineLog.emit(
                    "[HLSVideoEngine] audio: override sourceStreamIndex=\(override) invalid (not an audio stream), falling back to auto=\(autoAudioStreamIndex)",
                    category: .session
                )
                audioStreamIndex = autoAudioStreamIndex
            }
        } else {
            audioStreamIndex = autoAudioStreamIndex
        }
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
                // ADTS-AAC from MPEG-TS carries no AudioSpecificConfig in
                // extradata, so the fMP4 mp4a/esds sample entry can't be built
                // and the mux write_header fails (EINVAL → "Could not find tag
                // for codec aac"), forcing the lossy FLAC bridge. Synthesise the
                // ASC into the codecpar (and clear the TS codec_tag) so stream-
                // copy works; the pump then strips the per-frame ADTS header.
                let stripAdts = Self.prepareAACForFMP4(audioStream.pointee.codecpar)
                if stripAdts {
                    EngineLog.emit(
                        "[HLSVideoEngine] audio: AAC/ADTS from TS — synthesised ASC + stripping ADTS for fMP4 stream-copy (no FLAC bridge)",
                        category: .session
                    )
                }
                streamCopyAudio = HLSSegmentProducer.AudioConfig(
                    codecpar: audioStream.pointee.codecpar,
                    timeBase: audioStream.pointee.time_base,
                    sourceStreamIndex: audioStreamIndex,
                    inputTimeBase: audioStream.pointee.time_base,
                    sourceTimeBase: audioStream.pointee.time_base,
                    bridge: nil,
                    stripAacAdts: stripAdts
                )
                // Compute the audio per-frame fallback duration in
                // the source audio time_base. Same need as
                // `videoFallbackDurationPts`: matroska demuxers that
                // drop block durations make every audio packet
                // arrive with `pkt->duration = 0`, and the mp4 sub-
                // muxer's last-sample-in-fragment lookup then writes
                // a zero-duration trailing entry. AC3 / EAC3 are
                // exactly 1536 samples per frame; AAC is 1024.
                let acp = audioStream.pointee.codecpar.pointee
                let sampleRate = Int64(acp.sample_rate)
                let frameSamples: Int64 = {
                    if acp.frame_size > 0 { return Int64(acp.frame_size) }
                    switch acp.codec_id {
                    case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3: return 1536
                    case AV_CODEC_ID_AAC: return 1024
                    case AV_CODEC_ID_MP3: return 1152
                    case AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC: return 4096
                    default: return 1024
                    }
                }()
                let audioTb = audioStream.pointee.time_base
                self.audioFallbackDurationPts = {
                    guard sampleRate > 0, audioTb.num > 0, audioTb.den > 0 else { return 1 }
                    let num = frameSamples * Int64(audioTb.den)
                    let den = sampleRate * Int64(audioTb.num)
                    return max(1, num / den)
                }()
                // EAC3 audio CODECS string. Always `ec-3` per RFC 6381
                // (the canonical IANA-registered identifier for E-AC-3).
                // JOC (Atmos via DD+) signaling stays intact through
                // the `dec3` box in the fMP4 segment, which carries
                // the JOC marker AVPlayer's downstream pipeline reads;
                // the playlist CODECS string never needed `ec+3` to
                // preserve Atmos passthrough.
                //
                // The `ec+3` variant was previously emitted on macOS /
                // tvOS for JOC sources based on an older (incorrect)
                // reading of Apple's HLS Authoring Spec. iOS AVPlayer
                // strictly enforced RFC 6381 and silently dropped any
                // variant with `ec+3`, producing the diagnostic
                // signature `AVFoundationErrorDomain -11848 /
                // CoreMediaErrorDomain -15517 / errorLog 0 events`.
                // tvOS 26.5 now enforces the same strictness (Vincent
                // test 2026-05-26: DV5+Atmos source served as master
                // with `CODECS="dvh1.05.06,ec+3"` got rejected with
                // exactly that error pair on a non-DV HDR10 panel;
                // same source via media playlist played cleanly).
                // Real-world streaming services (Apple TV+, Netflix,
                // Disney+) all ship `ec-3` for both JOC and non-JOC
                // EAC3 tracks; Atmos clients read `dec3` to upgrade.
                let isJOC = compat == .eac3 && acp.profile == 30
                // Route-driven Atmos downgrade. EAC3+JOC stream-copied
                // into an fMP4 variant goes out as MAT 2.0 passthrough
                // and AVPlayer's variant filter only accepts that on
                // routes that can carry Atmos end-to-end. On Bluetooth
                // A2DP / LE the filter rejects the item with -11868
                // before init.mp4 is even fetched. Force the FLAC
                // bridge here so the source EAC3 is decoded to bed-
                // channel PCM and re-encoded by the bridge: object
                // metadata is discarded (no renderer on this route
                // could use it anyway), but the bed channels still
                // play and AVPlayer downmixes to the route's available
                // channel count. See `currentRouteSupportsAtmos
                // Passthrough()` for the route signature.
                if isJOC && !Self.currentRouteSupportsAtmosPassthrough() {
                    EngineLog.emit(
                        "[HLSVideoEngine] audio: JOC source on non-Atmos route (Bluetooth A2DP / LE) — "
                        + "forcing FLAC bridge to avoid AVPlayer -11868 at variant selection. "
                        + "Object metadata discarded; bed channels preserved.",
                        category: .session
                    )
                    bridgePreferred = true
                    streamCopyAudio = nil
                    audioHLSCodecs = nil
                } else {
                    audioHLSCodecs = compat.hlsCodecsString
                    EngineLog.emit(
                        "[HLSVideoEngine] audio: codec=\(compat) → stream-copy as `\(audioHLSCodecs ?? "?")` "
                        + "\(isJOC ? "[JOC=Atmos] " : "")"
                        + "(fallback duration=\(audioFallbackDurationPts) in audioTb \(audioTb.num)/\(audioTb.den))",
                        category: .session
                    )
                }
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
        // Convert resume position (if any) to a segment index so the
        // provider's sliding-window playlist starts with the resume
        // segment already visible.
        let initialIndex = isLiveSession
            ? 0
            : Self.segmentIndex(forSeconds: initialPositionSeconds, plan: plan)
        // Live: no precomputed plan, no restart machinery (the feed is
        // forward-only and the live playlist grows as the producer cuts
        // segments). VOD keeps the restart handler so
        // scrubs relocate the producer.
        let prov = VideoSegmentProvider(
            cache: segmentCache,
            segments: plan,
            codecsString: manifestCodecs,
            supplementalCodecs: supplementalCodecs,
            resolution: resolution,
            videoRange: videoRange,
            frameRate: frameRate,
            hdcpLevel: hdcpLevel,
            sourceBitrate: sourceBitrate,
            initialIndex: initialIndex,
            isLive: isLiveSession,
            liveWindowSizing: LiveWindowSizing(
                targetSegmentDurationSeconds: Self.targetSegmentDuration,
                dvrWindowSeconds: dvrWindowSeconds
            ),
            restartHandler: isLiveSession ? nil : { [weak self] idx in
                self?.restartProducer(at: idx)
            }
        )
        self.provider = prov
        // Live producer appends each finalized segment to the provider's
        // growing list so the live playlist exposes it on the next poll.
        if isLiveSession {
            prod.onLiveSegmentFinalized = { [weak prov] index, durationSeconds, startPtsSeconds, discontinuous in
                prov?.appendLiveSegment(index: index,
                                        startSeconds: startPtsSeconds,
                                        durationSeconds: durationSeconds,
                                        discontinuous: discontinuous)
            }
        }

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

        // Pick the URL handed to AVPlayer.
        //
        // The decision is driven by the active panel's dynamic-range
        // state, not by the source's claim. Master-playlist routing
        // advertises `VIDEO-RANGE=PQ` (or HLG) and optionally
        // `SUPPLEMENTAL-CODECS=dvh1` upfront, which AVPlayer translates
        // into a panel-mode request the moment AVKit sees the manifest.
        // That request can succeed in three ways:
        //
        //   1. Panel is already in HDR (`panelIsInHDRMode == true`).
        //      No transition needed; HDR10 / HLG signaling lands on a
        //      panel that already accepts it. SUPPLEMENTAL-CODECS upgrades
        //      an HDR10 panel into DV mode per DrHurt's manual remux
        //      test in AetherEngine#4.
        //   2. Panel is in SDR, can do HDR (`displaySupportsHDR`), and
        //      `matchContentEnabled` is on. AVKit drives the panel
        //      transition out of SDR using its own criteria pipeline.
        //   3. Otherwise (SDR-only TV, or HDR-capable TV with Match
        //      Dynamic Range off): the panel won't transition, and a
        //      master playlist claiming HDR while the panel sits in SDR
        //      fails asset open with `Cannot Open` (-11848). Route via
        //      media playlist instead so AVPlayer sees no upfront HDR
        //      hint, opens as generic HEVC, and the display tone-maps
        //      the HDR bitstream to its locked mode.
        //
        // Source-side gate: only HDR or DV sources benefit from master
        // routing in the first place. SDR HEVC has nothing to advertise
        // and stays on the media playlist regardless of panel state.
        //
        // DV5 routing on non-DV panels: ALWAYS media playlist.
        //
        // Two tests on Vincent's HDR10-only Samsung (2026-05-26)
        // empirically disproved the "AVPlayer tone-maps DV→HDR10
        // via the master `dvh1.05` CODECS hint" hypothesis (DrHurt
        // #4 #63):
        //
        //   1. With `CODECS="dvh1.05.06,ec+3"` + `VIDEO-RANGE=PQ`:
        //      AVPlayer rejected with `AVFoundationErrorDomain
        //      -11848 / CoreMediaErrorDomain -15517` — CODECS-string
        //      mismatch caused by the non-standard `ec+3` audio
        //      token (fixed in b5462d7).
        //   2. With `CODECS="dvh1.05.06,ec-3"` + `VIDEO-RANGE=PQ`
        //      (canonical RFC 6381 audio token, otherwise identical
        //      master): AVPlayer still rejected with
        //      `AVFoundationErrorDomain -11868 /
        //      AVErrorNoCompatibleAlternatesForExternalDisplay /
        //      CoreMediaErrorDomain -17223`. Same `errorLog dump: 0
        //      events`, same `tracks count=0`, same `item.duration`
        //      parsed from EXTINFs but no playback.
        //
        // The -11868 vs the earlier -11848 is the actual variant-
        // filter rejection: tvOS 26.5 sees a `dvh1.05` master
        // variant, the panel has no DV capability and no fallback
        // variant exists (P5 has no SUPPLEMENTAL-CODECS brand for
        // backward-compat — `/db1p` and `/db4h` only work for P8.1
        // / P8.4), so "no compatible alternates" is the literal
        // truth. Matches the published Apple HLS Authoring Spec
        // contract: real streaming services (Apple TV+, Netflix,
        // Disney+) ship P5 alongside a sibling HDR10 variant for
        // non-DV clients; single-variant P5 master is not a
        // supported pattern on AVPlayer.
        //
        // DrHurt's positive #63 result was on a DV-capable system
        // with HDR10 panel mode active — there the variant filter
        // is lenient because the system reports DV decoder
        // availability. On a true non-DV system the filter is
        // strict and rejects unconditionally.
        //
        // So: P5 on any non-DV panel always routes via media. Plain
        // HEVC base never exists for P5 (IPT-PQ-c2 elementary stream
        // is the only thing the source carries), and AVPlayer's
        // media-playlist tonemap path via the dvh1 sample entry in
        // init.mp4 handles the DV-to-display downgrade internally.
        //
        // DV8.1 and DV8.4 on non-DV panels already downgrade their
        // CODECS string to `hvc1.*` in the HEVC dispatch above + strip
        // DV side data, so the master-side codec filter accepts them
        // and the standard `sourceIsHDR && panelReadyForHDR` check
        // below routes them correctly.
        let sourceIsHDR = videoRange != .sdr || effectiveDvMode
        // `panelIsInHDRMode` is authoritative here. AetherEngine.load reads
        // `UIScreen.currentEDRHeadroom` AFTER `DisplayCriteriaController.
        // waitForSwitch` settles and passes the empirical result down, so a
        // panel that's about to switch to HDR via match-range already reads
        // as HDR by the time we route here.
        //
        // Previously this OR-fell-through via `(displaySupportsHDR &&
        // matchContentEnabled)`, but tvOS's match-content API exposes only
        // one combined `isDisplayCriteriaMatchingEnabled` flag — there's no
        // way to tell whether Match Dynamic Range specifically is on or
        // only Match Frame Rate. Trusting the combined flag as a panel-
        // will-switch proxy broke playback for users with rate-match ON +
        // range-match OFF: we routed master with `VIDEO-RANGE=PQ`, the
        // panel stayed SDR, AVPlayer rejected with -11848 / -11868 (DrHurt
        // #4 2026-05-27).
        let panelReadyForHDR = panelIsInHDRMode
        let dv5OnNonDVPanel = dvVariant == .profile5 && !effectiveDvMode
        let useMasterPlaylist: Bool
        if dv5OnNonDVPanel {
            useMasterPlaylist = false
        } else {
            useMasterPlaylist = sourceIsHDR && panelReadyForHDR
        }
        let resolvedURL: URL? = useMasterPlaylist
            ? srv.playlistURL
            : srv.mediaPlaylistURL
        guard let url = resolvedURL else {
            stop()
            throw HLSVideoEngineError.openFailed(reason: "server URL not ready")
        }
        self.servingMasterPlaylist = useMasterPlaylist
        EngineLog.emit("[HLSVideoEngine] serving on \(url.absoluteString) (dvModeAvailable=\(dvModeAvailable) effectiveDvMode=\(effectiveDvMode) panelIsHDR=\(panelIsInHDRMode) displaySupportsHDR=\(displaySupportsHDR) matchContent=\(matchContentEnabled) sourceIsHDR=\(sourceIsHDR) useMaster=\(useMasterPlaylist) videoRange=\(videoRange) dvVariant=\(dvVariant))")
        return url
    }

    /// Resolved routing decision exposed for the host's AVPlayerItem
    /// configuration. `true` when `start()` chose the master playlist
    /// (HDR / DV signaling reaches AVPlayer); `false` for the media
    /// playlist auto-tonemap path. Read after `start()` returns;
    /// undefined before. Host wires this into AVPlayerItem flags that
    /// only make sense when AVPlayer can engage an HDR pipeline.
    public private(set) var servingMasterPlaylist: Bool = false

    // MARK: - Diagnostics

    /// Snapshot of internal pipeline counters for the engine memory
    /// probe. All fields are point-in-time reads; no locking across
    /// fields, so individual values may be from slightly different
    /// instants (acceptable for a 30 s probe).
    public struct DiagnosticStats {
        public let segmentCacheCount: Int
        public let segmentCacheBytes: Int
        public let producerPacketsWritten: Int
        public let avioBytesFetched: Int64
        public let audioFifoSamples: Int
        /// Bytes held in AudioBridge's growable PCM buffers (FIFO +
        /// swr delay). Zero if the bridge isn't active (stream-copy
        /// audio path or video-only). Linear growth across probe
        /// samples implicates the bridge as a leak source.
        public let audioBridgeFifoBytes: Int
        public let audioBridgeSwrBytes: Int
        public var audioBridgeTotalBytes: Int { audioBridgeFifoBytes + audioBridgeSwrBytes }
        /// Cumulative bytes the current MP4SegmentMuxer has emitted
        /// through its FragmentSplitter over its lifetime. Resets on
        /// muxer rebuild (currently never — the muxer is session-long).
        /// Used as the muxer-leak attribution baseline.
        public let muxerLifetimeFragmentBytes: Int
        public let muxerFragmentCuts: Int
        /// Accepted-not-yet-closed connections on the local HLS server.
        /// Steady (1-3) is normal AVPlayer keep-alive; rising count
        /// would point to a CFNetwork client leak.
        public let serverConnectionCount: Int
        /// Lifetime bytes the HLS server has sent over all responses
        /// (Data writeAll + sendfile combined). Should track
        /// `muxerLifetimeFragmentBytes` for the segment-serve path
        /// (modulo init.mp4 + playlist responses). Divergence flags a
        /// drop or duplicate.
        public let serverLifetimeBytesSent: Int
        /// Of `serverLifetimeBytesSent`, how many went via the
        /// `sendfile(2)` fast path (file → socket kernel-side, no
        /// Foundation `Data`). Used to verify the fast path is
        /// actually taken vs. silently falling back to the
        /// Data-allocation path on every fetch.
        public let serverSendfileBytesSent: Int
        /// `av_packet_alloc` count minus `av_packet_free` count from
        /// the `PacketBalanceTracker` covering all engine packet-
        /// handling paths (demuxer / bridge / producer / subtitle /
        /// SW host). Steady low single digits = balanced. Linear
        /// growth = a packet leak in one of our paths.
        public let packetsAlive: Int
        public let packetsTotalAllocs: Int
        /// Number of times the producer's `runPumpLoop` was entered for
        /// a restart session (restartTargetVideoDts != Int64.min). Each
        /// scrub or seek that triggers a producer restart increments this
        /// by one. Zero for non-restart (phase-A) sessions.
        public let producerRestartCount: Int
        /// Most recently measured open-audio-gate vs. open-video-gate
        /// gap in source-clock milliseconds. Matches the value logged
        /// at the gap-detection site. Zero until the first audio gate
        /// opens in a session.
        public let lastAVGapMs: Double
        /// Lifetime count of HTTP requests served by the loopback HLS
        /// server (one per `processRequest` call). Includes playlist,
        /// init-segment, and media-segment fetches.
        public let serverRequestCount: Int
    }

    // MARK: - Live telemetry forwarders

    // Flat counters used by `LiveTelemetrySampler`. Each forwarder reads
    // from the subsystem that owns the source-of-truth field (same source
    // as `diagnosticStats()` above) but exposes it as a single getter so
    // the sampler doesn't have to walk private subsystem pointers. All
    // return zero when the relevant subsystem isn't built yet.

    /// Bytes the active demuxer has fetched from the source. Mirrors
    /// `Demuxer.avioBytesFetched`.
    var demuxerBytesFetched: Int64 { demuxer?.avioBytesFetched ?? 0 }

    /// Resident bytes in the loopback HLS segment cache.
    var segmentCacheTotalBytes: Int { cache?.totalBytes ?? 0 }

    /// Authoritative on-disk byte footprint of the resident segment files
    /// (freshly stat-ed). 0 when no native session is active. Used by the
    /// `aetherctl live --report-cache-bytes` harness to verify the live
    /// window keeps disk bounded.
    var segmentCacheDiskBytes: Int64 { cache?.diskBytes() ?? 0 }

    /// Producer restart sessions in the current session.
    var producerRestartCount: Int { producer?.restartCount ?? 0 }

    /// Lifetime bytes emitted by the active MP4SegmentMuxer.
    var muxedBytesLifetime: Int { producer?.muxerLifetimeFragmentBytes ?? 0 }

    /// Lifetime bytes the loopback HLS server has written to AVPlayer.
    var serverLifetimeBytesSent: Int { server?.lifetimeBytesSent ?? 0 }

    /// HTTP requests served by the loopback HLS server.
    var serverRequestCount: Int { server?.requestCount ?? 0 }

    /// Bytes currently held in AudioBridge's FIFO + swr-delay buffers.
    var audioBridgeLiveBytes: Int { audioBridge?.liveBytes.totalBytes ?? 0 }

    /// Most recently measured audio/video gate gap in source-clock ms.
    var lastAVGapMs: Double { producer?.lastAVGapMs ?? 0 }

    /// Read the current pipeline counters. Returns zeros for any
    /// sub-system that hasn't been constructed yet (pre-start or
    /// post-stop).
    public func diagnosticStats() -> DiagnosticStats {
        let abLive = audioBridge?.liveBytes
        return DiagnosticStats(
            segmentCacheCount: cache?.count ?? 0,
            segmentCacheBytes: cache?.totalBytes ?? 0,
            producerPacketsWritten: producer?.packetsWrittenCount ?? 0,
            avioBytesFetched: demuxer?.avioBytesFetched ?? 0,
            audioFifoSamples: audioBridge?.fifoSampleCount ?? 0,
            audioBridgeFifoBytes: abLive?.fifoBytes ?? 0,
            audioBridgeSwrBytes: abLive?.swrDelayBytes ?? 0,
            muxerLifetimeFragmentBytes: producer?.muxerLifetimeFragmentBytes ?? 0,
            muxerFragmentCuts: producer?.muxerFragmentCuts ?? 0,
            serverConnectionCount: server?.activeConnectionCount ?? 0,
            serverLifetimeBytesSent: server?.lifetimeBytesSent ?? 0,
            serverSendfileBytesSent: server?.lifetimeSendfileBytes ?? 0,
            packetsAlive: PacketBalanceTracker.alive,
            packetsTotalAllocs: PacketBalanceTracker.totalAllocs,
            producerRestartCount: producer?.restartCount ?? 0,
            lastAVGapMs: producer?.lastAVGapMs ?? 0,
            serverRequestCount: server?.requestCount ?? 0
        )
    }

    /// Bump the sliding-window playlist so segments covering `seconds`
    /// are listed before AVPlayer issues the seek-driven segment fetch.
    /// Called by `AetherEngine.seek(to:)`. No-op if the position
    /// already falls inside the visible window or if the playlist has
    /// already transitioned to VOD-with-ENDLIST.
    public func extendVisibleWindow(toCoverSeconds seconds: Double) {
        guard let prov = provider else { return }
        let idx = Self.segmentIndex(forSeconds: seconds, plan: segmentPlan)
        prov.extendVisibleWindow(toCover: idx)
    }

    /// Locate the segment that contains a given source-time offset.
    /// Linear scan, fine for our 2k-segment scale on the engine's
    /// rare-event paths (load + seek). Returns 0 if `seconds` is nil
    /// or negative, last index if past the end.
    fileprivate static func segmentIndex(forSeconds seconds: Double?, plan: [Segment]) -> Int {
        guard let s = seconds, s > 0, !plan.isEmpty else { return 0 }
        for (i, seg) in plan.enumerated() {
            if s < seg.startSeconds + seg.durationSeconds {
                return i
            }
        }
        return plan.count - 1
    }

    public func stop() {
        // Snapshot every resource into locals under the lock so we can
        // (a) clear the instance state immediately and (b) hand the
        // resources to a detached cleanup task that doesn't capture
        // self. Per Delarkz's AetherEngine#10, SwiftUI releases its
        // @State engine reference on the main thread; without the
        // detach the dismiss path would freeze the host UI for up to
        // 3 seconds while the producer's pump (potentially parked
        // inside demuxer.readPacket waiting on an HTTP byte-range
        // read) finishes exiting.
        restartLock.lock()
        let p = producer
        producer = nil
        let s = server
        server = nil
        let c = cache
        cache = nil
        let ab = audioBridge
        audioBridge = nil
        let d = demuxer
        demuxer = nil
        // Pick up the preopened Demuxer if start() never consumed it
        // (e.g. an exception path before start()). Closing both d and
        // preopened is safe: when start() ran, preopened was set to
        // nil and only d holds the ref; when start() never ran, d is
        // nil and preopened holds it. Calling close on a nil is a
        // no-op; calling close twice is idempotent on Demuxer either
        // way.
        let preopened = preopenedDemuxer
        preopenedDemuxer = nil
        let prov = provider
        provider = nil
        savedVideoConfig = nil
        savedAudioConfig = nil
        segmentPlan = []
        restartLock.unlock()

        // Send the cancel signal synchronously so the pump starts
        // unwinding immediately. waitForFinish + the rest of the
        // resource teardown move to a detached task.
        p?.stop()

        // Wake any server thread parked in an LL-HLS blocking playlist
        // reload. The producer is stopped, so no segment append will
        // ever broadcast the condition again; without this the parked
        // thread sleeps out its full 18-30 s timeout holding the
        // provider alive and then writes into a possibly-recycled fd.
        prov?.cancelWaiters()

        // Unblock the pump's read synchronously. A live producer can be parked
        // inside av_read_frame in the AVIO reconnect loop, which only exits on
        // the reader's closed flag (not the producer's cancel flag). Without
        // this, the detached waitForFinish below blocks for up to 3s while the
        // old live source storms reconnects (e.g. Jellyfin 400s a superseded
        // transcode) until the reconnect cap is hit, polluting the next
        // session on the shared engine. markClosed is lock-free and
        // idempotent; the detached close() still frees the resources.
        d?.markClosed()
        preopened?.markClosed()

        // Detached cleanup. The closure captures the local resource
        // strong refs (not self), so they live as long as the cleanup
        // needs them. The producer waitForFinish has to come before
        // closing the demuxer / cache / server because the pump
        // accesses them by reference during the unwind; the closure
        // serialises that ordering off-thread.
        Task.detached {
            _ = p?.waitForFinish(timeout: 3.0)
            s?.stop()
            c?.close()
            ab?.close()
            d?.close()
            preopened?.close()
        }
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

        // Scan-forward + dynamic-shift wiring.
        //
        // Video scan target (for restart sessions): plan[N].startPts
        // in source video TB. The producer scans forward to the
        // first real `AV_PKT_FLAG_KEY` packet with dts ≥ this value,
        // which may land at a later IDR than the target when the
        // planned position is a non-IDR keyframe in libavformat's
        // wider index. Audio scan target is set DYNAMICALLY by the
        // producer once video lands (so audio and video first
        // samples come from the same source-time).
        //
        // Desired first tfdt (the value the muxer's fragment tfdt
        // ends up at after the dynamic shift applies): for
        // baseIndex == 0 this is 0 (playlist origin); for restart
        // sessions it's plan[N].startSeconds in source TB =
        // plan[N].startPts - firstKeyframePts. The producer computes
        // shift = actualFirstDts - desiredFirstTfdt on the first
        // kept packet per stream and applies it to all subsequent
        // packets, giving aligned tfdts on both streams without
        // relying on the demuxer hitting the plan exactly.
        let videoTarget: Int64
        let desiredVideoTfdt: Int64
        let desiredAudioTfdt: Int64
        if baseIndex > 0, baseIndex < segmentPlan.count {
            videoTarget = segmentPlan[baseIndex].startPts
            desiredVideoTfdt = segmentPlan[baseIndex].startPts - firstKeyframePts
            // Rescale into the source audio TB (not the bridge encoder
            // input TB). The producer subtracts this value from the
            // first kept audio packet's dts to compute audioShiftPts,
            // and that dts is ALWAYS in source audio TB. Pre-fix the
            // rescale targeted bridge.inputTimeBase (1/48000), so for
            // FLAC-bridged DTS sources the resulting shift was off by
            // a factor of 48 and the log line showed
            // `shift=-152485195` garbage. Stream-copy was unaffected
            // since sourceTimeBase == inputTimeBase there; the bug was
            // bridge-only and silent (bridge.feed re-stamps PTS
            // independently via nextEncoderPTS so the shift's effect
            // on output PTS is null, but the gate-target side of the
            // calculation was inconsistent).
            desiredAudioTfdt = savedAudioConfig.map {
                av_rescale_q(desiredVideoTfdt, cfg.timeBase, $0.sourceTimeBase)
            } ?? 0
        } else {
            videoTarget = Int64.min
            desiredVideoTfdt = 0
            desiredAudioTfdt = 0
        }

        // Build the producer's segment-boundary slice. Each entry is
        // the startPts of one segment in source video TB; the last
        // entry is the endPts of the final segment so the producer
        // has a known upper bound for its segmentIndex() lookup. The
        // producer indexes this slice with `i = absoluteSegIdx - baseIndex`.
        let plannedSegs = segmentPlan[baseIndex..<segmentPlan.count]
        var segmentBoundaries: [Int64] = plannedSegs.map { $0.startPts }
        if let last = plannedSegs.last {
            segmentBoundaries.append(last.endPts)
        }

        let prod = try HLSSegmentProducer(
            demuxer: dem,
            videoStreamIndex: videoStreamIndex,
            video: cfg,
            audio: savedAudioConfig,
            cache: cache,
            baseIndex: baseIndex,
            targetSegmentDurationSeconds: Self.targetSegmentDuration,
            videoFallbackDurationPts: videoFallbackDurationPts,
            audioFallbackDurationPts: audioFallbackDurationPts,
            restartTargetVideoDts: videoTarget,
            desiredFirstVideoTfdtPts: desiredVideoTfdt,
            desiredFirstAudioTfdtPts: desiredAudioTfdt,
            segmentBoundaries: segmentBoundaries,
            isLive: isLiveSession
        )
        prod.onFirstHDR10PlusDetected = { [weak self] in
            self?.notifyHDR10PlusOnce()
        }
        prod.onVideoShiftKnown = { [weak self] shiftPts in
            self?.handleVideoShiftKnown(shiftPts)
        }
        prod.onLiveTimelineRebase = { [weak self] shiftPts, seamOutputSeconds in
            self?.handleLiveTimelineRebase(shiftPts, seamOutputSeconds: seamOutputSeconds)
        }
        return prod
    }

    /// Converts the producer's `videoShiftPts` (in source video TB)
    /// to seconds and notifies the engine + AetherEngine that the
    /// AVPlayer-clock-to-source-PTS translation may have changed.
    /// Fires on initial start (shift ≈ firstKeyframeSeconds) and on
    /// every restart (shift can be larger when matroska seek
    /// imprecision lands past the planned target).
    private func handleVideoShiftKnown(_ shiftPts: Int64) {
        let seconds = shiftPts == Int64.min ? 0 : Double(shiftPts) * sourceVideoTbSeconds
        playlistShiftSeconds = seconds
        onPlaylistShiftChanged?(seconds)
    }

    /// Live program-boundary rebase. Unlike `handleVideoShiftKnown` this
    /// does NOT push the new shift through `onPlaylistShiftChanged`: the
    /// shift describes packets at the producer edge, which AVPlayer
    /// renders ~buffer + holdback later, so the host clock must keep the
    /// OLD shift until playback crosses the seam. The engine-side
    /// `playlistShiftSeconds` tracks the producer edge immediately
    /// (internal bookkeeping); the deferred host-facing activation goes
    /// through `onPlaylistShiftRebased`.
    private func handleLiveTimelineRebase(_ shiftPts: Int64, seamOutputSeconds: Double) {
        let seconds = shiftPts == Int64.min ? 0 : Double(shiftPts) * sourceVideoTbSeconds
        playlistShiftSeconds = seconds
        onPlaylistShiftRebased?(seconds, seamOutputSeconds)
    }

    /// Debounced relay. Producers each have their own once-per-instance
    /// scan latch; this guards against re-firing after a scrub restart
    /// (which builds a fresh producer that re-scans from packet zero).
    private func notifyHDR10PlusOnce() {
        hdr10PlusLock.lock()
        let alreadyFired = hasReportedHDR10Plus
        hasReportedHDR10Plus = true
        hdr10PlusLock.unlock()
        if !alreadyFired {
            onFirstHDR10PlusDetected?()
        }
    }

    /// AAC carried as ADTS (the typical MPEG-TS shape) arrives with no
    /// AudioSpecificConfig in `extradata`, so the fMP4 `mp4a`/`esds` sample
    /// entry can't be written and the mux fails. Synthesise a 2-byte ASC from
    /// the codecpar's sample rate / channel count and install it as extradata,
    /// and clear the codec_tag the mpegts demuxer leaves (the mov muxer rejects
    /// the TS tag). Returns true when it applied the fix — the caller flags the
    /// pump to strip the per-frame ADTS header. No-op (false) for non-AAC or
    /// AAC that already carries an ASC (then the existing copy path works).
    private static func prepareAACForFMP4(
        _ codecpar: UnsafeMutablePointer<AVCodecParameters>
    ) -> Bool {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_AAC else { return false }
        guard codecpar.pointee.extradata == nil || codecpar.pointee.extradata_size == 0 else { return false }
        let freqTable: [Int32] = [96000, 88200, 64000, 48000, 44100, 32000,
                                  24000, 22050, 16000, 12000, 11025, 8000, 7350]
        guard let freqIdx = freqTable.firstIndex(of: codecpar.pointee.sample_rate) else { return false }
        let channels = max(1, Int(codecpar.pointee.ch_layout.nb_channels))
        let chanConfig = channels <= 7 ? channels : 2
        // audioObjectType: basic AAC profiles map profile→profile+1 (LC = 2);
        // default to 2 (AAC-LC, the mp4a.40.2 the engine advertises) otherwise.
        let profile = Int(codecpar.pointee.profile)
        let aot = (profile >= 0 && profile <= 3) ? profile + 1 : 2
        let asc: [UInt8] = [
            UInt8((aot << 3) | (freqIdx >> 1)),
            UInt8(((freqIdx & 1) << 7) | (chanConfig << 3)),
        ]
        if codecpar.pointee.extradata != nil { av_freep(&codecpar.pointee.extradata) }
        codecpar.pointee.extradata_size = 0
        let total = asc.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let buf = av_malloc(total)?.assumingMemoryBound(to: UInt8.self) else { return false }
        asc.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { memcpy(buf, base, asc.count) }
        }
        memset(buf + asc.count, 0, Int(AV_INPUT_BUFFER_PADDING_SIZE))
        codecpar.pointee.extradata = buf
        codecpar.pointee.extradata_size = Int32(asc.count)
        codecpar.pointee.codec_tag = 0
        return true
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
        // Detect if the source is EAC3+JOC Atmos so we can flag any
        // stream-copy → FLAC-bridge fallback as an Atmos downgrade.
        // EAC3 profile=30 is the JOC marker libavformat's demuxer sets
        // on Atmos streams. If this fallback ever fires the user is
        // silently getting lossless bed-channel FLAC instead of Atmos
        // (object metadata is lost in the PCM intermediate), so we
        // want this loud in the log so it surfaces before someone
        // notices their AVR's Atmos indicator stayed off.
        let sourceIsAtmos: Bool = {
            guard let stream = sourceAudioStream else { return false }
            return stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_EAC3
                && stream.pointee.codecpar.pointee.profile == 30
        }()

        // If the source already needs the bridge (TrueHD / DTS / Vorbis
        // / PCM / MP2), skip the stream-copy attempt — we know the
        // muxer won't accept those codecs in fMP4 anyway.
        // Source-codec label used for diagnostic strings if the cascade
        // makes a decision worth surfacing. Falls back to "audio" so
        // that a missing codec entry in libavcodec (extremely rare,
        // mostly out-of-band-extension exotica) doesn't produce
        // "Stream-copy (nil)" in the UI.
        let sourceCodecLabel: String = {
            if let stream = sourceAudioStream,
               let cstr = avcodec_get_name(stream.pointee.codecpar.pointee.codec_id) {
                return String(cString: cstr).uppercased()
            }
            return "audio"
        }()

        if !preferBridge, let cfg = streamCopyAudio, let vcfg = savedVideoConfig {
            // Pre-flight the mp4 muxer's write_header to detect cases
            // the cascade would otherwise miss. makeProducer no longer
            // exercises avformat_write_header itself — the first muxer
            // alloc happens lazily inside the producer's pump on the
            // first keep-packet, well after this scope has returned.
            // Without the probe a failure there (typical case:
            // EAC3-from-MKV whose CodecPrivate lacks the dec3 extradata
            // the mov muxer needs to write the audio track's
            // sample-entry, returns -22 / "Cannot write moov atom
            // before EAC3 packets parsed") leaves the producer stuck
            // and the bridge fallback below never fires.
            let probeVideo = MP4SegmentMuxer.VideoConfig(
                codecpar: vcfg.codecpar,
                timeBase: vcfg.timeBase,
                codecTagOverride: vcfg.codecTagOverride,
                stripDolbyVisionMetadata: vcfg.stripDolbyVisionMetadata,
                colorOverride: vcfg.colorOverride,
                extradataOverride: vcfg.extradataOverride
            )
            let probeAudio = MP4SegmentMuxer.AudioConfig(
                codecpar: cfg.codecpar,
                timeBase: cfg.timeBase
            )
            let probeRet = MP4SegmentMuxer.probeWriteHeader(
                video: probeVideo,
                audio: probeAudio
            )
            if probeRet < 0 {
                if sourceIsAtmos {
                    EngineLog.emit(
                        "[HLSVideoEngine] WARNING: Atmos downgrade — EAC3+JOC stream-copy probe rejected by mp4 muxer (ret=\(probeRet)). "
                        + "Falling back to FLAC bridge: bed channels stay lossless, but object metadata is lost. "
                        + "Source: \(sourceAudioStream?.pointee.codecpar.pointee.profile.description ?? "?") profile, "
                        + "channels=\(sourceAudioStream?.pointee.codecpar.pointee.ch_layout.nb_channels ?? -1). "
                        + "If you see this in production, capture the source MKV — dec3 extradata reconstruction can recover Atmos.",
                        category: .session
                    )
                } else {
                    EngineLog.emit(
                        "[HLSVideoEngine] audio stream-copy probe failed (ret=\(probeRet)), retrying with FLAC bridge",
                        category: .session
                    )
                }
                // Fall through to bridge attempt.
            } else {
                self.savedAudioConfig = cfg
                do {
                    let prod = try makeProducer(baseIndex: 0)
                    if sourceIsAtmos {
                        EngineLog.emit(
                            "[HLSVideoEngine] EAC3+JOC Atmos: stream-copy engaged, MAT 2.0 passthrough intact",
                            category: .session
                        )
                    }
                    self.audioPipelineDescription = sourceIsAtmos
                        ? "Stream-copy (EAC3+JOC Atmos)"
                        : "Stream-copy (\(sourceCodecLabel))"
                    return prod
                } catch {
                    EngineLog.emit(
                        "[HLSVideoEngine] makeProducer failed after stream-copy probe succeeded (\(error)), retrying with FLAC bridge",
                        category: .session
                    )
                    // Fall through to bridge attempt.
                }
            }
        } else if preferBridge && sourceIsAtmos && Self.currentRouteSupportsAtmosPassthrough() {
            // Caller pre-decided bridge before reaching here. For Atmos
            // that's wrong UNLESS the route can't carry Atmos at all
            // (Bluetooth A2DP / LE), in which case the cascade setup
            // intentionally forced the bridge and already logged a
            // route-specific message. The remaining case — pre-bridge
            // on an Atmos-capable route — would silently degrade
            // Atmos, so diagnose it explicitly.
            EngineLog.emit(
                "[HLSVideoEngine] WARNING: Atmos source pre-routed to FLAC bridge without stream-copy attempt — Atmos lost. Investigate the codec compatibility table.",
                category: .session
            )
        }

        // FLAC bridge attempt. Requires a source audio stream.
        if let audioStream = sourceAudioStream, sourceAudioStreamIndex >= 0 {
            do {
                let bridge = try AudioBridge(
                    srcCodecpar: audioStream.pointee.codecpar,
                    srcTimeBase: audioStream.pointee.time_base,
                    mode: audioBridgeMode
                )
                if let cp = bridge.encoderCodecpar {
                    let cfg = HLSSegmentProducer.AudioConfig(
                        codecpar: cp,
                        timeBase: bridge.encoderTimeBase,
                        sourceStreamIndex: sourceAudioStreamIndex,
                        inputTimeBase: bridge.encoderTimeBase,
                        sourceTimeBase: audioStream.pointee.time_base,
                        bridge: bridge
                    )
                    self.savedAudioConfig = cfg
                    self.audioBridge = bridge
                    do {
                        let prod = try makeProducer(baseIndex: 0)
                        let (hlsCodec, pipelineLabel): (String, String)
                        switch audioBridgeMode {
                        case .surroundCompat:
                            hlsCodec = "ec-3"
                            pipelineLabel = "EAC3 5.1 bridge ← \(sourceCodecLabel)"
                        case .lossless:
                            hlsCodec = "fLaC"
                            pipelineLabel = "FLAC bridge ← \(sourceCodecLabel)"
                        }
                        audioHLSCodecs = hlsCodec
                        self.audioPipelineDescription = pipelineLabel
                        return prod
                    } catch {
                        EngineLog.emit(
                            "[HLSVideoEngine] \(audioBridgeMode.rawValue) bridge header write failed (\(error)), falling back to video-only",
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
        self.audioPipelineDescription = nil
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

        // Seek the demuxer to the ABSOLUTE source-PTS of the target
        // segment's first keyframe, not to the relative playlist time.
        // segmentPlan[N].startSeconds is relative to startPts0 (the
        // first video keyframe's PTS). If startPts0 != 0 (common when
        // a source has B-frames buffered at the head or has been
        // re-muxed with a non-zero start), seeking with the relative
        // value lands a-keyframe-or-more behind the intended one
        // (av_seek_frame's AVSEEK_FLAG_BACKWARD rolls back from the
        // target, and sorted[N] > target-in-relative-source-time when
        // startPts0 > 0). The muxer then emits seg-N with content
        // starting at sorted[N-1]'s source time, AVPlayer's playlist
        // clock advances per EXTINFs (which are correct as keyframe
        // diffs), and embedded subtitle cue.startTime stays in
        // absolute source-PTS. Net effect: subtitles appear up to one
        // segment duration AHEAD of the corresponding audio.
        let absoluteTargetPts = segmentPlan[idx].startPts
        let videoTb = savedVideoConfig?.timeBase ?? AVRational(num: 1, den: 1000)
        let absoluteTargetSeconds = Double(absoluteTargetPts) * Double(videoTb.num) / Double(videoTb.den)
        demuxer?.seek(to: absoluteTargetSeconds)
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
            "[HLSVideoEngine] producer restarted at idx=\(idx) (seek=\(String(format: "%.2f", absoluteTargetSeconds))s [absolute source-PTS], restart took \(String(format: "%.0f", elapsedMs))ms)",
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

    /// When the source HEVC's `hvcC` (in `codecpar.extradata`) carries
    /// the configuration header but no VPS / SPS / PPS arrays, scan
    /// the first packets for in-band parameter sets and return a
    /// rebuilt `hvcC` byte sequence with those arrays populated.
    /// Returns nil when the source already has parameter set arrays,
    /// when the source uses a non-4-byte NALU length size, or when
    /// the scan exhausts the budget without finding all three NAL
    /// types.
    ///
    /// Some DV Profile 5 MP4 encoders write only the 23-byte hvcC
    /// header (`numOfArrays = 0`) and leave VPS / SPS / PPS in-band
    /// in every IRAP packet (issue #19 Wandering Earth 2 WEB-DL).
    /// FFmpeg's mp4 muxer stream-copies that hvcC through, so the
    /// output fMP4 has a `dvh1` sample entry that AVPlayer cannot
    /// build a `CMVideoFormatDescription` from. AVPlayer's symptom is
    /// `item.tracks count=2` but `fourCC=<no fdesc>` and
    /// `item.status .failed` with `CoreMediaErrorDomain -4`. The
    /// matroska demuxer doesn't hit this because matroska parameter
    /// sets are in the `CodecPrivate` block which FFmpeg lifts into
    /// `codecpar.extradata` as a complete annex-B sequence that the
    /// mp4 muxer's `ff_isom_write_hvcc` then rebuilds properly.
    ///
    /// Caller is expected to seek the demuxer back to a known
    /// position after this returns, since extracting consumes
    /// packets.
    private func rebuildHEVCExtradataWithInBandParameterSets(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        codecpar: UnsafePointer<AVCodecParameters>
    ) -> [UInt8]? {
        guard codecpar.pointee.codec_id == AV_CODEC_ID_HEVC else { return nil }
        let extradataSize = Int(codecpar.pointee.extradata_size)
        guard extradataSize >= 23, let extradata = codecpar.pointee.extradata else { return nil }
        // hvcC byte 22 is numOfArrays. Non-zero means parameter sets
        // already in the configuration record; nothing to do.
        guard extradata[22] == 0 else { return nil }
        // hvcC byte 21 lower 2 bits + 1 is NALU length size. Anything
        // other than 4 is exotic enough that we bail rather than risk
        // mis-parsing.
        let naluLengthSize = Int(extradata[21] & 0x03) + 1
        guard naluLengthSize == 4 else { return nil }

        var vps: [UInt8]?
        var sps: [UInt8]?
        var pps: [UInt8]?
        let packetBudget = 16
        var packetsScanned = 0

        while packetsScanned < packetBudget {
            let readResult: UnsafeMutablePointer<AVPacket>?
            do {
                readResult = try demuxer.readPacket()
            } catch {
                break
            }
            guard let pkt = readResult else { break }
            defer {
                av_packet_unref(pkt)
                var maybePkt: UnsafeMutablePointer<AVPacket>? = pkt
                av_packet_free(&maybePkt)
            }
            packetsScanned += 1
            if pkt.pointee.stream_index != videoStreamIndex { continue }
            guard let pktData = pkt.pointee.data else { continue }
            let pktSize = Int(pkt.pointee.size)

            var offset = 0
            while offset + naluLengthSize <= pktSize {
                var nalLen = 0
                for i in 0..<naluLengthSize {
                    nalLen = (nalLen << 8) | Int(pktData[offset + i])
                }
                offset += naluLengthSize
                if nalLen == 0 || offset + nalLen > pktSize { break }
                // HEVC NAL header: byte 0 = forbidden_zero_bit(1) +
                // nal_unit_type(6) + layer_id high bit(1). NAL unit
                // type is bits 1..6 of byte 0.
                let nalType = (Int(pktData[offset]) >> 1) & 0x3F
                let nalBytes = Array(UnsafeBufferPointer(start: pktData + offset, count: nalLen))
                switch nalType {
                case 32: if vps == nil { vps = nalBytes }
                case 33: if sps == nil { sps = nalBytes }
                case 34: if pps == nil { pps = nalBytes }
                default: break
                }
                offset += nalLen
            }

            if vps != nil && sps != nil && pps != nil { break }
        }

        guard let vps, let sps, let pps else { return nil }

        // Assemble a proper hvcC: keep the source's 22-byte header
        // (configurationVersion + profile / level / chroma / temporal
        // layer fields), set numOfArrays = 3, then append VPS / SPS /
        // PPS arrays. Each array: 1 byte (arrayCompleteness=1 +
        // reserved=0 + nalUnitType), 2 bytes numNalus = 1, 2 bytes
        // nalUnitLength, NAL bytes.
        var hvcC: [UInt8] = []
        hvcC.reserveCapacity(22 + 1 + 5 * 3 + vps.count + sps.count + pps.count)
        for i in 0..<22 { hvcC.append(extradata[i]) }
        hvcC.append(3)
        func appendArray(nalUnitType: UInt8, nal: [UInt8]) {
            hvcC.append(0x80 | (nalUnitType & 0x3F))
            hvcC.append(0); hvcC.append(1)
            let nl = UInt16(nal.count)
            hvcC.append(UInt8(nl >> 8)); hvcC.append(UInt8(nl & 0xFF))
            hvcC.append(contentsOf: nal)
        }
        appendArray(nalUnitType: 32, nal: vps)
        appendArray(nalUnitType: 33, nal: sps)
        appendArray(nalUnitType: 34, nal: pps)
        return hvcC
    }

    /// Validate that `index` points at an audio stream in the demuxer's
    /// container. Used to gate `audioSourceStreamIndexOverride` so a
    /// stale picker selection (e.g. a stream index from a previous
    /// title) can't make `start()` filter packets nobody is producing.
    private static func isAudioStream(demuxer: Demuxer, index: Int32) -> Bool {
        guard index >= 0, let stream = demuxer.stream(at: index) else {
            return false
        }
        return stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
    }

    private func classifyDVVariant(
        _ record: AVDOVIDecoderConfigurationRecord?,
        codecID: AVCodecID
    ) -> DVVariant {
        guard let r = record else { return .none }
        let profile = Int(r.dv_profile)
        let compat = Int(r.dv_bl_signal_compatibility_id)

        // HEVC + DV: profiles 5, 7, 8 per Dolby's ETSI TS 103 572.
        // Profile 9 is AVC+DV which AetherEngine doesn't support
        // (AVPlayer accepts AVC but not AVC+DV per DrHurt's matrix).
        if codecID == AV_CODEC_ID_HEVC {
            if profile == 5 { return .profile5 }
            if profile == 7 { return .profile7 }
            if profile == 8 {
                switch compat {
                case 1: return .profile81
                case 2: return .profile82
                case 4: return .profile84
                default: return .profile81  // P8.6 etc → treat as P8.1
                }
            }
            return .unknown
        }

        // AV1 + DV: profile 10 per Dolby's spec. compat == 0 means
        // P10.0 (no base layer); compat == 1 / 2 / 4 mirror P8's HDR10
        // / SDR / HLG base-layer compatibility flags.
        if codecID == AV_CODEC_ID_AV1 {
            if profile == 10 {
                switch compat {
                case 0: return .av1Profile10
                case 1: return .av1Profile101
                case 2: return .av1Profile102
                case 4: return .av1Profile104
                default: return .av1Profile10
                }
            }
            return .unknown
        }

        return .unknown
    }

    /// Output of codec dispatch for the source's video stream — the full
    /// set of decisions that `start()` makes about how to expose the
    /// video track to AVPlayer. Computed once at start() and consumed by
    /// the producer (codec tag override) + the playlist builder (CODECS
    /// / SUPPLEMENTAL-CODECS / VIDEO-RANGE).
    fileprivate struct CodecRoute {
        /// `codec_tag` for the mp4 muxer's sample entry FourCC: `avc1`,
        /// `hvc1`, `dvh1`, `av01`, or `dav1`. Optional to match the
        /// producer's `StreamConfig` API (which allows `nil` for muxer
        /// default), but in practice always set by this dispatch.
        let codecTagOverride: String?
        let videoRange: HLSVideoRange
        let primaryCodecs: String
        let supplementalCodecs: String?
        /// Drop the source's `dvcC` configuration record before
        /// `avformat_write_header` writes the sample entry. Used for
        /// HEVC P7 (BL routed as plain HDR10, VT rejects dvcC with
        /// -12906) and for HEVC P8.1 / P8.4 on non-DV panels (tvOS 26
        /// master-level codec filter rejects dvvC + plain hvc1 with
        /// -11868).
        let stripDolbyVisionMetadata: Bool
        let dvVariant: DVVariant
    }

    /// Classify the source video's codec + DV profile and decide the
    /// sample-entry / CODECS / SUPPLEMENTAL-CODECS combination AVPlayer
    /// will see. Per-profile policy:
    ///
    ///   - H.264 → `avc1.<profile><level>` derived from codecpar.
    ///   - AV1 → `av01.*` for plain AV1 / HLG; `dav1.10.*` for DV P10.x.
    ///   - HEVC P5 → always `dvh1.05.<level>` + `dvcC`, regardless of
    ///     panel capability. AVPlayer's system DV decoder converts
    ///     IPT-PQ-c2 to YCbCr and auto-tonemaps to the panel's mode.
    ///   - HEVC P8.1 → `dvh1.08.<level>` on DV-capable display, plain
    ///     `hvc1.2.4.L<level>` downgrade on non-DV display (HDR10 base
    ///     layer plays as plain HEVC HDR10).
    ///   - HEVC P8.4 → `hvc1.2.4.L<level>` + SUPPLEMENTAL `dvh1.08.<level>
    ///     /db4h` on every panel; the cross-player-compat form because
    ///     P8.4's base is HLG-HEVC.
    ///   - HEVC P7 → plain `hvc1.2.4.L<level>` HDR10, strip dvcC (no P7
    ///     decoder on any Apple TV chip).
    ///   - HEVC plain → `hvc1.2.4.L<level>`, range derived from transfer.
    ///
    /// Pre-condition: caller has validated `codecpar.codec_id` is one of
    /// HEVC / H.264 / AV1 (with HW decode for AV1). The dispatch throws
    /// `unsupportedDVProfile` for DV variants AetherEngine doesn't
    /// route (P8.2, P10.2, etc.).
    fileprivate func resolveCodecRoute(
        codecpar: UnsafePointer<AVCodecParameters>
    ) throws -> CodecRoute {
        let codecID = codecpar.pointee.codec_id

        if codecID == AV_CODEC_ID_H264 {
            let profileIDC = Int(codecpar.pointee.profile)
            let levelIDC = Int(codecpar.pointee.level)
            let safeProfile = profileIDC > 0 ? profileIDC : 100  // High
            let safeLevel = levelIDC > 0 ? levelIDC : 40         // 4.0
            return CodecRoute(
                codecTagOverride: "avc1",
                videoRange: isHDRTransfer(codecpar) ? .pq : .sdr,
                primaryCodecs: String(format: "avc1.%02X%02X%02X", safeProfile, 0, safeLevel),
                supplementalCodecs: nil,
                stripDolbyVisionMetadata: false,
                dvVariant: .none
            )
        }

        if codecID == AV_CODEC_ID_AV1 {
            // AV1 path. When dvModeAvailable is false (device can't do
            // DV at all), we deliberately skip the DV side-data probe
            // so classify returns .none → plain AV1 codec string.
            // When dvModeAvailable is true and the source carries
            // Dolby Vision RPU, classify resolves to one of the
            // av1Profile10x variants and we emit the matching `dav1`
            // codec tag + Apple HLS Authoring Spec CODECS string.
            let dvRecord = effectiveDvMode ? doviConfigRecord(from: codecpar) : nil
            let dvVariant = classifyDVVariant(dvRecord, codecID: AV_CODEC_ID_AV1)

            // AV1 codec-string fields (per Apple HLS Authoring Spec +
            // AV1 codec-string IETF draft):
            //
            //   av01.<profile>.<level><tier>.<bitDepth>.
            //        <monochrome>.<chromaSubX><chromaSubY><chromaPos>.
            //        <colorPrim>.<transfer>.<matrix>.<videoFullRange>
            //
            // Profile 0 (Main) is the dominant case in the wild —
            // higher profiles cover 4:2:2 / 4:4:4 / 12-bit which Apple
            // doesn't accept in HLS-fMP4 today, but dav1d decodes them
            // so we let the muxer try; FFmpeg writes the `av1C` box
            // automatically from the codecpar.
            let av1ProfileRaw = Int(codecpar.pointee.profile)
            let av1Profile = (av1ProfileRaw >= 0 && av1ProfileRaw <= 2) ? av1ProfileRaw : 0
            let av1LevelRaw = Int(codecpar.pointee.level)
            // FFmpeg's seq_level_idx encoding: 0..23 → AV1 levels 2.0..7.3.
            // Default to 8 (= level 4.0) when the source doesn't expose
            // a value, matching ~4K @ 30fps.
            let av1Level = (av1LevelRaw >= 0 && av1LevelRaw <= 23) ? av1LevelRaw : 8
            let bitDepthRaw = Int(codecpar.pointee.bits_per_raw_sample)
            let dvLevelRaw = Int(dvRecord?.dv_level ?? 0)
            let dvLevel = dvLevelRaw > 0 ? dvLevelRaw : 6
            let dvLevelStr = String(format: "%02d", dvLevel)

            switch dvVariant {
            case .av1Profile10:
                // P10.0: DV-only, no HDR10 / HLG base layer. AVPlayer
                // refuses the asset on non-DV displays per Apple's
                // spec for `dav1` track type. Same shape as HEVC P5.
                return CodecRoute(
                    codecTagOverride: "dav1",
                    videoRange: .pq,
                    primaryCodecs: "dav1.10.\(dvLevelStr)",
                    supplementalCodecs: nil,
                    stripDolbyVisionMetadata: false,
                    dvVariant: dvVariant
                )
            case .av1Profile101:
                // P10.1: HDR10-compat base layer. Same `dav1` codec
                // tag — the HDR10 fallback is implicit in the
                // bitstream and the decoder picks it up when DV isn't
                // available. Analogous to HEVC P8.1.
                return CodecRoute(
                    codecTagOverride: "dav1",
                    videoRange: .pq,
                    primaryCodecs: "dav1.10.\(dvLevelStr)",
                    supplementalCodecs: nil,
                    stripDolbyVisionMetadata: false,
                    dvVariant: dvVariant
                )
            case .av1Profile104:
                // P10.4: HLG-compat base. Plain `av01` codec tag so
                // non-DV hosts present the HLG base layer; DV signaled
                // via the supplemental codecs string. Analogous to
                // HEVC P8.4 ↔ hvc1.2.4.LXX.b0 + dvh1.08.LL/db4h.
                let bd = bitDepthRaw > 0 ? bitDepthRaw : 10
                let primary = String(
                    format: "av01.%d.%02dM.%02d.0.111.09.18.09.0",
                    av1Profile, av1Level, bd
                )
                return CodecRoute(
                    codecTagOverride: "av01",
                    videoRange: .hlg,
                    primaryCodecs: primary,
                    supplementalCodecs: "dav1.10.\(dvLevelStr)/db4h",
                    stripDolbyVisionMetadata: false,
                    dvVariant: dvVariant
                )
            case .av1Profile102:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: 10, compatID: 2)
            case .unknown:
                let p = Int(dvRecord?.dv_profile ?? 0)
                let c = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 0)
                throw HLSVideoEngineError.unsupportedDVProfile(profile: p, compatID: c)
            case .none:
                // Plain AV1, no DV. Pick color signaling per the
                // source's transfer characteristic so AVPlayer hands
                // the right colorspace to the display.
                let trc = codecpar.pointee.color_trc
                let videoRange: HLSVideoRange
                let cp: Int, tc: Int, mc: Int, bd: Int
                if trc == AVCOL_TRC_ARIB_STD_B67 {
                    videoRange = .hlg; cp = 9; tc = 18; mc = 9
                    bd = bitDepthRaw > 0 ? bitDepthRaw : 10
                } else if trc == AVCOL_TRC_SMPTE2084 {
                    videoRange = .pq; cp = 9; tc = 16; mc = 9
                    bd = bitDepthRaw > 0 ? bitDepthRaw : 10
                } else {
                    videoRange = .sdr; cp = 1; tc = 1; mc = 1
                    bd = bitDepthRaw > 0 ? bitDepthRaw : 8
                }
                let primary = String(
                    format: "av01.%d.%02dM.%02d.0.111.%02d.%02d.%02d.0",
                    av1Profile, av1Level, bd, cp, tc, mc
                )
                return CodecRoute(
                    codecTagOverride: "av01",
                    videoRange: videoRange,
                    primaryCodecs: primary,
                    supplementalCodecs: nil,
                    stripDolbyVisionMetadata: false,
                    dvVariant: dvVariant
                )
            // HEVC DV variants can't reach this switch (classifyDVVariant
            // is called with AV_CODEC_ID_AV1) but Swift's exhaustivity
            // check needs explicit handling.
            case .profile5, .profile81, .profile84, .profile7, .profile82:
                throw HLSVideoEngineError.unsupportedDVProfile(profile: -1, compatID: -1)
            }
        }

        // HEVC path (DV or plain). Always classify the DV variant
        // so DV5 can emit a `dvh1` sample entry + `dvcC` box even
        // on a panel that won't engage DV mode at the HDMI
        // handshake. AVPlayer has a system-level DV decoder on
        // every tvOS 14+ device; it engages on the `dvh1` sample
        // entry regardless of panel state, converts the IPT-PQ-c2
        // elementary stream to a standard YCbCr colorspace, and
        // auto-tonemaps to whatever the panel can accept (HDR10 on
        // an HDR10-only TV, SDR on an SDR-locked panel). Without
        // the `dvh1` sample entry, the HEVC bitstream's IPT chroma
        // gets interpreted as YCbCr+BT.2020+PQ, producing the
        // green/purple cast DrHurt reported on AetherEngine#4
        // Build 160 + 163. Per DrHurt's #19 manual remux test,
        // `dvh1` sample entry + media playlist routing plays DV5
        // correctly on every panel mode. The routing branch below
        // forces media playlist for the DV5-on-non-DV-panel case.
        let dvRecord = doviConfigRecord(from: codecpar)
        let dvVariant = classifyDVVariant(dvRecord, codecID: AV_CODEC_ID_HEVC)

        // Dump the raw DV side data fields so a remote tester can
        // photograph the diagnostic overlay and confirm what the
        // demuxer surfaced for this source. Three fields drive
        // every downstream routing decision: dv_profile (5/7/8),
        // dv_bl_signal_compatibility_id (0/1/4 for no-base / HDR10
        // / HLG), and dv_level (1-13, content frame-rate × HDR
        // overhead). Pair with the source codecpar color fields
        // so the AVPlayer-side color interpretation can be cross-
        // checked against what FFmpeg parsed from the HEVC VUI.
        if let r = dvRecord {
            let cp = Int(codecpar.pointee.color_primaries.rawValue)
            let trc = Int(codecpar.pointee.color_trc.rawValue)
            let csp = Int(codecpar.pointee.color_space.rawValue)
            EngineLog.emit(
                "[HLSVideoEngine] DV source: profile=\(r.dv_profile) "
                + "compat=\(r.dv_bl_signal_compatibility_id) "
                + "level=\(r.dv_level) rpu=\(r.rpu_present_flag) "
                + "el=\(r.el_present_flag) bl=\(r.bl_present_flag) "
                + "color_primaries=\(cp) color_trc=\(trc) color_space=\(csp)",
                category: .session
            )
        }

        let dvLevelRaw = Int(dvRecord?.dv_level ?? 0)
        let dvLevel = dvLevelRaw > 0 ? dvLevelRaw : 6
        let hevcLevelRaw = Int(codecpar.pointee.level)
        let hevcLevel = hevcLevelRaw > 0 ? hevcLevelRaw : 150
        let dvLevelStr = String(format: "%02d", dvLevel)

        switch dvVariant {
        case .profile5:
            // P5 has no HDR10 base layer (IPT-PQ-c2 elementary
            // stream only). `dvh1` sample entry + `dvcC` box is
            // the only legal packaging. Emitted regardless of
            // `effectiveDvMode` because AVPlayer's DV decoder
            // engages on the sample entry independent of panel
            // state and tonemaps internally; without `dvh1` the
            // IPT chroma is misinterpreted as YCbCr (green/purple
            // cast). Master playlist with bare `dvh1.05` CODECS
            // is rejected by tvOS 26's master-level codec filter
            // on non-DV panels (-11868), so the routing logic
            // forces media playlist when the panel can't engage
            // DV/HDR mode.
            return CodecRoute(
                codecTagOverride: "dvh1",
                videoRange: .pq,
                primaryCodecs: "dvh1.05.\(dvLevelStr)",
                supplementalCodecs: nil,
                stripDolbyVisionMetadata: false,
                dvVariant: dvVariant
            )
        case .profile81:
            // P8.1 (HDR10-compat base layer). Two branches based on
            // display capability:
            //
            // DV-capable panel (`effectiveDvMode == true`): emit
            // Apple's HLS Authoring Spec post-WWDC22 signaling for
            // backward-compatible DV: `hvc1` sample entry + `hvcC`
            // + `dvvC` boxes (the mp4 muxer with `strict=-2` writes
            // dvvC automatically when DV side data is preserved on
            // the codecpar), primary CODECS `hvc1.2.4.LXX`,
            // SUPPLEMENTAL-CODECS `dvh1.08.XX/db1p`. The `/db1p`
            // brand identifier marks the supplemental as DV with
            // HDR10 base for AVPlayer's profile-matching; without
            // it the variant is treated as plain HDR10 and the DV
            // pipeline never engages. AVKit's auto-criteria parser
            // reads the dvvC from the live AVPlayerItem.
            // formatDescription via the private CoreMedia hook.
            //
            // Non-DV panel (HDR10-only): emit plain HEVC HDR10 and
            // STRIP DV side data so the muxer writes a clean
            // `hvc1` + `hvcC` sample entry with NO dvvC box. The
            // SUPPLEMENTAL hint causes AVPlayer to engage the DV
            // codec path even on HDR10-only displays and fail
            // silently (regression in 1.4.2, fixed in f7e9f77 by
            // gating SUPPLEMENTAL on `effectiveDvMode`). But a
            // dvvC box left in the sample entry trips tvOS 26's
            // master-level codec filter with -11868 even when
            // CODECS is plain `hvc1.2.4.LXX` (Vincent test
            // 2026-05-26: HDR10 TV + match dynamic range ON,
            // panel switches to HDR correctly but `item.status`
            // goes `.failed` with `AVFoundationErrorDomain -11868`
            // / `CoreMediaErrorDomain -17223`, picture stays
            // black). Stripping DV side data mirrors P7's strategy
            // (P7 always strips because no Apple TV chip has a P7
            // decoder); for P8.1 we strip conditionally based on
            // display capability since DV-capable panels need the
            // dvvC for the upgrade path.
            let supplemental: String?
            let strip: Bool
            if effectiveDvMode {
                supplemental = "dvh1.08.\(dvLevelStr)/db1p"
                strip = false
            } else {
                supplemental = nil
                strip = true
            }
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: .pq,
                primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                supplementalCodecs: supplemental,
                stripDolbyVisionMetadata: strip,
                dvVariant: dvVariant
            )
        case .profile84:
            // P8.4 (HLG-compat base layer). Two branches mirror P8.1:
            //
            // DV-capable panel (`effectiveDvMode == true`): emit
            // `hvc1` sample entry + `hvcC` + `dvvC` boxes (mp4
            // muxer writes dvvC automatically when DV side data
            // is preserved on the codecpar), primary CODECS
            // `hvc1.2.4.LXX`, SUPPLEMENTAL-CODECS `dvh1.08.XX/db4h`.
            // The `/db4h` brand identifier marks the supplemental
            // as DV with HLG base for AVPlayer's profile matching;
            // AVKit's auto-criteria reads dvvC from the live
            // formatDescription and drives DV mode on the panel.
            //
            // Non-DV panel (HDR10 / HLG-capable / SDR): emit plain
            // HEVC HLG and STRIP DV side data so init.mp4 has a
            // clean `hvc1` + `hvcC` sample entry with NO dvvC.
            // Mirrors P8.1's strip path (Vincent test 2026-05-26
            // on HDR10 panel: dvvC in init.mp4 trips tvOS 26's
            // master-level codec filter even when master CODECS
            // is plain hvc1.2.4 with no SUPPLEMENTAL). The plain
            // HLG variant plays on HLG-capable panels and gets
            // tonemapped on HDR10 / SDR panels by AVPlayer's
            // auto-tonemap path. Bare `dvh1` sample entry was
            // never an option for HLG-base regardless of panel
            // (DrHurt #4 Build 160: AVPlayer rejects dvh1 +
            // HLG transfer outright).
            let supplemental: String?
            let strip: Bool
            if effectiveDvMode {
                supplemental = "dvh1.08.\(dvLevelStr)/db4h"
                strip = false
            } else {
                supplemental = nil
                strip = true
            }
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: .hlg,
                primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                supplementalCodecs: supplemental,
                stripDolbyVisionMetadata: strip,
                dvVariant: dvVariant
            )
        case .profile7:
            // P7 dual-layer (UHD-BD remux territory). The bitstream
            // carries an HEVC Main10 base layer + an enhancement
            // layer + RPU; Apple has no system-level P7 decoder, so
            // the only legal path on tvOS is to play the base layer
            // as plain HEVC HDR10. AVPlayer's Main10 decoder ignores
            // NAL units with `nuh_layer_id != 0` per the HEVC spec
            // (Annex F multi-layer extension), which leaves just
            // the BL frames going through the video pipeline. The
            // EL NALs ride along in the fMP4 samples (modest
            // bandwidth cost on a local segment cache), the panel
            // sees HDR10 PQ, no DV mode is requested.
            //
            // `dv_bl_signal_compatibility_id` is typically 6 for P7
            // sources. The spec uses 6 as a P7-specific marker
            // rather than a formal HDR10 backwards-compat flag, but
            // the BL is always PQ HEVC Main10 by construction since
            // UHD-BD requires HDR10 backwards-compat. We don't read
            // compat here because all P7 routes the same way.
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: .pq,
                primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                supplementalCodecs: nil,
                stripDolbyVisionMetadata: true,
                dvVariant: dvVariant
            )
        case .profile82:
            throw HLSVideoEngineError.unsupportedDVProfile(profile: 8, compatID: 2)
        case .unknown:
            let p = Int(dvRecord?.dv_profile ?? 0)
            let c = Int(dvRecord?.dv_bl_signal_compatibility_id ?? 0)
            throw HLSVideoEngineError.unsupportedDVProfile(profile: p, compatID: c)
        case .none:
            return CodecRoute(
                codecTagOverride: "hvc1",
                videoRange: isHDRTransfer(codecpar) ? .pq : .sdr,
                primaryCodecs: "hvc1.2.4.L\(hevcLevel)",
                supplementalCodecs: nil,
                stripDolbyVisionMetadata: false,
                dvVariant: dvVariant
            )
        // AV1 DV variants unreachable here (classify was called with
        // AV_CODEC_ID_HEVC) but exhaustivity needs them.
        case .av1Profile10, .av1Profile101, .av1Profile104, .av1Profile102:
            throw HLSVideoEngineError.unsupportedDVProfile(profile: -1, compatID: -1)
        }
    }

    // MARK: - Segment plan model

    fileprivate struct Segment {
        let startPts: Int64
        let endPts: Int64
        let startSeconds: Double
        let durationSeconds: Double
        /// True when this segment opened at a detected live PTS
        /// discontinuity (program boundary). The playlist builder prefixes
        /// such a segment with `#EXT-X-DISCONTINUITY`. Always false for VOD
        /// (the precomputed plan has no discontinuities).
        var discontinuous: Bool = false
    }

}

// MARK: - Live window sizing

/// Single source of truth for how large the sliding live window is, in
/// segments. Both the playlist's visible window (`firstVisible = highWater -
/// windowSegmentCount`) and the on-disk cache eviction (`evictBelow(
/// firstVisible)`) read this so the two can never drift apart (a drift is
/// exactly what stalls AVPlayer: the playlist keeps listing a segment the
/// cache already deleted, or the cache keeps a segment the playlist dropped).
///
/// `effectiveWindowSeconds = dvrWindowSeconds ?? liveOnlyFloorSeconds`.
/// Live-only (no DVR seek) still gets a bounded floor so disk and the
/// playlist stay finite. `windowSegmentCount = max(minSafeSegments,
/// ceil(effectiveWindowSeconds / targetSegmentDurationSeconds))`.
struct LiveWindowSizing {
    /// Bound applied to a live-only session (no `dvrWindowSeconds`). No DVR
    /// seek is offered, but the window is still capped so memory and disk
    /// do not grow without bound. 60 s at 4 s segments is 15 segments.
    static let liveOnlyFloorSeconds: Double = 60

    /// Floor on the segment count regardless of how small the requested
    /// window is. AVPlayer keeps several target-durations of media buffered
    /// near the live edge (it prefetches ~5-7 segments ahead during normal
    /// playback, see `forwardWaitWindow`). If the window were smaller than
    /// that buffer, AVPlayer's forward/backward live-edge reads would
    /// routinely fall below MEDIA-SEQUENCE and it would lose its position
    /// (the spike's 81 s stall). 8 keeps the window comfortably wider than
    /// AVPlayer's live-edge buffer at 4 s segments (32 s of runway).
    static let minSafeSegments = 8

    let targetSegmentDurationSeconds: Double
    let dvrWindowSeconds: Double?

    /// Number of segments the playlist keeps visible (and the cache keeps
    /// resident). Clamped up to `minSafeSegments`.
    var windowSegmentCount: Int {
        let effective = dvrWindowSeconds ?? Self.liveOnlyFloorSeconds
        let raw = Int(ceil(effective / max(0.5, targetSegmentDurationSeconds)))
        return max(Self.minSafeSegments, raw)
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
private final class VideoSegmentProvider: HLSSegmentProvider, @unchecked Sendable {

    private let cache: SegmentCache
    /// Segment list. Immutable for VOD (the precomputed plan). For live
    /// it starts empty and the producer appends one entry per finalized
    /// segment via `appendLiveSegment`, guarded by `stateLock`. All reads
    /// (`segmentCount`, `segmentDuration(at:)`, `mediaSegmentURL(at:)`,
    /// `notePlaylistBuild`) take the lock when `isLive` so the growing
    /// list is observed consistently from the server's playlist-build
    /// thread.
    private var segments: [HLSVideoEngine.Segment]

    /// Whether this provider backs a live (unbounded, growing) session.
    /// Gates the mutable-segments path, the `.event` playlist type (no
    /// ENDLIST so AVPlayer re-polls), and the locked reads. VOD leaves
    /// this false and behaves byte-for-byte as before.
    private let isLive: Bool

    /// Sliding live window sizing. Drives both the playlist's visible
    /// window (`firstVisible = highWater - windowSegmentCount`) and the
    /// cache eviction cutoff, so the two never drift. Dormant for VOD.
    private let liveWindowSizing: LiveWindowSizing

    private let codecsString: String
    private let supplementalCodecsString: String?
    private let resolution: (Int, Int)
    private let videoRange: HLSVideoRange
    private let frameRate: Double?
    private let hdcpLevel: String?
    private let sourceBitrate: Int64

    /// Closure into the engine that tears down the current producer
    /// and brings up a fresh one rooted at the given absolute segment
    /// index. Synchronous: returns after the new producer's pump has
    /// started writing, which is typically within 50-200 ms on Apple
    /// TV against a local Jellyfin source.
    private let restartHandler: ((Int) -> Void)?

    /// Last index passed to `restartHandler`, also used as the assumed
    /// base index of the engine's currently-active producer. Used by
    /// the empty-cache branch in `mediaSegment(at:)` to distinguish
    /// between "producer just launched here, wait for it" (`abs(index
    /// − lastRestartIndex) ≤ 2`) and "producer is far away from this
    /// index, restart needed" (large diff). Initialised to 0 since
    /// every session starts with an initial producer at baseIndex 0
    /// or the host's resume target, with the engine updating this
    /// after the first explicit restart it triggers via the public
    /// `restartProducer(at:)` path.
    private var lastRestartIndex: Int = 0

    /// Forward-distance threshold beyond which a fetch triggers a
    /// restart instead of waiting for the producer to catch up.
    /// 8 is the value that survives both failure modes:
    ///
    ///   - Tightened to 3 briefly to fix a Vincent repro where a
    ///     seg-13 request waited 26 s for the existing producer to
    ///     sequentially write 11 segments. The smaller window did
    ///     trigger restart at the target index for that case, but
    ///     also restarted on every AVPlayer prefetch above the cache
    ///     edge. AVPlayer's HLS engine speculatively prefetches 5-7
    ///     segments ahead of the playhead during normal playback, so
    ///     with window 3 every prefetch above cache.max+3 triggered
    ///     a restart that killed the in-flight producer mid-write,
    ///     leaving cache holes that AVPlayer hit on its next sequential
    ///     request, restarting again, and so on. Vincent's "video
    ///     hängt nach Scrub nach vorn" was the cascade outcome.
    ///   - 8 is wide enough to absorb AVPlayer's prefetch (any request
    ///     within ~32 s of source content above cache.max waits) and
    ///     narrow enough that user-initiated scrubs of 30+ seconds
    ///     still trigger a restart at the target. The 26 s wait
    ///     in the original repro is the worst-case for "wait within
    ///     window"; it's annoying but not a hang, and stays bounded
    ///     by segment-write-rate × window. Tightening below 8
    ///     requires distinguishing user scrubs from AVPlayer's
    ///     speculative prefetch, which we currently cannot do from
    ///     the segment-server side.
    private static let forwardWaitWindow = 8

    // MARK: - Sliding-window live/VOD playlist state

    /// Segments visible in /media.m3u8 are `[0, visibleHighWater]`.
    /// The visible window is monotonically increasing over a session
    /// (live sliding window never retracts; VOD seek only extends).
    /// Grows by `growthPerRefresh` on each playlist build, plus explicit
    /// jumps from `extendVisibleWindow(toCover:)` on seek.
    ///
    /// Initial value covers the resume position so AVPlayer's first
    /// playlist read already contains the seg AVPlayer is about to
    /// seek to; otherwise AVPlayer either refuses the seek or stalls
    /// waiting for the playlist to grow past the requested time.
    ///
    /// AVPlayer fires CoreMediaErrorDomain -12888 ("Playlist File
    /// unchanged") after 2 consecutive polls of an unchanged playlist
    /// (target-duration / 2 cadence, ≈ 2 s for our 4 s segments).
    /// Adding ≥ 1 segment per build keeps that check happy.
    private let stateLock = NSLock()
    /// Condition variable used to signal `waitForFirstLiveSegment` when
    /// the first live segment is appended. A separate NSCondition (not
    /// the NSLock above) so the manifest handler can block without
    /// holding the segment-list lock. Signaled once from
    /// `appendLiveSegment` when `segments.count` transitions from 0 to 1.
    private let firstSegmentCondition = NSCondition()
    /// Set by `cancelWaiters()` when the engine tears the session down.
    /// With LL-HLS blocking reload, AVPlayer has a parked playlist request
    /// open at essentially all times during steady-state live playback
    /// (waiting on the next segment, which only arrives ~one target
    /// duration later). Once the producer is stopped no append will ever
    /// broadcast again, so without this flag the parked server thread
    /// sleeps out its full timeout (18-30 s) after stop(), pinning the
    /// provider + SegmentCache via its strong reference and then writing
    /// a stale playlist into a connection of the NEXT session if the fd
    /// number was recycled (engine is a process-wide singleton; channel
    /// zap restarts immediately). Guarded by `firstSegmentCondition`.
    private var waitersCancelled = false
    private var visibleHighWater: Int
    private var refreshCounter: Int = 0
    private var endlistAdded: Bool = false
    /// First segment index visible in the live sliding-window playlist
    /// (`#EXT-X-MEDIA-SEQUENCE`). Monotonically increasing; advanced by
    /// `notePlaylistBuild` to `max(0, highWater - windowSegmentCount)`.
    /// Stays 0 for VOD and the append-only EVENT audio path.
    private var _liveFirstVisible: Int = 0
    /// Running count of discontinuity-tagged segments that have slid out
    /// of the visible live window; the playlist's
    /// `#EXT-X-DISCONTINUITY-SEQUENCE` value. Guarded by `stateLock`.
    private var _discontinuitySequence: Int = 0

    /// How many segments past the resume position the initial playlist
    /// exposes. 30 × 4 s = 120 s of forward runway: enough to absorb
    /// AVPlayer's preferredForwardBufferDuration plus the producer's
    /// startup latency without AVPlayer hitting the end of the visible
    /// playlist and stalling.
    private static let initialFillSegments = 30

    /// Segments appended per playlist refresh. Must be ≥ 1 so two
    /// consecutive polls never see the same playlist (the
    /// -12888 trigger). Picked > 1 so the visible window grows faster
    /// than playback consumes it (1 seg per 4 s playback vs 2 segs per
    /// ~2.5 s poll = ~3.2x ahead).
    private static let growthPerRefresh = 2

    init(
        cache: SegmentCache,
        segments: [HLSVideoEngine.Segment],
        codecsString: String,
        supplementalCodecs: String?,
        resolution: (Int, Int),
        videoRange: HLSVideoRange,
        frameRate: Double?,
        hdcpLevel: String?,
        sourceBitrate: Int64,
        initialIndex: Int = 0,
        isLive: Bool = false,
        liveWindowSizing: LiveWindowSizing = LiveWindowSizing(targetSegmentDurationSeconds: 4.0, dvrWindowSeconds: nil),
        restartHandler: ((Int) -> Void)? = nil
    ) {
        self.cache = cache
        self.segments = segments
        self.isLive = isLive
        self.liveWindowSizing = liveWindowSizing
        self.codecsString = codecsString
        self.supplementalCodecsString = supplementalCodecs
        self.resolution = resolution
        self.videoRange = videoRange
        self.frameRate = frameRate
        self.hdcpLevel = hdcpLevel
        self.sourceBitrate = sourceBitrate
        self.restartHandler = restartHandler

        if isLive {
            // Live starts with an empty list; the producer appends as it
            // cuts. The sliding-window state is dormant for live.
            self.visibleHighWater = -1
        } else {
            let safeInitial = max(0, min(initialIndex, segments.count - 1))
            let target = safeInitial + Self.initialFillSegments
            self.visibleHighWater = min(segments.count - 1, max(Self.initialFillSegments, target))
        }
    }

    /// Append a producer-finalized live segment to the growing list under
    /// the state lock. Called once per fragment cut from the producer's
    /// pump thread (live mode only). `index` is the absolute segment
    /// index the producer assigned; appends are sequential so the list's
    /// position equals `index`. Defensive: an out-of-order or duplicate
    /// index is ignored so the list stays a dense `[0, n)`.
    func appendLiveSegment(index: Int, startSeconds: Double, durationSeconds: Double,
                           discontinuous: Bool = false) {
        stateLock.lock()
        guard index == segments.count else {
            stateLock.unlock()
            EngineLog.emit(
                "[HLSVideoEngine] live segment append out of order: got index=\(index), "
                + "expected \(segments.count); ignoring",
                category: .session
            )
            return
        }
        // unused for live; left 0 to avoid a wrong-timebase latent value
        // (source video TB is not reachable from this provider without a
        // large new dependency; DVR restart machinery will supply correct
        // values when wired)
        let startPts: Int64 = 0
        let endPts: Int64 = 0
        segments.append(HLSVideoEngine.Segment(
            startPts: startPts,
            endPts: endPts,
            startSeconds: startSeconds,
            durationSeconds: durationSeconds,
            discontinuous: discontinuous
        ))
        stateLock.unlock()
        // Wake the manifest handler's startup-buffer wait on every append (not
        // just the first), so it can unblock once the configured startup
        // segment count exists. One broadcast per ~4 s segment is negligible.
        firstSegmentCondition.lock()
        firstSegmentCondition.broadcast()
        firstSegmentCondition.unlock()
    }

    // MARK: - Sliding-window operations

    /// Extend the visible window so segment `index` is in the playlist.
    /// Called from the engine's seek path before AVPlayer issues its
    /// new segment fetch so the playlist already lists the target by
    /// the time AVPlayer re-reads it. Idempotent and monotonic.
    func extendVisibleWindow(toCover index: Int) {
        guard !isLive else { return }   // live uses segments.count directly; window/endlist are VOD-only
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !endlistAdded else { return }
        let target = min(segments.count - 1, index + Self.initialFillSegments)
        if target > visibleHighWater {
            visibleHighWater = target
            if visibleHighWater >= segments.count - 1 {
                endlistAdded = true
            }
        }
    }

    /// Atomic snapshot the playlist build reads from. For VOD this
    /// reports the full segment count so AVPlayer sees a complete asset
    /// with a correct duration (the historical EVENT experiment that
    /// reported visibleHighWater+1 made AVPlayer think the asset was
    /// 2:13 and stop there).
    ///
    /// For a live session this advances `_liveFirstVisible` to
    /// `max(0, highWater - windowSegmentCount)` so the playlist window
    /// slides forward, then evicts everything strictly below the new
    /// firstVisible from the cache. The same `windowSegmentCount` drives
    /// both, so the playlist and the cache stay byte-for-byte aligned.
    /// firstVisible only advances once enough segments exist to seed
    /// AVPlayer's live edge (the window stays anchored at 0 until then),
    /// which is the anti-stall guarantee.
    func notePlaylistBuild() -> (visibleCount: Int, refreshCounter: Int, endlistAdded: Bool, discontinuitySequence: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        refreshCounter += 1
        if isLive {
            let total = segments.count
            let window = liveWindowSizing.windowSegmentCount
            // highWater is the last produced index (total - 1). Keep the
            // last `window` segments visible: firstVisible = highWater -
            // window + 1 = total - window. Until at least `window`
            // segments exist, do not advance past 0 so AVPlayer's first
            // read sees all produced segments and can establish a live
            // edge without losing a not-yet-buffered position.
            let newFirst = max(0, total - window)
            if newFirst > _liveFirstVisible {
                // RFC 8216 §6.2.2: EXT-X-DISCONTINUITY-SEQUENCE MUST be
                // incremented for every discontinuity-tagged segment that
                // falls out of the window. The live `segments` array is
                // never pruned, so the slid-out range is still readable.
                for i in _liveFirstVisible..<newFirst where segments[i].discontinuous {
                    _discontinuitySequence += 1
                }
                _liveFirstVisible = newFirst
                // Evict everything below the new firstVisible. Off-lock to
                // avoid holding stateLock during file I/O; evictBelow takes
                // its own lock. Strictly below firstVisible, so no segment
                // the playlist still lists (or AVPlayer's live-edge buffer
                // still references) is ever removed.
                let cutoff = newFirst
                let cacheRef = cache
                DispatchQueue.global(qos: .utility).async {
                    cacheRef.evictBelow(cutoff)
                }
            }
            return (total, refreshCounter, false, _discontinuitySequence)
        }
        return (segments.count, refreshCounter, false, 0)
    }

    /// First segment index visible in the current playlist window.
    /// For VOD (and the append-only EVENT audio path) this is always 0.
    /// For a live session this is `_liveFirstVisible`, which advances as
    /// old segments fall off the back of the sliding window.
    var firstVisibleSegmentIndex: Int {
        guard isLive else { return 0 }
        stateLock.lock()
        defer { stateLock.unlock() }
        return _liveFirstVisible
    }

    // MARK: - HLSSegmentProvider

    func initSegment() -> Data? {
        return cache.fetchInit(timeout: 30.0)
    }

    /// File URL for a cached segment without materializing any bytes.
    /// Used by `HLSLocalServer` to take the `sendfile(2)` fast path
    /// (file → socket entirely kernel-side, no Foundation `Data`
    /// involvement). Returns nil when the segment isn't yet cached,
    /// is out of range, or its cache entry has been pruned. This is
    /// intentionally a pure-lookup: no producer restart, no window
    /// extension, no `declareTarget`. The caller falls back to
    /// `mediaSegment(at:)` (which does drive those side effects) on
    /// nil.
    func mediaSegmentURL(at index: Int) -> URL? {
        guard index >= 0, index < currentSegmentCount else { return nil }
        // Drive cache-window + restart side effects same as the Data
        // path; only the byte materialization changes. Without this
        // the sendfile path would skip the producer restart on
        // out-of-range fetches and AVPlayer would 404 indefinitely.
        extendVisibleWindow(toCover: index)
        handleTargetChange(to: index)
        return cache.peekURL(index: index)
    }

    /// Update the cache's target index AND, if the change represents
    /// a big backward jump, proactively relocate the producer.
    /// Shared by both `mediaSegment(at:)` (Data path) and
    /// `mediaSegmentURL(at:)` (sendfile path) — without unifying,
    /// the sendfile path skips the proactive restart entirely, and
    /// since the FIRST segment a back-scrub touches is almost always
    /// a cache hit (seg-0..seg-N from the initial burst, served via
    /// sendfile), the proactive restart would never fire when it
    /// matters most. Symptom: user back-scrubs, AVPlayer fetches
    /// cached seg-0..seg-10 via sendfile (target advances 0→10
    /// without ever going through `mediaSegment(at:)`), then hits
    /// seg-11 and falls into the reactive prune-gap restart with
    /// AVPlayer's buffer at the thinnest — exactly the user-visible
    /// post-scrub hang.
    private func handleTargetChange(to index: Int) {
        let previousTarget = cache.targetIndex
        cache.declareTarget(index)

        // Proactive relocation on backward-jump declareTarget.
        // Threshold of 2 mirrors the empty-cache branch's tolerance
        // for "near the producer's launch point, just wait" — small
        // backward jumps (e.g. tvOS HLS's occasional speculative
        // re-fetch of a recently-played segment) don't justify
        // tearing down the producer.
        if previousTarget >= 0, index < previousTarget - 2, let restart = restartHandler {
            EngineLog.emit(
                "[HLSVideoEngine] declareTarget backward jump \(previousTarget) → \(index), proactively restarting producer",
                category: .session
            )
            lastRestartIndex = index
            restart(index)
            cache.resetHighWaterForRestart()
        }
    }

    func mediaSegment(at index: Int) -> Data? {
        guard index >= 0, index < currentSegmentCount else { return nil }
        let totalStart = DispatchTime.now()

        // Defensive: if AVPlayer fetches a segment beyond the current
        // visible window (e.g. via an internal seek path that bypassed
        // the engine.seek hook), extend the window so the next playlist
        // refresh includes it. Without this, AVPlayer could end up
        // working off a stale view where it requests a seg that isn't
        // "supposed to exist" yet.
        extendVisibleWindow(toCover: index)

        // Update target + proactive-restart on big backward jump.
        // See `handleTargetChange` for rationale; this path and the
        // sendfile `mediaSegmentURL` path share the same logic so a
        // back-scrub's first cache-hit doesn't slip past unnoticed.
        handleTargetChange(to: index)

        // Fast path: serve from cache.
        if let hit = cache.peek(index: index) {
            return logServed(index: index, bytes: hit, totalStart: totalStart, restarted: false)
        }

        // Decide whether to restart the producer or wait. Four cases:
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
        //   - index nominally within the cache's [min..max] range but
        //     peek failed → could be a real hole OR producer-in-flight
        //     that hasn't yet written this segment. Wait briefly; only
        //     restart if the wait times out. Without this short wait
        //     every restart cascades: producer restarts at N, finishes
        //     writing N, returns to caller; AVPlayer then GETs N+1, but
        //     producer hasn't written N+1 yet so peek returns nil while
        //     cache.range is (N..M) from the previous producer's leftover.
        //     The "hole" branch triggers a fresh restart at N+1, which
        //     repeats the pattern for N+2, N+3, etc. A 2s wait absorbs
        //     the typical 100-500ms producer write cadence and breaks
        //     the cascade. True holes (rare; happen after CC's +10s skip
        //     when AVPlayer rebuffers behind the skip target and the
        //     declareTarget prune evicts a segment AVPlayer will need
        //     later) still trigger a restart after the wait times out.
        // Stale-leftover guard: the request is well below where the
        // current producer was launched. `cache.indexRange()` can still
        // report a lower bound from segments left over by a previous
        // producer (typical case: cold-start probe wrote seg-0 / seg-1
        // before the host's resume target triggered a restart at
        // baseIndex=N), and the range-based branch below would mis-
        // classify the request as "producer is about to write this;
        // wait" and stall on a segment the current producer will never
        // generate. Force a restart at the requested index so the
        // producer relocates to where AVPlayer is actually fetching.
        // Tolerance of 2 matches the empty-cache branch's heuristic
        // for "near the producer's launch point, just wait."
        //
        // Pruned-gap guard: the cache once held `index` but
        // `pruneOutsideWindow` evicted it (typical case: AVPlayer
        // jumped past `index` on a forward skip so the producer
        // wrote it but AVPlayer never fetched it, then a back-scrub
        // re-centred the window and the next slide pruned `index`
        // out from under us). `indexRange()` reports only currently-
        // resident entries — once the high end is pruned, the
        // range-based branch sees `r.1 < index <= r.1 + window`,
        // hits the else-clause, and concludes "producer is about
        // to write this; backpressure-wait." But the producer is
        // already past `index` and won't backfill without a restart.
        // `highestStoredIndex` is monotonic across prunes so it
        // remembers the producer's true high-water and catches the
        // case. Concrete repro: 110-segment episode, AVPlayer jumped
        // 8→12, then back-scrubbed to 0, then played seg-0..seg-10
        // from cache (seg-11..seg-24 pruned by the seg-0 declareTarget),
        // requested seg-11, hit the else-branch, waited 30 s, and
        // 404'd because the current producer was past seg-24.
        let range = cache.indexRange()
        let highWater = cache.highestStoredIndex
        let staleBelowProducer = index < lastRestartIndex - 2
        // Prune-created gap the producer already advanced past: `highWater`
        // says the current producer wrote beyond `index`, but that alone is
        // NOT a pruned gap. During normal forward-march the producer races
        // ahead of AVPlayer (highWater well above the requested index) while
        // the low segments are still resident and unpruned. Restarting on a
        // resident in-window index was a false positive that threw away the
        // producer's forward progress and forced an AVIO reconnect mid-
        // playback, eroding AVPlayer's forward buffer and stuttering (repro:
        // `cache.range=0..24 highWater=24`, request seg15 -> needless restart).
        // Only treat it as a real gap when `index` falls OUTSIDE the resident
        // window: above `r.1` means the high end was pruned after a window
        // slide (the documented seg-11 repro), below `r.0` means the low end
        // was pruned. When `index` is inside `[r.0, r.1]` the range branch
        // below serves it from cache (or waits briefly, then restarts only on
        // a genuine internal gap). Empty cache keeps the bare highWater test.
        let producerPassedAndPruned: Bool
        if highWater > index, let r = range {
            producerPassedAndPruned = index < r.0 || index > r.1
        } else {
            producerPassedAndPruned = highWater > index
        }
        let needsRestart: Bool
        if staleBelowProducer || producerPassedAndPruned {
            needsRestart = true
        } else if let r = range {
            if index < r.0 {
                needsRestart = true
            } else if index > r.1 + Self.forwardWaitWindow {
                needsRestart = true
            } else if index >= r.0 && index <= r.1 {
                // Producer might still be writing this index forward
                // from its current write head. Wait briefly first.
                if let waited = cache.fetch(index: index, timeout: 2.0) {
                    return logServed(index: index, bytes: waited, totalStart: totalStart, restarted: false)
                }
                needsRestart = true
            } else {
                // r.1 < index <= r.1 + forwardWaitWindow — producer is
                // about to write this; backpressure-wait.
                needsRestart = false
            }
        } else {
            // Empty cache. Two scenarios:
            //  1. Cold start: producer just launched at lastRestartIndex,
            //     hasn't written anything yet. AVPlayer's first GET for
            //     a nearby segment should wait briefly while the producer
            //     fills the cache (restarting would just churn the
            //     producer we already have).
            //  2. Big scrub after the cache window slid away: the
            //     producer is far from `index` (different baseIndex)
            //     and won't ever write into the requested region.
            //     Restart is mandatory; waiting just times out.
            //
            // Discriminate on lastRestartIndex (the absolute segment
            // index the engine's current producer was launched at):
            // close to `index` means cold-start case → wait; far from
            // it means scrub case → restart. The previous heuristic
            // (`index > 2`) only handled cold-start from index 0 and
            // missed Vincent's repro where the producer was at idx
            // 1314 and AVPlayer requested seg-0 after a back-scrub,
            // leaving AVPlayer to time out for 30 s and 404.
            needsRestart = abs(index - lastRestartIndex) > 2
        }

        if needsRestart, let restart = restartHandler {
            EngineLog.emit(
                "[HLSVideoEngine] seg\(index): out-of-range fetch (cache.range=\(range.map { "\($0.0)..\($0.1)" } ?? "empty") highWater=\(highWater)), restarting producer",
                category: .session
            )
            lastRestartIndex = index
            restart(index)
            // Reset cache's high-water AFTER `restart(index)` returns.
            // restart() is synchronous: it calls `old.stop()` then
            // `waitForFinish` so the old producer has fully exited
            // (or been abandoned after 5 s) before returning. The
            // new producer was just `start()`-ed but its pump loop
            // is async and hasn't stored anything yet. Resetting
            // here closes the race where the old producer's final
            // segment write (e.g. seg-21 captured immediately after
            // we triggered the restart at 11) re-bumps `highWater`
            // *after* a pre-restart reset would have cleared it,
            // re-arming the producerPassedAndPruned gate and
            // cascading into a per-segment restart storm. With the
            // reset positioned post-restart, only the new producer's
            // forward writes feed the high-water and the gate stays
            // inert for forward-march fetches.
            cache.resetHighWaterForRestart()
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

    /// Segment-count read that takes `stateLock` for live (the list grows
    /// on the producer thread) and reads directly for VOD (immutable list,
    /// no lock needed, byte-for-byte unchanged behaviour).
    private var currentSegmentCount: Int {
        guard isLive else { return segments.count }
        stateLock.lock()
        defer { stateLock.unlock() }
        return segments.count
    }

    var segmentCount: Int { currentSegmentCount }

    func segmentDuration(at index: Int) -> Double {
        if isLive {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard index >= 0, index < segments.count else { return 0 }
            return segments[index].durationSeconds
        }
        guard index >= 0, index < segments.count else { return 0 }
        return segments[index].durationSeconds
    }

    func segmentIsDiscontinuous(at index: Int) -> Bool {
        if isLive {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard index >= 0, index < segments.count else { return false }
            return segments[index].discontinuous
        }
        guard index >= 0, index < segments.count else { return false }
        return segments[index].discontinuous
    }

    /// Reverted to .vod after the sliding-window EVENT experiment:
    /// EVENT halved RSS growth (3.0 → 1.3 MB/sec) but did not bound
    /// it (AVPlayer still retains ~93% of consumed source bytes
    /// regardless of playlist type), and the side effects were
    /// unacceptable — Control Center showed "LIVE" instead of a
    /// scrub bar (caused by EVENT making asset.duration NaN), and
    /// replay-from-beginning landed ~2 min in (AVPlayer's EVENT
    /// live-edge default overrode EXT-X-START even with the
    /// explicit seek-to-0). The leak is fundamental to the
    /// AVPlayer + HLS-loopback pipeline for 4K HDR HEVC content.
    /// Live sessions serve a `.live` playlist: no `#EXT-X-PLAYLIST-TYPE`
    /// and no `#EXT-X-ENDLIST`, with an advancing `#EXT-X-MEDIA-SEQUENCE`
    /// as the sliding window drops consumed segments. EVENT was tried
    /// first but forbids segment removal (the spec), which contradicts a
    /// sliding window and was the likely cause of the spike's 81 s stall;
    /// VOD implies a finished asset and stops playback at the first read.
    /// `.live` is the only spec-correct shape for a window that grows at
    /// the edge AND drops the back. VOD stays `.vod` (the reverted-EVENT
    /// rationale below applies only to finite files); the audio-append
    /// path keeps `.event` available.
    var playlistType: HLSPlaylistType { isLive ? .live : .vod }
    /// Expose the producer's cut target so the playlist builder can anchor
    /// `#EXT-X-TARGETDURATION` to a stable, generous value from the first
    /// manifest, avoiding the -12888 startup race for high-bitrate live
    /// sources. Returns nil for VOD (the default extension nil suffices).
    var liveTargetSegmentDuration: Double? {
        isLive ? liveWindowSizing.targetSegmentDurationSeconds : nil
    }
    /// Live startup buffer, in segments. The manifest handler holds the FIRST
    /// playlist response until this many segments exist, so AVPlayer (which
    /// starts a live `.live` playlist at its oldest listed segment, reinforced
    /// by the host's explicit seek-to-0) begins `liveStartupSegments - 1`
    /// segments BEHIND the production edge and keeps that gap (production and
    /// playback both run at 1x, so the cushion is constant). This absorbs the
    /// real-time-transcode jitter that otherwise starves the bleeding edge
    /// (-16832 "restarting from end of live playlist" + playbackStalled). 2 =
    /// one segment (~4 s) of cushion: the minimum that gives any headroom, at
    /// the cost of ~one extra segment of startup latency. Distinct from the
    /// reverted live-edge hold-back, which trailed the ADVERTISED edge while
    /// still starting AVPlayer at the bleeding edge (1 segment) and so never
    /// built a cushion. 1 disables (serve at the first segment, old behaviour).
    private static let liveStartupSegments = 2

    /// Block the calling thread until at least `liveStartupSegments` live
    /// segments have been appended, or until `timeout` seconds elapse. Returns
    /// true if enough segments are available, false on timeout. Non-live
    /// sessions return immediately. Holding the first manifest response this
    /// way (a) avoids serving an empty live playlist that fires
    /// CoreMediaErrorDomain -12888 on the very first poll, and (b) gives
    /// AVPlayer a startup cushion behind the live edge (see
    /// `liveStartupSegments`). Subsequent polls return instantly once the
    /// count is reached, so only the first response is delayed.
    func waitForFirstLiveSegment(timeout: TimeInterval) -> Bool {
        guard isLive else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        firstSegmentCondition.lock()
        defer { firstSegmentCondition.unlock() }
        while true {
            if waitersCancelled { return false }
            stateLock.lock()
            let count = segments.count
            stateLock.unlock()
            if count >= Self.liveStartupSegments { return true }
            if !firstSegmentCondition.wait(until: deadline) { return count > 0 }
        }
    }

    /// Wake every thread parked in `waitForFirstLiveSegment` /
    /// `waitForLiveSegment` and make all future waits return immediately.
    /// Called from `HLSVideoEngine.stop()`; see `waitersCancelled`.
    func cancelWaiters() {
        firstSegmentCondition.lock()
        waitersCancelled = true
        firstSegmentCondition.broadcast()
        firstSegmentCondition.unlock()
    }

    /// LL-HLS blocking reload: block until segment `index` (0-based absolute
    /// index = the requested Media Sequence Number) has been appended, or
    /// until `timeout`. `segments.count > index` means the segment exists.
    /// Reuses the same per-append broadcast as `waitForFirstLiveSegment`, so
    /// the wait wakes the instant the producer finalizes the next segment.
    /// On timeout returns whether the segment happens to exist by then; the
    /// caller serves the current playlist either way (AVPlayer retries).
    func waitForLiveSegment(index: Int, timeout: TimeInterval) -> Bool {
        guard isLive else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        firstSegmentCondition.lock()
        defer { firstSegmentCondition.unlock() }
        while true {
            if waitersCancelled { return false }
            stateLock.lock()
            let count = segments.count
            stateLock.unlock()
            if count > index { return true }
            if !firstSegmentCondition.wait(until: deadline) {
                stateLock.lock()
                let final = segments.count
                stateLock.unlock()
                return final > index
            }
        }
    }
    var masterCodecs: String? { codecsString }
    var masterSupplementalCodecs: String? { supplementalCodecsString }
    var masterResolution: (width: Int, height: Int)? {
        return (resolution.0, resolution.1)
    }
    var masterVideoRange: HLSVideoRange? { videoRange }
    /// AVERAGE-BANDWIDTH reflects the source container's reported
    /// bitrate. Falls back to a high default (25 Mbps) when libavformat
    /// can't compute it, since under-declaring causes AVPlayer to log
    /// `CoreMediaErrorDomain -12318 'Segment exceeds specified
    /// bandwidth for variant'` for every above-average segment.
    /// Over-declaring is harmless to AVPlayer's variant-selection on a
    /// single-variant master.
    var masterAverageBandwidth: Int? {
        sourceBitrate > 0 ? Int(sourceBitrate) : 25_000_000
    }

    /// BANDWIDTH represents the peak segment bitrate. Per HLS spec it
    /// MUST NOT be smaller than any individual segment's bitrate.
    /// 4K HDR HEVC sources have heavily variable per-second bitrates
    /// (action-heavy scenes burst to ~2x average) so we publish 2x
    /// the source's average as a safety margin. 5 Mbps floor keeps
    /// us above AVPlayer's internal sanity thresholds even when the
    /// source reports a tiny / corrupt bitrate.
    var masterBandwidth: Int? {
        let avg = masterAverageBandwidth ?? 25_000_000
        return max(avg * 2, 5_000_000)
    }
    var masterFrameRate: Double? { frameRate }
    var masterHDCPLevel: String? { hdcpLevel }
    var masterClosedCaptions: String? { "NONE" }
}
