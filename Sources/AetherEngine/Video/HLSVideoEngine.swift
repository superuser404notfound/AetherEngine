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

    // MARK: - State

    let sourceURL: URL
    let sourceHTTPHeaders: [String: String]
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
    var effectiveDvMode: Bool { dvModeAvailable || keepDvh1TagWithoutDV }

    /// Optional caller-chosen audio source stream index. When `nil` the
    /// engine falls back to `av_find_best_stream(AVMEDIA_TYPE_AUDIO)`,
    /// which picks whichever stream libavformat ranks highest (typically
    /// the container's default flag, then bitrate). When set, the start
    /// path uses this stream for the muxed audio output, enabling host
    /// driven mid-playback audio track switching via the
    /// `AetherEngine.selectAudioTrack(index:)` reload.
    private let audioSourceStreamIndexOverride: Int32?

    var demuxer: Demuxer?
    private var cache: SegmentCache?
    var producer: HLSSegmentProducer?
    private var server: HLSLocalServer?
    var provider: VideoSegmentProvider?

    /// Side demuxer over a demuxed-audio companion reader (live HLS
    /// ingest whose variant is video-only with a separate audio
    /// rendition playlist). Opened in `start()` when the main demuxer
    /// found no audio stream and the source exposes a companion;
    /// otherwise nil and every path below behaves exactly as before.
    /// Engine-owned: `stop()` marks it closed synchronously (unblocks a
    /// pump parked in its read) and closes it in the detached cleanup,
    /// mirroring the main demuxer's teardown. Guarded by `restartLock`
    /// like the other subsystem refs.
    var sideAudioDemuxer: Demuxer?

    /// Packed-audio companion state (Apple HLS packed audio: raw ADTS
    /// AAC rendition, ID3 PRIV program-clock anchor). Set in `start()`
    /// when the companion resolved as packed; `makeProducer` threads
    /// both into the producer so it SYNTHESIZES side-audio timestamps
    /// on the shared 90 kHz program clock (FFmpeg's raw "aac" demuxer
    /// produces neither). `startPts` is the PRIV timestamp rescaled
    /// into the side audio stream's own time base; the fallback
    /// duration is one AAC frame (1024 samples) in the same base, for
    /// packets the demuxer hands over without a duration. nil / 0 for
    /// TS companions and every muxed-audio session.
    private var packedSideAudioStartPts: Int64?
    private var packedSideAudioFallbackDurationPts: Int64 = 0

    /// Source stream index of the audio stream this session's pipeline
    /// ACTUALLY muxes (post override-validation, auto-pick fallback,
    /// and the stream-copy/bridge cascade), or -1 when the session is
    /// video-only. For demuxed-audio sessions the index numbers a
    /// stream in the SIDE demuxer. Set once in `start()`; the engine
    /// host reads it after load to publish an `activeAudioTrackIndex`
    /// that matches what is really playing (a host comparing its
    /// preferred track against a stale published value otherwise
    /// triggers a pointless, stall-prone live reload of the very track
    /// already on air).
    public private(set) var activeAudioSourceStreamIndex: Int32 = -1

    /// Audio `TrackInfo`s of the demuxed-audio companion (side
    /// demuxer), snapshotted at `start()` while the side demuxer is
    /// open. Empty for muxed-audio sessions. The engine host publishes
    /// these when the main probe saw no audio at all, so the host's
    /// track list and `activeAudioTrackIndex` describe the same stream
    /// numbering.
    public private(set) var companionAudioTracks: [TrackInfo] = []

    /// Captured at `start()` so the restart path can spin up a fresh
    /// producer at any segment index without re-running the full
    /// DV-classification / codec-pick logic.
    var videoStreamIndex: Int32 = -1
    var savedVideoConfig: HLSSegmentProducer.StreamConfig?
    var savedAudioConfig: HLSSegmentProducer.AudioConfig?

    /// Mirror of `LoadOptions.prepareNativeSubtitles` + a text-subtitle
    /// guard. When true, `makeProducer` sets `enableNativeSubtitleTrack`
    /// on every producer it creates (initial + restart) so the muxer
    /// always declares the mov_text track in the init moov (#55).
    /// Set by `AetherEngine.loadNative` after the probe, before `start()`.
    /// Also settable via the public `enableNativeSubtitles()` affordance.
    var enableNativeSubtitleTrackForSession: Bool = false

    /// Session-persistent cue stores for the native mov_text subtitle
    /// tracks (#55, all-tracks). One store per declared text track, ordinal-
    /// aligned with `nativeSubtitleLanguagesForSession` and the muxer's
    /// mov_text stream order. Mirrors `enableNativeSubtitleTrackForSession`:
    /// set by `AetherEngine` when native subtitles are enabled and cleared
    /// by `clearSubtitle` / `stopInternal`. `makeProducer` re-threads the
    /// set onto every fresh producer (initial + restart) so per-segment cue
    /// drain survives a seek or audio-switch restart. Empty when no text
    /// subtitle track is active; the empty path is byte-identical to
    /// pre-#55 output.
    var nativeSubtitleCueStoresForSession: [NativeSubtitleCueStore] = []

    /// Language tags (ISO 639-2 / BCP-47) parallel to
    /// `nativeSubtitleCueStoresForSession`. Threaded onto the producer so
    /// the muxer can label each mov_text track for AVFoundation's media-
    /// selection menu. A nil entry => no language box for that track.
    var nativeSubtitleLanguagesForSession: [String?] = []

    /// Diagnostics affordance (#55): request the native mov_text track
    /// in the init moov. Call BEFORE `start()` so `makeProducer` picks
    /// up the flag when allocating the first muxer. Then call
    /// `attachNativeSubtitleStores(count:languages:)` after `start()` to
    /// wire the cue stores to the already-running producer.
    /// In a full `AetherEngine` session this is wired automatically;
    /// these methods exist so `aetherctl serve --native-subs N` can
    /// confirm the plumbing at the HLS-engine level.
    public func requestNativeSubtitleTrack() {
        enableNativeSubtitleTrackForSession = true
    }

    /// Attach `count` fresh `NativeSubtitleCueStore`s (one per declared
    /// text track) to the current producer (#55, all-tracks). Call AFTER
    /// `start()`. The stores start empty; cues arrive once `AetherEngine`
    /// feeds them via the native multi-decode reader. `languages` is
    /// ordinal-aligned (nil-padded to `count`). Used by
    /// `aetherctl serve --native-subs` to confirm the init moov declares N
    /// tracks; a full `AetherEngine` session wires the stores directly.
    public func attachNativeSubtitleStores(count: Int, languages: [String?] = []) {
        guard count > 0 else { return }
        let stores = (0..<count).map { _ in NativeSubtitleCueStore() }
        nativeSubtitleCueStoresForSession = stores
        nativeSubtitleLanguagesForSession = (0..<count).map { i in
            i < languages.count ? languages[i] : nil
        }
        producer?.subtitleCueStores = stores
        producer?.nativeSubtitleLanguages = nativeSubtitleLanguagesForSession
    }

    /// Discover every non-bitmap subtitle stream on the engine's own
    /// demuxer and attach one store per track, ordinal-aligned with source
    /// order and labelled with each track's metadata language (#55,
    /// all-tracks). Call AFTER `start()`. Returns the per-track languages
    /// (for logging). Used by `aetherctl serve --native-subs` to declare ALL
    /// native tracks in the init moov; a full `AetherEngine` session wires
    /// the stores itself via the multi-decode reader.
    @discardableResult
    public func attachAllNativeSubtitleStores() -> [String?] {
        let bitmap: Set<String> = ["hdmv_pgs_subtitle", "dvb_subtitle", "dvd_subtitle", "xsub"]
        let text = (demuxer?.subtitleTrackInfos() ?? []).filter { !bitmap.contains($0.codec) }
        let languages = text.map { $0.language }
        attachNativeSubtitleStores(count: text.count, languages: languages)
        return languages
    }

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
    public internal(set) var audioPipelineDescription: String?

    /// `videoShiftPts` of the currently active producer, converted to
    /// seconds via the source video time base. Updated by the producer's
    /// `onVideoShiftKnown` callback on every gate open. AVPlayer's HLS
    /// clock sits at `source_pts - playlistShiftSeconds`; the subtitle
    /// path and side-demuxer seek read this to translate back to
    /// source time.
    ///
    /// Lock-guarded: written from producer callbacks on the pump thread,
    /// read by the host/engine on other threads.
    public var playlistShiftSeconds: Double {
        shiftLock.lock(); defer { shiftLock.unlock() }; return _playlistShiftSeconds
    }
    private func setPlaylistShiftSeconds(_ value: Double) {
        shiftLock.lock(); _playlistShiftSeconds = value; shiftLock.unlock()
    }
    private let shiftLock = NSLock()
    private var _playlistShiftSeconds: Double = 0

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

    /// Fires when a native AVKit transport-bar scrub (or any AVPlayer seek
    /// that lands out of the currently-served LRU window) drives a producer
    /// restart, so AetherEngine can publish an accurate in-flight seek
    /// signal for scrubs that bypass `engine.seek()` (AetherEngine#38).
    /// `(true, playlistTime)` at the start of a coalesced restart run,
    /// `(false, nil)` once the run drains. `playlistTime` is the requested
    /// segment's start on the AVPlayer/playlist axis; the host folds it
    /// with `playlistShiftSeconds` onto its source-PTS `seekTarget`.
    var onSeekStateChanged: (@Sendable (Bool, Double?) -> Void)?

    /// Engine-owned deep copy of an AVCodecParameters. The saved
    /// video/audio configs previously held raw pointers INTO the
    /// session demuxer's AVStreams; a live reopen closes that demuxer
    /// (avformat_close_input frees the streams and their codecpar)
    /// while the continuation producer still dereferences the config
    /// lazily on its pump thread (muxer allocation copies the params),
    /// i.e. a use-after-free on every successful reopen. Deep-copying
    /// at capture time decouples the configs from any demuxer's
    /// lifetime. Freed by ARC via deinit; `stop()`'s detached cleanup
    /// captures the boxes so they outlive the pump's unwind.
    final class OwnedCodecParameters: @unchecked Sendable {
        let ptr: UnsafeMutablePointer<AVCodecParameters>

        init?(copying src: UnsafePointer<AVCodecParameters>) {
            guard let copy = avcodec_parameters_alloc() else { return nil }
            guard avcodec_parameters_copy(copy, src) >= 0 else {
                var c: UnsafeMutablePointer<AVCodecParameters>? = copy
                avcodec_parameters_free(&c)
                return nil
            }
            self.ptr = copy
        }

        deinit {
            var p: UnsafeMutablePointer<AVCodecParameters>? = ptr
            avcodec_parameters_free(&p)
        }
    }

    /// The owned copies backing `savedVideoConfig` / `savedAudioConfig`.
    /// Guarded by `restartLock` alongside the configs themselves.
    private var ownedCodecParams: [OwnedCodecParameters] = []

    /// Demuxer of an in-flight live reopen attempt, registered before its
    /// (potentially long-blocking) open so `stop()` can abort it. Without
    /// this, a reopen blocked in the AVIO reconnect loop against a dead
    /// tuner survives a channel zap and keeps reconnecting into the next
    /// session, the same orphan class the probe-abort hook fixed for
    /// `load()`. Guarded by `restartLock`.
    var reopenDemuxer: Demuxer?
    /// Fires when a live program-boundary rebase changes the shift.
    /// Carries (newShiftSeconds, seamOutputSeconds): AetherEngine queues
    /// the new shift and applies it to its published clock only when
    /// playback crosses `seamOutputSeconds` on the raw AVPlayer timeline,
    /// so currentTime/sourceTime don't jump while the old program is
    /// still on screen.
    var onPlaylistShiftRebased: (@Sendable (Double, Double) -> Void)?
    /// Fires when the live source replayed itself from the beginning
    /// after an unplanned reconnect (PumpExitReason.sourceReplay). The
    /// engine cannot recover on the same URL; the host must re-negotiate
    /// a fresh playback session (new transcode at the live edge) and
    /// reload. Fires at most once per producer generation.
    var onLiveSourceReset: (@Sendable () -> Void)?
    /// Session-long FLAC bridge for codecs that aren't legal in fMP4.
    /// Owned by the engine (not the producer) so that producer
    /// restarts on scrub don't lose the bridge's encoder state. The
    /// bridge's `startSegment()` is called before each restart so the
    /// FLAC encoder PTS rebases off the new demuxer cursor.
    var audioBridge: AudioBridge?
    private var segmentPlan: [Segment] = []

    /// Guards the subsystem references (producer / cache / server /
    /// demuxer / audioBridge / provider), the saved configs, and
    /// `sessionEpoch`. Held only for brief state mutations / snapshots,
    /// never across waits or network I/O, so `stop()` (often on the main
    /// thread via a SwiftUI dismiss) is never blocked behind a restart's
    /// 5 s producer wait or a network-bound demuxer seek.
    let restartLock = NSLock()

    /// Serializes restart requests among themselves so multiple AVPlayer
    /// GETs racing the same scrub can't tear down and rebuild the
    /// producer in parallel. Deliberately separate from `restartLock`:
    /// this one IS held across the restart's waits, which is fine because
    /// only other restarts contend on it.
    private let restartGate = NSLock()

    /// Coalesces rapid restart requests (burst seeks). Mutated only under
    /// `restartLock`. See `RestartCoalescer` and AetherEngine#35.
    private var restartCoalescer = RestartCoalescer()

    /// Bumped by `stop()` under `restartLock`. A restart that dropped the
    /// lock for its waits re-validates the epoch before installing the
    /// new producer, so a stop() that landed mid-restart wins and the
    /// restart unwinds instead of resurrecting a producer into a
    /// torn-down session.
    private var sessionEpoch: UInt64 = 0

    /// Fires once per session, the first time the producer sees an
    /// HDR10+ T.35 signature in a packet. Hooked by `AetherEngine` to
    /// upgrade the published `videoFormat` from `.hdr10` → `.hdr10Plus`.
    /// Debounced here so producer restarts on scrub don't re-fire.
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    private var hasReportedHDR10Plus = false
    private let hdr10PlusLock = NSLock()

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
    static let targetSegmentDuration: Double = 4.0

    /// Upper bound on the VOD cue-prewarm seek. A healthy MKV resolves its
    /// Cues index in well under a second (one or two byte-range reads); a
    /// source with a missing/out-of-bounds index instead triggers a multi-GB
    /// linear scan. Past this many seconds we abort the seek and fall back to
    /// the uniform-stride segment plan so playback starts promptly. Generous
    /// enough not to false-trip on a slow link doing legitimate tail reads.
    static let cuePrewarmTimeout: TimeInterval = 10.0

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
        audioBridgeMode: AudioBridgeMode = .surroundCompat,
        isLiveSession: Bool = false,
        dvrWindowSeconds: Double? = nil,
        liveSourceCadenceHint: Double? = nil,
        preopenedDemuxer: Demuxer? = nil,
        sourceReopenableByURL: Bool = true,
        companionAudioReader: IOReader? = nil
    ) {
        self.sourceURL = url
        self.sourceHTTPHeaders = sourceHTTPHeaders
        self.dvModeAvailable = dvModeAvailable
        self.displaySupportsHDR = displaySupportsHDR
        self.keepDvh1TagWithoutDV = keepDvh1TagWithoutDV
        self.matchContentEnabled = matchContentEnabled
        self.panelIsInHDRMode = panelIsInHDRMode
        self.audioSourceStreamIndexOverride = audioSourceStreamIndexOverride
        self.audioBridgeMode = audioBridgeMode
        self.isLiveSession = isLiveSession
        self.dvrWindowSeconds = dvrWindowSeconds
        self.liveSourceCadenceHint = liveSourceCadenceHint
        // A bursty source (upstream segments materially longer than our cut
        // target) cannot honor the LL-HLS blocking-reload contract: held
        // reloads would resolve only when the next upstream batch lands,
        // which AVPlayer flags as invalid blocking behavior (-15410) and
        // punishes with start delays and periodic stalls (device repro
        // 2026-06-11). For those sources, advertise NO blocking reload and
        // raise TARGETDURATION to the real arrival cadence so the plain
        // reload patience (1.5x TD) covers the inter-batch gap. Computed
        // once here; nil hint (URL live sources, VOD) keeps the previous
        // behavior exactly: blocking reload on, no extra TD floor.
        self.liveBlockingReloadEnabled = liveSourceCadenceHint
            .map { $0 <= Self.targetSegmentDuration * 1.5 } ?? true
        self.liveTargetDurationFloorSeconds = liveSourceCadenceHint.map { ceil($0) }
        self.preopenedDemuxer = preopenedDemuxer
        self.sourceReopenableByURL = sourceReopenableByURL
        self.companionAudioReader = companionAudioReader
    }

    /// Whether this engine is serving an unbounded (live) source. Set
    /// once at init from `LoadOptions.isLive`. When true, `start()`
    /// skips the VOD-only duration guard, mid-duration cue prewarm, and
    /// precomputed segment plan, and instead builds the provider +
    /// producer in their forward-only live cut mode (the producer cuts
    /// a new segment at each video keyframe past the duration target and
    /// appends it to the provider's growing segment list). VOD paths
    /// leave this false and are unaffected.
    let isLiveSession: Bool

    /// Whether a live-session loss can be recovered by reopening
    /// `sourceURL`. `true` for real network URLs; `false` for custom
    /// (IOReader-backed) sources whose `sourceURL` is the synthetic
    /// `aether-custom://source` placeholder. Burning the reopen backoff
    /// budget against that synthetic URL guarantees 6 consecutive
    /// failures before the session stalls silently; when `false`,
    /// `handlePumpFinished` surfaces the loss to the host via
    /// `onLiveSourceReset` immediately instead.
    let sourceReopenableByURL: Bool

    /// Upstream segment cadence in seconds for a custom-ingest live
    /// session (the upstream playlist's EXT-X-TARGETDURATION, via
    /// `LiveIngestSourceInfo`). nil for URL live sources and VOD.
    private let liveSourceCadenceHint: Double?

    /// Forward-only reader carrying the source's DEMUXED audio
    /// rendition (live HLS ingest, `LiveIngestSourceInfo.
    /// companionAudioReader`). When the main demuxer finds no audio
    /// stream and this is non-nil, `start()` opens `sideAudioDemuxer`
    /// over it and the audio pipeline runs against that demuxer's
    /// codecpar. The reader itself is owned by the host's main reader
    /// (its close() closes the companion); the engine only owns the
    /// side DEMUXER built on top. nil everywhere else.
    private let companionAudioReader: IOReader?

    /// Whether the local live playlist may advertise LL-HLS blocking
    /// reload (CAN-BLOCK-RELOAD). Derived once in init from
    /// `liveSourceCadenceHint`; see the init comment for the rationale.
    private let liveBlockingReloadEnabled: Bool

    /// Extra floor (seconds) for the local live playlist's
    /// #EXT-X-TARGETDURATION: ceil(upstream cadence), so AVPlayer's
    /// unchanged-playlist patience (1.5x TD) covers the real inter-batch
    /// arrival gap of a bursty ingest source. nil when no cadence hint.
    private let liveTargetDurationFloorSeconds: Double?

    /// DVR window in seconds for a live session (from `LoadOptions`).
    /// `nil` means live-only: no DVR seek, but the live window is still
    /// bounded to `LiveWindowSizing.liveOnlyFloorSeconds`. Threaded into
    /// the provider so the sliding playlist window and the cache eviction
    /// share one size. Ignored for VOD.
    private let dvrWindowSeconds: Double?

    /// Encoder choice for the audio bridge (used for source codecs that
    /// can't stream-copy into fMP4: TrueHD, DTS, DTS-HD MA, MP3, Opus,
    /// and EAC3-from-MKV-without-dec3-extradata).
    let audioBridgeMode: AudioBridgeMode

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

        // Source video parameter diagnostics. Decisive for AVPlayer -11821
        // ("decode failed" with both tracks unreadable right after
        // readyToPlay) on channels that mux cleanly: the two candidate
        // causes are interlaced source coding (field_order != progressive;
        // VT via the fMP4 loopback chokes where the working channels are
        // all progressive) and malformed/Annex-B extradata feeding a broken
        // avcC/hvcC into init.mp4. One log line names both.
        let extraSize = Int(codecpar.pointee.extradata_size)
        var extraHead = "none"
        if extraSize > 0, let extra = codecpar.pointee.extradata {
            let n = min(extraSize, 8)
            extraHead = (0..<n).map { String(format: "%02x", extra[$0]) }.joined()
        }
        EngineLog.emit(
            "[HLSVideoEngine] video codecpar: codec=\(codecpar.pointee.codec_id.rawValue) "
            + "\(codecpar.pointee.width)x\(codecpar.pointee.height) "
            + "profile=\(codecpar.pointee.profile) level=\(codecpar.pointee.level) "
            + "fieldOrder=\(codecpar.pointee.field_order.rawValue) "
            + "extradata=\(extraSize)B head=\(extraHead)",
            category: .session
        )

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
            //
            //    Bounded: when the Cues index is missing or points past EOF
            //    (truncated / mis-muxed remux) the matroska seek degrades into
            //    a multi-GB linear scan (tens of minutes on a remote source).
            //    The deadline aborts it so we fall through to the uniform-stride
            //    plan below and start playback immediately instead of hanging.
            let prewarmStart = DispatchTime.now()
            let prewarmOK = dem.seekBounded(to: durationSeconds * 0.5, timeout: Self.cuePrewarmTimeout)
            let prewarmMs = Double(DispatchTime.now().uptimeNanoseconds - prewarmStart.uptimeNanoseconds) / 1_000_000
            if prewarmOK {
                EngineLog.emit("[HLSVideoEngine] cue prewarm: seek to \(String(format: "%.1f", durationSeconds * 0.5))s took \(String(format: "%.1f", prewarmMs))ms")
            } else {
                EngineLog.emit("[HLSVideoEngine] cue prewarm: capped at \(String(format: "%.1f", prewarmMs))ms (no usable Cues index — index points past EOF or is absent); building plan from whatever keyframes were scanned")
            }

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
        let convertP7ToProfile81 = route.convertP7ToProfile81
        let rewriteDoviConfigTo81 = route.rewriteDoviConfigTo81
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
        // Deep-copy the codec parameters out of the demuxer's stream so
        // the config survives the demuxer (live reopen closes it while
        // the continuation producer still reads the config; see
        // OwnedCodecParameters).
        guard let ownedVideoParams = OwnedCodecParameters(copying: codecpar) else {
            throw HLSVideoEngineError.openFailed(reason: "codecpar copy failed")
        }
        ownedCodecParams.append(ownedVideoParams)
        let videoConfig = HLSSegmentProducer.StreamConfig(
            codecpar: UnsafePointer(ownedVideoParams.ptr),
            timeBase: videoTimeBase,
            codecTagOverride: codecTagOverride,
            stripDolbyVisionMetadata: stripDolbyVisionMetadata,
            convertP7ToProfile81: convertP7ToProfile81,
            rewriteDoviConfigTo81: rewriteDoviConfigTo81,
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

        // 6a-pre. Demuxed-audio companion (live HLS ingest). When the
        //     main variant is video-only and the source carries its
        //     audio in a separate rendition playlist, open a SIDE
        //     demuxer over the companion reader (same custom-AVIO
        //     mechanism) and run the whole audio pipeline below against
        //     ITS audio stream. The rendition is either MPEG-TS or
        //     Apple PACKED AUDIO (raw ADTS AAC, ARD-style); the
        //     companion classifies its first segment before publishing
        //     any byte, so the blocking resolve below is what decides
        //     the FFmpeg demuxer ("mpegts" vs "aac") without consuming
        //     stream data. The open then blocks on the companion's
        //     first segment bytes, the same way the main probe blocked
        //     on the main reader. Any failure here fails the LOAD:
        //     shipping a silently video-only session is exactly the
        //     failure mode the old fail-fast existed to prevent, and a
        //     thrown start() sends the host down its server-muxed
        //     fallback route.
        let audioDem: Demuxer
        if isLiveSession, dem.audioStreamIndex < 0, let companion = companionAudioReader {
            let formatHint: String
            if let info = companion as? LiveIngestSourceInfo {
                guard let resolved = info.resolveSegmentFormatHint() else {
                    // Terminal ingest (or no first segment inside the
                    // resolve bound): the companion can't deliver audio.
                    throw HLSVideoEngineError.openFailed(
                        reason: "demuxed-audio companion produced no classifiable first segment")
                }
                formatHint = resolved
            } else {
                // Non-ingest custom companions keep the previous TS contract.
                formatHint = "mpegts"
            }
            let side = Demuxer()
            do {
                try side.open(reader: companion, formatHint: formatHint, isLive: true)
            } catch {
                throw HLSVideoEngineError.openFailed(
                    reason: "demuxed-audio companion open failed (\(error))")
            }
            guard side.audioStreamIndex >= 0,
                  let sideAudioStream = side.stream(at: side.audioStreamIndex) else {
                side.close()
                throw HLSVideoEngineError.openFailed(
                    reason: "demuxed-audio companion has no audio stream")
            }
            // Packed audio: anchor the producer's synthesized side-audio
            // clock on the segment's ID3 PRIV program-clock timestamp,
            // rescaled into the side stream's own time base (the raw
            // "aac" demuxer's 1/28224000). Guaranteed non-nil for an
            // "aac" resolve (the reader goes terminal otherwise); the
            // guard is defensive.
            if formatHint == "aac" {
                guard let offset90k = (companion as? LiveIngestSourceInfo)?
                    .packedAudioTimestampOffset90k else {
                    side.close()
                    throw HLSVideoEngineError.openFailed(
                        reason: "packed-audio companion carries no program-clock timestamp")
                }
                let tb = sideAudioStream.pointee.time_base
                packedSideAudioStartPts = av_rescale_q(
                    offset90k, AVRational(num: 1, den: 90000), tb)
            }
            restartLock.lock()
            sideAudioDemuxer = side
            restartLock.unlock()
            audioDem = side
            companionAudioTracks = side.audioTrackInfos()
            EngineLog.emit(
                "[HLSVideoEngine] demuxed-audio companion opened: format=\(formatHint) "
                + "side demuxer audioStreamIndex=\(side.audioStreamIndex)"
                + (packedSideAudioStartPts.map { " packedStartPts=\($0) (side TB)" } ?? ""),
                category: .session
            )
        } else {
            audioDem = dem
        }

        // 6a. Pick the audio routing: stream-copy for codecs legal in
        //     fMP4, FLAC bridge for those that aren't, drop for the
        //     unsupported tail. The fallback cascade tries stream-copy
        //     first (the common case is `ec-3` for streaming UHD with
        //     Atmos JOC); if the muxer rejects the header (EAC3 from
        //     MKV without a parsed `dec3` extradata is the typical
        //     EINVAL), we retry with the FLAC bridge; if that also
        //     fails we ship video-only (demuxed-audio sessions instead
        //     fail the load, see buildProducerWithAudioCascade).
        //
        // Source selection: caller can override the auto-picked stream
        // (host-driven audio track switching). Override is validated
        // against the container; an invalid index logs and falls back
        // to libavformat's pick so a stale picker selection from a
        // previous title can't strand playback without audio. All
        // audio-side reads go through `audioDem`, which is the side
        // demuxer for demuxed-audio sessions and `dem` otherwise.
        var autoAudioStreamIndex = audioDem.audioStreamIndex
        // Live empty-codecpar escape: av_find_best_stream SKIPS audio
        // streams whose codecpar has no channels / sample_rate, which is
        // exactly what a live TS probe leaves behind when
        // find_stream_info gives up before decoding an audio frame (the
        // shape the AAC repair below exists for; it used to surface in
        // the override log as the AVERROR_STREAM_NOT_FOUND garbage value
        // -1381258232). Fall back to the first stream that IS audio by
        // codec type, matching the track list the host was shown, so the
        // auto pick reaches the repair instead of silently going
        // video-only. VOD keeps the strict best-stream pick.
        if autoAudioStreamIndex < 0, isLiveSession {
            let byType = audioDem.firstAudioStreamIndexByType
            if byType >= 0 {
                EngineLog.emit(
                    "[HLSVideoEngine] audio: av_find_best_stream found no usable audio "
                    + "(live probe left empty codecpar?); falling back to first "
                    + "audio-type stream \(byType)",
                    category: .session
                )
                autoAudioStreamIndex = byType
            }
        }
        let audioStreamIndex: Int32
        if let override = audioSourceStreamIndexOverride {
            if Self.isAudioStream(demuxer: audioDem, index: override) {
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

        if audioStreamIndex >= 0, let audioStream = audioDem.stream(at: audioStreamIndex) {
            let codecID = audioStream.pointee.codecpar.pointee.codec_id
            // A live MPEG-TS probe can return an AAC stream with EMPTY
            // codec parameters: find_stream_info gave up before decoding
            // an audio frame ("Could not find codec parameters for stream
            // 1 ... unspecified sample format"; device repro: KiKA). With
            // sample_rate 0 the ASC synthesis below bails, the stream-copy
            // header write fails, the bridge cannot initialise either, and
            // the session silently degrades to video-only. Fill the
            // de-facto live defaults instead: Jellyfin live transcodes pin
            // their audio output to 48 kHz stereo AAC-LC in the request
            // they generate, and DVB/IPTV ADTS is 48 kHz stereo in
            // practice. If a source ever deviates, audio pitch will be
            // off and this log line is the breadcrumb.
            if isLiveSession, codecID == AV_CODEC_ID_AAC,
               audioStream.pointee.codecpar.pointee.sample_rate == 0 {
                audioStream.pointee.codecpar.pointee.sample_rate = 48000
                if audioStream.pointee.codecpar.pointee.ch_layout.nb_channels <= 0 {
                    av_channel_layout_default(&audioStream.pointee.codecpar.pointee.ch_layout, 2)
                }
                if audioStream.pointee.codecpar.pointee.profile < 0 {
                    audioStream.pointee.codecpar.pointee.profile = 1  // FF_PROFILE_AAC_LOW
                }
                EngineLog.emit(
                    "[HLSVideoEngine] audio: AAC stream had no codec parameters from the live "
                    + "probe; assuming 48 kHz stereo AAC-LC (Jellyfin live transcode default)",
                    category: .session
                )
            }
            let compat = AudioCodecCompat.from(codecID)
            // HE-AAC (SBR) / HE-AACv2 (PS) only has to bridge when the source
            // carries NO AudioSpecificConfig (live ADTS/MPEG-TS): there the
            // ASC is synthesized below and would declare plain LC at the SBR
            // OUTPUT rate, which AudioToolbox decodes as garbage (-11821, NBC
            // HE-AAC). A movie-container HE-AAC track already ships a correct
            // ASC in extradata, so fMP4 stream-copy preserves SBR/PS and
            // AVPlayer decodes it natively — bridging it was an unnecessary
            // EAC3/FLAC re-encode (AetherEngine#33). See aacRequiresBridge.
            let acpForHE = audioStream.pointee.codecpar.pointee
            let hasASC = acpForHE.extradata != nil && acpForHE.extradata_size > 0
            let isHEAAC = acpForHE.codec_id == AV_CODEC_ID_AAC
                && Self.aacRequiresBridge(
                    profile: acpForHE.profile,
                    frameSize: acpForHE.frame_size,
                    hasASC: hasASC
                )
            if compat.requiresBridge || isHEAAC {
                bridgePreferred = true
                EngineLog.emit(
                    isHEAAC
                        ? "[HLSVideoEngine] audio: HE-AAC (profile=\(acpForHE.profile) frameSize=\(acpForHE.frame_size)), ADTS stream-copy would mis-signal SBR, bridging instead"
                        : "[HLSVideoEngine] audio: codec=\(compat) (bridge required), decoding + FLAC re-encode",
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
                // Deep-copy AFTER prepareAACForFMP4 so the synthesized ASC
                // extradata is included; same demuxer-lifetime decoupling
                // as the video config (see OwnedCodecParameters). The
                // bridge path is unaffected: bridge.encoderCodecpar is
                // bridge-owned and the bridge lives on the engine.
                guard let ownedAudioParams = OwnedCodecParameters(copying: audioStream.pointee.codecpar) else {
                    throw HLSVideoEngineError.openFailed(reason: "audio codecpar copy failed")
                }
                ownedCodecParams.append(ownedAudioParams)
                streamCopyAudio = HLSSegmentProducer.AudioConfig(
                    codecpar: UnsafePointer(ownedAudioParams.ptr),
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
                // EAC3 (with or without JOC) always stream-copies,
                // regardless of the current audio output route. A JOC
                // track is signaled in the playlist as `ec-3`, the exact
                // same CODECS string as a non-JOC EAC3 5.1 track (the
                // JOC marker lives only in the per-segment `dec3` box,
                // which AVPlayer reads at decode time, never at variant
                // selection). AVPlayer therefore cannot, and does not,
                // reject a JOC variant on a Bluetooth A2DP / LE route
                // that it would accept for plain EAC3 5.1 — it opens the
                // item and lets the downstream renderer decide: HDMI
                // passes DD+/JOC through to the AVR, AirPods render Atmos
                // spatially, and plain A2DP / LE downmixes the bed
                // channels to stereo natively. No FLAC bridge is needed
                // for any of these (issue #34). The only EAC3 case that
                // genuinely cannot stream-copy is a source whose codecpar
                // lacks the `dec3` extradata the mp4 muxer needs to write
                // the sample entry (typical of EAC3-from-MKV); that is
                // caught route-independently by `probeWriteHeader` in
                // `buildProducerWithAudioCascade`, which then bridges.
                audioHLSCodecs = compat.hlsCodecsString
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec=\(compat) → stream-copy as `\(audioHLSCodecs ?? "?")` "
                    + "\(isJOC ? "[JOC=Atmos] " : "")"
                    + "(fallback duration=\(audioFallbackDurationPts) in audioTb \(audioTb.num)/\(audioTb.den))",
                    category: .session
                )
            } else {
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec id=\(codecID.rawValue) unsupported, video-only",
                    category: .session
                )
            }
        }

        // 6a-post. Packed side audio: per-packet fallback advance for
        //     the producer's synthesized clock, one AAC frame in the
        //     side stream's time base. Computed AFTER the pick + repair
        //     above so frame_size / sample_rate are as filled-in as
        //     they will get (48 kHz default mirrors the repair).
        if packedSideAudioStartPts != nil, audioStreamIndex >= 0,
           let sideStream = audioDem.stream(at: audioStreamIndex) {
            let acp = sideStream.pointee.codecpar.pointee
            let samples = acp.frame_size > 0 ? Int64(acp.frame_size) : 1024
            let rate = acp.sample_rate > 0 ? Int64(acp.sample_rate) : 48000
            let tb = sideStream.pointee.time_base
            packedSideAudioFallbackDurationPts = (tb.num > 0 && tb.den > 0)
                ? max(1, samples * Int64(tb.den) / (rate * Int64(tb.num)))
                : 1
        }

        // 6b. Attempt the cascade. The bridge instance, if needed, is
        //     constructed up-front so it survives across restarts.
        let prod: HLSSegmentProducer
        prod = try buildProducerWithAudioCascade(
            preferBridge: bridgePreferred,
            streamCopyAudio: streamCopyAudio,
            sourceAudioStreamIndex: audioStreamIndex,
            sourceAudioStream: audioStreamIndex >= 0 ? audioDem.stream(at: audioStreamIndex) : nil,
            audioHLSCodecs: &audioHLSCodecs
        )
        self.producer = prod
        // What the session ACTUALLY plays: the cascade can still fall
        // back to video-only (savedAudioConfig nil), in which case no
        // audio stream is muxed regardless of the pick above.
        self.activeAudioSourceStreamIndex = savedAudioConfig != nil ? audioStreamIndex : -1

        // 7. Wire the provider, the server, and serve the URL.
        let manifestCodecs = audioHLSCodecs.map { "\(primaryCodecs),\($0)" } ?? primaryCodecs
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
            isLive: isLiveSession,
            liveWindowSizing: LiveWindowSizing(
                targetSegmentDurationSeconds: Self.targetSegmentDuration,
                dvrWindowSeconds: dvrWindowSeconds
            ),
            blockingReloadEnabled: liveBlockingReloadEnabled,
            targetDurationFloorSeconds: liveTargetDurationFloorSeconds,
            restartHandler: isLiveSession ? nil : { [weak self] idx in
                self?.requestRestart(at: idx)
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
    //
    // Every forwarder snapshots its subsystem ref under `restartLock`
    // first: stop(), performRestart(at:), and the live-reopen path
    // replace/nil these strong refs under that lock, so a lock-free read
    // from the sampler/memprobe thread was an ARC data race (a read
    // interleaved with the final release in stop() can retain a freed
    // object). Only the ref snapshot happens under the lock; the actual
    // counter read runs after unlock so telemetry can't block a restart.

    /// Snapshot the subsystem references under `restartLock`. See the
    /// comment above; `liveScrubThumbnailSource` documents the same
    /// convention.
    private func subsystemSnapshot() -> (
        producer: HLSSegmentProducer?, cache: SegmentCache?,
        server: HLSLocalServer?, demuxer: Demuxer?, audioBridge: AudioBridge?
    ) {
        restartLock.lock()
        defer { restartLock.unlock() }
        return (producer, cache, server, demuxer, audioBridge)
    }

    /// Bytes the active demuxer has fetched from the source. Mirrors
    /// `Demuxer.avioBytesFetched`.
    var demuxerBytesFetched: Int64 { subsystemSnapshot().demuxer?.avioBytesFetched ?? 0 }

    /// Resident bytes in the loopback HLS segment cache.
    var segmentCacheTotalBytes: Int { subsystemSnapshot().cache?.totalBytes ?? 0 }

    /// Authoritative on-disk byte footprint of the resident segment files
    /// (freshly stat-ed). 0 when no native session is active. Used by the
    /// `aetherctl live --report-cache-bytes` harness to verify the live
    /// window keeps disk bounded.
    var segmentCacheDiskBytes: Int64 { subsystemSnapshot().cache?.diskBytes() ?? 0 }

    /// Producer restart sessions in the current session.
    var producerRestartCount: Int { subsystemSnapshot().producer?.restartCount ?? 0 }

    /// Lifetime bytes emitted by the active MP4SegmentMuxer.
    var muxedBytesLifetime: Int { subsystemSnapshot().producer?.muxerLifetimeFragmentBytes ?? 0 }

    /// Lifetime bytes the loopback HLS server has written to AVPlayer.
    var serverLifetimeBytesSent: Int { subsystemSnapshot().server?.lifetimeBytesSent ?? 0 }

    /// HTTP requests served by the loopback HLS server.
    var serverRequestCount: Int { subsystemSnapshot().server?.requestCount ?? 0 }

    /// Number of live segments the provider currently lists (0 for VOD
    /// sessions and before the first cut). Read by the engine's
    /// live-reload watchdog as the "producer is serving" evidence:
    /// >= the 2-segment startup cushion means the manifest hold has
    /// been released and AVPlayer has real content to become ready
    /// against. Snapshot under restartLock, mirroring
    /// `liveScrubThumbnailSource`'s provider-read convention.
    var liveSegmentCount: Int {
        guard isLiveSession else { return 0 }
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        return prov?.segmentCount ?? 0
    }

    /// Bytes currently held in AudioBridge's FIFO + swr-delay buffers.
    var audioBridgeLiveBytes: Int { subsystemSnapshot().audioBridge?.liveBytes.totalBytes ?? 0 }

    /// Most recently measured audio/video gate gap in source-clock ms.
    var lastAVGapMs: Double { subsystemSnapshot().producer?.lastAVGapMs ?? 0 }

    /// Read the current pipeline counters. Returns zeros for any
    /// sub-system that hasn't been constructed yet (pre-start or
    /// post-stop).
    public func diagnosticStats() -> DiagnosticStats {
        let subs = subsystemSnapshot()
        let abLive = subs.audioBridge?.liveBytes
        return DiagnosticStats(
            segmentCacheCount: subs.cache?.count ?? 0,
            segmentCacheBytes: subs.cache?.totalBytes ?? 0,
            producerPacketsWritten: subs.producer?.packetsWrittenCount ?? 0,
            avioBytesFetched: subs.demuxer?.avioBytesFetched ?? 0,
            audioFifoSamples: subs.audioBridge?.fifoSampleCount ?? 0,
            audioBridgeFifoBytes: abLive?.fifoBytes ?? 0,
            audioBridgeSwrBytes: abLive?.swrDelayBytes ?? 0,
            muxerLifetimeFragmentBytes: subs.producer?.muxerLifetimeFragmentBytes ?? 0,
            muxerFragmentCuts: subs.producer?.muxerFragmentCuts ?? 0,
            serverConnectionCount: subs.server?.activeConnectionCount ?? 0,
            serverLifetimeBytesSent: subs.server?.lifetimeBytesSent ?? 0,
            serverSendfileBytesSent: subs.server?.lifetimeSendfileBytes ?? 0,
            packetsAlive: PacketBalanceTracker.alive,
            packetsTotalAllocs: PacketBalanceTracker.totalAllocs,
            producerRestartCount: subs.producer?.restartCount ?? 0,
            lastAVGapMs: subs.producer?.lastAVGapMs ?? 0,
            serverRequestCount: subs.server?.requestCount ?? 0
        )
    }

    /// Composed init.mp4 + segment bytes for the live scrub-thumbnail
    /// path, plus the segment index. The byte copy makes window-slide
    /// eviction harmless: if the file vanishes between lookup and read,
    /// this returns nil and the preview falls back to time-only.
    /// Synchronous local file I/O on a 1-3 MB file; call off-main.
    /// `segmentIndex` lets the caller dedupe repeat probes into the same
    /// segment (extractor reuse).
    func liveScrubThumbnailSource(atSeconds seconds: Double) -> (data: Data, segmentIndex: Int)? {
        // Snapshot provider under restartLock -- mirrors the live-reopen
        // path's convention (stop() writes provider = nil under the same
        // lock), keeping this unsynchronized off-main read safe.
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        guard isLiveSession, let prov else { return nil }
        guard let seg = prov.liveThumbnailSegment(atSeconds: seconds) else { return nil }
        guard let initData = prov.peekInitSegment(),
              let segData = try? Data(contentsOf: seg.fileURL) else { return nil }
        return (initData + segData, seg.index)
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
        sessionEpoch &+= 1
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
        // Demuxed-audio side demuxer rides the exact same teardown as
        // the main demuxer: synchronous markClosed below so a pump
        // parked in its read unblocks immediately, close in the
        // detached cleanup after waitForFinish.
        let sd = sideAudioDemuxer
        sideAudioDemuxer = nil
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
        // The owned codecpar copies must outlive the pump's unwind (the
        // muxer reads them); hand them to the detached cleanup, which
        // releases them after waitForFinish.
        let ownedParams = ownedCodecParams
        ownedCodecParams = []
        // Abort a live-reopen attempt blocked in Demuxer.open: markClosed
        // is lock-free, the reopen loop unwinds via its identity guards.
        let reopening = reopenDemuxer
        reopenDemuxer = nil
        segmentPlan = []
        restartLock.unlock()
        reopening?.markClosed()

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
        sd?.markClosed()
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
            sd?.close()
            preopened?.close()
            // Release the owned codecpar copies last: the pump (now
            // finished or abandoned) read them via the saved configs.
            _ = ownedParams
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
    func makeProducer(
        baseIndex: Int,
        liveReopenOutputEndSeconds: Double? = nil
    ) throws -> HLSSegmentProducer {
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
        if let endSeconds = liveReopenOutputEndSeconds {
            // Live reopen after source loss: no scan target (join the
            // fresh source at its head), but the first fragment's tfdt
            // must CONTINUE the output timeline where the failed
            // producer's last appended segment ended, so AVPlayer's
            // cumulative-EXTINF clock and the fragment timestamps stay
            // on one axis across the reopen seam (the seam segment
            // additionally carries #EXT-X-DISCONTINUITY via
            // firstSegmentDiscontinuous).
            videoTarget = Int64.min
            desiredVideoTfdt = sourceVideoTbSeconds > 0
                ? Int64(endSeconds / sourceVideoTbSeconds)
                : 0
            desiredAudioTfdt = savedAudioConfig.map {
                av_rescale_q(desiredVideoTfdt, cfg.timeBase, $0.sourceTimeBase)
            } ?? 0
        } else if baseIndex > 0, baseIndex < segmentPlan.count {
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
        // Clamp the lower bound: a live reopen passes baseIndex >
        // segmentPlan.count (the plan is empty for live), which would
        // otherwise build an invalid range.
        let plannedSegs = segmentPlan[min(baseIndex, segmentPlan.count)..<segmentPlan.count]
        var segmentBoundaries: [Int64] = plannedSegs.map { $0.startPts }
        if let last = plannedSegs.last {
            segmentBoundaries.append(last.endPts)
        }

        let prod = try HLSSegmentProducer(
            demuxer: dem,
            videoStreamIndex: videoStreamIndex,
            video: cfg,
            audio: savedAudioConfig,
            sideAudioDemuxer: sideAudioDemuxer,
            cache: cache,
            baseIndex: baseIndex,
            targetSegmentDurationSeconds: Self.targetSegmentDuration,
            videoFallbackDurationPts: videoFallbackDurationPts,
            audioFallbackDurationPts: audioFallbackDurationPts,
            restartTargetVideoDts: videoTarget,
            desiredFirstVideoTfdtPts: desiredVideoTfdt,
            desiredFirstAudioTfdtPts: desiredAudioTfdt,
            segmentBoundaries: segmentBoundaries,
            isLive: isLiveSession,
            packedSideAudioStartPts: packedSideAudioStartPts,
            packedSideAudioFallbackDurationPts: packedSideAudioFallbackDurationPts
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
        prod.onPumpFinished = { [weak self, weak prod] reason in
            guard let self, let prod else { return }
            self.handlePumpFinished(prod, reason: reason)
        }
        // Native mov_text track: propagate both the session-level flag and
        // the cue store onto every producer (initial + restart) so the muxer
        // init moov is consistent and the per-segment cue drain works across
        // scrub-driven producer restarts (#55). The store is nil when no text
        // subtitle track is active; the nil path is byte-identical to
        // sessions without native subtitle support (no-op in advanceMuxer).
        prod.enableNativeSubtitleTrack = enableNativeSubtitleTrackForSession
        // Thread the full store set + languages UNCONDITIONALLY (#55,
        // all-tracks): an empty session set clears the producer to [] so a
        // session without native subtitles is byte-identical, and a restart
        // after the stores were detached (clearSubtitle) does not carry the
        // old set forward. Setting the array only when non-empty was the
        // Task 2 latent gap this closes.
        prod.subtitleCueStores = nativeSubtitleCueStoresForSession
        prod.nativeSubtitleLanguages = nativeSubtitleLanguagesForSession
        return prod
    }

    // MARK: - Live source-loss recovery

    /// Bounded reopen-with-backoff after a live source is lost. The AVIO
    /// reader already absorbs transient drops by reconnecting internally
    /// (up to its unproductive-reconnect cap), so the pump only exits on
    /// a genuinely exhausted source: the Jellyfin transcode died, the
    /// tuner dropped, or the network was gone long enough to blow the
    /// reader's budget. For VOD the engine's restartHandler covers
    /// recovery; live had NO recovery at all (the stream stayed dead
    /// until the user re-entered the channel). The reopen tears down the
    /// dead demuxer, dials a fresh source connection, and brings up a
    /// producer that continues the output timeline (see
    /// `liveReopenOutputEndSeconds` in `makeProducer`).
    static let liveReopenMaxAttempts = 6

    /// Cross-cycle backstop: each lost source gets a fresh reopen budget,
    /// so an open-then-starve source (connects, never delivers a usable
    /// segment, pump times out) would otherwise cycle open/reopen forever
    /// without ever surfacing an error. Consecutive reopen cycles that
    /// produced NO new segment count as barren; after 3 the engine stops
    /// reviving the session.
    var barrenReopenCycles = 0
    var lastReopenSegmentCount = -1
    static let maxBarrenReopenCycles = 3

    /// Converts the producer's `videoShiftPts` (in source video TB)
    /// to seconds and notifies the engine + AetherEngine that the
    /// AVPlayer-clock-to-source-PTS translation may have changed.
    /// Fires on initial start (shift ≈ firstKeyframeSeconds) and on
    /// every restart (shift can be larger when matroska seek
    /// imprecision lands past the planned target).
    private func handleVideoShiftKnown(_ shiftPts: Int64) {
        let seconds = shiftPts == Int64.min ? 0 : Double(shiftPts) * sourceVideoTbSeconds
        setPlaylistShiftSeconds(seconds)
        // Refresh the cue store's shift so cuesInWindow maps source-PTS
        // cue timestamps onto the updated AVPlayer axis after a restart
        // (the shift can change when matroska seek lands past the planned
        // keyframe). No-op when no text subtitle track is active (#55).
        // Refresh EVERY store so all native tracks stay on the same axis.
        nativeSubtitleCueStoresForSession.forEach { $0.setShiftSeconds(seconds) }
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
    func handleLiveTimelineRebase(_ shiftPts: Int64, seamOutputSeconds: Double) {
        let seconds = shiftPts == Int64.min ? 0 : Double(shiftPts) * sourceVideoTbSeconds
        setPlaylistShiftSeconds(seconds)
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
    /// Public restart entry wired to the segment provider's restart
    /// handler. Coalesces a burst of restart requests so only the
    /// in-flight restart plus one final restart at the settled target run,
    /// instead of serializing one full teardown per intermediate scrub
    /// position (the cascade that wedged the pipeline in #35).
    func requestRestart(at idx: Int) {
        restartLock.lock()
        let shouldRun = restartCoalescer.begin(idx)
        // Map the requested segment to its playlist-axis start time while we
        // hold the lock that guards segmentPlan (issue #38 seek signal).
        let seekTime = segmentStartSecondsLocked(idx)
        restartLock.unlock()
        guard shouldRun else {
            EngineLog.emit(
                "[HLSVideoEngine] restart at idx=\(idx) coalesced behind in-flight restart",
                category: .session
            )
            return
        }
        // A native AVKit scrub (or any AVPlayer seek that landed out of the
        // served LRU window) is now in flight; publish it until the coalesced
        // restart run drains (#38). Purely additive to the #35 coalescer.
        onSeekStateChanged?(true, seekTime)
        var target = idx
        while true {
            performRestart(at: target)
            restartLock.lock()
            let nextTarget = restartCoalescer.next(justRan: target)
            let nextSeekTime = nextTarget.map { segmentStartSecondsLocked($0) } ?? nil
            restartLock.unlock()
            guard let nextTarget else { break }
            EngineLog.emit(
                "[HLSVideoEngine] coalesced restart advancing to settled target idx=\(nextTarget)",
                category: .session
            )
            // Burst scrub coalesced to a new settled target: keep the signal
            // in flight, update the published target.
            onSeekStateChanged?(true, nextSeekTime)
            target = nextTarget
        }
        // The restart run settled at the final target and the producer is
        // rebuilt and serving; clear the in-flight seek signal.
        onSeekStateChanged?(false, nil)
    }

    /// `segmentPlan[idx].startSeconds` on the AVPlayer/playlist axis, or nil
    /// if out of range. Caller must hold `restartLock` (segmentPlan is
    /// guarded by it).
    private func segmentStartSecondsLocked(_ idx: Int) -> Double? {
        guard idx >= 0, idx < segmentPlan.count else { return nil }
        return segmentPlan[idx].startSeconds
    }

    // Renamed from restartProducer(at:). Now driven exclusively through
    // requestRestart(at:) so bursts coalesce (#35). The body (restartGate
    // serialization, sessionEpoch abort guard, demuxer seek, rebuild) is
    // unchanged.
    private func performRestart(at idx: Int) {
        // Restarts serialize among themselves on restartGate (held across
        // the waits below). restartLock is only taken for the brief state
        // snapshots/mutations, so a stop() landing mid-restart (SwiftUI
        // dismiss on the main thread) is never blocked behind the old
        // producer's 5 s waitForFinish or the network-bound demuxer seek;
        // it bumps sessionEpoch instead and this restart unwinds at the
        // re-validation below.
        restartGate.lock()
        defer { restartGate.unlock() }

        restartLock.lock()
        guard idx >= 0, idx < segmentPlan.count, let dem = demuxer else {
            restartLock.unlock()
            return
        }
        let epoch = sessionEpoch
        let old = producer
        producer = nil
        let ab = audioBridge
        let targetStartPts = segmentPlan[idx].startPts
        let videoTb = savedVideoConfig?.timeBase ?? AVRational(num: 1, den: 1000)
        restartLock.unlock()

        let restartStart = DispatchTime.now()

        if let old {
            old.stop()
            let ok = old.waitForFinish(timeout: 5.0)
            if !ok {
                EngineLog.emit(
                    "[HLSVideoEngine] restart at idx=\(idx): old producer didn't exit within 5s, abandoning it "
                    + "(its in-flight read shares the demuxer and may consume the first post-seek packet; "
                    + "if the new session starts a GOP late, this is why)",
                    category: .session
                )
            }
        }

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
        let absoluteTargetSeconds = Double(targetStartPts) * Double(videoTb.num) / Double(videoTb.den)
        // Seek on the snapshotted demuxer, outside restartLock: the seek
        // is network-bound on remote sources. A concurrent stop() calls
        // markClosed() on the same demuxer, which makes this seek fail
        // fast instead of racing the teardown.
        dem.seek(to: absoluteTargetSeconds)
        // Re-arm the FLAC bridge's PTS rebase off the new demuxer
        // cursor. Without this, the bridge's encoder timeline keeps
        // climbing from where the old producer left off, drifting
        // out of alignment with the freshly-seeked video PTS.
        ab?.startSegment()

        // Re-validate before installing the new producer: a stop() that
        // landed during the waits above already tore the session down
        // (and bumped the epoch); bringing up a producer now would
        // resurrect the pump into a closed cache/server.
        restartLock.lock()
        guard sessionEpoch == epoch else {
            restartLock.unlock()
            EngineLog.emit(
                "[HLSVideoEngine] restart at idx=\(idx): superseded by stop(), unwinding",
                category: .session
            )
            return
        }
        do {
            let newProd = try makeProducer(baseIndex: idx)
            producer = newProd
            restartLock.unlock()
            newProd.start()
        } catch {
            restartLock.unlock()
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

}
